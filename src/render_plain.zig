//! Plain-text render of a transcript. Reads a `.jsonl` transcript, renders it,
//! strips ANSI/OSC escapes (keeping OSC-8 visible text), right-trims trailing
//! whitespace per line, skips wrap-placeholder rows, and writes plain text.

const std = @import("std");
const ansi = @import("ansi.zig");
const transcript = @import("transcript.zig");
const render = @import("render.zig");

/// Strip ANSI CSI and OSC escape sequences from `line`, keeping the visible
/// text of OSC-8 hyperlinks (the URI carried in the OSC payload is dropped).
/// The result is freshly allocated; the CALLER is responsible for right-trimming
/// (via `rtrim`) and freeing. See render.zig's `plainLine` strip loop (minus
/// the trim).
pub fn stripAnsi(alloc: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    const s = line;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) { // ESC
            if (i + 1 < s.len and s[i + 1] == '[') { // CSI: ESC [ ... final 0x40-0x7e
                i += 2;
                while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) i += 1;
                if (i < s.len) i += 1;
                continue;
            }
            if (i + 1 < s.len and s[i + 1] == ']') { // OSC: ESC ] ... BEL or ST (ESC \)
                i += 2;
                while (i < s.len and s[i] != 0x07 and !(s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\')) i += 1;
                if (i < s.len and s[i] == 0x07) i += 1 else if (i < s.len and s[i] == 0x1b) i += 2;
                continue;
            }
            if (i + 1 < s.len) i += 2 else i += 1; // other 2-byte escape
            continue;
        }
        if (s[i] == 0x07) { // stray BEL (OSC-8 terminator)
            i += 1;
            continue;
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// Drop trailing ' ', '\t', '\r' from `s`.
pub fn rtrim(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) end -= 1;
    return s[0..end];
}

fn isWrapPlaceholder(ln: []const u8) bool {
    return std.mem.eql(u8, ln, ansi.wrap_placeholder);
}

/// Read the transcript at `transcript_path`, render it at `cols`, strip + rtrim
/// each non-wrap-placeholder line, and write line+'\n' to `out_path`.
pub fn renderPlain(
    alloc: std.mem.Allocator,
    transcript_path: []const u8,
    out_path: []const u8,
    cols: usize,
) !void {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const jsonl = try cwd.readFileAlloc(io, transcript_path, alloc, .unlimited);
    defer alloc.free(jsonl);

    // `parse` owns an arena (built from `alloc`); reuse it for rendering and the
    // output buffer so a single `tr.deinit()` reclaims everything.
    var tr = try transcript.parse(alloc, jsonl);
    defer tr.deinit();
    const a = tr.arena.allocator();
    const lines = try render.renderItems(a, tr.items, cols);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);

    for (lines) |ln| {
        if (isWrapPlaceholder(ln)) continue;
        const stripped = try stripAnsi(a, ln);
        try out.appendSlice(a, rtrim(stripped));
        try out.append(a, '\n');
    }

    try cwd.writeFile(io, .{ .sub_path = out_path, .data = out.items });
}

/// Render the transcript at `transcript_path` to a freshly-allocated buffer of
/// COLORED text — ANSI CSI color is kept (URLs/OSC-8 are already absent from the
/// render output). Caller owns and frees the result. Used for the static
/// terminal summary; the inline-editor file uses `renderPlain`
/// (color-stripped) instead.
pub fn renderColored(
    alloc: std.mem.Allocator,
    transcript_path: []const u8,
    cols: usize,
) ![]u8 {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const jsonl = try cwd.readFileAlloc(io, transcript_path, alloc, .unlimited);
    defer alloc.free(jsonl);

    var tr = try transcript.parse(alloc, jsonl);
    defer tr.deinit();
    const a = tr.arena.allocator();
    const lines = try render.renderItems(a, tr.items, cols);

    // Build into the CALLER's allocator so the result outlives `tr.deinit()`.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    for (lines) |ln| {
        if (isWrapPlaceholder(ln)) continue;
        try out.appendSlice(alloc, rtrim(ln));
        try out.append(alloc, '\n');
    }

    return out.toOwnedSlice(alloc);
}

// ── Tests ──────────────────────────────────────────────────────────────────

fn buildPlain(a: std.mem.Allocator, jsonl: []const u8, cols: usize) ![]u8 {
    const tr = try transcript.parse(a, jsonl);
    const lines = try render.renderItems(a, tr.items, cols);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (lines) |ln| {
        if (std.mem.eql(u8, ln, ansi.wrap_placeholder)) continue;
        const stripped = try stripAnsi(a, ln);
        try out.appendSlice(a, rtrim(stripped));
        try out.append(a, '\n');
    }
    return out.items;
}

test "render_plain transform matches golden sample0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const built = try buildPlain(a, @embedFile("fixtures/sample0.jsonl"), 110);
    try std.testing.expectEqualStrings(@embedFile("fixtures/sample0.plain.txt"), built);
}

test "render_plain transform matches golden sample1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const built = try buildPlain(a, @embedFile("fixtures/sample1.jsonl"), 110);
    try std.testing.expectEqualStrings(@embedFile("fixtures/sample1.plain.txt"), built);
}

test "render_plain transform matches golden sample2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const built = try buildPlain(a, @embedFile("fixtures/sample2.jsonl"), 110);
    try std.testing.expectEqualStrings(@embedFile("fixtures/sample2.plain.txt"), built);
}

test "render_plain keeps table cells wider than 32 chars intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jsonl =
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"| Field | Value |\n|---|---|\n| Redirect URI | https://mist.findhotel.workers.dev/auth/callback |\n"}]}}
        \\
    ;
    const built = try buildPlain(a, jsonl, 110);
    try std.testing.expect(std.mem.indexOf(u8, built, "https://mist.findhotel.workers.dev/auth/callback") != null);
}

test "rtrim drops trailing space/tab/cr only" {
    try std.testing.expectEqualStrings("abc", rtrim("abc   \t\r"));
    try std.testing.expectEqualStrings("a b", rtrim("a b"));
    try std.testing.expectEqualStrings("", rtrim("  \t"));
    try std.testing.expectEqualStrings("  x", rtrim("  x"));
}

test "stripAnsi removes CSI and keeps OSC-8 visible text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // CSI color codes around text, plus an OSC-8 hyperlink wrapping "click".
    const in = "\x1b[1;32mgreen\x1b[0m \x1b]8;;https://x.test\x07click\x1b]8;;\x07!";
    const got = try stripAnsi(a, in);
    try std.testing.expectEqualStrings("green click!", got);
}

test "renderColored keeps color" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const in_path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "in.jsonl" });
    defer a.free(in_path);

    const jsonl =
        \\{"type":"user","message":{"role":"user","content":"hello"}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi there"}]}}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "in.jsonl", .data = jsonl });

    const out = try renderColored(a, in_path, 80);
    defer a.free(out);
    // Color is preserved in the body (an ESC sequence is present).
    try std.testing.expect(std.mem.indexOfScalar(u8, out, 0x1b) != null);
}

test "renderPlain file round-trip produces non-empty, no trailing whitespace" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // tmpDir lives at `.zig-cache/tmp/<sub_path>` relative to cwd, which is the
    // same cwd renderPlain resolves its paths against.
    const in_path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "in.jsonl" });
    defer a.free(in_path);
    const out_path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "out.txt" });
    defer a.free(out_path);

    const jsonl =
        \\{"type":"user","message":{"role":"user","content":"hello world"}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi there"}]}}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "in.jsonl", .data = jsonl });

    try renderPlain(a, in_path, out_path, 80);

    const got = try tmp.dir.readFileAlloc(io, "out.txt", a, .unlimited);
    defer a.free(got);
    try std.testing.expect(got.len > 0);
    // No line may carry trailing ' ', '\t', or '\r'.
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const last = line[line.len - 1];
        try std.testing.expect(last != ' ' and last != '\t' and last != '\r');
    }
}
