#!/bin/bash
# /bin/bash tests/usage-sprint.test.sh — fixtures only: scratch HOME, synthetic usage histories, no real quota files.
# Covers `usage-route.sh sprint` and `sprint-advice` (the end-of-window exception to the 95% target) and that the
# existing modes are untouched by it.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/usage-sprint.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
NOW=1793109600
mkdir -p "$T/home" "$T/mv/usage" "$T/codex/sessions/x"
export HOME="$T/home" MEGAVIBE_HOME="$T/mv" MEGAVIBE_NOW=$NOW
export MEGAVIBE_USAGE_FILE="$T/mv/usage/claude.jsonl" MEGAVIBE_USAGE_STATE="$T/mv/usage/state.json"
export MEGAVIBE_CODEX_HOME="$T/codex" MEGAVIBE_CODEX_STATE="$T/mv/usage/codex-state.json"
export MEGAVIBE_USER_SETTINGS="$T/settings.json" MEGAVIBE_ROUTER_PROVIDER=claude
unset MEGAVIBE_USAGE_TARGET MEGAVIBE_SPRINT MEGAVIBE_SPRINT_TARGET MEGAVIBE_SPRINT_HOURS
UR="$REPO/scripts/usage-route.sh"
row() { printf '{"t":%s,"sd":{"p":%s,"r":%s}}\n' "$((NOW - $1 * 60))" "$2" "$3"; }          # MINUTES_AGO USED RESET
rowfh() { printf '{"t":%s,"sd":{"p":%s,"r":%s},"fh":{"p":%s,"r":%s}}\n' "$((NOW - $1 * 60))" "$2" "$3" "$4" "$((NOW + 3600))"; }
sp() { /bin/bash "$UR" sprint; }
f() { printf '%s\n' "$o" | cut -d'|' -f"$1"; }   # 1 provider 2 state 3 hours_left 4 used 5 forecast 6 spare 7 spend 8 basis 9 reason
near() { awk -v a="$1" -v b="$2" -v e="${3:-0.15}" 'BEGIN {exit !(a != "" && a-b <= e && b-a <= e)}'; }
nf() { printf '%s' "$o" | tr -cd '|' | wc -c | tr -d ' '; }
R=$((NOW + 9000))   # 2.5 h left in the weekly window

# the case the rule was written for: 2.5 h left, 90 used, slow pace -> about 8 points spare below 99
{ row 1500 84 $R; row 720 87 $R; row 360 89 $R; row 120 90 $R; row 5 90 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'sprint: 2.5 h left, forecast ~90.6 -> state sprint, nine fields' '[ "$(f 1)" = claude ] && [ "$(f 2)" = sprint ] && [ "$(nf)" = 9 ] && [ "$(f 9)" = ok ]'
check 'sprint: hours left 2.5, used 90' 'near "$(f 3)" 2.5 0.05 && [ "$(f 4)" = 90 ]'
check 'sprint: spare is 99 minus the forecast, spend is (99-estimated use now)/2.5 = 3.59 per hour' 'near "$(f 6)" "$(awk -v x="$(f 5)" "BEGIN{print 99-x}")" 0.11 && near "$(f 7)" 3.59 0.02 && awk -v s="$(f 6)" "BEGIN{exit !(s > 7 && s < 9)}"'
check 'sprint mode writes no routing state' '[ ! -e "$MEGAVIBE_USAGE_STATE" ]'
fo=$(/bin/bash "$UR" forecast)
check 'forecast mode still measures against 95 (spare about 4.4), untouched by the sprint target' 'near "$(printf "%s" "$fo" | cut -d"|" -f5)" "$(awk -v x="$(printf "%s" "$fo" | cut -d"|" -f4)" "BEGIN{print 95-x}")" 0.11'

# more than 4 hours left: no sprint, whatever the room
R6=$((NOW + 6 * 3600))
{ row 1500 60 $R6; row 360 61 $R6; row 5 62 $R6; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'six hours left: not a sprint (reason outside), still nine fields' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = outside ] && [ "$(nf)" = 9 ] && [ -z "$(f 6)" ]'
o=$(MEGAVIBE_SPRINT_HOURS=8 sp)
check 'MEGAVIBE_SPRINT_HOURS=8 widens the window' '[ "$(f 2)" = sprint ]'
o=$(MEGAVIBE_SPRINT_HOURS=abc sp)
check 'a junk hours value falls back to 4' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = outside ]'

# exactly at the edge: 4 h left counts
R4=$((NOW + 4 * 3600))
{ row 1500 60 $R4; row 360 61 $R4; row 5 62 $R4; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'exactly four hours left: sprint' '[ "$(f 2)" = sprint ]'

# no room: the forecast already reaches 99 (fast pace), or used is there
{ row 1500 60 $R; row 360 80 $R; row 120 92 $R; row 5 96 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'fast pace, forecast over 99: no sprint (reason no-room)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ]'
{ row 1500 97 $R; row 360 98 $R; row 5 99 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'used already 99: no sprint' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ]'
{ row 1500 97 $R; row 360 97 $R; row 5 98 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'less than one point of room (whole-percent readings): no sprint' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ]'
# margin: a whole-percent reading of 98 can be 98.9, and other sessions are spending too: two points of room are the minimum
{ row 1500 98 $R; row 360 98 $R; row 5 98 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'quiet at 98, exactly one point to 99: no sprint (two points are the minimum)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ]'
{ row 1500 97 $R; row 360 97 $R; row 5 97 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'quiet at 97, two points to 99: sprint' '[ "$(f 2)" = sprint ] && near "$(f 6)" 2 0.05'
{ row 1500 96 $R; row 360 96 $R; row 5 97 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'at 97 with a pace that leaves 1.6 points: no sprint (no rounding up to the minimum)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ]'

# a reading older than 35 minutes is no basis for spending the last points (Claude counts as stale only after 6 h)
{ row 1500 84 $R; row 360 89 $R; row 90 90 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'newest reading 90 minutes old: no sprint (reason no-forecast)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-forecast ]'
fo=$(/bin/bash "$UR" forecast)
check 'the same history still has an ordinary forecast (the one-hour rule is the sprint'"'"'s own)' '[ -n "$(printf "%s" "$fo" | cut -d"|" -f4)" ]'

{ row 1500 84 $R; row 360 89 $R; row 40 90 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'newest reading 40 minutes old: no sprint (35 minutes is the limit)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-forecast ]'
{ row 1500 84 $R; row 360 89 $R; row 30 90 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'newest reading 30 minutes old: sprint (a 30-minute probe cadence must not flap)' '[ "$(f 2)" = sprint ]'
{ row 1500 84 $R; row 360 89 $R; row 5 90 $R; } > "$MEGAVIBE_USAGE_FILE"
fo=$(FSTALE=60 /bin/bash "$UR" forecast)
check 'an FSTALE in the environment does not reach the ordinary forecast' '[ -n "$(printf "%s" "$fo" | cut -d"|" -f4)" ]'

# a burst the 6 h / 24 h paces cannot see yet (readings under 2 h apart): 20 points in 95 minutes is not room to spend
{ row 1200 60 $R; row 100 70 $R; row 60 80 $R; row 5 90 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'burst in the last 90 minutes: the short pace counts, no sprint (reason no-room, basis says burst)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ] && [[ "$(f 8)" == *burst* ]]'
fo=$(/bin/bash "$UR" forecast)
check 'the ordinary forecast of the same history is untouched by the burst rule (basis 24h)' '[ "$(printf "%s" "$fo" | cut -d"|" -f7)" = 24h ]'
{ row 1200 84 $R; row 360 88 $R; row 80 89 $R; row 5 90 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'one point in 75 minutes with 2.5 h left is still a sprint (rated 2 points over 75 minutes, a small pace)' '[ "$(f 2)" = sprint ]'
# the last minutes: nothing useful can start, and the per-hour figure would be absurd
RL=$((NOW + 300)); { row 1500 84 $RL; row 360 89 $RL; row 5 90 $RL; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'five minutes left: not a sprint (reason outside)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = outside ]'

# a jump at the very end of a flat history: the steepest recent rise counts, not the average over 90 minutes
RJ=$((NOW + 1500))   # 25 minutes left
{ row 85 93 $RJ; row 60 93 $RJ; row 35 93 $RJ; row 15 93 $RJ; row 10 93 $RJ; row 5 96 $RJ; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'flat at 93 then 96 five minutes ago, 25 minutes left: no sprint (burst measured from the nearest reading)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ] && [[ "$(f 8)" == *burst* ]]'
# two points in five minutes near the limit is a burst too (whole-percent readings: the rise is counted one point short)
{ row 85 94 $RJ; row 60 94 $RJ; row 35 94 $RJ; row 15 94 $RJ; row 10 94 $RJ; row 5 96 $RJ; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check '94 then 96 five minutes ago, 25 minutes left: no sprint' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ] && [[ "$(f 8)" == *burst* ]]'
# an earlier one-point dip (unreliable trend) does not switch the burst check off
{ row 85 94 $RJ; row 60 93 $RJ; row 35 93 $RJ; row 15 93 $RJ; row 10 93 $RJ; row 5 96 $RJ; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check '94, a dip to 93, then 96 five minutes ago: still no sprint' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ]'
# usage between the newest reading and now is projected: 93 -> 95 over 30 minutes, 40 minutes ago, 30 minutes left
RP=$((NOW + 1800))
{ row 78 93 $RP; row 48 93 $RP; row 18 95 $RP; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'last reading 18 minutes old at 95 after a 2-point rise, 30 minutes left: no sprint (projected from the reading, not from now)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ]'
# a one-point rise in five minutes near the limit can be 95.0 -> 96.9
{ row 85 95 $RJ; row 60 95 $RJ; row 35 95 $RJ; row 15 95 $RJ; row 10 95 $RJ; row 5 96 $RJ; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'flat 95 then ONE point to 96 five minutes ago, 25 minutes left: a single tick is noise, so no burst term (known limit, decided: a burst that has not produced a two-point rise is invisible)' '[[ "$(f 8)" != *burst* ]]'
{ row 85 95 $RJ; row 60 95 $RJ; row 35 95 $RJ; row 15 95 $RJ; row 10 95 $RJ; row 5 97 $RJ; } > "$MEGAVIBE_USAGE_FILE"; o=$(sp)
check 'flat 95 then TWO points to 97 five minutes ago: a burst (rated 3 points over the 30-minute floor), no sprint' '[ "$(f 2)" = "-" ] && [[ "$(f 8)" == *burst* ]]'
# burst evidence does not age out of the lookback while the history is unchanged
RH=$((NOW + 3600))
{ row 89 94 $RH; row 40 96 $RH; } > "$MEGAVIBE_USAGE_FILE"; o=$(sp)
check 'readings 94 (89 min ago) and 96 (40 min ago), 60 minutes left: no sprint' '[ "$(f 2)" = "-" ]'
{ row 91 94 $RH; row 42 96 $RH; } > "$MEGAVIBE_USAGE_FILE"; o=$(sp)
check 'the same readings two minutes older: still no sprint (the lookback is anchored to the newest reading)' '[ "$(f 2)" = "-" ]'
# the advertised rate starts from the estimated use now, not from the old reading
{ row 80 90 $RP; row 18 92 $RP; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check '30 minutes left, 90 then 92 eighteen minutes ago: spend per hour is below (99-92)/0.5 = 14 (it starts from estimated use now)' 'awk -v s="$(f 7)" "BEGIN{exit !(s > 0 && s < 13.5)}"'
# flat 97 with a reading 40 minutes old is not fresh enough near the cap
{ row 1500 97 $R; row 360 97 $R; row 40 97 $R; } > "$MEGAVIBE_USAGE_FILE"; o=$(sp)
check 'flat 97, newest reading 40 minutes old: no sprint (no-forecast)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-forecast ]'
# an idle gap before the newest reading: the jump to the newest reading counts whatever the gap (no wall-clock cliff)
RG=$((NOW + 10800))
{ row 1440 70 $RG; row 360 80 $RG; row 300 80 $RG; row 100 80 $RG; row 0 88 $RG; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'idle for 100 minutes at 80, then 88: no sprint (the rise from the previous reading is rated whatever its age)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ] && [[ "$(f 8)" == *burst* ]]'
# an equal repeat reading must not erase a burst: 85 flat, 96 ten minutes ago, then 96 again five minutes ago, 25 minutes left
{ row 200 85 $RJ; row 105 85 $RJ; row 10 96 $RJ; } > "$MEGAVIBE_USAGE_FILE"; o=$(sp)
check 'jump 85 -> 96 ten minutes ago: no sprint' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ]'
{ row 200 85 $RJ; row 105 85 $RJ; row 10 96 $RJ; row 5 96 $RJ; } > "$MEGAVIBE_USAGE_FILE"; o=$(sp)
check 'the same plus an equal repeat reading five minutes ago: still no sprint (burst measured to the first reading at that level)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ] && [[ "$(f 8)" == *burst* ]]'
{ row 1500 60 $R; row 400 70 $R; row 100 70 $R; row 60 70 $R; row 5 70 $R; } > "$MEGAVIBE_USAGE_FILE"; o=$(sp)
check 'a rise that ended hours ago and is flat since is not a burst (the endpoint must be recent)' '[[ "$(f 8)" != *burst* ]]'
# five-hour window figure rides on the line
{ row 1500 84 $R; row 360 89 $R; rowfh 5 90 $R 40; } > "$MEGAVIBE_USAGE_FILE"; o=$(sp)
check 'the line carries the five-hour used percent as its tenth field' '[ "$(f 10)" = 40 ]'
o=$(/bin/bash "$UR" sprint-advice)
check 'the advice names the projected five-hour window when there is one' '[[ "$o" == *"five-hour window is projected at 40%"* ]]'
check 'the advice names the public command to re-read, not the uninstalled script path' '[[ "$o" == *"megavibe usage sprint"* ]] && [[ "$o" != *"usage-route.sh sprint"* ]]'
# steady use at 3 points per hour with 5-minute heartbeat rows and 3.8 h left is not a burst (the rise is rated over the
# time since the lower reading): true end about 84, so the sprint must stay on
RS=$((NOW + 13680))
: > "$MEGAVIBE_USAGE_FILE"
for m in $(seq 360 -5 0); do awk -v t=$((NOW - m * 60)) -v m=$m -v r=$RS 'BEGIN { printf "{\"t\":%d,\"sd\":{\"p\":%d,\"r\":%d}}\n", t, int(73.2 - 3 * m / 60), r }' >> "$MEGAVIBE_USAGE_FILE"; done
o=$(sp)
check 'steady 3 points/h at 73 with 3.8 h left: sprint (it read no-room, forecast 100.4, with a 15-minute floor and the span to the anchor)' '[ "$(f 2)" = sprint ]'
: > "$MEGAVIBE_USAGE_FILE"
for m in $(seq 360 -5 0); do awk -v t=$((NOW - m * 60)) -v m=$m -v r=$RS 'BEGIN { printf "{\"t\":%d,\"sd\":{\"p\":%d,\"r\":%d}}\n", t, int(79.2 - 2 * m / 60), r }' >> "$MEGAVIBE_USAGE_FILE"; done
o=$(sp)
check 'steady 2 points/h at 79 with 3.8 h left: sprint' '[ "$(f 2)" = sprint ]'
# two readings in the same epoch second (two sessions writing): the jump between them is still seen
RX=$((NOW + 1800))
printf '{"t":%s,"sd":{"p":90,"r":%s}}\n{"t":%s,"sd":{"p":94,"r":%s}}\n' "$((NOW - 300))" "$RX" "$((NOW - 300))" "$RX" > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'same-second 90 then 94 with 30 minutes left: a burst, no sprint' '[ "$(f 2)" = "-" ] && [[ "$(f 8)" == *burst* ]]'
# the two-point margin is applied before rounding: 97.04 forecast leaves 1.96, not 2.0
RM=$((NOW + 900))    # 15 minutes left
{ row 600 90 $RM; row 300 94 $RM; row 5 97 $RM; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'forecast just over 97.0: spare is rounded down, so no sprint' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ]'
{ row 1500 60 $R; row 360 62 $R; row 5 63 $R; } > "$MEGAVIBE_USAGE_FILE"
fo=$(SPRINT_BURST=1 /bin/bash "$UR" forecast); fo0=$(/bin/bash "$UR" forecast)
check 'SPRINT_BURST in the environment does not reach the ordinary forecast' '[ "$fo" = "$fo0" ] && [[ "$fo" != *burst* ]]'
fo=$(SPRINT_BURST=junk /bin/bash "$UR" forecast)
check 'a junk SPRINT_BURST does not blank it either' '[ "$fo" = "$fo0" ]'

# a five-hour surge: weekly flat at 72, five-hour 65 -> 84 within four minutes, 2 h left: the five-hour window projected over a
# 30-minute unit is over its cap, so no sprint (it advised the top tier, then withdrew when the window hit 100)
R2=$((NOW + 7200))
{ rowfh 1500 72 $R2 30; rowfh 360 72 $R2 40; rowfh 30 72 $R2 50; rowfh 8 72 $R2 65; rowfh 4 72 $R2 84; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'five-hour 65 -> 84 in four minutes: no sprint (5h-hot, the projected five-hour use is over the cap)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = 5h-hot ]'
{ rowfh 1500 72 $R2 30; rowfh 360 72 $R2 40; rowfh 30 72 $R2 50; rowfh 8 72 $R2 52; rowfh 4 72 $R2 54; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'five-hour 52 -> 54 in four minutes (a slow climb, projected under the cap): still a sprint' '[ "$(f 2)" = sprint ]'

# a five-hour RESET inside the last 30 minutes must not hide a surge in the new window: 96 from the expired window, then 62, 82, 84
FR=$((NOW + 16800)); FO=$((NOW - 1200))
printf '{"t":%s,"sd":{"p":72,"r":%s},"fh":{"p":96,"r":%s}}\n{"t":%s,"sd":{"p":72,"r":%s},"fh":{"p":62,"r":%s}}\n{"t":%s,"sd":{"p":72,"r":%s},"fh":{"p":82,"r":%s}}\n{"t":%s,"sd":{"p":72,"r":%s},"fh":{"p":84,"r":%s}}\n' \
  "$((NOW - 1500))" "$R2" "$FO" "$((NOW - 720))" "$R2" "$FR" "$((NOW - 480))" "$R2" "$FR" "$((NOW - 240))" "$R2" "$FR" > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'five-hour reset in the last 30 minutes (96 expired, then 62, 82, 84): 5h-hot, the surge in the live window is counted' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = 5h-hot ]'
# the line carries the PROJECTED five-hour use (used plus its climb over a 30-minute unit), not just the reading
{ rowfh 30 72 $R2 78; rowfh 15 72 $R2 80; rowfh 1 72 $R2 81; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'five-hour 78 -> 81 over 29 minutes: the tenth field is the projection (about 84), not 81' 'awk -v x="$(f 10)" "BEGIN{exit !(x > 83 && x < 86)}"'

# the five-hour window is hot: top-tier work would only hit that limit
{ row 1500 84 $R; row 360 89 $R; rowfh 5 90 $R 88; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'five-hour window at 88: no sprint (reason 5h-hot)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = 5h-hot ]'
{ row 1500 84 $R; row 360 89 $R; rowfh 5 90 $R 40; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'five-hour window at 40: sprint' '[ "$(f 2)" = sprint ]'

# a drop inside the window: trend unreliable, the week average stands in and is still a forecast
{ row 1500 80 $R; row 720 70 $R; row 5 90 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'drop in the window: the week average stands in (basis week, plus burst for the 20-point rise since the previous reading) and a decision is made' '[[ "$(f 8)" == week* ]] && [ -n "$(f 2)" ] && [ -n "$(f 5)" ]'

# knobs
{ row 1500 84 $R; row 720 87 $R; row 360 89 $R; row 120 90 $R; row 5 90 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(MEGAVIBE_SPRINT=0 sp)
check 'MEGAVIBE_SPRINT=0: off' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = off ] && [ "$(nf)" = 9 ]'
o=$(MEGAVIBE_SPRINT_TARGET=97 sp)
check 'MEGAVIBE_SPRINT_TARGET=97: spare and spend measured against 97' 'near "$(f 7)" 2.79 0.02 && [ "$(f 2)" = sprint ]'
o=$(MEGAVIBE_SPRINT_TARGET=150 sp)
check 'a sprint target over 100 is refused (falls back to 99): the backstop stays at 100' 'near "$(f 7)" 3.59 0.02'
o=$(MEGAVIBE_SPRINT_TARGET=100 sp)
check 'a sprint target of 100 is refused too (99): the sprint never aims at the limit itself' 'near "$(f 7)" 3.59 0.02'
o=$(MEGAVIBE_USAGE_TARGET=99 sp)
check 'ordinary target already at the sprint target: nothing to add (reason no-room)' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-room ]'

# no evidence
rm -f "$MEGAVIBE_USAGE_FILE"
o=$(sp)
check 'no history: provider, dash, empty fields, exit 0' '[ "$o" = "claude|-||||||||" ]'
: > "$MEGAVIBE_USAGE_FILE"; o=$(sp)
check 'empty history: same shape' '[ "$o" = "claude|-||||||||" ]'
row 5 90 $((NOW - 60)) > "$MEGAVIBE_USAGE_FILE"; o=$(sp)
check 'window already reset: no sprint' '[ "$(f 2)" = "-" ]'

# Codex: same rule on its own records; a reading from hours ago (stale only after 24 h there) is no basis
ts() { jq -nr --argjson t "$1" '$t | todateiso8601'; }
codex() { printf '{"timestamp":"%s","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s}}}}\n' "$(ts "$1")" "$2" "$3"; }
{ codex "$((NOW - 25 * 3600))" 50 "$R"; codex "$((NOW - 6 * 3600))" 55 "$R"; codex "$((NOW - 600))" 56 "$R"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex sp)
check 'codex, fresh reading, 2.5 h left at 56: sprint with about 42 points spare' '[ "$(f 1)" = codex ] && [ "$(f 2)" = sprint ] && awk -v s="$(f 6)" "BEGIN{exit !(s > 40 && s < 43.1)}"'
{ codex "$((NOW - 25 * 3600))" 50 "$R"; codex "$((NOW - 5 * 3600))" 56 "$R"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(MEGAVIBE_ROUTER_PROVIDER=codex sp)
check 'codex, newest reading five hours old: no sprint' '[ "$(f 2)" = "-" ] && [ "$(f 9)" = no-forecast ]'

# the two-minute Codex cache must not hide a fresh reading from the sprint decision (real clock: the cache is off under MEGAVIBE_NOW)
RN=$(date +%s); RR=$((RN + 7200)); mkdir -p "$T/codex2/sessions/x"
{ codex "$((RN - 25 * 3600))" 80 "$RR"; codex "$((RN - 5 * 3600))" 89 "$RR"; codex "$((RN - 120))" 90 "$RR"; } > "$T/codex2/sessions/x/rollout-1.jsonl"
cx() { env -u MEGAVIBE_NOW MEGAVIBE_CODEX_HOME="$T/codex2" MEGAVIBE_ROUTER_PROVIDER=codex /bin/bash "$UR" "$1"; }
cx forecast >/dev/null; o=$(cx sprint)
check 'codex on the real clock, 90 used, 2 h left: sprint' '[ "$(f 2)" = sprint ]'
codex "$RN" 100 "$RR" >> "$T/codex2/sessions/x/rollout-1.jsonl"
o=$(cx sprint)
check 'a 100 reading written seconds later ends the sprint at once (the cache is not trusted inside the window)' '[ "$(f 2)" = "-" ] && [ "$(f 4)" = 100 ]'
fo=$(cx forecast)
check 'the sprint did not refresh the shared forecast cache: the ordinary forecast still serves its cached 90 (no change for a session outside the sprint)' '[ "$(printf "%s" "$fo" | cut -d"|" -f2)" = 90 ]'
# a sprint call outside the window on a cold cache must not seed the shared cache either
rm -f "$T/mv/usage/codex-row-forecast.cache" "$T/mv/usage/codex-row.cache"
RO=$((RN + 6 * 3600))
{ codex "$((RN - 25 * 3600))" 60 "$RO"; codex "$((RN - 5 * 3600))" 64 "$RO"; codex "$((RN - 120))" 66 "$RO"; } > "$T/codex2/sessions/x/rollout-1.jsonl"
o=$(cx sprint)
check 'six hours left, cold cache: not a sprint' '[ "$(f 2)" = "-" ]'
codex "$RN" 77 "$RO" >> "$T/codex2/sessions/x/rollout-1.jsonl"
fo=$(cx forecast)
check 'a sprint call on a cold cache left nothing behind: the next ordinary forecast sees the new 77' '[ "$(printf "%s" "$fo" | cut -d"|" -f2)" = 77 ]'
# a cold cache is scanned ONCE by a sprint call (a second, "fresh" scan after a scan that already came from disk doubled the
# time and could cross the 2 s alarm)
mkdir -p "$T/shim"; REALFIND=$(command -v find)
printf '#!/bin/sh\necho x >> "%s/find.log"\nexec "%s" "$@"\n' "$T" "$REALFIND" > "$T/shim/find"; chmod +x "$T/shim/find"
rm -f "$T/mv/usage/codex-row-forecast.cache" "$T/mv/usage/codex-row.cache" "$T/find.log"
RR=$((RN + 7200))
{ codex "$((RN - 25 * 3600))" 60 "$RR"; codex "$((RN - 5 * 3600))" 66 "$RR"; codex "$((RN - 120))" 70 "$RR"; } > "$T/codex2/sessions/x/rollout-1.jsonl"
o=$(PATH="$T/shim:$PATH" cx sprint)
check 'cold cache, in the window: one scan only (find ran once), and it is a sprint' '[ "$(wc -l < "$T/find.log" | tr -d " ")" = 1 ] && [ "$(f 2)" = sprint ]'
# an EMPTY cached Codex result must not hide readings written since (the sprint re-reads once past the cache)
rm -f "$T/mv/usage/codex-row-forecast.cache" "$T/mv/usage/codex-row.cache"
: > "$T/codex2/sessions/x/rollout-1.jsonl"
cx forecast > /dev/null
RQ=$((RN + 7200))
{ codex "$((RN - 25 * 3600))" 60 "$RQ"; codex "$((RN - 5 * 3600))" 66 "$RQ"; codex "$((RN - 120))" 70 "$RQ"; } > "$T/codex2/sessions/x/rollout-1.jsonl"
o=$(cx sprint)
check 'codex: an empty cache from a moment ago, readings written since: sprint is found' '[ "$(f 2)" = sprint ]'

# `megavibe usage sprint` against an OLDER installed router (it has no sprint mode and runs its default, state-writing mode)
mkdir -p "$T/mvold/scripts" "$T/mvold/usage"
cat > "$T/mvold/scripts/usage-route.sh" <<'OLDR'
#!/bin/bash
[ "${2:-}" = "--peek" ] || echo touched > "${MEGAVIBE_HOME:-/nonexistent}/usage/route-state.json"
echo "over|sonnet|medium|7d 90% used"
OLDR
chmod +x "$T/mvold/scripts/usage-route.sh"
oe=$(HOME="$T/home" MEGAVIBE_HOME="$T/mvold" /bin/bash "$REPO/megavibe" usage sprint 2>&1 >/dev/null); orc=$?
check 'megavibe usage sprint with an older installed router: refuses with an upgrade message, exit 1, no state written' '[ "$orc" = 1 ] && [[ "$oe" == *"sprint"* ]] && [ ! -e "$T/mvold/usage/route-state.json" ]'
{ row 1500 84 $R; row 720 87 $R; row 360 89 $R; row 120 90 $R; row 5 90 $R; } > "$MEGAVIBE_USAGE_FILE"
ne=$(HOME="$T/home" MEGAVIBE_HOME="$T/mv" /bin/bash "$REPO/megavibe" usage sprint 2>/dev/null); nrc=$?
check 'megavibe usage sprint with the current router: both provider lines, the advice, exit 0, no routing state written' '[ "$nrc" = 0 ] && [[ "$ne" == claude\|sprint\|* ]] && [[ "$ne" == *$'"'"'\ncodex|'"'"'* ]] && [[ "$ne" == *"usage sprint: Claude"* ]] && [ ! -e "$MEGAVIBE_USAGE_STATE" ]'

# ---- sprint-advice: one sentence per sprinting subscription, nothing otherwise ------------------------------------
adv() { /bin/bash "$UR" sprint-advice; }
{ row 1500 84 $R; row 720 87 $R; row 360 89 $R; row 120 90 $R; row 5 90 $R; } > "$MEGAVIBE_USAGE_FILE"
o=$(adv)
check 'advice: one line, for Claude only (the Codex reading is old)' '[ "$(printf "%s\n" "$o" | grep -c .)" = 1 ] && [[ "$o" == "usage sprint: Claude "* ]]'
check 'advice names the numbers: hours, used, spare, per-hour, 99 and 95' '[[ "$o" == *"2.5 h"* ]] && [[ "$o" == *"90% used"* ]] && [[ "$o" == *"to 99%"* ]] && [[ "$o" == *"3.59 points per hour"* ]] && [[ "$o" == *"95%"* ]] && [[ "$o" == *"whole account"* ]]'
check 'advice says what to do and what does not move' '[[ "$o" == *"top model tier"* ]] && [[ "$o" == *"hardest open work"* ]] && [[ "$o" == *"100% backstop"* ]] && [[ "$o" == *"review floor"* ]]'
{ codex "$((NOW - 25 * 3600))" 50 "$R"; codex "$((NOW - 6 * 3600))" 55 "$R"; codex "$((NOW - 600))" 56 "$R"; } > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(adv)
check 'both sprinting: two lines, Claude then Codex' '[ "$(printf "%s\n" "$o" | grep -c .)" = 2 ] && [[ "$(printf "%s\n" "$o" | sed -n 2p)" == "usage sprint: Codex "* ]]'
mkdir -p "$T/noperl"; printf '#!/bin/sh\nexit 1\n' > "$T/noperl/perl"; chmod +x "$T/noperl/perl"
o=$(PATH="$T/noperl:$PATH" adv)
check 'a provider call that cannot run is reported as unknown, per provider, not as not-sprinting' '[ "$o" = "usage sprint-unknown: Claude
usage sprint-unknown: Codex" ]'
o=$(MEGAVIBE_SPRINT=0 adv)
check 'advice with MEGAVIBE_SPRINT=0: silent' '[ -z "$o" ]'
{ row 1500 60 $R6; row 360 61 $R6; row 5 62 $R6; } > "$MEGAVIBE_USAGE_FILE"; : > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(adv); rc=$?
check 'advice outside the window: silent, exit 0' '[ -z "$o" ] && [ "$rc" = 0 ]'
check 'sprint-advice writes no routing state either' '[ ! -e "$MEGAVIBE_USAGE_STATE" ] && [ ! -e "$MEGAVIBE_CODEX_STATE" ]'

# ---- the existing modes are unchanged inside a sprint window ------------------------------------------------------
{ row 1500 84 $R; row 720 87 $R; row 360 89 $R; row 120 90 $R; row 5 90 $R; } > "$MEGAVIBE_USAGE_FILE"
check 'band is still over at 90 used (the launch model choice does not sprint)' '[ "$(/bin/bash "$UR" band --peek)" = over ]'
o=$(/bin/bash "$UR" claude --peek)
check 'launch line unchanged: over|sonnet|medium' '[[ "$o" == "over|sonnet|medium|"* ]]'
o=$(/bin/bash "$UR" advisory --peek)
check 'the band advisory is the same sentence as before, no sprint text in it' '[[ "$o" == "usage router: Claude "*"reviewer subagent stays as pinned." ]] && [[ "$o" != *sprint* ]]'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
