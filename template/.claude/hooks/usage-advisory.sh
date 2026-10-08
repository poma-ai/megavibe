#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
# Subscription-first routing, mid-session half: when Claude subscription usage is
# running hot (or capacity will be lost at reset), tell the model once per band per
# session how to spend subagents. The launch half is `megavibe` + scripts/usage-route.sh.
# Triggered by: SessionStart (startup|resume) and PreToolUse (Agent), the moment the
# subagent model is decided. Advisory only; never blocks, always exits 0.

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
FLAG=".agent/LOGS/.usage-band.$SID"
[ "$BAND" = "$(cat "$FLAG" 2>/dev/null)" ] && exit 0
mkdir -p .agent/LOGS 2>/dev/null
printf '%s' "$BAND" > "$FLAG" 2>/dev/null
[ "$BAND" = "over" ] || [ "$BAND" = "under" ] || exit 0

MSG=$(bash "$UR" advisory 2>/dev/null)
[ -n "$MSG" ] || exit 0
jq -n --arg ev "$EVENT" --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}' 2>/dev/null
exit 0
