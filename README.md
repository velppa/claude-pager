# claude-pager

Shows your Claude Code session transcript when you press **Ctrl-G**, instead of a blank terminal, and hands the same context to your editor so you can write your next prompt with the conversation in front of you.

It does this without touching the terminal: the transcript is printed once as static plain text. There is **no interactive pager** — no mouse capture, no scroll hijacking, no clickable-link rewriting — so your terminal's native scrollback and text selection keep working exactly as they do in normal Claude Code.

The runtime is a single compiled Zig binary — no Python, no Node, no runtime dependencies.

## What it does

When you press **Ctrl-G** in Claude Code:

1. `claude-pager-open` (configured as Claude's `editor`) finds your session transcript.
2. It renders the transcript to plain text and exports the path as `CLAUDE_PAGER_RENDER_FILE` so the editor can show it as context.
3. It launches your configured editor.
4. For GUI editors it prints the rendered transcript **once, statically** to the terminal as a read-only summary, then waits for the editor to close.

That's the whole flow. No alternate screen, no input loop, no background process redrawing the terminal.

## Features

- Replaces the blank Ctrl-G terminal with a static, readable transcript summary
- Hands the rendered transcript to your editor via `CLAUDE_PAGER_RENDER_FILE` (single source of truth)
- Markdown rendering: headings, bold, inline code, code blocks, lists
- GFM-style table rendering with bounded row/column budgets
- Diff coloring (+green / -red / @@cyan)
- Leaves native terminal scrollback, mouse selection, and link handling untouched
- First-class Emacs integration (transcript-above-prompt buffer)
- Works with any GUI editor (VS Code, Cursor, Zed, Sublime, etc.) and any TUI editor (vim, nvim, emacs, …)

## Requirements

- macOS (arm64 or x86_64)
- [Zig](https://ziglang.org/) 0.16.0
- `jq` (installed automatically via Homebrew if missing)

## Install

### One-liner

```sh
curl -sSL https://raw.githubusercontent.com/velppa/claude-pager/zig-rewrite/install.sh | bash
```

This clones the repo to `~/.claude-pager`, builds the binary, sets `editor` in `~/.claude/settings.json`, preserves your original editor as `env.CLAUDE_PAGER_EDITOR`, writes `env.CLAUDE_PAGER_EDITOR_TYPE` (`tui`/`gui`), and installs the SessionStart hook used for transcript lookup. No shell config changes needed.

### Build from source

```sh
git clone https://github.com/velppa/claude-pager.git
cd claude-pager
zig build                          # debug build
zig build -Doptimize=ReleaseSmall  # optimized release build (installer default)
zig build test                     # run the test suite
```

This produces `zig-out/bin/claude-pager-open` (zero runtime dependencies).

## Setup

The installer handles everything automatically. If you set it up manually:

### 1. Set the editor in settings.json

Add to `~/.claude/settings.json`:

```json
{
  "editor": "/path/to/claude-pager-open",
  "env": {
    "CLAUDE_PAGER_EDITOR": "code --wait",
    "CLAUDE_PAGER_EDITOR_TYPE": "gui"
  }
}
```

Claude Code spawns `editor` on Ctrl-G. Since `env` values may not be exported to the editor process, claude-pager reads `~/.claude/settings.json` directly for `env.CLAUDE_PAGER_EDITOR` and `env.CLAUDE_PAGER_EDITOR_TYPE`.

### 2. Install the SessionStart hook

claude-pager uses a single Claude hook:

- **SessionStart** → remembers the exact transcript for the current terminal session, so the right transcript is found even when multiple Claude sessions run from the same directory.

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude-pager/shim/save-session-transcript.sh"
          }
        ]
      }
    ]
  }
}
```

Without the SessionStart hook, claude-pager falls back to the most recent transcript in your project directory.

> Claude hook entries must use hook-group objects with a nested `hooks` array. Flat hook objects like `{"type":"command","command":"..."}` directly under `hooks.SessionStart` are invalid in current Claude releases.

## Switching editors

Your editor is stored in `env.CLAUDE_PAGER_EDITOR` in `~/.claude/settings.json`. Change it to switch editors:

```json
{
  "env": {
    "CLAUDE_PAGER_EDITOR": "cursor --wait",
    "CLAUDE_PAGER_EDITOR_TYPE": "gui"
  }
}
```

Common values:

| Editor | Value |
| --- | --- |
| VS Code | `code --wait` |
| Cursor | `cursor --wait` |
| Zed | `zed --wait` |
| Sublime Text | `subl --wait` |
| Vim | `vim` |
| Neovim | `nvim` |
| Emacs | `emacsclient` (see below) |

The resolution order is: `CLAUDE_PAGER_EDITOR` (env or settings.json) → `VISUAL` → `EDITOR` → system default (`open -W -t`).

TUI editors (vim, nvim, emacs, nano, …) take over the terminal, so they are exec'd directly and the static summary is **not** printed (the editor owns the screen; it gets the transcript via `CLAUDE_PAGER_RENDER_FILE` instead). GUI editors run alongside the static summary.

You can force the path with `CLAUDE_PAGER_EDITOR_TYPE=tui` or `CLAUDE_PAGER_EDITOR_TYPE=gui` in the `env` section.

## Emacs Integration

If you run Emacs as a server (`emacsclient`), claude-pager ships a dedicated Emacs prompt editor: the session transcript is shown **read-only** above a separator in an Emacs buffer, and you type your next prompt **below** it. On finish, only the text below the separator is sent back to Claude.

This is a TUI flow — Emacs runs in the same terminal, so there is no static summary print; the transcript lives in the Emacs buffer instead.

The integration is two files under `emacs/`:

| File | Role |
| --- | --- |
| `emacs/claude-emacs-prompt` | Editor shim. Resolves the transcript, arms the Emacs side via `emacsclient -e`, then opens the prompt file with `emacsclient`. |
| `emacs/claude-prompt.el` | Emacs library. Renders the transcript read-only above `claude-prompt-separator`, forces Fundamental mode (no markdown fontification), and on save writes only the body below the separator. |

### Setup

1. Load the library from your Emacs config (`init.el`):

   ```elisp
   (load "~/.claude-pager/emacs/claude-prompt.el" nil t)
   ```

   It hooks `server-switch-hook`, so any prompt file opened by the shim becomes the transcript-above-prompt editor automatically.

2. Point `CLAUDE_PAGER_EDITOR` at the shim in `~/.claude/settings.json`:

   ```json
   {
     "editor": "/path/to/claude-pager-open",
     "env": {
       "CLAUDE_PAGER_EDITOR": "/Users/you/.claude-pager/emacs/claude-emacs-prompt",
       "CLAUDE_PAGER_EDITOR_TYPE": "tui"
     }
   }
   ```

   `CLAUDE_PAGER_EDITOR_TYPE` must be `tui` so claude-pager execs Emacs directly.

3. Make sure an Emacs server is running (`M-x server-start`, or `(server-start)` in your config). The shim talks to it via `emacsclient`; sockets are resolved from `DARWIN_USER_TEMP_DIR` on macOS.

### Usage

Press **Ctrl-G** in Claude Code. Emacs opens the prompt buffer with the transcript above the separator line:

```
=== TRANSCRIPT (read-only) ===

▶ USER
...
◀ ASSISTANT
...

----->8=----- TYPE PROMPT BELOW – text above is read-only context -----
<your prompt goes here>
```

Type below the separator and finish with **`C-c C-c`** (saves the body and returns control to Claude). Everything above the separator is dropped on save, so Claude receives only what you typed.

### Transcript source

The shim prefers the plain-text render produced by `claude-pager-open` (via `CLAUDE_PAGER_RENDER_FILE`), keeping a single source of truth. If that is absent, it falls back to the tty-keyed transcript pointer (`/tmp/claude-transcript-<tty>`) written by the SessionStart hook, and finally to the most recent `.jsonl` in the project directory — which `claude-prompt.el` then renders itself.

## Architecture

```
claude-pager-open (Zig binary)
├── Editor resolution (CLAUDE_PAGER_EDITOR from env/settings.json → VISUAL → EDITOR → system default)
├── TUI detection (known TUI list + optional CLAUDE_PAGER_EDITOR_TYPE override + optimistic unknown-editor probe)
├── Transcript lookup (tty-keyed temp file → PWD-derived project dir → newest jsonl)
├── Transcript parser (minimal JSON scanner, single-pass JSONL)
├── Plain-text renderer (markdown → ANSI → stripped plain text)
├── Editor launch (spawn editor, export CLAUDE_PAGER_RENDER_FILE, wait)
└── Static summary print (rendered transcript written once to /dev/tty for GUI editors)
```

Source layout under `src/`:

- `main_open.zig` / `open.zig` / `editor.zig` — entry point, editor resolution, launch orchestration, static summary print
- `transcript.zig` — JSONL parser
- `render.zig` / `markdown.zig` — markdown-to-ANSI line rendering
- `render_plain.zig` — strips ANSI/OSC to the plain-text summary shared with editors
- `settings.zig`, `term.zig`, `ansi.zig`, `outbuf.zig`, `log.zig` — settings, terminal, escape codes, buffering, debug logging

## Agent Instructions

This section is for AI coding agents (Claude Code, Cursor, Copilot, etc.). Everything here is deterministic — no user input is needed.

### 1. Check prerequisites

```sh
# macOS required; ensure Zig 0.16.0 is available
command -v zig >/dev/null 2>&1 || { echo "install Zig 0.16.0 from https://ziglang.org/"; exit 1; }
# jq required for settings.json manipulation
command -v jq >/dev/null 2>&1 || brew install jq
```

### 2. Clone and build

```sh
git clone https://github.com/velppa/claude-pager.git ~/.claude-pager
( cd ~/.claude-pager && zig build -Doptimize=ReleaseSmall )
test -x ~/.claude-pager/zig-out/bin/claude-pager-open
```

### 3. Configure settings.json

Read `~/.claude/settings.json` (create with `{}` if missing). Use `jq` to:

1. Save the current `editor` value as `env.CLAUDE_PAGER_EDITOR` (if it exists and isn't already claude-pager)
2. Set `editor` to the binary path
3. Infer `env.CLAUDE_PAGER_EDITOR_TYPE` (`tui` or `gui`)
4. Add the SessionStart hook

Important: Claude hooks must use wrapped hook-group objects with nested `hooks` arrays. Do not write legacy flat command objects directly under `hooks.SessionStart`.

```sh
BINARY="$HOME/.claude-pager/bin/claude-pager-open"
HOOK_SESSION="$HOME/.claude-pager/shim/save-session-transcript.sh"
SETTINGS="$HOME/.claude/settings.json"

mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

# Preserve old editor
OLD=$(jq -r '.editor // empty' "$SETTINGS")
if [[ -n "$OLD" && "$OLD" != *"claude-pager"* ]]; then
    jq --arg ed "$OLD" '.env.CLAUDE_PAGER_EDITOR = $ed' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

# If no editor was preserved and none detected, find one
if [[ -z "$(jq -r '.env.CLAUDE_PAGER_EDITOR // empty' "$SETTINGS")" ]]; then
    for cmd in cursor code zed subl; do
        if command -v "$cmd" &>/dev/null; then
            jq --arg ed "$cmd --wait" '.env.CLAUDE_PAGER_EDITOR = $ed' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
            break
        fi
    done
fi

# Set editor to claude-pager-open
jq --arg bin "$BINARY" '.editor = $bin' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

# Infer editor type
tok="$(jq -r '.env.CLAUDE_PAGER_EDITOR // empty' "$SETTINGS" | awk '{print $1}' | xargs basename 2>/dev/null || true)"
case "$tok" in
  vi|vim|nvim|lvim|nvi|vim.basic|vim.tiny|vim.nox|vim.gtk|vim.gtk3|emacs|nano|micro|helix|hx|kakoune|kak|joe|ed|ne|mg|jed|tilde|dte|mcedit|amp) ty="tui" ;;
  *) ty="gui" ;;
esac
if [[ -n "$tok" ]]; then
  jq --arg ty "$ty" '.env.CLAUDE_PAGER_EDITOR_TYPE = $ty' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

# Normalize legacy flat hook objects into Claude's current matcher+hooks schema
jq '
  def normalize_event_array:
    if type == "array" then
      map(
        if (type == "object" and (.hooks? | type) == "array") then
          .
        elif (type == "object" and .type == "command" and (.command? | type) == "string") then
          {hooks: [(if has("timeout") then {type, command, timeout} else {type, command} end)]}
        else
          .
        end
      )
    else
      []
    end;
  .hooks = (if (.hooks | type) == "object" then .hooks else {} end) |
  .hooks.SessionStart = ((.hooks.SessionStart // []) | normalize_event_array)
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

# Add SessionStart hook (if not already present)
if ! jq -e --arg cmd "$HOOK_SESSION" '.hooks.SessionStart[]?.hooks[]? | select(.command == $cmd)' "$SETTINGS" &>/dev/null; then
    jq --arg cmd "$HOOK_SESSION" '
        .hooks.SessionStart = ((.hooks.SessionStart // []) + [{
            "hooks": [ { "type": "command", "command": $cmd } ]
        }])
    ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

# Validate final hook shape
jq -e --arg session_cmd "$HOOK_SESSION" '
  (.hooks.SessionStart | type) == "array" and
  any(.hooks.SessionStart[]?; (.hooks | type) == "array") and
  any(.hooks.SessionStart[]?.hooks[]?; (.type == "command") and (.command == $session_cmd))
' "$SETTINGS" >/dev/null
```

### 4. Done

Tell the user to restart Claude Code and press **Ctrl-G**. The transcript summary prints in the terminal and the editor opens with the same context.

### Agent notes

- Editor resolution: `CLAUDE_PAGER_EDITOR` (env or settings.json) → `VISUAL` → `EDITOR` → `open -W -t` (macOS default)
- `CLAUDE_PAGER_EDITOR_TYPE` is also read from env or settings.json (`tui`/`gui` override)
- The SessionStart hook enables multi-session transcript lookup; without it claude-pager falls back to the most recent transcript in the project directory
- There is no Stop hook — the prompt queue was removed. If an older install left a `queue-drain-stop.sh` Stop hook, remove it from `~/.claude/settings.json` manually.
- No shell config changes (VISUAL/EDITOR) are needed — settings.json is the canonical configuration path

## License

MIT
