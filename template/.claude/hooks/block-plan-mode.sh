#!/bin/bash
# DO NOT use set -e — exit 2 = block, exit 0 = allow, exit 1 = hook error.
set -u

# Megavibe — block TaskCreate / TaskUpdate / EnterPlanMode
# These tools trigger unbypassable permission prompts that break autonomous execution.
# LESSONS.md: "User lost 1h to this."
# Runs in ALL projects (safety is always good).

TOOL_NAME="${TOOL_NAME:-}"

# If TOOL_NAME isn't set (shouldn't happen for PreToolUse), parse from stdin
if [ -z "$TOOL_NAME" ]; then
  command -v jq &>/dev/null || exit 0
  INPUT=$(cat)
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
fi

case "$TOOL_NAME" in
  TaskCreate|TaskUpdate|EnterPlanMode)
    cat <<'JSON'
{"decision":"block","reason":"Plan mode tools (TaskCreate/TaskUpdate/EnterPlanMode) are blocked by megavibe. They trigger unbypassable permission prompts that break autonomous execution. Track work in .agent/TASKS.md instead."}
JSON
    exit 2
    ;;
esac

exit 0
