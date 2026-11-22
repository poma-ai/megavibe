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

# balance leads with the forecast: Claude steady at 55 (forecast 97), Codex quiet at 20 -> lean on Codex, text shows the forecast
{ row 30 40 $R; row 24 43 $R; row 18 46 $R; row 12 49 $R; row 6 52 $R; row 0 55 $R; } > "$MEGAVIBE_USAGE_FILE"
{ codex "$((NOW - 30 * 3600))" 20 "$R"; codex "$((NOW - 6 * 3600))" 20 "$R"; codex "$NOW" 20 "$R"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=claude /bin/bash "$REPO/scripts/usage-route.sh" balance --peek)
check 'balance: prefers codex and names the recent-pace forecast' '[[ "$o" == codex\|*"recent-pace forecast ~96% by week end"* ]] || [[ "$o" == codex\|*"recent-pace forecast ~97% by week end"* ]]'

# ---- the probe is opt-in --------------------------------------------------------------------------------------
cat > "$T/bin/codex" <<'STUB'
#!/bin/bash
[ "${1:-}" = exec ] && [ "${2:-}" = "--help" ] && exit 0
printf '%s\n' "$*" >> "$STUB_LOG"
exit 0
STUB
cat > "$T/bin/launchctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LAUNCHCTL"
exit 1
STUB
chmod +x "$T/bin/codex" "$T/bin/launchctl"
export STUB_LOG="$T/codex.log" STUB_LAUNCHCTL="$T/launchctl.log" PATH="$T/bin:$PATH"
export MEGAVIBE_CODEX_BIN="$T/bin/codex" MEGAVIBE_PROBE_PLIST="$T/home/Library/LaunchAgents/com.megavibe.usage-probe.plist"
P="$REPO/scripts/usage-probe.sh"
o=$(/bin/bash "$P" status 2>&1)
check 'probe: not installed by default, no plist, no Codex call' '[[ "$o" == *"not installed (off"* ]] && [ ! -e "$MEGAVIBE_PROBE_PLIST" ] && [ ! -e "$STUB_LOG" ]'
check 'nothing else in the repo installs or calls the probe: only the subcommand and the script sync lists name it' \
  '! grep -rn "usage-probe" "$REPO/init.sh" "$REPO/template" "$REPO/scripts" --include=* 2>/dev/null | grep -v "^$REPO/scripts/usage-probe.sh" | grep -q .'
if [ "$(uname -s)" = Darwin ]; then
  o=$(/bin/bash "$P" install 45 2>&1)
  check 'install: writes the plist (45 min = 2700 s, RunAtLoad false) and only prints the load line' \
    '[ -f "$MEGAVIBE_PROBE_PLIST" ] && grep -q "<integer>2700</integer>" "$MEGAVIBE_PROBE_PLIST" && grep -q "<key>RunAtLoad</key><false/>" "$MEGAVIBE_PROBE_PLIST" && [[ "$o" == *"launchctl bootstrap"* ]] && ! grep -qE "bootstrap|bootout|load|kickstart" "$STUB_LAUNCHCTL"'
  o=$(MEGAVIBE_PROBE_MODEL=my-model MEGAVIBE_CODEX_HOME="$T/codex home" /bin/bash "$P" install 45 2>&1)
  check 'install: the chosen probe model and Codex home are kept in the plist' 'grep -q "<key>MEGAVIBE_PROBE_MODEL</key><string>my-model</string>" "$MEGAVIBE_PROBE_PLIST" && grep -q "<key>CODEX_HOME</key><string>$T/codex home</string>" "$MEGAVIBE_PROBE_PLIST"'
  check 'install: a bad interval is refused and nothing is written' '! /bin/bash "$P" install 5 >/dev/null 2>&1 && ! /bin/bash "$P" install abc >/dev/null 2>&1'
fi
export MEGAVIBE_CODEX_HOME="$T/codex-none"; mkdir -p "$T/codex-none/sessions"
/bin/bash "$P" run >/dev/null 2>&1
check 'run with no recent reading: one cheap read-only Codex call, logged' '[ "$(wc -l < "$STUB_LOG" | tr -d " ")" = 1 ] && grep -q -- "-s read-only" "$STUB_LOG" && grep -q -- "gpt-6-luna" "$STUB_LOG" && grep -q "rc=0" "$T/mv/usage/probe.log"'
mkdir -p "$T/codex-none/sessions/2026/11/22"; : > "$T/codex-none/sessions/2026/11/22/rollout-1.jsonl"
rm -f "$STUB_LOG"
o=$(/bin/bash "$P" run 2>&1)
check 'run with a Codex reading under 15 min old: skipped, no call' '[[ "$o" == *"under 15 min"* ]] && [ ! -e "$STUB_LOG" ]'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
