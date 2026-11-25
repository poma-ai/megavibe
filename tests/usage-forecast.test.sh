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

# ramp FROM_H_AGO TO_H_AGO P_START P_END RESET [LAG]: a reading every 10 minutes, linear in used percent (fractional: only the
# arithmetic is under test); LAG subtracts that many points from every other reading (a session whose figure lags)
ramp() { awk -v n="$NOW" -v a="$1" -v b="$2" -v p0="$3" -v p1="$4" -v r="$5" -v lag="${6:-0}" 'BEGIN {
  k = int((a - b) * 6); for (i = 0; i <= k; i++) { h = a - (a - b) * i / k; p = p0 + (p1 - p0) * i / k - ((i % 2) ? lag : 0);
  printf "{\"t\":%d,\"sd\":{\"p\":%.3f,\"r\":%d}}\n", n - h * 3600, p, r } }'; }

# steady 1 point per hour for 30 hours
ramp 30 0 25 55 $R > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'steady: pace 1.0, forecast 55 + 83.3 = 138.3, basis 6h+24h' 'near "$(f 3)" 1.0 0.06 && near "$(f 4)" 138.3 5 && [ "$(f 7)" = "6h+24h" ]'
check 'steady: spend per hour to reach the target is (95-55)/83.33' 'near "$(f 6)" 0.48 0.01'
check 'steady: the 7-day pace forecast is the eighth field' '[ -n "$(f 8)" ]'

# several sessions, one lagging a point behind on every other reading: row-to-row changes would sum to far more than the
# true rise (30 points of rise would read as about 90); the highest-reading method stays at the true pace
ramp 30 0 25 55 $R 1 > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'lagging sessions: pace stays about 1.0 (never an inflated row-to-row sum)' 'near "$(f 3)" 1.0 0.15'

# burst: flat for a day, then 13 points in the last hour
{ ramp 30 1 41 41 $R; ramp 1 0 41 54 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'burst: the 6 h pace dominates, forecast above 150' 'awk -v x="$(f 4)" "BEGIN{exit !(x > 150)}"'

# quiet: nothing used for 30 hours -> forecast is the used percent
ramp 30 0 30 30 $R > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'quiet: zero pace, forecast equals used' 'near "$(f 3)" 0 0.001 && near "$(f 4)" 30'

# short history: one reading has no trailing pace (window average stands in); two readings an hour apart do
row 0 55 $R > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'one reading in a window that began inside the 7-day horizon: 7-day pace' '[ "$(f 7)" = 7d ] && [ -n "$(f 4)" ]'
{ row 1 54 $R; row 0 55 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'two readings an hour apart: a trailing pace of 1 per hour, not the window average' 'near "$(f 3)" 1.0 0.01 && [ "$(f 7)" = "6h+24h" ]'

# a lagging low reading inside the window never breaks the pace: the highest readings decide
{ ramp 30 10 40 50 $R; row 8 49 $R; ramp 6 0 51 55 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'a lagging low reading inside the window: still a trailing pace' '[ "$(f 7)" = "6h+24h" ]'

# the reset boundary: a window that began 3 h ago, after the previous window rose from 56 to 62
NR=$((NOW + 604800 - 3 * 3600)); OR=$((NOW - 3 * 3600))
{ ramp 6 3 56 62 $OR; ramp 3 0 0 3 $NR; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'reset boundary: used 3, pace counts the old window rise plus the new reading over 6 h, 1.5 per hour' 'near "$(f 2)" 3 0.01 && near "$(f 3)" 1.5 0.3 && [ "$(f 7)" != week ]'
# the very first minute of a window: the new reading counts as used since the reset
{ ramp 10 1 40 61 $((NOW - 60)); row 0 1 $((NOW + 604800 - 60)); } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'first minute of a window: a forecast exists (used 1 + pace x 168 h), never blank' '[ -n "$(f 4)" ] && near "$(f 2)" 1 0.01 && awk -v x="$(f 4)" "BEGIN{exit !(x > 1)}"'
# a window outside every horizon adds nothing
{ row 400 99 $((NOW - 604800 - 1000)); ramp 6 0 10 16 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'an old window outside every horizon adds nothing' 'near "$(f 3)" 1.0 0.1'

# a late-logged row of a window that ended before the horizon began is no use inside it (reader finding: 0% became 250%)
OLD=$((NOW - 7 * 3600))
{ printf '{"t":%s,"sd":{"p":50,"r":%s}}\n' "$((NOW - 30 * 3600))" "$OLD"; printf '{"t":%s,"sd":{"p":60,"r":%s}}\n' "$((NOW - 3600))" "$OLD"; ramp 5 0 0 0 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'late row of a window that ended before the 6 h horizon: no phantom 6 h burn (pace stays under 0.3, was 1.2)' 'awk -v x="$(f 3)" "BEGIN{exit !(x < 0.3)}"'

# reset timestamps a couple of seconds apart (two sessions) are one window, not two
{ ramp 12 0 20 32 $R; ramp 12 0 19 31 $((R + 2)) ; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'reset jitter of 2 s: one window, pace about 1 per hour' 'near "$(f 3)" 1.0 0.25'

# a fresh first-minute reading with no other history: never blank
row 0 1 $((NOW + 604800 - 60)) > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'single reading 60 s after the reset: forecast exists, basis week' '[ "$(f 7)" = week ] && [ -n "$(f 4)" ]'

# history that begins inside the horizon: a lagging low reading later does not erase the first one
{ row 5 30 $R; row 4 29 $R; row 0 31 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'lagging reading in a window with no older baseline: used is 31 - 30 over the span' 'near "$(f 3)" 0.2 0.1'

# a gap in readings must not overstate the pace: 50 at 10 h ago, then silence, then 53 flat for the last 30 minutes
{ row 10 50 $R; ramp 0.5 0 53 53 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'gap after the baseline: the 3 points count over each horizon (a stretch with no rows is not guessed at)' 'near "$(f 3)" 0.42 0.05'
# reset times that wobble across a half hour (two sessions, one minute apart) are one window
{ ramp 12 0 20 32 $((NOW + 300000 - 1830 + 1800 + 30)); ramp 12 0 19 31 $((NOW + 300000 - 1830 + 1800 - 30)); } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'reset wobble of one minute across a half hour: one window, pace about 1 per hour' 'near "$(f 3)" 1.0 0.3'

# dense history with one lagging low reading far back: the baseline is the NEWEST reading before the horizon, so a
# one-point lag does not look like a 30 h gap (reader finding: forecast 72 instead of 114)
{ row 30 50 $R; ramp 29.9 6.1 49 49 $R; ramp 6 0 50 56 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'dense lagging baseline: both paces counted over their horizons, forecast about 114 (was 72 when read as a 30 h gap)' 'near "$(f 3)" 0.7 0.15 && near "$(f 4)" 114 6'
# a fresh reading whose reset is a minute or two past one window ahead (reset jitter) is still a forecast
{ row 0 1 $((NOW + 604800 + 90)); row 0 1 $((NOW + 604800 - 60)); } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'first minute with a reset 90 s beyond a window ahead: not blank' '[ -n "$(f 4)" ]'
# speed: 5000 flat readings must stay far under the advisory 3 s budget
awk -v n="$NOW" -v r="$R" 'BEGIN { for (i = 5000; i >= 0; i--) printf "{\"t\":%d,\"sd\":{\"p\":40,\"r\":%d}}\n", n - i * 10, r }' > "$MEGAVIBE_USAGE_FILE"
start=$SECONDS; o=$(fc)
check '5000 readings: the forecast returns in under 2 s' '[ $((SECONDS - start)) -lt 2 ] && [ -n "$(f 4)" ]'

# three sessions whose reset stamps chain 2 minutes apart (R, R+120, R+240) are still one window
{ ramp 30 0 25 55 $R; ramp 30 0 25 55 $((R + 120)); ramp 30 0 25 55 $((R + 240)); } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'chained reset jitter: one window, pace about 1 per hour (was 2-3)' 'near "$(f 3)" 1.0 0.15'
# two readings at the same second: the order they were written in cannot change the forecast
{ printf '{"t":%s,"sd":{"p":29,"r":%s}}\n{"t":%s,"sd":{"p":30,"r":%s}}\n' "$((NOW - 7200))" "$R" "$((NOW - 7200))" "$R"; row 0 30 $R; } > "$MEGAVIBE_USAGE_FILE"
a=$(fc)
{ printf '{"t":%s,"sd":{"p":30,"r":%s}}\n{"t":%s,"sd":{"p":29,"r":%s}}\n' "$((NOW - 7200))" "$R" "$((NOW - 7200))" "$R"; row 0 30 $R; } > "$MEGAVIBE_USAGE_FILE"
b=$(fc)
check 'same-second readings in either order: same forecast' '[ "$a" = "$b" ]'

# an idle night (no rows for 14 h, no session open) is not spread over the horizon as uniform use, and a concurrent window of
# another account interleaved in the file is not summed in
{ ramp 40 17 20 20 $R; ramp 3 0 20 26 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'idle gap, then 6 points in the last 3 h: a 6 h pace above 0.5' 'awk -v x="$(f 3)" "BEGIN{exit !(x > 0.5)}"'
OTHER=$((R + 172800))
{ ramp 30 0 25 55 $R; ramp 30 0 25 55 $OTHER; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'a second account (overlapping window) interleaved: pace stays about 1 per hour' 'near "$(f 3)" 1.0 0.15'

# Codex cache: a warm cache of a window that has since reset must not hide the new window (real clock: the cache is off under
# a pinned MEGAVIBE_NOW)
RT=$(mktemp -d "$T/rt.XXXXXX"); mkdir -p "$RT/sessions/y"; N0=$(date +%s)
ts0() { jq -nr --argjson t "$1" '$t | todateiso8601'; }
cx() { printf '{"timestamp":"%s","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s}}}}\n' "$(ts0 "$1")" "$2" "$3"; }
{ cx "$((N0 - 7200))" 40 "$((N0 + 2))"; cx "$((N0 - 60))" 50 "$((N0 + 2))"; } > "$RT/sessions/y/rollout-1.jsonl"
env -u MEGAVIBE_NOW MEGAVIBE_CODEX_HOME="$RT" MEGAVIBE_ROUTER_PROVIDER=codex /bin/bash "$REPO/scripts/usage-route.sh" forecast > /dev/null
sleep 3
cx "$(date +%s)" 1 "$((N0 + 604800))" >> "$RT/sessions/y/rollout-1.jsonl"
o=$(env -u MEGAVIBE_NOW MEGAVIBE_CODEX_HOME="$RT" MEGAVIBE_ROUTER_PROVIDER=codex /bin/bash "$REPO/scripts/usage-route.sh" forecast)
check 'codex warm cache across a reset: the new window is seen at once, not blank' '[ -n "$(f 4)" ]'

# stale reading (older than 6 h inside a live window): unknown, never spare capacity
{ row 9 50 $R; row 8 51 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'stale reading: empty forecast' '[ -z "$(f 4)" ]'

# no data / missing file
rm -f "$MEGAVIBE_USAGE_FILE"
o=$(fc)
check 'no history: provider and empty fields, exit 0' '[ "$o" = "claude|||||||" ]'

# target override
ramp 30 0 25 55 $R > "$MEGAVIBE_USAGE_FILE"
o=$(MEGAVIBE_USAGE_TARGET=100 fc)
check 'target 100: spare is 100 minus the forecast' 'near "$(f 5)" "$(awk -v x="$(f 4)" "BEGIN{print 100-x}")" 0.2'

# every output has exactly seven fields, also for no evidence; a junk target falls back to 95
{ row 30 40 $R; row 0 55 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(MEGAVIBE_USAGE_TARGET=abc fc)
check 'forecast with evidence: eight fields; junk target uses 95' '[ "$(printf "%s" "$o" | tr -cd "|" | wc -c | tr -d " ")" = 7 ] && near "$(f 5)" "$(awk -v x="$(f 4)" "BEGIN{print 95-x}")" 0.2'
# no history at all: still eight fields
rm -f "$MEGAVIBE_USAGE_FILE"; o=$(fc)
check 'no history: eight fields' '[ "$(printf "%s" "$o" | tr -cd "|" | wc -c | tr -d " ")" = 7 ]'

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
check 'codex, two readings an hour apart: a trailing pace of 1 per hour' '[ "$(f 7)" = "6h+24h" ] && near "$(f 3)" 1 0.01'
{ codex "$((NOW - 30 * 3600))" 10 "$R"; codex "$((NOW - 6 * 3600))" 16 "$R"; codex "$NOW" 20 "$R"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'codex, 30 h of readings: 6h+24h blend' '[ "$(f 7)" = "6h+24h" ] && awk -v x="$(f 3)" "BEGIN{exit !(x > 0.8 && x < 1.6)}"'

{ codex "$((NOW - 29 * 3600))" 20 "$R"; codex "$((NOW - 23 * 3600))" 32 "$R"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'codex readings 29 h and 23 h ago: only the 24 h horizon holds one (12 points over the 24 h horizon)' '[ "$(f 7)" = 24h ] && near "$(f 3)" 0.5 0.05'

# probe-style history: one rollout file per half-hour reading over 24 h must all count (the forecast reads up to 3000 files, not 6)
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
ramp 30 0 25 55 $R > "$MEGAVIBE_USAGE_FILE"
{ codex "$((NOW - 30 * 3600))" 20 "$R"; codex "$((NOW - 6 * 3600))" 20 "$R"; codex "$NOW" 20 "$R"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=claude /bin/bash "$REPO/scripts/usage-route.sh" balance --peek)
check 'balance: prefers codex and names the recent-pace forecast' '[[ "$o" == codex\|*"recent-pace forecast ~1"* ]]'

# Codex: one rollout per call, 140 calls three minutes apart over 7 h (flat 20, then a rise to 26 in the last 3 h). A file cap that
# keeps only the newest 60 loses the flat baseline and doubles the pace (reader finding: 106 points of forecast)
mkdir -p "$T/codex/sessions/many"; : > "$T/codex/sessions/x/rollout-1.jsonl"
for i in $(seq 0 139); do m=$((i * 3)); u=20; [ "$m" -lt 180 ] && u=$(awk -v m="$m" 'BEGIN { printf "%.2f", 20 + (180 - m) / 30 }'); codex "$((NOW - m * 60))" "$u" "$R" > "$T/codex/sessions/many/rollout-$(printf %03d $i).jsonl"; done
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'codex, 140 one-reading rollouts: the baseline beyond the newest 60 files counts (the cap is 3000) (pace about 1, not 2)' 'awk -v x="$(f 3)" "BEGIN{exit !(x > 0.7 && x < 1.3)}"'
rm -r "$T/codex/sessions/many"

# Codex: 481 one-reading rollouts, three minutes apart over 24 h (0 to 40 in the first 4 h, flat after): a file cap lost the rise
# (reader finding: 40 printed, 135 expected); all of them must be read, in a few seconds
mkdir -p "$T/codex/sessions/flood"; : > "$T/codex/sessions/x/rollout-1.jsonl"
for i in $(seq 0 480); do m=$((i * 3)); u=40; [ "$m" -gt 1200 ] && u=$(awk -v m="$m" 'BEGIN { printf "%.2f", 40 * (1440 - m) / 240 }'); [ "$m" -gt 1440 ] && u=0; codex "$((NOW - m * 60))" "$u" "$R" > "$T/codex/sessions/flood/rollout-$(printf %04d $i).jsonl"; done
start=$SECONDS; o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'codex, 481 rollouts over 24 h: the early rise is seen (forecast about 96, not 40) and the read takes under 6 s' '[ $((SECONDS - start)) -lt 6 ] && awk -v x="$(f 4)" "BEGIN{exit !(x > 80)}"'
rm -r "$T/codex/sessions/flood"

# Seven concurrent Codex streams, one rollout each every 3 minutes for 8 days (26880 files): the sampled forecast must match the same
# readings consolidated in one rollout within 2 points, in a few seconds (reader finding: 64.9 against 103.5 with a flat file cap)
FL="$T/codex/sessions/flood8"; mkdir -p "$FL"; : > "$T/codex/sessions/x/rollout-1.jsonl"
PREVR=$((R - 604800)); BASE=$(date +%s)
GEN='
  my ($dir, $now, $base, $r, $pr, $mode) = @ARGV; my $i = 0; my $one;
  if ($mode eq "one") { open($one, ">", "$dir/rollout-all.jsonl") or die }
  for my $m (reverse(0 .. 11520)) {
    next if $m % 3;
    my ($u, $rr) = $m < 4900 ? (20 + (4900 - $m) * 30 / 4900, $r) : (80 - ($m - 4900) * 40 / 6620, $pr);
    $u = 0 if $u < 0;
    for my $st (0 .. 6) {
      my $t = $now - $m * 60 - $st; my @g = gmtime($t);
      my $line = sprintf(q({"timestamp":"%04d-%02d-%02dT%02d:%02d:%02dZ","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":%.2f,"window_minutes":10080,"resets_at":%d}}}}) . "\n", $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0], $u, $rr);
      if ($mode eq "one") { print $one $line }
      else { my $f = sprintf("%s/rollout-%06d.jsonl", $dir, $i++); open(my $h, ">", $f) or die; print $h $line; close $h; my $mt = $base - $m * 60 - $st; utime($mt, $mt, $f) }
    }
  }'
perl -e "$GEN" "$FL" "$NOW" "$BASE" "$R" "$PREVR" many
start=$SECONDS; o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc); mt=$((SECONDS - start)); fm=$(f 4)
check 'codex, 26880 rollouts over 8 days: the sampled forecast is a number and the read takes under 6 s' '[ -n "$fm" ] && [ "$mt" -lt 6 ]'
rm -r "$FL"; mkdir -p "$FL"
perl -e "$GEN" "$FL" "$NOW" "$BASE" "$R" "$PREVR" one
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc); fc1=$(f 4)
check 'codex, 26880 rollouts: the sampled forecast is within 2 points of the consolidated forecast' 'near "$fm" "$fc1" 2'
rm -r "$FL"

# a 1.5 GB-equivalent set of rollout tails (450 files of 3.4 MB, sparse) finishes inside the budget with a number, not unknown
BG="$T/codex/sessions/big"; mkdir -p "$BG"
perl -e '
  my ($dir, $now, $base, $r) = @ARGV;
  for my $i (0 .. 449) { my $m = $i * 25; my $f = sprintf("%s/rollout-%04d.jsonl", $dir, $i); open(my $h, ">", $f) or die; truncate($h, 3_400_000); seek($h, 3_399_000, 0);
    my @g = gmtime($now - $m * 60); my $u = 20 + (11250 - $m) * 20 / 11250; $u = 20 if $m > 4900;
    printf $h "\n" . q({"timestamp":"%04d-%02d-%02dT%02d:%02d:%02dZ","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":%.2f,"window_minutes":10080,"resets_at":%d}}}}) . "\n", $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0], $u, $r;
    close $h; my $mt = $base - $m * 60; utime($mt, $mt, $f) }' "$BG" "$NOW" "$BASE" "$R"
start=$SECONDS; o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc); mt=$((SECONDS - start))
check 'codex, 450 files of 3.4 MB (1.5 GB of tails): a forecast, not unknown, inside 4 s' '[ -n "$(f 4)" ] && [ "$mt" -lt 4 ]'
rm -r "$BG"

# 222 rollouts over 8 days (every 10 minutes for 6 hours, then hourly), each a usage record followed by 6 MB of tool output (about 1.1 GB of tails: more than the default
# 128 MB budget can widen into): the budget must run out evenly, and the 24 h baseline survives (reader finding: 40 printed, 120 expected)
GENP='
  my ($dir, $now, $base, $r, $pad) = @ARGV;
  for my $h (0 .. 221) { my $m = $h < 36 ? $h * 10 : ($h - 30) * 60; my $u = $m < 1200 ? 40 : $m > 1440 ? 0 : 40 * (1440 - $m) / 240;
    my @g = gmtime($now - $m * 60); my $f = sprintf("%s/rollout-%04d.jsonl", $dir, $h); open(my $o, ">", $f) or die;
    printf $o q({"timestamp":"%04d-%02d-%02dT%02d:%02d:%02dZ","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":%.2f,"window_minutes":10080,"resets_at":%d}}}}) . "\n", $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0], $u, $r;
    if ($pad) { truncate($o, 6_000_000) } close $o; my $mt = $base - $m * 60; utime($mt, $mt, $f) }'
PD="$T/codex/sessions/padded"; mkdir -p "$PD"; : > "$T/codex/sessions/x/rollout-1.jsonl"
perl -e "$GENP" "$PD" "$NOW" "$BASE" "$R" 0
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc); fsmall=$(f 4)
rm -r "$PD"; mkdir -p "$PD"
perl -e "$GENP" "$PD" "$NOW" "$BASE" "$R" 1
o=$(MEGAVIBE_ROUTER_PROVIDER=codex fc); fpad=$(f 4)
check 'codex, 222 rollouts padded to 6 MB (far more than the budget widens into): within 2 points of the same readings unpadded' 'near "$fpad" "$fsmall" 2'
rm -r "$PD"

# the sampler reads at least 50 files whatever the clock says, and widens a slice that holds no record
mkdir -p "$T/codex/sessions/clk"; : > "$T/codex/sessions/x/rollout-1.jsonl"
for i in $(seq 0 59); do m=$((i * 3)); u=$(awk -v m="$m" 'BEGIN { printf "%.2f", 30 + (180 - m) / 12 }'); codex "$((NOW - m * 60))" "$u" "$R" > "$T/codex/sessions/clk/rollout-$(printf %03d $i).jsonl"; done
o=$(MEGAVIBE_ROLLOUT_SECONDS=0 MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'sampler with a zero time budget: still a forecast (the first 50 files are always read)' '[ -n "$(f 4)" ]'
rm -r "$T/codex/sessions/clk"
mkdir -p "$T/codex/sessions/pad"
for i in $(seq 0 19); do m=$((i * 60)); f="$T/codex/sessions/pad/rollout-$(printf %03d $i).jsonl"; codex "$((NOW - m * 60))" "$((20 + (1200 - m) / 40))" "$R" > "$f"; head -c 400000 /dev/zero | tr '\0' 'x' | fold -w 4000 >> "$f"; done
o=$(MEGAVIBE_ROLLOUT_BUDGET=200000 MEGAVIBE_ROUTER_PROVIDER=codex fc)
check 'sampler with a tiny per-file allowance and 400 KB of tool output after each record: the slice is widened, a forecast is printed' '[ -n "$(f 4)" ]'
rm -r "$T/codex/sessions/pad"

# an EMPTY warm cache hides the first valid reading for seconds, not two minutes
RE=$(mktemp -d "$T/re.XXXXXX"); mkdir -p "$RE/sessions/z"; N1=$(date +%s)
: > "$RE/sessions/z/rollout-1.jsonl"
env -u MEGAVIBE_NOW MEGAVIBE_CODEX_HOME="$RE" MEGAVIBE_ROUTER_PROVIDER=codex /bin/bash "$REPO/scripts/usage-route.sh" forecast > /dev/null
cx "$N1" 2 "$((N1 + 400000))" >> "$RE/sessions/z/rollout-1.jsonl"
sleep 16
o=$(env -u MEGAVIBE_NOW MEGAVIBE_CODEX_HOME="$RE" MEGAVIBE_ROUTER_PROVIDER=codex /bin/bash "$REPO/scripts/usage-route.sh" forecast)
check 'codex, empty warm cache then a first reading: seen after 15 s, not hidden for 2 minutes' '[ -n "$(f 4)" ]'

# ---- the probe: run by the PA's node only, throttled, never scheduled by itself -----------------------------------
cat > "$T/bin/codex" <<'STUB'
#!/bin/bash
[ "${1:-}" = exec ] && [ "${2:-}" = "--help" ] && exit 0
[ "${1:-}" = login ] && { echo "Logged in using ChatGPT"; exit 0; }
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
