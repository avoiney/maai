//! myterm — phase 0: a Wayland window with a GLES3 context and a frame-paced
//! render loop.
//!
//! There is deliberately no PTY, font, or grid yet. What this proves out is the
//! foundation everything else sits on: the configure/ack handshake, EGL on
//! wl_egl_window, and — most importantly — that rendering is driven by compositor
//! frame callbacks rather than a busy loop or a blocking swap. That pacing model
//! is what PLAN.md §6's latency budget depends on, so it is worth establishing
//! before there is anything interesting to draw.

const std = @import("std");
const c = @import("c.zig").c;
const Window = @import("wl/window.zig").Window;
const Gl = @import("gfx/egl.zig").Gl;

const App = struct {
    win: *Window,
    gl: *Gl,

    /// A frame callback is outstanding; the compositor has not yet said "go".
    frame_pending: bool = false,
    /// Compositor timestamp (ms) of the last frame callback.
    last_frame_ms: u32 = 0,

    // Frame pacing stats. Phase 0 uses these to confirm we actually track the
    // output's refresh rate (75 Hz on the MSI, 60 on the laptop panel) and to
    // give phase 7 a baseline to compare against.
    stat_frames: u32 = 0,
    stat_since_ms: u32 = 0,
};

pub fn main() !void {
    var win: Window = undefined;
    win.init() catch |err| {
        std.debug.print("myterm: wayland init failed: {s}\n", .{@errorName(err)});
        switch (err) {
            error.ConnectFailed => std.debug.print(
                "  no compositor on WAYLAND_DISPLAY={s}\n",
                .{if (std.c.getenv("WAYLAND_DISPLAY")) |v| std.mem.span(v) else "(unset)"},
            ),
            error.MissingXdgWmBase => std.debug.print(
                "  compositor does not implement xdg-shell\n",
                .{},
            ),
            else => {},
        }
        return err;
    };
    defer win.deinit();

    var gl: Gl = undefined;
    try gl.init(&win);
    defer gl.deinit();

    const gi = gl.info();
    std.debug.print(
        \\myterm phase 0
        \\  GL_RENDERER : {s}
        \\  GL_VERSION  : {s}
        \\  surface     : {d}x{d}
        \\  decorations : {s}
        \\
    , .{
        gi.renderer,
        gi.version,
        win.width,
        win.height,
        if (win.decoration != null) "server-side" else "none (tiling WM)",
    });

    var app = App{ .win = &win, .gl = &gl };

    // Kick the loop: draw one frame, which requests the first frame callback.
    render(&app);

    while (!win.closed) {
        win.dispatch() catch |err| {
            std.debug.print("myterm: {s}\n", .{@errorName(err)});
            break;
        };
        // Only ever one frame in flight. Without this guard a fast compositor and a
        // cheap frame would spin us at thousands of FPS burning the iGPU for nothing.
        if (!app.frame_pending) render(&app);
    }
}

fn render(app: *App) void {
    const win = app.win;

    if (win.resized) {
        app.gl.resize(win.width, win.height);
        win.resized = false;
    }

    // Placeholder content: a slow pulse, so it is visually obvious whether frames
    // are actually being delivered and paced. Replaced by the grid in phase 1.
    const t = @as(f32, @floatFromInt(app.last_frame_ms)) / 1000.0;
    const pulse = 0.5 + 0.5 * @sin(t * 1.5);
    c.glClearColor(0.05 + 0.04 * pulse, 0.05, 0.09 + 0.06 * pulse, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    // Request the next frame callback *before* swapping: eglSwapBuffers performs the
    // wl_surface.commit, and the callback must be attached to that same commit.
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
    time_ms: u32,
) callconv(.c) void {
    // Frame callbacks are one-shot; the object is dead after this event.
    c.wl_callback_destroy(callback);

    const app: *App = @ptrCast(@alignCast(data.?));
    app.frame_pending = false;
    app.last_frame_ms = time_ms;

    app.stat_frames += 1;
    if (app.stat_since_ms == 0) app.stat_since_ms = time_ms;
    const elapsed = time_ms -% app.stat_since_ms;
    if (elapsed >= 2000) {
        const fps = @as(f32, @floatFromInt(app.stat_frames)) * 1000.0 /
            @as(f32, @floatFromInt(elapsed));
        std.debug.print("  frame pacing: {d:.1} fps\n", .{fps});
        app.stat_frames = 0;
        app.stat_since_ms = time_ms;
    }
}
