//! Clipboard and PRIMARY selection.
//!
//! Wayland has two independent selections and users expect both:
//!
//!   CLIPBOARD  explicit copy/paste, `Ctrl+Shift+C` / `Ctrl+Shift+V`
//!   PRIMARY    select-to-copy, middle-click-to-paste (`primary-selection-v1`)
//!
//! They are separate protocols with near-identical shapes, so both live here.
//!
//! Pasting reads from a pipe the other client writes into. That read is bounded by
//! a timeout rather than looping until EOF: the peer is another process which may
//! be slow, wedged, or malicious, and blocking the terminal's event loop on it
//! would hang the window with no way out.

const std = @import("std");
const c = @import("../c.zig").c;

/// Offered for copies, and requested for pastes in this order.
const mime_utf8 = "text/plain;charset=utf-8";
const mime_plain = "text/plain";

/// How long to wait for the other client to hand over pasted text.
const paste_timeout_ms = 200;
/// Ceiling on a single paste. Generous for real use, but a bound: the source is
/// another process and the size is its choice, not ours.
const paste_max = 4 * 1024 * 1024;

pub const Kind = enum { clipboard, primary };

pub const Clipboard = struct {
    gpa: std.mem.Allocator,

    manager: ?*c.struct_wl_data_device_manager = null,
    device: ?*c.struct_wl_data_device = null,
    primary_manager: ?*c.struct_zwp_primary_selection_device_manager_v1 = null,
    primary_device: ?*c.struct_zwp_primary_selection_device_v1 = null,

    /// Text we are currently offering, one buffer per selection. Owned here and
    /// kept alive until the source is replaced or cancelled, because the compositor
    /// may ask for it at any point after we advertise it.
    clipboard_text: []u8 = &.{},
    primary_text: []u8 = &.{},

    clipboard_source: ?*c.struct_wl_data_source = null,
    primary_source: ?*c.struct_zwp_primary_selection_source_v1 = null,

    /// The most recent offer each selection has advertised to us.
    clipboard_offer: ?*c.struct_wl_data_offer = null,
    primary_offer: ?*c.struct_zwp_primary_selection_offer_v1 = null,
    /// Whether that offer includes a text mime type we can use.
    clipboard_offer_text: bool = false,
    primary_offer_text: bool = false,

    pub fn init(self: *Clipboard, gpa: std.mem.Allocator) void {
        self.* = .{ .gpa = gpa };
    }

    /// Called once the seat and both managers are known.
    pub fn attach(self: *Clipboard, seat: *c.struct_wl_seat) void {
        if (self.manager) |mgr| {
            self.device = c.wl_data_device_manager_get_data_device(mgr, seat);
            if (self.device) |dev| {
                _ = c.wl_data_device_add_listener(dev, &device_listener, self);
            }
        }
        if (self.primary_manager) |mgr| {
            self.primary_device =
                c.zwp_primary_selection_device_manager_v1_get_device(mgr, seat);
            if (self.primary_device) |dev| {
                _ = c.zwp_primary_selection_device_v1_add_listener(
                    dev,
                    &primary_device_listener,
                    self,
                );
            }
        }
    }

    pub fn deinit(self: *Clipboard) void {
        if (self.clipboard_source) |s| c.wl_data_source_destroy(s);
        if (self.primary_source) |s| c.zwp_primary_selection_source_v1_destroy(s);
        if (self.device) |d| c.wl_data_device_release(d);
        if (self.primary_device) |d| c.zwp_primary_selection_device_v1_destroy(d);
        if (self.manager) |m| c.wl_data_device_manager_destroy(m);
        if (self.primary_manager) |m| {
            c.zwp_primary_selection_device_manager_v1_destroy(m);
        }
        self.gpa.free(self.clipboard_text);
        self.gpa.free(self.primary_text);
    }

    /// Take ownership of a selection. `serial` must come from a recent input event;
    /// the compositor rejects stale serials, which is what stops a background
    /// client from silently stealing the clipboard.
    pub fn offer(self: *Clipboard, kind: Kind, text: []const u8, serial: u32) void {
        const copy = self.gpa.dupe(u8, text) catch return;

        switch (kind) {
            .clipboard => {
                const mgr = self.manager orelse {
                    self.gpa.free(copy);
                    return;
                };
                const dev = self.device orelse {
                    self.gpa.free(copy);
                    return;
                };
                if (self.clipboard_source) |old| c.wl_data_source_destroy(old);
                self.gpa.free(self.clipboard_text);
                self.clipboard_text = copy;

                const src = c.wl_data_device_manager_create_data_source(mgr);
                self.clipboard_source = src;
                if (src) |s| {
                    _ = c.wl_data_source_add_listener(s, &source_listener, self);
                    c.wl_data_source_offer(s, mime_utf8);
                    c.wl_data_source_offer(s, mime_plain);
                    // Legacy names some X11 clients still ask for via XWayland.
                    c.wl_data_source_offer(s, "UTF8_STRING");
                    c.wl_data_source_offer(s, "STRING");
                    c.wl_data_source_offer(s, "TEXT");
                    c.wl_data_device_set_selection(dev, s, serial);
                }
            },
            .primary => {
                const mgr = self.primary_manager orelse {
                    self.gpa.free(copy);
                    return;
                };
                const dev = self.primary_device orelse {
                    self.gpa.free(copy);
                    return;
                };
                if (self.primary_source) |old| {
                    c.zwp_primary_selection_source_v1_destroy(old);
                }
                self.gpa.free(self.primary_text);
                self.primary_text = copy;

                const src = c.zwp_primary_selection_device_manager_v1_create_source(mgr);
                self.primary_source = src;
                if (src) |s| {
                    _ = c.zwp_primary_selection_source_v1_add_listener(
                        s,
                        &primary_source_listener,
                        self,
                    );
                    c.zwp_primary_selection_source_v1_offer(s, mime_utf8);
                    c.zwp_primary_selection_source_v1_offer(s, mime_plain);
                    c.zwp_primary_selection_device_v1_set_selection(dev, s, serial);
                }
            },
        }
    }

    /// Fetch a selection's contents. Returns null when nothing is on offer.
    /// Caller owns the result.
    pub fn paste(
        self: *Clipboard,
        kind: Kind,
        display: *c.struct_wl_display,
    ) ?[]u8 {
        // When we own the selection, answer from our own buffer instead of going
        // through the compositor.
        //
        // Not an optimisation — a correctness fix. The round trip would have the
        // compositor ask *us* for the data via a `send` event, but we are about to
        // block in poll() on the pipe and would never dispatch it. Nor can we
        // dispatch while waiting: `paste` runs inside a pointer/keyboard listener,
        // itself inside wl_display_dispatch_pending, and libwayland does not allow
        // re-entrant dispatch. So the paste would deadlock until the timeout fired
        // and then yield nothing — copying inside maai and pasting back into
        // maai silently did nothing.
        //
        // `*_source != null` is a reliable ownership test: the compositor sends
        // `cancelled` when another client takes the selection, and that clears it.
        switch (kind) {
            .clipboard => if (self.clipboard_source != null) {
                return self.gpa.dupe(u8, self.clipboard_text) catch null;
            },
            .primary => if (self.primary_source != null) {
                return self.gpa.dupe(u8, self.primary_text) catch null;
            },
        }

        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return null;
        const read_fd = fds[0];
        const write_fd = fds[1];

        switch (kind) {
            .clipboard => {
                const off = self.clipboard_offer orelse {
                    _ = std.c.close(read_fd);
                    _ = std.c.close(write_fd);
                    return null;
                };
                if (!self.clipboard_offer_text) {
                    _ = std.c.close(read_fd);
                    _ = std.c.close(write_fd);
                    return null;
                }
                c.wl_data_offer_receive(off, mime_utf8, write_fd);
            },
            .primary => {
                const off = self.primary_offer orelse {
                    _ = std.c.close(read_fd);
                    _ = std.c.close(write_fd);
                    return null;
                };
                if (!self.primary_offer_text) {
                    _ = std.c.close(read_fd);
                    _ = std.c.close(write_fd);
                    return null;
                }
                c.zwp_primary_selection_offer_v1_receive(off, mime_utf8, write_fd);
            },
        }

        // The request has to reach the compositor before anyone writes, and our
        // copy of the write end must be closed or we never see EOF.
        _ = c.wl_display_flush(display);
        _ = std.c.close(write_fd);
        defer _ = std.c.close(read_fd);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);

        var buf: [4096]u8 = undefined;
        while (out.items.len < paste_max) {
            var pfd = [_]std.posix.pollfd{
                .{ .fd = read_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&pfd, paste_timeout_ms) catch break;
            if (ready == 0) break; // peer went quiet; take what we have

            const n = std.c.read(read_fd, &buf, buf.len);
            if (n <= 0) break; // EOF or error
            out.appendSlice(self.gpa, buf[0..@intCast(n)]) catch break;
        }

        return out.toOwnedSlice(self.gpa) catch null;
    }
};

// ── CLIPBOARD listeners ─────────────────────────────────────────────────────

const source_listener: c.struct_wl_data_source_listener = .{
    .target = sourceTarget,
    .send = sourceSend,
    .cancelled = sourceCancelled,
    .dnd_drop_performed = sourceDndDrop,
    .dnd_finished = sourceDndFinished,
    .action = sourceAction,
};

fn sourceSend(
    data: ?*anyopaque,
    _: ?*c.struct_wl_data_source,
    _: [*c]const u8,
    fd: i32,
) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data.?));
    writeAllAndClose(fd, self.clipboard_text);
}

fn sourceCancelled(data: ?*anyopaque, source: ?*c.struct_wl_data_source) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data.?));
    // Another client took the selection; our source is dead.
    c.wl_data_source_destroy(source);
    if (self.clipboard_source == source) self.clipboard_source = null;
}

fn sourceTarget(_: ?*anyopaque, _: ?*c.struct_wl_data_source, _: [*c]const u8) callconv(.c) void {}
fn sourceDndDrop(_: ?*anyopaque, _: ?*c.struct_wl_data_source) callconv(.c) void {}
fn sourceDndFinished(_: ?*anyopaque, _: ?*c.struct_wl_data_source) callconv(.c) void {}
fn sourceAction(_: ?*anyopaque, _: ?*c.struct_wl_data_source, _: u32) callconv(.c) void {}

const device_listener: c.struct_wl_data_device_listener = .{
    .data_offer = deviceDataOffer,
    .enter = deviceEnter,
    .leave = deviceLeave,
    .motion = deviceMotion,
    .drop = deviceDrop,
    .selection = deviceSelection,
};

const offer_listener: c.struct_wl_data_offer_listener = .{
    .offer = offerMime,
    .source_actions = offerSourceActions,
    .action = offerAction,
};

fn deviceDataOffer(
    data: ?*anyopaque,
    _: ?*c.struct_wl_data_device,
    offer_obj: ?*c.struct_wl_data_offer,
) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data.?));
    // A fresh offer advertises its own mime list, so the previous offer's answer
    // must not carry over — otherwise we would request a type this source never
    // offered and get nothing back.
    self.clipboard_offer_text = false;
    // The mime list arrives as separate events on this object; listen before it
    // is handed to us as a selection.
    if (offer_obj) |off| _ = c.wl_data_offer_add_listener(off, &offer_listener, self);
}

fn offerMime(
    data: ?*anyopaque,
    _: ?*c.struct_wl_data_offer,
    mime: [*c]const u8,
) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data.?));
    const m = std.mem.span(mime);
    if (std.mem.eql(u8, m, mime_utf8)) self.clipboard_offer_text = true;
}

fn offerSourceActions(_: ?*anyopaque, _: ?*c.struct_wl_data_offer, _: u32) callconv(.c) void {}
fn offerAction(_: ?*anyopaque, _: ?*c.struct_wl_data_offer, _: u32) callconv(.c) void {}

fn deviceSelection(
    data: ?*anyopaque,
    _: ?*c.struct_wl_data_device,
    offer_obj: ?*c.struct_wl_data_offer,
) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data.?));
    if (self.clipboard_offer) |old| c.wl_data_offer_destroy(old);
    self.clipboard_offer = offer_obj;
    if (offer_obj == null) self.clipboard_offer_text = false;
}

fn deviceEnter(
    _: ?*anyopaque,
    _: ?*c.struct_wl_data_device,
    _: u32,
    _: ?*c.struct_wl_surface,
    _: i32,
    _: i32,
    _: ?*c.struct_wl_data_offer,
) callconv(.c) void {}
fn deviceLeave(_: ?*anyopaque, _: ?*c.struct_wl_data_device) callconv(.c) void {}
fn deviceMotion(_: ?*anyopaque, _: ?*c.struct_wl_data_device, _: u32, _: i32, _: i32) callconv(.c) void {}
fn deviceDrop(_: ?*anyopaque, _: ?*c.struct_wl_data_device) callconv(.c) void {}

// ── PRIMARY listeners ───────────────────────────────────────────────────────

const primary_source_listener: c.struct_zwp_primary_selection_source_v1_listener = .{
    .send = primarySourceSend,
    .cancelled = primarySourceCancelled,
};

fn primarySourceSend(
    data: ?*anyopaque,
    _: ?*c.struct_zwp_primary_selection_source_v1,
    _: [*c]const u8,
    fd: i32,
) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data.?));
    writeAllAndClose(fd, self.primary_text);
}

fn primarySourceCancelled(
    data: ?*anyopaque,
    source: ?*c.struct_zwp_primary_selection_source_v1,
) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data.?));
    c.zwp_primary_selection_source_v1_destroy(source);
    if (self.primary_source == source) self.primary_source = null;
}

const primary_device_listener: c.struct_zwp_primary_selection_device_v1_listener = .{
    .data_offer = primaryDataOffer,
    .selection = primarySelection,
};

const primary_offer_listener: c.struct_zwp_primary_selection_offer_v1_listener = .{
    .offer = primaryOfferMime,
};

fn primaryDataOffer(
    data: ?*anyopaque,
    _: ?*c.struct_zwp_primary_selection_device_v1,
    offer_obj: ?*c.struct_zwp_primary_selection_offer_v1,
) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data.?));
    // Same reasoning as the CLIPBOARD path: the flag describes the newest offer.
    self.primary_offer_text = false;
    if (offer_obj) |off| {
        _ = c.zwp_primary_selection_offer_v1_add_listener(off, &primary_offer_listener, self);
    }
}

fn primaryOfferMime(
    data: ?*anyopaque,
    _: ?*c.struct_zwp_primary_selection_offer_v1,
    mime: [*c]const u8,
) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data.?));
    if (std.mem.eql(u8, std.mem.span(mime), mime_utf8)) self.primary_offer_text = true;
}

fn primarySelection(
    data: ?*anyopaque,
    _: ?*c.struct_zwp_primary_selection_device_v1,
    offer_obj: ?*c.struct_zwp_primary_selection_offer_v1,
) callconv(.c) void {
    const self: *Clipboard = @ptrCast(@alignCast(data.?));
    if (self.primary_offer) |old| c.zwp_primary_selection_offer_v1_destroy(old);
    self.primary_offer = offer_obj;
    if (offer_obj == null) self.primary_offer_text = false;
}

/// Hand our text to a requesting client. The fd is ours to close either way.
fn writeAllAndClose(fd: i32, text: []const u8) void {
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < text.len) {
        const n = std.c.write(fd, text[off..].ptr, text.len - off);
        if (n <= 0) {
            // EAGAIN cannot happen on a blocking fd; anything else means the peer
            // gave up on us, and there is nothing useful to do about it.
            if (std.c.errno(n) == .INTR) continue;
            return;
        }
        off += @intCast(n);
    }
}
