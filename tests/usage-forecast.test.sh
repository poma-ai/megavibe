#!/bin/bash
# /bin/bash tests/usage-forecast.test.sh — fixtures only: scratch HOME, stub codex and launchctl.
# Covers `usage-route.sh forecast` (steady, burst, quiet, sparse, rollover, drop, early, stale, Codex) and the
# opt-in default of scripts/usage-probe.sh.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/usage-forecast.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
NOW=1793109600
mkdir -p "$T/home" "$T/mv/usage" "$T/codex/sessions/x" "$T/bin"
export HOME="$T/home" MEGAVIBE_HOME="$T/mv" MEGAVIBE_NOW=$NOW
export MEGAVIBE_USAGE_FILE="$T/mv/usage/claude.jsonl" MEGAVIBE_USAGE_STATE="$T/mv/usage/state.json"
export MEGAVIBE_CODEX_HOME="$T/codex" MEGAVIBE_CODEX_STATE="$T/mv/usage/codex-state.json"
export MEGAVIBE_USER_SETTINGS="$T/settings.json" MEGAVIBE_ROUTER_PROVIDER=claude
unset MEGAVIBE_USAGE_TARGET
row() { printf '{"t":%s,"sd":{"p":%s,"r":%s}}\n' "$((NOW - $1 * 3600))" "$2" "$3"; }   # HOURS_AGO USED RESET
fc() { /bin/bash "$REPO/scripts/usage-route.sh" forecast; }
f() { printf '%s\n' "$o" | cut -d'|' -f"$1"; }   # 2 used, 3 pace, 4 forecast, 5 spare, 6 spend, 7 basis
near() { awk -v a="$1" -v b="$2" -v e="${3:-0.2}" 'BEGIN {exit !(a != "" && a-b <= e && b-a <= e)}'; }
R=$((NOW + 300000))   # 50 percent of the week elapsed, 83.33 h left

# steady 0.5 points per hour
{ row 30 40 $R; row 24 43 $R; row 18 46 $R; row 12 49 $R; row 6 52 $R; row 0 55 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'steady: pace 0.5, forecast 96.7, spare -1.7, basis 6h+24h' 'near "$(f 3)" 0.5 0.01 && near "$(f 4)" 96.7 && near "$(f 5)" -1.7 && [ "$(f 7)" = "6h+24h" ]'
check 'steady: spend per hour to reach the target is (95-55)/83.33' 'near "$(f 6)" 0.48 0.01'

# burst: quiet for a day, then 13 points in the last 6 hours
{ row 30 40 $R; row 24 41 $R; row 18 41 $R; row 12 41 $R; row 6 42 $R; row 0 55 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'burst: the 6 h pace dominates (0.6 x 2.17 + 0.4 x 0.58 = 1.53 per hour), forecast above 150' 'near "$(f 3)" 1.533 0.01 && awk -v x="$(f 4)" "BEGIN{exit !(x > 150)}"'

# quiet: nothing used for 30 hours -> forecast is the used percent, never below it
{ row 30 30 $R; row 18 30 $R; row 6 30 $R; row 0 30 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'quiet: zero pace is a real zero (readings exist), forecast equals used' 'near "$(f 3)" 0 0.001 && near "$(f 4)" 30'

# whole-percent readings: a span shorter than 2 h is unknown, not zero; the window average stands in
{ row 1 54 $R; row 0 55 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'two readings an hour apart: no 6 h / 24 h pace, basis week' '[ "$(f 7)" = week ] && near "$(f 3)" 0.65 0.01'

# sparse burst: a 48 h old reading must not stretch the recent pace (readings 48, 4, 2, 0 h ago)
{ row 48 20 $R; row 4 20 $R; row 2 24 $R; row 0 28 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'sparse burst: both paces use only readings inside their horizon (2 points per hour)' 'near "$(f 3)" 2 0.01 && [ "$(f 7)" = "6h+24h" ]'
# only an old reading plus a fresh one: no pace inside either horizon, the week average stands in
{ row 48 20 $R; row 0 28 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'old reading outside both horizons: basis week' '[ "$(f 7)" = week ]'

# horizons are measured from now, not from the newest reading: readings 29 h and 23 h ago are in neither horizon
{ row 29 20 $R; row 23 32 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'aged readings only (Claude, stale after 6 h): unknown' '[ -z "$(f 4)" ]'

# one reading
row 0 55 $R > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'one reading: week average basis, still a forecast' '[ "$(f 7)" = week ] && [ -n "$(f 4)" ]'

# a drop inside the window makes the trend unreliable: no recent pace
{ row 30 40 $R; row 20 30 $R; row 6 45 $R; row 0 55 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'drop in the window: basis week, not the recent pace' '[ "$(f 7)" = week ]'

# window rollover: old window rows (reset an hour ago) never enter the new window's pace
NR=$((NOW + 500000))
{ row 40 90 $((NOW - 3600)); row 30 95 $((NOW - 3600)); row 12 2 $NR; row 6 3 $NR; row 0 4 $NR; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'rollover: forecast comes from the new window only (4 used, 0.17 per hour)' '[ "$(f 2)" = 4 ] && near "$(f 3)" 0.167 0.01 && near "$(f 4)" 27 1'

# too early in the window: no forecast (whole-percent readings are too coarse before 5 percent)
row 0 30 $((NOW + 604800 - 3600)) > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'under 5 percent elapsed: empty forecast' '[ -z "$(f 4)" ] && [ "$(f 2)" = 30 ]'

# stale reading (older than 6 h inside a live window): unknown, never spare capacity
{ row 9 50 $R; row 8 51 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'stale reading: empty forecast' '[ -z "$(f 4)" ]'

# no data / missing file
rm -f "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'no history: provider and empty fields, exit 0' '[ "$o" = "claude||||||" ]'

# target override
{ row 30 40 $R; row 24 43 $R; row 18 46 $R; row 12 49 $R; row 6 52 $R; row 0 55 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(MEGAVIBE_USAGE_TARGET=100 fc)
check 'target 100: spare 3.3' 'near "$(f 5)" 3.3'

# every output has exactly seven fields, also for no evidence; a junk target falls back to 95
{ row 30 40 $R; row 0 55 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(MEGAVIBE_USAGE_TARGET=abc fc)
check 'forecast with evidence: seven fields; junk target uses 95' '[ "$(printf "%s" "$o" | tr -cd "|" | wc -c | tr -d " ")" = 6 ] && near "$(f 5)" "$(awk -v x="$(f 4)" "BEGIN{print 95-x}")" 0.2'
row 0 30 $((NOW + 604800 - 3600)) > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'early window (empty forecast) still has seven fields' '[ "$(printf "%s" "$o" | tr -cd "|" | wc -c | tr -d " ")" = 6 ]'

# status and pace lines are unchanged by the forecast mode (field counts)
o=$(/bin/bash "$REPO/scripts/usage-route.sh" pace)
check 'pace keeps its seven fields' '[ "$(printf "%s" "$o" | tr -cd "|" | wc -c | tr -d " ")" = 6 ]'
o=$(/bin/bash "$REPO/scripts/usage-route.sh" status --peek)
check 'status keeps its six fields' '[ "$(printf "%s" "$o" | tr -cd "|" | wc -c | tr -d " ")" = 5 ]'
check 'forecast mode never writes routing state' '[ ! -e "$MEGAVIBE_USAGE_STATE" ]'

# Codex, sparse: one rollout record is a forecast on the week basis; none is unknown
ts() { jq -nr --argjson t "$1" '$t | todateiso8601'; }
codex() { printf '{"timestamp":"%s","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s}}}}\n' "$(ts "$1")" "$2" "$3"; }
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'codex without records: unknown' '[ "$(f 1)" = codex ] && [ -z "$(f 4)" ]'
{ codex "$((NOW - 3600))" 20 "$R"; codex "$NOW" 21 "$R"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'codex, two readings an hour apart: basis week, not a zero pace' '[ "$(f 7)" = week ] && near "$(f 3)" 0.25 0.01'
{ codex "$((NOW - 30 * 3600))" 10 "$R"; codex "$((NOW - 6 * 3600))" 16 "$R"; codex "$NOW" 20 "$R"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'codex, 30 h of readings: 6h+24h blend' '[ "$(f 7)" = "6h+24h" ] && near "$(f 3)" 0.6 0.35'

{ codex "$((NOW - 29 * 3600))" 20 "$R"; codex "$((NOW - 23 * 3600))" 32 "$R"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'codex readings 29 h and 23 h ago: in neither horizon, basis week (not a 6h+24h burst)' '[ "$(f 7)" = week ]'

# probe-style history: one rollout file per half-hour reading over 24 h must all count (the forecast reads 60 files, not 6)
mkdir -p "$T/codex/sessions/p"; : > "$T/codex/sessions/x/rollout-1.jsonl"
for i in $(seq 0 47); do m=$((i * 30)); u=44; [ "$m" -gt 360 ] && u=$((20 + (1440 - m) / 50)); codex "$((NOW - m * 60))" "$u" "$R" > "$T/codex/sessions/p/rollout-$(printf %02d $i).jsonl"; done
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'probe-style history, 48 rollout files: the 24 h pace sees the rise' 'awk -v x="$(f 4)" "BEGIN{exit !(x > 60)}"'
rm -r "$T/codex/sessions/p"

# one busy rollout: 1.3 MB of tool output between the anchors and the recent readings must not hide the 24 h baseline
mkdir -p "$T/codex/sessions/b"; : > "$T/codex/sessions/x/rollout-1.jsonl"
{ codex "$((NOW - 24 * 3600))" 20 "$R"; codex "$((NOW - 6 * 3600))" 20 "$R"
  head -c 1300000 /dev/zero | tr '\0' 'x' | fold -w 4000 | sed 's/^/{"type":"tool","out":"/; s/$/"}/'
  for m in 50 40 30 20 10 0; do codex "$((NOW - m * 60))" "$((20 + (50 - m) / 5))" "$R"; done; } > "$T/codex/sessions/b/rollout-big.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'busy rollout over 1 MB: the forecast still sees the 24 h baseline (6h+24h basis)' '[ "$(f 7)" = "6h+24h" ]'
rm -r "$T/codex/sessions/b"

# balance leads with the forecast: Claude steady at 55 (forecast 97), Codex quiet at 20 -> lean on Codex, text shows the forecast
{ row 30 40 $R; row 24 43 $R; row 18 46 $R; row 12 49 $R; row 6 52 $R; row 0 55 $R; } > "$MEGAVIBE_USAGE_FILE"
{ codex "$((NOW - 30 * 3600))" 20 "$R"; codex "$((NOW - 6 * 3600))" 20 "$R"; codex "$NOW" 20 "$R"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=claude /bin/bash "$REPO/scripts/usage-route.sh" balance --peek)
check 'balance: prefers codex and names the recent-pace forecast' '[[ "$o" == codex\|*"recent-pace forecast ~96% by week end"* ]] || [[ "$o" == codex\|*"recent-pace forecast ~97% by week end"* ]]'

# ---- the probe: run by the PA's node only, throttled, never scheduled by itself -----------------------------------
cat > "$T/bin/codex" <<'STUB'
#!/bin/bash
[ "${1:-}" = exec ] && [ "${2:-}" = "--help" ] && exit 0
printf '%s\n' "$*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$T/bin/codex"
export STUB_LOG="$T/codex.log" PATH="$T/bin:$PATH" MEGAVIBE_CODEX_BIN="$T/bin/codex"
P="$REPO/scripts/usage-probe.sh"
o=$(/bin/bash "$P" status 2>&1)
check 'probe: status says off without pa.on, no Codex call' '[[ "$o" == *"probe: off"* ]] && [ ! -e "$STUB_LOG" ]'
mkdir -p "$T/mv/node"; : > "$T/mv/node/pa.on"
o=$(/bin/bash "$P" status 2>&1)
check 'probe: status says on with pa.on' '[[ "$o" == *"probe: on"* ]]'
mv "$T/mv/node/pa.on" "$T/mv/node/pa.was"
check 'no installer: install is refused and the code has no scheduler calls' '! /bin/bash "$P" install >/dev/null 2>&1 && ! grep -vE "^[[:space:]]*#" "$P" | grep -qE "launchctl|LaunchAgent|plist"'
check 'only the node, the wrapper and the setup lists name the probe' \
  '! grep -rln "usage-probe" "$REPO/init.sh" "$REPO/template" "$REPO/scripts" 2>/dev/null | grep -vE "scripts/usage-probe.sh|template/node/node.sh" | grep -q .'
export MEGAVIBE_CODEX_HOME="$T/codex-none"; mkdir -p "$T/codex-none/sessions"
/bin/bash "$P" run --every 30 >/dev/null 2>&1
check 'run with no recent reading: one cheap read-only Codex call, logged, stamped' '[ "$(wc -l < "$STUB_LOG" | tr -d " ")" = 1 ] && grep -q -- "-s read-only" "$STUB_LOG" && grep -q -- "gpt-6-luna" "$STUB_LOG" && grep -q "rc=0" "$T/mv/usage/probe.log" && [ -e "$T/mv/usage/probe.stamp" ]'
mv "$STUB_LOG" "$STUB_LOG.1"
o=$(/bin/bash "$P" run --every 30 2>&1)
check 'run --every 30 right after a probe: throttled, no call' '[[ "$o" == *"under 30 min"* ]] && [ ! -e "$STUB_LOG" ]'
touch -t 202001010000 "$T/mv/usage/probe.stamp"
/bin/bash "$P" run --every 30 >/dev/null 2>&1
check 'run --every 30 with an old stamp: probes again' '[ "$(wc -l < "$STUB_LOG" | tr -d " ")" = 1 ]'
mkdir -p "$T/codex-none/sessions/2026/11/22"; : > "$T/codex-none/sessions/2026/11/22/rollout-1.jsonl"
mv "$STUB_LOG" "$STUB_LOG.2"; touch -t 202001010000 "$T/mv/usage/probe.stamp"
o=$(/bin/bash "$P" run --every 30 2>&1)
check 'run with a Codex reading under 15 min old: skipped, no call' '[[ "$o" == *"under 15 min"* ]] && [ ! -e "$STUB_LOG" ]'
# a Codex whose worker outlives it: the deadline ends the whole process group
cat > "$T/bin/codex-slow" <<'STUB'
#!/bin/bash
[ "${1:-}" = exec ] && [ "${2:-}" = "--help" ] && exit 0
( sleep 5; : > "$STUB_MARK" ) &
wait
STUB
chmod +x "$T/bin/codex-slow"
export STUB_MARK="$T/worker-marker"; rm -f "$STUB_MARK"
touch -t 202001010000 "$T/mv/usage/probe.stamp"; rm -r "$T/codex-none/sessions/2026"
sed 's/bounded 120/bounded 1/' "$P" > "$T/probe-fast.sh"
MEGAVIBE_CODEX_BIN="$T/bin/codex-slow" /bin/bash "$T/probe-fast.sh" run >/dev/null 2>&1
sleep 6
check 'probe deadline: the worker the Codex left behind is ended too (no marker), rc 142 logged' '[ ! -e "$STUB_MARK" ] && grep -q "rc=142" "$T/mv/usage/probe.log"'
o=$(/bin/bash "$P" run --every abc 2>&1); rc=$?
check 'run --every with a bad value: usage error' '[ "$rc" = 2 ]'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
