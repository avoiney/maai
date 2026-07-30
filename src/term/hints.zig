//! Keyboard hint mode: label every link on screen, type a label to act on it.
//!
//! The point is that reaching a URL should never require the mouse. Labels come
//! from the home row outward, so the common case is one keystroke on a key your
//! fingers are already resting on.

const std = @import("std");
const sel = @import("selection.zig");
const urlmod = @import("url.zig");
const Screen = @import("screen.zig").Screen;

/// Cap on labelled links. Two-character labels over this alphabet could address far
/// more, but a screen with hundreds of hints is unusable, and the bound keeps the
/// whole thing on the stack.
pub const max_hints = 128;

/// Home row first, then the rest of the row above and below. Ordered by how little
/// the hand has to move, not alphabetically.
pub const alphabet = "asdfghjklqwertyuiopzxcvbnm";

pub const Hint = struct {
    /// First cell of the match — where the label is drawn.
    at: sel.Point,
    span: urlmod.Span,
    /// OSC 8 id, or 0 when the target is the matched text itself.
    id: u16,
    label: [2]u8 = .{ 0, 0 },
    label_len: u8 = 0,

    pub fn labelText(self: *const Hint) []const u8 {
        return self.label[0..self.label_len];
    }
};

/// Collect and label every link on the visible screen, in reading order.
///
/// Reading order matters to the renderer, which walks cells in the same order and
/// relies on it to find the label for a cell in constant time.
pub fn collect(screen: *const Screen, out: []Hint) usize {
    var n: usize = 0;
    const grid = &screen.grid;
    const top = grid.viewTop();

    var row: u32 = 0;
    rows: while (row < grid.rows) : (row += 1) {
        const line = top + row;
        if (line >= grid.count) break;

        var x: u32 = 0;
        while (x < grid.cols) : (x += 1) {
            if (n == out.len) break :rows;
            const p = sel.Point{ .line = line, .x = x };

            // An OSC 8 hyperlink, but only where its run *starts*: a run continued
            // from the previous row must not get a second label.
            if (screen.hyperlinkAt(p)) |h| {
                if (h.span.start.line == line and h.span.start.x == x) {
                    out[n] = .{ .at = p, .span = h.span, .id = h.id };
                    n += 1;
                    x = skipTo(h.span, line, x);
                }
                continue;
            }

            if (urlmod.startsAt(grid, p)) |span| {
                out[n] = .{ .at = p, .span = span, .id = 0 };
                n += 1;
                // Jumping past the match is what stops `https://a/?u=https://b/`
                // from being labelled twice — the inner scheme is inside a match
                // already accepted.
                x = skipTo(span, line, x);
            }
        }
    }

    assignLabels(out[0..n]);
    return n;
}

/// The last column of `span` on `line`, or the row's end if it continues. Returned
/// as the value the caller's loop counter should take, since the `continue`
/// expression will step past it.
fn skipTo(span: urlmod.Span, line: usize, x: u32) u32 {
    if (span.end.line != line) return std.math.maxInt(u32) - 1;
    return @max(x, span.end.x);
}

fn assignLabels(hints: []Hint) void {
    if (hints.len <= alphabet.len) {
        for (hints, 0..) |*h, i| {
            h.label[0] = alphabet[i];
            h.label_len = 1;
        }
        return;
    }
    // More links than letters: two characters each. Mixing one- and two-character
    // labels would make the first keystroke ambiguous — you could not tell whether
    // to expect a second one.
    for (hints, 0..) |*h, i| {
        h.label[0] = alphabet[i / alphabet.len];
        h.label[1] = alphabet[i % alphabet.len];
        h.label_len = 2;
    }
}

/// How a typed prefix relates to the labels on screen.
pub const Match = union(enum) {
    /// Exactly one label, fully typed.
    hit: usize,
    /// A prefix of at least one label; keep reading keys.
    partial,
    /// Nothing matches; leave hint mode.
    miss,
};

pub fn match(hints: []const Hint, typed: []const u8) Match {
    var candidates: usize = 0;
    var exact: ?usize = null;
    for (hints, 0..) |*h, i| {
        const label = h.labelText();
        if (typed.len > label.len) continue;
        if (!std.mem.eql(u8, label[0..typed.len], typed)) continue;
        candidates += 1;
        if (typed.len == label.len) exact = i;
    }
    if (candidates == 0) return .miss;
    if (exact) |i| if (candidates == 1) return .{ .hit = i };
    return .partial;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const parser = @import("../vt/parser.zig");

fn feed(s: *Screen, bytes: []const u8) void {
    var p = parser.Parser(Screen).init(s);
    p.feed(bytes);
}

test "every visible link gets one label, in reading order" {
    var s = try Screen.init(testing.allocator, 40, 4);
    defer s.deinit();

    feed(&s, "see https://a.example/ and https://b.example/\r\n");
    feed(&s, "\x1b]8;;https://c.example/\x1b\\click me\x1b]8;;\x1b\\\r\n");

    var buf: [max_hints]Hint = undefined;
    const n = collect(&s, &buf);
    try testing.expectEqual(@as(usize, 3), n);

    // Labels are handed out in reading order, from the home row.
    try testing.expectEqualStrings("a", buf[0].labelText());
    try testing.expectEqualStrings("s", buf[1].labelText());
    try testing.expectEqualStrings("d", buf[2].labelText());

    // First two are plain text, third is the OSC 8 one.
    try testing.expectEqual(@as(u16, 0), buf[0].id);
    try testing.expectEqual(@as(u16, 0), buf[1].id);
    try testing.expect(buf[2].id != 0);
    try testing.expectEqualStrings("https://c.example/", s.links.get(buf[2].id));

    // The label sits on the first cell of each match.
    try testing.expectEqual(@as(u32, 4), buf[0].at.x);
    try testing.expectEqual(@as(u32, 27), buf[1].at.x);
    try testing.expectEqual(@as(u32, 0), buf[2].at.x);
}

test "a nested scheme is not labelled twice" {
    var s = try Screen.init(testing.allocator, 60, 2);
    defer s.deinit();
    feed(&s, "https://host/r?u=https://other/");

    var buf: [max_hints]Hint = undefined;
    try testing.expectEqual(@as(usize, 1), collect(&s, &buf));
}

test "an OSC 8 run spanning a soft wrap is labelled once" {
    var s = try Screen.init(testing.allocator, 6, 3);
    defer s.deinit();
    feed(&s, "\x1b]8;;https://example.com/\x1b\\abcdefgh\x1b]8;;\x1b\\");

    var buf: [max_hints]Hint = undefined;
    const n = collect(&s, &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, 0), buf[0].at.x);
}

test "labels grow to two characters only when they have to" {
    var one: [alphabet.len]Hint = undefined;
    @memset(&one, .{
        .at = .{ .line = 0, .x = 0 },
        .span = .{ .start = .{ .line = 0, .x = 0 }, .end = .{ .line = 0, .x = 0 } },
        .id = 0,
    });
    assignLabels(&one);
    try testing.expectEqual(@as(u8, 1), one[alphabet.len - 1].label_len);

    var two: [alphabet.len + 1]Hint = undefined;
    @memset(&two, one[0]);
    assignLabels(&two);
    // All of them, not just the overflow: a mix would make the first keystroke
    // ambiguous.
    for (two) |h| try testing.expectEqual(@as(u8, 2), h.label_len);
    try testing.expectEqualStrings("aa", two[0].labelText());
    try testing.expectEqualStrings("as", two[1].labelText());
}

test "matching a typed prefix" {
    var buf: [3]Hint = undefined;
    @memset(&buf, .{
        .at = .{ .line = 0, .x = 0 },
        .span = .{ .start = .{ .line = 0, .x = 0 }, .end = .{ .line = 0, .x = 0 } },
        .id = 0,
    });
    assignLabels(&buf); // a, s, d

    try testing.expectEqual(@as(usize, 0), match(&buf, "a").hit);
    try testing.expectEqual(@as(usize, 2), match(&buf, "d").hit);
    try testing.expect(match(&buf, "q") == .miss);
    try testing.expect(match(&buf, "") == .partial);

    var wide: [alphabet.len + 1]Hint = undefined;
    @memset(&wide, buf[0]);
    assignLabels(&wide);
    try testing.expect(match(&wide, "a") == .partial);
    try testing.expectEqual(@as(usize, 1), match(&wide, "as").hit);
    try testing.expect(match(&wide, "sd") == .miss);
}
