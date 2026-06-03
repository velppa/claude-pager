# claude-pager: C → Zig rewrite + TurboDraft removal

Date: 2026-06-03
Status: Approved design

## Goal

Rewrite the claude-pager C codebase (~7k LOC across two binaries) in Zig, and
remove the external "TurboDraft" fast-path integration. Result: a clean,
single-language (Zig, pure `std`, no libc link) repo that builds the same two
executables with equivalent behavior.

## Decisions (locked)

- **Fidelity:** refactor freely — match runtime behavior and TUI/plain-render
  output, but restructure the 6k-line `pager.c` monolith into focused modules.
  Globals become explicit state passed through a context struct.
- **Dependencies:** Zig `std` abstractions only — no `@cImport` of C headers,
  no third-party packages. `std.posix` for termios/ioctl/fork/exec, `std.json`
  for JSON, `std.fs.selfExePath` to replace the macOS `mach-o/dyld` self-path
  lookup. Note: on macOS `std.posix` necessarily routes through libSystem
  (Apple exposes no stable raw syscall ABI), so libc is linked by default. That
  is expected and distinct from hand-importing C headers; `ioctl(TIOCGWINSZ)`
  uses `std.c.ioctl` accordingly.
- **Build/tests:** `build.zig` + `build.zig.zon` replace the `Makefile`;
  `pager_wrap_tests.c` becomes inline `test {}` blocks run by `zig build test`.
- **Layout:** new `src/` tree; the C sources (`bin/*.c`, `bin/*.h`, `Makefile`)
  are deleted in the same effort. C remains recoverable from git history.
- **TurboDraft removal scope:** remove the external-app Unix-socket fast path and
  the Ctrl+Q→session coupling. Keep the in-pager draft-stash queue feature.

## What "TurboDraft" means here

Two distinct things share the "draft" name; only one is removed.

1. **External TurboDraft.app fast path (REMOVE).** `claude-pager-open.c` detects a
   Unix socket at `~/Library/Application Support/TurboDraft/turbodraft.sock` and
   speaks JSON-RPC (`turbodraft.session.open` / `.wait` / `.close`,
   `kTurboDraftProtocolVersion`) for sub-100ms editor launch. Ctrl+Q inside the
   pager signals `claude-pager-open` to send `session.close`, surfaced by two
   notices ("closing TurboDraft session", "tip: Ctrl+Q closes a TurboDraft
   session"). All of this is removed.

2. **In-pager draft-stash (KEEP).** `g_input_draft*` in `pager.c`. When the user
   has half-typed a new prompt and starts cycling through queued prompts to edit
   them, the typed text is snapshotted (`input_snapshot_draft_if_needed`) and
   restored (`input_restore_draft`) when cycling back out ("draft restored").
   This is a generic prompt-queue convenience with no dependency on the external
   app. It is retained; its notices never mention TurboDraft, so wording is
   unchanged.

After removal, `claude-pager-open` always uses the
`CLAUDE_PAGER_EDITOR` / `VISUAL` / `EDITOR` fallback path (the generic GUI-editor
+ pager flow, and the terminal-editor direct-exec flow).

## Architecture

Two executables sharing one module set:

- `claude-pager-open` — editor shim Claude Code invokes as `$EDITOR`. Reads the
  configured editor from settings, finds the transcript, pre-renders it, forks
  the pager, launches the editor, waits.
- `claude-pager-c` — standalone interactive pager CLI over a `.jsonl` transcript.

### Module map (`src/`)

| Module | Responsibility | Replaces (C section) |
|---|---|---|
| `main_open.zig` | entry for `claude-pager-open` | `claude-pager-open.c` `main` |
| `main_cli.zig` | entry for `claude-pager-c` | `pager_cli.c` |
| `ansi.zig` | SGR color/style constants; ANSI-aware visible length | ANSI, visible-length |
| `term.zig` | raw mode, `TIOCGWINSZ` winsize, `/dev/tty` open | Terminal |
| `outbuf.zig` | output buffering (thin over `std.ArrayList(u8)`/writer) | Output buffer |
| `transcript.zig` | item model + parser via `std.json` | Transcript items + parser, JSON scanner |
| `links.zig` | OSC-8 hyperlink linkification | OSC-8 linkification |
| `markdown.zig` | inline (`**bold**`, `` `code` ``) + block (tables) render | Inline markdown, Markdown renderer |
| `render.zig` | transcript item → styled lines | Item renderer |
| `render_plain.zig` | styled lines → plain text (trailing-ws trim) | Plain-text render |
| `draw.zig` | viewport / frame drawing | Drawing |
| `input.zig` | key decode + line editing | Input |
| `queue.zig` | prompt queue + draft-stash (snapshot/restore/discard) | Prompt queue |
| `pager.zig` | `run_pager` interactive loop; owns the `State` struct | Main loop, Globals |
| `settings.zig` | read editor env vars from `settings.json` via `std.json` | Read settings.json |
| `editor.zig` | editor-command validation, terminal-editor detection, self-ref | Editor validation/detection, self-reference |
| `open.zig` | fork pager child; generic + terminal editor launch paths | Fork pager, editor paths, pre-render |
| `log.zig` | debug logging | Debug logging |

**Removed (no Zig equivalent):** socket helpers, `turbodraft_path`,
`turbodraft.session.*`, `kTurboDraftProtocolVersion`, Ctrl+Q session.close
coupling, the two TurboDraft notices.

### State management

`pager.c` uses ~30 file-scope globals (`g_*`). In Zig these become fields of a
`State` struct owned by `pager.zig` and passed by pointer to `input`, `draw`,
`queue`, `render`. No mutable global state except process-level concerns
(debug log handle, signal flags) which live in `log.zig` / `term.zig`.

## Data flow

1. Claude Code execs `claude-pager-open <promptfile>` as `$EDITOR`.
2. `settings.zig` resolves the real editor; `transcript.zig` finds the latest
   `.jsonl`; `render`/`render_plain` pre-render context to a temp file.
3. `open.zig` forks the pager (`pager.zig`) and launches the editor; on editor
   exit it reaps the pager and returns.
4. `claude-pager-c` path: `main_cli.zig` → `pager.zig` `run_pager` directly.

## Error handling

- Zig error unions throughout; no silent `errno` swallowing. The launcher
  degrades gracefully (missing transcript, unreadable settings) exactly as the C
  does — failures fall back rather than abort.
- Terminal raw mode restored via `defer` (replaces C atexit/manual restore).
- Allocator: `std.heap.GeneralPurposeAllocator` (debug) / arena for per-render
  scratch; OOM surfaces as a Zig error rather than the C `g_oom` flag.

## Testing & parity gate

1. **Golden fixtures first.** Before deleting the C, build it and capture
   `pager_render_plain` output for a set of sample `.jsonl` transcripts into
   `tests/fixtures/`. These are the parity reference.
2. **Plain-render parity:** `zig build test` asserts the Zig `render_plain`
   output is byte-identical to each golden fixture (including the trailing-ws
   trim already shipped in C).
3. **Unit tests:** port `pager_wrap_tests.c` (wrap/placeholder row accounting)
   to inline `test {}` blocks; add tests for `ansi` visible-length, `links`
   OSC-8, `markdown` tables, `queue` draft-stash.
4. **Interactive:** manual smoke of the TUI (scroll, queue cycle/edit/remove,
   draft stash/restore, Ctrl+Q now just closes the pager).

## Integration touchpoints

- `~/.claude/settings.json` `env.EDITOR` currently points at
  `bin/claude-pager-open`. Repoint to the Zig output path
  (`zig-out/bin/claude-pager-open`).
- `shim/` and `emacs/` are unchanged (they only invoke the binaries / scripts).
- `README.md`: remove TurboDraft sections and the TurboDraft Ctrl-G timing
  claims; update build instructions (`zig build` instead of `make`).
- `install.sh`: update to build via `zig build` and install from `zig-out/bin`.
- `.gitignore`: replace C build artifacts (`*.o`, built binaries under `bin/`)
  with `zig-out/` and `.zig-cache/`.

## Out of scope

- No new pager features. No change to the rendered TUI appearance.
- No change to `shim/` or `emacs/` behavior.
- Windows support (codebase is macOS/POSIX; remains so).

## Sequencing (for the implementation plan)

1. Capture golden fixtures from the current C build.
2. Scaffold `build.zig`, `build.zig.zon`, `src/` skeleton, two empty exes.
3. Leaf modules: `ansi`, `links`, `term`, `outbuf`, `log` (+ tests).
4. `transcript` (std.json parser) + `markdown` + `render` + `render_plain`;
   pass plain-render parity gate.
5. Interactive: `input`, `queue` (draft-stash), `draw`, `pager` `run_pager`.
6. Launcher: `settings`, `editor`, `open`, `main_open`, `main_cli` — **without**
   any TurboDraft socket code.
7. Delete `bin/` C, `Makefile`; update `.gitignore`, `install.sh`, `README.md`,
   and repoint `settings.json`.
8. Full `zig build test` green + manual TUI smoke.
