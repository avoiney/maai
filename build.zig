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
///   phase 3  unstable/primary-selection/primary-selection-unstable-v1.xml
///   phase 3  staging/cursor-shape/cursor-shape-v1.xml  (also needs tablet-v2,
///            whose types cursor-shape's XML references)
///   phase 4  staging/xdg-activation/xdg-activation-v1.xml
///   phase 7  staging/fractional-scale/fractional-scale-v1.xml
///   phase 7  stable/viewporter/viewporter.xml
const protocols = [_]Protocol{
    .{ .name = "xdg-shell", .path = "stable/xdg-shell/xdg-shell.xml" },
    .{ .name = "xdg-decoration", .path = "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" },
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
    }) |lib| mod.linkSystemLibrary(lib, .{});

    const exe = b.addExecutable(.{ .name = "myterm", .root_module = mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run myterm");
    run_step.dependOn(&run_cmd.step);

    // Full suite: links everything, so it can cover font and renderer code.
    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Pure-Zig suite: no C libraries, so it builds and runs in well under a
    // second. This is the one to run on every save while working on the parser,
    // grid, reflow, or URL scanning.
    const pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const pure_step = b.step("test-pure", "Run unit tests that need no C libraries");
    pure_step.dependOn(&b.addRunArtifact(pure).step);
}

/// Ask pkg-config where a package keeps its data files. Runs at configure time,
/// so a missing dev package fails here with pkg-config's own error rather than
/// producing a confusing "file not found" mid-build.
fn pkgDataDir(b: *std.Build, pkg: []const u8) []const u8 {
    const out = b.run(&.{ "pkg-config", "--variable=pkgdatadir", pkg });
    return std.mem.trim(u8, out, " \n\r\t");
}
