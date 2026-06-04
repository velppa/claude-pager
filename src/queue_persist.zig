//! Prompt-queue persistence layer for claude-pager, porting the queue
//! serialize/load/lock/fingerprint code from `bin/pager.c`. The on-disk format
//! is line-based: each queue item is one line, terminated by '\n'. A line is
//! either a JSON object `{...}` (when the item carries an id/added_us/raw_json
//! or its prompt contains control characters) or a bare prompt string.
//!
//! C references (bin/pager.c):
//!   - JSON escape:          queue_json_escape          (1297)
//!   - per-item serialize:   queue_serialize_json_item  (1475)
//!   - per-item line:        queue_serialize_item_line  (1532)
//!   - load/parse:           queue_load_from_disk       (1971)
//!   - fingerprint (FNV-1a): queue_hash_update (1327), queue_hash_hex (1339),
//!                           queue_fingerprint_file (1344)
//!   - lock path/open/close: queue_lock_path_for (1366), queue_lock_open (1375),
//!                           queue_lock_close (1387)
//!   - path resolution:      queue_compact_key (1029),
//!                           pager_queue_attachment_for_transcript (1043)
//!   - json helpers:         jws (620), jfind (648), jstr (669)

const std = @import("std");

/// On-disk format version. Mirrors PAGER_QUEUE_FORMAT_VERSION (bin/pager.h:6).
/// The format is line-based and carries no explicit version marker on disk;
/// this constant exists for parity / future use, matching the C header.
pub const QUEUE_FORMAT_VERSION = 1;

/// Offset basis used by the C hash (bin/pager.c:1353,1991). This is the literal
/// constant the C uses — note it is NOT the canonical FNV-1a 64 basis
/// (0xcbf29ce484222325); it is the (truncated) 1469598103934665603. We mirror it
/// exactly so fingerprints match the C and on-disk files stay interchangeable.
const FNV_OFFSET: u64 = 1469598103934665603;
/// FNV-1a 64-bit prime (bin/pager.c:1334).
const FNV_PRIME: u64 = 1099511628211;

pub const QueueItem = struct {
    prompt: []u8,
    persisted_id: ?[]u8,
    added_us: i64,
    has_added_us: bool,
    encoding_json: bool,
    raw_json: ?[]u8,
};

// ── JSON escape ──────────────────────────────────────────────────────────────

/// Append `src` to `out` with C's queue_json_escape rules (bin/pager.c:1297):
/// '\\' and '"' are backslash-escaped, '\n'/'\r'/'\t' become \n/\r/\t, other
/// control bytes (< 0x20) are dropped, everything >= 0x20 is copied verbatim.
fn appendEscaped(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, src: []const u8) !void {
    for (src) |c| {
        switch (c) {
            '\\', '"' => {
                try out.append(alloc, '\\');
                try out.append(alloc, c);
            },
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (c >= 0x20) try out.append(alloc, c);
                // control bytes < 0x20 are dropped (matches C)
            },
        }
    }
}

// ── Serialize ────────────────────────────────────────────────────────────────

/// Serialize one item as a single line (no trailing '\n'), mirroring C
/// queue_serialize_item_line (bin/pager.c:1532). The bare-string fast path is
/// used only when the item has no id/added_us/raw_json, is not JSON-encoding,
/// and the prompt contains no '\n'/'\r'. Otherwise a JSON object is emitted.
fn serializeItem(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, item: QueueItem) !void {
    const bare_ok = !item.encoding_json and
        item.persisted_id == null and
        !item.has_added_us and
        item.raw_json == null and
        std.mem.indexOfScalar(u8, item.prompt, '\n') == null and
        std.mem.indexOfScalar(u8, item.prompt, '\r') == null;
    if (bare_ok) {
        try out.appendSlice(alloc, item.prompt);
        return;
    }

    // JSON object form. Field order mirrors queue_serialize_json_item:
    // [passthrough raw_json fields except id/prompt/added_us], id, prompt, added_us.
    try out.append(alloc, '{');
    var need_comma = false;

    if (item.raw_json) |raw| {
        if (raw.len > 0 and raw[0] == '{') {
            try appendRawPassthrough(out, alloc, raw, &need_comma);
        }
    }

    if (item.persisted_id) |id| {
        if (id.len > 0) {
            if (need_comma) try out.append(alloc, ',');
            try out.appendSlice(alloc, "\"id\":\"");
            try appendEscaped(out, alloc, id);
            try out.append(alloc, '"');
            need_comma = true;
        }
    }

    if (need_comma) try out.append(alloc, ',');
    try out.appendSlice(alloc, "\"prompt\":\"");
    try appendEscaped(out, alloc, item.prompt);
    try out.append(alloc, '"');
    need_comma = true;

    if (item.has_added_us) {
        try out.append(alloc, ',');
        try out.print(alloc, "\"added_us\":{d}", .{item.added_us});
    }

    try out.append(alloc, '}');
}

/// Copy raw_json object entries verbatim, skipping the "id", "prompt" and
/// "added_us" keys (which are re-emitted from the typed fields). Mirrors the
/// passthrough loop in queue_serialize_json_item (bin/pager.c:1487-1514).
fn appendRawPassthrough(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    raw: []const u8,
    need_comma: *bool,
) !void {
    var p: usize = 1; // skip '{'
    p = skipWs(raw, p);
    while (p < raw.len and raw[p] != '}') {
        if (raw[p] != '"') return; // malformed; bail (C returns 0/error, we just stop)
        const entry_start = p;
        const key_end = skipJsonString(raw, p) orelse return;
        const key = raw[p + 1 .. key_end - 1];
        var q = skipWs(raw, key_end);
        if (q >= raw.len or raw[q] != ':') return;
        q = skipWs(raw, q + 1);
        const value_end = skipJsonValue(raw, q) orelse return;

        const is_reserved = std.mem.eql(u8, key, "id") or
            std.mem.eql(u8, key, "prompt") or
            std.mem.eql(u8, key, "added_us");
        if (!is_reserved) {
            if (need_comma.*) try out.append(alloc, ',');
            try out.appendSlice(alloc, raw[entry_start..value_end]);
            need_comma.* = true;
        }

        p = skipWs(raw, value_end);
        if (p < raw.len and raw[p] == ',') p = skipWs(raw, p + 1);
    }
}

/// Serialize all items into the on-disk byte stream: each item line followed by
/// '\n'. Mirrors the line-writing loops in queue_append_prompt /
/// queue_write_all_items (bin/pager.c:1850-1856, 1905-1921). Caller owns result.
pub fn serialize(alloc: std.mem.Allocator, items: []const QueueItem) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (items) |item| {
        try serializeItem(&out, alloc, item);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

// ── Minimal JSON scanning helpers (port of jws/jskip_s/jskip/jfind/jstr) ──────

fn skipWs(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
    return i;
}

/// Given index `i` at an opening '"', return the index just past the closing
/// quote, or null if unterminated. Mirrors queue_skip_json_string / jskip_s.
fn skipJsonString(s: []const u8, i: usize) ?usize {
    if (i >= s.len or s[i] != '"') return null;
    var p = i + 1;
    while (p < s.len) {
        if (s[p] == '\\') {
            p += 1;
            if (p < s.len) p += 1;
            continue;
        }
        if (s[p] == '"') return p + 1;
        p += 1;
    }
    return null;
}

/// Skip a JSON value starting at `i`, returning the index just past it.
/// Mirrors queue_skip_json_value (bin/pager.c:1408).
fn skipJsonValue(s: []const u8, i: usize) ?usize {
    if (i >= s.len) return null;
    const c = s[i];
    if (c == '"') return skipJsonString(s, i);
    if (c == '{' or c == '[') {
        const close: u8 = if (c == '{') '}' else ']';
        var depth: i32 = 1;
        var p = i + 1;
        while (p < s.len) {
            if (s[p] == '"') {
                p = skipJsonString(s, p) orelse return null;
                continue;
            }
            if (s[p] == c) {
                depth += 1;
            } else if (s[p] == close) {
                depth -= 1;
                p += 1;
                if (depth == 0) return p;
                continue;
            }
            p += 1;
        }
        return null;
    }
    var p = i;
    while (p < s.len and !isPrimitiveTerminator(s[p])) p += 1;
    return p;
}

fn isPrimitiveTerminator(c: u8) bool {
    return c == ',' or c == '}' or c == ']' or c == '\r' or c == '\n' or c == '\t' or c == ' ';
}

/// Find the value position for `key` in a JSON object slice. Returns the index
/// of the first byte of the value (after ':' and whitespace), or null.
/// Mirrors jfind (bin/pager.c:648).
fn jfind(s: []const u8, key: []const u8) ?usize {
    var p = skipWs(s, 0);
    if (p < s.len and s[p] == '{') p += 1;
    while (p < s.len and s[p] != '}') {
        p = skipWs(s, p);
        if (p >= s.len or s[p] != '"') break;
        const ks = p + 1;
        const after = skipJsonString(s, p) orelse break;
        const kn = after - 1 - ks; // bytes between the quotes
        p = skipWs(s, after);
        if (p < s.len and s[p] == ':') p = skipWs(s, p + 1);
        if (kn == key.len and std.mem.eql(u8, s[ks .. ks + kn], key)) return p;
        p = skipJsonValue(s, p) orelse break;
        p = skipWs(s, p);
        if (p < s.len and s[p] == ',') p += 1;
    }
    return null;
}

/// Decode a JSON string value starting at index `i` (which must be at '"').
/// Returns a freshly-allocated decoded string. Mirrors jstr (bin/pager.c:669):
/// handles \n \t \r(dropped) \" \\ \/ \uXXXX (BMP, UTF-8 encoded); unknown
/// escapes pass the following byte through literally.
fn jstrDecode(alloc: std.mem.Allocator, s: []const u8, i: usize) !?[]u8 {
    if (i >= s.len or s[i] != '"') return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var p = i + 1;
    while (p < s.len and s[p] != '"') {
        if (s[p] == '\\') {
            p += 1;
            if (p >= s.len) break;
            switch (s[p]) {
                'n' => try out.append(alloc, '\n'),
                't' => try out.append(alloc, '\t'),
                'r' => {}, // C drops '\r'
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                '/' => try out.append(alloc, '/'),
                'u' => {
                    var cp: u21 = 0;
                    var j: usize = 1;
                    while (j <= 4 and p + j < s.len) : (j += 1) {
                        const ch = s[p + j];
                        const nyb: u21 = if (ch >= '0' and ch <= '9')
                            @intCast(ch - '0')
                        else if (ch >= 'a' and ch <= 'f')
                            @intCast(ch - 'a' + 10)
                        else if (ch >= 'A' and ch <= 'F')
                            @intCast(ch - 'A' + 10)
                        else
                            break;
                        cp = (cp << 4) | nyb;
                    }
                    p += 4;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch blk: {
                        buf[0] = @intCast(cp & 0x7f);
                        break :blk @as(usize, 1);
                    };
                    try out.appendSlice(alloc, buf[0..n]);
                },
                else => try out.append(alloc, s[p]),
            }
            p += 1;
        } else {
            try out.append(alloc, s[p]);
            p += 1;
        }
    }
    return try out.toOwnedSlice(alloc);
}

// ── Load ─────────────────────────────────────────────────────────────────────

/// Parse the on-disk byte stream into items. Splits on '\n', strips trailing
/// '\r'/'\n', skips empty lines. A line beginning with '{' that has a "prompt"
/// string is parsed as a JSON item (reading "id", "prompt", "added_us");
/// otherwise the whole line is taken as a bare prompt. Mirrors
/// queue_load_from_disk (bin/pager.c:1971). Items allocated in `alloc`.
pub fn load(alloc: std.mem.Allocator, json: []const u8) ![]QueueItem {
    var items: std.ArrayListUnmanaged(QueueItem) = .empty;
    errdefer {
        for (items.items) |it| freeItem(alloc, it);
        items.deinit(alloc);
    }

    var it = std.mem.splitScalar(u8, json, '\n');
    while (it.next()) |raw_line| {
        var line = raw_line;
        // strip trailing '\r' (and any '\n' already removed by the split)
        while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == '\n')) {
            line = line[0 .. line.len - 1];
        }
        if (line.len == 0) continue;

        if (line[0] == '{') {
            if (jfind(line, "prompt")) |pv| {
                if (pv < line.len and line[pv] == '"') {
                    const prompt = (try jstrDecode(alloc, line, pv)) orelse {
                        // shouldn't happen since line[pv]=='"'; fall through to bare
                        try appendBare(&items, alloc, line);
                        continue;
                    };
                    var id: ?[]u8 = null;
                    if (jfind(line, "id")) |iv| {
                        if (iv < line.len and line[iv] == '"') {
                            const decoded = try jstrDecode(alloc, line, iv);
                            if (decoded) |d| {
                                if (d.len > 0) id = d else alloc.free(d);
                            }
                        }
                    }
                    var added_us: i64 = 0;
                    var has_added_us = false;
                    if (jfind(line, "added_us")) |av| {
                        has_added_us = true;
                        added_us = parseI64(line, av);
                    }
                    const raw_copy = try alloc.dupe(u8, line);
                    items.append(alloc, .{
                        .prompt = prompt,
                        .persisted_id = id,
                        .added_us = added_us,
                        .has_added_us = has_added_us,
                        .encoding_json = true,
                        .raw_json = raw_copy,
                    }) catch |e| {
                        alloc.free(prompt);
                        if (id) |d| alloc.free(d);
                        alloc.free(raw_copy);
                        return e;
                    };
                    continue;
                }
            }
            // '{' line without a usable "prompt": treat whole line as bare prompt.
            try appendBare(&items, alloc, line);
        } else {
            try appendBare(&items, alloc, line);
        }
    }
    return items.toOwnedSlice(alloc);
}

fn appendBare(items: *std.ArrayListUnmanaged(QueueItem), alloc: std.mem.Allocator, line: []const u8) !void {
    const prompt = try alloc.dupe(u8, line);
    items.append(alloc, .{
        .prompt = prompt,
        .persisted_id = null,
        .added_us = 0,
        .has_added_us = false,
        .encoding_json = false,
        .raw_json = null,
    }) catch |e| {
        alloc.free(prompt);
        return e;
    };
}

/// Parse a leading decimal i64 from `s` at index `i` after skipping whitespace.
/// Mirrors `strtoll(jws(av), NULL, 10)` (bin/pager.c:2008).
fn parseI64(s: []const u8, i: usize) i64 {
    var p = skipWs(s, i);
    var neg = false;
    if (p < s.len and (s[p] == '+' or s[p] == '-')) {
        neg = s[p] == '-';
        p += 1;
    }
    var v: i64 = 0;
    while (p < s.len and s[p] >= '0' and s[p] <= '9') : (p += 1) {
        v = v *% 10 +% @as(i64, s[p] - '0');
    }
    return if (neg) -v else v;
}

/// Free one item's owned allocations. Useful when `load`'s result was made with
/// a non-arena allocator (the public API allocates each field with `alloc`).
pub fn freeItem(alloc: std.mem.Allocator, item: QueueItem) void {
    alloc.free(item.prompt);
    if (item.persisted_id) |id| alloc.free(id);
    if (item.raw_json) |r| alloc.free(r);
}

/// Free a slice of items and the slice itself (companion to `load`).
pub fn freeItems(alloc: std.mem.Allocator, items: []QueueItem) void {
    for (items) |it| freeItem(alloc, it);
    alloc.free(items);
}

// ── Fingerprint ──────────────────────────────────────────────────────────────

/// 16-hex-char FNV-1a 64-bit fingerprint of `bytes`, matching
/// queue_fingerprint_file + queue_hash_update + queue_hash_hex
/// (bin/pager.c:1327-1364). Hashes the raw bytes (including newlines) and
/// formats as lowercase "%016llx".
pub fn fingerprint(bytes: []const u8) [16]u8 {
    var hash: u64 = FNV_OFFSET;
    for (bytes) |b| {
        hash ^= @as(u64, b);
        hash *%= FNV_PRIME;
    }
    var out: [16]u8 = undefined;
    const hexdigits = "0123456789abcdef";
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        out[i] = hexdigits[@as(usize, (hash >> shift) & 0xf)];
    }
    return out;
}

// ── Queue file path resolution ───────────────────────────────────────────────

/// getenv equivalent for 0.16: scan the POSIX `environ` global directly,
/// matching C getenv() semantics without allocation (same idiom as
/// src/links.zig:getEnv / src/log.zig:getenv).
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

/// Compact a key into the dest buffer: alnum/'-'/'_'/'.' pass through, all other
/// bytes become '_'. Empty input yields "default". Mirrors queue_compact_key
/// (bin/pager.c:1029). Returns the written slice of `dst`.
fn compactKey(dst: []u8, src: []const u8) []const u8 {
    var i: usize = 0;
    for (src) |c| {
        if (i + 1 >= dst.len) break;
        const ok = (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            c == '-' or c == '_' or c == '.';
        dst[i] = if (ok) c else '_';
        i += 1;
    }
    if (i == 0) {
        const def = "default";
        @memcpy(dst[0..def.len], def);
        return dst[0..def.len];
    }
    return dst[0..i];
}

/// Resolve the queue file path for `transcript` into `out`, returning the slice.
/// Mirrors pager_queue_attachment_for_transcript + queue_init_path
/// (bin/pager.c:1043-1100): key is the compacted CLAUDE_SESSION_ID if set,
/// else the compacted transcript basename without extension, else "default";
/// path is "$HOME/.claude/queues/<key>.queue". Errors if HOME is unset/empty.
pub fn queuePathFor(transcript: []const u8, out: []u8) ![]const u8 {
    const home = getEnv("HOME") orelse return error.NoHome;
    if (home.len == 0) return error.NoHome;

    var keybuf: [160]u8 = undefined;
    var key: []const u8 = undefined;

    if (getEnv("CLAUDE_SESSION_ID")) |sid| {
        if (sid.len > 0) {
            key = compactKey(&keybuf, sid);
        } else {
            key = keyFromTranscript(&keybuf, transcript);
        }
    } else {
        key = keyFromTranscript(&keybuf, transcript);
    }

    return std.fmt.bufPrint(out, "{s}/.claude/queues/{s}.queue", .{ home, key });
}

/// Derive the compact key from a transcript path: take the basename, drop the
/// last '.'-extension, then compact. Empty transcript yields "default".
/// Mirrors bin/pager.c:1060-1070.
fn keyFromTranscript(keybuf: []u8, transcript: []const u8) []const u8 {
    if (transcript.len == 0) return compactKey(keybuf, "default");
    var base = transcript;
    if (std.mem.lastIndexOfScalar(u8, transcript, '/')) |slash| base = transcript[slash + 1 ..];
    // drop last extension
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base = base[0..dot];
    return compactKey(keybuf, base);
}

// ── Locking ──────────────────────────────────────────────────────────────────

/// Advisory exclusive lock over a queue file, using a sibling ".<name>.lock"
/// file. Mirrors queue_lock_path_for / queue_lock_open / queue_lock_close
/// (bin/pager.c:1366-1391): open(O_CREAT|O_RDWR, 0600) then flock(LOCK_EX),
/// release with flock(LOCK_UN) + close.
pub const Lock = struct {
    fd: std.posix.fd_t,

    /// Compute the lock path "<dir>/.<basename>.lock" for `path` into `out`.
    /// Mirrors queue_lock_path_for (bin/pager.c:1366). Requires `path` to
    /// contain a '/'.
    fn lockPathFor(path: []const u8, out: []u8) ![]const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.NoDirInPath;
        const dir = path[0 .. slash + 1]; // includes trailing '/'
        const base = path[slash + 1 ..];
        return std.fmt.bufPrint(out, "{s}.{s}.lock", .{ dir, base });
    }

    pub fn acquire(path: []const u8) !Lock {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const lock_path = try lockPathFor(path, &buf);
        // NUL-terminate for openat.
        var pathz: [std.fs.max_path_bytes]u8 = undefined;
        if (lock_path.len >= pathz.len) return error.NameTooLong;
        @memcpy(pathz[0..lock_path.len], lock_path);
        pathz[lock_path.len] = 0;

        const fd = try std.posix.openatZ(
            std.posix.AT.FDCWD,
            pathz[0..lock_path.len :0],
            .{ .ACCMODE = .RDWR, .CREAT = true },
            0o600,
        );
        errdefer _ = std.c.close(fd);
        // std 0.16 has no std.posix.flock wrapper; call libc flock directly,
        // matching C queue_lock_open's flock(fd, LOCK_EX) (bin/pager.c:1380).
        if (std.c.flock(fd, std.posix.LOCK.EX) != 0) return error.LockFailed;
        return .{ .fd = fd };
    }

    pub fn release(self: Lock) void {
        _ = std.c.flock(self.fd, std.posix.LOCK.UN);
        _ = std.c.close(self.fd);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "serialize then load roundtrips an item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]QueueItem{.{
        .prompt = try a.dupe(u8, "hello \"world\"\n"),
        .persisted_id = null,
        .added_us = 123456,
        .has_added_us = true,
        .encoding_json = false,
        .raw_json = null,
    }};
    const json = try serialize(a, &items);
    const back = try load(a, json);
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings("hello \"world\"\n", back[0].prompt);
    try std.testing.expectEqual(@as(i64, 123456), back[0].added_us);
}

test "fingerprint stable and length 16" {
    const a = fingerprint("abc");
    const b = fingerprint("abc");
    try std.testing.expectEqualSlices(u8, &a, &b);
    try std.testing.expect(fingerprint("abc").len == 16);
}

test "queuePathFor is deterministic" {
    var buf1: [4096]u8 = undefined;
    var buf2: [4096]u8 = undefined;
    const p1 = try queuePathFor("/x/y/transcript.jsonl", &buf1);
    const p2 = try queuePathFor("/x/y/transcript.jsonl", &buf2);
    try std.testing.expectEqualStrings(p1, p2);
}

test "fingerprint matches C's hash algorithm exactly" {
    // NOTE: the C offset basis (bin/pager.c:1353) is the non-canonical constant
    // 1469598103934665603 (0x14650fb0739d0383), NOT the textbook FNV-1a basis
    // 0xcbf29ce484222325. We deliberately match the C so on-disk files stay
    // interchangeable. Values below are produced by the same byte-for-byte loop.
    try std.testing.expectEqualStrings("e16801510db89efd", &fingerprint("abc"));
    // Empty input yields the (truncated) offset basis in hex.
    try std.testing.expectEqualStrings("14650fb0739d0383", &fingerprint(""));
}

test "bare prompt serializes without JSON wrapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]QueueItem{.{
        .prompt = try a.dupe(u8, "just a plain prompt"),
        .persisted_id = null,
        .added_us = 0,
        .has_added_us = false,
        .encoding_json = false,
        .raw_json = null,
    }};
    const json = try serialize(a, &items);
    try std.testing.expectEqualStrings("just a plain prompt\n", json);
}

test "JSON item serializes with id, prompt, added_us in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]QueueItem{.{
        .prompt = try a.dupe(u8, "hi\tthere"),
        .persisted_id = try a.dupe(u8, "1700000000"),
        .added_us = 1700000000,
        .has_added_us = true,
        .encoding_json = true,
        .raw_json = null,
    }};
    const json = try serialize(a, &items);
    try std.testing.expectEqualStrings(
        "{\"id\":\"1700000000\",\"prompt\":\"hi\\tthere\",\"added_us\":1700000000}\n",
        json,
    );
}

test "load parses JSON item fields and escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const disk = "{\"id\":\"abc\",\"prompt\":\"line1\\nline2\",\"added_us\":42}\n";
    const back = try load(a, disk);
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings("line1\nline2", back[0].prompt);
    try std.testing.expect(back[0].persisted_id != null);
    try std.testing.expectEqualStrings("abc", back[0].persisted_id.?);
    try std.testing.expectEqual(@as(i64, 42), back[0].added_us);
    try std.testing.expect(back[0].has_added_us);
    try std.testing.expect(back[0].encoding_json);
}

test "raw_json passthrough preserves extra fields, drops reserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]QueueItem{.{
        .prompt = try a.dupe(u8, "p"),
        .persisted_id = try a.dupe(u8, "id1"),
        .added_us = 7,
        .has_added_us = true,
        .encoding_json = true,
        .raw_json = try a.dupe(u8, "{\"extra\":\"keep\",\"id\":\"old\",\"prompt\":\"old\"}"),
    }};
    const json = try serialize(a, &items);
    try std.testing.expectEqualStrings(
        "{\"extra\":\"keep\",\"id\":\"id1\",\"prompt\":\"p\",\"added_us\":7}\n",
        json,
    );
}

test "load: bare line becomes plain prompt item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const back = try load(a, "plain one\nplain two\n");
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("plain one", back[0].prompt);
    try std.testing.expectEqualStrings("plain two", back[1].prompt);
    try std.testing.expect(!back[0].encoding_json);
    try std.testing.expect(back[0].persisted_id == null);
}

test "load with std.testing.allocator frees cleanly" {
    const a = std.testing.allocator;
    const disk = "{\"id\":\"x\",\"prompt\":\"hello\",\"added_us\":1}\nbare\n";
    const back = try load(a, disk);
    defer freeItems(a, back);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("hello", back[0].prompt);
    try std.testing.expectEqualStrings("bare", back[1].prompt);
}

test "queuePathFor uses transcript basename without extension" {
    var buf: [4096]u8 = undefined;
    const home = getEnv("HOME") orelse return error.SkipZigTest;
    const p = try queuePathFor("/some/dir/my-transcript.jsonl", &buf);
    const expect = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/.claude/queues/my-transcript.queue",
        .{home},
    );
    defer std.testing.allocator.free(expect);
    try std.testing.expectEqualStrings(expect, p);
}

test "Lock acquire/release on a temp file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "t.queue" });
    defer a.free(path);

    const lock = try Lock.acquire(path);
    lock.release();
    // Re-acquire after release must succeed.
    const lock2 = try Lock.acquire(path);
    lock2.release();
}

test "roundtrip of multiple mixed items preserves order and content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]QueueItem{
        .{
            .prompt = try a.dupe(u8, "first \\ backslash"),
            .persisted_id = try a.dupe(u8, "1"),
            .added_us = 10,
            .has_added_us = true,
            .encoding_json = true,
            .raw_json = null,
        },
        .{
            .prompt = try a.dupe(u8, "second plain"),
            .persisted_id = null,
            .added_us = 0,
            .has_added_us = false,
            .encoding_json = false,
            .raw_json = null,
        },
    };
    const json = try serialize(a, &items);
    const back = try load(a, json);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("first \\ backslash", back[0].prompt);
    try std.testing.expectEqualStrings("1", back[0].persisted_id.?);
    try std.testing.expectEqualStrings("second plain", back[1].prompt);
    try std.testing.expect(back[1].persisted_id == null);
}
