//! PTY allocation and child process spawn.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Error = error{
    ForkFailed,
    ExecFailed,
};

pub const Pty = struct {
    master: std.posix.fd_t = -1,
    child: std.posix.pid_t = -1,
    /// Set once the child has exited or the master has hung up.
    hung_up: bool = false,

    /// Fork a child on a new PTY, with `argv[0]` as the program to exec.
    ///
    /// forkpty() handles the setsid + TIOCSCTTY dance for us, which is what makes
    /// the child a proper session leader so job control and Ctrl+C work.
    ///
    /// `argv` must already be null-terminated and fully built by the caller: after
    /// the fork only async-signal-safe calls are legal, so there can be no
    /// allocation or Zig formatting in the child branch below.
    pub fn spawn(
        cols: u32,
        rows: u32,
        argv: [*:null]const ?[*:0]const u8,
        /// Directory the child starts in; empty inherits ours. Applied in the child
        /// after the fork, so this process never moves.
        dir: []const u8,
    ) Error!Pty {
        var ws = std.mem.zeroes(c.struct_winsize);
        ws.ws_col = @intCast(cols);
        ws.ws_row = @intCast(rows);

        const program = argv[0] orelse return Error.ExecFailed;

        var master: c_int = -1;
        const pid = c.forkpty(&master, null, null, &ws);
        if (pid < 0) return Error.ForkFailed;

        if (pid == 0) {
            // ── child ──
            // TERM is xterm-256color until phase 2 ships a myterm terminfo entry.
            // Claiming a TERM whose terminfo is not installed breaks everything
            // that uses curses, so this stays conservative until we can also
            // answer `--print-terminfo` for remote hosts.
            if (dir.len > 0 and dir.len < 4096) {
                var dirz: [4096]u8 = undefined;
                @memcpy(dirz[0..dir.len], dir);
                dirz[dir.len] = 0;
                // Failure is not fatal: a shell in the wrong directory beats no shell.
                _ = c.chdir(@ptrCast(&dirz));
            }
            _ = c.setenv("TERM", "xterm-256color", 1);
            _ = c.setenv("COLORTERM", "truecolor", 1);
            // Stale values inherited from the launching terminal would mislead
            // anything that reads them before the first resize.
            _ = c.unsetenv("COLUMNS");
            _ = c.unsetenv("LINES");

            // Signal dispositions and the blocked mask survive exec, so whatever
            // the parent chose leaks into the shell and everything it runs. We
            // ignore SIGPIPE deliberately (see `ignoreSigpipe` in main.zig), and a
            // shell that inherited that would behave subtly wrong in pipelines —
            // `head` closing a pipe early would no longer stop the writer. Reset to
            // defaults so the child starts from a clean slate.
            //
            // Only async-signal-safe calls are legal here, which signal() and
            // sigprocmask() both are.
            for ([_]c_int{
                c.SIGPIPE, c.SIGINT,  c.SIGQUIT,  c.SIGTERM, c.SIGHUP,
                c.SIGTSTP, c.SIGTTIN, c.SIGTTOU,  c.SIGCHLD, c.SIGALRM,
                c.SIGUSR1, c.SIGUSR2, c.SIGWINCH,
            }) |sig| {
                _ = c.signal(sig, c.SIG_DFL);
            }
            var mask: c.sigset_t = undefined;
            _ = c.sigemptyset(&mask);
            _ = c.sigprocmask(c.SIG_SETMASK, &mask, null);

            _ = c.execvp(program, @ptrCast(argv));
            // execvp only returns on failure, and we cannot report it upward.
            c._exit(127);
        }

        // ── parent ──
        // Non-blocking: the poll loop must never stall inside read().
        const flags = c.fcntl(master, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK);
        _ = c.fcntl(master, c.F_SETFD, c.FD_CLOEXEC);

        return .{ .master = @intCast(master), .child = @intCast(pid) };
    }

    pub fn resize(self: *Pty, cols: u32, rows: u32) void {
        var ws = std.mem.zeroes(c.struct_winsize);
        ws.ws_col = @intCast(cols);
        ws.ws_row = @intCast(rows);
        _ = c.ioctl(self.master, c.TIOCSWINSZ, &ws);
    }

    /// Returns the number of bytes read; 0 means "nothing available right now".
    /// Sets `hung_up` when the child is gone.
    pub fn read(self: *Pty, buf: []u8) usize {
        const n = std.posix.read(self.master, buf) catch |err| switch (err) {
            error.WouldBlock => return 0,
            // The kernel reports a closed slave side as EIO on Linux, not EOF.
            error.InputOutput => {
                self.hung_up = true;
                return 0;
            },
            else => {
                self.hung_up = true;
                return 0;
            },
        };
        if (n == 0) self.hung_up = true;
        return n;
    }

    pub fn write(self: *Pty, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            // std.posix.write was removed in Zig 0.16 in favour of the Io
            // interface; we link libc, so call it directly.
            const rc = std.c.write(self.master, bytes[off..].ptr, bytes.len - off);
            if (rc < 0) {
                switch (std.c.errno(rc)) {
                    // The PTY buffer is full. Dropping input is wrong, but blocking
                    // the UI thread is worse; phase 3 adds a small pending-write
                    // queue drained on POLLOUT.
                    .AGAIN => return,
                    .INTR => continue,
                    else => {
                        self.hung_up = true;
                        return;
                    },
                }
            }
            if (rc == 0) return;
            off += @intCast(rc);
        }
    }

    /// True once the child has exited. Reaps it so it does not linger as a zombie.
    /// The child's current working directory, via `/proc/<pid>/cwd`.
    ///
    /// This is the primary source, not a fallback. OSC 7 is the polite way for a shell
    /// to announce its directory, but this machine's zsh does not emit it and most
    /// distributions' shells do not either — so a feature built on OSC 8 alone would
    /// simply not work here. `/proc` needs no cooperation from anyone.
    ///
    /// It is the *shell's* directory, which is what "open another window here" means,
    /// rather than the foreground command's.
    pub fn cwd(self: *Pty, buf: []u8) ?[]const u8 {
        if (self.child < 0) return null;
        var link: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&link, "/proc/{d}/cwd", .{self.child}) catch
            return null;
        const n = std.c.readlink(path, buf.ptr, buf.len);
        if (n <= 0) return null;
        const len: usize = @intCast(n);
        // readlink does not terminate, and truncation would hand out a wrong path.
        if (len >= buf.len) return null;
        return buf[0..len];
    }

    pub fn childExited(self: *Pty) bool {
        if (self.child < 0) return true;
        var status: c_int = 0;
        const r = std.c.waitpid(self.child, &status, c.WNOHANG);
        if (r == self.child) {
            self.child = -1;
            self.hung_up = true;
            return true;
        }
        return false;
    }

    pub fn deinit(self: *Pty) void {
        if (self.master >= 0) _ = std.c.close(self.master);
        if (self.child > 0) {
            _ = c.kill(self.child, c.SIGHUP);
            var status: c_int = 0;
            _ = std.c.waitpid(self.child, &status, 0);
        }
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the child's working directory is readable without its cooperation" {
    // This is the mechanism "open another window here" rests on, and it has to work
    // with an unmodified shell: this machine's zsh never emits OSC 7, so a feature
    // built on the escape sequence alone would do nothing at all here.
    var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "sleep 5" };
    var pty = Pty.spawn(20, 5, &argv, "") catch return error.SkipZigTest;
    defer pty.deinit();

    var buf: [1024]u8 = undefined;
    const dir = pty.cwd(&buf) orelse return error.NoCwd;
    // Inherited from us, and absolute.
    try testing.expect(dir.len > 0);
    try testing.expectEqual(@as(u8, '/'), dir[0]);
    // readlink does not terminate its output; a stray NUL would mean we handed back
    // the buffer's tail as part of the path.
    try testing.expect(std.mem.indexOfScalar(u8, dir, 0) == null);
}

test "a dead child has no directory" {
    var pty = Pty{ .master = -1, .child = -1 };
    var buf: [64]u8 = undefined;
    try testing.expect(pty.cwd(&buf) == null);
}
