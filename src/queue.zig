//! queue.zig — in-memory prompt-queue model, the draft-stash feature, and the
//! glue to persistence (queue_persist.zig) + input (input.zig). Ported from
//! bin/pager.c. The C couples the queue to globals (g_queue, g_input_*,
//! g_edit_index, g_queue_notice) and to drawing (queue_recalc_rows → geo_update);
//! this module owns the queue state explicitly and OMITS the drawing coupling —
//! `queue_recalc_rows` belongs to the pager loop (Task 15), so clampSelection is
//! exposed for the loop to call instead.
//!
//! C references (bin/pager.c):
//!   - queue model: QueueItems 133-139, QueueItem 124-131 (reuse queue_persist).
//!   - queue_set_notice 722, queue_item_free 727, queue_clear_items 735,
//!     queue_push_item 742, queue_clamp_selection 782.
//!   - draft-stash (KEPT): input_snapshot_draft_if_needed 838,
//!     input_discard_draft 846, input_restore_draft 853.
//!   - queue_set_input_from_selected 1935, queue_cycle_edit 1945.
//!   - load/save: queue_load_from_disk 1971, queue_write_all_items 1872.
//!   - token→path: queue_token_to_path 1602 (+ helpers 1554/1573/2401/2318).

const std = @import("std");
const InputBuf = @import("input.zig").InputBuf;
const QUEUE_INPUT_MAX = @import("input.zig").QUEUE_INPUT_MAX;
const persist = @import("queue_persist.zig");

/// QUEUE_SHOW_MAX (bin/pager.c:120). Not used for clamping here (that is the
/// loop's queue_recalc_rows job) but kept for parity / the loop's use.
pub const QUEUE_SHOW_MAX = 5;

pub const Queue = struct {
    items: std.ArrayListUnmanaged(persist.QueueItem),
    alloc: std.mem.Allocator,
    selected: usize,
    scroll_off: usize,
    edit_index: i64, // -1 = not editing a queued item (g_edit_index)
    notice: [160]u8, // g_queue_notice (sizeof 160 in C)
    notice_len: usize,
    // draft stash (KEPT) — g_input_draft / g_input_draft_len / _cursor / _saved.
    draft: [QUEUE_INPUT_MAX]u8,
    draft_len: usize,
    draft_cursor: usize,
    draft_saved: bool,

    pub fn init(a: std.mem.Allocator) Queue {
        return .{
            .items = .empty,
            .alloc = a,
            .selected = 0,
            .scroll_off = 0,
            .edit_index = -1,
            .notice = [_]u8{0} ** 160,
            .notice_len = 0,
            .draft = [_]u8{0} ** QUEUE_INPUT_MAX,
            .draft_len = 0,
            .draft_cursor = 0,
            .draft_saved = false,
        };
    }

    pub fn deinit(self: *Queue) void {
        self.clear();
        self.items.deinit(self.alloc);
    }

    // queue_clear_items (bin/pager.c:735): free each item, reset the list. (The
    // C also clears g_queue_fingerprint; that lives in the loop here.)
    pub fn clear(self: *Queue) void {
        for (self.items.items) |it| persist.freeItem(self.alloc, it);
        self.items.clearRetainingCapacity();
        self.selected = 0;
        self.scroll_off = 0;
    }

    // queue_push_item (bin/pager.c:742): empty prompt is rejected; the prompt and
    // (non-empty) persisted_id/raw_json are duplicated into owned storage.
    pub fn push(self: *Queue, prompt: []const u8) !void {
        try self.pushItem(prompt, null, 0, false, false, null);
    }

    /// Full push mirroring queue_push_item's parameters, used by loadFromDisk.
    pub fn pushItem(
        self: *Queue,
        prompt: []const u8,
        persisted_id: ?[]const u8,
        added_us: i64,
        has_added_us: bool,
        encoding_json: bool,
        raw_json: ?[]const u8,
    ) !void {
        if (prompt.len == 0) return; // !prompt || !*prompt → return 0 (no-op)

        const prompt_copy = try self.alloc.dupe(u8, prompt);
        errdefer self.alloc.free(prompt_copy);

        var id_copy: ?[]u8 = null;
        if (persisted_id) |id| {
            if (id.len > 0) id_copy = try self.alloc.dupe(u8, id);
        }
        errdefer if (id_copy) |c| self.alloc.free(c);

        var raw_copy: ?[]u8 = null;
        if (raw_json) |raw| {
            if (raw.len > 0) raw_copy = try self.alloc.dupe(u8, raw);
        }
        errdefer if (raw_copy) |c| self.alloc.free(c);

        try self.items.append(self.alloc, .{
            .prompt = prompt_copy,
            .persisted_id = id_copy,
            .added_us = added_us,
            .has_added_us = has_added_us,
            .encoding_json = encoding_json,
            .raw_json = raw_copy,
        });
    }

    // queue_clamp_selection (bin/pager.c:782). selected/scroll_off are usize here
    // (the C ints can't go negative through the public API), so the < 0 branches
    // collapse; the empty-queue and upper-bound clamps are preserved.
    pub fn clampSelection(self: *Queue) void {
        const n = self.items.items.len;
        if (n == 0) {
            self.selected = 0;
            self.scroll_off = 0;
            return;
        }
        if (self.selected >= n) self.selected = n - 1;
        if (self.scroll_off > self.selected) self.scroll_off = self.selected;
    }

    // queue_set_notice (bin/pager.c:722): snprintf-truncate into the fixed buffer.
    pub fn setNotice(self: *Queue, msg: []const u8) void {
        const cap = self.notice.len - 1;
        const n = @min(msg.len, cap);
        @memcpy(self.notice[0..n], msg[0..n]);
        self.notice[n] = 0;
        self.notice_len = n;
    }

    pub fn noticeText(self: *Queue) []const u8 {
        return self.notice[0..self.notice_len];
    }

    // ── draft-stash (KEPT) ───────────────────────────────────────────────────

    // input_snapshot_draft_if_needed (bin/pager.c:838): snapshot the current
    // input buffer once; further calls while saved are no-ops.
    pub fn snapshotDraftIfNeeded(self: *Queue, ib: *InputBuf) void {
        if (self.draft_saved) return;
        const txt = ib.text();
        const cap = self.draft.len - 1;
        const n = @min(txt.len, cap);
        @memcpy(self.draft[0..n], txt[0..n]);
        self.draft[n] = 0;
        self.draft_len = n;
        self.draft_cursor = ib.cursor;
        self.draft_saved = true;
    }

    // input_discard_draft (bin/pager.c:846).
    pub fn discardDraft(self: *Queue) void {
        self.draft_saved = false;
        self.draft_len = 0;
        self.draft_cursor = 0;
        self.draft[0] = 0;
    }

    // input_restore_draft (bin/pager.c:853): restore the snapshot into the input
    // buffer (clamping cursor to len), then discard the draft. Returns false if
    // nothing was saved. NOTE: the C caller (queue_cycle_edit) sets the "draft
    // restored" notice; per the task API, restoreDraft sets it here too.
    pub fn restoreDraft(self: *Queue, ib: *InputBuf) bool {
        if (!self.draft_saved) return false;
        ib.setText(self.draft[0..self.draft_len]);
        // input_set_text put the cursor at end; restore the saved cursor,
        // clamped to len (mirrors bin/pager.c:860-862).
        var cur = self.draft_cursor;
        if (cur > ib.len) cur = ib.len;
        ib.cursor = cur;
        ib.goal_col = -1;
        self.discardDraft();
        self.setNotice("draft restored");
        return true;
    }

    // queue_set_input_from_selected (bin/pager.c:1935).
    pub fn setInputFromSelected(self: *Queue, ib: *InputBuf) void {
        if (self.items.items.len == 0) return;
        self.clampSelection();
        if (self.selected >= self.items.items.len) return;
        ib.setText(self.items.items[self.selected].prompt);
        self.edit_index = @intCast(self.selected);
        self.setNotice("editing queued prompt");
    }

    // queue_cycle_edit (bin/pager.c:1945). dir != 0 (typically -1 / +1).
    pub fn cycleEdit(self: *Queue, ib: *InputBuf, dir: i32) bool {
        const n = self.items.items.len;
        if (n == 0) return false;
        if (dir == 0) return false;

        if (self.edit_index < 0) {
            // First cycle from a fresh draft: stash the half-typed prompt and
            // jump to the last (dir<0) or first (dir>0) queued item.
            self.snapshotDraftIfNeeded(ib);
            self.selected = if (dir < 0) n - 1 else 0;
            self.setInputFromSelected(ib);
            return true;
        }

        const cur: i64 = @intCast(self.selected);
        const next: i64 = cur + dir;
        if (next < 0 or next >= @as(i64, @intCast(n))) {
            // Cycled past an end: restore the draft and leave edit mode.
            if (self.restoreDraft(ib)) {
                self.edit_index = -1;
                self.setNotice("draft restored"); // mirror C (restoreDraft already set it)
                return true;
            }
            return false;
        }

        self.selected = @intCast(next);
        self.setInputFromSelected(ib);
        return true;
    }

    // ── persistence glue ─────────────────────────────────────────────────────

    /// Load the queue file for `transcript` from disk, replacing the in-memory
    /// items. Mirrors queue_load_from_disk (bin/pager.c:1971): missing file →
    /// clear; otherwise parse via queue_persist.load under an advisory lock.
    /// (The C's file_stamp_changed short-circuit and fingerprint tracking live
    /// in the loop; here we always reload, which is safe and idempotent.)
    pub fn loadFromDisk(self: *Queue, transcript: []const u8) !void {
        var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try persist.queuePathFor(transcript, &pathbuf);

        const lock = persist.Lock.acquire(path) catch null;
        defer if (lock) |l| l.release();

        var threaded = std.Io.Threaded.init(self.alloc, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();

        const data = cwd.readFileAlloc(io, path, self.alloc, .unlimited) catch |e| switch (e) {
            error.FileNotFound => {
                // stat failure in the C → clear if non-empty (bin/pager.c:1977).
                self.clear();
                return;
            },
            else => return e,
        };
        defer self.alloc.free(data);

        const old_n = self.items.items.len;
        self.clear();

        const loaded = try persist.load(self.alloc, data);
        defer self.alloc.free(loaded); // free the slice; items move into self
        errdefer for (loaded) |it| persist.freeItem(self.alloc, it);
        for (loaded) |it| {
            try self.items.append(self.alloc, it);
        }

        // bin/pager.c:2030 — if the queue grew, select the newest item.
        if (self.items.items.len > old_n and self.items.items.len > 0) {
            self.selected = self.items.items.len - 1;
        }
        self.clampSelection();
    }

    /// Write the queue to its file for `transcript`. Mirrors
    /// queue_write_all_items (bin/pager.c:1872): empty queue → unlink the file;
    /// otherwise serialize via queue_persist and atomically replace, under the
    /// advisory lock. (The C's fingerprint conflict check lives in the loop;
    /// here we do a straight write — the lock prevents concurrent writers.)
    pub fn saveToDisk(self: *Queue, transcript: []const u8) !void {
        var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try persist.queuePathFor(transcript, &pathbuf);

        const lock = persist.Lock.acquire(path) catch null;
        defer if (lock) |l| l.release();

        var threaded = std.Io.Threaded.init(self.alloc, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();

        if (self.items.items.len == 0) {
            cwd.deleteFile(io, path) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            };
            return;
        }

        const bytes = try persist.serialize(self.alloc, self.items.items);
        defer self.alloc.free(bytes);

        // Atomic replace: write a sibling temp file then rename over the target,
        // matching the C's mkstemp+rename (bin/pager.c:1896-1925).
        var tmpbuf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmpbuf, "{s}.tmp", .{path});
        try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = bytes });
        cwd.rename(tmp_path, cwd, path, io) catch |e| {
            cwd.deleteFile(io, tmp_path) catch {};
            return e;
        };
    }
};

// ── token → path validation (port of queue_token_to_path, bin/pager.c:1602) ───

/// Validate a token as a path to an existing regular file. On success copies the
/// resolved absolute path into `out` and returns the slice; otherwise returns an
/// error. Mirrors queue_token_to_path: strips surrounding quotes/brackets and
/// trailing punctuation, unescapes backslash-escapes, handles an optional
/// leading '@' and `file://` URI (with a local-authority check + %-decoding),
/// requires an absolute or '~/'-relative path, expands '~/', and stats it.
pub fn tokenToPath(tok_in: []const u8, out: []u8) ![]const u8 {
    if (tok_in.len == 0 or out.len == 0) return error.InvalidToken;

    // Strip leading opening quotes/brackets (bin/pager.c:1604).
    var tok = tok_in;
    while (tok.len > 0 and (tok[0] == '"' or tok[0] == '\'' or tok[0] == '(' or tok[0] == '[')) {
        tok = tok[1..];
    }
    // Strip trailing punctuation (bin/pager.c:1606-1610).
    var n = tok.len;
    while (n > 0) {
        const c = tok[n - 1];
        if (c == '"' or c == '\'' or c == ')' or c == ']' or c == ',' or c == '.' or c == ';' or c == ':') {
            n -= 1;
        } else break;
    }
    if (n == 0) return error.InvalidToken;
    tok = tok[0..n];

    // Unescape backslash-escaped space/backslash/quote (bin/pager.c:1615-1626).
    var tmp: [std.fs.max_path_bytes]u8 = undefined;
    var j: usize = 0;
    var i: usize = 0;
    while (i < tok.len and j + 1 < tmp.len) : (i += 1) {
        const c = tok[i];
        if (c == '\\' and i + 1 < tok.len) {
            const nx = tok[i + 1];
            if (nx == ' ' or nx == '\\' or nx == '"' or nx == '\'') {
                tmp[j] = nx;
                j += 1;
                i += 1;
                continue;
            }
        }
        tmp[j] = c;
        j += 1;
    }
    const unescaped = tmp[0..j];

    // Optional leading '@', then file:// URI handling (bin/pager.c:1629-1646).
    var p: []const u8 = unescaped;
    var uri_mode = false;
    if (p.len > 0 and p[0] == '@') p = p[1..];
    if (std.mem.startsWith(u8, p, "file://")) {
        uri_mode = true;
        p = p["file://".len..];
        if (p.len > 0 and p[0] != '/') {
            const slash = std.mem.indexOfScalar(u8, p, '/') orelse return error.InvalidToken;
            const authority = p[0..slash];
            if (authority.len == 0 or authority.len >= 256) return error.InvalidToken;
            if (!uriAuthorityIsLocal(authority)) return error.InvalidToken;
            p = p[slash..];
        }
    }
    if (p.len > 0 and p[0] == '@') p = p[1..];

    // Require absolute or '~/'-relative (bin/pager.c:1648).
    const is_abs = p.len > 0 and p[0] == '/';
    const is_tilde = p.len >= 2 and p[0] == '~' and p[1] == '/';
    if (!is_abs and !is_tilde) return error.InvalidToken;

    // Decode %-escapes for URI mode, else copy verbatim (bin/pager.c:1650-1657).
    var decbuf: [std.fs.max_path_bytes]u8 = undefined;
    var decoded: []const u8 = undefined;
    if (uri_mode) {
        decoded = try uriDecodePath(&decbuf, p);
    } else {
        if (p.len >= decbuf.len) return error.InvalidToken;
        @memcpy(decbuf[0..p.len], p);
        decoded = decbuf[0..p.len];
    }

    // Expand '~/' to $HOME (bin/pager.c:1659-1665, expand_path_to_abs 2401).
    var absbuf: [std.fs.max_path_bytes]u8 = undefined;
    var path = decoded;
    if (decoded.len >= 2 and decoded[0] == '~' and decoded[1] == '/') {
        path = try expandTildeToAbs(&absbuf, decoded);
    }

    // Must stat as an existing regular file (bin/pager.c:1667-1668).
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.NotAFile;
    if (st.kind != .file) return error.NotAFile;

    if (path.len >= out.len) return error.InvalidToken;
    @memcpy(out[0..path.len], path);
    return out[0..path.len];
}

// queue_uri_decode_path (bin/pager.c:1554): %-decode, reject NUL/'\n'/'\r' and
// empty input.
fn uriDecodePath(dst: []u8, src: []const u8) ![]const u8 {
    if (src.len == 0) return error.InvalidToken;
    var j: usize = 0;
    var i: usize = 0;
    while (i < src.len and j + 1 < dst.len) : (i += 1) {
        var c = src[i];
        if (c == '%') {
            if (i + 2 >= src.len) return error.InvalidToken;
            const hi = hexNybble(src[i + 1]) orelse return error.InvalidToken;
            const lo = hexNybble(src[i + 2]) orelse return error.InvalidToken;
            c = (hi << 4) | lo;
            i += 2;
        }
        if (c == 0 or c == '\n' or c == '\r') return error.InvalidToken;
        dst[j] = c;
        j += 1;
    }
    return dst[0..j];
}

fn hexNybble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// queue_uri_authority_is_local (bin/pager.c:1573): empty/"localhost"/local
// hostname (full or short-name) are local.
fn uriAuthorityIsLocal(authority: []const u8) bool {
    if (authority.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(authority, "localhost")) return true;

    var hostbuf: [256]u8 = undefined;
    const local = fileUriHost(&hostbuf);
    if (local.len > 0 and std.ascii.eqlIgnoreCase(authority, local)) return true;

    const auth_short = shortHost(authority);
    const local_short = shortHost(local);
    return auth_short.len > 0 and local_short.len > 0 and
        std.ascii.eqlIgnoreCase(auth_short, local_short);
}

/// Leading label of a host, up to the first '.' or ':'.
fn shortHost(host: []const u8) []const u8 {
    var i: usize = 0;
    while (i < host.len and host[i] != '.' and host[i] != ':') i += 1;
    return host[0..i];
}

// file_uri_host (bin/pager.c:2318): gethostname, sanitizing control/'/'/'\\'
// bytes to '-'; falls back to "localhost".
fn fileUriHost(buf: []u8) []const u8 {
    var raw: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = std.posix.gethostname(&raw) catch "localhost";
    const src = if (name.len == 0) "localhost" else name;
    const n = @min(src.len, buf.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = src[i];
        buf[i] = if (c <= ' ' or c == '/' or c == '\\') '-' else c;
    }
    return buf[0..n];
}

// expand_path_to_abs (bin/pager.c:2401), '~/' branch only (callers here already
// guaranteed a leading '~/').
fn expandTildeToAbs(dst: []u8, path: []const u8) ![]const u8 {
    const home = getEnv("HOME") orelse return error.NoHome;
    if (home.len == 0) return error.NoHome;
    const tail = path[1..]; // includes the leading '/'
    if (home.len + tail.len >= dst.len) return error.InvalidToken;
    @memcpy(dst[0..home.len], home);
    @memcpy(dst[home.len .. home.len + tail.len], tail);
    return dst[0 .. home.len + tail.len];
}

/// getenv for 0.16 — scan std.c.environ (same idiom as queue_persist.getEnv).
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

/// getcwd for 0.16 tests — std.posix.getcwd is gone; call libc directly.
fn testGetCwd(buf: []u8) []const u8 {
    const r = std.c.getcwd(buf.ptr, buf.len) orelse return ".";
    return std.mem.span(@as([*:0]const u8, @ptrCast(r)));
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "push and clampSelection" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    try q.push("a");
    try q.push("b");
    q.selected = 99;
    q.clampSelection();
    try std.testing.expectEqual(@as(usize, 1), q.selected);
}

test "draft stash and restore preserves half-typed text" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    var ib = InputBuf.init();
    ib.setText("half typed");
    q.snapshotDraftIfNeeded(&ib);
    ib.setText("a queued item"); // user is now editing a queued prompt
    try std.testing.expect(q.restoreDraft(&ib));
    try std.testing.expectEqualStrings("half typed", ib.text());
    try std.testing.expect(std.mem.indexOf(u8, q.noticeText(), "draft") != null);
}

test "cycleEdit on empty queue is a no-op" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    var ib = InputBuf.init();
    try std.testing.expect(!q.cycleEdit(&ib, 1));
}

test "push rejects empty prompt" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    try q.push("");
    try std.testing.expectEqual(@as(usize, 0), q.items.items.len);
}

test "clear frees and resets" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    try q.push("a");
    try q.push("b");
    q.selected = 1;
    q.clear();
    try std.testing.expectEqual(@as(usize, 0), q.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), q.selected);
}

test "setNotice truncates and noticeText reflects it" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    q.setNotice("hello");
    try std.testing.expectEqualStrings("hello", q.noticeText());
}

test "cycleEdit from fresh draft stashes and jumps to last for dir<0" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    try q.push("first");
    try q.push("second");
    var ib = InputBuf.init();
    ib.setText("my draft");
    try std.testing.expect(q.cycleEdit(&ib, -1));
    try std.testing.expectEqual(@as(usize, 1), q.selected); // last item
    try std.testing.expectEqualStrings("second", ib.text());
    try std.testing.expect(q.draft_saved);
    try std.testing.expectEqual(@as(i64, 1), q.edit_index);
}

test "cycleEdit from fresh draft jumps to first for dir>0" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    try q.push("first");
    try q.push("second");
    var ib = InputBuf.init();
    ib.setText("d");
    try std.testing.expect(q.cycleEdit(&ib, 1));
    try std.testing.expectEqual(@as(usize, 0), q.selected);
    try std.testing.expectEqualStrings("first", ib.text());
}

test "cycleEdit past the end restores draft and exits edit mode" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    try q.push("first");
    try q.push("second");
    var ib = InputBuf.init();
    ib.setText("keep me");
    // Enter edit at last item.
    try std.testing.expect(q.cycleEdit(&ib, -1)); // selected = 1 (last)
    try std.testing.expectEqual(@as(usize, 1), q.selected);
    // Cycle forward past the end → restore draft.
    try std.testing.expect(q.cycleEdit(&ib, 1));
    try std.testing.expectEqual(@as(i64, -1), q.edit_index);
    try std.testing.expectEqualStrings("keep me", ib.text());
    try std.testing.expect(!q.draft_saved);
    try std.testing.expect(std.mem.indexOf(u8, q.noticeText(), "draft restored") != null);
}

test "cycleEdit moves between items while editing" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    try q.push("a");
    try q.push("b");
    try q.push("c");
    var ib = InputBuf.init();
    ib.setText("x");
    try std.testing.expect(q.cycleEdit(&ib, 1)); // first → "a", selected 0
    try std.testing.expectEqualStrings("a", ib.text());
    try std.testing.expect(q.cycleEdit(&ib, 1)); // selected 1 → "b"
    try std.testing.expectEqualStrings("b", ib.text());
    try std.testing.expect(q.cycleEdit(&ib, 1)); // selected 2 → "c"
    try std.testing.expectEqualStrings("c", ib.text());
    try std.testing.expectEqual(@as(usize, 2), q.selected);
}

test "snapshotDraftIfNeeded only snapshots once" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    var ib = InputBuf.init();
    ib.setText("original");
    q.snapshotDraftIfNeeded(&ib);
    ib.setText("changed");
    q.snapshotDraftIfNeeded(&ib); // no-op, draft already saved
    try std.testing.expect(q.restoreDraft(&ib));
    try std.testing.expectEqualStrings("original", ib.text());
}

test "restoreDraft on no saved draft returns false" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    var ib = InputBuf.init();
    ib.setText("typed");
    try std.testing.expect(!q.restoreDraft(&ib));
    try std.testing.expectEqualStrings("typed", ib.text());
}

test "save then load roundtrips through disk" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    // Use a unique transcript so the queue path is isolated for this test.
    const transcript = "/tmp/claude-pager-queue-test-XYZ.jsonl";
    try q.push("alpha");
    try q.push("beta with \"quotes\"\nand newline");
    try q.saveToDisk(transcript);

    var q2 = Queue.init(std.testing.allocator);
    defer q2.deinit();
    try q2.loadFromDisk(transcript);
    try std.testing.expectEqual(@as(usize, 2), q2.items.items.len);
    try std.testing.expectEqualStrings("alpha", q2.items.items[0].prompt);
    try std.testing.expectEqualStrings("beta with \"quotes\"\nand newline", q2.items.items[1].prompt);

    // Empty queue save should remove the file → load yields nothing.
    q.clear();
    try q.saveToDisk(transcript);
    var q3 = Queue.init(std.testing.allocator);
    defer q3.deinit();
    try q3.loadFromDisk(transcript);
    try std.testing.expectEqual(@as(usize, 0), q3.items.items.len);
}

test "loadFromDisk on missing file clears the queue" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    try q.push("stale");
    try q.loadFromDisk("/tmp/claude-pager-queue-test-DOES-NOT-EXIST-12345.jsonl");
    try std.testing.expectEqual(@as(usize, 0), q.items.items.len);
}

test "tokenToPath validates an existing file and rejects nonexistent" {
    // Create a temp file via the queue path machinery isn't needed; use cwd.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const fname = "queue_token_test_file.txt";
    try cwd.writeFile(io, .{ .sub_path = fname, .data = "hi" });
    defer cwd.deleteFile(io, fname) catch {};

    // Build an absolute path to the file.
    var cwdbuf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = testGetCwd(&cwdbuf);
    var abs: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try std.fmt.bufPrint(&abs, "{s}/{s}", .{ cwd_path, fname });

    var out: [std.fs.max_path_bytes]u8 = undefined;
    const got = try tokenToPath(abs_path, &out);
    try std.testing.expectEqualStrings(abs_path, got);

    // Trailing punctuation is stripped.
    var with_punct: [std.fs.max_path_bytes]u8 = undefined;
    const wp = try std.fmt.bufPrint(&with_punct, "({s}),", .{abs_path});
    const got2 = try tokenToPath(wp, &out);
    try std.testing.expectEqualStrings(abs_path, got2);

    // Relative / nonexistent → error.
    try std.testing.expectError(error.InvalidToken, tokenToPath("relative/path", &out));
    try std.testing.expectError(error.NotAFile, tokenToPath("/no/such/file/here/xyz", &out));
}

test "tokenToPath accepts file:// localhost URI" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const fname = "queue_token_uri_test.txt";
    try cwd.writeFile(io, .{ .sub_path = fname, .data = "x" });
    defer cwd.deleteFile(io, fname) catch {};

    var cwdbuf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = testGetCwd(&cwdbuf);
    var uri: [std.fs.max_path_bytes]u8 = undefined;
    const uri_str = try std.fmt.bufPrint(&uri, "file://localhost{s}/{s}", .{ cwd_path, fname });
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const got = try tokenToPath(uri_str, &out);
    var expect: [std.fs.max_path_bytes]u8 = undefined;
    const expect_path = try std.fmt.bufPrint(&expect, "{s}/{s}", .{ cwd_path, fname });
    try std.testing.expectEqualStrings(expect_path, got);
}
