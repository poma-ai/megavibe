#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
trap 'exit 0' ERR
set -u

# Megavibe — ask the user what to do with what agents moved to the Trash
# Triggered by: PostToolUse (matcher: "Bash")
#
# scripts/trash.sh records every trashed item in ~/.megavibe/trash/ledger.jsonl.
# When a size/age threshold is reached, the main session gets a review procedure.
# The review itself never deletes. The final step offers the approved emptier.
# Opt out: MEGAVIBE_TRASH_REVIEW=0.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
command -v python3 &>/dev/null || exit 0
[ "${MEGAVIBE_TRASH_REVIEW:-1}" = "0" ] && exit 0

INPUT=$(cat 2>/dev/null || echo "")
# Hook stdin/stdout are pipes even for attended runs, and remote sessions can have
# no controlling tty. Suppress explicit unattended signals and bound ambiguous cases
# (including cron inside a live session) with a machine-wide due-state stamp.
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = "0" ] && exit 0
ATTENDANCE=$(printf '%s' "$INPUT" | jq -ers '
  select(length == 1) | .[0] |
  select(type == "object" and
  ((.agent_id // "") == "") and
  ((.transcript_path // "") | test("/subagents/agent-[^/]+\\.jsonl$") | not)) |
  if .is_interactive == false or .scheduled == true then "unattended"
  elif .is_interactive == true then "attended"
  else "unknown" end
' 2>/dev/null) || exit 0
if [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" != "1" ]; then
  [ "$ATTENDANCE" = "unattended" ] && exit 0
  # Remote Control bridge processes also use SDK entrypoints.
  if [ "$ATTENDANCE" = "unknown" ] && [ "${CLAUDE_CODE_ENVIRONMENT_KIND:-}" != "bridge" ]; then
    case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk*|ci|headless) exit 0 ;; esac
  fi
fi

DIR="${MEGAVIBE_TRASH_LEDGER_DIR:-${HOME:-}/.megavibe/trash}"
REVIEW="${HOME:-}/.megavibe/scripts/trash-review.py"
[ -f "$DIR/ledger.jsonl" ] && [ -f "$REVIEW" ] || exit 0
OUT=$(python3 "$REVIEW" nudge 2>/dev/null) || exit 0
[ -n "$OUT" ] || exit 0

MSG="## Trash review due

${OUT}

Do this now, before other work, in the main thread. If nobody is there to answer, leave the items pending and skip the procedure.
1. \`python3 ~/.megavibe/scripts/trash-review.py pending --json > <scratchpad>/trash-pending.jsonl\`
2. Spawn one Agent with \`model: \"haiku\"\`: read that file and group the items (by project, cwd, path prefix and kind) into at most 8 groups. Per group: a short label, what it is, total size, the ids, and a recommendation (restore / keep / backup / droppable) with one line of reason. Regenerable output (build dirs, node_modules, caches, test fixtures it created) leans droppable; anything that looks like work — notes, reviews, audits, reports, data, code not in git — leans keep or backup, never droppable.
3. Write the groups as {\"groups\": [{\"label\": \"...\", \"ids\": [...]}]} and run \`python3 ~/.megavibe/scripts/trash-review.py group <file>\`. It prints one summary line per group, starting with its code ([G...]).
4. Ask the user with AskUserQuestion: one question per group (at most 4 per call), with that group's summary line, what it is and the recommendation; options Restore / Keep in Trash / Back up ($(python3 "$REVIEW" backup-dir 2>/dev/null)) / Mark droppable (it stays in the Trash until the user approves the emptying in step 6, or empties it in Finder), the recommended one first. Then write {\"decisions\": [{\"group\": \"G...\", \"action\": \"restore|keep|backup|droppable\"}]} from the answers and run \`python3 ~/.megavibe/scripts/trash-review.py apply <file>\`. Nothing in this step deletes; droppable items stay in the Trash until step 6.
5. Report what was restored, backed up and marked droppable, what failed, and the droppable total from \`trash-review.py status\`.
6. If \`python3 ~/.megavibe/scripts/trash-review.py status\` reports droppable items, tell the user how many and how big they are, and offer to free them by running exactly \`~/.megavibe/scripts/trash-empty.sh\` (that spelling only: no \`bash\`, no \`\$HOME\`, no variable prefix, no other command in the same call). Claude Code then asks the user for permission, on the phone too; their answer is the decision. Never add \`--all\` (it empties the whole Trash) unless the user asked for exactly that. If the prompt is denied, do nothing else and do not retry; the user can empty the Trash in Finder."

jq -n --arg msg "$MSG" --arg line "megavibe: $OUT Review queued." \
  '{systemMessage: $line, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}'
exit 0
