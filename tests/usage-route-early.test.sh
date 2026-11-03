#!/bin/bash
# /bin/bash tests/usage-route-early.test.sh
# Early in the weekly window (no projection before 25% elapsed) a usage far ahead of the
# straight-line pace is `over`, not `normal`; a pace near the line stays normal.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/usage-route.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
NOW=1793109600; WEEK=604800

# band ELAPSED_FRACTION USED_PERCENT [STATE_BAND]: the Codex band for one synthetic rollout row
band() {
  local d="$T/c$RANDOM$RANDOM" reset ts
  reset=$(python3 -c "print(int($NOW + $WEEK * (1 - $1)) // 60 * 60)")
  ts=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($NOW - 60, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  mkdir -p "$d/sessions/x" "$d/mv"
  printf '{"timestamp":"%s","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s},"secondary":null}}}\n' "$ts" "$2" "$reset" > "$d/sessions/x/rollout-1.jsonl"
  [ -n "${3:-}" ] && printf '{"band":"%s","since":%s,"pend":0,"calm":0,"mx":{}}\n' "$3" "$((NOW - 7200))" > "$d/mv/state.json"
  MEGAVIBE_NOW=$NOW MEGAVIBE_CODEX_HOME="$d" MEGAVIBE_CODEX_STATE="$d/mv/state.json" MEGAVIBE_HOME="$d/mv" \
    bash "$REPO/scripts/usage-route.sh" codex-band 2>/dev/null
}

check "day 1.2, 64% used (the 2026-10-27 case) is over" '[ "$(band 0.166 64)" = over ]'
check "day 1.2, 20% used (on the line) stays normal" '[ "$(band 0.166 20)" = normal ]'
check "day 1.2, 45% used (under 30 points ahead) stays normal" '[ "$(band 0.166 45)" = normal ]'
check "first hour, 32% used is over" '[ "$(band 0.005 32)" = over ]'
check "held over at 40% on day 1.2 (20+ ahead) stays over" '[ "$(band 0.166 40 over)" = over ]'
check "late week unchanged: day 5, 60% used stays normal" '[ "$(band 0.714 60)" = normal ]'
check "late week unchanged: day 3, 60% used (projection 140%) is over" '[ "$(band 0.43 60)" = over ]'

# A steady 32% from hour one, stepped across the week with one persistent state file: one
# `over` stretch, no over -> normal -> over flap at the 25% boundary.
seq_bands() {   # $1 = claude|codex
  local d="$T/seq-$1" reset=$((NOW + WEEK - 600)) out="" el n ts
  mkdir -p "$d/sessions/x" "$d/mv/usage"
  for el in 0.003 0.05 0.10 0.15 0.18 0.22 0.248 0.26 0.30 0.40 0.50 0.65 0.75; do
    n=$(python3 -c "print(int($reset - $WEEK * (1 - $el)))")
    ts=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($n - 60, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    if [ "$1" = codex ]; then
      printf '{"timestamp":"%s","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":32,"window_minutes":10080,"resets_at":%s},"secondary":null}}}\n' "$ts" "$reset" > "$d/sessions/x/rollout-1.jsonl"
      out="$out $(MEGAVIBE_NOW=$n MEGAVIBE_CODEX_HOME="$d" MEGAVIBE_CODEX_STATE="$d/mv/state.json" MEGAVIBE_HOME="$d/mv" bash "$REPO/scripts/usage-route.sh" codex-band 2>/dev/null)"
    else
      printf '{"t":%s,"sd":{"p":32,"r":%s}}\n' "$((n - 60))" "$reset" >> "$d/mv/usage/claude.jsonl"
      out="$out $(MEGAVIBE_NOW=$n MEGAVIBE_HOME="$d/mv" MEGAVIBE_USAGE_FILE="$d/mv/usage/claude.jsonl" bash "$REPO/scripts/usage-route.sh" band 2>/dev/null)"
    fi
  done
  printf '%s' "$out"
}
for prov in codex claude; do
  b=$(seq_bands $prov)
  # collapse runs: "over normal" is the only allowed shape (or just one band)
  shape=$(printf '%s\n' $b | uniq | tr '\n' ' ')
  check "$prov: steady 32% from hour one gives one over stretch, no flap ($shape)" '[ "$shape" = "over normal " ]'
done

# Transitions that must still release after the usual 30 minutes (reviews of 683b4c5):
# a state file with `over`, then two evaluations 31 minutes apart on a low weekly reading.
release() {   # $1 = weekly used %, $2 = 5-hour used % (or empty), $3 = elapsed fraction
  local d="$T/rel$RANDOM$RANDOM" reset fr n out=""
  reset=$(python3 -c "print(int($NOW + $WEEK * (1 - $3)) // 60 * 60)"); fr=$((NOW + 9000))
  mkdir -p "$d/mv/usage"
  printf '{"band":"over","since":%s,"pend":0,"calm":0,"mx":{}}\n' "$((NOW - 3600))" > "$d/mv/usage/route-state.json"
  for n in $NOW $((NOW + 1860)); do
    if [ -n "$2" ]; then printf '{"t":%s,"fh":{"p":%s,"r":%s},"sd":{"p":%s,"r":%s}}\n' "$((n - 30))" "$2" "$fr" "$1" "$reset"
    else printf '{"t":%s,"sd":{"p":%s,"r":%s}}\n' "$((n - 30))" "$1" "$reset"; fi >> "$d/mv/usage/claude.jsonl"
    out=$(MEGAVIBE_NOW=$n MEGAVIBE_HOME="$d/mv" MEGAVIBE_USAGE_FILE="$d/mv/usage/claude.jsonl" bash "$REPO/scripts/usage-route.sh" band 2>/dev/null)
  done
  printf '%s' "$out"
}
check "5-hour over at 5% weekly, day 0.7: released after 30 min" '[ "$(release 5 1 0.1)" = normal ]'
check "fresh week at 1% after an over: released after 30 min" '[ "$(release 1 "" 0.01)" = normal ]'
check "inherited over at 5% weekly, day 1: released after 30 min" '[ "$(release 5 "" 0.15)" = normal ]'
check "early over at 40% on day 1 is still held" '[ "$(release 40 "" 0.15)" = over ]'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
