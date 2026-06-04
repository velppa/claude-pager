# claude-pager

A scrollable terminal pager for Claude Code session transcripts. Press **Ctrl-G** in Claude Code and your conversation history renders in the terminal while your GUI editor is open.

claude-pager solves two major Ctrl-G pain points:

- Claude Code’s TUI going blank while an external GUI editor is open
- Broken Cmd-click behavior on long wrapped links in terminal output

It does this with a native pager + OSC-8 hyperlinks, so wrapped URLs and file paths stay clickable.

The runtime is a single compiled Zig binary — no Python, no Node, no runtime dependencies.

## Before vs After: clickable links and file paths

<table>
  <tr>
    <td align="center"><strong>Before</strong></td>
    <td align="center"><strong>After (claude-pager)</strong></td>
  </tr>
  <tr>
    <td><img src="assets/readme/osc8-before.png" alt="Before: raw, hard-to-click links and file paths in terminal output" width="460"></td>
    <td><img src="assets/readme/osc8-after.png" alt="After: shortened clickable OSC-8 links and file paths in claude-pager" width="460"></td>
  </tr>
</table>

<sub>claude-pager shortens and wraps links and file paths into clickable OSC-8 hyperlinks, and keeps mouse scrolling just like regular Claude Code session context.</sub>

## What's New in v2

<img src="assets/readme/v2-overview.svg" alt="claude-pager v2 overview with transcript rendering, built-in prompt composer, queue editing, and clickable links" width="100%">

- **Built-in queued prompt composer** right inside the pager, so Ctrl-G no longer means read-only transcript context
- **Multiline prompt drafting** with **Shift+Enter**, plus queue cycle/edit/remove controls
- **Clipboard + drag/drop attachments** that turn pasted files and images into `@/absolute/path` references
- **Interactive terminal ergonomics**: scroll wheel browsing, click/Cmd-click links, and Shift-drag text selection

## Install (quick start)

### One-liner

```sh
curl -sSL https://raw.githubusercontent.com/gradigit/claude-pager/main/install.sh | bash
```

This clones the repo to `~/.claude-pager`, builds the binary, sets the `editor` in `~/.claude/settings.json`, preserves your original editor as `env.CLAUDE_PAGER_EDITOR`, writes `env.CLAUDE_PAGER_EDITOR_TYPE` (`tui`/`gui`), and installs the required Claude hooks for transcript lookup + queued prompt draining. No shell config changes needed.

### AI agent install

Paste the repo URL into Claude Code or any AI coding agent. The [agent instructions](#agent-instructions) below have everything it needs to install and configure claude-pager automatically.

Important: Claude hook entries must use hook-group objects with a nested `hooks` array. Flat hook objects like `{"type":"command","command":"..."}` directly under `hooks.SessionStart` or `hooks.Stop` are invalid in current Claude releases.

### Prebuilt binaries

If you don't want to compile locally, download the latest release assets from the GitHub releases page:

- `claude-pager-<version>-macos-arm64.tar.gz` (Apple Silicon)
- `claude-pager-<version>-macos-x86_64.tar.gz` (Intel)
- `checksums.txt`

Then verify:

```sh
shasum -a 256 -c checksums.txt
```

Extract the archive and use `zig-out/bin/claude-pager-open` as your Claude Code editor path.

## ⚡ Performance

claude-pager is tuned for low-latency Ctrl-G flow, with instrumented timings from a production benchmark run (52 cycles total, 2 warmup excluded, 50 measured).

### claude-pager internal rendering timings

| Component | Median |
| --- | ---: |
| Claude Code exec overhead | **6.3ms** |
| claude-pager first draw | **2.7ms** |
| Terminal-ready probe | **0.04ms** |

claude-pager itself is extremely fast; most remaining end-to-end latency is outside claude-pager (external editor + window rendering path).

## Features

- Keeps your terminal transcript visible while GUI editors are open (no blank Ctrl-G screen)
- Scrollable viewport with mouse wheel and keyboard navigation
- Markdown rendering: headings, bold, inline code, code blocks, lists
- GFM-style table rendering with bounded row/column budgets for predictable performance
- Diff coloring (+green / -red / @@cyan)
- Context usage bar showing token consumption
- OSC-8 hyperlink rendering so long wrapped links remain easy to open
- OSC-8 file/path hyperlink rendering so local paths are easy to open
- Boxed multiline prompt composer is active by default while browsing transcript
- Composer auto-wraps and expands vertically for longer prompts
- File/image path references auto-prepended as `@/absolute/path` when pasted into queue input
- `Ctrl+V` in queue input can attach clipboard files (Finder copy) and clipboard images as `@` references
- Drag-and-drop file paths into queue input are accepted as `@` references
- Terminal resize support (SIGWINCH)
- Works with any GUI editor (VS Code, Cursor, Zed, Sublime, etc.)
- Queue draining is handled by the shipped Claude Stop hook so queued prompts continue automatically

## Requirements

- macOS (arm64 or x86_64)
- [Zig](https://ziglang.org/) 0.16.0
- `jq` (installed automatically via Homebrew if missing)

## Build from source (manual)

```sh
git clone https://github.com/gradigit/claude-pager.git
cd claude-pager
zig build                          # debug build
zig build -Doptimize=ReleaseFast   # optimized release build
```

This produces `zig-out/bin/claude-pager-open` and `zig-out/bin/claude-pager-c` (zero runtime dependencies). The editor launch always uses `CLAUDE_PAGER_EDITOR` / `VISUAL` / `EDITOR`.

## Setup

The installer handles everything automatically. If you installed manually:

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

Claude Code sets `editor` as the binary it spawns on Ctrl-G. Since `env` values may not be exported to the editor process, claude-pager reads `~/.claude/settings.json` directly for `env.CLAUDE_PAGER_EDITOR` and `env.CLAUDE_PAGER_EDITOR_TYPE`.

### 2. Install the required hooks

claude-pager uses two Claude hooks:

- **SessionStart** → remembers the exact transcript for the current terminal session
- **Stop** → drains the next queued prompt from the session queue so prompt queuing continues automatically

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
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude-pager/shim/queue-drain-stop.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

Without the SessionStart hook, the pager falls back to the most recent transcript in your project directory. Without the Stop hook, the queued prompt composer UI still appears, but queued prompts will not auto-drain back into Claude after the current response completes.

## Switching Editors

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

The resolution order is: `CLAUDE_PAGER_EDITOR` (env or settings.json) → `VISUAL` → `EDITOR` → system default (`open -W -t`).

TUI editors (vim, nvim, emacs, nano, etc.) are exec'd directly without the pager. GUI editors are forked with the pager running alongside.

You can force the path with `CLAUDE_PAGER_EDITOR_TYPE=tui` or `CLAUDE_PAGER_EDITOR_TYPE=gui` in the `env` section (read from env or settings.json).

## Key Bindings

| Key | Action |
| --- | --- |
| Scroll wheel | Scroll up/down |
| Click / Cmd-click | Open hovered OSC-8 link or file path |
| Shift-drag | Select transcript text while mouse interactions stay enabled |
| Arrow keys (in composer) | Move caret and edit wrapped prompt text |
| Page Up/Down | Scroll one page |
| Home / End (in composer) | Jump caret to start / end |
| Shift+Up / Shift+Down | Cycle queued prompts and load selected one for editing |
| Shift+Enter (in composer) | Insert a newline into the queued prompt |
| Ctrl+D (in input mode) | Remove selected queued prompt |
| Ctrl+V (in input mode) | Attach clipboard file/image as `@/absolute/path` reference |
| Enter (in input mode) | Queue prompt or update the selected queued prompt |
| Esc (in input mode) | Restore stashed draft or clear current input text |
| Mouse / Page Up / Page Down | Browse transcript while input stays active |
| Ctrl+Q | Quit the pager and return to Claude Code |

## How It Works

When you press Ctrl-G in Claude Code:

1. Claude Code opens an alt screen and spawns the editor shim
2. The binary finds your session transcript via a tty-keyed temp file (~0.1ms)
3. It launches your configured editor via `CLAUDE_PAGER_EDITOR` / `VISUAL` / `EDITOR`
4. It forks and renders the pager (~3ms for pre-render, ~5ms for full transcript)
5. Your editor opens the file — the pager is already visible
6. Queued prompts are persisted to a session-scoped queue file while you work in the pager composer
7. The shipped Claude Stop hook drains queued prompts back into Claude after each response completes
8. On `Ctrl+Q`: the pager quits cleanly and returns control to Claude Code
9. On editor close: the binary kills the pager and returns control to Claude Code

The pager keeps mouse interactions enabled for scroll-wheel browsing, link activation, and Shift-drag text selection.

## Architecture

```
claude-pager-open (Zig binary)
├── Editor resolution (CLAUDE_PAGER_EDITOR from env/settings.json → VISUAL → EDITOR → system default)
├── TUI detection (known TUI list + optional CLAUDE_PAGER_EDITOR_TYPE override + optimistic unknown-editor probe)
├── Editor launch path (fork editor + fork pager + waitpid)
├── Transcript parser (minimal JSON scanner, single-pass JSONL)
├── Markdown renderer (ANSI escape codes)
├── Scrollable viewport (raw terminal mode, keyboard/mouse input)
└── Recursion guard (_CLAUDE_PAGER_ACTIVE env var)
```

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
git clone https://github.com/gradigit/claude-pager.git ~/.claude-pager
( cd ~/.claude-pager && zig build -Doptimize=ReleaseFast )
# verify binary exists
test -x ~/.claude-pager/zig-out/bin/claude-pager-open
```

### 3. Configure settings.json

Read `~/.claude/settings.json` (create with `{}` if missing). Use `jq` to:

1. Save the current `editor` value as `env.CLAUDE_PAGER_EDITOR` (if it exists and isn't already claude-pager)
2. Set `editor` to the binary path
3. Infer `env.CLAUDE_PAGER_EDITOR_TYPE` (`tui` or `gui`)
4. Add the SessionStart + Stop hooks

Important: Claude hooks must use wrapped hook-group objects with nested `hooks` arrays. Do not write legacy flat command objects directly under `hooks.SessionStart` or `hooks.Stop`.

```sh
BINARY="$HOME/.claude-pager/bin/claude-pager-open"
HOOK_SESSION="$HOME/.claude-pager/shim/save-session-transcript.sh"
STOP_HOOK="$HOME/.claude-pager/shim/queue-drain-stop.sh"
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
          {hooks: [(
            if has("timeout") then
              {type, command, timeout}
            else
              {type, command}
            end
          )]}
        else
          .
        end
      )
    else
      []
    end;
  .hooks = (if (.hooks | type) == "object" then .hooks else {} end) |
  .hooks.SessionStart = ((.hooks.SessionStart // []) | normalize_event_array) |
  .hooks.Stop = ((.hooks.Stop // []) | normalize_event_array)
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

# Add SessionStart hook (if not already present)
if ! jq -e --arg cmd "$HOOK_SESSION" '.hooks.SessionStart[]?.hooks[]? | select(.command == $cmd)' "$SETTINGS" &>/dev/null; then
    jq --arg cmd "$HOOK_SESSION" '
        .hooks.SessionStart = ((.hooks.SessionStart // []) + [{
            "hooks": [
                {
                    "type": "command",
                    "command": $cmd
                }
            ]
        }])
    ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

# Add Stop hook (if not already present)
if ! jq -e --arg cmd "$STOP_HOOK" '.hooks.Stop[]?.hooks[]? | select(.command == $cmd)' "$SETTINGS" &>/dev/null; then
    jq --arg cmd "$STOP_HOOK" '
        .hooks.Stop = ((.hooks.Stop // []) + [{
            "hooks": [
                {
                    "type": "command",
                    "command": $cmd,
                    "timeout": 10
                }
            ]
        }])
    ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

# Validate final hook shape
jq -e --arg session_cmd "$HOOK_SESSION" --arg stop_cmd "$STOP_HOOK" '
  (.hooks.SessionStart | type) == "array" and
  any(.hooks.SessionStart[]?; (.hooks | type) == "array") and
  any(.hooks.SessionStart[]?.hooks[]?; (.type == "command") and (.command == $session_cmd)) and
  (.hooks.Stop | type) == "array" and
  any(.hooks.Stop[]?; (.hooks | type) == "array") and
  any(.hooks.Stop[]?.hooks[]?; (.type == "command") and (.command == $stop_cmd) and ((.timeout // 10) == 10))
' "$SETTINGS" >/dev/null
```

### 4. Done

Tell the user to restart Claude Code and press **Ctrl-G**. The pager will render their conversation transcript while the editor is open.

### Agent notes

- Editor resolution: `CLAUDE_PAGER_EDITOR` (env or settings.json) → `VISUAL` → `EDITOR` → `open -W -t` (macOS default)
- `CLAUDE_PAGER_EDITOR_TYPE` is also read from env or settings.json (`tui`/`gui` override)
- The SessionStart hook enables multi-session transcript lookup; without it the pager falls back to the most recent transcript in the project directory
- The Stop hook drains queued prompts from the session queue back into Claude after each completed response
- `_CLAUDE_PAGER_ACTIVE` env var is set internally to prevent recursion — agents do not need to set this
- No shell config changes (VISUAL/EDITOR) are needed — settings.json is the canonical configuration path

## Development

```sh
git clone https://github.com/gradigit/claude-pager.git
cd claude-pager
zig build                          # builds claude-pager-open + claude-pager-c
zig build -Doptimize=ReleaseFast   # optimized release build
zig build test                     # runs the test suite
```

Builds produce `zig-out/bin/claude-pager-open` and `zig-out/bin/claude-pager-c`.

The Zig source lives in `src/`: `src/main_open.zig` / `src/open.zig` / `src/editor.zig` handle editor resolution and fork/launch orchestration, while `src/pager.zig`, `src/render.zig`, `src/render_plain.zig`, `src/draw.zig`, and `src/markdown.zig` handle transcript parsing and rendering.

## License

MIT
