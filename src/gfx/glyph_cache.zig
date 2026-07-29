//! Codepoint -> atlas region cache.

const std = @import("std");
const c = @import("../c.zig").c;
const atlas = @import("atlas.zig");
const Font = @import("../font/font.zig").Font;

/// The scale component is present from day one even though phase 1 only ever uses
/// 1.0. This machine has a 1920x1200 panel and a 2560x1440 external monitor, so
/// glyphs must be re-rasterized per scale; adding `scale` to the key later would
/// mean auditing every lookup site (PLAN.md §10).
pub const Key = struct {
    cp: u32,
    /// Scale in 1/256ths, so 256 == 1.0.
    scale_q8: u16,
};

pub const Glyph = struct {
    kind: atlas.Kind,
    region: atlas.Region,
    /// Bearings, relative to the pen position on the baseline.
    left: i16,
    top: i16,
    /// Columns this glyph occupies, per wcwidth.
    cols: u8,
    /// A glyph with no bitmap at all, e.g. a space.
    blank: bool,
};

pub const GlyphCache = struct {
    gpa: std.mem.Allocator,
    font: *Font,
    mono: atlas.Atlas,
    color: atlas.Atlas,
    map: std.AutoHashMapUnmanaged(Key, Glyph) = .empty,
    /// Set when an atlas fills up, so the caller can report it rather than
    /// silently rendering blanks. Phase 7 replaces this with LRU eviction.
    exhausted: bool = false,

    pub fn init(gpa: std.mem.Allocator, font: *Font, size: u32) GlyphCache {
        return .{
            .gpa = gpa,
            .font = font,
            .mono = atlas.Atlas.init(size, .mono),
            .color = atlas.Atlas.init(size, .color),
        };
    }

    pub fn deinit(self: *GlyphCache) void {
        self.mono.deinit();
        self.color.deinit();
        self.map.deinit(self.gpa);
    }

    pub fn get(self: *GlyphCache, cp: u32, scale_q8: u16) ?Glyph {
        const key = Key{ .cp = cp, .scale_q8 = scale_q8 };
        if (self.map.get(key)) |g| return g;

        const raster = self.font.rasterize(cp) orelse return null;
        const glyph = self.upload(raster) catch {
            self.exhausted = true;
            return null;
        };
        self.map.put(self.gpa, key, glyph) catch return glyph;
        return glyph;
    }

    fn upload(self: *GlyphCache, raster: *const c.struct_fcft_glyph) !Glyph {
        const w: u32 = @intCast(@max(raster.width, 0));
        const h: u32 = @intCast(@max(raster.height, 0));
        const cols: u8 = @intCast(std.math.clamp(raster.cols, 1, 2));

        if (w == 0 or h == 0 or raster.pix == null) {
            return .{
                .kind = .mono,
                .region = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
                .left = @intCast(raster.x),
                .top = @intCast(raster.y),
                .cols = cols,
                .blank = true,
            };
        }

        const data = c.pixman_image_get_data(raster.pix);
        const stride: u32 = @intCast(c.pixman_image_get_stride(raster.pix));
        const kind: atlas.Kind = if (raster.is_color_glyph) .color else .mono;

        const target = switch (kind) {
            .mono => &self.mono,
            .color => &self.color,
        };
        const region = try target.put(w, h, @ptrCast(data), stride);

        return .{
            .kind = kind,
            .region = region,
            .left = @intCast(raster.x),
            .top = @intCast(raster.y),
            .cols = cols,
            .blank = false,
        };
    }
};
