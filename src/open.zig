//! open.zig — the editor-launcher core for claude-pager-open.
//!
//! C-g flow: resolve the session transcript, render it to plain text (shared
//! with the editor via CLAUDE_PAGER_RENDER_FILE), print that summary statically
//! to the terminal, then launch the editor and wait. There is NO interactive
//! pager — no mouse tracking, no scroll loop, no clickable-URL rewriting — so
//! the terminal's native scrollback/selection are left untouched.
//!
//!   findTranscript                 — locate the session transcript by session id
//!   maybeRenderTranscript          — render to plain text + export render file
//!   printSummary                   — write the rendered summary to /dev/tty
//!   spawnEditor / terminalEditorPath / genericEditorPath — launch the editor

const std = @import("std");
const render_plain = @import("render_plain.zig");
const term = @import("term.zig");
const log = @import("log.zig");

// libc functions not surfaced by std in Zig 0.16.
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn fork() std.c.pid_t;

// ── Transcript finding (pure, no process spawns) ────────────────────────────

/// Locate the current session's transcript under `<home>/.claude/projects/...`,
/// or null when it can't be identified. The editor is spawned with only
/// CLAUDE_CODE_BRIDGE_SESSION_ID; Claude Code's session registry maps that to the
/// session UUID that names the transcript. Resolution is exact — never
/// cwd/newest-jsonl guessing — so an unidentified session yields "no transcript"
/// rather than another session's conversation. Caller owns the slice.
pub fn findTranscript(alloc: std.mem.Allocator, home: []const u8) !?[]u8 {
    // Some contexts expose the UUID directly.
    if (getEnv("CLAUDE_CODE_SESSION_ID")) |sid| {
        if (uuidValid(sid)) {
            if (try transcriptForUuid(alloc, home, sid)) |p| return p;
        }
    }
    // The editor only gets the bridge id; look up its UUID in the registry.
    if (try uuidFromBridge(alloc, home)) |uuid| {
        defer alloc.free(uuid);
        return transcriptForUuid(alloc, home, uuid);
    }
    return null;
}

/// A session id is a bare UUID; anything with a path separator (or NUL) is
/// rejected so it can never escape the projects directory when interpolated.
fn uuidValid(sid: []const u8) bool {
    if (sid.len == 0) return false;
    for (sid) |c| if (c == '/' or c == 0) return false;
    return true;
}

/// Map CLAUDE_CODE_BRIDGE_SESSION_ID to the session UUID via Claude Code's
/// session registry (~/.claude/sessions/<pid>.json, each carrying bridgeSessionId
/// and sessionId). Returns the UUID, or null when the bridge id is unset or no
/// registry entry matches. Caller owns the slice.
fn uuidFromBridge(alloc: std.mem.Allocator, home: []const u8) !?[]u8 {
    const bid = getEnv("CLAUDE_CODE_BRIDGE_SESSION_ID") orelse return null;
    if (bid.len == 0) return null;

    const sessions_dir = try std.fmt.allocPrint(alloc, "{s}/.claude/sessions", .{home});
    defer alloc.free(sessions_dir);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sd = std.Io.Dir.cwd().openDir(io, sessions_dir, .{ .iterate = true }) catch return null;
    defer sd.close(io);

    var it = sd.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ sessions_dir, entry.name });
        defer alloc.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(65536)) catch continue;
        defer alloc.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const b = obj.get("bridgeSessionId") orelse continue;
        if (b != .string or !std.mem.eql(u8, b.string, bid)) continue;
        const s = obj.get("sessionId") orelse continue;
        if (s != .string or !uuidValid(s.string)) continue;
        return try alloc.dupe(u8, s.string);
    }
    return null;
}

/// Locate <uuid>.jsonl under any project dir (the session's cwd may differ from
/// the current one). Returns null when no matching file exists.
fn transcriptForUuid(alloc: std.mem.Allocator, home: []const u8, uuid: []const u8) !?[]u8 {
    if (!uuidValid(uuid)) return null;

    const projects_dir = try std.fmt.allocPrint(alloc, "{s}/.claude/projects", .{home});
    defer alloc.free(projects_dir);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pd = std.Io.Dir.cwd().openDir(io, projects_dir, .{ .iterate = true }) catch return null;
    defer pd.close(io);

    var it = pd.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const candidate = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}.jsonl", .{ projects_dir, entry.name, uuid });
        if (std.Io.Dir.cwd().statFile(io, candidate, .{})) |_| {
            return candidate;
        } else |_| {
            alloc.free(candidate);
        }
    }
    return null;
}


// ── Plain-text render for inline-context editors ────────────────────────────

/// Render the transcript to /tmp/claude-pager-render-<pid>.txt and export its
/// path via CLAUDE_PAGER_RENDER_FILE so the editor child inherits it. Returns
/// the render path (caller owns/frees), or null on any failure. `tty_fd` is
/// used to query the column width; pass -1 to skip.
pub fn maybeRenderTranscript(alloc: std.mem.Allocator, home: []const u8, tty_fd: std.posix.fd_t) ?[]u8 {
    const transcript = (findTranscript(alloc, home) catch null) orelse return null;
    defer alloc.free(transcript);

    var cols: usize = 100;
    if (tty_fd >= 0) {
        const ws = term.getWinsize(tty_fd);
        if (ws.cols > 0) cols = if (ws.cols < 120) ws.cols else 120;
    }

    const render_path = std.fmt.allocPrint(
        alloc,
        "/tmp/claude-pager-render-{d}.txt",
        .{std.c.getpid()},
    ) catch return null;
    errdefer alloc.free(render_path);

    render_plain.renderPlain(alloc, transcript, render_path, cols) catch {
        log.dbg("plain render failed for {s}", .{transcript});
        alloc.free(render_path);
        return null;
    };

    // Null-terminate both for setenv.
    var key_buf: [32]u8 = undefined;
    @memcpy(key_buf[0.."CLAUDE_PAGER_RENDER_FILE".len], "CLAUDE_PAGER_RENDER_FILE");
    key_buf["CLAUDE_PAGER_RENDER_FILE".len] = 0;

    const val_z = alloc.dupeZ(u8, render_path) catch {
        alloc.free(render_path);
        return null;
    };
    defer alloc.free(val_z);

    _ = setenv(@ptrCast(&key_buf), val_z.ptr, 1);
    log.dbg("rendered transcript to {s} (cols={d})", .{ render_path, cols });
    return render_path;
}

// ── Static summary print ─────────────────────────────────────────────────────

/// Render the newest transcript to COLORED static text and write it to /dev/tty
/// once — no alternate screen, no mouse, no input loop, so the terminal's native
/// scrollback/selection stay intact. Re-parses the transcript (the editor file
/// is rendered separately, color-stripped, by `maybeRenderTranscript`). Best
/// effort; silent on any failure.
fn printSummary(alloc: std.mem.Allocator, home: []const u8) void {
    const tty_fd = term.openTty() catch return;
    defer _ = std.c.close(tty_fd);

    const no_transcript = "claude-pager: no transcript yet — fresh session\n";

    const transcript = (findTranscript(alloc, home) catch null) orelse {
        _ = std.c.write(tty_fd, no_transcript, no_transcript.len);
        return;
    };
    defer alloc.free(transcript);

    var cols: usize = 100;
    const ws = term.getWinsize(tty_fd);
    if (ws.cols > 0) cols = if (ws.cols < 120) ws.cols else 120;

    const text = render_plain.renderColored(alloc, transcript, cols) catch {
        _ = std.c.write(tty_fd, no_transcript, no_transcript.len);
        return;
    };
    defer alloc.free(text);
    if (text.len == 0) {
        _ = std.c.write(tty_fd, no_transcript, no_transcript.len);
        return;
    }

    _ = std.c.write(tty_fd, text.ptr, text.len);
    if (text[text.len - 1] != '\n') _ = std.c.write(tty_fd, "\n", 1);
}

// ── Editor spawn / exec ─────────────────────────────────────────────────────

/// Fork+exec the editor command (via `/bin/sh -c "exec <editor> \"$1\""`) on
/// `file`. When `detach_stdin` is set, the child's stdin is redirected from
/// /dev/null. Returns the child pid.
pub fn spawnEditor(
    alloc: std.mem.Allocator,
    editor: []const u8,
    file: []const u8,
    detach_stdin: bool,
) !std.posix.pid_t {
    const cmd = try std.fmt.allocPrintSentinel(alloc, "exec {s} \"$1\"", .{editor}, 0);
    defer alloc.free(cmd);
    const file_z = try alloc.dupeZ(u8, file);
    defer alloc.free(file_z);

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        if (detach_stdin) {
            const devnull = std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDONLY }, 0) catch -1;
            if (devnull >= 0) {
                _ = std.c.dup2(devnull, std.posix.STDIN_FILENO);
                _ = std.c.close(devnull);
            }
        }
        const argv = [_:null]?[*:0]const u8{ "sh", "-c", cmd.ptr, "sh", file_z.ptr };
        _ = execvp("/bin/sh", &argv);
        std.c._exit(127);
    }
    return pid;
}

// ── Terminal editor path (exec directly, no pager) ──────────────────────────

/// Terminal (TUI) editors can't share the terminal with the pager, so render
/// the transcript to plain text (for inline-context editors) then exec the
/// editor directly, replacing this process. On exec failure returns 127.
pub fn terminalEditorPath(
    alloc: std.mem.Allocator,
    home: []const u8,
    editor: []const u8,
    file: []const u8,
) !u8 {
    log.dbg("terminal editor, exec without pager", .{});
    // Render context for inline-aware editors. The TUI editor takes over the
    // terminal, so there is no static summary print here.
    if (maybeRenderTranscript(alloc, home, -1)) |p| alloc.free(p);

    const cmd = try std.fmt.allocPrintSentinel(alloc, "exec {s} \"$1\"", .{editor}, 0);
    defer alloc.free(cmd);
    const file_z = try alloc.dupeZ(u8, file);
    defer alloc.free(file_z);

    const argv = [_:null]?[*:0]const u8{ "sh", "-c", cmd.ptr, "sh", file_z.ptr };
    _ = execvp("/bin/sh", &argv);
    return 127;
}

// ── Generic (GUI) editor path: editor + static summary, TUI auto-detection ──

/// GUI editor flow: render context (exported to the editor + printed once as a
/// static summary to the terminal only when `print_summary` is set), spawn
/// the editor, and wait. Unknown editors get the "optimistic" probe: if the
/// editor exits within ~150ms it is reclassified as a TUI and re-launched via
/// terminalEditorPath (which never prints a summary, since the TUI owns the
/// terminal).
pub fn genericEditorPath(
    alloc: std.mem.Allocator,
    home: []const u8,
    editor: []const u8,
    file: []const u8,
    print_summary: bool,
) !u8 {
    const editorm = @import("editor.zig");

    const forced_gui = blk: {
        const t = getEnv("CLAUDE_PAGER_EDITOR_TYPE") orelse break :blk false;
        break :blk std.mem.eql(u8, t, "gui");
    };
    const known_gui = editorm.isKnownGuiEditor(editor);

    if (forced_gui or known_gui) {
        // Editor may show context inline (e.g. Emacs); render before spawning so
        // the editor child inherits CLAUDE_PAGER_RENDER_FILE.
        const render_path = maybeRenderTranscript(alloc, home, -1);
        defer if (render_path) |p| alloc.free(p);

        const ed_pid = spawnEditor(alloc, editor, file, false) catch return 1;
        log.dbg("GUI path: editor forked pid={d}", .{ed_pid});

        // Print the static summary to the terminal (no interactive pager) only
        // when enabled via --with-summary. On failure it prints a "no transcript
        // yet" line so the terminal is never silently blank.
        if (print_summary) printSummary(alloc, home);

        const status = waitEditorQuiet(ed_pid);
        log.dbg("editor exited status={d}", .{status});
        return 0;
    }

    // Unknown editor: render context first, then optimistic launch + 150ms probe.
    const render_path = maybeRenderTranscript(alloc, home, -1);
    defer if (render_path) |p| alloc.free(p);

    const ed_pid = spawnEditor(alloc, editor, file, true) catch return 1;
    log.dbg("optimistic path: editor forked pid={d} (stdin detached)", .{ed_pid});

    var i: usize = 0;
    while (i < 15) : (i += 1) {
        sleepMs(10);
        if (std.c.waitpid(ed_pid, null, std.c.W.NOHANG) == ed_pid) {
            log.dbg("optimistic probe: editor exited in {d}ms — TUI detected", .{(i + 1) * 10});
            log.dbg("re-launching as TUI editor (exec with tty)", .{});
            return terminalEditorPath(alloc, home, editor, file);
        }
    }

    log.dbg("optimistic probe: editor alive after 150ms — GUI confirmed", .{});
    // GUI confirmed — safe to print the static summary now (unless disabled).
    if (print_summary) printSummary(alloc, home);

    const status = waitEditorQuiet(ed_pid);
    log.dbg("editor exited status={d}", .{status});
    return 0;
}

/// Blocking waitpid; returns the raw status word (or 0 on error).
fn waitBlocking(pid: std.posix.pid_t) c_int {
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    return status;
}

/// Wait for the editor with the tty in raw mode. Claude Code leaves focus
/// tracking (DECSET 1004) enabled while the editor runs, so switching focus
/// to the editor makes the terminal send ESC[O/ESC[I; with ECHO on the
/// kernel paints those over Claude's UI and its differential repaint then
/// scrambles. Raw mode (not merely ECHO off) matters: canonical-mode-with-
/// echo-off is the pty signature terminal emulators read as "child is asking
/// for a password" (e.g. ghostel pops read-passwd on it), while raw+no-echo
/// is ordinary TUI state. The escapes stay queued for Claude to consume.
fn waitEditorQuiet(pid: std.posix.pid_t) c_int {
    const tty_fd = term.openTty() catch return waitBlocking(pid);
    defer _ = std.c.close(tty_fd);
    const quiet = term.RawMode.enable(tty_fd) catch return waitBlocking(pid);
    defer quiet.restore();
    return waitBlocking(pid);
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Sleep for `ms` milliseconds (std.Thread.sleep is gone in 0.16).
fn sleepMs(ms: u64) void {
    const ns = ms * std.time.ns_per_ms;
    const req = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem = req;
    // Single retry budget is plenty; nanosleep restarts with the remainder.
    _ = std.c.nanosleep(&req, &rem);
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

// ── Tests ────────────────────────────────────────────────────────────────────

test "transcriptForUuid resolves the exact session, not the newest sibling" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Two sessions sharing one project dir: ours, plus a newer sibling that a
    // newest-jsonl heuristic would wrongly prefer.
    try tmp.dir.createDirPath(io, ".claude/projects/proj");
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude/projects/proj/mine.jsonl", .data = "m\n" });
    sleepMs(1_100);
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude/projects/proj/newer-sibling.jsonl", .data = "s\n" });

    const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(home);

    const got = try transcriptForUuid(a, home, "mine");
    defer if (got) |g| a.free(g);
    try std.testing.expect(got != null);
    try std.testing.expect(std.mem.endsWith(u8, got.?, "proj/mine.jsonl"));
}

test "transcriptForUuid returns null when the uuid names no file" {
    const got = try transcriptForUuid(std.testing.allocator, "/nonexistent/home/xyz", "no-such-session");
    try std.testing.expect(got == null);
}

test "uuidFromBridge maps the bridge id to the session UUID via the registry" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Two registry entries; only the matching bridge id must be picked.
    try tmp.dir.createDirPath(io, ".claude/sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".claude/sessions/111.json",
        .data = "{\"pid\":111,\"sessionId\":\"other-uuid\",\"bridgeSessionId\":\"session_other\"}",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = ".claude/sessions/222.json",
        .data = "{\"pid\":222,\"sessionId\":\"the-uuid\",\"bridgeSessionId\":\"session_wanted\"}",
    });

    const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(home);

    _ = setenv("CLAUDE_CODE_BRIDGE_SESSION_ID", "session_wanted", 1);
    defer _ = setenv("CLAUDE_CODE_BRIDGE_SESSION_ID", "", 1);

    const got = try uuidFromBridge(a, home);
    defer if (got) |g| a.free(g);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("the-uuid", got.?);
}

test "uuidFromBridge returns null when no registry entry matches" {
    _ = setenv("CLAUDE_CODE_BRIDGE_SESSION_ID", "session_absent", 1);
    defer _ = setenv("CLAUDE_CODE_BRIDGE_SESSION_ID", "", 1);
    const got = try uuidFromBridge(std.testing.allocator, "/nonexistent/home/xyz");
    try std.testing.expect(got == null);
}
