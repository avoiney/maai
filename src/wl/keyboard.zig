//! Minimal keyboard input: xkbcommon keymap handling and key-to-byte encoding.
//!
//! SCOPE NOTE: PLAN.md puts keyboard work in phase 3. This is a deliberate subset
//! brought forward, because phase 1's acceptance criteria ("`ls --color` and a
//! shell prompt render correctly") cannot be checked interactively without being
//! able to type. Phase 3 replaces this wholesale and adds what is missing here:
//!
//!   - key repeat (repeat_info is captured below but not acted on)
//!   - the Kitty keyboard protocol and legacy modifyOtherKeys
//!   - xkbcommon-compose for dead keys and Compose sequences
//!   - application cursor-key mode (DECCKM), which changes CSI to SS3
//!   - configurable bindings

const std = @import("std");
const c = @import("../c.zig").c;
const Modes = @import("../term/screen.zig").Modes;
const mouse = @import("../term/mouse.zig");

/// Where encoded key bytes go. Indirected so this module does not need to know
/// about the PTY or the App.
pub const Sink = struct {
    ctx: *anyopaque,
    write: *const fn (*anyopaque, []const u8) void,
};

/// First refusal on a key press. Returning true consumes it, so `Ctrl+Shift+C`
/// copies instead of sending a control byte to the child.
pub const Bindings = struct {
    ctx: *anyopaque,
    /// `keycode` is the raw evdev code, for bindings that mean "the Nth key of a row"
    /// rather than "this character" — see config.num_row.
    handle: *const fn (*anyopaque, sym: u32, keycode: u32, ctrl: bool, shift: bool, alt: bool) bool,
};

pub const Keyboard = struct {
    xkb: ?*c.struct_xkb_context = null,
    keymap: ?*c.struct_xkb_keymap = null,
    state: ?*c.struct_xkb_state = null,
    /// Dead keys and Compose sequences.
    ///
    /// Not optional polish on this machine: the layout is French AZERTY, where `^`
    /// and `¨` are *dead* keys — `key <AD11> { [dead_circumflex, dead_diaeresis…] }`.
    /// A dead keysym has no UTF-8 of its own, so `xkb_state_key_get_utf8` returns
    /// zero bytes for it. Without compose handling the key silently produced nothing
    /// and the following letter arrived unaccented: `être` came out as `etre`.
    compose_table: ?*c.struct_xkb_compose_table = null,
    compose_state: ?*c.struct_xkb_compose_state = null,
    wl_kbd: ?*c.struct_wl_keyboard = null,
    sink: ?Sink = null,
    bindings: ?Bindings = null,
    /// Terminal modes that change how keys encode. Borrowed from the Screen.
    modes: ?*const Modes = null,
    /// Called when the modifier state changes. Link hovering depends on whether
    /// Ctrl is held, and without this the highlight would only appear once the
    /// pointer next moved.
    on_mods: ?struct {
        ctx: *anyopaque,
        changed: *const fn (*anyopaque) void,
    } = null,

    /// Serial of the most recent input event. The compositor requires a recent one
    /// to accept a clipboard claim, which is what stops a background client from
    /// silently taking the selection.
    last_serial: u32 = 0,

    /// From repeat_info: keys per second, and the delay before repeating starts.
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,

    /// Held-key repeat state. Driven from the main loop's poll timeout rather than a
    /// timerfd, since the loop already computes a deadline for synchronized output.
    repeat_buf: [64]u8 = undefined,
    repeat_len: usize = 0,
    repeat_key: u32 = 0,
    /// Monotonic milliseconds at which the next repeat is due; 0 means idle.
    repeat_at: i64 = 0,

    /// Milliseconds between repeats once started.
    pub fn repeatInterval(self: *const Keyboard) i64 {
        if (self.repeat_rate <= 0) return 0;
        return @max(1, @divTrunc(@as(i64, 1000), self.repeat_rate));
    }

    /// Emit one repeat and schedule the next. Call when `repeat_at` has come due.
    pub fn fireRepeat(self: *Keyboard, now_ms: i64) void {
        if (self.repeat_len == 0) return;
        if (self.sink) |s| s.write(s.ctx, self.repeat_buf[0..self.repeat_len]);
        const interval = self.repeatInterval();
        if (interval == 0) {
            self.stopRepeat();
        } else {
            self.repeat_at = now_ms + interval;
        }
    }

    pub fn stopRepeat(self: *Keyboard) void {
        self.repeat_at = 0;
        self.repeat_len = 0;
        self.repeat_key = 0;
    }

    pub fn init(self: *Keyboard) void {
        self.xkb = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        self.initCompose();
    }

    /// Build the compose table from the locale's Compose file.
    ///
    /// Failure is not fatal: without a table, dead keys behave as they did before
    /// this existed. A missing Compose file is a real configuration, not a bug.
    fn initCompose(self: *Keyboard) void {
        const xkb = self.xkb orelse return;

        // The same precedence libX11 uses. `xkb_compose_table_new_from_locale` reads
        // the env itself, but only LC_ALL/LC_CTYPE/LANG in that order, and being
        // explicit here documents what decides which Compose file is used.
        const locale = std.c.getenv("LC_ALL") orelse
            std.c.getenv("LC_CTYPE") orelse
            std.c.getenv("LANG") orelse
            "C.UTF-8";

        self.compose_table = c.xkb_compose_table_new_from_locale(
            xkb,
            locale,
            c.XKB_COMPOSE_COMPILE_NO_FLAGS,
        );
        const table = self.compose_table orelse return;
        self.compose_state = c.xkb_compose_state_new(
            table,
            c.XKB_COMPOSE_STATE_NO_FLAGS,
        );
    }

    pub fn attach(self: *Keyboard, wl_kbd: *c.struct_wl_keyboard) void {
        self.wl_kbd = wl_kbd;
        _ = c.wl_keyboard_add_listener(wl_kbd, &keyboard_listener, self);
    }

    pub fn deinit(self: *Keyboard) void {
        if (self.compose_state) |s| c.xkb_compose_state_unref(s);
        if (self.compose_table) |t| c.xkb_compose_table_unref(t);
        if (self.state) |s| c.xkb_state_unref(s);
        if (self.keymap) |k| c.xkb_keymap_unref(k);
        if (self.xkb) |x| c.xkb_context_unref(x);
        if (self.wl_kbd) |k| c.wl_keyboard_release(k);
    }

    fn modActive(self: *Keyboard, name: [*:0]const u8) bool {
        const state = self.state orelse return false;
        return c.xkb_state_mod_name_is_active(
            state,
            name,
            c.XKB_STATE_MODS_EFFECTIVE,
        ) > 0;
    }

    /// Modifier state right now.
    ///
    /// Pointer events carry no modifier information of their own — `wl_pointer`
    /// leaves that to the seat's keyboard — so mouse handling reads it from here.
    pub fn activeMods(self: *Keyboard) mouse.Mods {
        return .{
            .shift = self.modActive("Shift"),
            .alt = self.modActive("Mod1"),
            .ctrl = self.modActive("Control"),
        };
    }

    /// What compose handling did with a key.
    const Composed = union(enum) {
        /// Not part of a sequence; carry on with normal encoding.
        passthrough,
        /// Mid-sequence, or a cancelled one. The key produces no output.
        swallowed,
        /// A finished sequence, already encoded as UTF-8.
        text: []const u8,
    };

    fn compose(self: *Keyboard, sym: u32, buf: []u8) Composed {
        const cs = self.compose_state orelse return .passthrough;
        if (c.xkb_compose_state_feed(cs, sym) != c.XKB_COMPOSE_FEED_ACCEPTED) {
            return .passthrough;
        }

        switch (c.xkb_compose_state_get_status(cs)) {
            c.XKB_COMPOSE_COMPOSING => return .swallowed,
            c.XKB_COMPOSE_COMPOSED => {
                const n = c.xkb_compose_state_get_utf8(cs, @ptrCast(buf.ptr), buf.len);
                c.xkb_compose_state_reset(cs);
                if (n <= 0 or @as(usize, @intCast(n)) > buf.len) return .swallowed;
                return .{ .text = buf[0..@intCast(n)] };
            },
            c.XKB_COMPOSE_CANCELLED => {
                // An invalid sequence, `^` then `q`. Dropped rather than emitting the
                // raw key, which is what xkbcommon's own documented handling does:
                // the cancelling keysym is not the character the user meant, and
                // emitting it would put a stray letter in a command line.
                c.xkb_compose_state_reset(cs);
                return .swallowed;
            },
            // XKB_COMPOSE_NOTHING: fed, but not the start of any sequence.
            else => return .passthrough,
        }
    }

    // ── kitty keyboard protocol ─────────────────────────────────────────────

    /// Base codepoint of a key: what it produces with no modifiers, in the current
    /// layout.
    ///
    /// Level 0 rather than `xkb_state_key_get_one_sym`, which applies the modifiers —
    /// the protocol wants the key's identity, so `Shift+A` and `a` report the same 97.
    fn baseCodepoint(self: *Keyboard, keycode: u32) u32 {
        const km = self.keymap orelse return 0;
        const st = self.state orelse return 0;
        const layout = c.xkb_state_key_get_layout(st, keycode);

        var syms: [*c]const c.xkb_keysym_t = undefined;
        const n = c.xkb_keymap_key_get_syms_by_level(km, keycode, layout, 0, &syms);
        if (n < 1) return 0;
        return c.xkb_keysym_to_utf32(syms[0]);
    }

    /// C0 bytes that two different keys can both produce, which is the ambiguity the
    /// protocol exists to remove.
    ///
    /// `Ctrl+I` and `Tab` are both 0x09; `Ctrl+M` and `Enter` both 0x0D; `Ctrl+[` and
    /// `Esc` both 0x1B; `Ctrl+H` collides with Backspace's other convention; `Ctrl+J`
    /// with the newline a pasted line carries; `Ctrl+Space` and `Ctrl+@` are both NUL.
    fn collidesAsControl(cp: u32) bool {
        return switch (cp) {
            'i', 'm', '[', 'h', 'j', ' ', '@' => true,
            else => false,
        };
    }

    /// Encode a key under the protocol, or null when the legacy form is correct.
    ///
    /// Only flag 1 is implemented (see `Screen.kitty_supported`), so this reports the
    /// keys legacy cannot express *unambiguously* and leaves everything else alone.
    /// That conservatism is deliberate: sending `Ctrl+C` as an escape sequence would
    /// mean the line discipline never sees 0x03, and a program that enabled the mode
    /// and died would leave a shell that cannot be interrupted. The per-screen flags
    /// stack guards against that too, but not sending it is a stronger guarantee.
    fn encodeKitty(self: *Keyboard, keycode: u32, sym: u32, buf: []u8) ?[]const u8 {
        const m = self.activeMods();
        const mods: u8 = 1 +
            (if (m.shift) @as(u8, 1) else 0) +
            (if (m.alt) @as(u8, 2) else 0) +
            (if (m.ctrl) @as(u8, 4) else 0);

        const code: u32 = switch (sym) {
            // Escape always reports. This is the headline of flag 1: an application
            // can tell Esc from the start of an escape sequence *immediately*, instead
            // of waiting to see whether more bytes arrive. nvim's `ttimeoutlen` exists
            // solely to work around not having this.
            c.XKB_KEY_Escape => 27,
            // Modified only: plain Enter/Tab/Backspace have unambiguous legacy bytes,
            // and taking them over is flag 8's job, which we do not claim.
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => if (m.ctrl or m.shift) 13 else return null,
            // Shift+Tab already has `CSI Z`; Ctrl+Tab has nothing.
            c.XKB_KEY_Tab => if (m.ctrl) 9 else return null,
            c.XKB_KEY_BackSpace => if (m.ctrl or m.shift) 127 else return null,
            else => blk: {
                if (!m.ctrl) return null;
                const cp = self.baseCodepoint(keycode);
                if (cp == 0) return null;
                // Ctrl+Shift+letter collapses onto the same C0 byte as Ctrl+letter, so
                // legacy cannot tell them apart either.
                if (m.shift or collidesAsControl(cp)) break :blk cp;
                // Nothing at all in legacy: Ctrl+digit, Ctrl+punctuation. Detected by
                // asking xkb rather than by enumerating a table, since which keys those
                // are depends entirely on the layout — on this AZERTY the digits sit
                // where a US layout has punctuation.
                var probe: [8]u8 = undefined;
                const n = c.xkb_state_key_get_utf8(
                    self.state.?,
                    keycode,
                    @ptrCast(&probe),
                    probe.len,
                );
                if (n <= 0) break :blk cp;
                return null;
            },
        };

        // Modifiers are omitted when there are none, per the protocol's defaults.
        if (mods == 1) {
            return std.fmt.bufPrint(buf, "\x1b[{d}u", .{code}) catch null;
        }
        return std.fmt.bufPrint(buf, "\x1b[{d};{d}u", .{ code, mods }) catch null;
    }

    /// Encode one key press into terminal input bytes. Returns a slice of `buf`,
    /// or null if the key produces nothing.
    fn encode(self: *Keyboard, keycode: u32, buf: []u8) ?[]const u8 {
        const state = self.state orelse return null;
        const sym = c.xkb_state_key_get_one_sym(state, keycode);

        // Before everything else: a dead key must not fall through to the function-key
        // tables or to xkb's UTF-8 translation, which has nothing to give for it.
        switch (self.compose(sym, buf)) {
            .passthrough => {},
            .swallowed => return null,
            .text => |t| return t,
        }

        // The kitty keyboard protocol, when the application asked for it. Returns null
        // to mean "legacy is right for this key", so everything not disambiguated
        // stays byte-identical to what it was before the protocol existed.
        const kitty_flags = if (self.modes) |m| m.kitty_flags else 0;
        if (kitty_flags & 1 != 0) {
            if (self.encodeKitty(keycode, sym, buf)) |bytes| return bytes;
        }

        const mods = self.activeMods();
        const shift = mods.shift;
        const ctrl = mods.ctrl;
        const alt = mods.alt;

        // xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
        const mod: u8 = 1 +
            (if (shift) @as(u8, 1) else 0) +
            (if (alt) @as(u8, 2) else 0) +
            (if (ctrl) @as(u8, 4) else 0);
        const modded = mod != 1;

        const csi_final: ?u8 = switch (sym) {
            c.XKB_KEY_Up => 'A',
            c.XKB_KEY_Down => 'B',
            c.XKB_KEY_Right => 'C',
            c.XKB_KEY_Left => 'D',
            c.XKB_KEY_End => 'F',
            c.XKB_KEY_Home => 'H',
            else => null,
        };
        if (csi_final) |final| {
            if (modded) {
                // Modified cursor keys always use the CSI form with a parameter,
                // even under DECCKM — SS3 has nowhere to put the modifier.
                return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mod, final }) catch null;
            }
            // DECCKM (application cursor keys): SS3 rather than CSI. nvim and less
            // both enable this, and arrow keys misbehave in them without it.
            const app = if (self.modes) |m| m.app_cursor else false;
            return if (app)
                std.fmt.bufPrint(buf, "\x1bO{c}", .{final}) catch null
            else
                std.fmt.bufPrint(buf, "\x1b[{c}", .{final}) catch null;
        }

        const tilde: ?u8 = switch (sym) {
            c.XKB_KEY_Insert => 2,
            c.XKB_KEY_Delete => 3,
            c.XKB_KEY_Page_Up => 5,
            c.XKB_KEY_Page_Down => 6,
            c.XKB_KEY_F5 => 15,
            c.XKB_KEY_F6 => 17,
            c.XKB_KEY_F7 => 18,
            c.XKB_KEY_F8 => 19,
            c.XKB_KEY_F9 => 20,
            c.XKB_KEY_F10 => 21,
            c.XKB_KEY_F11 => 23,
            c.XKB_KEY_F12 => 24,
            else => null,
        };
        if (tilde) |n| {
            return if (modded)
                std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ n, mod }) catch null
            else
                std.fmt.bufPrint(buf, "\x1b[{d}~", .{n}) catch null;
        }

        switch (sym) {
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
                // CR, not LF: the line discipline turns it into NL (ICRNL).
                if (alt) return copy(buf, "\x1b\r");
                return copy(buf, "\r");
            },
            // DEL rather than BS, matching every mainstream terminal's default.
            c.XKB_KEY_BackSpace => return copy(buf, if (alt) "\x1b\x7f" else "\x7f"),
            c.XKB_KEY_Tab => return copy(buf, "\t"),
            c.XKB_KEY_ISO_Left_Tab => return copy(buf, "\x1b[Z"),
            c.XKB_KEY_Escape => return copy(buf, "\x1b"),
            c.XKB_KEY_F1 => return copy(buf, "\x1bOP"),
            c.XKB_KEY_F2 => return copy(buf, "\x1bOQ"),
            c.XKB_KEY_F3 => return copy(buf, "\x1bOR"),
            c.XKB_KEY_F4 => return copy(buf, "\x1bOS"),
            else => {},
        }

        // Everything else goes through xkb's UTF-8 translation, which already
        // applies Ctrl to produce C0 control bytes (Ctrl+C -> 0x03).
        const reserve: usize = if (alt) 1 else 0;
        const n = c.xkb_state_key_get_utf8(
            state,
            keycode,
            @ptrCast(buf.ptr + reserve),
            buf.len - reserve,
        );
        if (n <= 0) return null;
        const len: usize = @intCast(n);

        if (alt) {
            // Alt is sent as an ESC prefix (xterm's "eightBitMeta off" behaviour).
            buf[0] = 0x1b;
            return buf[0 .. len + 1];
        }
        return buf[0..len];
    }
};

fn copy(buf: []u8, bytes: []const u8) ?[]const u8 {
    if (bytes.len > buf.len) return null;
    @memcpy(buf[0..bytes.len], bytes);
    return buf[0..bytes.len];
}

// ── listener ────────────────────────────────────────────────────────────────

const keyboard_listener: c.struct_wl_keyboard_listener = .{
    .keymap = handleKeymap,
    .enter = handleEnter,
    .leave = handleLeave,
    .key = handleKey,
    .modifiers = handleModifiers,
    .repeat_info = handleRepeatInfo,
};

fn handleKeymap(
    data: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    const self: *Keyboard = @ptrCast(@alignCast(data.?));
    defer _ = std.c.close(fd);

    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;
    const xkb = self.xkb orelse return;

    // MAP_PRIVATE: the compositor may share this fd with other clients, so it must
    // not be mapped writable-shared.
    const mem = std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return;
    defer std.posix.munmap(mem);

    const keymap = c.xkb_keymap_new_from_string(
        xkb,
        @ptrCast(mem.ptr),
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return;
    const state = c.xkb_state_new(keymap) orelse {
        c.xkb_keymap_unref(keymap);
        return;
    };

    // The compositor can hand us a new keymap at any time (layout switch), so
    // replace rather than assume this runs once.
    if (self.state) |s| c.xkb_state_unref(s);
    if (self.keymap) |k| c.xkb_keymap_unref(k);
    self.keymap = keymap;
    self.state = state;
    // A layout switch mid-sequence would otherwise leave a half-composed character
    // waiting for a key that no longer exists.
    if (self.compose_state) |cs| c.xkb_compose_state_reset(cs);
}

fn handleKey(
    data: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    serial: u32,
    _: u32,
    key: u32,
    key_state: u32,
) callconv(.c) void {
    const self: *Keyboard = @ptrCast(@alignCast(data.?));
    self.last_serial = serial;

    // Wayland reports evdev keycodes; xkb expects them offset by 8.
    const keycode = key + 8;

    if (key_state != c.WL_KEYBOARD_KEY_STATE_PRESSED) {
        // Only the key actually repeating should cancel it; releasing a modifier
        // while a key is held must not stop the repeat.
        if (self.repeat_key == keycode) self.stopRepeat();
        return;
    }

    // Application shortcuts get first refusal, so Ctrl+Shift+C copies rather than
    // sending a control byte to the child.
    if (self.bindings) |b| {
        const state = self.state;
        const sym = if (state) |s| c.xkb_state_key_get_one_sym(s, keycode) else 0;
        if (b.handle(
            b.ctx,
            sym,
            key,
            self.modActive("Control"),
            self.modActive("Shift"),
            self.modActive("Mod1"),
        )) {
            self.stopRepeat();
            return;
        }
    }

    const sink = self.sink orelse return;
    var buf: [64]u8 = undefined;
    const bytes = self.encode(keycode, &buf) orelse {
        // Produced nothing — a dead key, or a key this encoder has no bytes for.
        // Any repeat still running belongs to a key that is no longer the one being
        // pressed, so holding `a` and then tapping `^` must not keep streaming `a`.
        self.stopRepeat();
        return;
    };
    sink.write(sink.ctx, bytes);

    // Arm repeat, but only for keys the keymap marks as repeating — otherwise
    // holding a modifier would stream bytes.
    const repeats = if (self.keymap) |km|
        c.xkb_keymap_key_repeats(km, keycode) != 0
    else
        false;
    if (repeats and self.repeat_rate > 0 and bytes.len <= self.repeat_buf.len) {
        @memcpy(self.repeat_buf[0..bytes.len], bytes);
        self.repeat_len = bytes.len;
        self.repeat_key = keycode;
        self.repeat_at = nowMs() + self.repeat_delay;
    } else {
        self.stopRepeat();
    }
}

/// Monotonic milliseconds, so an NTP step backwards cannot leave a repeat deadline
/// permanently in the future. `std.time.milliTimestamp` was removed in Zig 0.16.
fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn handleModifiers(
    data: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    const self: *Keyboard = @ptrCast(@alignCast(data.?));
    const state = self.state orelse return;
    _ = c.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
    if (self.on_mods) |h| h.changed(h.ctx);
}

fn handleRepeatInfo(
    data: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    rate: i32,
    delay: i32,
) callconv(.c) void {
    const self: *Keyboard = @ptrCast(@alignCast(data.?));
    self.repeat_rate = rate;
    self.repeat_delay = delay;
}

fn handleEnter(
    _: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    _: ?*c.struct_wl_surface,
    _: ?*c.struct_wl_array,
) callconv(.c) void {}

fn handleLeave(
    _: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    _: ?*c.struct_wl_surface,
) callconv(.c) void {}

// ── tests ───────────────────────────────────────────────────────────────────
//
// Compose is testable without a keyboard because `compose` takes a *keysym*: the
// sequence `dead_circumflex, e` can be fed directly, which is exactly what the
// layout produces and what no script on this machine can synthesize.

const testing = std.testing;

/// A keyboard with only the compose machinery — no Wayland, no keymap.
fn composeOnly() ?Keyboard {
    var kbd = Keyboard{};
    kbd.xkb = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    kbd.initCompose();
    if (kbd.compose_state == null) {
        kbd.deinit();
        return null;
    }
    return kbd;
}

test "a dead key composes with the next letter" {
    var kbd = composeOnly() orelse return error.SkipZigTest;
    defer kbd.deinit();

    var buf: [64]u8 = undefined;

    // `^` alone produces nothing and holds the sequence open. Before this existed the
    // key silently did nothing *and* nothing was held, so the next letter came out
    // bare: `être` typed as `etre`.
    try testing.expect(kbd.compose(c.XKB_KEY_dead_circumflex, &buf) == .swallowed);

    switch (kbd.compose(c.XKB_KEY_e, &buf)) {
        .text => |t| try testing.expectEqualStrings("ê", t),
        else => return error.NotComposed,
    }
}

test "the diaeresis dead key composes too" {
    var kbd = composeOnly() orelse return error.SkipZigTest;
    defer kbd.deinit();

    var buf: [64]u8 = undefined;
    try testing.expect(kbd.compose(c.XKB_KEY_dead_diaeresis, &buf) == .swallowed);
    switch (kbd.compose(c.XKB_KEY_e, &buf)) {
        .text => |t| try testing.expectEqualStrings("ë", t),
        else => return error.NotComposed,
    }
}

test "an ordinary key passes straight through" {
    var kbd = composeOnly() orelse return error.SkipZigTest;
    defer kbd.deinit();

    var buf: [64]u8 = undefined;
    // Otherwise every keystroke would route through compose and normal typing would
    // lose its function keys and control bytes.
    try testing.expect(kbd.compose(c.XKB_KEY_a, &buf) == .passthrough);
    try testing.expect(kbd.compose(c.XKB_KEY_Return, &buf) == .passthrough);
    try testing.expect(kbd.compose(c.XKB_KEY_F5, &buf) == .passthrough);
}

test "an invalid sequence is dropped, and does not wedge the state" {
    var kbd = composeOnly() orelse return error.SkipZigTest;
    defer kbd.deinit();

    var buf: [64]u8 = undefined;
    try testing.expect(kbd.compose(c.XKB_KEY_dead_circumflex, &buf) == .swallowed);
    // `^q` is not a sequence in any Compose file.
    try testing.expect(kbd.compose(c.XKB_KEY_q, &buf) == .swallowed);

    // The important half: the state was reset, so the *next* sequence still works.
    // A wedged compose state would silently eat every following keystroke.
    try testing.expect(kbd.compose(c.XKB_KEY_dead_circumflex, &buf) == .swallowed);
    switch (kbd.compose(c.XKB_KEY_o, &buf)) {
        .text => |t| try testing.expectEqualStrings("ô", t),
        else => return error.NotComposed,
    }
}

test "with no compose table, keys pass through unchanged" {
    // A machine with no Compose file for its locale must still be typable.
    var kbd = Keyboard{};
    defer kbd.deinit();
    var buf: [64]u8 = undefined;
    try testing.expect(kbd.compose(c.XKB_KEY_dead_circumflex, &buf) == .passthrough);
}

// ── kitty protocol tests ────────────────────────────────────────────────────
//
// Also driven without a keyboard: an xkb keymap can be built from layout *names*, so
// the encoder can be asked what it would send for a given key with given modifiers —
// the one thing no script on this machine can produce.

/// A keyboard with a real French AZERTY keymap and no Wayland.
fn azerty() ?Keyboard {
    var kbd = Keyboard{};
    kbd.xkb = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return null;

    var names = c.struct_xkb_rule_names{
        .rules = null,
        .model = null,
        .layout = "fr",
        .variant = null,
        .options = null,
    };
    kbd.keymap = c.xkb_keymap_new_from_names(
        kbd.xkb,
        &names,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse {
        kbd.deinit();
        return null;
    };
    kbd.state = c.xkb_state_new(kbd.keymap) orelse {
        kbd.deinit();
        return null;
    };
    return kbd;
}

/// The keycode that produces `want` at level 0, found by asking the keymap rather than
/// hardcoding evdev numbers — which differ per layout.
fn keycodeFor(kbd: *Keyboard, want: c.xkb_keysym_t) ?u32 {
    const km = kbd.keymap.?;
    var code = c.xkb_keymap_min_keycode(km);
    const max = c.xkb_keymap_max_keycode(km);
    while (code <= max) : (code += 1) {
        var syms: [*c]const c.xkb_keysym_t = undefined;
        const n = c.xkb_keymap_key_get_syms_by_level(km, code, 0, 0, &syms);
        if (n >= 1 and syms[0] == want) return code;
    }
    return null;
}

fn hold(kbd: *Keyboard, ctrl: bool, shift: bool) void {
    const km = kbd.keymap.?;
    var mask: c.xkb_mod_mask_t = 0;
    if (ctrl) mask |= @as(c.xkb_mod_mask_t, 1) <<
        @intCast(c.xkb_keymap_mod_get_index(km, c.XKB_MOD_NAME_CTRL));
    if (shift) mask |= @as(c.xkb_mod_mask_t, 1) <<
        @intCast(c.xkb_keymap_mod_get_index(km, c.XKB_MOD_NAME_SHIFT));
    _ = c.xkb_state_update_mask(kbd.state.?, mask, 0, 0, 0, 0, 0);
}

fn kittyFor(kbd: *Keyboard, sym: c.xkb_keysym_t, buf: []u8) ?[]const u8 {
    const code = keycodeFor(kbd, sym) orelse return null;
    return kbd.encodeKitty(code, sym, buf);
}

test "escape always disambiguates" {
    var kbd = azerty() orelse return error.SkipZigTest;
    defer kbd.deinit();
    var buf: [32]u8 = undefined;

    // The headline of flag 1. Without it an application has to wait and see whether
    // more bytes follow, which is exactly what nvim's ttimeoutlen works around.
    try testing.expectEqualStrings("\x1b[27u", kittyFor(&kbd, c.XKB_KEY_Escape, &buf).?);
}

test "Ctrl+I is distinguishable from Tab" {
    var kbd = azerty() orelse return error.SkipZigTest;
    defer kbd.deinit();
    var buf: [32]u8 = undefined;

    // Both are 0x09 in the legacy encoding, which is why `<C-i>` cannot be mapped in
    // nvim without losing the tab key.
    hold(&kbd, true, false);
    try testing.expectEqualStrings("\x1b[105;5u", kittyFor(&kbd, c.XKB_KEY_i, &buf).?);

    // Tab itself keeps its legacy byte: unmodified, it is not ambiguous.
    hold(&kbd, false, false);
    try testing.expect(kittyFor(&kbd, c.XKB_KEY_Tab, &buf) == null);
    // Ctrl+Tab has no legacy encoding at all.
    hold(&kbd, true, false);
    try testing.expectEqualStrings("\x1b[9;5u", kittyFor(&kbd, c.XKB_KEY_Tab, &buf).?);
}

test "Shift+Enter gets an encoding it never had" {
    var kbd = azerty() orelse return error.SkipZigTest;
    defer kbd.deinit();
    var buf: [32]u8 = undefined;

    // This is what lets Claude Code take a newline without sending the message.
    hold(&kbd, false, true);
    try testing.expectEqualStrings("\x1b[13;2u", kittyFor(&kbd, c.XKB_KEY_Return, &buf).?);
    hold(&kbd, true, false);
    try testing.expectEqualStrings("\x1b[13;5u", kittyFor(&kbd, c.XKB_KEY_Return, &buf).?);

    // Plain Enter still sends CR, so nothing changes for anything else.
    hold(&kbd, false, false);
    try testing.expect(kittyFor(&kbd, c.XKB_KEY_Return, &buf) == null);
}

test "Ctrl+C keeps its control byte" {
    var kbd = azerty() orelse return error.SkipZigTest;
    defer kbd.deinit();
    var buf: [32]u8 = undefined;

    // Deliberately *not* reported. 0x03 is unambiguous, and sending an escape sequence
    // instead would mean the line discipline never sees it — a program that enabled the
    // mode and then died would leave a shell that cannot be interrupted.
    hold(&kbd, true, false);
    try testing.expect(kittyFor(&kbd, c.XKB_KEY_c, &buf) == null);
    try testing.expect(kittyFor(&kbd, c.XKB_KEY_d, &buf) == null);

    // Ctrl+Shift+C *is* reported: legacy collapses it onto the same 0x03.
    hold(&kbd, true, true);
    try testing.expectEqualStrings("\x1b[99;6u", kittyFor(&kbd, c.XKB_KEY_c, &buf).?);
}

test "the colliding control keys report, and the base codepoint ignores shift" {
    var kbd = azerty() orelse return error.SkipZigTest;
    defer kbd.deinit();
    var buf: [32]u8 = undefined;

    hold(&kbd, true, false);
    // Ctrl+M collides with Enter, Ctrl+[ with Escape, Ctrl+H with Backspace.
    try testing.expectEqualStrings("\x1b[109;5u", kittyFor(&kbd, c.XKB_KEY_m, &buf).?);
    try testing.expectEqualStrings("\x1b[104;5u", kittyFor(&kbd, c.XKB_KEY_h, &buf).?);
    try testing.expectEqualStrings("\x1b[106;5u", kittyFor(&kbd, c.XKB_KEY_j, &buf).?);

    // Shift must not change the key's identity: the code is the unshifted codepoint.
    hold(&kbd, true, true);
    try testing.expectEqualStrings("\x1b[109;6u", kittyFor(&kbd, c.XKB_KEY_m, &buf).?);
}

test "nothing is reported without the modifier that makes it ambiguous" {
    var kbd = azerty() orelse return error.SkipZigTest;
    defer kbd.deinit();
    var buf: [32]u8 = undefined;

    // The safety property of the whole feature: with no modifier held, every key falls
    // through to the encoding it had before this protocol existed.
    hold(&kbd, false, false);
    for ([_]c.xkb_keysym_t{
        c.XKB_KEY_a,
        c.XKB_KEY_i,
        c.XKB_KEY_Return,
        c.XKB_KEY_Tab,
        c.XKB_KEY_BackSpace,
    }) |sym| {
        try testing.expect(kittyFor(&kbd, sym, &buf) == null);
    }
    // Shift alone likewise: `A` is not ambiguous.
    hold(&kbd, false, true);
    try testing.expect(kittyFor(&kbd, c.XKB_KEY_a, &buf) == null);
}

test "the protocol is reachable through encode, not just through encodeKitty" {
    // The tests above call `encodeKitty` directly, so they say nothing about whether
    // `encode` ever *reaches* it. That gap hid a real bug once: Tab and Ctrl+I came out
    // identical in a live terminal while every unit test passed.
    var kbd = azerty() orelse return error.SkipZigTest;
    defer kbd.deinit();

    var modes = Modes{};
    kbd.modes = &modes;

    var buf: [32]u8 = undefined;
    const code_i = keycodeFor(&kbd, c.XKB_KEY_i).?;
    const code_tab = keycodeFor(&kbd, c.XKB_KEY_Tab).?;

    // Legacy: both are 0x09, which is the whole problem.
    hold(&kbd, true, false);
    try testing.expectEqualStrings("\t", kbd.encode(code_i, &buf).?);
    hold(&kbd, false, false);
    try testing.expectEqualStrings("\t", kbd.encode(code_tab, &buf).?);

    // With the flag on, they must differ.
    modes.kitty_flags = 1;
    hold(&kbd, true, false);
    try testing.expectEqualStrings("\x1b[105;5u", kbd.encode(code_i, &buf).?);
    hold(&kbd, false, false);
    try testing.expectEqualStrings("\t", kbd.encode(code_tab, &buf).?);

    // And Escape, the other headline.
    const code_esc = keycodeFor(&kbd, c.XKB_KEY_Escape).?;
    try testing.expectEqualStrings("\x1b[27u", kbd.encode(code_esc, &buf).?);
    modes.kitty_flags = 0;
    try testing.expectEqualStrings("\x1b", kbd.encode(code_esc, &buf).?);
}
