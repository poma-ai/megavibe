#!/bin/bash
# DO NOT use set -e — exit 2 = block, exit 0 = allow, exit 1 = hook error.
set -u

# Megavibe — block writes to WORKING_CONTEXT.md outside .agent/sessions/{sid}/
# The protocol requires session-scoping (CLAUDE.md "Session isolation"), but
# Claude drifts and occasionally writes .agent/WORKING_CONTEXT.md or even
# <project>/WORKING_CONTEXT.md. These stray files poison rehydration:
# log-tool-event.sh matches "*WORKING_CONTEXT.md" and silently clears the
# rehydrate flag, so the wrong location satisfies the hook without fixing anything.
#
# Runs on Write|Edit|MultiEdit. No-op when jq is missing (graceful).

command -v jq &>/dev/null || exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")

case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
[ -z "$FILE_PATH" ] && exit 0

# Only care about files literally named WORKING_CONTEXT.md
BASENAME="${FILE_PATH##*/}"
[ "$BASENAME" = "WORKING_CONTEXT.md" ] || exit 0

# Allow the canonical session-scoped path: anything ending in /.agent/sessions/<sid>/WORKING_CONTEXT.md
# Reject everything else (project root, .agent/WORKING_CONTEXT.md, .agent/sessions/WORKING_CONTEXT.md, etc.)
if [[ "$FILE_PATH" =~ /\.agent/sessions/[^/]+/WORKING_CONTEXT\.md$ ]]; then
  exit 0
fi

# Try to extract session_id from hook stdin for a helpful suggested path
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | cut -c1-11)
if [ -n "$SESSION_ID" ]; then
  SUGGESTED=".agent/sessions/${SESSION_ID}/WORKING_CONTEXT.md"
else
  SUGGESTED=".agent/sessions/{session_id}/WORKING_CONTEXT.md"
fi

REASON="WORKING_CONTEXT.md is session-scoped. Write to ${SUGGESTED} instead (see CLAUDE.md \"Session isolation\"). Attempted path: ${FILE_PATH}. Concurrent sessions corrupt a shared WORKING_CONTEXT, and a stray file at the wrong path silently satisfies the rehydration hook without fixing context."

jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
exit 2
