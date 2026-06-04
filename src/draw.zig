//! draw.zig — frame composition + link click-map for the interactive pager.
//!
//! Ported from bin/pager.c's drawing section (lines 4947-5251) and the link-map
//! tracking (LinkMap/LinkSpan 150-161, link_map_* 2688-2790) plus the footer /
//! hover-emit helpers (2816-2843). The whole frame is composed into an `OutBuf`
//! (the C's `ob`/`obf` buffer) and the caller writes it to the tty in one shot.
//!
//! State lives in `pager.zig`'s `State` (the C's globals folded into a struct).
//! `drawFrame` mirrors the C `draw()` (5180-5250): hide cursor + home, top
//! separator, the scrolled transcript viewport, blank-fill, the queue panel
//! (separator + Queue(n) header + item list + input box), the status line and
//! the hotkeys footer.
//!
//! TurboDraft coupling (control_fd / g_ctrl_quit_supported) is NOT ported. The
//! Ctrl+Q footer hint is shown unconditionally as a plain "^Q quit".
//!
//! Glyphs/escapes come from `ansi.zig`; the input box layout from
//! `input.InputBuf.layout`; visible-length math is byte-count (ansi.visibleLen).

const std = @import("std");
const ansi = @import("ansi.zig");
const input = @import("input.zig");

pub const LinkSpan = @import("links.zig").LinkSpan;

// QUEUE_SHOW_MAX (bin/pager.c:120).
const QUEUE_SHOW_MAX = 5;

// ── LinkMap (bin/pager.c:150-161, 2688-2790) ────────────────────────────────

pub const LinkMap = struct {
    spans: std.ArrayListUnmanaged(LinkSpan),
    alloc: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) LinkMap {
        return .{ .spans = .empty, .alloc = a };
    }

    pub fn deinit(self: *LinkMap) void {
        self.clear();
        self.spans.deinit(self.alloc);
    }

    // link_map_clear (bin/pager.c:2688): free each span's owned uri, reset.
    pub fn clear(self: *LinkMap) void {
        for (self.spans.items) |sp| self.alloc.free(sp.uri);
        self.spans.clearRetainingCapacity();
    }

    // link_map_add (bin/pager.c:2696): coalesce with the previous span when it is
    // the same row, adjacent (last.x1 + 1 == x0), and the same uri; otherwise
    // append a copy (the uri is duplicated into owned storage).
    pub fn add(self: *LinkMap, s: LinkSpan) !void {
        if (s.uri.len == 0 or s.x1 < s.x0) return;
        if (self.spans.items.len > 0) {
            const last = &self.spans.items[self.spans.items.len - 1];
            if (last.row == s.row and last.x1 + 1 == s.x0 and
                std.mem.eql(u8, last.uri, s.uri))
            {
                last.x1 = s.x1;
                return;
            }
        }
        const uri_copy = try self.alloc.dupe(u8, s.uri);
        errdefer self.alloc.free(uri_copy);
        try self.spans.append(self.alloc, .{
            .row = s.row,
            .x0 = s.x0,
            .x1 = s.x1,
            .uri = uri_copy,
        });
    }

    // link_map_hit (bin/pager.c:2785): first span covering (row, col).
    pub fn at(self: *LinkMap, row: usize, col: usize) ?[]const u8 {
        for (self.spans.items) |sp| {
            if (sp.row == row and col >= sp.x0 and col <= sp.x1) return sp.uri;
        }
        return null;
    }
};

// ── frame composition ───────────────────────────────────────────────────────

const State = @import("pager.zig").State;
const OutBuf = @import("outbuf.zig").OutBuf;

// line_is_wrap_placeholder (bin/pager.c:2206).
fn isWrapPlaceholder(s: []const u8) bool {
    return s.len == 1 and s[0] == ansi.wrap_placeholder[0];
}

// link_map_track_line (bin/pager.c:2720): walk the rendered line `s`, tracking
// the active OSC-8 uri, and record a 1-cell span per visible cell while a uri is
// active. Cells wrap to the next row at column g_cols (here st.cols). Mirrors the
// C exactly (1-based row/col); spans coalesce in LinkMap.add.
fn trackLine(st: *State, s: []const u8, start_row: usize) !void {
    if (s.len == 0 or start_row == 0) return;
    var row = start_row;
    var col: usize = 1;
    var active_uri: []const u8 = "";
    const slen = s.len;
    var i: usize = 0;
    while (i < slen) {
        const c = s[i];
        // CSI: ESC [ … final
        if (c == 0x1b and i + 1 < slen and s[i + 1] == '[') {
            i += 2;
            while (i < slen and !isAlpha(s[i]) and s[i] != '~') i += 1;
            if (i < slen) i += 1;
            continue;
        }
        // OSC-8: ESC ] 8 ;
        if (c == 0x1b and i + 3 < slen and s[i + 1] == ']' and s[i + 2] == '8' and s[i + 3] == ';') {
            i += 4;
            var sep = false;
            while (i < slen) {
                if (s[i] == ';') {
                    sep = true;
                    i += 1;
                    break;
                }
                if (s[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (s[i] == 0x1b and i + 1 < slen and s[i + 1] == '\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            if (!sep) {
                active_uri = "";
                continue;
            }
            const uri_start = i;
            while (i < slen) {
                if (s[i] == 0x07) {
                    break;
                }
                if (s[i] == 0x1b and i + 1 < slen and s[i + 1] == '\\') {
                    break;
                }
                i += 1;
            }
            active_uri = s[uri_start..i];
            // skip the terminator
            if (i < slen and s[i] == 0x07) {
                i += 1;
            } else if (i + 1 < slen and s[i] == 0x1b and s[i + 1] == '\\') {
                i += 2;
            }
            continue;
        }
        // other OSC
        if (c == 0x1b and i + 1 < slen and s[i + 1] == ']') {
            i += 2;
            while (i < slen) {
                if (s[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (s[i] == 0x1b and i + 1 < slen and s[i + 1] == '\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }
        // other ESC
        if (c == 0x1b) {
            i += if (i + 1 < slen) 2 else 1;
            continue;
        }

        if (col > st.cols) {
            row += 1;
            col = 1;
        }

        const next = nextBoundary(s, slen, i);
        if (active_uri.len != 0) {
            try st.links.add(.{ .row = row, .x0 = col, .x1 = col, .uri = active_uri });
        }
        col += 1;
        i = next;
    }
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// input_next_boundary equivalent (UTF-8 aware), used to advance one cell.
fn nextBoundary(buf: []const u8, len: usize, pos: usize) usize {
    if (pos >= len) return len;
    var p = pos + 1;
    while (p < len and (buf[p] & 0xC0) == 0x80) p += 1;
    return p;
}

// queue_compact_prompt (bin/pager.c:2035): collapse to a single display line,
// control bytes → space, truncate at the first newline or `max_chars` cells with
// an ellipsis. Writes into `dst` and returns the slice.
fn compactPrompt(dst: []u8, src: []const u8, max_chars_in: usize) []u8 {
    if (dst.len == 0 or max_chars_in == 0) return dst[0..0];
    var max_chars = max_chars_in;
    if (max_chars > dst.len - 1) max_chars = dst.len - 1;
    var truncated = false;
    var i: usize = 0;
    var p: usize = 0;
    while (p < src.len and i < max_chars) : (p += 1) {
        const c = src[p];
        if (c == '\n' or c == '\r') {
            truncated = true;
            break;
        }
        dst[i] = if (c < 0x20) ' ' else c;
        i += 1;
    }
    if (!truncated) {
        truncated = (i < src.len);
    }
    if (truncated) {
        if (i == 0) {
            const dots = if (max_chars < 3) max_chars else 3;
            var j: usize = 0;
            while (j < dots) : (j += 1) {
                dst[i] = '.';
                i += 1;
            }
        } else if (i + 4 <= max_chars) {
            dst[i] = ' ';
            dst[i + 1] = '.';
            dst[i + 2] = '.';
            dst[i + 3] = '.';
            i += 4;
        } else if (i + 3 <= max_chars) {
            dst[i] = '.';
            dst[i + 1] = '.';
            dst[i + 2] = '.';
            i += 3;
        } else {
            if (i >= 1) dst[i - 1] = '.';
            if (i >= 2) dst[i - 2] = '.';
            if (i >= 3) dst[i - 3] = '.';
        }
    }
    return dst[0..i];
}

// draw_status (bin/pager.c:4953).
fn drawStatus(ob: *OutBuf, st: *State, tok: usize, pct: f64, cl: usize) !void {
    try ob.write(ansi.c_ban ++ "  Editor open " ++ ansi.emd ++ " edit and close to send" ++ ansi.reset);
    try ob.write(ansi.dim);
    if (st.queue_enabled) try ob.print("  " ++ ansi.dot ++ "  queue:{d}", .{st.queue.items.items.len});
    const notice = st.queue.noticeText();
    if (notice.len > 0) try ob.print("  " ++ ansi.dot ++ "  {s}", .{notice});
    try ob.write(ansi.reset);
    if (tok == 0) return;

    const bar_levels = [_][]const u8{ " ", "\xe2\x96\x8f", "\xe2\x96\x8e", "\xe2\x96\x8d", "\xe2\x96\x8c", "\xe2\x96\x8b", "\xe2\x96\x8a", "\xe2\x96\x89", "\xe2\x96\x88" };
    const bw: usize = 8;
    var scaled: f64 = pct / 100.0 * @as(f64, @floatFromInt(bw)) * 8.0;
    if (scaled < 0.0) scaled = 0.0;
    const max_scaled = @as(f64, @floatFromInt(bw)) * 8.0;
    if (scaled > max_scaled) scaled = max_scaled;

    var ctbuf: [64]u8 = undefined;
    const ct = std.fmt.bufPrint(&ctbuf, "{d:.0}%  {d:.0}k/{d}k", .{
        pct,
        @as(f64, @floatFromInt(tok)) / 1000.0,
        cl / 1000,
    }) catch ctbuf[0..0];

    const bvl: usize = 70;
    const cvl: usize = bw + 3 + ct.len;
    const svl: usize = 9;
    var pad: usize = 0;
    if (st.cols > bvl + svl + cvl) pad = st.cols - bvl - svl - cvl;

    try ob.print("{[s]s: >[pad]}", .{ .s = "", .pad = pad });
    try ob.write(ansi.dim ++ "  " ++ ansi.dot ++ "  " ++ ansi.reset);
    try ob.write(ansi.c_hdm ++ "ctx " ++ ansi.reset);
    var i: usize = 0;
    while (i < bw) : (i += 1) {
        const rem = scaled - @as(f64, @floatFromInt(i * 8));
        var level: i64 = @intFromFloat(rem + 0.0001);
        if (level < 0) level = 0;
        if (level > 8) level = 8;
        if (i == 0) try ob.write(ansi.c_sep ++ "[");
        if (level > 0) {
            const segc = if (i < 4) ansi.c_brg else if (i < 6) ansi.c_bry else ansi.c_brr;
            try ob.write(segc);
            try ob.write(bar_levels[@intCast(level)]);
        } else {
            try ob.write(ansi.c_sep ++ ansi.dot);
        }
        if (i == bw - 1) try ob.write(ansi.c_sep ++ "]");
    }
    try ob.write(ansi.reset ++ ansi.dim ++ " ");
    try ob.write(ct);
    try ob.write(ansi.reset);
}

// footer_emit_plain (bin/pager.c:2816): emit up to (max_cells - used) cells.
fn footerEmitPlain(ob: *OutBuf, s: []const u8, used: *usize, max_cells: usize) !void {
    if (s.len == 0 or max_cells == 0) return;
    var i: usize = 0;
    while (i < s.len and used.* < max_cells) {
        const next = nextBoundary(s, s.len, i);
        try ob.write(s[i..next]);
        used.* += 1;
        i = next;
    }
}

// footer_emit_styled (bin/pager.c:2827).
fn footerEmitStyled(ob: *OutBuf, style: []const u8, text: []const u8, used: *usize, max_cells: usize) !void {
    if (text.len == 0 or used.* >= max_cells) return;
    if (style.len > 0) try ob.write(style);
    try footerEmitPlain(ob, text, used, max_cells);
    try ob.write(ansi.reset);
    try ob.write(ansi.c_qbg);
}

// draw_hotkeys_footer (bin/pager.c:5139). The TurboDraft-gated "^Q close" hint is
// replaced by an unconditional plain "^Q quit".
fn drawHotkeysFooter(ob: *OutBuf, st: *State) !void {
    try ob.write(ansi.c_qbg);
    if (st.cols < 2) {
        try ob.write(ansi.reset);
        return;
    }
    const maxw: usize = st.cols - 2;
    var used: usize = 0;
    if (st.input_mode) {
        try footerEmitPlain(ob, "  ", &used, maxw);
        try footerEmitStyled(ob, ansi.c_hdm, "keys: ", &used, maxw);
        try footerEmitStyled(ob, ansi.c_qacc, "\xe2\x87\xa7\xe2\x86\x91/\xe2\x86\x93", &used, maxw); // ⇧↑/↓
        try footerEmitPlain(ob, " hist  ", &used, maxw);
        try footerEmitStyled(ob, ansi.c_qacc, "\xe2\x87\xa7Enter", &used, maxw);
        try footerEmitPlain(ob, " nl  ", &used, maxw);
        try footerEmitStyled(ob, ansi.c_qacc, "Enter", &used, maxw);
        try footerEmitPlain(ob, " save  ", &used, maxw);
        try footerEmitStyled(ob, ansi.c_qacc, "Esc", &used, maxw);
        try footerEmitPlain(ob, " clear  ", &used, maxw);
        try footerEmitStyled(ob, ansi.c_qacc, "^V", &used, maxw);
        try footerEmitPlain(ob, " attach  ", &used, maxw);
        try footerEmitStyled(ob, ansi.c_qacc, "^D", &used, maxw);
        try footerEmitPlain(ob, " del  ", &used, maxw);
        try footerEmitStyled(ob, ansi.c_qacc, "^Q", &used, maxw);
        try footerEmitPlain(ob, " quit", &used, maxw);
    } else {
        try footerEmitPlain(ob, "  ", &used, maxw);
        try footerEmitStyled(ob, ansi.c_hdm, "keys: ", &used, maxw);
        try footerEmitStyled(ob, ansi.c_qacc, "\xe2\x87\xa7\xe2\x86\x91/\xe2\x86\x93", &used, maxw);
        try footerEmitPlain(ob, " cycle/edit  ", &used, maxw);
        try footerEmitStyled(ob, ansi.c_qacc, "^Q", &used, maxw);
        try footerEmitPlain(ob, " quit", &used, maxw);
    }
    try ob.write(ansi.reset);
}

// draw_queue_panel (bin/pager.c:4994).
fn drawQueuePanel(ob: *OutBuf, st: *State) !void {
    if (st.queue_rows == 0) return;

    const rows_i: i64 = @intCast(st.rows);
    var qsep_row: i64 = rows_i - 3 - @as(i64, @intCast(st.queue_rows));
    if (qsep_row < 2) qsep_row = 2;

    try ob.print("\x1b[{d};1H", .{qsep_row});
    try ob.write(ansi.c_sep);
    var i: usize = 0;
    while (i < st.cols) : (i += 1) try ob.write(ansi.hl);
    try ob.write(ansi.reset);
    try ob.write("\x1b[K");

    var row: i64 = qsep_row + 1;
    const n = st.queue.items.items.len;
    var item_rows: usize = n;
    if (item_rows > QUEUE_SHOW_MAX) item_rows = QUEUE_SHOW_MAX;

    if (n > 0) {
        try ob.print("\x1b[{d};1H", .{row});
        row += 1;
        try ob.write(ansi.c_qbg);
        try ob.print("  " ++ ansi.bul ++ " Queue({d})", .{n});
        if (st.queue.edit_index >= 0) {
            try ob.write(ansi.c_qacc ++ "  editing history" ++ ansi.reset ++ ansi.c_qbg);
        } else if (st.queue.draft_saved) {
            try ob.write(ansi.c_qacc ++ "  draft stashed" ++ ansi.reset ++ ansi.c_qbg);
        }
        try ob.write("\x1b[K");
        try ob.write(ansi.reset);

        // scroll clamp (bin/pager.c:5020-5027)
        var max_scroll: usize = if (n > item_rows) n - item_rows else 0;
        if (st.queue.scroll_off > max_scroll) st.queue.scroll_off = max_scroll;
        if (st.queue.selected < st.queue.scroll_off) st.queue.scroll_off = st.queue.selected;
        if (st.queue.selected >= st.queue.scroll_off + item_rows) {
            st.queue.scroll_off = st.queue.selected - item_rows + 1;
        }
        _ = &max_scroll;
    }

    var compact_buf: [1024]u8 = undefined;
    var k: usize = 0;
    while (k < item_rows) : (k += 1) {
        const idx = st.queue.scroll_off + k;
        try ob.print("\x1b[{d};1H", .{row});
        row += 1;
        try ob.write(ansi.c_qbg);
        if (idx < n) {
            var max_chars: usize = if (st.cols > 12) st.cols - 12 else 0;
            if (max_chars < 12) max_chars = 12;
            const src = if (@as(i64, @intCast(idx)) == st.queue.edit_index)
                st.input.text()
            else
                st.queue.items.items[idx].prompt;
            const compact = compactPrompt(&compact_buf, src, max_chars);
            if (idx == st.queue.selected) {
                try ob.write(ansi.c_qsel);
                try ob.print("  " ++ ansi.chv ++ " {d: >2}. {s}", .{ idx + 1, compact });
                try ob.write(ansi.reset);
            } else {
                try ob.write(ansi.c_qbg);
                try ob.print("    {d: >2}. ", .{idx + 1});
                try ob.write(ansi.c_ast);
                try ob.print("{s}", .{compact});
                try ob.write(ansi.reset);
            }
        }
        try ob.write("\x1b[K");
        try ob.write(ansi.reset);
    }

    var outer_w: usize = if (st.cols > 4) st.cols - 4 else 0;
    if (outer_w < 8) outer_w = 8;
    var inner_w: usize = if (outer_w > 2) outer_w - 2 else 0;
    if (inner_w < 6) inner_w = 6;

    const lo = st.input.layout(inner_w);

    var labelbuf: [128]u8 = undefined;
    const label: []const u8 = if (st.queue.edit_index >= 0)
        std.fmt.bufPrint(&labelbuf, " Editing Queue #{d} ", .{st.queue.edit_index + 1}) catch " Prompt "
    else
        " Prompt ";
    const label_len = label.len;

    // top border
    try ob.print("\x1b[{d};1H", .{row});
    row += 1;
    try ob.write("  ");
    try ob.write(ansi.c_qacc);
    try ob.write(ansi.tl);
    if (label_len + 1 < inner_w) {
        try ob.write(ansi.hl);
        try ob.write(ansi.bold);
        try ob.write(label);
        try ob.write(ansi.reset);
        try ob.write(ansi.c_qacc);
        var j: usize = 0;
        while (j < inner_w - label_len - 1) : (j += 1) try ob.write(ansi.hl);
    } else {
        var j: usize = 0;
        while (j < inner_w) : (j += 1) try ob.write(ansi.hl);
    }
    try ob.write(ansi.tr);
    try ob.write(ansi.reset);
    try ob.write("\x1b[K");

    // input box lines
    var vis: usize = 0;
    while (vis < lo.visible_lines) : (vis += 1) {
        const li = lo.visible_start + vis;
        const start = lo.starts[li];
        const end = lo.ends[li];
        const cursor_on_line = (li == lo.cursor_line);
        var cursor_drawn = false;
        var cells: usize = 0;

        try ob.print("\x1b[{d};1H", .{row});
        row += 1;
        try ob.write("  ");
        try ob.write(ansi.c_qacc);
        try ob.write(ansi.vl);
        try ob.write(ansi.reset);
        try ob.write(ansi.c_qbg);

        var pos = start;
        while (pos < end) {
            const next = nextBoundary(st.input.buf[0..st.input.len], end, pos);
            if (cursor_on_line and !cursor_drawn and pos == st.input.cursor) {
                try ob.write(ansi.c_qsel);
                try ob.write(st.input.buf[pos..next]);
                try ob.write(ansi.reset);
                try ob.write(ansi.c_qbg);
                cursor_drawn = true;
            } else {
                try ob.write(st.input.buf[pos..next]);
            }
            pos = next;
            cells += 1;
        }
        if (cursor_on_line and !cursor_drawn) {
            try ob.write(ansi.c_qsel ++ " " ++ ansi.reset);
            try ob.write(ansi.c_qbg);
            cells += 1;
        }
        while (cells < inner_w) : (cells += 1) try ob.write(" ");
        try ob.write(ansi.reset);
        try ob.write(ansi.c_qacc);
        try ob.write(ansi.vl);
        try ob.write(ansi.reset);
        try ob.write("\x1b[K");
    }

    // bottom border
    try ob.print("\x1b[{d};1H", .{row});
    try ob.write("  ");
    try ob.write(ansi.c_qacc);
    try ob.write(ansi.bl);
    var j: usize = 0;
    while (j < inner_w) : (j += 1) try ob.write(ansi.hl);
    try ob.write(ansi.br);
    try ob.write(ansi.reset);
    try ob.write("\x1b[K");
}

/// drawFrame — compose the whole frame into `ob` (bin/pager.c `draw`, 5180-5250).
/// Rebuilds the link click-map from the visible transcript rows.
pub fn drawFrame(ob: *OutBuf, st: *State) !void {
    st.links.clear();

    if (st.first) {
        try ob.write("\x1b[?25l\x1b[2J\x1b[H");
    } else {
        try ob.write("\x1b[?25l\x1b[H");
    }

    // top separator (draw_sep, 4949)
    try ob.write(ansi.c_sep);
    var i: usize = 0;
    while (i < st.cols) : (i += 1) try ob.write(ansi.hl);
    try ob.write(ansi.reset);
    try ob.write("\x1b[K\n");

    var row: usize = 2;
    const off = st.scroll_off;

    if (off > 0) {
        try ob.print(ansi.c_hdm ++ "  " ++ ansi.uar ++ " {d} lines above  (scroll to view)" ++ ansi.reset ++ "\x1b[K\n", .{off});
        row += 1;
    }

    const avail: usize = st.crows - @as(usize, if (off > 0) 1 else 0);
    var end = off + avail;
    if (end > st.lines.len) end = st.lines.len;

    var idx = off;
    while (idx < end) : (idx += 1) {
        const ln = st.lines[idx];
        if (isWrapPlaceholder(ln)) {
            row += 1;
            continue;
        }
        try trackLine(st, ln, row);
        try ob.write(ln);
        try ob.write("\x1b[K\n");
        row += 1;
    }

    var body_end: usize = if (st.queue_rows > 0)
        (if (st.rows > 3 + st.queue_rows) st.rows - 3 - st.queue_rows else 0)
    else
        (if (st.rows > 3) st.rows - 3 else 0);
    if (body_end < row) body_end = row;
    while (row < body_end) : (row += 1) try ob.write("\x1b[K\n");

    try drawQueuePanel(ob, st);

    if (st.queue_rows == 0) {
        try ob.print("\x1b[{d};1H", .{if (st.rows >= 3) st.rows - 3 else 0});
        try ob.write(ansi.c_sep);
        i = 0;
        while (i < st.cols) : (i += 1) try ob.write(ansi.hl);
        try ob.write(ansi.reset);
        try ob.write("\x1b[K");
        try ob.print("\x1b[{d};1H", .{if (st.rows >= 2) st.rows - 2 else 0});
        try drawStatus(ob, st, st.tok, st.pct, st.ctx_limit);
        try ob.write("\x1b[K");
        try ob.print("\x1b[{d};1H", .{if (st.rows >= 1) st.rows - 1 else 0});
        try ob.write(ansi.c_qbg);
        try ob.write("\x1b[K");
        try ob.print("\x1b[{d};1H", .{st.rows});
        try drawHotkeysFooter(ob, st);
        try ob.write("\x1b[K");
    } else {
        try ob.print("\x1b[{d};1H", .{if (st.rows >= 2) st.rows - 2 else 0});
        try ob.write(ansi.c_sep);
        i = 0;
        while (i < st.cols) : (i += 1) try ob.write(ansi.hl);
        try ob.write(ansi.reset);
        try ob.write("\x1b[K");
        try ob.print("\x1b[{d};1H", .{if (st.rows >= 1) st.rows - 1 else 0});
        try drawStatus(ob, st, st.tok, st.pct, st.ctx_limit);
        try ob.write("\x1b[K");
        try ob.print("\x1b[{d};1H", .{st.rows});
        try drawHotkeysFooter(ob, st);
        try ob.write("\x1b[K");
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "LinkMap hit-test" {
    var lm = LinkMap.init(std.testing.allocator);
    defer lm.deinit();
    try lm.add(.{ .row = 2, .x0 = 3, .x1 = 10, .uri = "https://x.io" });
    try std.testing.expectEqualStrings("https://x.io", lm.at(2, 5).?);
    try std.testing.expect(lm.at(2, 20) == null);
    try std.testing.expect(lm.at(5, 5) == null);
}

test "LinkMap coalesces adjacent same-uri spans" {
    var lm = LinkMap.init(std.testing.allocator);
    defer lm.deinit();
    try lm.add(.{ .row = 1, .x0 = 1, .x1 = 1, .uri = "u" });
    try lm.add(.{ .row = 1, .x0 = 2, .x1 = 2, .uri = "u" });
    try std.testing.expectEqual(@as(usize, 1), lm.spans.items.len);
    try std.testing.expectEqual(@as(usize, 2), lm.spans.items[0].x1);
}

test "compactPrompt truncates with ellipsis and collapses newlines" {
    var buf: [64]u8 = undefined;
    const out = compactPrompt(&buf, "hello\nworld", 32);
    // newline triggers truncation; only "hello" kept + " ..."
    try std.testing.expectEqualStrings("hello ...", out);
}

test "compactPrompt fits short prompt unchanged" {
    var buf: [64]u8 = undefined;
    const out = compactPrompt(&buf, "abc", 32);
    try std.testing.expectEqualStrings("abc", out);
}
