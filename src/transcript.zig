//! Transcript data model and a newline-delimited JSON (.jsonl) parser.
//!
//! Parses each line into an Item list (types, order, and exact text bytes)
//! using Zig's `std.json`. The helpers handle text extraction, tool_use
//! labeling, structured-patch payloads, and tool-result metadata.
//!
//! Notable parsing behaviors:
//!  - Thinking blocks are NOT emitted; only "text" and "tool_use" blocks
//!    inside assistant content are handled.
//!  - Text is trimmed (leading/trailing ' ' and '\n' only) but NOT
//!    ANSI-sanitized.
//!  - Malformed / non-message lines are skipped silently (a JSON parse error
//!    skips the line).

const std = @import("std");

pub const ItemType = enum { user, assistant, tool_use, tool_result, thinking, other };

pub const Item = struct {
    type: ItemType,
    text: []u8,
    label: ?[]u8,
    is_err: bool,
};

pub const Transcript = struct {
    items: []Item,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Transcript) void {
        self.arena.deinit();
    }
};

/// Keys probed, in order, to derive a tool_use label from its `input` object.
const lbl_keys = [_][]const u8{
    "command", "file_path", "path", "pattern", "query", "url", "content", "description",
};

const ItemList = std.ArrayListUnmanaged(Item);

/// Parses newline-delimited JSON `jsonl`. All returned strings are owned by the
/// returned Transcript's arena (created from `backing`); free everything via
/// `Transcript.deinit()`.
pub fn parse(backing: std.mem.Allocator, jsonl: []const u8) !Transcript {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();

    var items: ItemList = .empty;

    var line_it = std.mem.splitScalar(u8, jsonl, '\n');
    while (line_it.next()) |raw_line| {
        // Strip trailing CR/LF. splitScalar already removed the '\n'; drop a
        // stray trailing '\r' (and any leftover).
        var line = raw_line;
        while (line.len > 0 and (line[line.len - 1] == '\n' or line[line.len - 1] == '\r'))
            line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        // Parse the line leniently. A malformed line is skipped.
        var parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) continue;
        const obj = root.object;

        const tv = getString(obj.get("type")) orelse continue;
        const msg_val = obj.get("message") orelse continue;
        if (msg_val != .object) continue;
        const msg = msg_val.object;
        const content = msg.get("content");

        if (std.mem.eql(u8, tv, "assistant")) {
            // Content must be an array of blocks.
            const ct = content orelse continue;
            if (ct != .array) continue;
            for (ct.array.items) |block_val| {
                if (block_val != .object) continue;
                const block = block_val.object;
                const bt = getString(block.get("type")) orelse continue;
                if (std.mem.eql(u8, bt, "text")) {
                    if (try extractText(a, block.get("text"))) |t| {
                        try items.append(a, .{ .type = .assistant, .text = t, .label = null, .is_err = false });
                    }
                } else if (std.mem.eql(u8, bt, "tool_use")) {
                    try handleToolUse(a, &items, block);
                }
                // "thinking" and any other block type: ignored.
            }
        } else if (std.mem.eql(u8, tv, "user")) {
            const ct = content orelse continue;
            if (ct == .string) {
                // Plain user text.
                if (try extractText(a, ct)) |t| {
                    if (isSystag(t)) {
                        // Dropped without pushing.
                    } else {
                        try items.append(a, .{ .type = .user, .text = t, .label = null, .is_err = false });
                    }
                }
            } else if (ct == .array) {
                try handleUserArray(a, &items, obj, ct.array.items);
            }
        }
    }

    return .{
        .items = try items.toOwnedSlice(a),
        .arena = arena,
    };
}

/// Build the display name + label for a tool_use block, including the
/// Read / Edit / MultiEdit special cases and the 72-char label truncation.
fn handleToolUse(a: std.mem.Allocator, items: *ItemList, block: std.json.ObjectMap) !void {
    const nm = getString(block.get("name")) orelse "?";

    // Default display name is the tool name (nm_disp).
    var nm_disp_buf: std.ArrayListUnmanaged(u8) = .empty;
    try nm_disp_buf.appendSlice(a, nm);

    var lbl: []const u8 = "";

    const inp_val = block.get("input");
    const inp: ?std.json.ObjectMap = if (inp_val != null and inp_val.? == .object) inp_val.?.object else null;

    if (inp) |input_obj| {
        // First label candidate: first matching lbl_key whose value is a string.
        var found = false;
        for (lbl_keys) |k| {
            if (getString(input_obj.get(k))) |lv| {
                lbl = lv;
                found = true;
                break;
            }
        }
        // Fallback: first key in the object whose value is a string.
        // std.json preserves insertion order.
        if (!found) {
            var it = input_obj.iterator();
            if (it.next()) |entry| {
                if (entry.value_ptr.* == .string) lbl = entry.value_ptr.*.string;
            }
        }
    }

    // Read: "Read N lines" when input.limit > 0.
    if (asciiEqIgnoreCase(nm, "Read")) {
        if (inp) |input_obj| {
            const lim = getInt(input_obj.get("limit")) orelse 0;
            if (lim > 0) {
                nm_disp_buf.clearRetainingCapacity();
                try nm_disp_buf.print(a, "Read {d} lines", .{lim});
                lbl = "";
            }
        }
    } else if (asciiEqIgnoreCase(nm, "Edit") or asciiEqIgnoreCase(nm, "MultiEdit")) {
        // Update(file_path) / Update.
        if (inp) |input_obj| {
            var fpb: []const u8 = "";
            if (getString(input_obj.get("file_path"))) |fp| {
                fpb = fp;
            } else if (getString(input_obj.get("path"))) |fp| {
                fpb = fp;
            }
            nm_disp_buf.clearRetainingCapacity();
            if (fpb.len > 0) {
                try nm_disp_buf.print(a, "Update({s})", .{fpb});
                lbl = "";
            } else {
                try nm_disp_buf.appendSlice(a, "Update");
            }
        }
    }

    // Truncate label to 72 chars with a "..." tail: first 69 bytes + "...".
    var lbl_owned: []u8 = undefined;
    if (lbl.len > 72) {
        lbl_owned = try a.alloc(u8, 72);
        @memcpy(lbl_owned[0..69], lbl[0..69]);
        @memcpy(lbl_owned[69..72], "...");
    } else {
        lbl_owned = try a.dupe(u8, lbl);
    }

    const text = try nm_disp_buf.toOwnedSlice(a);
    try items.append(a, .{ .type = .tool_use, .text = text, .label = lbl_owned, .is_err = false });
}

/// Handle a user message whose content is an array: structuredPatch relabeling
/// of the previous tool_use, then tool_result block extraction.
fn handleUserArray(
    a: std.mem.Allocator,
    items: *ItemList,
    root_obj: std.json.ObjectMap,
    blocks: []const std.json.Value,
) !void {
    const tur_val = root_obj.get("toolUseResult");
    const tur: ?std.json.ObjectMap = if (tur_val != null and tur_val.? == .object) tur_val.?.object else null;

    var sp_add: i64 = 0;
    var sp_del: i64 = 0;
    var sp_payload: ?[]u8 = try buildStructuredPatchPayload(a, tur, &sp_add, &sp_del);
    var sp_used = false;

    // tool_use_result meta (kind + path).
    var tur_kind: []const u8 = "";
    var tur_path: []const u8 = "";
    if (tur) |t| {
        if (getString(t.get("type"))) |k| tur_kind = k;
        if (getString(t.get("filePath"))) |p| tur_path = p;
    }

    // Relabel last tool_use when we have a structured patch.
    if (sp_payload != null) {
        if (asciiEqIgnoreCase(tur_kind, "create")) {
            try relabelLastToolUse(a, items, "Create", tur_path);
        } else if (asciiEqIgnoreCase(tur_kind, "update") or asciiEqIgnoreCase(tur_kind, "edit")) {
            try relabelLastToolUse(a, items, "Update", tur_path);
        } else if (tur_path.len > 0) {
            try relabelLastToolUse(a, items, "Update", tur_path);
        }
    }

    for (blocks) |block_val| {
        if (block_val != .object) continue;
        const block = block_val.object;
        const bt = getString(block.get("type")) orelse continue;
        if (!std.mem.eql(u8, bt, "tool_result")) continue;

        const rc = block.get("content");
        var text: ?[]u8 = null;
        var handled_struct_patch = false;

        // is_error flag.
        var ie = false;
        if (block.get("is_error")) |ev| {
            switch (ev) {
                .bool => ie = ev.bool,
                .string => |s| ie = (s.len > 0 and (s[0] == 't' or s[0] == 'T')),
                else => {},
            }
        }

        // Structured-patch payload emission.
        if (!ie and sp_payload != null and !sp_used) {
            const sbuf = try std.fmt.allocPrint(a, "Added {d} lines, removed {d} lines", .{ sp_add, sp_del });
            try items.append(a, .{ .type = .tool_result, .text = sbuf, .label = null, .is_err = false });
            try items.append(a, .{ .type = .tool_result, .text = sp_payload.?, .label = null, .is_err = false });
            sp_payload = null;
            sp_used = true;
            handled_struct_patch = true;
        }

        if (!handled_struct_patch) {
            if (rc) |rcv| {
                if (rcv == .string) {
                    // String content.
                    text = try extractText(a, rcv);
                } else if (rcv == .array) {
                    // Array of blocks: concatenate text blocks with '\n'.
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    for (rcv.array.items) |sub_val| {
                        if (sub_val != .object) continue;
                        const sub = sub_val.object;
                        const st = getString(sub.get("type")) orelse continue;
                        if (!std.mem.eql(u8, st, "text")) continue;
                        if (getString(sub.get("text"))) |sv| {
                            if (buf.items.len > 0) try buf.append(a, '\n');
                            try buf.appendSlice(a, sv);
                        }
                    }
                    // Trim leading/trailing ' ' and '\n'.
                    const trimmed = std.mem.trim(u8, buf.items, " \n");
                    if (trimmed.len > 0) {
                        // Keep raw text, not sanitized.
                        text = try a.dupe(u8, trimmed);
                    }
                }
            }
        }

        if (text) |t| {
            try items.append(a, .{ .type = .tool_result, .text = t, .label = null, .is_err = ie });
        }
    }
}

/// Flatten `toolUseResult.structuredPatch` into the "CP_SP1\n..." line-prefixed
/// payload, counting +/- lines. Returns null if there's no usable structured
/// patch.
fn buildStructuredPatchPayload(
    a: std.mem.Allocator,
    tur: ?std.json.ObjectMap,
    out_add: *i64,
    out_del: *i64,
) !?[]u8 {
    out_add.* = 0;
    out_del.* = 0;
    const t = tur orelse return null;
    const sp_val = t.get("structuredPatch") orelse return null;
    if (sp_val != .array) return null;

    var sb: std.ArrayListUnmanaged(u8) = .empty;
    try sb.appendSlice(a, "CP_SP1\n");

    if (getString(t.get("filePath"))) |fp| {
        if (fp.len > 0) {
            try sb.appendSlice(a, "F\t");
            try sb.appendSlice(a, fp);
            try sb.append(a, '\n');
        }
    }

    var adds: i64 = 0;
    var dels: i64 = 0;
    var patch_count: usize = 0;
    for (sp_val.array.items) |hunk_val| {
        if (hunk_val != .object) continue;
        const hunk = hunk_val.object;
        const old_start = getInt(hunk.get("oldStart")) orelse 0;
        const old_lines = getInt(hunk.get("oldLines")) orelse 0;
        const new_start = getInt(hunk.get("newStart")) orelse 0;
        const new_lines = getInt(hunk.get("newLines")) orelse 0;
        try sb.print(a, "P\t{d}\t{d}\t{d}\t{d}\n", .{ old_start, old_lines, new_start, new_lines });

        if (hunk.get("lines")) |lv| {
            if (lv == .array) {
                for (lv.array.items) |line_val| {
                    if (line_val != .string) continue;
                    // Replace embedded CR/LF with spaces.
                    const line_buf = try a.dupe(u8, line_val.string);
                    for (line_buf) |*c| {
                        if (c.* == '\n' or c.* == '\r') c.* = ' ';
                    }
                    if (line_buf.len > 0) {
                        if (line_buf[0] == '+') adds += 1 else if (line_buf[0] == '-') dels += 1;
                    }
                    try sb.appendSlice(a, "L\t");
                    try sb.appendSlice(a, line_buf);
                    try sb.append(a, '\n');
                }
            }
        }
        try sb.appendSlice(a, "E\n");
        patch_count += 1;
    }

    if (patch_count == 0) return null;
    out_add.* = adds;
    out_del.* = dels;
    return try sb.toOwnedSlice(a);
}

/// Rewrite the most recent tool_use item whose text starts with a known
/// file-op verb to "op_name(file_path)".
fn relabelLastToolUse(
    a: std.mem.Allocator,
    items: *ItemList,
    op_name: []const u8,
    file_path: []const u8,
) !void {
    if (items.items.len == 0 or op_name.len == 0) return;
    var i: usize = items.items.len;
    while (i > 0) {
        i -= 1;
        const it = &items.items[i];
        if (it.type != .tool_use) continue;
        if (std.mem.startsWith(u8, it.text, "Write") or
            std.mem.startsWith(u8, it.text, "Edit") or
            std.mem.startsWith(u8, it.text, "MultiEdit") or
            std.mem.startsWith(u8, it.text, "Update") or
            std.mem.startsWith(u8, it.text, "Create"))
        {
            if (file_path.len > 0) {
                it.text = try std.fmt.allocPrint(a, "{s}({s})", .{ op_name, file_path });
            } else {
                it.text = try a.dupe(u8, op_name);
            }
            // Set the label to an empty string ("") rather than null.
            it.label = try a.dupe(u8, "");
        }
        // Break after the first tool_use regardless of whether it matched.
        break;
    }
}

/// Extract text from a JSON value: value must be a JSON string; trim
/// leading/trailing ' ' and '\n'; return null when empty. No ANSI sanitization.
fn extractText(a: std.mem.Allocator, value: ?std.json.Value) !?[]u8 {
    const v = value orelse return null;
    if (v != .string) return null;
    const trimmed = std.mem.trim(u8, v.string, " \n");
    if (trimmed.len == 0) return null;
    return try a.dupe(u8, trimmed);
}

/// Returns true when text is a system tag that should be filtered out.
fn isSystag(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "<local-command-caveat") != null or
        std.mem.indexOf(u8, s, "<command-name") != null or
        std.mem.indexOf(u8, s, "<system-reminder") != null or
        std.mem.indexOf(u8, s, "<user-prompt-submit-hook") != null;
}

fn getString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => v.string,
        else => null,
    };
}

/// Reads an integer from a JSON value, handling the common cases: integer,
/// float-truncation, and leading-numeric strings.
fn getInt(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => v.integer,
        .float => @intFromFloat(v.float),
        .number_string => std.fmt.parseInt(i64, v.number_string, 10) catch null,
        .string => std.fmt.parseInt(i64, std.mem.trimStart(u8, v.string, " \t"), 10) catch null,
        else => null,
    };
}

fn asciiEqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// Fixtures are embedded at compile time. In Zig 0.16 the filesystem read API
// (`std.Io.Dir.readFileAlloc`) requires an `Io` instance; `@embedFile` reads
// the exact same bytes without that plumbing and keeps the tests pure.
const fixture0 = @embedFile("fixtures/sample0.jsonl");
const fixture1 = @embedFile("fixtures/sample1.jsonl");

test "parse extracts items from fixture" {
    var tr = try parse(std.testing.allocator, fixture0);
    defer tr.deinit();
    try std.testing.expect(tr.items.len > 0);
}

test "parse handles tool_use and tool_result fixture" {
    var tr = try parse(std.testing.allocator, fixture1);
    defer tr.deinit();
    var saw_tool_use = false;
    var saw_tool_result = false;
    for (tr.items) |it| {
        if (it.type == .tool_use) saw_tool_use = true;
        if (it.type == .tool_result) saw_tool_result = true;
    }
    try std.testing.expect(saw_tool_use and saw_tool_result);
}

test "thinking blocks are dropped, not emitted" {
    // sample0 has 2 user, 2 assistant text, and 1 thinking block.
    var tr = try parse(std.testing.allocator, fixture0);
    defer tr.deinit();
    var users: usize = 0;
    var assistants: usize = 0;
    for (tr.items) |it| {
        try std.testing.expect(it.type != .thinking);
        if (it.type == .user) users += 1;
        if (it.type == .assistant) assistants += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), users);
    try std.testing.expectEqual(@as(usize, 2), assistants);
    try std.testing.expectEqual(@as(usize, 4), tr.items.len);
}

test "tool_use label derived from input, tool_result text preserved" {
    var tr = try parse(std.testing.allocator, fixture1);
    defer tr.deinit();
    var found_bash = false;
    var found_result = false;
    for (tr.items) |it| {
        if (it.type == .tool_use) {
            try std.testing.expectEqualStrings("Bash", it.text);
            // First lbl_key is "command".
            try std.testing.expectEqualStrings("ls -la /tmp/example", it.label.?);
            found_bash = true;
        }
        if (it.type == .tool_result) {
            try std.testing.expect(std.mem.startsWith(u8, it.text, "total 8"));
            try std.testing.expect(!it.is_err);
            found_result = true;
        }
    }
    try std.testing.expect(found_bash and found_result);
}

test "malformed and empty lines are skipped" {
    const input =
        "\n" ++
        "not json at all\n" ++
        "{ broken json\n" ++
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"  hello  \"}}\n" ++
        "\n";
    var tr = try parse(std.testing.allocator, input);
    defer tr.deinit();
    try std.testing.expectEqual(@as(usize, 1), tr.items.len);
    try std.testing.expectEqual(ItemType.user, tr.items[0].type);
    // Leading/trailing spaces trimmed.
    try std.testing.expectEqualStrings("hello", tr.items[0].text);
}

test "systag user messages are filtered out" {
    const input =
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"<system-reminder>ignore me</system-reminder>\"}}\n" ++
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"keep me\"}}\n";
    var tr = try parse(std.testing.allocator, input);
    defer tr.deinit();
    try std.testing.expectEqual(@as(usize, 1), tr.items.len);
    try std.testing.expectEqualStrings("keep me", tr.items[0].text);
}

test "Read tool_use with limit becomes 'Read N lines'" {
    const input =
        "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"/x\",\"limit\":42}}]}}\n";
    var tr = try parse(std.testing.allocator, input);
    defer tr.deinit();
    try std.testing.expectEqual(@as(usize, 1), tr.items.len);
    try std.testing.expectEqualStrings("Read 42 lines", tr.items[0].text);
    try std.testing.expectEqualStrings("", tr.items[0].label.?);
}

test "Edit tool_use becomes Update(file_path)" {
    const input =
        "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"/path/foo.txt\"}}]}}\n";
    var tr = try parse(std.testing.allocator, input);
    defer tr.deinit();
    try std.testing.expectEqual(@as(usize, 1), tr.items.len);
    try std.testing.expectEqualStrings("Update(/path/foo.txt)", tr.items[0].text);
    try std.testing.expectEqualStrings("", tr.items[0].label.?);
}

test "structured patch relabels tool_use and emits payload" {
    const input =
        "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"/f\"}}]}}\n" ++
        "{\"type\":\"user\",\"toolUseResult\":{\"type\":\"update\",\"filePath\":\"/f\",\"structuredPatch\":[{\"oldStart\":1,\"oldLines\":2,\"newStart\":1,\"newLines\":3,\"lines\":[\" ctx\",\"-gone\",\"+added\",\"+more\"]}]},\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"ok\"}]}}\n";
    var tr = try parse(std.testing.allocator, input);
    defer tr.deinit();
    // items: tool_use (relabeled), tool_result summary, tool_result payload.
    try std.testing.expectEqual(@as(usize, 3), tr.items.len);
    try std.testing.expectEqual(ItemType.tool_use, tr.items[0].type);
    try std.testing.expectEqualStrings("Update(/f)", tr.items[0].text);
    try std.testing.expectEqualStrings("Added 2 lines, removed 1 lines", tr.items[1].text);
    try std.testing.expect(std.mem.startsWith(u8, tr.items[2].text, "CP_SP1\n"));
    try std.testing.expect(std.mem.indexOf(u8, tr.items[2].text, "F\t/f\n") != null);
}
