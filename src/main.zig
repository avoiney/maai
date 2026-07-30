//! myterm — phase 1: a PTY, a VT parser, and text on the screen.
//!
//! Usage:
//!   myterm              run $SHELL
//!   myterm -e cmd args  run a specific command (handy for scripted checks)

const std = @import("std");
const c = @import("c.zig").c;

const Window = @import("wl/window.zig").Window;
const Gl = @import("gfx/egl.zig").Gl;
const rendermod = @import("gfx/renderer.zig");
const Renderer = rendermod.Renderer;
const Padding = @import("gfx/renderer.zig").Padding;
const GlyphCache = @import("gfx/glyph_cache.zig").GlyphCache;
const Font = @import("font/font.zig").Font;
const Screen = @import("term/screen.zig").Screen;
const Pty = @import("pty/pty.zig").Pty;
const vt = @import("vt/parser.zig");
const sel = @import("term/selection.zig");
const mouse = @import("term/mouse.zig");
const urlmod = @import("term/url.zig");
const hintsmod = @import("term/hints.zig");
const launch = @import("launch.zig");
const cfgmod = @import("config.zig");
const watchmod = @import("watch.zig");
const ptr = @import("wl/pointer.zig");
const clip = @import("wl/clipboard.zig");

const atlas_size = 2048;
/// Per-read chunk. Bigger reads mean fewer syscalls during heavy output.
const read_chunk = 64 * 1024;
/// Cap on bytes parsed per loop iteration, so a flood cannot starve input or
/// resize handling. The loop simply comes back around for more (PLAN.md §2).
const drain_budget = 1024 * 1024;
/// How long synchronized output (DECSET 2026) may suppress presentation before we
/// draw anyway. Guards against an application that sets the mode and then dies.
const sync_timeout_ms = 150;

/// Two clicks within this window at the same cell count as a double click.
const multi_click_ms = 400;

/// Wheel notches to honour in one axis event. A flick can deliver a large
/// accumulated delta, and turning that into an unbounded burst of reports or cursor
/// keys hands the child more input than the gesture meant.
const max_wheel_notches = 16;
/// Cursor keys sent per wheel notch under alternate scroll, matching the three
/// lines the local scrollback moves.
const arrows_per_notch = 3;

/// Ceiling on tabs. A bound rather than a growable list because the whole point of the
/// fixed array is that tab addresses never move: the parser holds a `*Screen`, so a
/// reallocation would leave it pointing at freed memory.
const max_tabs = 32;

/// One terminal session: its screen, its child, and the parser between them.
///
/// Heap-allocated and never moved. `parser` holds a pointer to `screen` *in the same
/// struct*, so copying a Tab by value would leave the copy's parser feeding the
/// original's screen — a bug that would look like output landing in the wrong tab.
const Tab = struct {
    screen: Screen,
    pty: Pty,
    parser: vt.Parser(Screen),

    fn create(
        gpa: std.mem.Allocator,
        cols: u32,
        rows: u32,
        cfg: *const cfgmod.Config,
        argv: [*:null]const ?[*:0]const u8,
        /// Where the child starts; empty means inherit ours.
        dir: []const u8,
    ) !*Tab {
        const tab = try gpa.create(Tab);
        errdefer gpa.destroy(tab);

        tab.screen = try Screen.initScrollback(gpa, cols, rows, cfg.scrollback_lines);
        errdefer tab.screen.deinit();
        applyConfig(&tab.screen, cfg);

        tab.pty = try Pty.spawn(cols, rows, argv, dir);
        // Only now, once `screen` sits at its final address.
        tab.parser = vt.Parser(Screen).init(&tab.screen);
        return tab;
    }

    fn destroy(self: *Tab, gpa: std.mem.Allocator) void {
        self.pty.deinit();
        self.screen.deinit();
        gpa.destroy(self);
    }
};

const App = struct {
    gpa: std.mem.Allocator,
    win: *Window,
    gl: *Gl,
    /// The active tab's screen and child. Held as pointers so every method below reads
    /// the same way whether there is one tab or ten.
    screen: *Screen,
    pty: *Pty,
    tabs: [max_tabs]*Tab = undefined,
    tab_count: usize = 0,
    active: usize = 0,
    /// The child command, so a new tab runs the same thing as the first.
    child_argv: [*:null]const ?[*:0]const u8,
    /// Scratch for the tab bar, rebuilt each frame it is drawn.
    bar: [1024]rendermod.BarCell = undefined,
    font: *const Font,
    pad: Padding,
    cfg: *const cfgmod.Config,
    /// Set by MYTERM_DEBUG. Traces input and selection handling, which is
    /// otherwise invisible: these paths are driven by hardware events that cannot
    /// be reproduced from a script.
    debug: bool = false,

    frame_pending: bool = false,
    /// Set when the compositor has given us a frame and the grid has changed.
    needs_render: bool = true,

    /// Pointer state for selection dragging and click counting.
    dragging: bool = false,
    last_click_ms: i64 = 0,
    last_click_line: usize = 0,
    last_click_x: u32 = 0,
    click_count: u2 = 0,

    /// Buttons the *application* currently holds, as `heldBit` values. Non-zero
    /// means a reported drag is in progress.
    held_mask: u8 = 0,
    /// Last cell reported to the application, so motion reports once per cell
    /// rather than once per pointer event. Starts out of range so the first motion
    /// always reports.
    report_col: u32 = std.math.maxInt(u32),
    report_row: u32 = std.math.maxInt(u32),

    /// Launched URL handlers awaiting reaping.
    reaper: launch.Reaper = .{},

    /// Hint mode: every visible link labelled, waiting for a label to be typed.
    /// While active, every key belongs to us — none reach the child.
    hint_on: bool = false,
    hints: [hintsmod.max_hints]hintsmod.Hint = undefined,
    hint_n: usize = 0,
    hint_typed: [2]u8 = undefined,
    hint_typed_len: u8 = 0,

    fn tab(self: *App) *Tab {
        return self.tabs[self.active];
    }

    /// Point everything that follows the focus at tab `i`.
    fn focus(self: *App, i: usize) void {
        if (i >= self.tab_count) return;
        self.active = i;
        const t = self.tabs[i];
        self.screen = &t.screen;
        self.pty = &t.pty;
        // The key encoder reads the *active* screen's modes: DECCKM and the keyboard
        // protocol are per-session, so a background tab's must not encode our keys.
        self.win.keyboard.modes = &t.screen.modes;
        t.screen.reply = .{ .ctx = self, .write = App.writeToPty };
        self.hintsExit();
        self.needs_render = true;
    }

    /// Lay the tab bar out, one column per cell.
    ///
    /// Built here rather than in the renderer because it is *layout* — truncation,
    /// separators, numbering, which tab is active — and the renderer's job is to put
    /// cells on screen. It also owns the colours, since powerline needs a cell holding
    /// two tabs' colours at once.
    fn buildBar(self: *App) []const rendermod.BarCell {
        const cols = self.screen.grid.cols;
        const theme = &self.screen.theme;
        const powerline = self.cfg.tab_bar_style == .powerline;
        const sep = self.cfg.tab_powerline_style.separator();
        var n: usize = 0;

        const room = @min(cols, self.bar.len);

        for (self.tabs[0..self.tab_count], 0..) |t, i| {
            const active = i == self.active;
            const fg = if (active) theme.bar_active_fg else theme.bar_inactive_fg;
            const bg = if (active) theme.bar_active_bg else theme.bar_inactive_bg;

            var label: [64]u8 = undefined;
            const title = t.screen.title();
            const text = if (title.len > 0)
                std.fmt.bufPrint(&label, " {d}: {s} ", .{ i + 1, title }) catch continue
            else
                std.fmt.bufPrint(&label, " {d} ", .{i + 1}) catch continue;

            // Decoded as UTF-8 so a title with accents occupies the columns it looks
            // like it occupies, rather than one per byte.
            var it = (std.unicode.Utf8View.init(text) catch continue).iterator();
            while (it.nextCodepoint()) |cp| {
                if (n == room) break;
                self.bar[n] = .{ .cp = cp, .fg = fg, .bg = bg };
                n += 1;
            }
            if (n == room) break;

            if (powerline) {
                // The separator wears the colour of the tab it leaves, on the background
                // of whatever comes next. That is the whole trick: the glyph reads as
                // the edge of the previous tab rather than as a character of its own.
                const next_bg = if (i + 1 < self.tab_count)
                    (if (i + 1 == self.active) theme.bar_active_bg else theme.bar_inactive_bg)
                else
                    theme.bar_bg;
                self.bar[n] = .{ .cp = sep, .fg = bg, .bg = next_bg };
                n += 1;
                if (n == room) break;
            }
        }

        // The strip runs the full width, so the bar reads as a bar and not as a label
        // floating on the terminal background.
        while (n < room) : (n += 1) {
            self.bar[n] = .{ .cp = ' ', .fg = theme.bar_inactive_fg, .bg = theme.bar_bg };
        }
        return self.bar[0..n];
    }

    /// Open a tab, starting where the current one is.
    fn tabNew(self: *App) void {
        if (self.tab_count == max_tabs) {
            std.debug.print("myterm: {d} tabs is the limit\n", .{max_tabs});
            return;
        }

        var buf: [launch.max_path_len]u8 = undefined;
        const announced = self.screen.cwd();
        const dir = if (announced.len > 0) announced else self.pty.cwd(&buf) orelse "";

        const t = Tab.create(
            self.gpa,
            self.screen.grid.cols,
            self.screen.grid.rows,
            self.cfg,
            self.child_argv,
            dir,
        ) catch |err| {
            std.debug.print("myterm: could not open a tab: {s}\n", .{@errorName(err)});
            return;
        };
        self.tabs[self.tab_count] = t;
        self.tab_count += 1;
        self.focus(self.tab_count - 1);
    }

    /// Drop tab `i`, whose child has gone. Returns false when that was the last one.
    fn tabClosed(self: *App, i: usize) bool {
        self.tabs[i].destroy(self.gpa);
        var k = i;
        while (k + 1 < self.tab_count) : (k += 1) self.tabs[k] = self.tabs[k + 1];
        self.tab_count -= 1;
        if (self.tab_count == 0) return false;
        // Focus the neighbour, which is what closing a tab means everywhere else.
        self.focus(@min(i, self.tab_count - 1));
        return true;
    }

    fn writeToPty(ctx: *anyopaque, bytes: []const u8) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        // Typing snaps the view back to the live screen; otherwise the reply to
        // whatever you just typed scrolls past unseen.
        if (self.screen.grid.view != 0) {
            self.screen.grid.resetView();
            self.needs_render = true;
        }
        self.pty.write(bytes);
    }

    /// Map surface-local pixels to a cell on the *visible* screen.
    fn cellAt(self: *App, px: f64, py: f64) CellPos {
        const grid = &self.screen.grid;
        const fx = @max(px - @as(f64, @floatFromInt(self.pad.x)), 0);
        const fy = @max(py - @as(f64, @floatFromInt(self.pad.y)), 0);

        const col = @as(u32, @intFromFloat(fx / @as(f64, @floatFromInt(self.font.cell_w))));
        const row = @as(u32, @intFromFloat(fy / @as(f64, @floatFromInt(self.font.cell_h))));

        return .{
            .col = @min(col, grid.cols - 1),
            .row = @min(row, grid.rows - 1),
        };
    }

    /// Same position as a point in the grid ring, which is what selection needs so
    /// that a selection stays anchored to its text while the view scrolls.
    fn pointAt(self: *App, px: f64, py: f64) sel.Point {
        const cell = self.cellAt(px, py);
        return .{ .line = self.screen.grid.viewTop() + cell.row, .x = cell.col };
    }

    /// Does this pointer event belong to the application rather than to us?
    ///
    /// A press decides, and every event until the matching release follows that
    /// decision. Re-deciding per event would let pressing Shift mid-drag leave the
    /// application with a button stuck down forever — it would never see the up.
    fn mouseGoesToApp(self: *App, mods: mouse.Mods) bool {
        if (self.screen.mouse.mode() == .off) {
            // An application that switches tracking off mid-drag will never send
            // the release we are holding the pointer for. Forget it here rather
            // than routing every later event to nobody.
            self.held_mask = 0;
            return false;
        }
        if (self.held_mask != 0) return true; // the application's drag
        if (self.dragging) return false; // ours

        // Shift is the universal override, and it is not a nicety: while an
        // application holds the mouse it is the only way to select text out of
        // nvim, tmux or lazygit. Ctrl is ours too, because it opens links; that is
        // also why the planned Ctrl+drag block selection moves to Alt+drag.
        if (mods.shift or mods.ctrl) return false;
        // Scrolled into history, the application's coordinate space no longer
        // matches what is on screen — a report would make it act on unrelated text.
        // Local selection and local scrolling stay available up there instead.
        if (self.screen.grid.view != 0) return false;
        return true;
    }

    /// What is under `at`: an OSC 8 hyperlink if the cell carries one, otherwise
    /// whatever the plain-text scanner can make of the surrounding characters.
    ///
    /// OSC 8 wins because it is explicit. An application that went to the trouble of
    /// declaring a target knows better than our heuristics — and its link text often
    /// is not a URL at all.
    fn linkUnder(self: *App, at: sel.Point) ?Link {
        if (self.screen.hyperlinkAt(at)) |h| {
            return .{ .span = h.span, .id = h.id };
        }
        if (urlmod.find(&self.screen.grid, at)) |span| {
            return .{ .span = span, .id = 0 };
        }
        return null;
    }

    /// Recompute what the pointer is hovering, and reflect it in the cursor shape.
    ///
    /// Only while Ctrl is held: underlining every URL the pointer crosses while you
    /// are simply reading is noise, and the underline is a promise that a click
    /// *right now* will open that link.
    fn updateHover(self: *App, mods: mouse.Mods) void {
        const before = self.screen.hover;
        self.screen.hover = if (mods.ctrl) blk: {
            const hit = self.linkUnder(self.pointAt(
                self.win.pointer.x,
                self.win.pointer.y,
            )) orelse break :blk null;
            break :blk hit.span;
        } else null;

        self.win.pointer.setShape(if (self.screen.hover != null) .pointer else .text);

        const changed = if (before) |b|
            if (self.screen.hover) |a| !a.eql(b) else true
        else
            self.screen.hover != null;
        if (changed) self.needs_render = true;
    }

    /// Open another window in the same directory.
    ///
    /// The directory comes from `/proc` first and OSC 7 only as a refinement, because
    /// this machine's zsh — like most shells — never emits OSC 7. Building this on the
    /// escape sequence alone would have shipped a binding that does nothing.
    fn newWindowHere(self: *App) void {
        var buf: [launch.max_path_len]u8 = undefined;
        const announced = self.screen.cwd();
        const dir = if (announced.len > 0)
            announced
        else
            self.pty.cwd(&buf) orelse {
                if (self.debug) std.debug.print("new window: no cwd\n", .{});
                return;
            };

        if (self.debug) std.debug.print("new window in '{s}'\n", .{dir});
        if (launch.newWindow(dir)) |pid| {
            self.reaper.track(pid);
        } else {
            std.debug.print("myterm: could not open a window in '{s}'\n", .{dir});
        }
    }

    /// Called when the modifier state changes, so the underline appears the moment
    /// Ctrl goes down rather than on the next pointer motion.
    fn onModsChanged(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.updateHover(self.win.keyboard.activeMods());
    }

    /// Open whatever is under the pointer, if it is a link. Returns true if it was.
    fn openLinkAt(self: *App, at: sel.Point) bool {
        const hit = self.linkUnder(at) orelse return false;
        self.openLink(hit);
        return true;
    }

    // ── hint mode ──────────────────────────────────────────────────────────

    fn hintsEnter(self: *App) void {
        self.hint_n = hintsmod.collect(self.screen, &self.hints);
        self.hint_typed_len = 0;
        self.hint_on = self.hint_n > 0;
        if (self.debug) std.debug.print("hints: {d} labelled\n", .{self.hint_n});
        self.needs_render = true;
    }

    fn hintsExit(self: *App) void {
        self.hint_on = false;
        self.hint_n = 0;
        self.hint_typed_len = 0;
        self.needs_render = true;
    }

    /// Handle one key while hint mode is up. Always consumes it: a stray keystroke
    /// reaching the shell from here would be typed into a command line the user
    /// cannot see behind the labels.
    fn hintsKey(self: *App, sym: u32, shift: bool) void {
        const ch: ?u8 = switch (sym) {
            'a'...'z' => @intCast(sym),
            // Shift is the copy modifier, so labels have to match case-insensitively.
            'A'...'Z' => @intCast(sym + 32),
            else => null,
        };
        // A modifier going down is not a keystroke to act on. Without this, holding
        // Shift to copy would cancel the mode before the label was even typed.
        switch (sym) {
            c.XKB_KEY_Shift_L,
            c.XKB_KEY_Shift_R,
            c.XKB_KEY_Control_L,
            c.XKB_KEY_Control_R,
            c.XKB_KEY_Alt_L,
            c.XKB_KEY_Alt_R,
            c.XKB_KEY_Super_L,
            c.XKB_KEY_Super_R,
            c.XKB_KEY_Meta_L,
            c.XKB_KEY_Meta_R,
            c.XKB_KEY_ISO_Level3_Shift,
            c.XKB_KEY_Caps_Lock,
            c.XKB_KEY_Num_Lock,
            => return,
            else => {},
        }

        const letter = ch orelse {
            // Escape, Enter, an arrow — anything that is not a label ends the mode.
            self.hintsExit();
            return;
        };

        self.hint_typed[self.hint_typed_len] = letter;
        self.hint_typed_len += 1;
        const typed = self.hint_typed[0..self.hint_typed_len];

        switch (hintsmod.match(self.hints[0..self.hint_n], typed)) {
            .partial => self.needs_render = true,
            .miss => self.hintsExit(),
            .hit => |i| {
                const hint = self.hints[i];
                // Copy the target out of the hint before leaving the mode, since
                // exiting clears the array it lives in.
                const link = Link{ .span = hint.span, .id = hint.id };
                self.hintsExit();
                if (shift) self.copyLink(link) else self.openLink(link);
            },
        }
    }

    /// The target of a link as UTF-8. Caller frees.
    fn linkTarget(self: *App, link: Link) ?[]u8 {
        // An OSC 8 target lives in the link table, not in the cells: what is on
        // screen is the *label*, which is frequently not a URL at all.
        if (link.id != 0) {
            return self.gpa.dupe(u8, self.screen.links.get(link.id)) catch null;
        }
        return urlmod.text(
            self.gpa,
            &self.screen.grid,
            &self.screen.graphemes,
            link.span,
        ) catch null;
    }

    fn openLink(self: *App, link: Link) void {
        const text = self.linkTarget(link) orelse return;
        defer self.gpa.free(text);

        if (self.debug) std.debug.print("link: opening '{s}'\n", .{text});
        var program: [512]u8 = undefined;
        const name = self.cfg.url_launcher.slice();
        @memcpy(program[0..name.len], name);
        program[name.len] = 0;
        if (launch.openWith(@ptrCast(&program), text)) |pid| {
            self.reaper.track(pid);
            return;
        }
        // Rejected by the allowlist or the spawn failed. Say so rather than looking
        // like a click that did nothing.
        std.debug.print("myterm: refused to open '{s}'\n", .{text});
    }

    fn copyLink(self: *App, link: Link) void {
        const text = self.linkTarget(link) orelse return;
        defer self.gpa.free(text);
        if (self.debug) std.debug.print("link: copying '{s}'\n", .{text});
        self.win.clipboard.offer(.clipboard, text, self.win.keyboard.last_serial);
    }

    fn reportMouse(self: *App, ev: mouse.Event) void {
        var buf: [mouse.max_len]u8 = undefined;
        const bytes = mouse.encode(
            &buf,
            self.screen.mouse.mode(),
            self.screen.mouse.encoding(),
            ev,
        ) orelse return;
        if (self.debug) {
            // Every report starts with ESC; printing the rest verbatim keeps the
            // trace readable without an escaping formatter.
            std.debug.print("mouse -> app: {s} {s} at {d},{d}: ESC{s}\n", .{
                @tagName(ev.button),
                @tagName(ev.kind),
                ev.col,
                ev.row,
                bytes[1..],
            });
        }
        // Straight to the PTY rather than through `writeToPty`: a mouse report is
        // not typing, and must not snap the view back to the live screen.
        self.pty.write(bytes);
    }

    fn appButton(self: *App, code: u32, pressed: bool, cell: CellPos, mods: mouse.Mods) void {
        const b = mouseButton(code) orelse return;
        const bit = heldBit(b);
        if (pressed) self.held_mask |= bit else self.held_mask &= ~bit;

        self.report_col = cell.col;
        self.report_row = cell.row;
        self.reportMouse(.{
            .button = b,
            .kind = if (pressed) .press else .release,
            .col = cell.col,
            .row = cell.row,
            .mods = mods,
        });
    }

    fn onMotion(ctx: *anyopaque, px: f64, py: f64) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const mods = self.win.keyboard.activeMods();

        if (self.mouseGoesToApp(mods)) {
            const cell = self.cellAt(px, py);
            // One report per cell entered, not one per pointer event: motion
            // arrives at device rate, and an application that redraws on each
            // report would be permanently behind the pointer.
            if (cell.col == self.report_col and cell.row == self.report_row) return;
            self.report_col = cell.col;
            self.report_row = cell.row;
            self.reportMouse(.{
                .button = heldButton(self.held_mask),
                .kind = .motion,
                .col = cell.col,
                .row = cell.row,
                .mods = mods,
            });
            return;
        }

        if (!self.dragging) {
            if (self.debug) std.debug.print("motion {d:.0},{d:.0} (not dragging)\n", .{ px, py });
            self.updateHover(mods);
            return;
        }
        const p = self.pointAt(px, py);
        self.screen.selection.extend(&self.screen.grid, p);
        if (self.debug) {
            const b = self.screen.selection.bounds();
            std.debug.print(
                "motion {d:.0},{d:.0} -> line {d} col {d}; sel {d}:{d}..{d}:{d}\n",
                .{ px, py, p.line, p.x, b.start.line, b.start.x, b.end.line, b.end.x },
            );
        }
        self.needs_render = true;
    }

    fn onButton(ctx: *anyopaque, button: u32, pressed: bool, serial: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const mods = self.win.keyboard.activeMods();

        if (self.mouseGoesToApp(mods)) {
            self.appButton(button, pressed, self.cellAt(
                self.win.pointer.x,
                self.win.pointer.y,
            ), mods);
            return;
        }

        const p = self.pointAt(self.win.pointer.x, self.win.pointer.y);

        switch (button) {
            ptr.button_left => {
                // Ctrl+click opens a link instead of selecting. Only when there is
                // one under the pointer, so Ctrl+click elsewhere still selects.
                if (pressed and mods.ctrl and self.openLinkAt(p)) return;

                if (pressed) {
                    const now = monotonicMs();
                    const same_cell = p.line == self.last_click_line and
                        p.x == self.last_click_x;
                    if (same_cell and now - self.last_click_ms < multi_click_ms) {
                        self.click_count = if (self.click_count >= 3) 1 else self.click_count + 1;
                    } else {
                        self.click_count = 1;
                    }
                    self.last_click_ms = now;
                    self.last_click_line = p.line;
                    self.last_click_x = p.x;

                    const mode: sel.Mode = switch (self.click_count) {
                        1 => .char,
                        2 => .word,
                        else => .line,
                    };
                    self.screen.selection.begin(&self.screen.grid, p, mode);
                    self.dragging = true;
                    if (self.debug) {
                        std.debug.print(
                            "press left at line {d} col {d}, clicks {d}, mode {s}\n",
                            .{ p.line, p.x, self.click_count, @tagName(mode) },
                        );
                    }
                } else if (self.dragging) {
                    self.dragging = false;
                    // Finishing a selection publishes it to PRIMARY, so middle-click
                    // paste works, *and* to CLIPBOARD so Ctrl+Shift+V picks it up.
                    // Feeding CLIPBOARD on select is not the platform default — it
                    // means a clipboard manager records every mouse selection — but
                    // it is what was asked for here. Becomes a config option
                    // (`copy_on_select`) in phase 6.
                    //
                    // Gated on `dragging`: a release that did not follow one of our
                    // presses — the button went down while the application owned the
                    // mouse — must not republish a stale selection.
                    if (self.cfg.copy_on_select) {
                        self.publishSelection(serial, &.{ .primary, .clipboard });
                    } else {
                        self.publishSelection(serial, &.{.primary});
                    }
                }
                self.needs_render = true;
            },
            ptr.button_middle => {
                if (pressed) self.pasteFrom(.primary);
            },
            else => {},
        }
    }

    fn onAxis(ctx: *anyopaque, lines: f64) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const mods = self.win.keyboard.activeMods();
        // Wheel down is positive.
        const up = lines < 0;
        const notches = @min(
            @as(usize, @intFromFloat(@abs(lines))),
            max_wheel_notches,
        );

        if (self.mouseGoesToApp(mods)) {
            const cell = self.cellAt(self.win.pointer.x, self.win.pointer.y);
            for (0..notches) |_| {
                self.reportMouse(.{
                    .button = if (up) .wheel_up else .wheel_down,
                    .kind = .press,
                    .col = cell.col,
                    .row = cell.row,
                    .mods = mods,
                });
            }
            return;
        }

        // The alternate screen has no scrollback of its own, so the wheel would
        // otherwise do nothing at all here. xterm's mode 1007 turns it into cursor
        // keys, which is what makes the wheel work in `less` and `man` — neither of
        // which asks for mouse tracking.
        if (self.screen.in_alt and self.screen.modes.alternate_scroll) {
            self.sendArrows(up, notches * arrows_per_notch);
            return;
        }

        // Scrolling back through history is negative view motion, hence the
        // inversion.
        const delta: i64 = @intFromFloat(-lines * 3);
        self.screen.grid.scrollView(delta);
        self.needs_render = true;
    }

    fn sendArrows(self: *App, up: bool, count: usize) void {
        // DECCKM applies to synthesised cursor keys exactly as to typed ones; an
        // application in application-keypad mode does not recognise the CSI form.
        const seq: []const u8 = if (self.screen.modes.app_cursor)
            (if (up) "\x1bOA" else "\x1bOB")
        else
            (if (up) "\x1b[A" else "\x1b[B");
        for (0..count) |_| self.pty.write(seq);
    }

    /// Publish the current selection to one or both selections. The text is
    /// extracted once and offered to each, since a drag now feeds both.
    fn publishSelection(self: *App, serial: u32, kinds: []const clip.Kind) void {
        const s = &self.screen.selection;
        if (!s.active) {
            if (self.debug) std.debug.print("publish: no active selection\n", .{});
            return;
        }
        const text = s.copyText(self.gpa, &self.screen.grid, &self.screen.graphemes) catch |err| {
            if (self.debug) std.debug.print("publish: copy failed {s}\n", .{@errorName(err)});
            return;
        };
        defer self.gpa.free(text);
        if (self.debug) {
            std.debug.print("publish: {d} bytes, serial {d}\n", .{ text.len, serial });
        }
        if (text.len == 0) return;
        for (kinds) |kind| self.win.clipboard.offer(kind, text, serial);
    }

    fn pasteFrom(self: *App, kind: clip.Kind) void {
        const text = self.win.clipboard.paste(kind, self.win.display) orelse return;
        defer self.gpa.free(text);
        if (text.len == 0) return;

        // Bracketed paste lets the application tell pasted text from typing, which
        // is what stops a pasted newline from executing a command outright. When the
        // application has not enabled it we sanitise instead: strip C0 controls
        // except tab, and turn newlines into carriage returns so the result behaves
        // like typed input rather than smuggling escape sequences.
        if (self.screen.modes.bracketed_paste) {
            self.pty.write("\x1b[200~");
            self.pty.write(text);
            self.pty.write("\x1b[201~");
        } else {
            var buf: [1024]u8 = undefined;
            var n: usize = 0;
            for (text) |ch| {
                const out: ?u8 = switch (ch) {
                    '\n', '\r' => '\r',
                    '\t' => '\t',
                    0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => null,
                    else => ch,
                };
                if (out) |o| {
                    buf[n] = o;
                    n += 1;
                    if (n == buf.len) {
                        self.pty.write(buf[0..n]);
                        n = 0;
                    }
                }
            }
            if (n > 0) self.pty.write(buf[0..n]);
        }

        // Any input snaps the view back to the live screen.
        self.screen.grid.resetView();
        self.needs_render = true;
    }

    /// Application shortcuts. Returning true stops the key reaching the child.
    ///
    /// The table comes from the config, so a combination can be moved or handed back to
    /// applications with `key <combo> none` — which matters for the ones we take that
    /// the keyboard protocol would otherwise make available.
    fn onBinding(
        ctx: *anyopaque,
        sym: u32,
        keycode: u32,
        ctrl: bool,
        shift: bool,
        alt: bool,
    ) bool {
        const self: *App = @ptrCast(@alignCast(ctx));

        // Hint mode swallows everything while it is up — see `hintsKey`.
        if (self.hint_on) {
            self.hintsKey(sym, shift);
            return true;
        }

        const action = self.cfg.bindings.lookup(sym, keycode, ctrl, shift, alt) orelse
            return false;
        const grid = &self.screen.grid;
        switch (action) {
            .none => return false,
            .copy => self.publishSelection(self.win.keyboard.last_serial, &.{.clipboard}),
            .paste => self.pasteFrom(.clipboard),
            .paste_primary => self.pasteFrom(.primary),
            .hints => self.hintsEnter(),
            .new_window => self.newWindowHere(),
            .scroll_page_up => {
                grid.scrollView(@intCast(grid.rows / 2));
                self.needs_render = true;
            },
            .scroll_page_down => {
                grid.scrollView(-@as(i64, @intCast(grid.rows / 2)));
                self.needs_render = true;
            },
            .scroll_top => {
                grid.scrollView(@intCast(grid.maxView()));
                self.needs_render = true;
            },
            .scroll_bottom => {
                grid.resetView();
                self.needs_render = true;
            },
            .tab_new => self.tabNew(),
            .tab_next => self.focus((self.active + 1) % self.tab_count),
            .tab_prev => self.focus(
                (self.active + self.tab_count - 1) % self.tab_count,
            ),
            .tab_goto => {
                // The key's position *is* the argument, which is what lets one binding
                // cover all ten keys.
                const i = cfgmod.numRowIndex(keycode) orelse return true;
                if (i < self.tab_count) self.focus(i);
            },
        }
        return true;
    }
};

/// A position on the visible screen, 0-based.
const CellPos = struct { col: u32, row: u32 };

/// A clickable link: the cells it covers, plus its OSC 8 id when it has one.
const Link = struct {
    span: urlmod.Span,
    /// Non-zero for an OSC 8 hyperlink, whose target is in `Screen.links` rather
    /// than in the cells themselves.
    id: u16,
};

/// evdev button code to the wire button number.
///
/// Unknown codes return null and are dropped rather than guessed at: a gaming
/// mouse's extra buttons have no agreed terminal meaning.
fn mouseButton(code: u32) ?mouse.Button {
    return switch (code) {
        ptr.button_left => .left,
        ptr.button_middle => .middle,
        ptr.button_right => .right,
        ptr.button_side, ptr.button_back => .back,
        ptr.button_extra, ptr.button_forward => .forward,
        else => null,
    };
}

fn heldBit(b: mouse.Button) u8 {
    return switch (b) {
        .left => 1,
        .middle => 2,
        .right => 4,
        .back => 8,
        .forward => 16,
        // The wheel has no release, so nothing to track.
        else => 0,
    };
}

/// Which button a motion report should name. With several down, the first in this
/// order wins — the wire format has room for exactly one.
fn heldButton(mask: u8) mouse.Button {
    if (mask & 1 != 0) return .left;
    if (mask & 2 != 0) return .middle;
    if (mask & 4 != 0) return .right;
    if (mask & 8 != 0) return .back;
    if (mask & 16 != 0) return .forward;
    return .none;
}

test {
    // Test discovery follows *referenced* declarations, and in test mode nothing
    // references `main` — so without this block `zig build test` silently covered
    // almost nothing. Found by breaking an assertion in launch.zig on purpose and
    // watching the suite stay green.
    _ = @import("config.zig");
    _ = @import("watch.zig");
    _ = @import("launch.zig");
    _ = @import("font/font.zig");
    _ = @import("gfx/atlas.zig");
    _ = @import("gfx/egl.zig");
    _ = @import("gfx/glyph_cache.zig");
    _ = @import("gfx/renderer.zig");
    _ = @import("pty/pty.zig");
    _ = @import("term/cell.zig");
    _ = @import("term/grid.zig");
    _ = @import("term/hints.zig");
    _ = @import("term/mouse.zig");
    _ = @import("term/reclaim.zig");
    _ = @import("term/screen.zig");
    _ = @import("term/screen_test.zig");
    _ = @import("term/selection.zig");
    _ = @import("term/theme.zig");
    _ = @import("term/url.zig");
    _ = @import("term/width.zig");
    _ = @import("vt/parser.zig");
    _ = @import("wl/clipboard.zig");
    _ = @import("wl/keyboard.zig");
    _ = @import("wl/pointer.zig");
    _ = @import("wl/window.zig");
}

/// Zig 0.16 hands argv and environ to `main` rather than exposing them as
/// globals, so we take the `Init.Minimal` form.
pub fn main(init: std.process.Init.Minimal) !void {
    ignoreSigpipe();

    // We link libc anyway, so use its allocator rather than paying for Zig's
    // debug allocator bookkeeping in the render path.
    const gpa = std.heap.c_allocator;

    const args = parseArgs(init.args.vector);
    const argv = try buildArgv(gpa, args.child, init.environ);
    defer gpa.free(argv);

    // Start where we were asked to. Before the fork, so the child inherits it — and
    // failure is not fatal: a window that opens in the wrong directory beats one that
    // does not open, and the directory came from another process's OSC 7.
    if (args.cwd.len > 0) {
        var dirz: [launch.max_path_len + 1]u8 = undefined;
        if (args.cwd.len <= launch.max_path_len) {
            @memcpy(dirz[0..args.cwd.len], args.cwd);
            dirz[args.cwd.len] = 0;
            if (std.c.chdir(@ptrCast(&dirz)) != 0) {
                std.debug.print("myterm: could not enter '{s}'\n", .{args.cwd});
            }
        }
    }

    // ── config before anything it configures ────────────────────────────────
    var diags = cfgmod.Diagnostics{};
    var cfg = loadConfig(gpa, args.config_path, &diags);
    diags.report();

    // ── font: cell geometry determines the initial window size ──────────────
    var font = loadFont(&cfg) catch |err| {
        std.debug.print("myterm: could not load '{s}' ({s})\n", .{
            cfg.font_family.slice(),
            @errorName(err),
        });
        return err;
    };
    defer font.deinit();

    var win: Window = undefined;
    try win.init(gpa);
    defer win.deinit();

    var gl: Gl = undefined;
    try gl.init(&win);
    defer gl.deinit();

    var renderer = try Renderer.init(gpa);
    defer renderer.deinit();

    var cache = GlyphCache.init(gpa, &font, atlas_size);
    defer cache.deinit();

    var pad = Padding{ .x = cfg.padding_x, .y = cfg.padding_y };
    var dims = gridSize(win.width, win.height, &font, pad);

    const first = Tab.create(gpa, dims.cols, dims.rows, &cfg, argv.ptr, "") catch |err| {
        std.debug.print("myterm: could not start {s}: {s}\n", .{
            std.mem.span(argv[0].?),
            @errorName(err),
        });
        return err;
    };

    var app = App{
        .gpa = gpa,
        .win = &win,
        .gl = &gl,
        .screen = &first.screen,
        .pty = &first.pty,
        .font = &font,
        .pad = pad,
        .cfg = &cfg,
        .child_argv = argv.ptr,
        .debug = std.c.getenv("MYTERM_DEBUG") != null,
    };
    app.tabs[0] = first;
    app.tab_count = 1;
    defer for (app.tabs[0..app.tab_count]) |t| t.destroy(gpa);

    win.keyboard.sink = .{ .ctx = &app, .write = App.writeToPty };
    win.keyboard.bindings = .{ .ctx = &app, .handle = App.onBinding };
    // DECCKM and friends change how keys encode, so the encoder needs to see them.
    win.keyboard.modes = &first.screen.modes;
    win.keyboard.on_mods = .{ .ctx = &app, .changed = App.onModsChanged };
    win.pointer.handler = .{
        .ctx = &app,
        .motion = App.onMotion,
        .button = App.onButton,
        .axis = App.onAxis,
    };
    // Device queries (DA, DSR) answer back down the PTY.
    first.screen.reply = .{ .ctx = &app, .write = App.writeToPty };

    // Live reload. A missing inotify fd is not fatal — the terminal simply stops
    // noticing edits, which is what it did before this existed.
    var watcher = watchmod.Watcher.init();
    if (watcher) |*w| armWatches(w, args.config_path, &cfg);
    defer if (watcher) |*w| w.deinit();

    const gi = gl.info();
    const caps = Font.capabilities();
    std.debug.print(
        \\myterm
        \\  GL_RENDERER : {s}
        \\  cell        : {d}x{d} px  (baseline {d})
        \\  grid        : {d}x{d} cells in {d}x{d} px
        \\  fcft        : grapheme={} text-run={} svg={}
        \\  seat        : keyboard={} pointer={}
        \\  selections  : clipboard={} primary={} cursor-shape={}
        \\  child       : {s} (pid {d})
        \\
    , .{
        gi.renderer,
        font.cell_w,
        font.cell_h,
        font.baseline,
        dims.cols,
        dims.rows,
        win.width,
        win.height,
        caps.grapheme,
        caps.text_run,
        caps.svg,
        win.keyboard.wl_kbd != null,
        win.pointer.wl_pointer != null,
        win.clipboard.device != null,
        win.clipboard.primary_device != null,
        win.pointer.shape_device != null,
        std.mem.span(argv[0].?),
        first.pty.child,
    });

    // ── event loop ─────────────────────────────────────────────────────────
    // One thread, polling Wayland and the PTY together. PLAN.md §2 sketches a
    // per-pane parse thread; that only starts paying off once there are multiple
    // panes (phase 5), and foot demonstrates a single-threaded loop is entirely
    // competitive. Revisit with measurements rather than on principle.
    var read_buf: [read_chunk]u8 = undefined;
    // Wayland, inotify, then one per tab. Every tab is polled, not just the visible
    // one: a hidden tab that stops draining its PTY blocks its child the moment the
    // pipe fills, so a build running in another tab would silently stall.
    var fds: [2 + max_tabs]std.posix.pollfd = undefined;
    var sync_started_ms: i64 = 0;

    while (!win.closed) {
        // Synchronized output (DECSET 2026): while an application is mid-update we
        // hold off presenting, so its screen appears atomically instead of torn.
        // The deadline is a safety valve — an app that sets the mode and then dies
        // must not freeze the terminal forever.
        const now_ms = monotonicMs();
        const screen = app.screen;
        if (screen.sync_output) {
            if (sync_started_ms == 0) sync_started_ms = now_ms;
        } else {
            sync_started_ms = 0;
        }
        const sync_elapsed = now_ms - sync_started_ms;
        const sync_holding = screen.sync_output and sync_elapsed < sync_timeout_ms;

        // Held-key repeat, driven off the same deadline machinery as sync output
        // rather than a separate timerfd.
        if (win.keyboard.repeat_at != 0 and now_ms >= win.keyboard.repeat_at) {
            win.keyboard.fireRepeat(now_ms);
        }

        if (app.needs_render and !app.frame_pending and !sync_holding) {
            render(&app, &renderer, &cache, &font, pad);
        }

        // The prepare_read / read_events dance is required: checking the fd for
        // readability without it races against events already queued in memory,
        // which manifests as a hang that only reproduces under load.
        while (c.wl_display_prepare_read(win.display) != 0) {
            _ = c.wl_display_dispatch_pending(win.display);
        }
        _ = c.wl_display_flush(win.display);

        fds[0] = .{ .fd = win.fd(), .events = std.posix.POLL.IN, .revents = 0 };
        // A negative fd is ignored by poll, which is how "no inotify" costs nothing.
        fds[1] = .{
            .fd = if (watcher) |*w| w.fd else -1,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        for (app.tabs[0..app.tab_count], 0..) |t, i| {
            fds[2 + i] = .{
                .fd = t.pty.master,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
        }
        const n_fds = 2 + app.tab_count;

        // Block indefinitely unless a deadline needs us back sooner. Two can be
        // outstanding — the synchronized-output safety valve and the next key
        // repeat — so wake for whichever comes first.
        var timeout: i32 = -1;
        if (sync_holding) {
            timeout = @intCast(@max(1, sync_timeout_ms - sync_elapsed));
        }
        if (win.keyboard.repeat_at != 0) {
            const due: i32 = @intCast(@max(1, win.keyboard.repeat_at - now_ms));
            timeout = if (timeout < 0) due else @min(timeout, due);
        }
        if (watcher) |*w| {
            if (w.timeout(now_ms)) |due| {
                timeout = if (timeout < 0) due else @min(timeout, due);
            }
        }

        _ = std.posix.poll(fds[0..n_fds], timeout) catch |err| {
            c.wl_display_cancel_read(win.display);
            std.debug.print("myterm: poll failed: {s}\n", .{@errorName(err)});
            break;
        };

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            if (c.wl_display_read_events(win.display) < 0) {
                reportWaylandError(&win);
                break;
            }
        } else {
            c.wl_display_cancel_read(win.display);
            // A hangup or error without POLLIN means the compositor is gone. Without
            // this the loop spins at 100% of a core: poll returns immediately with
            // the same revents, forever.
            const dead = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
            if (fds[0].revents & dead != 0) {
                std.debug.print("myterm: compositor connection closed\n", .{});
                break;
            }
        }
        if (c.wl_display_dispatch_pending(win.display) < 0) {
            reportWaylandError(&win);
            break;
        }

        // Drain every tab, with the budget applied per tab so one flooding session
        // cannot starve the others — or the input handling.
        for (app.tabs[0..app.tab_count], 0..) |t, i| {
            if (fds[2 + i].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) == 0) continue;
            var drained: usize = 0;
            while (drained < drain_budget) {
                const n = t.pty.read(&read_buf);
                if (n == 0) break;
                t.parser.feed(read_buf[0..n]);
                drained += n;
            }
        }

        if (watcher) |*w| {
            if (fds[1].revents & std.posix.POLL.IN != 0) _ = w.drain(monotonicMs());
            if (w.ready(monotonicMs())) {
                reloadConfig(.{
                    .gpa = gpa,
                    .cfg = &cfg,
                    .config_path = args.config_path,
                    .font = &font,
                    .cache = &cache,
                    .pad = &pad,
                    .app = &app,
                    .win = &win,
                    .watcher = w,
                });
            }
        }

        if (win.resized) {
            // Reflow renumbers lines, so every hint span would point at unrelated
            // text. The same reason `Screen.resize` drops the hover span.
            app.hintsExit();
            gl.resize(win.width, win.height);
            dims = gridSize(win.width, win.height, &font, pad);
            for (app.tabs[0..app.tab_count]) |t| {
                // Every tab, not only the visible one: a background tab left at the old
                // width writes at the wrong size and reflows wrongly when shown.
                try t.screen.resize(dims.cols, dims.rows);
                t.pty.resize(dims.cols, dims.rows);
            }
            win.resized = false;
        }

        if (screen.dirty) {
            screen.dirty = false;
            app.needs_render = true;
        }

        // Collect any URL handler that has finished. Cheap: it only touches slots
        // that hold a live pid.
        app.reaper.poll();

        // A tab whose child is gone goes with it; the window closes with the last one.
        // Iterated backwards so removing one does not shift an index we have yet to
        // check.
        var ti = app.tab_count;
        var all_closed = false;
        while (ti > 0) {
            ti -= 1;
            const t = app.tabs[ti];
            if (!(t.pty.hung_up or t.pty.childExited())) continue;
            if (!app.tabClosed(ti)) {
                all_closed = true;
                break;
            }
        }
        if (all_closed) break;
    }
}

fn render(
    app: *App,
    renderer: *Renderer,
    cache: *GlyphCache,
    font: *const Font,
    pad: Padding,
) void {
    const win = app.win;

    renderer.draw(
        app.screen,
        app.hints[0..app.hint_n],
        app.buildBar(),
        cache,
        font,
        win.width,
        win.height,
        pad,
    );
    app.needs_render = false;

    if (cache.exhausted) {
        // Not fatal: affected glyphs render blank. Phase 7 adds LRU eviction.
        std.debug.print("myterm: glyph atlas full\n", .{});
        cache.exhausted = false;
    }

    // Request the next frame callback *before* swapping: eglSwapBuffers performs
    // the wl_surface.commit, and the callback must ride on that same commit.
    if (c.wl_surface_frame(win.surface)) |cb| {
        _ = c.wl_callback_add_listener(cb, &frame_listener, app);
        app.frame_pending = true;
    }
    app.gl.swap();
}

const frame_listener: c.struct_wl_callback_listener = .{ .done = handleFrame };

fn handleFrame(
    data: ?*anyopaque,
    callback: ?*c.struct_wl_callback,
    _: u32,
) callconv(.c) void {
    c.wl_callback_destroy(callback);
    const app: *App = @ptrCast(@alignCast(data.?));
    app.frame_pending = false;
}

/// Ignore SIGPIPE, whose default action is to terminate the process *silently* —
/// no panic, no message, no exit code to inspect.
///
/// A terminal writes to file descriptors owned by other processes all the time and
/// cannot assume any of them stay open:
///
///   - Serving a clipboard or PRIMARY request means writing into a pipe the asking
///     client created. If it closes the read end early — because it got what it
///     wanted, or died — our write returns EPIPE.
///   - Writing to the PTY master races with the child exiting.
///
/// With SIGPIPE ignored, both surface as an ordinary error the caller can handle.
fn ignoreSigpipe() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &act, null);
}

/// Explain why the Wayland connection died.
///
/// Without this a protocol error is indistinguishable from a clean exit: the loop
/// just stops and the window vanishes with nothing on stderr. libwayland does not
/// print these itself, it only records them for the client to ask about.
fn reportWaylandError(win: *Window) void {
    const err = c.wl_display_get_error(win.display);
    if (err == 0) return;

    var iface: ?*const c.struct_wl_interface = null;
    var id: u32 = 0;
    const code = c.wl_display_get_protocol_error(win.display, &iface, &id);

    if (iface) |i| {
        std.debug.print(
            "myterm: wayland protocol error: {s} raised code {d} on object {d}\n",
            .{ std.mem.span(i.*.name), code, id },
        );
    } else {
        std.debug.print("myterm: wayland connection lost (errno {d})\n", .{err});
    }
}

/// Milliseconds on a monotonic clock.
///
/// Monotonic rather than wall time on purpose: an NTP step backwards would make a
/// deadline computed from wall time never expire. `std.time.milliTimestamp` was
/// removed in Zig 0.16, so this goes straight to the syscall (vDSO-accelerated).
fn monotonicMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

const Dims = struct { cols: u32, rows: u32 };

/// Rows the tab bar takes out of the grid.
///
/// Always reserved, even with one tab, so opening a second one does not resize the grid
/// and reflow everything you were looking at. It also matches the existing kitty config,
/// which shows the bar from the first tab.
const tab_bar_rows: u32 = 1;

fn gridSize(width: u32, height: u32, font: *const Font, pad: Padding) Dims {
    // Padding is left/top only, matching the user's existing kitty and wezterm
    // configs (`window_padding_width 0 0 0 4`).
    const usable_w = if (width > pad.x) width - pad.x else font.cell_w;
    const usable_h = if (height > pad.y) height - pad.y else font.cell_h;
    const rows = usable_h / font.cell_h;
    return .{
        .cols = @max(usable_w / font.cell_w, 1),
        .rows = @max(rows -| tab_bar_rows, 1),
    };
}

/// Command line: `-c path` picks a config, `-e cmd args...` a child command.
const Args = struct {
    config_path: []const u8 = "",
    /// Directory to start the child in; empty means inherit ours.
    cwd: []const u8 = "",
    /// Everything from `-e` onwards, or the whole argv when absent.
    child: []const [*:0]const u8,
};

fn parseArgs(argv: []const [*:0]const u8) Args {
    var out = Args{ .child = argv };
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "-e")) break;
        if ((std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) and
            i + 1 < argv.len)
        {
            out.config_path = std.mem.span(argv[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--cwd") and i + 1 < argv.len) {
            out.cwd = std.mem.span(argv[i + 1]);
            i += 1;
        }
    }
    return out;
}

/// Where the config lives when `-c` did not say.
fn defaultConfigPath(out: []u8) []const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| {
        const dir = std.mem.span(xdg);
        if (dir.len > 0) {
            return std.fmt.bufPrint(out, "{s}/myterm/myterm.conf", .{dir}) catch
                "~/.config/myterm/myterm.conf";
        }
    }
    return "~/.config/myterm/myterm.conf";
}

/// Load the config, then the theme.
///
/// The theme comes from the flavour file *only* when the config did not name one.
/// Otherwise an explicit `theme` in the config would be silently overridden by a file
/// the user may not even remember exists.
fn loadConfig(
    gpa: std.mem.Allocator,
    path_arg: []const u8,
    diags: *cfgmod.Diagnostics,
) cfgmod.Config {
    var buf: [1024]u8 = undefined;
    const path = if (path_arg.len > 0) path_arg else defaultConfigPath(&buf);
    var cfg = cfgmod.load(gpa, path, diags);
    if (cfg.theme_path.len == 0) cfgmod.reloadTheme(gpa, &cfg, diags);
    return cfg;
}

fn loadFont(cfg: *const cfgmod.Config) !Font {
    var name: [512]u8 = undefined;
    const family = cfg.font_family.slice();
    @memcpy(name[0..family.len], family);
    name[family.len] = 0;

    var attrs: [64]u8 = undefined;
    // dpi=96 with the compositor's scale applied separately; per-output scaling is
    // phase 7's problem.
    const spec = std.fmt.bufPrintZ(&attrs, "size={d:.1}:dpi=96", .{cfg.font_size}) catch
        "size=12.0:dpi=96";
    return Font.init(@ptrCast(&name), spec);
}

/// Push the settings that live on the Screen rather than in the Config.
fn applyConfig(screen: *Screen, cfg: *const cfgmod.Config) void {
    screen.theme = cfg.theme;
    screen.selection.word_separators = cfg.word_separators.slice();
    screen.modes.alternate_scroll = cfg.alternate_scroll;
    screen.dirty = true;
}

/// Everything a reload may have to touch.
const Live = struct {
    gpa: std.mem.Allocator,
    cfg: *cfgmod.Config,
    config_path: []const u8,
    font: *Font,
    cache: *GlyphCache,
    pad: *Padding,
    app: *App,
    win: *Window,
    watcher: *watchmod.Watcher,
};

/// Re-read the config and apply what can be applied without restarting.
fn reloadConfig(l: Live) void {
    var diags = cfgmod.Diagnostics{};
    const fresh = loadConfig(l.gpa, l.config_path, &diags);
    diags.report();

    const font_changed = !l.cfg.font_family.eql(fresh.font_family.slice()) or
        l.cfg.font_size != fresh.font_size;
    const geom_changed = l.cfg.padding_x != fresh.padding_x or
        l.cfg.padding_y != fresh.padding_y;
    // scrollback_lines is missing on purpose: changing it means reallocating the ring
    // and deciding what to do with the history that no longer fits. It applies at the
    // next start, which is what every other terminal does too.
    if (l.cfg.scrollback_lines != fresh.scrollback_lines) {
        std.debug.print("myterm: scrollback_lines applies at the next start\n", .{});
    }

    if (l.app.debug) {
        std.debug.print("reload: theme '{s}', font '{s}' {d}\n", .{
            fresh.theme_path.slice(),
            fresh.font_family.slice(),
            fresh.font_size,
        });
    }

    l.cfg.* = fresh;
    for (l.app.tabs[0..l.app.tab_count]) |t| applyConfig(&t.screen, l.cfg);

    if (font_changed) {
        // Load the new font *before* dropping the old one: a bad font_family in the
        // config must not leave the terminal with no font at all.
        if (loadFont(l.cfg)) |next| {
            l.font.deinit();
            l.font.* = next;
            // The atlas holds glyphs rasterized by the previous font, so it cannot be
            // reused — every cached entry would draw the old size.
            l.cache.deinit();
            l.cache.* = GlyphCache.init(l.gpa, l.font, atlas_size);
        } else |err| {
            std.debug.print("myterm: keeping the old font, '{s}' failed ({s})\n", .{
                l.cfg.font_family.slice(),
                @errorName(err),
            });
        }
    }

    if (font_changed or geom_changed) {
        l.pad.* = .{ .x = l.cfg.padding_x, .y = l.cfg.padding_y };
        l.app.pad = l.pad.*;
        const dims = gridSize(l.win.width, l.win.height, l.font, l.pad.*);
        for (l.app.tabs[0..l.app.tab_count]) |t| {
            t.screen.resize(dims.cols, dims.rows) catch |err| {
                std.debug.print("myterm: resize after reload failed: {s}\n", .{
                    @errorName(err),
                });
            };
            t.pty.resize(dims.cols, dims.rows);
        }
        // Hint spans and the hover span are in absolute line coordinates, which the
        // reflow just renumbered.
        l.app.hintsExit();
    }

    // A new `theme` value points at a different file, so the watch list changes with it.
    l.watcher.reset();
    armWatches(l.watcher, l.config_path, l.cfg);
    l.app.needs_render = true;
}

fn armWatches(
    w: *watchmod.Watcher,
    config_path_arg: []const u8,
    cfg: *const cfgmod.Config,
) void {
    var buf: [1024]u8 = undefined;
    const path = if (config_path_arg.len > 0)
        config_path_arg
    else
        defaultConfigPath(&buf);

    var expanded: [1024]u8 = undefined;
    if (cfgmod.expandTilde(path, &expanded)) |p| w.add(p);

    var flavour: [1024]u8 = undefined;
    if (cfgmod.expandTilde(cfg.theme_flavour_file.slice(), &flavour)) |p| w.add(p);

    // The resolved theme file, so editing the colours directly also applies. Already
    // absolute — `applyThemeRef` expanded it.
    if (cfg.theme_path.len > 0) w.add(cfg.theme_path.slice());
}

/// Build the child's argv: `-e cmd args...` runs a specific command, otherwise
/// $SHELL and then zsh as a fallback.
///
/// The incoming pointers are the process's own argv and environ, which live for
/// the process lifetime, so only the array itself needs allocating — the strings
/// can be referenced directly and stay valid across the fork.
fn buildArgv(
    gpa: std.mem.Allocator,
    args: []const [*:0]const u8,
    environ: std.process.Environ,
) ![:null]?[*:0]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, std.mem.span(arg), "-e") and i + 1 < args.len) {
            const rest = args[i + 1 ..];
            const argv = try gpa.allocSentinel(?[*:0]const u8, rest.len, null);
            for (rest, 0..) |a, j| argv[j] = a;
            return argv;
        }
    }

    const shell: [*:0]const u8 = if (environ.getPosix("SHELL")) |s|
        @ptrCast(s.ptr)
    else
        "/usr/bin/zsh";

    const argv = try gpa.allocSentinel(?[*:0]const u8, 1, null);
    argv[0] = shell;
    return argv;
}
