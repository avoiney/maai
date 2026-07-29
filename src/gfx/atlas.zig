//! GPU glyph atlas with a shelf-packing allocator.
//!
//! Two atlases are needed, not one: most glyphs are 8-bit coverage masks tinted by
//! the cell's foreground colour, while emoji and some Nerd Font glyphs are full
//! colour bitmaps that must be blended as-is. Keeping them in separate textures
//! avoids wasting 4x the memory on the common case.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Kind = enum { mono, color };

pub const Region = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

pub const Error = error{Full};

pub const Atlas = struct {
    tex: c.GLuint = 0,
    size: u32,
    kind: Kind,

    /// Shelf packer: glyphs are placed left to right on a shelf whose height is
    /// set by the first glyph on it. Cheap, and a good fit for glyphs, which are
    /// all roughly one line tall. Phase 7 adds LRU eviction with a memory budget.
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    pen_x: u32 = 0,

    /// 1px gutter so nearest-neighbour sampling at the edges cannot pick up a
    /// neighbouring glyph.
    const pad = 1;

    pub fn init(size: u32, kind: Kind) Atlas {
        var a = Atlas{ .size = size, .kind = kind };

        c.glGenTextures(1, &a.tex);
        c.glBindTexture(c.GL_TEXTURE_2D, a.tex);

        const internal: c.GLint = switch (kind) {
            .mono => c.GL_R8,
            .color => c.GL_RGBA8,
        };
        const format: c.GLenum = switch (kind) {
            .mono => c.GL_RED,
            .color => c.GL_RGBA,
        };
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            internal,
            @intCast(size),
            @intCast(size),
            0,
            format,
            c.GL_UNSIGNED_BYTE,
            null,
        );

        // NEAREST, not LINEAR: glyphs are blitted at 1:1 scale, so filtering would
        // only blur them.
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

        return a;
    }

    pub fn deinit(self: *Atlas) void {
        if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
    }

    fn alloc(self: *Atlas, w: u32, h: u32) Error!Region {
        if (w > self.size or h > self.size) return Error.Full;

        if (self.pen_x + w > self.size) {
            // Next shelf.
            self.shelf_y += self.shelf_h + pad;
            self.shelf_h = 0;
            self.pen_x = 0;
        }
        if (h > self.shelf_h) {
            // Growing the current shelf must not push it off the texture.
            if (self.shelf_y + h > self.size) return Error.Full;
            self.shelf_h = h;
        }
        if (self.shelf_y + self.shelf_h > self.size) return Error.Full;

        const r = Region{
            .x = @intCast(self.pen_x),
            .y = @intCast(self.shelf_y),
            .w = @intCast(w),
            .h = @intCast(h),
        };
        self.pen_x += w + pad;
        return r;
    }

    /// Copy a pixman bitmap into the atlas and return where it landed.
    ///
    /// `stride` is in bytes, as pixman reports it, and is generally wider than
    /// `w * bytes_per_pixel` because of row alignment — hence GL_UNPACK_ROW_LENGTH.
    pub fn put(self: *Atlas, w: u32, h: u32, data: [*]const u8, stride: u32) Error!Region {
        const region = try self.alloc(w, h);
        if (w == 0 or h == 0) return region;

        const bpp: u32 = switch (self.kind) {
            .mono => 1,
            .color => 4,
        };
        const format: c.GLenum = switch (self.kind) {
            .mono => c.GL_RED,
            .color => c.GL_RGBA,
        };

        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, @intCast(stride / bpp));
        c.glTexSubImage2D(
            c.GL_TEXTURE_2D,
            0,
            region.x,
            region.y,
            @intCast(w),
            @intCast(h),
            format,
            c.GL_UNSIGNED_BYTE,
            data,
        );
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, 0);

        return region;
    }
};
