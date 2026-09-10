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

# The poma-memory search daemon is machine-wide, not per-session, so it is only
# reapable once NOBODY is left to serve. Otherwise this hook would kill the warm
# index out from under three other sessions.
#
# Observed, not counted. A reference count incremented at SessionStart and
# decremented here leaks upward every time this hook does not run — a crash, a
# kill -9, a laptop shutdown — and a leaked count means the daemon never exits,
# which is worse than the 30-minute idle timer it would be replacing. Counting
# live processes re-derives the truth every time and cannot drift.
#
# The idle timeout stays as the backstop for the case where this hook never
# fires at all.
if tmux has-session -t poma-serve 2>/dev/null; then
  MY_PID="${PPID:-0}"
  OTHERS=0
  # Every claude process except our own parent; alive AND sitting in a directory
  # that has a .agent, i.e. a megavibe project that would want the daemon.
  for _p in $(pgrep -x claude 2>/dev/null); do
    [ "$_p" = "$MY_PID" ] && continue
    _cwd=$(lsof -a -p "$_p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [ -n "$_cwd" ] && [ -d "$_cwd/.agent" ] && OTHERS=$((OTHERS+1))
  done
  if [ "$OTHERS" -eq 0 ]; then
    tmux kill-session -t poma-serve 2>/dev/null || true
    echo "$(date -u +%FT%TZ) poma-serve stopped: last megavibe session ended" \
      >> .agent/LOGS/poma-serve-spawn.log 2>/dev/null || true
  fi
fi

exit 0
