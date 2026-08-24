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
