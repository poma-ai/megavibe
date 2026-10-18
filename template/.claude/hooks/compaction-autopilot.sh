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
# The flag stands only while the register checkpoint covers every marked
# decision event. File timestamps do not establish register coverage.
#
# Opt out entirely with MEGAVIBE_CLOSEOUT=0.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
case "${MEGAVIBE_CLOSEOUT-1}" in
  0) exit 0 ;;
  1) ;;
  *) echo "MEGAVIBE_CLOSEOUT: expected 0 or 1" >&2; exit 2 ;;
esac

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null) || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
SID="${SID:-default}"
# The full id, for compact-readiness.sh (its session files are keyed on it).
SID_FULL=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
READY="$(dirname "$0")/compact-readiness.sh"

# A subagent's tool calls (same session_id, agent_id set) must not run the
# PARENT's close-out: they measured the subagent's transcript against the
# parent's window and could tell the subagent to mark the parent closed out.
[ -z "$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)" ] || exit 0

LOGDIR=".agent/LOGS"
mkdir -p "$LOGDIR" 2>/dev/null || true
DONE_FLAG="${LOGDIR}/.closeout-done.${SID}"
BLOCKED_FLAG="${LOGDIR}/.closeout-blocked.${SID}"
COUNT_FILE="${LOGDIR}/.closeout-count.${SID}"

SOFT_PCT="${MEGAVIBE_CLOSEOUT_SOFT_PCT-85}"
HARD_PCT="${MEGAVIBE_CLOSEOUT_HARD_PCT-95}"
REMIND_EVERY="${MEGAVIBE_CLOSEOUT_REMIND_EVERY-25}"
decimal() {
  local value="$2"
  case "$value" in ''|*[!0-9]*) echo "$1: expected a decimal integer" >&2; return 2 ;; esac
  while [ "${value#0}" != "$value" ]; do value="${value#0}"; done
  value="${value:-0}"
  [ "${#value}" -le 6 ] && [ "$value" -gt 0 ] || {
    echo "$1: expected 1..999999" >&2; return 2;
  }
  printf '%s' "$value"
}
SOFT_PCT=$(decimal MEGAVIBE_CLOSEOUT_SOFT_PCT "$SOFT_PCT") || exit 2
HARD_PCT=$(decimal MEGAVIBE_CLOSEOUT_HARD_PCT "$HARD_PCT") || exit 2
REMIND_EVERY=$(decimal MEGAVIBE_CLOSEOUT_REMIND_EVERY "$REMIND_EVERY") || exit 2
[ "$SOFT_PCT" -le 100 ] && [ "$HARD_PCT" -le 100 ] || {
  echo "close-out percentages must be at most 100" >&2; exit 2;
}

# --- REHYDRATE comes first, always -----------------------------------------
# Before the context measurement on purpose: it acts on a flag, not on a guess
# about window size, so a session whose size cannot be read still gets it (it
# used to sit behind the measurement and silently never fire there).
# Sequencing, deliberate: right after a compaction the window is nearly empty,
# so the close-out thresholds cannot be met and these two can never contend for
# the same Stop. The precedence is stated anyway, because "they cannot collide"
# is exactly the assumption that stops being true after someone tunes a
# threshold. Rehydrate wins: when its Stop block fires, this hook does nothing
# else on that event.
#
# on-compact.sh sets .needs-rehydration when the working context is stale;
# log-tool-event.sh clears it the moment WORKING_CONTEXT.md is written. So the
# flag being gone is proof the work happened, not a promise that it will.
REHYDRATE_FLAG="${LOGDIR}/.needs-rehydration.${SID}"
R_BLOCKED="${LOGDIR}/.rehydrate-blocked.${SID}"
REHYDRATE_TASK='Run /rehydrate NOW, before anything else. The last compaction
left the working context stale, and every answer until it is rebuilt is guesswork
dressed as recall.'

# One reminder policy, not two: the soft reminders come from log-tool-event.sh,
# which honours the 5-minute grace window and ignores subagents' tool
# calls. This hook adds only the hard stage: one blocked Stop, and only after at
# least one of those reminders was delivered (its count file exists), so it can
# never fire before /rehydrate has had a turn. After that block the session has
# been told and chose to carry on: stand down. The flag itself stays until a
# WORKING_CONTEXT write clears it, and a pending rehydrate never silences the
# close-out logic below.
R_NAGCOUNT="${LOGDIR}/.rehydrate-nagcount.${SID}"
if [ "$EVENT" = "Stop" ] && [ -f "$REHYDRATE_FLAG" ] && [ ! -f "$R_BLOCKED" ] && [ -s "$R_NAGCOUNT" ]; then
  ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || ACTIVE="true"
  [ "$ACTIVE" = "true" ] && exit 0
  # Block only if the once-only marker was actually written: a marker that
  # cannot be persisted (permissions, full disk) would make this block every
  # turn, and an infrastructure failure must never trap the session.
  OUTPUT=$(printf '%s' "$REHYDRATE_TASK" | jq -Rs '{decision:"block", reason:.}' 2>/dev/null) || exit 0
  [ -n "$OUTPUT" ] || exit 0
  : > "$R_BLOCKED" 2>/dev/null || exit 0
  printf '%s\n' "$OUTPUT"
  exit 0
fi

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

# Probe identity coverage; random suffixes and late arrivals are unordered.
# Reuse a positive probe below instead of scanning the event bodies twice.
REARMED=""
_NEW=0
if [ -f "$DONE_FLAG" ]; then
  [ "$PCT" -ge "$SOFT_PCT" ] || [ "$PCT" -ge "$HARD_PCT" ] || exit 0
  _RC=0
  _NEW=$("$READY" --decisions-since .agent/.registers-checkpoint 2>&1) || _RC=$?
  case "$_NEW" in ''|*[!0-9]*) _RC=2 ;; esac
  if [ "$_RC" -gt 1 ]; then
    # A failed probe is advisory, never grounds to rearm or consume a block.
    if [ "$EVENT" = "Stop" ]; then
      ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || ACTIVE="true"
      [ "$ACTIVE" = "true" ] && exit 0
      [ -f "$BLOCKED_FLAG" ] && exit 0
    fi
    N=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
    case "$N" in ''|*[!0-9]*) N=0 ;; esac
    if [ "$N" -eq 0 ] || [ $(( N % REMIND_EVERY )) -eq 0 ]; then
      printf '%s' "$_NEW" | jq -Rs '{systemMessage:
        ("compact-readiness: unable to check done-flag coverage (ADVISORY); " +
         (split("\n")[0:3] | join(" ") | .[0:500]))}' 2>/dev/null || true
    fi
    echo $(( N + 1 )) > "$COUNT_FILE" 2>/dev/null || true
    exit 0
  fi
  [ "$_NEW" -gt 0 ] || exit 0
  rm -f "$DONE_FLAG" "$COUNT_FILE" 2>/dev/null || true
  REARMED=" The close-out is open again: ${_NEW} marked-decision event(s) after the register checkpoint."
fi

CLOSEOUT_TASK='Wrap up for compaction NOW, before doing anything else:
1. Append the decisions of this session to .agent/DECISIONS.md — each with the
   reasoning, so nobody re-derives it. Not a list of what changed.
2. Update .agent/TASKS.md with what is still open and WHO each item is blocked
   on.
3. Write one close-out summary via .claude/hooks/agent-log.sh append: what
   shipped, what was corrected, what the next session must not re-derive.
4. Run .claude/hooks/compact-readiness.sh and reconcile each [!] item.
   Record coverage with --mark; if register blockers remain after synthesis,
   use --mark --force. Add --staged-handled ROW_ID ... using the exact IDs printed by the check.
   Only after marking succeeds, run:
   touch .agent/LOGS/.closeout-done.'"${SID}"'
The context watcher keeps the narrative fresh but cannot do this synthesis.'"${REARMED}"

# The readiness report, so the nudge says what is missing. `|| true` keeps its
# "not ready" exit status out of this hook's ERR trap.
readiness() {
  local out=""
  if [ -n "$REARMED" ]; then
    printf '\nReadiness now:\ncompact-readiness: NOT READY\n'
    printf '%s\n' "- [!] ${_NEW} marked-decision events after checkpoint: reconcile DECISIONS.md and TASKS.md."
    printf '%s' 'Run compact-readiness.sh for staged rows and background tasks.'
    return 0
  fi
  out=$(printf '%s' "$INPUT" | "$READY" ${SID_FULL:+--session "$SID_FULL"} --hook-input - 2>&1) || true
  [ -n "$out" ] || out="compact-readiness: unable to check (no report)"
  [ -n "$out" ] && printf '\nReadiness now:\n%s' "$out"
  return 0
}

# --- HARD: Stop hook, refuse to end the turn ------------------------------
if [ "$EVENT" = "Stop" ] && [ "$PCT" -ge "$HARD_PCT" ]; then
  # The harness sets this once a Stop hook has already blocked. Documented
  # contract: return success while it is true. Ignoring it is how a session
  # becomes unable to end.
  ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || ACTIVE="true"
  [ "$ACTIVE" = "true" ] && exit 0
  [ -f "$BLOCKED_FLAG" ] && exit 0          # once per session, never a loop
  OUTPUT=$(printf '%s' "Context is at ${PCT}%. ${CLOSEOUT_TASK}$(readiness)" |
    jq -Rs '{decision:"block", reason:.}' 2>/dev/null) || exit 0
  [ -n "$OUTPUT" ] || exit 0
  : > "$BLOCKED_FLAG" 2>/dev/null || exit 0
  printf '%s\n' "$OUTPUT"
  exit 0
fi

# --- SOFT: PostToolUse, lands on the next tool call -----------------------
if [ "$EVENT" = "PostToolUse" ] && [ "$PCT" -ge "$SOFT_PCT" ]; then
  N=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
  case "$N" in ''|*[!0-9]*) N=0 ;; esac
  if [ "$N" -eq 0 ] || [ $(( N % REMIND_EVERY )) -eq 0 ]; then
    printf '%s' "Context is at ${PCT}% (soft threshold ${SOFT_PCT}%). ${CLOSEOUT_TASK}$(readiness)" |
      jq -Rs '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:.}}' 2>/dev/null || true
  fi
  echo $(( N + 1 )) > "$COUNT_FILE" 2>/dev/null || true
fi

exit 0
