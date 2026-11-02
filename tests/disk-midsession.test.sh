#!/bin/bash
# /bin/bash tests/disk-midsession.test.sh
# The mid-session disk check in log-tool-event.sh: it counts every main-thread
# tool call under flock (context writes included), one call claims the check when
# the count reaches the due mark (every MEGAVIBE_DISK_CHECK_CALLS calls), asks
# disk-watch.sh for one level word, scans sizes only on the way into a low level,
# speaks once per level change, treats a failed reading as no reading, and stays
# quiet for a subagent, in the post-compact grace window and when off.
# disk-check.sh records the level at SessionStart after its warning went out, so
# the first mid-session reading after a compaction is not a repeat.
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
# names a worse level than the reading (the trap a text search fell into);
# CRITNOSCAN is a CRITICAL reading whose sizes scan fails.
cat > "$T/home/.megavibe/scripts/disk-watch.sh" <<'EOF'
#!/bin/bash
case "$1" in
  level) case "${MV_FAKE:-OK}" in FAIL) exit 0 ;; HANG) sleep 30 ;; CRIT|CRITNOSCAN) echo CRITICAL ;; *) echo "${MV_FAKE:-OK}" ;; esac ;;
  check) case "${MV_FAKE:-OK}" in
           CRIT) echo "disk: 7.0 GB free on /x — CRITICAL (warn < 15 GB, critical < 8 GB)" ;;
           LOW)  echo "disk: 12.0 GB free on /x — LOW (warn < 15 GB, critical < 8 GB)"; echo "   3.0 GB  /projects/CRITICAL/.venv" ;;
           CRITNOSCAN) exit 1 ;;
         esac ;;
esac
EOF
chmod +x "$T/home/.megavibe/scripts/disk-watch.sh" "$T/hook.sh" "$T/disk-check.sh"
cd "$T/proj" || exit 2
CALLS=.agent/LOGS/.disk-calls.sid1
DUE=.agent/LOGS/.disk-due.sid1
LEVEL=.agent/LOGS/.disk-level.sid1

# run <level> [tool] [agent_id] [file_path] -> the additionalContext the hook emitted
run() {
  local tool="${2:-Bash}" agent="${3:-}" fp="${4:-x}" payload
  payload="{\"session_id\":\"sid1\",\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"true\",\"file_path\":\"$fp\"}"
  [ -n "$agent" ] && payload="$payload,\"agent_id\":\"$agent\""
  payload="$payload}"
  printf '%s' "$payload" | HOME="$T/home" MV_FAKE="$1" bash "$T/hook.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}
# at <calls> [due]: the hook counts before it checks, so calls N-1 means this call
# is N; the due mark defaults to the next multiple of 25 at or above call N.
at() { echo "$1" > "$CALLS"; if [ -n "${2:-}" ]; then echo "$2" > "$DUE"; else echo $(( (($1 + 1 + 24) / 25) * 25 )) > "$DUE"; fi; }

at 24; OUT=$(run CRIT)
check "call 25, CRITICAL: nudge fires with the sizes report" '[[ "$OUT" == *"Low disk space"* && "$OUT" == *"7.0 GB free"* ]]'
check "the level file records CRITICAL" '[ "$(cat "$LEVEL")" = CRITICAL ]'
check "the call counter advanced to 25, the mark moved to 50" '[ "$(cat "$CALLS")" = 25 ] && [ "$(cat "$DUE")" = 50 ]'

OUT=$(run CRIT Read)
check "a Read counts (26) and is not a check call" '[ "$(cat "$CALLS")" = 26 ] && [[ "$OUT" != *"Low disk space"* ]]'

OUT=$(run CRIT Write "" .agent/DECISIONS.md)
check "a context write counts (27) although the hook returns early for it" '[ "$(cat "$CALLS")" = 27 ]'

at 49; OUT=$(run CRIT)
check "call 50, still CRITICAL: no repeat" '[[ "$OUT" != *"Low disk space"* ]]'

at 60; OUT=$(run OK)
check "call 61 is not a check call: nothing, level unchanged" '[[ "$OUT" != *"back above"* ]] && [ "$(cat "$LEVEL")" = CRITICAL ]'

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

# A check call that happens to be a context write: the early return skips the
# check, the mark stays claimed... so the NEXT call must still check. The claim
# moves the mark to calls+N, so a write landing exactly on the mark would lose a
# whole period: verify the loss is bounded to that one call.
echo OK > "$LEVEL"; at 24; OUT=$(run CRIT Write "" .agent/TASKS.md)
check "a context write on the mark: counted, no message (early return)" '[ "$(cat "$CALLS")" = 25 ] && [[ "$OUT" != *"Low disk space"* ]]'
OUT=$(run CRIT)
check "the next ordinary call checks instead" '[[ "$OUT" == *"Low disk space"* ]]'

at 224; OUT=$(run CRIT Bash agent-1)
check "a subagent's call neither counts nor checks" '[[ "$OUT" != *"Low disk space"* ]] && [ "$(cat "$CALLS")" = 224 ]'

echo OK > "$LEVEL"; at 224; date +%s > .agent/LOGS/.compact-ts.sid1; OUT=$(run CRIT)
check "inside the post-compact grace window: counted, no check, mark given back" '[[ "$OUT" != *"Low disk space"* ]] && [ "$(cat "$CALLS")" = 225 ] && [ "$(cat "$DUE")" = 225 ]'
rm -f .agent/LOGS/.compact-ts.sid1
OUT=$(run CRIT)
check "the first call after the grace window checks" '[[ "$OUT" == *"Low disk space"* ]]'

# Parallel calls in one session: the count must not lose increments and exactly
# one call claims the check.
echo OK > "$LEVEL"; at 0 25; N=0
for _ in $(seq 1 30); do
  ( printf '{"session_id":"sid1","tool_name":"Bash","tool_input":{"command":"true"}}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/hook.sh" 2>/dev/null \
      | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null | grep -c 'Low disk space' > "$(mktemp "$T/par.XXXXXX")" ) &
done; wait
for f in "$T"/par.*; do N=$((N + $(cat "$f"))); done
check "30 parallel calls: counter 30, exactly one check" '[ "$(cat "$CALLS")" = 30 ] && [ "$N" -eq 1 ]'

echo OK > "$LEVEL"; at 24; OUT=$(MEGAVIBE_DISK_CHECK_CALLS=0 run CRIT)
check "MEGAVIBE_DISK_CHECK_CALLS=0 switches it off" '[[ "$OUT" != *"Low disk space"* ]]'
at 24; OUT=$(MEGAVIBE_DISK_WATCH=0 run CRIT)
check "MEGAVIBE_DISK_WATCH=0 switches it off" '[[ "$OUT" != *"Low disk space"* ]]'
at 7 8; OUT=$(MEGAVIBE_DISK_CHECK_CALLS=08 run CRIT)
check "cadence 08 reads as 8 (no octal error)" '[[ "$OUT" == *"Low disk space"* ]]'
echo OK > "$LEVEL"; at 9 10; OUT=$(MEGAVIBE_DISK_CHECK_CALLS=10 run CRIT)
check "cadence follows MEGAVIBE_DISK_CHECK_CALLS, mark moves by it" '[[ "$OUT" == *"Low disk space"* ]] && [ "$(cat "$DUE")" = 20 ]'

# The staleness counter resets on .agent writes; the disk counter must not.
echo OK > "$LEVEL"; at 20; touch .agent/DECISIONS.md; sleep 1
for _ in 1 2 3 4; do run OK >/dev/null; done
OUT=$(run CRIT)
check "context writes do not reset the disk counter (call 25 still checks)" '[[ "$OUT" == *"Low disk space"* ]]'

# disk-check.sh at SessionStart records the level after warning, so the next
# mid-session reading is no repeat; a failed sizes scan still warns.
rm -f "$LEVEL"; at 24
OUT=$(printf '{"session_id":"sid1","hook_event_name":"SessionStart","source":"compact"}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/disk-check.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
check "disk-check.sh warned and wrote the session level" '[[ "$OUT" == *"Low disk space"* ]] && [ "$(cat "$LEVEL")" = CRITICAL ]'
OUT=$(run CRIT)
check "the mid-session check after it does not repeat CRITICAL" '[[ "$OUT" != *"Low disk space"* ]]'
echo OK > "$LEVEL"
OUT=$(printf '{"session_id":"sid1"}' | HOME="$T/home" MV_FAKE=CRITNOSCAN bash "$T/disk-check.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
check "disk-check.sh with a failed sizes scan still warns and records" '[[ "$OUT" == *"Low disk space"* && "$OUT" == *"did not finish"* ]] && [ "$(cat "$LEVEL")" = CRITICAL ]'
echo OK > "$LEVEL"
printf '{"session_id":"sid1"}' | HOME="$T/home" MV_FAKE=FAIL bash "$T/disk-check.sh" >/dev/null 2>&1
check "disk-check.sh with a failed reading leaves the level alone" '[ "$(cat "$LEVEL")" = OK ]'
OUT=$(printf '{"session_id":"sid1","agent_id":"child"}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/disk-check.sh" 2>/dev/null)
check "disk-check.sh for a subagent's SessionStart: silent, parent state untouched" '[ -z "$OUT" ] && [ "$(cat "$LEVEL")" = OK ]'

rm -f "$T/home/.megavibe/scripts/disk-watch.sh"
at 249; OUT=$(run CRIT); RC=$?
check "no disk-watch.sh installed: silent, hook exits 0" '[[ "$OUT" != *"Low disk space"* ]] && [ "$RC" -eq 0 ]'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
