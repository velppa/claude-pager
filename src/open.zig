//! open.zig — the editor-launcher core for claude-pager-open.
//!
//! Ports these sections from bin/claude-pager-open.c. The external editor socket
//! fast path and all Unix-socket / control_fd code are intentionally NOT ported:
//!   newest_jsonl            (line 237) → newestJsonl
//!   find_transcript         (line 260) → findTranscript
//!   maybe_render_transcript (line 699) → maybeRenderTranscript
//!   pre_render              (line 322) → preRender
//!   fork_pager              (line 347) → forkPager   (NO control_fd)
//!   spawn_editor            (line 741) → spawnEditor
//!   terminal_editor_path    (line 726) → terminalEditorPath
//!   generic_editor_path     (line 756) → genericEditorPath

const std = @import("std");
const render_plain = @import("render_plain.zig");
const pager = @import("pager.zig");
const term = @import("term.zig");
const log = @import("log.zig");

const CTX_LIMIT: usize = 200000;

// libc functions not surfaced by std in Zig 0.16.
extern "c" fn ttyname(fd: c_int) ?[*:0]const u8;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn fork() std.c.pid_t;

// ── Transcript finding (pure, no process spawns) ────────────────────────────

/// Return the path of the most-recently-modified `*.jsonl` file directly in
/// `dir`, or null if there is none / the dir can't be opened.
/// Caller owns the returned slice. Mirrors newest_jsonl (C line 237).
pub fn newestJsonl(alloc: std.mem.Allocator, dir: []const u8) !?[]u8 {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return null;
    defer d.close(io);

    var best_path: ?[]u8 = null;
    errdefer if (best_path) |p| alloc.free(p);
    var best_mtime: i96 = std.math.minInt(i96);

    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const st = d.statFile(io, entry.name, .{}) catch continue;
        const m = st.mtime.nanoseconds;
        if (best_path == null or m > best_mtime) {
            const full = try std.fs.path.join(alloc, &.{ dir, entry.name });
            if (best_path) |p| alloc.free(p);
            best_path = full;
            best_mtime = m;
        }
    }
    return best_path;
}

/// Locate the newest `.jsonl` transcript for the current session/cwd under
/// `<home>/.claude/projects/...`. Caller owns the returned slice (or null).
/// Mirrors find_transcript (C line 260).
pub fn findTranscript(alloc: std.mem.Allocator, home: []const u8) !?[]u8 {
    // Strategy 1: tty-keyed file written by the SessionStart hook.
    if (ttyKeyedTranscript(alloc)) |t| {
        if (t) |path| return path;
    } else |_| {}

    // Strategy 2: PWD-derived project directory.
    if (getEnv("PWD")) |pwd| {
        if (pwd.len > 0) {
            const key = try projectKey(alloc, pwd);
            defer alloc.free(key);
            const project_dir = try std.fmt.allocPrint(alloc, "{s}/.claude/projects/{s}", .{ home, key });
            defer alloc.free(project_dir);
            if (try newestJsonl(alloc, project_dir)) |path| return path;
        }
    }

    // Strategy 3: globally most-recent across all project dirs.
    return globalNewest(alloc, home);
}

/// Replace '/' with '-' in `pwd` to derive the ~/.claude/projects/<key> name.
fn projectKey(alloc: std.mem.Allocator, pwd: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, pwd.len);
    for (pwd, 0..) |c, i| out[i] = if (c == '/') '-' else c;
    return out;
}

/// Strategy 1: read /tmp/claude-transcript-<tty> (first line is a path).
fn ttyKeyedTranscript(alloc: std.mem.Allocator) !?[]u8 {
    const tty = ttyname(std.posix.STDIN_FILENO) orelse return null;
    var key = std.mem.span(tty);
    if (std.mem.startsWith(u8, key, "/dev/")) key = key[5..];

    const path = try std.fmt.allocPrint(alloc, "/tmp/claude-transcript-{s}", .{key});
    defer alloc.free(path);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8192)) catch return null;
    defer alloc.free(bytes);

    var line: []const u8 = bytes;
    if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];
    line = std.mem.trimEnd(u8, line, " \r\t");
    if (line.len == 0) return null;

    // Must be readable.
    var nul_buf: [4096]u8 = undefined;
    if (line.len + 1 > nul_buf.len) return null;
    @memcpy(nul_buf[0..line.len], line);
    nul_buf[line.len] = 0;
    if (std.c.access(@ptrCast(&nul_buf), 4) != 0) return null; // R_OK

    return try alloc.dupe(u8, line);
}

/// Strategy 3: scan every project dir, return the single newest jsonl.
fn globalNewest(alloc: std.mem.Allocator, home: []const u8) !?[]u8 {
    const projects_dir = try std.fmt.allocPrint(alloc, "{s}/.claude/projects", .{home});
    defer alloc.free(projects_dir);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pd = std.Io.Dir.cwd().openDir(io, projects_dir, .{ .iterate = true }) catch return null;
    defer pd.close(io);

    var best_path: ?[]u8 = null;
    errdefer if (best_path) |p| alloc.free(p);
    var best_mtime: i96 = std.math.minInt(i96);

    var it = pd.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const subdir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ projects_dir, entry.name });
        defer alloc.free(subdir);
        const candidate = (try newestJsonl(alloc, subdir)) orelse continue;
        defer alloc.free(candidate);
        const st = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        const m = st.mtime.nanoseconds;
        if (best_path == null or m > best_mtime) {
            if (best_path) |p| alloc.free(p);
            best_path = try alloc.dupe(u8, candidate);
            best_mtime = m;
        }
    }
    return best_path;
}

// ── Plain-text render for inline-context editors ────────────────────────────

/// Render the transcript to /tmp/claude-pager-render-<pid>.txt and export its
/// path via CLAUDE_PAGER_RENDER_FILE so the editor child inherits it. Best
/// effort: silently does nothing on any failure. Mirrors maybe_render_transcript
/// (C line 699). `tty_fd` is used to query the column width; pass -1 to skip.
pub fn maybeRenderTranscript(alloc: std.mem.Allocator, home: []const u8, tty_fd: std.posix.fd_t) void {
    const transcript = (findTranscript(alloc, home) catch null) orelse return;
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
    ) catch return;
    defer alloc.free(render_path);

    render_plain.renderPlain(alloc, transcript, render_path, cols, CTX_LIMIT) catch {
        log.dbg("plain render failed for {s}", .{transcript});
        return;
    };

    // Null-terminate both for setenv.
    var key_buf: [32]u8 = undefined;
    @memcpy(key_buf[0.."CLAUDE_PAGER_RENDER_FILE".len], "CLAUDE_PAGER_RENDER_FILE");
    key_buf["CLAUDE_PAGER_RENDER_FILE".len] = 0;

    const val_z = alloc.dupeZ(u8, render_path) catch return;
    defer alloc.free(val_z);

    _ = setenv(@ptrCast(&key_buf), val_z.ptr, 1);
    log.dbg("rendered transcript to {s} (cols={d})", .{ render_path, cols });
}

// ── Pre-render: instant initial frame ───────────────────────────────────────

/// Draw a minimal "Editor open" frame so the user sees something instantly.
/// Mirrors pre_render (C line 322).
fn preRender(tty_fd: std.posix.fd_t) void {
    const ws = term.getWinsize(tty_fd);
    const ws_col: usize = if (ws.cols == 0) 100 else ws.cols;
    const ws_row: usize = if (ws.rows == 0) 24 else ws.rows;
    const cols = if (ws_col < 120) ws_col else 120;

    var buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll("\x1b[2J\x1b[H") catch return;
    var i: usize = 0;
    while (i < cols) : (i += 1) w.writeAll("\x1b[38;2;80;80;80m\xe2\x94\x80") catch break;
    w.writeAll("\x1b[0m\n") catch {};
    var r: usize = 0;
    while (r + 4 < ws_row) : (r += 1) w.writeByte('\n') catch break;
    i = 0;
    while (i < cols) : (i += 1) w.writeAll("\x1b[38;2;80;80;80m\xe2\x94\x80") catch break;
    w.writeAll("\x1b[0m\n") catch {};
    w.writeAll("\x1b[1;33m  Editor open \xe2\x80\x94 edit and close to send\x1b[0m") catch {};

    const out = w.buffered();
    _ = std.c.write(tty_fd, out.ptr, out.len);
}

// ── Fork the pager child ────────────────────────────────────────────────────

/// Fork a child that opens /dev/tty, pre-renders, and runs the pager watching
/// `watch_pid`. Returns the child's pid in the parent. NO control_fd — the
/// external editor Ctrl+Q close protocol is removed. Mirrors fork_pager (C line 347).
pub fn forkPager(transcript: []const u8, watch_pid: std.posix.pid_t, ctx_limit: usize) !std.posix.pid_t {
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child.
        const tty_fd = term.openTty() catch std.c._exit(0);
        preRender(tty_fd);
        pager.runPager(tty_fd, transcript, watch_pid, ctx_limit) catch {};
        _ = std.c.close(tty_fd);
        std.c._exit(0);
    }
    return pid;
}

// ── Editor spawn / exec ─────────────────────────────────────────────────────

/// Fork+exec the editor command (via `/bin/sh -c "exec <editor> \"$1\""`) on
/// `file`. When `detach_stdin` is set, the child's stdin is redirected from
/// /dev/null. Returns the child pid. Mirrors spawn_editor (C line 741).
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
/// Mirrors terminal_editor_path (C line 726).
pub fn terminalEditorPath(
    alloc: std.mem.Allocator,
    home: []const u8,
    editor: []const u8,
    file: []const u8,
) !u8 {
    log.dbg("terminal editor, exec without pager", .{});
    maybeRenderTranscript(alloc, home, -1);

    const cmd = try std.fmt.allocPrintSentinel(alloc, "exec {s} \"$1\"", .{editor}, 0);
    defer alloc.free(cmd);
    const file_z = try alloc.dupeZ(u8, file);
    defer alloc.free(file_z);

    const argv = [_:null]?[*:0]const u8{ "sh", "-c", cmd.ptr, "sh", file_z.ptr };
    _ = execvp("/bin/sh", &argv);
    return 127;
}

// ── Generic (GUI) editor path: editor + pager, with TUI auto-detection ──────

/// GUI editor flow: optionally render context, spawn the editor, fork the pager
/// watching the editor pid, wait for the editor, then reap the pager. Unknown
/// editors get the "optimistic" probe: if the editor exits within ~150ms it is
/// reclassified as a TUI and re-launched via terminalEditorPath.
/// Mirrors generic_editor_path (C line 756).
pub fn genericEditorPath(
    alloc: std.mem.Allocator,
    home: []const u8,
    editor: []const u8,
    file: []const u8,
) !u8 {
    const editorm = @import("editor.zig");

    const forced_gui = blk: {
        const t = getEnv("CLAUDE_PAGER_EDITOR_TYPE") orelse break :blk false;
        break :blk std.mem.eql(u8, t, "gui");
    };
    const known_gui = editorm.isKnownGuiEditor(editor);

    // Resolve the transcript once for the pager child.
    const transcript = (findTranscript(alloc, home) catch null);
    defer if (transcript) |t| alloc.free(t);
    const transcript_s: []const u8 = transcript orelse "";

    if (forced_gui or known_gui) {
        // Editor may show context inline (e.g. Emacs); render before forking so
        // the editor child inherits CLAUDE_PAGER_RENDER_FILE.
        maybeRenderTranscript(alloc, home, -1);

        const ed_pid = spawnEditor(alloc, editor, file, false) catch return 1;
        log.dbg("fast GUI path: editor forked pid={d}", .{ed_pid});

        const pager_pid: std.posix.pid_t = forkPager(transcript_s, ed_pid, CTX_LIMIT) catch -1;
        log.dbg("pager forked pid={d}", .{pager_pid});

        const status = waitBlocking(ed_pid);
        log.dbg("editor exited status={d}", .{status});

        reapPager(pager_pid);
        return 0;
    }

    // Unknown editor: optimistic launch + 150ms probe to detect TUIs.
    const ed_pid = spawnEditor(alloc, editor, file, true) catch return 1;
    log.dbg("optimistic path: editor forked pid={d} (stdin detached)", .{ed_pid});

    const pager_pid: std.posix.pid_t = forkPager(transcript_s, ed_pid, CTX_LIMIT) catch -1;
    log.dbg("pager forked pid={d}", .{pager_pid});

    var i: usize = 0;
    while (i < 15) : (i += 1) {
        sleepMs(10);
        if (std.c.waitpid(ed_pid, null, std.c.W.NOHANG) == ed_pid) {
            log.dbg("optimistic probe: editor exited in {d}ms — TUI detected", .{(i + 1) * 10});
            reapPager(pager_pid);
            log.dbg("re-launching as TUI editor (exec with tty)", .{});
            return terminalEditorPath(alloc, home, editor, file);
        }
    }

    log.dbg("optimistic probe: editor alive after 150ms — GUI confirmed", .{});
    const status = waitBlocking(ed_pid);
    log.dbg("editor exited status={d}", .{status});
    reapPager(pager_pid);
    return 0;
}

/// Blocking waitpid; returns the raw status word (or 0 on error).
fn waitBlocking(pid: std.posix.pid_t) c_int {
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    return status;
}

/// Terminate and reap the pager child (if it was forked).
fn reapPager(pager_pid: std.posix.pid_t) void {
    if (pager_pid > 0) {
        std.posix.kill(pager_pid, std.posix.SIG.TERM) catch {};
        _ = std.c.waitpid(pager_pid, null, 0);
    }
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

test "newestJsonl picks the most recently modified" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.jsonl", .data = "a\n" });
    // Coarse-timestamp filesystems need a gap to distinguish mtimes.
    sleepMs(1_100);
    try tmp.dir.writeFile(io, .{ .sub_path = "b.jsonl", .data = "b\n" });
    // A non-jsonl file must be ignored even though it is newest.
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "c\n" });

    // tmpDir lives at .zig-cache/tmp/<sub_path> relative to cwd.
    const dir_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(dir_path);

    const got = try newestJsonl(std.testing.allocator, dir_path);
    defer if (got) |g| std.testing.allocator.free(g);

    try std.testing.expect(got != null);
    try std.testing.expect(std.mem.endsWith(u8, got.?, "b.jsonl"));
}

test "newestJsonl returns null for a missing dir" {
    const got = try newestJsonl(std.testing.allocator, "/nonexistent/dir/xyz-claude-pager");
    try std.testing.expect(got == null);
}
