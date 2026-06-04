const std = @import("std");
const term = @import("term.zig");
const pager = @import("pager.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var iter = init.minimal.args.iterate();
    _ = iter.next(); // argv0

    var transcript: ?[]const u8 = null;
    var editor_pid: ?std.posix.pid_t = null;
    var ctx_limit: usize = 200000;

    while (iter.next()) |a| {
        if (std.mem.eql(u8, a, "--ctx-limit")) {
            const v = iter.next() orelse return error.MissingCtxLimitValue;
            ctx_limit = try std.fmt.parseInt(usize, v, 10);
        } else if (transcript == null) {
            transcript = try alloc.dupe(u8, a);
        } else if (editor_pid == null) {
            editor_pid = try std.fmt.parseInt(std.posix.pid_t, a, 10);
        }
    }

    const t = transcript orelse {
        std.debug.print("usage: claude-pager-c <transcript.jsonl> [editor_pid] [--ctx-limit N]\n", .{});
        std.process.exit(1);
    };
    defer alloc.free(t);

    const tty = try term.openTty();
    defer _ = std.c.close(tty);
    try pager.runPager(tty, t, editor_pid, ctx_limit);
}
