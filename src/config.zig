//! Configuration: a flat `key value` file, plus theme files in the same format.
//!
//! Syntax is deliberately tiny — one setting per line, `#` comments, and `include`.
//! Both `key value` and `key: value` are accepted, because the two conventions the
//! machine already uses disagree: kitty theme files write `background #192330`, and
//! `theme: nord.yaml` is what reads naturally when pointing at a file. Supporting one
//! optional colon costs a line of parsing and means the existing
//! `~/.config/kitty/themes/*.conf` files load unchanged.
//!
//! This is *not* YAML, despite the colon and despite `.yaml` being a fine name for a
//! theme file. Nesting, lists, anchors and quoting rules are all absent. A real YAML
//! parser is thousands of lines and a supply of surprises; a flat mapping is what a
//! terminal config actually needs.
//!
//! Unknown keys are reported and ignored, never fatal. A config that fails to load
//! must still leave a usable terminal — the alternative is a window that will not open
//! because of a typo.

const std = @import("std");
const thememod = @import("term/theme.zig");
const urlmod = @import("term/url.zig");
const Theme = thememod.Theme;
const Rgb = @import("term/cell.zig").Rgb;

/// Guards against an `include` cycle, which is otherwise an infinite loop at startup.
pub const max_include_depth = 8;
/// No config or theme file has any business being larger.
pub const max_file_bytes = 1 << 20;

pub const Config = struct {
    // ── font and layout ────────────────────────────────────────────────────
    font_family: Str = .init("FiraCode Nerd Font Ret"),
    font_size: f64 = 12.0,
    /// Left/top only, matching the existing kitty and wezterm configs
    /// (`window_padding_width 0 0 0 4`).
    padding_x: u32 = 4,
    padding_y: u32 = 0,
    scrollback_lines: u32 = 10_000,

    // ── behaviour ──────────────────────────────────────────────────────────
    /// Feed a finished selection to CLIPBOARD as well as PRIMARY. Not the platform
    /// default — it means a clipboard manager records every mouse selection — but it
    /// is what was asked for here.
    copy_on_select: bool = true,
    /// Double-click word boundaries. Includes shell punctuation so double-clicking
    /// inside a path or URL grabs the whole thing.
    word_separators: Str = .init(" \t\n\"'`()[]{}<>|;:,!?*+=&^%$#@\\"),
    /// DECSET 1007: on the alternate screen with no mouse tracking, the wheel sends
    /// cursor keys. Without it the wheel does nothing at all in `less` or `man`.
    alternate_scroll: bool = true,
    /// The program handed a URL, as an argv[0]. Never a shell string.
    url_launcher: Str = .init("xdg-open"),

    // ── theme ──────────────────────────────────────────────────────────────
    theme: Theme = .{},
    /// Where to look for a theme named rather than pathed. Defaults to the directory
    /// the machine's existing theme switcher already writes into.
    theme_dir: Str = .init("~/.config/kitty/themes"),
    /// A file holding just a theme name. The machine's app-theme switcher rewrites
    /// this, so watching it is what makes the dayfox/nightfox flip apply live.
    theme_flavour_file: Str = .init("~/.config/.app-theme-flavour"),
    /// Resolved theme file, for the reloader to watch. Empty when none was loaded.
    theme_path: Str = .init(""),

    /// Inline string storage. Config strings are few, short, and live as long as the
    /// process, so a fixed buffer avoids an allocator on the reload path — which runs
    /// from an inotify callback where a failure is awkward to report.
    pub const Str = struct {
        buf: [512]u8 = undefined,
        len: usize = 0,

        pub fn init(comptime s: []const u8) Str {
            comptime std.debug.assert(s.len <= 512);
            var r = Str{};
            @memcpy(r.buf[0..s.len], s);
            r.len = s.len;
            return r;
        }

        pub fn set(self: *Str, s: []const u8) void {
            const n = @min(s.len, self.buf.len);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }

        pub fn slice(self: *const Str) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn eql(self: *const Str, s: []const u8) bool {
            return std.mem.eql(u8, self.slice(), s);
        }
    };
};

/// A problem with a config file. Collected rather than thrown: one bad line must not
/// cost the user their terminal.
pub const Diagnostic = struct {
    file: Config.Str = .init(""),
    line: usize = 0,
    message: Config.Str = .init(""),
};

pub const Diagnostics = struct {
    /// Beyond this the file is so wrong that listing more helps nobody.
    pub const capacity = 16;

    items: [capacity]Diagnostic = undefined,
    len: usize = 0,
    /// Problems past `capacity`, so the count is honest.
    dropped: usize = 0,

    fn add(self: *Diagnostics, file: []const u8, line: usize, message: []const u8) void {
        if (self.len == capacity) {
            self.dropped += 1;
            return;
        }
        var d = Diagnostic{ .line = line };
        d.file.set(file);
        d.message.set(message);
        self.items[self.len] = d;
        self.len += 1;
    }

    pub fn report(self: *const Diagnostics) void {
        for (self.items[0..self.len]) |d| {
            std.debug.print("myterm: {s}:{d}: {s}\n", .{
                d.file.slice(),
                d.line,
                d.message.slice(),
            });
        }
        if (self.dropped > 0) {
            std.debug.print("myterm: ...and {d} more\n", .{self.dropped});
        }
    }
};

/// Load a config file over the defaults. Missing file is not an error — running with
/// no config at all is a supported state.
pub fn load(
    gpa: std.mem.Allocator,
    path: []const u8,
    diags: *Diagnostics,
) Config {
    var cfg = Config{};
    var expanded: [1024]u8 = undefined;
    const real = expandTilde(path, &expanded) orelse return cfg;
    applyFile(gpa, &cfg, real, diags, 0);
    return cfg;
}

/// Re-read a theme, honouring the flavour file when the config asked for that.
///
/// Separate from `load` because a theme flip must not re-read the config: the config
/// may have been edited to something broken since startup, and swapping colours is no
/// reason to adopt it.
pub fn reloadTheme(gpa: std.mem.Allocator, cfg: *Config, diags: *Diagnostics) void {
    cfg.theme = .{};
    cfg.theme_path.set("");

    var name_buf: [256]u8 = undefined;
    const flavour = readFlavour(cfg.theme_flavour_file.slice(), &name_buf);
    const want = flavour orelse return;
    applyThemeRef(gpa, cfg, want, diags, "flavour file", 0);
}

fn readFlavour(path: []const u8, out: []u8) ?[]const u8 {
    var expanded: [1024]u8 = undefined;
    const real = expandTilde(path, &expanded) orelse return null;
    var pathz: [1024]u8 = undefined;
    if (real.len >= pathz.len) return null;
    @memcpy(pathz[0..real.len], real);
    pathz[real.len] = 0;
    const fd = std.c.open(@ptrCast(&pathz), .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var buf: [256]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return null;
    // First line only: the switcher writes a bare name, and trailing content is not
    // ours to interpret.
    const line = std.mem.sliceTo(buf[0..n], '\n');
    const name = std.mem.trim(u8, line, " \t\r");
    if (name.len == 0 or name.len > out.len) return null;
    @memcpy(out[0..name.len], name);
    return out[0..name.len];
}

/// Resolve a `theme` value, which may be a name or a path, and apply it.
///
/// A name is looked up in `theme_dir`, trying the extensions the machine actually
/// uses. A value containing a `/` or starting with `~` is taken as a path — that is
/// what makes `theme nord.yaml` and `theme ~/themes/solarized.yaml` both work without
/// a second setting to disambiguate.
fn applyThemeRef(
    gpa: std.mem.Allocator,
    cfg: *Config,
    value: []const u8,
    diags: *Diagnostics,
    from_file: []const u8,
    from_line: usize,
) void {
    var candidate: [1024]u8 = undefined;

    if (std.mem.indexOfScalar(u8, value, '/') != null or value[0] == '~') {
        var expanded: [1024]u8 = undefined;
        const real = expandTilde(value, &expanded) orelse {
            diags.add(from_file, from_line, "theme path too long");
            return;
        };
        if (loadTheme(gpa, real, cfg, diags)) return;
        diags.add(from_file, from_line, "theme file not found");
        return;
    }

    // A bare name: try it as given, then with each extension in turn.
    var dir_buf: [1024]u8 = undefined;
    const dir = expandTilde(cfg.theme_dir.slice(), &dir_buf) orelse return;
    for ([_][]const u8{ "", ".conf", ".yaml", ".yml" }) |ext| {
        const p = std.fmt.bufPrint(&candidate, "{s}/{s}{s}", .{ dir, value, ext }) catch continue;
        if (loadTheme(gpa, p, cfg, diags)) return;
    }
    diags.add(from_file, from_line, "no theme file for that name");
}

fn loadTheme(
    gpa: std.mem.Allocator,
    path: []const u8,
    cfg: *Config,
    diags: *Diagnostics,
) bool {
    const text = readFile(gpa, path) catch return false;
    defer gpa.free(text);
    parseTheme(text, path, &cfg.theme, diags);
    cfg.theme_path.set(path);
    return true;
}

/// Parse theme keys. The names are kitty's, because the machine's theme files are
/// kitty's — reusing them means the existing switcher keeps working untouched.
pub fn parseTheme(
    text: []const u8,
    path: []const u8,
    theme: *Theme,
    diags: *Diagnostics,
) void {
    var it = lines(text);
    while (it.next()) |entry| {
        const key = entry.key;
        const value = entry.value;

        if (std.mem.startsWith(u8, key, "color")) {
            const idx = std.fmt.parseUnsigned(u16, key[5..], 10) catch {
                diags.add(path, entry.line, "colour index is not a number");
                continue;
            };
            if (idx > 255) {
                diags.add(path, entry.line, "colour index above 255");
                continue;
            }
            theme.palette[idx] = thememod.parseColor(value) orelse {
                diags.add(path, entry.line, "unparseable colour");
                continue;
            };
            continue;
        }

        const slot: ?*Rgb =
            if (std.mem.eql(u8, key, "background")) &theme.bg else if (std.mem.eql(u8, key, "foreground")) &theme.fg else if (std.mem.eql(u8, key, "cursor")) &theme.cursor else if (std.mem.eql(u8, key, "cursor_text_color")) &theme.cursor_text else if (std.mem.eql(u8, key, "selection_background")) &theme.selection_bg else if (std.mem.eql(u8, key, "selection_foreground")) &theme.selection_fg else if (std.mem.eql(u8, key, "hint_background")) &theme.hint_bg else if (std.mem.eql(u8, key, "hint_foreground")) &theme.hint_fg else null;

        if (slot) |s| {
            s.* = thememod.parseColor(value) orelse {
                diags.add(path, entry.line, "unparseable colour");
                continue;
            };
        }
        // Every other kitty theme key — tab bar, borders, bell — describes chrome
        // myterm does not have yet. Silently ignored rather than reported, or loading
        // an unmodified kitty theme would print a dozen complaints.
    }
}

fn applyFile(
    gpa: std.mem.Allocator,
    cfg: *Config,
    path: []const u8,
    diags: *Diagnostics,
    depth: usize,
) void {
    const text = readFile(gpa, path) catch |err| {
        if (err != error.FileNotFound) {
            diags.add(path, 0, @errorName(err));
        }
        return;
    };
    defer gpa.free(text);

    var it = lines(text);
    while (it.next()) |entry| {
        applyKey(gpa, cfg, entry, path, diags, depth);
    }
}

fn applyKey(
    gpa: std.mem.Allocator,
    cfg: *Config,
    entry: Entry,
    path: []const u8,
    diags: *Diagnostics,
    depth: usize,
) void {
    const key = entry.key;
    const value = entry.value;

    if (std.mem.eql(u8, key, "include")) {
        if (depth + 1 >= max_include_depth) {
            diags.add(path, entry.line, "include nested too deeply (cycle?)");
            return;
        }
        var buf: [1024]u8 = undefined;
        // Relative includes resolve against the including file's directory, which is
        // what makes a config directory movable.
        const resolved = resolveRelative(path, value, &buf) orelse {
            diags.add(path, entry.line, "include path too long");
            return;
        };
        applyFile(gpa, cfg, resolved, diags, depth + 1);
        return;
    }

    if (std.mem.eql(u8, key, "font_family")) {
        cfg.font_family.set(value);
    } else if (std.mem.eql(u8, key, "font_size")) {
        cfg.font_size = std.fmt.parseFloat(f64, value) catch {
            diags.add(path, entry.line, "font_size is not a number");
            return;
        };
        if (!(cfg.font_size > 0 and cfg.font_size < 400)) {
            diags.add(path, entry.line, "font_size out of range");
            cfg.font_size = 12.0;
        }
    } else if (std.mem.eql(u8, key, "padding_x")) {
        cfg.padding_x = parseU32(value, 0, 512) orelse {
            diags.add(path, entry.line, "padding_x out of range");
            return;
        };
    } else if (std.mem.eql(u8, key, "padding_y")) {
        cfg.padding_y = parseU32(value, 0, 512) orelse {
            diags.add(path, entry.line, "padding_y out of range");
            return;
        };
    } else if (std.mem.eql(u8, key, "scrollback_lines")) {
        cfg.scrollback_lines = parseU32(value, 0, 10_000_000) orelse {
            diags.add(path, entry.line, "scrollback_lines out of range");
            return;
        };
    } else if (std.mem.eql(u8, key, "copy_on_select")) {
        cfg.copy_on_select = parseBool(value) orelse {
            diags.add(path, entry.line, "expected yes or no");
            return;
        };
    } else if (std.mem.eql(u8, key, "alternate_scroll")) {
        cfg.alternate_scroll = parseBool(value) orelse {
            diags.add(path, entry.line, "expected yes or no");
            return;
        };
    } else if (std.mem.eql(u8, key, "word_separators")) {
        cfg.word_separators.set(value);
    } else if (std.mem.eql(u8, key, "url_launcher")) {
        // An argv[0], so a value with spaces would be a program whose name contains
        // them — almost certainly a shell command in disguise. Refuse it: this is the
        // one setting that names a process to run (PLAN.md §7).
        if (std.mem.indexOfAny(u8, value, " \t") != null) {
            diags.add(path, entry.line, "url_launcher takes one program, no arguments");
            return;
        }
        cfg.url_launcher.set(value);
    } else if (std.mem.eql(u8, key, "theme_dir")) {
        cfg.theme_dir.set(value);
    } else if (std.mem.eql(u8, key, "theme_flavour_file")) {
        cfg.theme_flavour_file.set(value);
    } else if (std.mem.eql(u8, key, "theme")) {
        if (value.len == 0) {
            diags.add(path, entry.line, "theme needs a name or a path");
            return;
        }
        applyThemeRef(gpa, cfg, value, diags, path, entry.line);
    } else {
        diags.add(path, entry.line, "unknown setting");
    }
}

// ── line scanning ───────────────────────────────────────────────────────────

const Entry = struct {
    key: []const u8,
    value: []const u8,
    line: usize,
};

fn lines(text: []const u8) LineIter {
    return .{ .rest = text };
}

const LineIter = struct {
    rest: []const u8,
    n: usize = 0,

    fn next(self: *LineIter) ?Entry {
        while (self.rest.len > 0) {
            const end = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
            const raw = self.rest[0..end];
            self.rest = self.rest[@min(end + 1, self.rest.len)..];
            self.n += 1;

            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            // Split on the first run of whitespace, or on a colon directly after the
            // key. Both spellings are accepted — see the module comment.
            var key_end = line.len;
            for (line, 0..) |ch, i| {
                if (ch == ' ' or ch == '\t' or ch == ':') {
                    key_end = i;
                    break;
                }
            }
            const key = line[0..key_end];
            var rest = line[key_end..];
            if (rest.len > 0 and rest[0] == ':') rest = rest[1..];
            const value = std.mem.trim(u8, rest, " \t\r");

            if (key.len == 0) continue;
            return .{ .key = key, .value = value, .line = self.n };
        }
        return null;
    }
};

// ── helpers ─────────────────────────────────────────────────────────────────

/// Read a whole file.
///
/// Straight to libc rather than `std.fs`, which Zig 0.16 replaced with `std.Io.Dir`
/// and its explicit `Io` instance — a lot of machinery for reading two small files at
/// startup, and the rest of the project already talks to libc directly.
fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var pathz: [1024]u8 = undefined;
    if (path.len >= pathz.len) return error.NameTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;

    const fd = std.c.open(@ptrCast(&pathz), .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch return error.ReadFailed;
        if (n == 0) break;
        if (out.items.len + n > max_file_bytes) return error.FileTooBig;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// Expand a leading `~/`. Only leading, and only `~/` — `~user` needs passwd lookups
/// for a syntax nobody writes in a config file.
pub fn expandTilde(path: []const u8, out: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) {
        if (path.len > out.len) return null;
        @memcpy(out[0..path.len], path);
        return out[0..path.len];
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    return std.fmt.bufPrint(out, "{s}{s}", .{ home, path[1..] }) catch null;
}

/// Resolve `path` against the directory of `base`, unless it is already absolute or
/// starts with `~`.
fn resolveRelative(base: []const u8, path: []const u8, out: []u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] == '/' or path[0] == '~') return expandTilde(path, out);
    const dir = std.fs.path.dirname(base) orelse ".";
    return std.fmt.bufPrint(out, "{s}/{s}", .{ dir, path }) catch null;
}

fn parseBool(value: []const u8) ?bool {
    for ([_][]const u8{ "yes", "true", "1", "on" }) |t| {
        if (std.ascii.eqlIgnoreCase(value, t)) return true;
    }
    for ([_][]const u8{ "no", "false", "0", "off" }) |f| {
        if (std.ascii.eqlIgnoreCase(value, f)) return false;
    }
    return null;
}

fn parseU32(value: []const u8, lo: u32, hi: u32) ?u32 {
    const v = std.fmt.parseUnsigned(u32, value, 10) catch return null;
    if (v < lo or v > hi) return null;
    return v;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseInto(text: []const u8, cfg: *Config, diags: *Diagnostics) void {
    var it = lines(text);
    while (it.next()) |entry| {
        applyKey(testing.allocator, cfg, entry, "test.conf", diags, 0);
    }
}

test "both key value and key: value are accepted" {
    var cfg = Config{};
    var diags = Diagnostics{};
    parseInto(
        \\font_size 14
        \\padding_x: 8
        \\  copy_on_select   no
        \\word_separators: ab c
    , &cfg, &diags);

    try testing.expectEqual(@as(f64, 14), cfg.font_size);
    try testing.expectEqual(@as(u32, 8), cfg.padding_x);
    try testing.expectEqual(false, cfg.copy_on_select);
    // The value keeps its inner spaces; only the ends are trimmed.
    try testing.expectEqualStrings("ab c", cfg.word_separators.slice());
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "comments and blank lines are skipped" {
    var cfg = Config{};
    var diags = Diagnostics{};
    parseInto(
        \\# a comment
        \\
        \\   # indented comment
        \\font_size 9
    , &cfg, &diags);
    try testing.expectEqual(@as(f64, 9), cfg.font_size);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "a bad line is reported and everything else still applies" {
    var cfg = Config{};
    var diags = Diagnostics{};
    parseInto(
        \\font_size not-a-number
        \\padding_x 7
        \\nonsense whatever
        \\copy_on_select maybe
    , &cfg, &diags);

    // The defaults survive the bad lines, and the good line took effect. A config
    // with a typo must still leave a usable terminal.
    try testing.expectEqual(@as(f64, 12.0), cfg.font_size);
    try testing.expectEqual(@as(u32, 7), cfg.padding_x);
    try testing.expectEqual(true, cfg.copy_on_select);
    try testing.expectEqual(@as(usize, 3), diags.len);
    try testing.expectEqual(@as(usize, 1), diags.items[0].line);
    try testing.expectEqual(@as(usize, 4), diags.items[2].line);
}

test "out-of-range numbers are refused, not clamped silently" {
    var cfg = Config{};
    var diags = Diagnostics{};
    parseInto(
        \\font_size 0
        \\padding_x 99999
    , &cfg, &diags);
    try testing.expectEqual(@as(f64, 12.0), cfg.font_size);
    try testing.expectEqual(@as(u32, 4), cfg.padding_x);
    try testing.expectEqual(@as(usize, 2), diags.len);
}

test "url_launcher refuses anything that looks like a command line" {
    var cfg = Config{};
    var diags = Diagnostics{};
    // This is the one setting that names a process to run, so a value with arguments
    // is refused rather than split — splitting is how a shell string sneaks in.
    parseInto("url_launcher sh -c 'curl $0'", &cfg, &diags);
    try testing.expectEqualStrings("xdg-open", cfg.url_launcher.slice());
    try testing.expectEqual(@as(usize, 1), diags.len);

    var ok = Config{};
    var ok_diags = Diagnostics{};
    parseInto("url_launcher firefox", &ok, &ok_diags);
    try testing.expectEqualStrings("firefox", ok.url_launcher.slice());
    try testing.expectEqual(@as(usize, 0), ok_diags.len);
}

test "kitty theme files parse, including the keys we have no chrome for" {
    var theme = Theme.default;
    var diags = Diagnostics{};
    // Lifted verbatim from ~/.config/kitty/themes/nightfox.conf, tab-bar keys and all.
    parseTheme(
        \\## name: nightfox
        \\background #192330
        \\foreground #cdcecf
        \\selection_background #2b3b51
        \\cursor #cdcecf
        \\active_tab_background #719cd6
        \\color1 #c94f6d
        \\color15 #e4e4e5
    , "nightfox.conf", &theme, &diags);

    try testing.expect(theme.bg.eq(Rgb.rgb(0x19, 0x23, 0x30)));
    try testing.expect(theme.fg.eq(Rgb.rgb(0xcd, 0xce, 0xcf)));
    try testing.expect(theme.selection_bg.eq(Rgb.rgb(0x2b, 0x3b, 0x51)));
    try testing.expect(theme.palette[1].eq(Rgb.rgb(0xc9, 0x4f, 0x6d)));
    try testing.expect(theme.palette[15].eq(Rgb.rgb(0xe4, 0xe4, 0xe5)));
    // Chrome we do not have is ignored quietly, or an unmodified kitty theme would
    // print a dozen complaints.
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "a malformed colour is reported and leaves the old one" {
    var theme = Theme.default;
    var diags = Diagnostics{};
    parseTheme(
        \\background nonsense
        \\color999 #ffffff
        \\colorX #ffffff
    , "t.conf", &theme, &diags);

    try testing.expect(theme.bg.eq(thememod.default_bg));
    try testing.expectEqual(@as(usize, 3), diags.len);
}

test "diagnostics saturate instead of overflowing" {
    var cfg = Config{};
    var diags = Diagnostics{};
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    for (0..Diagnostics.capacity + 5) |_| {
        const s = "nonsense x\n";
        @memcpy(buf[w..][0..s.len], s);
        w += s.len;
    }
    parseInto(buf[0..w], &cfg, &diags);
    try testing.expectEqual(Diagnostics.capacity, diags.len);
    try testing.expectEqual(@as(usize, 5), diags.dropped);
}

test "tilde expansion only touches a leading ~/" {
    var out: [256]u8 = undefined;
    const home = std.mem.span(std.c.getenv("HOME").?);

    const expanded = expandTilde("~/x/y", &out).?;
    try testing.expect(std.mem.startsWith(u8, expanded, home));
    try testing.expect(std.mem.endsWith(u8, expanded, "/x/y"));

    try testing.expectEqualStrings("/abs/path", expandTilde("/abs/path", &out).?);
    // Not a home reference: a file really called `a~b` must survive.
    try testing.expectEqualStrings("a~b", expandTilde("a~b", &out).?);
}

test "relative includes resolve against the including file" {
    var out: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "/etc/myterm/theme.conf",
        resolveRelative("/etc/myterm/myterm.conf", "theme.conf", &out).?,
    );
    try testing.expectEqualStrings(
        "/abs.conf",
        resolveRelative("/etc/myterm/myterm.conf", "/abs.conf", &out).?,
    );
}

test "booleans accept the spellings people actually write" {
    try testing.expectEqual(true, parseBool("yes").?);
    try testing.expectEqual(true, parseBool("TRUE").?);
    try testing.expectEqual(true, parseBool("1").?);
    try testing.expectEqual(false, parseBool("no").?);
    try testing.expectEqual(false, parseBool("off").?);
    try testing.expect(parseBool("perhaps") == null);
}
