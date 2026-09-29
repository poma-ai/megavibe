#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
trap 'exit 0' ERR
set -u

# Megavibe — tell the session when the disk is nearly full
# Triggered by: SessionStart (matcher: "startup|resume")
#
# Silent unless free space is below the warn threshold (default 15 GB; see
# scripts/disk-watch.sh). One bounded `df` when the disk is fine, so it costs nothing.
# Opt out: MEGAVIBE_DISK_WATCH=0.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
[ "${MEGAVIBE_DISK_WATCH:-1}" = "0" ] && exit 0

SCRIPT="${HOME:-}/.megavibe/scripts/disk-watch.sh"
[ -x "$SCRIPT" ] || exit 0

OUT=$(bash "$SCRIPT" check 2>/dev/null) || exit 0
[ -n "$OUT" ] || exit 0

MSG="## Low disk space

${OUT}

Rules while space is short:
- Say so to the user before starting anything that writes gigabytes: datasets, model weights, virtualenvs, builds, worktrees, screenshots.
- Do not empty the Trash and do not delete files you did not create; the sizes above are for the user to decide on. With rmtrash installed, deleting most files moves them to the Trash and frees no space until the user empties it (temp directories and node_modules are removed for real).
- For a long job, arm a heartbeat: Monitor on \`~/.megavibe/scripts/disk-watch.sh watch\` prints only when space moves by 1 GB or a threshold is crossed."

# additionalContext reaches the model; systemMessage is the line the user sees.
jq -n --arg msg "$MSG" --arg line "$(printf '%s' "$OUT" | head -1)" \
  '{systemMessage: $line, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $msg}}'
