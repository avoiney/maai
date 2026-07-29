//! Font loading and glyph rasterization via fcft.
//!
//! fcft bundles FreeType rasterization, HarfBuzz shaping, fontconfig fallback
//! chains, and a glyph cache behind one C API. Phase 1 uses only per-codepoint
//! rasterization; run shaping (`fcft_rasterize_text_run_utf32`) is what FiraCode's
//! ligatures need and lands with the typography work in phase 7.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Error = error{
    InitFailed,
    LoadFailed,
};

var fcft_ready = false;

pub const Font = struct {
    handle: *c.struct_fcft_font,

    /// Cell geometry, in device pixels.
    cell_w: u32,
    cell_h: u32,
    /// Distance from the top of the cell down to the baseline.
    baseline: i32,

    underline_pos: i32,
    underline_thickness: i32,
    strikeout_pos: i32,
    strikeout_thickness: i32,

    /// `name` is a family such as "FiraCode Nerd Font"; `attrs` is a fontconfig
    /// pattern fragment such as "size=12:dpi=96".
    pub fn init(name: [*:0]const u8, attrs: [*:0]const u8) Error!Font {
        if (!fcft_ready) {
            if (!c.fcft_init(c.FCFT_LOG_COLORIZE_AUTO, false, c.FCFT_LOG_CLASS_WARNING))
                return Error.InitFailed;
            fcft_ready = true;
        }

        var names = [_][*c]const u8{name};
        const handle = c.fcft_from_name(names.len, &names, attrs) orelse
            return Error.LoadFailed;

        // Cell width comes from the advance of U+0020 rather than the font's
        // max_advance. For a Nerd Font those differ a lot: max_advance reflects the
        // widest icon in the fallback chain, which would leave every column of text
        // padded with dead space.
        var cell_w: u32 = @intCast(@max(handle.*.max_advance.x, 1));
        if (c.fcft_rasterize_char_utf32(handle, ' ', c.FCFT_SUBPIXEL_NONE)) |space| {
            if (space.*.advance.x > 0) cell_w = @intCast(space.*.advance.x);
        }

        return .{
            .handle = handle,
            .cell_w = cell_w,
            .cell_h = @intCast(@max(handle.*.height, 1)),
            .baseline = handle.*.ascent,
            .underline_pos = handle.*.underline.position,
            .underline_thickness = @max(handle.*.underline.thickness, 1),
            .strikeout_pos = handle.*.strikeout.position,
            .strikeout_thickness = @max(handle.*.strikeout.thickness, 1),
        };
    }

    pub fn deinit(self: *Font) void {
        c.fcft_destroy(self.handle);
    }

    /// Rasterize one codepoint. fcft owns and caches the returned glyph, so the
    /// pointer stays valid for the font's lifetime and must not be freed.
    pub fn rasterize(self: *Font, cp: u32) ?*const c.struct_fcft_glyph {
        return c.fcft_rasterize_char_utf32(self.handle, cp, c.FCFT_SUBPIXEL_NONE);
    }

    pub fn capabilities() struct { grapheme: bool, text_run: bool, svg: bool } {
        const caps = c.fcft_capabilities();
        return .{
            .grapheme = caps & c.FCFT_CAPABILITY_GRAPHEME_SHAPING != 0,
            .text_run = caps & c.FCFT_CAPABILITY_TEXT_RUN_SHAPING != 0,
            .svg = caps & c.FCFT_CAPABILITY_SVG != 0,
        };
    }
};
