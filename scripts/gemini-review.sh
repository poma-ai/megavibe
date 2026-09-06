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
#   scripts/gemini-review.sh [--pro] [--level low|medium|high] [--max N]
#                            [--out FILE] --prompt "text" FILE...
#   scripts/gemini-review.sh ... --prompt-file PROMPT.md FILE...
#
# Files are appended to the prompt as "===== path =====" blocks. Output: the
# model's text on stdout; with --out, the text goes there and the raw JSON to
# FILE.raw.json for audit (without --out nothing is left behind).
# Exit 0 on a complete answer, 3 if the answer was cut off (MAX_TOKENS), 1 on
# API/network error. Never retries more than once (megavibe rule).
#
# Model: gemini-flash-latest by default (≈$0.04 per 50K-token review on the
# paid key). --pro = gemini-3.1-pro-preview at thinkingLevel medium (≈$0.15);
# use it for reviews of protocol/template changes and anything user-facing.
# Needs a key from a BILLED project in $GEMINI_API_KEY — the free tier is
# 20 requests/day and trains on prompts.

set -euo pipefail

# Measured 2026-09-06: gemini-flash-latest → gemini-3.8-flash; --pro → gemini-3.1-pro-preview
# (the current Pro line; answered live that day). Both accept thinkingConfig.thinkingLevel.
# If Google moves the alias to a model that rejects the field, the API returns 400 and
# this script exits 1 with the message — re-check `models?key=` and adjust MODEL/--pro.
MODEL="gemini-flash-latest"; LEVEL="low"; MAX=16000; OUT=""; PROMPT=""; PROMPT_FILE=""
FILES=()
need(){ [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --pro)         MODEL="gemini-3.1-pro-preview"; LEVEL="medium"; shift ;;
    --model)       need "$@"; MODEL="$2"; shift 2 ;;
    --level)       need "$@"; LEVEL="$2"; shift 2 ;;
    --max)         need "$@"; MAX="$2"; shift 2 ;;
    --out)         need "$@"; OUT="$2"; shift 2 ;;
    --prompt)      need "$@"; PROMPT="$2"; shift 2 ;;
    --prompt-file) need "$@"; PROMPT_FILE="$2"; shift 2 ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    --)            shift; FILES+=("$@"); break ;;
    -*)            echo "unknown arg: $1" >&2; exit 2 ;;
    *)             FILES+=("$1"); shift ;;
  esac
done

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
trap '[ -n "$KEEP_RAW" ] || rm -f "$RAW"; rm -f "$REQ"' EXIT
{
  printf '%s\n' "$PROMPT"
  for f in "${FILES[@]:-}"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] && [ -r "$f" ] || { echo "error: not a readable file: $f" >&2; exit 1; }
    printf '\n\n===== %s =====\n' "$f"; cat -- "$f"
  done
} | jq -Rs --arg model "$MODEL" --arg level "$LEVEL" --argjson max "$MAX" \
  '{contents:[{parts:[{text:.}]}], generationConfig:{maxOutputTokens:$max, temperature:0.2, thinkingConfig:{thinkingLevel:$level}}}' > "$REQ"

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

if [ -n "$OUT" ]; then printf '%s\n' "$TEXT" > "$OUT"; fi
printf '%s\n' "$TEXT"
echo "" >&2; echo "[gemini-review: model=$MV level=$LEVEL finish=$FINISH $USAGE${KEEP_RAW:+ raw=$RAW}]" >&2
[ "$FINISH" = "STOP" ] || { echo "warning: answer was cut off ($FINISH) — raise --max or lower --level" >&2; exit 3; }
