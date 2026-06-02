#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="revive-watcher.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — revive the context-watcher daemon if it died or never spawned.
#
# Triggered by: PostToolUse (all tools). Exit 0 ALWAYS — best-effort, advisory.
#
# Why this exists: start-context-watcher.sh fires ONCE at SessionStart and can
# lose a startup race — Claude Code may not have written the transcript JSONL
# to disk yet, so the glob finds nothing and the hook gives up PERMANENTLY.
# Result: the watcher never runs, .agent/ silently stops auto-flushing, and the
# only safety net left is the user noticing a high % in the statusline. By the
# time ANY tool has run, the transcript exists — so revive the watcher here.
#
# Kept in its own file (not folded into log-tool-event.sh) per that hook's
# concern-count moratorium. Single concern, fast path: an early tmux check and
# a 60s throttle mean the common case is two cheap checks and an exit.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0

# Respect the same opt-out and prerequisites as the spawn hook — if the watcher
# was never meant to run, don't thrash trying to start it.
[ "${MEGAVIBE_WATCHER:-1}" != "0" ] || exit 0
command -v tmux &>/dev/null || exit 0
WATCHER_BIN="$HOME/.megavibe/scripts/context-watcher.py"
[ -x "$WATCHER_BIN" ] || exit 0

# Project stdin down to the two small fields we need — never hold the
# (possibly multi-MB) tool_response in a shell variable or re-pipe it. jq
# streams stdin and emits a tiny object; that object is all we pass onward.
META=$(jq -c '{session_id, transcript_path}' 2>/dev/null || echo '{}')
SID=$(echo "$META" | jq -r '.session_id // ""' 2>/dev/null | cut -c1-12)
[ -n "$SID" ] || exit 0

# Already alive → nothing to do (the overwhelmingly common case).
tmux has-session -t "mvw-${SID}" 2>/dev/null && exit 0

# Throttle: at most one revive attempt per 60s per session, so a watcher that
# genuinely can't start (e.g. python missing) doesn't spawn a subprocess on
# every single tool call.
FLAG=".agent/LOGS/.watcher-respawn.${SID}"
NOW=$(date +%s 2>/dev/null || echo 0)
LAST=0
[ -f "$FLAG" ] && LAST=$(cat "$FLAG" 2>/dev/null || echo 0)
[ "$((NOW - LAST))" -ge 60 ] 2>/dev/null || exit 0
mkdir -p .agent/LOGS 2>/dev/null || true
echo "$NOW" > "$FLAG" 2>/dev/null || true

# Reuse the canonical spawn logic — pipe our own input through (it carries both
# session_id AND transcript_path, so the spawn hook can skip the racey glob).
HOOK_DIR=$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)
if [ -n "$HOOK_DIR" ] && [ -x "$HOOK_DIR/start-context-watcher.sh" ]; then
  echo "$META" | bash "$HOOK_DIR/start-context-watcher.sh" >/dev/null 2>&1 || true
fi

exit 0
