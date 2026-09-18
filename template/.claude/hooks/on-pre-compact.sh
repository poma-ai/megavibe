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
# - Drop this session's read-delta cache, whose rows would otherwise claim
#   that file content survived the compaction that is about to drop it
#   (see the SID note at that block: the two hooks must agree on the name)
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

# --- Invalidate the read-delta re-Read cache ---
# read-delta.sh answers a re-Read of an unchanged file with a stub saying the
# content is "already in your context above". Compaction is exactly the event
# that makes that false: the earlier Read leaves the context window while the
# cache row survives, so the next Read of that file would hand back a stub
# pointing at content nobody has. Dropping this session's rows costs one full
# re-read and nothing else. PreCompact is the only hook that fires for both
# manual and automatic compaction, which is why it lives here.
#
# read-delta.sh sanitises the id before it reaches a filename; $SID above is
# NOT sanitised, because other per-session files written here are read back
# by log-tool-event.sh under the unsanitised name. So derive read-delta's
# form separately, and delete both spellings: the two hooks agreeing is what
# makes the invalidation work, and deleting a cache that is not there costs
# nothing while missing one costs a false stub.
RD_SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | tr -cd 'A-Za-z0-9-' | cut -c1-12)
RD_SID="${RD_SID:-default}"
for _rd_sid in "$RD_SID" "$SID"; do
  rm -f "${LOGDIR}/read-cache.${_rd_sid}.jsonl" 2>/dev/null || true
  rm -f "${LOGDIR}"/read-stub."${_rd_sid}".*.txt 2>/dev/null || true
  # ...and the pre-fix stub name, which has no agent segment for that glob
  # to match. One file per project, but it is never cleaned up otherwise.
  rm -f "${LOGDIR}/read-stub.${_rd_sid}.txt" 2>/dev/null || true
  # The once-per-session "payload shape moved" flag belongs to that cache.
  rm -f "${LOGDIR}/.read-delta-shape.${_rd_sid}" 2>/dev/null || true
done

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

After compaction, your only required action is: run /rehydrate (single command — it regenerates WORKING_CONTEXT.md via Codex, the Claude subagent, then Gemini). A 5-minute post-compact grace period suppresses stale-context nags while /rehydrate runs, so you won't get double-yelled-at during recovery. On auto-compactions the on-compact hook will additionally inline git state + DECISIONS/TASKS/LESSONS in its systemMessage — on manual /compact that orientation lives in this compaction summary instead."

# --- Optional /prune-context hint (appended only if FULL_CONTEXT.md is large) ---
# Distinct from /compact: /prune-context trims redundant lines from the
# durable .agent/FULL_CONTEXT.md log. Keeps future rehydrations focused.
PRUNE_THRESHOLD=500
if [ "$FC_LINES" -gt "$PRUNE_THRESHOLD" ] 2>/dev/null; then
  MSG="$MSG

🧹 FULL_CONTEXT.md is ${FC_LINES} lines (above the ${PRUNE_THRESHOLD}-line pruning threshold). After /rehydrate, consider running /prune-context to let Codex (or the chain behind it) selectively remove redundant or superseded entries. This is distinct from /compact: /compact summarizes the live conversation, /prune-context cleans the durable .agent/FULL_CONTEXT.md log."
fi

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
