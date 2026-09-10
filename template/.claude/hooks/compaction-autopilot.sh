#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  echo "compaction-autopilot.sh failed at line $1: $2" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — make the pre-compaction close-out happen by itself.
# Triggered by: PostToolUse (all tools) and Stop.
#
# The problem this exists for, measured on one real session: at 86% context
# NOTHING Claude-facing had fired. The 50/75/90 tier nudges in log-tool-event.sh
# are gated on the context-watcher being OFF, on the reasoning that the watcher
# keeps .agent/ fresh so tiers would be noise. The watcher was alive, so all
# three suppressed and no tier file was ever created. Only a user-facing ratio
# nudge fired, once, to the human — who then had to ask for the close-out by
# hand.
#
# That suppression conflates two different things. The watcher keeps the
# NARRATIVE fresh: it auto-flushes events all session. It cannot do the
# SYNTHESIS — structured DECISIONS entries with the reasoning, a TASKS table
# saying who each open item is blocked on, a close-out summary. Only the session
# can write those. So this hook is deliberately EXEMPT from the watcher rule.
#
# Two stages, because forcing should be the last resort:
#
#   SOFT  (>= MEGAVIBE_CLOSEOUT_SOFT_PCT, default 85) — PostToolUse
#         additionalContext. Lands on the very next tool call, so it reaches a
#         working session immediately rather than waiting for a turn boundary.
#         Repeats every REMIND_EVERY tool calls while un-answered, because one
#         line mid-flight is easy to scroll past.
#
#   HARD  (>= MEGAVIBE_CLOSEOUT_HARD_PCT, default 95) — Stop hook returning
#         decision:"block". That refuses to end the turn and hands back the
#         close-out instruction. Verified against the 2.1.266 binary: `decision`
#         - "block" for PostToolUse/Stop/UserPromptSubmit hooks, with `reason`
#         as the explanation. Only at 95, because a hook that can stop a session
#         ending is the most dangerous thing in this repo — at that point the
#         alternative is losing the context anyway.
#
# THE BLOCK IS BOUNDED THREE WAYS, and all three must hold or a session could
# become unable to finish:
#   1. stop_hook_active in the input — the harness sets it once a Stop hook has
#      already blocked. "return success while it's true" is the documented
#      contract, so we exit 0 immediately.
#   2. A once-per-session flag file. Blocking twice is a loop, not a reminder.
#   3. Any failure to measure = no block. Silence is never grounds for forcing.
#
# The session signals it is done by writing .closeout-done.<sid>, which
# agent-log.sh does NOT do for it — the session writes it deliberately after the
# synthesis, so "I logged something" cannot be mistaken for "I closed out".
#
# Opt out entirely with MEGAVIBE_CLOSEOUT=0.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
[ "${MEGAVIBE_CLOSEOUT:-1}" != "0" ] || exit 0

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null) || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
SID="${SID:-default}"

LOGDIR=".agent/LOGS"
mkdir -p "$LOGDIR" 2>/dev/null || true
DONE_FLAG="${LOGDIR}/.closeout-done.${SID}"
BLOCKED_FLAG="${LOGDIR}/.closeout-blocked.${SID}"
COUNT_FILE="${LOGDIR}/.closeout-count.${SID}"

# Already closed out this session: nothing to do on any event.
[ -f "$DONE_FLAG" ] && exit 0

SOFT_PCT="${MEGAVIBE_CLOSEOUT_SOFT_PCT:-85}"
HARD_PCT="${MEGAVIBE_CLOSEOUT_HARD_PCT:-95}"
REMIND_EVERY="${MEGAVIBE_CLOSEOUT_REMIND_EVERY:-25}"
case "$SOFT_PCT" in ''|*[!0-9]*) SOFT_PCT=85 ;; esac
case "$HARD_PCT" in ''|*[!0-9]*) HARD_PCT=95 ;; esac
case "$REMIND_EVERY" in ''|*[!0-9]*) REMIND_EVERY=25 ;; esac

# --- measure, fresh, every time -------------------------------------------
# Not the .token-mark file: on the session that motivated this hook, that mark
# said 75% while the statusline said 86%, because it only updates on certain
# tool events. Reading the transcript here costs one tail and is never stale.
PCT=0
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TOKENS=$(tail -100 "$TRANSCRIPT" 2>/dev/null \
    | grep 'input_tokens' | tail -1 \
    | jq '(.message.usage.input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0)' 2>/dev/null || echo 0)
  TOKENS="${TOKENS:-0}"
  # Effective window, cached by statusline.sh from the harness's own
  # context_window_size — the transcript's model field strips the [1m] suffix,
  # so it cannot tell a 1M session from a 200K one.
  CTX=$(cat "${LOGDIR}/.ctx-size.${SID}" 2>/dev/null || echo 0)
  case "$CTX" in ''|*[!0-9]*) CTX=0 ;; esac
  case "$TOKENS" in ''|*[!0-9]*) TOKENS=0 ;; esac
  [ "$CTX" -gt 0 ] && [ "$TOKENS" -gt 0 ] && PCT=$(( TOKENS * 100 / CTX ))
fi
# Could not measure → do nothing at all. Never force on a guess.
[ "$PCT" -gt 0 ] || exit 0

# --- REHYDRATE comes first, always -----------------------------------------
# Sequencing, deliberate: right after a compaction the window is nearly empty,
# so the close-out thresholds cannot be met and these two can never contend for
# the same Stop. The precedence is stated anyway, because "they cannot collide"
# is exactly the assumption that stops being true after someone tunes a
# threshold. Rehydrate wins; if it fires, this hook does nothing else.
#
# on-compact.sh sets .needs-rehydration when the working context is stale;
# log-tool-event.sh clears it the moment WORKING_CONTEXT.md is written. So the
# flag being gone is proof the work happened, not a promise that it will.
REHYDRATE_FLAG="${LOGDIR}/.needs-rehydration.${SID}"
R_NUDGE="${LOGDIR}/.rehydrate-nudge.${SID}"
R_BLOCKED="${LOGDIR}/.rehydrate-blocked.${SID}"
REHYDRATE_TASK='Run /rehydrate NOW, before anything else. The last compaction
left the working context stale, and every answer until it is rebuilt is guesswork
dressed as recall.'

if [ -f "$REHYDRATE_FLAG" ]; then
  if [ "$EVENT" = "PostToolUse" ]; then
    if [ ! -f "$R_NUDGE" ]; then
      : > "$R_NUDGE" 2>/dev/null || true
      jq -n --arg c "$REHYDRATE_TASK" \
        '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$c}}' 2>/dev/null || true
    fi
    exit 0
  fi
  if [ "$EVENT" = "Stop" ]; then
    ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || ACTIVE="true"
    [ "$ACTIVE" = "true" ] && exit 0
    # Only escalate once the soft nudge has actually been delivered. Blocking on
    # the first Stop after a compaction would fire before /rehydrate has had a
    # single turn to run — and it spawns Gemini or Codex, which takes one.
    [ -f "$R_NUDGE" ] || exit 0
    [ -f "$R_BLOCKED" ] && exit 0
    : > "$R_BLOCKED" 2>/dev/null || true
    jq -n --arg r "$REHYDRATE_TASK" '{decision:"block", reason:$r}' 2>/dev/null || true
    exit 0
  fi
  exit 0
fi

CLOSEOUT_TASK='Wrap up for compaction NOW, before doing anything else:
1. Append the decisions of this session to .agent/DECISIONS.md — each with the
   reasoning, so nobody re-derives it. Not a list of what changed.
2. Update .agent/TASKS.md with what is still open and WHO each item is blocked
   on.
3. Write one close-out summary via .claude/hooks/agent-log.sh append: what
   shipped, what was corrected, what the next session must not re-derive.
4. Then run: touch .agent/LOGS/.closeout-done.'"${SID}"'
The context watcher keeps the narrative fresh but cannot do this synthesis.'

# --- HARD: Stop hook, refuse to end the turn ------------------------------
if [ "$EVENT" = "Stop" ] && [ "$PCT" -ge "$HARD_PCT" ]; then
  # The harness sets this once a Stop hook has already blocked. Documented
  # contract: return success while it is true. Ignoring it is how a session
  # becomes unable to end.
  ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || ACTIVE="true"
  [ "$ACTIVE" = "true" ] && exit 0
  [ -f "$BLOCKED_FLAG" ] && exit 0          # once per session, never a loop
  : > "$BLOCKED_FLAG" 2>/dev/null || true
  jq -n --arg r "Context is at ${PCT}%. ${CLOSEOUT_TASK}" \
    '{decision:"block", reason:$r}' 2>/dev/null || true
  exit 0
fi

# --- SOFT: PostToolUse, lands on the next tool call -----------------------
if [ "$EVENT" = "PostToolUse" ] && [ "$PCT" -ge "$SOFT_PCT" ]; then
  N=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
  case "$N" in ''|*[!0-9]*) N=0 ;; esac
  if [ "$N" -eq 0 ] || [ $(( N % REMIND_EVERY )) -eq 0 ]; then
    jq -n --arg c "Context is at ${PCT}% (soft threshold ${SOFT_PCT}%). ${CLOSEOUT_TASK}" \
      '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$c}}' 2>/dev/null || true
  fi
  echo $(( N + 1 )) > "$COUNT_FILE" 2>/dev/null || true
fi

exit 0
