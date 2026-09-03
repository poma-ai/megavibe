#!/usr/bin/env bash
# Print the newest flash-class Gemini model this API key can actually call.
#
# Why probe instead of hardcoding a version:
#   - Google retires models per-generation and gates them by account age. As of
#     2026-09, `gemini-2.5-flash` returns "no longer available to new users" on
#     freshly created projects, while older projects still work — so there is no
#     single correct constant.
#   - ListModels LIES for this purpose: it lists models (incl. 2.5-flash and the
#     `-latest` aliases) that generateContent then rejects. Only a real call proves
#     usability.
#   - Probing keeps megavibe "defaulting to the default": each setup run picks the
#     current generation, so nobody has to trace model releases by hand.
#
# Flash-class only, on purpose: Pro is billing-gated since May 2026 — on a postpay
# key it silently bills, on a free key it 429s.
#
# Usage: bash scripts/pick-gemini-model.sh [API_KEY]     # falls back to $GEMINI_API_KEY
# Prints the model id on stdout, or exits 1 if none worked.

set -euo pipefail

KEY="${1:-${GEMINI_API_KEY:-}}"
[ -n "$KEY" ] || { echo "no API key given and GEMINI_API_KEY unset" >&2; exit 1; }

# Newest first. `-latest` aliases are tried first so the pin self-updates where
# Google honours them; explicit generations follow as the reliable fallback.
CANDIDATES=(
  "${GEMINI_MODEL_CANDIDATES:-}"
  gemini-flash-latest
  gemini-3.6-flash
  gemini-3.1-flash
  gemini-3.1-flash-lite
  gemini-3-flash-preview
  gemini-2.5-flash
)

probe() { # $1=model → 0 if a real generateContent call succeeds
  local body
  body=$(curl -s --max-time 45 \
    -X POST "https://generativelanguage.googleapis.com/v1beta/models/$1:generateContent" \
    -H "x-goog-api-key: $KEY" -H 'Content-Type: application/json' \
    -d '{"contents":[{"parts":[{"text":"hi"}]}],"generationConfig":{"maxOutputTokens":1}}' 2>/dev/null) || return 1
  [ -n "$body" ] || return 1                      # empty = throttled/dropped, not a verdict
  printf '%s' "$body" | grep -q '"usageMetadata"\|"candidates"'
}

for m in "${CANDIDATES[@]}"; do
  [ -n "$m" ] || continue
  # Two attempts: bursty sequential calls to this API get dropped (empty body),
  # which must not be mistaken for "model unavailable".
  if probe "$m" || { sleep 2; probe "$m"; }; then
    echo "$m"
    exit 0
  fi
done

echo "no flash-class model was callable with this key" >&2
exit 1
