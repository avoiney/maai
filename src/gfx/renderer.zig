//! Instanced GLES3 renderer.
//!
//! Two passes over one unit quad:
//!   1. backgrounds — one instance per cell whose background differs from default
//!   2. foregrounds — one instance per glyph, plus solid rects for underline and
//!      strikethrough
//!
//! Everything is rebuilt from the grid each frame. At ~19k cells that is a few
//! hundred KB of upload and well inside the 1 ms budget, so damage tracking is
//! deferred to phase 7 where it belongs (and where presentation-feedback pacing
//! makes it measurable).
//!
//! Colours are written premultiplied and blended with (ONE, ONE_MINUS_SRC_ALPHA),
//! which lets colour emoji — already premultiplied by pixman — and tinted coverage
//! masks share a single blend state.

const std = @import("std");
const c = @import("../c.zig").c;
const cellmod = @import("../term/cell.zig");
const Screen = @import("../term/screen.zig").Screen;
const Font = @import("../font/font.zig").Font;
const GlyphCache = @import("glyph_cache.zig").GlyphCache;
const Hint = @import("../term/hints.zig").Hint;

/// One column of the tab bar, prepared by the caller.
///
/// A flat list of columns rather than a list of tabs: the bar is drawn like any other
/// row of cells, and deciding what goes in each column — truncation, separators, which
/// tab is active — is layout, which belongs with the application, not the renderer.
pub const BarCell = struct {
    cp: u21 = ' ',
    /// Explicit rather than a flag the renderer maps to colours. Powerline needs a
    /// separator whose foreground is the tab it leaves and whose background is the one
    /// it enters — two different tabs' colours in one cell, which no flag can express.
    fg: Rgb,
    bg: Rgb,
};

const Rgb = cellmod.Rgb;

pub const Error = error{
    ShaderCompile,
    ProgramLink,
};

const BgInstance = extern struct {
    cell: [2]i16,
    color: [4]u8,
};

const FgInstance = extern struct {
    pos: [2]i16,
    size: [2]u16,
    uv: [2]u16,
    color: [4]u8,
    flags: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

const flag_color_glyph: u8 = 1;
const flag_solid: u8 = 2;

pub const Padding = struct { x: u32 = 4, y: u32 = 0 };

const bg_vs =
    \\#version 300 es
    \\layout(location = 0) in vec2 a_corner;
    \\layout(location = 1) in ivec2 a_cell;
    \\layout(location = 2) in vec4 a_color;
    \\uniform vec2 u_viewport;
    \\uniform vec2 u_cell;
    \\uniform vec2 u_pad;
    \\out vec4 v_color;
    \\void main() {
    \\    vec2 px = u_pad + (vec2(a_cell) + a_corner) * u_cell;
    \\    gl_Position = vec4(px.x / u_viewport.x * 2.0 - 1.0,
    \\                      1.0 - px.y / u_viewport.y * 2.0, 0.0, 1.0);
    \\    v_color = a_color;
    \\}
;

const bg_fs =
    \\#version 300 es
    \\precision mediump float;
    \\in vec4 v_color;
    \\out vec4 o_color;
    \\void main() { o_color = vec4(v_color.rgb * v_color.a, v_color.a); }
;

const fg_vs =
    \\#version 300 es
    \\layout(location = 0) in vec2 a_corner;
    \\layout(location = 1) in ivec2 a_pos;
    \\layout(location = 2) in uvec2 a_size;
    \\layout(location = 3) in uvec2 a_uv;
    \\layout(location = 4) in vec4 a_color;
    \\layout(location = 5) in uint a_flags;
    \\uniform vec2 u_viewport;
    \\uniform vec2 u_atlas;
    \\out vec2 v_uv;
    \\out vec4 v_color;
    \\flat out uint v_flags;
    \\void main() {
    \\    vec2 px = vec2(a_pos) + a_corner * vec2(a_size);
    \\    gl_Position = vec4(px.x / u_viewport.x * 2.0 - 1.0,
    \\                      1.0 - px.y / u_viewport.y * 2.0, 0.0, 1.0);
    \\    v_uv = (vec2(a_uv) + a_corner * vec2(a_size)) / u_atlas;
    \\    v_color = a_color;
    \\    v_flags = a_flags;
    \\}
;

const fg_fs =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 v_uv;
    \\in vec4 v_color;
    \\flat in uint v_flags;
    \\uniform sampler2D u_mono;
    \\uniform sampler2D u_color;
    \\out vec4 o_color;
    \\void main() {
    \\    if ((v_flags & 2u) != 0u) {
    \\        o_color = vec4(v_color.rgb * v_color.a, v_color.a);
    \\    } else if ((v_flags & 1u) != 0u) {
    \\        vec4 t = texture(u_color, v_uv);
    \\        // pixman's a8r8g8b8 is BGRA in memory on little-endian, and we upload
    \\        // it as GL_RGBA, so unswizzle here. Already premultiplied.
    \\        o_color = vec4(t.b, t.g, t.r, t.a);
    \\    } else {
    \\        float a = texture(u_mono, v_uv).r;
    \\        o_color = vec4(v_color.rgb * a, a * v_color.a);
    \\    }
    \\}
;

pub const Renderer = struct {
    gpa: std.mem.Allocator,

    bg_prog: c.GLuint = 0,
    fg_prog: c.GLuint = 0,
    quad: c.GLuint = 0,
    bg_vao: c.GLuint = 0,
    bg_vbo: c.GLuint = 0,
    fg_vao: c.GLuint = 0,
    fg_vbo: c.GLuint = 0,

    u_bg_viewport: c.GLint = -1,
    u_bg_cell: c.GLint = -1,
    u_bg_pad: c.GLint = -1,
    u_fg_viewport: c.GLint = -1,
    u_fg_atlas: c.GLint = -1,

    bg_list: std.ArrayList(BgInstance) = .empty,
    fg_list: std.ArrayList(FgInstance) = .empty,

    pub fn init(gpa: std.mem.Allocator) Error!Renderer {
        var r = Renderer{ .gpa = gpa };

        r.bg_prog = try buildProgram(bg_vs, bg_fs);
        r.fg_prog = try buildProgram(fg_vs, fg_fs);

        r.u_bg_viewport = c.glGetUniformLocation(r.bg_prog, "u_viewport");
        r.u_bg_cell = c.glGetUniformLocation(r.bg_prog, "u_cell");
        r.u_bg_pad = c.glGetUniformLocation(r.bg_prog, "u_pad");
        r.u_fg_viewport = c.glGetUniformLocation(r.fg_prog, "u_viewport");
        r.u_fg_atlas = c.glGetUniformLocation(r.fg_prog, "u_atlas");

        // Sampler bindings are fixed for the program's lifetime.
        c.glUseProgram(r.fg_prog);
        c.glUniform1i(c.glGetUniformLocation(r.fg_prog, "u_mono"), 0);
        c.glUniform1i(c.glGetUniformLocation(r.fg_prog, "u_color"), 1);

        // One unit quad, instanced for every cell and glyph.
        const corners = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };
        c.glGenBuffers(1, &r.quad);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, r.quad);
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(corners)), &corners, c.GL_STATIC_DRAW);

        r.setupBgVao();
        r.setupFgVao();

        return r;
    }

    pub fn deinit(self: *Renderer) void {
        self.bg_list.deinit(self.gpa);
        self.fg_list.deinit(self.gpa);
        c.glDeleteBuffers(1, &self.quad);
        c.glDeleteBuffers(1, &self.bg_vbo);
        c.glDeleteBuffers(1, &self.fg_vbo);
        c.glDeleteVertexArrays(1, &self.bg_vao);
        c.glDeleteVertexArrays(1, &self.fg_vao);
        c.glDeleteProgram(self.bg_prog);
        c.glDeleteProgram(self.fg_prog);
    }

    fn setupBgVao(self: *Renderer) void {
        c.glGenVertexArrays(1, &self.bg_vao);
        c.glBindVertexArray(self.bg_vao);

        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.quad);
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 0, null);

        c.glGenBuffers(1, &self.bg_vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.bg_vbo);
        const stride: c.GLsizei = @sizeOf(BgInstance);

        c.glEnableVertexAttribArray(1);
        c.glVertexAttribIPointer(1, 2, c.GL_SHORT, stride, @ptrFromInt(@offsetOf(BgInstance, "cell")));
        c.glVertexAttribDivisor(1, 1);

        c.glEnableVertexAttribArray(2);
        c.glVertexAttribPointer(2, 4, c.GL_UNSIGNED_BYTE, c.GL_TRUE, stride, @ptrFromInt(@offsetOf(BgInstance, "color")));
        c.glVertexAttribDivisor(2, 1);

        c.glBindVertexArray(0);
    }

    fn setupFgVao(self: *Renderer) void {
        c.glGenVertexArrays(1, &self.fg_vao);
        c.glBindVertexArray(self.fg_vao);

        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.quad);
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 0, null);

        c.glGenBuffers(1, &self.fg_vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.fg_vbo);
        const stride: c.GLsizei = @sizeOf(FgInstance);

        c.glEnableVertexAttribArray(1);
        c.glVertexAttribIPointer(1, 2, c.GL_SHORT, stride, @ptrFromInt(@offsetOf(FgInstance, "pos")));
        c.glVertexAttribDivisor(1, 1);

        c.glEnableVertexAttribArray(2);
        c.glVertexAttribIPointer(2, 2, c.GL_UNSIGNED_SHORT, stride, @ptrFromInt(@offsetOf(FgInstance, "size")));
        c.glVertexAttribDivisor(2, 1);

        c.glEnableVertexAttribArray(3);
        c.glVertexAttribIPointer(3, 2, c.GL_UNSIGNED_SHORT, stride, @ptrFromInt(@offsetOf(FgInstance, "uv")));
        c.glVertexAttribDivisor(3, 1);

        c.glEnableVertexAttribArray(4);
        c.glVertexAttribPointer(4, 4, c.GL_UNSIGNED_BYTE, c.GL_TRUE, stride, @ptrFromInt(@offsetOf(FgInstance, "color")));
        c.glVertexAttribDivisor(4, 1);

        c.glEnableVertexAttribArray(5);
        c.glVertexAttribIPointer(5, 1, c.GL_UNSIGNED_BYTE, stride, @ptrFromInt(@offsetOf(FgInstance, "flags")));
        c.glVertexAttribDivisor(5, 1);

        c.glBindVertexArray(0);
    }

    pub fn draw(
        self: *Renderer,
        screen: *const Screen,
        /// Hint-mode labels, in reading order. Passed rather than read off the
        /// Screen because the storage belongs to the caller — unlike `selection`
        /// and `hover`, which are plain values the Screen can own outright.
        hints: []const Hint,
        /// Tab bar, drawn on the row below the grid. Empty draws nothing.
        bar: []const BarCell,
        cache: *GlyphCache,
        font: *const Font,
        viewport_w: u32,
        viewport_h: u32,
        pad: Padding,
    ) void {
        self.bg_list.clearRetainingCapacity();
        self.fg_list.clearRetainingCapacity();
        self.build(screen, hints, cache, font, pad);
        self.buildBar(screen, bar, cache, font, pad);

        const bg = screen.theme.bg;
        c.glClearColor(
            @as(f32, @floatFromInt(bg.r)) / 255.0,
            @as(f32, @floatFromInt(bg.g)) / 255.0,
            @as(f32, @floatFromInt(bg.b)) / 255.0,
            1.0,
        );
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);

        const vw: f32 = @floatFromInt(viewport_w);
        const vh: f32 = @floatFromInt(viewport_h);

        if (self.bg_list.items.len > 0) {
            c.glUseProgram(self.bg_prog);
            c.glUniform2f(self.u_bg_viewport, vw, vh);
            c.glUniform2f(
                self.u_bg_cell,
                @floatFromInt(font.cell_w),
                @floatFromInt(font.cell_h),
            );
            c.glUniform2f(self.u_bg_pad, @floatFromInt(pad.x), @floatFromInt(pad.y));

            c.glBindVertexArray(self.bg_vao);
            c.glBindBuffer(c.GL_ARRAY_BUFFER, self.bg_vbo);
            c.glBufferData(
                c.GL_ARRAY_BUFFER,
                @intCast(self.bg_list.items.len * @sizeOf(BgInstance)),
                self.bg_list.items.ptr,
                c.GL_STREAM_DRAW,
            );
            c.glDrawArraysInstanced(
                c.GL_TRIANGLE_STRIP,
                0,
                4,
                @intCast(self.bg_list.items.len),
            );
        }

        if (self.fg_list.items.len > 0) {
            c.glUseProgram(self.fg_prog);
            c.glUniform2f(self.u_fg_viewport, vw, vh);
            c.glUniform2f(
                self.u_fg_atlas,
                @floatFromInt(cache.mono.size),
                @floatFromInt(cache.mono.size),
            );

            c.glActiveTexture(c.GL_TEXTURE0);
            c.glBindTexture(c.GL_TEXTURE_2D, cache.mono.tex);
            c.glActiveTexture(c.GL_TEXTURE1);
            c.glBindTexture(c.GL_TEXTURE_2D, cache.color.tex);

            c.glBindVertexArray(self.fg_vao);
            c.glBindBuffer(c.GL_ARRAY_BUFFER, self.fg_vbo);
            c.glBufferData(
                c.GL_ARRAY_BUFFER,
                @intCast(self.fg_list.items.len * @sizeOf(FgInstance)),
                self.fg_list.items.ptr,
                c.GL_STREAM_DRAW,
            );
            c.glDrawArraysInstanced(
                c.GL_TRIANGLE_STRIP,
                0,
                4,
                @intCast(self.fg_list.items.len),
            );
        }

        c.glBindVertexArray(0);
    }

    /// The bar sits on the row after the last grid row — a row the grid never had, which
    /// is why `gridSize` reserves it.
    fn buildBar(
        self: *Renderer,
        screen: *const Screen,
        bar: []const BarCell,
        cache: *GlyphCache,
        font: *const Font,
        pad: Padding,
    ) void {
        if (bar.len == 0) return;
        const y = screen.grid.rows;

        for (bar, 0..) |cell, i| {
            const x: u32 = @intCast(i);
            const bg = cell.bg;
            const fg = cell.fg;

            self.bg_list.append(self.gpa, .{
                .cell = .{ @intCast(x), @intCast(y) },
                .color = .{ bg.r, bg.g, bg.b, bg.a },
            }) catch {};
            if (cell.cp != ' ') {
                self.emitGlyph(
                    cache,
                    font,
                    pad.x + x * font.cell_w,
                    pad.y + y * font.cell_h,
                    cell.cp,
                    fg,
                );
            }
        }
    }

    fn build(
        self: *Renderer,
        screen: *const Screen,
        hints: []const Hint,
        cache: *GlyphCache,
        font: *const Font,
        pad: Padding,
    ) void {
        const theme = &screen.theme;
        const default_bg = theme.bg;
        // The viewport is the live screen only when the user has not scrolled back.
        const view_top = screen.grid.viewTop();
        const scrolled = screen.grid.view != 0;

        // Hints arrive in reading order, the same order this loop walks, so one
        // moving index finds the label for a cell without searching.
        var hint_i: usize = 0;

        var y: u32 = 0;
        while (y < screen.grid.rows) : (y += 1) {
            const row = screen.grid.viewRow(y);
            const line = view_top + y;
            var x: u32 = 0;
            while (x < screen.grid.cols) : (x += 1) {
                const cell = row[x];
                const style = screen.styles.get(cell.style);

                while (hint_i < hints.len and hintEndsBefore(hints[hint_i], line, x)) {
                    hint_i += 1;
                }
                if (hint_i < hints.len) {
                    if (labelChar(hints[hint_i], line, x)) |ch| {
                        // A label replaces the cell entirely. Drawing both would
                        // overprint two glyphs in one cell.
                        self.bg_list.append(self.gpa, .{
                            .cell = .{ @intCast(x), @intCast(y) },
                            .color = .{
                                theme.hint_bg.r,
                                theme.hint_bg.g,
                                theme.hint_bg.b,
                                theme.hint_bg.a,
                            },
                        }) catch {};
                        self.emitGlyph(
                            cache,
                            font,
                            pad.x + x * font.cell_w,
                            pad.y + y * font.cell_h,
                            ch,
                            theme.hint_fg,
                        );
                        continue;
                    }
                }

                // Colour slots hold requests; the theme turns them into pixels
                // here, which is what lets a theme reload repaint old text.
                var fg = theme.resolve(style.fg, .fg);
                var bg = theme.resolve(style.bg, .bg);
                if (style.attrs.inverse) std.mem.swap(Rgb, &fg, &bg);
                if (style.attrs.dim) fg = dim(fg);

                if (screen.selection.contains(line, x)) {
                    bg = theme.selection_bg;
                    fg = theme.selection_fg;
                }

                // No cursor while scrolled back: it belongs to the live screen,
                // which is not what is on display.
                const on_cursor = !scrolled and screen.cursor_visible and
                    x == screen.cursor_x and y == screen.cursor_y;
                if (on_cursor) {
                    bg = theme.cursor;
                    fg = theme.cursor_text;
                }

                if (!bg.eq(default_bg)) {
                    self.bg_list.append(self.gpa, .{
                        .cell = .{ @intCast(x), @intCast(y) },
                        .color = .{ bg.r, bg.g, bg.b, bg.a },
                    }) catch {};
                }

                const cell_x = pad.x + x * font.cell_w;
                const cell_y = pad.y + y * font.cell_h;

                // `wide == 2` marks the trailing spacer of a double-width
                // character; its glyph was already drawn by the lead cell, and
                // drawing anything here would overprint it.
                if (!style.attrs.invisible and cell.wide != 2) {
                    if (cell.grapheme) {
                        // Overlay every codepoint of the cluster at the same cell
                        // origin. Combining marks carry bearings that place them
                        // over the base character, so this composes correctly
                        // without needing full shaping.
                        for (screen.graphemes.get(cell.content)) |cp| {
                            self.emitGlyph(cache, font, cell_x, cell_y, cp, fg);
                        }
                    } else if (cell.content != cellmod.Cell.empty and cell.content != ' ') {
                        self.emitGlyph(cache, font, cell_x, cell_y, cell.content, fg);
                    }
                }

                // A hovered link underlines even where the text carries no
                // underline attribute of its own, and in the foreground colour
                // rather than `ul` — the point is to show what a click will act on,
                // not to render an attribute the application asked for.
                const hovered = if (screen.hover) |h| h.contains(line, x) else false;
                if (hovered and style.attrs.underline == .none) {
                    const uy = @as(i64, cell_y) + font.baseline - font.underline_pos;
                    self.solid(
                        cell_x,
                        uy,
                        font.cell_w,
                        @intCast(font.underline_thickness),
                        fg,
                    );
                }

                // Decorations reuse the foreground program as untextured solid
                // rects, so they need no extra pass or shader.
                if (style.attrs.underline != .none) {
                    // TODO(phase 7): curly, dotted and dashed need a shader; all
                    // five styles currently draw as a single solid line.
                    const uy = @as(i64, cell_y) + font.baseline - font.underline_pos;
                    self.solid(
                        cell_x,
                        uy,
                        font.cell_w,
                        @intCast(font.underline_thickness),
                        theme.resolve(style.ul, .ul),
                    );
                }
                if (style.attrs.strike) {
                    const sy = @as(i64, cell_y) + font.baseline - font.strikeout_pos;
                    self.solid(
                        cell_x,
                        sy,
                        font.cell_w,
                        @intCast(font.strikeout_thickness),
                        fg,
                    );
                }
            }
        }
    }

    fn emitGlyph(
        self: *Renderer,
        cache: *GlyphCache,
        font: *const Font,
        cell_x: u32,
        cell_y: u32,
        cp: u32,
        fg: Rgb,
    ) void {
        const glyph = cache.get(cp, 256) orelse return;
        if (glyph.blank) return;

        // fcft reports bearings relative to the pen on the baseline: +x to the
        // right, +y upwards from the baseline.
        const gx = @as(i64, cell_x) + glyph.left;
        const gy = @as(i64, cell_y) + font.baseline - glyph.top;
        self.fg_list.append(self.gpa, .{
            .pos = .{ clampI16(gx), clampI16(gy) },
            .size = .{ glyph.region.w, glyph.region.h },
            .uv = .{ glyph.region.x, glyph.region.y },
            .color = .{ fg.r, fg.g, fg.b, fg.a },
            .flags = if (glyph.kind == .color) flag_color_glyph else 0,
        }) catch {};
    }

    fn solid(self: *Renderer, x: u32, y: i64, w: u32, h: u32, color: Rgb) void {
        self.fg_list.append(self.gpa, .{
            .pos = .{ clampI16(@intCast(x)), clampI16(y) },
            .size = .{ @intCast(w), @intCast(@max(h, 1)) },
            .uv = .{ 0, 0 },
            .color = .{ color.r, color.g, color.b, color.a },
            .flags = flag_solid,
        }) catch {};
    }
};

fn dim(col: Rgb) Rgb {
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(col.r)) * 0.6),
        .g = @intFromFloat(@as(f32, @floatFromInt(col.g)) * 0.6),
        .b = @intFromFloat(@as(f32, @floatFromInt(col.b)) * 0.6),
        .a = col.a,
    };
}

fn clampI16(v: i64) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

fn buildProgram(vs_src: []const u8, fs_src: []const u8) Error!c.GLuint {
    const vs = try compile(c.GL_VERTEX_SHADER, vs_src);
    defer c.glDeleteShader(vs);
    const fs = try compile(c.GL_FRAGMENT_SHADER, fs_src);
    defer c.glDeleteShader(fs);

    const prog = c.glCreateProgram();
    c.glAttachShader(prog, vs);
    c.glAttachShader(prog, fs);
    c.glLinkProgram(prog);

    var ok: c.GLint = 0;
    c.glGetProgramiv(prog, c.GL_LINK_STATUS, &ok);
    if (ok == c.GL_FALSE) {
        var log: [1024]u8 = undefined;
        var len: c.GLsizei = 0;
        c.glGetProgramInfoLog(prog, log.len, &len, &log);
        std.debug.print("shader link failed: {s}\n", .{log[0..@intCast(len)]});
        c.glDeleteProgram(prog);
        return Error.ProgramLink;
    }
    return prog;
}

fn compile(kind: c.GLenum, src: []const u8) Error!c.GLuint {
    const shader = c.glCreateShader(kind);
    const ptr: [*c]const u8 = src.ptr;
    const len: c.GLint = @intCast(src.len);
    c.glShaderSource(shader, 1, &ptr, &len);
    c.glCompileShader(shader);

    var ok: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
    if (ok == c.GL_FALSE) {
        var log: [1024]u8 = undefined;
        var out_len: c.GLsizei = 0;
        c.glGetShaderInfoLog(shader, log.len, &out_len, &log);
        std.debug.print("shader compile failed: {s}\n", .{log[0..@intCast(out_len)]});
        c.glDeleteShader(shader);
        return Error.ShaderCompile;
    }
    return shader;
}

/// Is this hint entirely behind the cell being drawn? Used to advance the moving
/// index in `build`, which relies on hints arriving in reading order.
fn hintEndsBefore(h: Hint, line: usize, x: u32) bool {
    if (h.at.line != line) return h.at.line < line;
    return x >= h.at.x + h.label_len;
}

fn labelChar(h: Hint, line: usize, x: u32) ?u21 {
    if (h.at.line != line) return null;
    if (x < h.at.x or x >= h.at.x + h.label_len) return null;
    return h.label[x - h.at.x];
}
