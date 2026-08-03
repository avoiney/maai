//! Terminal semantics: cursor, pen, modes, and the parser's handler interface.
//!
//! Covers what full-screen applications need: the alternate screen, scroll
//! regions, line and character insert/delete, tab stops, saved cursor, bounded
//! replies to device queries, and character widths including double-width cells
//! and grapheme clusters (see `print` and `width.zig`).

const std = @import("std");
const cellmod = @import("cell.zig");
const gridmod = @import("grid.zig");
const mousemod = @import("mouse.zig");
const thememod = @import("theme.zig");
const urlmod = @import("url.zig");
const reclaim = @import("reclaim.zig");
const Grid = gridmod.Grid;
const width = @import("width.zig");
const sel = @import("selection.zig");
const parser = @import("../vt/parser.zig");

const Cell = cellmod.Cell;
const Style = cellmod.Style;
const Rgb = cellmod.Rgb;
const Color = thememod.Color;
const StyleTable = cellmod.StyleTable;

/// Where replies to device queries go — normally the PTY.
pub const Reply = struct {
    ctx: *anyopaque,
    write: *const fn (*anyopaque, []const u8) void,
};

pub const MouseModes = mousemod.Modes;

/// Garbage-collection pacing for one interned table.
///
/// `floor` is tracked separately from `trigger` because the trigger is re-armed
/// above whatever survived a collection; re-arming against a global constant would
/// make it un-lowerable.
///
/// `cooldown` exists because collection cannot always help. Per-cell truecolor —
/// `lolcat`, a gradient prompt, an image converted to ANSI — genuinely references
/// tens of thousands of distinct styles from live cells, so a scan frees nothing,
/// the trigger re-arms at the ceiling, and every subsequent SGR rescans the entire
/// grid. That is quadratic, and it is not theoretical: before this cooldown existed
/// the benchmark took **240 seconds** to parse 4 MiB of per-cell truecolor, versus
/// well under a second after. When a collection turns out unproductive we back off
/// hard and accept saturation, which is honest — no more than 65535 distinct styles
/// can be represented at once — rather than paying for a scan that cannot help.
/// Public because reclamation lives in reclaim.zig and the tests set the triggers.
pub const Gc = struct {
    trigger: usize,
    floor: usize = 0,
    /// Interns to let past before attempting collection again.
    cooldown: usize = 0,

    /// How many interns to skip after a collection that freed almost nothing. Large
    /// enough that the amortised scan cost disappears, small enough that space
    /// freed by scrollback churn is eventually reclaimed.
    const unproductive_cooldown: usize = 1 << 16;

    pub fn init(trigger: usize) Gc {
        return .{ .trigger = trigger, .floor = trigger };
    }

    /// True if a collection should run now, consuming one step of any cooldown.
    pub fn due(self: *Gc, live: usize) bool {
        if (self.cooldown > 0) {
            self.cooldown -= 1;
            return false;
        }
        return live >= self.trigger;
    }

    pub fn rearm(self: *Gc, before: usize, after: usize, ceiling: usize) void {
        const base = if (self.floor == 0) self.trigger else self.floor;
        self.floor = base;
        self.trigger = @min(@max(base, after * 2), ceiling);

        // Freed less than a quarter? The live set is simply this large.
        const freed = before - after;
        if (freed * 4 < before) self.cooldown = unproductive_cooldown;
    }
};

fn maskCsiUFlags(raw: u16) u5 {
    return @intCast(raw & csi_u_supported);
}

const SavedCursor = struct {
    x: u32 = 0,
    y: u32 = 0,
    pen: Style = Style.default,
    pen_id: u16 = 0,
    origin_mode: bool = false,
    autowrap: bool = true,
};

/// Modes the input encoder needs to see. Kept in one struct so `Keyboard` can hold
/// a single pointer rather than reaching into `Screen`.
pub const Modes = struct {
    /// DECCKM: cursor keys emit SS3 (`ESC O A`) instead of CSI (`ESC [ A`).
    /// nvim and less both rely on this.
    app_cursor: bool = false,
    /// DECSET 2004. Consumed by paste handling in phase 3.
    bracketed_paste: bool = false,
    /// DECSET 1004.
    focus_events: bool = false,
    /// DECSET 1007. On the alternate screen, with no mouse tracking active, the
    /// wheel sends cursor keys instead of moving a scrollback that does not exist.
    /// Defaults on, as in xterm: without it the wheel does nothing at all in `less`
    /// or `man`, which is the single most common wheel use in a terminal.
    alternate_scroll: bool = true,
    /// CSI u keyboard protocol flags currently in effect. Zero means the legacy
    /// encoding, which is the default and must stay byte-identical to what it was
    /// before this protocol existed.
    csi_u_flags: u5 = 0,
};

/// The CSI u keyboard protocol: what we implement.
///
/// **Only flag 1, "disambiguate escape codes".** That is the flag that carries the
/// value: it makes `Esc` unambiguous, separates `Ctrl+I` from `Tab` and `Ctrl+M` from
/// `Enter`, and gives combinations legacy cannot express at all — `Shift+Enter`,
/// `Ctrl+Enter` — an encoding.
///
/// The others are deliberately not claimed:
///
///   - 2 (event types) would need a release report for *every* key, which only makes
///     sense together with flag 8.
///   - 4 (alternate keys) needs the shifted and base-layout keysym per key; useful for
///     layout-independent shortcuts, not for anything asked for here.
///   - 8 (report all keys as escape codes) takes over `Enter`, `Tab` and `Backspace`
///     wholesale.
///   - 16 (associated text) is near-vacuous without 8, since the keys we report have
///     no text.
///
/// Masking unsupported bits off is not a shortcut, it is the protocol working: an
/// application queries with `CSI ? u`, is told exactly which flags took effect, and
/// falls back for the rest. Claiming a flag we do not implement is what would break
/// applications.
pub const csi_u_supported: u5 = 1;

/// Depth of the flags stack. Applications push on entry and pop on exit; a bounded
/// stack means a program that pushes in a loop cannot grow our memory.
pub const csi_u_stack_max = 16;

pub const Screen = struct {
    gpa: std.mem.Allocator,

    /// The active grid. On the alternate screen this is the alt grid and `other`
    /// holds the primary (with its scrollback).
    grid: Grid,
    /// The inactive grid. Swapped with `grid` on 1049. Held by value, never by
    /// pointer, so that `Screen` stays movable.
    other: Grid,
    in_alt: bool = false,

    styles: StyleTable = .{},
    /// Multi-codepoint clusters (base plus combining marks or variation selectors).
    graphemes: cellmod.GraphemeTable = .{},
    /// OSC 8 hyperlink targets. Cells reach them through their style's
    /// `hyperlink` id.
    links: cellmod.LinkTable = .{},
    /// Colours the styles resolve against. Owned per screen because OSC 4/10/11 are
    /// per-terminal state: one pane redefining colour 4 must not repaint another.
    theme: thememod.Theme = .{},
    /// Mouse/keyboard text selection. Lives here so the renderer can highlight it
    /// from the same place it reads cells.
    selection: sel.Selection = .{},
    /// The URL under the pointer while the link modifier is held, for the renderer
    /// to underline. Set by pointer handling, not by the parser — it lives beside
    /// `selection` for the same reason: this is where the renderer already looks.
    hover: ?urlmod.Span = null,

    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    cursor_visible: bool = true,

    pen: Style = Style.default,
    pen_id: u16 = 0,

    /// Scroll region, inclusive and 0-based. Full screen unless DECSTBM narrows it.
    margin_top: u32 = 0,
    margin_bottom: u32 = 0,

    autowrap: bool = true,
    /// DECAWM's deferred wrap: writing the last column parks the cursor there and
    /// only wraps on the *next* printable character, so a line that exactly fills
    /// the width does not scroll early.
    wrap_pending: bool = false,
    /// DECOM: cursor addressing is relative to the scroll region.
    origin_mode: bool = false,
    /// IRM: printing shifts the rest of the line right instead of overwriting.
    insert_mode: bool = false,

    modes: Modes = .{},
    /// What to report to the application, and how. Read by the pointer handling in
    /// `main.zig`, which owns the local-versus-application decision.
    mouse: MouseModes = .{},
    /// DECSET 2026. While set, the renderer holds off presenting so an app's
    /// multi-write screen update appears atomically instead of tearing.
    sync_output: bool = false,

    saved: SavedCursor = .{},
    other_saved: SavedCursor = .{},

    /// Saved keyboard flags, and the same for the inactive screen.
    ///
    /// Per screen buffer, which is a safety property rather than tidiness: a
    /// full-screen application that enables the protocol and then dies
    /// without popping would otherwise leave the *shell* with a keyboard encoding it
    /// does not understand. Swapping the stack on 1049 means leaving the alternate
    /// screen restores whatever the shell had.
    csi_u_stack: [csi_u_stack_max]u5 = @splat(0),
    csi_u_depth: usize = 0,
    other_csi_u_flags: u5 = 0,
    other_csi_u_stack: [csi_u_stack_max]u5 = @splat(0),
    other_csi_u_depth: usize = 0,

    /// One entry per column; true where a tab stop sits.
    tab_stops: []bool,

    /// When `collectGarbage` runs, per table.
    gc_styles: Gc = .{ .trigger = cellmod.style_gc_threshold },
    gc_graphemes: Gc = .{ .trigger = cellmod.grapheme_gc_threshold },
    gc_links: Gc = .{ .trigger = cellmod.link_gc_threshold },

    /// Last printed codepoint, for REP.
    last_printed: u21 = ' ',

    reply: ?Reply = null,
    dirty: bool = true,

    title_buf: [256]u8 = undefined,
    title_len: usize = 0,

    /// Working directory as announced by OSC 7, empty when never announced.
    ///
    /// Advisory only: most shells never emit it, so anything that needs the directory
    /// reads `/proc` instead and treats this as a refinement.
    cwd_buf: [1024]u8 = undefined,
    cwd_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, cols: u32, rows: u32) !Screen {
        return initScrollback(gpa, cols, rows, gridmod.default_scrollback);
    }

    pub fn initScrollback(
        gpa: std.mem.Allocator,
        cols: u32,
        rows: u32,
        scrollback: u32,
    ) !Screen {
        var primary = try Grid.init(gpa, cols, rows, scrollback);
        errdefer primary.deinit();
        // The alternate screen has no scrollback: a full-screen application's
        // redraws are not history anyone wants to scroll back through.
        var alt = try Grid.init(gpa, cols, rows, 0);
        errdefer alt.deinit();

        const tabs = try gpa.alloc(bool, cols);
        errdefer gpa.free(tabs);

        var s = Screen{
            .gpa = gpa,
            .grid = primary,
            .other = alt,
            .margin_bottom = rows - 1,
            .tab_stops = tabs,
        };
        try s.styles.init(gpa);
        try s.links.init(gpa);
        s.resetTabs();
        return s;
    }

    pub fn deinit(self: *Screen) void {
        self.grid.deinit();
        self.other.deinit();
        self.gpa.free(self.tab_stops);
        self.styles.deinit(self.gpa);
        self.graphemes.deinit(self.gpa);
        self.links.deinit(self.gpa);
    }

    pub fn resize(self: *Screen, cols: u32, rows: u32) !void {
        // Captured before the grids change: whether the region spanned the whole
        // screen has to be judged against the *old* height, or a full-screen region
        // stays pinned to the old row count and full-screen apps scroll wrongly.
        const was_full_height = self.margin_top == 0 and
            self.margin_bottom + 1 >= self.grid.rows;

        // The primary grid reflows so scrollback survives; the alternate screen
        // does not, because its rows are independent screen lines rather than
        // wrapped text, and its owner redraws on SIGWINCH.
        if (self.in_alt) {
            var saved = gridmod.Cursor{ .x = self.other_saved.x, .y = self.other_saved.y };
            try self.other.resizeReflow(cols, rows, &saved);
            self.other_saved.x = saved.x;
            self.other_saved.y = saved.y;
            try self.grid.resizePreserve(cols, rows, self.pen_id);
            self.cursor_x = @min(self.cursor_x, cols - 1);
            self.cursor_y = @min(self.cursor_y, rows - 1);
        } else {
            var cur = gridmod.Cursor{ .x = self.cursor_x, .y = self.cursor_y };
            try self.grid.resizeReflow(cols, rows, &cur);
            self.cursor_x = cur.x;
            self.cursor_y = cur.y;
            try self.other.resizePreserve(cols, rows, self.pen_id);
        }

        if (self.tab_stops.len != cols) {
            self.tab_stops = try self.gpa.realloc(self.tab_stops, cols);
            self.resetTabs();
        }

        // Reflow renumbers lines, so selection coordinates no longer refer to the
        // text the user picked. Dropping it beats highlighting the wrong region.
        self.selection.clear();
        // Reflow renumbers lines, so a span held in absolute coordinates would
        // highlight unrelated text.
        self.hover = null;

        // A region that spanned the whole screen should keep spanning it.
        if (was_full_height) {
            self.margin_bottom = rows - 1;
        } else {
            self.margin_bottom = @min(self.margin_bottom, rows - 1);
            self.margin_top = @min(self.margin_top, self.margin_bottom);
        }

        self.wrap_pending = false;
        self.dirty = true;
    }

    pub fn title(self: *const Screen) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn respond(self: *Screen, bytes: []const u8) void {
        if (self.reply) |r| r.write(r.ctx, bytes);
    }

    fn resetTabs(self: *Screen) void {
        for (self.tab_stops, 0..) |*t, i| t.* = (i % 8 == 0 and i != 0);
    }

    // ── parser handler interface ────────────────────────────────────────────

    pub fn print(self: *Screen, cp: u21) void {
        const w = width.charWidth(cp);
        // Zero-width codepoints — combining marks, variation selectors — belong to
        // the character before them and must not consume a column of their own.
        if (w == 0) {
            self.combine(cp);
            return;
        }

        if (self.wrap_pending) {
            self.wrap_pending = false;
            // Record that this row continues onto the next. This single bit is what
            // lets resize tell a soft wrap from a real newline, and so is the thing
            // reflow depends on entirely.
            self.grid.rowMeta(self.cursor_y).wrapped = true;
            self.cursor_x = 0;
            self.lineFeed();
        }

        // A double-width glyph may not straddle the right edge: it wraps whole,
        // leaving the final column blank.
        if (w == 2 and self.cursor_x + 2 > self.grid.cols) {
            if (!self.autowrap) return;
            // Mark the column being vacated, for the same reason reflow does: it is
            // padding, not a space, and a later reflow must not promote it to content.
            var px = self.cursor_x;
            while (px < self.grid.cols) : (px += 1) {
                self.grid.at(px, self.cursor_y).* = .{ .content = ' ', .wide = 3 };
            }
            self.grid.markWide(self.cursor_y);
            self.grid.rowMeta(self.cursor_y).wrapped = true;
            self.cursor_x = 0;
            self.lineFeed();
        }

        if (self.insert_mode) self.insertChars(w);

        self.writeCell(self.cursor_x, cp, w);
        self.last_printed = cp;

        const next = self.cursor_x + w;
        if (next >= self.grid.cols) {
            // Park on the lead cell; wrap_pending defers the wrap to the next
            // printable character.
            if (self.autowrap) self.wrap_pending = true;
        } else {
            self.cursor_x = next;
        }
        self.dirty = true;
    }

    /// Write one character at `x`, laying down a spacer cell when it is wide.
    fn writeCell(self: *Screen, x: u32, cp: u21, w: u8) void {
        self.breakPairAt(x);
        self.grid.at(x, self.cursor_y).* = .{
            .content = cp,
            .style = self.pen_id,
            .wide = if (w == 2) 1 else 0,
            .dirty = true,
        };
        if (w == 2 and x + 1 < self.grid.cols) {
            self.breakPairAt(x + 1);
            self.grid.markWide(self.cursor_y);
            self.grid.at(x + 1, self.cursor_y).* = .{
                .content = Cell.empty,
                .style = self.pen_id,
                .wide = 2,
                .dirty = true,
            };
        }
    }

    /// Overwriting half of a double-width pair must clear the other half, or an
    /// orphaned lead or spacer is left behind and the row renders wrong from there
    /// on.
    fn breakPairAt(self: *Screen, x: u32) void {
        const cell = self.grid.at(x, self.cursor_y);
        switch (cell.wide) {
            1 => if (x + 1 < self.grid.cols) {
                const spacer = self.grid.at(x + 1, self.cursor_y);
                if (spacer.wide == 2) spacer.* = gridmod.blankCell(spacer.style);
            },
            2 => if (x > 0) {
                const lead = self.grid.at(x - 1, self.cursor_y);
                if (lead.wide == 1) lead.* = gridmod.blankCell(lead.style);
            },
            else => {},
        }
    }

    /// Attach a zero-width codepoint to the character it modifies.
    fn combine(self: *Screen, cp: u21) void {
        // With a wrap pending the cursor still sits on the last character written;
        // otherwise it has already moved past it.
        var x: u32 = if (self.wrap_pending)
            self.cursor_x
        else if (self.cursor_x > 0)
            self.cursor_x - 1
        else
            return;

        // Step from a spacer back onto its lead.
        if (self.grid.at(x, self.cursor_y).wide == 2 and x > 0) x -= 1;
        const cell = self.grid.at(x, self.cursor_y);
        if (cell.content == Cell.empty and !cell.grapheme) return;

        // Emoji presentation widens a one-column base to two (see width.zig).
        if (width.widensToEmoji(cp, if (cell.wide == 0) 1 else 2) and
            x + 1 < self.grid.cols)
        {
            self.breakPairAt(x + 1);
            cell.wide = 1;
            self.grid.markWide(self.cursor_y);
            self.grid.at(x + 1, self.cursor_y).* = .{
                .content = Cell.empty,
                .style = cell.style,
                .wide = 2,
                .dirty = true,
            };
            if (!self.wrap_pending) {
                if (x + 2 >= self.grid.cols) {
                    if (self.autowrap) self.wrap_pending = true;
                    self.cursor_x = x;
                } else {
                    self.cursor_x = x + 2;
                }
            }
        }

        self.extendCluster(cell, cp);
        self.dirty = true;
    }

    fn extendCluster(self: *Screen, cell: *Cell, cp: u21) void {
        // Cluster growth is driven by printing, not by SGR, so the pacing check has
        // to live here as well — `commitPen` alone would never see it, and a `cat`
        // of decomposed text would grow the table without bound.
        //
        // Safe to collect at this point: collection rewrites cell *fields* but never
        // moves cells, so `cell` stays valid, and the old cluster it still refers to
        // is marked live and survives with a remapped index.
        if (self.gc_graphemes.due(self.graphemes.spans.items.len)) self.collectGarbage();

        var buf: [cellmod.GraphemeTable.max_len]u21 = undefined;
        var n: usize = 0;

        if (cell.grapheme) {
            const existing = self.graphemes.get(cell.content);
            n = @min(existing.len, buf.len);
            @memcpy(buf[0..n], existing[0..n]);
        } else {
            buf[0] = @intCast(cell.content);
            n = 1;
        }
        // Cluster at capacity: drop the mark rather than grow without bound.
        if (n >= buf.len) return;

        buf[n] = cp;
        n += 1;

        const idx = self.graphemes.add(self.gpa, buf[0..n]) catch return;
        cell.content = idx;
        cell.grapheme = true;
        cell.dirty = true;
    }

    pub fn execute(self: *Screen, b: u8) void {
        switch (b) {
            0x07 => {}, // BEL: no audio bell, by design.
            0x08 => { // BS
                self.wrap_pending = false;
                if (self.cursor_x > 0) self.cursor_x -= 1;
                self.dirty = true;
            },
            0x09 => self.tab(1),
            0x0a, 0x0b, 0x0c => { // LF, VT, FF
                self.wrap_pending = false;
                self.lineFeed();
            },
            0x0d => { // CR
                self.wrap_pending = false;
                self.cursor_x = 0;
                self.dirty = true;
            },
            else => {},
        }
    }

    pub fn escDispatch(self: *Screen, final: u8, intermediates: []const u8) void {
        if (intermediates.len > 0) {
            // DECALN: fill the screen with 'E'. vttest leads with this.
            if (intermediates[0] == '#' and final == '8') self.alignmentTest();
            return;
        }
        switch (final) {
            'D' => self.lineFeed(), // IND
            'E' => { // NEL
                self.cursor_x = 0;
                self.lineFeed();
            },
            'M' => self.reverseIndex(), // RI
            '7' => self.saveCursor(),
            '8' => self.restoreCursor(),
            'H' => { // HTS
                if (self.cursor_x < self.tab_stops.len) self.tab_stops[self.cursor_x] = true;
            },
            'c' => self.reset(), // RIS
            else => {}, // keypad modes and charset selection are no-ops for now
        }
        self.dirty = true;
    }

    pub fn csiDispatch(
        self: *Screen,
        final: u8,
        private: u8,
        intermediates: []const u8,
        params: *const parser.Params,
    ) void {
        // DECSCUSR (`CSI Ps SP q`) and friends carry intermediates; we render a
        // block cursor regardless, so drop them rather than misreading the final.
        if (intermediates.len > 0) return;

        // A private marker puts the sequence in a different namespace, where the
        // same final byte means something else entirely. Falling through to the
        // standard handlers is not a harmless no-op, it actively corrupts state:
        //
        //   CSI > 4 ; 2 m   xterm modifyOtherKeys, was read as SGR 4 (underline)
        //                   plus SGR 2 (dim), so everything after it rendered
        //                   underlined -- the reported Claude Code symptom
        //   CSI > 1 u       CSI u keyboard protocol push, was read as CSI u
        //                   (restore cursor), moving the cursor at random
        if (private != 0) {
            switch (final) {
                'h' => if (private == '?') self.decPrivateMode(params, true),
                'l' => if (private == '?') self.decPrivateMode(params, false),
                'c' => if (private == '>') self.deviceAttributes('>'),
                'u' => self.csiUKeyboard(private, params),
                // Recognised and deliberately inert: DECDSR (`CSI ? Ps n`),
                // XTMODKEYS (`CSI > Ps m`) and XTVERSION (`CSI > Ps q`). Legacy
                // modifyOtherKeys is not implemented; applications that ask for it
                // and get no reply stay on their legacy encodings, which works.
                else => {},
            }
            self.dirty = true;
            return;
        }

        switch (final) {
            'm' => self.sgr(params),
            '@' => self.insertChars(params.get(0, 1)),
            'A' => self.moveCursor(0, -@as(i64, params.get(0, 1))),
            'B' => self.moveCursor(0, params.get(0, 1)),
            'C' => self.moveCursor(params.get(0, 1), 0),
            'D' => self.moveCursor(-@as(i64, params.get(0, 1)), 0),
            'E' => { // CNL
                self.cursor_x = 0;
                self.moveCursor(0, params.get(0, 1));
            },
            'F' => { // CPL
                self.cursor_x = 0;
                self.moveCursor(0, -@as(i64, params.get(0, 1)));
            },
            'G', '`' => self.setColumn(params.get(0, 1)), // CHA, HPA
            'a' => self.moveCursor(params.get(0, 1), 0), // HPR
            'H', 'f' => self.setPosition(params.get(0, 1), params.get(1, 1)),
            'I' => self.tab(params.get(0, 1)), // CHT
            'J' => self.eraseInDisplay(params.get(0, 0)),
            'K' => self.eraseInLine(params.get(0, 0)),
            'L' => self.insertLines(params.get(0, 1)),
            'M' => self.deleteLines(params.get(0, 1)),
            'P' => self.deleteChars(params.get(0, 1)),
            'S' => self.scrollUpRegion(params.get(0, 1)),
            'T' => self.scrollDownRegion(params.get(0, 1)),
            'X' => self.eraseChars(params.get(0, 1)),
            'Z' => self.backTab(params.get(0, 1)), // CBT
            'b' => self.repeatLast(params.get(0, 1)), // REP
            'd' => self.setRow(params.get(0, 1)), // VPA
            'e' => self.moveCursor(0, params.get(0, 1)), // VPR
            'c' => self.deviceAttributes(0), // DA1
            'g' => self.clearTabs(params.get(0, 0)), // TBC
            'h', 'l' => self.ansiMode(params, final == 'h'),
            'n' => self.deviceStatus(params),
            'r' => self.setScrollRegion(params),
            's' => self.saveCursor(),
            'u' => self.restoreCursor(),
            // 't' is xterm window manipulation. Deliberately unimplemented: several
            // of its subcommands *report* window state, and a terminal that echoes
            // state back into the input stream is an exfiltration primitive
            // (PLAN.md §7).
            else => {},
        }
        self.dirty = true;
    }

    pub fn oscDispatch(self: *Screen, data: []const u8) void {
        // OSC 0 (icon + title) and OSC 2 (title).
        //
        // There is deliberately no title *query* support, and never will be: output
        // can set the title, and a terminal that reports it back lets a compromised
        // remote host echo arbitrary bytes onto our input stream (PLAN.md §7).
        // The separator is optional: `OSC 104 ST` (reset the whole palette) and
        // `OSC 110 ST` carry no argument at all, and requiring one silently dropped
        // every reset sequence.
        const semi = std.mem.indexOfScalar(u8, data, ';');
        const code = if (semi) |i| data[0..i] else data;
        const text = if (semi) |i| data[i + 1 ..] else "";

        if (std.mem.eql(u8, code, "0") or std.mem.eql(u8, code, "2")) {
            const n = @min(text.len, self.title_buf.len);
            @memcpy(self.title_buf[0..n], text[0..n]);
            self.title_len = n;
        } else if (std.mem.eql(u8, code, "8")) {
            self.setHyperlink(text);
        } else if (std.mem.eql(u8, code, "7")) {
            self.setCwd(text);
        } else if (std.mem.eql(u8, code, "4")) {
            self.setPaletteColors(text);
        } else if (std.mem.eql(u8, code, "104")) {
            self.resetPaletteColors(text);
        } else if (std.mem.eql(u8, code, "10")) {
            // 10 takes fg, and a second argument means bg — xterm's chained form,
            // which `tput` and some prompt themes emit.
            self.setDynamicColors(text, &.{ .fg, .bg, .cursor });
        } else if (std.mem.eql(u8, code, "11")) {
            self.setDynamicColors(text, &.{ .bg, .cursor });
        } else if (std.mem.eql(u8, code, "12")) {
            self.setDynamicColors(text, &.{.cursor});
        } else if (std.mem.eql(u8, code, "110")) {
            self.theme.fg = thememod.default_fg;
            self.dirty = true;
        } else if (std.mem.eql(u8, code, "111")) {
            self.theme.bg = thememod.default_bg;
            self.theme.cursor_text = thememod.default_bg;
            self.dirty = true;
        } else if (std.mem.eql(u8, code, "112")) {
            self.theme.cursor = thememod.default_cursor;
            self.dirty = true;
        }
        // OSC 7 (cwd) lands with phase 5's tabs, which is what needs it. OSC 52
        // *reads* stay denied by default regardless (PLAN.md §7).
    }

    /// `OSC 4 ; index ; spec [; index ; spec]* ST`
    ///
    /// A `?` in place of a spec is a *query*, and goes unanswered — deliberately, and
    /// for the same reason as the title query. It would let output read back state it
    /// had just written, which is a channel, and it buys us nothing (PLAN.md §7).
    fn setPaletteColors(self: *Screen, text: []const u8) void {
        var it = std.mem.splitScalar(u8, text, ';');
        while (it.next()) |idx_str| {
            const spec = it.next() orelse return;
            const idx = std.fmt.parseUnsigned(u16, idx_str, 10) catch continue;
            if (idx > 255) continue;
            const col = thememod.parseColor(spec) orelse continue;
            self.theme.palette[idx] = col;
            self.dirty = true;
        }
    }

    /// `OSC 104 [; index]* ST` — reset listed entries, or the whole palette when the
    /// list is empty.
    fn resetPaletteColors(self: *Screen, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) {
            self.theme.palette = thememod.default_palette;
            self.dirty = true;
            return;
        }
        var it = std.mem.splitScalar(u8, trimmed, ';');
        while (it.next()) |idx_str| {
            const idx = std.fmt.parseUnsigned(u16, idx_str, 10) catch continue;
            if (idx > 255) continue;
            self.theme.palette[idx] = thememod.default_palette[idx];
            self.dirty = true;
        }
    }

    const DynamicSlot = enum { fg, bg, cursor };

    fn setDynamicColors(self: *Screen, text: []const u8, slots: []const DynamicSlot) void {
        var it = std.mem.splitScalar(u8, text, ';');
        for (slots) |slot| {
            const spec = it.next() orelse return;
            const col = thememod.parseColor(spec) orelse continue;
            switch (slot) {
                .fg => self.theme.fg = col,
                .bg => {
                    self.theme.bg = col;
                    // Text under the cursor block sits on the cursor colour, so it
                    // tracks the background rather than staying at the old one.
                    self.theme.cursor_text = col;
                },
                .cursor => self.theme.cursor = col,
            }
            self.dirty = true;
        }
    }

    pub fn cwd(self: *const Screen) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    /// `OSC 7 ; file://host/path ST` — the shell announcing where it is.
    ///
    /// The value comes from output, so a remote host can choose it. It ends up as the
    /// starting directory of a *new terminal*, never as a command, but it is still
    /// checked: absolute, no control characters, and bounded. A relative or malformed
    /// path is ignored rather than half-applied.
    fn setCwd(self: *Screen, text: []const u8) void {
        var rest = text;
        if (std.mem.startsWith(u8, rest, "file://")) {
            rest = rest["file://".len..];
            // Strip the hostname, which is empty or the local host and either way not
            // ours to interpret. The path starts at the next slash.
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return;
            rest = rest[slash..];
        }
        if (rest.len == 0 or rest[0] != '/' or rest.len > self.cwd_buf.len) return;

        // Percent-decoding, since OSC 7 carries a URI: a directory with a space in it
        // arrives as %20.
        //
        // Decoded into scratch and copied over only on success. Writing straight into
        // `cwd_buf` and bailing out partway leaves the head of the rejected path
        // spliced onto the tail of the previous one — `/plain/path` became
        // `/badin/path`, which is neither, and is exactly the half-application this
        // validation exists to prevent.
        var scratch: [1024]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < rest.len) {
            var ch = rest[i];
            if (ch == '%' and i + 2 < rest.len) {
                const hi = std.fmt.charToDigit(rest[i + 1], 16) catch return;
                const lo = std.fmt.charToDigit(rest[i + 2], 16) catch return;
                ch = @intCast(hi * 16 + lo);
                i += 3;
            } else {
                i += 1;
            }
            if (ch <= 0x1f or ch == 0x7f) return;
            if (n == scratch.len) return;
            scratch[n] = ch;
            n += 1;
        }
        @memcpy(self.cwd_buf[0..n], scratch[0..n]);
        self.cwd_len = n;
    }

    /// `OSC 8 ; params ; URI ST` — everything printed from now on belongs to that
    /// URI, until an empty URI ends the run.
    ///
    /// The `params` field (`id=…`, used to group discontiguous runs) is parsed off
    /// and discarded: it only matters for grouping, and highlighting the contiguous
    /// run under the pointer needs no grouping.
    fn setHyperlink(self: *Screen, text: []const u8) void {
        // Split at the *first* semicolon only. A URI's query may well contain more,
        // and cutting at the last one would corrupt exactly those links.
        const semi = std.mem.indexOfScalar(u8, text, ';') orelse return;
        const uri = text[semi + 1 ..];

        if (uri.len == 0) {
            self.pen.hyperlink = 0;
            self.commitPen();
            return;
        }

        // Only schemes the launcher will actually open become links. Otherwise the
        // hover underline would promise a click that gets refused — and the whole
        // point of the allowlist is that `javascript:` never reaches a handler,
        // whether it arrived as plain text or as an OSC 8 payload.
        if (!urlmod.allowedScheme(uri)) return;
        // A URI is a single argument to a program later on; a control character in
        // it has no legitimate purpose here.
        for (uri) |ch| if (ch <= 0x20 or ch == 0x7f) return;

        if (self.gc_links.due(self.links.count())) self.collectGarbage();
        self.pen.hyperlink = self.links.intern(self.gpa, uri);
        self.commitPen();
    }

    /// The OSC 8 hyperlink under `at`, as the contiguous run of cells sharing its
    /// id, or null if there is none.
    pub fn hyperlinkAt(self: *const Screen, at: sel.Point) ?struct {
        span: urlmod.Span,
        id: u16,
    } {
        if (at.line >= self.grid.count or at.x >= self.grid.cols) return null;
        const id = self.styles.get(self.grid.line(at.line).cells[at.x].style).hyperlink;
        if (id == 0) return null;

        var start = at;
        while (urlmod.prevPos(&self.grid, start)) |p| {
            if (self.linkIdAt(p) != id) break;
            start = p;
        }
        var end = at;
        while (urlmod.nextPos(&self.grid, end)) |p| {
            if (self.linkIdAt(p) != id) break;
            end = p;
        }
        return .{ .span = .{ .start = start, .end = end }, .id = id };
    }

    fn linkIdAt(self: *const Screen, p: sel.Point) u16 {
        if (p.line >= self.grid.count or p.x >= self.grid.cols) return 0;
        return self.styles.get(self.grid.line(p.line).cells[p.x].style).hyperlink;
    }

    // DCS is parsed but dropped until Sixel arrives in phase 8.
    pub fn dcsHook(_: *Screen, _: u8, _: u8, _: *const parser.Params) void {}
    pub fn dcsPut(_: *Screen, _: u8) void {}
    pub fn dcsUnhook(_: *Screen) void {}

    // ── cursor movement ────────────────────────────────────────────────────

    fn setPosition(self: *Screen, row: u16, col: u16) void {
        const base: u32 = if (self.origin_mode) self.margin_top else 0;
        const limit: u32 = if (self.origin_mode) self.margin_bottom else self.grid.rows - 1;
        self.cursor_y = @min(base + @max(row, 1) - 1, limit);
        self.cursor_x = @min(@max(col, 1) - 1, self.grid.cols - 1);
        self.wrap_pending = false;
    }

    fn setColumn(self: *Screen, col: u16) void {
        self.cursor_x = @min(@max(col, 1) - 1, self.grid.cols - 1);
        self.wrap_pending = false;
    }

    fn setRow(self: *Screen, row: u16) void {
        const base: u32 = if (self.origin_mode) self.margin_top else 0;
        const limit: u32 = if (self.origin_mode) self.margin_bottom else self.grid.rows - 1;
        self.cursor_y = @min(base + @max(row, 1) - 1, limit);
        self.wrap_pending = false;
    }

    fn moveCursor(self: *Screen, dx: i64, dy: i64) void {
        const x = @as(i64, self.cursor_x) + dx;
        const y = @as(i64, self.cursor_y) + dy;
        self.cursor_x = @intCast(std.math.clamp(x, 0, @as(i64, self.grid.cols) - 1));
        // Cursor motion does not scroll, and inside a region it cannot leave it.
        const lo: i64 = if (self.cursorInRegion()) self.margin_top else 0;
        const hi: i64 = if (self.cursorInRegion())
            self.margin_bottom
        else
            @as(i64, self.grid.rows) - 1;
        self.cursor_y = @intCast(std.math.clamp(y, lo, hi));
        self.wrap_pending = false;
    }

    fn cursorInRegion(self: *const Screen) bool {
        return self.cursor_y >= self.margin_top and self.cursor_y <= self.margin_bottom;
    }

    fn saveCursor(self: *Screen) void {
        self.saved = .{
            .x = self.cursor_x,
            .y = self.cursor_y,
            .pen = self.pen,
            .pen_id = self.pen_id,
            .origin_mode = self.origin_mode,
            .autowrap = self.autowrap,
        };
    }

    fn restoreCursor(self: *Screen) void {
        self.cursor_x = @min(self.saved.x, self.grid.cols - 1);
        self.cursor_y = @min(self.saved.y, self.grid.rows - 1);
        self.pen = self.saved.pen;
        self.pen_id = self.saved.pen_id;
        self.origin_mode = self.saved.origin_mode;
        self.autowrap = self.saved.autowrap;
        self.wrap_pending = false;
    }

    // ── scrolling ──────────────────────────────────────────────────────────

    fn fullScreenRegion(self: *const Screen) bool {
        return self.margin_top == 0 and self.margin_bottom == self.grid.rows - 1;
    }

    fn lineFeed(self: *Screen) void {
        if (self.cursor_y == self.margin_bottom) {
            // Only a full-screen scroll on the primary grid produces scrollback.
            // Region scrolls and alt-screen scrolls are an application repainting
            // itself, not history worth keeping.
            if (self.fullScreenRegion() and !self.in_alt) {
                self.grid.scrollUp(1, self.pen_id);
            } else {
                self.grid.scrollRegionUp(self.margin_top, self.margin_bottom, 1, self.pen_id);
            }
        } else if (self.cursor_y + 1 < self.grid.rows) {
            self.cursor_y += 1;
        }
        self.dirty = true;
    }

    fn reverseIndex(self: *Screen) void {
        if (self.cursor_y == self.margin_top) {
            self.grid.scrollRegionDown(self.margin_top, self.margin_bottom, 1, self.pen_id);
        } else if (self.cursor_y > 0) {
            self.cursor_y -= 1;
        }
    }

    fn scrollUpRegion(self: *Screen, n: u16) void {
        const count = @max(n, 1);
        if (self.fullScreenRegion() and !self.in_alt) {
            self.grid.scrollUp(count, self.pen_id);
        } else {
            self.grid.scrollRegionUp(self.margin_top, self.margin_bottom, count, self.pen_id);
        }
    }

    fn scrollDownRegion(self: *Screen, n: u16) void {
        self.grid.scrollRegionDown(self.margin_top, self.margin_bottom, @max(n, 1), self.pen_id);
    }

    fn setScrollRegion(self: *Screen, params: *const parser.Params) void {
        const top = @max(params.get(0, 1), 1) - 1;
        const bottom_raw = params.get(1, @intCast(self.grid.rows));
        const bottom = @min(@max(bottom_raw, 1) - 1, self.grid.rows - 1);

        // A degenerate region is ignored outright, per DEC.
        if (top >= bottom) {
            self.margin_top = 0;
            self.margin_bottom = self.grid.rows - 1;
        } else {
            self.margin_top = top;
            self.margin_bottom = bottom;
        }
        // DECSTBM homes the cursor.
        self.cursor_y = if (self.origin_mode) self.margin_top else 0;
        self.cursor_x = 0;
        self.wrap_pending = false;
    }

    fn insertLines(self: *Screen, n: u16) void {
        if (!self.cursorInRegion()) return;
        self.grid.scrollRegionDown(self.cursor_y, self.margin_bottom, @max(n, 1), self.pen_id);
        self.cursor_x = 0;
    }

    fn deleteLines(self: *Screen, n: u16) void {
        if (!self.cursorInRegion()) return;
        self.grid.scrollRegionUp(self.cursor_y, self.margin_bottom, @max(n, 1), self.pen_id);
        self.cursor_x = 0;
    }

    // ── line editing ───────────────────────────────────────────────────────

    fn insertChars(self: *Screen, n: u16) void {
        const row = self.grid.row(self.cursor_y);
        const cols = self.grid.cols;
        const x = self.cursor_x;
        const count = @min(@as(u32, @max(n, 1)), cols - x);

        var i = cols;
        while (i > x + count) {
            i -= 1;
            row[i] = row[i - count];
        }
        @memset(row[x .. x + count], gridmod.blankCell(self.pen_id));
    }

    fn deleteChars(self: *Screen, n: u16) void {
        const row = self.grid.row(self.cursor_y);
        const cols = self.grid.cols;
        const x = self.cursor_x;
        const count = @min(@as(u32, @max(n, 1)), cols - x);

        var i = x;
        while (i + count < cols) : (i += 1) row[i] = row[i + count];
        @memset(row[cols - count ..], gridmod.blankCell(self.pen_id));
    }

    fn eraseChars(self: *Screen, n: u16) void {
        const row = self.grid.row(self.cursor_y);
        const end = @min(self.cursor_x + @max(n, 1), self.grid.cols);
        @memset(row[self.cursor_x..end], gridmod.blankCell(self.pen_id));
    }

    fn repeatLast(self: *Screen, n: u16) void {
        const cp = self.last_printed;
        var i: u16 = 0;
        while (i < @max(n, 1)) : (i += 1) self.print(cp);
    }

    fn eraseInDisplay(self: *Screen, mode: u16) void {
        switch (mode) {
            0 => {
                self.eraseInLine(0);
                self.grid.clearRows(self.cursor_y + 1, self.grid.rows, self.pen_id);
            },
            1 => {
                self.grid.clearRows(0, self.cursor_y, self.pen_id);
                self.eraseInLine(1);
            },
            2 => self.grid.clearVisible(self.pen_id),
            3 => {
                self.grid.clearVisible(self.pen_id);
                self.grid.dropScrollback();
            },
            else => {},
        }
    }

    fn eraseInLine(self: *Screen, mode: u16) void {
        const meta = self.grid.rowMeta(self.cursor_y);
        const b = gridmod.blankCell(self.pen_id);
        switch (mode) {
            0 => {
                @memset(meta.cells[self.cursor_x..], b);
                // The line no longer runs on, so reflow must not join it.
                meta.wrapped = false;
            },
            1 => @memset(meta.cells[0 .. self.cursor_x + 1], b),
            2 => {
                @memset(meta.cells, b);
                meta.wrapped = false;
            },
            else => {},
        }
    }

    fn alignmentTest(self: *Screen) void {
        var y: u32 = 0;
        while (y < self.grid.rows) : (y += 1) {
            const meta = self.grid.rowMeta(y);
            for (meta.cells) |*cl| cl.* = .{ .content = 'E', .style = 0 };
            meta.wrapped = false;
        }
        self.cursor_x = 0;
        self.cursor_y = 0;
    }

    // ── tabs ───────────────────────────────────────────────────────────────

    fn tab(self: *Screen, n: u16) void {
        var remaining = @max(n, 1);
        while (remaining > 0) : (remaining -= 1) {
            var x = self.cursor_x + 1;
            while (x < self.grid.cols and !self.tab_stops[x]) x += 1;
            self.cursor_x = @min(x, self.grid.cols - 1);
            if (self.cursor_x == self.grid.cols - 1) break;
        }
        self.wrap_pending = false;
        self.dirty = true;
    }

    fn backTab(self: *Screen, n: u16) void {
        var remaining = @max(n, 1);
        while (remaining > 0) : (remaining -= 1) {
            if (self.cursor_x == 0) break;
            var x = self.cursor_x - 1;
            while (x > 0 and !self.tab_stops[x]) x -= 1;
            self.cursor_x = x;
        }
        self.wrap_pending = false;
    }

    fn clearTabs(self: *Screen, mode: u16) void {
        switch (mode) {
            0 => if (self.cursor_x < self.tab_stops.len) {
                self.tab_stops[self.cursor_x] = false;
            },
            3 => @memset(self.tab_stops, false),
            else => {},
        }
    }

    // ── modes ──────────────────────────────────────────────────────────────

    fn ansiMode(self: *Screen, params: *const parser.Params, set: bool) void {
        for (0..params.len) |i| {
            switch (params.values[i]) {
                4 => self.insert_mode = set, // IRM
                else => {}, // LNM (20) intentionally ignored
            }
        }
    }

    fn decPrivateMode(self: *Screen, params: *const parser.Params, set: bool) void {
        for (0..params.len) |i| {
            switch (params.values[i]) {
                1 => self.modes.app_cursor = set, // DECCKM
                6 => { // DECOM
                    self.origin_mode = set;
                    self.cursor_x = 0;
                    self.cursor_y = if (set) self.margin_top else 0;
                },
                7 => self.autowrap = set, // DECAWM
                25 => self.cursor_visible = set, // DECTCEM
                // Mouse tracking. Each mode is its own bit — see mouse.Modes for
                // why collapsing them breaks nested applications.
                9 => self.mouse.x10 = set,
                1000 => self.mouse.button = set,
                1002 => self.mouse.drag = set,
                1003 => self.mouse.any = set,
                1006 => self.mouse.sgr = set,
                // 1005 (UTF-8) and 1015 (urxvt) are recognised and ignored on
                // purpose; mouse.zig explains why neither is worth having.
                1005, 1015 => {},
                1004 => self.modes.focus_events = set,
                1007 => self.modes.alternate_scroll = set,
                // 47 and 1047 switch buffers without touching the cursor; 1048 is
                // cursor save/restore alone; 1049 is the combination everything
                // actually uses.
                47, 1047 => self.setAltScreen(set, false, set),
                1048 => if (set) self.saveCursor() else self.restoreCursor(),
                1049 => self.setAltScreen(set, true, set),
                2004 => self.modes.bracketed_paste = set,
                2026 => self.sync_output = set,
                else => {},
            }
        }
    }

    /// The CSI u keyboard protocol's mode negotiation, all four of its forms.
    fn csiUKeyboard(self: *Screen, private: u8, params: *const parser.Params) void {
        switch (private) {
            // `CSI > flags u` — push the current flags, then set.
            '>' => {
                if (self.csi_u_depth < csi_u_stack_max) {
                    self.csi_u_stack[self.csi_u_depth] = self.modes.csi_u_flags;
                    self.csi_u_depth += 1;
                }
                // Saturate rather than drop the request: an application that pushed
                // too deep still gets the mode it asked for, it just cannot restore
                // as far back. Dropping it would leave it encoding for a mode that
                // is not active.
                self.modes.csi_u_flags = maskCsiUFlags(params.get(0, 0));
            },
            // `CSI < n u` — pop n entries, default 1.
            '<' => {
                var n = params.get(0, 1);
                if (n == 0) n = 1;
                while (n > 0 and self.csi_u_depth > 0) : (n -= 1) {
                    self.csi_u_depth -= 1;
                    self.modes.csi_u_flags = self.csi_u_stack[self.csi_u_depth];
                }
            },
            // `CSI = flags ; mode u` — 1 replaces, 2 sets bits, 3 clears bits.
            '=' => {
                const want = maskCsiUFlags(params.get(0, 0));
                switch (params.get(1, 1)) {
                    1 => self.modes.csi_u_flags = want,
                    2 => self.modes.csi_u_flags |= want,
                    3 => self.modes.csi_u_flags &= ~want,
                    else => {},
                }
            },
            // `CSI ? u` — report what actually took effect.
            //
            // Answered, unlike the title and colour queries, because this reply *is*
            // the negotiation: without it an application cannot know the protocol
            // exists and stays on legacy forever. It is also safe in a way those are
            // not — the value is a small integer this terminal chose, not text the
            // remote side supplied.
            '?' => {
                var buf: [16]u8 = undefined;
                const out = std.fmt.bufPrint(&buf, "\x1b[?{d}u", .{
                    self.modes.csi_u_flags,
                }) catch return;
                self.respond(out);
            },
            else => {},
        }
    }

    /// Switch between the primary and alternate screen.
    ///
    /// The two grids are swapped by value rather than behind a pointer, so `Screen`
    /// remains movable — an internal self-pointer would dangle the moment the
    /// struct returned from `init` were copied.
    fn setAltScreen(self: *Screen, enable: bool, with_cursor: bool, clear: bool) void {
        if (enable == self.in_alt) return;

        if (with_cursor) {
            const mine = SavedCursor{
                .x = self.cursor_x,
                .y = self.cursor_y,
                .pen = self.pen,
                .pen_id = self.pen_id,
                .origin_mode = self.origin_mode,
                .autowrap = self.autowrap,
            };
            const theirs = self.other_saved;
            self.other_saved = mine;
            self.saved = theirs;
        }

        std.mem.swap(Grid, &self.grid, &self.other);
        // The keyboard mode belongs to the buffer, so an application that dies on the
        // alternate screen cannot leave the shell with an encoding it never asked for.
        std.mem.swap(u5, &self.modes.csi_u_flags, &self.other_csi_u_flags);
        std.mem.swap([csi_u_stack_max]u5, &self.csi_u_stack, &self.other_csi_u_stack);
        std.mem.swap(usize, &self.csi_u_depth, &self.other_csi_u_depth);
        self.in_alt = enable;

        // Margins belong to the buffer being left behind.
        self.margin_top = 0;
        self.margin_bottom = self.grid.rows - 1;
        self.origin_mode = false;
        self.wrap_pending = false;

        if (clear) self.grid.clearVisible(self.pen_id);

        if (with_cursor and !enable) {
            self.cursor_x = @min(self.saved.x, self.grid.cols - 1);
            self.cursor_y = @min(self.saved.y, self.grid.rows - 1);
            self.pen = self.saved.pen;
            self.pen_id = self.saved.pen_id;
            self.autowrap = self.saved.autowrap;
        } else if (enable) {
            self.cursor_x = 0;
            self.cursor_y = 0;
        }
        self.dirty = true;
    }

    fn reset(self: *Screen) void {
        if (self.in_alt) self.setAltScreen(false, false, false);
        self.pen = Style.default;
        self.pen_id = 0;
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.cursor_visible = true;
        self.autowrap = true;
        self.origin_mode = false;
        self.insert_mode = false;
        self.wrap_pending = false;
        self.margin_top = 0;
        self.margin_bottom = self.grid.rows - 1;
        self.modes = .{};
        self.mouse = .{};
        self.csi_u_depth = 0;
        self.other_csi_u_flags = 0;
        self.other_csi_u_depth = 0;
        self.sync_output = false;
        self.resetTabs();
        self.grid.clearVisible(0);
        self.dirty = true;
    }

    // ── device reports ─────────────────────────────────────────────────────
    // Every reply here is a fixed shape with no attacker-influenced content.
    // That is a security property, not a simplification: a report that echoes
    // bytes chosen by remote output injects them into our own input stream.

    fn deviceAttributes(self: *Screen, private: u8) void {
        if (private == '>') {
            // DA2: terminal id 0, "firmware" 10, cartridge 1.
            self.respond("\x1b[>0;10;1c");
        } else if (private == 0) {
            // DA1: VT220 with ANSI colour.
            self.respond("\x1b[?62;22c");
        }
    }

    /// Only reached with no private marker; DECDSR (`CSI ? Ps n`) is filtered out
    /// earlier and stays unanswered.
    fn deviceStatus(self: *Screen, params: *const parser.Params) void {
        switch (params.get(0, 0)) {
            5 => self.respond("\x1b[0n"), // ready, no malfunction
            6 => { // CPR
                const base: u32 = if (self.origin_mode) self.margin_top else 0;
                var buf: [32]u8 = undefined;
                const out = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                    self.cursor_y - base + 1,
                    self.cursor_x + 1,
                }) catch return;
                self.respond(out);
            },
            else => {},
        }
    }

    // ── SGR ────────────────────────────────────────────────────────────────

    fn sgr(self: *Screen, params: *const parser.Params) void {
        if (params.len == 0) {
            self.pen = Style.default;
            self.commitPen();
            return;
        }

        var i: usize = 0;
        while (i < params.len) : (i += 1) {
            const p = params.values[i];
            switch (p) {
                0 => self.pen = Style.default,
                1 => self.pen.attrs.bold = true,
                2 => self.pen.attrs.dim = true,
                3 => self.pen.attrs.italic = true,
                4 => {
                    // `4:n` selects a style; plain `4` is a single underline.
                    const sub = i + 1 < params.len and params.is_sub[i + 1];
                    const style_arg = if (sub) params.values[i + 1] else 1;
                    if (sub) i += 1;
                    self.pen.attrs.underline = switch (style_arg) {
                        0 => .none,
                        1 => .single,
                        2 => .double,
                        3 => .curly,
                        4 => .dotted,
                        5 => .dashed,
                        else => .single,
                    };
                },
                5, 6 => self.pen.attrs.blink = true,
                7 => self.pen.attrs.inverse = true,
                8 => self.pen.attrs.invisible = true,
                9 => self.pen.attrs.strike = true,
                21 => self.pen.attrs.underline = .double,
                22 => {
                    self.pen.attrs.bold = false;
                    self.pen.attrs.dim = false;
                },
                23 => self.pen.attrs.italic = false,
                24 => self.pen.attrs.underline = .none,
                25 => self.pen.attrs.blink = false,
                27 => self.pen.attrs.inverse = false,
                28 => self.pen.attrs.invisible = false,
                29 => self.pen.attrs.strike = false,
                30...37 => self.pen.fg = Color.indexed(@intCast(p - 30)),
                38 => if (extendedColor(params, &i)) |col| {
                    self.pen.fg = col;
                },
                39 => self.pen.fg = Color.default,
                40...47 => self.pen.bg = Color.indexed(@intCast(p - 40)),
                48 => if (extendedColor(params, &i)) |col| {
                    self.pen.bg = col;
                },
                49 => self.pen.bg = Color.default,
                58 => if (extendedColor(params, &i)) |col| {
                    self.pen.ul = col;
                },
                59 => self.pen.ul = Color.default,
                90...97 => self.pen.fg = Color.indexed(@intCast(p - 90 + 8)),
                100...107 => self.pen.bg = Color.indexed(@intCast(p - 100 + 8)),
                else => {},
            }
        }
        self.commitPen();
    }

    fn commitPen(self: *Screen) void {
        if (self.gc_styles.due(self.styles.list.items.len)) self.collectGarbage();
        // Falling back to the default style on OOM is a cosmetic loss; refusing to
        // render would not be.
        self.pen_id = self.styles.intern(self.gpa, self.pen) catch 0;
    }

    /// Reclaim ids no cell refers to any more. See reclaim.zig.
    pub fn collectGarbage(self: *Screen) void {
        reclaim.collect(self);
    }
};

/// Parse the argument of SGR 38/48/58, advancing `i` past what it consumed.
///
/// Accepts the semicolon form (`38;5;n`, `38;2;r;g;b`) and the colon form
/// (`38:5:n`, `38:2:r:g:b`). TODO(phase 2): the colon form may also carry a
/// colour-space id — `38:2::r:g:b` — which we currently misread.
fn extendedColor(params: *const parser.Params, i: *usize) ?Color {
    switch (params.get(i.* + 1, 0)) {
        // `5;n` stays an *index*, not the colour it currently resolves to: an
        // application that later redefines colour n with OSC 4 expects this text to
        // change with it.
        5 => {
            const idx = params.get(i.* + 2, 0);
            i.* += 2;
            return Color.indexed(@intCast(@min(idx, 255)));
        },
        2 => {
            const r = params.get(i.* + 2, 0);
            const g = params.get(i.* + 3, 0);
            const b = params.get(i.* + 4, 0);
            i.* += 4;
            return Color.rgb(
                @intCast(@min(r, 255)),
                @intCast(@min(g, 255)),
                @intCast(@min(b, 255)),
            );
        },
        else => return null,
    }
}

test {
    // The suite lives in its own file; referencing it here keeps it running
    // wherever screen.zig is analysed.
    _ = @import("screen_test.zig");
}
