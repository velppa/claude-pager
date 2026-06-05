//! settings.zig — Read editor configuration from ~/.claude/settings.json.
//!
//! Keys read from the `env` block:
//!   CLAUDE_PAGER_EDITOR
//!   CLAUDE_PAGER_EDITOR_TYPE
//!   CLAUDE_PAGER_BENCH
//!
//! The settings file structure: { "env": { "CLAUDE_PAGER_EDITOR": "...", ... } }

const std = @import("std");

/// Read `env.<key>` from `settings_json` bytes.
/// Returns null if the file is not valid JSON, "env" is absent, or the key is
/// absent. Caller owns the returned slice.
pub fn envValue(alloc: std.mem.Allocator, settings_json: []const u8, key: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, settings_json, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const env_val = root.object.get("env") orelse return null;
    if (env_val != .object) return null;

    const kv = env_val.object.get(key) orelse return null;
    if (kv != .string) return null;

    return try alloc.dupe(u8, kv.string);
}

/// Read the settings file at `<home>/.claude/settings.json` and return
/// the value of `env.<key>`, or null if absent / file missing.
/// Caller owns the returned slice.
fn readKey(alloc: std.mem.Allocator, home: []const u8, key: []const u8) !?[]u8 {
    // Build path: <home>/.claude/settings.json
    const path = try std.fmt.allocPrint(alloc, "{s}/.claude/settings.json", .{home});
    defer alloc.free(path);

    // Read the file using the same std.Io pattern used throughout this codebase.
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return null;
    defer alloc.free(bytes);

    return envValue(alloc, bytes, key);
}

/// Read `env.CLAUDE_PAGER_EDITOR` from ~/.claude/settings.json.
/// Caller owns the returned slice.
pub fn editor(alloc: std.mem.Allocator, home: []const u8) !?[]u8 {
    return readKey(alloc, home, "CLAUDE_PAGER_EDITOR");
}

/// Read `env.CLAUDE_PAGER_EDITOR_TYPE` from ~/.claude/settings.json.
/// Caller owns the returned slice.
pub fn editorType(alloc: std.mem.Allocator, home: []const u8) !?[]u8 {
    return readKey(alloc, home, "CLAUDE_PAGER_EDITOR_TYPE");
}

/// Read `env.CLAUDE_PAGER_BENCH` from ~/.claude/settings.json.
/// Caller owns the returned slice.
pub fn benchMode(alloc: std.mem.Allocator, home: []const u8) !?[]u8 {
    return readKey(alloc, home, "CLAUDE_PAGER_BENCH");
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "envValue reads a present key" {
    const json =
        \\{"env":{"CLAUDE_PAGER_EDITOR":"emacsclient","CLAUDE_PAGER_EDITOR_TYPE":"gui"},"other":1}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try envValue(arena.allocator(), json, "CLAUDE_PAGER_EDITOR");
    try std.testing.expectEqualStrings("emacsclient", v.?);
}

test "envValue reads second key" {
    const json =
        \\{"env":{"CLAUDE_PAGER_EDITOR":"emacsclient","CLAUDE_PAGER_EDITOR_TYPE":"gui"},"other":1}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try envValue(arena.allocator(), json, "CLAUDE_PAGER_EDITOR_TYPE");
    try std.testing.expectEqualStrings("gui", v.?);
}

test "envValue returns null for missing key" {
    const json =
        \\{"env":{"X":"y"}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try envValue(arena.allocator(), json, "NOPE")) == null);
}

test "envValue returns null when env absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try envValue(arena.allocator(), "{}", "K")) == null);
}

test "envValue returns null for invalid JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try envValue(arena.allocator(), "not json", "K")) == null);
}

test "envValue reads bench key" {
    const json =
        \\{"env":{"CLAUDE_PAGER_BENCH":"1"}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try envValue(arena.allocator(), json, "CLAUDE_PAGER_BENCH");
    try std.testing.expectEqualStrings("1", v.?);
}
