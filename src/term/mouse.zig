//! Mouse reporting to the application: DECSET 9/1000/1002/1003 for *what* is
//! reported, DECSET 1006 for *how* it is encoded.
//!
//! Encoding only. Whether a given click belongs to the application or to local
//! selection is policy that depends on the modifier state and the scrollback
//! position, so it lives with the application (see `App.mouseGoesToApp`).
//!
//! Two encodings are implemented. The legacy one (`\x1b[M` plus three bytes biased
//! by 32) cannot express a coordinate past 223 and cannot say *which* button was
//! released — both are inherent to packing everything into single bytes. SGR (1006)
//! fixes both, and every application that cares negotiates it. The other proposals
//! are deliberately absent: 1005 (UTF-8) is ambiguous by construction, since a
//! coordinate byte in the 0x80..0xff range is indistinguishable from the lead byte
//! of a multi-byte sequence, and 1015 (urxvt) was a dead end that 1006 replaced.

const std = @import("std");

/// What the terminal has been asked to report. These come from four independent
/// mode bits; `Modes.mode` below resolves them to one effective behaviour.
pub const Mode = enum {
    off,
    /// DECSET 9. Presses only, no modifiers, no releases.
    x10,
    /// DECSET 1000. Presses and releases.
    button,
    /// DECSET 1002. Adds motion, but only while a button is held.
    drag,
    /// DECSET 1003. Adds motion with nothing held.
    any,
};

pub const Encoding = enum { normal, sgr };

pub const Mods = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const Button = enum(u8) {
    left = 0,
    middle = 1,
    right = 2,
    /// Nothing held. Shares its wire value with "some button came up" in the legacy
    /// encoding — which is precisely why that encoding cannot report which one.
    none = 3,
    wheel_up = 64,
    wheel_down = 65,
    wheel_left = 66,
    wheel_right = 67,
    /// Buttons 8 and 9 on the wire, encoded as 128 + n.
    back = 128,
    forward = 129,

    pub fn isWheel(self: Button) bool {
        return switch (self) {
            .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
            else => false,
        };
    }
};

pub const Kind = enum { press, release, motion };

pub const Event = struct {
    button: Button,
    kind: Kind,
    /// Both 0-based and relative to the visible screen, not to the scrollback ring:
    /// the application's coordinate space is what it last drew.
    col: u32,
    row: u32,
    mods: Mods = .{},
};

/// Longest report an encoding can produce, for the caller's stack buffer.
pub const max_len = 32;

/// Encode one event, or return null when this mode does not report it.
///
/// Filtering lives here rather than in the caller so that "does mode 1002 report
/// motion with nothing held?" has exactly one answer in the codebase.
pub fn encode(buf: []u8, mode: Mode, enc: Encoding, ev: Event) ?[]const u8 {
    if (!reports(mode, ev)) return null;

    var cb: u32 = @intFromEnum(ev.button);
    // The legacy encoding has no room for a button on release.
    if (ev.kind == .release and enc == .normal) cb = @intFromEnum(Button.none);
    if (ev.kind == .motion) cb += 32;
    if (mode != .x10) {
        if (ev.mods.shift) cb += 4;
        if (ev.mods.alt) cb += 8;
        if (ev.mods.ctrl) cb += 16;
    }

    // The wire format is 1-based.
    const col = ev.col + 1;
    const row = ev.row + 1;

    switch (enc) {
        .sgr => {
            const final: u8 = if (ev.kind == .release) 'm' else 'M';
            return std.fmt.bufPrint(
                buf,
                "\x1b[<{d};{d};{d}{c}",
                .{ cb, col, row, final },
            ) catch null;
        },
        .normal => {
            if (buf.len < 6) return null;
            // Each field is one byte biased by 32, so nothing past 223 fits. Clamp
            // rather than drop the event: a click at the far right of a wide window
            // still lands somewhere plausible, whereas dropping it looks like the
            // mouse is broken. Anything that needs the real coordinate asks for SGR.
            buf[0] = 0x1b;
            buf[1] = '[';
            buf[2] = 'M';
            buf[3] = @intCast(32 + @min(cb, 223));
            buf[4] = @intCast(32 + @min(col, 223));
            buf[5] = @intCast(32 + @min(row, 223));
            return buf[0..6];
        },
    }
}

fn reports(mode: Mode, ev: Event) bool {
    // A wheel notch has no release; if one ever reached here it would decode as a
    // spurious button-up.
    if (ev.button.isWheel() and ev.kind == .release) return false;

    return switch (mode) {
        .off => false,
        .x10 => ev.kind == .press,
        .button => ev.kind != .motion,
        .drag => ev.kind != .motion or ev.button != .none,
        .any => true,
    };
}

/// The four tracking modes and the encoding, held as the independent bits they
/// really are.
///
/// Applications do enable more than one — 1002 and 1003 together is common, and
/// tmux resets them one at a time on exit. Collapsing them into a single enum makes
/// `DECRST 1002` switch off tracking that 1003 still wants, which shows up as a
/// mouse that stops working after leaving a nested application.
pub const Modes = struct {
    x10: bool = false,
    button: bool = false,
    drag: bool = false,
    any: bool = false,
    sgr: bool = false,

    /// The most capable mode currently enabled.
    pub fn mode(self: Modes) Mode {
        if (self.any) return .any;
        if (self.drag) return .drag;
        if (self.button) return .button;
        if (self.x10) return .x10;
        return .off;
    }

    pub fn encoding(self: Modes) Encoding {
        return if (self.sgr) .sgr else .normal;
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn report(buf: []u8, mode: Mode, e: Encoding, ev: Event) []const u8 {
    return encode(buf, mode, e, ev) orelse "";
}

test "legacy encoding biases every field by 32" {
    var buf: [max_len]u8 = undefined;
    // Column 0, row 0, left press: cb 0, coords 1 -> ' ', '!', '!'.
    try testing.expectEqualStrings("\x1b[M !!", report(&buf, .button, .normal, .{
        .button = .left,
        .kind = .press,
        .col = 0,
        .row = 0,
    }));
}

test "legacy encoding loses the button on release" {
    var buf: [max_len]u8 = undefined;
    const right = report(&buf, .button, .normal, .{
        .button = .right,
        .kind = .release,
        .col = 0,
        .row = 0,
    });
    var buf2: [max_len]u8 = undefined;
    const left = report(&buf2, .button, .normal, .{
        .button = .left,
        .kind = .release,
        .col = 0,
        .row = 0,
    });
    // Both collapse to button 3 — indistinguishable, which is the limitation SGR
    // exists to fix.
    try testing.expectEqualStrings(right, left);
    try testing.expectEqualStrings("\x1b[M#!!", left);
}

test "sgr keeps the button on release and marks it with a lowercase final" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("\x1b[<2;1;1m", report(&buf, .button, .sgr, .{
        .button = .right,
        .kind = .release,
        .col = 0,
        .row = 0,
    }));
    try testing.expectEqualStrings("\x1b[<2;1;1M", report(&buf, .button, .sgr, .{
        .button = .right,
        .kind = .press,
        .col = 0,
        .row = 0,
    }));
}

test "modifiers add 4/8/16" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("\x1b[<20;1;1M", report(&buf, .button, .sgr, .{
        .button = .left,
        .kind = .press,
        .col = 0,
        .row = 0,
        .mods = .{ .shift = true, .ctrl = true },
    }));
}

test "x10 reports presses only, without modifiers" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("\x1b[M !!", report(&buf, .x10, .normal, .{
        .button = .left,
        .kind = .press,
        .col = 0,
        .row = 0,
        .mods = .{ .ctrl = true, .shift = true },
    }));
    try testing.expect(encode(&buf, .x10, .normal, .{
        .button = .left,
        .kind = .release,
        .col = 0,
        .row = 0,
    }) == null);
}

test "motion is gated by the mode" {
    var buf: [max_len]u8 = undefined;
    const held = Event{ .button = .left, .kind = .motion, .col = 0, .row = 0 };
    const free = Event{ .button = .none, .kind = .motion, .col = 0, .row = 0 };

    // 1000: no motion at all.
    try testing.expect(encode(&buf, .button, .sgr, held) == null);
    // 1002: only while a button is held.
    try testing.expectEqualStrings("\x1b[<32;1;1M", report(&buf, .drag, .sgr, held));
    try testing.expect(encode(&buf, .drag, .sgr, free) == null);
    // 1003: everything, and bare motion reports button 3 + the motion bit.
    try testing.expectEqualStrings("\x1b[<35;1;1M", report(&buf, .any, .sgr, free));
}

test "wheel notches encode as buttons 64 and 65, and never as a release" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("\x1b[<64;1;1M", report(&buf, .button, .sgr, .{
        .button = .wheel_up,
        .kind = .press,
        .col = 0,
        .row = 0,
    }));
    try testing.expect(encode(&buf, .button, .sgr, .{
        .button = .wheel_down,
        .kind = .release,
        .col = 0,
        .row = 0,
    }) == null);
}

test "off reports nothing" {
    var buf: [max_len]u8 = undefined;
    try testing.expect(encode(&buf, .off, .sgr, .{
        .button = .left,
        .kind = .press,
        .col = 0,
        .row = 0,
    }) == null);
}

test "legacy coordinates clamp at 223, sgr does not" {
    var buf: [max_len]u8 = undefined;
    const far = Event{ .button = .left, .kind = .press, .col = 400, .row = 300 };
    const legacy = report(&buf, .button, .normal, far);
    try testing.expectEqual(@as(u8, 32 + 223), legacy[4]);
    try testing.expectEqual(@as(u8, 32 + 223), legacy[5]);

    var buf2: [max_len]u8 = undefined;
    try testing.expectEqualStrings("\x1b[<0;401;301M", report(&buf2, .button, .sgr, far));
}

test "the most capable enabled mode wins, and bits are independent" {
    var m = Modes{};
    try testing.expectEqual(Mode.off, m.mode());

    m.button = true;
    try testing.expectEqual(Mode.button, m.mode());
    m.any = true;
    try testing.expectEqual(Mode.any, m.mode());

    // Resetting 1002 (never set here) or 1000 must not disturb 1003.
    m.drag = false;
    m.button = false;
    try testing.expectEqual(Mode.any, m.mode());

    m.any = false;
    try testing.expectEqual(Mode.off, m.mode());
}

test "encoding follows 1006" {
    var m = Modes{};
    try testing.expectEqual(Encoding.normal, m.encoding());
    m.sgr = true;
    try testing.expectEqual(Encoding.sgr, m.encoding());
}
