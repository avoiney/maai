//! Tab bar layout: which column holds which character, in which colours.
//!
//! Kept apart from both the renderer and the event loop, and free of C, for one
//! reason: it is the only chrome with non-trivial *rules* — numbering, truncation,
//! ellipsis placement, a separator that wears two tabs' colours — and rules want
//! tests. Living in `main.zig` it could only be exercised by starting a compositor
//! and looking at the window, which is how the truncation bug below survived.
//!
//! Output is a flat list of columns rather than a list of tabs, so the renderer draws
//! the bar like any other row of cells and owns none of the decisions.

const std = @import("std");
const Rgb = @import("../term/cell.zig").Rgb;
const Theme = @import("../term/theme.zig").Theme;

/// One column of the bar.
pub const Cell = struct {
    cp: u21 = ' ',
    /// Explicit rather than a flag the renderer maps to colours. Powerline needs a
    /// separator whose foreground is the tab it leaves and whose background is the one
    /// it enters — two different tabs' colours in one cell, which no flag can express.
    fg: Rgb,
    bg: Rgb,
};

/// What the layout needs to know about a tab. A title only, for now.
pub const Tab = struct { title: []const u8 };

pub const Style = struct {
    powerline: bool = true,
    /// Separator glyph, drawn between tabs when `powerline` is set.
    separator: u21 = 0xE0B0,
};

/// Columns a title may occupy before it is cut short.
///
/// Titles are not length-bounded in practice: a shell that announces its directory
/// passes sixty characters as soon as that directory is a git worktree
/// (`/work/.claude-worktrees/some-long-branch-name`), and an agent that announces what
/// it is doing passes it immediately. So a label has to be *truncated* — never
/// *dropped*, which is what the previous `bufPrint` into a 64-byte buffer did on
/// overflow: `catch continue` skipped the whole tab, leaving an empty strip that reads
/// as the tab bar having disappeared.
pub const max_title_cols: usize = 24;

/// Floor on a title's share when the bar is split between many tabs, so the far tabs
/// keep a readable label instead of the near ones eating the width.
pub const min_title_cols: usize = 6;

/// Overhead of the fixed parts of a label: `" 12: "` plus the separator.
const overhead: usize = 6;

/// Lay the bar into `out`, returning the columns actually written.
///
/// `cols` is the window width in columns; the strip always runs the full width, so the
/// bar reads as a bar and not as a label floating on the terminal background.
pub fn layout(
    out: []Cell,
    cols: usize,
    tabs: []const Tab,
    active: usize,
    theme: *const Theme,
    style: Style,
) []const Cell {
    var n: usize = 0;
    const room = @min(cols, out.len);

    // Share of the bar each tab may claim for its title. Without it, one tab with a
    // long title pushes every later tab past the right edge — including the active one,
    // which is the tab you most need to see.
    const share = if (tabs.len > 0) room / tabs.len else room;
    const title_cols = std.math.clamp(share -| overhead, min_title_cols, max_title_cols);

    for (tabs, 0..) |t, i| {
        const is_active = i == active;
        const fg = if (is_active) theme.bar_active_fg else theme.bar_inactive_fg;
        const bg = if (is_active) theme.bar_active_bg else theme.bar_inactive_bg;

        // The number first, and unconditionally: whatever becomes of the title, every
        // tab keeps the handle its `alt+<n>` binding refers to.
        var num: [8]u8 = undefined;
        const number = std.fmt.bufPrint(&num, " {d}", .{i + 1}) catch " ?";
        for (number) |ch| {
            if (n == room) break;
            out[n] = .{ .cp = ch, .fg = fg, .bg = bg };
            n += 1;
        }

        const title = t.title;
        if (title.len > 0 and n + 2 <= room) {
            out[n] = .{ .cp = ':', .fg = fg, .bg = bg };
            out[n + 1] = .{ .cp = ' ', .fg = fg, .bg = bg };
            n += 2;

            // Counted before it is written, because truncation needs to know both
            // whether the title fits and — for a path — how much of the head to drop.
            var total: usize = 0;
            var j: usize = 0;
            while (j < title.len) {
                _ = nextCodepoint(title, &j);
                total += 1;
            }

            // A path carries its meaning at the *end*: `/work/.claude-worktrees/foo`
            // cut from the right leaves every worktree tab reading `/work/.claude-…`,
            // which distinguishes nothing. Anything else — a command line, a page
            // title — carries it at the start and keeps the usual trailing ellipsis.
            const keep_tail = total > title_cols and (title[0] == '/' or title[0] == '~');
            const skip = if (keep_tail) total - (title_cols - 1) else 0;

            if (keep_tail and n < room) {
                out[n] = .{ .cp = '…', .fg = fg, .bg = bg };
                n += 1;
            }

            var b: usize = 0;
            var seen: usize = 0;
            var written: usize = if (keep_tail) 1 else 0;
            while (b < title.len and n < room) {
                const cp = nextCodepoint(title, &b);
                seen += 1;
                if (seen <= skip) continue;
                if (written == title_cols) {
                    // Ellipsis in place of the last column kept, so a cut title
                    // announces itself instead of passing for a shorter one.
                    out[n - 1] = .{ .cp = '…', .fg = fg, .bg = bg };
                    break;
                }
                out[n] = .{ .cp = cp, .fg = fg, .bg = bg };
                n += 1;
                written += 1;
            }
        }

        if (n < room) {
            out[n] = .{ .cp = ' ', .fg = fg, .bg = bg };
            n += 1;
        }
        if (n == room) break;

        if (style.powerline) {
            // The separator wears the colour of the tab it leaves, on the background of
            // whatever comes next. That is the whole trick: the glyph reads as the edge
            // of the previous tab rather than as a character of its own.
            const next_bg = if (i + 1 < tabs.len)
                (if (i + 1 == active) theme.bar_active_bg else theme.bar_inactive_bg)
            else
                theme.bar_bg;
            out[n] = .{ .cp = style.separator, .fg = bg, .bg = next_bg };
            n += 1;
            if (n == room) break;
        }
    }

    while (n < room) : (n += 1) {
        out[n] = .{ .cp = ' ', .fg = theme.bar_inactive_fg, .bg = theme.bar_bg };
    }
    return out[0..n];
}

/// Decode one codepoint from `s` at `i`, advancing `i`, and never failing.
///
/// An invalid or truncated sequence yields U+FFFD and consumes one byte — the same
/// resynchronisation the VT parser does. This is not a hypothetical: `Screen` truncates
/// a title at 256 bytes without regard for sequence boundaries, so a half-encoded
/// character at the end is ordinary. Validating the whole label instead, as this code
/// used to, cost the tab its place in the bar over one byte.
fn nextCodepoint(s: []const u8, i: *usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(s[i.*]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > s.len) {
        i.* += 1;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(s[i.* .. i.* + len]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += len;
    return cp;
}

// ─── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The bar as text, which is what these tests are about. Colours are checked
/// separately, where they mean something.
fn render(buf: []u8, cols: usize, titles: []const []const u8, active: usize, style: Style) []const u8 {
    var tabs: [16]Tab = undefined;
    for (titles, 0..) |t, i| tabs[i] = .{ .title = t };

    var cells: [512]Cell = undefined;
    const theme = Theme.default;
    const bar = layout(&cells, cols, tabs[0..titles.len], active, &theme, style);

    var n: usize = 0;
    for (bar) |cell| n += std.unicode.utf8Encode(cell.cp, buf[n..]) catch unreachable;
    return buf[0..n];
}

const plain: Style = .{ .powerline = false };

test "a long title is truncated, not dropped" {
    // The regression: `/work/.claude-worktrees/<branch>` overflowed a 64-byte label
    // buffer once the number and separators were added, and the tab vanished from the
    // bar entirely — with nothing else to show, the bar looked switched off.
    var buf: [2048]u8 = undefined;
    const long = "/work/.claude-worktrees/revault-adr-backoffice-mcp-server";
    const got = render(&buf, 80, &.{long}, 0, plain);

    try testing.expect(std.mem.startsWith(u8, got, " 1: "));
    try testing.expect(std.mem.indexOf(u8, got, "mcp-server") != null);
}

test "a title far past any buffer still lays out" {
    var buf: [2048]u8 = undefined;
    const huge = "x" ** 300;
    const got = render(&buf, 80, &.{huge}, 0, plain);
    try testing.expect(std.mem.startsWith(u8, got, " 1: xxx"));
    try testing.expect(std.mem.indexOf(u8, got, "…") != null);
}

test "a path keeps its tail, a command keeps its head" {
    var buf: [2048]u8 = undefined;

    const path = render(&buf, 80, &.{"/work/.claude-worktrees/revault-adr-backoffice-mcp-server"}, 0, plain);
    try testing.expect(std.mem.indexOf(u8, path, ": …") != null);
    try testing.expect(std.mem.indexOf(u8, path, "mcp-server") != null);

    var buf2: [2048]u8 = undefined;
    const cmd = render(&buf2, 80, &.{"nvim src/term/screen.zig --very-long-flag"}, 0, plain);
    try testing.expect(std.mem.indexOf(u8, cmd, "nvim src/term") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, cmd, " "), "…"));
}

test "a title cut mid-sequence costs one character, not the tab" {
    var buf: [2048]u8 = undefined;
    // What a 256-byte truncation leaves behind: a lead byte with no continuation.
    const got = render(&buf, 80, &.{"abc\xC3"}, 0, plain);
    try testing.expect(std.mem.startsWith(u8, got, " 1: abc"));
    try testing.expect(std.mem.indexOf(u8, got, "\u{FFFD}") != null);
}

test "every tab is present when many share a narrow bar" {
    var buf: [2048]u8 = undefined;
    const titles: []const []const u8 = &.{
        "/work/.claude-worktrees/one",   "/work/.claude-worktrees/two",
        "/work/.claude-worktrees/three", "/work/.claude-worktrees/four",
    };
    const got = render(&buf, 80, titles, 3, plain);

    for ([_][]const u8{ " 1", " 2", " 3", " 4" }) |number| {
        try testing.expect(std.mem.indexOf(u8, got, number) != null);
    }
}

test "an untitled tab shows its number" {
    var buf: [2048]u8 = undefined;
    const got = render(&buf, 80, &.{""}, 0, plain);
    try testing.expectEqualStrings(" 1", std.mem.trimEnd(u8, got, " "));
}

test "the strip runs the full width" {
    var cells: [512]Cell = undefined;
    const theme = Theme.default;
    const bar = layout(&cells, 40, &.{.{ .title = "zsh" }}, 0, &theme, plain);
    try testing.expectEqual(@as(usize, 40), bar.len);
}

test "the active tab wears the active colours" {
    var cells: [512]Cell = undefined;
    const theme = Theme.default;
    const bar = layout(&cells, 40, &.{ .{ .title = "a" }, .{ .title = "b" } }, 1, &theme, plain);

    // ` 1: a ` then ` 2: b `: the second label is the active one.
    try testing.expectEqual(theme.bar_inactive_bg, bar[0].bg);
    try testing.expectEqual(theme.bar_active_bg, bar[6].bg);
}

test "the powerline separator carries both neighbours' colours" {
    var cells: [512]Cell = undefined;
    const theme = Theme.default;
    const style: Style = .{ .powerline = true, .separator = 0xE0B0 };
    const bar = layout(&cells, 40, &.{ .{ .title = "a" }, .{ .title = "b" } }, 0, &theme, style);

    const sep = bar[6];
    try testing.expectEqual(@as(u21, 0xE0B0), sep.cp);
    try testing.expectEqual(theme.bar_active_bg, sep.fg); // the tab it leaves
    try testing.expectEqual(theme.bar_inactive_bg, sep.bg); // the one it enters
}

test "a bar narrower than one label does not overrun" {
    var buf: [2048]u8 = undefined;
    const got = render(&buf, 4, &.{"/work/.claude-worktrees/revault"}, 0, plain);
    try testing.expectEqual(@as(usize, 4), std.unicode.utf8CountCodepoints(got) catch unreachable);
}
