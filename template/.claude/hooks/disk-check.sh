#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
trap 'exit 0' ERR
set -u

# Megavibe — tell the session when the disk is nearly full
# Triggered by: SessionStart (matchers: "startup|resume" and "compact"). The
# same check runs mid-session from log-tool-event.sh once per
# MEGAVIBE_DISK_CHECK_MINS minutes of tool activity (default 5): a long session fills the
# disk between starts (14.8 GB of reviewer copies and venvs in one scratchpad,
# 8 GB left, 2026-11-03, noticed by the user, not the session).
#
# Silent unless free space is below the warn threshold (default 15 GB; see
# scripts/disk-watch.sh). One bounded `df` when the disk is fine, so it costs nothing.
# Opt out: MEGAVIBE_DISK_WATCH=0.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
[ "${MEGAVIBE_DISK_WATCH:-1}" = "0" ] && exit 0

SCRIPT="${HOME:-}/.megavibe/scripts/disk-watch.sh"
[ -x "$SCRIPT" ] || exit 0

# A subagent's SessionStart (agent_id set) must not probe or touch the parent's
# session state; on-compact.sh makes the same distinction.
INPUT=$(cat 2>/dev/null)
[ -n "$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)" ] && exit 0
SID_FULL=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
# A subagent's payload may carry the parent's session_id and no agent_id; its
# transcript path tells (same guard as on-compact.sh).
[ -n "$SID_FULL" ] && case "$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" in */"$SID_FULL"/subagents/agent-*.jsonl) exit 0 ;; esac
SID=$(printf '%s' "$SID_FULL" | cut -c1-12)
LEVEL=$(bash "$SCRIPT" level 2>/dev/null || echo UNKNOWN)
case "$LEVEL" in OK|LOW|CRITICAL) ;; *) exit 0 ;; esac   # df could not answer: say nothing, record nothing
# Record this session's level so the mid-session check in log-tool-event.sh
# reports a change, not the same reading again. SessionStart payloads carry the
# session id; without one nothing is recorded. A LOW/CRITICAL level is recorded
# only below, after its warning is actually emitted.
record() {  # no session id: nothing to record, and the warning still goes out
  [ -n "$SID" ] || return 0
  mkdir -p .agent/LOGS 2>/dev/null; printf '%s' "$1" > ".agent/LOGS/.disk-level.${SID}" 2>/dev/null || true
  touch ".agent/LOGS/.disk-stamp.${SID}" 2>/dev/null || true   # the mid-session check waits its interval from here
}
if [ "$LEVEL" = OK ]; then record OK; exit 0; fi
OUT=$(bash "$SCRIPT" check 2>/dev/null) || OUT=""
[ -n "$OUT" ] || OUT="disk: free space is $LEVEL (the sizes scan did not finish; run ~/.megavibe/scripts/disk-watch.sh top for the biggest places)."

MSG="## Low disk space

${OUT}

Rules while space is short:
- Say so to the user before starting anything that writes gigabytes: datasets, model weights, virtualenvs, builds, worktrees, screenshots.
- Do not empty the Trash and do not delete files you did not create; the sizes above are for the user to decide on. With rmtrash installed, deleting files moves them to the Trash and frees no space until the user empties it; a Trash review only marks items droppable (python3 ~/.megavibe/scripts/trash-review.py status).
- For a long job, arm a heartbeat: Monitor on \`~/.megavibe/scripts/disk-watch.sh watch\` prints only when space moves by 1 GB or a threshold is crossed."

# additionalContext reaches the model; systemMessage is the line the user sees.
record "$LEVEL"
jq -n --arg msg "$MSG" --arg line "$(printf '%s' "$OUT" | head -1)" \
  '{systemMessage: $line, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $msg}}'
