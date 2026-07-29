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
            _ = c.setenv("TERM", "xterm-256color", 1);
            _ = c.setenv("COLORTERM", "truecolor", 1);
            // Stale values inherited from the launching terminal would mislead
            // anything that reads them before the first resize.
            _ = c.unsetenv("COLUMNS");
            _ = c.unsetenv("LINES");

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
