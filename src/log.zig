// log.zig — debug logging for claude-pager.
// Debug-logging helper (PDBG / dbg_open pattern).
//
// Gate: the open binary sets _CLAUDE_PAGER_T0_US before the pager runs,
// so that env var being present signals that the debug session is active.
// Log file: /tmp/claude-pager-open.log  (same path as C).

const std = @import("std");
const builtin = @import("builtin");

// Global C FILE handle; null means logging is disabled.
var g_file: ?*std.c.FILE = null;
// Start time in microseconds for elapsed-ms timestamps.
var g_t0_us: i64 = 0;

/// Open the debug log if the gating env var (_CLAUDE_PAGER_T0_US) is set.
/// No-op if already open or if the env var is absent.
pub fn open() void {
    if (g_file != null) return;

    // Look up _CLAUDE_PAGER_T0_US in the environment without allocating.
    const t0_str = getenv("_CLAUDE_PAGER_T0_US") orelse return;

    // Parse the stored start-time so our timestamps are relative to the
    // same epoch the launcher records.
    g_t0_us = std.fmt.parseInt(i64, t0_str, 10) catch nowUs();

    g_file = std.c.fopen("/tmp/claude-pager-open.log", "a");
}

/// Write a timestamped formatted line to the debug log.
/// No-op if the log is not open.
pub fn dbg(comptime fmt: []const u8, args: anytype) void {
    const f = g_file orelse return;
    const elapsed = @as(f64, @floatFromInt(nowUs() - g_t0_us)) / 1000.0;
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d:7.2}ms] " ++ fmt ++ "\n", .{elapsed} ++ args) catch return;
    _ = std.c.fwrite(line.ptr, 1, line.len, f);
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn nowUs() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1_000_000 + @as(i64, tv.usec);
}

/// Look up an env var without allocating by scanning std.c.environ directly.
/// Returns a slice into the existing memory; lifetime is the process lifetime.
fn getenv(name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .wasi) return null;
    const envp = std.c.environ;
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const kv = std.mem.span(entry);
        if (std.mem.startsWith(u8, kv, name)) {
            if (kv.len > name.len and kv[name.len] == '=') {
                return kv[name.len + 1 ..];
            }
        }
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "dbg is a no-op when log unopened" {
    // Without calling open() (env unset in test runner), dbg must not crash.
    dbg("hello {d}", .{1});
    try std.testing.expect(true);
}
