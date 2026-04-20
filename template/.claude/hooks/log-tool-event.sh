#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures,
# especially during parallel tool calls where multiple instances race.
# Capture and report errors instead of crashing with unhelpful "hook error".
_hook_error() {
  local msg="log-tool-event.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  jq -n --arg msg "$msg" '{systemMessage: $msg}' 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — log every tool event to .agent/LOGS/tool-events.jsonl
# Also: nudge Claude if .agent/ context files haven't been updated recently,
# nag if post-compaction re-hydration hasn't happened yet,
# and trigger proactive compaction when context exceeds token threshold.
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
# Tiered proactive-compaction thresholds (escalating urgency).
# Calibrated against Claude Code's built-in auto-compact at ~83.5% of window
# (~835K on 1M), and against megavibe's own research (150K–300K = orange,
# 300K+ = red). Each tier fires AT MOST once per session until a higher tier
# is crossed; the tier counter resets after an actual compaction event.
COMPACT_TIER1=100000   # 🟡 advisory
COMPACT_TIER2=250000   # 🟠 urgent
COMPACT_TIER3=500000   # 🔴 critical (auto-compact approaching)
TOKEN_COOLDOWN_SECS=300

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

  # Clear rehydration flag ONLY if the canonical session-scoped WORKING_CONTEXT was written.
  # A stray .agent/WORKING_CONTEXT.md or project-root WORKING_CONTEXT.md must NOT clear the flag —
  # block-stray-working-context.sh blocks those at PreToolUse, but defend in depth.
  if [[ "$FILE_PATH" =~ /\.agent/sessions/[^/]+/WORKING_CONTEXT\.md$ ]] && [ -f "$REHYDRATE_FLAG" ]; then
    rm -f "$REHYDRATE_FLAG" 2>/dev/null || true
  fi

  # Background-index the file via poma-memory (pip preferred, bundled fallback)
  if command -v poma-memory &>/dev/null; then
    poma-memory index --file "$FILE_PATH" &>/dev/null &
  elif [ -f "$HOME/.megavibe/poma_memory.py" ]; then
    PYCMD=$(cat "$HOME/.megavibe/python-cmd" 2>/dev/null || echo "python3")
    "$PYCMD" "$HOME/.megavibe/poma_memory.py" index --file "$FILE_PATH" &>/dev/null &
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
  if command -v poma-memory &>/dev/null; then
    poma-memory index --file "$FILE_PATH" &>/dev/null &
  elif [ -f "$HOME/.megavibe/poma_memory.py" ]; then
    PYCMD=$(cat "$HOME/.megavibe/python-cmd" 2>/dev/null || echo "python3")
    "$PYCMD" "$HOME/.megavibe/poma_memory.py" index --file "$FILE_PATH" &>/dev/null &
  fi
  # Don't exit — still need to count this tool call
fi

# Only count implementation calls toward the nudge threshold.
# Read-heavy exploration (Grep, Glob, Read) shouldn't trigger "stale context" nudges.
IMPL_TOOL=0
case "$TOOL_NAME" in
  Edit|MultiEdit|Write|Bash|NotebookEdit) IMPL_TOOL=1 ;;
esac

# Increment counter atomically using flock (only for implementation tools)
COUNT=0
if [ "$IMPL_TOOL" -eq 1 ]; then
  (
    flock -x 200 2>/dev/null
    COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$COUNTER_FILE"
  ) 200>"${COUNTER_FILE}.lock" 2>/dev/null || true
fi

# Re-read counter after flock (the subshell variable doesn't propagate)
COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")

# --- Proactive compaction: tiered escalating nudges ---
# Runs on EVERY PostToolUse. Fires at most once per tier per session, so the
# user/Claude sees escalating warnings as context grows (100K → 250K → 500K)
# instead of a single advisory message that gets ignored.
#
# The post-compact grace period uses .compact-ts.${SID} (stamped by
# on-pre-compact.sh and on-compact.sh). This hook only READS that file to
# know "compaction just happened"; it does NOT write to it. Tier tracking
# lives in .compact-tier.${SID} (independent).
COMPACT_NUDGE=""
COOLDOWN_TS_FILE="${LOGDIR}/.compact-ts.${SID}"
COMPACT_TIER_FILE="${LOGDIR}/.compact-tier.${SID}"
IN_COOLDOWN=0
if [ -f "$COOLDOWN_TS_FILE" ]; then
  LAST_COMPACT_TS=$(cat "$COOLDOWN_TS_FILE" 2>/dev/null || echo "0")
  NOW_TS=$(date +%s)
  ELAPSED=$((NOW_TS - LAST_COMPACT_TS))
  [ "$ELAPSED" -lt "$TOKEN_COOLDOWN_SECS" ] 2>/dev/null && IN_COOLDOWN=1
fi

# Reset tier tracking when a compaction just happened — post-compact context
# starts fresh, so tier 1 should fire again as it refills.
if [ "$IN_COOLDOWN" -eq 1 ] && [ -f "$COMPACT_TIER_FILE" ]; then
  echo "0" > "$COMPACT_TIER_FILE" 2>/dev/null || true
fi

if [ "$IN_COOLDOWN" -eq 0 ]; then
  TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    TOTAL_TOKENS=$(tail -100 "$TRANSCRIPT_PATH" 2>/dev/null \
      | grep 'input_tokens' \
      | tail -1 \
      | jq '(.message.usage.input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0)' 2>/dev/null \
      || echo "0")
    TOTAL_TOKENS="${TOTAL_TOKENS:-0}"

    # Determine current tier (highest threshold exceeded)
    CURRENT_TIER=0
    [ "$TOTAL_TOKENS" -gt "$COMPACT_TIER1" ] 2>/dev/null && CURRENT_TIER=1
    [ "$TOTAL_TOKENS" -gt "$COMPACT_TIER2" ] 2>/dev/null && CURRENT_TIER=2
    [ "$TOTAL_TOKENS" -gt "$COMPACT_TIER3" ] 2>/dev/null && CURRENT_TIER=3

    LAST_TIER=$(cat "$COMPACT_TIER_FILE" 2>/dev/null || echo "0")
    LAST_TIER="${LAST_TIER:-0}"

    if [ "$CURRENT_TIER" -gt "$LAST_TIER" ] 2>/dev/null; then
      case "$CURRENT_TIER" in
        1) COMPACT_NUDGE="🟡 Context at ~${TOTAL_TOKENS} tokens (tier 1 / 100K advisory). When the current task wraps, flush pending decisions, tasks, and lessons to .agent/ files (FULL_CONTEXT.md, DECISIONS.md, TASKS.md, LESSONS.md) and run /compact. Doing it early keeps post-compact recovery clean." ;;
        2) COMPACT_NUDGE="🟠 Context at ~${TOTAL_TOKENS} tokens (tier 2 / 250K urgent). Flush now: write ALL pending context to .agent/ files, then run /compact before starting the next non-trivial operation. Quality degrades in this range and post-compact recovery ONLY has what's on disk." ;;
        3) COMPACT_NUDGE="🔴 Context at ~${TOTAL_TOKENS} tokens (tier 3 / 500K critical). COMPACT IMMEDIATELY. Claude Code's built-in auto-compaction fires at ~835K on a 1M window — if it triggers before you flush, the summary is all post-compact Claude will see. Write every pending thought to .agent/ files NOW, then /compact." ;;
      esac
      echo "$CURRENT_TIER" > "$COMPACT_TIER_FILE" 2>/dev/null || true

      # If FULL_CONTEXT.md is large, also hint at /prune-context.
      # Distinct from /compact: /prune-context trims redundant lines from the
      # durable .agent/FULL_CONTEXT.md log via AI. Tier-gated so wc -l runs
      # at most once per tier per session.
      FC_LINES_NUDGE=$(wc -l < .agent/FULL_CONTEXT.md 2>/dev/null | tr -d ' ' || echo "0")
      FC_LINES_NUDGE="${FC_LINES_NUDGE:-0}"
      if [ "$FC_LINES_NUDGE" -gt 500 ] 2>/dev/null; then
        COMPACT_NUDGE="${COMPACT_NUDGE}
🧹 FULL_CONTEXT.md is ${FC_LINES_NUDGE} lines — after flushing, consider /prune-context (AI-driven line removal on the durable log; distinct from /compact)."
      fi
    fi
  fi
fi

# --- Build nudge message if needed ---
NUDGE_MSG=""

# Post-compact grace period: on-compact.sh stamps .compact-ts.$SID. For the
# first TOKEN_COOLDOWN_SECS (default 300s / 5 min) after that, suppress both
# the threshold nudge AND the rehydrate nag. Rationale: right after compact,
# Claude is running /rehydrate, which touches many files before it writes
# WORKING_CONTEXT.md. Without the grace period, every tool call inside
# /rehydrate would get double-yelled-at (stale context + rehydration pending).
POST_COMPACT_GRACE=0
if [ "$IN_COOLDOWN" -eq 1 ]; then
  POST_COMPACT_GRACE=1
fi

# Threshold nudge (first hit) — suppressed during post-compact grace
if [ "$POST_COMPACT_GRACE" -eq 0 ]; then
  if [ "$COUNT" -eq "$NUDGE_THRESHOLD" ] 2>/dev/null; then
    NUDGE_MSG="⚠️ $COUNT tool calls since last .agent/ update. Write current state to FULL_CONTEXT.md, DECISIONS.md, and TASKS.md now."
  # Repeat nudge
  elif [ "$COUNT" -gt "$NUDGE_THRESHOLD" ] 2>/dev/null && [ $((COUNT % NUDGE_REPEAT)) -eq 0 ] 2>/dev/null; then
    NUDGE_MSG="⚠️ $COUNT tool calls without .agent/ update. Context files are going stale — write to them NOW or rehydration will have nothing to work with."
  fi
fi

# Re-hydration nag (appended to nudge if both apply) — suppressed during grace
if [ -f "$REHYDRATE_FLAG" ] && [ "$POST_COMPACT_GRACE" -eq 0 ]; then
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

# Append compact nudge if triggered
if [ -n "$COMPACT_NUDGE" ]; then
  if [ -n "$NUDGE_MSG" ]; then
    NUDGE_MSG="${NUDGE_MSG}
${COMPACT_NUDGE}"
  else
    NUDGE_MSG="$COMPACT_NUDGE"
  fi
fi

# --- Update notification: alert running sessions when megavibe was updated ---
UPDATE_APPLIED_FILE="$HOME/.megavibe/.update-applied"
if [ -f "$UPDATE_APPLIED_FILE" ] && [ -n "${MEGAVIBE_LAUNCH_VERSION:-}" ] && [ "$MEGAVIBE_LAUNCH_VERSION" != "unknown" ]; then
  NEW_VER=$(cat "$UPDATE_APPLIED_FILE" 2>/dev/null || echo "")
  if [ -n "$NEW_VER" ] && [ "$NEW_VER" != "$MEGAVIBE_LAUNCH_VERSION" ]; then
    # Show once per session (flag in session-scoped dir)
    SESSION_DIR=".agent/sessions/${SID}"
    SEEN_FLAG="${SESSION_DIR}/.update-nudge-seen"
    if [ ! -f "$SEEN_FLAG" ]; then
      mkdir -p "$SESSION_DIR" 2>/dev/null || true
      touch "$SEEN_FLAG" 2>/dev/null || true
      UPDATE_MSG="⚡ Megavibe was updated (new version available). Run /megavibe-restart to apply (updates hooks, rules, skills, then resumes this conversation). Or finish your current task first — no rush."
      if [ -n "$NUDGE_MSG" ]; then
        NUDGE_MSG="${NUDGE_MSG}
${UPDATE_MSG}"
      else
        NUDGE_MSG="$UPDATE_MSG"
      fi
    fi
  fi
fi

# Emit nudge as systemMessage (authoritative — Claude treats it as system-level instruction)
if [ -n "$NUDGE_MSG" ]; then
  jq -n --arg msg "$NUDGE_MSG" '{systemMessage: $msg}' 2>/dev/null || true
fi
