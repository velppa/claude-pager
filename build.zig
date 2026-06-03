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

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Expose transcript test fixtures to `@embedFile` (they live outside the
    // src/ package root, so they must be wired in as anonymous imports).
    test_mod.addAnonymousImport("fixtures/sample0.jsonl", .{
        .root_source_file = b.path("tests/fixtures/sample0.jsonl"),
    });
    test_mod.addAnonymousImport("fixtures/sample1.jsonl", .{
        .root_source_file = b.path("tests/fixtures/sample1.jsonl"),
    });
    test_mod.addAnonymousImport("fixtures/sample2.jsonl", .{
        .root_source_file = b.path("tests/fixtures/sample2.jsonl"),
    });
    // render.zig parity tests compare against the C-generated plain goldens.
    test_mod.addAnonymousImport("fixtures/sample0.plain.txt", .{
        .root_source_file = b.path("tests/fixtures/sample0.plain.txt"),
    });
    test_mod.addAnonymousImport("fixtures/sample1.plain.txt", .{
        .root_source_file = b.path("tests/fixtures/sample1.plain.txt"),
    });
    test_mod.addAnonymousImport("fixtures/sample2.plain.txt", .{
        .root_source_file = b.path("tests/fixtures/sample2.plain.txt"),
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
