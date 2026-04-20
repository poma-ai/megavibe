#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="on-pre-compact.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — pre-compaction context flush reminder + grace-period stamper
# Triggered by: PreCompact (fires on BOTH auto-compact AND manual /compact)
#
# IMPORTANT: Claude does NOT get a turn between this hook and compaction.
# The systemMessage here becomes part of the compaction summary — it tells
# the post-compaction Claude whether context files were stale and what to
# run next.
#
# Strategy:
# - Read the tool-call counter to assess staleness
# - Stamp .compact-ts.$SID and .needs-rehydration.$SID so post-compact
#   log-tool-event.sh honors the grace period even on manual /compact
#   (SessionStart:compact only fires on AUTO-compaction, so on-compact.sh
#   cannot be relied on to stamp these files — PreCompact is the only
#   hook that reliably fires for both manual and automatic compactions)
# - Emit a systemMessage noting what may be lost and the single required
#   post-compact action (/rehydrate) — per D79, /catchup is folded inline

# Only run if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
SID="${SID:-default}"

LOGDIR=".agent/LOGS"
COUNTER_FILE="${LOGDIR}/.tool-call-counter.${SID}"

mkdir -p "$LOGDIR" 2>/dev/null || true

# --- Stamp the grace-period cooldown and rehydration flag ---
# log-tool-event.sh reads .compact-ts.$SID to suppress both the 8-call
# stale-context nudge and the rehydrate-pending nag for TOKEN_COOLDOWN_SECS
# (default 300s). on-compact.sh ALSO stamps this on auto-compaction, but
# stamping here guarantees manual /compact also gets the grace window.
date +%s > "${LOGDIR}/.compact-ts.${SID}" 2>/dev/null || true
# Mark that rehydration is needed. on-compact.sh normally sets this too,
# but it won't fire for manual /compact — so we set it here as the floor.
touch "${LOGDIR}/.needs-rehydration.${SID}" 2>/dev/null || true

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

After compaction, your only required action is: run /rehydrate (single command — it regenerates WORKING_CONTEXT.md via Gemini/Codex). A 5-minute post-compact grace period suppresses stale-context nags while /rehydrate runs, so you won't get double-yelled-at during recovery. On auto-compactions the on-compact hook will additionally inline git state + DECISIONS/TASKS/LESSONS in its systemMessage — on manual /compact that orientation lives in this compaction summary instead."

# --- User-visible alert ---
# The systemMessage below is folded into the compaction summary, so the user
# never sees it as a standalone turn. To prove the hook ran, we ALSO:
#   1. Write a durable alert file the user can tail/grep
#   2. Echo the report to stderr (Claude Code surfaces hook stderr to the user)
ALERT_FILE="${LOGDIR}/pre-compact-alert.${SID}.md"
{
  echo "# Pre-compact alert — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "$MSG"
} > "$ALERT_FILE" 2>/dev/null || true

# Echo to stderr — visible to the user in the Claude Code UI
echo "" >&2
echo "═══════════════════════════════════════════════════════════════" >&2
echo "$MSG" >&2
echo "" >&2
echo "(saved to $ALERT_FILE)" >&2
echo "═══════════════════════════════════════════════════════════════" >&2
echo "" >&2

jq -n --arg msg "$MSG" '{systemMessage: $msg}' 2>/dev/null || true
