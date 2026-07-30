//! Micro-benchmarks for the terminal core. `zig build bench`.
//!
//! Deliberately links no Wayland, EGL or fcft: the point is to measure parsing,
//! grid mutation and reflow in isolation, so a number can be attributed to one
//! layer rather than to "the terminal". That also makes it usable under `perf` and
//! `valgrind --tool=callgrind` without a compositor in the picture.
//!
//! Method notes, so results stay comparable between runs:
//!
//!   - Build with `-Doptimize=ReleaseFast`. Debug builds are 5-20x slower here and
//!     say nothing useful about shipped performance.
//!   - Each case runs a warmup pass that is discarded, then reports the *minimum*
//!     of N runs, not the mean. The minimum is the best estimate of the code's cost;
//!     the spread above it is scheduler and cache noise, and is reported separately
//!     so a suspiciously wide spread is visible.
//!   - Timing is monotonic. Allocation counts come from a wrapping allocator, since
//!     allocator churn is the thing under suspicion for reflow.

const std = @import("std");
const Screen = @import("term/screen.zig").Screen;
const gridmod = @import("term/grid.zig");
const Grid = gridmod.Grid;
const vt = @import("vt/parser.zig");
const cellmod = @import("term/cell.zig");
const thememod = @import("term/theme.zig");

/// Runs per case. Small on purpose: the whole suite must stay quick enough to run
/// after a change, or it stops being run at all.
const runs = 5;

/// Counts allocations and bytes so a benchmark can report churn, not just time.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        self.bytes += len;
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(buf, a, new_len, ra);
    }
    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        self.bytes += new_len;
        return self.child.rawRemap(buf, a, new_len, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, a, ra);
    }
};

fn nowNs() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

const Result = struct {
    name: []const u8,
    min_ns: u64,
    max_ns: u64,
    /// Optional throughput numerator, in bytes.
    bytes: usize = 0,
    allocs: usize = 0,
    alloc_bytes: usize = 0,

    fn report(self: Result) void {
        const ms = @as(f64, @floatFromInt(self.min_ns)) / 1e6;
        const spread = @as(f64, @floatFromInt(self.max_ns - self.min_ns)) /
            @as(f64, @floatFromInt(self.min_ns)) * 100.0;

        std.debug.print("{s:<38} {d:>9.3} ms  (+{d:.0}%)", .{ self.name, ms, spread });
        if (self.bytes > 0) {
            const mbps = @as(f64, @floatFromInt(self.bytes)) /
                (@as(f64, @floatFromInt(self.min_ns)) / 1e9) / (1024 * 1024);
            std.debug.print("  {d:>8.1} MiB/s", .{mbps});
        }
        if (self.allocs > 0) {
            std.debug.print("  {d} allocs, {d:.1} MiB", .{
                self.allocs,
                @as(f64, @floatFromInt(self.alloc_bytes)) / (1024 * 1024),
            });
        }
        std.debug.print("\n", .{});
    }
};

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    std.debug.print(
        \\myterm benchmarks
        \\  build: {s}   (use -Doptimize=ReleaseFast for meaningful numbers)
        \\  {d} runs per case, reporting the minimum with spread above it
        \\
        \\
    , .{ @tagName(@import("builtin").mode), runs });

    // `MYTERM_BENCH=<substring>` runs only the matching cases. Added for profiling:
    // a profiler pointed at the whole suite reports the parse cases, which drown out
    // whatever is being investigated, and callgrind's --toggle-collect cannot latch
    // onto a function the optimiser inlined.
    const filter: ?[]const u8 = if (std.c.getenv("MYTERM_BENCH")) |f|
        std.mem.span(f)
    else
        null;

    const cases = [_]struct { name: []const u8, run: *const fn (std.mem.Allocator) anyerror!void }{
        .{ .name = "parse-ascii", .run = benchParseAscii },
        .{ .name = "parse-sgr", .run = benchParseSgr },
        .{ .name = "parse-utf8", .run = benchParseUtf8 },
        .{ .name = "reflow-width", .run = benchReflowWidth },
        .{ .name = "reflow-height", .run = benchReflowHeightOnly },
        .{ .name = "scroll", .run = benchScroll },
        .{ .name = "styles", .run = benchStyleChurn },
        .{ .name = "resolve-colors", .run = benchResolveColors },
    };

    for (cases) |case| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, case.name, f) == null) continue;
        }
        try case.run(gpa);
    }
}

// ── rendering ───────────────────────────────────────────────────────────────

/// The per-cell work the renderer added when colour resolution moved from parse time
/// to draw time.
///
/// This exists because the change is invisible to every other case here: it took work
/// *out* of SGR handling and put it into the draw loop, which links GL and so cannot
/// be measured in this harness. What can be measured is the arithmetic itself, over a
/// screen's worth of cells at the resolution the renderer performs — three slots per
/// cell, fg, bg and underline.
///
/// The comparison that matters is against reading a stored `Rgb` directly, which is
/// what the old code did. If the difference were anywhere near a frame budget the
/// indirection would not be worth having.
fn benchResolveColors(gpa: std.mem.Allocator) !void {
    const cols = 240;
    const rows = 68;

    var screen = try Screen.init(gpa, cols, rows);
    defer screen.deinit();
    var parser = vt.Parser(Screen).init(&screen);

    // A mix of the three slot kinds, since they cost different amounts: default is a
    // branch, indexed adds a table read, rgb unpacks in place.
    var i: usize = 0;
    while (i < cols * rows) : (i += 1) {
        var tmp: [48]u8 = undefined;
        const seq = switch (i % 3) {
            0 => try std.fmt.bufPrint(&tmp, "\x1b[3{d}mX", .{i % 8}),
            1 => try std.fmt.bufPrint(&tmp, "\x1b[38;2;{d};{d};{d}mX", .{
                i % 256,
                (i / 256) % 256,
                7,
            }),
            else => try std.fmt.bufPrint(&tmp, "\x1b[0mX", .{}),
        };
        parser.feed(seq);
    }

    const frames = 100;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    var run: usize = 0;
    while (run <= runs) : (run += 1) {
        const t0 = nowNs();
        var sink: u64 = 0;
        for (0..frames) |_| {
            var y: u32 = 0;
            while (y < screen.grid.rows) : (y += 1) {
                for (screen.grid.viewRow(y)) |cell| {
                    const st = screen.styles.get(cell.style);
                    const fg = screen.theme.resolve(st.fg, .fg);
                    const bg = screen.theme.resolve(st.bg, .bg);
                    const ul = screen.theme.resolve(st.ul, .ul);
                    // Consumed so the loop cannot be optimised away.
                    sink +%= fg.r +% bg.g +% ul.b;
                }
            }
        }
        std.mem.doNotOptimizeAway(sink);
        const dt: u64 = @intCast(nowNs() - t0);
        if (run == 0) continue;
        min = @min(min, dt);
        max = @max(max, dt);
    }

    const per_frame_us = @as(f64, @floatFromInt(min)) / 1000.0 / frames;
    (Result{
        .name = "render: resolve 240x68 colours x100",
        .min_ns = min,
        .max_ns = max,
    }).report();
    std.debug.print(
        "{s:<38} {d:>9.3} ms  per frame ({d} cells, 3 slots each)\n",
        .{ "  -> per frame", per_frame_us / 1000.0, cols * rows },
    );
}

// ── parsing ─────────────────────────────────────────────────────────────────

fn benchParse(gpa: std.mem.Allocator, name: []const u8, input: []const u8) !void {
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;

    var run: usize = 0;
    while (run <= runs) : (run += 1) {
        var screen = try Screen.init(gpa, 240, 68);
        defer screen.deinit();
        var parser = vt.Parser(Screen).init(&screen);

        const t0 = nowNs();
        parser.feed(input);
        const dt: u64 = @intCast(nowNs() - t0);

        if (run == 0) continue; // warmup
        min = @min(min, dt);
        max = @max(max, dt);
    }

    (Result{ .name = name, .min_ns = min, .max_ns = max, .bytes = input.len }).report();
}

fn benchParseAscii(gpa: std.mem.Allocator) !void {
    // 8 MiB of printable text in 80-column lines: the `cat a big file` case.
    const size = 4 * 1024 * 1024;
    const buf = try gpa.alloc(u8, size);
    defer gpa.free(buf);
    for (buf, 0..) |*b, i| {
        b.* = if (i % 80 == 79) '\n' else @intCast('a' + (i % 26));
    }
    try benchParse(gpa, "parse: plain ASCII", buf);
}

fn benchParseSgr(gpa: std.mem.Allocator) !void {
    // Truecolor per cell, as lolcat or a gradient prompt emits. This is both the
    // parser's worst case and what used to exhaust the style table.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    while (out.items.len < 2 * 1024 * 1024) : (i += 1) {
        var tmp: [40]u8 = undefined;
        const seq = try std.fmt.bufPrint(&tmp, "\x1b[38;2;{d};{d};{d}mX", .{
            i % 256,
            (i / 256) % 256,
            (i / 65536) % 256,
        });
        try out.appendSlice(gpa, seq);
        if (i % 80 == 79) try out.append(gpa, '\n');
    }
    try benchParse(gpa, "parse: truecolor SGR per cell", out.items);
}

fn benchParseUtf8(gpa: std.mem.Allocator) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    while (out.items.len < 2 * 1024 * 1024) {
        try out.appendSlice(gpa, "日本語テキスト éàö ");
    }
    try benchParse(gpa, "parse: CJK + combining marks", out.items);
}

// ── reflow ──────────────────────────────────────────────────────────────────

/// Fill a screen and its scrollback with wrapped content, the state that makes
/// reflow expensive.
fn fillScrollback(screen: *Screen, lines: usize) void {
    var parser = vt.Parser(Screen).init(screen);
    var i: usize = 0;
    while (i < lines) : (i += 1) {
        var tmp: [300]u8 = undefined;
        const line = std.fmt.bufPrint(
            &tmp,
            "line {d:0>6} the quick brown fox jumps over the lazy dog and keeps going " ++
                "well past the right edge so that this wraps\r\n",
            .{i},
        ) catch unreachable;
        parser.feed(line);
    }
}

fn benchReflowWidth(gpa: std.mem.Allocator) !void {
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    var allocs: usize = 0;
    var alloc_bytes: usize = 0;

    var run: usize = 0;
    while (run <= runs) : (run += 1) {
        var counting = CountingAllocator{ .child = gpa };
        const a = counting.allocator();

        var screen = try Screen.initScrollback(a, 240, 68, 10_000);
        defer screen.deinit();
        fillScrollback(&screen, 10_000);

        counting.allocs = 0;
        counting.bytes = 0;
        const t0 = nowNs();
        // One column narrower: the common case while dragging a window edge.
        try screen.resize(239, 68);
        const dt: u64 = @intCast(nowNs() - t0);

        if (run == 0) continue;
        min = @min(min, dt);
        max = @max(max, dt);
        allocs = counting.allocs;
        alloc_bytes = counting.bytes;
    }

    (Result{
        .name = "reflow: 10k scrollback, width -1",
        .min_ns = min,
        .max_ns = max,
        .allocs = allocs,
        .alloc_bytes = alloc_bytes,
    }).report();
}

fn benchReflowHeightOnly(gpa: std.mem.Allocator) !void {
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    var allocs: usize = 0;
    var alloc_bytes: usize = 0;

    var run: usize = 0;
    while (run <= runs) : (run += 1) {
        var counting = CountingAllocator{ .child = gpa };
        const a = counting.allocator();

        var screen = try Screen.initScrollback(a, 240, 68, 10_000);
        defer screen.deinit();
        fillScrollback(&screen, 10_000);

        counting.allocs = 0;
        counting.bytes = 0;
        const t0 = nowNs();
        // Height only, width unchanged: no rewrapping is logically required, so
        // this is the case most worth specialising if the numbers justify it.
        try screen.resize(240, 67);
        const dt: u64 = @intCast(nowNs() - t0);

        if (run == 0) continue;
        min = @min(min, dt);
        max = @max(max, dt);
        allocs = counting.allocs;
        alloc_bytes = counting.bytes;
    }

    (Result{
        .name = "reflow: 10k scrollback, height -1",
        .min_ns = min,
        .max_ns = max,
        .allocs = allocs,
        .alloc_bytes = alloc_bytes,
    }).report();
}

// ── grid ────────────────────────────────────────────────────────────────────

fn benchScroll(gpa: std.mem.Allocator) !void {
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;

    var run: usize = 0;
    while (run <= runs) : (run += 1) {
        var grid = try Grid.init(gpa, 240, 68, 10_000);
        defer grid.deinit();

        const t0 = nowNs();
        var i: usize = 0;
        while (i < 50_000) : (i += 1) grid.scrollUp(1, 0);
        const dt: u64 = @intCast(nowNs() - t0);

        if (run == 0) continue;
        min = @min(min, dt);
        max = @max(max, dt);
    }

    (Result{ .name = "grid: 50k line scrolls", .min_ns = min, .max_ns = max }).report();
}

fn benchStyleChurn(gpa: std.mem.Allocator) !void {
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;

    var run: usize = 0;
    while (run <= runs) : (run += 1) {
        var screen = try Screen.init(gpa, 240, 68);
        defer screen.deinit();
        var parser = vt.Parser(Screen).init(&screen);

        const t0 = nowNs();
        // Enough distinct styles to force several collections.
        var i: usize = 0;
        while (i < 150_000) : (i += 1) {
            var tmp: [40]u8 = undefined;
            const seq = std.fmt.bufPrint(&tmp, "\x1b[38;2;{d};{d};{d}mX", .{
                i % 256,
                (i / 256) % 256,
                (i / 65536) % 256,
            }) catch unreachable;
            parser.feed(seq);
        }
        const dt: u64 = @intCast(nowNs() - t0);

        if (run == 0) continue;
        min = @min(min, dt);
        max = @max(max, dt);
    }

    (Result{
        .name = "styles: 150k distinct, with collection",
        .min_ns = min,
        .max_ns = max,
    }).report();
}
