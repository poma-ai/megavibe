#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
# jq or file operations can fail on edge cases; the hook must still emit output.
_hook_error() {
  local msg="on-compact.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  jq -n --arg msg "$msg" '{systemMessage: $msg}' 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — auto re-hydrate context after compaction
# Triggered by: SessionStart (matcher: "compact")
# Only acts when source === "compact" (Claude Code auto-compacted the context)
#
# Strategy:
# - Always inject: DECISIONS.md + TASKS.md + LESSONS.md (structured, small)
# - FULL_CONTEXT.md < 10KB: also inject raw (no AI needed)
# - FULL_CONTEXT.md >= 10KB: inject rehydration instructions for Claude to
#   call Gemini MCP → GEMINI_API_KEY curl → Codex MCP → Claude subagent (fallback chain)
#
# Improvements over v1:
# - LESSONS.md injected (was missing)
# - Raw FULL_CONTEXT for small files (was never injected)
# - No-cliff rule: Gemini output >= input size or 400 lines, whichever smaller
# - Source-of-truth guard: always compact from raw FULL_CONTEXT.md, not old WC
# - poma-memory search suggestion for targeted context augmentation
#
# CRITICAL: Gemini must always read raw .agent/FULL_CONTEXT.md from disk
# (the append-only source of truth), NEVER from a previous WORKING_CONTEXT.md.
#
# Session isolation: rehydration flag and WORKING_CONTEXT are session-scoped.

# Redirect stderr to debug log (avoids confusing Claude Code's hook capture)
exec 2>".agent/LOGS/on-compact-debug.log" 2>/dev/null || exec 2>/dev/null

# Only act if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

mkdir -p ".agent/LOGS"

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // ""')

# Only act on compaction events
[ "$SOURCE" = "compact" ] || exit 0

echo "on-compact.sh fired at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2

# Extract session ID for scoping
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' | cut -c1-12)
SESSION_DIR=".agent/sessions/${SID}"
mkdir -p "$SESSION_DIR"

WC_PATH="${SESSION_DIR}/WORKING_CONTEXT.md"
INSTRUCTIONS_FILE=".agent/LOGS/rehydration-instructions.${SID}.md"

# WC freshness gate: if /rehydrate ran within the last hour, the existing
# WORKING_CONTEXT is still useful and post-compact orientation injection is
# enough. Setting the rehydration flag here would just spawn a sticky nag
# that fires on every tool call until Claude *re-runs* /rehydrate — which
# Claude won't do if it (correctly) decides carryover context is sufficient.
# Skip the flag in that case; user can still invoke /rehydrate voluntarily.
WC_FRESH=0
if [ -f "$WC_PATH" ]; then
  WC_MTIME=$(stat -f %m "$WC_PATH" 2>/dev/null || stat -c %Y "$WC_PATH" 2>/dev/null || echo 0)
  NOW_TS=$(date +%s)
  WC_AGE=$(( NOW_TS - WC_MTIME ))
  [ "$WC_AGE" -lt 3600 ] 2>/dev/null && WC_FRESH=1
fi

# --- Read structured files (always small, always injected) ---
DECISIONS=$(cat .agent/DECISIONS.md 2>/dev/null || echo "(empty)")
TASKS=$(cat .agent/TASKS.md 2>/dev/null || echo "(empty)")
LESSONS=$(cat .agent/LESSONS.md 2>/dev/null || echo "(empty)")

# --- Inline /catchup: git state + pre-compact WORKING_CONTEXT (if any) ---
# Folding catchup into the hook means post-compact Claude only has to run
# one slash command (/rehydrate). The catchup skill is still available for
# session-start orientation.
GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "(unknown)")
GIT_LOG=$(git log --oneline -10 2>/dev/null || echo "(no commits)")
GIT_DIFF_STAT=$(git diff --stat 2>/dev/null || echo "")
[ -z "$GIT_DIFF_STAT" ] && GIT_DIFF_STAT="(clean — no uncommitted changes)"

GIT_STATE="--- Git state ---
Branch: ${GIT_BRANCH}
Recent commits:
${GIT_LOG}
Uncommitted changes:
${GIT_DIFF_STAT}"

# Pre-compact WORKING_CONTEXT may still exist from before /compact fired.
# It's stale (compaction summary is now the source of truth) but useful as
# a what-was-I-doing hint. Truncate to 80 lines to avoid bloating the inject.
OLD_WC=""
if [ -f "$WC_PATH" ]; then
  OLD_WC_BODY=$(head -80 "$WC_PATH" 2>/dev/null || echo "")
  if [ -n "$OLD_WC_BODY" ]; then
    OLD_WC="--- Pre-compact WORKING_CONTEXT.md (first 80 lines, stale hint only) ---
${OLD_WC_BODY}"
  fi
fi

# --- Check FULL_CONTEXT.md size ---
FULL_CONTEXT_SIZE=$(wc -c < .agent/FULL_CONTEXT.md 2>/dev/null || echo "0")
FULL_CONTEXT_SIZE=$(echo "$FULL_CONTEXT_SIZE" | tr -d ' ')
FULL_CONTEXT_LINES=$(wc -l < .agent/FULL_CONTEXT.md 2>/dev/null || echo "0")
FULL_CONTEXT_LINES=$(echo "$FULL_CONTEXT_LINES" | tr -d ' ')

echo "FULL_CONTEXT: ${FULL_CONTEXT_SIZE} bytes, ${FULL_CONTEXT_LINES} lines" >&2

# --- Build additionalContext based on size ---

if [ "$FULL_CONTEXT_LINES" -le 10 ]; then
  # === BOOTSTRAP: .agent/ files are empty ===
  echo "Strategy: bootstrap (empty .agent/ files)" >&2
  [ "$WC_FRESH" -eq 0 ] && touch ".agent/LOGS/.needs-rehydration.${SID}"

  CONTEXT="⚠️ CONTEXT WAS JUST COMPACTED — .agent/ FILES ARE EMPTY

Session: ${SID}
WORKING_CONTEXT path: ${WC_PATH}

The .agent/ context files were never populated during this session. The
compaction summary above is your ONLY source of context. Before continuing:

1. IMMEDIATELY write a summary of the compaction above to .agent/FULL_CONTEXT.md
   (append after the header). Include: goal, key decisions, files changed,
   current state, what was being worked on.
2. Update .agent/DECISIONS.md with any decisions from the summary.
3. Update .agent/TASKS.md with pending tasks from the summary.
4. Then run /rehydrate — this is your only required slash command. It will
   regenerate ${WC_PATH} via Gemini/Codex (full AI-powered recovery).

DO NOT skip steps 1–3. The compaction summary will be lost if you don't
externalize it now. Orientation (git state + /catchup equivalent) is inlined
below so you do NOT need to run /catchup separately.

${GIT_STATE}

--- DECISIONS.md ---
${DECISIONS}

--- TASKS.md ---
${TASKS}

--- LESSONS.md ---
${LESSONS}"

elif [ "$FULL_CONTEXT_SIZE" -lt 10240 ]; then
  # === SMALL: inject raw FULL_CONTEXT directly (no AI needed) ===
  echo "Strategy: raw injection (${FULL_CONTEXT_SIZE} bytes < 10KB)" >&2
  FULL_CONTEXT=$(cat .agent/FULL_CONTEXT.md 2>/dev/null || echo "")

  CONTEXT="✅ CONTEXT WAS COMPACTED — orientation below. Your only required action is /rehydrate.

Session: ${SID}
WORKING_CONTEXT path: ${WC_PATH}
FULL_CONTEXT on disk: .agent/FULL_CONTEXT.md (${FULL_CONTEXT_LINES} lines, ${FULL_CONTEXT_SIZE} bytes — small enough to inline below)

## Post-compact recovery

Run /rehydrate — it regenerates ${WC_PATH} via the Gemini/Codex fallback
chain (full AI-powered recovery). That is the ONLY slash command you need
to type; the catchup-equivalent (git state + .agent/ files) is inlined
below so you already have the information /catchup would have produced.

Do /rehydrate BEFORE resuming any other work. Until it completes,
stale-context nags are suppressed for ~5 minutes so you get a clean window.

${GIT_STATE}

--- DECISIONS.md ---
${DECISIONS}

--- TASKS.md ---
${TASKS}

--- LESSONS.md ---
${LESSONS}

${OLD_WC}

--- FULL_CONTEXT.md (raw) ---
${FULL_CONTEXT}"

else
  # === NORMAL: instruct Claude to call Gemini/Codex for focused summary ===
  echo "Strategy: rehydration instructions (${FULL_CONTEXT_SIZE} bytes, ${FULL_CONTEXT_LINES} lines, wc_fresh=${WC_FRESH})" >&2
  [ "$WC_FRESH" -eq 0 ] && touch ".agent/LOGS/.needs-rehydration.${SID}"

  if [ "$WC_FRESH" -eq 1 ]; then
    REHYDRATE_HINT="Your prior WORKING_CONTEXT (${WC_PATH}) was written within the last hour
and is likely still valid. Treat it as your source of truth — running
/rehydrate now is OPTIONAL. If you decide carryover context is enough,
just continue working; no nag will fire."
  else
    REHYDRATE_HINT="Run /rehydrate — it regenerates ${WC_PATH} via the Gemini/Codex fallback
chain (full AI-powered recovery). Do /rehydrate BEFORE resuming any other
work. Until it completes, stale-context nags are suppressed for ~5 minutes
so you get a clean window."
  fi

  CONTEXT="⚠️ CONTEXT WAS JUST COMPACTED

Session: ${SID}
WORKING_CONTEXT path: ${WC_PATH}
FULL_CONTEXT on disk: .agent/FULL_CONTEXT.md (${FULL_CONTEXT_LINES} lines, ${FULL_CONTEXT_SIZE} bytes — the append-only source of truth, too large to inline)
Durable backup of these instructions: ${INSTRUCTIONS_FILE}

## Post-compact recovery

${REHYDRATE_HINT}

Orientation (git state + structured .agent/ files) is inlined below so
/catchup is not needed separately.

${GIT_STATE}

--- DECISIONS.md ---
${DECISIONS}

--- TASKS.md ---
${TASKS}

--- LESSONS.md ---
${LESSONS}

${OLD_WC}"
fi

# --- Record cooldown for proactive compaction ---
# log-tool-event.sh checks this timestamp to suppress nudges post-compaction
date +%s > ".agent/LOGS/.compact-ts.${SID}" 2>/dev/null || true

# --- Write durable backup (in case systemMessage injection fails) ---
cat > "$INSTRUCTIONS_FILE" << INSTREOF
$CONTEXT
INSTREOF
echo "Wrote rehydration instructions to ${INSTRUCTIONS_FILE}" >&2

echo "Emitting systemMessage (${#CONTEXT} chars)" >&2

# Return as systemMessage (authoritative — Claude treats it as system-level instruction)
jq -n --arg msg "$CONTEXT" '{systemMessage: $msg}'
