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
    // Some contexts expose the UUID directly. The whole CLAUDE_* env block can
    // also be inherited from an unrelated session (e.g. an Emacs restarted
    // from inside a Claude session hands that session's env to everything it
    // later spawns), so the id is trusted only when the block isn't provably
    // foreign — see envSessionLeaked.
    if (getEnv("CLAUDE_CODE_SESSION_ID")) |sid| {
        if (uuidValid(sid) and !envSessionLeaked()) {
            if (try transcriptForUuid(alloc, home, sid)) |p| return p;
        }
    }
    // The editor only gets the bridge id; look up its UUID in the registry.
    if (try uuidFromBridge(alloc, home)) |uuid| {
        defer alloc.free(uuid);
        if (try transcriptForUuid(alloc, home, uuid)) |p| return p;
    }
    // The bridge id can go stale (a relogin drops the bridge and the registry
    // entry ends up with bridgeSessionId=null). The registry is also keyed by
    // the Claude process pid, and this process is a descendant of it — so walk
    // ancestor pids and match them against the registry directly.
    if (try uuidFromAncestors(alloc, home)) |uuid| {
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

// proc_pidinfo(PROC_PIDTBSDINFO) — used to walk ancestor pids and to read a
// process's start time (guards against pid reuse when matching the registry).
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;

const PROC_PIDTBSDINFO: c_int = 3;

const ProcBsdInfo = extern struct {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: u32,
    pbi_gid: u32,
    pbi_ruid: u32,
    pbi_rgid: u32,
    pbi_svuid: u32,
    pbi_svgid: u32,
    rfu_1: u32,
    pbi_comm: [16]u8,
    pbi_name: [32]u8,
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
};

/// Walk this process's ancestor pids and return the session UUID of the first
/// one that has a registry entry (~/.claude/sessions/<pid>.json). The Claude
/// process that spawned the editor is always an ancestor, so this resolves the
/// session with no environment cooperation at all. Caller owns the slice.
fn uuidFromAncestors(alloc: std.mem.Allocator, home: []const u8) !?[]u8 {
    var pid: std.c.pid_t = std.c.getppid();
    var depth: usize = 0;
    while (pid > 1 and depth < 12) : (depth += 1) {
        var info: ProcBsdInfo = undefined;
        const n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, @sizeOf(ProcBsdInfo));
        if (n != @sizeOf(ProcBsdInfo)) return null;

        const start_secs: i64 = @intCast(info.pbi_start_tvsec);
        if (try registryUuidForPid(alloc, home, pid, start_secs)) |uuid| return uuid;
        pid = @intCast(info.pbi_ppid);
    }
    return null;
}

/// True when `target` appears among this process's ancestor pids.
fn pidIsAncestor(target: std.c.pid_t) bool {
    var pid: std.c.pid_t = std.c.getppid();
    var depth: usize = 0;
    while (pid > 1 and depth < 12) : (depth += 1) {
        if (pid == target) return true;
        var info: ProcBsdInfo = undefined;
        const n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, @sizeOf(ProcBsdInfo));
        if (n != @sizeOf(ProcBsdInfo)) return false;
        pid = @intCast(info.pbi_ppid);
    }
    return false;
}

/// The CLAUDE_* env block travels together; CLAUDE_PID names the Claude
/// process that exported it. When that process is not an ancestor, the block
/// was inherited from another session and its session id must not be trusted.
/// Absent/unparseable CLAUDE_PID gives no evidence either way — not leaked.
fn envSessionLeaked() bool {
    const cp = getEnv("CLAUDE_PID") orelse return false;
    const pid = std.fmt.parseInt(std.c.pid_t, cp, 10) catch return false;
    if (pid <= 1) return false;
    return !pidIsAncestor(pid);
}

/// The registry's startedAt (session start) trails the process start by
/// however long the CLI takes to boot; allow that much slack when matching.
const start_match_slack_secs: i64 = 60;

/// Read ~/.claude/sessions/<pid>.json and return its sessionId. When both
/// `expect_start_secs` (the live process's start time, epoch seconds) and the
/// entry's startedAt are present they must agree within a small slack — this
/// rejects a stale registry file left behind by a dead session whose pid the
/// OS has since reused. Caller owns the slice.
fn registryUuidForPid(
    alloc: std.mem.Allocator,
    home: []const u8,
    pid: std.c.pid_t,
    expect_start_secs: ?i64,
) !?[]u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/.claude/sessions/{d}.json", .{ home, pid });
    defer alloc.free(path);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(65536)) catch return null;
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    if (expect_start_secs) |want| {
        if (obj.get("startedAt")) |sa| {
            const started_ms: ?i64 = switch (sa) {
                .integer => sa.integer,
                .float => @intFromFloat(sa.float),
                else => null,
            };
            if (started_ms) |ms| {
                const started_secs = @divTrunc(ms, 1000);
                const delta = started_secs - want;
                if (delta < -2 or delta > start_match_slack_secs) return null;
            }
        }
    }

    const s = obj.get("sessionId") orelse return null;
    if (s != .string or !uuidValid(s.string)) return null;
    return try alloc.dupe(u8, s.string);
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

test "registryUuidForPid returns the sessionId for a matching pid file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try tmp.dir.createDirPath(io, ".claude/sessions");
    // startedAt = 1784035756963 ms → 1784035756 s; process started ~1s earlier.
    try tmp.dir.writeFile(io, .{
        .sub_path = ".claude/sessions/37300.json",
        .data = "{\"pid\":37300,\"sessionId\":\"pid-uuid\",\"startedAt\":1784035756963,\"bridgeSessionId\":null}",
    });

    const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(home);

    // Process start just before startedAt: accepted.
    const got = try registryUuidForPid(a, home, 37300, 1784035755);
    defer if (got) |g| a.free(g);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("pid-uuid", got.?);

    // No expected start time (caller couldn't read it): accepted.
    const got2 = try registryUuidForPid(a, home, 37300, null);
    defer if (got2) |g| a.free(g);
    try std.testing.expect(got2 != null);

    // Start-time mismatch (pid reused by an unrelated, later process): rejected.
    const got3 = try registryUuidForPid(a, home, 37300, 1784035756 + 3600);
    try std.testing.expect(got3 == null);

    // Registry claims a start long after the live process began: rejected.
    const got5 = try registryUuidForPid(a, home, 37300, 1784035756 - 3600);
    try std.testing.expect(got5 == null);

    // Unknown pid: no registry file.
    const got4 = try registryUuidForPid(a, home, 99999, null);
    try std.testing.expect(got4 == null);
}

test "envSessionLeaked: absent or empty CLAUDE_PID is not leaked" {
    _ = setenv("CLAUDE_PID", "", 1);
    try std.testing.expect(!envSessionLeaked());
}

test "envSessionLeaked: CLAUDE_PID naming an ancestor is trusted" {
    var buf: [16]u8 = undefined;
    const s = try std.fmt.bufPrintZ(&buf, "{d}", .{std.c.getppid()});
    _ = setenv("CLAUDE_PID", s, 1);
    defer _ = setenv("CLAUDE_PID", "", 1);
    try std.testing.expect(!envSessionLeaked());
}

test "envSessionLeaked: CLAUDE_PID naming a foreign process is leaked" {
    _ = setenv("CLAUDE_PID", "99999999", 1);
    defer _ = setenv("CLAUDE_PID", "", 1);
    try std.testing.expect(envSessionLeaked());
}

test "uuidFromBridge returns null when no registry entry matches" {
    _ = setenv("CLAUDE_CODE_BRIDGE_SESSION_ID", "session_absent", 1);
    defer _ = setenv("CLAUDE_CODE_BRIDGE_SESSION_ID", "", 1);
    const got = try uuidFromBridge(std.testing.allocator, "/nonexistent/home/xyz");
    try std.testing.expect(got == null);
}
