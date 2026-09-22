//! A control socket, so something outside can focus a tab.
//!
//! maai is one process per *window*, and each window holds several tabs. Focusing
//! the right window from outside is already a solved problem — sway's tree carries
//! our pid, and `swaymsg '[con_id=N] focus'` finishes the job. Focusing the right
//! *tab* had no answer at all, because until this file a tab was a purely internal
//! thing: no window, no pid, no handle any other process had ever heard of.
//!
//! What a tab does have is its pseudo-terminal, and `/dev/pts/N` is visible from
//! the outside. It shows up in `ps`, in `/proc/<pid>/fdinfo`, and a process can
//! read its own. That makes the pts index the one name a session and an outside
//! observer can both pronounce, which is why the whole protocol reduces to *focus
//! the tab whose pty is pts N*.
//!
//! Two deliberate choices about what this is not:
//!
//!   * **The access control is the filesystem's, not ours.** The socket lives under
//!     `$XDG_RUNTIME_DIR`, which the session manager already creates 0700 and owned
//!     by one user. Inventing a token or a handshake here would add a thing to get
//!     wrong without adding a thing an attacker has to get past.
//!   * **Three fixed commands, and none of them writes to a child.** A control
//!     surface that could inject input into a shell would be a far larger promise
//!     than "jump to that tab", and a far larger hole if the directory rule above
//!     ever failed.
//!
//! Like the config watcher, this is an *optional* fd in the main poll loop. If any
//! part of the setup fails — no `XDG_RUNTIME_DIR`, a read-only runtime directory,
//! a kernel with no unix sockets — `fd` stays -1, poll ignores it, and maai behaves
//! exactly as it did before this file existed.

const std = @import("std");

const Addr = std.posix.sockaddr.un;

/// Pending connections the kernel will hold for us. A handful, because clients
/// arrive one per user gesture and each is served in microseconds.
const backlog = 8;

/// Longest request read from a client. Every command is under twenty bytes; the cap
/// is what stops a client that connects and then floods from doing anything but
/// filling this buffer once.
const max_request = 256;

/// Longest reply. `list` is the only one that grows: two bytes of `ok`, then at
/// most twelve per tab — a separator, the active marker, and ten digits of an i32 —
/// which covers far more tabs than a window will ever hold.
const max_reply = 1024;

/// How long one client may hold the render loop. The peer is a process on this
/// machine sending a dozen bytes, so anything slower than this is a client that has
/// wandered off rather than a slow link — and a frame must not wait for it either
/// way.
const client_timeout_ms = 50;

// ── the protocol ────────────────────────────────────────────────────────────

/// The tabs, as seen from out here: a pts index each, and which one is in front.
/// Deliberately not a list of tabs — this module has no business knowing what a tab
/// is made of.
pub const Tabs = struct {
    /// One entry per tab, in tab order. -1 for a tab whose pty index is unknown.
    pts: []const i32,
    active: usize,
};

/// The two things the socket can ask of whoever owns the tabs.
pub const Handler = struct {
    ctx: *anyopaque,
    tabs: *const fn (ctx: *anyopaque) Tabs,
    /// Focus the tab whose pty is `pts`. False when no tab has that index.
    focus: *const fn (ctx: *anyopaque, pts: i32) bool,
};

/// Answer one command line, writing into `out` when the reply is not a constant.
///
/// Pure apart from the handler, which is the point: the wire format is the part an
/// external client is written against, and it can be pinned down by tests without a
/// socket, a compositor or a tab anywhere in sight.
pub fn respond(line: []const u8, h: Handler, out: []u8) []const u8 {
    if (std.mem.eql(u8, line, "ping")) return "ok\n";
    if (std.mem.eql(u8, line, "list")) return formatList(h.tabs(h.ctx), out);
    if (parseFocus(line)) |pts| {
        return if (h.focus(h.ctx, pts)) "ok\n" else "err no-such-pts\n";
    }
    return "err bad-command\n";
}

/// The first line of a request, with surrounding blanks removed.
///
/// A *line*, because a client is free to hold the connection open and say more, and
/// trimmed because a client that thinks in CRLF should not have its perfectly good
/// command rejected over the `\r`.
fn firstLine(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, '\n') orelse buf.len;
    return std.mem.trim(u8, buf[0..end], " \t\r");
}

/// The index in a `focus-pts N` line, or null for anything else.
///
/// A `focus-pts` whose argument is not a plain non-negative number returns null too,
/// so it is answered as a bad command rather than as a tab that does not exist. The
/// distinction matters to a client deciding whether to retry: `no-such-pts` means
/// the session is gone, `bad-command` means the client is broken.
fn parseFocus(line: []const u8) ?i32 {
    const verb = "focus-pts ";
    if (!std.mem.startsWith(u8, line, verb)) return null;
    const arg = std.mem.trim(u8, line[verb.len..], " \t");
    // u31 rather than i32: a pts index is never negative, and -1 is our own marker
    // for "unknown", which must not be addressable from outside.
    return std.fmt.parseUnsigned(u31, arg, 10) catch null;
}

fn formatList(t: Tabs, out: []u8) []const u8 {
    // One byte held back, so the terminator the client reads up to always fits.
    const body = out[0 .. out.len - 1];
    @memcpy(body[0..2], "ok");
    var n: usize = 2;

    for (t.pts, 0..) |pts, i| {
        const sep: []const u8 = if (i == 0) " " else ",";
        const mark: []const u8 = if (i == t.active) "*" else "";
        const piece = if (pts < 0)
            std.fmt.bufPrint(body[n..], "{s}{s}?", .{ sep, mark }) catch break
        else
            std.fmt.bufPrint(body[n..], "{s}{s}{d}", .{ sep, mark, pts }) catch break;
        n += piece.len;
    }

    out[n] = '\n';
    return out[0 .. n + 1];
}

// ── the socket ──────────────────────────────────────────────────────────────

pub const Control = struct {
    fd: i32 = -1,
    handler: Handler,
    /// The bound address. Kept whole because `deinit` has to unlink the same path
    /// again, and this is already a NUL-terminated copy of it.
    addr: Addr = .{ .path = undefined },

    /// Bind `$XDG_RUNTIME_DIR/maai/<pid>.sock`, or return null having changed
    /// nothing. Named after our own pid so every window in a session gets its own
    /// socket without any of them coordinating.
    pub fn init(handler: Handler) ?Control {
        const run = std.mem.span(std.c.getenv("XDG_RUNTIME_DIR") orelse return null);
        if (run.len == 0) return null;

        var self = Control{ .handler = handler };

        var dirz: [@typeInfo(@FieldType(Addr, "path")).array.len]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&dirz, "{s}/maai", .{run}) catch return null;
        // EEXIST is the ordinary case: the second window of a session finds the
        // directory the first one made.
        if (std.c.mkdir(dir, 0o700) != 0 and std.c.errno(@as(c_int, -1)) != .EXIST) {
            return null;
        }

        _ = std.fmt.bufPrintZ(
            &self.addr.path,
            "{s}/maai/{d}.sock",
            .{ run, std.c.getpid() },
        ) catch return null;

        // Non-blocking because the fd shares the main poll loop, and CLOEXEC so no
        // shell we spawn inherits a handle on our own control surface.
        const fd = std.c.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        );
        if (fd < 0) return null;
        self.fd = fd;

        if (!self.listen()) {
            _ = std.c.close(fd);
            return null;
        }
        return self;
    }

    fn listen(self: *Control) bool {
        var e = self.bindOnce();
        if (e == .ADDRINUSE) {
            // A maai that crashed without unlinking, whose pid the kernel has since
            // handed to us. Removing the file is safe in a way that unlinking an
            // arbitrary socket would not be: the path is named after *our* pid, so
            // nothing that is still alive can legitimately own it.
            _ = std.c.unlink(@ptrCast(&self.addr.path));
            e = self.bindOnce();
        }
        if (e != .SUCCESS) return false;
        return std.c.listen(self.fd, backlog) == 0;
    }

    fn bindOnce(self: *Control) std.posix.E {
        const rc = std.c.bind(self.fd, @ptrCast(&self.addr), @sizeOf(Addr));
        return if (rc == 0) .SUCCESS else std.c.errno(rc);
    }

    pub fn deinit(self: *Control) void {
        if (self.fd < 0) return;
        _ = std.c.close(self.fd);
        // The path outlives the socket unless somebody removes it, and the next
        // process handed this pid would find it sitting in the way.
        _ = std.c.unlink(@ptrCast(&self.addr.path));
        self.fd = -1;
    }

    /// Serve everyone already waiting. Called when poll reports the listening fd
    /// readable.
    ///
    /// Loops rather than accepting once: several clients can pile up between two
    /// turns of the event loop, and one left queued would wait for the next
    /// keystroke or frame before being answered.
    pub fn drain(self: *Control) void {
        if (self.fd < 0) return;
        while (true) {
            const fd = std.c.accept4(self.fd, null, null, std.posix.SOCK.CLOEXEC);
            if (fd < 0) return;
            defer _ = std.c.close(fd);
            serve(fd, self.handler);
        }
    }
};

/// One connection, start to finish, on the main thread.
///
/// A *blocking* read with a short deadline, rather than a second non-blocking fd in
/// the poll array with a per-connection state machine behind it. The whole exchange
/// is a dozen bytes each way between two processes on one machine; the timeout is
/// there only so a client that connects and says nothing cannot hold a frame.
fn serve(fd: i32, h: Handler) void {
    const tv = std.posix.timeval{ .sec = 0, .usec = client_timeout_ms * std.time.us_per_ms };
    const opt = std.mem.asBytes(&tv);
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, opt) catch return;
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, opt) catch return;

    var req: [max_request]u8 = undefined;
    const n = std.c.read(fd, &req, req.len);
    if (n <= 0) return;

    var rep: [max_reply]u8 = undefined;
    const reply = respond(firstLine(req[0..@intCast(n)]), h, &rep);
    _ = std.c.write(fd, reply.ptr, reply.len);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A stand-in for the App: a fixed set of tabs and a record of what was focused.
const FakeTabs = struct {
    pts: []const i32,
    active: usize = 0,
    focused: i32 = -1,

    fn handler(self: *FakeTabs) Handler {
        return .{ .ctx = self, .tabs = snapshot, .focus = focus };
    }

    fn snapshot(ctx: *anyopaque) Tabs {
        const self: *FakeTabs = @ptrCast(@alignCast(ctx));
        return .{ .pts = self.pts, .active = self.active };
    }

    fn focus(ctx: *anyopaque, pts: i32) bool {
        const self: *FakeTabs = @ptrCast(@alignCast(ctx));
        for (self.pts) |p| {
            if (p != pts) continue;
            self.focused = pts;
            return true;
        }
        return false;
    }
};

fn ask(f: *FakeTabs, line: []const u8, out: []u8) []const u8 {
    return respond(firstLine(line), f.handler(), out);
}

test "ping answers ok" {
    var f = FakeTabs{ .pts = &.{} };
    var out: [max_reply]u8 = undefined;
    try testing.expectEqualStrings("ok\n", ask(&f, "ping\n", &out));
}

test "list reports every tab in order, marking the active one" {
    // The exact shape a separate client is written against, so it is pinned here
    // rather than left to whatever the formatter happens to produce.
    var f = FakeTabs{ .pts = &.{ 7, 12, 3 }, .active = 1 };
    var out: [max_reply]u8 = undefined;
    try testing.expectEqualStrings("ok 7,*12,3\n", ask(&f, "list\n", &out));

    f.active = 0;
    try testing.expectEqualStrings("ok *7,12,3\n", ask(&f, "list\n", &out));
}

test "a tab whose pts is unknown is reported rather than skipped" {
    // Dropping it would shift every later tab's position, and a client that counts
    // would then focus the wrong one.
    var f = FakeTabs{ .pts = &.{ 7, -1, 3 }, .active = 2 };
    var out: [max_reply]u8 = undefined;
    try testing.expectEqualStrings("ok 7,?,*3\n", ask(&f, "list\n", &out));
}

test "focus-pts focuses the tab with that pts" {
    var f = FakeTabs{ .pts = &.{ 7, 12, 3 } };
    var out: [max_reply]u8 = undefined;
    try testing.expectEqualStrings("ok\n", ask(&f, "focus-pts 12\n", &out));
    try testing.expectEqual(@as(i32, 12), f.focused);
}

test "focus-pts on an unknown pts is refused" {
    var f = FakeTabs{ .pts = &.{ 7, 12, 3 } };
    var out: [max_reply]u8 = undefined;
    try testing.expectEqualStrings("err no-such-pts\n", ask(&f, "focus-pts 99\n", &out));
    try testing.expectEqual(@as(i32, -1), f.focused);
}

test "a tab whose pts is unknown cannot be addressed" {
    // -1 is our marker for "the kernel would not tell us", not an index. Letting
    // `focus-pts -1` match it would make an unaddressable tab addressable by
    // accident, and pick an arbitrary one when several are unknown.
    var f = FakeTabs{ .pts = &.{ -1, 12 } };
    var out: [max_reply]u8 = undefined;
    try testing.expectEqualStrings("err bad-command\n", ask(&f, "focus-pts -1\n", &out));
    try testing.expectEqual(@as(i32, -1), f.focused);
}

test "anything else is a bad command" {
    var f = FakeTabs{ .pts = &.{7} };
    var out: [max_reply]u8 = undefined;
    for ([_][]const u8{
        "",
        "pong\n",
        "LIST\n",
        "list extra\n",
        "focus-pts\n",
        "focus-pts \n",
        "focus-pts abc\n",
        "focus-pts 0x7\n",
        "focus-pts 7 8\n",
        // A client that sends a shell-ish line gets the same flat refusal: there is
        // no command here that takes anything but a number.
        "focus-pts $(id)\n",
    }) |bad| {
        try testing.expectEqualStrings("err bad-command\n", ask(&f, bad, &out));
    }
    try testing.expectEqual(@as(i32, -1), f.focused);
}

test "a command is read up to the first newline, CRLF and all" {
    var f = FakeTabs{ .pts = &.{7} };
    var out: [max_reply]u8 = undefined;
    try testing.expectEqualStrings("ok\n", ask(&f, "ping\r\nlist\n", &out));
    try testing.expectEqualStrings("ok\n", ask(&f, "  ping  \n", &out));
    // No terminator at all still parses: a client that closes its write side
    // without a newline has still said what it meant.
    try testing.expectEqualStrings("ok\n", ask(&f, "ping", &out));
}

test "a window with no tabs still answers list" {
    var f = FakeTabs{ .pts = &.{} };
    var out: [max_reply]u8 = undefined;
    try testing.expectEqualStrings("ok\n", ask(&f, "list\n", &out));
}

test "the socket binds, serves a real client, and cleans up after itself" {
    var f = FakeTabs{ .pts = &.{ 7, 12 }, .active = 1 };
    var ctl = Control.init(f.handler()) orelse return error.SkipZigTest;
    defer ctl.deinit();

    const path: [*:0]const u8 = @ptrCast(&ctl.addr.path);

    // A real connect over the real socket, because the interesting failures — a
    // path that will not fit, a directory that is not there, an fd left blocking —
    // all live below `respond` and none of them show up in a parsing test.
    const client = std.c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    try testing.expect(client >= 0);
    try testing.expectEqual(
        @as(c_int, 0),
        std.c.connect(client, @ptrCast(&ctl.addr), @sizeOf(Addr)),
    );
    const req = "focus-pts 12\n";
    try testing.expect(std.c.write(client, req, req.len) == req.len);

    // The accept side has to happen after the client has written, since `serve`
    // blocks on the read — which is exactly the arrangement the timeout guards.
    ctl.drain();

    var buf: [64]u8 = undefined;
    const n = std.c.read(client, &buf, buf.len);
    _ = std.c.close(client);
    try testing.expect(n > 0);
    try testing.expectEqualStrings("ok\n", buf[0..@intCast(n)]);
    try testing.expectEqual(@as(i32, 12), f.focused);

    // Nothing left behind in the runtime directory.
    ctl.deinit();
    try testing.expect(std.c.unlink(path) != 0);
}

test "a stale socket from a crashed predecessor does not lock the pid out" {
    var f = FakeTabs{ .pts = &.{} };
    var crashed = Control.init(f.handler()) orelse return error.SkipZigTest;

    // What a SIGKILL leaves: the fd is gone, the file in the runtime directory is
    // not. Since the path is named after a pid, the next process to be given that
    // pid walks straight into it.
    _ = std.c.close(crashed.fd);
    crashed.fd = -1;

    var successor = Control.init(f.handler()) orelse return error.SkipZigTest;
    defer successor.deinit();
    try testing.expect(successor.fd >= 0);
}
