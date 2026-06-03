const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_open = b.addExecutable(.{
        .name = "claude-pager-open",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_open.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe_open);

    const exe_cli = b.addExecutable(.{
        .name = "claude-pager-c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe_cli);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
