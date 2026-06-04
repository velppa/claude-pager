//! queue_clipboard.zig — Clipboard text/image/file attachment for the prompt
//! queue on macOS.
//!
//! Ported from bin/pager.c:1116-1251:
//!   - queue_assets_dir           (1116)
//!   - queue_export_clipboard_png (1134) — osascript
//!   - queue_attach_clipboard_image (1161)
//!   - queue_make_ref_token        (1196)
//!   - queue_read_pbpaste_text     (1209) — pbpaste
//!   - queue_attach_clipboard_file_refs (1222)
//!
//! External commands used (exact args match the C):
//!   pbpaste (no args) — read clipboard text
//!   osascript -e "on run argv" \
//!             -e "set outPath to item 1 of argv" \
//!             -e "set imgData to the clipboard as «class PNGf»" \
//!             -e "set fRef to open for access POSIX file outPath with write permission" \
//!             -e "set eof fRef to 0" \
//!             -e "write imgData to fRef" \
//!             -e "close access fRef" \
//!             -e "end run" \
//!             -- <dst_path>
//!
//! Asset dir:    $HOME/.claude/queues/assets   (bin/pager.c:1126)
//! Filename:     clip-<us_timestamp>-<pid>.png (bin/pager.c:1171)
//! Token format: @<escaped_path>  where ' ', '\', '"', '\'' are
//!               backslash-escaped (bin/pager.c:1198-1206)

const std = @import("std");

/// Maximum image size accepted (20 MiB). Mirrors QUEUE_IMAGE_MAX_BYTES
/// (bin/pager.c:122).
const QUEUE_IMAGE_MAX_BYTES: u64 = 20 * 1024 * 1024;

// ── getenv helper (matches links.zig / queue_persist.zig idiom) ─────────────

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

// ── Io helper ────────────────────────────────────────────────────────────────

/// Build a short-lived threaded Io backed by the given allocator.
/// Caller must call deinit on the returned Threaded.
fn makeIo(alloc: std.mem.Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(alloc, .{});
}

// ── Directory creation ───────────────────────────────────────────────────────

/// Ensure `path` (absolute) exists as a directory, creating it if needed.
/// Mirrors queue_ensure_dir (bin/pager.c:1107-1114).
fn ensureDir(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    // createDir fails with PathAlreadyExists when it already exists — that is fine.
    cwd.createDir(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Confirm it is actually a directory (not a file).
            var d = try cwd.openDir(io, path, .{});
            d.close(io);
        },
        else => return err,
    };
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Resolve (creating if needed) the assets directory: $HOME/.claude/queues/assets.
/// Mirrors queue_assets_dir (bin/pager.c:1116-1132). Writes into `out` and
/// returns the written slice.
pub fn assetsDir(out: []u8) ![]const u8 {
    const home = getEnv("HOME") orelse return error.NoHome;
    if (home.len == 0) return error.NoHome;

    var threaded = makeIo(std.heap.c_allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Ensure each path component exists in order (bin/pager.c:1128-1130).
    var tmp: [std.fs.max_path_bytes]u8 = undefined;

    const claude_dir = try std.fmt.bufPrint(&tmp, "{s}/.claude", .{home});
    try ensureDir(io, claude_dir);

    const queue_dir = try std.fmt.bufPrint(&tmp, "{s}/.claude/queues", .{home});
    try ensureDir(io, queue_dir);

    const assets = try std.fmt.bufPrint(out, "{s}/.claude/queues/assets", .{home});
    try ensureDir(io, assets);

    return assets;
}

/// Export clipboard image as PNG to `dst_path` via osascript.
/// Mirrors queue_export_clipboard_png (bin/pager.c:1134-1159).
/// The osascript script uses AppleScript's «class PNGf» coercion to read the
/// clipboard PNG data and write it to the given POSIX path.
/// Returns true on success (osascript exits 0), false otherwise.
pub fn exportClipboardPng(dst_path: []const u8) !bool {
    var threaded = makeIo(std.heap.c_allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // «class PNGf» in UTF-8: \xC2\xAB = «, \xC2\xBB = »
    const argv = [_][]const u8{
        "osascript",
        "-e", "on run argv",
        "-e", "set outPath to item 1 of argv",
        "-e", "set imgData to the clipboard as \xC2\xABclass PNGf\xC2\xBB",
        "-e", "set fRef to open for access POSIX file outPath with write permission",
        "-e", "set eof fRef to 0",
        "-e", "write imgData to fRef",
        "-e", "close access fRef",
        "-e", "end run",
        "--",
        dst_path,
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);

    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// If clipboard holds an image, save it under assetsDir and return its path
/// written into `out`. Returns null if no image is available or on any error.
/// Mirrors queue_attach_clipboard_image (bin/pager.c:1161-1194).
pub fn attachClipboardImage(out: []u8) !?[]const u8 {
    var assets_buf: [std.fs.max_path_bytes]u8 = undefined;
    const assets = assetsDir(&assets_buf) catch return null;

    // Timestamp in microseconds (mirrors now_us / gettimeofday, bin/pager.c:1168).
    const ts_us = nowUs();
    const pid: i32 = std.c.getpid();
    const dst = std.fmt.bufPrint(out, "{s}/clip-{d}-{d}.png", .{ assets, ts_us, pid }) catch return null;

    var threaded = makeIo(std.heap.c_allocator);
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const ok = exportClipboardPng(dst) catch {
        cwd.deleteFile(io, dst) catch {};
        return null;
    };
    if (!ok) {
        cwd.deleteFile(io, dst) catch {};
        return null;
    }

    // Verify the file is regular, non-empty and within size limit
    // (bin/pager.c:1178-1190).
    const st = cwd.statFile(io, dst, .{}) catch {
        cwd.deleteFile(io, dst) catch {};
        return null;
    };
    if (st.size == 0 or st.size > QUEUE_IMAGE_MAX_BYTES) {
        cwd.deleteFile(io, dst) catch {};
        return null;
    }

    return dst;
}

/// Format `path` into a queue ref token: '@' followed by the path with
/// backslash-escaping of ' ', '\', '"', '\''.
/// Mirrors queue_make_ref_token (bin/pager.c:1196-1207). Returns the written
/// slice of `out`.
pub fn makeRefToken(path: []const u8, out: []u8) ![]const u8 {
    if (path.len == 0) return error.EmptyPath;
    if (out.len < 4) return error.BufferTooSmall;

    var j: usize = 0;
    out[j] = '@';
    j += 1;
    for (path) |c| {
        if (j + 2 >= out.len) return error.BufferTooSmall;
        if (c == ' ' or c == '\\' or c == '"' or c == '\'') {
            out[j] = '\\';
            j += 1;
        }
        out[j] = c;
        j += 1;
    }
    return out[0..j];
}

/// Read clipboard text via `pbpaste`. Returns null if clipboard is empty or
/// command fails. Caller owns the returned slice.
/// Mirrors queue_read_pbpaste_text (bin/pager.c:1209-1220).
pub fn readPbpasteText(alloc: std.mem.Allocator) !?[]u8 {
    var threaded = makeIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const result = std.process.run(alloc, io, .{
        .argv = &.{"pbpaste"},
        .stdout_limit = std.Io.Limit.limited(8 * 1024 * 1024), // 8 MiB cap
    }) catch return null;
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);

    const exited_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok or result.stdout.len == 0) {
        alloc.free(result.stdout);
        return null;
    }
    return result.stdout;
}

/// If clipboard holds file references (absolute paths on separate lines),
/// return them formatted as space-separated ref tokens (caller owns).
/// Returns null if no usable paths found.
/// Mirrors queue_attach_clipboard_file_refs (bin/pager.c:1222-1251).
/// Note: queue_token_to_path path validation and input_append_token belong to
/// queue.zig (Task 13); here we collect absolute-path lines and format tokens.
pub fn attachClipboardFileRefs(alloc: std.mem.Allocator) !?[]u8 {
    const clip = (try readPbpasteText(alloc)) orelse return null;
    defer alloc.free(clip);

    var tokens: std.ArrayListUnmanaged(u8) = .empty;
    errdefer tokens.deinit(alloc);

    var line_iter = std.mem.splitAny(u8, clip, "\r\n");
    while (line_iter.next()) |raw_line| {
        // Trim leading/trailing whitespace (mirrors isspace loop in C:1237-1239).
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0) continue;

        // Only process absolute paths (bin/pager.c:1243 — queue_token_to_path
        // returns 0 for non-paths; we check '/' prefix as a first filter).
        if (line[0] != '/') continue;

        var ref_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
        const ref = makeRefToken(line, &ref_buf) catch continue;

        if (tokens.items.len > 0) try tokens.append(alloc, ' ');
        try tokens.appendSlice(alloc, ref);
    }

    if (tokens.items.len == 0) {
        tokens.deinit(alloc);
        return null;
    }
    return try tokens.toOwnedSlice(alloc);
}

// ── Timestamp helper ─────────────────────────────────────────────────────────

/// Current time in microseconds (mirrors now_us / gettimeofday, bin/pager.c:196-200).
fn nowUs() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1_000_000 + @as(i64, tv.usec);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "makeRefToken formats a path reference" {
    var buf: [4096]u8 = undefined;
    const tok = try makeRefToken("/tmp/example/pic.png", &buf);
    try std.testing.expect(std.mem.indexOf(u8, tok, "pic.png") != null);
    try std.testing.expect(tok[0] == '@');
    try std.testing.expectEqualStrings("@/tmp/example/pic.png", tok);
}

test "makeRefToken escapes spaces and special chars" {
    var buf: [4096]u8 = undefined;
    const tok = try makeRefToken("/path/with space/file.png", &buf);
    try std.testing.expectEqualStrings("@/path/with\\ space/file.png", tok);
}

test "makeRefToken escapes backslash and quotes" {
    var buf: [4096]u8 = undefined;
    const tok = try makeRefToken("/a\\b\"c'd", &buf);
    try std.testing.expectEqualStrings("@/a\\\\b\\\"c\\'d", tok);
}

test "makeRefToken errors on empty path" {
    var buf: [4096]u8 = undefined;
    try std.testing.expectError(error.EmptyPath, makeRefToken("", &buf));
}

test "assetsDir returns a non-empty path under HOME" {
    var buf: [4096]u8 = undefined;
    const dir = try assetsDir(&buf);
    try std.testing.expect(dir.len > 0);
    // Must be under HOME.
    const home = getEnv("HOME") orelse return error.SkipZigTest;
    try std.testing.expect(std.mem.startsWith(u8, dir, home));
    try std.testing.expect(std.mem.endsWith(u8, dir, "/.claude/queues/assets"));
}

test "assetsDir creates and can open the directory" {
    var buf: [4096]u8 = undefined;
    const dir_path = try assetsDir(&buf);
    var threaded = makeIo(std.testing.allocator);
    defer threaded.deinit();
    const io = threaded.io();
    var d = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    d.close(io);
}

test "readPbpasteText does not crash (clipboard may be empty)" {
    const result = try readPbpasteText(std.testing.allocator);
    if (result) |text| {
        std.testing.allocator.free(text);
    }
}

test "attachClipboardFileRefs does not crash" {
    const result = try attachClipboardFileRefs(std.testing.allocator);
    if (result) |refs| {
        std.testing.allocator.free(refs);
    }
}

test "attachClipboardImage does not crash (no clipboard image expected in CI)" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // May return null (no image in clipboard); must not error.
    const result = try attachClipboardImage(&buf);
    _ = result;
}
