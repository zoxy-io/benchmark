const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zrk = b.dependency("zrk", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    // zurl is std-only plus hparse: no second zio or TLS stack in this graph.
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

    // report/index/notify only, without zio or the fleet path, for
    // publish.yml. Not installed by default: a bare `zig build` must still
    // produce the full `bench` that nightly and tests need.
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

    // `zig build test`; analysis.zig carries the report.py regression tests.
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
