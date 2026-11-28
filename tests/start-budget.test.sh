#!/bin/bash
# /bin/bash tests/start-budget.test.sh — fixtures only: temp project, temp HOME and MEGAVIBE_HOME, stub scripts.
# Every SessionStart hook that speaks to the model draws on ONE start budget. Each
# declares its share with a "start-budget share: N" comment; this test checks that
# the shares fit the total, that no other SessionStart hook writes model context,
# and that each hook keeps to its share on oversized input.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOKS="$REPO/template/.claude/hooks"
TOTAL=15500   # characters of additionalContext across one session start (README "What every session loads")
T=$(mktemp -d "${TMPDIR:-/tmp}/start-budget.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
share() { sed -n 's/.*start-budget share: \([0-9][0-9]*\).*/\1/p' "$HOOKS/$1" | head -1; }

# 1. Static: which SessionStart hooks write model context, and their shares.
start_hooks=$(jq -r '.hooks.SessionStart[] | select((.matcher // "") | split("|") | index("startup")) | .hooks[].command' "$REPO/template/.claude/settings.json" | sed 's#.*/##; s/"//g' | sort -u)
speakers=""
for h in $start_hooks; do grep -q additionalContext "$HOOKS/$h" 2>/dev/null && speakers="$speakers $h"; done
check "startup speakers are exactly the budgeted four (got:$speakers)" '[ "$(echo $speakers | tr " " "\n" | sort | tr "\n" " ")" = "disk-check.sh on-session-start.sh status-sync.sh usage-advisory.sh " ]'
sum=0
for h in $speakers; do
  s=$(share "$h"); check "$h declares a start-budget share" '[ -n "$s" ]'
  sum=$((sum + ${s:-0}))
done
check "shares ($sum) fit the start budget ($TOTAL)" '[ "$sum" -le "$TOTAL" ]'
# on-compact replaces on-session-start after a compaction; its 3000-character cap must not exceed that share.
check "on-compact's cap fits on-session-start's share" 'grep -q "\${#SHORT}\" -le 3000" "$HOOKS/on-compact.sh" && [ 3000 -le "$(share on-session-start.sh)" ]'

# 2. on-session-start: a huge LESSONS.md and DECISIONS.md stay within the share.
P="$T/proj"; mkdir -p "$P/.agent/LOGS" "$T/home" "$T/mv/scripts" "$T/cfg"
awk 'BEGIN { for (i = 0; i < 4000; i++) printf "| lesson %d | do the thing properly this time, with a long explanation |\n", i }' > "$P/.agent/LESSONS.md"
awk 'BEGIN { for (i = 0; i < 40; i++) { printf "| %d | ", i; for (j = 0; j < 60; j++) printf "decision "; print "|" } }' > "$P/.agent/DECISIONS.md"
out=$(cd "$P" && echo '{"session_id":"s-budget","source":"startup"}' | env -i PATH="$PATH" HOME="$T/home" MEGAVIBE_HOME="$T/mv" CLAUDE_CONFIG_DIR="$T/cfg" TMPDIR="$T" bash "$HOOKS/on-session-start.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
check "on-session-start spoke" '[ -n "$out" ]'
check "on-session-start within its share (${#out} <= $(share on-session-start.sh))" '[ "${#out}" -le "$(share on-session-start.sh)" ]'
check "on-session-start keeps the pointer to the full block" '[[ "$out" == *"Full block"* ]]'

# 3. disk-check: an oversized sizes report is cut, the rules survive.
cat > "$T/home/.megavibe-disk-watch" <<'STUB'
#!/bin/bash
case "$1" in
  level) echo LOW ;;
  check) echo "disk: free space is LOW"; for i in $(seq 1 200); do echo "  /some/very/long/path/number/$i  12 GB"; done ;;
  footprint) echo "megavibe footprint: 3 GB" ;;
esac
STUB
mkdir -p "$T/home/.megavibe/scripts"; mv "$T/home/.megavibe-disk-watch" "$T/home/.megavibe/scripts/disk-watch.sh"; chmod +x "$T/home/.megavibe/scripts/disk-watch.sh"
out=$(cd "$P" && echo '{"session_id":"s-budget"}' | HOME="$T/home" bash "$HOOKS/disk-check.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
check "disk-check spoke" '[ -n "$out" ]'
check "disk-check within its share (${#out} <= $(share disk-check.sh))" '[ "${#out}" -le "$(share disk-check.sh)" ]'
check "disk-check keeps its rules and a pointer to the full report" '[[ "$out" == *"Do not empty the Trash"* ]] && [[ "$out" == *"[cut; the full report"* ]]'

# 4. usage-advisory: an oversized advisory is cut at its share.
cat > "$T/mv/scripts/usage-route.sh" <<'STUB'
#!/bin/bash
case "$1" in
  band) echo over ;;
  balance) echo "-|" ;;
  advisory) for i in $(seq 1 100); do printf 'usage router: long advice sentence number %d. ' "$i"; done; echo ;;
  *) ;;
esac
STUB
out=$(cd "$P" && jq -nc '{hook_event_name:"SessionStart",session_id:"s1"}' | HOME="$T/home" MEGAVIBE_HOME="$T/mv" TMPDIR="$T" bash "$HOOKS/usage-advisory.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
check "usage-advisory spoke" '[ -n "$out" ]'
check "usage-advisory within its share (${#out} <= $(share usage-advisory.sh))" '[ "${#out}" -le "$(share usage-advisory.sh)" ] && [[ "$out" == *"[cut]" ]]'

# 5. status-sync: 20 answers of 300 characters stay within the share.
mkdir -p "$P/megavibe-deliverables"
{ echo "# Status"; echo; echo "## Decisions needed"; echo
  for i in $(seq 1 20); do printf '### D%d · decision\nOptions: A, B\nAnswer: %s\n\n' "$i" "$(printf 'x%.0s' $(seq 1 300))"; done
  echo "## Decided"; } > "$P/megavibe-deliverables/STATUS.md"
out=$(cd "$P" && jq -nc '{hook_event_name:"SessionStart",session_id:"s1"}' | HOME="$T/home" MEGAVIBE_HOME="$T/mv" TMPDIR="$T" bash "$HOOKS/status-sync.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
check "status-sync spoke" '[ -n "$out" ]'
check "status-sync within its share (${#out} <= $(share status-sync.sh))" '[ "${#out}" -le "$(share status-sync.sh)" ]'

echo "start-budget tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
