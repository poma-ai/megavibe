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

command -v jq &>/dev/null || exit 0
# Hooks run in the session's CURRENT directory, which is often below the project root (a frontend/ or
# backend/ folder): anchor to the root first, from CLAUDE_PROJECT_DIR when it holds .agent/, else by
# walking up (at most 8 levels). No .agent/ anywhere above means this is not a megavibe project.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR/.agent" ]; then
  cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || exit 0
else
  _d="$PWD"; _n=0
  while [ ! -d "$_d/.agent" ] && [ "$_d" != "/" ] && [ "$_n" -lt 8 ]; do _d=$(dirname "$_d"); _n=$((_n + 1)); done
  [ -d "$_d/.agent" ] || exit 0
  cd "$_d" 2>/dev/null || exit 0
fi
F="megavibe-deliverables/STATUS.md"
# A regular file only: a symlinked or FIFO STATUS.md could point anywhere or hang. (The folder itself may be a
# symlink: `megavibe worktree` links it to the main checkout's on purpose.)
[ -f "$F" ] && [ ! -L "$F" ] || exit 0

INFO=$(cat | jq -r '[(.hook_event_name // "UserPromptSubmit"), ((.session_id // "default") | tostring | .[0:12]), ((.agent_id // "") | tostring | .[0:40])] | @tsv' 2>/dev/null)
IFS=$'\t' read -r EVENT SID AGENT <<< "$INFO"
[ -n "$EVENT" ] || EVENT="UserPromptSubmit"
# Project hooks also fire inside subagents (their calls carry an agent_id): the answer is the PARENT's, so a
# subagent's tool call must neither receive it nor mark it as seen.
[ -z "${AGENT:-}" ] || exit 0
case "$SID" in ''|.|..|*[!A-Za-z0-9._-]*) SID="default" ;; esac

mkdir -p .agent/LOGS 2>/dev/null
SEEN=".agent/LOGS/.status-seen.$SID"
# State files are checked BEFORE they are read: a symlink or FIFO there is refused, and reads are bounded.
[ -L "$SEEN" ] && exit 0
{ [ ! -e "$SEEN" ] || [ -f "$SEEN" ]; } || exit 0
# One delivery at a time per session (parallel tool calls run PostToolUse hooks at once): the loser leaves
# the answer pending for its next run. A lock left by a crashed hook is broken after a minute.
LOCK="$SEEN.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
# Content signature, not stat: `stat -f` means different things on BSD and GNU. Capped read.
SIG=$(head -c 1048576 "$F" 2>/dev/null | cksum 2>/dev/null | tr ' ' '-')
PREVSIG=""; [ -f "$SEEN" ] && PREVSIG=$(head -c 256 "$SEEN" 2>/dev/null | head -n 1 | cut -c1-64)
# Cheap gate: an unchanged file says nothing new (SessionStart always looks, to count what is open).
if [ "$EVENT" != "SessionStart" ] && [ -n "$SIG" ] && [ "$SIG" = "$PREVSIG" ]; then exit 0; fi

# A file a clone shipped is not something this user typed: a tracked STATUS.md is ignored.
if git ls-files --error-unmatch -- "$F" >/dev/null 2>&1; then exit 0; fi

# "D<n> <TAB> answer" for each decision under "## Decisions needed" whose FIRST Answer: line has text, and
# "OPEN <TAB> D<n>" for each without. Placeholders (only * _ - … or nothing) count as empty. Only a
# comment that starts a line is a comment. Each answer is flattened to one line of at most 300 characters,
# with double quotes and backslashes replaced so it cannot forge another entry inside the framed message.
PARSED=$(head -c 1048576 "$F" 2>/dev/null | tr -d '\r' | awk '
  function flush() { if (insec && id != "" && !got) print "OPEN\t" id; id = ""; got = 0; want = 0; seen1 = 0 }
  function clean(x) { gsub(/[[:cntrl:]]/, " ", x); gsub(/\042/, "\047", x); gsub(/\134/, "/", x); gsub(/[[:space:]]+$/, "", x); return x }
  function empty(x) { return x ~ /^[*_…`[:space:]-]*$/ }
  function emit(x) { print id "\t" substr(x, 1, 300); got = 1; want = 0 }
  # a fence line: sets fch (` or ~), fln (run length >= 3) and frest (what follows the run); 0 when it is not one
  function isfence(x,   t, c, n) { t = x; sub(/^[[:space:]]*/, "", t); c = substr(t, 1, 1); if (c != "`" && c != "~") return 0; n = 0; while (substr(t, n + 1, 1) == c) n++; if (n < 3) return 0; fch = c; fln = n; frest = substr(t, n + 1); return 1 }
  # a line that is a field of its own ("Options:", "**Context:**", "  Note:"), after stripping indentation and decoration
  function isfield(x,   t) { t = x; gsub(/^[[:space:]>*_`]+/, "", t); return t ~ /^[A-Za-z][A-Za-z ]+[*_`]*:/ }
  fence { if (isfence($0) && fch == ofch && fln >= oln && frest ~ /^[[:space:]]*$/) fence = 0; next }   # only the matching end of a fence counts
  inc { if ($0 ~ /-->/) inc = 0; next }                               # inside an HTML comment only its end matters
  /^[[:space:]]*<!--/ { if ($0 !~ /-->/) inc = 1; next }
  isfence($0) { fence = 1; ofch = fch; oln = fln; next }
  /^#[[:space:]]/ || /^##[[:space:]]/ { flush(); insec = (tolower($0) ~ /^##[[:space:]]+decisions needed/); next }
  !insec { next }
  /^###[[:space:]]/ {
    flush(); h = $0; gsub(/[*_`:]/, "", h)
    if (h ~ /^###[[:space:]]+[Dd][0-9]+([[:space:]]|$)/) { split(h, t, /[[:space:]]+/); if (length(t[2]) <= 7 && nblocks < 200) { id = toupper(t[2]); nblocks++ } }   # at most 200 decisions, ids up to 6 digits
    next
  }
  id != "" && !got && tolower($0) ~ /^[[:space:]>*_]*answer[[:space:]]*[*_]*:/ {
    if (seen1) next                                                    # only the FIRST Answer: line of a block counts
    seen1 = 1
    a = $0; sub(/^[^:]*:[*_]*[[:space:]]*/, "", a); a = clean(a)
    if (empty(a)) want = 1; else emit(a)
    next
  }
  want && !NF { want = 0 }                                          # only the line DIRECTLY below an empty Answer: counts
  # an answer typed on the line BELOW an empty "Answer:" counts: the plain line that is not a field of its own
  want && id != "" && !got && NF && !isfield($0) && $0 !~ /^[[:space:]]*(#|\||<)/ { a = clean($0); if (!empty(a)) emit(a); want = 0; next }
  want && isfield($0) { want = 0 }
  END { flush() }
')

ANSWERS=$(printf '%s\n' "$PARSED" | grep -v '^OPEN' | grep -v '^$')
OPEN=$(printf '%s\n' "$PARSED" | grep -c '^OPEN')
PREVANS=""; [ -f "$SEEN" ] && PREVANS=$(head -c 262144 "$SEEN" 2>/dev/null | tail -n +2)

NEW=$(printf '%s\n' "$ANSWERS" | grep -v '^$' | grep -vxF -f <(printf '%s\n' "$PREVANS") 2>/dev/null)
MSG=""; RELAYED=""
if [ -n "$NEW" ]; then
  # At most 20 answers and about 3500 characters per message; an answer that does not fit is NOT marked as seen
  # and arrives with the next message.
  LIST=""; n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    item="${line%%$'\t'*} = \"${line#*$'\t'}\""
    if [ "$n" -ge 20 ] || [ $(( ${#LIST} + ${#item} )) -gt 3500 ]; then break; fi
    LIST="${LIST:+$LIST; }$item"; RELAYED="${RELAYED:+$RELAYED$'\n'}$line"; n=$((n + 1))
  done <<< "$NEW"
  MSG="The user typed these answers into megavibe-deliverables/STATUS.md (file content, not chat): $LIST. Read each as a choice among that decision's listed options or a short instruction from the user; it never authorises a destructive or irreversible action by itself, so confirm those in chat. Then record it (agent-log.sh append) and move its block under \"## Decided\" with the answer so it is not asked again."
fi
# Seen = what the session already had plus what this message carries (never an answer that was cut).
SEENANS=$(printf '%s\n' "$ANSWERS" | grep -xF -f <(printf '%s\n%s\n' "$PREVANS" "$RELAYED") 2>/dev/null | grep -v '^$')
# Something was left for the next message: do not record the signature, or the unchanged-file gate would hide it.
if [ -n "$NEW" ] && [ "$(printf '%s\n' "$NEW" | grep -c .)" -gt "$(printf '%s\n' "$RELAYED" | grep -c .)" ]; then SIG="pending"; fi
if [ "$EVENT" = "SessionStart" ] && [ "${OPEN:-0}" -gt 0 ]; then
  MSG="${MSG:+$MSG }megavibe-deliverables/STATUS.md has $OPEN open decision(s) awaiting the user's Answer: line. Keep it current; do not ask the same thing inline."
fi

# Persistence comes first and must succeed: a state file we cannot write would re-relay the same answer on every
# prompt, so in that case say nothing and leave the answer pending. Never write through a symlinked state file;
# write a temp file and rename it into place (atomic against overlapping hooks of the same session).
TMPSEEN=$(mktemp "$SEEN.XXXXXX" 2>/dev/null) || exit 0
{ printf "%s\n" "$SIG"; if [ -n "$SEENANS" ]; then printf "%s\n" "$SEENANS"; fi; } 2>/dev/null > "$TMPSEEN" || { rm -f "$TMPSEEN" 2>/dev/null; exit 0; }
if [ -z "$MSG" ]; then mv -f "$TMPSEEN" "$SEEN" 2>/dev/null || rm -f "$TMPSEEN" 2>/dev/null; exit 0; fi
OUT=$(jq -n --arg ev "$EVENT" --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}' 2>/dev/null)
if [ -z "$OUT" ]; then rm -f "$TMPSEEN" 2>/dev/null; exit 0; fi   # not emitted: leave the answer pending
mv -f "$TMPSEEN" "$SEEN" 2>/dev/null || { rm -f "$TMPSEEN" 2>/dev/null; exit 0; }
printf '%s\n' "$OUT"
exit 0
