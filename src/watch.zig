//! Watching config and theme files for changes.
//!
//! The subtlety, and the reason this is not three lines of `inotify_add_watch`:
//! **almost nothing edits a file in place.** vim writes a temporary file and renames
//! it over the target; the machine's theme switcher copies a file into place; `sed -i`
//! and `install` do the same. A watch on the *file* follows the old inode and goes
//! permanently silent after the first save.
//!
//! So the watch goes on the containing *directory*, and events are filtered by name.
//! That survives replacement, creation of a file that did not exist yet, and deletion
//! followed by recreation — all of which happen in normal use.

const std = @import("std");
const c = @import("c.zig").c;

/// Config, theme, flavour file, and room for a couple more without a reshuffle.
pub const max_paths = 8;

/// How long to wait after an event before reloading. A single editor save produces
/// several events (temporary file created, renamed, attributes set); reloading on each
/// one would re-read and re-apply the config three times, and one of those reads can
/// land while the file is half-written.
pub const debounce_ms: i64 = 60;

pub const Watcher = struct {
    fd: i32 = -1,
    entries: [max_paths]Entry = undefined,
    n: usize = 0,
    /// Monotonic deadline at which a pending change should be applied; 0 when idle.
    due_ms: i64 = 0,

    const Entry = struct {
        wd: i32,
        /// The basename we care about in that directory.
        name_buf: [256]u8 = undefined,
        name_len: usize = 0,

        fn name(self: *const Entry) []const u8 {
            return self.name_buf[0..self.name_len];
        }
    };

    pub fn init() ?Watcher {
        // Non-blocking because the fd shares the main poll loop, and CLOEXEC so the
        // shell does not inherit it.
        const fd = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
        if (fd < 0) return null;
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Watcher) void {
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
        self.n = 0;
    }

    /// Watch the directory holding `path`, for changes to that name.
    ///
    /// Watching a file that does not exist yet is fine and useful — creating
    /// `~/.config/maai/maai.conf` for the first time should take effect without a
    /// restart.
    pub fn add(self: *Watcher, path: []const u8) void {
        if (self.fd < 0 or self.n == max_paths) return;
        if (path.len == 0) return;

        const dir = std.fs.path.dirname(path) orelse ".";
        const base = std.fs.path.basename(path);
        if (base.len == 0 or base.len > 256) return;

        var dirz: [1024]u8 = undefined;
        if (dir.len >= dirz.len) return;
        @memcpy(dirz[0..dir.len], dir);
        dirz[dir.len] = 0;

        const mask: u32 = c.IN_CLOSE_WRITE | c.IN_MOVED_TO | c.IN_CREATE | c.IN_ATTRIB;
        const wd = c.inotify_add_watch(self.fd, @ptrCast(&dirz), mask);
        if (wd < 0) return;

        // The same directory may already be watched for a different name — inotify
        // returns the same descriptor, and both names must stay registered.
        var e = Entry{ .wd = wd };
        @memcpy(e.name_buf[0..base.len], base);
        e.name_len = base.len;
        self.entries[self.n] = e;
        self.n += 1;
    }

    /// Drop every watch, for re-registering after a reload changed which files matter
    /// (a new `theme` value points at a different file).
    pub fn reset(self: *Watcher) void {
        for (self.entries[0..self.n]) |e| {
            _ = c.inotify_rm_watch(self.fd, e.wd);
        }
        self.n = 0;
    }

    /// Consume pending events. Returns true if one of our files was touched, in which
    /// case `due_ms` has been armed.
    pub fn drain(self: *Watcher, now_ms: i64) bool {
        if (self.fd < 0) return false;

        // Aligned because inotify_event contains 32-bit fields that are read directly
        // out of this buffer.
        var buf: [4096]u8 align(@alignOf(c.struct_inotify_event)) = undefined;
        var hit = false;

        while (true) {
            const n = std.posix.read(self.fd, &buf) catch break;
            if (n == 0) break;

            var off: usize = 0;
            while (off + @sizeOf(c.struct_inotify_event) <= n) {
                const ev: *const c.struct_inotify_event = @ptrCast(@alignCast(&buf[off]));
                const name_len: usize = @intCast(ev.len);
                const total = @sizeOf(c.struct_inotify_event) + name_len;
                if (off + total > n) break;

                if (name_len > 0) {
                    const raw = buf[off + @sizeOf(c.struct_inotify_event) ..][0..name_len];
                    const name = std.mem.sliceTo(raw, 0);
                    if (self.matches(ev.wd, name)) hit = true;
                }
                off += total;
            }
        }

        if (hit) self.due_ms = now_ms + debounce_ms;
        return hit;
    }

    fn matches(self: *const Watcher, wd: i32, name: []const u8) bool {
        for (self.entries[0..self.n]) |e| {
            if (e.wd == wd and std.mem.eql(u8, e.name(), name)) return true;
        }
        return false;
    }

    /// True once the debounce window has elapsed, disarming as it reports.
    pub fn ready(self: *Watcher, now_ms: i64) bool {
        if (self.due_ms == 0 or now_ms < self.due_ms) return false;
        self.due_ms = 0;
        return true;
    }

    /// Milliseconds until the pending reload, or null when idle. Feeds the poll
    /// timeout, so a change is applied on time rather than on the next input event.
    pub fn timeout(self: *const Watcher, now_ms: i64) ?i32 {
        if (self.due_ms == 0) return null;
        return @intCast(@max(1, self.due_ms - now_ms));
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a rename over the target is seen, because the directory is watched" {
    var w = Watcher.init() orelse return error.NoInotify;
    defer w.deinit();

    // A real directory and a real replace, since that is exactly the case a watch on
    // the file itself would miss.
    var tmp_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&tmp_buf, "/tmp/maai-watch-{d}", .{std.c.getpid()});
    var dirz: [80]u8 = undefined;
    @memcpy(dirz[0..dir.len], dir);
    dirz[dir.len] = 0;
    _ = std.c.mkdir(@ptrCast(&dirz), 0o700);
    defer _ = std.c.rmdir(@ptrCast(&dirz));

    var target_buf: [128]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "{s}/conf", .{dir});
    var tmp2_buf: [128]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp2_buf, "{s}/conf.new", .{dir});

    // Watch before the file exists — creating it for the first time must register.
    w.add(target);
    try testing.expectEqual(@as(usize, 1), w.n);

    try writeFile(tmp, "font_size 13\n");
    try rename(tmp, target);
    defer deleteFile(target);

    try testing.expect(w.drain(1000));
    try testing.expect(w.due_ms > 1000);

    // Debounced: not ready immediately, ready once the window passes.
    try testing.expect(!w.ready(1000));
    try testing.expect(w.ready(1000 + debounce_ms));
    // ...and disarmed after reporting, so one save is one reload.
    try testing.expect(!w.ready(1000 + debounce_ms));
}

test "an unrelated file in the same directory is ignored" {
    var w = Watcher.init() orelse return error.NoInotify;
    defer w.deinit();

    var tmp_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&tmp_buf, "/tmp/maai-watch2-{d}", .{std.c.getpid()});
    var dirz: [80]u8 = undefined;
    @memcpy(dirz[0..dir.len], dir);
    dirz[dir.len] = 0;
    _ = std.c.mkdir(@ptrCast(&dirz), 0o700);
    defer _ = std.c.rmdir(@ptrCast(&dirz));

    var a_buf: [128]u8 = undefined;
    const watched = try std.fmt.bufPrint(&a_buf, "{s}/watched", .{dir});
    var b_buf: [128]u8 = undefined;
    const other = try std.fmt.bufPrint(&b_buf, "{s}/other", .{dir});

    w.add(watched);
    // This matters because the flavour file lives in ~/.config, a directory that sees
    // constant traffic from everything else on the machine.
    try writeFile(other, "x");
    defer deleteFile(other);
    try testing.expect(!w.drain(1000));
    try testing.expectEqual(@as(i64, 0), w.due_ms);
}

test "timeout reports the wait, and nothing when idle" {
    var w = Watcher{};
    try testing.expect(w.timeout(500) == null);
    w.due_ms = 560;
    try testing.expectEqual(@as(i32, 60), w.timeout(500).?);
    // Already due: at least 1 ms, never zero, so the poll cannot busy-spin.
    try testing.expectEqual(@as(i32, 1), w.timeout(9999).?);
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    var pathz: [256]u8 = undefined;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const fd = std.c.open(
        @ptrCast(&pathz),
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        @as(c.mode_t, 0o600),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, contents.ptr, contents.len) < 0) return error.WriteFailed;
}

fn rename(from: []const u8, to: []const u8) !void {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    @memcpy(a[0..from.len], from);
    a[from.len] = 0;
    @memcpy(b[0..to.len], to);
    b[to.len] = 0;
    if (std.c.rename(@ptrCast(&a), @ptrCast(&b)) != 0) return error.RenameFailed;
}

fn deleteFile(path: []const u8) void {
    var pathz: [256]u8 = undefined;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    _ = std.c.unlink(@ptrCast(&pathz));
}
