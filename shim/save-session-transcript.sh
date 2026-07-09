#!/usr/bin/env bash
# SessionStart hook: records the session's transcript_path so the prompt editor
# can find the exact transcript for the session it was invoked from, even when
# many sessions share a working directory.
#
# Two keys are written because different session types expose different
# identifiers to the editor subprocess:
#   - bridge id: desktop-app / harness sessions give the editor only
#     CLAUDE_CODE_BRIDGE_SESSION_ID (no session UUID, no usable tty).
#   - tty:       plain terminal sessions are identified by their controlling tty.
# Both map to the same transcript_path; the editor reads whichever it has.
#
# Install: add to Claude Code settings.json under hooks.SessionStart
set -euo pipefail

input=$(cat)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
[[ -z "$transcript" ]] && exit 0

# Bridge/harness sessions: key by the bridge id (present even when there is no
# real tty, e.g. the desktop app).
if [[ -n "${CLAUDE_CODE_BRIDGE_SESSION_ID:-}" ]]; then
    printf '%s\n' "$transcript" > "/tmp/claude-transcript-bridge-${CLAUDE_CODE_BRIDGE_SESSION_ID}"
fi

# Walk up the process tree to find the Claude process and get its tty
pid=$PPID
tty_key=""
for _ in 1 2 3 4 5 6; do
    comm=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ' || true)
    if [[ "$comm" == "claude" || "$comm" == "node" ]]; then
        tty_key=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d ' ' || true)
        break
    fi
    ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
    [[ -z "$ppid" || "$ppid" -le 1 ]] && break
    pid=$ppid
done

[[ -z "$tty_key" || "$tty_key" == "??" ]] && exit 0

printf '%s\n' "$transcript" > "/tmp/claude-transcript-${tty_key}"
