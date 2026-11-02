#!/bin/bash
# /bin/bash tests/disk-midsession.test.sh
# The mid-session disk check in log-tool-event.sh: every MEGAVIBE_DISK_CHECK_CALLS
# main-thread tool calls it runs disk-watch.sh check (stubbed here) and speaks once
# per level change — not on every call, not for a subagent, not when switched off.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/disk-mid.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }

mkdir -p "$T/proj/.agent/LOGS" "$T/home/.megavibe/scripts"
cp "$REPO/template/.claude/hooks/log-tool-event.sh" "$T/hook.sh"
# Stub: the level comes from MV_FAKE, so the test never depends on the real disk.
cat > "$T/home/.megavibe/scripts/disk-watch.sh" <<'EOF'
#!/bin/bash
case "${MV_FAKE:-OK}" in
  CRIT) echo "disk: 7.0 GB free on /x — CRITICAL (warn < 15 GB, critical < 8 GB)" ;;
  LOW)  echo "disk: 12.0 GB free on /x — LOW (warn < 15 GB, critical < 8 GB)" ;;
esac
EOF
chmod +x "$T/home/.megavibe/scripts/disk-watch.sh" "$T/hook.sh"
cd "$T/proj" || exit 2
COUNTER=.agent/LOGS/.tool-call-counter.sid1

# run <level> [agent_id] -> the additionalContext the hook emitted (empty when none)
run() {
  local agent="${2:-}" payload
  payload='{"session_id":"sid1","tool_name":"Bash","tool_input":{"command":"true"}'
  [ -n "$agent" ] && payload="$payload,\"agent_id\":\"$agent\""
  payload="$payload}"
  printf '%s' "$payload" | HOME="$T/home" MV_FAKE="$1" bash "$T/hook.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}
# The hook increments the counter for an implementation tool before the check,
# so a counter of N-1 means this call is call N.
at() { echo "$1" > "$COUNTER"; }

at 24; OUT=$(run CRIT)
check "call 25, CRITICAL: nudge fires" '[[ "$OUT" == *"Low disk space"* ]]'
check "the level file records CRITICAL" '[ "$(cat .agent/LOGS/.disk-level.sid1)" = CRITICAL ]'

at 49; OUT=$(run CRIT)
check "call 50, still CRITICAL: no repeat" '[[ "$OUT" != *"Low disk space"* ]]'

at 60; OUT=$(run OK)
check "call 61 is not a check call: nothing, level unchanged" '[[ "$OUT" != *"back above"* ]] && [ "$(cat .agent/LOGS/.disk-level.sid1)" = CRITICAL ]'

at 74; OUT=$(run OK)
check "call 75, back to OK: one all-clear" '[[ "$OUT" == *"back above the warn threshold"* ]]'
check "the level file records OK" '[ "$(cat .agent/LOGS/.disk-level.sid1)" = OK ]'

at 99; OUT=$(run LOW)
check "call 100, LOW: nudge fires with the LOW line" '[[ "$OUT" == *"Low disk space"* && "$OUT" == *" LOW "* ]]'

at 124; OUT=$(run CRIT agent-1)
check "a subagent's call never checks" '[[ "$OUT" != *"Low disk space"* ]] && [ "$(cat .agent/LOGS/.disk-level.sid1)" = LOW ]'

at 149; OUT=$(MEGAVIBE_DISK_CHECK_CALLS=0 run CRIT)
check "MEGAVIBE_DISK_CHECK_CALLS=0 switches it off" '[[ "$OUT" != *"Low disk space"* ]]'

at 149; OUT=$(MEGAVIBE_DISK_WATCH=0 run CRIT)
check "MEGAVIBE_DISK_WATCH=0 switches it off" '[[ "$OUT" != *"Low disk space"* ]]'

at 9; OUT=$(MEGAVIBE_DISK_CHECK_CALLS=10 run CRIT)
check "cadence follows MEGAVIBE_DISK_CHECK_CALLS" '[[ "$OUT" == *"Low disk space"* ]]'

rm -f "$T/home/.megavibe/scripts/disk-watch.sh"
at 174; OUT=$(run CRIT)
check "no disk-watch.sh installed: silent, hook still exits 0" '[[ "$OUT" != *"Low disk space"* ]]'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
