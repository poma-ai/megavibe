#!/usr/bin/env bash
# gemini-review.sh — a Gemini review/summary call that actually comes back.
#
# Why not the MCP tool or `gemini -p`:
#   Gemini 3.x Flash thinks by default, and the Gemini CLI (which gemini-mcp
#   wraps) hardcodes the thinking mode with no setting to lower it. Measured
#   2026-09-06 on gemini-3.8-flash with a 9K-token review prompt: default
#   thinking spent 15,362 thought tokens and returned 318 tokens of text before
#   hitting an 8,000 cap (39,493 thoughts at a 32,000 cap — still truncated);
#   `thinkingLevel: low` returned the complete review in 6 seconds. The CLI's
#   multi-minute "hangs" in the watcher and /rehydrate are the same effect.
#   This script calls the API directly, so it can set the level.
#
# Usage:
#   scripts/gemini-review.sh [--as-reviewer] [--pro] [--level low|medium|high]
#                            [--max N] [--out FILE] --prompt "text" FILE...
#   scripts/gemini-review.sh ... --prompt-file PROMPT.md FILE...
#
# Files are appended to the prompt as "===== path =====" blocks. Output: the
# model's text on stdout; with --out, the text goes there and the raw JSON to
# FILE.raw.json for audit (without --out nothing is left behind).
# --as-reviewer marks this call as one of non-negotiable 4's reviews, and is the
# ONLY mode MEGAVIBE_REVIEWERS gates: without it this is just megavibe's general
# Gemini path (/rehydrate, summaries, large context), which no reviewer setting
# should be able to switch off.
#
# Exit 0 on a complete answer, 3 if the answer was cut off (MAX_TOKENS), 4 if
# asked to review while gemini is off in MEGAVIBE_REVIEWERS, 1 on API/network
# error. Never retries more than once (megavibe rule).
#
# Model: gemini-flash-latest by default (≈$0.04 per 50K-token review on the
# paid key). --pro = gemini-3.1-pro-preview at thinkingLevel medium (≈$0.15);
# use it for reviews of protocol/template changes and anything user-facing.
# Needs a key from a BILLED project in $GEMINI_API_KEY — the free tier is
# 20 requests/day and trains on prompts.

set -euo pipefail

# Measured 2026-09-10: default is now the pinned gemini-3.1-flash-lite (cheapest
# non-deprecated tier). NOT the `gemini-flash-lite-latest` alias — it answered with
# no text part at all in testing, so it is unreliable for scripted use; pinned
# lite versions (3.1, 3.5) both answer correctly with thinkingLevel.
# gemini-flash-latest still resolves to gemini-3.8-flash if you want the bigger model.
# (the current Pro line; answered live that day). Both accept thinkingConfig.thinkingLevel.
# If Google moves the alias to a model that rejects the field, the API returns 400 and
# this script exits 1 with the message — re-check `models?key=` and adjust MODEL/--pro.
MODEL="gemini-3.1-flash-lite"; LEVEL="low"; MAX=16000; OUT=""; PROMPT=""; PROMPT_FILE=""
# --auto: review on the cheap model, escalate to Pro only when warranted.
#
# Self-reported confidence is deliberately NOT the only gate. A model that misses
# a blocker does not know it missed it — confidence tracks fluency, not accuracy,
# so "no findings, confidence 0.95" is exactly the failure this is meant to catch.
# Escalation therefore fires on ANY of four signals, three of which do not depend
# on the model's own introspection:
#   1. it reported a blocker/major finding      (its findings, not its confidence)
#   2. self-reported confidence below threshold (weakest signal; a tiebreak only)
#   3. it reported partial coverage, or emitted no parseable verdict at all
#   4. the INPUT is high-stakes by deterministic file match — fires even when the
#      cheap model says everything is fine
AS_REVIEWER=""
AUTO=""; MIN_CONF="0.75"; PRO_MODEL="gemini-3.1-pro-preview"; PRO_LEVEL="medium"
FILES=()
need(){ [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --as-reviewer) AS_REVIEWER=1; shift ;;
    --pro)         MODEL="$PRO_MODEL"; LEVEL="$PRO_LEVEL"; shift ;;
    --auto)        AUTO=1; shift ;;
    --min-conf)    need "$@"; MIN_CONF="$2"; shift 2 ;;
    --model)       need "$@"; MODEL="$2"; shift 2 ;;
    --level)       need "$@"; LEVEL="$2"; shift 2 ;;
    --max)         need "$@"; MAX="$2"; shift 2 ;;
    --out)         need "$@"; OUT="$2"; shift 2 ;;
    --prompt)      need "$@"; PROMPT="$2"; shift 2 ;;
    --prompt-file) need "$@"; PROMPT_FILE="$2"; shift 2 ;;
    -h|--help)     sed -n '2,36p' "$0"; exit 0 ;;
    --)            shift; FILES+=("$@"); break ;;
    -*)            echo "unknown arg: $1" >&2; exit 2 ;;
    *)             FILES+=("$1"); shift ;;
  esac
done

# Asked to REVIEW, and this reviewer is switched off? Refuse before spending
# anything. The gate lives here, not only in the protocol text, so an agent that
# calls a disabled reviewer out of habit gets a free no-op instead of a paid
# review the user did not want.
#
# Only under --as-reviewer. This script is also megavibe's general gemini path —
# /rehydrate and /prune-context and every large-context task come through here —
# and MEGAVIBE_REVIEWERS is a statement about reviewing, not about the backend.
# Gating unconditionally would have stripped context recovery of its backend for
# anyone who switched one reviewer off.
_RVDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ -n "$AS_REVIEWER" ] && [ -f "$_RVDIR/reviewers.sh" ]; then
  _rv_rc=0; bash "$_RVDIR/reviewers.sh" enabled gemini >/dev/null 2>&1 || _rv_rc=$?
  # ONLY 1 means "switched off". A helper that crashed, or one from a future
  # version with different exit codes, must not be able to silence a reviewer —
  # non-negotiable 4 fails open.
  if [ "$_rv_rc" -eq 1 ]; then
    echo "skip: gemini is not in MEGAVIBE_REVIEWERS ($(bash "$_RVDIR/reviewers.sh" list 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'))" >&2
    exit 4
  fi
fi

KEY="${GEMINI_API_KEY:-}"
[ -n "$KEY" ] || { echo "error: GEMINI_API_KEY is not set (needs a key from a billed project)" >&2; exit 1; }
[ -n "$PROMPT" ] || [ -n "$PROMPT_FILE" ] || { echo "error: --prompt or --prompt-file is required" >&2; exit 2; }
command -v jq &>/dev/null || { echo "error: jq is required" >&2; exit 1; }
[ -n "$PROMPT_FILE" ] && PROMPT=$(cat -- "$PROMPT_FILE")
[ -n "$(printf '%s' "$PROMPT" | tr -d '[:space:]')" ] || { echo "error: the prompt is empty" >&2; exit 2; }
[ "${#FILES[@]}" -gt 0 ] || echo "note: no files given — sending the prompt alone" >&2

# Assemble the request in a temp file — a 1M-character body must not pass
# through argv. jq -Rs escapes the text exactly.
REQ=$(mktemp -t gemini-req)
if [ -n "$OUT" ]; then RAW="$OUT.raw.json"; KEEP_RAW=1; else RAW=$(mktemp -t gemini-raw); KEEP_RAW=""; fi
trap '[ -n "$KEEP_RAW" ] || rm -f "$RAW"; rm -f "$REQ" "$REQ.txt"' EXIT
AUTO_SUFFIX=''
if [ -n "$AUTO" ]; then
  AUTO_SUFFIX=$(cat <<'SUF'

---
After your review, emit EXACTLY this line last, on its own, nothing after it:

<<<VERDICT severity=SEV confidence=CONF coverage=COV>>>

  SEV   = blocker | major | minor | none   (the most severe issue you actually found)
  CONF  = 0.00-1.00, how confident you are that you found everything that matters
  COV   = full | partial   ("partial" if anything stopped you reviewing properly:
          missing files, truncated input, code you could not follow, or a change
          whose consequences you cannot see from what was provided)

Be honest about partial coverage and about low confidence. A cheap model saying
"none / 1.00" on work it did not fully understand is worse than useless — an
honest "partial" costs one extra call, a false "full" ships a defect.
SUF
)
fi

{
  printf '%s\n' "$PROMPT"
  [ -n "$AUTO_SUFFIX" ] && printf '%s\n' "$AUTO_SUFFIX"
  for f in "${FILES[@]:-}"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] && [ -r "$f" ] || { echo "error: not a readable file: $f" >&2; exit 1; }
    printf '\n\n===== %s =====\n' "$f"; cat -- "$f"
  done
} > "$REQ.txt"
build_req(){ jq -Rs --arg level "$1" --argjson max "$MAX" \
  '{contents:[{parts:[{text:.}]}], generationConfig:{maxOutputTokens:$max, temperature:0.2, thinkingConfig:{thinkingLevel:$level}}}' \
  < "$REQ.txt" > "$REQ"; }
build_req "$LEVEL"

call(){ curl -s --max-time 280 -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent" \
  -H "x-goog-api-key: $KEY" -H 'Content-Type: application/json' --data-binary @"$REQ"; }

BODY=$(call || true)
# One retry only, and only for the transient shapes (empty body, 429, 5xx).
if [ -z "$BODY" ] || printf '%s' "$BODY" | jq -e '.error.code as $c | $c==429 or $c>=500' >/dev/null 2>&1; then
  sleep 5; BODY=$(call || true)
fi
[ -n "$BODY" ] || { echo "error: no response from Gemini (network/throttle)" >&2; exit 1; }
printf '%s' "$BODY" > "$RAW"
printf '%s' "$BODY" | jq -e . >/dev/null 2>&1 || { echo "error: invalid response from Gemini (proxy page or truncated JSON) — raw kept at $RAW" >&2; KEEP_RAW=1; exit 1; }

if printf '%s' "$BODY" | jq -e '.error' >/dev/null 2>&1; then
  echo "error: $(printf '%s' "$BODY" | jq -r '.error.message' | cut -c1-300)" >&2; exit 1
fi
printf '%s' "$BODY" | jq -e '.candidates[0].content.parts' >/dev/null 2>&1 \
  || { echo "error: no answer in the response (blocked or empty) — $(printf '%s' "$BODY" | jq -c '.promptFeedback // .candidates[0].finishReason // empty' | cut -c1-200)" >&2; KEEP_RAW=1; exit 1; }
TEXT=$(printf '%s' "$BODY" | jq -r '[.candidates[0].content.parts[]? | select(.thought != true) | .text // empty] | join("")')
FINISH=$(printf '%s' "$BODY" | jq -r '.candidates[0].finishReason // "?"')
USAGE=$(printf '%s' "$BODY" | jq -r '.usageMetadata | "in=\(.promptTokenCount // "?") out=\(.candidatesTokenCount // "?") thoughts=\(.thoughtsTokenCount // 0)"')
MV=$(printf '%s' "$BODY" | jq -r '.modelVersion // "?"')

if [ -n "$AUTO" ]; then
  V=$(printf '%s' "$TEXT" | grep -oE '<<<VERDICT[^>]*>>>' | tail -1)
  SEV=$(printf '%s' "$V" | grep -oE 'severity=[a-z]+' | cut -d= -f2)
  CONF=$(printf '%s' "$V" | grep -oE 'confidence=[0-9.]+' | cut -d= -f2)
  COV=$(printf '%s' "$V" | grep -oE 'coverage=[a-z]+' | cut -d= -f2)

  # (4) Deterministic high-stakes match on the INPUT — independent of the model.
  # These are the paths where a missed defect is expensive, so they always get
  # the stronger reviewer regardless of how confident the cheap one sounded.
  STAKES=""
  for f in "${FILES[@]:-}"; do
    case "$f" in
      *auth*|*Auth*|*credential*|*secret*|*token*|*passwd*|*password*|*crypto*|*key*.py|\
      *payment*|*billing*|*invoice*|*charge*|*refund*|\
      *migration*|*migrate*|*schema*|*delete*|*destroy*|*drop*|*purge*|\
      *CLAUDE.md|*README*.md|*SKILL.md|*.github/workflows/*)
        STAKES="$f"; break ;;
    esac
  done

  WHY=""
  case "$SEV" in blocker|major) WHY="found a $SEV finding" ;; esac
  [ -z "$WHY" ] && [ -z "$V" ] && WHY="emitted no parseable verdict"
  [ -z "$WHY" ] && [ "$COV" != "full" ] && WHY="reported coverage=$COV"
  [ -z "$WHY" ] && [ -n "$CONF" ] && awk -v c="$CONF" -v m="$MIN_CONF" 'BEGIN{exit !(c<m)}' \
    && WHY="confidence $CONF < $MIN_CONF"
  [ -z "$WHY" ] && [ -n "$STAKES" ] && WHY="high-stakes input ($STAKES)"

  if [ -n "$WHY" ]; then
    echo "[gemini-review: escalating to $PRO_MODEL — $WHY]" >&2
    CHEAP_TEXT="$TEXT"; CHEAP_MV="$MV"; CHEAP_USAGE="$USAGE"
    MODEL="$PRO_MODEL"; LEVEL="$PRO_LEVEL"; build_req "$PRO_LEVEL"
    BODY=$(call || true)
    if printf '%s' "$BODY" | jq -e '.candidates[0].content.parts' >/dev/null 2>&1; then
      TEXT=$(printf '%s' "$BODY" | jq -r '[.candidates[0].content.parts[]? | select(.thought != true) | .text // empty] | join("")')
      FINISH=$(printf '%s' "$BODY" | jq -r '.candidates[0].finishReason // "?"')
      USAGE=$(printf '%s' "$BODY" | jq -r '.usageMetadata | "in=\(.promptTokenCount // "?") out=\(.candidatesTokenCount // "?") thoughts=\(.thoughtsTokenCount // 0)"')
      MV=$(printf '%s' "$BODY" | jq -r '.modelVersion // "?"')
      USAGE="$USAGE (escalated from $CHEAP_MV: $CHEAP_USAGE)"
    else
      # Pro failed: keep the cheap review rather than returning nothing, and say so.
      echo "warning: escalation call failed — returning the $CHEAP_MV review" >&2
      TEXT="$CHEAP_TEXT"
    fi
  else
    echo "[gemini-review: no escalation — severity=$SEV confidence=$CONF coverage=$COV]" >&2
  fi
fi

if [ -n "$OUT" ]; then printf '%s\n' "$TEXT" > "$OUT"; fi
printf '%s\n' "$TEXT"
echo "" >&2; echo "[gemini-review: model=$MV level=$LEVEL finish=$FINISH $USAGE${KEEP_RAW:+ raw=$RAW}]" >&2
[ "$FINISH" = "STOP" ] || { echo "warning: answer was cut off ($FINISH) — raise --max or lower --level" >&2; exit 3; }
