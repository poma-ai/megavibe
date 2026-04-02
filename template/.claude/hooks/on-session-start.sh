#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
# Safety net: non-blocking hooks must NEVER exit non-zero (causes "hook error" noise).
trap 'exit 0' EXIT
set -u

# Megavibe — auto-orient on fresh session start
# Triggered by: SessionStart (matcher: "startup")
#
# Injects project knowledge (LESSONS + DECISIONS) on every session start.
# Task state is NOT injected automatically — the user runs /catchup for that.

# Only act if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // ""')

# Only act on fresh startup (not compact — that's handled by on-compact.sh)
[ "$SOURCE" = "startup" ] || exit 0

# Check if project has real context
DECISIONS_LINES=$(wc -l < ".agent/DECISIONS.md" 2>/dev/null || echo "0")
DECISIONS_LINES=$(echo "$DECISIONS_LINES" | tr -d ' ')
LESSONS_LINES=$(wc -l < ".agent/LESSONS.md" 2>/dev/null || echo "0")
LESSONS_LINES=$(echo "$LESSONS_LINES" | tr -d ' ')

# If nothing to orient with, skip silently
[ "$DECISIONS_LINES" -gt 5 ] || [ "$LESSONS_LINES" -gt 5 ] || exit 0

# Extract session ID
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' | cut -c1-12)

# Check for open tasks to tailor the message
OPEN_TASKS=$(grep -cE "\| pending|\| in.progress" ".agent/TASKS.md" 2>/dev/null || echo "0")
OPEN_TASKS=$(echo "$OPEN_TASKS" | tr -d ' ')

if [ "$OPEN_TASKS" -gt 0 ] 2>/dev/null; then
  TASK_HINT="There are ${OPEN_TASKS} open task(s) from previous work. Use \`/catchup\` to review them, or start your new task — project knowledge is loaded below."
else
  TASK_HINT="All previous tasks are complete. Project knowledge is loaded below — ready for a new task."
fi

# --- poma-memory: search for context related to open tasks ---
POMA_CONTEXT=""
if [ "$OPEN_TASKS" -gt 0 ] 2>/dev/null && [ -f ".agent/.poma-memory.db" ]; then
  # Find poma-memory command (pip preferred, bundled fallback)
  POMA_CMD=""
  if command -v poma-memory &>/dev/null; then
    POMA_CMD="poma-memory"
  elif [ -f "$HOME/.megavibe/poma_memory.py" ]; then
    PYCMD=$(cat "$HOME/.megavibe/python-cmd" 2>/dev/null || echo "python3")
    POMA_CMD="$PYCMD $HOME/.megavibe/poma_memory.py"
  fi

  if [ -n "$POMA_CMD" ]; then
    # Extract open task names as search terms
    TASK_TERMS=$(grep -E "\| pending|\| in.progress" ".agent/TASKS.md" 2>/dev/null \
      | sed 's/|/\n/g' | sed -n '3p' | tr -d '[:space:]' | head -c 200)
    if [ -n "$TASK_TERMS" ]; then
      POMA_RESULTS=$($POMA_CMD search "$TASK_TERMS" --path .agent/ --top-k 5 2>/dev/null || echo "")
      if [ -n "$POMA_RESULTS" ] && [ "$POMA_RESULTS" != "No results found." ]; then
        POMA_CONTEXT="
--- poma-memory: context related to open tasks ---
${POMA_RESULTS}"
      fi
    fi
  fi
fi

CONTEXT="## Megavibe — project knowledge

Your session ID is: ${SID}
WORKING_CONTEXT path: .agent/sessions/${SID}/WORKING_CONTEXT.md

${TASK_HINT}

--- LESSONS.md ---
$(cat .agent/LESSONS.md 2>/dev/null || echo '(empty)')

--- DECISIONS.md (last 20 lines) ---
$(tail -20 .agent/DECISIONS.md 2>/dev/null || echo '(empty)')${POMA_CONTEXT}"

# Emit as systemMessage (authoritative — Claude treats it as system-level instruction)
jq -n --arg msg "$CONTEXT" '{systemMessage: $msg}'
