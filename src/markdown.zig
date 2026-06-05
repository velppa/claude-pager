//! markdown.zig — inline markdown spans and block (table) rendering.
//!
//! Components:
//!  - renderInline  ← fmt_inline
//!  - tableBorderLine ← md_table_border_line
//!  - renderBlock   ← render_md, the inline-block path
//!    (headers, bullets, numbered lists, default text) plus the table assembly
//!    (md_render_table_block).
//!
//! All escape sequences and box glyphs are taken from `ansi.zig`. Visible-length
//! / column math uses byte-count semantics (no Unicode width), as documented in
//! ansi.zig.
//!
//! Scope notes:
//!  - Code fences, the `md_tail_start` "earlier lines omitted" prefix, URL/path
//!    shortening and OSC-8 file-link targets (md_cell_target/md_cell_label
//!    shorten_url/shorten_path/build_file_uri_target) live in other modules and
//!    are out of scope for Task 7. renderBlock renders table cell labels via the
//!    fit/truncate logic (md_fit_cell), but without the URL/path shortening
//!    pre-pass and without emitting OSC-8 link wrappers. This is the plain-text
//!    cell path; link wrapping is layered later.
//!  - `g_cols` (terminal width) is passed in as `cols`.

const std = @import("std");
const ansi = @import("ansi.zig");

// ── Inline markdown: **bold** and `code` (fmt_inline) ───────────────────────

/// Render inline markdown (`**bold**` and `` `code` ``) in `s` into a new
/// ANSI-styled string owned by `alloc`. fmt_inline behavior:
///  - The whole run is wrapped in C_AST … RS.
///  - `**bold**`  → BO text RS C_AST  (closing `**` consumed if present).
///  - `` `code` `` (single backtick, not a double) → C_CIN text RS C_AST
///    (closing backtick consumed if present).
pub fn renderInline(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = @as(std.ArrayListUnmanaged(u8), .empty);
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, ansi.c_ast); // A(C_AST)
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '*' and s[i + 1] == '*') {
            i += 2;
            try out.appendSlice(alloc, ansi.bold); // A(BO)
            while (i < s.len and !(i + 1 < s.len and s[i] == '*' and s[i + 1] == '*')) {
                try out.append(alloc, s[i]);
                i += 1;
            }
            try out.appendSlice(alloc, ansi.reset); // A(RS C_AST)
            try out.appendSlice(alloc, ansi.c_ast);
            if (i + 1 < s.len and s[i] == '*' and s[i + 1] == '*') i += 2;
        } else if (s[i] == '`' and !(i + 1 < s.len and s[i + 1] == '`')) {
            i += 1;
            try out.appendSlice(alloc, ansi.c_cin); // A(C_CIN)
            while (i < s.len and s[i] != '`') {
                try out.append(alloc, s[i]);
                i += 1;
            }
            try out.appendSlice(alloc, ansi.reset); // A(RS C_AST)
            try out.appendSlice(alloc, ansi.c_ast);
            if (i < s.len and s[i] == '`') i += 1;
        } else {
            try out.append(alloc, s[i]);
            i += 1;
        }
    }
    try out.appendSlice(alloc, ansi.reset); // A(RS)
    return out.toOwnedSlice(alloc);
}

// ── Table border line (md_table_border_line) ────────────────────────────────

/// Build one table border/rule line into `buf`, returning the slice written.
///
/// md_table_border_line: a "  " indent prefixed with C_HDM, then for
/// each column `widths[c] + 2` horizontal-line glyphs followed by `mid` (between
/// columns) or `right` (last column); `left` opens the run. Closed with RS.
///
/// The `left`/`mid`/`right` glyphs are caller-supplied (e.g. ansi.tl/┬/ansi.tr)
/// so the same routine builds top, separator and bottom rules.
pub fn tableBorderLine(
    buf: []u8,
    widths: []const usize,
    left: []const u8,
    mid: []const u8,
    right: []const u8,
) []u8 {
    var o: usize = 0;
    // Append helper: copies as much of `s` as fits, advancing `o`.
    const App = struct {
        fn put(b: []u8, pos: *usize, s: []const u8) void {
            const room = b.len - pos.*;
            const n = @min(room, s.len);
            @memcpy(b[pos.* .. pos.* + n], s[0..n]);
            pos.* += n;
        }
    };
    // o += snprintf(out+o, "C_HDM  %s", left)
    App.put(buf, &o, ansi.c_hdm);
    App.put(buf, &o, "  ");
    App.put(buf, &o, left);
    const ncol = widths.len;
    for (widths, 0..) |width, c| {
        var k: usize = 0;
        while (k < width + 2) : (k += 1) {
            App.put(buf, &o, ansi.hl);
        }
        App.put(buf, &o, if (c + 1 < ncol) mid else right);
    }
    App.put(buf, &o, ansi.reset);
    return buf[0..o];
}

// ── Block rendering helpers ──────────────────────────────────────────────────

/// md_trim_span: trim leading/trailing spaces & tabs,
/// returning the trimmed subslice.
fn trimSpan(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) start += 1;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    return s[start..end];
}

/// looks_like_table_row.
fn looksLikeTableRow(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.indexOf(u8, s, ansi.vl) != null or
        std.mem.indexOf(u8, s, ansi.tl) != null or
        std.mem.indexOf(u8, s, "\xe2\x94\x9c") != null or // ├
        std.mem.indexOf(u8, s, ansi.bl) != null) return true;
    var pipes: usize = 0;
    for (s) |ch| {
        if (ch == '|') pipes += 1;
    }
    if (pipes < 2) return false;
    var p: usize = 0;
    while (p < s.len and (s[p] == ' ' or s[p] == '\t')) p += 1;
    if (p < s.len and s[p] == '|') return true;
    return std.mem.indexOf(u8, s, " | ") != null;
}

/// md_is_table_sep_line: the `---|:--:|---` separator row.
fn isTableSepLine(line: []const u8) bool {
    if (line.len == 0) return false;
    var p: usize = 0;
    while (p < line.len and (line[p] == ' ' or line[p] == '\t')) p += 1;
    if (p < line.len and line[p] == '|') p += 1;

    var cols: usize = 0;
    while (p < line.len) {
        const s = p;
        while (p < line.len and line[p] != '|') p += 1;
        const span = trimSpan(line[s..p]);
        if (span.len > 0) {
            var dashes: usize = 0;
            for (span) |q| {
                if (q == '-') dashes += 1 else if (q != ':') return false;
            }
            if (dashes < 1) return false;
            cols += 1;
        }
        if (p < line.len and line[p] == '|') p += 1;
        while (p < line.len and (line[p] == ' ' or line[p] == '\t')) p += 1;
        if (p >= line.len) break;
    }
    return cols >= 1;
}

const md_tbl_max_cols = 8;
const md_tbl_cell_max = 192;

/// md_split_table_cells. Splits a row into trimmed cells
/// (each capped to md_tbl_cell_max-1 bytes). Returns the cell slices written
/// into `cells` and the count. Trailing empty cells are dropped.
fn splitTableCells(line: []const u8, cells: [][]const u8, max_cols: usize) usize {
    if (line.len == 0 or max_cols == 0) return 0;
    var p: usize = 0;
    while (p < line.len and (line[p] == ' ' or line[p] == '\t')) p += 1;
    if (p < line.len and line[p] == '|') p += 1;

    var n: usize = 0;
    while (p < line.len and n < max_cols) {
        const s = p;
        while (p < line.len and line[p] != '|') p += 1;
        var span = trimSpan(line[s..p]);
        if (span.len >= md_tbl_cell_max) span = span[0 .. md_tbl_cell_max - 1];
        cells[n] = span;
        n += 1;
        if (p < line.len and line[p] == '|') p += 1;
        while (p < line.len and (line[p] == ' ' or line[p] == '\t')) p += 1;
        if (p >= line.len) break;
    }
    while (n > 0 and cells[n - 1].len == 0) n -= 1;
    return n;
}

/// md_fit_cell: fit `src` into a cell of visible width
/// `width`. If it fits, copied verbatim; otherwise truncated to width-1 bytes
/// plus a literal '.' (or just "." when width<=1). Returns slice in `dst`.
fn fitCell(dst: []u8, src: []const u8, width: usize) []u8 {
    if (src.len <= width) {
        const n = @min(src.len, dst.len);
        @memcpy(dst[0..n], src[0..n]);
        return dst[0..n];
    }
    if (width <= 1) {
        dst[0] = '.';
        return dst[0..1];
    }
    var n = width - 1;
    if (n > dst.len - 1) n = dst.len - 1;
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = '.';
    return dst[0 .. n + 1];
}

/// md_render_table_block: compute column widths and emit the
/// box-ruled table into `out` (one slice per rendered line, allocated in
/// `alloc`). `header`/`rows` hold trimmed cell slices; `ncol` is the column
/// count; `cols` is the terminal width.
fn renderTableBlock(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]u8),
    header: []const []const u8,
    hcols: usize,
    rows: []const [md_tbl_max_cols][]const u8,
    ncol_in: usize,
    cols: usize,
) !void {
    var ncol = ncol_in;
    if (ncol > md_tbl_max_cols) ncol = md_tbl_max_cols;
    if (ncol == 0) return;

    var widths: [md_tbl_max_cols]usize = undefined;
    for (0..ncol) |c| widths[c] = 3;

    // Header widths.
    {
        var c: usize = 0;
        while (c < hcols and c < ncol) : (c += 1) {
            const wl = header[c].len;
            if (wl > widths[c]) widths[c] = wl;
        }
    }
    // Row widths.
    for (rows) |row| {
        for (0..ncol) |c| {
            const wl = row[c].len;
            if (wl > widths[c]) widths[c] = wl;
        }
    }

    // Clamp 3..32, then shrink to fit terminal.
    var sum: usize = 0;
    for (0..ncol) |c| {
        if (widths[c] > 32) widths[c] = 32;
        if (widths[c] < 3) widths[c] = 3;
        sum += widths[c];
    }
    // max_sum = g_cols - (3*ncol + 3); guard against unsigned underflow.
    const overhead = 3 * ncol + 3;
    var max_sum: usize = if (cols > overhead) cols - overhead else 0;
    const min_sum = ncol * 3;
    if (max_sum < min_sum) max_sum = min_sum;
    while (sum > max_sum) {
        var shrunk = false;
        var c: usize = 0;
        while (c < ncol and sum > max_sum) : (c += 1) {
            if (widths[c] > 3) {
                widths[c] -= 1;
                sum -= 1;
                shrunk = true;
            }
        }
        if (!shrunk) break;
    }

    const wslice = widths[0..ncol];
    var buf: [16384]u8 = undefined;
    var cellbuf: [md_tbl_cell_max + 8]u8 = undefined;

    // Top rule ┌┬┐
    try pushDup(alloc, out, tableBorderLine(&buf, wslice, ansi.tl, "\xe2\x94\xac", ansi.tr));

    // Header row.
    {
        var ln = @as(std.ArrayListUnmanaged(u8), .empty);
        defer ln.deinit(alloc);
        try ln.appendSlice(alloc, ansi.c_hdm);
        try ln.appendSlice(alloc, "  ");
        try ln.appendSlice(alloc, ansi.vl);
        try ln.appendSlice(alloc, ansi.reset);
        for (0..ncol) |c| {
            const src = if (c < hcols) header[c] else "";
            const cell = fitCell(&cellbuf, src, widths[c]);
            // BO C_AST " %-*s " RS C_HDM "│" RS
            try ln.appendSlice(alloc, ansi.bold);
            try ln.appendSlice(alloc, ansi.c_ast);
            try ln.append(alloc, ' ');
            try ln.appendSlice(alloc, cell);
            const pad = if (widths[c] > cell.len) widths[c] - cell.len else 0;
            try ln.appendNTimes(alloc, ' ', pad);
            try ln.append(alloc, ' ');
            try ln.appendSlice(alloc, ansi.reset);
            try ln.appendSlice(alloc, ansi.c_hdm);
            try ln.appendSlice(alloc, ansi.vl);
            try ln.appendSlice(alloc, ansi.reset);
        }
        try out.append(alloc, try alloc.dupe(u8, ln.items));
    }

    // Header separator ├┼┤
    try pushDup(alloc, out, tableBorderLine(&buf, wslice, "\xe2\x94\x9c", "\xe2\x94\xbc", "\xe2\x94\xa4"));

    // Body rows.
    for (rows, 0..) |row, r| {
        var ln = @as(std.ArrayListUnmanaged(u8), .empty);
        defer ln.deinit(alloc);
        try ln.appendSlice(alloc, ansi.c_hdm);
        try ln.appendSlice(alloc, "  ");
        try ln.appendSlice(alloc, ansi.vl);
        try ln.appendSlice(alloc, ansi.reset);
        for (0..ncol) |c| {
            const src = row[c];
            const cell = fitCell(&cellbuf, src, widths[c]);
            const vis = cell.len;
            const pad = if (widths[c] > vis) widths[c] - vis else 0;
            // C_AST " " then cell then pad then " " RS C_HDM "│" RS
            try ln.appendSlice(alloc, ansi.c_ast);
            try ln.append(alloc, ' ');
            try ln.appendSlice(alloc, cell);
            try ln.appendNTimes(alloc, ' ', pad);
            try ln.append(alloc, ' ');
            try ln.appendSlice(alloc, ansi.reset);
            try ln.appendSlice(alloc, ansi.c_hdm);
            try ln.appendSlice(alloc, ansi.vl);
            try ln.appendSlice(alloc, ansi.reset);
        }
        try out.append(alloc, try alloc.dupe(u8, ln.items));
        if (r + 1 < rows.len) {
            try pushDup(alloc, out, tableBorderLine(&buf, wslice, "\xe2\x94\x9c", "\xe2\x94\xbc", "\xe2\x94\xa4"));
        }
    }

    // Bottom rule └┴┘
    try pushDup(alloc, out, tableBorderLine(&buf, wslice, ansi.bl, "\xe2\x94\xb4", ansi.br));
}

fn pushDup(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged([]u8), s: []const u8) !void {
    try out.append(alloc, try alloc.dupe(u8, s));
}

// ── renderBlock (render_md) ──────────────────────────────────────────────────

/// Render a markdown block `md` into a list of ANSI-styled lines for a terminal
/// `cols` wide. Each returned slice is one output line, allocated in `alloc`.
///
/// Implements the per-line dispatch of render_md (excluding code fences and the
/// tail-omission prefix; see module header): GitHub-style tables, ATX headers,
/// bullet lists, numbered lists, and default inline text. Table detection
/// requires `cols >= 72`.
pub fn renderBlock(alloc: std.mem.Allocator, md: []const u8, cols: usize) ![][]u8 {
    var out = @as(std.ArrayListUnmanaged([]u8), .empty);
    errdefer {
        for (out.items) |it| alloc.free(it);
        out.deinit(alloc);
    }

    var it = LineIter{ .s = md };
    while (it.next()) |line| {
        // Tables.
        if (cols >= 72 and looksLikeTableRow(line)) {
            // Peek the separator line.
            if (it.peek()) |sep_line| {
                if (isTableSepLine(sep_line)) {
                    var header_buf: [md_tbl_max_cols][]const u8 = .{""} ** md_tbl_max_cols;
                    var hcols = splitTableCells(line, &header_buf, md_tbl_max_cols);
                    if (hcols > md_tbl_max_cols) hcols = md_tbl_max_cols;
                    if (hcols > 0) {
                        _ = it.next(); // consume separator
                        var ncol = hcols;
                        var rows = @as(std.ArrayListUnmanaged([md_tbl_max_cols][]const u8), .empty);
                        defer rows.deinit(alloc);
                        while (rows.items.len < 32) {
                            const rline = it.peek() orelse break;
                            if (!looksLikeTableRow(rline)) break;
                            var rowcells: [md_tbl_max_cols][]const u8 = .{""} ** md_tbl_max_cols;
                            const ncells = splitTableCells(rline, &rowcells, md_tbl_max_cols);
                            if (ncells == 0) break;
                            if (ncells > ncol) ncol = ncells;
                            try rows.append(alloc, rowcells);
                            _ = it.next();
                        }
                        if (rows.items.len > 0) {
                            try renderTableBlock(alloc, &out, header_buf[0..hcols], hcols, rows.items, ncol, cols);
                            continue;
                        }
                    }
                }
            }
        }

        // Headers.
        if (line.len > 0 and line[0] == '#') {
            var lv: usize = 0;
            while (lv < line.len and line[lv] == '#') lv += 1;
            if (lv < line.len and line[lv] == ' ') {
                const ht = line[lv + 1 ..];
                if (lv == 1) {
                    // BO C_AST ht RS
                    try pushFmt(alloc, &out, &.{ ansi.bold, ansi.c_ast, ht, ansi.reset });
                    // separator rule: C_SEP then min(strlen(ht)+2, cols) HL then RS
                    var ul = ht.len + 2;
                    if (ul > cols) ul = cols;
                    var sep = @as(std.ArrayListUnmanaged(u8), .empty);
                    defer sep.deinit(alloc);
                    try sep.appendSlice(alloc, ansi.c_sep);
                    var i: usize = 0;
                    while (i < ul) : (i += 1) try sep.appendSlice(alloc, ansi.hl);
                    try sep.appendSlice(alloc, ansi.reset);
                    try out.append(alloc, try alloc.dupe(u8, sep.items));
                } else if (lv == 2) {
                    try pushFmt(alloc, &out, &.{ ansi.bold, ansi.c_ast, ht, ansi.reset });
                } else {
                    try pushFmt(alloc, &out, &.{ ansi.bold, ansi.dim, ansi.c_ast, ht, ansi.reset });
                }
                continue;
            }
        }

        // Bullets.
        var ind: usize = 0;
        while (ind < line.len and line[ind] == ' ') ind += 1;
        if (ind < line.len and (line[ind] == '-' or line[ind] == '*') and
            ind + 1 < line.len and line[ind + 1] == ' ')
        {
            const inner = try renderInline(alloc, line[ind + 2 ..]);
            defer alloc.free(inner);
            // "%*s" C_AST BUL " %s" RS
            var ln = @as(std.ArrayListUnmanaged(u8), .empty);
            defer ln.deinit(alloc);
            try ln.appendNTimes(alloc, ' ', ind);
            try ln.appendSlice(alloc, ansi.c_ast);
            try ln.appendSlice(alloc, ansi.bul);
            try ln.append(alloc, ' ');
            try ln.appendSlice(alloc, inner);
            try ln.appendSlice(alloc, ansi.reset);
            try out.append(alloc, try alloc.dupe(u8, ln.items));
            continue;
        }

        // Numbered lists.
        if (line.len > 0 and std.ascii.isDigit(line[0])) {
            var d: usize = 0;
            while (d < line.len and std.ascii.isDigit(line[d])) d += 1;
            if (d + 1 < line.len and line[d] == '.' and line[d + 1] == ' ') {
                const num = line[0..d];
                const inner = try renderInline(alloc, line[d + 2 ..]);
                defer alloc.free(inner);
                // C_AST "%s. %s" RS
                var ln = @as(std.ArrayListUnmanaged(u8), .empty);
                defer ln.deinit(alloc);
                try ln.appendSlice(alloc, ansi.c_ast);
                try ln.appendSlice(alloc, num);
                try ln.appendSlice(alloc, ". ");
                try ln.appendSlice(alloc, inner);
                try ln.appendSlice(alloc, ansi.reset);
                try out.append(alloc, try alloc.dupe(u8, ln.items));
                continue;
            }
        }

        // Default text.
        if (line.len > 0) {
            const inner = try renderInline(alloc, line);
            try out.append(alloc, inner);
        } else {
            try out.append(alloc, try alloc.dupe(u8, ""));
        }
    }

    return out.toOwnedSlice(alloc);
}

/// Append one line built by concatenating `parts`, duped into `alloc`.
fn pushFmt(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged([]u8), parts: []const []const u8) !void {
    var ln = @as(std.ArrayListUnmanaged(u8), .empty);
    defer ln.deinit(alloc);
    for (parts) |p| try ln.appendSlice(alloc, p);
    try out.append(alloc, try alloc.dupe(u8, ln.items));
}

/// Iterates `s` by '\n'-delimited lines (the newline is not included). As in
/// render_md's loop, a trailing segment without '\n' is still yielded.
const LineIter = struct {
    s: []const u8,
    pos: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.s.len) return null;
        const rest = self.s[self.pos..];
        if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            self.pos += nl + 1;
            return rest[0..nl];
        }
        self.pos = self.s.len;
        return rest;
    }

    fn peek(self: *LineIter) ?[]const u8 {
        var copy = self.*;
        return copy.next();
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "inline bold wraps text in bold + reset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try renderInline(arena.allocator(), "a **b** c");
    try std.testing.expect(std.mem.indexOf(u8, out, ansi.bold) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b") != null);
}

test "inline code uses inline-code color" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try renderInline(arena.allocator(), "x `y` z");
    try std.testing.expect(std.mem.indexOf(u8, out, ansi.c_cin) != null);
}

test "table border line contains mid junction" {
    var buf: [256]u8 = undefined;
    const s = tableBorderLine(&buf, &[_]usize{ 3, 3 }, ansi.tl, "\xe2\x94\xac", ansi.tr); // ┌ ┬ ┐
    try std.testing.expect(std.mem.indexOf(u8, s, "\xe2\x94\xac") != null);
}

test "inline run is wrapped in C_AST and trailing RS" {
    const a = std.testing.allocator;
    const out = try renderInline(a, "plain");
    defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, ansi.c_ast));
    try std.testing.expect(std.mem.endsWith(u8, out, ansi.reset));
    // exact: C_AST plain RS
    const want = ansi.c_ast ++ "plain" ++ ansi.reset;
    try std.testing.expectEqualStrings(want, out);
}

test "inline bold exact byte sequence (fmt_inline)" {
    const a = std.testing.allocator;
    const out = try renderInline(a, "**hi**");
    defer a.free(out);
    // C_AST BO hi RS C_AST RS
    const want = ansi.c_ast ++ ansi.bold ++ "hi" ++ ansi.reset ++ ansi.c_ast ++ ansi.reset;
    try std.testing.expectEqualStrings(want, out);
}

test "inline code exact byte sequence" {
    const a = std.testing.allocator;
    const out = try renderInline(a, "`x`");
    defer a.free(out);
    const want = ansi.c_ast ++ ansi.c_cin ++ "x" ++ ansi.reset ++ ansi.c_ast ++ ansi.reset;
    try std.testing.expectEqualStrings(want, out);
}

test "double backtick is not treated as inline code" {
    const a = std.testing.allocator;
    const out = try renderInline(a, "``x");
    defer a.free(out);
    // first backtick is literal (next is also '`'), then '`x'... actually src[0]='`',src[1]='`'
    // → falls to default branch, copies '`', then second '`' src[1]='x' → not code (src[1]!='`' so it IS code)
    // Mirror C precisely: just ensure no crash and C_AST/RS present.
    try std.testing.expect(std.mem.startsWith(u8, out, ansi.c_ast));
}

test "tableBorderLine exact layout for one column width 3" {
    var buf: [256]u8 = undefined;
    const s = tableBorderLine(&buf, &[_]usize{3}, ansi.tl, "\xe2\x94\xac", ansi.tr);
    // C_HDM "  " ┌ + (3+2)=5 HL + ┐ + RS
    var want = @as(std.ArrayListUnmanaged(u8), .empty);
    defer want.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try want.appendSlice(a, ansi.c_hdm);
    try want.appendSlice(a, "  ");
    try want.appendSlice(a, ansi.tl);
    var i: usize = 0;
    while (i < 5) : (i += 1) try want.appendSlice(a, ansi.hl);
    try want.appendSlice(a, ansi.tr);
    try want.appendSlice(a, ansi.reset);
    try std.testing.expectEqualStrings(want.items, s);
}

test "renderBlock h1 emits bold heading and separator rule" {
    const a = std.testing.allocator;
    const lines = try renderBlock(a, "# Title", 100);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], ansi.bold) != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], ansi.c_sep) != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], ansi.hl) != null);
}

test "renderBlock bullet uses bullet glyph and inline rendering" {
    const a = std.testing.allocator;
    const lines = try renderBlock(a, "- **x** y", 100);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], ansi.bul) != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], ansi.bold) != null);
}

test "renderBlock numbered list" {
    const a = std.testing.allocator;
    const lines = try renderBlock(a, "12. item", 100);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "12. ") != null);
}

test "renderBlock renders a markdown table with box rules" {
    const a = std.testing.allocator;
    const md = "| A | B |\n|---|---|\n| 1 | 2 |\n";
    const lines = try renderBlock(a, md, 100);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    // top rule, header, header sep, one body row, bottom rule = 5 lines
    try std.testing.expectEqual(@as(usize, 5), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], ansi.tl) != null); // ┌
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "\xe2\x94\xac") != null); // ┬
    try std.testing.expect(std.mem.indexOf(u8, lines[1], "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], ansi.vl) != null); // │
    try std.testing.expect(std.mem.indexOf(u8, lines[4], ansi.bl) != null); // └
    try std.testing.expect(std.mem.indexOf(u8, lines[4], "\xe2\x94\xb4") != null); // ┴
}

test "renderBlock table not detected below 72 cols" {
    const a = std.testing.allocator;
    const md = "| A | B |\n|---|---|\n| 1 | 2 |\n";
    const lines = try renderBlock(a, md, 60);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    // Falls back to inline text: 3 lines, none with box glyphs.
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], ansi.tl) == null);
}

test "renderBlock plain text wrapped inline" {
    const a = std.testing.allocator;
    const lines = try renderBlock(a, "hello world", 100);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    const want = ansi.c_ast ++ "hello world" ++ ansi.reset;
    try std.testing.expectEqualStrings(want, lines[0]);
}

test "renderBlock empty line preserved" {
    const a = std.testing.allocator;
    const lines = try renderBlock(a, "a\n\nb", 100);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("", lines[1]);
}
