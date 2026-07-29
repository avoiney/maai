//! Cell grid with scrollback and reflow-on-resize.
//!
//! Storage is one ring buffer covering scrollback *and* the visible screen. The
//! last `rows` logical lines are what is on screen; everything before them is
//! history. Scrolling the screen up is therefore just "append a blank line", and
//! eviction of old history falls out of the ring for free.
//!
//! Two allocations, not one per row: a single `slab` of cells, with `buf[k].cells`
//! pointing at `slab[k * cols ..]`. Ring slot k always owns the same storage, so
//! recycling a line during scroll is a memset rather than a free/alloc.
//!
//! The `wrapped` flag is what makes reflow possible: it records that a row's
//! content continues on the next row (a soft wrap) rather than ending in a real
//! newline. Without it, narrowing a window cannot tell "one long line" from "two
//! short lines", and both truncation and un-rewrappable output follow.

const std = @import("std");
const cellmod = @import("cell.zig");
const Cell = cellmod.Cell;

pub const default_scrollback = 10_000;

pub const Row = struct {
    cells: []Cell,
    /// This row's content continues on the next row (soft wrap), as opposed to
    /// ending at a hard newline.
    wrapped: bool = false,
};

/// Where the cursor is, in visible-screen coordinates. Reflow has to move it, so
/// it travels with the resize call.
pub const Cursor = struct { x: u32, y: u32 };

pub fn blankCell(style: u16) Cell {
    return .{ .content = ' ', .style = style };
}

/// A cell that carries no information and so may be dropped from the end of a
/// logical line during reflow. Cells with a non-default style are kept even when
/// blank, because a trailing run of coloured background is visible.
fn trimmable(c: Cell) bool {
    return (c.content == Cell.empty or c.content == ' ') and c.style == 0;
}

fn trimmedLen(cells: []const Cell) usize {
    var n = cells.len;
    while (n > 0 and trimmable(cells[n - 1])) n -= 1;
    return n;
}

pub const Grid = struct {
    gpa: std.mem.Allocator,
    cols: u32,
    /// Visible height.
    rows: u32,
    scrollback_max: u32,

    slab: []Cell,
    buf: []Row,
    /// Ring index of logical line 0 (the oldest line held).
    start: usize = 0,
    /// Logical lines held, scrollback + screen. Invariant: `count >= rows`.
    count: usize = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        cols: u32,
        rows: u32,
        scrollback_max: u32,
    ) !Grid {
        const capacity = @as(usize, rows) + scrollback_max;

        const slab = try gpa.alloc(Cell, capacity * cols);
        errdefer gpa.free(slab);
        @memset(slab, blankCell(0));

        const buf = try gpa.alloc(Row, capacity);
        for (buf, 0..) |*r, k| r.* = .{ .cells = slab[k * cols ..][0..cols] };

        var g = Grid{
            .gpa = gpa,
            .cols = cols,
            .rows = rows,
            .scrollback_max = scrollback_max,
            .slab = slab,
            .buf = buf,
        };
        // The screen must always exist, so start with a full screen of blanks.
        g.count = rows;
        return g;
    }

    pub fn deinit(self: *Grid) void {
        self.gpa.free(self.slab);
        self.gpa.free(self.buf);
    }

    pub fn cap(self: *const Grid) usize {
        return self.buf.len;
    }

    /// Logical line `i`, where 0 is the oldest line held.
    pub fn line(self: *const Grid, i: usize) *Row {
        std.debug.assert(i < self.count);
        return &self.buf[(self.start + i) % self.buf.len];
    }

    /// Logical index of the first visible row.
    pub fn screenTop(self: *const Grid) usize {
        return self.count - self.rows;
    }

    /// Number of scrollback lines above the screen.
    pub fn historyLen(self: *const Grid) usize {
        return self.count - self.rows;
    }

    pub fn rowMeta(self: *const Grid, y: u32) *Row {
        return self.line(self.screenTop() + y);
    }

    pub fn row(self: *const Grid, y: u32) []Cell {
        return self.rowMeta(y).cells;
    }

    pub fn at(self: *const Grid, x: u32, y: u32) *Cell {
        return &self.row(y)[x];
    }

    /// Append one blank line, evicting the oldest if the ring is full.
    fn pushBlank(self: *Grid, style: u16) *Row {
        if (self.count == self.buf.len) {
            self.start = (self.start + 1) % self.buf.len;
        } else {
            self.count += 1;
        }
        const r = self.line(self.count - 1);
        @memset(r.cells, blankCell(style));
        r.wrapped = false;
        return r;
    }

    /// Scroll the screen up by `n`, pushing displaced lines into scrollback.
    pub fn scrollUp(self: *Grid, n: u32, style: u16) void {
        var i: u32 = 0;
        while (i < n) : (i += 1) _ = self.pushBlank(style);
    }

    pub fn clearRows(self: *Grid, from: u32, to_exclusive: u32, style: u16) void {
        var y = from;
        while (y < @min(to_exclusive, self.rows)) : (y += 1) {
            const r = self.rowMeta(y);
            @memset(r.cells, blankCell(style));
            r.wrapped = false;
        }
    }

    /// Clear the visible screen. Scrollback is untouched, matching every other
    /// terminal's ED(2) behaviour.
    pub fn clearVisible(self: *Grid, style: u16) void {
        self.clearRows(0, self.rows, style);
    }

    pub fn dropScrollback(self: *Grid) void {
        self.start = (self.start + self.historyLen()) % self.buf.len;
        self.count = self.rows;
    }

    // ── scroll regions ──────────────────────────────────────────────────────
    // Region scrolling copies row contents rather than rotating the `cells`
    // pointers, because ring slot k permanently owns slab[k * cols ..]. Breaking
    // that would corrupt every later index calculation.
    //
    // Note these never touch scrollback: only a full-screen scroll produces
    // history, which is why `Screen.lineFeed` routes to `scrollUp` when the top
    // margin is 0 and here otherwise. Pushing region scrolls into history would
    // fill it with garbage from every full-screen app's redraw.

    fn copyVisibleRow(self: *Grid, dst: u32, src: u32) void {
        const d = self.rowMeta(dst);
        const s = self.rowMeta(src);
        @memcpy(d.cells, s.cells);
        d.wrapped = s.wrapped;
    }

    /// Scroll rows [top, bottom] up by `n`, blanking those exposed at the bottom.
    pub fn scrollRegionUp(self: *Grid, top: u32, bottom: u32, n: u32, style: u16) void {
        if (n == 0 or top > bottom or bottom >= self.rows) return;
        const height = bottom - top + 1;
        if (n >= height) {
            self.clearRows(top, bottom + 1, style);
            return;
        }
        var y = top;
        while (y + n <= bottom) : (y += 1) self.copyVisibleRow(y, y + n);
        self.clearRows(bottom + 1 - n, bottom + 1, style);
    }

    /// Scroll rows [top, bottom] down by `n`, blanking those exposed at the top.
    pub fn scrollRegionDown(self: *Grid, top: u32, bottom: u32, n: u32, style: u16) void {
        if (n == 0 or top > bottom or bottom >= self.rows) return;
        const height = bottom - top + 1;
        if (n >= height) {
            self.clearRows(top, bottom + 1, style);
            return;
        }
        var y: u32 = bottom + 1;
        while (y > top + n) {
            y -= 1;
            self.copyVisibleRow(y, y - n);
        }
        self.clearRows(top, top + n, style);
    }

    /// Resize without reflow, preserving the top-left overlap.
    ///
    /// This is for the alternate screen, which has no scrollback and whose owner
    /// redraws on SIGWINCH anyway. Rewrapping a full-screen TUI would produce
    /// garbage, since its "lines" are really independent screen rows.
    pub fn resizePreserve(self: *Grid, cols: u32, rows: u32, style: u16) !void {
        if (cols == self.cols and rows == self.rows) return;
        if (cols == 0 or rows == 0) return;

        const capacity = @as(usize, rows) + self.scrollback_max;
        const slab = try self.gpa.alloc(Cell, capacity * cols);
        errdefer self.gpa.free(slab);
        @memset(slab, blankCell(style));

        const buf = try self.gpa.alloc(Row, capacity);
        errdefer self.gpa.free(buf);
        for (buf, 0..) |*r, k| r.* = .{ .cells = slab[k * cols ..][0..cols] };

        const copy_rows = @min(rows, self.rows);
        const copy_cols = @min(cols, self.cols);
        var y: u32 = 0;
        while (y < copy_rows) : (y += 1) {
            @memcpy(buf[y].cells[0..copy_cols], self.row(y)[0..copy_cols]);
        }

        self.gpa.free(self.slab);
        self.gpa.free(self.buf);
        self.slab = slab;
        self.buf = buf;
        self.cols = cols;
        self.rows = rows;
        self.start = 0;
        self.count = rows;
    }

    // ── reflow ──────────────────────────────────────────────────────────────

    const Logical = struct {
        /// First logical-line index in the *old* grid.
        start: usize,
        /// Rows it occupied in the old grid.
        old_rows: usize,
        /// Content length in cells, after trimming the tail.
        len: usize,
        /// Rows it will occupy at the new width. Filled in by pass 2.
        new_rows: usize = 1,
    };

    /// Walks a logical line at a target width, placing each character so that a
    /// double-width pair never straddles a row boundary.
    ///
    /// Row breaks cannot be computed arithmetically once wide characters exist: a
    /// pair that would land half on one row and half on the next must move whole to
    /// the following row, leaving the last column blank. Counting rows and emitting
    /// them therefore share this one walker, so the two can never disagree.
    const Wrap = struct {
        g: *const Grid,
        line_start: usize,
        len: usize,
        cols: u32,

        off: usize = 0,
        row: usize = 0,
        x: u32 = 0,

        const Step = struct { row: usize, x: u32, off: usize, w: u8 };

        fn next(self: *Wrap) ?Step {
            while (self.off < self.len) {
                const src = self.cellAt(self.off);
                // Spacers carry no content; the lead reproduces them.
                if (src.wide == 2) {
                    self.off += 1;
                    continue;
                }
                const w: u8 = if (src.wide == 1) 2 else 1;
                // The `x > 0` guard keeps a width-1 grid from looping forever on a
                // wide character that can never fit.
                if (self.x > 0 and self.x + w > self.cols) {
                    self.row += 1;
                    self.x = 0;
                }
                const step = Step{ .row = self.row, .x = self.x, .off = self.off, .w = w };
                self.x += w;
                self.off += 1;
                return step;
            }
            return null;
        }

        fn cellAt(self: *const Wrap, off: usize) Cell {
            // Wrapped rows are exactly `g.cols` wide, so an offset maps uniformly
            // onto (old row, old column).
            const r = self.g.line(self.line_start + off / self.g.cols);
            return r.cells[off % self.g.cols];
        }
    };

    fn countWrappedRows(self: *const Grid, l: Logical, cols: u32) usize {
        var it = Wrap{ .g = self, .line_start = l.start, .len = l.len, .cols = cols };
        var rows: usize = 0;
        while (it.next()) |st| rows = st.row + 1;
        return @max(rows, 1);
    }

    /// Resize, rewrapping soft-wrapped lines to the new width.
    ///
    /// Logical lines are recovered by joining rows across the `wrapped` flag, then
    /// re-split at the new width. Because history is kept, narrowing and widening
    /// again restores the original layout instead of losing cells.
    ///
    /// The cursor is carried along by converting it to an offset within its logical
    /// line, then back to a row and column at the new width.
    pub fn resizeReflow(self: *Grid, cols: u32, rows: u32, cur: *Cursor) !void {
        if (cols == self.cols and rows == self.rows) return;
        if (cols == 0 or rows == 0) return;

        // ── pass 1: recover logical lines ──
        var logical: std.ArrayList(Logical) = .empty;
        defer logical.deinit(self.gpa);
        try logical.ensureTotalCapacity(self.gpa, self.count);

        const cur_abs = self.screenTop() + cur.y;
        var cur_logical: usize = 0;
        var cur_offset: usize = 0;

        var i: usize = 0;
        while (i < self.count) {
            const first = i;
            var total: usize = 0;
            while (true) {
                const r = self.line(i);
                const is_last = !(r.wrapped and i + 1 < self.count);
                if (i == cur_abs) {
                    cur_logical = logical.items.len;
                    cur_offset = (i - first) * self.cols + cur.x;
                }
                // A wrapped row is full by definition; only a line's final row can
                // have a trimmable tail.
                total += if (is_last) trimmedLen(r.cells) else self.cols;
                i += 1;
                if (is_last) break;
            }
            logical.appendAssumeCapacity(.{
                .start = first,
                .old_rows = i - first,
                .len = total,
            });
        }

        // Drop trailing empty lines before rewrapping. Without this, the blank
        // remainder of the screen counts as real logical lines, so every resize
        // pushes actual content further up into scrollback and the user sees their
        // output scroll away. The cursor's own line is always kept, since the
        // prompt usually sits on an otherwise-empty line.
        while (logical.items.len > 1) {
            const last = logical.items.len - 1;
            if (logical.items[last].len != 0 or last == cur_logical) break;
            _ = logical.pop();
        }

        // ── pass 2: how many rows will that be at the new width? ──
        const new_cap = @as(usize, rows) + self.scrollback_max;
        var total_new: usize = 0;
        for (logical.items) |*l| {
            l.new_rows = self.countWrappedRows(l.*, cols);
            total_new += l.new_rows;
        }

        // Oldest history is dropped when it no longer fits.
        const drop = if (total_new > new_cap) total_new - new_cap else 0;

        // ── build the new ring ──
        const slab = try self.gpa.alloc(Cell, new_cap * cols);
        errdefer self.gpa.free(slab);
        @memset(slab, blankCell(0));

        const buf = try self.gpa.alloc(Row, new_cap);
        errdefer self.gpa.free(buf);
        for (buf, 0..) |*r, k| r.* = .{ .cells = slab[k * cols ..][0..cols] };

        var global_row: usize = 0;
        var cur_new_abs: ?usize = null;
        var cur_new_x: u32 = 0;

        for (logical.items, 0..) |l, li| {
            const on_cursor_line = li == cur_logical;
            // Best placement seen so far for the cursor: the last character at or
            // before its offset. The offset can land on a spacer, or past the end of
            // the line entirely when the cursor trails the text.
            var best: ?Wrap.Step = null;

            var it = Wrap{ .g = self, .line_start = l.start, .len = l.len, .cols = cols };
            while (it.next()) |st| {
                if (on_cursor_line and st.off <= cur_offset) best = st;

                const grow = global_row + st.row;
                if (grow < drop) continue;
                const di = grow - drop;
                if (di >= new_cap) break;

                const src = it.cellAt(st.off);
                buf[di].cells[st.x] = src;
                if (st.w == 2 and st.x + 1 < cols) {
                    buf[di].cells[st.x + 1] = .{
                        .content = Cell.empty,
                        .style = src.style,
                        .wide = 2,
                    };
                }
            }

            // Mark soft-wrap continuations for every row of this logical line.
            var k: usize = 0;
            while (k < l.new_rows) : (k += 1) {
                const grow = global_row + k;
                if (grow < drop) continue;
                const di = grow - drop;
                if (di < new_cap) buf[di].wrapped = k + 1 < l.new_rows;
            }

            if (on_cursor_line) {
                if (best) |st| {
                    // Sitting exactly on a character keeps its column; anything
                    // past it (spacer, or trailing cursor) moves just after.
                    const x = if (st.off == cur_offset) st.x else st.x + st.w;
                    const overflow = x >= cols;
                    const grow = global_row + st.row + @intFromBool(overflow);
                    cur_new_x = if (overflow) 0 else x;
                    if (grow >= drop) cur_new_abs = grow - drop;
                } else {
                    // Empty line: the cursor sits at its start.
                    const grow = global_row;
                    cur_new_x = 0;
                    if (grow >= drop) cur_new_abs = grow - drop;
                }
            }

            global_row += l.new_rows;
        }

        self.gpa.free(self.slab);
        self.gpa.free(self.buf);
        self.slab = slab;
        self.buf = buf;
        self.cols = cols;
        self.rows = rows;
        self.start = 0;
        self.count = total_new - drop;

        // Pad so the screen is always fully populated.
        while (self.count < rows) _ = self.pushBlank(0);

        const top = self.screenTop();
        if (cur_new_abs) |abs| {
            cur.y = if (abs >= top) @intCast(@min(abs - top, rows - 1)) else 0;
            cur.x = @min(cur_new_x, cols - 1);
        } else {
            cur.y = @min(cur.y, rows - 1);
            cur.x = @min(cur.x, cols - 1);
        }
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn put(g: *Grid, y: u32, text: []const u8) void {
    for (text, 0..) |ch, x| g.at(@intCast(x), y).content = ch;
}

fn rowText(g: *Grid, y: u32, buf: []u8) []const u8 {
    const cells = g.row(y);
    var n: usize = 0;
    for (cells) |cl| {
        if (n >= buf.len) break;
        buf[n] = if (cl.content == Cell.empty or cl.content > 0x7f) ' ' else @intCast(cl.content);
        n += 1;
    }
    return std.mem.trimEnd(u8, buf[0..n], " ");
}

test "scrollUp pushes displaced lines into scrollback" {
    var g = try Grid.init(testing.allocator, 4, 2, 8);
    defer g.deinit();

    put(&g, 0, "aa");
    put(&g, 1, "bb");
    g.scrollUp(1, 0);

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("bb", rowText(&g, 0, &buf));
    try testing.expectEqualStrings("", rowText(&g, 1, &buf));
    // "aa" is now history, not lost.
    try testing.expectEqual(@as(usize, 1), g.historyLen());
    try testing.expectEqualStrings("aa", std.mem.trimEnd(u8, blk: {
        var tmp: [16]u8 = undefined;
        const cells = g.line(0).cells;
        for (cells, 0..) |cl, i| tmp[i] = if (cl.content > 0x7f or cl.content == 0) ' ' else @intCast(cl.content);
        break :blk tmp[0..cells.len];
    }, " "));
}

test "scrollback is bounded by scrollback_max" {
    var g = try Grid.init(testing.allocator, 4, 2, 3);
    defer g.deinit();

    g.scrollUp(100, 0);
    try testing.expectEqual(@as(usize, 5), g.count); // 2 visible + 3 history
    try testing.expectEqual(@as(usize, 3), g.historyLen());
}

test "narrowing rewraps a long line instead of truncating it" {
    var g = try Grid.init(testing.allocator, 8, 3, 8);
    defer g.deinit();

    // One logical line of 12 chars, soft-wrapped across two rows at width 8.
    put(&g, 0, "abcdefgh");
    g.rowMeta(0).wrapped = true;
    put(&g, 1, "ijkl");

    var cur = Cursor{ .x = 4, .y = 1 };
    try g.resizeReflow(4, 4, &cur);

    var buf: [16]u8 = undefined;
    // 12 chars at width 4 == exactly three rows, none of them lost.
    try testing.expectEqualStrings("abcd", rowText(&g, 0, &buf));
    try testing.expectEqualStrings("efgh", rowText(&g, 1, &buf));
    try testing.expectEqualStrings("ijkl", rowText(&g, 2, &buf));
    try testing.expect(g.rowMeta(0).wrapped);
    try testing.expect(g.rowMeta(1).wrapped);
    try testing.expect(!g.rowMeta(2).wrapped);
}

test "narrow then widen restores the original wrapping" {
    var g = try Grid.init(testing.allocator, 10, 4, 16);
    defer g.deinit();

    put(&g, 0, "0123456789");
    g.rowMeta(0).wrapped = true;
    put(&g, 1, "abcde");

    var cur = Cursor{ .x = 5, .y = 1 };
    try g.resizeReflow(3, 8, &cur);
    try g.resizeReflow(10, 4, &cur);

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0123456789", rowText(&g, 0, &buf));
    try testing.expectEqualStrings("abcde", rowText(&g, 1, &buf));
}

test "hard newlines are not joined by reflow" {
    var g = try Grid.init(testing.allocator, 8, 3, 8);
    defer g.deinit();

    // Two separate logical lines: no wrapped flag between them.
    put(&g, 0, "abc");
    put(&g, 1, "def");

    var cur = Cursor{ .x = 0, .y = 0 };
    try g.resizeReflow(4, 3, &cur);

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("abc", rowText(&g, 0, &buf));
    try testing.expectEqualStrings("def", rowText(&g, 1, &buf));
}

test "cursor follows its logical position through a rewrap" {
    var g = try Grid.init(testing.allocator, 8, 3, 8);
    defer g.deinit();

    put(&g, 0, "abcdefgh");
    g.rowMeta(0).wrapped = true;
    put(&g, 1, "ij");

    // Cursor sits on 'j' — logical offset 9.
    var cur = Cursor{ .x = 1, .y = 1 };
    try g.resizeReflow(4, 4, &cur);

    // At width 4, offset 9 is row 2, column 1.
    try testing.expectEqual(@as(u32, 1), cur.x);
    const abs = g.screenTop() + cur.y;
    try testing.expectEqual(@as(usize, 2), abs);
}

test "reflow preserves styles, including trailing coloured blanks" {
    var g = try Grid.init(testing.allocator, 6, 2, 8);
    defer g.deinit();

    // A blank cell with a non-default style must survive the tail trim.
    g.at(0, 0).* = .{ .content = 'x', .style = 7 };
    g.at(1, 0).* = .{ .content = ' ', .style = 7 };

    var cur = Cursor{ .x = 0, .y = 0 };
    try g.resizeReflow(3, 2, &cur);

    try testing.expectEqual(@as(u16, 7), g.at(0, 0).style);
    try testing.expectEqual(@as(u16, 7), g.at(1, 0).style);
}

test "property: width round-trip never loses cells of a wrapped line" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < 60) : (trial += 1) {
        const w0: u32 = rand.intRangeAtMost(u32, 2, 24);
        var g = try Grid.init(gpa, w0, 4, 64);
        defer g.deinit();

        // Build one long logical line across the whole screen.
        const text_len = w0 * 3;
        var expect: std.ArrayList(u8) = .empty;
        defer expect.deinit(gpa);
        var n: usize = 0;
        while (n < text_len) : (n += 1) {
            const ch: u8 = 'a' + @as(u8, @intCast(n % 26));
            try expect.append(gpa, ch);
            g.at(@intCast(n % w0), @intCast(n / w0)).content = ch;
        }
        var r: u32 = 0;
        while (r < 2) : (r += 1) g.rowMeta(r).wrapped = true;

        var cur = Cursor{ .x = 0, .y = 0 };
        const w1: u32 = rand.intRangeAtMost(u32, 2, 24);
        try g.resizeReflow(w1, rand.intRangeAtMost(u32, 2, 8), &cur);
        try g.resizeReflow(w0, 4, &cur);

        // Read the logical line back out and compare.
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        var idx: usize = 0;
        while (idx < g.count) : (idx += 1) {
            const rowp = g.line(idx);
            for (rowp.cells) |cl| {
                if (cl.content != Cell.empty and cl.content != ' ') {
                    try got.append(gpa, @intCast(cl.content));
                }
            }
            if (!rowp.wrapped and got.items.len > 0) break;
        }
        try testing.expectEqualStrings(expect.items, got.items);
    }
}
