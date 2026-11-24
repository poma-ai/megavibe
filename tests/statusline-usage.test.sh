#!/bin/bash
# /bin/bash tests/statusline-usage.test.sh — template/statusline.sh usage record: a payload with and without a five_hour window.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/statusline-usage.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
fresh() { rm -rf "$T/mv"; mkdir -p "$T/mv"; }
run() { printf '%s' "$1" | HOME="$T/home" MEGAVIBE_HOME="$T/mv" /bin/bash "$REPO/template/statusline.sh" >/dev/null 2>&1; }
w() { HOME="$T/home" MEGAVIBE_HOME="$T/mv" MEGAVIBE_ROUTER_PROVIDER=claude /bin/bash "$REPO/scripts/usage-route.sh" windows; }
mkdir -p "$T/home"; fresh
check 'no record yet: unknown' '[[ "$(w)" == "windows: unknown"* ]]'

# Claude Code 2.1.331 on a Max plan sends only seven_day
run '{"session_id":"s1","rate_limits":{"seven_day":{"used_percentage":18,"resets_at":1796065200}}}'
check 'seven_day only: the row carries sd and a null fh' 'jq -e ".fh.p == null and .sd.p == 18" "$T/mv/usage/claude.jsonl" >/dev/null'
check 'seven_day only: the shape record lists key names, no values' '[ "$(cat "$T/mv/usage/claude-shape.json")" = "{\"seven_day\":[\"used_percentage\",\"resets_at\"]}" ]'
check 'seven_day only: windows says five_hour is not reported' '[[ "$(w)" == *"seven_day reported"*"five_hour not reported by Claude Code"* ]]'

# the documented shape with both windows
fresh
run '{"session_id":"s2","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41,"resets_at":1738857600}}}'
check 'both windows: fh and sd filled' 'jq -e ".fh.p == 23.5 and .fh.r == 1738425600 and .sd.p == 41" "$T/mv/usage/claude.jsonl" >/dev/null'
check 'both windows: windows reports both' '[ "$(w)" = "windows: seven_day reported, five_hour reported" ]'

# no rate_limits at all (an API-billed or older session): nothing written
fresh
run '{"session_id":"s3","model":{"display_name":"x"}}'
check 'no rate_limits: no row, no record' '[ ! -e "$T/mv/usage/claude.jsonl" ] && [ ! -e "$T/mv/usage/claude-shape.json" ]'

# a window key appearing with unchanged percentages is recorded at once (the 5-minute throttle must not hide it)
fresh
run '{"session_id":"s4","rate_limits":{"seven_day":{"used_percentage":18,"resets_at":1796065200}}}'
run '{"session_id":"s4","rate_limits":{"five_hour":{"used_percentage":2,"resets_at":1796000000},"seven_day":{"used_percentage":18,"resets_at":1796065200}}}'
check 'five_hour key appears, same percentages: windows sees it immediately' '[ "$(w)" = "windows: seven_day reported, five_hour reported" ]'

# a key appearing inside a window object with the same percentages is recorded at once; a null percentage is not a reading
fresh
run '{"session_id":"s7","rate_limits":{"five_hour":{"used_percentage":null},"seven_day":{"used_percentage":18,"resets_at":1796065200}}}'
check 'five_hour with a null percentage: not reported' '[[ "$(w)" == *"five_hour not reported"* ]]'
run '{"session_id":"s7","rate_limits":{"five_hour":{"used_percentage":null,"resets_at":5},"seven_day":{"used_percentage":18,"resets_at":1796065200}}}'
check 'a new key in the window object, same percentages: the shape record follows at once' 'jq -e ".five_hour == [\"resets_at\"]" "$T/mv/usage/claude-shape.json" >/dev/null'

# a window sent as null or as an empty object is not reported
fresh
run '{"session_id":"s6","rate_limits":{"five_hour":null,"seven_day":{"used_percentage":18,"resets_at":1796065200}}}'
check 'five_hour null: not reported' '[[ "$(w)" == *"five_hour not reported"* ]]'
fresh
run '{"session_id":"s6","rate_limits":{"five_hour":{},"seven_day":{"used_percentage":18,"resets_at":1796065200}}}'
check 'five_hour empty object: not reported' '[[ "$(w)" == *"five_hour not reported"* ]]'

# a FIFO planted at the shape record must not block the statusline (the row is still written)
fresh; mkdir -p "$T/mv/usage"
mkfifo "$T/mv/usage/claude-shape.json" 2>/dev/null
check 'FIFO at the shape record: the row is still written and the call returns' '{ run "{\"session_id\":\"s5\",\"rate_limits\":{\"seven_day\":{\"used_percentage\":1,\"resets_at\":1796065200}}}"; [ -s "$T/mv/usage/claude.jsonl" ]; }'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
