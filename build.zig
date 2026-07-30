const std = @import("std");

/// Wayland *extension* protocols we generate glue for. `path` is relative to the
/// `wayland-protocols` pkgdatadir.
///
/// The core protocol is deliberately absent: libwayland-dev already ships
/// `wayland-client-protocol.h` and libwayland-client.so already exports every
/// `wl_*_interface` symbol. Running wayland-scanner over wayland.xml as well
/// would duplicate all of them and break the link.
///
/// Protocols are added per-phase rather than all at once, so a missing or moved
/// XML fails the build with an obvious message instead of a link error 20 files
/// later. Remaining ones, from PLAN.md §9:
///
///   phase 4  staging/xdg-activation/xdg-activation-v1.xml
///   phase 7  staging/fractional-scale/fractional-scale-v1.xml
///   phase 7  stable/viewporter/viewporter.xml
const protocols = [_]Protocol{
    .{ .name = "xdg-shell", .path = "stable/xdg-shell/xdg-shell.xml" },
    .{ .name = "xdg-decoration", .path = "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" },
    // The PRIMARY selection — select-to-copy and middle-click-paste.
    .{ .name = "primary-selection", .path = "unstable/primary-selection/primary-selection-unstable-v1.xml" },
    // Pointer cursors without loading an XCursor theme ourselves.
    .{ .name = "cursor-shape", .path = "staging/cursor-shape/cursor-shape-v1.xml" },
    // Not used directly, but cursor-shape-v1's XML references zwp_tablet_tool_v2,
    // so its interface symbol has to exist or the link fails.
    .{ .name = "tablet", .path = "stable/tablet/tablet-v2.xml" },
};

const Protocol = struct {
    name: []const u8,
    path: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    disableFortify(mod);

    // ── Wayland protocol code generation ────────────────────────────────────
    // wayland-scanner turns each protocol XML into a client header (interface
    // declarations, inline request wrappers) plus a "private-code" C file (the
    // wl_interface tables). We compile the latter into the binary and put the
    // former on the include path so src/c.zig can @cInclude it.
    const wp_dir = pkgDataDir(b, "wayland-protocols");

    for (protocols) |proto| {
        const xml = b.pathJoin(&.{ wp_dir, proto.path });

        const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", xml });
        const header_out = header.addOutputFileArg(
            b.fmt("{s}-client-protocol.h", .{proto.name}),
        );
        mod.addIncludePath(header_out.dirname());

        const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", xml });
        const code_out = code.addOutputFileArg(b.fmt("{s}-protocol.c", .{proto.name}));
        mod.addCSourceFile(.{ .file = code_out, .flags = &.{"-std=c11"} });
    }

    // ── System libraries ───────────────────────────────────────────────────
    // Later phases add: xkbcommon-compose (phase 3), harfbuzz / freetype2 when we
    // drop below fcft (phase 7), spng and utf8proc (phase 8).
    //
    // forkpty/openpty are in libc since glibc 2.34, so there is no -lutil here.
    for ([_][]const u8{
        "wayland-client",
        "wayland-egl",
        "EGL",
        "GLESv2",
        "fcft",
        "pixman-1",
        "xkbcommon",
        "utf8proc",
    }) |lib| mod.linkSystemLibrary(lib, .{});

    const exe = b.addExecutable(.{ .name = "maai", .root_module = mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run maai");
    run_step.dependOn(&run_cmd.step);

    // Full suite: links everything, so it can cover font and renderer code.
    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Fast suite: terminal logic only, so it builds and runs in well under a
    // second. This is the one to run on every save while working on the parser,
    // grid, reflow, or URL scanning.
    //
    // It links utf8proc because character widths come from the Unicode tables and
    // reimplementing them in Zig just to keep this target dependency-free would be
    // a lot of code to get subtly wrong. Wayland, EGL and fcft stay out.
    const pure_mod = b.createModule(.{
        .root_source_file = b.path("src/tests_pure.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    disableFortify(pure_mod);
    pure_mod.linkSystemLibrary("utf8proc", .{});
    const pure = b.addTest(.{ .root_module = pure_mod });
    const pure_step = b.step("test-pure", "Run the fast terminal-logic unit tests");
    pure_step.dependOn(&b.addRunArtifact(pure).step);

    // Benchmarks. Same dependency-light shape as the fast tests, so parsing, grid
    // mutation and reflow can be measured — and profiled under perf or callgrind —
    // without a compositor in the picture.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    disableFortify(bench_mod);
    bench_mod.linkSystemLibrary("utf8proc", .{});
    const bench = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    b.installArtifact(bench);
    const bench_run = b.addRunArtifact(bench);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run core benchmarks (use -Doptimize=ReleaseFast)");
    bench_step.dependOn(&bench_run.step);
    // Install *as part of the bench step*, not only as part of the default step.
    //
    // `installArtifact` attaches to the default step, so `zig build bench
    // -Doptimize=ReleaseFast` ran the optimised binary from the cache while leaving a
    // stale **Debug** one in zig-out/bin. Anyone profiling `zig-out/bin/bench` — which
    // the comment above suggests doing — measured the wrong build entirely. Cost me a
    // round of callgrind output that meant nothing.
    bench_step.dependOn(&b.addInstallArtifact(bench, .{}).step);
}

/// Turn glibc's `_FORTIFY_SOURCE` wrappers off for a module's C translation.
///
/// Zig defines `-D_FORTIFY_SOURCE=2` in **ReleaseSafe only**. glibc's fortified
/// `open`/`openat` (bits/fcntl2.h) count their varargs with `__va_arg_pack_len`,
/// which translate-c cannot evaluate, so it takes the "too many arguments" branch
/// and the `@cImport` in src/c.zig fails with a wall of `__open_too_many_args`
/// errors. Debug and ReleaseFast build fine, which is why `--optimize ReleaseSafe`
/// was the only thing broken.
///
/// Nothing meaningful is given up: `_FORTIFY_SOURCE` only ever covered the
/// generated Wayland protocol .c files, and Zig code is not affected by it —
/// ReleaseSafe's own runtime safety checks are untouched.
fn disableFortify(mod: *std.Build.Module) void {
    mod.addCMacro("_FORTIFY_SOURCE", "0");
}

/// Ask pkg-config where a package keeps its data files. Runs at configure time,
/// so a missing dev package fails here with pkg-config's own error rather than
/// producing a confusing "file not found" mid-build.
fn pkgDataDir(b: *std.Build, pkg: []const u8) []const u8 {
    const out = b.run(&.{ "pkg-config", "--variable=pkgdatadir", pkg });
    return std.mem.trim(u8, out, " \n\r\t");
}
