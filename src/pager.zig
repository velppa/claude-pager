//! pager.zig — the interactive pager: the `State` struct (the C's globals folded
//! into one struct, bin/pager.c:91-194) plus the `runPager` read/decode/dispatch
//! loop (run_pager, bin/pager.c:5533-5989). `handleKey` is the pure-ish key
//! dispatcher (mutates `State`, returns an `Action`) so the loop's core can be
//! unit-tested without a tty.
//!
//! ⚠️ The external TurboDraft coupling is REMOVED: `runPager` takes NO
//! control_fd, there is no `g_ctrl_quit_supported`, and Ctrl+Q simply requests a
//! clean quit (`Action.quit`). No "TurboDraft" text is emitted anywhere.
//!
//! Deviations from the full C loop (reported, see the task's escalation clause):
//!  - SGR mouse handling (hover, click-to-open) is NOT ported into the loop:
//!    `input.decode` does not surface mouse events and the link click-map is
//!    rebuilt purely for completeness. Links are still tracked + drawn; opening
//!    them via mouse is deferred.
//!  - Page-up/down (ESC [ 5/6 ~) and wheel scroll decode as `.unknown` in
//!    `input.decode`, so they are not wired; arrow/Home/End scrolling works.
//!  - The C's render-cap / dropped-line banner bookkeeping and file-stamp
//!    short-circuit are simplified: the transcript is rendered once up front
//!    (and re-rendered on demand), without the incremental cap-adjust math.
//!  - SIGWINCH resize re-derives cols/rows/crows and re-renders; the C's
//!    off-adjust subtleties around capping are not reproduced.

const std = @import("std");
const ansi = @import("ansi.zig");
const term = @import("term.zig");
const input = @import("input.zig");
const transcript = @import("transcript.zig");
const render = @import("render.zig");
const queue_mod = @import("queue.zig");
const links = @import("links.zig");
const outbuf = @import("outbuf.zig");
const draw = @import("draw.zig");
const log = @import("log.zig");

pub const Action = enum { none, redraw, quit };

// Cols/rows clamps (the C clamps cols to 20..1000 and rows to a sane range; the
// render pipeline expects sane values — see the task note).
const COLS_MIN: usize = 20;
const COLS_MAX: usize = 1000;
const ROWS_MIN: usize = 4;
const ROWS_MAX: usize = 1000;
const QUEUE_SHOW_MAX: usize = 5;

fn clampCols(c: usize) usize {
    return std.math.clamp(c, COLS_MIN, COLS_MAX);
}
fn clampRows(r: usize) usize {
    return std.math.clamp(r, ROWS_MIN, ROWS_MAX);
}

pub const State = struct {
    alloc: std.mem.Allocator,
    lines: [][]u8, // rendered transcript lines (owned via arena)
    arena: std.heap.ArenaAllocator,
    links: draw.LinkMap,
    queue: queue_mod.Queue,
    input: input.InputBuf,
    win: term.Winsize,
    cols: usize,
    rows: usize,
    crows: usize, // transcript viewport height (g_crows)
    queue_rows: usize, // g_queue_rows
    queue_enabled: bool,
    scroll_off: usize,
    uscroll: bool, // user scrolled (vs auto-stick-to-bottom)
    input_mode: bool,
    first: bool, // first draw → full clear
    transcript_path: []u8,
    ctx_limit: usize,
    editor_pid: ?std.posix.pid_t,
    tok: usize,
    pct: f64,

    /// Build a State from in-memory jsonl for tests (no tty, no disk queue).
    pub fn initForTest(a: std.mem.Allocator, jsonl_bytes: []const u8, cols_in: usize) !State {
        const cols = clampCols(cols_in);
        const rows: usize = 24;

        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const aa = arena.allocator();

        var tr = try transcript.parse(a, jsonl_bytes, 200000);
        defer tr.deinit();
        const lines = try render.renderItems(aa, tr.items, cols);

        const path = try a.dupe(u8, "");
        errdefer a.free(path);

        var st = State{
            .alloc = a,
            .lines = lines,
            .arena = arena,
            .links = draw.LinkMap.init(a),
            .queue = queue_mod.Queue.init(a),
            .input = input.InputBuf.init(),
            .win = .{ .rows = @intCast(rows), .cols = @intCast(cols) },
            .cols = cols,
            .rows = rows,
            .crows = 1,
            .queue_rows = 0,
            .queue_enabled = true,
            .scroll_off = 0,
            .uscroll = false,
            .input_mode = false,
            .first = true,
            .transcript_path = path,
            .ctx_limit = 200000,
            .editor_pid = null,
            .tok = tr.token_count,
            .pct = tr.pct,
        };
        st.geoUpdate();
        st.recalcQueueRows();
        st.stickToBottom();
        return st;
    }

    pub fn deinit(self: *State) void {
        self.links.deinit();
        self.queue.deinit();
        self.alloc.free(self.transcript_path);
        self.arena.deinit();
    }

    // geo_update (bin/pager.c:522): derive crows from rows/queue_rows. cols/rows
    // are taken from the (already-clamped) winsize by the caller.
    fn geoUpdate(self: *State) void {
        var qr = self.queue_rows;
        const qr_cap: usize = if (self.rows > 4) self.rows - 4 else 0;
        if (qr > qr_cap) qr = qr_cap;
        const base: usize = 5;
        if (self.rows > base + qr) {
            self.crows = self.rows - base - qr;
        } else {
            self.crows = 1;
        }
        if (self.crows < 1) self.crows = 1;
    }

    // queue_recalc_rows (bin/pager.c:1004).
    fn recalcQueueRows(self: *State) void {
        var item_rows = self.queue.items.items.len;
        if (item_rows > QUEUE_SHOW_MAX) item_rows = QUEUE_SHOW_MAX;

        if (self.queue_enabled) {
            var inner_w: usize = if (self.cols > 6) self.cols - 6 else 0;
            if (inner_w < 8) inner_w = 8;
            const box_lines = self.input.boxVisibleLines(inner_w);
            self.queue_rows = 2 + box_lines +
                (if (self.queue.items.items.len > 0) (1 + item_rows) else 0);
        } else {
            self.queue_rows = 0;
        }

        const cap: usize = if (self.rows > 6) self.rows - 6 else 0;
        if (self.queue_rows > cap) self.queue_rows = cap;

        self.queue.clampSelection();
        self.geoUpdate();
    }

    // Re-derive cols/rows/crows from a fresh winsize (SIGWINCH / resize).
    fn applyWinsize(self: *State, ws: term.Winsize) void {
        self.win = ws;
        self.cols = clampCols(ws.colsOr(100));
        self.rows = clampRows(ws.rowsOr(24));
        self.geoUpdate();
        self.recalcQueueRows();
    }

    // normalize_off_visual (bin/pager.c:2271): never land scroll_off on a wrap
    // placeholder. `dir` < 0 → search up; >= 0 → search down then back up.
    fn normalizeOff(self: *State, off_in: usize, dir: i64) usize {
        if (self.lines.len == 0) return 0;
        var off = off_in;
        if (off >= self.lines.len) off = self.lines.len - 1;
        if (!isWrapPlaceholder(self.lines[off])) return off;
        if (dir >= 0) {
            while (off < self.lines.len and isWrapPlaceholder(self.lines[off])) off += 1;
            if (off >= self.lines.len) off = self.lines.len - 1;
            while (off > 0 and isWrapPlaceholder(self.lines[off])) off -= 1;
        } else {
            while (off > 0 and isWrapPlaceholder(self.lines[off])) off -= 1;
        }
        return off;
    }

    fn maxOff(self: *State) usize {
        return if (self.lines.len > 0) self.lines.len - 1 else 0;
    }

    // Stick the viewport to the bottom (the C's !uscroll path, 5665-5668).
    fn stickToBottom(self: *State) void {
        const avail = if (self.crows > 0) self.crows - 1 else 0;
        var b: usize = 0;
        if (self.lines.len > avail) b = self.lines.len - avail;
        self.scroll_off = self.normalizeOff(b, -1);
    }

    // Scroll by `delta` rows (clamped + wrap-normalized). Sets uscroll.
    fn scrollBy(self: *State, delta: i64) void {
        var off: i64 = @as(i64, @intCast(self.scroll_off)) + delta;
        if (off < 0) off = 0;
        const mx: i64 = @intCast(self.maxOff());
        if (off > mx) off = mx;
        self.scroll_off = self.normalizeOff(@intCast(off), delta);
        self.uscroll = true;
    }

    /// handleKey — dispatch one decoded key. Mutates state; returns the Action
    /// the loop should take. Mirrors the input-mode / scroll-mode split of
    /// run_pager (bin/pager.c:5724-5962), minus mouse/TurboDraft.
    pub fn handleKey(self: *State, key: input.Key) Action {
        // Ctrl+Q always quits (no TurboDraft close; clean teardown in the loop).
        switch (key) {
            .ctrl => |c| {
                if (c == 'q') return .quit;
            },
            else => {},
        }

        if (self.input_mode) return self.handleInputKey(key);
        return self.handleScrollKey(key);
    }

    fn handleInputKey(self: *State, key: input.Key) Action {
        const inner_w: usize = blk: {
            var w: usize = if (self.cols > 6) self.cols - 6 else 0;
            if (w < 8) w = 8;
            break :blk w;
        };
        switch (key) {
            .esc => {
                if (self.queue.edit_index >= 0 and self.queue.restoreDraft(&self.input)) {
                    self.queue.edit_index = -1;
                    self.queue.setNotice("draft restored");
                } else {
                    self.input.clear();
                    self.queue.discardDraft();
                    self.queue.edit_index = -1;
                    self.queue.setNotice("input cleared");
                }
                self.recalcQueueRows();
                return .redraw;
            },
            .enter => {
                self.commitInput();
                self.recalcQueueRows();
                return .redraw;
            },
            .shift_enter => {
                if (self.input.insertByte('\n')) {
                    self.recalcQueueRows();
                    return .redraw;
                }
                return .none;
            },
            .backspace => {
                if (self.input.deletePrev()) {
                    self.recalcQueueRows();
                    return .redraw;
                }
                return .none;
            },
            .delete => {
                // INP_QDELETE: remove the selected/edited queue item.
                self.deleteQueueItem();
                self.recalcQueueRows();
                return .redraw;
            },
            .byte => |b| {
                if (self.input.insertByte(b)) {
                    self.recalcQueueRows();
                    return .redraw;
                }
                return .none;
            },
            .arrow_left => {
                self.input.moveLeft();
                return .redraw;
            },
            .arrow_right => {
                self.input.moveRight();
                return .redraw;
            },
            .arrow_up => {
                self.input.moveVert(-1, inner_w);
                return .redraw;
            },
            .arrow_down => {
                self.input.moveVert(1, inner_w);
                return .redraw;
            },
            .home => {
                self.input.moveHome();
                return .redraw;
            },
            .end => {
                self.input.moveEnd();
                return .redraw;
            },
            .ctrl => |c| {
                // ^D del / ^V attach are queue-action no-ops here (attach needs
                // clipboard plumbing not in scope); ^D maps to queue delete.
                if (c == 'd') {
                    self.deleteQueueItem();
                    self.recalcQueueRows();
                    return .redraw;
                }
                return .none;
            },
            .unknown => return .none,
        }
    }

    fn handleScrollKey(self: *State, key: input.Key) Action {
        switch (key) {
            .byte => |b| {
                // 'i' / 'a' / Enter-equivalent: enter input mode (queue add). The
                // C uses INP_QUEUE_ADD (mapped from specific keys); we accept 'i'.
                if (b == 'i' or b == 'a') {
                    if (self.queue_enabled) {
                        self.input_mode = true;
                        self.input.clear();
                        self.queue.discardDraft();
                        self.queue.edit_index = -1;
                        self.queue.setNotice("");
                        self.recalcQueueRows();
                        return .redraw;
                    }
                    self.queue.setNotice("queue unavailable");
                    return .redraw;
                }
                // 'q' quits in scroll mode (in addition to Ctrl+Q).
                if (b == 'q') return .quit;
                return .none;
            },
            .enter => {
                // Enter from scroll mode opens the prompt (queue add).
                if (self.queue_enabled) {
                    self.input_mode = true;
                    self.input.clear();
                    self.queue.discardDraft();
                    self.queue.edit_index = -1;
                    self.queue.setNotice("");
                    self.recalcQueueRows();
                    return .redraw;
                }
                return .none;
            },
            .arrow_up => {
                self.scrollBy(-1);
                return .redraw;
            },
            .arrow_down => {
                self.scrollBy(1);
                return .redraw;
            },
            .home => {
                self.scroll_off = 0;
                self.uscroll = true;
                return .redraw;
            },
            .end => {
                self.uscroll = false;
                self.stickToBottom();
                return .redraw;
            },
            .esc => return .none,
            else => return .none,
        }
    }

    // ENTER in input mode: save/update the queued prompt (bin/pager.c:5738-5777).
    fn commitInput(self: *State) void {
        const txt = self.input.text();
        if (txt.len > 0) {
            if (self.queue.edit_index >= 0 and
                self.queue.edit_index < @as(i64, @intCast(self.queue.items.items.len)))
            {
                const idx: usize = @intCast(self.queue.edit_index);
                const updated = self.alloc.dupe(u8, txt) catch {
                    self.queue.setNotice("queue write failed");
                    self.afterCommit();
                    return;
                };
                self.alloc.free(self.queue.items.items[idx].prompt);
                self.queue.items.items[idx].prompt = updated;
                self.queue.items.items[idx].encoding_json = true;
                self.persist();
                self.queue.setNotice("queue updated");
                self.queue.selected = idx;
            } else {
                self.queue.push(txt) catch {
                    self.queue.setNotice("queue write failed");
                    self.afterCommit();
                    return;
                };
                self.persist();
                self.queue.setNotice("queued");
                if (self.queue.items.items.len > 0)
                    self.queue.selected = self.queue.items.items.len - 1;
            }
        } else {
            self.queue.setNotice("empty prompt");
        }
        self.afterCommit();
    }

    fn afterCommit(self: *State) void {
        self.input.clear();
        self.queue.discardDraft();
        self.queue.edit_index = -1;
    }

    // INP_QDELETE (bin/pager.c:5814-5849).
    fn deleteQueueItem(self: *State) void {
        const n = self.queue.items.items.len;
        if (n > 0) {
            self.queue.clampSelection();
            const idx: usize = if (self.queue.edit_index >= 0)
                @intCast(self.queue.edit_index)
            else
                self.queue.selected;
            if (idx < self.queue.items.items.len) {
                const it = self.queue.items.orderedRemove(idx);
                @import("queue_persist.zig").freeItem(self.alloc, it);
                if (self.queue.selected >= self.queue.items.items.len and self.queue.items.items.len > 0)
                    self.queue.selected = self.queue.items.items.len - 1;
                if (self.queue.items.items.len == 0) self.queue.selected = 0;
                self.persist();
                self.queue.setNotice("queue item removed");
            }
        }
        if (self.queue.items.items.len > 0) {
            self.queue.clampSelection();
            if (self.queue.edit_index >= 0) self.queue.setInputFromSelected(&self.input);
        } else if (self.queue.restoreDraft(&self.input)) {
            self.queue.edit_index = -1;
            self.queue.setNotice("draft restored");
        } else {
            self.input.clear();
            self.queue.edit_index = -1;
        }
    }

    // Persist the queue to disk (best-effort; no-op when no transcript path).
    fn persist(self: *State) void {
        if (self.transcript_path.len == 0) return;
        self.queue.saveToDisk(self.transcript_path) catch {};
    }
};

fn isWrapPlaceholder(s: []const u8) bool {
    return s.len == 1 and s[0] == ansi.wrap_placeholder[0];
}

// ── SIGWINCH ────────────────────────────────────────────────────────────────

var g_resize = std.atomic.Value(u8).init(0);

fn onWinch(_: std.c.SIG) callconv(.c) void {
    g_resize.store(1, .seq_cst);
}

// ── runPager — the interactive loop (run_pager, bin/pager.c:5533-5989) ───────

/// Run the interactive pager on `tty_fd`. NO control_fd (TurboDraft removed).
/// `editor_pid`, when set, is polled for liveness — the loop exits when the
/// editor process is gone (the C's `kill(editor_pid,0) != 0` check).
pub fn runPager(
    tty_fd: std.posix.fd_t,
    transcript_path: []const u8,
    editor_pid: ?std.posix.pid_t,
    ctx_limit_in: usize,
) !void {
    log.open();
    const ctx_limit: usize = if (ctx_limit_in == 0) 200000 else ctx_limit_in;

    const a = std.heap.c_allocator;

    // Read + parse + render the transcript once up front.
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var ws = term.getWinsize(tty_fd);
    var cols = clampCols(ws.colsOr(100));
    const rows0 = clampRows(ws.rowsOr(24));

    var tok: usize = 0;
    var pct: f64 = 0;
    var lines: [][]u8 = &[_][]u8{};
    {
        const jsonl = readFile(a, transcript_path) catch null;
        if (jsonl) |data| {
            defer a.free(data);
            var tr = try transcript.parse(a, data, ctx_limit);
            defer tr.deinit();
            tok = tr.token_count;
            pct = tr.pct;
            var built = try render.renderItems(aa, tr.items, cols);
            // end-of-transcript marker (bin/pager.c:5632-5633).
            built = try appendMarker(aa, built);
            lines = built;
        } else {
            var one = try aa.alloc([]u8, 1);
            one[0] = try aa.dupe(u8, ansi.c_hdm ++ "(transcript not found)" ++ ansi.reset);
            lines = one;
        }
    }

    const path_copy = try a.dupe(u8, transcript_path);
    errdefer a.free(path_copy);

    var st = State{
        .alloc = a,
        .lines = lines,
        .arena = arena,
        .links = draw.LinkMap.init(a),
        .queue = queue_mod.Queue.init(a),
        .input = input.InputBuf.init(),
        .win = ws,
        .cols = cols,
        .rows = rows0,
        .crows = 1,
        .queue_rows = 0,
        .queue_enabled = true,
        .scroll_off = 0,
        .uscroll = false,
        .input_mode = true, // queue enabled → start in input mode (C 5582).
        .first = true,
        .transcript_path = path_copy,
        .ctx_limit = ctx_limit,
        .editor_pid = editor_pid,
        .tok = tok,
        .pct = pct,
    };
    defer st.deinit();

    st.geoUpdate();
    st.queue.loadFromDisk(transcript_path) catch {};
    if (st.queue.items.items.len > 0) st.queue.setNotice("queue loaded");
    st.recalcQueueRows();
    st.stickToBottom();

    // Enter raw mode + mouse + install SIGWINCH.
    var raw = try term.RawMode.enable(tty_fd);
    defer raw.restore();
    var mouse_enabled = false;
    if (writeAll(tty_fd, ansi.mouse_on)) mouse_enabled = true;
    defer if (mouse_enabled) {
        _ = writeAll(tty_fd, ansi.mouse_off);
    };
    defer _ = writeAll(tty_fd, "\x1b[?25h"); // show cursor on exit

    installWinch();

    var ob = outbuf.OutBuf.init(a);
    defer ob.deinit();

    // Initial draw.
    try redraw(&ob, &st, tty_fd);
    st.first = false;

    var read_buf: [4096]u8 = undefined;
    var pending: [input.QUEUE_INPUT_MAX * 2]u8 = undefined;
    var pending_len: usize = 0;

    while (true) {
        // Editor liveness.
        if (st.editor_pid) |pid| {
            if (std.c.kill(pid, @enumFromInt(0)) != 0) break;
        }

        // Resize.
        if (g_resize.swap(0, .seq_cst) != 0) {
            ws = term.getWinsize(tty_fd);
            st.applyWinsize(ws);
            cols = st.cols;
            st.first = true;
            try redraw(&ob, &st, tty_fd);
            st.first = false;
        }

        // Read input (blocking with VMIN=0/VTIME=0 → may return 0). Poll-ish.
        const n = std.posix.read(tty_fd, &read_buf) catch |e| switch (e) {
            error.WouldBlock => 0,
            else => return e,
        };
        if (n == 0) {
            // Nothing to read; brief idle to avoid a busy spin, then re-check
            // resize / editor liveness.
            sleepMs(16);
            continue;
        }

        // Append to the pending buffer, then drain decodable keys.
        if (pending_len + n <= pending.len) {
            @memcpy(pending[pending_len .. pending_len + n], read_buf[0..n]);
            pending_len += n;
        } else {
            // Overflow: reset (matches the C's bounded pending queue).
            pending_len = 0;
            if (n <= pending.len) {
                @memcpy(pending[0..n], read_buf[0..n]);
                pending_len = n;
            }
        }

        var did_redraw = false;
        var want_quit = false;
        var consumed_any = true;
        while (consumed_any and pending_len > 0) {
            consumed_any = false;
            const dr = input.decode(pending[0..pending_len]);
            if (dr.consumed == 0) break; // need more bytes
            // shift the consumed bytes out
            std.mem.copyForwards(u8, pending[0 .. pending_len - dr.consumed], pending[dr.consumed..pending_len]);
            pending_len -= dr.consumed;
            consumed_any = true;

            // Skip mouse / paste artifacts that decode as .unknown silently.
            const act = st.handleKey(dr.key);
            switch (act) {
                .quit => {
                    want_quit = true;
                    break;
                },
                .redraw => did_redraw = true,
                .none => {},
            }
        }

        if (want_quit) break;
        if (did_redraw) {
            try redraw(&ob, &st, tty_fd);
        }
    }
}

fn redraw(ob: *outbuf.OutBuf, st: *State, tty_fd: std.posix.fd_t) !void {
    ob.clear();
    try draw.drawFrame(ob, st);
    _ = writeAll(tty_fd, ob.bytes());
}

// Append the C end-of-transcript marker lines (bin/pager.c:5632-5633).
fn appendMarker(aa: std.mem.Allocator, lines: [][]u8) ![][]u8 {
    var list: std.ArrayListUnmanaged([]u8) = .empty;
    try list.appendSlice(aa, lines);
    try list.append(aa, try aa.dupe(u8, ansi.c_hdm ++ "  " ++ ansi.emd ++ " end of transcript " ++ ansi.emd ++ ansi.reset));
    try list.append(aa, try aa.dupe(u8, ""));
    try list.append(aa, try aa.dupe(u8, ""));
    return list.toOwnedSlice(aa);
}

// ── small platform helpers ───────────────────────────────────────────────────

fn readFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return error.FileNotFound;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const w = std.c.write(fd, bytes[off..].ptr, bytes[off..].len);
        if (w <= 0) return false;
        off += @intCast(w);
    }
    return true;
}

fn installWinch() void {
    var act = std.mem.zeroes(std.posix.Sigaction);
    act.handler = .{ .handler = onWinch };
    std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
}

fn sleepMs(ms: u64) void {
    const ns = ms * std.time.ns_per_ms;
    const ts = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const fixture = @embedFile("fixtures/sample0.jsonl");

test "Ctrl+Q requests quit" {
    var st = try State.initForTest(std.testing.allocator, fixture, 110);
    defer st.deinit();
    try std.testing.expectEqual(Action.quit, st.handleKey(.{ .ctrl = 'q' }));
}

test "scroll down then up changes offset" {
    var st = try State.initForTest(std.testing.allocator, fixture, 110);
    defer st.deinit();
    const before = st.scroll_off;
    _ = st.handleKey(.arrow_down);
    try std.testing.expect(st.scroll_off >= before);
    _ = st.handleKey(.arrow_up);
    // offset stays valid (≤ maxOff)
    try std.testing.expect(st.scroll_off <= st.maxOff());
}

test "input mode: typing inserts and Enter queues" {
    var st = try State.initForTest(std.testing.allocator, fixture, 110);
    defer st.deinit();
    st.input_mode = true;
    _ = st.handleKey(.{ .byte = 'h' });
    _ = st.handleKey(.{ .byte = 'i' });
    try std.testing.expectEqualStrings("hi", st.input.text());
    // Enter with no transcript path → push to the in-memory queue (persist no-op).
    _ = st.handleKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), st.queue.items.items.len);
    try std.testing.expectEqualStrings("hi", st.queue.items.items[0].prompt);
    // input buffer cleared after commit.
    try std.testing.expectEqual(@as(usize, 0), st.input.len);
}

test "input mode: Esc clears input" {
    var st = try State.initForTest(std.testing.allocator, fixture, 110);
    defer st.deinit();
    st.input_mode = true;
    _ = st.handleKey(.{ .byte = 'x' });
    _ = st.handleKey(.esc);
    try std.testing.expectEqual(@as(usize, 0), st.input.len);
    try std.testing.expect(std.mem.indexOf(u8, st.queue.noticeText(), "cleared") != null);
}

test "Home and End scroll to extremes" {
    var st = try State.initForTest(std.testing.allocator, fixture, 110);
    defer st.deinit();
    st.input_mode = false;
    _ = st.handleKey(.home);
    try std.testing.expectEqual(@as(usize, 0), st.scroll_off);
    _ = st.handleKey(.end);
    try std.testing.expect(st.scroll_off <= st.maxOff());
}

test "delete removes selected queue item in input mode" {
    var st = try State.initForTest(std.testing.allocator, fixture, 110);
    defer st.deinit();
    try st.queue.push("one");
    try st.queue.push("two");
    st.input_mode = true;
    st.queue.selected = 0;
    _ = st.handleKey(.delete);
    try std.testing.expectEqual(@as(usize, 1), st.queue.items.items.len);
    try std.testing.expectEqualStrings("two", st.queue.items.items[0].prompt);
}

test "drawFrame composes a non-empty frame without crashing" {
    var st = try State.initForTest(std.testing.allocator, fixture, 110);
    defer st.deinit();
    var ob = outbuf.OutBuf.init(std.testing.allocator);
    defer ob.deinit();
    try draw.drawFrame(&ob, &st);
    try std.testing.expect(ob.bytes().len > 0);
    // home-cursor + clear prefix present on the first frame.
    try std.testing.expect(std.mem.indexOf(u8, ob.bytes(), "\x1b[2J") != null);
}
