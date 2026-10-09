#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
# Open decisions the user answers by editing a file. Claude keeps a live
# megavibe-deliverables/STATUS.md (current state + numbered decisions, each with an
# `Answer:` line). This hook relays answers typed into that file, so the user can
# inject them at any moment without a chat turn of their own.
# Triggered by: SessionStart (startup|resume|clear|compact) and UserPromptSubmit.
# Advisory only; never blocks, always exits 0.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
F="megavibe-deliverables/STATUS.md"
[ -f "$F" ] || exit 0

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "UserPromptSubmit"' 2>/dev/null)
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
case "$SID" in ''|.|..|*[!A-Za-z0-9._-]*) SID="default" ;; esac

SEEN=".agent/LOGS/.status-seen.$SID"
SIG=$(stat -f '%m-%z' "$F" 2>/dev/null || stat -c '%Y-%s' "$F" 2>/dev/null)
PREVSIG=""; [ -f "$SEEN" ] && PREVSIG=$(head -n 1 "$SEEN" 2>/dev/null)
# Cheap gate: an unchanged file says nothing new (SessionStart always looks, to count what is open).
if [ "$EVENT" != "SessionStart" ] && [ -n "$SIG" ] && [ "$SIG" = "$PREVSIG" ]; then exit 0; fi

# "D<n> <TAB> answer" for every decision under "## Decisions needed" whose Answer: line has text,
# and "OPEN <TAB> D<n>" for those without. The placeholder "…"/"_"/"-" counts as empty.
PARSED=$(awk '
  /<!--/ { inc = 1 }
  inc { if ($0 ~ /-->/) inc = 0; next }                  # an HTML comment (the block shape in the template) is not a decision
  /^##[[:space:]]/ { if (insec && id != "" && !got) print "OPEN\t" id; insec = ($0 ~ /^##[[:space:]]+Decisions needed/); id = ""; got = 0; next }
  !insec { next }
  /^###[[:space:]]+D[0-9]+/ { if (id != "" && !got) print "OPEN\t" id; id = $2; got = 0; next }
  id != "" && tolower($0) ~ /^[[:space:]*_-]*answer[*_]*:[*_]*/ {
    a = $0; sub(/^[[:space:]*_-]*[Aa][Nn][Ss][Ww][Ee][Rr][*_]*:[*_]*[[:space:]]*/, "", a)
    gsub(/[[:space:]]+$/, "", a)
    if (a != "" && a != "…" && a != "_" && a != "-") { print id "\t" a; got = 1 }
  }
  END { if (id != "" && !got) print "OPEN\t" id }
' "$F" 2>/dev/null)

ANSWERS=$(printf '%s\n' "$PARSED" | grep -v '^OPEN' | grep -v '^$')
OPEN=$(printf '%s\n' "$PARSED" | grep -c '^OPEN')
PREVANS=""; [ -f "$SEEN" ] && PREVANS=$(tail -n +2 "$SEEN" 2>/dev/null)
mkdir -p .agent/LOGS 2>/dev/null
{ [ ! -e "$SEEN" ] || [ -f "$SEEN" ]; } && { printf '%s\n' "$SIG"; [ -n "$ANSWERS" ] && printf '%s\n' "$ANSWERS"; } > "$SEEN" 2>/dev/null

NEW=$(printf '%s\n' "$ANSWERS" | grep -v '^$' | grep -vxF -f <(printf '%s\n' "$PREVANS") 2>/dev/null)
MSG=""
if [ -n "$NEW" ]; then
  LIST=$(printf '%s\n' "$NEW" | awk -F'\t' '{printf "%s%s -> %s", (NR>1?"; ":""), $1, $2}')
  MSG="STATUS.md answers from the user (typed into megavibe-deliverables/STATUS.md, not into this chat): $LIST. Treat each as the user's decision now: act on it, record it (agent-log.sh append), then move its block under \"## Decided\" with the answer so it is not asked again."
elif [ "$EVENT" = "SessionStart" ] && [ "${OPEN:-0}" -gt 0 ]; then
  MSG="megavibe-deliverables/STATUS.md has $OPEN open decision(s) awaiting the user's Answer: line. Keep it current; do not ask the same thing inline."
fi
[ -n "$MSG" ] || exit 0
jq -n --arg ev "$EVENT" --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}' 2>/dev/null
exit 0
