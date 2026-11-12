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
check 'percent drop with same reset starts a new sequence' 'near "$(field 5)" 4.8'
{ row "$((NOW - 21600))" 17 "$RESET"; row "$((NOW - 18000))" 18 "$((RESET + 60))"; row "$NOW" 19 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'different reset breaks sequence even when the old reset returns' '[ "$(field 5)$(field 6)" = "" ] && [ "$(field 2)" = 19 ]'
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
check 'duplicate timestamp cannot hide an intervening reset boundary' 'near "$(field 5)" 4.8'
{ row "$((NOW - 21600))" 17 "$RESET"; row "$((NOW - 18000))" 21 "$RESET"; row "$((NOW - 18000))" 19 "$RESET"; row "$NOW" 20 "$RESET"; } > "$MEGAVIBE_USAGE_FILE"
o=$(pace)
check 'duplicate timestamp cannot hide a percentage drop' 'near "$(field 5)" 4.8'
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
codex "$NOW" 19 "$RESET" > "$T/codex/sessions/x/rollout-1.jsonl"
o=$(pace)
check 'pace sees six-hour baseline beyond last 50 samples' 'near "$(field 5)" 4 && near "$(field 6)" 109'
o=$(route balance --peek)
check 'balance preference unchanged, both absolute estimates beside advice' '[[ "$o" == codex\|* ]] && [[ "$o" == *"Claude"*"~190%"*"recent estimate ~109%"*"Codex"*"[linear estimate ~135%]"*"Lean optional work"* ]]'
check 'pace and peek leave routing state untouched' '[ ! -e "$MEGAVIBE_USAGE_STATE" ] && [ ! -e "$MEGAVIBE_CODEX_STATE" ]'

# Run the real tick with fake auth/GitHub and no network.
printf '#!/bin/bash\ncase "$*" in "api user --jq .login") echo fixture ;; *) echo "[]" ;; esac\n' > "$T/bin/gh"
chmod +x "$T/bin/gh"
printf '{"claudeAiOauth":{"expiresAt":%s,"refreshTokenExpiresAt":%s}}\n' "$(((NOW + 86400) * 1000))" "$(((NOW + WEEK) * 1000))" > "$T/credentials.json"
o=$(MEGAVIBE_TICK_CONF="$T/no.conf" MEGAVIBE_GH="$T/bin/gh" MEGAVIBE_CLAUDE_CREDENTIALS="$T/credentials.json" TICK_LINEAR=0 /bin/bash "$REPO/scripts/tick.sh" --no-mark fixture/repo)
usage=$(printf '%s\n' "$o" | grep '^usage:')
check 'tick keeps first-line and one usage-line format with both projections' '[[ "$o" == "tick default: quiet | window "* ]] && [[ "$usage" == "usage: Claude 95% used"*"~190%"*"recent estimate ~109%"*" | Codex 19% used"*"[linear estimate ~135%]"*" | lean optional work on codex" ]] && [ "$(printf "%s\n" "$usage" | wc -l | tr -d " ")" = 1 ]'

# Byte-for-byte snapshots from the pre-change script, reproducing the existing early fixtures.
while IFS=';' read -r rem used prev expected; do
  row "$((NOW - 60))" "$used" "$((NOW + rem))" > "$MEGAVIBE_USAGE_FILE"
  codex "$((NOW - 60))" "$used" "$((NOW + rem))" > "$T/codex/sessions/x/rollout-1.jsonl"
  printf '{"band":"%s","since":%s,"pend":0,"calm":0,"mx":{}}\n' "$prev" "$((NOW - 7200))" > "$MEGAVIBE_USAGE_STATE"
  cp "$MEGAVIBE_USAGE_STATE" "$MEGAVIBE_CODEX_STATE"
  for provider in claude codex; do
    o=$(MEGAVIBE_ROUTER_PROVIDER=$provider route status --peek)
    check "$provider status unchanged: $expected" '[ "$o" = "$expected" ]'
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
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
