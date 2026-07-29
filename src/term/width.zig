//! Character width, from the Unicode tables via utf8proc.
//!
//! Getting this to agree with what applications think is the whole point. An
//! application lays out its own frames and tables using its language's width
//! function; if the terminal disagrees by even one column, every box border in its
//! UI lands in the wrong place. So the rule here is "match what the ecosystem
//! does", not "follow the spec most literally".
//!
//! libc `wcwidth()` is deliberately avoided: it consults the process locale, which
//! would make layout depend on how the terminal happened to be launched.

const std = @import("std");

/// Deliberately its own `@cImport` rather than going through `c.zig`, which is
/// otherwise the single point of contact with C.
///
/// That rule exists to stop one C struct being translated into two incompatible
/// Zig types. utf8proc's surface here is a single function over integers, so no
/// types cross the boundary and the hazard does not apply. Keeping it separate is
/// what lets `zig build test-pure` link only utf8proc instead of also needing
/// Wayland, EGL, fcft and the generated protocol headers.
const c = @cImport({
    @cInclude("utf8proc.h");
});

/// U+FE0F VARIATION SELECTOR-16 requests emoji presentation for the preceding
/// character.
pub const vs16: u21 = 0xFE0F;
/// U+FE0E VARIATION SELECTOR-15 requests text presentation.
pub const vs15: u21 = 0xFE0E;

/// Columns a codepoint occupies: 0 (combining or zero-width), 1, or 2.
pub fn charWidth(cp: u21) u8 {
    const w = c.utf8proc_charwidth(@intCast(cp));
    if (w <= 0) return 0;
    if (w >= 2) return 2;
    return 1;
}

/// Whether appending `cp` to a character of width `base_width` should widen it to
/// two columns.
///
/// Bare `⚠` (U+26A0) is one column, but `⚠️` (with VS16) is treated as two by
/// Node's `string-width`, Python's `wcwidth` emoji handling, and Go's
/// `go-runewidth` — which is to say by the layout code of nearly every TUI a user
/// will run. Terminals that keep it at one column misalign those UIs.
pub fn widensToEmoji(cp: u21, base_width: u8) bool {
    return cp == vs16 and base_width == 1;
}

test "widths match what TUI layout code expects" {
    // Box drawing stays single-width, or every frame breaks.
    try std.testing.expectEqual(@as(u8, 1), charWidth('─'));
    try std.testing.expectEqual(@as(u8, 1), charWidth('╭'));
    try std.testing.expectEqual(@as(u8, 1), charWidth('│'));

    // CJK and most emoji are double-width.
    try std.testing.expectEqual(@as(u8, 2), charWidth('日'));
    try std.testing.expectEqual(@as(u8, 2), charWidth(0x1f527)); // 🔧
    try std.testing.expectEqual(@as(u8, 2), charWidth(0x2705)); // ✅

    // Combining marks and variation selectors take no space of their own.
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x0301)); // ́
    try std.testing.expectEqual(@as(u8, 0), charWidth(vs16));

    // Nerd Font glyphs live in the private use area and are single-width, which
    // is also what application width functions report for them.
    try std.testing.expectEqual(@as(u8, 1), charWidth(0xe0b0));

    // The emoji-presentation promotion.
    try std.testing.expectEqual(@as(u8, 1), charWidth(0x26a0)); // ⚠ alone
    try std.testing.expect(widensToEmoji(vs16, 1));
    try std.testing.expect(!widensToEmoji(vs16, 2));
    try std.testing.expect(!widensToEmoji(0x0301, 1));
}
