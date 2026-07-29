//! Terminal semantics: cursor, pen, and the parser's handler interface.
//!
//! Phase 1 covers what a shell prompt and `ls --color` need. Deliberately absent
//! until phase 2: scroll regions (DECSTBM), insert/delete line and char, alt
//! screen, tab stop manipulation, and double-width characters (every cell is
//! assumed one column wide — see `print`).

const std = @import("std");
const cellmod = @import("cell.zig");
const gridmod = @import("grid.zig");
const Grid = gridmod.Grid;
const parser = @import("../vt/parser.zig");

const Cell = cellmod.Cell;
const Style = cellmod.Style;
const Rgb = cellmod.Rgb;
const StyleTable = cellmod.StyleTable;

pub const Screen = struct {
    gpa: std.mem.Allocator,
    grid: Grid,
    styles: StyleTable = .{},

    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    cursor_visible: bool = true,

    /// Current SGR state, and its interned id. The id is recomputed only when SGR
    /// changes, so `print` stays a plain store with no hash lookup.
    pen: Style = Style.default,
    pen_id: u16 = 0,

    /// DECAWM. When the cursor writes the last column, the wrap is *deferred*
    /// until the next printable character — otherwise a line that exactly fills
    /// the width would scroll one row too early.
    autowrap: bool = true,
    wrap_pending: bool = false,

    /// Set on any mutation; the render loop consumes and clears it.
    dirty: bool = true,

    title_buf: [256]u8 = undefined,
    title_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, cols: u32, rows: u32) !Screen {
        return initScrollback(gpa, cols, rows, gridmod.default_scrollback);
    }

    pub fn initScrollback(
        gpa: std.mem.Allocator,
        cols: u32,
        rows: u32,
        scrollback: u32,
    ) !Screen {
        var s = Screen{ .gpa = gpa, .grid = try Grid.init(gpa, cols, rows, scrollback) };
        try s.styles.init(gpa);
        return s;
    }

    pub fn deinit(self: *Screen) void {
        self.grid.deinit();
        self.styles.deinit(self.gpa);
    }

    pub fn resize(self: *Screen, cols: u32, rows: u32) !void {
        var cur = gridmod.Cursor{ .x = self.cursor_x, .y = self.cursor_y };
        try self.grid.resizeReflow(cols, rows, &cur);
        self.cursor_x = cur.x;
        self.cursor_y = cur.y;
        // A pending wrap is meaningless at the new width.
        self.wrap_pending = false;
        self.dirty = true;
    }

    pub fn title(self: *const Screen) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    // ── parser handler interface ────────────────────────────────────────────

    pub fn print(self: *Screen, cp: u21) void {
        if (self.wrap_pending) {
            self.wrap_pending = false;
            // Record that this row continues onto the next one. This is the single
            // bit of state that lets resize tell a soft wrap from a real newline,
            // and therefore the thing reflow depends on entirely.
            self.grid.rowMeta(self.cursor_y).wrapped = true;
            self.cursor_x = 0;
            self.lineFeed();
        }

        // TODO(phase 2): double-width via wcwidth, plus the trailing spacer cell
        // and grapheme cluster side table. Phase 1 treats every codepoint as one
        // column, which is correct for ASCII and most Nerd Font icons.
        const cell = self.grid.at(self.cursor_x, self.cursor_y);
        cell.* = .{ .content = cp, .style = self.pen_id, .dirty = true };

        if (self.cursor_x + 1 >= self.grid.cols) {
            if (self.autowrap) self.wrap_pending = true;
        } else {
            self.cursor_x += 1;
        }
        self.dirty = true;
    }

    pub fn execute(self: *Screen, b: u8) void {
        switch (b) {
            0x07 => {}, // BEL: no audio bell, matching the user's kitty config.
            0x08 => { // BS
                self.wrap_pending = false;
                if (self.cursor_x > 0) self.cursor_x -= 1;
                self.dirty = true;
            },
            0x09 => self.tab(),
            // LF, VT and FF all move down one line.
            0x0a, 0x0b, 0x0c => {
                self.wrap_pending = false;
                self.lineFeed();
            },
            0x0d => { // CR
                self.wrap_pending = false;
                self.cursor_x = 0;
                self.dirty = true;
            },
            else => {},
        }
    }

    pub fn escDispatch(self: *Screen, final: u8, _: []const u8) void {
        switch (final) {
            // NEL, IND: down one line. RI (reverse index) is phase 2 (needs
            // scroll regions to be meaningful).
            'D', 'E' => {
                if (final == 'E') self.cursor_x = 0;
                self.lineFeed();
            },
            'c' => self.reset(),
            else => {},
        }
    }

    pub fn csiDispatch(
        self: *Screen,
        final: u8,
        private: u8,
        _: []const u8,
        params: *const parser.Params,
    ) void {
        switch (final) {
            'm' => self.sgr(params),
            'H', 'f' => { // CUP — 1-based, defaults to home
                const row = params.get(0, 1);
                const col = params.get(1, 1);
                self.cursor_y = @min(@max(row, 1) - 1, self.grid.rows - 1);
                self.cursor_x = @min(@max(col, 1) - 1, self.grid.cols - 1);
                self.wrap_pending = false;
            },
            'A' => self.moveCursor(0, -@as(i64, params.get(0, 1))),
            'B' => self.moveCursor(0, params.get(0, 1)),
            'C' => self.moveCursor(params.get(0, 1), 0),
            'D' => self.moveCursor(-@as(i64, params.get(0, 1)), 0),
            'G' => { // CHA: absolute column
                self.cursor_x = @min(@max(params.get(0, 1), 1) - 1, self.grid.cols - 1);
                self.wrap_pending = false;
            },
            'd' => { // VPA: absolute row
                self.cursor_y = @min(@max(params.get(0, 1), 1) - 1, self.grid.rows - 1);
                self.wrap_pending = false;
            },
            'J' => self.eraseInDisplay(params.get(0, 0)),
            'K' => self.eraseInLine(params.get(0, 0)),
            'X' => self.eraseChars(params.get(0, 1)),
            'h', 'l' => {
                if (private == '?') self.decPrivateMode(params, final == 'h');
            },
            else => {},
        }
        self.dirty = true;
    }

    pub fn oscDispatch(self: *Screen, data: []const u8) void {
        // OSC 0 (icon + title) and OSC 2 (title).
        //
        // Note there is deliberately no title *query* support, and there never
        // will be: output can set the title, and a terminal that reports it back
        // lets a compromised remote host echo arbitrary bytes onto our input
        // stream. See PLAN.md §7.
        const semi = std.mem.indexOfScalar(u8, data, ';') orelse return;
        const code = data[0..semi];
        const text = data[semi + 1 ..];

        if (std.mem.eql(u8, code, "0") or std.mem.eql(u8, code, "2")) {
            const n = @min(text.len, self.title_buf.len);
            @memcpy(self.title_buf[0..n], text[0..n]);
            self.title_len = n;
        }
    }

    // DCS is parsed but dropped until Sixel lands in phase 8.
    pub fn dcsHook(_: *Screen, _: u8, _: u8, _: *const parser.Params) void {}
    pub fn dcsPut(_: *Screen, _: u8) void {}
    pub fn dcsUnhook(_: *Screen) void {}

    // ── operations ─────────────────────────────────────────────────────────

    fn lineFeed(self: *Screen) void {
        if (self.cursor_y + 1 >= self.grid.rows) {
            // Appending a blank line is what scrolls the screen; the displaced row
            // becomes scrollback, so cursor_y keeps pointing at the bottom row.
            self.grid.scrollUp(1, self.pen_id);
        } else {
            self.cursor_y += 1;
        }
        self.dirty = true;
    }

    fn tab(self: *Screen) void {
        // Fixed 8-column tab stops; DECST8C / HTS come in phase 2.
        const next = (self.cursor_x / 8 + 1) * 8;
        self.cursor_x = @min(next, self.grid.cols - 1);
        self.dirty = true;
    }

    fn moveCursor(self: *Screen, dx: i64, dy: i64) void {
        const x = @as(i64, self.cursor_x) + dx;
        const y = @as(i64, self.cursor_y) + dy;
        self.cursor_x = @intCast(std.math.clamp(x, 0, @as(i64, self.grid.cols) - 1));
        self.cursor_y = @intCast(std.math.clamp(y, 0, @as(i64, self.grid.rows) - 1));
        self.wrap_pending = false;
    }

    fn eraseInDisplay(self: *Screen, mode: u16) void {
        switch (mode) {
            0 => { // cursor to end of screen
                self.eraseInLine(0);
                self.grid.clearRows(self.cursor_y + 1, self.grid.rows, self.pen_id);
            },
            1 => { // start of screen to cursor
                self.grid.clearRows(0, self.cursor_y, self.pen_id);
                self.eraseInLine(1);
            },
            2 => self.grid.clearVisible(self.pen_id),
            // ED(3) additionally discards scrollback.
            3 => {
                self.grid.clearVisible(self.pen_id);
                self.grid.dropScrollback();
            },
            else => {},
        }
    }

    fn eraseInLine(self: *Screen, mode: u16) void {
        const meta = self.grid.rowMeta(self.cursor_y);
        const b = gridmod.blankCell(self.pen_id);
        switch (mode) {
            0 => {
                @memset(meta.cells[self.cursor_x..], b);
                // The line no longer runs on, so it must not be joined by reflow.
                meta.wrapped = false;
            },
            1 => @memset(meta.cells[0 .. self.cursor_x + 1], b),
            2 => {
                @memset(meta.cells, b);
                meta.wrapped = false;
            },
            else => {},
        }
    }

    fn eraseChars(self: *Screen, n: u16) void {
        const row = self.grid.row(self.cursor_y);
        const end = @min(self.cursor_x + @max(n, 1), self.grid.cols);
        @memset(row[self.cursor_x..end], gridmod.blankCell(self.pen_id));
    }

    fn decPrivateMode(self: *Screen, params: *const parser.Params, set: bool) void {
        for (0..params.len) |i| {
            switch (params.values[i]) {
                7 => self.autowrap = set, // DECAWM
                25 => self.cursor_visible = set, // DECTCEM
                else => {}, // 1049 alt screen, 2004 bracketed paste: phase 2/3
            }
        }
    }

    fn reset(self: *Screen) void {
        self.pen = Style.default;
        self.pen_id = 0;
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.autowrap = true;
        self.wrap_pending = false;
        self.grid.clearVisible(0);
        self.dirty = true;
    }

    // ── SGR ────────────────────────────────────────────────────────────────

    fn sgr(self: *Screen, params: *const parser.Params) void {
        if (params.len == 0) {
            self.pen = Style.default;
            self.commitPen();
            return;
        }

        var i: usize = 0;
        while (i < params.len) : (i += 1) {
            const p = params.values[i];
            switch (p) {
                0 => self.pen = Style.default,
                1 => self.pen.attrs.bold = true,
                2 => self.pen.attrs.dim = true,
                3 => self.pen.attrs.italic = true,
                4 => {
                    // `4:n` selects a style; plain `4` is a single underline.
                    const style_arg = if (i + 1 < params.len and params.is_sub[i + 1])
                        params.values[i + 1]
                    else
                        1;
                    if (i + 1 < params.len and params.is_sub[i + 1]) i += 1;
                    self.pen.attrs.underline = switch (style_arg) {
                        0 => .none,
                        1 => .single,
                        2 => .double,
                        3 => .curly,
                        4 => .dotted,
                        5 => .dashed,
                        else => .single,
                    };
                },
                5, 6 => self.pen.attrs.blink = true,
                7 => self.pen.attrs.inverse = true,
                8 => self.pen.attrs.invisible = true,
                9 => self.pen.attrs.strike = true,
                21 => self.pen.attrs.underline = .double,
                22 => {
                    self.pen.attrs.bold = false;
                    self.pen.attrs.dim = false;
                },
                23 => self.pen.attrs.italic = false,
                24 => self.pen.attrs.underline = .none,
                25 => self.pen.attrs.blink = false,
                27 => self.pen.attrs.inverse = false,
                28 => self.pen.attrs.invisible = false,
                29 => self.pen.attrs.strike = false,
                30...37 => self.pen.fg = cellmod.ansi16[p - 30],
                38 => if (self.extendedColor(params, &i)) |col| {
                    self.pen.fg = col;
                },
                39 => self.pen.fg = cellmod.default_fg,
                40...47 => self.pen.bg = cellmod.ansi16[p - 40],
                48 => if (self.extendedColor(params, &i)) |col| {
                    self.pen.bg = col;
                },
                49 => self.pen.bg = cellmod.default_bg,
                58 => if (self.extendedColor(params, &i)) |col| {
                    self.pen.ul = col;
                },
                59 => self.pen.ul = cellmod.default_fg,
                90...97 => self.pen.fg = cellmod.ansi16[p - 90 + 8],
                100...107 => self.pen.bg = cellmod.ansi16[p - 100 + 8],
                else => {},
            }
        }
        self.commitPen();
    }

    /// Parse the argument of SGR 38/48/58, advancing `i` past what it consumed.
    ///
    /// Accepts both the semicolon form (`38;5;n`, `38;2;r;g;b`) and the colon form
    /// (`38:5:n`, `38:2:r:g:b`). TODO(phase 2): the colon form may also carry a
    /// colour-space id — `38:2::r:g:b` — which we currently misread.
    fn extendedColor(_: *Screen, params: *const parser.Params, i: *usize) ?Rgb {
        const kind = params.get(i.* + 1, 0);
        switch (kind) {
            5 => {
                const idx = params.get(i.* + 2, 0);
                i.* += 2;
                return cellmod.palette256[@min(idx, 255)];
            },
            2 => {
                const r = params.get(i.* + 2, 0);
                const g = params.get(i.* + 3, 0);
                const b = params.get(i.* + 4, 0);
                i.* += 4;
                return Rgb.rgb(
                    @intCast(@min(r, 255)),
                    @intCast(@min(g, 255)),
                    @intCast(@min(b, 255)),
                );
            },
            else => return null,
        }
    }

    fn commitPen(self: *Screen) void {
        // Falling back to the default style on OOM is a cosmetic loss; refusing to
        // render would not be.
        self.pen_id = self.styles.intern(self.gpa, self.pen) catch 0;
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const Parser = parser.Parser(Screen);

fn feed(s: *Screen, bytes: []const u8) void {
    var p = Parser.init(s);
    p.feed(bytes);
}

fn rowText(s: *const Screen, y: u32, buf: []u8) []const u8 {
    const row = s.grid.row(y);
    var n: usize = 0;
    for (row) |cl| {
        if (n >= buf.len) break;
        buf[n] = if (cl.content == Cell.empty or cl.content > 0x7f)
            ' '
        else
            @intCast(cl.content);
        n += 1;
    }
    return std.mem.trimEnd(u8, buf[0..n], " ");
}

test "plain text lands on the grid" {
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();
    feed(&s, "hello");

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hello", rowText(&s, 0, &buf));
    try std.testing.expectEqual(@as(u32, 5), s.cursor_x);
}

test "deferred wrap: a line that exactly fills the width does not scroll early" {
    var s = try Screen.init(std.testing.allocator, 4, 3);
    defer s.deinit();

    feed(&s, "abcd");
    // Cursor parked on the last column with a wrap pending, still on row 0.
    try std.testing.expectEqual(@as(u32, 0), s.cursor_y);
    try std.testing.expect(s.wrap_pending);

    feed(&s, "e");
    try std.testing.expectEqual(@as(u32, 1), s.cursor_y);
    try std.testing.expectEqual(@as(u32, 1), s.cursor_x);

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", rowText(&s, 0, &buf));
    try std.testing.expectEqualStrings("e", rowText(&s, 1, &buf));
}

test "CR then overwrite replaces the line in place" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();
    feed(&s, "abcdef\rXY");

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("XYcdef", rowText(&s, 0, &buf));
}

test "LF on the last row scrolls" {
    var s = try Screen.init(std.testing.allocator, 4, 2);
    defer s.deinit();
    feed(&s, "a\r\nb\r\nc");

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("b", rowText(&s, 0, &buf));
    try std.testing.expectEqualStrings("c", rowText(&s, 1, &buf));
}

test "SGR truecolor and 256-colour set the pen" {
    var s = try Screen.init(std.testing.allocator, 8, 2);
    defer s.deinit();

    feed(&s, "\x1b[38;2;10;20;30mA");
    const a = s.styles.get(s.grid.at(0, 0).style);
    try std.testing.expect(a.fg.eq(Rgb.rgb(10, 20, 30)));

    feed(&s, "\x1b[38;5;196mB");
    const b = s.styles.get(s.grid.at(1, 0).style);
    try std.testing.expect(b.fg.eq(cellmod.palette256[196]));

    feed(&s, "\x1b[0mC");
    const c = s.styles.get(s.grid.at(2, 0).style);
    try std.testing.expect(c.fg.eq(cellmod.default_fg));
}

test "SGR 4:3 selects curly underline without also setting italic" {
    var s = try Screen.init(std.testing.allocator, 8, 2);
    defer s.deinit();
    feed(&s, "\x1b[4:3mA");

    const st = s.styles.get(s.grid.at(0, 0).style);
    try std.testing.expectEqual(cellmod.Underline.curly, st.attrs.underline);
    try std.testing.expect(!st.attrs.italic);
}

test "CUP is 1-based and clamps to the grid" {
    var s = try Screen.init(std.testing.allocator, 5, 4);
    defer s.deinit();

    feed(&s, "\x1b[2;3H");
    try std.testing.expectEqual(@as(u32, 1), s.cursor_y);
    try std.testing.expectEqual(@as(u32, 2), s.cursor_x);

    feed(&s, "\x1b[H");
    try std.testing.expectEqual(@as(u32, 0), s.cursor_y);
    try std.testing.expectEqual(@as(u32, 0), s.cursor_x);

    feed(&s, "\x1b[99;99H");
    try std.testing.expectEqual(@as(u32, 3), s.cursor_y);
    try std.testing.expectEqual(@as(u32, 4), s.cursor_x);
}

test "erase in line and display" {
    var s = try Screen.init(std.testing.allocator, 6, 2);
    defer s.deinit();
    feed(&s, "abcdef\x1b[1;3H\x1b[K");

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ab", rowText(&s, 0, &buf));

    feed(&s, "\x1b[2J");
    try std.testing.expectEqualStrings("", rowText(&s, 0, &buf));
}

test "OSC 2 sets the title, and no query path exists" {
    var s = try Screen.init(std.testing.allocator, 8, 2);
    defer s.deinit();
    feed(&s, "\x1b]2;my shell\x07");
    try std.testing.expectEqualStrings("my shell", s.title());
}

test "soft-wrapped output rewraps on narrow and survives widening again" {
    // The reported bug: shrinking the window below the text width made text
    // disappear, and widening did not bring it back.
    var s = try Screen.init(std.testing.allocator, 20, 5);
    defer s.deinit();

    const long = "the quick brown fox jumps over the lazy dog";
    feed(&s, long);

    // rowText trims the trailing blanks of each row, so expectations carry none.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("the quick brown fox", rowText(&s, 0, &buf));
    try std.testing.expect(s.grid.rowMeta(0).wrapped);

    // Narrow well below the line width.
    try s.resize(10, 5);
    try std.testing.expectEqualStrings("the quick", rowText(&s, 0, &buf));
    try std.testing.expectEqualStrings("brown fox", rowText(&s, 1, &buf));
    try std.testing.expectEqualStrings("jumps over", rowText(&s, 2, &buf));

    // Widen again: the original layout comes back rather than staying truncated.
    try s.resize(20, 5);
    try std.testing.expectEqualStrings("the quick brown fox", rowText(&s, 0, &buf));
    try std.testing.expectEqualStrings("jumps over the lazy", rowText(&s, 1, &buf));
    try std.testing.expectEqualStrings("dog", rowText(&s, 2, &buf));
}

test "hard-newline lines are not merged when narrowing" {
    var s = try Screen.init(std.testing.allocator, 12, 4);
    defer s.deinit();
    feed(&s, "alpha\r\nbeta\r\ngamma");

    try s.resize(4, 6);

    var buf: [32]u8 = undefined;
    // "alpha" rewraps to two rows; "beta" and "gamma" stay separate lines.
    try std.testing.expectEqualStrings("alph", rowText(&s, 0, &buf));
    try std.testing.expectEqualStrings("a", rowText(&s, 1, &buf));
    try std.testing.expectEqualStrings("beta", rowText(&s, 2, &buf));
    try std.testing.expectEqualStrings("gamm", rowText(&s, 3, &buf));
    try std.testing.expectEqualStrings("a", rowText(&s, 4, &buf));
}

test "scrolled-off output goes to scrollback rather than being lost" {
    var s = try Screen.initScrollback(std.testing.allocator, 8, 2, 16);
    defer s.deinit();
    feed(&s, "one\r\ntwo\r\nthree\r\nfour");

    // Screen shows the last two lines; the earlier ones are history.
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("three", rowText(&s, 0, &buf));
    try std.testing.expectEqualStrings("four", rowText(&s, 1, &buf));
    try std.testing.expectEqual(@as(usize, 2), s.grid.historyLen());
}

test "tab advances to the next 8-column stop" {
    var s = try Screen.init(std.testing.allocator, 24, 2);
    defer s.deinit();
    feed(&s, "a\tb");
    try std.testing.expectEqual(@as(u32, 9), s.cursor_x);

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("a       b", rowText(&s, 0, &buf));
}
