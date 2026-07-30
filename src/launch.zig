//! Handing a URL to the desktop's handler.
//!
//! This is the sharpest security boundary in the program (PLAN.md §7). Everything
//! on screen was written by another process, and clicking turns some of those bytes
//! into arguments to a program. The rules, in order of how badly they matter:
//!
//!   1. **An argv array, never a shell string.** `posix_spawnp` takes the URL as
//!      one element of `argv`, so no amount of `$(...)`, backticks, `;` or newlines
//!      in it can become a second command. A `system()` call here would be a remote
//!      code execution bug reachable by printing a line of text.
//!   2. **A scheme allowlist**, checked here and not only by the scanner, because
//!      OSC 8 hyperlinks carry a URI the writing process chose freely.
//!   3. **No control characters and a length cap**, so nothing can smuggle a NUL to
//!      truncate the argument or a newline past a handler that re-parses it.
//!
//! Signal dispositions survive `exec`, and this process ignores SIGPIPE — so the
//! handler is spawned with signals reset, for the same reason `Pty.spawn` does it
//! for the shell.

const std = @import("std");
const c = @import("c.zig").c;
const url = @import("term/url.zig");

/// The desktop's URL handler. `xdg-open` rather than a hardcoded browser so the
/// user's own default applies, including for `mailto:` and `file://`.
pub const opener = "xdg-open";

/// Nothing longer is a link worth opening, and the bound keeps the copy on the
/// stack. Browsers themselves stop well before this.
pub const max_url_len = 2048;

/// Spawn the handler for `link`. Returns the child's pid to be reaped, or null if
/// the link was rejected or the spawn failed.
pub fn open(link: []const u8) ?std.c.pid_t {
    return openWith(opener, link);
}

/// `open`, with the program named explicitly. Separate so the spawn plumbing can be
/// exercised against something harmless in a test, and so phase 6 can make the
/// launcher configurable without touching any of the checks below.
pub fn openWith(program: [*:0]const u8, link: []const u8) ?std.c.pid_t {
    if (link.len == 0 or link.len > max_url_len) return null;
    if (!url.allowedScheme(link)) return null;
    // Printable, non-space bytes only. A NUL would truncate the argument; a newline
    // or an ESC could survive into something that re-parses it downstream.
    for (link) |ch| if (ch <= 0x20 or ch == 0x7f) return null;

    var buf: [max_url_len + 1]u8 = undefined;
    @memcpy(buf[0..link.len], link);
    buf[link.len] = 0;

    var argv = [_:null]?[*:0]const u8{ program, @ptrCast(&buf) };
    return spawn(program, &argv);
}

/// `posix_spawn` with signals reset.
///
/// Dispositions survive `exec` and this process ignores SIGPIPE, so a child inheriting
/// that would behave subtly wrong in pipelines — exactly the bug that already bit the
/// shell once. The mask is emptied for the same reason.
fn spawn(program: [*:0]const u8, argv: [:null]const ?[*:0]const u8) ?std.c.pid_t {
    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return null;
    defer _ = c.posix_spawnattr_destroy(&attr);

    var defaults: c.sigset_t = undefined;
    _ = c.sigfillset(&defaults);
    _ = c.posix_spawnattr_setsigdefault(&attr, &defaults);
    var mask: c.sigset_t = undefined;
    _ = c.sigemptyset(&mask);
    _ = c.posix_spawnattr_setsigmask(&attr, &mask);
    _ = c.posix_spawnattr_setflags(
        &attr,
        c.POSIX_SPAWN_SETSIGDEF | c.POSIX_SPAWN_SETSIGMASK,
    );

    var pid: std.c.pid_t = 0;
    const rc = c.posix_spawnp(
        &pid,
        program,
        null,
        &attr,
        @ptrCast(argv.ptr),
        // `environ` is a libc variable, which translate-c does not surface; std
        // declares it directly.
        @ptrCast(std.c.environ),
    );
    if (rc != 0) return null;
    return pid;
}

/// Start another maai, beginning in `dir`.
///
/// `/proc/self/exe` rather than argv[0]: it is the actual binary regardless of how this
/// process was invoked, so a window opened from a window opened from a shell alias
/// still finds the right executable.
///
/// The directory is passed as an argument rather than applied with a chdir here — this
/// process must not move, and `posix_spawn_file_actions_addchdir_np` is a glibc
/// extension we would then depend on.
pub fn newWindow(dir: []const u8) ?std.c.pid_t {
    if (dir.len == 0 or dir.len > max_path_len) return null;
    if (dir[0] != '/') return null;
    for (dir) |ch| if (ch <= 0x1f or ch == 0x7f) return null;

    var buf: [max_path_len + 1]u8 = undefined;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;

    var argv = [_:null]?[*:0]const u8{ "maai", "--cwd", @ptrCast(&buf) };
    return spawn("/proc/self/exe", &argv);
}

pub const max_path_len = 4096;

/// Reaps launched handlers so they do not accumulate as zombies.
///
/// A blocking `waitpid` is out of the question — `xdg-open` may not return until
/// the browser does — and a bare `waitpid(-1)` would steal the shell's exit status
/// out from under `Pty.childExited`. So the pids are tracked explicitly and polled.
pub const Reaper = struct {
    /// Well beyond what clicking can produce between two loop iterations, since
    /// `xdg-open` exits in milliseconds.
    pub const capacity = 16;

    pids: [capacity]std.c.pid_t = @splat(0),

    pub fn track(self: *Reaper, pid: std.c.pid_t) void {
        for (&self.pids) |*slot| {
            if (slot.* == 0) {
                slot.* = pid;
                return;
            }
        }
        // Full. Dropping the pid leaves one zombie until we exit, which is a far
        // better outcome than blocking the event loop to make room.
    }

    pub fn poll(self: *Reaper) void {
        for (&self.pids) |*slot| {
            if (slot.* == 0) continue;
            var status: c_int = 0;
            if (std.c.waitpid(slot.*, &status, c.WNOHANG) == slot.*) slot.* = 0;
        }
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "only allowlisted schemes are launched" {
    // `true` exists on every POSIX system and does nothing, so a reaching spawn is
    // observable without side effects. Anything rejected must not reach it at all.
    for ([_][]const u8{
        "javascript:alert(1)",
        "data:text/html,x",
        "vscode://file/etc/passwd",
        "",
        "notaurl",
        "--version",
        "/usr/bin/id",
    }) |bad| {
        try testing.expect(openWith("true", bad) == null);
    }
}

test "control characters and oversize links are refused" {
    try testing.expect(openWith("true", "https://x/\x00y") == null);
    try testing.expect(openWith("true", "https://x/\ny") == null);
    try testing.expect(openWith("true", "https://x/\x1b[2J") == null);
    try testing.expect(openWith("true", "https://x/ y") == null);

    var long: [max_url_len + 2]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..8], "https://");
    try testing.expect(openWith("true", &long) == null);
}

test "an allowed link spawns, and the reaper collects it" {
    const pid = openWith("true", "https://example.com/x") orelse
        return error.SpawnFailed;

    var reaper = Reaper{};
    reaper.track(pid);

    // The child may not have exited yet, so poll rather than assert on the first
    // pass. A blocking wait here would defeat the point of the Reaper, and would
    // also leave `poll` nothing to reap.
    const nap = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
    var tries: usize = 0;
    while (tries < 2000) : (tries += 1) {
        reaper.poll();
        if (reaper.pids[0] == 0) break;
        _ = std.c.nanosleep(&nap, null);
    }
    try testing.expectEqual(@as(std.c.pid_t, 0), reaper.pids[0]);
}

test "the reaper drops pids rather than blocking when full" {
    var reaper = Reaper{};
    for (&reaper.pids, 1..) |*slot, i| slot.* = @intCast(i);
    reaper.track(999999); // no slot; must simply return
    try testing.expectEqual(@as(std.c.pid_t, 1), reaper.pids[0]);
}

test "newWindow refuses anything that is not an absolute path" {
    // Only the rejections are exercised: a valid path would open a real window, which
    // a test suite has no business doing.
    for ([_][]const u8{
        "",
        "relative/path",
        "~/home",
        "/tmp/with\x00nul",
        "/tmp/with\nnewline",
    }) |bad| {
        try testing.expect(newWindow(bad) == null);
    }

    var long: [max_path_len + 2]u8 = undefined;
    @memset(&long, 'a');
    long[0] = '/';
    try testing.expect(newWindow(&long) == null);
}
