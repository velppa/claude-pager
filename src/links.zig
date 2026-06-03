//! links.zig — OSC-8 hyperlink linkification plus URL/path shortening and
//! file-URI helpers.
//!
//! Ported from bin/pager.c:2287-2954 (the "OSC-8 linkification" section):
//!  - linkify            ← linkify (bin/pager.c:2530-2671)
//!  - shortenUrl         ← shorten_url (bin/pager.c:2447-2490)
//!  - shortenPath        ← shorten_path (bin/pager.c:2493-2528)
//!  - buildFileUriTarget ← build_file_uri_target (bin/pager.c:2349-2366) and
//!    its helpers uri_path_is_safe / uri_encode_path / expand_path_to_abs.
//!  - LinkSpan           ← LinkSpan (bin/pager.c:150-155)
//!
//! Fidelity target: output is byte-compared to the C goldens. The OSC-8 byte
//! sequence matches the C exactly:
//!   opener:  ESC ] 8 ; ; <uri> BEL
//!   label:   BO C_URL UL_ON <visible> UL_OFF ESC[22m
//!   closer:  ESC ] 8 ; ; BEL
//! (The C uses BEL (0x07) as the OSC terminator, NOT ST (ESC '\'); see
//! bin/pager.c:2593-2599 and 2646-2652.)
//!
//! All escape sequences and glyphs come from `ansi.zig`, which mirrors the same
//! C #defines, so bytes match the C. Column/length math uses byte-count
//! semantics matching the C (no Unicode width).

const std = @import("std");
const ansi = @import("ansi.zig");

pub const LinkSpan = struct {
    row: usize,
    x0: usize,
    x1: usize,
    uri: []const u8,
};

// ── Character-class predicates (bin/pager.c:2289-2308) ──────────────────────

// is_urlch (bin/pager.c:2289-2293)
fn isUrlCh(c: u8) bool {
    if (c <= ' ') return false;
    if (c == '<' or c == '>' or c == '"' or c == '\'' or c == '\\' or
        c == ')' or c == '}' or c == ']') return false;
    return true;
}

// is_path_token_char (bin/pager.c:2295-2298)
fn isPathTokenChar(c: u8) bool {
    if (c == 0 or c == '\n' or c == '\r' or c == '\t' or c == '\x1b') return false;
    return true;
}

// is_path_lead_boundary (bin/pager.c:2300-2308)
fn isPathLeadBoundary(c: u8) bool {
    if ((c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '-' or c == '.' or c == '/' or c == '~')
    {
        return false;
    }
    return true;
}

// path_looks_valid (bin/pager.c:2310-2316)
fn pathLooksValid(s: []const u8) bool {
    const n = s.len;
    if (n < 2) return false;
    if (!(s[0] == '/' or (s[0] == '~' and n >= 3 and s[1] == '/'))) return false;
    var slash = false;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        if (s[i] == '/') {
            slash = true;
            break;
        }
    }
    return slash;
}

// ── URI encoding helpers (bin/pager.c:2368-2419) ────────────────────────────

// uri_is_unreserved (bin/pager.c:2368-2373)
fn uriIsUnreserved(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '.' or c == '_' or c == '~' or c == '/';
}

// uri_path_is_safe (bin/pager.c:2375-2381)
fn uriPathIsSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |c| {
        if (!uriIsUnreserved(c)) return false;
    }
    return true;
}

// uri_encode_path (bin/pager.c:2383-2399), appending to a growable buffer.
fn uriEncodePath(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, src: []const u8) !void {
    const hx = "0123456789ABCDEF";
    for (src) |c| {
        if (uriIsUnreserved(c)) {
            try out.append(alloc, c);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, hx[(c >> 4) & 0xF]);
            try out.append(alloc, hx[c & 0xF]);
        }
    }
}

// getenv equivalent for 0.16: scan the POSIX `environ` global directly.
// getEnv was removed; std.process.getEnvVarOwned requires an
// allocator and would error on missing vars. Reading `environ` matches the C
// getenv() semantics (NUL-terminated "KEY=VALUE" entries) without allocation.
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

// expand_path_to_abs (bin/pager.c:2401-2419). Returns null on failure (matches
// the C returning 0 / not building a target). Uses HOME from the environment.
fn expandPathToAbs(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (path.len == 0) return null;
    if (path[0] == '/') {
        return try alloc.dupe(u8, path);
    }
    if (path[0] == '~' and path.len >= 2 and path[1] == '/') {
        const home = getEnv("HOME") orelse return null;
        if (home.len == 0) return null;
        // home + path[1..]
        var buf = try alloc.alloc(u8, home.len + path.len - 1);
        @memcpy(buf[0..home.len], home);
        @memcpy(buf[home.len..], path[1..]);
        return buf;
    }
    return null;
}

// allow_remote_file_links (bin/pager.c:2334-2343). The C caches a global and
// honors SSH_CONNECTION/SSH_TTY plus CLAUDE_PAGER_LINK_REMOTE. Ported as a pure
// function reading the environment each call.
fn allowRemoteFileLinks() bool {
    const remote = (getEnv("SSH_CONNECTION") != null) or
        (getEnv("SSH_TTY") != null);
    if (!remote) return true;
    return envEnabled("CLAUDE_PAGER_LINK_REMOTE");
}

// env_enabled equivalent: non-empty and not "0"/"false"/"no"/"off".
fn envEnabled(name: []const u8) bool {
    const v = getEnv(name) orelse return false;
    if (v.len == 0) return false;
    if (std.mem.eql(u8, v, "0") or
        std.ascii.eqlIgnoreCase(v, "false") or
        std.ascii.eqlIgnoreCase(v, "no") or
        std.ascii.eqlIgnoreCase(v, "off")) return false;
    return true;
}

/// Build a `file://` URI target from a path (build_file_uri_target,
/// bin/pager.c:2349-2366). Returns an empty slice when the C would return 0
/// (remote links disabled or path expansion failed).
pub fn buildFileUriTarget(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return try alloc.dupe(u8, "");
    if (!allowRemoteFileLinks()) return try alloc.dupe(u8, "");

    if (path[0] == '/' and uriPathIsSafe(path)) {
        return try std.fmt.allocPrint(alloc, "file://{s}", .{path});
    }

    const abs = (try expandPathToAbs(alloc, path)) orelse return try alloc.dupe(u8, "");
    defer alloc.free(abs);

    var enc: std.ArrayListUnmanaged(u8) = .empty;
    defer enc.deinit(alloc);
    try uriEncodePath(&enc, alloc, abs);
    return try std.fmt.allocPrint(alloc, "file://{s}", .{enc.items});
}

// ── Display shortening (bin/pager.c:2446-2528) ──────────────────────────────

/// Shorten a URL for display: strip http(s):// scheme, truncate with an
/// ellipsis (shorten_url, bin/pager.c:2447-2490). `max` is unused beyond
/// preserving the public signature; the C hard-codes a 60-visible-char budget.
pub fn shortenUrl(alloc: std.mem.Allocator, url: []const u8, max: usize) ![]u8 {
    _ = max;
    var d = url;
    if (d.len >= 8 and std.mem.eql(u8, d[0..8], "https://")) {
        d = d[8..];
    } else if (d.len >= 7 and std.mem.eql(u8, d[0..7], "http://")) {
        d = d[7..];
    }
    const dlen = d.len;

    if (dlen <= 60) {
        return try alloc.dupe(u8, d);
    }

    const sl = std.mem.indexOfScalar(u8, d, '/');
    if (sl == null) {
        // 59 head chars + ellipsis
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(alloc, d[0..59]);
        try out.appendSlice(alloc, ansi.ell);
        return try out.toOwnedSlice(alloc);
    }

    const domlen = sl.? + 1; // include the slash
    const avail = @as(i64, 60) - @as(i64, @intCast(domlen)) - 1; // 1 visible char for …
    if (avail < 8) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(alloc, d[0..59]);
        try out.appendSlice(alloc, ansi.ell);
        return try out.toOwnedSlice(alloc);
    }

    var tail: i64 = @divTrunc(avail, 3);
    if (tail > 20) tail = 20;
    var head: i64 = avail - tail;
    const path = d[domlen..];
    const pathlen: i64 = @intCast(path.len); // dlen - domlen
    if (tail > pathlen) tail = pathlen;
    if (head > pathlen) head = pathlen;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(alloc, d[0..domlen]);
    const hc: usize = @intCast(if (head < pathlen) head else pathlen);
    try out.appendSlice(alloc, path[0..hc]);
    try out.appendSlice(alloc, ansi.ell);
    if (tail > 0 and pathlen > tail) {
        const t: usize = @intCast(tail);
        try out.appendSlice(alloc, path[path.len - t ..]);
    }
    return try out.toOwnedSlice(alloc);
}

/// Shorten a filesystem path for display: …/parent/filename (shorten_path,
/// bin/pager.c:2493-2528). `max` preserves the public signature; the C
/// hard-codes a 50-visible-char budget.
pub fn shortenPath(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    _ = max;
    const plen = path.len;
    if (plen <= 50) {
        return try alloc.dupe(u8, path);
    }

    // Find last two slashes (scanning backwards).
    var last: ?usize = null;
    var prev: ?usize = null;
    var i: i64 = @as(i64, @intCast(plen)) - 1;
    while (i >= 0) : (i -= 1) {
        const idx: usize = @intCast(i);
        if (path[idx] == '/') {
            if (last == null) {
                last = idx;
            } else if (prev == null) {
                prev = idx;
                break;
            }
        }
    }

    if (last == null) {
        // ELL "/" + up to 48 chars of path
        const n: usize = if (plen < 48) plen else 48;
        return try std.fmt.allocPrint(alloc, "{s}/{s}", .{ ansi.ell, path[0..n] });
    }

    if (prev) |pv| {
        const slen = plen - pv; // (path+plen) - prev
        if (slen + 1 <= 50) { // +1 for … visible char
            return try std.fmt.allocPrint(alloc, "{s}{s}", .{ ansi.ell, path[pv..] });
        }
    }

    const lst = last.?;
    const flen = plen - lst; // (path+plen) - last
    if (flen + 1 <= 50) {
        return try std.fmt.allocPrint(alloc, "{s}{s}", .{ ansi.ell, path[lst..] });
    }
    // ELL "/" + 48 chars after last slash
    return try std.fmt.allocPrint(alloc, "{s}/{s}", .{ ansi.ell, path[lst + 1 .. lst + 1 + 48] });
}

// ── Table / tool-header row detection (bin/pager.c:2421-2444) ───────────────

// looks_like_table_row (bin/pager.c:2421-2433)
fn looksLikeTableRow(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.indexOf(u8, s, "\xe2\x94\x82") != null or // │
        std.mem.indexOf(u8, s, "\xe2\x94\x8c") != null or // ┌
        std.mem.indexOf(u8, s, "\xe2\x94\x9c") != null or // ├
        std.mem.indexOf(u8, s, "\xe2\x94\x94") != null) // └
        return true;
    var pipes: usize = 0;
    for (s) |c| {
        if (c == '|') pipes += 1;
    }
    if (pipes < 2) return false;
    var p: usize = 0;
    while (p < s.len and (s[p] == ' ' or s[p] == '\t')) p += 1;
    if (p < s.len and s[p] == '|') return true;
    return std.mem.indexOf(u8, s, " | ") != null;
}

// looks_like_tool_header_row (bin/pager.c:2435-2444)
fn looksLikeToolHeaderRow(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.indexOf(u8, s, ansi.bul) == null) return false; // BUL
    if (std.mem.indexOf(u8, s, "Update(") != null or
        std.mem.indexOf(u8, s, "Create(") != null or
        std.mem.indexOf(u8, s, "Edit(") != null or
        std.mem.indexOf(u8, s, "Write(") != null or
        std.mem.indexOf(u8, s, "Read ") != null)
    {
        return true;
    }
    return false;
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// Wrap detected URLs/paths in `line` with OSC-8 escapes, returning a freshly
/// allocated string. `row` is the display row recorded for click-spans; pass
/// `spans = null` to skip span recording. A span is recorded per emitted OSC-8
/// hyperlink, with x0/x1 the byte offsets of the visible label in the output.
///
/// Ported from linkify (bin/pager.c:2530-2671). The span-recording is the Zig
/// equivalent of the C's link-map tracking, simplified to one span per link.
pub fn linkify(
    alloc: std.mem.Allocator,
    line: []const u8,
    cols: usize,
    row: usize,
    spans: ?*std.ArrayListUnmanaged(LinkSpan),
) ![]u8 {
    _ = cols; // The C linkify itself does not use g_cols; span x is a byte offset.

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    const src = line;
    const compact_labels = !(looksLikeTableRow(src) or looksLikeToolHeaderRow(src));
    var in_osc8_label = false;

    var p: usize = 0;
    while (p < src.len) {
        const c = src[p];

        // Pass through ANSI CSI sequences.
        if (c == '\x1b' and p + 1 < src.len and src[p + 1] == '[') {
            try out.append(alloc, src[p]);
            p += 1;
            try out.append(alloc, src[p]);
            p += 1;
            while (p < src.len and !isAlpha(src[p]) and src[p] != '~') {
                try out.append(alloc, src[p]);
                p += 1;
            }
            if (p < src.len) {
                try out.append(alloc, src[p]);
                p += 1;
            }
            continue;
        }
        // Pass through existing OSC-8 sequences.
        if (c == '\x1b' and p + 3 < src.len and src[p + 1] == ']' and src[p + 2] == '8' and src[p + 3] == ';') {
            const payload_is_close = blk: {
                const q = p + 4;
                if (q < src.len and src[q] == '\x07') break :blk true;
                if (q + 1 < src.len and src[q] == '\x1b' and src[q + 1] == '\\') break :blk true;
                break :blk false;
            };
            while (p < src.len) {
                if (src[p] == '\x07') {
                    try out.append(alloc, src[p]);
                    p += 1;
                    break;
                }
                if (src[p] == '\x1b' and p + 1 < src.len and src[p + 1] == '\\') {
                    try out.append(alloc, src[p]);
                    p += 1;
                    try out.append(alloc, src[p]);
                    p += 1;
                    break;
                }
                try out.append(alloc, src[p]);
                p += 1;
            }
            in_osc8_label = !payload_is_close;
            continue;
        }
        // Pass through other OSC sequences.
        if (c == '\x1b' and p + 1 < src.len and src[p + 1] == ']') {
            while (p < src.len) {
                if (src[p] == '\x07') {
                    try out.append(alloc, src[p]);
                    p += 1;
                    break;
                }
                if (src[p] == '\x1b' and p + 1 < src.len and src[p + 1] == '\\') {
                    try out.append(alloc, src[p]);
                    p += 1;
                    try out.append(alloc, src[p]);
                    p += 1;
                    break;
                }
                try out.append(alloc, src[p]);
                p += 1;
            }
            continue;
        }
        // Pass through other ESC sequences.
        if (c == '\x1b') {
            try out.append(alloc, src[p]);
            p += 1;
            if (p < src.len) {
                try out.append(alloc, src[p]);
                p += 1;
            }
            continue;
        }
        if (in_osc8_label) {
            try out.append(alloc, src[p]);
            p += 1;
            continue;
        }
        // Detect URL.
        if ((p + 7 <= src.len and std.mem.eql(u8, src[p .. p + 7], "http://")) or
            (p + 8 <= src.len and std.mem.eql(u8, src[p .. p + 8], "https://")))
        {
            const start = p;
            while (p < src.len and isUrlCh(src[p])) p += 1;
            while (p > start and (src[p - 1] == '.' or src[p - 1] == ',' or
                src[p - 1] == ';' or src[p - 1] == ':')) p -= 1;
            const ulen = p - start;
            const url = src[start..p];
            if (ulen > 10) {
                const label = if (compact_labels)
                    try shortenUrl(alloc, url, 256)
                else
                    try alloc.dupe(u8, url);
                defer alloc.free(label);

                try out.appendSlice(alloc, "\x1b]8;;");
                try out.appendSlice(alloc, url);
                try out.append(alloc, '\x07');
                try out.appendSlice(alloc, ansi.bold);
                try out.appendSlice(alloc, ansi.c_url);
                try out.appendSlice(alloc, ansi.ul_on);
                const x0 = out.items.len;
                try out.appendSlice(alloc, label);
                const x1 = out.items.len;
                try out.appendSlice(alloc, ansi.ul_off);
                try out.appendSlice(alloc, "\x1b[22m");
                try out.appendSlice(alloc, "\x1b]8;;\x07");

                if (spans) |sp| {
                    try sp.append(alloc, .{
                        .row = row,
                        .x0 = x0,
                        .x1 = x1,
                        .uri = try alloc.dupe(u8, url),
                    });
                }
            } else {
                try out.appendSlice(alloc, url);
            }
            continue;
        }
        // Detect file path: /segment/segment... or ~/segment...
        if ((c == '/' or (c == '~' and p + 1 < src.len and src[p + 1] == '/')) and
            (p == 0 or isPathLeadBoundary(src[p - 1])))
        {
            const start = p;
            var sp_i = p + 1;
            while (sp_i < src.len and isPathTokenChar(src[sp_i])) {
                if (src[sp_i] == ' ') {
                    const q0 = sp_i + 1;
                    const q_is_path_start = (q0 < src.len and src[q0] == '/') or
                        (q0 + 1 < src.len and src[q0] == '~' and src[q0 + 1] == '/');
                    if (q_is_path_start) break;
                    var path_hint = false;
                    var q = q0;
                    while (q < src.len and src[q] != ' ' and src[q] != '\n' and
                        src[q] != '\r' and src[q] != '\t')
                    {
                        if (src[q] == '/' or src[q] == '.' or src[q] == '_' or src[q] == '-') path_hint = true;
                        if (src[q] == ')' or src[q] == ']' or src[q] == '}' or
                            src[q] == '"' or src[q] == '\'' or src[q] == '>') break;
                        q += 1;
                    }
                    if (!path_hint) break;
                }
                sp_i += 1;
            }
            while (sp_i > start + 1 and (src[sp_i - 1] == ' ' or src[sp_i - 1] == '.' or
                src[sp_i - 1] == ',' or src[sp_i - 1] == ';' or src[sp_i - 1] == ':' or
                src[sp_i - 1] == ')' or src[sp_i - 1] == ']' or src[sp_i - 1] == '}' or
                src[sp_i - 1] == '"' or src[sp_i - 1] == '\'' or src[sp_i - 1] == '>')) sp_i -= 1;

            const fp = src[start..sp_i];
            if (pathLooksValid(fp)) {
                p = sp_i;
                const label = if (compact_labels)
                    try shortenPath(alloc, fp, 256)
                else
                    try alloc.dupe(u8, fp);
                defer alloc.free(label);

                const uri = try buildFileUriTarget(alloc, fp);
                defer alloc.free(uri);
                if (uri.len != 0) {
                    try out.appendSlice(alloc, "\x1b]8;;");
                    try out.appendSlice(alloc, uri);
                    try out.append(alloc, '\x07');
                    try out.appendSlice(alloc, ansi.bold);
                    try out.appendSlice(alloc, ansi.c_flink);
                    try out.appendSlice(alloc, ansi.ul_on);
                    const x0 = out.items.len;
                    try out.appendSlice(alloc, label);
                    const x1 = out.items.len;
                    try out.appendSlice(alloc, ansi.ul_off);
                    try out.appendSlice(alloc, "\x1b[22m");
                    try out.appendSlice(alloc, "\x1b]8;;\x07");

                    if (spans) |sp| {
                        try sp.append(alloc, .{
                            .row = row,
                            .x0 = x0,
                            .x1 = x1,
                            .uri = try alloc.dupe(u8, uri),
                        });
                    }
                } else {
                    // Non-clickable fallback (remote default or expansion failure).
                    try out.appendSlice(alloc, fp);
                }
                continue;
            }
        }
        try out.append(alloc, src[p]);
        p += 1;
    }

    return try out.toOwnedSlice(alloc);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "linkify wraps a bare url in OSC-8" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try linkify(arena.allocator(), "see https://example.com now", 80, 0, null);
    // C uses BEL (0x07) as the OSC terminator, not ST (ESC '\').
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]8;;https://example.com\x07") != null);
    try testing.expect(std.mem.indexOf(u8, out, "example.com") != null);
}

test "linkify records a click span" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: std.ArrayListUnmanaged(LinkSpan) = .empty;
    _ = try linkify(arena.allocator(), "x https://a.io y", 80, 3, &spans);
    try testing.expect(spans.items.len == 1);
    try testing.expectEqual(@as(usize, 3), spans.items[0].row);
}

test "linkify leaves plain text unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try linkify(arena.allocator(), "no links here", 80, 0, null);
    try testing.expectEqualStrings("no links here", out);
}

test "linkify strips trailing punctuation from url" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try linkify(arena.allocator(), "go https://example.com/page.", 80, 0, null);
    // Trailing '.' is excluded from the URI.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]8;;https://example.com/page\x07") != null);
    // The stripped '.' is emitted verbatim after the closing OSC-8.
    try testing.expect(std.mem.endsWith(u8, out, "."));
}

test "linkify does not wrap short urls (ulen<=10)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // "http://a.b" is exactly 10 bytes → not > 10 → left as-is.
    const out = try linkify(arena.allocator(), "http://a.b", 80, 0, null);
    try testing.expectEqualStrings("http://a.b", out);
}

test "shortenUrl strips https scheme and keeps short urls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try shortenUrl(arena.allocator(), "https://example.com/path", 256);
    try testing.expectEqualStrings("example.com/path", out);
}

test "shortenUrl truncates long pathless host with ellipsis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const long = "https://" ++ ("a" ** 70);
    const out = try shortenUrl(arena.allocator(), long, 256);
    // 59 'a' chars + ellipsis
    try testing.expectEqualStrings(("a" ** 59) ++ ansi.ell, out);
}

test "shortenPath keeps short paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try shortenPath(arena.allocator(), "/usr/local/bin", 256);
    try testing.expectEqualStrings("/usr/local/bin", out);
}

test "shortenPath shortens long path to ellipsis parent/file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = "/very/long/leading/prefix/that/exceeds/the/fifty/char/limit/parent/file.txt";
    const out = try shortenPath(arena.allocator(), p, 256);
    // last two slashes give "/parent/file.txt"; +1 visible ≤ 50 → ELL + that.
    try testing.expectEqualStrings(ansi.ell ++ "/parent/file.txt", out);
}

test "buildFileUriTarget builds file uri for safe absolute path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Only valid when remote links are allowed (no SSH). In CI/local this holds.
    if (!allowRemoteFileLinks()) return error.SkipZigTest;
    const out = try buildFileUriTarget(arena.allocator(), "/usr/local/bin");
    try testing.expectEqualStrings("file:///usr/local/bin", out);
}

test "buildFileUriTarget percent-encodes unsafe chars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    if (!allowRemoteFileLinks()) return error.SkipZigTest;
    // A space is not unreserved → falls to expand+encode path → %20.
    const out = try buildFileUriTarget(arena.allocator(), "/a b");
    try testing.expectEqualStrings("file:///a%20b", out);
}
