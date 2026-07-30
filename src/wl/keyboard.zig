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
    handle: *const fn (*anyopaque, sym: u32, ctrl: bool, shift: bool, alt: bool) bool,
};

pub const Keyboard = struct {
    xkb: ?*c.struct_xkb_context = null,
    keymap: ?*c.struct_xkb_keymap = null,
    state: ?*c.struct_xkb_state = null,
    wl_kbd: ?*c.struct_wl_keyboard = null,
    sink: ?Sink = null,
    bindings: ?Bindings = null,
    /// Terminal modes that change how keys encode. Borrowed from the Screen.
    modes: ?*const Modes = null,

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
    }

    pub fn attach(self: *Keyboard, wl_kbd: *c.struct_wl_keyboard) void {
        self.wl_kbd = wl_kbd;
        _ = c.wl_keyboard_add_listener(wl_kbd, &keyboard_listener, self);
    }

    pub fn deinit(self: *Keyboard) void {
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

    /// Encode one key press into terminal input bytes. Returns a slice of `buf`,
    /// or null if the key produces nothing.
    fn encode(self: *Keyboard, keycode: u32, buf: []u8) ?[]const u8 {
        const state = self.state orelse return null;
        const sym = c.xkb_state_key_get_one_sym(state, keycode);

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
    const bytes = self.encode(keycode, &buf) orelse return;
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
