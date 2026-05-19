#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="on-session-end.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — graceful watcher shutdown on session end
# Triggered by: SessionEnd
#
# Tears down the tmux session that hosts the context-watcher daemon spawned
# by on-session-start.sh. Killing the tmux session sends SIGHUP to the
# Python process, which the watcher's signal handler converts to a final
# flush + clean exit. Without this, watcher processes would linger after
# every Claude session.

# Only act if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require jq + tmux
command -v jq &>/dev/null || exit 0
command -v tmux &>/dev/null || exit 0

INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // ""' | cut -c1-12)
[ -n "$SID" ] || exit 0

TMUX_SESSION="mvw-${SID}"
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
fi
exit 0
