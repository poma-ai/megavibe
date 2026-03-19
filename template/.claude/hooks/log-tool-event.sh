#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures,
# especially during parallel tool calls where multiple instances race.
set -uo pipefail

# Megavibe — log every tool event to .agent/LOGS/tool-events.jsonl
# Also: nudge Claude if .agent/ context files haven't been updated recently,
# and nag if post-compaction re-hydration hasn't happened yet.
#
# Triggered by: PostToolUse (all tools), PostToolUseFailure (Bash)
# Input: hook stdin JSON (tool_name, tool_input, tool_response, etc.)
#
# Session isolation: counter, rehydration flag, and tool-events log are
# scoped per session_id to prevent races between concurrent sessions.
#
# Concurrency safety: flock is used for atomic counter operations.
# JSONL logging is best-effort — failures must not block the nudge path.

# Only run if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require jq — exit silently if missing (don't block Claude)
command -v jq &>/dev/null || exit 0

LOGDIR=".agent/LOGS"
NUDGE_THRESHOLD=8
NUDGE_REPEAT=20

mkdir -p "$LOGDIR" 2>/dev/null || true

# Read stdin, extract session ID for scoping
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
SID="${SID:-default}"

# Session-scoped paths (prevent concurrent session races)
LOGFILE="${LOGDIR}/tool-events.${SID}.jsonl"
COUNTER_FILE="${LOGDIR}/.tool-call-counter.${SID}"
REHYDRATE_FLAG="${LOGDIR}/.needs-rehydration.${SID}"

# --- Best-effort JSONL logging (must NOT abort the nudge path) ---
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
echo "$INPUT" | jq -c --arg ts "$TIMESTAMP" '. + {logged_at: $ts}' >> "$LOGFILE" 2>/dev/null || true

# --- Context freshness nudge (the CRITICAL path) ---
# Check if this tool call was itself a write to .agent/*.md (reset counter if so)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")

if [[ "$TOOL_NAME" =~ ^(Edit|Write)$ ]] && [[ "$FILE_PATH" == *".agent/"*".md" ]]; then
  # Claude just wrote to a context file — reset counter atomically
  (
    flock -x 200 2>/dev/null
    echo "0" > "$COUNTER_FILE"
  ) 200>"${COUNTER_FILE}.lock" 2>/dev/null || echo "0" > "$COUNTER_FILE" 2>/dev/null || true

  # Clear rehydration flag if WORKING_CONTEXT was written
  if [[ "$FILE_PATH" == *"WORKING_CONTEXT.md" ]] && [ -f "$REHYDRATE_FLAG" ]; then
    rm -f "$REHYDRATE_FLAG" 2>/dev/null || true
  fi

  # Background-index the file via poma-memory (bundled or pip-installed)
  POMA_SCRIPT="$HOME/.megavibe/poma_memory.py"
  if [ -f "$POMA_SCRIPT" ]; then
    python3 "$POMA_SCRIPT" index --file "$FILE_PATH" &>/dev/null &
  elif command -v poma-memory &>/dev/null; then
    poma-memory index --file "$FILE_PATH" &>/dev/null &
  fi

  # --- Event emission for remote bot (replaces ntfy) ---
  # Append structured events to events.jsonl. Bot watches this file.
  # No network calls from hooks — fast, safe, no token exposure.
  if [[ "$FILE_PATH" == *"TASKS.md" ]]; then
    DONE_COUNT=$(grep -cE "\| done" "$FILE_PATH" 2>/dev/null || echo "0")
    TOTAL=$(grep -cE "^\| [0-9R]" "$FILE_PATH" 2>/dev/null || echo "0")
    OPEN=$(grep -cE "\| pending|\| in.progress|\| planned" "$FILE_PATH" 2>/dev/null || echo "0")
    if [ "$DONE_COUNT" -gt 0 ] 2>/dev/null; then
      EVENTS_FILE="$(dirname "$(dirname "$FILE_PATH")")/events.jsonl"
      EVENT_TYPE="task_progress"
      [ "$OPEN" -eq 0 ] 2>/dev/null && EVENT_TYPE="task_complete"
      jq -n --arg type "$EVENT_TYPE" \
        --arg done "$DONE_COUNT" --arg total "$TOTAL" --arg open "$OPEN" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{type: $type, done: ($done|tonumber), total: ($total|tonumber), open: ($open|tonumber), ts: $ts}' \
        >> "$EVENTS_FILE" 2>/dev/null || true
    fi
  fi
  exit 0
fi

# Also index .agent/ files on Read (keeps search index warm for augment-search hook)
if [[ "$TOOL_NAME" == "Read" ]] && [[ "$FILE_PATH" == *".agent/"*".md" ]]; then
  POMA_SCRIPT="$HOME/.megavibe/poma_memory.py"
  if [ -f "$POMA_SCRIPT" ]; then
    python3 "$POMA_SCRIPT" index --file "$FILE_PATH" &>/dev/null &
  elif command -v poma-memory &>/dev/null; then
    poma-memory index --file "$FILE_PATH" &>/dev/null &
  fi
  # Don't exit — still need to count this tool call
fi

# Increment counter atomically using flock
COUNT=0
(
  flock -x 200 2>/dev/null
  COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
  COUNT=$((COUNT + 1))
  echo "$COUNT" > "$COUNTER_FILE"
) 200>"${COUNTER_FILE}.lock" 2>/dev/null || true

# Re-read counter after flock (the subshell variable doesn't propagate)
COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")

# --- Build nudge message if needed ---
NUDGE_MSG=""

# Threshold nudge (first hit)
if [ "$COUNT" -eq "$NUDGE_THRESHOLD" ] 2>/dev/null; then
  NUDGE_MSG="⚠️ $COUNT tool calls since last .agent/ update. Write current state to FULL_CONTEXT.md, DECISIONS.md, and TASKS.md now."
# Repeat nudge
elif [ "$COUNT" -gt "$NUDGE_THRESHOLD" ] 2>/dev/null && [ $((COUNT % NUDGE_REPEAT)) -eq 0 ] 2>/dev/null; then
  NUDGE_MSG="⚠️ $COUNT tool calls without .agent/ update. Context files are going stale — write to them NOW or rehydration will have nothing to work with."
fi

# Re-hydration nag (appended to nudge if both apply)
if [ -f "$REHYDRATE_FLAG" ]; then
  INSTRUCTIONS_FILE=".agent/LOGS/rehydration-instructions.${SID}.md"
  if [ -f "$INSTRUCTIONS_FILE" ]; then
    REHYDRATE_MSG="⚠️ Context was compacted but re-hydration hasn't completed. Read ${INSTRUCTIONS_FILE} for full instructions (Gemini MCP → GEMINI_API_KEY fallback → Codex)."
  else
    REHYDRATE_MSG="⚠️ Context was compacted but re-hydration hasn't completed. Call Gemini (or use \$GEMINI_API_KEY via curl, or Codex) to regenerate WORKING_CONTEXT.md."
  fi
  if [ -n "$NUDGE_MSG" ]; then
    NUDGE_MSG="${NUDGE_MSG}
${REHYDRATE_MSG}"
  else
    NUDGE_MSG="$REHYDRATE_MSG"
  fi
fi

# Emit nudge as additionalContext if there's a message
if [ -n "$NUDGE_MSG" ]; then
  jq -n --arg ctx "$NUDGE_MSG" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}' 2>/dev/null || true
fi
