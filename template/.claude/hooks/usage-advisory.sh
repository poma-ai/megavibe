#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
# Subscription-first routing, mid-session half: when Claude subscription usage is
# running hot (or capacity will be lost at reset), or Codex has room Claude lacks (or
# the reverse), tell the model once per state per session how to spend subagents. The launch half is `megavibe` + scripts/usage-route.sh.
# Triggered by: SessionStart (startup|resume|clear|compact) and PreToolUse (Agent). The
# PreToolUse context lands after that call chose its model, so it steers the calls after it.
# Advisory only; never blocks, always exits 0.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
UR="${MEGAVIBE_HOME:-$HOME/.megavibe}/scripts/usage-route.sh"
[ -f "$UR" ] || exit 0
[ "${MEGAVIBE_ROUTER:-1}" = "0" ] && exit 0

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "PreToolUse"' 2>/dev/null)
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
case "$SID" in ''|.|..|*[!A-Za-z0-9._-]*) SID="default" ;; esac

BAND=$(bash "$UR" band 2>/dev/null)
# Which subscription should optional work lean on? "prefer|sentence", prefer = claude | codex | -
BAL=$(bash "$UR" balance 2>/dev/null); PREF="${BAL%%|*}"; BALMSG="${BAL#*|}"
case "$PREF" in claude|codex) ;; *) PREF="-"; BALMSG="" ;; esac
KEY="$BAND:$PREF"
FLAG=".agent/LOGS/.usage-band.$SID"
PREVKEY=""; [ -f "$FLAG" ] && PREVKEY=$(cat "$FLAG" 2>/dev/null)   # regular files only: a FIFO here must not hang a hook
# SessionStart (a fresh session, /clear, a compaction) always restates a non-normal state: the
# model may have lost the earlier advisory. PreToolUse speaks only when the state changed.
if [ "$EVENT" != "SessionStart" ] && [ "$KEY" = "$PREVKEY" ]; then exit 0; fi
mkdir -p .agent/LOGS 2>/dev/null
{ [ ! -e "$FLAG" ] || [ -f "$FLAG" ]; } && printf '%s' "$KEY" > "$FLAG" 2>/dev/null
MSG=""
case "$BAND" in over|under) MSG=$(bash "$UR" advisory 2>/dev/null) ;; esac
[ -n "$BALMSG" ] && MSG="${MSG:+$MSG }$BALMSG"
# A band that just ended must be retracted even when a balance sentence speaks in the same breath,
# or the session keeps the earlier subagent pinning.
case "$PREVKEY" in
  over:*|under:*) [ "$BAND" = normal ] && MSG="usage router: Claude usage is back in the normal range; the earlier subagent model advice no longer applies.${MSG:+ $MSG}" ;;
  *:claude|*:codex) [ -z "$MSG" ] && MSG="usage router: the earlier balance advice no longer applies; subscription usage is balanced." ;;
esac
[ -n "$MSG" ] || exit 0
jq -n --arg ev "$EVENT" --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}' 2>/dev/null
exit 0
