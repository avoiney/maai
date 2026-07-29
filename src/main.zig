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
const sel = @import("term/selection.zig");
const ptr = @import("wl/pointer.zig");
const clip = @import("wl/clipboard.zig");

const atlas_size = 2048;
/// Per-read chunk. Bigger reads mean fewer syscalls during heavy output.
const read_chunk = 64 * 1024;
/// Cap on bytes parsed per loop iteration, so a flood cannot starve input or
/// resize handling. The loop simply comes back around for more (PLAN.md §2).
const drain_budget = 1024 * 1024;
/// How long synchronized output (DECSET 2026) may suppress presentation before we
/// draw anyway. Guards against an application that sets the mode and then dies.
const sync_timeout_ms = 150;

/// Two clicks within this window at the same cell count as a double click.
const multi_click_ms = 400;

const App = struct {
    gpa: std.mem.Allocator,
    win: *Window,
    gl: *Gl,
    screen: *Screen,
    pty: *Pty,
    font: *const Font,
    pad: Padding,
    /// Set by MYTERM_DEBUG. Traces input and selection handling, which is
    /// otherwise invisible: these paths are driven by hardware events that cannot
    /// be reproduced from a script.
    debug: bool = false,

    frame_pending: bool = false,
    /// Set when the compositor has given us a frame and the grid has changed.
    needs_render: bool = true,

    /// Pointer state for selection dragging and click counting.
    dragging: bool = false,
    last_click_ms: i64 = 0,
    last_click_line: usize = 0,
    last_click_x: u32 = 0,
    click_count: u2 = 0,

    fn writeToPty(ctx: *anyopaque, bytes: []const u8) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        // Typing snaps the view back to the live screen; otherwise the reply to
        // whatever you just typed scrolls past unseen.
        if (self.screen.grid.view != 0) {
            self.screen.grid.resetView();
            self.needs_render = true;
        }
        self.pty.write(bytes);
    }

    /// Map surface-local pixels to a point in the grid, including scrollback.
    fn pointAt(self: *App, px: f64, py: f64) sel.Point {
        const grid = &self.screen.grid;
        const fx = @max(px - @as(f64, @floatFromInt(self.pad.x)), 0);
        const fy = @max(py - @as(f64, @floatFromInt(self.pad.y)), 0);

        const col = @as(u32, @intFromFloat(fx / @as(f64, @floatFromInt(self.font.cell_w))));
        const row = @as(u32, @intFromFloat(fy / @as(f64, @floatFromInt(self.font.cell_h))));

        return .{
            .line = grid.viewTop() + @min(row, grid.rows - 1),
            .x = @min(col, grid.cols - 1),
        };
    }

    fn onMotion(ctx: *anyopaque, px: f64, py: f64) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (!self.dragging) {
            if (self.debug) std.debug.print("motion {d:.0},{d:.0} (not dragging)\n", .{ px, py });
            return;
        }
        const p = self.pointAt(px, py);
        self.screen.selection.extend(&self.screen.grid, p);
        if (self.debug) {
            const b = self.screen.selection.bounds();
            std.debug.print(
                "motion {d:.0},{d:.0} -> line {d} col {d}; sel {d}:{d}..{d}:{d}\n",
                .{ px, py, p.line, p.x, b.start.line, b.start.x, b.end.line, b.end.x },
            );
        }
        self.needs_render = true;
    }

    fn onButton(ctx: *anyopaque, button: u32, pressed: bool, serial: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const p = self.pointAt(self.win.pointer.x, self.win.pointer.y);

        switch (button) {
            ptr.button_left => {
                if (pressed) {
                    const now = monotonicMs();
                    const same_cell = p.line == self.last_click_line and
                        p.x == self.last_click_x;
                    if (same_cell and now - self.last_click_ms < multi_click_ms) {
                        self.click_count = if (self.click_count >= 3) 1 else self.click_count + 1;
                    } else {
                        self.click_count = 1;
                    }
                    self.last_click_ms = now;
                    self.last_click_line = p.line;
                    self.last_click_x = p.x;

                    const mode: sel.Mode = switch (self.click_count) {
                        1 => .char,
                        2 => .word,
                        else => .line,
                    };
                    self.screen.selection.begin(&self.screen.grid, p, mode);
                    self.dragging = true;
                    if (self.debug) {
                        std.debug.print(
                            "press left at line {d} col {d}, clicks {d}, mode {s}\n",
                            .{ p.line, p.x, self.click_count, @tagName(mode) },
                        );
                    }
                } else {
                    self.dragging = false;
                    // Finishing a selection publishes it to PRIMARY, so middle-click
                    // paste works, *and* to CLIPBOARD so Ctrl+Shift+V picks it up.
                    // Feeding CLIPBOARD on select is not the platform default — it
                    // means a clipboard manager records every mouse selection — but
                    // it is what was asked for here. Becomes a config option
                    // (`copy_on_select`) in phase 6.
                    self.publishSelection(serial, &.{ .primary, .clipboard });
                }
                self.needs_render = true;
            },
            ptr.button_middle => {
                if (pressed) self.pasteFrom(.primary);
            },
            else => {},
        }
    }

    fn onAxis(ctx: *anyopaque, lines: f64) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        // Wheel down is positive; scrolling back through history is negative view
        // motion, hence the inversion.
        const delta: i64 = @intFromFloat(-lines * 3);
        self.screen.grid.scrollView(delta);
        self.needs_render = true;
    }

    /// Publish the current selection to one or both selections. The text is
    /// extracted once and offered to each, since a drag now feeds both.
    fn publishSelection(self: *App, serial: u32, kinds: []const clip.Kind) void {
        const s = &self.screen.selection;
        if (!s.active) {
            if (self.debug) std.debug.print("publish: no active selection\n", .{});
            return;
        }
        const text = s.copyText(self.gpa, &self.screen.grid, &self.screen.graphemes) catch |err| {
            if (self.debug) std.debug.print("publish: copy failed {s}\n", .{@errorName(err)});
            return;
        };
        defer self.gpa.free(text);
        if (self.debug) {
            std.debug.print("publish: {d} bytes, serial {d}\n", .{ text.len, serial });
        }
        if (text.len == 0) return;
        for (kinds) |kind| self.win.clipboard.offer(kind, text, serial);
    }

    fn pasteFrom(self: *App, kind: clip.Kind) void {
        const text = self.win.clipboard.paste(kind, self.win.display) orelse return;
        defer self.gpa.free(text);
        if (text.len == 0) return;

        // Bracketed paste lets the application tell pasted text from typing, which
        // is what stops a pasted newline from executing a command outright. When the
        // application has not enabled it we sanitise instead: strip C0 controls
        // except tab, and turn newlines into carriage returns so the result behaves
        // like typed input rather than smuggling escape sequences.
        if (self.screen.modes.bracketed_paste) {
            self.pty.write("\x1b[200~");
            self.pty.write(text);
            self.pty.write("\x1b[201~");
        } else {
            var buf: [1024]u8 = undefined;
            var n: usize = 0;
            for (text) |ch| {
                const out: ?u8 = switch (ch) {
                    '\n', '\r' => '\r',
                    '\t' => '\t',
                    0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => null,
                    else => ch,
                };
                if (out) |o| {
                    buf[n] = o;
                    n += 1;
                    if (n == buf.len) {
                        self.pty.write(buf[0..n]);
                        n = 0;
                    }
                }
            }
            if (n > 0) self.pty.write(buf[0..n]);
        }

        // Any input snaps the view back to the live screen.
        self.screen.grid.resetView();
        self.needs_render = true;
    }

    /// Application shortcuts. Returning true stops the key reaching the child.
    fn onBinding(ctx: *anyopaque, sym: u32, ctrl: bool, shift: bool, _: bool) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        const grid = &self.screen.grid;

        if (ctrl and shift) {
            switch (sym) {
                c.XKB_KEY_C, c.XKB_KEY_c => {
                    self.publishSelection(self.win.keyboard.last_serial, &.{.clipboard});
                    return true;
                },
                c.XKB_KEY_V, c.XKB_KEY_v => {
                    self.pasteFrom(.clipboard);
                    return true;
                },
                else => {},
            }
        }

        // Scrollback navigation. Shift+Page keys are the convention, and shifted so
        // full-screen applications still receive plain Page Up/Down.
        if (shift) {
            switch (sym) {
                c.XKB_KEY_Page_Up => {
                    grid.scrollView(@intCast(grid.rows / 2));
                    self.needs_render = true;
                    return true;
                },
                c.XKB_KEY_Page_Down => {
                    grid.scrollView(-@as(i64, @intCast(grid.rows / 2)));
                    self.needs_render = true;
                    return true;
                },
                c.XKB_KEY_Home => {
                    grid.scrollView(@intCast(grid.maxView()));
                    self.needs_render = true;
                    return true;
                },
                c.XKB_KEY_End => {
                    grid.resetView();
                    self.needs_render = true;
                    return true;
                },
                else => {},
            }
        }

        return false;
    }
};

/// Zig 0.16 hands argv and environ to `main` rather than exposing them as
/// globals, so we take the `Init.Minimal` form.
pub fn main(init: std.process.Init.Minimal) !void {
    ignoreSigpipe();

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
    try win.init(gpa);
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

    var app = App{
        .gpa = gpa,
        .win = &win,
        .gl = &gl,
        .screen = &screen,
        .pty = &pty,
        .font = &font,
        .pad = pad,
        .debug = std.c.getenv("MYTERM_DEBUG") != null,
    };
    win.keyboard.sink = .{ .ctx = &app, .write = App.writeToPty };
    win.keyboard.bindings = .{ .ctx = &app, .handle = App.onBinding };
    // DECCKM and friends change how keys encode, so the encoder needs to see them.
    win.keyboard.modes = &screen.modes;
    win.pointer.handler = .{
        .ctx = &app,
        .motion = App.onMotion,
        .button = App.onButton,
        .axis = App.onAxis,
    };
    // Device queries (DA, DSR) answer back down the PTY.
    screen.reply = .{ .ctx = &app, .write = App.writeToPty };

    var parser = vt.Parser(Screen).init(&screen);

    const gi = gl.info();
    const caps = Font.capabilities();
    std.debug.print(
        \\myterm
        \\  GL_RENDERER : {s}
        \\  cell        : {d}x{d} px  (baseline {d})
        \\  grid        : {d}x{d} cells in {d}x{d} px
        \\  fcft        : grapheme={} text-run={} svg={}
        \\  seat        : keyboard={} pointer={}
        \\  selections  : clipboard={} primary={} cursor-shape={}
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
        win.keyboard.wl_kbd != null,
        win.pointer.wl_pointer != null,
        win.clipboard.device != null,
        win.clipboard.primary_device != null,
        win.pointer.shape_device != null,
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
    var sync_started_ms: i64 = 0;

    while (!win.closed) {
        // Synchronized output (DECSET 2026): while an application is mid-update we
        // hold off presenting, so its screen appears atomically instead of torn.
        // The deadline is a safety valve — an app that sets the mode and then dies
        // must not freeze the terminal forever.
        const now_ms = monotonicMs();
        if (screen.sync_output) {
            if (sync_started_ms == 0) sync_started_ms = now_ms;
        } else {
            sync_started_ms = 0;
        }
        const sync_elapsed = now_ms - sync_started_ms;
        const sync_holding = screen.sync_output and sync_elapsed < sync_timeout_ms;

        // Held-key repeat, driven off the same deadline machinery as sync output
        // rather than a separate timerfd.
        if (win.keyboard.repeat_at != 0 and now_ms >= win.keyboard.repeat_at) {
            win.keyboard.fireRepeat(now_ms);
        }

        if (app.needs_render and !app.frame_pending and !sync_holding) {
            render(&app, &renderer, &cache, &font, pad);
        }

        // The prepare_read / read_events dance is required: checking the fd for
        // readability without it races against events already queued in memory,
        // which manifests as a hang that only reproduces under load.
        while (c.wl_display_prepare_read(win.display) != 0) {
            _ = c.wl_display_dispatch_pending(win.display);
        }
        _ = c.wl_display_flush(win.display);

        fds[0] = .{ .fd = win.fd(), .events = std.posix.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = pty.master, .events = std.posix.POLL.IN, .revents = 0 };

        // Block indefinitely unless a deadline needs us back sooner. Two can be
        // outstanding — the synchronized-output safety valve and the next key
        // repeat — so wake for whichever comes first.
        var timeout: i32 = -1;
        if (sync_holding) {
            timeout = @intCast(@max(1, sync_timeout_ms - sync_elapsed));
        }
        if (win.keyboard.repeat_at != 0) {
            const due: i32 = @intCast(@max(1, win.keyboard.repeat_at - now_ms));
            timeout = if (timeout < 0) due else @min(timeout, due);
        }

        _ = std.posix.poll(&fds, timeout) catch |err| {
            c.wl_display_cancel_read(win.display);
            std.debug.print("myterm: poll failed: {s}\n", .{@errorName(err)});
            break;
        };

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            if (c.wl_display_read_events(win.display) < 0) {
                reportWaylandError(&win);
                break;
            }
        } else {
            c.wl_display_cancel_read(win.display);
            // A hangup or error without POLLIN means the compositor is gone. Without
            // this the loop spins at 100% of a core: poll returns immediately with
            // the same revents, forever.
            const dead = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
            if (fds[0].revents & dead != 0) {
                std.debug.print("myterm: compositor connection closed\n", .{});
                break;
            }
        }
        if (c.wl_display_dispatch_pending(win.display) < 0) {
            reportWaylandError(&win);
            break;
        }

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

/// Ignore SIGPIPE, whose default action is to terminate the process *silently* —
/// no panic, no message, no exit code to inspect.
///
/// A terminal writes to file descriptors owned by other processes all the time and
/// cannot assume any of them stay open:
///
///   - Serving a clipboard or PRIMARY request means writing into a pipe the asking
///     client created. If it closes the read end early — because it got what it
///     wanted, or died — our write returns EPIPE.
///   - Writing to the PTY master races with the child exiting.
///
/// With SIGPIPE ignored, both surface as an ordinary error the caller can handle.
fn ignoreSigpipe() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &act, null);
}

/// Explain why the Wayland connection died.
///
/// Without this a protocol error is indistinguishable from a clean exit: the loop
/// just stops and the window vanishes with nothing on stderr. libwayland does not
/// print these itself, it only records them for the client to ask about.
fn reportWaylandError(win: *Window) void {
    const err = c.wl_display_get_error(win.display);
    if (err == 0) return;

    var iface: ?*const c.struct_wl_interface = null;
    var id: u32 = 0;
    const code = c.wl_display_get_protocol_error(win.display, &iface, &id);

    if (iface) |i| {
        std.debug.print(
            "myterm: wayland protocol error: {s} raised code {d} on object {d}\n",
            .{ std.mem.span(i.*.name), code, id },
        );
    } else {
        std.debug.print("myterm: wayland connection lost (errno {d})\n", .{err});
    }
}

/// Milliseconds on a monotonic clock.
///
/// Monotonic rather than wall time on purpose: an NTP step backwards would make a
/// deadline computed from wall time never expire. `std.time.milliTimestamp` was
/// removed in Zig 0.16, so this goes straight to the syscall (vDSO-accelerated).
fn monotonicMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
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
