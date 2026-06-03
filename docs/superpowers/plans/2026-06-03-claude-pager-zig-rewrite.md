# claude-pager C → Zig Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the C implementation of claude-pager with a Zig (`std`-only) implementation producing the same two binaries with equivalent behavior, and remove the external TurboDraft socket fast-path.

**Architecture:** Bottom-up port gated by golden-output parity. Leaf/pure modules first (validated byte-identical to the C `pager_render_plain`), then interactive layers, then the launcher (without TurboDraft). `pager.c`'s ~30 file globals become fields of a `State` struct.

**Tech Stack:** Zig 0.16.0, `std` only (no `@cImport`, no third-party deps; libSystem linked implicitly on macOS). `std.json`, `std.posix`, `std.fs`, `std.ArrayList`.

---

## Reference & ground rules

- **C porting oracle:** the C sources in `bin/` at the spec commit (`8372791`). Each port task names the exact C file + line range to translate. Do NOT delete `bin/` until Task 19.
- **Correctness oracle:** golden fixtures captured in Task 0 (plain-render byte-equality) + per-module unit tests.
- TDD: write/adjust the test, watch it fail, port the module, watch it pass, commit.
- Every module is one file with one responsibility. Keep files focused.
- After each task: `zig build test` green before commit.

## File structure (`src/`)

| File | Responsibility | Ported from |
|---|---|---|
| `main_open.zig` | entry: `claude-pager-open` | `claude-pager-open.c` `main` |
| `main_cli.zig` | entry: `claude-pager-c` | `pager_cli.c` |
| `ansi.zig` | SGR constants, `visibleLen` | pager.c ANSI, visible-length |
| `term.zig` | raw mode, winsize, `/dev/tty` | pager.c Terminal |
| `outbuf.zig` | output byte buffer | pager.c Output buffer |
| `log.zig` | debug logging (`CLAUDE_PAGER_DEBUG`) | both Debug logging |
| `transcript.zig` | `Item`/`Transcript` model + `std.json` parse | pager.c Transcript items+parser |
| `links.zig` | OSC-8 linkification | pager.c OSC-8 |
| `markdown.zig` | inline + table render | pager.c markdown |
| `render.zig` | `Item` → styled `Line`s | pager.c Item renderer |
| `render_plain.zig` | styled lines → plain text (trailing-ws trim) | pager.c Plain-text render |
| `input.zig` | key decode, editing, `InputLayout` | pager.c Input |
| `queue.zig` | queue model + draft-stash + layout glue | pager.c Prompt queue |
| `queue_persist.zig` | serialize/load, lock, fingerprint | pager.c queue serialize/lock |
| `queue_clipboard.zig` | pbpaste text, clipboard PNG/file refs | pager.c queue clipboard |
| `draw.zig` | viewport/frame drawing | pager.c Drawing |
| `pager.zig` | `State` + `runPager` loop | pager.c Main loop, Globals |
| `settings.zig` | read editor vars from settings.json | open.c settings |
| `editor.zig` | validation, gui/terminal detect, self-ref | open.c editor detect |
| `open.zig` | fork pager, generic/terminal launch, pre-render | open.c editor paths |

**Shared public types** (defined Task 6, used everywhere after):

```zig
// transcript.zig
pub const ItemType = enum { user, assistant, tool_use, tool_result, thinking, other };
pub const Item = struct { type: ItemType, text: []u8, label: ?[]u8, is_err: bool };
pub const Transcript = struct {
    items: []Item,
    token_count: usize,
    pct: f64,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *Transcript) void { self.arena.deinit(); }
};
pub fn parse(arena: std.mem.Allocator, jsonl: []const u8, ctx_limit: usize) !Transcript;

// render.zig
pub const Line = []u8;                       // one rendered terminal line (may contain ANSI)
pub fn renderItems(alloc: std.mem.Allocator, items: []const Item, cols: usize) ![]Line;
```

---

### Task 0: Capture golden fixtures from the C build

**Files:**
- Create: `tests/fixtures/README.md`
- Create: `tests/fixtures/*.jsonl` (sample transcripts)
- Create: `tests/fixtures/*.plain.txt` (expected plain renders)
- Create: `tests/gen_golden.sh`

- [ ] **Step 1: Build the current C**

Run: `cd bin && make && cd ..`
Expected: `bin/claude-pager-c` and `bin/claude-pager-open` built.

- [ ] **Step 2: Collect 3 sample transcripts**

Copy three real `.jsonl` transcripts of varying size into `tests/fixtures/`:

```bash
mkdir -p tests/fixtures
i=0; for f in $(ls -S "$HOME/.claude/projects/-Users-pavel-Notes"/*.jsonl | head -3); do
  cp "$f" "tests/fixtures/sample$i.jsonl"; i=$((i+1)); done
ls tests/fixtures
```
Expected: `sample0.jsonl sample1.jsonl sample2.jsonl`.

- [ ] **Step 3: Write `tests/gen_golden.sh`**

```bash
#!/usr/bin/env bash
# Regenerate golden plain-render fixtures from the C build.
# Usage: tests/gen_golden.sh   (run from repo root, after `cd bin && make`)
set -euo pipefail
cat > /tmp/cpg_golden.c <<'EOF'
#include "pager.h"
int main(int c, char **v){ return pager_render_plain(v[1], v[2], 110, 200000); }
EOF
clang -O2 -Ibin -o /tmp/cpg_golden /tmp/cpg_golden.c bin/pager.o
for jf in tests/fixtures/sample*.jsonl; do
  /tmp/cpg_golden "$jf" "${jf%.jsonl}.plain.txt"
done
echo "golden fixtures regenerated at cols=110 ctx=200000"
```

- [ ] **Step 4: Generate fixtures and verify trailing-ws trimmed**

Run: `chmod +x tests/gen_golden.sh && tests/gen_golden.sh`
Then: `grep -c ' $' tests/fixtures/sample0.plain.txt`
Expected: `0` (the shipped trim).

- [ ] **Step 5: Document and commit**

Write `tests/fixtures/README.md`: "Golden plain-render fixtures generated from the C build at commit 8372791 via `tests/gen_golden.sh`, cols=110 ctx=200000. The Zig port must reproduce `*.plain.txt` byte-for-byte from `*.jsonl`."

```bash
git add -f tests/fixtures tests/gen_golden.sh
git commit -m "test: capture golden plain-render fixtures from C build"
```

---

### Task 1: Zig project scaffold (two compiling exes + test runner)

**Files:**
- Create: `build.zig`, `build.zig.zon`
- Create: `src/main_open.zig`, `src/main_cli.zig`
- Modify: `.gitignore`

- [ ] **Step 1: Write `build.zig.zon`**

```zig
.{
    .name = .claude_pager,
    .version = "3.0.0",
    .fingerprint = 0x0, // replace with value zig prints on first build
    .minimum_zig_version = "0.16.0",
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

- [ ] **Step 2: Write `build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_open = b.addExecutable(.{
        .name = "claude-pager-open",
        .root_source_file = b.path("src/main_open.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe_cli = b.addExecutable(.{
        .name = "claude-pager-c",
        .root_source_file = b.path("src/main_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe_open);
    b.installArtifact(exe_cli);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
```

- [ ] **Step 3: Write minimal entrypoints + test aggregator**

`src/main_open.zig`:
```zig
const std = @import("std");
pub fn main() !void {
    std.debug.print("claude-pager-open stub\n", .{});
}
```
`src/main_cli.zig`:
```zig
const std = @import("std");
pub fn main() !void {
    std.debug.print("claude-pager-c stub\n", .{});
}
```
`src/tests.zig`:
```zig
test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
```

- [ ] **Step 4: Build + run tests**

Run: `zig build && zig build test`
Expected: both binaries in `zig-out/bin/`; test step exits 0. (On first build, copy the printed `fingerprint` into `build.zig.zon` and rebuild.)

- [ ] **Step 5: Update `.gitignore` and commit**

Add to `.gitignore`:
```
zig-out/
.zig-cache/
```

```bash
git add -f build.zig build.zig.zon src/main_open.zig src/main_cli.zig src/tests.zig .gitignore
git commit -m "build: scaffold Zig project with two exes and test runner"
```

---

### Task 2: `ansi.zig` — SGR constants + visible length

**Files:**
- Create: `src/ansi.zig`
- Test: in `src/ansi.zig` (`test` blocks)
- Reference: `bin/pager.c:28-90` (ANSI), `bin/pager.c:2241-2286` (visible length).

- [ ] **Step 1: Write failing tests**

```zig
// src/ansi.zig
const std = @import("std");
test "visibleLen ignores SGR sequences" {
    try std.testing.expectEqual(@as(usize, 3), visibleLen("\x1b[31mabc\x1b[0m"));
}
test "visibleLen counts wide CJK as 2" {
    try std.testing.expectEqual(@as(usize, 2), visibleLen("世"));
}
test "visibleLen plain ascii" {
    try std.testing.expectEqual(@as(usize, 5), visibleLen("hello"));
}
```

- [ ] **Step 2: Run, verify fail**

Run: `zig build test`
Expected: FAIL — `visibleLen` undefined.

- [ ] **Step 3: Implement**

Port the SGR color/style string constants from `bin/pager.c:28-90` as `pub const` (e.g. `pub const reset = "\x1b[0m";`). Port the ANSI-aware width walker from `bin/pager.c:2241-2286` to:
```zig
pub fn visibleLen(s: []const u8) usize { ... }
```
Skip CSI (`ESC [ ... final 0x40-0x7e`) and OSC (`ESC ] ... BEL|ST`); for visible bytes decode UTF-8 and add `std.unicode`-based East-Asian wide = 2 else 1, matching the C `wcwidth`-style logic.

- [ ] **Step 4: Run, verify pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/ansi.zig
git commit -m "feat(zig): ansi constants and visible-length"
```

---

### Task 3: `links.zig` — OSC-8 linkification

**Files:**
- Create: `src/links.zig`
- Reference: `bin/pager.c:2287-2954`.

- [ ] **Step 1: Write failing test**

```zig
const std = @import("std");
test "linkify wraps bare url in OSC-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try linkify(arena.allocator(), "see https://x.io now", 80);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]8;;https://x.io\x1b\\") != null);
}
```

- [ ] **Step 2: Run, verify fail**

Run: `zig build test` — FAIL, `linkify` undefined.

- [ ] **Step 3: Implement**

Port URL detection + OSC-8 wrapping from `bin/pager.c:2287-2954`:
```zig
pub fn linkify(alloc: std.mem.Allocator, line: []const u8, cols: usize) ![]u8;
```
Preserve the C's URL boundary rules and the `LinkSpan`/`LinkMap` row/x0/x1 tracking only if needed by `draw` (defer the click-map to Task 12; expose just the string transform here, plus a `pub const LinkSpan`).

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/links.zig
git commit -m "feat(zig): OSC-8 linkification"
```

---

### Task 4: `outbuf.zig` + `log.zig`

**Files:**
- Create: `src/outbuf.zig`, `src/log.zig`
- Reference: `bin/pager.c:560-617` (output buffer); `bin/claude-pager-open.c:33-52` + `bin/pager.c` debug (logging).

- [ ] **Step 1: Write failing tests**

```zig
// src/outbuf.zig
const std = @import("std");
test "outbuf appends and reads" {
    var b = OutBuf.init(std.testing.allocator);
    defer b.deinit();
    try b.write("ab"); try b.print("{d}", .{12});
    try std.testing.expectEqualStrings("ab12", b.bytes());
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

`outbuf.zig`: thin wrapper over `std.ArrayList(u8)`:
```zig
pub const OutBuf = struct {
    list: std.ArrayList(u8),
    pub fn init(a: std.mem.Allocator) OutBuf;
    pub fn deinit(self: *OutBuf) void;
    pub fn write(self: *OutBuf, s: []const u8) !void;
    pub fn print(self: *OutBuf, comptime fmt: []const u8, args: anytype) !void;
    pub fn bytes(self: *OutBuf) []const u8;
    pub fn clear(self: *OutBuf) void;
};
```
`log.zig`: debug logger gated by `CLAUDE_PAGER_DEBUG` env, writing timestamped lines to the debug file the C used:
```zig
pub fn open() void;            // no-op if env unset
pub fn dbg(comptime fmt: []const u8, args: anytype) void;
```

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/outbuf.zig src/log.zig
git commit -m "feat(zig): output buffer and debug logging"
```

---

### Task 5: `term.zig` — raw mode, winsize, /dev/tty

**Files:**
- Create: `src/term.zig`
- Reference: `bin/pager.c:5252-5281` (Terminal); `bin/claude-pager-open.c` winsize usage.

- [ ] **Step 1: Write failing test (winsize parse helper is the only pure-testable bit)**

```zig
const std = @import("std");
test "Winsize default fallback" {
    const ws = Winsize{ .rows = 0, .cols = 0 };
    try std.testing.expectEqual(@as(u16, 80), ws.colsOr(80));
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

```zig
pub const Winsize = struct {
    rows: u16, cols: u16,
    pub fn colsOr(self: Winsize, d: u16) u16 { return if (self.cols == 0) d else self.cols; }
};
pub fn openTty() !std.fs.File;                 // open("/dev/tty", O_RDWR)
pub fn getWinsize(fd: std.posix.fd_t) Winsize; // std.c.ioctl(fd, TIOCGWINSZ, ...)
pub const RawMode = struct {
    fd: std.posix.fd_t, orig: std.posix.termios,
    pub fn enable(fd: std.posix.fd_t) !RawMode;  // cfmakeraw-equivalent via tcgetattr/tcsetattr
    pub fn restore(self: RawMode) void;          // tcsetattr orig  (call via defer)
};
```
Port flag manipulation from `bin/pager.c:5252-5281`. Use `std.c.ioctl` for `TIOCGWINSZ` (libSystem on macOS).

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/term.zig
git commit -m "feat(zig): terminal raw mode, winsize, /dev/tty"
```

---

### Task 6: `transcript.zig` — model + std.json parser

**Files:**
- Create: `src/transcript.zig`
- Reference: `bin/pager.c:2955-3494` (items + parser; `Item`/`Items` at 2958-2959). Replace the hand-rolled JSON scanner (`bin/pager.c:618-719`) with `std.json`.

- [ ] **Step 1: Write failing test against a fixture**

```zig
const std = @import("std");
const t = @import("transcript.zig");
test "parse extracts user and assistant items" {
    const data = try std.fs.cwd().readFileAlloc(
        std.testing.allocator, "tests/fixtures/sample0.jsonl", 50 * 1024 * 1024);
    defer std.testing.allocator.free(data);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tr = try t.parse(arena.allocator(), data, 200000);
    try std.testing.expect(tr.items.len > 0);
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL, `parse` undefined.

- [ ] **Step 3: Implement**

Define `ItemType`, `Item`, `Transcript`, `parse` exactly as in the **Shared public types** section above. Parse each `.jsonl` line with `std.json.parseFromSlice` (or `std.json.Scanner` for streaming); map message roles + content blocks to `Item`s following `bin/pager.c:3329-3494` (`text`/`tool_use`/`tool_result`/`thinking` handling, error flags, token count + pct from `ctx_limit`). Allocate item strings in the arena.

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/transcript.zig
git commit -m "feat(zig): transcript model and std.json parser"
```

---

### Task 7: `markdown.zig` — inline + table render

**Files:**
- Create: `src/markdown.zig`
- Reference: `bin/pager.c:3495-3914` (inline `**bold**`/`` `code` ``, markdown renderer, table border helpers `md_table_border_line` at 3679, `md_trim_span` at 3555).

- [ ] **Step 1: Write failing tests**

```zig
const std = @import("std");
test "inline bold becomes SGR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try renderInline(arena.allocator(), "a **b** c");
    try std.testing.expect(std.mem.indexOf(u8, out, "b") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[") != null);
}
test "table border line draws box rule" {
    var buf: [256]u8 = undefined;
    const s = tableBorderLine(&buf, &[_]usize{3,3}, "┌","┬","┐");
    try std.testing.expect(std.mem.indexOf(u8, s, "┬") != null);
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

```zig
pub fn renderInline(alloc: std.mem.Allocator, s: []const u8) ![]u8;
pub fn renderBlock(alloc: std.mem.Allocator, md: []const u8, cols: usize) ![][]u8; // lines
pub fn tableBorderLine(buf: []u8, widths: []const usize, l: []const u8, mid: []const u8, r: []const u8) []u8;
```
Port from `bin/pager.c:3495-3914`, preserving the `┌┬┐ ├┼┤ └┴┘ │` glyphs and column-width math.

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/markdown.zig
git commit -m "feat(zig): markdown inline and table rendering"
```

---

### Task 8: `render.zig` — item → styled lines

**Files:**
- Create: `src/render.zig`
- Reference: `bin/pager.c:3915-4946` (Item renderer); dynamic line array `bin/pager.c:2140-2240`.

- [ ] **Step 1: Write failing test**

```zig
const std = @import("std");
const t = @import("transcript.zig");
const r = @import("render.zig");
test "renderItems produces lines for a parsed transcript" {
    const data = try std.fs.cwd().readFileAlloc(
        std.testing.allocator, "tests/fixtures/sample0.jsonl", 50 * 1024 * 1024);
    defer std.testing.allocator.free(data);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tr = try t.parse(arena.allocator(), data, 200000);
    const lines = try r.renderItems(arena.allocator(), tr.items, 110);
    try std.testing.expect(lines.len > 0);
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

Implement `renderItems` (signature in Shared public types) by porting `bin/pager.c:3915-4946`: per-item role headers (`▶ USER`/`◀ ASSISTANT`), tool_use/tool_result formatting, markdown via `markdown.zig`, wrapping to `cols`, wrap-placeholder rows, and links via `links.zig`. Return `[]Line` (each an owned `[]u8`).

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/render.zig
git commit -m "feat(zig): transcript item renderer"
```

---

### Task 9: `render_plain.zig` + GOLDEN PARITY GATE

**Files:**
- Create: `src/render_plain.zig`
- Reference: `bin/pager.c:5990-6068` (the function already carrying the trailing-ws trim).

- [ ] **Step 1: Write the parity test (the milestone)**

```zig
const std = @import("std");
const rp = @import("render_plain.zig");
fn parityCase(comptime name: []const u8) !void {
    const tmp = "/tmp/zig_" ++ name ++ ".plain.txt";
    try rp.renderPlain(std.testing.allocator,
        "tests/fixtures/" ++ name ++ ".jsonl", tmp, 110, 200000);
    const got = try std.fs.cwd().readFileAlloc(std.testing.allocator, tmp, 50 * 1024 * 1024);
    defer std.testing.allocator.free(got);
    const want = try std.fs.cwd().readFileAlloc(std.testing.allocator,
        "tests/fixtures/" ++ name ++ ".plain.txt", 50 * 1024 * 1024);
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, got);
}
test "plain render parity sample0" { try parityCase("sample0"); }
test "plain render parity sample1" { try parityCase("sample1"); }
test "plain render parity sample2" { try parityCase("sample2"); }
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL (`renderPlain` undefined / mismatch).

- [ ] **Step 3: Implement**

```zig
pub fn renderPlain(alloc: std.mem.Allocator, transcript_path: []const u8,
                   out_path: []const u8, cols: usize, ctx_limit: usize) !void;
```
Port `bin/pager.c:5990-6068`: read file → `transcript.parse` → `render.renderItems` → for each line strip ANSI (CSI+OSC, keep OSC-8 visible text, drop URI), **rstrip trailing space/tab/CR**, write line + `\n`. Skip wrap-placeholder lines.

- [ ] **Step 4: Iterate to byte-equality**

Run: `zig build test`
Expected: all three parity tests PASS. If a diff appears, compare with `diff <(...) tests/fixtures/sampleN.plain.txt` and fix `render`/`markdown` until byte-identical. **This gate validates the entire non-interactive render pipeline.**

- [ ] **Step 5: Commit**

```bash
git add -f src/render_plain.zig src/tests.zig
git commit -m "feat(zig): plain render with golden parity gate"
```

---

### Task 10: `input.zig` — key decode, editing, layout

**Files:**
- Create: `src/input.zig`
- Reference: `bin/pager.c:794-1003` (input buffer/cursor/layout), `bin/pager.c:1253-1296` (insert/delete), `bin/pager.c:5282-5532` (Input/key decode). `InputLayout` struct at `bin/pager.c:186-194`.

- [ ] **Step 1: Write failing tests**

```zig
const std = @import("std");
test "insert then delete prev" {
    var ib = InputBuf.init();
    ib.setText("ab");
    _ = ib.insertByte('c');
    try std.testing.expectEqualStrings("abc", ib.text());
    _ = ib.deletePrev();
    try std.testing.expectEqualStrings("ab", ib.text());
}
test "cursor home/end" {
    var ib = InputBuf.init();
    ib.setText("hello");
    ib.moveHome(); try std.testing.expectEqual(@as(usize,0), ib.cursor);
    ib.moveEnd();  try std.testing.expectEqual(@as(usize,5), ib.cursor);
}
test "layout wraps to inner width" {
    var ib = InputBuf.init();
    ib.setText("aaaaaaaa");
    const lo = ib.layout(4);
    try std.testing.expect(lo.total_lines >= 2);
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

```zig
pub const InputLayout = struct { total_lines: usize, visible_lines: usize, visible_start: usize,
    cursor_line: usize, cursor_col: usize, starts: []usize, ends: []usize };
pub const InputBuf = struct {
    buf: [QUEUE_INPUT_MAX]u8, len: usize, cursor: usize, goal_col: i32,
    pub fn init() InputBuf;
    pub fn setText(self: *InputBuf, s: []const u8) void;
    pub fn text(self: *InputBuf) []const u8;
    pub fn insertByte(self: *InputBuf, c: u8) bool;
    pub fn insertRaw(self: *InputBuf, s: []const u8) bool;
    pub fn deletePrev(self: *InputBuf) bool;
    pub fn moveLeft(self: *InputBuf) void;
    pub fn moveRight(self: *InputBuf) void;
    pub fn moveHome(self: *InputBuf) void;
    pub fn moveEnd(self: *InputBuf) void;
    pub fn moveVert(self: *InputBuf, dir: i32, inner_w: usize) void;
    pub fn layout(self: *InputBuf, inner_w: usize) InputLayout;
};
pub const Key = union(enum) { byte: u8, ctrl: u8, arrow: enum{up,down,left,right},
    home, end, enter, shift_enter, backspace, esc, ctrl_q, /* ... */ };
pub fn decode(pending: []const u8) struct { key: ?Key, consumed: usize };
```
Port editing + UTF-8 boundary logic (`bin/pager.c:812-836`) and escape-sequence decode (`bin/pager.c:5282-5532`). `QUEUE_INPUT_MAX` = same `#define` as C.

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/input.zig
git commit -m "feat(zig): input buffer, editing, key decode"
```

---

### Task 11: `queue_persist.zig` — serialize/load, lock, fingerprint

**Files:**
- Create: `src/queue_persist.zig`
- Reference: `bin/pager.c:1297-1475+` (json escape, hash/fingerprint, lock open/close, skip-json helpers, serialize item), queue file path `bin/pager.c:1081-1101`, `pager_queue_attachment_for_transcript` (in `pager.h`).

- [ ] **Step 1: Write failing tests**

```zig
const std = @import("std");
test "serialize then load roundtrips a queue item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = [_]QueueItem{.{ .prompt = "hi", .persisted_id = null,
        .added_us = 123, .has_added_us = true, .encoding_json = false, .raw_json = null }};
    const json = try serialize(arena.allocator(), &items);
    const back = try load(arena.allocator(), json);
    try std.testing.expectEqualStrings("hi", back[0].prompt);
}
test "fingerprint stable for same bytes" {
    try std.testing.expectEqualStrings(fingerprint("abc"), fingerprint("abc"));
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

```zig
pub const QueueItem = struct { prompt: []u8, persisted_id: ?[]u8, added_us: i64,
    has_added_us: bool, encoding_json: bool, raw_json: ?[]u8 };
pub fn serialize(alloc: std.mem.Allocator, items: []const QueueItem) ![]u8;   // format v1
pub fn load(alloc: std.mem.Allocator, json: []const u8) ![]QueueItem;
pub fn fingerprint(bytes: []const u8) [16]u8;                                 // hash hex
pub fn queuePathFor(transcript: []const u8, out: []u8) ![]u8;
pub const Lock = struct { fd: std.posix.fd_t, pub fn acquire(path: []const u8) !Lock; pub fn release(self: Lock) void; };
pub fn attachmentForTranscript(transcript: []const u8, out_path: []u8, out_key: []u8) !struct{ path: []u8, key: []u8 };
```
Use `std.json` for (de)serialization keeping `PAGER_QUEUE_FORMAT_VERSION = 1`. Port hash/lock from the C verbatim in behavior.

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/queue_persist.zig
git commit -m "feat(zig): queue persistence, locking, fingerprint"
```

---

### Task 12: `queue_clipboard.zig` — pbpaste text, clipboard image/file refs

**Files:**
- Create: `src/queue_clipboard.zig`
- Reference: `bin/pager.c:1116-1252` (assets dir, export clipboard PNG, attach image, pbpaste text, file refs, ref token).

- [ ] **Step 1: Write failing test (token formatting is the pure-testable part)**

```zig
const std = @import("std");
test "makeRefToken formats path ref" {
    var buf: [256]u8 = undefined;
    const tok = try makeRefToken("/tmp/x.png", &buf);
    try std.testing.expect(std.mem.indexOf(u8, tok, "x.png") != null);
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

```zig
pub fn assetsDir(out: []u8) ![]u8;
pub fn readPbpasteText(alloc: std.mem.Allocator) !?[]u8;                 // spawn `pbpaste`
pub fn exportClipboardPng(dst_path: []const u8) !bool;                   // spawn `osascript`/`pngpaste` per C
pub fn attachClipboardImage(out_path: []u8) !?[]u8;
pub fn attachClipboardFileRefs(alloc: std.mem.Allocator) !?[]u8;
pub fn makeRefToken(path: []const u8, out: []u8) ![]u8;
```
Port `bin/pager.c:1116-1252`. Spawn helpers via `std.process.Child` (replaces C `popen`/`system`).

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/queue_clipboard.zig
git commit -m "feat(zig): clipboard text/image/file attachment"
```

---

### Task 13: `queue.zig` — queue model + draft-stash + glue

**Files:**
- Create: `src/queue.zig`
- Reference: `bin/pager.c:720-1080` (queue model, notice, push/clear/clamp, recalc rows, compact key, init path), draft-stash `bin/pager.c:838-867`.

- [ ] **Step 1: Write failing tests (incl. draft-stash — kept feature)**

```zig
const std = @import("std");
test "push and clamp selection" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    try q.push("a"); try q.push("b");
    q.selected = 5; q.clampSelection();
    try std.testing.expectEqual(@as(usize,1), q.selected);
}
test "draft stash and restore" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();
    var ib = @import("input.zig").InputBuf.init();
    ib.setText("half typed");
    q.snapshotDraftIfNeeded(&ib);
    ib.setText("queued item");
    try std.testing.expect(q.restoreDraft(&ib));
    try std.testing.expectEqualStrings("half typed", ib.text());
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

```zig
const InputBuf = @import("input.zig").InputBuf;
pub const Queue = struct {
    items: std.ArrayList(@import("queue_persist.zig").QueueItem),
    selected: usize, scroll_off: usize, edit_index: i64,
    notice: [160]u8, notice_len: usize,
    draft: [QUEUE_INPUT_MAX]u8, draft_len: usize, draft_cursor: usize, draft_saved: bool,
    pub fn init(a: std.mem.Allocator) Queue;
    pub fn deinit(self: *Queue) void;
    pub fn push(self: *Queue, prompt: []const u8) !void;
    pub fn clear(self: *Queue) void;
    pub fn clampSelection(self: *Queue) void;
    pub fn setNotice(self: *Queue, msg: []const u8) void;
    pub fn snapshotDraftIfNeeded(self: *Queue, ib: *InputBuf) void;     // KEEP (not TurboDraft)
    pub fn discardDraft(self: *Queue) void;
    pub fn restoreDraft(self: *Queue, ib: *InputBuf) bool;              // sets notice "draft restored"
    pub fn cycleEdit(self: *Queue, ib: *InputBuf, dir: i32) bool;
};
```
Port from `bin/pager.c:720-1080` + draft-stash `838-867`. Notices stay neutral ("draft restored") — they never said "TurboDraft".

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/queue.zig
git commit -m "feat(zig): queue model with draft-stash"
```

---

### Task 14: `draw.zig` — viewport/frame drawing + link click-map

**Files:**
- Create: `src/draw.zig`
- Reference: `bin/pager.c:4947-5251` (Drawing); `LinkSpan`/`LinkMap` (`bin/pager.c:150-163`).

- [ ] **Step 1: Write failing test (link hit-test is pure)**

```zig
const std = @import("std");
test "link hit-test finds span at coords" {
    var lm = LinkMap.init(std.testing.allocator);
    defer lm.deinit();
    try lm.add(.{ .row = 2, .x0 = 3, .x1 = 10, .uri = "https://x.io" });
    try std.testing.expectEqualStrings("https://x.io", lm.at(2, 5).?);
    try std.testing.expect(lm.at(2, 20) == null);
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

```zig
pub const LinkSpan = struct { row: usize, x0: usize, x1: usize, uri: []const u8 };
pub const LinkMap = struct {
    spans: std.ArrayList(LinkSpan),
    pub fn init(a: std.mem.Allocator) LinkMap;
    pub fn deinit(self: *LinkMap) void;
    pub fn add(self: *LinkMap, s: LinkSpan) !void;
    pub fn at(self: *LinkMap, row: usize, col: usize) ?[]const u8;
};
pub fn drawFrame(ob: *@import("outbuf.zig").OutBuf, st: *@import("pager.zig").State) !void;
```
Port the viewport/frame composition + input box + queue list + status line from `bin/pager.c:4947-5251`, writing into the `OutBuf`. (`State` defined next task; this file imports it — both compile together.)

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/draw.zig
git commit -m "feat(zig): frame drawing and link click-map"
```

---

### Task 15: `pager.zig` — State + runPager loop (NO TurboDraft Ctrl+Q coupling)

**Files:**
- Create: `src/pager.zig`
- Reference: `bin/pager.c:5533-5989` (Main loop). **Remove** the Ctrl+Q→TurboDraft-session behavior and the two notices at `bin/pager.c:5687,5694`; Ctrl+Q simply exits the pager.

- [ ] **Step 1: Write failing test (State init + one decoded key step)**

```zig
const std = @import("std");
test "State init then handle Ctrl+Q requests quit" {
    var st = try State.initForTest(std.testing.allocator, "tests/fixtures/sample0.jsonl", 110);
    defer st.deinit();
    const action = st.handleKey(.{ .ctrl_q = {} });
    try std.testing.expectEqual(Action.quit, action);
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

```zig
pub const Action = enum { none, redraw, quit };
pub const State = struct {
    alloc: std.mem.Allocator,
    lines: []@import("render.zig").Line,
    links: @import("draw.zig").LinkMap,
    queue: @import("queue.zig").Queue,
    input: @import("input.zig").InputBuf,
    win: @import("term.zig").Winsize,
    visible_start: usize, input_mode: bool, ctrl_quit_supported: bool,
    pub fn initForTest(a: std.mem.Allocator, jsonl: []const u8, cols: usize) !State;
    pub fn deinit(self: *State) void;
    pub fn handleKey(self: *State, key: @import("input.zig").Key) Action;
};
pub fn runPager(tty_fd: std.posix.fd_t, transcript: []const u8,
                editor_pid: ?std.posix.pid_t, ctx_limit: usize) !void;
```
Port the loop from `bin/pager.c:5533-5989` (read keys via `term`/`input.decode`, dispatch to scroll/queue/input handlers, redraw via `draw.drawFrame`), **omitting** all `turbodraft.session.close` / control_fd-for-TurboDraft logic and the two removed notices. `runPager` no longer takes a `control_fd` parameter (the only consumer was the TurboDraft path).

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/pager.zig src/draw.zig
git commit -m "feat(zig): pager State and run loop; drop TurboDraft Ctrl+Q coupling"
```

---

### Task 16: `main_cli.zig` — wire `claude-pager-c`

**Files:**
- Modify: `src/main_cli.zig`
- Reference: `bin/pager_cli.c`.

- [ ] **Step 1: Implement**

```zig
const std = @import("std");
const term = @import("term.zig");
const pager = @import("pager.zig");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // argv0
    const transcript = args.next() orelse return error.MissingTranscript;
    var ctx_limit: usize = 200000;
    // optional: parse "--ctx-limit N" like bin/pager_cli.c
    const tty = try term.openTty();
    defer tty.close();
    try pager.runPager(tty.handle, transcript, null, ctx_limit);
}
```

- [ ] **Step 2: Build + manual smoke**

Run: `zig build && zig-out/bin/claude-pager-c tests/fixtures/sample0.jsonl`
Expected: interactive pager renders sample0; scroll works; `q`/Ctrl+Q exits cleanly; terminal restored.

- [ ] **Step 3: Commit**

```bash
git add -f src/main_cli.zig
git commit -m "feat(zig): wire claude-pager-c CLI to runPager"
```

---

### Task 17: `settings.zig` — read editor vars from settings.json

**Files:**
- Create: `src/settings.zig`
- Reference: `bin/claude-pager-open.c:130-234` (`read_settings_env_value`, editor, editor_type, bench_mode).

- [ ] **Step 1: Write failing test**

```zig
const std = @import("std");
test "reads env value from settings json" {
    const json =
        \\{"env":{"CLAUDE_PAGER_EDITOR":"emacsclient","CLAUDE_PAGER_EDITOR_TYPE":"gui"}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try envValue(arena.allocator(), json, "CLAUDE_PAGER_EDITOR");
    try std.testing.expectEqualStrings("emacsclient", v.?);
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

```zig
pub fn envValue(alloc: std.mem.Allocator, settings_json: []const u8, key: []const u8) !?[]u8;
pub fn editor(alloc: std.mem.Allocator, home: []const u8) !?[]u8;        // env.CLAUDE_PAGER_EDITOR
pub fn editorType(alloc: std.mem.Allocator, home: []const u8) !?[]u8;    // env.CLAUDE_PAGER_EDITOR_TYPE
pub fn benchMode(alloc: std.mem.Allocator, home: []const u8) !?[]u8;
```
Use `std.json` parsing of `~/.claude/settings.json` (replaces the hand-rolled brace scanner `bin/claude-pager-open.c:130-234`).

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/settings.zig
git commit -m "feat(zig): read editor settings via std.json"
```

---

### Task 18: `editor.zig` — validation + gui/terminal detection (NO TurboDraft)

**Files:**
- Create: `src/editor.zig`
- Reference: `bin/claude-pager-open.c:598-698` minus `is_turbodraft_editor` (665-673), which is **removed**.

- [ ] **Step 1: Write failing tests**

```zig
const std = @import("std");
test "terminal editor detected" {
    try std.testing.expect(isTerminalEditor("nvim"));
    try std.testing.expect(!isTerminalEditor("emacsclient"));
}
test "basename extraction" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("code", basename("/usr/bin/code -w", &buf));
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement**

```zig
pub fn isSelf(cmd: []const u8) bool;
pub fn editorExists(cmd: []const u8) bool;
pub fn basename(editor: []const u8, buf: []u8) []const u8;
pub fn isKnownGuiEditor(editor: []const u8) bool;
pub fn isTerminalEditor(editor: []const u8) bool;
```
Port `bin/claude-pager-open.c:598-664,674-698`. Do **not** port `is_turbodraft_editor`.

- [ ] **Step 4: Run, verify pass** — `zig build test` PASS.

- [ ] **Step 5: Commit**

```bash
git add -f src/editor.zig
git commit -m "feat(zig): editor validation and detection (no TurboDraft)"
```

---

### Task 19: `open.zig` + `main_open.zig` — launcher (NO socket fast-path)

**Files:**
- Create: `src/open.zig`
- Modify: `src/main_open.zig`
- Reference: `bin/claude-pager-open.c` — transcript find (235-319), pre-render (320-344, 693-723), fork pager (345-368), terminal path (724-738), spawn editor (741-755), generic path (756-829), main (832+). **Remove** socket helpers (54-129), `turbodraft_path` + fast path (369-597), and the fork-pager `control_fd` used only by TurboDraft.

- [ ] **Step 1: Write failing test (transcript finder is pure-ish)**

```zig
const std = @import("std");
test "newestJsonl picks most recent" {
    // create two temp .jsonl with different mtimes in a temp dir, assert newest returned
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ... write a.jsonl then b.jsonl ...
    const got = try newestJsonl(std.testing.allocator, try tmp.dir.realpathAlloc(std.testing.allocator, "."));
    try std.testing.expect(std.mem.endsWith(u8, got.?, ".jsonl"));
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` FAIL.

- [ ] **Step 3: Implement `open.zig`**

```zig
pub fn newestJsonl(alloc: std.mem.Allocator, dir: []const u8) !?[]u8;
pub fn findTranscript(alloc: std.mem.Allocator, home: []const u8) !?[]u8;
pub fn preRender(tty_fd: std.posix.fd_t, transcript: []const u8) void;
pub fn forkPager(transcript: []const u8, ctx_limit: usize) !std.posix.pid_t; // fork+runPager in child
pub fn terminalEditorPath(editor: []const u8, file: []const u8) !u8;         // exec, no pager
pub fn spawnEditor(editor: []const u8, file: []const u8, detach_stdin: bool) !std.posix.pid_t;
pub fn genericEditorPath(alloc: std.mem.Allocator, editor: []const u8, file: []const u8) !u8; // GUI + pager
```
Port the named C sections via `std.posix` (`fork`, `execvpe`, `waitpid`) and `std.fs.selfExePath` (replaces `mach-o/dyld`). `forkPager` calls `pager.runPager` in the child (no `control_fd`).

- [ ] **Step 4: Implement `main_open.zig`**

```zig
const std = @import("std");
const settings = @import("settings.zig");
const editor = @import("editor.zig");
const open = @import("open.zig");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();
    const file = args.next() orelse return error.MissingFile;
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    const ed = (try settings.editor(alloc, home))
        orelse (std.process.getEnvVarOwned(alloc, "VISUAL") catch null)
        orelse (std.process.getEnvVarOwned(alloc, "EDITOR") catch null)
        orelse return error.NoEditor;
    if (editor.isTerminalEditor(ed)) {
        std.process.exit(try open.terminalEditorPath(ed, file));
    } else {
        std.process.exit(try open.genericEditorPath(alloc, ed, file));
    }
}
```

- [ ] **Step 5: Build + manual smoke**

Run: `zig build`
Then set `CLAUDE_PAGER_EDITOR` to a trivial editor and exercise:
`CLAUDE_PAGER_EDITOR='emacsclient' zig-out/bin/claude-pager-open /tmp/testprompt.md`
Expected: pager renders context, editor opens `/tmp/testprompt.md`, on editor exit pager is reaped and process returns 0. No socket/TurboDraft references in `CLAUDE_PAGER_DEBUG` log.

- [ ] **Step 6: Commit**

```bash
git add -f src/open.zig src/main_open.zig
git commit -m "feat(zig): editor launcher without TurboDraft fast-path"
```

---

### Task 20: Port wrap tests + full parity gate green

**Files:**
- Modify: `src/render.zig` (add `test` blocks)
- Reference: `bin/pager_wrap_tests.c`.

- [ ] **Step 1: Port the wrap/placeholder row-accounting cases**

Translate each assertion in `bin/pager_wrap_tests.c` into a `test "wrap: ..."` block in `src/render.zig`, exercising `renderItems` row counts for known inputs.

- [ ] **Step 2: Run full suite**

Run: `zig build test`
Expected: all unit tests + 3 plain-render parity tests + wrap tests PASS.

- [ ] **Step 3: Commit**

```bash
git add -f src/render.zig
git commit -m "test(zig): port wrap/placeholder row-accounting tests"
```

---

### Task 21: Remove C, update tooling/docs, repoint settings

**Files:**
- Delete: `bin/pager.c`, `bin/pager.h`, `bin/pager_cli.c`, `bin/claude-pager-open.c`, `bin/pager_wrap_tests.c`, `bin/Makefile`, `bin/*.o`, built binaries in `bin/`
- Modify: `.gitignore`, `install.sh`, `README.md`, `~/.claude/settings.json`

- [ ] **Step 1: Delete the C sources and build artifacts**

```bash
git rm -f bin/pager.c bin/pager.h bin/pager_cli.c bin/claude-pager-open.c bin/pager_wrap_tests.c bin/Makefile
rm -f bin/*.o bin/claude-pager-open bin/claude-pager-c
rmdir bin 2>/dev/null || true
```

- [ ] **Step 2: Update `.gitignore`**

Remove the C artifact rules (`*.o`, `bin/claude-pager-open`, `bin/claude-pager-c`); keep `zig-out/` and `.zig-cache/`.

- [ ] **Step 3: Update `install.sh`**

Replace `cd bin && make` with `zig build -Doptimize=ReleaseFast`; install from `zig-out/bin/claude-pager-open` and `zig-out/bin/claude-pager-c` to the install dir.

- [ ] **Step 4: Update `README.md`**

Remove the TurboDraft sections (overview bullet "TurboDraft fast path", the "Ctrl-G flow timings (TurboDraft fast path)" section, the SVG alt-text TurboDraft mention). Replace build instructions (`make` → `zig build`). State the editor launch always uses `CLAUDE_PAGER_EDITOR`/`VISUAL`/`EDITOR`.

- [ ] **Step 5: Repoint `~/.claude/settings.json`**

Change `env.EDITOR` from `…/claude-pager/bin/claude-pager-open` to `…/claude-pager/zig-out/bin/claude-pager-open`.

```bash
python3 - <<'EOF'
import json,os
p=os.path.expanduser("~/.claude/settings.json")
d=json.load(open(p))
d["env"]["EDITOR"]="/Users/pavel/Developer/src/clones/claude-pager/zig-out/bin/claude-pager-open"
json.dump(d,open(p,"w"),indent=2); open(p,"a").write("\n")
print("repointed")
EOF
```

- [ ] **Step 6: Final verification**

Run: `zig build -Doptimize=ReleaseFast && zig build test`
Expected: both binaries built; all tests PASS.
Run: `grep -rin turbodraft README.md src/ install.sh || echo "no turbodraft refs"`
Expected: `no turbodraft refs`.

- [ ] **Step 7: Commit**

```bash
git add -A
git add -f install.sh README.md .gitignore
git commit -m "chore: remove C sources; build via Zig; drop TurboDraft from docs/tooling"
```

---

## Self-Review

**Spec coverage:** all spec modules mapped to tasks 2–19; golden gate (spec "Verification") = Tasks 0+9+20; pure-std (spec "Dependencies") honored incl. macOS libSystem note (Tasks 5,17,19); TurboDraft removal (spec) = Tasks 15 (Ctrl+Q), 18 (`is_turbodraft_editor`), 19 (socket fast-path), 21 (README/tooling); draft-stash kept = Task 13; build.zig + zig test (spec) = Tasks 1,20; src/ + delete bin/ (spec layout) = Tasks 1,21; settings repoint = Task 21. No gaps.

**Placeholder scan:** no TBD/“add error handling”/“similar to Task N”. Port-body steps name exact C file+line ranges as the translation source plus golden/unit oracles — concrete, not vague.

**Type consistency:** `Item`/`Transcript`/`parse` (Task 6) reused in 8,9; `Line`/`renderItems` (render.zig) reused in 8,9,15,20; `InputBuf`/`Key` (Task 10) reused in 13,15; `QueueItem` (Task 11) reused in 13; `Queue` (Task 13) used in 15; `State` (Task 15) used by `draw.drawFrame` (Task 14, forward-imported — compiles together); `runPager` signature (no `control_fd`) consistent in 15,16,19. Consistent.
