//! Tests for `Screen`.
//!
//! Split out because screen.zig had grown past 2500 lines with 1000 of them tests,
//! which is the size at which finding anything means grepping. Behaviour is unchanged:
//! screen.zig references this file from a `test` block, so the suite still runs
//! wherever screen.zig is analysed.

const std = @import("std");
const screenmod = @import("screen.zig");
const Screen = screenmod.Screen;
const csi_u_stack_max = screenmod.csi_u_stack_max;
const Gc = screenmod.Gc;
const cellmod = @import("cell.zig");
const Cell = cellmod.Cell;
const Style = cellmod.Style;
const Rgb = cellmod.Rgb;
const thememod = @import("theme.zig");
const Color = thememod.Color;
const mousemod = @import("mouse.zig");
const parser = @import("../vt/parser.zig");

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

/// Collects replies so device-report tests can assert on them.
const Sink = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn write(ctx: *anyopaque, bytes: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        const n = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }

    fn got(self: *const Sink) []const u8 {
        return self.buf[0..self.len];
    }
};

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
    try std.testing.expect(s.styles.get(s.grid.at(0, 0).style).fg.eql(Color.rgb(10, 20, 30)));

    feed(&s, "\x1b[38;5;196mB");
    try std.testing.expect(s.styles.get(s.grid.at(1, 0).style).fg.eql(Color.indexed(196)));

    feed(&s, "\x1b[0mC");
    try std.testing.expect(s.styles.get(s.grid.at(2, 0).style).fg.eql(Color.default));
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

    feed(&s, "the quick brown fox jumps over the lazy dog");

    // rowText trims the trailing blanks of each row, so expectations carry none.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("the quick brown fox", rowText(&s, 0, &buf));
    try std.testing.expect(s.grid.rowMeta(0).wrapped);

    try s.resize(10, 5);
    try std.testing.expectEqualStrings("the quick", rowText(&s, 0, &buf));
    try std.testing.expectEqualStrings("brown fox", rowText(&s, 1, &buf));
    try std.testing.expectEqualStrings("jumps over", rowText(&s, 2, &buf));

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

test "HTS and TBC move and clear tab stops" {
    var s = try Screen.init(std.testing.allocator, 24, 2);
    defer s.deinit();

    feed(&s, "\x1b[3g"); // clear all stops
    feed(&s, "\x1b[1;5H\x1bH"); // set one at column 5 (index 4)
    feed(&s, "\x1b[1;1H\ta");
    try std.testing.expectEqual(@as(u32, 5), s.cursor_x);

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("    a", rowText(&s, 0, &buf));
}

test "CBT walks back through tab stops" {
    var s = try Screen.init(std.testing.allocator, 32, 2);
    defer s.deinit();
    feed(&s, "\x1b[1;20H\x1b[2Z");
    // From column 20 (index 19), two stops back is index 8.
    try std.testing.expectEqual(@as(u32, 8), s.cursor_x);
}

test "alternate screen keeps the primary intact and has no scrollback" {
    var s = try Screen.initScrollback(std.testing.allocator, 10, 3, 16);
    defer s.deinit();

    feed(&s, "primary text\r\n");
    feed(&s, "\x1b[?1049h"); // enter alt
    try std.testing.expect(s.in_alt);

    var buf: [32]u8 = undefined;
    // Alt starts cleared.
    try std.testing.expectEqualStrings("", rowText(&s, 0, &buf));

    feed(&s, "alt");
    try std.testing.expectEqualStrings("alt", rowText(&s, 0, &buf));
    // Scrolling the alt screen must not accumulate history.
    feed(&s, "\r\n\r\n\r\n\r\n\r\n");
    try std.testing.expectEqual(@as(usize, 0), s.grid.historyLen());

    feed(&s, "\x1b[?1049l"); // back to primary
    try std.testing.expect(!s.in_alt);
    try std.testing.expectEqualStrings("primary te", rowText(&s, 0, &buf));
}

test "alt screen restores the cursor position on exit" {
    var s = try Screen.init(std.testing.allocator, 10, 4);
    defer s.deinit();

    feed(&s, "\x1b[3;5H"); // row 3, col 5
    feed(&s, "\x1b[?1049h");
    feed(&s, "\x1b[1;1Hxyz");
    feed(&s, "\x1b[?1049l");

    try std.testing.expectEqual(@as(u32, 2), s.cursor_y);
    try std.testing.expectEqual(@as(u32, 4), s.cursor_x);
}

test "alt screen switches clear stale selection overlays" {
    var s = try Screen.init(std.testing.allocator, 10, 4);
    defer s.deinit();

    s.selection.begin(&s.grid, .{ .line = s.grid.screenTop(), .x = 1 }, .char);
    s.selection.extend(&s.grid, .{ .line = s.grid.screenTop(), .x = 3 });
    try std.testing.expect(s.selection.active);

    feed(&s, "\x1b[?1049h");
    try std.testing.expect(!s.selection.active);

    s.selection.begin(&s.grid, .{ .line = s.grid.screenTop(), .x = 2 }, .char);
    s.selection.extend(&s.grid, .{ .line = s.grid.screenTop(), .x = 4 });
    try std.testing.expect(s.selection.active);

    feed(&s, "\x1b[?1049l");
    try std.testing.expect(!s.selection.active);
}

test "scroll region confines scrolling to its rows" {
    var s = try Screen.init(std.testing.allocator, 6, 5);
    defer s.deinit();

    feed(&s, "\x1b[1;1Hr0\x1b[2;1Hr1\x1b[3;1Hr2\x1b[4;1Hr3\x1b[5;1Hr4");
    // Region covers rows 2..4 (1-based), i.e. indices 1..3.
    feed(&s, "\x1b[2;4r");
    feed(&s, "\x1b[4;1H\n"); // LF on the region's last row scrolls the region

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("r0", rowText(&s, 0, &buf)); // untouched
    try std.testing.expectEqualStrings("r2", rowText(&s, 1, &buf));
    try std.testing.expectEqualStrings("r3", rowText(&s, 2, &buf));
    try std.testing.expectEqualStrings("", rowText(&s, 3, &buf)); // blanked
    try std.testing.expectEqualStrings("r4", rowText(&s, 4, &buf)); // untouched
}

test "region scrolling does not pollute scrollback" {
    var s = try Screen.initScrollback(std.testing.allocator, 6, 4, 16);
    defer s.deinit();

    feed(&s, "\x1b[1;3r"); // region is rows 1..3
    feed(&s, "\x1b[3;1H\n\n\n\n");
    try std.testing.expectEqual(@as(usize, 0), s.grid.historyLen());
}

test "reverse index scrolls the region down at its top" {
    var s = try Screen.init(std.testing.allocator, 6, 4);
    defer s.deinit();

    feed(&s, "\x1b[1;1Ha\x1b[2;1Hb\x1b[3;1Hc");
    feed(&s, "\x1b[1;1H\x1bM"); // RI at the top margin

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", rowText(&s, 0, &buf));
    try std.testing.expectEqualStrings("a", rowText(&s, 1, &buf));
    try std.testing.expectEqualStrings("b", rowText(&s, 2, &buf));
}

test "insert and delete lines within the region" {
    var s = try Screen.init(std.testing.allocator, 6, 4);
    defer s.deinit();

    feed(&s, "\x1b[1;1Ha\x1b[2;1Hb\x1b[3;1Hc\x1b[4;1Hd");
    feed(&s, "\x1b[2;1H\x1b[L"); // insert a line at row 2

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a", rowText(&s, 0, &buf));
    try std.testing.expectEqualStrings("", rowText(&s, 1, &buf));
    try std.testing.expectEqualStrings("b", rowText(&s, 2, &buf));

    feed(&s, "\x1b[2;1H\x1b[M"); // delete it again
    try std.testing.expectEqualStrings("b", rowText(&s, 1, &buf));
    try std.testing.expectEqualStrings("c", rowText(&s, 2, &buf));
}

test "insert and delete characters shift the line" {
    var s = try Screen.init(std.testing.allocator, 8, 2);
    defer s.deinit();

    feed(&s, "abcdef\x1b[1;3H\x1b[2@"); // insert 2 blanks before 'c'
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ab  cdef", rowText(&s, 0, &buf));

    feed(&s, "\x1b[1;3H\x1b[2P"); // delete them again
    try std.testing.expectEqualStrings("abcdef", rowText(&s, 0, &buf));
}

test "insert mode shifts instead of overwriting" {
    var s = try Screen.init(std.testing.allocator, 8, 2);
    defer s.deinit();
    feed(&s, "abcd\x1b[1;2H\x1b[4hXY");

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("aXYbcd", rowText(&s, 0, &buf));
}

test "origin mode makes addressing relative to the region" {
    var s = try Screen.init(std.testing.allocator, 6, 6);
    defer s.deinit();

    feed(&s, "\x1b[3;5r"); // region rows 3..5 -> indices 2..4
    feed(&s, "\x1b[?6h"); // DECOM
    feed(&s, "\x1b[1;1HX");

    var buf: [16]u8 = undefined;
    // Row 1 in origin mode is the region's top, index 2.
    try std.testing.expectEqualStrings("X", rowText(&s, 2, &buf));
}

test "REP repeats the last printed character" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();
    feed(&s, "-\x1b[4b");

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("-----", rowText(&s, 0, &buf));
}

test "DECALN fills the screen with E" {
    var s = try Screen.init(std.testing.allocator, 4, 2);
    defer s.deinit();
    feed(&s, "\x1b#8");

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("EEEE", rowText(&s, 0, &buf));
    try std.testing.expectEqualStrings("EEEE", rowText(&s, 1, &buf));
}

test "save and restore cursor round-trips position and pen" {
    var s = try Screen.init(std.testing.allocator, 10, 4);
    defer s.deinit();

    feed(&s, "\x1b[2;4H\x1b[31m\x1b7"); // DECSC
    feed(&s, "\x1b[1;1H\x1b[0m");
    feed(&s, "\x1b8"); // DECRC

    try std.testing.expectEqual(@as(u32, 1), s.cursor_y);
    try std.testing.expectEqual(@as(u32, 3), s.cursor_x);
    try std.testing.expect(s.pen.fg.eql(Color.indexed(1)));
}

test "device attributes and cursor position report" {
    var s = try Screen.init(std.testing.allocator, 20, 5);
    defer s.deinit();

    var sink = Sink{};
    s.reply = .{ .ctx = &sink, .write = Sink.write };

    feed(&s, "\x1b[c");
    try std.testing.expectEqualStrings("\x1b[?62;22c", sink.got());

    sink.len = 0;
    feed(&s, "\x1b[>c");
    try std.testing.expectEqualStrings("\x1b[>0;10;1c", sink.got());

    sink.len = 0;
    feed(&s, "\x1b[3;7H\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[3;7R", sink.got());

    sink.len = 0;
    feed(&s, "\x1b[5n");
    try std.testing.expectEqualStrings("\x1b[0n", sink.got());
}

test "private-marker sequences are not mistaken for their unmarked namesakes" {
    // Taken verbatim from a capture of Claude Code's output. Every one of these
    // shares a final byte with a standard sequence, and treating them alike
    // corrupted state rather than merely being ignored.
    var s = try Screen.init(std.testing.allocator, 20, 5);
    defer s.deinit();

    var sink = Sink{};
    s.reply = .{ .ctx = &sink, .write = Sink.write };

    // XTMODKEYS. Was read as SGR 4 + SGR 2, underlining and dimming everything
    // that followed.
    feed(&s, "\x1b[>4;2mX");
    const st = s.styles.get(s.grid.at(0, 0).style);
    try std.testing.expectEqual(cellmod.Underline.none, st.attrs.underline);
    try std.testing.expect(!st.attrs.dim);

    // CSI u keyboard protocol push/pop. Was read as CSI u, restoring the cursor.
    feed(&s, "\x1b[3;8H");
    feed(&s, "\x1b[>1u\x1b[<u");
    try std.testing.expectEqual(@as(u32, 2), s.cursor_y);
    try std.testing.expectEqual(@as(u32, 7), s.cursor_x);

    // XTVERSION must not be answered — a reply here would be a fixed string, but
    // the query also must not be mistaken for anything else.
    sink.len = 0;
    feed(&s, "\x1b[>0q");
    try std.testing.expectEqual(@as(usize, 0), sink.len);

    // DA2 still works, and is the one private-marker query we do answer.
    feed(&s, "\x1b[>c");
    try std.testing.expectEqualStrings("\x1b[>0;10;1c", sink.got());
}

test "DECDSR private status queries go unanswered" {
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();

    var sink = Sink{};
    s.reply = .{ .ctx = &sink, .write = Sink.write };

    feed(&s, "\x1b[?6n");
    try std.testing.expectEqual(@as(usize, 0), sink.len);
}

test "application cursor keys and bracketed paste modes are tracked" {
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();

    feed(&s, "\x1b[?1h\x1b[?2004h");
    try std.testing.expect(s.modes.app_cursor);
    try std.testing.expect(s.modes.bracketed_paste);

    feed(&s, "\x1b[?1l\x1b[?2004l");
    try std.testing.expect(!s.modes.app_cursor);
    try std.testing.expect(!s.modes.bracketed_paste);
}

test "OSC 4 redefines palette entries, and 104 puts them back" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();

    feed(&s, "\x1b]4;1;#ff0000;2;rgb:00/ff/00\x1b\\");
    try std.testing.expect(s.theme.palette[1].eq(Rgb.rgb(255, 0, 0)));
    try std.testing.expect(s.theme.palette[2].eq(Rgb.rgb(0, 255, 0)));

    // Text printed *before* the change resolves through the palette, so it moves
    // with it — that is the point of storing the index rather than the pixels.
    feed(&s, "\x1b[31mred");
    const cell_style = s.styles.get(s.grid.at(0, 0).style);
    try std.testing.expect(cell_style.fg.eql(Color.indexed(1)));
    try std.testing.expect(s.theme.resolve(cell_style.fg, .fg).eq(Rgb.rgb(255, 0, 0)));

    feed(&s, "\x1b]104;1\x1b\\");
    try std.testing.expect(s.theme.palette[1].eq(thememod.default_ansi16[1]));
    try std.testing.expect(s.theme.palette[2].eq(Rgb.rgb(0, 255, 0))); // untouched

    feed(&s, "\x1b]104\x1b\\"); // no list: everything
    try std.testing.expect(s.theme.palette[2].eq(thememod.default_ansi16[2]));
}

test "OSC 10/11/12 set the dynamic colours, and 110-112 reset them" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();

    feed(&s, "\x1b]10;#010203\x1b\\\x1b]11;#040506\x1b\\\x1b]12;#070809\x1b\\");
    try std.testing.expect(s.theme.fg.eq(Rgb.rgb(1, 2, 3)));
    try std.testing.expect(s.theme.bg.eq(Rgb.rgb(4, 5, 6)));
    try std.testing.expect(s.theme.cursor.eq(Rgb.rgb(7, 8, 9)));

    // xterm's chained form: 10 with several arguments walks fg, bg, cursor.
    feed(&s, "\x1b]10;#111111;#222222\x1b\\");
    try std.testing.expect(s.theme.fg.eq(Rgb.rgb(0x11, 0x11, 0x11)));
    try std.testing.expect(s.theme.bg.eq(Rgb.rgb(0x22, 0x22, 0x22)));

    feed(&s, "\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\");
    try std.testing.expect(s.theme.fg.eq(thememod.default_fg));
    try std.testing.expect(s.theme.bg.eq(thememod.default_bg));
    try std.testing.expect(s.theme.cursor.eq(thememod.default_cursor));
}

test "colour queries go unanswered" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();

    var sink = Sink{};
    s.reply = .{ .ctx = &sink, .write = Sink.write };

    // Answering would let output read back state it just wrote. It is a channel with
    // no upside, exactly like the title query.
    feed(&s, "\x1b]4;1;?\x1b\\\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b]12;?\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), sink.len);
    // ...and a query must not corrupt the colour it asked about.
    try std.testing.expect(s.theme.palette[1].eq(thememod.default_ansi16[1]));
    try std.testing.expect(s.theme.fg.eq(thememod.default_fg));
}

test "OSC 8 marks printed cells, and an empty URI ends the run" {
    var s = try Screen.init(std.testing.allocator, 20, 2);
    defer s.deinit();

    feed(&s, "a\x1b]8;;https://example.com/x\x1b\\link\x1b]8;;\x1b\\b");

    const row = s.grid.line(s.grid.screenTop()).cells;
    const idOf = struct {
        fn f(scr: *const Screen, cell: Cell) u16 {
            return scr.styles.get(cell.style).hyperlink;
        }
    }.f;

    try std.testing.expectEqual(@as(u16, 0), idOf(&s, row[0])); // 'a', before
    const id = idOf(&s, row[1]);
    try std.testing.expect(id != 0);
    for (1..5) |x| try std.testing.expectEqual(id, idOf(&s, row[x])); // "link"
    try std.testing.expectEqual(@as(u16, 0), idOf(&s, row[5])); // 'b', after

    try std.testing.expectEqualStrings("https://example.com/x", s.links.get(id));
}

test "hyperlinkAt returns the whole run, following a soft wrap" {
    var s = try Screen.init(std.testing.allocator, 6, 3);
    defer s.deinit();

    // "abcdefgh" wraps after 6 columns; the whole thing is one hyperlink.
    feed(&s, "\x1b]8;;https://example.com/\x1b\\abcdefgh\x1b]8;;\x1b\\");

    const top = s.grid.screenTop();
    const hit = s.hyperlinkAt(.{ .line = top, .x = 3 }) orelse
        return error.NoHyperlink;
    try std.testing.expectEqual(top, hit.span.start.line);
    try std.testing.expectEqual(@as(u32, 0), hit.span.start.x);
    try std.testing.expectEqual(top + 1, hit.span.end.line);
    try std.testing.expectEqual(@as(u32, 1), hit.span.end.x);
    try std.testing.expectEqualStrings("https://example.com/", s.links.get(hit.id));

    // Reachable from the continuation row too.
    const from_second = s.hyperlinkAt(.{ .line = top + 1, .x = 0 }) orelse
        return error.NoHyperlink;
    try std.testing.expectEqual(hit.id, from_second.id);

    // Not on a plain cell.
    feed(&s, "\r\nplain");
    try std.testing.expect(s.hyperlinkAt(.{ .line = top + 2, .x = 1 }) == null);
}

test "OSC 8 refuses schemes the launcher would not open" {
    var s = try Screen.init(std.testing.allocator, 20, 2);
    defer s.deinit();

    // An underlined, clickable `javascript:` link would be a promise we must not
    // make: the allowlist has to hold whether the URI arrived as text or as OSC 8.
    for ([_][]const u8{
        "\x1b]8;;javascript:alert(1)\x1b\\",
        "\x1b]8;;data:text/html,x\x1b\\",
        "\x1b]8;;vscode://file/etc/passwd\x1b\\",
        // A raw control byte inside the URI. Our OSC collector is permissive —
        // it takes everything up to BEL or ST — so this really does reach the
        // handler, unlike an ESC, which ends the string before it gets here.
        "\x1b]8;;https://x/\x01y\x1b\\",
    }) |seq| {
        feed(&s, seq);
        feed(&s, "z");
        try std.testing.expectEqual(@as(u16, 0), s.pen.hyperlink);
    }
    // Nothing was stored: only the reserved slot 0 exists.
    try std.testing.expectEqual(@as(usize, 1), s.links.count());
}

test "hyperlinks referenced only from scrollback survive collection" {
    var s = try Screen.initScrollback(std.testing.allocator, 8, 2, 16);
    defer s.deinit();
    s.gc_links.trigger = 1;
    s.gc_styles.trigger = 1;

    feed(&s, "\x1b]8;;https://kept/\x1b\\keep\x1b]8;;\x1b\\\r\n");
    // Scroll it off the visible screen but not out of the ring.
    feed(&s, "x\r\ny\r\n");

    // A link nothing references any more.
    feed(&s, "\x1b]8;;https://gone/\x1b\\g\x1b]8;;\x1b\\");
    feed(&s, "\x1b[2K\r"); // erase the line holding it
    s.collectGarbage();

    var kept = false;
    var gone = false;
    for (1..s.links.count()) |i| {
        const uri = s.links.get(@intCast(i));
        if (std.mem.eql(u8, uri, "https://kept/")) kept = true;
        if (std.mem.eql(u8, uri, "https://gone/")) gone = true;
    }
    try std.testing.expect(kept);
    try std.testing.expect(!gone);

    // And the surviving cells still resolve to the right URI.
    const hit = s.hyperlinkAt(.{ .line = 0, .x = 0 }) orelse return error.NoHyperlink;
    try std.testing.expectEqualStrings("https://kept/", s.links.get(hit.id));
}

test "CSI u keyboard flags push, pop, set and report" {
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();

    var sink = Sink{};
    s.reply = .{ .ctx = &sink, .write = Sink.write };

    // Nothing asked for: legacy, and the query says so. An application reads this and
    // knows to stay on its legacy encodings.
    feed(&s, "\x1b[?u");
    try std.testing.expectEqualStrings("\x1b[?0u", sink.got());

    // Push, as an application does on entry.
    sink.len = 0;
    feed(&s, "\x1b[>1u\x1b[?u");
    try std.testing.expectEqualStrings("\x1b[?1u", sink.got());

    // Unsupported bits are masked off, and the query reports what actually took
    // effect — claiming a flag we do not implement is what would break applications.
    sink.len = 0;
    feed(&s, "\x1b[>31u\x1b[?u");
    try std.testing.expectEqualStrings("\x1b[?1u", sink.got());

    // Pop twice, back to legacy.
    sink.len = 0;
    feed(&s, "\x1b[<2u\x1b[?u");
    try std.testing.expectEqualStrings("\x1b[?0u", sink.got());
    try std.testing.expectEqual(@as(usize, 0), s.csi_u_depth);

    // `CSI = flags ; mode u`: 1 replaces, 2 sets bits, 3 clears them.
    feed(&s, "\x1b[=1;1u");
    try std.testing.expectEqual(@as(u5, 1), s.modes.csi_u_flags);
    feed(&s, "\x1b[=1;3u");
    try std.testing.expectEqual(@as(u5, 0), s.modes.csi_u_flags);
    feed(&s, "\x1b[=1;2u");
    try std.testing.expectEqual(@as(u5, 1), s.modes.csi_u_flags);
}

test "popping an empty stack and pushing past the limit stay bounded" {
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();

    // A pop with nothing pushed must not underflow.
    feed(&s, "\x1b[<u\x1b[<9u");
    try std.testing.expectEqual(@as(usize, 0), s.csi_u_depth);

    // Pushing in a loop must not grow anything. The mode still takes effect at the
    // ceiling — dropping the request would leave the application encoding for a mode
    // that is not active.
    for (0..csi_u_stack_max + 8) |_| feed(&s, "\x1b[>1u");
    try std.testing.expectEqual(csi_u_stack_max, s.csi_u_depth);
    try std.testing.expectEqual(@as(u5, 1), s.modes.csi_u_flags);
}

test "the keyboard mode belongs to its screen buffer" {
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();

    // A full-screen application enables the protocol on the alternate screen...
    feed(&s, "\x1b[?1049h\x1b[>1u");
    try std.testing.expectEqual(@as(u5, 1), s.modes.csi_u_flags);

    // ...and dies without popping. Leaving the alternate screen must restore what the
    // shell had, or the shell would be left with an encoding it never asked for — and
    // in particular one where its keys arrive as escape sequences.
    feed(&s, "\x1b[?1049l");
    try std.testing.expectEqual(@as(u5, 0), s.modes.csi_u_flags);

    // And going back finds the application's mode again.
    feed(&s, "\x1b[?1049h");
    try std.testing.expectEqual(@as(u5, 1), s.modes.csi_u_flags);
}

test "RIS clears the keyboard mode" {
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();
    feed(&s, "\x1b[>1u");
    feed(&s, "\x1bc");
    try std.testing.expectEqual(@as(u5, 0), s.modes.csi_u_flags);
    try std.testing.expectEqual(@as(usize, 0), s.csi_u_depth);
}

test "mouse tracking modes are independent bits" {
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();

    try std.testing.expectEqual(mousemod.Mode.off, s.mouse.mode());

    // What nvim sends: button tracking, drag tracking, SGR encoding.
    feed(&s, "\x1b[?1000h\x1b[?1002h\x1b[?1006h");
    try std.testing.expectEqual(mousemod.Mode.drag, s.mouse.mode());
    try std.testing.expectEqual(mousemod.Encoding.sgr, s.mouse.encoding());

    // Adding any-motion tracking wins while it is set...
    feed(&s, "\x1b[?1003h");
    try std.testing.expectEqual(mousemod.Mode.any, s.mouse.mode());
    // ...and dropping it falls back to what is still enabled rather than to off.
    feed(&s, "\x1b[?1003l");
    try std.testing.expectEqual(mousemod.Mode.drag, s.mouse.mode());
    feed(&s, "\x1b[?1002l");
    try std.testing.expectEqual(mousemod.Mode.button, s.mouse.mode());

    feed(&s, "\x1b[?1000l\x1b[?1006l");
    try std.testing.expectEqual(mousemod.Mode.off, s.mouse.mode());
    try std.testing.expectEqual(mousemod.Encoding.normal, s.mouse.encoding());
}

test "x10 mouse mode and alternate scroll are tracked, and RIS clears them" {
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();

    // Alternate scroll defaults on, as in xterm.
    try std.testing.expect(s.modes.alternate_scroll);
    feed(&s, "\x1b[?1007l");
    try std.testing.expect(!s.modes.alternate_scroll);

    feed(&s, "\x1b[?9h");
    try std.testing.expectEqual(mousemod.Mode.x10, s.mouse.mode());

    feed(&s, "\x1bc");
    try std.testing.expectEqual(mousemod.Mode.off, s.mouse.mode());
    try std.testing.expect(s.modes.alternate_scroll);
}

test "synchronized output mode is tracked" {
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();
    feed(&s, "\x1b[?2026h");
    try std.testing.expect(s.sync_output);
    feed(&s, "\x1b[?2026l");
    try std.testing.expect(!s.sync_output);
}

test "double-width characters occupy two cells with a spacer" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();
    feed(&s, "a日b");

    try std.testing.expectEqual(@as(u32, 'a'), s.grid.at(0, 0).content);
    try std.testing.expectEqual(@as(u21, '日'), @as(u21, @intCast(s.grid.at(1, 0).content)));
    try std.testing.expectEqual(@as(u2, 1), s.grid.at(1, 0).wide);
    // The spacer holds no content of its own.
    try std.testing.expectEqual(@as(u2, 2), s.grid.at(2, 0).wide);
    try std.testing.expectEqual(@as(u32, 'b'), s.grid.at(3, 0).content);
    // 'a' + 2 columns + 'b' == 4
    try std.testing.expectEqual(@as(u32, 4), s.cursor_x);
}

test "overwriting half of a wide pair clears the other half" {
    var s = try Screen.init(std.testing.allocator, 8, 2);
    defer s.deinit();

    feed(&s, "日");
    // Overwrite the lead: the orphaned spacer must be cleared too.
    feed(&s, "\x1b[1;1Hx");
    try std.testing.expectEqual(@as(u32, 'x'), s.grid.at(0, 0).content);
    try std.testing.expectEqual(@as(u2, 0), s.grid.at(1, 0).wide);

    feed(&s, "\x1b[1;1H日");
    // Now overwrite the spacer instead; the lead must go.
    feed(&s, "\x1b[1;2Hy");
    try std.testing.expectEqual(@as(u32, 'y'), s.grid.at(1, 0).content);
    try std.testing.expectEqual(@as(u2, 0), s.grid.at(0, 0).wide);
    try std.testing.expect(s.grid.at(0, 0).isBlank());
}

test "a wide character wraps whole rather than splitting at the edge" {
    var s = try Screen.init(std.testing.allocator, 5, 3);
    defer s.deinit();

    // Four narrow characters leave exactly one free column, too few for 日.
    feed(&s, "abcd日");

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", rowText(&s, 0, &buf));
    // It moved to the next row rather than straddling the boundary.
    try std.testing.expectEqual(@as(u2, 1), s.grid.at(0, 1).wide);
    try std.testing.expectEqual(@as(u2, 2), s.grid.at(1, 1).wide);
    try std.testing.expect(s.grid.rowMeta(0).wrapped);
}

test "combining marks attach to the base cell without taking a column" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();
    feed(&s, "e\u{0301}x"); // e + combining acute, then x

    // 'e' and its accent share one cell, so 'x' is at column 1.
    try std.testing.expect(s.grid.at(0, 0).grapheme);
    try std.testing.expectEqual(@as(u32, 'x'), s.grid.at(1, 0).content);
    try std.testing.expectEqual(@as(u32, 2), s.cursor_x);

    const cluster = s.graphemes.get(s.grid.at(0, 0).content);
    try std.testing.expectEqual(@as(usize, 2), cluster.len);
    try std.testing.expectEqual(@as(u21, 'e'), cluster[0]);
    try std.testing.expectEqual(@as(u21, 0x0301), cluster[1]);
}

test "a variation selector widens its base to emoji presentation" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();
    // U+26A0 is one column bare; with VS16 the ecosystem treats it as two, and a
    // terminal that disagrees misaligns every framed TUI.
    feed(&s, "\u{26A0}\u{FE0F}x");

    try std.testing.expectEqual(@as(u2, 1), s.grid.at(0, 0).wide);
    try std.testing.expectEqual(@as(u2, 2), s.grid.at(1, 0).wide);
    try std.testing.expectEqual(@as(u32, 'x'), s.grid.at(2, 0).content);
    try std.testing.expectEqual(@as(u32, 3), s.cursor_x);
}

test "a run of combining marks is capped rather than growing without bound" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();

    feed(&s, "e");
    var i: usize = 0;
    while (i < 500) : (i += 1) feed(&s, "\u{0301}");

    const cluster = s.graphemes.get(s.grid.at(0, 0).content);
    try std.testing.expectEqual(cellmod.GraphemeTable.max_len, cluster.len);
    // And layout is unaffected.
    try std.testing.expectEqual(@as(u32, 1), s.cursor_x);
}

test "box frames stay aligned across mixed-width content" {
    // This is the reported Claude Code symptom: a framed UI whose right border
    // drifted per row depending on the emoji and CJK it contained.
    var s = try Screen.init(std.testing.allocator, 12, 4);
    defer s.deinit();

    feed(&s, "|abcdefghij|\r\n"); // 10 narrow
    feed(&s, "|日本語abcd|\r\n"); // 3 wide + 4 narrow == 10
    feed(&s, "|e\u{0301}bcdefghij|"); // combining mark takes no column

    // Every closing bar must land in the same column.
    for (0..3) |y| {
        try std.testing.expectEqual(
            @as(u32, '|'),
            s.grid.at(11, @intCast(y)).content,
        );
    }
}

test "the session's first grapheme cluster survives a reflow" {
    // Cluster indices live in Cell.content, so index 0 — the first cluster of the
    // session — is bit-identical to Cell.empty, and index 32 to a space. Any
    // blank-detection that ignores the `grapheme` flag trims them off the end of a
    // logical line, silently deleting the character.
    var s = try Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();

    feed(&s, "abcde\u{0301}"); // trailing e-with-acute is cluster index 0
    try std.testing.expect(s.grid.at(4, 0).grapheme);
    try std.testing.expectEqual(@as(u32, 0), s.grid.at(4, 0).content);

    try s.resize(10, 3);
    try s.resize(6, 3);
    try s.resize(10, 3);

    // Still five columns of content, the last one still the cluster.
    try std.testing.expect(s.grid.at(4, 0).grapheme);
    const cluster = s.graphemes.get(s.grid.at(4, 0).content);
    try std.testing.expectEqual(@as(u21, 'e'), cluster[0]);
    try std.testing.expectEqual(@as(u21, 0x0301), cluster[1]);
}

test "a wide pair survives being reflowed twice" {
    // The arithmetic row count is only valid for lines with no wide character, so the
    // `has_wide` marker has to survive reflow itself. One resize would not catch a
    // marker that reflow forgets to carry: the *second* one would then take the fast
    // path on a line that needs the walk, and mis-wrap silently.
    var s = try Screen.initScrollback(std.testing.allocator, 8, 3, 16);
    defer s.deinit();

    feed(&s, "ab日cd日ef");
    try s.resize(6, 3);
    try s.resize(5, 3);
    try s.resize(9, 3);

    // Every wide cell still has its spacer, and no spacer is orphaned.
    var line: usize = 0;
    var pairs: usize = 0;
    while (line < s.grid.count) : (line += 1) {
        const cells = s.grid.line(line).cells;
        for (cells, 0..) |cell, x| {
            if (cell.wide == 1) {
                pairs += 1;
                try std.testing.expect(x + 1 < cells.len);
                try std.testing.expectEqual(@as(u2, 2), cells[x + 1].wide);
            }
            if (cell.wide == 2) {
                try std.testing.expect(x > 0);
                try std.testing.expectEqual(@as(u2, 1), cells[x - 1].wide);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), pairs);
}

test "reflow keeps double-width pairs intact across a row break" {
    var s = try Screen.init(std.testing.allocator, 8, 3);
    defer s.deinit();
    feed(&s, "ab日本語");

    // At width 5 the pairs cannot split: 'ab' + 日 fills 4 of 5, so 本 moves down.
    try s.resize(5, 4);

    var y: u32 = 0;
    while (y < s.grid.rows) : (y += 1) {
        var x: u32 = 0;
        while (x < s.grid.cols) : (x += 1) {
            const cell = s.grid.at(x, y);
            if (cell.wide == 1) {
                // A lead must never sit in the final column, and its spacer must
                // immediately follow.
                try std.testing.expect(x + 1 < s.grid.cols);
                try std.testing.expectEqual(@as(u2, 2), s.grid.at(x + 1, y).wide);
            }
            if (cell.wide == 2) {
                try std.testing.expect(x > 0);
                try std.testing.expectEqual(@as(u2, 1), s.grid.at(x - 1, y).wide);
            }
        }
    }
}

test "style ids are reclaimed rather than exhausting the table" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();
    s.gc_styles = Gc.init(64); // collect early so the test stays quick

    // Overwrite one cell with a thousand distinct truecolor styles. Only the last
    // is referenced, so the table must not grow without bound — this is the
    // `lolcat` case that used to degrade the session permanently.
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        var buf: [40]u8 = undefined;
        const seq = try std.fmt.bufPrint(
            &buf,
            "\x1b[1;1H\x1b[38;2;{d};{d};7mX",
            .{ i % 256, (i / 256) % 256 },
        );
        feed(&s, seq);
    }

    try std.testing.expect(s.styles.list.items.len < 300);
    // The most recent style is intact, so collection did not corrupt live data.
    const st = s.styles.get(s.grid.at(0, 0).style);
    try std.testing.expect(st.fg.eql(Color.rgb(999 % 256, (999 / 256) % 256, 7)));
}

test "styles referenced only from scrollback survive collection" {
    var s = try Screen.initScrollback(std.testing.allocator, 8, 2, 16);
    defer s.deinit();

    // Push a red line into history, where nothing on screen refers to its style.
    feed(&s, "\x1b[31mRED\r\n\x1b[0mx\r\ny\r\nz");
    try std.testing.expect(s.grid.historyLen() > 0);

    s.gc_styles = Gc.init(4);
    feed(&s, "\x1b[32mG"); // triggers collection

    // Find the history line holding "RED" and check it is still red.
    var found = false;
    var line: usize = 0;
    while (line < s.grid.count) : (line += 1) {
        const cells = s.grid.line(line).cells;
        if (cells[0].content != 'R') continue;
        found = true;
        try std.testing.expect(s.styles.get(cells[0].style).fg.eql(Color.indexed(1)));
    }
    try std.testing.expect(found);
}

test "grapheme clusters are reclaimed but live ones survive" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();
    s.gc_graphemes = Gc.init(32);
    s.gc_styles = Gc.init(32);

    // Each pass writes a fresh cluster into the same cell, orphaning the previous.
    var i: u32 = 0;
    while (i < 500) : (i += 1) feed(&s, "\x1b[1;1He\u{0301}");

    try std.testing.expect(s.graphemes.spans.items.len < 200);

    const cell = s.grid.at(0, 0);
    try std.testing.expect(cell.grapheme);
    const cluster = s.graphemes.get(cell.content);
    try std.testing.expectEqual(@as(usize, 2), cluster.len);
    try std.testing.expectEqual(@as(u21, 'e'), cluster[0]);
    try std.testing.expectEqual(@as(u21, 0x0301), cluster[1]);
}

test "collection keeps id 0 as the default style" {
    var s = try Screen.init(std.testing.allocator, 6, 2);
    defer s.deinit();
    s.gc_styles = Gc.init(2);

    feed(&s, "\x1b[38;2;1;2;3mA\x1b[38;2;4;5;6mB");
    s.collectGarbage();

    // A zeroed Cell must still mean "default", so id 0 cannot be renumbered.
    try std.testing.expect(s.styles.get(0).fg.eql(Color.default));
    try std.testing.expect(s.styles.get(0).bg.eql(Color.default));
}

test "resize keeps the alternate screen in step with the primary" {
    var s = try Screen.init(std.testing.allocator, 10, 4);
    defer s.deinit();

    feed(&s, "\x1b[?1049h");
    try s.resize(20, 6);

    try std.testing.expectEqual(@as(u32, 20), s.grid.cols);
    try std.testing.expectEqual(@as(u32, 6), s.grid.rows);
    try std.testing.expectEqual(@as(u32, 20), s.other.cols);
    try std.testing.expectEqual(@as(u32, 6), s.other.rows);
    try std.testing.expectEqual(@as(u32, 5), s.margin_bottom);
}

/// Every cell of the ring as UTF-8, one line per row, wrap flags marked.
fn snapshot(gpa: std.mem.Allocator, s: *const Screen) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var line: usize = 0;
    while (line < s.grid.count) : (line += 1) {
        const row = s.grid.line(line);
        for (row.cells) |cell| {
            // Spacers and wrap padding are not content.
            if (cell.wide == 2 or cell.wide == 3) continue;
            if (cell.grapheme) {
                for (s.graphemes.get(cell.content)) |cp| {
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &b) catch continue;
                    try out.appendSlice(gpa, b[0..n]);
                }
            } else if (cell.content != Cell.empty) {
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cell.content), &b) catch continue;
                try out.appendSlice(gpa, b[0..n]);
            } else {
                try out.append(gpa, ' ');
            }
        }
        try out.append(gpa, if (row.wrapped) '|' else '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "reflow round-trips through a range of widths" {
    // The property that matters for the bulk-copy emit path: narrowing and widening
    // back must reproduce the original layout exactly. A per-cell loop and a run copy
    // can disagree on the last run of a row, on a run that spans two source rows, or
    // on the row a line ends on — none of which a single fixed-width test would show.
    const gpa = std.testing.allocator;

    for ([_][]const u8{
        "short",
        "a line of exactly twenty",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "mixed 123 !@# and more text to push past a row",
        // Wide characters included: they take the walker rather than the bulk copy, and
        // they are the case that used to fail. A pair that cannot finish a row moves
        // whole to the next one, and the column it vacates is now marked as *padding*
        // rather than stored as a space — otherwise each resize inserted one more
        // character that was never typed.
        "cjk 日本語 mixed with latin text here",
        "日本語日本語日本語日本語日本語日本語日本語",
        "a日b日c日d日e日f日g日h日i日j日k日l日m",
    }) |text| {
        var s = try Screen.initScrollback(gpa, 20, 4, 64);
        defer s.deinit();
        feed(&s, text);

        const before = try snapshot(gpa, &s);
        defer gpa.free(before);

        // Down and back up, through widths that split runs in different places.
        for ([_]u32{ 19, 13, 7, 3, 11, 20 }) |w| try s.resize(w, 4);

        const after = try snapshot(gpa, &s);
        defer gpa.free(after);
        try std.testing.expectEqualStrings(before, after);
    }
}

test "the bulk-copy path agrees with the walker" {
    // Same content, once as-is and once with a wide character forced into an unrelated
    // row so the whole line takes the walker. Both must lay it out identically.
    const gpa = std.testing.allocator;

    var fast = try Screen.initScrollback(gpa, 16, 3, 32);
    defer fast.deinit();
    var slow = try Screen.initScrollback(gpa, 16, 3, 32);
    defer slow.deinit();

    const text = "abcdefghijklmnopqrstuvwxyz0123456789";
    feed(&fast, text);
    feed(&slow, text);
    // Mark the rows so `slow` cannot take the arithmetic count or the run copy, while
    // its *content* stays identical.
    var line: usize = 0;
    while (line < slow.grid.count) : (line += 1) slow.grid.line(line).has_wide = true;

    for ([_]u32{ 9, 5, 21, 16 }) |w| {
        try fast.resize(w, 3);
        try slow.resize(w, 3);
        // resize() clears the marker on rebuilt rows, so re-arm it every round.
        var l: usize = 0;
        while (l < slow.grid.count) : (l += 1) slow.grid.line(l).has_wide = true;

        const a = try snapshot(gpa, &fast);
        defer gpa.free(a);
        const b = try snapshot(gpa, &slow);
        defer gpa.free(b);
        try std.testing.expectEqualStrings(b, a);
    }
}

test "OSC 7 records the working directory, and refuses a bad one" {
    var s = try Screen.init(std.testing.allocator, 10, 2);
    defer s.deinit();

    try std.testing.expectEqualStrings("", s.cwd());

    feed(&s, "\x1b]7;file://host/home/user/src\x1b\\");
    try std.testing.expectEqualStrings("/home/user/src", s.cwd());

    // A URI, so a directory with a space arrives percent-encoded.
    feed(&s, "\x1b]7;file://host/tmp/a%20b\x1b\\");
    try std.testing.expectEqualStrings("/tmp/a b", s.cwd());

    // Without the scheme, still accepted: some shells emit a bare path.
    feed(&s, "\x1b]7;/plain/path\x1b\\");
    try std.testing.expectEqualStrings("/plain/path", s.cwd());

    // Refused, leaving the previous value: this ends up as another process's starting
    // directory, so a relative or control-laden path is not half-applied.
    for ([_][]const u8{
        "\x1b]7;relative/path\x1b\\",
        "\x1b]7;file://host/bad\x01path\x1b\\",
        "\x1b]7;\x1b\\",
    }) |seq| {
        feed(&s, seq);
        try std.testing.expectEqualStrings("/plain/path", s.cwd());
    }
}
