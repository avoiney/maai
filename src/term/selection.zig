//! Text selection over the grid, including scrollback.
//!
//! Coordinates are absolute logical line indices into the grid ring, not screen
//! rows, so a selection stays put while the view scrolls. Reflow renumbers those
//! lines, so a resize clears the selection rather than trying to migrate it.
//!
//! The subtle part is `copyText`: a soft-wrapped line must be copied back as one
//! continuous line with no newline inserted at the wrap. Getting that wrong is why
//! pasting a long command from some terminals executes it in pieces.

const std = @import("std");
const cellmod = @import("cell.zig");
const gridmod = @import("grid.zig");
const Cell = cellmod.Cell;
const Grid = gridmod.Grid;

/// Characters that end a word for double-click selection. Deliberately includes
/// shell punctuation so double-clicking inside a path or URL grabs the whole thing.
pub const default_word_separators = " \t\n\"'`()[]{}<>|;:,!?*+=&^%$#@\\";

pub const Mode = enum { char, word, line, block };

pub const Point = struct {
    line: usize,
    x: u32,

    fn beforeOrEqual(a: Point, b: Point) bool {
        if (a.line != b.line) return a.line < b.line;
        return a.x <= b.x;
    }
};

pub const Selection = struct {
    active: bool = false,
    mode: Mode = .char,
    /// Where the drag began; stays fixed while the head moves.
    anchor: Point = .{ .line = 0, .x = 0 },
    head: Point = .{ .line = 0, .x = 0 },
    word_separators: []const u8 = default_word_separators,

    pub fn clear(self: *Selection) void {
        self.active = false;
    }

    pub fn begin(self: *Selection, grid: *const Grid, at: Point, mode: Mode) void {
        self.active = true;
        self.mode = mode;
        self.anchor = at;
        self.head = at;
        self.normalize(grid);
    }

    pub fn extend(self: *Selection, grid: *const Grid, to: Point) void {
        if (!self.active) return;
        self.head = to;
        self.normalize(grid);
    }

    /// Lower and upper bounds in reading order.
    pub fn bounds(self: *const Selection) struct { start: Point, end: Point } {
        if (self.anchor.beforeOrEqual(self.head)) {
            return .{ .start = self.anchor, .end = self.head };
        }
        return .{ .start = self.head, .end = self.anchor };
    }

    /// Snap the endpoints outward according to the mode. Word and line selections
    /// re-expand on every update so that dragging grows them a word or line at a
    /// time rather than a character.
    fn normalize(self: *Selection, grid: *const Grid) void {
        switch (self.mode) {
            .char, .block => {},
            .word => {
                const b = self.bounds();
                var start = b.start;
                var end = b.end;
                start.x = wordStart(grid, start, self.word_separators);
                end.x = wordEnd(grid, end, self.word_separators);
                self.setOrdered(start, end);
            },
            .line => {
                const b = self.bounds();
                // Whole logical lines, following soft wraps at both ends.
                const first = logicalStart(grid, b.start.line);
                const last = logicalEnd(grid, b.end.line);
                self.setOrdered(
                    .{ .line = first, .x = 0 },
                    .{ .line = last, .x = grid.cols - 1 },
                );
            },
        }
    }

    fn setOrdered(self: *Selection, start: Point, end: Point) void {
        // Preserve which end the user is dragging so further motion feels right.
        if (self.anchor.beforeOrEqual(self.head)) {
            self.anchor = start;
            self.head = end;
        } else {
            self.anchor = end;
            self.head = start;
        }
    }

    pub fn contains(self: *const Selection, line: usize, x: u32) bool {
        if (!self.active) return false;
        const b = self.bounds();

        if (self.mode == .block) {
            if (line < b.start.line or line > b.end.line) return false;
            const lo = @min(self.anchor.x, self.head.x);
            const hi = @max(self.anchor.x, self.head.x);
            return x >= lo and x <= hi;
        }

        if (line < b.start.line or line > b.end.line) return false;
        if (line == b.start.line and x < b.start.x) return false;
        if (line == b.end.line and x > b.end.x) return false;
        return true;
    }

    /// Render the selection as UTF-8. Caller owns the result.
    pub fn copyText(
        self: *const Selection,
        gpa: std.mem.Allocator,
        grid: *const Grid,
        graphemes: *const cellmod.GraphemeTable,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (!self.active) return out.toOwnedSlice(gpa);

        const b = self.bounds();
        const block = self.mode == .block;
        const block_lo = @min(self.anchor.x, self.head.x);
        const block_hi = @max(self.anchor.x, self.head.x);

        var line = b.start.line;
        while (line <= b.end.line and line < grid.count) : (line += 1) {
            const row = grid.line(line);

            const x0: u32 = if (block)
                block_lo
            else if (line == b.start.line) b.start.x else 0;
            const x1: u32 = if (block)
                block_hi
            else if (line == b.end.line) b.end.x else grid.cols - 1;

            const hi = @min(x1, grid.cols - 1);
            const slice = row.cells[x0 .. hi + 1];

            // Trailing blanks are noise, except inside a soft-wrapped line where
            // they are real content that the next row continues from.
            const keep = if (block or !row.wrapped) trimmedLen(slice) else slice.len;

            for (slice[0..keep]) |cell| {
                // A spacer carries no content of its own.
                if (cell.wide == 2) continue;
                if (cell.grapheme) {
                    for (graphemes.get(cell.content)) |cp| try appendCp(&out, gpa, cp);
                } else if (cell.content == Cell.empty) {
                    try out.append(gpa, ' ');
                } else {
                    try appendCp(&out, gpa, @intCast(cell.content));
                }
            }

            if (line == b.end.line) break;
            // A soft wrap is not a line break: joining the rows back together is
            // what makes a pasted command run as one line.
            if (block or !row.wrapped) try out.append(gpa, '\n');
        }

        return out.toOwnedSlice(gpa);
    }
};

fn appendCp(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.append(gpa, '?');
        return;
    };
    try out.appendSlice(gpa, buf[0..n]);
}

fn trimmedLen(cells: []const Cell) usize {
    var n = cells.len;
    while (n > 0) : (n -= 1) {
        const cell = cells[n - 1];
        if (cell.content != Cell.empty and cell.content != ' ') break;
    }
    return n;
}

fn cellChar(grid: *const Grid, line: usize, x: u32) u21 {
    if (line >= grid.count or x >= grid.cols) return ' ';
    const cell = grid.line(line).cells[x];
    if (cell.grapheme) return ' '; // treat clusters as word content below
    if (cell.content == Cell.empty) return ' ';
    return @intCast(cell.content);
}

fn isSeparator(grid: *const Grid, line: usize, x: u32, seps: []const u8) bool {
    if (line >= grid.count or x >= grid.cols) return true;
    const cell = grid.line(line).cells[x];
    // Clusters and wide characters are word content, never separators.
    if (cell.grapheme or cell.wide != 0) return false;
    const cp = cellChar(grid, line, x);
    if (cp > 0x7f) return false;
    return std.mem.indexOfScalar(u8, seps, @intCast(cp)) != null;
}

fn wordStart(grid: *const Grid, at: Point, seps: []const u8) u32 {
    if (isSeparator(grid, at.line, at.x, seps)) return at.x;
    var x = at.x;
    while (x > 0 and !isSeparator(grid, at.line, x - 1, seps)) x -= 1;
    return x;
}

fn wordEnd(grid: *const Grid, at: Point, seps: []const u8) u32 {
    if (isSeparator(grid, at.line, at.x, seps)) return at.x;
    var x = at.x;
    while (x + 1 < grid.cols and !isSeparator(grid, at.line, x + 1, seps)) x += 1;
    return x;
}

/// First row of the logical line containing `line`, walking back over soft wraps.
pub fn logicalStart(grid: *const Grid, line: usize) usize {
    var l = line;
    while (l > 0 and grid.line(l - 1).wrapped) l -= 1;
    return l;
}

/// Last row of the logical line containing `line`, walking forward over soft wraps.
pub fn logicalEnd(grid: *const Grid, line: usize) usize {
    var l = line;
    while (l + 1 < grid.count and grid.line(l).wrapped) l += 1;
    return l;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn put(g: *Grid, line: usize, text: []const u8) void {
    const row = g.line(line);
    for (text, 0..) |ch, i| {
        if (i >= g.cols) break;
        row.cells[i] = .{ .content = ch };
    }
}

fn copy(sel: *const Selection, g: *const Grid) ![]u8 {
    const empty_table = cellmod.GraphemeTable{};
    return sel.copyText(testing.allocator, g, &empty_table);
}

test "character selection across one row" {
    var g = try Grid.init(testing.allocator, 10, 2, 4);
    defer g.deinit();
    put(&g, 0, "hello world");

    var sel = Selection{};
    sel.begin(&g, .{ .line = 0, .x = 0 }, .char);
    sel.extend(&g, .{ .line = 0, .x = 4 });

    const text = try copy(&sel, &g);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hello", text);
}

test "selection spanning a hard line break inserts a newline" {
    var g = try Grid.init(testing.allocator, 6, 3, 4);
    defer g.deinit();
    put(&g, 0, "abc");
    put(&g, 1, "def");

    var sel = Selection{};
    sel.begin(&g, .{ .line = 0, .x = 0 }, .char);
    sel.extend(&g, .{ .line = 1, .x = 2 });

    const text = try copy(&sel, &g);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("abc\ndef", text);
}

test "a soft wrap is joined rather than broken by a newline" {
    // This is what makes a pasted long command run as one line.
    var g = try Grid.init(testing.allocator, 6, 3, 4);
    defer g.deinit();
    put(&g, 0, "abcdef");
    g.line(0).wrapped = true;
    put(&g, 1, "ghi");

    var sel = Selection{};
    sel.begin(&g, .{ .line = 0, .x = 0 }, .char);
    sel.extend(&g, .{ .line = 1, .x = 2 });

    const text = try copy(&sel, &g);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("abcdefghi", text);
}

test "double-click word selection grabs a whole path" {
    var g = try Grid.init(testing.allocator, 32, 2, 4);
    defer g.deinit();
    put(&g, 0, "run /usr/local/bin/tool now");

    var sel = Selection{};
    // Click somewhere inside the path.
    sel.begin(&g, .{ .line = 0, .x = 8 }, .word);

    const text = try copy(&sel, &g);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("/usr/local/bin/tool", text);
}

test "line selection covers the whole logical line, wraps included" {
    var g = try Grid.init(testing.allocator, 5, 4, 8);
    defer g.deinit();
    put(&g, 0, "aaaaa");
    g.line(0).wrapped = true;
    put(&g, 1, "bbbbb");
    g.line(1).wrapped = true;
    put(&g, 2, "ccc");

    var sel = Selection{};
    // Triple-click on the middle row of the wrapped line.
    sel.begin(&g, .{ .line = 1, .x = 2 }, .line);

    const text = try copy(&sel, &g);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("aaaaabbbbbccc", text);
}

test "block selection takes a rectangle and always breaks lines" {
    var g = try Grid.init(testing.allocator, 10, 3, 4);
    defer g.deinit();
    put(&g, 0, "one   xxx");
    put(&g, 1, "two   yyy");
    put(&g, 2, "three zzz");

    var sel = Selection{};
    sel.begin(&g, .{ .line = 0, .x = 6 }, .block);
    sel.extend(&g, .{ .line = 2, .x = 8 });

    const text = try copy(&sel, &g);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("xxx\nyyy\nzzz", text);
}

test "contains matches the highlighted region" {
    var g = try Grid.init(testing.allocator, 10, 3, 4);
    defer g.deinit();

    var sel = Selection{};
    sel.begin(&g, .{ .line = 0, .x = 3 }, .char);
    sel.extend(&g, .{ .line = 1, .x = 2 });

    try testing.expect(!sel.contains(0, 2));
    try testing.expect(sel.contains(0, 3));
    try testing.expect(sel.contains(0, 9));
    try testing.expect(sel.contains(1, 0));
    try testing.expect(sel.contains(1, 2));
    try testing.expect(!sel.contains(1, 3));
    try testing.expect(!sel.contains(2, 0));
}

test "selection dragged backwards still yields ordered text" {
    var g = try Grid.init(testing.allocator, 10, 2, 4);
    defer g.deinit();
    put(&g, 0, "abcdef");

    var sel = Selection{};
    sel.begin(&g, .{ .line = 0, .x = 4 }, .char);
    sel.extend(&g, .{ .line = 0, .x = 1 });

    const text = try copy(&sel, &g);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("bcde", text);
}

test "wide characters copy once, without their spacer" {
    var g = try Grid.init(testing.allocator, 8, 2, 4);
    defer g.deinit();
    const row = g.line(0);
    row.cells[0] = .{ .content = 'a' };
    row.cells[1] = .{ .content = '日', .wide = 1 };
    row.cells[2] = .{ .content = Cell.empty, .wide = 2 };
    row.cells[3] = .{ .content = 'b' };

    var sel = Selection{};
    sel.begin(&g, .{ .line = 0, .x = 0 }, .char);
    sel.extend(&g, .{ .line = 0, .x = 3 });

    const text = try copy(&sel, &g);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("a日b", text);
}
