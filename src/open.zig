//! open.zig — the editor-launcher core for claude-pager-open.
//!
//! C-g flow: resolve the session transcript, render it to plain text (shared
//! with the editor via CLAUDE_PAGER_RENDER_FILE), print that summary statically
//! to the terminal, then launch the editor and wait. There is NO interactive
//! pager — no mouse tracking, no scroll loop, no clickable-URL rewriting — so
//! the terminal's native scrollback/selection are left untouched.
//!
//!   newestJsonl / findTranscript   — locate the newest *.jsonl transcript
//!   maybeRenderTranscript          — render to plain text + export render file
//!   printSummary                   — write the rendered summary to /dev/tty
//!   spawnEditor / terminalEditorPath / genericEditorPath — launch the editor

const std = @import("std");
const render_plain = @import("render_plain.zig");
const term = @import("term.zig");
const log = @import("log.zig");

// libc functions not surfaced by std in Zig 0.16.
extern "c" fn ttyname(fd: c_int) ?[*:0]const u8;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn fork() std.c.pid_t;

// ── Transcript finding (pure, no process spawns) ────────────────────────────

/// Return the path of the most-recently-modified `*.jsonl` file directly in
/// `dir`, or null if there is none / the dir can't be opened.
/// Caller owns the returned slice.
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
pub fn findTranscript(alloc: std.mem.Allocator, home: []const u8) !?[]u8 {
    // Strategy 1: tty-keyed file written by the SessionStart hook. When the
    // pointer exists but its target hasn't been created yet (fresh session),
    // stop here: falling through to the newest-jsonl strategies would show
    // another session's conversation.
    if (ttyKeyedTranscript(alloc)) |t| {
        if (t) |path| return path;
    } else |err| switch (err) {
        error.FreshSession => return null,
        else => {},
    }

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

/// Derive the ~/.claude/projects/<key> name from `pwd` the way Claude does:
/// every non-alphanumeric character becomes '-' (".claude" -> "-claude").
fn projectKey(alloc: std.mem.Allocator, pwd: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, pwd.len);
    for (pwd, 0..) |c, i| out[i] = if (std.ascii.isAlphanumeric(c)) c else '-';
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

    return (try resolvePointerTarget(alloc, line)) orelse error.FreshSession;
}

/// Resolve a transcript path written by the SessionStart hook. Claude creates
/// the session .jsonl lazily (only after the first user message), so a fresh
/// session's pointer can name a file that doesn't exist yet.
fn resolvePointerTarget(alloc: std.mem.Allocator, line: []const u8) !?[]u8 {
    var nul_buf: [4096]u8 = undefined;
    if (line.len == 0 or line.len + 1 > nul_buf.len) return null;
    @memcpy(nul_buf[0..line.len], line);
    nul_buf[line.len] = 0;
    if (std.c.access(@ptrCast(&nul_buf), 4) == 0) return try alloc.dupe(u8, line); // R_OK
    // Target not born yet: fresh session, nothing to show. Never guess a
    // sibling session's transcript — that displays the wrong conversation.
    return null;
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
/// static summary to the terminal), spawn the editor, and wait. Unknown editors
/// get the "optimistic" probe: if the editor exits within ~150ms it is
/// reclassified as a TUI and re-launched via terminalEditorPath (which does not
/// print a summary, since the TUI owns the terminal).
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

    if (forced_gui or known_gui) {
        // Editor may show context inline (e.g. Emacs); render before spawning so
        // the editor child inherits CLAUDE_PAGER_RENDER_FILE.
        const render_path = maybeRenderTranscript(alloc, home, -1);
        defer if (render_path) |p| alloc.free(p);

        const ed_pid = spawnEditor(alloc, editor, file, false) catch return 1;
        log.dbg("GUI path: editor forked pid={d}", .{ed_pid});

        // Print the static summary to the terminal (no interactive pager).
        // Always called: on failure it prints a "no transcript yet" line so
        // the terminal is never silently blank.
        printSummary(alloc, home);

        const status = waitBlocking(ed_pid);
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
    // GUI confirmed — safe to print the static summary now.
    printSummary(alloc, home);

    const status = waitBlocking(ed_pid);
    log.dbg("editor exited status={d}", .{status});
    return 0;
}

/// Blocking waitpid; returns the raw status word (or 0 on error).
fn waitBlocking(pid: std.posix.pid_t) c_int {
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    return status;
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

test "projectKey maps every non-alphanumeric char to '-' like Claude does" {
    const a = std.testing.allocator;
    // Claude derives ~/.claude/projects/<key> by replacing [^a-zA-Z0-9] with '-':
    // "/Users/p/.claude" -> "-Users-p--claude", "github.com" -> "github-com".
    const cases = [_][2][]const u8{
        .{ "/Users/pavel/Notes", "-Users-pavel-Notes" },
        .{ "/Users/pavel/.claude", "-Users-pavel--claude" },
        .{
            "/Users/pavel/Developer/src/github.com/FindHotel/content-pipeline",
            "-Users-pavel-Developer-src-github-com-FindHotel-content-pipeline",
        },
        .{ "/tmp/repo_name", "-tmp-repo-name" },
    };
    for (cases) |c| {
        const got = try projectKey(a, c[0]);
        defer a.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

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

test "resolvePointerTarget returns the path itself when readable" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "live.jsonl", .data = "x\n" });

    const target = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/live.jsonl", .{tmp.sub_path});
    defer a.free(target);

    const got = try resolvePointerTarget(a, target);
    defer if (got) |g| a.free(g);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(target, got.?);
}

test "resolvePointerTarget returns null when target is missing, even with sibling jsonls" {
    // A pointer whose target doesn't exist yet means a fresh session with no
    // conversation. Guessing a sibling session's transcript here showed the
    // wrong conversation; the only correct answer is "no transcript yet".
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "previous.jsonl", .data = "x\n" });

    const target = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/not-born-yet.jsonl", .{tmp.sub_path});
    defer a.free(target);

    const got = try resolvePointerTarget(a, target);
    defer if (got) |g| a.free(g);
    try std.testing.expect(got == null);
}

test "newestJsonl returns null for a missing dir" {
    const got = try newestJsonl(std.testing.allocator, "/nonexistent/dir/xyz-claude-pager");
    try std.testing.expect(got == null);
}
