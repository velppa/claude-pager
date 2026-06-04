// input.zig — prompt input buffer (text + cursor + multi-line layout) and
// terminal key decoding.
//
// Ported from bin/pager.c:
//   - input buffer / cursor / UTF-8 boundary / layout: lines 794-1003
//   - insert / delete: lines 1253-1296 (insert_raw/insert_byte/delete_prev)
//   - key decoding / escape sequences: lines 5282-5532 (Input section)
//
// Scope note: this module is ONLY the input buffer + layout + key decode. It
// deliberately contains NO queue logic and NO draft-stash (those belong to
// Task 13). It exposes the primitives the pager loop and queue will call.
//
// Width semantics match the C exactly: layout wrapping uses *codepoint cells*
// where each UTF-8 codepoint counts as one column (input_codepoint_cells /
// input_next_boundary), matching the C's byte-boundary-based wrapping.

const std = @import("std");

// Same value as the C #define QUEUE_INPUT_MAX (bin/pager.c:119).
pub const QUEUE_INPUT_MAX = 4096;

// Same value as the C #define INPUT_BOX_MAX_LINES (bin/pager.c:121).
const INPUT_BOX_MAX_LINES = 5;

pub const InputLayout = struct {
    total_lines: usize = 0,
    visible_lines: usize = 0,
    visible_start: usize = 0,
    cursor_line: usize = 0,
    cursor_col: usize = 0,
    // starts[i]/ends[i] are byte offsets into the buffer for visual line i.
    starts: [QUEUE_INPUT_MAX + 2]usize = [_]usize{0} ** (QUEUE_INPUT_MAX + 2),
    ends: [QUEUE_INPUT_MAX + 2]usize = [_]usize{0} ** (QUEUE_INPUT_MAX + 2),
};

pub const InputBuf = struct {
    buf: [QUEUE_INPUT_MAX]u8 = [_]u8{0} ** QUEUE_INPUT_MAX,
    len: usize = 0,
    cursor: usize = 0,
    goal_col: i32 = -1, // -1 = unset

    pub fn init() InputBuf {
        return .{};
    }

    // input_clear_buffer (bin/pager.c:798)
    pub fn clear(self: *InputBuf) void {
        self.len = 0;
        self.cursor = 0;
        self.buf[0] = 0;
        self.goal_col = -1;
    }

    // input_set_text (bin/pager.c:805): snprintf-truncate into the buffer, then
    // cursor goes to the end. The C buffer holds at most sizeof-1 bytes plus a
    // NUL terminator; we mirror that capacity (QUEUE_INPUT_MAX - 1 usable).
    pub fn setText(self: *InputBuf, s: []const u8) void {
        const cap = self.buf.len - 1;
        const n = @min(s.len, cap);
        @memcpy(self.buf[0..n], s[0..n]);
        self.buf[n] = 0;
        self.len = n;
        self.cursor = n;
        self.goal_col = -1;
    }

    // The current text (excluding the NUL terminator).
    pub fn text(self: *InputBuf) []const u8 {
        return self.buf[0..self.len];
    }

    // input_prev_boundary (bin/pager.c:812)
    fn prevBoundary(buf: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        var p = pos - 1;
        while (p > 0 and (buf[p] & 0xC0) == 0x80) p -= 1;
        return p;
    }

    // input_next_boundary (bin/pager.c:819)
    fn nextBoundary(buf: []const u8, len: usize, pos: usize) usize {
        if (pos >= len) return len;
        var p = pos + 1;
        while (p < len and (buf[p] & 0xC0) == 0x80) p += 1;
        return p;
    }

    // input_codepoint_cells (bin/pager.c:826)
    fn codepointCells(buf: []const u8, start: usize, end: usize) usize {
        var cells: usize = 0;
        var i = start;
        const e = if (end < start) start else end;
        while (i < e) {
            i = nextBoundary(buf, e, i);
            cells += 1;
        }
        return cells;
    }

    // input_insert_raw (bin/pager.c:1253)
    pub fn insertRaw(self: *InputBuf, s: []const u8) bool {
        if (s.len == 0) return false;
        const cap = self.buf.len - 1;
        if (self.len + s.len > cap) return false;
        // Shift the tail (including the NUL terminator) right by n.
        const tail_len = self.len - self.cursor + 1; // +1 for NUL
        var k = tail_len;
        while (k > 0) {
            k -= 1;
            self.buf[self.cursor + s.len + k] = self.buf[self.cursor + k];
        }
        @memcpy(self.buf[self.cursor .. self.cursor + s.len], s);
        self.len += s.len;
        self.cursor += s.len;
        self.goal_col = -1;
        return true;
    }

    // input_insert_byte (bin/pager.c:1266)
    pub fn insertByte(self: *InputBuf, c: u8) bool {
        const ch = [_]u8{c};
        return self.insertRaw(ch[0..]);
    }

    // input_delete_prev (bin/pager.c:1271)
    pub fn deletePrev(self: *InputBuf) bool {
        if (self.cursor == 0) return false;
        const prev = prevBoundary(self.buf[0..self.len], self.cursor);
        // Move the tail (including NUL) back to `prev`.
        const tail_len = self.len - self.cursor + 1; // +1 for NUL
        var k: usize = 0;
        while (k < tail_len) : (k += 1) {
            self.buf[prev + k] = self.buf[self.cursor + k];
        }
        self.len -= (self.cursor - prev);
        self.cursor = prev;
        self.goal_col = -1;
        return true;
    }

    // input_move_cursor_left (bin/pager.c:957)
    pub fn moveLeft(self: *InputBuf) void {
        if (self.cursor == 0) return;
        self.cursor = prevBoundary(self.buf[0..self.len], self.cursor);
        self.goal_col = -1;
    }

    // input_move_cursor_right (bin/pager.c:963)
    pub fn moveRight(self: *InputBuf) void {
        if (self.cursor >= self.len) return;
        self.cursor = nextBoundary(self.buf[0..self.len], self.len, self.cursor);
        self.goal_col = -1;
    }

    // input_move_cursor_home (bin/pager.c:969)
    pub fn moveHome(self: *InputBuf) void {
        self.cursor = 0;
        self.goal_col = -1;
    }

    // input_move_cursor_end (bin/pager.c:974)
    pub fn moveEnd(self: *InputBuf) void {
        self.cursor = self.len;
        self.goal_col = -1;
    }

    // input_layout_compute (bin/pager.c:868)
    pub fn layout(self: *InputBuf, inner_w_in: usize) InputLayout {
        var lo = InputLayout{};
        const inner_w: usize = if (inner_w_in < 1) 1 else inner_w_in;

        const len = self.len;
        var ls: usize = 0;
        var cells: usize = 0;
        var line: usize = 0;
        var cursor_line: usize = 0;
        var cursor_col: usize = 0;
        var cursor_found = false;

        if (self.cursor == 0) {
            cursor_found = true;
            cursor_line = 0;
            cursor_col = 0;
        }

        var i: usize = 0;
        while (i < len) {
            if (cells >= inner_w) {
                lo.starts[line] = ls;
                lo.ends[line] = i;
                line += 1;
                ls = i;
                cells = 0;
                if (!cursor_found and self.cursor == i) {
                    cursor_found = true;
                    cursor_line = line;
                    cursor_col = 0;
                }
                continue;
            }

            if (self.buf[i] == '\n') {
                lo.starts[line] = ls;
                lo.ends[line] = i;
                if (!cursor_found and self.cursor == i) {
                    cursor_found = true;
                    cursor_line = line;
                    cursor_col = cells;
                }
                line += 1;
                i += 1;
                ls = i;
                cells = 0;
                if (!cursor_found and self.cursor == i) {
                    cursor_found = true;
                    cursor_line = line;
                    cursor_col = 0;
                }
                continue;
            }

            i = nextBoundary(self.buf[0..len], len, i);
            cells += 1;
            if (!cursor_found and self.cursor == i) {
                cursor_found = true;
                cursor_line = line;
                cursor_col = cells;
            }
        }

        lo.starts[line] = ls;
        lo.ends[line] = len;
        if (!cursor_found) {
            cursor_line = line;
            cursor_col = codepointCells(self.buf[0..len], ls, self.cursor);
        }
        line += 1;

        lo.total_lines = if (line > 0) line else 1;
        lo.cursor_line = cursor_line;
        lo.cursor_col = cursor_col;
        lo.visible_lines = lo.total_lines;
        if (lo.visible_lines < 1) lo.visible_lines = 1;
        if (lo.visible_lines > INPUT_BOX_MAX_LINES) lo.visible_lines = INPUT_BOX_MAX_LINES;
        lo.visible_start = 0;
        if (lo.total_lines > lo.visible_lines and lo.cursor_line >= lo.visible_lines) {
            lo.visible_start = lo.cursor_line - lo.visible_lines + 1;
        }
        return lo;
    }

    // input_box_visible_lines (bin/pager.c:951)
    pub fn boxVisibleLines(self: *InputBuf, inner_w: usize) usize {
        const lo = self.layout(inner_w);
        return lo.visible_lines;
    }

    // input_move_cursor_vert (bin/pager.c:979). `dir` is -1 (up) or +1 (down).
    // The C derives inner_w from g_cols-6 (min 8); here the caller supplies it,
    // matching how the rest of this module takes inner_w as a parameter.
    pub fn moveVert(self: *InputBuf, dir: i32, inner_w: usize) void {
        const lo = self.layout(inner_w);
        if (lo.total_lines <= 1) return;

        const cur_line_i: i64 = @intCast(lo.cursor_line);
        var target_i: i64 = cur_line_i + dir;
        if (target_i < 0) target_i = 0;
        const max_line: i64 = @as(i64, @intCast(lo.total_lines)) - 1;
        if (target_i > max_line) target_i = max_line;
        if (target_i == cur_line_i) return;
        const target: usize = @intCast(target_i);

        var goal: i32 = if (self.goal_col >= 0) self.goal_col else @intCast(lo.cursor_col);
        self.goal_col = goal;

        const target_len: i32 = @intCast(codepointCells(self.buf[0..self.len], lo.starts[target], lo.ends[target]));
        if (goal > target_len) goal = target_len;

        var pos = lo.starts[target];
        var c: i32 = 0;
        while (c < goal and pos < lo.ends[target]) : (c += 1) {
            pos = nextBoundary(self.buf[0..self.len], lo.ends[target], pos);
        }
        self.cursor = pos;
    }
};

// ── Key decoding ────────────────────────────────────────────────────────────
//
// Ported from the C "Input" section (bin/pager.c:5282-5532). The C couples byte
// reading, a 2ms escape-coalescing read loop, SGR mouse decoding, and several
// globals (g_crows for page-up/down, mouse coordinate state, an input_pending
// UTF-8 reassembly queue) directly into poll_input. Per the task scope, decode()
// here is a PURE function over an already-read byte slice and covers only the
// input-buffer-relevant keys: arrows, home/end, enter, shift-enter, backspace,
// esc, delete, ctrl-letters, and literal text bytes.
//
// Deviations forced by decoupling from the C's globals (reported, not silent):
//   - Mouse (SGR `ESC [ < …`), wheel scroll, and page-up/down (`ESC [ 5/6 ~`)
//     are NOT decoded here — they depend on g_crows / mouse state and belong to
//     the pager loop, not the input buffer. They decode as .unknown.
//   - The C maps Tab → space and Ctrl-D/Ctrl-V/Ctrl-Q to queue actions inside
//     poll_input. Here Ctrl-letters surface generically as `.ctrl` so the pager
//     loop decides their meaning; Tab is `.ctrl='I'` (0x09 = Ctrl-I) likewise.

pub const Key = union(enum) {
    byte: u8, // a literal text byte to insert
    ctrl: u8, // Ctrl-<letter>, store the letter (e.g. 'q')
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    home,
    end,
    enter,
    shift_enter,
    backspace,
    esc,
    delete,
    unknown,
};

pub const DecodeResult = struct { key: Key, consumed: usize };

// Decode the next key from a byte slice already read from the terminal.
// Returns the decoded Key and how many bytes it consumed (0 if it needs more
// bytes to disambiguate an in-progress escape sequence).
pub fn decode(bytes: []const u8) DecodeResult {
    if (bytes.len == 0) return .{ .key = .unknown, .consumed = 0 };

    const b0 = bytes[0];

    if (b0 == 0x1b) return decodeEscape(bytes);

    // Single control / text byte (mirrors poll_input's n==1 branch,
    // bin/pager.c:5490-5504).
    if (b0 == '\r') return .{ .key = .enter, .consumed = 1 };
    if (b0 == '\n') return .{ .key = .shift_enter, .consumed = 1 }; // INP_NEWLINE
    if (b0 == 127 or b0 == 8) return .{ .key = .backspace, .consumed = 1 };
    if (b0 == '\t') return .{ .key = .{ .ctrl = 'I' }, .consumed = 1 }; // 0x09
    if (b0 < 32) {
        // Other control bytes → Ctrl-<letter>. 0x01 == Ctrl-A … 0x1a == Ctrl-Z.
        return .{ .key = .{ .ctrl = b0 - 1 + 'a' }, .consumed = 1 };
    }
    // b0 >= 32: literal text byte (UTF-8 lead/continuation bytes pass through
    // one at a time; the input buffer stores raw bytes, matching the C).
    return .{ .key = .{ .byte = b0 }, .consumed = 1 };
}

// decode_escape_key (bin/pager.c:5350), restricted to input-buffer keys.
fn decodeEscape(bytes: []const u8) DecodeResult {
    // Lone ESC with nothing after it: need more bytes to know if it's a bare
    // ESC keypress or the start of a CSI/SS3 sequence (C coalesces with a 2ms
    // select; here the caller must supply more bytes or eventually decide).
    if (bytes.len < 2) return .{ .key = .unknown, .consumed = 0 };

    // SS3: ESC O <final>
    if (bytes[1] == 'O') {
        if (bytes.len < 3) return .{ .key = .unknown, .consumed = 0 };
        return switch (bytes[2]) {
            'A' => .{ .key = .arrow_up, .consumed = 3 },
            'B' => .{ .key = .arrow_down, .consumed = 3 },
            'H' => .{ .key = .home, .consumed = 3 },
            'F' => .{ .key = .end, .consumed = 3 },
            else => .{ .key = .unknown, .consumed = 3 },
        };
    }

    // Anything other than CSI after ESC: treat as a bare ESC keypress, consuming
    // only the ESC byte (the following byte decodes on its own next call).
    if (bytes[1] != '[') return .{ .key = .esc, .consumed = 1 };

    // CSI: ESC [ params final. Parse digits/`;`-separated params until a final
    // byte. If we run out of bytes before a final, we need more.
    var params: [4]i32 = .{ 0, 0, 0, 0 };
    var param_count: usize = 0;
    var current: i32 = 0;
    var saw_digit = false;
    var final: u8 = 0;
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c >= '0' and c <= '9') {
            current = current * 10 + @as(i32, c - '0');
            saw_digit = true;
        } else if (c == ';') {
            if (param_count < params.len) {
                params[param_count] = current;
                param_count += 1;
            }
            current = 0;
            saw_digit = false;
        } else {
            if (saw_digit and param_count < params.len) {
                params[param_count] = current;
                param_count += 1;
            }
            final = c;
            break;
        }
    }
    if (final == 0) return .{ .key = .unknown, .consumed = 0 }; // incomplete CSI

    const consumed = i + 1;
    const p1: i32 = if (param_count >= 1) params[0] else 0;
    const p2: i32 = if (param_count >= 2) params[1] else 0;
    const p3: i32 = if (param_count >= 3) params[2] else 0;
    const have_p2 = param_count >= 2;
    const have_p3 = param_count >= 3;

    switch (final) {
        // 'A'/'B' with modifier param 2 are queue-cycle in the C (INP_QCYCLE_*);
        // for the input buffer they remain plain arrow up/down.
        'A' => return .{ .key = .arrow_up, .consumed = consumed },
        'B' => return .{ .key = .arrow_down, .consumed = consumed },
        'C' => return .{ .key = .arrow_right, .consumed = consumed },
        'D' => return .{ .key = .arrow_left, .consumed = consumed },
        'H' => return .{ .key = .home, .consumed = consumed },
        'F' => return .{ .key = .end, .consumed = consumed },
        'u' => {
            // CSI u (kitty/fixterms): 13 = Enter; with shift modifier (p2==2) it
            // is Shift+Enter / newline (bin/pager.c:5409-5414).
            if (p1 == 13) {
                if (have_p2 and p2 == 2) return .{ .key = .shift_enter, .consumed = consumed };
                return .{ .key = .enter, .consumed = consumed };
            }
            return .{ .key = .unknown, .consumed = consumed };
        },
        '~' => {
            // ESC [ 3 ~  → Delete. (C only special-cases Shift+Delete via p2==2
            // → INP_QDELETE; plain Delete is INP_NONE in the C input path, but
            // the task API asks decode to surface `.delete` for ESC [ 3 ~.)
            if (p1 == 3) return .{ .key = .delete, .consumed = consumed };
            // modifyOtherKeys Shift+Enter: ESC [ 27 ; 2 ; 13 ~ (bin/pager.c:5419)
            if (p1 == 27 and have_p2 and have_p3 and p2 == 2 and p3 == 13)
                return .{ .key = .shift_enter, .consumed = consumed };
            return .{ .key = .unknown, .consumed = consumed };
        },
        else => return .{ .key = .unknown, .consumed = consumed },
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "insert then deletePrev" {
    var ib = InputBuf.init();
    ib.setText("ab");
    try std.testing.expect(ib.insertByte('c'));
    try std.testing.expectEqualStrings("abc", ib.text());
    try std.testing.expect(ib.deletePrev());
    try std.testing.expectEqualStrings("ab", ib.text());
}

test "cursor home and end" {
    var ib = InputBuf.init();
    ib.setText("hello");
    ib.moveHome();
    try std.testing.expectEqual(@as(usize, 0), ib.cursor);
    ib.moveEnd();
    try std.testing.expectEqual(@as(usize, 5), ib.cursor);
}

test "layout wraps long text to multiple lines" {
    var ib = InputBuf.init();
    ib.setText("aaaaaaaa");
    const lo = ib.layout(4);
    try std.testing.expect(lo.total_lines >= 2);
}

test "decode arrow up" {
    const r = decode("\x1b[A");
    try std.testing.expectEqual(@as(usize, 3), r.consumed);
    try std.testing.expect(r.key == .arrow_up);
}

test "decode plain byte" {
    const r = decode("x");
    try std.testing.expectEqual(@as(usize, 1), r.consumed);
    try std.testing.expect(r.key == .byte and r.key.byte == 'x');
}

test "decode incomplete escape needs more" {
    const r = decode("\x1b");
    try std.testing.expectEqual(@as(usize, 0), r.consumed); // need more bytes
}

// ── Additional fidelity tests ───────────────────────────────────────────────

test "insert in the middle moves only the tail" {
    var ib = InputBuf.init();
    ib.setText("abc");
    ib.moveHome();
    ib.moveRight(); // cursor after 'a'
    try std.testing.expect(ib.insertByte('X'));
    try std.testing.expectEqualStrings("aXbc", ib.text());
    try std.testing.expectEqual(@as(usize, 2), ib.cursor);
}

test "utf8 boundary moves treat a codepoint as one step" {
    var ib = InputBuf.init();
    ib.setText("é"); // 2 bytes: 0xC3 0xA9
    try std.testing.expectEqual(@as(usize, 2), ib.len);
    ib.moveHome();
    ib.moveRight();
    try std.testing.expectEqual(@as(usize, 2), ib.cursor); // skipped whole cp
    ib.moveLeft();
    try std.testing.expectEqual(@as(usize, 0), ib.cursor);
}

test "deletePrev removes a whole utf8 codepoint" {
    var ib = InputBuf.init();
    ib.setText("aé");
    try std.testing.expect(ib.deletePrev());
    try std.testing.expectEqualStrings("a", ib.text());
}

test "explicit newline starts a new layout line" {
    var ib = InputBuf.init();
    ib.setText("ab\ncd");
    const lo = ib.layout(80);
    try std.testing.expectEqual(@as(usize, 2), lo.total_lines);
    try std.testing.expectEqual(@as(usize, 0), lo.starts[0]);
    try std.testing.expectEqual(@as(usize, 2), lo.ends[0]);
    try std.testing.expectEqual(@as(usize, 3), lo.starts[1]);
    try std.testing.expectEqual(@as(usize, 5), lo.ends[1]);
}

test "layout caps visible lines at INPUT_BOX_MAX_LINES" {
    var ib = InputBuf.init();
    ib.setText("a\nb\nc\nd\ne\nf\ng");
    const lo = ib.layout(80);
    try std.testing.expectEqual(@as(usize, 7), lo.total_lines);
    try std.testing.expectEqual(@as(usize, INPUT_BOX_MAX_LINES), lo.visible_lines);
}

test "moveVert down keeps goal column" {
    var ib = InputBuf.init();
    ib.setText("abcd\nef");
    // cursor at end (after 'f'); move up should land within "abcd".
    ib.moveVert(-1, 80);
    const lo = ib.layout(80);
    try std.testing.expectEqual(@as(usize, 0), lo.cursor_line);
}

test "decode CSI shift-enter via modifyOtherKeys" {
    const r = decode("\x1b[27;2;13~");
    try std.testing.expect(r.key == .shift_enter);
    try std.testing.expectEqual(@as(usize, 10), r.consumed);
}

test "decode CSI u enter and shift-enter" {
    const e = decode("\x1b[13u");
    try std.testing.expect(e.key == .enter);
    const se = decode("\x1b[13;2u");
    try std.testing.expect(se.key == .shift_enter);
}

test "decode delete ESC[3~" {
    const r = decode("\x1b[3~");
    try std.testing.expect(r.key == .delete);
    try std.testing.expectEqual(@as(usize, 4), r.consumed);
}

test "decode SS3 arrows and home/end" {
    try std.testing.expect(decode("\x1bOA").key == .arrow_up);
    try std.testing.expect(decode("\x1bOB").key == .arrow_down);
    try std.testing.expect(decode("\x1bOH").key == .home);
    try std.testing.expect(decode("\x1bOF").key == .end);
}

test "decode CSI arrows left/right and home/end" {
    try std.testing.expect(decode("\x1b[C").key == .arrow_right);
    try std.testing.expect(decode("\x1b[D").key == .arrow_left);
    try std.testing.expect(decode("\x1b[H").key == .home);
    try std.testing.expect(decode("\x1b[F").key == .end);
}

test "decode incomplete CSI needs more bytes" {
    const r = decode("\x1b[1;");
    try std.testing.expectEqual(@as(usize, 0), r.consumed);
}

test "decode enter and backspace single bytes" {
    try std.testing.expect(decode("\r").key == .enter);
    try std.testing.expect(decode("\n").key == .shift_enter);
    try std.testing.expect(decode("\x7f").key == .backspace);
    try std.testing.expect(decode("\x08").key == .backspace);
}

test "decode ctrl letters" {
    const q = decode("\x11"); // Ctrl-Q
    try std.testing.expect(q.key == .ctrl and q.key.ctrl == 'q');
    const v = decode("\x16"); // Ctrl-V
    try std.testing.expect(v.key == .ctrl and v.key.ctrl == 'v');
}

test "decode bare esc consumes one byte" {
    const r = decode("\x1bZ"); // ESC then a non-CSI byte
    try std.testing.expect(r.key == .esc);
    try std.testing.expectEqual(@as(usize, 1), r.consumed);
}

test "insertRaw respects capacity" {
    var ib = InputBuf.init();
    // Fill to one below capacity.
    var i: usize = 0;
    while (i < QUEUE_INPUT_MAX - 1) : (i += 1) {
        try std.testing.expect(ib.insertByte('a'));
    }
    // Buffer is now full (cap = QUEUE_INPUT_MAX - 1); next insert must fail.
    try std.testing.expect(!ib.insertByte('b'));
}

test "clear resets everything" {
    var ib = InputBuf.init();
    ib.setText("stuff");
    ib.clear();
    try std.testing.expectEqual(@as(usize, 0), ib.len);
    try std.testing.expectEqual(@as(usize, 0), ib.cursor);
    try std.testing.expectEqual(@as(i32, -1), ib.goal_col);
}
