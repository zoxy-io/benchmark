const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zrk = b.dependency("zrk", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    // zurl replaces the hand-rolled std.http.Client wrapper src/http.zig used
    // to be. It is std-only plus hparse, so it brings no second copy of zio
    // or of a TLS stack into this graph -- which is the property its rule 6
    // exists to guarantee, and the reason it can sit next to zrk here.
    const zurl = b.dependency("zurl", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zrk", .module = zrk.module("zrk") },
            .{ .name = "zio", .module = zio.module("zio") },
            .{ .name = "zurl", .module = zurl.module("zurl") },
        },
    });

    const exe = b.addExecutable(.{ .name = "bench", .root_module = mod });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run bench");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // report/index/notify only -- no zio, and none of suite/remote/ramp/ycs
    // (fleet orchestration and the load ramp), which together are close to
    // half this package. What publish.yml builds: that job renders and
    // deploys a run that already finished measuring, and never touches the
    // fleet, so there is no reason for it to pay to compile the path that
    // does. Not part of the default install step -- ask for it by name
    // (`zig build publish`) so a bare `zig build` (what nightly's musl cross
    // build and `zig build test` both start from) keeps building the FULL
    // `bench`, which both of those still need.
    const publish_mod = b.createModule(.{
        .root_source_file = b.path("src/publish_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zrk", .module = zrk.module("zrk") },
            .{ .name = "zurl", .module = zurl.module("zurl") },
        },
    });
    const publish_exe = b.addExecutable(.{ .name = "bench-publish", .root_module = publish_mod });
    const publish_step = b.step("publish", "Build bench-publish (report/index/notify only)");
    publish_step.dependOn(&b.addInstallArtifact(publish_exe, .{}).step);

    // `zig build test` — analysis.zig carries the port's regression tests, which
    // are the Phase 0 gate against report/report.py.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zrk", .module = zrk.module("zrk") },
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "zurl", .module = zurl.module("zurl") },
            },
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
