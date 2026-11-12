#!/bin/bash
# /bin/bash tests/usage-route-pace.test.sh — fixtures only, including HOME and Codex.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/usage-route-pace.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
NOW=1793109600; WEEK=604800; RESET=$((NOW + 520128))
mkdir -p "$T/home" "$T/mv/usage" "$T/codex/sessions/x" "$T/bin"
export HOME="$T/home" MEGAVIBE_HOME="$T/mv" MEGAVIBE_NOW=$NOW
export MEGAVIBE_USAGE_FILE="$T/mv/usage/claude.jsonl" MEGAVIBE_USAGE_STATE="$T/mv/usage/state.json"
export MEGAVIBE_CODEX_HOME="$T/codex" MEGAVIBE_CODEX_STATE="$T/mv/usage/codex-state.json"
export MEGAVIBE_USER_SETTINGS="$T/settings.json"
export MEGAVIBE_ROUTER_PROVIDER=claude
row() { printf '{"t":%s,"sd":{"p":%s,"r":%s}}\n' "$1" "$2" "$3"; }
route() { /bin/bash "$REPO/scripts/usage-route.sh" "$@"; }
pace() { route pace; }
field() { printf '%s\n' "$o" | cut -d'|' -f"$1"; }
near() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a != "" && a-b < .01 && b-a < .01)}'; }
codex() {
  local ts
  ts=$(jq -nr --argjson t "$1" '$t | todateiso8601')
  printf '{"timestamp":"%s","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s}}}}\n' "$ts" "$2" "$3"
}
row "$NOW" 19 "$RESET" > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check '14 percent elapsed: linear estimate before the old 25 percent gate' 'near "$(field 3)" 14 && near "$(field 4)" 135.714 && near "$(field 7)" 6.02'
check 'one sample: recent fields empty, seven fields retained' '[[ "$o" == claude\|19\|* ]] && [ "$(field 5)$(field 6)" = "" ] && [ "$(printf "%s" "$o" | tr -cd "|")" = "||||||" ]'
row "$NOW" 19 "$((NOW + WEEK - 1))" > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'tiny elapsed fraction: no linear estimate' '[ "$(field 4)" = "" ] && [ "$(field 2)" = 19 ]'
row "$NOW" 19 "$((NOW + WEEK - 30240))" > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'exactly five percent allows an estimate' 'near "$(field 4)" 380'
row "$NOW" 19 "$((NOW + WEEK + 60))" > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'clock skew: negative elapsed gives no evidence' '[ "$o" = "claude||||||" ]'
row "$((NOW + 1))" 19 "$RESET" > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'future sample is not fresh evidence' '[ "$o" = "claude||||||" ]'

{ row "$((NOW - 21600))" 90 "$((RESET - WEEK))"; row "$((NOW - 18000))" 18 "$RESET"; row "$NOW" 19 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'reset boundary: only current-window increase counts' 'near "$(field 5)" 4.8 && near "$(field 6)" 47.896'
{ row "$((NOW - 21600))" 90 "$RESET"; row "$((NOW - 18000))" 18 "$RESET"; row "$NOW" 19 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'percent drop makes the selected window unreliable' '[ "$(field 5)$(field 6)" = "" ]'
{ row "$((NOW - 21600))" 17 "$RESET"; row "$((NOW - 18000))" 18 "$((RESET + 60))"; row "$NOW" 19 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'reset jitter of seconds remains one window' '[ "$(field 5)" = 8 ] && [ "$(field 6)" = 67.16 ] && [ "$(field 2)" = 19 ]'
{ row "$((NOW - 21601))" 18 "$RESET"; row "$NOW" 19 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'fewer than two samples inside six hours: no recent guess' '[ "$(field 5)$(field 6)" = "" ] && [ "$(field 2)" = 19 ]'
{ row "$NOW" 18 "$RESET"; row "$NOW" 19 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'duplicate timestamps do not divide by zero' '[ "$(field 5)$(field 6)" = "" ] && [ "$(field 2)" = 19 ]'
{ row "$((NOW - 21600))" 18 "$RESET"; row "$NOW" 19 "$RESET"; row "$NOW" 19 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'duplicate latest reading does not erase valid history' 'near "$(field 5)" 4'
{ row "$((NOW - 21600))" 17 "$RESET"; row "$((NOW - 18000))" 18 "$((RESET + 60))"; row "$((NOW - 18000))" 19 "$RESET"; row "$NOW" 20 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'duplicate timestamp with reset jitter stays in one window' '[ "$(field 5)" = 12 ]'
{ row "$((NOW - 21600))" 17 "$RESET"; row "$((NOW - 18000))" 21 "$RESET"; row "$((NOW - 18000))" 19 "$RESET"; row "$NOW" 20 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'duplicate timestamp cannot hide a percentage drop' '[ "$(field 5)$(field 6)" = "" ]'
{ row "$((NOW - 18000))" 18.25 "$RESET"; row "$NOW" 19.5 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(LC_ALL=de_DE pace)
check 'decimal readings under comma locale remain numeric' 'near "$(field 4)" 139.286 && near "$(field 5)" 6 && near "$(field 6)" 55.62'
row "$NOW" '"19,5"' "$RESET" > "$MEGAVIBE_USAGE_FILE"
o=$(LC_ALL=de_DE pace)
check 'locale-comma string is rejected, never interpreted as an integer' '[ "$o" = "claude||||||" ]'
row "$((NOW - 21601))" 19 "$RESET" > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'stale data: empty fields' '[ "$o" = "claude||||||" ]'
: > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'empty file under bash 3.2 set -u: empty fields, exit zero' '[ "$o" = "claude||||||" ] && pace >/dev/null'
rm "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'missing file: empty fields' '[ "$o" = "claude||||||" ]'
printf '%s\n' 'broken JSON' '{"sd":null}' > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'malformed file: empty fields' '[ "$o" = "claude||||||" ]'
o=$(PATH="$T/bin" /bin/bash "$REPO/scripts/usage-route.sh" pace); rc=$?
check 'jq missing: silent exit zero' '[ "$rc" = 0 ] && [ -z "$o" ]'

codex "$NOW" 19 "$RESET" > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex pace)
check 'Codex latest only: linear present, recent empty' '[[ "$o" == codex\|19\|* ]] && near "$(field 4)" 135.638 && [ "$(field 5)$(field 6)" = "" ]'
{ codex "$((NOW - 21600))" 18 "$RESET"; codex "$NOW" 19 "$RESET"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex pace)
check 'Codex history supports recent rate' 'near "$(field 5)" 4'
codex "$((NOW - 86401))" 19 "$RESET" > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex pace)
check 'Codex stale data: empty fields' '[ "$o" = "codex||||||" ]'
rm "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex pace)
check 'Codex empty file list under bash 3.2: no crash' '[ "$o" = "codex||||||" ]'

# A busy statusline can append more than the status reader's 50-row slice in six hours.
{ row "$((NOW - 21600))" 94 "$((NOW + WEEK / 2))"; for i in $(seq 59 -1 0); do row "$((NOW - i))" 95 "$((NOW + WEEK / 2))"; done; } > "$MEGAVIBE_USAGE_FILE"
codex "$NOW" 9 "$RESET" > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(pace)
check 'pace sees six-hour baseline beyond last 50 samples' 'near "$(field 5)" 4 && near "$(field 6)" 109'
o=$(route balance --peek)
check 'balance preference unchanged, both absolute estimates beside advice' '[[ "$o" == codex\|* ]] && [[ "$o" == *"Claude"*"~190%"*"recent estimate ~109%"*"Codex"*"[linear estimate ~64%]"*"Lean optional work"* ]]'
# The effective projection (router projection, else straight-line estimate, else used) decides the preference:
# a subscription that is early in its window but already on a high straight line is no place to send work.
codex "$NOW" 33 "$((NOW + 556416))" > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(route balance --peek)
check 'Codex 8 percent into its window and already 33 percent used (linear estimate ~383%): no advice to lean on Codex' '[ "$o" = "-|" ]'
codex "$NOW" 4 "$((NOW + 556416))" > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(route balance --peek)
check 'Codex early in its window with a low straight line (~49%): still leans on Codex, estimate shown' '[[ "$o" == codex\|* ]] && [[ "$o" == *"[linear estimate ~49%]"* ]]'
codex "$NOW" 9 "$RESET" > "$T/codex/sessions/x/rollout-1.jsonl"
check 'pace and peek leave routing state untouched' '[ ! -e "$MEGAVIBE_USAGE_STATE" ] && [ ! -e "$MEGAVIBE_CODEX_STATE" ]'

# Run the real tick with fake auth/GitHub and no network.
printf '#!/bin/bash\ncase "$*" in "api user --jq .login") echo fixture ;; *) echo "[]" ;; esac\n' > "$T/bin/gh"
chmod +x "$T/bin/gh"
printf '{"claudeAiOauth":{"expiresAt":%s,"refreshTokenExpiresAt":%s}}\n' "$(((NOW + 86400) * 1000))" "$(((NOW + WEEK) * 1000))" > "$T/credentials.json"
o=$(MEGAVIBE_TICK_CONF="$T/no.conf" MEGAVIBE_GH="$T/bin/gh" MEGAVIBE_CLAUDE_CREDENTIALS="$T/credentials.json" TICK_LINEAR=0 /bin/bash "$REPO/scripts/tick.sh" --no-mark fixture/repo)
usage=$(printf '%s\n' "$o" | grep '^usage:')
check 'tick keeps first-line and one usage-line format with both projections' '[[ "$o" == "tick default: quiet | window "* ]] && [[ "$usage" == "usage: Claude 95% used"*"~190%"*"recent estimate ~109%"*" | Codex 9% used"*"[linear estimate ~64%]"*" | lean optional work on codex" ]] && [ "$(printf "%s\n" "$usage" | wc -l | tr -d " ")" = 1 ]'

# Exact display contract: a recent projection always includes its non-negative rate.
tick_usage() {
  MEGAVIBE_TICK_CONF="$T/no.conf" MEGAVIBE_GH="$T/bin/gh" MEGAVIBE_CLAUDE_CREDENTIALS="$T/credentials.json" TICK_LINEAR=0 \
    /bin/bash "$REPO/scripts/tick.sh" --no-mark fixture/repo | grep '^usage:'
}
expected_balance() {
  printf 'codex|usage balance: Claude 95%% used (linear estimate ~190%% by week end)%s; Codex 9%% used [linear estimate ~64%%] (one is running hot). Lean optional work (digests, exploration, second opinions) on Codex; the review floor does not move.' "$1"
}
expected_tick() {
  printf 'usage: Claude 95%% used (linear estimate ~190%% by week end)%s, resets in 3d [over] | Codex 9%% used [linear estimate ~64%%], resets in 6d | lean optional work on codex' "$1"
}
o=$(pace)
check 'exact high linear, low recent pace record' '[ "$o" = "claude|95|50|190|4|109|3.5" ]'
o=$(route balance --peek)
check 'balance exact recent estimate with burn rate' '[ "$o" = "$(expected_balance " (recent estimate ~109% at 4 pts/day)")" ]'
o=$(tick_usage)
check 'tick exact recent estimate with burn rate' '[ "$o" = "$(expected_tick " (recent estimate ~109% at 4 pts/day)")" ]'

# Only the selected jq invocation is faulty; all other jq calls use the real binary.
export PACE_REAL_JQ=$(command -v jq)
cat > "$T/bin/jq" <<'SHIM'
#!/bin/bash
stage=""
for arg in "$@"; do
  case "$arg" in
    '[$b, (.wk.used'*) stage=status ;;
    *'def blank: [$provider'*) stage=pace ;;
    '.band') stage=band ;;
    '.reason') stage=reason ;;
    *'def pick($k):'*) stage=decision ;;
    'fromjson? | select(type == "object")') stage=stream ;;
    '.') stage=history ;;
    'select(length > 0)') stage=row ;;
  esac
done
if [ "${MEGAVIBE_ROUTER_PROVIDER:-claude}" = claude ] && [ "$stage" = "${PACE_FAULT_STAGE:-unset}" ]; then
  case "${PACE_FAULT_MODE:-fail}" in
    fail) exit 1 ;;
    empty) exit 0 ;;
    partial) printf 'broken'; exit 1 ;;
    record) printf '%s\n' "$PACE_FAULT_RECORD"; exit 0 ;;
  esac
fi
exec "$PACE_REAL_JQ" "$@"
SHIM
chmod +x "$T/bin/jq"
export PACE_REAL_TAIL=$(command -v tail)
cat > "$T/bin/tail" <<'SHIM'
#!/bin/bash
if [ "${PACE_FAULT_STAGE:-}" = raw ] && [ "$*" = "-n 5000 $MEGAVIBE_USAGE_FILE" ]; then
  case "$PACE_FAULT_MODE" in
    fail) exit 1 ;;
    empty) exit 0 ;;
    partial) "$PACE_REAL_TAIL" "$@"; exit 1 ;;
  esac
fi
exec "$PACE_REAL_TAIL" "$@"
SHIM
chmod +x "$T/bin/tail"
export PATH="$T/bin:$PATH"

# Status failures must never turn the pace provider into the used percentage.
for stage in raw status band reason decision history row stream; do
  for fault in fail empty partial; do
    # An empty reason is legitimate (no live windows), unlike failed serialization.
    [ "$stage:$fault" != reason:empty ] || continue
    o=$(PACE_FAULT_STAGE=$stage PACE_FAULT_MODE=$fault route status-pace --peek); rc=$?
    check "$stage $fault: exact combined no-data record, exit zero" '[ "$rc" = 0 ] && [ "$o" = "normal||||||claude||||||" ]'
    o=$(PACE_FAULT_STAGE=$stage PACE_FAULT_MODE=$fault route balance --peek)
    check "$stage $fault: balance gives no advice" '[ "$o" = "-|" ]'
    o=$(PACE_FAULT_STAGE=$stage PACE_FAULT_MODE=$fault tick_usage)
    check "$stage $fault: tick no reading, no false reset or lean advice" '[ "$o" = "usage: Claude: no reading | Codex 9% used [linear estimate ~64%], resets in 6d" ]'
  done
done
# With Codex hot, a shifted Claude record used to invent spare Claude capacity.
codex "$NOW" 95 "$((NOW + WEEK / 2))" > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(PACE_FAULT_STAGE=status route balance --peek)
check 'failed Claude status cannot recommend Claude when Codex is hot' '[ "$o" = "-|" ]'
codex "$NOW" 9 "$RESET" > "$T/codex/sessions/x/rollout-1.jsonl"
for fault in fail empty partial; do
  o=$(PACE_FAULT_STAGE=status PACE_FAULT_MODE=$fault route status --peek); rc=$?
  check "status $fault: legacy no-data shape, exit zero" '[ "$rc" = 0 ] && [ "$o" = "normal|||||" ]'
  o=$(PACE_FAULT_STAGE=pace PACE_FAULT_MODE=$fault route status-pace --peek); rc=$?
  check "pace $fault: valid status and seven empty pace fields" '[ "$rc" = 0 ] && [ "$o" = "over|95|190|302400|0|7d 95% used, resets in 3d|claude||||||" ]'
  o=$(PACE_FAULT_STAGE=pace PACE_FAULT_MODE=$fault route balance --peek)
  check "pace $fault: balance retains status and advice" '[ "$o" = "$(expected_balance "")" ]'
  o=$(PACE_FAULT_STAGE=pace PACE_FAULT_MODE=$fault tick_usage)
  check "pace $fault: tick retains status and reset" '[ "$o" = "$(expected_tick "")" ]'
  o=$(PACE_FAULT_STAGE=pace PACE_FAULT_MODE=$fault pace); rc=$?
  check "pace $fault: standalone no-data record, exit zero" '[ "$rc" = 0 ] && [ "$o" = "claude||||||" ]'
done

# Missing/invalid rate cannot masquerade as zero; zero is a valid observed rate.
while IFS=';' read -r rate projection suffix; do
  export PACE_FAULT_STAGE=pace PACE_FAULT_MODE=record
  export PACE_FAULT_RECORD="claude|95|50|190|$rate|$projection|3.5"
  o=$(LC_ALL=de_DE route balance --peek)
  check "balance exact rate '$rate' under de_DE" '[ "$o" = "$(expected_balance "$suffix")" ]'
  o=$(LC_ALL=de_DE tick_usage)
  check "tick exact rate '$rate' under de_DE" '[ "$o" = "$(expected_tick "$suffix")" ]'
done <<'EOF'
;109;
-4;81;
0;95; (recent estimate ~95% at 0 pts/day)
4.125;109.438; (recent estimate ~109% at 4.125 pts/day)
EOF
unset PACE_FAULT_STAGE PACE_FAULT_MODE PACE_FAULT_RECORD

# Real samples: a decrease suppresses both recent fields; flat use retains zero.
{ row "$((NOW - 21600))" 96 "$((NOW + WEEK / 2))"; row "$NOW" 95 "$((NOW + WEEK / 2))"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'negative observed rate never emitted' '[ "$o" = "claude|96|50|192|||3.5" ]'
{ row "$((NOW - 21600))" 95 "$((NOW + WEEK / 2))"; row "$NOW" 95 "$((NOW + WEEK / 2))"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'zero observed rate retained exactly' '[ "$o" = "claude|95|50|190|0|95|3.5" ]'

# A PATH with required system tools but no jq exercises both callers too.
mkdir "$T/no-jq"
for tool in bash dirname cut tr; do
  ln -s "$(command -v "$tool")" "$T/no-jq/$tool"
done
for mode in pace status status-pace balance; do
  case "$mode" in pace) expected='' ;; status) expected='normal|||||' ;; status-pace) expected='normal||||||claude||||||' ;; balance) expected='-|' ;; esac
  o=$(PATH="$T/no-jq" route "$mode" --peek); rc=$?
  check "jq absent: $mode exact fallback, exit zero" '[ "$rc" = 0 ] && [ "$o" = "$expected" ]'
done
o=$(PATH="$T/no-jq" MEGAVIBE_TICK_CONF="$T/no.conf" MEGAVIBE_GH="$T/bin/gh" MEGAVIBE_CLAUDE_CREDENTIALS="$T/credentials.json" TICK_LINEAR=0 /bin/bash "$REPO/scripts/tick.sh" --no-mark fixture/repo)
check 'jq absent: tick reports its existing dependency fallback' '[ "$o" = "tick default: jq is required" ]'

# Projection starts at the observation, while remaining/elapsed are measured at NOW.
{ row "$((NOW - 21600))" 10 "$((NOW + WEEK / 2))"; row "$((NOW - 10800))" 20 "$((NOW + WEEK / 2))"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'three-hour-old reading: exact 310 percent projection, 3.5 days remaining now' '[ "$o" = "claude|20|50|40|80|310|3.5" ]'
# Same observations appended in reverse order must keep the same result.
{ row "$((NOW - 10800))" 20 "$((NOW + WEEK / 2))"; row "$((NOW - 21600))" 10 "$((NOW + WEEK / 2))"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'out-of-order appends within one window preserve exact projection' '[ "$o" = "claude|20|50|40|80|310|3.5" ]'
row "$((NOW - 60))" 95 "$((NOW - 1))" > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'after reset no negative remaining days or estimates' '[ "$o" = "claude||||||" ]'

# Reviewer reproduction: the last appended live window wins even with an older timestamp.
{ row "$((NOW - 18000))" 10 "$((NOW + 6 * 86400))"; row "$NOW" 20 "$((NOW + 6 * 86400))"; row "$((NOW - 20000))" 95 "$((NOW + 86400))"; } > "$MEGAVIBE_USAGE_FILE"
o=$(route status --peek)
check 'delayed-window status byte-identical' '[ "$o" = "over|95|110|86400|0|7d 95% used, resets in 24h" ]'
o=$(pace)
check 'delayed-window pace uses status window, one sample has no recent estimate' '[ "$o" = "claude|95|85.714|110.833|||1" ]'
o=$(route balance --peek)
check 'balance never borrows recent estimate from other window' '[[ "$o" == codex\|*"Claude 95% used (linear estimate ~110% by week end); Codex"* ]]'
o=$(MEGAVIBE_TICK_CONF="$T/no.conf" MEGAVIBE_GH="$T/bin/gh" MEGAVIBE_CLAUDE_CREDENTIALS="$T/credentials.json" TICK_LINEAR=0 /bin/bash "$REPO/scripts/tick.sh" --no-mark fixture/repo)
usage=$(printf '%s\n' "$o" | grep '^usage:')
check 'tick uses one window for used, linear, recent and remaining' '[[ "$usage" == "usage: Claude 95% used (linear estimate ~110% by week end), resets in 24h [over] | Codex"* ]]'

# Interleaving a different live window must not discard the selected window's baseline.
{ row "$((NOW - 21600))" 90 "$((NOW + 86400))"; row "$((NOW - 18000))" 8 "$((NOW + 6 * 86400))"; row "$((NOW - 10800))" 95 "$((NOW + 86400))"; row "$NOW" 20 "$((NOW + 6 * 86400))"; row "$((NOW - 14400))" 92 "$((NOW + 86400))"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'two interleaved windows: sort only selected samples and extrapolate from last observation' '[ "$o" = "claude|95|85.714|110.833|40|140|1" ]'
o=$(route status --peek)
check 'interleaved status byte-identical' '[ "$o" = "over|95|110|86400|0|7d 95% used, resets in 24h" ]'

# Combined display must preserve the raw 50-line status slice, including trailing blanks.
{ row "$NOW" 95 "$((NOW + 86400))"; for i in $(seq 1 50); do printf '\n'; done; } > "$MEGAVIBE_USAGE_FILE"
o=$(route status-pace --peek)
check 'combined snapshot respects trailing blank lines in status slice' '[ "$(printf "%s\n" "$o" | cut -d"|" -f1-6)" = "$(route status --peek)" ]'

# Byte-for-byte snapshots from the pre-change script, reproducing the existing early fixtures.
while IFS=';' read -r rem used prev expected; do
  row "$((NOW - 60))" "$used" "$((NOW + rem))" > "$MEGAVIBE_USAGE_FILE"
  codex "$((NOW - 60))" "$used" "$((NOW + rem))" > "$T/codex/sessions/x/rollout-1.jsonl"
  printf '{"band":"%s","since":%s,"pend":0,"calm":0,"mx":{}}\n' "$prev" "$((NOW - 7200))" > "$MEGAVIBE_USAGE_STATE"
  cp "$MEGAVIBE_USAGE_STATE" "$MEGAVIBE_CODEX_STATE"
  for provider in claude codex; do
    o=$(MEGAVIBE_ROUTER_PROVIDER=$provider route status --peek)
    check "$provider status unchanged: $expected" '[ "$o" = "$expected" ]'
    o=$(MEGAVIBE_ROUTER_PROVIDER=$provider route status-pace --peek)
    check "$provider combined status unchanged: $expected" '[ "$(printf "%s\n" "$o" | cut -d"|" -f1-6)" = "$expected" ]'
  done
done <<'EOF'
504360;64;normal;over|64||504360|0|7d 64% used, resets in 5d
504360;20;normal;normal|20||504360|0|7d 20% used, resets in 5d
504360;45;normal;normal|45||504360|0|7d 45% used, resets in 5d
601740;32;normal;over|32||601740|0|7d 32% used, resets in 6d
504360;40;over;over|40||504360|0|7d 40% used, resets in 5d
172920;60;normal;normal|60|84|172920|0|7d 60% used, resets in 2d
344700;60;normal;over|60|139|344700|0|7d 60% used, resets in 3d
EOF

# minimum span: a rate from samples minutes apart is noise, not a trend
{ row "$((NOW - 1200))" 17 "$RESET"; row "$NOW" 19 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'two samples 20 minutes apart: no recent rate or projection' '[ "$(field 5)$(field 6)" = "" ] && [ "$(field 2)" = 19 ] && near "$(field 3)" 14'
{ row "$((NOW - 7199))" 17 "$RESET"; row "$NOW" 19 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'a span one second under two hours: no recent rate' '[ "$(field 5)$(field 6)" = "" ]'
{ row "$((NOW - 7200))" 17 "$RESET"; row "$NOW" 19 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'a span of exactly two hours gives the rate (2 points in 2 h is 24 per day)' 'near "$(field 5)" 24 && [ -n "$(field 6)" ]'
{ codex "$((NOW - 1200))" 31 "$RESET"; codex "$NOW" 33 "$RESET"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex pace)
check 'Codex samples 20 minutes apart: no recent rate (the live 1150 percent case)' '[ "$(field 5)$(field 6)" = "" ] && [ "$(field 2)" = 33 ]'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
