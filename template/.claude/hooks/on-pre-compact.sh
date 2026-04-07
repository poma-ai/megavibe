#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="on-pre-compact.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — pre-compaction context flush reminder
# Triggered by: PreCompact
#
# IMPORTANT: Claude does NOT get a turn between this hook and compaction.
# The systemMessage here becomes part of the compaction summary — it tells
# the post-compaction Claude whether context files were stale.
#
# Strategy:
# - Read the tool-call counter to assess staleness
# - Emit a systemMessage noting what may be lost
# - The compaction summarizer includes this in its summary
# - Post-compact hook (/catchup + /rehydrate) uses this info

# Only run if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
SID="${SID:-default}"

LOGDIR=".agent/LOGS"
COUNTER_FILE="${LOGDIR}/.tool-call-counter.${SID}"

# How stale is the context?
COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")

# Check which .agent/ files have content
FC_LINES=$(wc -l < .agent/FULL_CONTEXT.md 2>/dev/null || echo "0")
FC_LINES=$(echo "$FC_LINES" | tr -d ' ')
TASKS_LINES=$(wc -l < .agent/TASKS.md 2>/dev/null || echo "0")
TASKS_LINES=$(echo "$TASKS_LINES" | tr -d ' ')
DECISIONS_LINES=$(wc -l < .agent/DECISIONS.md 2>/dev/null || echo "0")
DECISIONS_LINES=$(echo "$DECISIONS_LINES" | tr -d ' ')
LESSONS_LINES=$(wc -l < .agent/LESSONS.md 2>/dev/null || echo "0")
LESSONS_LINES=$(echo "$LESSONS_LINES" | tr -d ' ')

MSG="📋 COMPACTION IS ABOUT TO HAPPEN — CONTEXT FILE STATUS:
- FULL_CONTEXT.md: ${FC_LINES} lines
- TASKS.md: ${TASKS_LINES} lines
- DECISIONS.md: ${DECISIONS_LINES} lines
- LESSONS.md: ${LESSONS_LINES} lines
- Tool calls since last .agent/ write: ${COUNT}

⚠️ If ${COUNT} is high, context accumulated in this conversation may NOT be in the .agent/ files yet. The post-compaction recovery will only have what's on disk.

After compaction, you will be instructed to run /catchup then /rehydrate to recover full context."

jq -n --arg msg "$MSG" '{systemMessage: $msg}' 2>/dev/null || true
