//! VT500-series escape sequence parser.
//!
//! The state machine is Paul Williams' DEC ANSI parser, implemented in full so
//! that phase 2 only has to fill in dispatch handlers rather than restructure
//! anything. UTF-8 decoding is folded into the ground state.
//!
//! The handler is a comptime duck-typed pointer, so dispatch is a direct call
//! with no vtable. Phase 7 adds `fastpath.zig`, which bypasses the per-byte switch
//! for runs of printable ASCII — the single biggest throughput win available.

const std = @import("std");

pub const max_params = 32;
pub const max_intermediates = 4;
pub const max_osc = 4096;

/// CSI/DCS parameters. `is_sub[i]` marks a parameter that was introduced by a
/// colon rather than a semicolon, which is what distinguishes `SGR 4:3` (curly
/// underline) from `SGR 4;3` (underline, then italic).
pub const Params = struct {
    values: [max_params]u16 = @splat(0),
    is_sub: [max_params]bool = @splat(false),
    /// Whether the parameter at this index was explicitly written. An omitted
    /// parameter means "use the default", which is not always 0.
    present: [max_params]bool = @splat(false),
    len: usize = 0,

    pub fn get(self: *const Params, i: usize, fallback: u16) u16 {
        if (i >= self.len or !self.present[i]) return fallback;
        return self.values[i];
    }

    pub fn slice(self: *const Params) []const u16 {
        return self.values[0..self.len];
    }
};

const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    osc_string,
    // ESC, APC and PM strings are consumed and dropped until phase 8 needs APC
    // for the Kitty graphics protocol.
    sos_pm_apc_string,
};

pub fn Parser(comptime H: type) type {
    return struct {
        const Self = @This();

        handler: *H,
        state: State = .ground,

        params: Params = .{},
        intermediates: [max_intermediates]u8 = @splat(0),
        intermediate_len: usize = 0,
        /// CSI private marker (`<`, `=`, `>`, `?`), 0 if none.
        private: u8 = 0,
        /// Set when a sequence has overflowed its limits; it is parsed to
        /// completion then dropped, per the DEC state machine.
        ignoring: bool = false,

        osc_buf: [max_osc]u8 = undefined,
        osc_len: usize = 0,

        // UTF-8 decode state for the ground state.
        utf8_cp: u32 = 0,
        utf8_remaining: u8 = 0,
        /// Smallest codepoint the in-progress sequence length may legally encode,
        /// used to reject overlong forms.
        utf8_min: u32 = 0,

        pub fn init(handler: *H) Self {
            return .{ .handler = handler };
        }

        pub fn feed(self: *Self, bytes: []const u8) void {
            for (bytes) |b| self.step(b);
        }

        fn step(self: *Self, b: u8) void {
            // ESC, CAN and SUB abort whatever is in progress from any state.
            switch (b) {
                0x1b => {
                    // Inside a string, ESC terminates it (as the first half of ST).
                    switch (self.state) {
                        .osc_string => self.endOsc(),
                        .dcs_passthrough => self.handler.dcsUnhook(),
                        else => {},
                    }
                    self.clear();
                    self.state = .escape;
                    return;
                },
                0x18, 0x1a => {
                    if (self.state == .dcs_passthrough) self.handler.dcsUnhook();
                    self.handler.execute(b);
                    self.state = .ground;
                    return;
                },
                else => {},
            }

            switch (self.state) {
                .ground => self.ground(b),
                .escape => self.escape(b),
                .escape_intermediate => self.escapeIntermediate(b),
                .csi_entry => self.csiEntry(b),
                .csi_param => self.csiParam(b),
                .csi_intermediate => self.csiIntermediate(b),
                .csi_ignore => {
                    if (b >= 0x40 and b <= 0x7e) self.state = .ground;
                },
                .dcs_entry => self.dcsEntry(b),
                .dcs_param => self.dcsParam(b),
                .dcs_intermediate => self.dcsIntermediate(b),
                .dcs_passthrough => {
                    if (isC0(b)) self.handler.execute(b) else self.handler.dcsPut(b);
                },
                .dcs_ignore => {},
                .osc_string => self.oscString(b),
                .sos_pm_apc_string => {},
            }
        }

        // ── ground ──────────────────────────────────────────────────────────

        fn ground(self: *Self, b: u8) void {
            if (self.utf8_remaining > 0) {
                if (b & 0xc0 != 0x80) {
                    // Malformed: emit a replacement for the truncated sequence and
                    // reprocess this byte as a fresh one.
                    self.utf8_remaining = 0;
                    self.handler.print(0xfffd);
                    self.ground(b);
                    return;
                }
                self.utf8_cp = (self.utf8_cp << 6) | (b & 0x3f);
                self.utf8_remaining -= 1;
                if (self.utf8_remaining == 0) {
                    // Reject what the lead-byte ranges alone cannot: non-minimal
                    // encodings (E0 80 80 for U+0000), UTF-16 surrogates, and
                    // anything past U+10FFFF. All are invalid UTF-8, and this is
                    // untrusted remote output.
                    const cp = self.utf8_cp;
                    const valid = cp >= self.utf8_min and
                        cp <= 0x10ffff and
                        !(cp >= 0xd800 and cp <= 0xdfff);
                    self.handler.print(if (valid) @intCast(cp) else 0xfffd);
                }
                return;
            }

            switch (b) {
                0x00...0x17, 0x19, 0x1c...0x1f => self.handler.execute(b),
                0x20...0x7e => self.handler.print(b),
                // DEL is discarded by convention.
                0x7f => {},
                0xc2...0xdf => {
                    self.utf8_cp = b & 0x1f;
                    self.utf8_remaining = 1;
                    self.utf8_min = 0x80;
                },
                0xe0...0xef => {
                    self.utf8_cp = b & 0x0f;
                    self.utf8_remaining = 2;
                    self.utf8_min = 0x800;
                },
                0xf0...0xf4 => {
                    self.utf8_cp = b & 0x07;
                    self.utf8_remaining = 3;
                    self.utf8_min = 0x10000;
                },
                // 0x80-0xc1 and 0xf5-0xff can never start a valid sequence.
                else => self.handler.print(0xfffd),
            }
        }

        // ── escape ──────────────────────────────────────────────────────────

        fn escape(self: *Self, b: u8) void {
            switch (b) {
                0x00...0x17, 0x19, 0x1c...0x1f => self.handler.execute(b),
                0x20...0x2f => {
                    self.collect(b);
                    self.state = .escape_intermediate;
                },
                '[' => self.state = .csi_entry,
                ']' => {
                    self.osc_len = 0;
                    self.state = .osc_string;
                },
                'P' => self.state = .dcs_entry,
                'X', '^', '_' => self.state = .sos_pm_apc_string,
                0x30...0x4f, 0x51...0x57, 0x59, 0x5a, 0x5c, 0x60...0x7e => {
                    self.handler.escDispatch(b, self.intermediates[0..self.intermediate_len]);
                    self.state = .ground;
                },
                else => self.state = .ground,
            }
        }

        fn escapeIntermediate(self: *Self, b: u8) void {
            switch (b) {
                0x00...0x17, 0x19, 0x1c...0x1f => self.handler.execute(b),
                0x20...0x2f => self.collect(b),
                else => {
                    self.handler.escDispatch(b, self.intermediates[0..self.intermediate_len]);
                    self.state = .ground;
                },
            }
        }

        // ── CSI ─────────────────────────────────────────────────────────────

        fn csiEntry(self: *Self, b: u8) void {
            switch (b) {
                0x00...0x17, 0x19, 0x1c...0x1f => self.handler.execute(b),
                '0'...'9', ';', ':' => {
                    self.state = .csi_param;
                    self.csiParam(b);
                },
                0x3c...0x3f => {
                    self.private = b;
                    self.state = .csi_param;
                },
                0x20...0x2f => {
                    self.collect(b);
                    self.state = .csi_intermediate;
                },
                0x40...0x7e => {
                    self.dispatchCsi(b);
                    self.state = .ground;
                },
                else => self.state = .csi_ignore,
            }
        }

        fn csiParam(self: *Self, b: u8) void {
            switch (b) {
                0x00...0x17, 0x19, 0x1c...0x1f => self.handler.execute(b),
                '0'...'9' => {
                    if (self.params.len == 0) self.params.len = 1;
                    const i = self.params.len - 1;
                    self.params.present[i] = true;
                    // Clamp instead of wrapping; 16383 is xterm's documented cap.
                    const v = @as(u32, self.params.values[i]) * 10 + (b - '0');
                    self.params.values[i] = @intCast(@min(v, 16383));
                },
                ';', ':' => {
                    if (self.params.len >= max_params) {
                        self.state = .csi_ignore;
                        return;
                    }
                    if (self.params.len == 0) self.params.len = 1;
                    self.params.len += 1;
                    self.params.is_sub[self.params.len - 1] = (b == ':');
                },
                0x20...0x2f => {
                    self.collect(b);
                    self.state = .csi_intermediate;
                },
                0x40...0x7e => {
                    self.dispatchCsi(b);
                    self.state = .ground;
                },
                else => self.state = .csi_ignore,
            }
        }

        fn csiIntermediate(self: *Self, b: u8) void {
            switch (b) {
                0x00...0x17, 0x19, 0x1c...0x1f => self.handler.execute(b),
                0x20...0x2f => self.collect(b),
                0x40...0x7e => {
                    self.dispatchCsi(b);
                    self.state = .ground;
                },
                else => self.state = .csi_ignore,
            }
        }

        fn dispatchCsi(self: *Self, final: u8) void {
            if (self.ignoring) return;
            self.handler.csiDispatch(
                final,
                self.private,
                self.intermediates[0..self.intermediate_len],
                &self.params,
            );
        }

        // ── DCS ─────────────────────────────────────────────────────────────
        // States are complete so phase 8 can hang Sixel off dcsHook/Put/Unhook.

        fn dcsEntry(self: *Self, b: u8) void {
            switch (b) {
                '0'...'9', ';', ':' => {
                    self.state = .dcs_param;
                    self.dcsParam(b);
                },
                0x3c...0x3f => {
                    self.private = b;
                    self.state = .dcs_param;
                },
                0x20...0x2f => {
                    self.collect(b);
                    self.state = .dcs_intermediate;
                },
                0x40...0x7e => {
                    self.handler.dcsHook(b, self.private, &self.params);
                    self.state = .dcs_passthrough;
                },
                else => self.state = .dcs_ignore,
            }
        }

        fn dcsParam(self: *Self, b: u8) void {
            switch (b) {
                '0'...'9' => {
                    if (self.params.len == 0) self.params.len = 1;
                    const i = self.params.len - 1;
                    self.params.present[i] = true;
                    const v = @as(u32, self.params.values[i]) * 10 + (b - '0');
                    self.params.values[i] = @intCast(@min(v, 16383));
                },
                ';', ':' => {
                    if (self.params.len >= max_params) {
                        self.state = .dcs_ignore;
                        return;
                    }
                    if (self.params.len == 0) self.params.len = 1;
                    self.params.len += 1;
                    self.params.is_sub[self.params.len - 1] = (b == ':');
                },
                0x20...0x2f => {
                    self.collect(b);
                    self.state = .dcs_intermediate;
                },
                0x40...0x7e => {
                    self.handler.dcsHook(b, self.private, &self.params);
                    self.state = .dcs_passthrough;
                },
                else => self.state = .dcs_ignore,
            }
        }

        fn dcsIntermediate(self: *Self, b: u8) void {
            switch (b) {
                0x20...0x2f => self.collect(b),
                0x40...0x7e => {
                    self.handler.dcsHook(b, self.private, &self.params);
                    self.state = .dcs_passthrough;
                },
                else => self.state = .dcs_ignore,
            }
        }

        // ── OSC ─────────────────────────────────────────────────────────────

        fn oscString(self: *Self, b: u8) void {
            switch (b) {
                // BEL is the legacy terminator; ST (ESC \) is handled in step().
                0x07 => {
                    self.endOsc();
                    self.state = .ground;
                },
                else => {
                    if (self.osc_len < max_osc) {
                        self.osc_buf[self.osc_len] = b;
                        self.osc_len += 1;
                    }
                },
            }
        }

        fn endOsc(self: *Self) void {
            if (self.osc_len > 0) self.handler.oscDispatch(self.osc_buf[0..self.osc_len]);
            self.osc_len = 0;
        }

        // ── helpers ─────────────────────────────────────────────────────────

        fn collect(self: *Self, b: u8) void {
            if (self.intermediate_len >= max_intermediates) {
                self.ignoring = true;
                return;
            }
            self.intermediates[self.intermediate_len] = b;
            self.intermediate_len += 1;
        }

        fn clear(self: *Self) void {
            self.params = .{};
            self.intermediate_len = 0;
            self.private = 0;
            self.ignoring = false;
        }

        fn isC0(b: u8) bool {
            return b <= 0x17 or b == 0x19 or (b >= 0x1c and b <= 0x1f);
        }
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

const Recorder = struct {
    const Event = union(enum) {
        print: u21,
        execute: u8,
        csi: struct { final: u8, private: u8, params: [4]u16, len: usize },
        esc: u8,
        osc: []const u8,
    };

    events: std.ArrayList(Event) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *Recorder) void {
        self.events.deinit(self.gpa);
    }

    pub fn print(self: *Recorder, cp: u21) void {
        self.events.append(self.gpa, .{ .print = cp }) catch unreachable;
    }
    pub fn execute(self: *Recorder, b: u8) void {
        self.events.append(self.gpa, .{ .execute = b }) catch unreachable;
    }
    pub fn csiDispatch(self: *Recorder, final: u8, private: u8, _: []const u8, params: *const Params) void {
        var p: [4]u16 = @splat(0);
        for (0..@min(4, params.len)) |i| p[i] = params.values[i];
        self.events.append(self.gpa, .{ .csi = .{
            .final = final,
            .private = private,
            .params = p,
            .len = params.len,
        } }) catch unreachable;
    }
    pub fn escDispatch(self: *Recorder, final: u8, _: []const u8) void {
        self.events.append(self.gpa, .{ .esc = final }) catch unreachable;
    }
    pub fn oscDispatch(self: *Recorder, data: []const u8) void {
        self.events.append(self.gpa, .{ .osc = data }) catch unreachable;
    }
    pub fn dcsHook(_: *Recorder, _: u8, _: u8, _: *const Params) void {}
    pub fn dcsPut(_: *Recorder, _: u8) void {}
    pub fn dcsUnhook(_: *Recorder) void {}
};

fn recorderFor(gpa: std.mem.Allocator, input: []const u8, rec: *Recorder) void {
    rec.* = .{ .gpa = gpa };
    var p = Parser(Recorder).init(rec);
    p.feed(input);
}

test "printable ASCII becomes print events" {
    var rec: Recorder = undefined;
    recorderFor(std.testing.allocator, "hi", &rec);
    defer rec.deinit();

    try std.testing.expectEqual(@as(usize, 2), rec.events.items.len);
    try std.testing.expectEqual(@as(u21, 'h'), rec.events.items[0].print);
    try std.testing.expectEqual(@as(u21, 'i'), rec.events.items[1].print);
}

test "CSI parameters, defaults and private markers" {
    var rec: Recorder = undefined;
    recorderFor(std.testing.allocator, "\x1b[1;32m\x1b[?25l\x1b[H", &rec);
    defer rec.deinit();

    try std.testing.expectEqual(@as(usize, 3), rec.events.items.len);

    const sgr = rec.events.items[0].csi;
    try std.testing.expectEqual(@as(u8, 'm'), sgr.final);
    try std.testing.expectEqual(@as(u16, 1), sgr.params[0]);
    try std.testing.expectEqual(@as(u16, 32), sgr.params[1]);

    const dec = rec.events.items[1].csi;
    try std.testing.expectEqual(@as(u8, 'l'), dec.final);
    try std.testing.expectEqual(@as(u8, '?'), dec.private);
    try std.testing.expectEqual(@as(u16, 25), dec.params[0]);

    // CUP with no parameters at all must report length 0 so the handler applies
    // the default of row 1, column 1 rather than row 0.
    const cup = rec.events.items[2].csi;
    try std.testing.expectEqual(@as(u8, 'H'), cup.final);
    try std.testing.expectEqual(@as(usize, 0), cup.len);
}

test "UTF-8 multibyte sequences decode to one codepoint" {
    var rec: Recorder = undefined;
    // é (2 bytes), € (3 bytes), 😀 (4 bytes)
    recorderFor(std.testing.allocator, "é€😀", &rec);
    defer rec.deinit();

    try std.testing.expectEqual(@as(usize, 3), rec.events.items.len);
    try std.testing.expectEqual(@as(u21, 0xe9), rec.events.items[0].print);
    try std.testing.expectEqual(@as(u21, 0x20ac), rec.events.items[1].print);
    try std.testing.expectEqual(@as(u21, 0x1f600), rec.events.items[2].print);
}

test "truncated UTF-8 yields a replacement char and resyncs" {
    var rec: Recorder = undefined;
    // Lead byte of a 3-byte sequence, then an ASCII 'A' instead of a continuation.
    recorderFor(std.testing.allocator, "\xe2A", &rec);
    defer rec.deinit();

    try std.testing.expectEqual(@as(usize, 2), rec.events.items.len);
    try std.testing.expectEqual(@as(u21, 0xfffd), rec.events.items[0].print);
    try std.testing.expectEqual(@as(u21, 'A'), rec.events.items[1].print);
}

test "invalid UTF-8 encodings are rejected rather than passed through" {
    // Non-minimal ("overlong") forms and UTF-16 surrogates are invalid UTF-8, and
    // this is untrusted remote output — the lead-byte ranges alone do not catch them.
    const cases = [_][]const u8{
        "\xe0\x80\x80", // overlong encoding of U+0000
        "\xe0\x9f\xbf", // overlong encoding of U+07FF
        "\xed\xa0\x80", // U+D800, a high surrogate
        "\xed\xbf\xbf", // U+DFFF, a low surrogate
        "\xf0\x80\x80\x80", // overlong 4-byte form
    };
    for (cases) |input| {
        var rec: Recorder = undefined;
        recorderFor(std.testing.allocator, input, &rec);
        defer rec.deinit();
        try std.testing.expectEqual(@as(usize, 1), rec.events.items.len);
        try std.testing.expectEqual(@as(u21, 0xfffd), rec.events.items[0].print);
    }
}

test "valid sequences at the edges of each length still decode" {
    const cases = [_]struct { bytes: []const u8, cp: u21 }{
        .{ .bytes = "\xc2\x80", .cp = 0x80 }, // shortest 2-byte
        .{ .bytes = "\xe0\xa0\x80", .cp = 0x800 }, // shortest 3-byte
        .{ .bytes = "\xef\xbf\xbf", .cp = 0xffff }, // longest 3-byte
        .{ .bytes = "\xf0\x90\x80\x80", .cp = 0x10000 }, // shortest 4-byte
        .{ .bytes = "\xf4\x8f\xbf\xbf", .cp = 0x10ffff }, // highest codepoint
    };
    for (cases) |case| {
        var rec: Recorder = undefined;
        recorderFor(std.testing.allocator, case.bytes, &rec);
        defer rec.deinit();
        try std.testing.expectEqual(@as(usize, 1), rec.events.items.len);
        try std.testing.expectEqual(case.cp, rec.events.items[0].print);
    }
}

test "OSC terminated by BEL and by ST both dispatch" {
    {
        var rec: Recorder = undefined;
        recorderFor(std.testing.allocator, "\x1b]0;title\x07", &rec);
        defer rec.deinit();
        try std.testing.expectEqualStrings("0;title", rec.events.items[0].osc);
    }
    {
        var rec: Recorder = undefined;
        recorderFor(std.testing.allocator, "\x1b]2;other\x1b\\", &rec);
        defer rec.deinit();
        try std.testing.expectEqualStrings("2;other", rec.events.items[0].osc);
    }
}

test "colon sub-parameters are distinguished from semicolons" {
    var rec: Recorder = undefined;
    recorderFor(std.testing.allocator, "\x1b[4:3m", &rec);
    defer rec.deinit();

    const csi = rec.events.items[0].csi;
    try std.testing.expectEqual(@as(usize, 2), csi.len);
    try std.testing.expectEqual(@as(u16, 4), csi.params[0]);
    try std.testing.expectEqual(@as(u16, 3), csi.params[1]);
}

test "C0 controls inside a CSI are executed without breaking the sequence" {
    var rec: Recorder = undefined;
    recorderFor(std.testing.allocator, "\x1b[1\r2m", &rec);
    defer rec.deinit();

    try std.testing.expectEqual(@as(u8, '\r'), rec.events.items[0].execute);
    const csi = rec.events.items[1].csi;
    try std.testing.expectEqual(@as(u8, 'm'), csi.final);
    try std.testing.expectEqual(@as(u16, 12), csi.params[0]);
}

test "parameter values clamp rather than overflow" {
    var rec: Recorder = undefined;
    recorderFor(std.testing.allocator, "\x1b[99999999m", &rec);
    defer rec.deinit();
    try std.testing.expectEqual(@as(u16, 16383), rec.events.items[0].csi.params[0]);
}
