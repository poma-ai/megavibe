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

# Locate the transcript. Prefer the transcript_path the hook input carries
# (present on PostToolUse — used by revive-watcher.sh's lazy re-spawn), which
# is authoritative and dodges the startup race. Fall back to a session-id glob
# at ~/.claude/projects/<slug>/<full-sid>.jsonl (the session_id field is the
# full UUID; our SID is the 12-char prefix). At SessionStart the transcript may
# not exist on disk yet — that's the race revive-watcher.sh later heals.
WTRANS=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
if [ -z "$WTRANS" ] || [ ! -f "$WTRANS" ]; then
  WTRANS=$(ls -t "$HOME/.claude/projects/"*"/${SID}"*.jsonl 2>/dev/null | head -1)
fi
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

# tmux runs the command string through a shell, so each arg is parsed TWICE
# (once here, once by tmux's shell). Plain "\"$VAR\"" quoting survives spaces
# but not $, backticks, or quotes in a path. printf %q makes each value safe
# for that second parse.
WATCHER_BIN_Q=$(printf '%q' "$WATCHER_BIN")
SID_Q=$(printf '%q' "$SID")
PWD_Q=$(printf '%q' "$(pwd)")
WTRANS_Q=$(printf '%q' "$WTRANS")
# tmux hands the pane the SERVER's environment, not this hook's, so the allow-list state has to be
# passed explicitly in both directions: an exported MEGAVIBE_BACKENDS must reach the watcher, and an
# UNSET one must not be inherited from whichever session started the tmux server (a pin removed with
# `megavibe backends set auto` would otherwise stay in force). The project dir is passed for the same
# reason, so the watcher reads this project's settings.local.json and no other.
# MEGAVIBE_CODEX_AUTH (the user's override) goes the same way. A Codex API key is NOT forwarded (the secret stays off
# the command line and an existing tmux server lacks it), so the admission check below runs without it too:
# a keyed-only Codex is not admitted here, and a user who wants the watcher on it sets MEGAVIBE_CODEX_AUTH=2.
if [ -n "${MEGAVIBE_BACKENDS+x}" ]; then
  BK_ENV="env MEGAVIBE_BACKENDS=$(printf '%q' "$MEGAVIBE_BACKENDS") CLAUDE_PROJECT_DIR=$PWD_Q "
else
  BK_ENV="env -u MEGAVIBE_BACKENDS CLAUDE_PROJECT_DIR=$PWD_Q "
fi
if [ -n "${MEGAVIBE_CODEX_AUTH+x}" ]; then
  BK_ENV="${BK_ENV}MEGAVIBE_CODEX_AUTH=$(printf '%q' "$MEGAVIBE_CODEX_AUTH") "
else
  BK_ENV="env -u MEGAVIBE_CODEX_AUTH ${BK_ENV#env }"
fi
# A watcher that may use neither codex nor gemini can only skip every cycle, and its tmux session
# would still mute the in-session flush nudges. Do not start one then.
RV_SH="$HOME/.megavibe/scripts/reviewers.sh"
if [ -f "$RV_SH" ]; then
  # digest-chain applies MEGAVIBE_BACKENDS and the Codex login check, so it also says "subagent" for a
  # logged-out Codex, where a watcher would only skip every cycle while its tmux session muted the
  # in-session nudges. revive-watcher.sh asks again on later tool calls, so the watcher starts once
  # Codex is logged in again. An empty or failed answer starts it (the watcher is fail-closed itself).
  if [ -n "${MEGAVIBE_BACKENDS+x}" ]; then
    BK_CHAIN=$(env -u CODEX_API_KEY -u CODEX_ACCESS_TOKEN MEGAVIBE_BACKENDS="$MEGAVIBE_BACKENDS" CLAUDE_PROJECT_DIR="$(pwd)" bash "$RV_SH" digest-chain 2>/dev/null </dev/null | tr '\n' ' ') || BK_CHAIN=""
  else
    BK_CHAIN=$(env -u MEGAVIBE_BACKENDS -u CODEX_API_KEY -u CODEX_ACCESS_TOKEN CLAUDE_PROJECT_DIR="$(pwd)" bash "$RV_SH" digest-chain 2>/dev/null </dev/null | tr '\n' ' ') || BK_CHAIN=""
  fi
  # MEGAVIBE_GEMINI_DIGEST=1 opts an allowed Gemini in after or instead of Codex (the watcher applies the same rule).
  if [ "${MEGAVIBE_GEMINI_DIGEST:-}" = 1 ] && [ -n "$(printf '%s' "${GEMINI_API_KEY:-}" | tr -d '[:space:]')" ] \
     && bash "$HOME/.megavibe/scripts/backends.sh" enabled gemini >/dev/null 2>&1; then BK_CHAIN="$BK_CHAIN gemini"; fi
  case " $BK_CHAIN " in
    *" codex "*|*" gemini "*) ;;
    *[!\ ]*) echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) not started: no allowed backend is usable (MEGAVIBE_BACKENDS, Codex login; a Codex API key alone needs MEGAVIBE_CODEX_AUTH=2)" >> "$SPAWN_LOG" 2>/dev/null; exit 0 ;;
  esac
fi
if tmux new -d -s "$TMUX_SESSION" \
     "${BK_ENV}python3 $WATCHER_BIN_Q --session-id $SID_Q --project-dir $PWD_Q --transcript $WTRANS_Q" \
     2>>"$SPAWN_LOG"; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) spawn ok" >> "$SPAWN_LOG" 2>/dev/null
else
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) spawn failed (tmux returned non-zero)" >> "$SPAWN_LOG" 2>/dev/null
fi

exit 0
