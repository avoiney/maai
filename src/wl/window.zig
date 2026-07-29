//! Wayland display connection, globals, and one xdg_toplevel window.
//!
//! Phase 0 scope: connect, bind globals, create a toplevel, negotiate
//! decorations, and track configure/close state. No input, no buffers of our own
//! (EGL owns those — see gfx/egl.zig).

const std = @import("std");
const c = @import("../c.zig").c;
const Keyboard = @import("keyboard.zig").Keyboard;

pub const Error = error{
    ConnectFailed,
    MissingCompositor,
    MissingXdgWmBase,
    SurfaceFailed,
    RoleFailed,
    Disconnected,
};

pub const Window = struct {
    display: *c.struct_wl_display,
    registry: *c.struct_wl_registry,

    compositor: ?*c.struct_wl_compositor = null,
    wm_base: ?*c.struct_xdg_wm_base = null,
    deco_manager: ?*c.struct_zxdg_decoration_manager_v1 = null,
    seat: ?*c.struct_wl_seat = null,

    /// Owned here so its address is stable for the wl_keyboard listener.
    keyboard: Keyboard = .{},

    surface: ?*c.struct_wl_surface = null,
    xdg_surface: ?*c.struct_xdg_surface = null,
    toplevel: ?*c.struct_xdg_toplevel = null,
    decoration: ?*c.struct_zxdg_toplevel_decoration_v1 = null,

    /// Current committed size, in surface-local (logical) pixels.
    width: u32 = 1000,
    height: u32 = 700,
    /// Size the compositor last asked for; 0 means "you choose".
    pending_width: u32 = 0,
    pending_height: u32 = 0,

    configured: bool = false,
    /// Size changed since the last render; renderer must resync its viewport.
    resized: bool = true,
    /// Compositor or user asked us to go away.
    closed: bool = false,

    pub fn init(w: *Window) Error!void {
        const display = c.wl_display_connect(null) orelse return Error.ConnectFailed;
        const registry = c.wl_display_get_registry(display) orelse
            return Error.ConnectFailed;

        w.* = .{ .display = display, .registry = registry };
        w.keyboard.init();

        _ = c.wl_registry_add_listener(registry, &registry_listener, w);

        // First roundtrip delivers the global advertisements; the second lets any
        // listener we attached inside those handlers (e.g. xdg_wm_base ping) settle.
        _ = c.wl_display_roundtrip(display);
        _ = c.wl_display_roundtrip(display);

        if (w.compositor == null) return Error.MissingCompositor;
        if (w.wm_base == null) return Error.MissingXdgWmBase;

        try w.createToplevel();
    }

    fn createToplevel(w: *Window) Error!void {
        w.surface = c.wl_compositor_create_surface(w.compositor) orelse
            return Error.SurfaceFailed;
        w.xdg_surface = c.xdg_wm_base_get_xdg_surface(w.wm_base, w.surface) orelse
            return Error.RoleFailed;
        _ = c.xdg_surface_add_listener(w.xdg_surface, &xdg_surface_listener, w);

        w.toplevel = c.xdg_surface_get_toplevel(w.xdg_surface) orelse
            return Error.RoleFailed;
        _ = c.xdg_toplevel_add_listener(w.toplevel, &toplevel_listener, w);

        c.xdg_toplevel_set_title(w.toplevel, "myterm");
        // sway matches rules on app_id; keep this stable, it is effectively API.
        c.xdg_toplevel_set_app_id(w.toplevel, "myterm");

        // Ask for server-side decorations so sway draws its own 1px border rather
        // than us reimplementing titlebars. If the compositor lacks the protocol we
        // simply render edge to edge, which is what we want under a tiling WM anyway.
        if (w.deco_manager) |mgr| {
            w.decoration = c.zxdg_decoration_manager_v1_get_toplevel_decoration(mgr, w.toplevel);
            if (w.decoration) |d| {
                c.zxdg_toplevel_decoration_v1_set_mode(
                    d,
                    c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE,
                );
            }
        }

        // Commit the role without a buffer, then block for the initial configure.
        // Attaching a buffer before the first configure is a protocol error.
        c.wl_surface_commit(w.surface);
        while (!w.configured and !w.closed) {
            if (c.wl_display_dispatch(w.display) < 0) return Error.Disconnected;
        }
    }

    /// Block until at least one event has been processed.
    pub fn dispatch(w: *Window) Error!void {
        if (c.wl_display_dispatch(w.display) < 0) return Error.Disconnected;
    }

    /// The Wayland connection's fd, for the poll loop in main.
    pub fn fd(w: *Window) std.posix.fd_t {
        return c.wl_display_get_fd(w.display);
    }

    pub fn deinit(w: *Window) void {
        w.keyboard.deinit();
        if (w.seat) |s| c.wl_seat_destroy(s);
        if (w.decoration) |d| c.zxdg_toplevel_decoration_v1_destroy(d);
        if (w.toplevel) |t| c.xdg_toplevel_destroy(t);
        if (w.xdg_surface) |s| c.xdg_surface_destroy(s);
        if (w.surface) |s| c.wl_surface_destroy(s);
        if (w.deco_manager) |m| c.zxdg_decoration_manager_v1_destroy(m);
        if (w.wm_base) |b| c.xdg_wm_base_destroy(b);
        if (w.compositor) |co| c.wl_compositor_destroy(co);
        c.wl_registry_destroy(w.registry);
        c.wl_display_disconnect(w.display);
    }
};

// ── Listeners ───────────────────────────────────────────────────────────────
// Listener structs are passed by pointer to libwayland and must outlive the
// object, so they live at file scope.

const registry_listener: c.struct_wl_registry_listener = .{
    .global = handleGlobal,
    .global_remove = handleGlobalRemove,
};

fn handleGlobal(
    data: ?*anyopaque,
    registry: ?*c.struct_wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    const iface = std.mem.span(interface);

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        w.compositor = @ptrCast(c.wl_registry_bind(
            registry,
            name,
            &c.wl_compositor_interface,
            @min(version, 4),
        ));
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        w.wm_base = @ptrCast(c.wl_registry_bind(
            registry,
            name,
            &c.xdg_wm_base_interface,
            @min(version, 3),
        ));
        _ = c.xdg_wm_base_add_listener(w.wm_base, &wm_base_listener, w);
    } else if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
        w.deco_manager = @ptrCast(c.wl_registry_bind(
            registry,
            name,
            &c.zxdg_decoration_manager_v1_interface,
            1,
        ));
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        w.seat = @ptrCast(c.wl_registry_bind(
            registry,
            name,
            &c.wl_seat_interface,
            @min(version, 7),
        ));
        _ = c.wl_seat_add_listener(w.seat, &seat_listener, w);
    }
}

const seat_listener: c.struct_wl_seat_listener = .{
    .capabilities = handleSeatCapabilities,
    .name = handleSeatName,
};

/// Capabilities can change at runtime (a keyboard being unplugged), so this both
/// attaches and detaches rather than assuming a one-time announcement.
fn handleSeatCapabilities(
    data: ?*anyopaque,
    seat: ?*c.struct_wl_seat,
    caps: u32,
) callconv(.c) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    const has_keyboard = caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0;

    if (has_keyboard and w.keyboard.wl_kbd == null) {
        if (c.wl_seat_get_keyboard(seat)) |kbd| w.keyboard.attach(kbd);
    } else if (!has_keyboard) {
        if (w.keyboard.wl_kbd) |kbd| {
            c.wl_keyboard_release(kbd);
            w.keyboard.wl_kbd = null;
        }
    }
    // TODO(phase 3): WL_SEAT_CAPABILITY_POINTER for selection and link clicking.
}

fn handleSeatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.c) void {}

fn handleGlobalRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}

const wm_base_listener: c.struct_xdg_wm_base_listener = .{ .ping = handlePing };

/// Answering ping is mandatory — sway treats an unresponsive client as hung.
fn handlePing(
    _: ?*anyopaque,
    wm_base: ?*c.struct_xdg_wm_base,
    serial: u32,
) callconv(.c) void {
    c.xdg_wm_base_pong(wm_base, serial);
}

const xdg_surface_listener: c.struct_xdg_surface_listener = .{
    .configure = handleSurfaceConfigure,
};

/// The configure/ack handshake: apply whatever the toplevel handler stashed, then
/// acknowledge the serial. Acking is what makes the size authoritative.
fn handleSurfaceConfigure(
    data: ?*anyopaque,
    xdg_surface: ?*c.struct_xdg_surface,
    serial: u32,
) callconv(.c) void {
    const w: *Window = @ptrCast(@alignCast(data.?));

    if (w.pending_width != 0 and w.pending_height != 0) {
        if (w.pending_width != w.width or w.pending_height != w.height) {
            w.width = w.pending_width;
            w.height = w.pending_height;
            w.resized = true;
        }
    }

    c.xdg_surface_ack_configure(xdg_surface, serial);
    w.configured = true;
}

const toplevel_listener: c.struct_xdg_toplevel_listener = .{
    .configure = handleToplevelConfigure,
    .close = handleToplevelClose,
    // Present in xdg-shell v4+; harmless to leave null when unused.
    .configure_bounds = null,
    .wm_capabilities = null,
};

/// Stash the proposed size. It only becomes real once xdg_surface.configure
/// arrives and we ack it — the two events are one atomic transaction.
fn handleToplevelConfigure(
    data: ?*anyopaque,
    _: ?*c.struct_xdg_toplevel,
    width: i32,
    height: i32,
    _: ?*c.struct_wl_array,
) callconv(.c) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    w.pending_width = if (width > 0) @intCast(width) else 0;
    w.pending_height = if (height > 0) @intCast(height) else 0;
}

fn handleToplevelClose(data: ?*anyopaque, _: ?*c.struct_xdg_toplevel) callconv(.c) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    w.closed = true;
}
