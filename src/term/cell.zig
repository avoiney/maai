//! Cell, style interning, and the colour palette.
//!
//! Cell packing is fixed deliberately early (PLAN.md §4) because it drives both
//! memory footprint and render-loop cache behaviour, and widening it later means
//! touching every file that reads the grid.

const std = @import("std");

pub const Rgb = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(r: u8, g: u8, b: u8) Rgb {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn eq(self: Rgb, other: Rgb) bool {
        return @as(u32, @bitCast(self)) == @as(u32, @bitCast(other));
    }
};

pub const Underline = enum(u3) { none, single, double, curly, dotted, dashed };

pub const Attrs = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strike: bool = false,
    blink: bool = false,
    underline: Underline = .none,
    _pad: u6 = 0,
};

/// Interned, so cells store a 16-bit id rather than ~14 bytes of colour and
/// attributes. A typical screen uses well under 100 distinct styles.
pub const Style = struct {
    fg: Rgb,
    bg: Rgb,
    ul: Rgb,
    attrs: Attrs = .{},
    /// Index into `LinkTable` (OSC 8). 0 = none.
    ///
    /// Riding along in the style rather than in the `Cell` is what keeps a cell at 8
    /// bytes: a hyperlink run has uniform styling in practice, so interning collapses
    /// it to one entry instead of one per cell.
    hyperlink: u16 = 0,

    pub const default: Style = .{
        .fg = default_fg,
        .bg = default_bg,
        .ul = default_fg,
    };
};

/// 8 bytes. At 2560x1440 with ~10x19px cells a screen is ~19k cells; 10k lines of
/// scrollback (phase 2) is ~2.6M cells ≈ 21 MB.
pub const Cell = packed struct(u64) {
    /// A codepoint, or an index into the grapheme side table when `grapheme` is
    /// set. `empty` means nothing has been written here.
    content: u32 = empty,
    style: u16 = 0,
    /// 0 = narrow, 1 = leading half of a wide glyph, 2 = trailing spacer.
    wide: u2 = 0,
    grapheme: bool = false,
    dirty: bool = false,
    _pad: u12 = 0,

    pub const empty: u32 = 0;

    pub fn isBlank(self: Cell) bool {
        // When `grapheme` is set, `content` is an index into the cluster table, not
        // a codepoint — index 0 would otherwise be mistaken for `empty` and index
        // 32 for a space.
        if (self.grapheme) return false;
        return self.content == empty or self.content == ' ';
    }
};

comptime {
    std.debug.assert(@sizeOf(Cell) == 8);
}

/// Live-set thresholds at which `Screen` compacts its tables. Chosen well below the
/// 65535 id ceiling so there is room to keep working while the scan runs.
pub const style_gc_threshold: usize = 32768;
pub const grapheme_gc_threshold: usize = 16384;
/// Links are far rarer than styles, so this collects long before the id space or the
/// byte budget runs out.
pub const link_gc_threshold: usize = 4096;

/// Maps Style -> id, with a dense array for id -> Style.
///
/// Ids are allocated append-only; unreferenced ones are reclaimed by
/// `Screen.collectGarbage`, which is the only thing with a view of every cell.
pub const StyleTable = struct {
    list: std.ArrayList(Style) = .empty,
    map: std.AutoHashMapUnmanaged(Style, u16) = .empty,

    pub fn init(self: *StyleTable, gpa: std.mem.Allocator) !void {
        self.* = .{};
        // id 0 is always the default style, so a zeroed Cell is already valid.
        _ = try self.intern(gpa, Style.default);
    }

    pub fn deinit(self: *StyleTable, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
        self.map.deinit(gpa);
    }

    pub fn intern(self: *StyleTable, gpa: std.mem.Allocator, style: Style) !u16 {
        if (self.map.get(style)) |id| return id;
        // Saturate rather than fail: reusing the default style is a cosmetic
        // degradation, whereas erroring out would kill the terminal.
        if (self.list.items.len >= std.math.maxInt(u16)) return 0;
        const id: u16 = @intCast(self.list.items.len);
        try self.list.append(gpa, style);
        try self.map.put(gpa, style, id);
        return id;
    }

    pub fn get(self: *const StyleTable, id: u16) Style {
        if (id >= self.list.items.len) return Style.default;
        return self.list.items[id];
    }

    /// Replace the contents with `styles`, whose order defines the new ids.
    pub fn rebuild(
        self: *StyleTable,
        gpa: std.mem.Allocator,
        styles: []const Style,
    ) !void {
        self.list.clearRetainingCapacity();
        self.map.clearRetainingCapacity();
        try self.list.ensureTotalCapacity(gpa, styles.len);
        for (styles, 0..) |s, i| {
            self.list.appendAssumeCapacity(s);
            try self.map.put(gpa, s, @intCast(i));
        }
    }
};

/// OSC 8 hyperlink targets, interned so a run of linked cells costs one id.
///
/// The URIs come from output, which is untrusted: a process can print a distinct
/// hyperlink per cell. Hence the caps below, and `Screen.collectGarbage` reclaiming
/// entries no surviving style references.
pub const LinkTable = struct {
    /// Longer than any URI worth storing, and it bounds a single OSC 8 payload.
    pub const max_uri_len: usize = 2048;
    /// Total budget for stored URIs. Beyond it, interning fails closed — new links
    /// simply are not links, which degrades cosmetically instead of growing without
    /// bound.
    pub const max_bytes: usize = 1 << 20;

    pub const Span = struct { start: u32, len: u32 };

    data: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    /// URI -> id. Keys are owned copies: `data` reallocates as it grows, so keys
    /// pointing into it would dangle after any append.
    map: std.StringHashMapUnmanaged(u16) = .empty,

    pub fn init(self: *LinkTable, gpa: std.mem.Allocator) !void {
        self.* = .{};
        // Id 0 means "no link", so it holds an empty span and is never handed out.
        try self.spans.append(gpa, .{ .start = 0, .len = 0 });
    }

    pub fn deinit(self: *LinkTable, gpa: std.mem.Allocator) void {
        self.freeKeys(gpa);
        self.data.deinit(gpa);
        self.spans.deinit(gpa);
        self.map.deinit(gpa);
    }

    fn freeKeys(self: *LinkTable, gpa: std.mem.Allocator) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
    }

    /// Intern a URI and return its id, or 0 if it cannot be stored.
    pub fn intern(self: *LinkTable, gpa: std.mem.Allocator, uri: []const u8) u16 {
        if (uri.len == 0 or uri.len > max_uri_len) return 0;
        if (self.map.get(uri)) |id| return id;
        if (self.data.items.len + uri.len > max_bytes) return 0;
        if (self.spans.items.len >= std.math.maxInt(u16)) return 0;

        const start: u32 = @intCast(self.data.items.len);
        self.data.appendSlice(gpa, uri) catch return 0;
        const id: u16 = @intCast(self.spans.items.len);
        self.spans.append(gpa, .{ .start = start, .len = @intCast(uri.len) }) catch {
            self.data.shrinkRetainingCapacity(start);
            return 0;
        };
        const key = gpa.dupe(u8, uri) catch return id; // usable, just not deduped
        self.map.put(gpa, key, id) catch gpa.free(key);
        return id;
    }

    pub fn get(self: *const LinkTable, id: u16) []const u8 {
        if (id == 0 or id >= self.spans.items.len) return "";
        const span = self.spans.items[id];
        return self.data.items[span.start..][0..span.len];
    }

    pub fn count(self: *const LinkTable) usize {
        return self.spans.items.len;
    }

    /// Replace the contents wholesale. `spans` index into `data`, and ids start at 1
    /// — slot 0 is prepended here and stays "no link".
    ///
    /// Takes the compacted bytes rather than a list of slices *on purpose*: the
    /// caller's slices would otherwise point into `self.data`, and copying them back
    /// into that same buffer is an overlapping `@memcpy`. Zig catches it in debug
    /// mode; it would be silent corruption in release.
    pub fn replace(
        self: *LinkTable,
        gpa: std.mem.Allocator,
        data: []const u8,
        spans: []const Span,
    ) !void {
        std.debug.assert(!overlaps(data, self.data.items));

        self.freeKeys(gpa);
        self.map.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();

        try self.data.appendSlice(gpa, data);
        try self.spans.append(gpa, .{ .start = 0, .len = 0 });
        for (spans) |span| {
            const id: u16 = @intCast(self.spans.items.len);
            try self.spans.append(gpa, span);
            const key = try gpa.dupe(u8, data[span.start..][0..span.len]);
            self.map.put(gpa, key, id) catch gpa.free(key);
        }
    }

    fn overlaps(a: []const u8, b: []const u8) bool {
        if (a.len == 0 or b.len == 0) return false;
        return @intFromPtr(a.ptr) < @intFromPtr(b.ptr) + b.len and
            @intFromPtr(b.ptr) < @intFromPtr(a.ptr) + a.len;
    }
};

/// Multi-codepoint grapheme clusters, held out of line so the common
/// single-codepoint cell stays 8 bytes.
///
/// A cell with `grapheme` set stores an index here in `content`.
pub const GraphemeTable = struct {
    /// Hard cap on codepoints per cluster. Combining marks are unbounded in
    /// principle, and a remote process can emit thousands of them against one base
    /// character ("zalgo" text); without a cap that is an unbounded allocation
    /// driven by untrusted input.
    pub const max_len = 8;

    pub const Span = struct { start: u32, len: u8 };

    data: std.ArrayList(u21) = .empty,
    spans: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *GraphemeTable, gpa: std.mem.Allocator) void {
        self.data.deinit(gpa);
        self.spans.deinit(gpa);
    }

    /// Store a cluster and return its index.
    ///
    /// Append-only: extending a cluster writes a new entry rather than editing the
    /// old one, so the previous copy is dead. `Screen.collectGarbage` reclaims both
    /// that waste and clusters whose cells are gone.
    pub fn add(self: *GraphemeTable, gpa: std.mem.Allocator, cps: []const u21) !u32 {
        const n = @min(cps.len, max_len);
        const start: u32 = @intCast(self.data.items.len);
        try self.data.appendSlice(gpa, cps[0..n]);
        const idx: u32 = @intCast(self.spans.items.len);
        try self.spans.append(gpa, .{ .start = start, .len = @intCast(n) });
        return idx;
    }

    pub fn get(self: *const GraphemeTable, idx: u32) []const u21 {
        if (idx >= self.spans.items.len) return &.{};
        const span = self.spans.items[idx];
        return self.data.items[span.start..][0..span.len];
    }

    pub fn clear(self: *GraphemeTable) void {
        self.data.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
    }
};

// ── Default colours ─────────────────────────────────────────────────────────
// A dark nightfox-ish default. Phase 6 replaces these with parsed themes and
// hooks up the ~/.config/.app-theme-flavour watch.

pub const default_fg = Rgb.rgb(0xcd, 0xce, 0xcf);
pub const default_bg = Rgb.rgb(0x19, 0x1a, 0x21);
pub const default_cursor = Rgb.rgb(0x71, 0x9c, 0xd6);
pub const selection_bg = Rgb.rgb(0x2b, 0x3b, 0x51);
pub const selection_fg = Rgb.rgb(0xe4, 0xe4, 0xe5);

pub const ansi16 = [16]Rgb{
    Rgb.rgb(0x39, 0x3b, 0x44), // 0 black
    Rgb.rgb(0xc9, 0x4f, 0x6d), // 1 red
    Rgb.rgb(0x81, 0xb2, 0x9a), // 2 green
    Rgb.rgb(0xdb, 0xc0, 0x74), // 3 yellow
    Rgb.rgb(0x71, 0x9c, 0xd6), // 4 blue
    Rgb.rgb(0x9d, 0x79, 0xd6), // 5 magenta
    Rgb.rgb(0x63, 0xcd, 0xcf), // 6 cyan
    Rgb.rgb(0xdf, 0xdf, 0xe0), // 7 white
    Rgb.rgb(0x57, 0x5b, 0x66), // 8  bright black
    Rgb.rgb(0xd1, 0x69, 0x83), // 9  bright red
    Rgb.rgb(0x8e, 0xbe, 0xa6), // 10 bright green
    Rgb.rgb(0xe0, 0xc9, 0x89), // 11 bright yellow
    Rgb.rgb(0x86, 0xab, 0xdc), // 12 bright blue
    Rgb.rgb(0xba, 0xa1, 0xe2), // 13 bright magenta
    Rgb.rgb(0x7a, 0xd5, 0xd6), // 14 bright cyan
    Rgb.rgb(0xe4, 0xe4, 0xe5), // 15 bright white
};

/// The xterm 256-colour palette: 16 base colours, a 6x6x6 cube, then 24 greys.
pub const palette256: [256]Rgb = blk: {
    var p: [256]Rgb = undefined;
    for (ansi16, 0..) |col, i| p[i] = col;

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

test "cell is 8 bytes and zeroed cell is the default style" {
    const c: Cell = .{};
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Cell));
    try std.testing.expectEqual(@as(u16, 0), c.style);
    try std.testing.expect(c.isBlank());
}

test "style interning dedupes and assigns 0 to default" {
    const gpa = std.testing.allocator;
    var table: StyleTable = undefined;
    try table.init(gpa);
    defer table.deinit(gpa);

    try std.testing.expectEqual(@as(u16, 0), try table.intern(gpa, Style.default));

    var red = Style.default;
    red.fg = ansi16[1];
    const a = try table.intern(gpa, red);
    const b = try table.intern(gpa, red);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != 0);
    try std.testing.expect(table.get(a).fg.eq(ansi16[1]));
}

test "link interning dedupes, reserves 0, and fails closed when full" {
    const gpa = std.testing.allocator;
    var links: LinkTable = undefined;
    try links.init(gpa);
    defer links.deinit(gpa);

    // 0 is "no link" and never handed out.
    try std.testing.expectEqualStrings("", links.get(0));
    try std.testing.expectEqual(@as(u16, 0), links.intern(gpa, ""));

    const a = links.intern(gpa, "https://example.com/one");
    const b = links.intern(gpa, "https://example.com/two");
    try std.testing.expect(a != 0 and b != 0 and a != b);
    try std.testing.expectEqual(a, links.intern(gpa, "https://example.com/one"));
    try std.testing.expectEqualStrings("https://example.com/one", links.get(a));
    try std.testing.expectEqualStrings("https://example.com/two", links.get(b));

    // Oversize URIs are refused rather than truncated: a truncated URI is a
    // different URI.
    var huge: [LinkTable.max_uri_len + 1]u8 = undefined;
    @memset(&huge, 'a');
    try std.testing.expectEqual(@as(u16, 0), links.intern(gpa, &huge));

    // Unknown ids read as no link rather than reading out of bounds.
    try std.testing.expectEqualStrings("", links.get(9999));
}

test "link replace renumbers from 1 and keeps dedup working" {
    const gpa = std.testing.allocator;
    var links: LinkTable = undefined;
    try links.init(gpa);
    defer links.deinit(gpa);

    _ = links.intern(gpa, "https://gone/");
    _ = links.intern(gpa, "https://kept/");

    const kept = "https://kept/";
    try links.replace(gpa, kept, &.{.{ .start = 0, .len = kept.len }});
    try std.testing.expectEqual(@as(usize, 2), links.count()); // slot 0 plus one
    try std.testing.expectEqualStrings(kept, links.get(1));
    // The map was rebuilt against the new bytes, so interning finds the survivor.
    try std.testing.expectEqual(@as(u16, 1), links.intern(gpa, kept));
}

test "palette256 cube and greyscale land on known xterm values" {
    // 16 is the first cube entry (pure black), 231 the last (pure white).
    try std.testing.expect(palette256[16].eq(Rgb.rgb(0, 0, 0)));
    try std.testing.expect(palette256[231].eq(Rgb.rgb(255, 255, 255)));
    try std.testing.expect(palette256[232].eq(Rgb.rgb(8, 8, 8)));
    try std.testing.expect(palette256[255].eq(Rgb.rgb(238, 238, 238)));
}
