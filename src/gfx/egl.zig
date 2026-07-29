//! EGL/GLES3 context bound to a wl_surface via wl_egl_window.

const std = @import("std");
const c = @import("../c.zig").c;
const Window = @import("../wl/window.zig").Window;

pub const Error = error{
    NoDisplay,
    InitFailed,
    NoConfig,
    ContextFailed,
    WindowFailed,
    SurfaceFailed,
    MakeCurrentFailed,
};

pub const Gl = struct {
    dpy: c.EGLDisplay = null,
    ctx: c.EGLContext = null,
    surf: c.EGLSurface = null,
    egl_window: ?*c.struct_wl_egl_window = null,

    pub fn init(gl: *Gl, win: *Window) Error!void {
        gl.* = .{};

        // TODO(phase 7): eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, ...) is the
        // correct modern entry point. eglGetDisplay works fine on Mesa and keeps
        // phase 0 free of eglext.h function-pointer loading.
        gl.dpy = c.eglGetDisplay(@ptrCast(win.display));
        if (gl.dpy == null) return Error.NoDisplay;

        var major: c.EGLint = undefined;
        var minor: c.EGLint = undefined;
        if (c.eglInitialize(gl.dpy, &major, &minor) != c.EGL_TRUE) return Error.InitFailed;
        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) != c.EGL_TRUE) return Error.InitFailed;

        const config_attrs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            // Alpha is requested now so background opacity in a later phase does not
            // require renegotiating the config (and thus the whole context).
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_NONE,
        };

        var config: c.EGLConfig = null;
        var num_configs: c.EGLint = 0;
        if (c.eglChooseConfig(gl.dpy, &config_attrs, &config, 1, &num_configs) != c.EGL_TRUE)
            return Error.NoConfig;
        if (num_configs < 1) return Error.NoConfig;

        const ctx_attrs = [_]c.EGLint{
            c.EGL_CONTEXT_MAJOR_VERSION, 3,
            c.EGL_CONTEXT_MINOR_VERSION, 0,
            c.EGL_NONE,
        };
        gl.ctx = c.eglCreateContext(gl.dpy, config, c.EGL_NO_CONTEXT, &ctx_attrs);
        if (gl.ctx == null) return Error.ContextFailed;

        gl.egl_window = c.wl_egl_window_create(
            win.surface,
            @intCast(win.width),
            @intCast(win.height),
        ) orelse return Error.WindowFailed;

        // EGLNativeWindowType is `*struct wl_egl_window` on the Wayland platform,
        // so the pointer goes straight through with no handle cast.
        gl.surf = c.eglCreateWindowSurface(gl.dpy, config, gl.egl_window, null);
        if (gl.surf == null) return Error.SurfaceFailed;

        if (c.eglMakeCurrent(gl.dpy, gl.surf, gl.surf, gl.ctx) != c.EGL_TRUE)
            return Error.MakeCurrentFailed;

        // Swap interval 0 is deliberate and important. With interval 1, eglSwapBuffers
        // blocks until the compositor releases the buffer, which would stall the event
        // loop and add a frame of input latency. Pacing comes from wl_surface frame
        // callbacks instead, which is also what phase 7's presentation-feedback
        // latency work builds on.
        _ = c.eglSwapInterval(gl.dpy, 0);
    }

    pub fn resize(gl: *Gl, width: u32, height: u32) void {
        if (gl.egl_window) |w| {
            c.wl_egl_window_resize(w, @intCast(width), @intCast(height), 0, 0);
        }
        c.glViewport(0, 0, @intCast(width), @intCast(height));
    }

    pub fn swap(gl: *Gl) void {
        _ = c.eglSwapBuffers(gl.dpy, gl.surf);
    }

    pub fn info(gl: *Gl) struct { vendor: []const u8, renderer: []const u8, version: []const u8 } {
        _ = gl;
        return .{
            .vendor = cstr(c.glGetString(c.GL_VENDOR)),
            .renderer = cstr(c.glGetString(c.GL_RENDERER)),
            .version = cstr(c.glGetString(c.GL_VERSION)),
        };
    }

    pub fn deinit(gl: *Gl) void {
        if (gl.dpy == null) return;
        _ = c.eglMakeCurrent(gl.dpy, null, null, null);
        if (gl.surf != null) _ = c.eglDestroySurface(gl.dpy, gl.surf);
        if (gl.ctx != null) _ = c.eglDestroyContext(gl.dpy, gl.ctx);
        if (gl.egl_window) |w| c.wl_egl_window_destroy(w);
        _ = c.eglTerminate(gl.dpy);
    }
};

fn cstr(s: ?[*:0]const c.GLubyte) []const u8 {
    const p = s orelse return "?";
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}
