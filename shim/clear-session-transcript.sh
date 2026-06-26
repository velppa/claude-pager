#!/usr/bin/env bash
# SessionEnd hook: removes the tty-keyed transcript pointer written by
# save-session-transcript.sh, so a dead session's pointer can't be read by a
# new session that lands on the same recycled tty.
#
# Install: add to Claude Code settings.json under hooks.SessionEnd
set -euo pipefail

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

rm -f "/tmp/claude-transcript-${tty_key}"
