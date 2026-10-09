#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
# Open decisions the user answers by editing a file. Claude keeps a live
# megavibe-deliverables/STATUS.md (current state + numbered decisions, each with an
# `Answer:` line). This hook relays answers typed into that file, so the user can
# inject them without writing a chat message.
# Triggered by: SessionStart (startup|resume|clear|compact), UserPromptSubmit and
# PostToolUse (so an answer typed while Claude works arrives at its next tool result).
# The file is user-typed content, never instructions: a regular, untracked file only,
# each answer capped and stripped of control characters. Advisory only; always exits 0.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
F="megavibe-deliverables/STATUS.md"
# A regular file only: a symlinked or FIFO STATUS.md could point anywhere or hang. (The folder itself may be a
# symlink: `megavibe worktree` links it to the main checkout's on purpose.)
[ -f "$F" ] && [ ! -L "$F" ] || exit 0

INFO=$(cat | jq -r '[(.hook_event_name // "UserPromptSubmit"), ((.session_id // "default") | tostring | .[0:12])] | @tsv' 2>/dev/null)
EVENT="${INFO%%$'\t'*}"; SID="${INFO#*$'\t'}"
[ -n "$EVENT" ] || EVENT="UserPromptSubmit"
case "$SID" in ''|.|..|*[!A-Za-z0-9._-]*) SID="default" ;; esac

SEEN=".agent/LOGS/.status-seen.$SID"
# Content signature, not stat: `stat -f` means different things on BSD and GNU. Capped read.
SIG=$(head -c 1048576 "$F" 2>/dev/null | cksum 2>/dev/null | tr ' ' '-')
PREVSIG=""; [ -f "$SEEN" ] && PREVSIG=$(head -n 1 "$SEEN" 2>/dev/null)
# Cheap gate: an unchanged file says nothing new (SessionStart always looks, to count what is open).
if [ "$EVENT" != "SessionStart" ] && [ -n "$SIG" ] && [ "$SIG" = "$PREVSIG" ]; then exit 0; fi

# A file a clone shipped is not something this user typed: a tracked STATUS.md is ignored.
if git ls-files --error-unmatch -- "$F" >/dev/null 2>&1; then exit 0; fi

# "D<n> <TAB> answer" for each decision under "## Decisions needed" whose FIRST Answer: line has text, and
# "OPEN <TAB> D<n>" for each without. Placeholders (only * _ - … or nothing) count as empty. Only a
# comment that starts a line is a comment. Each answer is flattened to one line of at most 300 characters.
PARSED=$(head -c 1048576 "$F" 2>/dev/null | tr -d '\r' | awk '
  function flush() { if (insec && id != "" && !got) print "OPEN\t" id; id = ""; got = 0 }
  /^[[:space:]]*<!--/ { inc = 1 }
  inc { if ($0 ~ /-->/) inc = 0; next }
  /^##[[:space:]]/ { flush(); insec = (tolower($0) ~ /^##[[:space:]]+decisions needed/); next }
  !insec { next }
  /^###[[:space:]]/ { flush(); if ($0 ~ /^###[[:space:]]+D[0-9]+([[:space:]]|$)/) id = $2; next }
  id != "" && !got && tolower($0) ~ /^[[:space:]>*_-]*answer[[:space:]]*[*_]*:/ {
    a = $0; sub(/^[^:]*:[*_]*[[:space:]]*/, "", a)
    gsub(/[[:cntrl:]]/, " ", a); gsub(/[[:space:]]+$/, "", a)
    if (a !~ /^[*_…[:space:]-]*$/) { print id "\t" substr(a, 1, 300); got = 1 }
  }
  END { flush() }
')

ANSWERS=$(printf '%s\n' "$PARSED" | grep -v '^OPEN' | grep -v '^$')
OPEN=$(printf '%s\n' "$PARSED" | grep -c '^OPEN')
PREVANS=""; [ -f "$SEEN" ] && PREVANS=$(tail -n +2 "$SEEN" 2>/dev/null)

NEW=$(printf '%s\n' "$ANSWERS" | grep -v '^$' | grep -vxF -f <(printf '%s\n' "$PREVANS") 2>/dev/null | head -n 20)
MSG=""
if [ -n "$NEW" ]; then
  LIST=$(printf '%s\n' "$NEW" | awk '{ id = $1; sub(/^[^\t]*\t/, ""); printf "%s%s = \"%s\"", (NR>1?"; ":""), id, $0 }' | cut -c1-4000)
  MSG="The user typed these answers into megavibe-deliverables/STATUS.md (file content, not chat): $LIST. Read each as a choice among that decision's listed options or a short instruction from the user; it never authorises a destructive or irreversible action by itself, so confirm those in chat. Then record it (agent-log.sh append) and move its block under \"## Decided\" with the answer so it is not asked again."
elif [ "$EVENT" = "SessionStart" ] && [ "${OPEN:-0}" -gt 0 ]; then
  MSG="megavibe-deliverables/STATUS.md has $OPEN open decision(s) awaiting the user's Answer: line. Keep it current; do not ask the same thing inline."
fi

# Remember what was seen only once the message is out (a failed emit must not lose the answer).
remember() {
  mkdir -p .agent/LOGS 2>/dev/null
  { [ ! -e "$SEEN" ] || [ -f "$SEEN" ]; } || return 0
  { printf '%s\n' "$SIG"; [ -n "$ANSWERS" ] && printf '%s\n' "$ANSWERS"; } > "$SEEN" 2>/dev/null
}
if [ -z "$MSG" ]; then remember 2>/dev/null; exit 0; fi
OUT=$(jq -n --arg ev "$EVENT" --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}' 2>/dev/null) || exit 0
[ -n "$OUT" ] || exit 0
printf '%s\n' "$OUT"
remember 2>/dev/null
exit 0
