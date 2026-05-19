#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="start-context-watcher.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — spawn the context-watcher daemon (idempotent)
# Triggered by: SessionStart (matchers: startup, resume)
#
# Lives in its own hook because it fires on BOTH startup and resume, while
# on-session-start.sh deliberately gates on source=startup only (project
# knowledge gets injected only once per fresh session, not on every resume).
# Resumed sessions still need the watcher — without this hook, /megavibe-restart
# and `claude --continue` would leave the session without a daemon.
#
# Behavior: on by default. Set MEGAVIBE_WATCHER=0 to opt out.

# Only act if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

# Opt-out gate
[ "${MEGAVIBE_WATCHER:-1}" != "0" ] || exit 0

# Prerequisites: watcher script + tmux on PATH. Any missing → silent skip.
WATCHER_BIN="$HOME/.megavibe/scripts/context-watcher.py"
[ -x "$WATCHER_BIN" ] || exit 0
command -v tmux &>/dev/null || exit 0

INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | cut -c1-12)
[ -n "$SID" ] || exit 0

TMUX_SESSION="mvw-${SID}"
LOG_FILE=".agent/LOGS/watcher.${SID}.log"
SPAWN_LOG=".agent/LOGS/watcher-spawn.${SID}.log"

# Idempotent — already running? exit clean.
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  exit 0
fi

# Find the transcript file by session-id glob. Claude Code stores transcripts
# at ~/.claude/projects/<slug>/<full-sid>.jsonl. The session_id field is the
# full UUID; our SID is the 12-char prefix. Glob for it.
WTRANS=$(ls -t "$HOME/.claude/projects/"*"/${SID}"*.jsonl 2>/dev/null | head -1)
if [ -z "$WTRANS" ] || [ ! -f "$WTRANS" ]; then
  # Log the skip — useful for diagnosing "watcher never spawned" tickets.
  mkdir -p .agent/LOGS 2>/dev/null
  {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) spawn-skip: transcript not found for SID=${SID}"
    echo "  globbed: ~/.claude/projects/*/${SID}*.jsonl"
  } >> "$SPAWN_LOG" 2>/dev/null
  exit 0
fi

# Spawn into a named tmux session. The 2>/dev/null swallows tmux's stderr —
# but we also write a spawn log entry so silent failures are at least
# diagnosable later.
mkdir -p .agent/LOGS 2>/dev/null
{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) spawn attempt: sid=${SID} tmux=${TMUX_SESSION} transcript=${WTRANS##*/}"
} >> "$SPAWN_LOG" 2>/dev/null

if tmux new -d -s "$TMUX_SESSION" \
     "python3 \"$WATCHER_BIN\" --session-id \"$SID\" --project-dir \"$(pwd)\" --transcript \"$WTRANS\"" \
     2>>"$SPAWN_LOG"; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) spawn ok" >> "$SPAWN_LOG" 2>/dev/null
else
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) spawn failed (tmux returned non-zero)" >> "$SPAWN_LOG" 2>/dev/null
fi

exit 0
