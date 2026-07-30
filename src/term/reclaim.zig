//! Reclaiming interned ids: styles, grapheme clusters and hyperlink URIs.
//!
//! Split out of screen.zig, which had no business being 2500 lines. This is one
//! self-contained pass with its own vocabulary, and nothing else in the terminal
//! needs to see it.

const std = @import("std");
const cellmod = @import("cell.zig");
const gridmod = @import("grid.zig");
const Grid = gridmod.Grid;
const Cell = cellmod.Cell;
const Screen = @import("screen.zig").Screen;

const unused_style: u16 = 0xffff;
const marked_style: u16 = 0xfffe;
const unused_cluster: u32 = 0xffff_ffff;
const marked_cluster: u32 = 0xffff_fffe;
const unused_link: u16 = 0xffff;
const marked_link: u16 = 0xfffe;

/// Reclaim style ids and grapheme clusters no cell refers to any more.
///
/// Mark and compact, not refcounting. Refcounting would put an increment and a
/// decrement on every cell write — including the bulk `@memset` paths used by
/// erase, scroll and clear, which have no single place to hook — and `print` is
/// the hottest loop in the program. Compaction costs one full scan of both
/// grids, but only when a table is nearly full.
///
/// Without this, a `lolcat` or a gradient prompt exhausts all 65535 style ids in
/// a few screens at 1440p, after which every cell renders in the default style
/// for the rest of the session, with no message and no way to recover.
pub fn collect(self: *Screen) void {
    const gpa = self.gpa;
    const style_n = self.styles.list.items.len;
    const cluster_n = self.graphemes.spans.items.len;

    const style_map = gpa.alloc(u16, style_n) catch return;
    defer gpa.free(style_map);
    @memset(style_map, unused_style);

    const cluster_map = gpa.alloc(u32, cluster_n) catch return;
    defer gpa.free(cluster_map);
    @memset(cluster_map, unused_cluster);

    // ── mark ──
    // Scrollback counts: a cell that has scrolled off screen is still live, and
    // will be shown again if the user scrolls back or the window is widened.
    for ([_]*const Grid{ &self.grid, &self.other }) |g| {
        var i: usize = 0;
        while (i < g.count) : (i += 1) {
            for (g.line(i).cells) |cell| {
                if (cell.style < style_n) style_map[cell.style] = marked_style;
                if (cell.grapheme and cell.content < cluster_n) {
                    cluster_map[cell.content] = marked_cluster;
                }
            }
        }
    }
    // Ids held outside the grids: the current pen and both saved cursors.
    for ([_]u16{ self.pen_id, self.saved.pen_id, self.other_saved.pen_id }) |id| {
        if (id < style_n) style_map[id] = marked_style;
    }
    // Id 0 is the default style and must keep that id, referenced or not: a
    // zeroed Cell means "default", so renumbering it would change every blank.
    if (style_n > 0) style_map[0] = marked_style;

    // ── assign new ids ──
    var new_styles: std.ArrayList(cellmod.Style) = .empty;
    defer new_styles.deinit(gpa);
    for (style_map, 0..) |*slot, old| {
        if (slot.* != marked_style) continue;
        slot.* = @intCast(new_styles.items.len);
        new_styles.append(gpa, self.styles.list.items[old]) catch return;
    }

    // Hyperlinks are reached only through styles, so the surviving styles are
    // exactly the mark phase for the link table — no second sweep over cells.
    const link_n = self.links.count();
    const link_map = gpa.alloc(u16, link_n) catch return;
    defer gpa.free(link_map);
    @memset(link_map, unused_link);
    for (new_styles.items) |style| {
        if (style.hyperlink != 0 and style.hyperlink < link_n) {
            link_map[style.hyperlink] = marked_link;
        }
    }
    // Compacted into fresh buffers rather than a list of slices: slices would
    // point into the table we are about to overwrite.
    var new_link_data: std.ArrayList(u8) = .empty;
    defer new_link_data.deinit(gpa);
    var new_link_spans: std.ArrayList(cellmod.LinkTable.Span) = .empty;
    defer new_link_spans.deinit(gpa);
    for (link_map, 0..) |*slot, old| {
        if (slot.* != marked_link) continue;
        const uri = self.links.get(@intCast(old));
        const start: u32 = @intCast(new_link_data.items.len);
        new_link_data.appendSlice(gpa, uri) catch return;
        // Ids restart at 1; 0 stays "no link".
        slot.* = @intCast(new_link_spans.items.len + 1);
        new_link_spans.append(gpa, .{
            .start = start,
            .len = @intCast(uri.len),
        }) catch return;
    }
    for (new_styles.items) |*style| {
        if (style.hyperlink == 0) continue;
        style.hyperlink = if (style.hyperlink < link_n and
            link_map[style.hyperlink] < marked_link)
            link_map[style.hyperlink]
        else
            0;
    }

    var new_data: std.ArrayList(u21) = .empty;
    defer new_data.deinit(gpa);
    var new_spans: std.ArrayList(cellmod.GraphemeTable.Span) = .empty;
    defer new_spans.deinit(gpa);
    for (cluster_map, 0..) |*slot, old| {
        if (slot.* != marked_cluster) continue;
        const cps = self.graphemes.get(@intCast(old));
        const start: u32 = @intCast(new_data.items.len);
        new_data.appendSlice(gpa, cps) catch return;
        slot.* = @intCast(new_spans.items.len);
        new_spans.append(gpa, .{
            .start = start,
            .len = @intCast(cps.len),
        }) catch return;
    }

    // Everything below this point must not fail: the maps are final and the
    // cells are about to be renumbered against them.

    // ── rewrite references ──
    for ([_]*const Grid{ &self.grid, &self.other }) |g| {
        var i: usize = 0;
        while (i < g.count) : (i += 1) {
            for (g.line(i).cells) |*cell| {
                if (cell.style < style_n and style_map[cell.style] < marked_style) {
                    cell.style = style_map[cell.style];
                } else {
                    cell.style = 0;
                }
                if (cell.grapheme) {
                    if (cell.content < cluster_n and
                        cluster_map[cell.content] < marked_cluster)
                    {
                        cell.content = cluster_map[cell.content];
                    } else {
                        // Unreachable in practice: the cell was just marked.
                        // Degrade to a blank rather than point at nothing.
                        cell.grapheme = false;
                        cell.content = Cell.empty;
                    }
                }
            }
        }
    }
    self.pen_id = if (self.pen_id < style_n) style_map[self.pen_id] else 0;
    self.saved.pen_id = if (self.saved.pen_id < style_n) style_map[self.saved.pen_id] else 0;
    self.other_saved.pen_id = if (self.other_saved.pen_id < style_n)
        style_map[self.other_saved.pen_id]
    else
        0;

    self.styles.rebuild(gpa, new_styles.items) catch {};
    self.links.replace(gpa, new_link_data.items, new_link_spans.items) catch {};
    self.graphemes.data.clearRetainingCapacity();
    self.graphemes.spans.clearRetainingCapacity();
    self.graphemes.data.appendSlice(gpa, new_data.items) catch {};
    self.graphemes.spans.appendSlice(gpa, new_spans.items) catch {};

    self.gc_styles.rearm(style_n, new_styles.items.len, std.math.maxInt(u16) - 1);
    self.gc_graphemes.rearm(
        cluster_n,
        new_spans.items.len,
        std.math.maxInt(u32) - 1,
    );
    self.gc_links.rearm(
        link_n,
        new_link_spans.items.len + 1,
        std.math.maxInt(u16) - 1,
    );
    self.dirty = true;
}
