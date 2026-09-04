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
#
# ⚠️ MORATORIUM (self-audit 2026-04-20): this hook already carries six
# independent concerns (logging, staleness counter, three compact tiers,
# rehydrate nag, update-applied alert, task-progress events) across ~280
# lines. It fires on every tool call. Any seventh concern goes in its own
# hook file — do not pile further into this one.

# Only run if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require jq — exit silently if missing (don't block Claude)
command -v jq &>/dev/null || exit 0

LOGDIR=".agent/LOGS"
NUDGE_THRESHOLD=8
NUDGE_REPEAT=20
# Tiered proactive-compaction nudges (escalating urgency). Tier values are
# computed at runtime as 50% / 75% / 90% of the model's effective auto-compact
# threshold (set by the megavibe launcher via CLAUDE_CODE_AUTO_COMPACT_WINDOW;
# clamps to model-native context). This guarantees all tiers fire BEFORE the
# harness compacts, regardless of model size (1M Opus vs 200K Sonnet/Haiku).
# Each tier fires AT MOST once per session until a higher tier is crossed;
# the tier counter resets after an actual compaction event.
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

# --- Cross-tool rehydrate-flag clear (defense in depth) ---
# The Edit/Write branch below clears the flag when Claude writes the canonical
# WORKING_CONTEXT via the Write tool. But /rehydrate's curl fallback redirects
# jq output into the file (Bash), which produces no Write event. Generic fix:
# if the canonical file exists and is newer than the flag, rehydration
# happened — clear regardless of which tool wrote it. Two stats per call.
SESSION_WC=".agent/sessions/${SID}/WORKING_CONTEXT.md"
if [ -f "$REHYDRATE_FLAG" ] && [ -s "$SESSION_WC" ] && [ "$SESSION_WC" -nt "$REHYDRATE_FLAG" ]; then
  rm -f "$REHYDRATE_FLAG" 2>/dev/null || true
fi

# --- Generic mtime-based reset ---
# Catches writes to .agent/*.md by any tool, not just Edit/Write. Bash
# heredocs (`cat >> .agent/FULL_CONTEXT.md <<EOF`), `tee -a`, multi-line
# scripts, and any other write path leave the file's mtime newer than the
# counter file. Treat that as "context just got flushed". Excludes
# .agent/LOGS/ so the hook's own JSONL writes don't reset the counter.
MTIME_RESET=0
if [ -f "$COUNTER_FILE" ]; then
  NEWEST_AGENT_MD=$(find .agent -name '*.md' -not -path '.agent/LOGS/*' -newer "$COUNTER_FILE" -print -quit 2>/dev/null)
  if [ -n "$NEWEST_AGENT_MD" ]; then
    MTIME_RESET=1
    (
      flock -x 200 2>/dev/null
      echo "0" > "$COUNTER_FILE"
    ) 200>"${COUNTER_FILE}.lock" 2>/dev/null || echo "0" > "$COUNTER_FILE" 2>/dev/null || true
  fi
fi

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

  # Background-index the file via poma-memory (pip-installed).
  # Skip .agent/LOGS/ — audit trail (rehydration-instructions, flag files,
  # per-session counters); indexing it makes old "CONTEXT WAS JUST COMPACTED"
  # text resurface via augment-search.sh as if it were a live nag.
  if command -v poma-memory &>/dev/null && [[ "$FILE_PATH" != *"/.agent/LOGS/"* ]]; then
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

# Also index .agent/ files on Read (keeps search index warm for augment-search hook).
# Skip .agent/LOGS/ — see rationale in the write branch above.
if [[ "$TOOL_NAME" == "Read" ]] && [[ "$FILE_PATH" == *".agent/"*".md" ]] && [[ "$FILE_PATH" != *"/.agent/LOGS/"* ]]; then
  if command -v poma-memory &>/dev/null; then
    poma-memory index --file "$FILE_PATH" &>/dev/null &
  fi
  # Don't exit — still need to count this tool call
fi

# Only count implementation calls toward the nudge threshold.
# Read-heavy exploration (Grep, Glob, Read) shouldn't trigger "stale context" nudges.
IMPL_TOOL=0
case "$TOOL_NAME" in
  Edit|MultiEdit|Write|Bash|NotebookEdit) IMPL_TOOL=1 ;;
esac

# Increment counter atomically using flock (only for implementation tools).
# Skip if mtime-reset already fired — this call IS the writer, don't re-bump
# it back above zero on the very same invocation.
COUNT=0
if [ "$IMPL_TOOL" -eq 1 ] && [ "$MTIME_RESET" -eq 0 ]; then
  (
    flock -x 200 2>/dev/null
    COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$COUNTER_FILE"
  ) 200>"${COUNTER_FILE}.lock" 2>/dev/null || true
fi

# Re-read counter after flock (the subshell variable doesn't propagate)
COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")

# --- Proactive compaction: tiered escalating nudges + user ratio nudge ---
# Runs on EVERY PostToolUse. Two distinct paths now:
#   (a) Claude-facing tier nudges (50/75/90% of harness threshold) — only
#       when the context-watcher is OFF; otherwise the watcher keeps
#       .agent/ fresh and tier nudges become noise.
#   (b) User-facing stderr nudge (the "ratio nudge") — fires once per
#       session when the watcher IS on but context has grown faster than
#       the watcher can keep up with (>400K tokens AND token-gain-per-hour
#       to agent-write-per-hour ratio is poor). The statusline already
#       shows token usage continuously, so this is rare and informational.
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

# Watcher gate: if the context-watcher daemon is alive for this session
# (named tmux session 'mvw-<sid>'), it is keeping .agent/ files fresh
# between turns and Claude doesn't need in-session nudges to flush.
# Suppress tier nudges entirely when watcher is active — they become noise
# without value. The user can still see context size in the statusline.
# When watcher is OFF (opted-out or prerequisites missing), tier nudges
# remain the safety net.
WATCHER_ACTIVE=0
if command -v tmux >/dev/null 2>&1 && tmux has-session -t "mvw-${SID}" 2>/dev/null; then
  WATCHER_ACTIVE=1
fi

if [ "$IN_COOLDOWN" -eq 0 ] && [ "$WATCHER_ACTIVE" -eq 0 ]; then
  TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    TOTAL_TOKENS=$(tail -100 "$TRANSCRIPT_PATH" 2>/dev/null \
      | grep 'input_tokens' \
      | tail -1 \
      | jq '(.message.usage.input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0)' 2>/dev/null \
      || echo "0")
    TOTAL_TOKENS="${TOTAL_TOKENS:-0}"

    # Read effective context size cached by statusline.sh (which gets it
    # straight from Claude Code's stdin: .context_window.context_window_size).
    # Transcript model field strips the [1m] suffix so we cannot detect 1M
    # from there; the statusline JSON is the only reliable source.
    EFFECTIVE_CTX=0
    CTX_FILE=".agent/LOGS/.ctx-size.${SID}"
    if [ -f "$CTX_FILE" ]; then
      CACHED_CTX=$(cat "$CTX_FILE" 2>/dev/null)
      if [ -n "$CACHED_CTX" ] && [ "$CACHED_CTX" -gt 0 ] 2>/dev/null; then
        EFFECTIVE_CTX=$CACHED_CTX
      fi
    fi

    # Effective threshold = min(launcher WINDOW, model native) - 33K buffer.
    # The harness clamps WINDOW to native context; tiers follow whichever is
    # smaller. Sentinel 0 = "env unset" → use native ctx directly (no
    # megavibe-imposed cap). Used to default to 533000 here; removed because
    # the context-watcher now keeps .agent/ fresh out-of-band, and capping a
    # 1M-context model at 500K wastes half the window.
    COMPACT_WIN="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-0}"

    # Cache missing (statusline hasn't rendered yet for this session): infer
    # from the launcher window. The harness clamps COMPACT_WIN to model-native
    # context, so a >200K window can only mean a 1M-context model. Otherwise
    # assume 200K-native — safe baseline for Sonnet/Haiku without [1m] variant.
    # If COMPACT_WIN is also 0 (no env, no settings), we can't distinguish —
    # default to 1M (Opus is the common 1M case; Sonnet/Haiku 200K users get
    # statusline cache early and self-correct downward below).
    if [ "$EFFECTIVE_CTX" -eq 0 ] 2>/dev/null; then
      if [ "$COMPACT_WIN" -gt 200000 ] 2>/dev/null; then
        EFFECTIVE_CTX=1000000
      elif [ "$COMPACT_WIN" -eq 0 ] 2>/dev/null; then
        EFFECTIVE_CTX=1000000
      else
        EFFECTIVE_CTX=200000
      fi
    fi

    # Empirical self-correct: if observed tokens exceed the supposed window
    # without any auto-compact firing, the cache is provably wrong (model was
    # switched up between sessions, or stdin lacked context_window_size).
    # Trust observation over the cache and bump to 1M. Without this, a stale
    # 200K cache on a 1M-context session triggers tier-3 nudges with
    # nonsensical math like "~0K to auto-compact at ~167K".
    if [ "$TOTAL_TOKENS" -gt "$EFFECTIVE_CTX" ] 2>/dev/null; then
      EFFECTIVE_CTX=1000000
    fi

    # COMPACT_WIN=0 (sentinel for unset) means "no megavibe cap" → use native ctx.
    if [ "$COMPACT_WIN" -gt 0 ] 2>/dev/null; then
      EFFECTIVE_WIN=$(( COMPACT_WIN < EFFECTIVE_CTX ? COMPACT_WIN : EFFECTIVE_CTX ))
    else
      EFFECTIVE_WIN=$EFFECTIVE_CTX
    fi
    THRESHOLD=$(( EFFECTIVE_WIN - 33000 ))
    [ "$THRESHOLD" -lt 50000 ] 2>/dev/null && THRESHOLD=50000  # sanity floor
    THRESHOLD_K=$(( THRESHOLD / 1000 ))
    TOK_K=$(( TOTAL_TOKENS / 1000 ))

    # Runway: positive if room remains, negative if past trigger.
    # When negative, render as "past" rather than clamping to 0 — the
    # latter implies "approaching trigger" which is false and gaslights
    # the user when the harness threshold is clearly higher than ours.
    RUNWAY_K=$(( THRESHOLD_K - TOK_K ))
    if [ "$RUNWAY_K" -lt 0 ] 2>/dev/null; then
      PAST_K=$(( -RUNWAY_K ))
      RUNWAY_DESC="${PAST_K}K past our ~${THRESHOLD_K}K estimate (harness threshold likely higher — no auto-compact yet)"
    else
      RUNWAY_DESC="~${RUNWAY_K}K to auto-compact at ~${THRESHOLD_K}K"
    fi

    # Tier thresholds as % of effective threshold — always fire below it.
    # Ratios 50/75/90: half-way is the earliest yellow, three-quarters urgent,
    # 90% critical. Lower ratios fire too early when there's still real runway.
    COMPACT_TIER1=$(( THRESHOLD * 50 / 100 ))
    COMPACT_TIER2=$(( THRESHOLD * 75 / 100 ))
    COMPACT_TIER3=$(( THRESHOLD * 90 / 100 ))

    # Determine current tier (highest threshold exceeded)
    CURRENT_TIER=0
    [ "$TOTAL_TOKENS" -gt "$COMPACT_TIER1" ] 2>/dev/null && CURRENT_TIER=1
    [ "$TOTAL_TOKENS" -gt "$COMPACT_TIER2" ] 2>/dev/null && CURRENT_TIER=2
    [ "$TOTAL_TOKENS" -gt "$COMPACT_TIER3" ] 2>/dev/null && CURRENT_TIER=3

    LAST_TIER=$(cat "$COMPACT_TIER_FILE" 2>/dev/null || echo "0")
    LAST_TIER="${LAST_TIER:-0}"

    if [ "$CURRENT_TIER" -gt "$LAST_TIER" ] 2>/dev/null; then
      case "$CURRENT_TIER" in
        1) COMPACT_NUDGE="🟡 Context ~${TOK_K}K (advisory). ${RUNWAY_DESC}. Start flushing decisions, tasks, and lessons to .agent/ continuously; every line saved is a recovery line later." ;;
        2) COMPACT_NUDGE="🟠 Context ~${TOK_K}K — ${RUNWAY_DESC}. Flush ALL pending state to .agent/ NOW and run /compact at the next clean break. The threshold is deterministic — it WILL fire." ;;
        3) COMPACT_NUDGE="🔴 Context ~${TOK_K}K — ${RUNWAY_DESC}. /compact NOW. If the harness fires first it picks the moment (likely mid-tool-call); post-compact Claude only sees the summary." ;;
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

# --- User-facing ratio nudge (only when watcher is alive) -----------------
# Fires AT MOST ONCE per session via stderr (visible to user, not folded
# into Claude's context). Triggers when:
#   - total context > 400K tokens AND
#   - tokens-grown-per-hour / agent-writes-per-hour > 100K   (the watcher
#     is being outrun: lots of context coming in, not many durable writes)
# Watcher-off path is covered by the Claude-facing tier nudges above —
# this nudge intentionally doesn't double up.
USER_NUDGE_FIRED="${LOGDIR}/.user-nudge-fired.${SID}"
TOKEN_MARK_FILE="${LOGDIR}/.token-mark.${SID}"  # format: <unix_ts>:<tokens>
if [ "$IN_COOLDOWN" -eq 0 ] && [ "$WATCHER_ACTIVE" -eq 1 ] && [ ! -f "$USER_NUDGE_FIRED" ]; then
  RTRANS=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
  if [ -n "$RTRANS" ] && [ -f "$RTRANS" ]; then
    RTOK=$(tail -100 "$RTRANS" 2>/dev/null \
      | grep 'input_tokens' | tail -1 \
      | jq '(.message.usage.input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0)' 2>/dev/null \
      || echo "0")
    RTOK="${RTOK:-0}"

    # Refresh / read the token-mark window. Older than 60 min → rewrite.
    NOW_TS=$(date +%s)
    OLD_TS=0
    OLD_TOK=0
    if [ -f "$TOKEN_MARK_FILE" ]; then
      MARK=$(cat "$TOKEN_MARK_FILE" 2>/dev/null || echo "0:0")
      OLD_TS=${MARK%:*}
      OLD_TOK=${MARK#*:}
    fi
    AGE_SEC=$((NOW_TS - OLD_TS))
    if [ "$OLD_TS" -eq 0 ] || [ "$AGE_SEC" -gt 3600 ] 2>/dev/null; then
      echo "${NOW_TS}:${RTOK}" > "$TOKEN_MARK_FILE" 2>/dev/null
    fi

    # Only evaluate ratio once we have a mark older than 5 min (otherwise the
    # extrapolation to per-hour is noisy).
    if [ "$RTOK" -gt 400000 ] 2>/dev/null && [ "$AGE_SEC" -gt 300 ] 2>/dev/null; then
      TOK_GAIN=$((RTOK - OLD_TOK))
      # Extrapolate to per-hour. Integer math; clamp to non-negative.
      [ "$TOK_GAIN" -lt 0 ] && TOK_GAIN=0
      TOK_GAIN_HR=$(( TOK_GAIN * 3600 / AGE_SEC ))
      # Count .agent/*.md files modified in the last 60 min (proxy for watcher activity).
      RECENT_WRITES=$(find .agent -name '*.md' -not -path '.agent/LOGS/*' -mmin -60 -print 2>/dev/null | wc -l | tr -d ' ')
      SAFE_WRITES=$(( RECENT_WRITES > 0 ? RECENT_WRITES : 1 ))
      RATIO=$(( TOK_GAIN_HR / SAFE_WRITES ))
      if [ "$RATIO" -gt 100000 ] 2>/dev/null; then
        TOK_K=$(( RTOK / 1000 ))
        GAIN_K=$(( TOK_GAIN_HR / 1000 ))
        # stderr (user-visible), NOT systemMessage — this is for the human,
        # not for Claude to act on. Fire-once via the sentinel file.
        {
          echo ""
          echo "📊 Context at ${TOK_K}K — grew ${GAIN_K}K in the last hour with ${RECENT_WRITES} .agent/ writes."
          echo "   The watcher is being outrun. If this thread of work is winding down,"
          echo "   consider /compact (durable state is in .agent/ — recovery is cheap)."
          echo ""
        } >&2
        touch "$USER_NUDGE_FIRED" 2>/dev/null || true
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

# Threshold nudge (first hit) — suppressed during post-compact grace AND
# when the context-watcher is alive (the watcher writes .agent/ between
# turns; nagging Claude to flush is redundant and noisy).
if [ "$POST_COMPACT_GRACE" -eq 0 ] && [ "$WATCHER_ACTIVE" -eq 0 ]; then
  if [ "$COUNT" -eq "$NUDGE_THRESHOLD" ] 2>/dev/null; then
    NUDGE_MSG="⚠️ $COUNT tool calls since last .agent/ update. Write current state to FULL_CONTEXT.md, DECISIONS.md, and TASKS.md now."
  # Repeat nudge
  elif [ "$COUNT" -gt "$NUDGE_THRESHOLD" ] 2>/dev/null && [ $((COUNT % NUDGE_REPEAT)) -eq 0 ] 2>/dev/null; then
    NUDGE_MSG="⚠️ $COUNT tool calls without .agent/ update. Context files are going stale — write to them NOW or rehydration will have nothing to work with."
  fi
fi

# Re-hydration nag — suppressed during grace. Capped at REHYDRATE_NAG_MAX
# fires per flag: if Claude has been told 3 times and still hasn't written
# a fresh WORKING_CONTEXT, it's an informed choice (carryover context is
# enough, or the user moved on). Auto-clear after the cap and emit one
# final notice — repeating the same warning on every tool call indefinitely
# is noise, not signal.
REHYDRATE_NAG_MAX=3
if [ -f "$REHYDRATE_FLAG" ] && [ "$POST_COMPACT_GRACE" -eq 0 ]; then
  NAG_COUNT=$(cat "$REHYDRATE_FLAG" 2>/dev/null | tr -d ' \n')
  NAG_COUNT="${NAG_COUNT:-0}"
  REHYDRATE_MSG=""
  if [ "$NAG_COUNT" -ge "$REHYDRATE_NAG_MAX" ] 2>/dev/null; then
    rm -f "$REHYDRATE_FLAG" 2>/dev/null || true
    REHYDRATE_MSG="ℹ️ Rehydration flag auto-cleared after ${REHYDRATE_NAG_MAX} nags. Continuing with carryover context. /rehydrate is still available if you want a fresh WORKING_CONTEXT.md."
  else
    NEW_COUNT=$((NAG_COUNT + 1))
    echo "$NEW_COUNT" > "$REHYDRATE_FLAG" 2>/dev/null || true
    INSTRUCTIONS_FILE=".agent/LOGS/rehydration-instructions.${SID}.md"
    if [ -f "$INSTRUCTIONS_FILE" ]; then
      REHYDRATE_MSG="⚠️ Context was compacted but re-hydration hasn't completed (nag ${NEW_COUNT}/${REHYDRATE_NAG_MAX}). Read ${INSTRUCTIONS_FILE} for instructions, OR ignore if your carryover context is sufficient — flag auto-clears after ${REHYDRATE_NAG_MAX} nags."
    else
      REHYDRATE_MSG="⚠️ Context was compacted but re-hydration hasn't completed (nag ${NEW_COUNT}/${REHYDRATE_NAG_MAX}). Call Gemini/Codex to regenerate WORKING_CONTEXT.md, or ignore if carryover context is enough."
    fi
  fi
  if [ -n "$REHYDRATE_MSG" ]; then
    if [ -n "$NUDGE_MSG" ]; then
      NUDGE_MSG="${NUDGE_MSG}
${REHYDRATE_MSG}"
    else
      NUDGE_MSG="$REHYDRATE_MSG"
    fi
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
