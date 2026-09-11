#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  echo "read-coverage.sh failed at line $1: $2" >> "${HOME:-/tmp}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — say so when an edit lands on lines that were never read.
#
# Claude Code already requires a Read of a file before Edit will touch it. That
# guard checks THAT you read, not HOW MUCH: a grep hit followed by
# `Read(file, offset=100, limit=3)` satisfies it completely, and the next Edit
# can rewrite line 1400 of a file whose other 1,997 lines the model has never
# seen. Demonstrated directly on 2026-09-11 — three lines of a 200-line file
# read, line 101 edited, no warning anywhere.
#
# Measured across every project's tool logs on that date, counting only `Edit`,
# the tool that requires a prior Read:
#     2,947  edits after only a SLICE read
#     1,883  edits after reading the file fully
# Slice-then-edit was the more common of the two. This hook exists because that
# ratio is the wrong way round.
#
# What it does NOT do: block. A guard that fires thousands of times gets turned
# off within a week, and most slice reads are perfectly sound — reading lines
# 1-2000 and editing line 500 is fine and stays silent here. It speaks only when
# the edited region falls outside every range actually read, which is the case
# where the model genuinely cannot know what it is changing.
#
# Three handlers, one script:
#   PostToolUse(Read)                — record the (file, first, last) line read
#   PostToolUse(Edit|MultiEdit|Write)— credit what the model just authored, and
#                                      shift recorded ranges by the line delta
#   PreToolUse(Edit|MultiEdit)       — locate the edit, compare against ranges
#
# Two limits, stated rather than implied:
#   - Line numbers DRIFT. Ranges are recorded at read time; a later edit that
#     inserts or deletes lines shifts everything below it. A full read still
#     covers the file, so the common case is unaffected, but after a large
#     insertion a slice range can point at the wrong lines. The post-edit
#     branch shifts ranges by the line delta so this mostly cancels, but an
#     edit made outside this session (another process, a git operation) is not
#     seen and will leave ranges stale.
#   - The anchor can be COMMON. If the first line of old_string is `}` or
#     `import os`, an occurrence inside a read range silences the warning even
#     when the edit itself is elsewhere. That is the deliberate direction to err
#     in: a missed warning costs one unread edit, a false one costs the hook.
#
# Not covered, deliberately: edits made through Bash (`sed -i`, a python
# heredoc, `cat >`). Those bypass Read-before-Edit entirely and are the larger
# hole, but the target file cannot be identified reliably from an arbitrary
# shell command, and a guess that cries wolf is worse than silence. See
# MEGAVIBE_READ_COVERAGE=0 to disable this hook.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
[ "${MEGAVIBE_READ_COVERAGE:-1}" != "0" ] || exit 0

INPUT=$(cat 2>/dev/null || echo "")
[ -n "$INPUT" ] || exit 0
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null) || exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
# No shared "default" bucket: without a real session id this would be one
# permanent file that every session writes to and reads from, where a stranger's
# old range silences a real warning. No id, no tracking.
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | cut -c1-12)
case "${SID:-}" in ''|.|..|*[!A-Za-z0-9._-]*) exit 0 ;; esac

LOGDIR=".agent/LOGS"
mkdir -p "$LOGDIR" 2>/dev/null || true
RANGES="${LOGDIR}/.read-ranges.${SID}.jsonl"

# --- record what was read ---------------------------------------------------
if [ "$EVENT" = "PostToolUse" ] && [ "$TOOL" = "Read" ]; then
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || exit 0
  [ -n "$FILE" ] && [ -f "$FILE" ] || exit 0
  OFF=$(printf '%s' "$INPUT" | jq -r '.tool_input.offset // 0' 2>/dev/null)
  LIM=$(printf '%s' "$INPUT" | jq -r '.tool_input.limit // 0' 2>/dev/null)
  case "$OFF" in ''|*[!0-9]*) OFF=0 ;; esac
  case "$LIM" in ''|*[!0-9]*) LIM=0 ;; esac
  # Read returns at most DEFAULT_LINES lines. A "full" read of a longer file is
  # therefore NOT the whole file, and recording it as such overcredits the read
  # — silencing the very warning this hook exists to raise. Clamp to what Read
  # can actually have returned, and to EOF.
  DEFAULT_LINES=2000
  # awk NR, not `wc -l`: wc counts newlines, so a file whose last line has no
  # terminator loses that line, and the old +1 invented one that never existed.
  EOFLINE=$(awk 'END{print NR}' "$FILE" 2>/dev/null)
  case "${EOFLINE:-}" in ''|*[!0-9]*) exit 0 ;; esac
  [ "$EOFLINE" -gt 0 ] || exit 0
  A=$(( OFF > 0 ? OFF : 1 ))
  # An offset past the end read nothing; recording it produced an inverted
  # range (a > b) that silently matched nothing thereafter.
  [ "$A" -le "$EOFLINE" ] || exit 0
  if [ "$LIM" -gt 0 ]; then B=$(( A + LIM - 1 )); else B=$(( A + DEFAULT_LINES - 1 )); fi
  [ "$B" -gt "$EOFLINE" ] && B="$EOFLINE"
  jq -nc --arg f "$FILE" --argjson a "$A" --argjson b "$B" '{f:$f,a:$a,b:$b}' \
    >> "$RANGES" 2>/dev/null || true
  # Bounded: the check path re-parses this file on every Edit, and a long
  # session Reads hundreds of times. The oldest ranges are also the most likely
  # to be stale, so losing them first is the right trade.
  LINES=$(wc -l < "$RANGES" 2>/dev/null | tr -d ' ')
  if [ "${LINES:-0}" -gt 2000 ]; then
    tail -n 1000 "$RANGES" > "${RANGES}.tmp" 2>/dev/null && mv -f "${RANGES}.tmp" "$RANGES" 2>/dev/null
  fi
  exit 0
fi

# --- keep the ranges honest after the model changes the file ----------------
# Absolute line numbers go stale the moment an edit adds or removes lines, and
# a stale range is a FALSE ALARM — telling the model it has not seen text it
# wrote a call earlier. Reviewers reproduced three such cases on first try, so
# this branch does three things:
#   Write          — the model authored the whole file: record 1..EOF.
#   Edit/MultiEdit — credit the WHOLE inserted region (not just its first line),
#                    and SHIFT every existing range for that file by the line
#                    delta so previously-read text keeps pointing at itself.
if [ "$EVENT" = "PostToolUse" ] && \
   { [ "$TOOL" = "Edit" ] || [ "$TOOL" = "MultiEdit" ] || [ "$TOOL" = "Write" ]; }; then
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || exit 0
  [ -n "$FILE" ] && [ -f "$FILE" ] || exit 0
  EOFLINE=$(awk 'END{print NR}' "$FILE" 2>/dev/null)
  case "${EOFLINE:-}" in ''|*[!0-9]*) exit 0 ;; esac

  if [ "$TOOL" = "Write" ]; then
    jq -nc --arg f "$FILE" --argjson a 1 --argjson b "$EOFLINE" '{f:$f,a:$a,b:$b}' \
      >> "$RANGES" 2>/dev/null || true
    exit 0
  fi

  # old/new line counts per edit, tab-separated, in application order.
  PAIRS=$(printf '%s' "$INPUT" | jq -r '
    (if .tool_input.edits then .tool_input.edits[]? else .tool_input end)
    | [ ((.new_string // "") | split("\n") | length)
      , ((.old_string // "") | split("\n") | length)
      , ((.new_string // "") | [splits("\n") | select(length >= 3)][0] // "") ]
    | @tsv' 2>/dev/null) || exit 0

  while IFS="$(printf '\t')" read -r NLINES OLINES ANCHOR; do
    case "${NLINES:-}" in ''|*[!0-9]*) continue ;; esac
    case "${OLINES:-}" in ''|*[!0-9]*) continue ;; esac
    [ -n "${ANCHOR:-}" ] || continue
    H=$(grep -nF -- "$ANCHOR" "$FILE" 2>/dev/null | cut -d: -f1 | head -1)
    case "${H:-}" in ''|*[!0-9]*) continue ;; esac
    DELTA=$(( NLINES - OLINES ))
    if [ "$DELTA" -ne 0 ]; then
      # One jq pass: anything starting below the edit moves with it, and a range
      # spanning the edit grows or shrinks by the same amount.
      if jq -c --arg f "$FILE" --argjson h "$H" --argjson d "$DELTA" '
           if .f == $f then
             (if .a > $h then .a += $d else . end)
             | (if .b >= $h then .b += $d else . end)
             | (if .a < 1 then .a = 1 else . end)
           else . end' "$RANGES" > "${RANGES}.tmp" 2>/dev/null; then
        mv -f "${RANGES}.tmp" "$RANGES" 2>/dev/null || rm -f "${RANGES}.tmp" 2>/dev/null
      else
        rm -f "${RANGES}.tmp" 2>/dev/null
      fi
    fi
    # The inserted region in full: the model authored every line of it.
    jq -nc --arg f "$FILE" --argjson a "$H" --argjson b "$(( H + NLINES - 1 ))" \
      '{f:$f,a:$a,b:$b}' >> "$RANGES" 2>/dev/null || true
  done <<EOF
$PAIRS
EOF
  exit 0
fi

# --- check that an edit lands on something that was read --------------------
case "$EVENT:$TOOL" in
  PreToolUse:Edit|PreToolUse:MultiEdit) ;;
  *) exit 0 ;;
esac
[ -s "$RANGES" ] || exit 0

FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || exit 0
[ -n "$FILE" ] && [ -f "$FILE" ] || exit 0

# One anchor per edit: the first line of its old_string. That is what the edit
# is pinned to, and it keeps the check to one grep per edit.
OLDS=$(printf '%s' "$INPUT" | jq -r '
  if .tool_input.edits then (.tool_input.edits[]?.old_string // empty)
  else (.tool_input.old_string // empty) end
  | [splits("\n") | select(length >= 3)][0] // empty' 2>/dev/null) || exit 0
[ -n "$OLDS" ] || exit 0

# Ranges for this file only, as "start end" lines.
RANGE_LIST=$(jq -r --arg f "$FILE" 'select(.f==$f) | "\(.a) \(.b)"' "$RANGES" 2>/dev/null)
[ -n "$RANGE_LIST" ] || exit 0

# No python here: it fires on every Edit, and interpreter startup measured
# ~112ms against ~6ms for grep. CLAUDE.md requires hooks to be fast.
BAD=0; BADLINE=""; BADTEXT=""
while IFS= read -r OLD; do
  NEEDLE=$(printf '%s' "$OLD" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ "${#NEEDLE}" -ge 3 ] || continue
  # Capped: a common anchor in a large file can match hundreds of times, and
  # the coverage test below is hits x ranges shell comparisons. Beyond a few
  # dozen matches the anchor is too generic to carry a useful signal anyway, so
  # the cap costs nothing real and bounds the hot path.
  HITS=$(grep -nF -- "$NEEDLE" "$FILE" 2>/dev/null | cut -d: -f1 | head -40)
  [ -n "$HITS" ] || continue
  # `grep` on a file with a NUL byte prints "Binary file X matches", which is
  # not a line number: it reached an integer test and the message text.
  case "$HITS" in *[!0-9[:space:]]*) continue ;; esac
  # Conservative: if ANY occurrence sits inside a read range, stay quiet. A
  # false alarm costs more than a missed one — it is what gets a hook disabled.
  COVERED=0
  for H in $HITS; do
    while read -r A B; do
      [ -n "$A" ] || continue
      if [ "$H" -ge "$A" ] && [ "$H" -le "$B" ]; then COVERED=1; break; fi
    done <<EOF
$RANGE_LIST
EOF
    [ "$COVERED" -eq 1 ] && break
  done
  if [ "$COVERED" -eq 0 ]; then
    BAD=$(( BAD + 1 ))
    if [ -z "$BADLINE" ]; then
      BADLINE=$(printf '%s' "$HITS" | head -1)
      BADTEXT=$(printf '%.60s' "$NEEDLE")
    fi
  fi
done <<EOF
$OLDS
EOF

[ "$BAD" -gt 0 ] || exit 0
COUNT="$BAD"; LINE="$BADLINE"; TEXT="$BADTEXT"
COUNT_NOTE=""
[ "$COUNT" -gt 1 ] && COUNT_NOTE=" ${COUNT} of the edits in this call land outside what you have read."
TOTAL=$(awk 'END{print NR}' "$FILE" 2>/dev/null)
SEEN=$(jq -r --arg f "$FILE" 'select(.f==$f) | 1' "$RANGES" 2>/dev/null | grep -c . || echo 0)

MSG="[megavibe read-coverage] This edit lands on line ~${LINE} of ${FILE} (${TOTAL} lines), outside every range you have read this session"
MSG="${MSG}. You are changing something you have not seen: near \"${TEXT}\". Read that region first, or say plainly that you are editing blind and why.${COUNT_NOTE} (${SEEN} ranges recorded for this file; MEGAVIBE_READ_COVERAGE=0 disables this.)"

jq -nc --arg c "$MSG" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$c}}' 2>/dev/null || true
exit 0
