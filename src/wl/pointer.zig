//! Pointer input: selection drags, middle-click paste, wheel scrolling, and the
//! cursor shape.
//!
//! Surface-local coordinates are passed through as floats; converting them to grid
//! cells needs font metrics, which live with the application, so that mapping stays
//! out of here.

const std = @import("std");
const c = @import("../c.zig").c;

pub const button_left: u32 = 0x110; // BTN_LEFT
pub const button_middle: u32 = 0x112; // BTN_MIDDLE
pub const button_right: u32 = 0x111; // BTN_RIGHT

// Side buttons. Which pair a mouse reports is not consistent: most five-button
// devices send SIDE/EXTRA for back/forward, some send BACK/FORWARD, so both are
// mapped rather than guessing.
pub const button_side: u32 = 0x113; // BTN_SIDE
pub const button_extra: u32 = 0x114; // BTN_EXTRA
pub const button_forward: u32 = 0x115; // BTN_FORWARD
pub const button_back: u32 = 0x116; // BTN_BACK

pub const Handler = struct {
    ctx: *anyopaque,
    motion: *const fn (*anyopaque, x: f64, y: f64) void,
    button: *const fn (*anyopaque, button: u32, pressed: bool, serial: u32) void,
    /// Vertical wheel movement in lines; negative scrolls towards history.
    axis: *const fn (*anyopaque, lines: f64) void,
};

pub const Pointer = struct {
    wl_pointer: ?*c.struct_wl_pointer = null,
    shape_manager: ?*c.struct_wp_cursor_shape_manager_v1 = null,
    shape_device: ?*c.struct_wp_cursor_shape_device_v1 = null,
    handler: ?Handler = null,

    /// Latest surface-local position, kept so button events can report where they
    /// happened — wl_pointer.button carries no coordinates of its own.
    x: f64 = 0,
    y: f64 = 0,

    /// Accumulates fractional wheel motion from high-resolution devices, so a
    /// touchpad's many small deltas still add up to whole lines.
    axis_accum: f64 = 0,

    /// Serial of the last `enter`. cursor-shape-v1 requires it for every shape
    /// change, not just the first.
    enter_serial: u32 = 0,
    /// Current shape, so a change per motion event does not become a request per
    /// motion event. Null means unknown — the compositor resets the cursor on
    /// `enter`, so the next request has to go out even if the shape is unchanged.
    shape: ?Shape = null,

    pub fn attach(self: *Pointer, wl_pointer: *c.struct_wl_pointer) void {
        self.wl_pointer = wl_pointer;
        _ = c.wl_pointer_add_listener(wl_pointer, &pointer_listener, self);

        if (self.shape_manager) |mgr| {
            self.shape_device = c.wp_cursor_shape_manager_v1_get_pointer(mgr, wl_pointer);
        }
    }

    pub fn deinit(self: *Pointer) void {
        if (self.shape_device) |d| c.wp_cursor_shape_device_v1_destroy(d);
        if (self.shape_manager) |m| c.wp_cursor_shape_manager_v1_destroy(m);
        if (self.wl_pointer) |p| c.wl_pointer_release(p);
    }

    /// Via cursor-shape-v1 the compositor picks the theme and size, so we neither
    /// load an XCursor theme nor manage a cursor surface.
    pub const Shape = enum {
        /// An I-beam over the grid.
        text,
        /// A hand over something clickable.
        pointer,

        fn value(self: Shape) u32 {
            return switch (self) {
                .text => c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT,
                .pointer => c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER,
            };
        }
    };

    pub fn setShape(self: *Pointer, shape: Shape) void {
        if (self.shape == shape) return;
        const dev = self.shape_device orelse return;
        // The protocol wants the serial of the *enter* event, not of whatever
        // prompted the change, so the entry serial is kept for exactly this.
        if (self.enter_serial == 0) return;
        c.wp_cursor_shape_device_v1_set_shape(dev, self.enter_serial, shape.value());
        self.shape = shape;
    }
};

const pointer_listener: c.struct_wl_pointer_listener = .{
    .enter = handleEnter,
    .leave = handleLeave,
    .motion = handleMotion,
    .button = handleButton,
    .axis = handleAxis,
    // Present from wl_pointer v5 onwards. libwayland calls whatever the compositor
    // sends, so every one of these must be a real function, not null.
    .frame = handleFrame,
    .axis_source = handleAxisSource,
    .axis_stop = handleAxisStop,
    .axis_discrete = handleAxisDiscrete,
    .axis_value120 = handleAxisValue120,
    .axis_relative_direction = handleAxisRelativeDirection,
};

fn handleEnter(
    data: ?*anyopaque,
    _: ?*c.struct_wl_pointer,
    serial: u32,
    _: ?*c.struct_wl_surface,
    sx: c.wl_fixed_t,
    sy: c.wl_fixed_t,
) callconv(.c) void {
    const self: *Pointer = @ptrCast(@alignCast(data.?));
    self.x = fixedToDouble(sx);
    self.y = fixedToDouble(sy);
    self.enter_serial = serial;
    self.shape = null;
    self.setShape(.text);
}

fn handleLeave(
    _: ?*anyopaque,
    _: ?*c.struct_wl_pointer,
    _: u32,
    _: ?*c.struct_wl_surface,
) callconv(.c) void {}

fn handleMotion(
    data: ?*anyopaque,
    _: ?*c.struct_wl_pointer,
    _: u32,
    sx: c.wl_fixed_t,
    sy: c.wl_fixed_t,
) callconv(.c) void {
    const self: *Pointer = @ptrCast(@alignCast(data.?));
    self.x = fixedToDouble(sx);
    self.y = fixedToDouble(sy);
    if (self.handler) |h| h.motion(h.ctx, self.x, self.y);
}

fn handleButton(
    data: ?*anyopaque,
    _: ?*c.struct_wl_pointer,
    serial: u32,
    _: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    const self: *Pointer = @ptrCast(@alignCast(data.?));
    if (self.handler) |h| {
        h.button(h.ctx, button, state == c.WL_POINTER_BUTTON_STATE_PRESSED, serial);
    }
}

fn handleAxis(
    data: ?*anyopaque,
    _: ?*c.struct_wl_pointer,
    _: u32,
    axis: u32,
    value: c.wl_fixed_t,
) callconv(.c) void {
    const self: *Pointer = @ptrCast(@alignCast(data.?));
    if (axis != c.WL_POINTER_AXIS_VERTICAL_SCROLL) return;

    // The value is in surface units; roughly 10 per notch on a mouse wheel.
    self.axis_accum += fixedToDouble(value) / 10.0;
    const whole = @trunc(self.axis_accum);
    if (whole != 0) {
        self.axis_accum -= whole;
        if (self.handler) |h| h.axis(h.ctx, whole);
    }
}

fn handleFrame(_: ?*anyopaque, _: ?*c.struct_wl_pointer) callconv(.c) void {}
fn handleAxisSource(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32) callconv(.c) void {}
fn handleAxisStop(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn handleAxisDiscrete(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn handleAxisValue120(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn handleAxisRelativeDirection(
    _: ?*anyopaque,
    _: ?*c.struct_wl_pointer,
    _: u32,
    _: u32,
) callconv(.c) void {}

/// wl_fixed_t is a 24.8 fixed-point number.
fn fixedToDouble(v: c.wl_fixed_t) f64 {
    return @as(f64, @floatFromInt(v)) / 256.0;
}
