#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
trap 'exit 0' ERR
set -u

# Megavibe — ask the user what to do with what agents moved to the Trash
# Triggered by: PostToolUse (matcher: "Bash")
#
# scripts/trash.sh records every trashed item in ~/.megavibe/trash/ledger.jsonl.
# Once the unreviewed ones pass a threshold (MEGAVIBE_TRASH_REVIEW_COUNT items,
# default 30, or MEGAVIBE_TRASH_REVIEW_MB, default 2048), the session is told to
# have them grouped and to ask the user, per group: restore, keep in the Trash,
# back up, or mark droppable (it never deletes). A single large delete crosses it in the same turn. Once per
# crossing; silent otherwise. Costs two wc calls when nothing changed.
# Opt out: MEGAVIBE_TRASH_REVIEW=0.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
command -v python3 &>/dev/null || exit 0
[ "${MEGAVIBE_TRASH_REVIEW:-1}" = "0" ] && exit 0

INPUT=$(cat 2>/dev/null || echo "")
# A subagent cannot ask the user; the main thread gets the nudge on its next Bash call.
[ -z "$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)" ] || exit 0
# Per session: a review one session deferred (nobody there to answer) is raised again,
# once, in the next session.
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')

DIR="${MEGAVIBE_TRASH_LEDGER_DIR:-${HOME:-}/.megavibe/trash}"
REVIEW="${HOME:-}/.megavibe/scripts/trash-review.py"
[ -f "$DIR/ledger.jsonl" ] && [ -f "$REVIEW" ] || exit 0
# Nothing trashed or reviewed since this session last checked: done. Both files only grow,
# so their sizes say it (an mtime compare misses two writes within one second). seen-size
# holds the sizes, then the sessions that checked at them, so interleaved sessions do not
# start python on every call.
_sz() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
SIZE="$(_sz "$DIR/ledger.jsonl"):$(_sz "$DIR/reviewed.jsonl")"
SEEN=$(cat "$DIR/seen-size" 2>/dev/null || true)
[ "$(printf '%s\n' "$SEEN" | head -n 1)" = "$SIZE" ] && printf '%s\n' "$SEEN" | tail -n +2 | grep -qxF -- "${SID:--}" && exit 0
_seen() {   # record this session at the current sizes
  if [ "$(printf '%s\n' "$SEEN" | head -n 1)" = "$SIZE" ]; then
    { printf '%s\n' "$SEEN" | head -n 1; printf '%s\n' "$SEEN" | tail -n +2 | tail -n 49; printf '%s\n' "${SID:--}"; } > "$DIR/seen-size.tmp" 2>/dev/null
  else
    printf '%s\n%s\n' "$SIZE" "${SID:--}" > "$DIR/seen-size.tmp" 2>/dev/null
  fi && mv -f "$DIR/seen-size.tmp" "$DIR/seen-size" 2>/dev/null || true
}

OUT=$(python3 "$REVIEW" nudge --peek --session "$SID" 2>/dev/null) || exit 0
if [ -z "$OUT" ]; then
  _seen
  exit 0
fi

MSG="## Trash review due

${OUT}

Do this now, before other work, in the main thread. If nobody is there to answer (an unattended or scheduled run), say so in your report and leave the review for the next attended session; nothing is lost by waiting:
1. \`python3 ~/.megavibe/scripts/trash-review.py pending --json > <scratchpad>/trash-pending.jsonl\`
2. Spawn one Agent with \`model: \"haiku\"\`: read that file and group the items (by project, cwd, path prefix and kind) into at most 8 groups. Per group: a short label, what it is, total size, the ids, and a recommendation (restore / keep / backup / droppable) with one line of reason. Regenerable output (build dirs, node_modules, caches, test fixtures it created) leans droppable; anything that looks like work — notes, reviews, audits, reports, data, code not in git — leans keep or backup, never droppable.
3. Write the groups as {\"groups\": [{\"label\": \"...\", \"ids\": [...]}]} and run \`python3 ~/.megavibe/scripts/trash-review.py group <file>\`. It prints one summary line per group, starting with its code ([G...]).
4. Ask the user with AskUserQuestion: one question per group (at most 4 per call), with that group's summary line, what it is and the recommendation; options Restore / Keep in Trash / Back up ($(python3 "$REVIEW" backup-dir 2>/dev/null)) / Mark droppable (it stays in the Trash; only the user empties it), the recommended one first. Then write {\"decisions\": [{\"group\": \"G...\", \"action\": \"restore|keep|backup|droppable\"}]} from the answers and run \`python3 ~/.megavibe/scripts/trash-review.py apply <file>\`. Nothing here deletes; droppable items stay in the Trash for the user to empty.
5. Report what was restored, backed up and marked droppable, what failed, and the droppable total from \`trash-review.py status\`."

# Record the crossing only once the message exists, so a failure here retries next call.
JSON=$(jq -n --arg msg "$MSG" --arg line "megavibe: $OUT Review queued." \
  '{systemMessage: $line, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}') || exit 0
python3 "$REVIEW" nudge-ack --session "$SID" 2>/dev/null || true
_seen
printf '%s\n' "$JSON"
exit 0
