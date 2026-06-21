const std = @import("std");

/// Compute the v0.N.9OCTAL version at configure time.
///   N      = total commit count on HEAD.
///   9OCTAL = the full commit SHA re-encoded base-16 → base-8, prefixed with
///            `9` so the (otherwise 0-7 only) octal run is self-identifying and
///            decodable back to the SHA.
/// Falls back to "v0.0.9dev" outside a git checkout.
fn computeVersion(b: *std.Build) []const u8 {
    const script =
        \\set -e
        \\N=$(git rev-list --count HEAD)
        \\SHA=$(git rev-parse HEAD)
        \\OCT=$(echo "obase=8; ibase=16; $(echo "$SHA" | tr a-z A-Z)" | bc | tr -d '\\\n')
        \\printf 'v0.%s.9%s' "$N" "$OCT"
    ;
    var code: u8 = undefined;
    const out = b.runAllowFail(
        &.{ "sh", "-c", script },
        &code,
        .ignore,
    ) catch return "v0.0.9dev";
    // runAllowFail returns stdout only when the child exited 0.
    if (out.len == 0) return "v0.0.9dev";
    return out;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const opts = b.addOptions();
    opts.addOption([]const u8, "version", computeVersion(b));
    // Default to ReleaseSmall (a terminal pager — favor small binaries).
    // Override per build, e.g. `zig build -Doptimize=Debug`.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimize mode (default ReleaseSmall)",
    ) orelse .ReleaseSmall;
    // Strip the shipped executables in any release build (no effect on Debug).
    const strip = optimize != .Debug;

    const exe_open = b.addExecutable(.{
        .name = "claude-pager",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_open.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    exe_open.root_module.addOptions("build_options", opts);
    b.installArtifact(exe_open);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        // Always run tests with full runtime safety, regardless of the
        // executables' release default.
        .optimize = .Debug,
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
    // render.zig parity tests compare against the plain-text golden fixtures.
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
