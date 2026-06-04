#!/usr/bin/env bash
# claude-pager installer — run with:
#   curl -sSL https://raw.githubusercontent.com/velppa/claude-pager/zig-rewrite/install.sh | bash
set -euo pipefail

REPO="https://github.com/velppa/claude-pager.git"
REPO_BRANCH="zig-rewrite"
INSTALL_DIR="${HOME}/.claude-pager"
BINARY="${INSTALL_DIR}/bin/claude-pager-open"
SETTINGS="${HOME}/.claude/settings.json"
HOOK_SESSION="${INSTALL_DIR}/shim/save-session-transcript.sh"

infer_editor_type() {
    local cmd="$1"
    local tok="${cmd%% *}"
    tok="${tok##*/}"
    case "$tok" in
        vi|vim|nvim|lvim|nvi|vim.basic|vim.tiny|vim.nox|vim.gtk|vim.gtk3|\
        emacs|nano|micro|helix|hx|kakoune|kak|joe|ed|ne|mg|jed|tilde|dte|mcedit|amp)
            echo "tui"
            ;;
        *)
            echo "gui"
            ;;
    esac
}

apply_jq() {
    local argc=$#
    local filter="${!argc}"
    local jq_args=()
    if (( argc > 1 )); then
        jq_args=("${@:1:argc-1}")
    fi
    local tmp
    tmp=$(mktemp)
    if (( ${#jq_args[@]} > 0 )); then
        jq "${jq_args[@]}" "$filter" "$SETTINGS" > "$tmp"
    else
        jq "$filter" "$SETTINGS" > "$tmp"
    fi
    mv "$tmp" "$SETTINGS"
}

normalize_hook_events() {
    apply_jq '
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
        .hooks.SessionStart = ((.hooks.SessionStart // []) | normalize_event_array)
    '
}

echo "Installing claude-pager..."

# ── Clone or update ──────────────────────────────────────────────────────────
if [[ -d "$INSTALL_DIR" ]]; then
    echo "Updating existing install..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    git clone --branch "$REPO_BRANCH" "$REPO" "$INSTALL_DIR"
fi

# ── Build ────────────────────────────────────────────────────────────────────
echo "Building..."
( cd "$INSTALL_DIR" && zig build -Doptimize=ReleaseSmall )

BUILD_OPEN="${INSTALL_DIR}/zig-out/bin/claude-pager-open"

if [[ ! -x "$BUILD_OPEN" ]]; then
    echo "ERROR: build failed — expected binary not found in ${INSTALL_DIR}/zig-out/bin" >&2
    exit 1
fi

# Install built binary into ${INSTALL_DIR}/bin
mkdir -p "${INSTALL_DIR}/bin"
install -m 0755 "$BUILD_OPEN" "$BINARY"

# Strip the local symbol table that ReleaseSmall leaves behind (~10% smaller).
strip "$BINARY" 2>/dev/null || true

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: install failed — $BINARY not found" >&2
    exit 1
fi
echo "Built: $BINARY"

# ── Ensure jq is available ───────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    echo "jq not found — installing via Homebrew..."
    if command -v brew &>/dev/null; then
        brew install jq
    else
        echo "ERROR: jq is required but not installed, and Homebrew is not available." >&2
        echo "  Install jq manually: https://jqlang.github.io/jq/download/" >&2
        exit 1
    fi
fi

# ── Configure settings.json ─────────────────────────────────────────────────
mkdir -p "$(dirname "$SETTINGS")"

if [[ ! -f "$SETTINGS" ]]; then
    echo "{}" > "$SETTINGS"
fi

# Read current editor value (if any)
OLD_EDITOR=$(jq -r '.editor // empty' "$SETTINGS")

# Save old editor as env.CLAUDE_PAGER_EDITOR (if it's not already our binary)
if [[ -n "$OLD_EDITOR" && "$OLD_EDITOR" != "$BINARY" && "$OLD_EDITOR" != *"claude-pager"* ]]; then
    echo "Preserving previous editor: $OLD_EDITOR"
    SETTINGS_TMP=$(mktemp)
    jq --arg ed "$OLD_EDITOR" '.env.CLAUDE_PAGER_EDITOR = $ed' "$SETTINGS" > "$SETTINGS_TMP"
    mv "$SETTINGS_TMP" "$SETTINGS"
else
    # Check if CLAUDE_PAGER_EDITOR is already set
    EXISTING_CPE=$(jq -r '.env.CLAUDE_PAGER_EDITOR // empty' "$SETTINGS")
    if [[ -z "$EXISTING_CPE" ]]; then
        # No old editor and no CLAUDE_PAGER_EDITOR — try to detect an IDE
        DETECTED=""
        for candidate in cursor code zed subl; do
            if command -v "$candidate" &>/dev/null; then
                case "$candidate" in
                    cursor) DETECTED="cursor --wait" ;;
                    code)   DETECTED="code --wait" ;;
                    zed)    DETECTED="zed --wait" ;;
                    subl)   DETECTED="subl --wait" ;;
                esac
                break
            fi
        done

        if [[ -n "$DETECTED" ]]; then
            echo "Detected editor: $DETECTED"
            SETTINGS_TMP=$(mktemp)
            jq --arg ed "$DETECTED" '.env.CLAUDE_PAGER_EDITOR = $ed' "$SETTINGS" > "$SETTINGS_TMP"
            mv "$SETTINGS_TMP" "$SETTINGS"
        else
            # Nothing detected — prompt the user
            echo ""
            echo "No GUI editor detected. Which editor should claude-pager open files in?"
            echo ""
            echo "  1) code --wait      (VS Code)"
            echo "  2) cursor --wait    (Cursor)"
            echo "  3) zed --wait       (Zed)"
            echo "  4) subl --wait      (Sublime Text)"
            echo "  5) vim              (terminal)"
            echo "  6) nvim             (terminal)"
            echo "  7) other"
            echo ""
            read -rp "Choice [1-7]: " choice
            case "$choice" in
                1) DETECTED="code --wait" ;;
                2) DETECTED="cursor --wait" ;;
                3) DETECTED="zed --wait" ;;
                4) DETECTED="subl --wait" ;;
                5) DETECTED="vim" ;;
                6) DETECTED="nvim" ;;
                7)
                    read -rp "Enter editor command: " DETECTED
                    ;;
                *)
                    echo "No editor selected — you can set it later in ~/.claude/settings.json"
                    DETECTED=""
                    ;;
            esac

            if [[ -n "$DETECTED" ]]; then
                SETTINGS_TMP=$(mktemp)
                jq --arg ed "$DETECTED" '.env.CLAUDE_PAGER_EDITOR = $ed' "$SETTINGS" > "$SETTINGS_TMP"
                mv "$SETTINGS_TMP" "$SETTINGS"
                echo "Set editor: $DETECTED"
            fi
        fi
    else
        echo "Editor already configured: $EXISTING_CPE"
    fi
fi

# Set editor to claude-pager-open binary
SETTINGS_TMP=$(mktemp)
jq --arg bin "$BINARY" '.editor = $bin' "$SETTINGS" > "$SETTINGS_TMP"
mv "$SETTINGS_TMP" "$SETTINGS"
echo "Set editor in settings.json: $BINARY"

# Infer editor type from configured CLAUDE_PAGER_EDITOR and persist it
FINAL_EDITOR=$(jq -r '.env.CLAUDE_PAGER_EDITOR // empty' "$SETTINGS")
if [[ -n "$FINAL_EDITOR" ]]; then
    FINAL_EDITOR_TYPE=$(infer_editor_type "$FINAL_EDITOR")
    SETTINGS_TMP=$(mktemp)
    jq --arg ty "$FINAL_EDITOR_TYPE" '.env.CLAUDE_PAGER_EDITOR_TYPE = $ty' "$SETTINGS" > "$SETTINGS_TMP"
    mv "$SETTINGS_TMP" "$SETTINGS"
    echo "Set editor type: $FINAL_EDITOR_TYPE"
fi

# ── Hooks ───────────────────────────────────────────────────────────────────
normalize_hook_events

if jq -e --arg cmd "$HOOK_SESSION" '.hooks.SessionStart[]?.hooks[]? | select(.command == $cmd)' "$SETTINGS" &>/dev/null; then
    echo "SessionStart hook already configured"
else
    apply_jq --arg cmd "$HOOK_SESSION" '
        .hooks.SessionStart += [{
            "hooks": [
                {
                    "type": "command",
                    "command": $cmd
                }
            ]
        }]
    '
    echo "Added SessionStart hook"
fi

if ! jq -e '
    (.hooks.SessionStart | type) == "array" and
    any(.hooks.SessionStart[]?; (.hooks | type) == "array") and
    any(.hooks.SessionStart[]?.hooks[]?; (.type == "command") and (.command == $session_cmd))
' --arg session_cmd "$HOOK_SESSION" "$SETTINGS" >/dev/null; then
    echo "ERROR: Claude hook installation failed validation." >&2
    echo "Expected a nested hook group with a hooks[] array for SessionStart." >&2
    exit 1
fi

echo ""
echo "Done! Restart Claude Code and press Ctrl-G to use the pager."
echo ""
echo "Your editor is configured in ~/.claude/settings.json:"
echo "  editor: $BINARY"
echo "  env.CLAUDE_PAGER_EDITOR: $(jq -r '.env.CLAUDE_PAGER_EDITOR // "not set"' "$SETTINGS")"
echo "  env.CLAUDE_PAGER_EDITOR_TYPE: $(jq -r '.env.CLAUDE_PAGER_EDITOR_TYPE // "not set"' "$SETTINGS")"
