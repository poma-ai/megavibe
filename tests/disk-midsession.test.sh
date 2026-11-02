#!/bin/bash
# /bin/bash tests/disk-midsession.test.sh
# The mid-session disk check in log-tool-event.sh: it paces itself on its own
# per-session call counter (every tool, never reset), asks disk-watch.sh for one
# level word every MEGAVIBE_DISK_CHECK_CALLS calls, scans sizes only on the way into
# a low level, speaks once per level change, treats a failed reading as no reading,
# and stays quiet for a subagent, in the post-compact grace window and when off.
# disk-check.sh records the level at SessionStart so the first mid-session reading
# after a compaction is not a repeat.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/disk-mid.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }

mkdir -p "$T/proj/.agent/LOGS" "$T/home/.megavibe/scripts"
cp "$REPO/template/.claude/hooks/log-tool-event.sh" "$T/hook.sh"
cp "$REPO/template/.claude/hooks/disk-check.sh" "$T/disk-check.sh"
# Stub: the level comes from MV_FAKE; `check` prints a report whose path text
# names a worse level than the reading (the trap a text search fell into).
cat > "$T/home/.megavibe/scripts/disk-watch.sh" <<'EOF'
#!/bin/bash
case "$1" in
  level) case "${MV_FAKE:-OK}" in FAIL) exit 0 ;; HANG) sleep 30 ;; CRIT) echo CRITICAL ;; *) echo "${MV_FAKE:-OK}" ;; esac ;;
  check) case "${MV_FAKE:-OK}" in
           CRIT) echo "disk: 7.0 GB free on /x — CRITICAL (warn < 15 GB, critical < 8 GB)" ;;
           LOW)  echo "disk: 12.0 GB free on /x — LOW (warn < 15 GB, critical < 8 GB)"; echo "   3.0 GB  /projects/CRITICAL/.venv" ;;
         esac ;;
esac
EOF
chmod +x "$T/home/.megavibe/scripts/disk-watch.sh" "$T/hook.sh" "$T/disk-check.sh"
cd "$T/proj" || exit 2
CALLS=.agent/LOGS/.disk-calls.sid1
LEVEL=.agent/LOGS/.disk-level.sid1

# run <level> [tool] [agent_id] -> the additionalContext the hook emitted
run() {
  local tool="${2:-Bash}" agent="${3:-}" payload
  payload="{\"session_id\":\"sid1\",\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"true\",\"file_path\":\"x\"}"
  [ -n "$agent" ] && payload="$payload,\"agent_id\":\"$agent\""
  payload="$payload}"
  printf '%s' "$payload" | HOME="$T/home" MV_FAKE="$1" bash "$T/hook.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}
at() { echo "$1" > "$CALLS"; }   # the hook increments before it checks: N-1 means call N

at 24; OUT=$(run CRIT)
check "call 25, CRITICAL: nudge fires with the sizes report" '[[ "$OUT" == *"Low disk space"* && "$OUT" == *"7.0 GB free"* ]]'
check "the level file records CRITICAL" '[ "$(cat "$LEVEL")" = CRITICAL ]'
check "the call counter advanced to 25" '[ "$(cat "$CALLS")" = 25 ]'

OUT=$(run CRIT Read)
check "a Read counts (26) and is not a check call" '[ "$(cat "$CALLS")" = 26 ] && [[ "$OUT" != *"Low disk space"* ]]'

at 49; OUT=$(run CRIT)
check "call 50, still CRITICAL: no repeat" '[[ "$OUT" != *"Low disk space"* ]]'

at 74; OUT=$(run OK)
check "call 75, back to OK: one all-clear" '[[ "$OUT" == *"back above the warn threshold"* ]]'
check "the level file records OK" '[ "$(cat "$LEVEL")" = OK ]'

at 99; OUT=$(run LOW)
check "call 100, LOW: nudge names LOW" '[[ "$OUT" == *"mid-session check: LOW"* ]]'
check "a CRITICAL in a path of the report does not set the level" '[ "$(cat "$LEVEL")" = LOW ]'

at 124; OUT=$(run CRIT)
check "call 125, LOW -> CRITICAL escalates" '[[ "$OUT" == *"mid-session check: CRITICAL"* ]]'

at 149; OUT=$(run FAIL)
check "a failed reading says nothing and keeps CRITICAL" '[[ -z "$OUT" ]] && [ "$(cat "$LEVEL")" = CRITICAL ]'

if command -v perl >/dev/null 2>&1; then
  at 174; START=$SECONDS; OUT=$(run HANG)
  check "a hung disk-watch is cut off (deadline), level kept" '[ $((SECONDS - START)) -lt 25 ] && [[ -z "$OUT" ]] && [ "$(cat "$LEVEL")" = CRITICAL ]'
fi

echo garbage > "$LEVEL"; at 199; OUT=$(run OK)
check "garbage level file + OK reading: no false recovery, file repaired" '[[ "$OUT" != *"back above"* ]] && [ "$(cat "$LEVEL")" = OK ]'

at 224; OUT=$(run CRIT Bash agent-1)
check "a subagent's call neither counts nor checks" '[[ "$OUT" != *"Low disk space"* ]] && [ "$(cat "$CALLS")" = 224 ]'

at 224; date +%s > .agent/LOGS/.compact-ts.sid1; OUT=$(run CRIT)
check "inside the post-compact grace window: no check, no count" '[[ "$OUT" != *"Low disk space"* ]] && [ "$(cat "$CALLS")" = 224 ]'
rm -f .agent/LOGS/.compact-ts.sid1

echo OK > "$LEVEL"; at 24; OUT=$(MEGAVIBE_DISK_CHECK_CALLS=0 run CRIT)
check "MEGAVIBE_DISK_CHECK_CALLS=0 switches it off" '[[ "$OUT" != *"Low disk space"* ]]'
at 24; OUT=$(MEGAVIBE_DISK_WATCH=0 run CRIT)
check "MEGAVIBE_DISK_WATCH=0 switches it off" '[[ "$OUT" != *"Low disk space"* ]]'
at 7; OUT=$(MEGAVIBE_DISK_CHECK_CALLS=08 run CRIT)
check "cadence 08 reads as 8 (no octal error)" '[[ "$OUT" == *"Low disk space"* ]]'
echo OK > "$LEVEL"; at 9; OUT=$(MEGAVIBE_DISK_CHECK_CALLS=10 run CRIT)
check "cadence follows MEGAVIBE_DISK_CHECK_CALLS" '[[ "$OUT" == *"Low disk space"* ]]'

# The staleness counter resets on .agent writes; the disk counter must not.
echo OK > "$LEVEL"; at 20; touch .agent/DECISIONS.md; sleep 1
for _ in 1 2 3 4; do run OK >/dev/null; done
OUT=$(run CRIT)
check "context writes do not reset the disk counter (call 25 still checks)" '[[ "$OUT" == *"Low disk space"* ]]'

# disk-check.sh at SessionStart records the level, so the next mid-session reading is no repeat.
rm -f "$LEVEL"; at 24
printf '{"session_id":"sid1","hook_event_name":"SessionStart","source":"compact"}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/disk-check.sh" >/dev/null 2>&1
check "disk-check.sh wrote the session level" '[ "$(cat "$LEVEL")" = CRITICAL ]'
OUT=$(run CRIT)
check "the mid-session check after it does not repeat CRITICAL" '[[ "$OUT" != *"Low disk space"* ]]'
echo OK > "$LEVEL"
printf '{"session_id":"sid1"}' | HOME="$T/home" MV_FAKE=FAIL bash "$T/disk-check.sh" >/dev/null 2>&1
check "disk-check.sh with a failed reading leaves the level alone" '[ "$(cat "$LEVEL")" = OK ]'

rm -f "$T/home/.megavibe/scripts/disk-watch.sh"
at 249; OUT=$(run CRIT); RC=$?
check "no disk-watch.sh installed: silent, hook exits 0" '[[ "$OUT" != *"Low disk space"* ]] && [ "$RC" -eq 0 ]'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
