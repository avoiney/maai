//! Finding URLs in grid text.
//!
//! Detection is deliberately conservative: a match must begin with one of the
//! schemes in `schemes`, and that list is the same one the launcher enforces
//! (PLAN.md §7). Anything the scanner cannot name a scheme for is not a link, so
//! there is no path from "some text on screen" to "a process argument" that skips
//! the allowlist.
//!
//! Everything here works in grid coordinates rather than on an extracted string.
//! A logical line can be thousands of rows long after wrapping, and building its
//! text on every pointer motion — which is when hover detection runs — would mean
//! allocating on a path that fires at device rate.

const std = @import("std");
const cellmod = @import("cell.zig");
const gridmod = @import("grid.zig");
const sel = @import("selection.zig");
const Cell = cellmod.Cell;
const Grid = gridmod.Grid;

pub const Point = sel.Point;

/// Schemes we are willing to recognise, longest-prefix-first so `https://` is
/// tested before `http://` would need to be.
///
/// This list is a security boundary. Adding to it means adding a way for text
/// printed by a remote process to become an argument to a program, so each entry
/// should be one whose handler is safe to hand a hostile URL.
pub const schemes = [_][]const u8{
    "https://",
    "http://",
    "ftps://",
    "ftp://",
    "file://",
    "mailto:",
    "ssh://",
    "git://",
};

/// Longest run of non-blank cells we will scan through. A "URL" longer than this
/// is not something to hand to a browser, and scanning is bounded so that a line
/// of megabytes of unbroken punctuation cannot turn pointer motion into a stall.
/// Runs that exceed it yield no match rather than a truncated one, since a
/// truncated URL is a *different* URL.
pub const max_run_cells: usize = 2048;

/// Trailing characters that are punctuation around a URL far more often than part
/// of one. `>` is here because it cannot appear in a URL unencoded, so `<url>`
/// closes cleanly.
const trailing_punctuation = ".,;:!?'\"*_>";

pub const Span = struct {
    start: Point,
    /// Inclusive.
    end: Point,

    pub fn contains(self: Span, line: usize, x: u32) bool {
        if (line < self.start.line or line > self.end.line) return false;
        if (line == self.start.line and x < self.start.x) return false;
        if (line == self.end.line and x > self.end.x) return false;
        return true;
    }

    pub fn eql(a: Span, b: Span) bool {
        return a.start.line == b.start.line and a.start.x == b.start.x and
            a.end.line == b.end.line and a.end.x == b.end.x;
    }
};

/// The URL under `at`, if any.
pub fn find(grid: *const Grid, at: Point) ?Span {
    if (at.line >= grid.count or at.x >= grid.cols) return null;
    if (!isBody(charAt(grid, at))) return null;

    // Walk left to the start of the unbroken run, bounded.
    var run_start = at;
    var steps: usize = 0;
    while (prev(grid, run_start)) |p| {
        if (!isBody(charAt(grid, p))) break;
        steps += 1;
        if (steps > max_run_cells) return null;
        run_start = p;
    }

    // The leftmost scheme in the run wins. That is what makes
    // `https://host/path/https://elsewhere` one URL with a colon in its path
    // rather than two, and it also means a prefix like `foo,` or `"` in front of
    // the scheme is simply skipped.
    var start: ?Point = null;
    var p = run_start;
    while (true) {
        if (schemeAt(grid, p) != null and !precededByAlnum(grid, p)) {
            start = p;
            break;
        }
        if (p.line == at.line and p.x == at.x) break;
        p = next(grid, p) orelse break;
    }
    const from = start orelse return null;

    // Walk right to the end of the run.
    var end = from;
    steps = 0;
    while (next(grid, end)) |q| {
        if (!isBody(charAt(grid, q))) break;
        steps += 1;
        if (steps > max_run_cells) return null;
        end = q;
    }

    end = trimEnd(grid, from, end);

    // `at` may have been inside the punctuation we just trimmed, in which case the
    // click was not on the link.
    const span = Span{ .start = from, .end = end };
    if (!span.contains(at.line, at.x)) return null;
    return span;
}

/// Extract a span as UTF-8. Caller owns the result.
pub fn text(
    gpa: std.mem.Allocator,
    grid: *const Grid,
    graphemes: *const cellmod.GraphemeTable,
    span: Span,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var p = span.start;
    while (true) {
        const cell = cellAt(grid, p);
        if (cell.wide != 2) {
            if (cell.grapheme) {
                for (graphemes.get(cell.content)) |cp| try appendCp(&out, gpa, cp);
            } else if (cell.content != Cell.empty) {
                try appendCp(&out, gpa, @intCast(cell.content));
            }
        }
        if (p.line == span.end.line and p.x == span.end.x) break;
        p = next(grid, p) orelse break;
    }

    return out.toOwnedSlice(gpa);
}

/// Does this text start with a scheme we are willing to launch?
///
/// `find` guarantees this for its own matches, but OSC 8 hyperlinks carry a URI
/// chosen entirely by the writing process, so the launcher checks again rather
/// than trusting where the string came from.
pub fn allowedScheme(s: []const u8) bool {
    for (schemes) |scheme| {
        if (s.len < scheme.len) continue;
        if (std.ascii.eqlIgnoreCase(s[0..scheme.len], scheme)) return true;
    }
    return false;
}

// ── walking ─────────────────────────────────────────────────────────────────
// A "logical line" follows soft wraps, so a URL broken across the right edge of
// the window is still one URL.

fn cellAt(grid: *const Grid, p: Point) Cell {
    if (p.line >= grid.count or p.x >= grid.cols) return .{};
    return grid.line(p.line).cells[p.x];
}

/// The character at `p` for scanning purposes. A trailing spacer reports the
/// codepoint of nothing in particular but must not break a run, so it comes back
/// as a body character; a grapheme cluster likewise, since it cannot be part of a
/// scheme but can be part of a path.
fn charAt(grid: *const Grid, p: Point) u21 {
    const cell = cellAt(grid, p);
    if (cell.wide == 2 or cell.grapheme) return 0xfffd;
    if (cell.content == Cell.empty) return ' ';
    return @intCast(cell.content);
}

fn prev(grid: *const Grid, p: Point) ?Point {
    if (p.x > 0) return .{ .line = p.line, .x = p.x - 1 };
    if (p.line == 0) return null;
    // Only a soft wrap continues a line; a hard break ends the URL.
    if (!grid.line(p.line - 1).wrapped) return null;
    return .{ .line = p.line - 1, .x = grid.cols - 1 };
}

fn next(grid: *const Grid, p: Point) ?Point {
    if (p.x + 1 < grid.cols) return .{ .line = p.line, .x = p.x + 1 };
    if (p.line + 1 >= grid.count) return null;
    if (!grid.line(p.line).wrapped) return null;
    return .{ .line = p.line + 1, .x = 0 };
}

/// Anything printable. Brackets and quotes are included on purpose: they occur
/// inside real URLs, and the ones that merely surround a URL are dealt with by
/// scheme detection at the front and `trimEnd` at the back.
fn isBody(cp: u21) bool {
    return cp > 0x20 and cp != 0x7f;
}

fn schemeAt(grid: *const Grid, p: Point) ?usize {
    for (schemes) |scheme| {
        var q = p;
        var i: usize = 0;
        while (i < scheme.len) : (i += 1) {
            const cp = charAt(grid, q);
            if (cp > 0x7f) break;
            if (std.ascii.toLower(@intCast(cp)) != scheme[i]) break;
            if (i + 1 < scheme.len) q = next(grid, q) orelse break;
        }
        if (i == scheme.len) return scheme.len;
    }
    return null;
}

/// Reject `xhttps://y`: a scheme has to start a word, or every string ending in
/// something scheme-shaped becomes a link.
fn precededByAlnum(grid: *const Grid, p: Point) bool {
    const q = prev(grid, p) orelse return false;
    const cp = charAt(grid, q);
    if (cp > 0x7f) return false;
    return std.ascii.isAlphanumeric(@intCast(cp));
}

/// Drop trailing punctuation and unbalanced closing brackets.
///
/// Balance rather than a blanket rule, because both cases are common:
/// `https://en.wikipedia.org/wiki/Foo_(bar)` needs its closing paren, and
/// `(see https://example.com/)` must not steal one.
fn trimEnd(grid: *const Grid, start: Point, end: Point) Point {
    var open = [3]u32{ 0, 0, 0 };
    var close = [3]u32{ 0, 0, 0 };

    var p = start;
    while (true) {
        switch (charAt(grid, p)) {
            '(' => open[0] += 1,
            ')' => close[0] += 1,
            '[' => open[1] += 1,
            ']' => close[1] += 1,
            '{' => open[2] += 1,
            '}' => close[2] += 1,
            else => {},
        }
        if (p.line == end.line and p.x == end.x) break;
        p = next(grid, p) orelse break;
    }

    var cur = end;
    while (!(cur.line == start.line and cur.x == start.x)) {
        const cp = charAt(grid, cur);
        const kind: ?usize = switch (cp) {
            ')' => 0,
            ']' => 1,
            '}' => 2,
            else => null,
        };
        if (kind) |k| {
            if (close[k] <= open[k]) break;
            close[k] -= 1;
        } else if (cp > 0x7f or
            std.mem.indexOfScalar(u8, trailing_punctuation, @intCast(cp)) == null)
        {
            break;
        }
        cur = prev(grid, cur) orelse break;
    }
    return cur;
}

fn appendCp(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try out.appendSlice(gpa, buf[0..n]);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn put(g: *Grid, line: usize, s: []const u8) void {
    const row = g.line(line);
    // Clear first: several tests reuse one grid, and a leftover tail from a longer
    // previous string would silently extend the run being matched.
    @memset(row.cells[0..g.cols], .{});
    var x: u32 = 0;
    var it = (std.unicode.Utf8View.init(s) catch unreachable).iterator();
    while (it.nextCodepoint()) |cp| {
        if (x >= g.cols) break;
        row.cells[x] = .{ .content = cp };
        x += 1;
    }
}

/// Find at a column and return the matched text, or "" for no match.
fn matchText(g: *Grid, line: usize, x: u32) ![]u8 {
    const span = find(g, .{ .line = line, .x = x }) orelse
        return testing.allocator.dupe(u8, "");
    const empty_table = cellmod.GraphemeTable{};
    return text(testing.allocator, g, &empty_table, span);
}

fn expectMatch(g: *Grid, x: u32, want: []const u8) !void {
    const got = try matchText(g, 0, x);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "a bare url is found from anywhere inside it" {
    var g = try Grid.init(testing.allocator, 40, 2, 4);
    defer g.deinit();
    put(&g, 0, "see https://example.com/x here");

    try expectMatch(&g, 4, "https://example.com/x"); // first char
    try expectMatch(&g, 12, "https://example.com/x"); // middle
    try expectMatch(&g, 24, "https://example.com/x"); // last char
    try expectMatch(&g, 3, ""); // the space before
    try expectMatch(&g, 26, ""); // the word after
}

test "surrounding punctuation is not part of the url" {
    var g = try Grid.init(testing.allocator, 60, 2, 4);
    defer g.deinit();

    put(&g, 0, "(see https://example.com/)");
    try expectMatch(&g, 10, "https://example.com/");

    put(&g, 0, "read https://example.com/x, then");
    try expectMatch(&g, 10, "https://example.com/x");

    put(&g, 0, "<https://example.com/>");
    try expectMatch(&g, 5, "https://example.com/");

    put(&g, 0, "quoted \"https://example.com/\" end");
    try expectMatch(&g, 12, "https://example.com/");

    put(&g, 0, "end of sentence: https://example.com.");
    try expectMatch(&g, 20, "https://example.com");
}

test "balanced brackets inside a url are kept" {
    var g = try Grid.init(testing.allocator, 60, 2, 4);
    defer g.deinit();
    put(&g, 0, "https://en.wikipedia.org/wiki/Fo_(bar) x");
    try expectMatch(&g, 10, "https://en.wikipedia.org/wiki/Fo_(bar)");
}

test "a url is joined across a soft wrap but not a hard break" {
    var g = try Grid.init(testing.allocator, 12, 4, 8);
    defer g.deinit();

    // The row has to be *full* for the wrap to be real — that is what soft wrap
    // means — so the first row is exactly `cols` wide.
    put(&g, 0, "https://exam");
    g.line(0).wrapped = true;
    put(&g, 1, "ple.com/abc");

    try expectMatch(&g, 3, "https://example.com/abc");

    // Without the wrap flag the same rows are two unrelated lines.
    g.line(0).wrapped = false;
    try expectMatch(&g, 3, "https://exam");
}

test "only allowlisted schemes match" {
    var g = try Grid.init(testing.allocator, 60, 2, 4);
    defer g.deinit();

    put(&g, 0, "mailto:someone@example.com");
    try expectMatch(&g, 3, "mailto:someone@example.com");

    put(&g, 0, "file:///etc/hostname");
    try expectMatch(&g, 3, "file:///etc/hostname");

    // Not on the list: no match, so nothing downstream can be asked to open it.
    put(&g, 0, "javascript:alert(1)");
    try expectMatch(&g, 3, "");
    put(&g, 0, "data:text/html,hello");
    try expectMatch(&g, 3, "");
    put(&g, 0, "vscode://file/etc/passwd");
    try expectMatch(&g, 3, "");
}

test "a scheme must start a word" {
    var g = try Grid.init(testing.allocator, 60, 2, 4);
    defer g.deinit();
    put(&g, 0, "xhttps://example.com");
    try expectMatch(&g, 5, "");

    // ...but non-alphanumeric neighbours are fine.
    put(&g, 0, "url=https://example.com");
    try expectMatch(&g, 10, "https://example.com");
    put(&g, 0, "foo,https://example.com");
    try expectMatch(&g, 10, "https://example.com");
}

test "the leftmost scheme wins, so a colon in a path does not split the url" {
    var g = try Grid.init(testing.allocator, 60, 2, 4);
    defer g.deinit();
    put(&g, 0, "https://host/r?u=https://other/");
    try expectMatch(&g, 25, "https://host/r?u=https://other/");
}

test "shell injection in a url stays inside the url" {
    // The launcher passes an argv array, so this can only ever be one argument.
    // The scanner's job is simply not to lose track of where it ends.
    var g = try Grid.init(testing.allocator, 60, 2, 4);
    defer g.deinit();
    put(&g, 0, "https://x/$(id>/tmp/pwn) rest");
    const got = try matchText(&g, 0, 10);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("https://x/$(id>/tmp/pwn)", got);
}

test "uppercase schemes are recognised" {
    var g = try Grid.init(testing.allocator, 60, 2, 4);
    defer g.deinit();
    put(&g, 0, "HTTPS://Example.COM/x");
    try expectMatch(&g, 3, "HTTPS://Example.COM/x");
}

test "no match on blank cells or outside the grid" {
    var g = try Grid.init(testing.allocator, 20, 2, 4);
    defer g.deinit();
    put(&g, 0, "   ");
    try testing.expect(find(&g, .{ .line = 0, .x = 1 }) == null);
    try testing.expect(find(&g, .{ .line = 0, .x = 19 }) == null);
    try testing.expect(find(&g, .{ .line = 99, .x = 0 }) == null);
}

test "allowedScheme mirrors the scanner's list" {
    try testing.expect(allowedScheme("https://x"));
    try testing.expect(allowedScheme("HTTPS://x"));
    try testing.expect(allowedScheme("mailto:a@b"));
    try testing.expect(!allowedScheme("javascript:x"));
    try testing.expect(!allowedScheme("http"));
    try testing.expect(!allowedScheme(""));
    // A leading dash would be an option to whatever we spawn; no scheme allows it.
    try testing.expect(!allowedScheme("--version"));
}

test "a wide character inside a url does not break the run" {
    var g = try Grid.init(testing.allocator, 40, 2, 4);
    defer g.deinit();
    const row = g.line(0);
    put(&g, 0, "https://x/");
    row.cells[10] = .{ .content = '日', .wide = 1 };
    row.cells[11] = .{ .content = Cell.empty, .wide = 2 };
    row.cells[12] = .{ .content = 'y' };

    const got = try matchText(&g, 0, 3);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("https://x/日y", got);
}
