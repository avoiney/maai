//! myterm — phase 1: a PTY, a VT parser, and text on the screen.
//!
//! Usage:
//!   myterm              run $SHELL
//!   myterm -e cmd args  run a specific command (handy for scripted checks)

const std = @import("std");
const c = @import("c.zig").c;

const Window = @import("wl/window.zig").Window;
const Gl = @import("gfx/egl.zig").Gl;
const Renderer = @import("gfx/renderer.zig").Renderer;
const Padding = @import("gfx/renderer.zig").Padding;
const GlyphCache = @import("gfx/glyph_cache.zig").GlyphCache;
const Font = @import("font/font.zig").Font;
const Screen = @import("term/screen.zig").Screen;
const Pty = @import("pty/pty.zig").Pty;
const vt = @import("vt/parser.zig");

const atlas_size = 2048;
/// Per-read chunk. Bigger reads mean fewer syscalls during heavy output.
const read_chunk = 64 * 1024;
/// Cap on bytes parsed per loop iteration, so a flood cannot starve input or
/// resize handling. The loop simply comes back around for more (PLAN.md §2).
const drain_budget = 1024 * 1024;

const App = struct {
    win: *Window,
    gl: *Gl,
    screen: *Screen,
    pty: *Pty,

    frame_pending: bool = false,
    /// Set when the compositor has given us a frame and the grid has changed.
    needs_render: bool = true,

    fn writeToPty(ctx: *anyopaque, bytes: []const u8) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.pty.write(bytes);
    }
};

/// Zig 0.16 hands argv and environ to `main` rather than exposing them as
/// globals, so we take the `Init.Minimal` form.
pub fn main(init: std.process.Init.Minimal) !void {
    // We link libc anyway, so use its allocator rather than paying for Zig's
    // debug allocator bookkeeping in the render path.
    const gpa = std.heap.c_allocator;

    const argv = try buildArgv(gpa, init.args.vector, init.environ);
    defer gpa.free(argv);

    // ── font first: cell geometry determines the initial window size ────────
    var font = Font.init("FiraCode Nerd Font", "size=12:dpi=96") catch |err| {
        std.debug.print(
            "myterm: could not load 'FiraCode Nerd Font' ({s})\n",
            .{@errorName(err)},
        );
        return err;
    };
    defer font.deinit();

    var win: Window = undefined;
    try win.init();
    defer win.deinit();

    var gl: Gl = undefined;
    try gl.init(&win);
    defer gl.deinit();

    var renderer = try Renderer.init(gpa);
    defer renderer.deinit();

    var cache = GlyphCache.init(gpa, &font, atlas_size);
    defer cache.deinit();

    const pad = Padding{};
    var dims = gridSize(win.width, win.height, &font, pad);

    var screen = try Screen.init(gpa, dims.cols, dims.rows);
    defer screen.deinit();

    var pty = Pty.spawn(dims.cols, dims.rows, argv.ptr) catch |err| {
        std.debug.print("myterm: could not spawn {s}: {s}\n", .{
            std.mem.span(argv[0].?),
            @errorName(err),
        });
        return err;
    };
    defer pty.deinit();

    var app = App{ .win = &win, .gl = &gl, .screen = &screen, .pty = &pty };
    win.keyboard.sink = .{ .ctx = &app, .write = App.writeToPty };

    var parser = vt.Parser(Screen).init(&screen);

    const gi = gl.info();
    const caps = Font.capabilities();
    std.debug.print(
        \\myterm phase 1
        \\  GL_RENDERER : {s}
        \\  cell        : {d}x{d} px  (baseline {d})
        \\  grid        : {d}x{d} cells in {d}x{d} px
        \\  fcft        : grapheme={} text-run={} svg={}
        \\  child       : {s} (pid {d})
        \\
    , .{
        gi.renderer,
        font.cell_w,
        font.cell_h,
        font.baseline,
        dims.cols,
        dims.rows,
        win.width,
        win.height,
        caps.grapheme,
        caps.text_run,
        caps.svg,
        std.mem.span(argv[0].?),
        pty.child,
    });

    // ── event loop ─────────────────────────────────────────────────────────
    // One thread, polling Wayland and the PTY together. PLAN.md §2 sketches a
    // per-pane parse thread; that only starts paying off once there are multiple
    // panes (phase 5), and foot demonstrates a single-threaded loop is entirely
    // competitive. Revisit with measurements rather than on principle.
    var read_buf: [read_chunk]u8 = undefined;
    var fds: [2]std.posix.pollfd = undefined;

    while (!win.closed) {
        if (app.needs_render and !app.frame_pending) render(&app, &renderer, &cache, &font, pad);

        // The prepare_read / read_events dance is required: checking the fd for
        // readability without it races against events already queued in memory,
        // which manifests as a hang that only reproduces under load.
        while (c.wl_display_prepare_read(win.display) != 0) {
            _ = c.wl_display_dispatch_pending(win.display);
        }
        _ = c.wl_display_flush(win.display);

        fds[0] = .{ .fd = win.fd(), .events = std.posix.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = pty.master, .events = std.posix.POLL.IN, .revents = 0 };

        _ = std.posix.poll(&fds, -1) catch {
            c.wl_display_cancel_read(win.display);
            break;
        };

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            if (c.wl_display_read_events(win.display) < 0) break;
        } else {
            c.wl_display_cancel_read(win.display);
        }
        _ = c.wl_display_dispatch_pending(win.display);

        if (fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
            var drained: usize = 0;
            while (drained < drain_budget) {
                const n = pty.read(&read_buf);
                if (n == 0) break;
                parser.feed(read_buf[0..n]);
                drained += n;
            }
        }

        if (win.resized) {
            gl.resize(win.width, win.height);
            dims = gridSize(win.width, win.height, &font, pad);
            try screen.resize(dims.cols, dims.rows);
            pty.resize(dims.cols, dims.rows);
            win.resized = false;
        }

        if (screen.dirty) {
            screen.dirty = false;
            app.needs_render = true;
        }

        if (pty.hung_up or pty.childExited()) break;
    }
}

fn render(
    app: *App,
    renderer: *Renderer,
    cache: *GlyphCache,
    font: *const Font,
    pad: Padding,
) void {
    const win = app.win;

    renderer.draw(app.screen, cache, font, win.width, win.height, pad);
    app.needs_render = false;

    if (cache.exhausted) {
        // Not fatal: affected glyphs render blank. Phase 7 adds LRU eviction.
        std.debug.print("myterm: glyph atlas full\n", .{});
        cache.exhausted = false;
    }

    // Request the next frame callback *before* swapping: eglSwapBuffers performs
    // the wl_surface.commit, and the callback must ride on that same commit.
    if (c.wl_surface_frame(win.surface)) |cb| {
        _ = c.wl_callback_add_listener(cb, &frame_listener, app);
        app.frame_pending = true;
    }
    app.gl.swap();
}

const frame_listener: c.struct_wl_callback_listener = .{ .done = handleFrame };

fn handleFrame(
    data: ?*anyopaque,
    callback: ?*c.struct_wl_callback,
    _: u32,
) callconv(.c) void {
    c.wl_callback_destroy(callback);
    const app: *App = @ptrCast(@alignCast(data.?));
    app.frame_pending = false;
}

const Dims = struct { cols: u32, rows: u32 };

fn gridSize(width: u32, height: u32, font: *const Font, pad: Padding) Dims {
    // Padding is left/top only, matching the user's existing kitty and wezterm
    // configs (`window_padding_width 0 0 0 4`).
    const usable_w = if (width > pad.x) width - pad.x else font.cell_w;
    const usable_h = if (height > pad.y) height - pad.y else font.cell_h;
    return .{
        .cols = @max(usable_w / font.cell_w, 1),
        .rows = @max(usable_h / font.cell_h, 1),
    };
}

/// Build the child's argv: `-e cmd args...` runs a specific command, otherwise
/// $SHELL and then zsh as a fallback.
///
/// The incoming pointers are the process's own argv and environ, which live for
/// the process lifetime, so only the array itself needs allocating — the strings
/// can be referenced directly and stay valid across the fork.
fn buildArgv(
    gpa: std.mem.Allocator,
    args: []const [*:0]const u8,
    environ: std.process.Environ,
) ![:null]?[*:0]const u8 {
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, std.mem.span(arg), "-e") and i + 1 < args.len) {
            const rest = args[i + 1 ..];
            const argv = try gpa.allocSentinel(?[*:0]const u8, rest.len, null);
            for (rest, 0..) |a, j| argv[j] = a;
            return argv;
        }
    }

    const shell: [*:0]const u8 = if (environ.getPosix("SHELL")) |s|
        @ptrCast(s.ptr)
    else
        "/usr/bin/zsh";

    const argv = try gpa.allocSentinel(?[*:0]const u8, 1, null);
    argv[0] = shell;
    return argv;
}
