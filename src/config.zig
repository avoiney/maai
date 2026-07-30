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
const c = @import("c.zig").c;
const thememod = @import("term/theme.zig");
const urlmod = @import("term/url.zig");
const Theme = thememod.Theme;
const Rgb = @import("term/cell.zig").Rgb;

/// Guards against an `include` cycle, which is otherwise an infinite loop at startup.
pub const max_include_depth = 8;
/// No config or theme file has any business being larger.
pub const max_file_bytes = 1 << 20;

/// How the tab bar is drawn.
pub const BarStyle = enum {
    /// Flat blocks of colour.
    plain,
    /// Separator glyphs between tabs, each carrying the colour of the tab it leaves on
    /// the background of the one it enters — which is what makes the edge read as a
    /// shape rather than a character. Needs a Nerd Font for the glyphs; the machine's
    /// FiraCode Nerd Font has them.
    powerline,
};

/// Which separator glyph. Names and codepoints follow kitty, whose config on this
/// machine already says `tab_powerline_style slanted`.
pub const PowerlineStyle = enum {
    angled,
    slanted,
    round,

    pub fn separator(self: PowerlineStyle) u21 {
        return switch (self) {
            .angled => 0xe0b0,
            .slanted => 0xe0bc,
            .round => 0xe0b4,
        };
    }
};

/// What a key can be made to do.
///
/// Names, not function pointers: the config names an action and `main.zig` decides what
/// it means, so a typo in a config file cannot become anything but a diagnostic.
pub const Action = enum {
    /// Explicitly unbound. Distinct from absent: it is how you *free* a combination we
    /// bind by default, handing it back to applications.
    none,
    copy,
    paste,
    paste_primary,
    hints,
    new_window,
    scroll_page_up,
    scroll_page_down,
    scroll_top,
    scroll_bottom,
    tab_new,
    tab_next,
    tab_prev,
    /// Jump to the tab at the pressed key's position in the number row.
    tab_goto,
};

/// evdev codes of the number row, in order. Positional bindings match these rather
/// than characters: on this AZERTY the row unshifted is `& é " ' ( - è _ ç à`, so
/// matching characters would freeze one layout into the code, while "the Nth key of the
/// number row" means the same thing everywhere. Browsers do exactly this, which is why
/// their Ctrl+1..9 works on AZERTY without Shift.
pub const num_row = [10]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

/// Position of `keycode` in the number row, 0-based.
pub fn numRowIndex(keycode: u32) ?usize {
    for (num_row, 0..) |code, i| {
        if (code == keycode) return i;
    }
    return null;
}

pub const Binding = struct {
    /// Keysym, normalised to lower case — with Shift held xkb reports `C`, not `c`, and
    /// a config that had to know that would be a trap. Ignored when `numrow` is set.
    sym: u32,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    /// Matches any key of the number row, by position. Written `numrow` in a config.
    numrow: bool = false,
    action: Action,

    fn sameCombo(a: Binding, b: Binding) bool {
        if (a.numrow != b.numrow) return false;
        if (!a.numrow and a.sym != b.sym) return false;
        return a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt;
    }
};

pub const Bindings = struct {
    pub const capacity = 64;

    items: [capacity]Binding = undefined,
    len: usize = 0,

    /// What the terminal binds when the config says nothing.
    pub fn defaults() Bindings {
        var b = Bindings{};
        // Ctrl+Shift is the terminal's own namespace: in the legacy encoding it
        // collapses onto Ctrl+key, so applications cannot bind it and lose nothing.
        b.add(.{ .sym = 'c', .ctrl = true, .shift = true, .action = .copy });
        b.add(.{ .sym = 'v', .ctrl = true, .shift = true, .action = .paste });
        b.add(.{ .sym = 'u', .ctrl = true, .shift = true, .action = .hints });
        // Carried over from wezterm. The character is matched, not the physical key.
        b.add(.{ .sym = '%', .alt = true, .action = .new_window });
        // Shifted so full-screen applications still receive plain Page Up/Down.
        b.add(.{ .sym = c.XKB_KEY_Page_Up, .shift = true, .action = .scroll_page_up });
        b.add(.{ .sym = c.XKB_KEY_Page_Down, .shift = true, .action = .scroll_page_down });
        b.add(.{ .sym = c.XKB_KEY_Home, .shift = true, .action = .scroll_top });
        b.add(.{ .sym = c.XKB_KEY_End, .shift = true, .action = .scroll_bottom });
        // Tabs. Ctrl+Tab is the convention every other application uses; note it is a
        // combination the keyboard protocol would otherwise offer applications, so
        // `key ctrl+tab none` is the way to give it back.
        b.add(.{ .sym = 't', .ctrl = true, .shift = true, .action = .tab_new });
        b.add(.{ .sym = c.XKB_KEY_Tab, .ctrl = true, .action = .tab_next });
        b.add(.{ .sym = c.XKB_KEY_Tab, .ctrl = true, .shift = true, .action = .tab_prev });
        b.add(.{ .sym = 0, .alt = true, .numrow = true, .action = .tab_goto });
        return b;
    }

    /// Add or replace. A later line wins, which is what makes `include` and a
    /// user override behave the way anyone would expect.
    pub fn add(self: *Bindings, raw: Binding) void {
        var binding = raw;
        // Normalised on the way in so a table never holds two entries that mean the
        // same combination.
        if (!binding.numrow and shiftSelectsChar(binding.sym)) binding.shift = false;

        for (self.items[0..self.len]) |*existing| {
            if (existing.sameCombo(binding)) {
                existing.action = binding.action;
                return;
            }
        }
        if (self.len == capacity) return;
        self.items[self.len] = binding;
        self.len += 1;
    }

    /// `keycode` is the raw evdev code, needed only by positional bindings.
    pub fn lookup(
        self: *const Bindings,
        sym: u32,
        keycode: u32,
        ctrl: bool,
        shift: bool,
        alt: bool,
    ) ?Action {
        const key = normalizeSym(sym);
        for (self.items[0..self.len]) |b| {
            // For a punctuation key, Shift is how the character was typed, not part of
            // the combination — see `shiftSelectsChar`.
            const want_shift = if (!b.numrow and shiftSelectsChar(b.sym)) false else shift;
            if (b.ctrl != ctrl or b.shift != want_shift or b.alt != alt) continue;
            const hit = if (b.numrow)
                numRowIndex(keycode) != null
            else
                b.sym == key;
            if (hit) return if (b.action == .none) null else b.action;
        }
        return null;
    }
};

/// Undo what Shift does to a keysym, so a combination is written as it reads.
///
/// With Shift held xkb reports the *shifted* keysym, which is a different symbol and not
/// merely a case: `C` for Ctrl+Shift+C, and — the one that bit — **`ISO_Left_Tab` for
/// Shift+Tab**. A default bound to `Tab` therefore never matched Ctrl+Shift+Tab, the key
/// fell through to the legacy encoder as `CSI Z`, and zsh ran `reverse-menu-complete`.
/// Which looked like the terminal doing something bizarre rather than like a binding that
/// simply was not there.
///
/// Any config that had to know these substitutions would be a trap, so they are undone
/// here instead — in one place, where the next one can be added.
/// Is Shift merely *how this character is typed*, rather than a modifier of its own?
///
/// Printable ASCII that is not alphanumeric — `%`, `&`, `$`, `_`. Which of those need
/// Shift depends entirely on the layout: `%` is `Shift+ù` on this AZERTY and unshifted
/// nowhere near there on a US keyboard. Requiring Shift in the binding would make the
/// config layout-specific, which is the very thing matching the character was meant to
/// avoid — so for these the Shift state is ignored.
///
/// Letters and digits are excluded deliberately. For them Shift *is* the distinction, and
/// `ctrl+c` must stay different from `ctrl+shift+c`.
fn shiftSelectsChar(sym: u32) bool {
    if (sym < 0x21 or sym > 0x7e) return false;
    return !std.ascii.isAlphanumeric(@intCast(sym));
}

fn normalizeSym(sym: u32) u32 {
    if (sym >= 'A' and sym <= 'Z') return sym + 32;
    if (sym == c.XKB_KEY_ISO_Left_Tab) return c.XKB_KEY_Tab;
    return sym;
}

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
    /// Keyboard shortcuts the terminal keeps for itself.
    bindings: Bindings = Bindings.defaults(),
    tab_bar_style: BarStyle = .powerline,
    tab_powerline_style: PowerlineStyle = .slanted,

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
            std.debug.print("maai: {s}:{d}: {s}\n", .{
                d.file.slice(),
                d.line,
                d.message.slice(),
            });
        }
        if (self.dropped > 0) {
            std.debug.print("maai: ...and {d} more\n", .{self.dropped});
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
            if (std.mem.eql(u8, key, "background")) &theme.bg else if (std.mem.eql(u8, key, "foreground")) &theme.fg else if (std.mem.eql(u8, key, "cursor")) &theme.cursor else if (std.mem.eql(u8, key, "cursor_text_color")) &theme.cursor_text else if (std.mem.eql(u8, key, "selection_background")) &theme.selection_bg else if (std.mem.eql(u8, key, "selection_foreground")) &theme.selection_fg else if (std.mem.eql(u8, key, "hint_background")) &theme.hint_bg else if (std.mem.eql(u8, key, "hint_foreground")) &theme.hint_fg else if (std.mem.eql(u8, key, "tab_bar_background")) &theme.bar_bg else if (std.mem.eql(u8, key, "inactive_tab_background")) &theme.bar_inactive_bg else if (std.mem.eql(u8, key, "inactive_tab_foreground")) &theme.bar_inactive_fg else if (std.mem.eql(u8, key, "active_tab_background")) &theme.bar_active_bg else if (std.mem.eql(u8, key, "active_tab_foreground")) &theme.bar_active_fg else null;

        if (slot) |s| {
            s.* = thememod.parseColor(value) orelse {
                diags.add(path, entry.line, "unparseable colour");
                continue;
            };
        }
        // Every other kitty theme key — tab bar, borders, bell — describes chrome
        // maai does not have yet. Silently ignored rather than reported, or loading
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
    } else if (std.mem.eql(u8, key, "tab_bar_style")) {
        cfg.tab_bar_style = std.meta.stringToEnum(BarStyle, value) orelse {
            diags.add(path, entry.line, "expected plain or powerline");
            return;
        };
    } else if (std.mem.eql(u8, key, "tab_powerline_style")) {
        cfg.tab_powerline_style = std.meta.stringToEnum(PowerlineStyle, value) orelse {
            diags.add(path, entry.line, "expected angled, slanted or round");
            return;
        };
    } else if (std.mem.eql(u8, key, "key")) {
        parseBinding(cfg, value, path, entry.line, diags);
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

/// `key ctrl+shift+c copy` — a combination, whitespace, an action.
///
/// Key names come from xkbcommon rather than a table of our own: `c`, `percent`,
/// `Page_Up`, `F5`, `Tab` all work, and they are the names already written in
/// `/usr/share/X11/xkb/symbols`, so there is one vocabulary rather than two.
fn parseBinding(
    cfg: *Config,
    value: []const u8,
    path: []const u8,
    line: usize,
    diags: *Diagnostics,
) void {
    const sep = std.mem.indexOfAny(u8, value, " \t") orelse {
        diags.add(path, line, "key needs a combination and an action");
        return;
    };
    const combo = value[0..sep];
    const action_name = std.mem.trim(u8, value[sep..], " \t");

    const action = std.meta.stringToEnum(Action, action_name) orelse {
        diags.add(path, line, "unknown action");
        return;
    };

    var binding = Binding{ .sym = 0, .action = action };
    var it = std.mem.splitScalar(u8, combo, '+');
    var key_name: ?[]const u8 = null;
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            binding.ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            binding.shift = true;
        } else if (std.ascii.eqlIgnoreCase(part, "alt")) {
            binding.alt = true;
        } else if (std.ascii.eqlIgnoreCase(part, "numrow")) {
            binding.numrow = true;
        } else {
            // Anything not a modifier is the key, and there can only be one.
            if (key_name != null) {
                diags.add(path, line, "more than one key in the combination");
                return;
            }
            key_name = part;
        }
    }

    if (binding.numrow) {
        if (key_name != null) {
            diags.add(path, line, "numrow is the key; it takes no other");
            return;
        }
        cfg.bindings.add(binding);
        return;
    }

    const name = key_name orelse {
        diags.add(path, line, "combination has no key");
        return;
    };

    var namez: [64]u8 = undefined;
    if (name.len >= namez.len) {
        diags.add(path, line, "key name too long");
        return;
    }
    @memcpy(namez[0..name.len], name);
    namez[name.len] = 0;

    const sym = c.xkb_keysym_from_name(@ptrCast(&namez), c.XKB_KEYSYM_CASE_INSENSITIVE);
    if (sym == c.XKB_KEY_NoSymbol) {
        diags.add(path, line, "unknown key name");
        return;
    }
    binding.sym = normalizeSym(sym);
    cfg.bindings.add(binding);
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
        "/etc/maai/theme.conf",
        resolveRelative("/etc/maai/maai.conf", "theme.conf", &out).?,
    );
    try testing.expectEqualStrings(
        "/abs.conf",
        resolveRelative("/etc/maai/maai.conf", "/abs.conf", &out).?,
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

test "bindings parse a combination and an action" {
    var cfg = Config{};
    var diags = Diagnostics{};
    parseInto(
        \\key ctrl+shift+f copy
        \\key alt+percent new_window
        \\key shift+Page_Up scroll_top
    , &cfg, &diags);
    try testing.expectEqual(@as(usize, 0), diags.len);

    try testing.expectEqual(Action.copy, cfg.bindings.lookup('f', 0, true, true, false).?);
    try testing.expectEqual(Action.new_window, cfg.bindings.lookup('%', 0, false, false, true).?);
    // Names come from xkbcommon, so the xkb spelling works as written.
    try testing.expectEqual(
        Action.scroll_top,
        cfg.bindings.lookup(c.XKB_KEY_Page_Up, 0, false, true, false).?,
    );

    // The modifiers are part of the match: the same key without them is not bound.
    try testing.expect(cfg.bindings.lookup('f', 0, false, false, false) == null);
}

test "Shift does not have to be spelled into the keysym" {
    // xkb reports `C` when Shift is held, so a config writing `ctrl+shift+c` would
    // never match unless lookups normalise. This is the trap that normalisation avoids.
    const b = Bindings.defaults();
    try testing.expectEqual(Action.copy, b.lookup('C', 0, true, true, false).?);
    try testing.expectEqual(Action.copy, b.lookup('c', 0, true, true, false).?);
}

test "a later line overrides an earlier one, and `none` frees a combination" {
    var cfg = Config{};
    var diags = Diagnostics{};

    // Ctrl+Shift+C is a default; rebinding it must replace rather than shadow.
    parseInto("key ctrl+shift+c hints", &cfg, &diags);
    try testing.expectEqual(Action.hints, cfg.bindings.lookup('c', 0, true, true, false).?);

    // ...and handing it back to applications is what `none` is for. This is the escape
    // hatch for combinations the keyboard protocol would otherwise expose.
    parseInto("key ctrl+shift+c none", &cfg, &diags);
    try testing.expect(cfg.bindings.lookup('c', 0, true, true, false) == null);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "a malformed binding is reported and the defaults survive" {
    var cfg = Config{};
    var diags = Diagnostics{};
    parseInto(
        \\key ctrl+shift+c nonsense_action
        \\key ctrl+nosuchkey copy
        \\key ctrl+shift copy
        \\key ctrl+a+b copy
        \\key onlyacombo
    , &cfg, &diags);

    try testing.expectEqual(@as(usize, 5), diags.len);
    // Every line was refused, so copy is still where it was.
    try testing.expectEqual(Action.copy, cfg.bindings.lookup('c', 0, true, true, false).?);
}

test "the binding table saturates rather than overflowing" {
    var b = Bindings{};
    for (0..Bindings.capacity + 10) |i| {
        b.add(.{ .sym = @intCast('a' + i), .action = .copy });
    }
    try testing.expectEqual(Bindings.capacity, b.len);
}

test "a positional binding matches the number row by key, not by character" {
    const b = Bindings.defaults();

    // On this AZERTY the unshifted row is `& é " ' ( - è _ ç à`, so the *keysym* differs
    // per position and per layout. The keycode does not.
    for (num_row, 0..) |code, i| {
        _ = i;
        try testing.expectEqual(Action.tab_goto, b.lookup(0, code, false, false, true).?);
    }
    // Outside the row, nothing.
    try testing.expect(b.lookup(0, 30, false, false, true) == null);
    // And the modifier still counts.
    try testing.expect(b.lookup(0, num_row[0], false, false, false) == null);
}

test "numRowIndex gives the position, which is the action's argument" {
    try testing.expectEqual(@as(usize, 0), numRowIndex(2).?);
    try testing.expectEqual(@as(usize, 8), numRowIndex(10).?);
    // KEY_0 sits last, as it does on the keyboard.
    try testing.expectEqual(@as(usize, 9), numRowIndex(11).?);
    try testing.expect(numRowIndex(1) == null);
}

test "numrow is configurable, and takes no other key" {
    var cfg = Config{};
    var diags = Diagnostics{};
    parseInto("key ctrl+numrow tab_goto", &cfg, &diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
    try testing.expectEqual(
        Action.tab_goto,
        cfg.bindings.lookup(0, num_row[3], true, false, false).?,
    );

    parseInto("key alt+numrow+f tab_goto", &cfg, &diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
}

test "the tab defaults are what was agreed" {
    const b = Bindings.defaults();
    try testing.expectEqual(Action.tab_new, b.lookup('t', 0, true, true, false).?);
    try testing.expectEqual(Action.tab_next, b.lookup(c.XKB_KEY_Tab, 0, true, false, false).?);
    try testing.expectEqual(Action.tab_prev, b.lookup(c.XKB_KEY_Tab, 0, true, true, false).?);
    // Plain Tab is untouched, which is the whole point of putting ours behind Ctrl.
    try testing.expect(b.lookup(c.XKB_KEY_Tab, 0, false, false, false) == null);
}

test "Shift+Tab is reported as ISO_Left_Tab and must still match `tab`" {
    // The regression this exists for: Ctrl+Shift+Tab reached the shell as CSI Z and zsh
    // ran reverse-menu-complete, because xkb substitutes a different keysym under Shift
    // and the default was bound to Tab.
    const b = Bindings.defaults();
    try testing.expectEqual(
        Action.tab_prev,
        b.lookup(c.XKB_KEY_ISO_Left_Tab, 0, true, true, false).?,
    );
    // Written as `tab` in a config, matched either way.
    var cfg = Config{};
    var diags = Diagnostics{};
    parseInto("key ctrl+shift+tab tab_next", &cfg, &diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
    try testing.expectEqual(
        Action.tab_next,
        cfg.bindings.lookup(c.XKB_KEY_ISO_Left_Tab, 0, true, true, false).?,
    );

    // Shift+Tab *without* Ctrl stays the application's: it is how every shell walks
    // completions backwards.
    try testing.expect(b.lookup(c.XKB_KEY_ISO_Left_Tab, 0, false, true, false) == null);
}

test "Shift needed to type a character is not part of the combination" {
    // The regression: `%` is Shift+ù on this AZERTY, so Alt+Shift+ù arrives with Shift
    // held — and the default, written `alt+percent`, required Shift *absent*. The window
    // never opened. The hardcoded check this table replaced ignored Shift, which is why
    // it worked before.
    const b = Bindings.defaults();
    try testing.expectEqual(Action.new_window, b.lookup('%', 0, false, true, true).?);
    // ...and equally on a layout where no Shift is needed.
    try testing.expectEqual(Action.new_window, b.lookup('%', 0, false, false, true).?);

    // Letters keep Shift as a real distinction, or copy and interrupt would collide.
    try testing.expectEqual(Action.copy, b.lookup('c', 0, true, true, false).?);
    try testing.expect(b.lookup('c', 0, true, false, false) == null);
}

test "writing shift into a punctuation binding is harmless, not a second entry" {
    var cfg = Config{};
    var diags = Diagnostics{};
    parseInto(
        \\key alt+shift+percent new_window
        \\key alt+percent hints
    , &cfg, &diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
    // Both spellings name the same combination, so the second replaced the first rather
    // than sitting behind it forever.
    try testing.expectEqual(Action.hints, cfg.bindings.lookup('%', 0, false, true, true).?);
}
