//! main_open.zig — entrypoint for `claude-pager-open`, the editor shim.
//!
//! Ports main() from bin/claude-pager-open.c:832 MINUS the TurboDraft socket
//! fast path. Resolves the editor (settings.json → VISUAL → EDITOR), guards
//! against self-recursion, then dispatches to the terminal- or GUI-editor path.

const std = @import("std");
const settings = @import("settings.zig");
const editor = @import("editor.zig");
const open = @import("open.zig");
const log = @import("log.zig");

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    log.open();

    // Arg parsing: first positional is the prompt file to edit. Required.
    var iter = init.minimal.args.iterate();
    _ = iter.next(); // argv[0]
    const file = iter.next() orelse {
        std.debug.print("usage: claude-pager-open <file>\n", .{});
        std.process.exit(1);
    };
    // Dupe so it outlives the iterator.
    const file_owned = try alloc.dupe(u8, file);
    defer alloc.free(file_owned);

    const home = getEnv("HOME") orelse {
        // No HOME — open with the system default (best effort) and bail.
        std.process.exit(openSystemDefault(file_owned));
    };

    log.dbg("--- claude-pager-open pid={d} file={s}", .{ std.c.getpid(), file_owned });

    // Resolve editor: CLAUDE_PAGER_EDITOR (env or settings.json) → VISUAL → EDITOR.
    // `resolved` may be borrowed from env (no free) or allocated from settings.
    var settings_editor: ?[]u8 = null;
    defer if (settings_editor) |s| alloc.free(s);

    var resolved: ?[]const u8 = getEnv("CLAUDE_PAGER_EDITOR");
    if (resolved == null or resolved.?.len == 0) {
        settings_editor = settings.editor(alloc, home) catch null;
        resolved = settings_editor;
    }
    if (skipSelf(resolved)) resolved = null;

    if (resolved == null) {
        resolved = getEnv("VISUAL");
        if (skipSelf(resolved)) resolved = null;
    }
    if (resolved == null) {
        resolved = getEnv("EDITOR");
        if (skipSelf(resolved)) resolved = null;
    }

    // Validate the resolved editor exists; otherwise fall back to system default.
    if (resolved) |ed| {
        if (!editor.editorExists(ed)) {
            std.debug.print("claude-pager: editor not found: {s}\n", .{ed});
            resolved = null;
        }
    }

    const ed = resolved orelse {
        std.debug.print("claude-pager: no editor configured — using system default\n", .{});
        std.process.exit(openSystemDefault(file_owned));
    };

    log.dbg("resolved editor={s}", .{ed});

    if (editor.isTerminalEditor(ed)) {
        const rc = try open.terminalEditorPath(alloc, home, ed, file_owned);
        std.process.exit(rc);
    } else {
        const rc = try open.genericEditorPath(alloc, home, ed, file_owned);
        std.process.exit(rc);
    }
}

/// Return true when `cmd` is empty or refers to claude-pager itself (recursion).
fn skipSelf(cmd: ?[]const u8) bool {
    const c = cmd orelse return false;
    return c.len == 0 or editor.isSelf(c);
}

/// Open `file` with the OS default text editor (macOS `open -W -t`). Returns the
/// exit code to propagate. Replaces this process via exec on success.
fn openSystemDefault(file: []const u8) u8 {
    var buf: [4096]u8 = undefined;
    if (file.len + 1 > buf.len) return 1;
    @memcpy(buf[0..file.len], file);
    buf[file.len] = 0;
    const file_z: [*:0]const u8 = @ptrCast(&buf);
    const argv = [_:null]?[*:0]const u8{ "open", "-W", "-t", file_z };
    _ = execvp("open", &argv);
    return 1;
}

/// getenv without allocating, scanning std.c.environ.
fn getEnv(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (e.len > name.len and e[name.len] == '=' and
            std.mem.eql(u8, e[0..name.len], name))
        {
            return e[name.len + 1 ..];
        }
    }
    return null;
}
