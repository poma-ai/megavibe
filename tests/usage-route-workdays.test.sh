#!/bin/bash
# /bin/bash tests/usage-route-workdays.test.sh — fixtures only (HOME, settings, Codex all temporary).
# MEGAVIBE_WORK_DAYS makes the weekly projection count only the hours of the working days.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/usage-route-wd.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
near() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a != "" && a-b < .01 && b-a < .01)}'; }
mkdir -p "$T/home" "$T/mv/usage"
export TZ=UTC HOME="$T/home" MEGAVIBE_HOME="$T/mv" MEGAVIBE_ROUTER_PROVIDER=claude
export MEGAVIBE_USAGE_FILE="$T/mv/usage/claude.jsonl" MEGAVIBE_USAGE_STATE="$T/mv/usage/state.json"
export MEGAVIBE_USER_SETTINGS="$T/settings.json" MEGAVIBE_CODEX_HOME="$T/codex" MEGAVIBE_CODEX_STATE="$T/mv/usage/codex-state.json"
unset MEGAVIBE_WORK_DAYS
FRI17=1794589200; THU10=1795082400; SUN12=1794744000; MON10=1794823200; FRI13=1794574800; FRI2330=1794612600
route() { /bin/bash "$REPO/scripts/usage-route.sh" "$@" 2>/dev/null; }
pace() { MEGAVIBE_NOW=$1 route pace | cut -d'|' -f"$2"; }
rows() { : > "$MEGAVIBE_USAGE_FILE"; while [ $# -gt 0 ]; do printf '{"t":%s,"sd":{"p":%s,"r":%s}}\n' "$1" "$2" "$3" >> "$MEGAVIBE_USAGE_FILE"; shift 3; done; }

# Window Thu 10:00 -> Thu 10:00 (UTC). Fri 17:00: 31 h elapsed of 168 calendar hours, of 120 working hours (Mon-Fri).
rows $FRI17 20 $THU10
check 'unset: calendar time, as before (elapsed 18.45%, linear 108.39)' 'near "$(pace $FRI17 3)" 18.452 && near "$(pace $FRI17 4)" 108.387'
check 'mon-fri: working time (elapsed 25.83%, linear 77.42)' 'near "$(MEGAVIBE_WORK_DAYS=mon-fri pace $FRI17 3)" 25.833 && near "$(MEGAVIBE_WORK_DAYS=mon-fri pace $FRI17 4)" 77.419'
check 'all and the full list equal unset' '[ "$(MEGAVIBE_WORK_DAYS=all pace $FRI17 4)" = "$(pace $FRI17 4)" ] && [ "$(MEGAVIBE_WORK_DAYS="Sun,Mon,Tue,Wed,Thu,Fri,Sat" pace $FRI17 4)" = "$(pace $FRI17 4)" ]'
check 'spellings: "Monday tue wed thu Friday" equals mon-fri' '[ "$(MEGAVIBE_WORK_DAYS="Monday tue wed thu Friday" pace $FRI17 4)" = "$(MEGAVIBE_WORK_DAYS=mon-fri pace $FRI17 4)" ]'
check 'invalid value falls back to calendar time' '[ "$(MEGAVIBE_WORK_DAYS=mon-xyz pace $FRI17 4)" = "$(pace $FRI17 4)" ] && [ "$(MEGAVIBE_WORK_DAYS=mo pace $FRI17 4)" = "$(pace $FRI17 4)" ]'
rows $SUN12 20 $THU10
# Friday ends at Sat 00:00 (38 working hours); Sunday noon adds none, while the calendar adds 36 hours.
check 'a weekend without use leaves the mon-fri projection where Friday ended (63.16)' 'near "$(MEGAVIBE_WORK_DAYS=mon-fri pace $SUN12 4)" 63.158'
check 'the calendar projection falls over the same weekend (45.41)' 'near "$(pace $SUN12 4)" 45.405'

# Settings file: read when the variable is unset; the variable wins when set.
rows $FRI17 20 $THU10
printf '{"env":{"MEGAVIBE_WORK_DAYS":"mon-fri"}}\n' > "$MEGAVIBE_USER_SETTINGS"
check 'settings env block is read' 'near "$(pace $FRI17 4)" 77.419'
check 'the variable overrides the settings file' 'near "$(MEGAVIBE_WORK_DAYS=all pace $FRI17 4)" 108.387'
printf '{"env":{"MEGAVIBE_WORK_DAYS":5}}\n' > "$MEGAVIBE_USER_SETTINGS"
check 'a non-string setting is ignored' 'near "$(pace $FRI17 4)" 108.387'
printf 'not json' > "$MEGAVIBE_USER_SETTINGS"
check 'an unreadable settings file is calendar time' 'near "$(pace $FRI17 4)" 108.387'
rm -f "$MEGAVIBE_USER_SETTINGS"

# Recent estimate: 10% -> 20% from Fri 13:00 to 17:00 is 60 points a day, spent only on the working hours left
# (Fri 7 h + Mon-Wed 72 h + Thu 10 h = 89 h) instead of 137 calendar hours.
rows $FRI13 10 $THU10 $FRI17 20 $THU10
check 'recent: calendar 362.5' 'near "$(pace $FRI17 6)" 362.5'
check 'recent: mon-fri 242.5' 'near "$(MEGAVIBE_WORK_DAYS=mon-fri pace $FRI17 6)" 242.5'

# Local time decides the day: at Fri 23:30 UTC it is already Saturday in UTC+1.
rows $FRI2330 20 $THU10
check 'UTC: Friday counts until 23:30 (37.5 of 120 h)' 'near "$(MEGAVIBE_WORK_DAYS=mon-fri pace $FRI2330 3)" 31.25'
check 'UTC+1: Friday is over (37 of 120 h)' 'near "$(TZ=Etc/GMT-1 MEGAVIBE_WORK_DAYS=mon-fri pace $FRI2330 3)" 30.833'

# Bands. Window Mon 10:00 -> Mon 10:00; Fri 17:00 is 103 h of 168 calendar, 103 h of 120 working.
# 65% used projects to 106% over the calendar (over) and to 76% over the working week (normal).
rows $FRI17 65 $MON10
rm -f "$MEGAVIBE_USAGE_STATE"
check 'calendar: 65% by Friday is over' '[ "$(MEGAVIBE_NOW=$FRI17 route band)" = over ]'
rm -f "$MEGAVIBE_USAGE_STATE"
check 'mon-fri: 65% by Friday is normal' '[ "$(MEGAVIBE_WORK_DAYS=mon-fri MEGAVIBE_NOW=$FRI17 route band)" = normal ]'
rm -f "$MEGAVIBE_USAGE_STATE"
check 'status carries the working-week projection' '[ "$(MEGAVIBE_WORK_DAYS=mon-fri MEGAVIBE_NOW=$FRI17 route status --peek | cut -d"|" -f3)" = 75 ]'

# Codex runs the same engine.
mkdir -p "$T/codex/sessions/x"
ts=$(jq -nr --argjson t "$((FRI17 - 60))" '$t | todateiso8601')
printf '{"timestamp":"%s","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":65,"window_minutes":10080,"resets_at":%s},"secondary":null}}}\n' "$ts" "$MON10" > "$T/codex/sessions/x/rollout-1.jsonl"
rm -f "$MEGAVIBE_CODEX_STATE"
check 'codex calendar: over' '[ "$(MEGAVIBE_NOW=$FRI17 route codex-band)" = over ]'
rm -f "$MEGAVIBE_CODEX_STATE"
check 'codex mon-fri: normal' '[ "$(MEGAVIBE_WORK_DAYS=mon-fri MEGAVIBE_NOW=$FRI17 route codex-band)" = normal ]'

printf 'usage-route-workdays: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
