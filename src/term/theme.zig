//! Colours, resolved at draw time rather than at parse time.
//!
//! The important decision here: a `Style` stores what the application *asked for* —
//! "colour 4", "default foreground", "#a1b2c3" — never the pixels. Resolution happens
//! against a `Theme` when a cell is drawn.
//!
//! That indirection is the whole reason live theme reload works on text already on
//! screen. Resolving at parse time would bake yesterday's palette into every cell in
//! the scrollback, and a theme switch would only affect text printed afterwards —
//! which reads as a bug even though every individual step looked correct.
//!
//! It is also what makes OSC 4/10/11 behave: an application that redefines colour 4
//! expects everything already drawn in colour 4 to change.

const std = @import("std");
const Rgb = @import("cell.zig").Rgb;

/// Which default a `.default` colour slot means. The slot's role is known from where
/// it sits in the `Style`, so one tag covers all three.
pub const Role = enum { fg, bg, ul };

pub const Theme = struct {
    fg: Rgb = default_fg,
    bg: Rgb = default_bg,
    cursor: Rgb = default_cursor,
    /// Text drawn *under* the cursor block.
    cursor_text: Rgb = default_bg,
    selection_bg: Rgb = default_selection_bg,
    selection_fg: Rgb = default_selection_fg,
    /// Hint-mode labels. Deliberately loud: they cover real text, so they have to
    /// read as an overlay rather than as content.
    hint_bg: Rgb = default_hint_bg,
    hint_fg: Rgb = default_bg,

    /// Tab bar. Four colours plus the strip behind them, which is kitty's model —
    /// the machine's themes are written for kitty, so reusing its vocabulary means the
    /// existing files describe the bar without being edited.
    bar_bg: Rgb = default_bar_bg,
    bar_inactive_bg: Rgb = default_bar_inactive_bg,
    bar_inactive_fg: Rgb = default_bar_inactive_fg,
    bar_active_bg: Rgb = default_bar_active_bg,
    bar_active_fg: Rgb = default_bar_active_fg,

    /// The 256-colour palette. 0-15 come from the theme; 16-255 are the fixed xterm
    /// cube and greyscale ramp, which no theme redefines but OSC 4 may.
    palette: [256]Rgb = default_palette,

    pub const default: Theme = .{};

    pub fn resolve(self: *const Theme, color: Color, role: Role) Rgb {
        return switch (color.kind) {
            .rgb => Rgb.rgb(color.r, color.g, color.b),
            .indexed => self.palette[color.r],
            .default => switch (role) {
                .fg, .ul => self.fg,
                .bg => self.bg,
            },
        };
    }
};

/// A colour slot in a style: a request, not a result.
pub const Color = packed struct(u32) {
    /// The palette index when `kind == .indexed`, otherwise the red channel.
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    kind: Kind = .default,

    pub const Kind = enum(u8) { default, indexed, rgb };

    pub const default: Color = .{};

    pub fn indexed(i: u8) Color {
        return .{ .r = i, .kind = .indexed };
    }

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .kind = .rgb };
    }

    pub fn eql(a: Color, b: Color) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

// ── defaults ────────────────────────────────────────────────────────────────
// nightfox, matching ~/.config/kitty/themes/nightfox.conf exactly — the machine
// already has a theme switcher writing those files, and myterm reading the same
// values means it looks right before any config exists.

pub const default_fg = Rgb.rgb(0xcd, 0xce, 0xcf);
pub const default_bg = Rgb.rgb(0x19, 0x23, 0x30);
pub const default_cursor = Rgb.rgb(0xcd, 0xce, 0xcf);
pub const default_selection_bg = Rgb.rgb(0x2b, 0x3b, 0x51);
pub const default_selection_fg = Rgb.rgb(0xcd, 0xce, 0xcf);
pub const default_hint_bg = Rgb.rgb(0xdb, 0xc0, 0x74);
// Straight from ~/.config/kitty/themes/nightfox.conf, key for key.
pub const default_bar_bg = Rgb.rgb(0x19, 0x23, 0x30);
pub const default_bar_inactive_bg = Rgb.rgb(0x2b, 0x3b, 0x51);
pub const default_bar_inactive_fg = Rgb.rgb(0x73, 0x80, 0x91);
pub const default_bar_active_bg = Rgb.rgb(0x71, 0x9c, 0xd6);
pub const default_bar_active_fg = Rgb.rgb(0x13, 0x1a, 0x24);

pub const default_ansi16 = [16]Rgb{
    Rgb.rgb(0x39, 0x3b, 0x44), // 0 black
    Rgb.rgb(0xc9, 0x4f, 0x6d), // 1 red
    Rgb.rgb(0x81, 0xb2, 0x9a), // 2 green
    Rgb.rgb(0xdb, 0xc0, 0x74), // 3 yellow
    Rgb.rgb(0x71, 0x9c, 0xd6), // 4 blue
    Rgb.rgb(0x9d, 0x79, 0xd6), // 5 magenta
    Rgb.rgb(0x63, 0xcd, 0xcf), // 6 cyan
    Rgb.rgb(0xdf, 0xdf, 0xe0), // 7 white
    Rgb.rgb(0x57, 0x58, 0x60), // 8  bright black
    Rgb.rgb(0xd1, 0x69, 0x83), // 9  bright red
    Rgb.rgb(0x8e, 0xba, 0xa4), // 10 bright green
    Rgb.rgb(0xe0, 0xc9, 0x89), // 11 bright yellow
    Rgb.rgb(0x86, 0xab, 0xdc), // 12 bright blue
    Rgb.rgb(0xba, 0xa1, 0xe2), // 13 bright magenta
    Rgb.rgb(0x7a, 0xd5, 0xd6), // 14 bright cyan
    Rgb.rgb(0xe4, 0xe4, 0xe5), // 15 bright white
};

/// The xterm 256-colour palette: 16 base colours, a 6x6x6 cube, then 24 greys.
pub const default_palette: [256]Rgb = blk: {
    var p: [256]Rgb = undefined;
    for (default_ansi16, 0..) |col, i| p[i] = col;

    const steps = [6]u8{ 0, 95, 135, 175, 215, 255 };
    var i: usize = 16;
    for (steps) |r| {
        for (steps) |g| {
            for (steps) |b| {
                p[i] = Rgb.rgb(r, g, b);
                i += 1;
            }
        }
    }

    var grey: u8 = 8;
    while (i < 256) : (i += 1) {
        p[i] = Rgb.rgb(grey, grey, grey);
        grey += 10;
    }
    break :blk p;
};

/// Parse a colour the way OSC 4/10/11 and X resources write them.
///
/// Accepted: `#rgb`, `#rrggbb`, `#rrrgggbbb`, `#rrrrggggbbbb`, and XParseColor's
/// `rgb:r/g/b` with 1-4 hex digits per channel. Each channel is scaled to 8 bits by
/// its width, so `#fff` is white rather than a very dark grey.
///
/// X11 colour *names* are deliberately not supported: it would mean shipping rgb.txt
/// or a 750-entry table to serve a syntax nothing has emitted in decades.
pub fn parseColor(spec: []const u8) ?Rgb {
    if (spec.len == 0) return null;

    if (spec[0] == '#') {
        const hex = spec[1..];
        if (hex.len % 3 != 0 or hex.len == 0 or hex.len > 12) return null;
        const w = hex.len / 3;
        return Rgb.rgb(
            scaleChannel(hex[0..w]) orelse return null,
            scaleChannel(hex[w .. 2 * w]) orelse return null,
            scaleChannel(hex[2 * w ..]) orelse return null,
        );
    }

    if (std.ascii.startsWithIgnoreCase(spec, "rgb:")) {
        var it = std.mem.splitScalar(u8, spec[4..], '/');
        const r = it.next() orelse return null;
        const g = it.next() orelse return null;
        const b = it.next() orelse return null;
        if (it.next() != null) return null;
        return Rgb.rgb(
            scaleChannel(r) orelse return null,
            scaleChannel(g) orelse return null,
            scaleChannel(b) orelse return null,
        );
    }

    return null;
}

/// One channel of 1-4 hex digits, widened to 8 bits.
fn scaleChannel(digits: []const u8) ?u8 {
    if (digits.len == 0 or digits.len > 4) return null;
    const v = std.fmt.parseUnsigned(u16, digits, 16) catch return null;
    // Scale by the field width rather than truncating: `f` means full intensity in a
    // one-digit field, so it has to become 0xff and not 0x0f.
    const max: u32 = (@as(u32, 1) << @intCast(4 * digits.len)) - 1;
    return @intCast(@as(u32, v) * 255 / max);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "colour specs parse in every width" {
    try testing.expect(parseColor("#192330").?.eq(Rgb.rgb(0x19, 0x23, 0x30)));
    // One digit per channel is full-scale, not the low nibble.
    try testing.expect(parseColor("#fff").?.eq(Rgb.rgb(255, 255, 255)));
    try testing.expect(parseColor("#f00").?.eq(Rgb.rgb(255, 0, 0)));
    try testing.expect(parseColor("#000000000000").?.eq(Rgb.rgb(0, 0, 0)));
    try testing.expect(parseColor("#ffffffffffff").?.eq(Rgb.rgb(255, 255, 255)));

    try testing.expect(parseColor("rgb:19/23/30").?.eq(Rgb.rgb(0x19, 0x23, 0x30)));
    try testing.expect(parseColor("rgb:f/f/f").?.eq(Rgb.rgb(255, 255, 255)));
    try testing.expect(parseColor("RGB:ffff/0000/0000").?.eq(Rgb.rgb(255, 0, 0)));

    // Malformed input yields nothing rather than a guess: a half-parsed colour is
    // worse than an ignored directive.
    try testing.expect(parseColor("") == null);
    try testing.expect(parseColor("#") == null);
    try testing.expect(parseColor("#1234") == null); // not a multiple of 3
    try testing.expect(parseColor("#zzz") == null);
    try testing.expect(parseColor("rgb:1/2") == null);
    try testing.expect(parseColor("rgb:1/2/3/4") == null);
    try testing.expect(parseColor("red") == null); // names unsupported by design
}

test "palette cube and greyscale land on known xterm values" {
    // 16 is the first cube entry (pure black), 231 the last (pure white).
    try testing.expect(default_palette[16].eq(Rgb.rgb(0, 0, 0)));
    try testing.expect(default_palette[231].eq(Rgb.rgb(255, 255, 255)));
    try testing.expect(default_palette[232].eq(Rgb.rgb(8, 8, 8)));
    try testing.expect(default_palette[255].eq(Rgb.rgb(238, 238, 238)));
}

test "a colour slot stores the request, not the result" {
    var theme = Theme.default;

    const four = Color.indexed(4);
    try testing.expect(theme.resolve(four, .fg).eq(default_ansi16[4]));

    // Redefining colour 4 — what OSC 4 or a theme reload does — changes what every
    // cell holding that slot resolves to, including cells drawn long ago.
    theme.palette[4] = Rgb.rgb(1, 2, 3);
    try testing.expect(theme.resolve(four, .fg).eq(Rgb.rgb(1, 2, 3)));

    // A direct colour is immune to that, which is also correct: the application
    // asked for those exact pixels.
    const exact = Color.rgb(10, 20, 30);
    try testing.expect(theme.resolve(exact, .fg).eq(Rgb.rgb(10, 20, 30)));
}

test "the default slot follows its role" {
    var theme = Theme.default;
    theme.fg = Rgb.rgb(1, 1, 1);
    theme.bg = Rgb.rgb(2, 2, 2);

    try testing.expect(theme.resolve(Color.default, .fg).eq(Rgb.rgb(1, 1, 1)));
    try testing.expect(theme.resolve(Color.default, .bg).eq(Rgb.rgb(2, 2, 2)));
    // Underline colour defaults to the foreground, not to a colour of its own.
    try testing.expect(theme.resolve(Color.default, .ul).eq(Rgb.rgb(1, 1, 1)));
}

test "Color fits in 32 bits and compares by value" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(Color));
    try testing.expect(Color.indexed(3).eql(Color.indexed(3)));
    try testing.expect(!Color.indexed(3).eql(Color.rgb(3, 0, 0)));
    // An indexed 0 and the default slot must not collide: "colour 0" is black,
    // "default" is whatever the theme says.
    try testing.expect(!Color.indexed(0).eql(Color.default));
}
