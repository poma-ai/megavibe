#!/bin/bash
# /bin/bash tests/disk-midsession.test.sh
# The mid-session disk check in log-tool-event.sh: a check is due when the
# session's stamp is missing or older than MEGAVIBE_DISK_CHECK_MINS minutes; the
# check runs inside one directory lock (stamp, one-word probe, level compare and
# update), scans sizes only on the way into a low level, speaks once per level
# change, treats a failed reading as no reading, and stays quiet for a subagent,
# in the post-compact grace window and when off. disk-check.sh records the level
# and the stamp at SessionStart after its warning went out.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/disk-mid.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo $((SECONDS * 1000)); }
old_stamp() { touch -t "$(date -v-10M +%Y%m%d%H%M.%S 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M.%S)" "$1"; }

mkdir -p "$T/proj/.agent/LOGS" "$T/home/.megavibe/scripts"
cp "$REPO/template/.claude/hooks/log-tool-event.sh" "$T/hook.sh"
cp "$REPO/template/.claude/hooks/disk-check.sh" "$T/disk-check.sh"
# Stub: the level comes from MV_FAKE; every `level` probe appends a line to
# probes.log; `check` prints a report whose path text names a worse level than
# the reading (the trap a text search fell into); CRITNOSCAN is a CRITICAL
# reading whose sizes scan fails.
cat > "$T/home/.megavibe/scripts/disk-watch.sh" <<'EOF'
#!/bin/bash
case "$1" in
  level) echo probe >> "$MV_PROBES"
         case "${MV_FAKE:-OK}" in FAIL) exit 0 ;; HANG) sleep 30 ;; CRIT|CRITNOSCAN) echo CRITICAL ;; *) echo "${MV_FAKE:-OK}" ;; esac ;;
  check) case "${MV_FAKE:-OK}" in
           CRIT) echo "disk: 7.0 GB free on /x — CRITICAL (warn < 15 GB, critical < 8 GB)" ;;
           LOW)  echo "disk: 12.0 GB free on /x — LOW (warn < 15 GB, critical < 8 GB)"; echo "   3.0 GB  /projects/CRITICAL/.venv" ;;
           CRITNOSCAN) exit 1 ;;
         esac ;;
esac
EOF
chmod +x "$T/home/.megavibe/scripts/disk-watch.sh" "$T/hook.sh" "$T/disk-check.sh"
cd "$T/proj" || exit 2
STAMP=.agent/LOGS/.disk-stamp.sid1
LEVEL=.agent/LOGS/.disk-level.sid1
LOCK=.agent/LOGS/.disk-lock.sid1
export MV_PROBES="$T/probes.log"
probes() { grep -c probe "$MV_PROBES" 2>/dev/null || echo 0; }

# run <level> [tool] [agent_id] [file_path] -> the additionalContext the hook emitted
run() {
  local tool="${2:-Bash}" agent="${3:-}" fp="${4:-x}" payload
  payload="{\"session_id\":\"sid1\",\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"true\",\"file_path\":\"$fp\"}"
  [ -n "$agent" ] && payload="$payload,\"agent_id\":\"$agent\""
  payload="$payload}"
  printf '%s' "$payload" | HOME="$T/home" MV_FAKE="$1" bash "$T/hook.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}
due() { rm -f "$STAMP"; }          # no stamp: a check is due
fresh() { touch "$STAMP"; }        # just checked: nothing due

due; OUT=$(run CRIT)
check "due + CRITICAL: nudge fires with the sizes report" '[[ "$OUT" == *"Low disk space"* && "$OUT" == *"7.0 GB free"* ]]'
check "the level file records CRITICAL, the stamp is set" '[ "$(cat "$LEVEL")" = CRITICAL ] && [ -f "$STAMP" ]'
check "the lock was released" '[ ! -d "$LOCK" ]'

P=$(probes); OUT=$(run CRIT Read)
check "a fresh stamp: no probe, no message" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]]'

due; OUT=$(run CRIT)
check "due, still CRITICAL: no repeat" '[[ "$OUT" != *"Low disk space"* ]]'

old_stamp "$STAMP"; P=$(probes); OUT=$(run OK)
check "a 10-minute-old stamp is due (default 5): one probe" '[ "$(probes)" = $((P + 1)) ]'
check "back to OK: one all-clear, level OK" '[[ "$OUT" == *"back above the warn threshold"* ]] && [ "$(cat "$LEVEL")" = OK ]'

old_stamp "$STAMP"; P=$(probes); OUT=$(MEGAVIBE_DISK_CHECK_MINS=15 run OK)
check "MEGAVIBE_DISK_CHECK_MINS=15: a 10-minute-old stamp is not due" '[ "$(probes)" = "$P" ]'
P=$(probes); OUT=$(MEGAVIBE_DISK_CHECK_MINS=08 run OK)
check "cadence 08 reads as 8 minutes (no octal error): due" '[ "$(probes)" = $((P + 1)) ]'

due; OUT=$(run LOW)
check "LOW: nudge names LOW" '[[ "$OUT" == *"mid-session check: LOW"* ]]'
check "a CRITICAL in a path of the report does not set the level" '[ "$(cat "$LEVEL")" = LOW ]'

due; OUT=$(run CRIT)
check "LOW -> CRITICAL escalates" '[[ "$OUT" == *"mid-session check: CRITICAL"* ]]'

due; OUT=$(run FAIL)
check "a failed reading says nothing about the disk, keeps CRITICAL, still stamps" '[[ "$OUT" != *"disk"* ]] && [ "$(cat "$LEVEL")" = CRITICAL ] && [ -f "$STAMP" ]'

if command -v perl >/dev/null 2>&1; then
  due; S0=$(now_ms); OUT=$(run HANG); S1=$(now_ms)
  check "a hung disk-watch is cut off (deadline), level kept, lock released" '[ $((S1 - S0)) -lt 25000 ] && [[ "$OUT" != *"disk"* ]] && [ "$(cat "$LEVEL")" = CRITICAL ] && [ ! -d "$LOCK" ]'
fi

echo garbage > "$LEVEL"; due; OUT=$(run OK)
check "garbage level file + OK reading: no false recovery, file repaired" '[[ "$OUT" != *"back above"* ]] && [ "$(cat "$LEVEL")" = OK ]'

# A due check on a context write: the hook returns early, the stamp is untouched,
# so the next ordinary call checks.
echo OK > "$LEVEL"; due; P=$(probes); OUT=$(run CRIT Write "" .agent/TASKS.md)
check "a context write while due: no probe, no message, no stamp" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]] && [ ! -f "$STAMP" ]'
OUT=$(run CRIT)
check "the next ordinary call checks" '[[ "$OUT" == *"Low disk space"* ]]'

due; P=$(probes); OUT=$(run CRIT Bash agent-1)
check "a subagent's call never checks" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]] && [ ! -f "$STAMP" ]'

echo OK > "$LEVEL"; due; date +%s > .agent/LOGS/.compact-ts.sid1; P=$(probes); OUT=$(run CRIT)
check "inside the post-compact grace window: no probe, no stamp" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]] && [ ! -f "$STAMP" ]'
rm -f .agent/LOGS/.compact-ts.sid1
OUT=$(run CRIT)
check "the first call after the grace window checks" '[[ "$OUT" == *"Low disk space"* ]]'

# Parallel calls, all due: one probe, one message, nothing stolen, all exit 0.
echo OK > "$LEVEL"; due; P=$(probes); N=0; rm -f "$T"/par.*
for _ in $(seq 1 60); do
  ( printf '{"session_id":"sid1","tool_name":"Bash","tool_input":{"command":"true"}}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/hook.sh" 2>/dev/null \
      | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null | grep -c 'Low disk space' > "$(mktemp "$T/par.XXXXXX")" ) &
done; wait
for f in "$T"/par.*; do N=$((N + $(cat "$f"))); done
check "60 parallel due calls: exactly one probe, exactly one message" '[ "$(probes)" = $((P + 1)) ] && [ "$N" -eq 1 ] && [ ! -d "$LOCK" ]'

# A lock held by a live owner: the call waits at most ~0.3 s, then skips.
echo OK > "$LEVEL"; due; mkdir "$LOCK"; P=$(probes); S0=$(now_ms); OUT=$(run CRIT); RC=$?; S1=$(now_ms)
check "live lock: no probe, no message, exit 0, under 2 s, lock kept" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]] && [ "$RC" -eq 0 ] && [ $((S1 - S0)) -lt 2000 ] && [ -d "$LOCK" ]'
# An abandoned lock (older than 60 s) is reclaimed and the check runs.
old_stamp "$LOCK"; OUT=$(run CRIT)
check "abandoned lock (10 min old): reclaimed, check runs, lock released" '[[ "$OUT" == *"Low disk space"* ]] && [ ! -d "$LOCK" ]'

echo OK > "$LEVEL"; due; P=$(probes); OUT=$(MEGAVIBE_DISK_CHECK_MINS=0 run CRIT)
check "MEGAVIBE_DISK_CHECK_MINS=0 switches it off" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]]'
P=$(probes); OUT=$(MEGAVIBE_DISK_WATCH=0 run CRIT)
check "MEGAVIBE_DISK_WATCH=0 switches it off" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]]'

# disk-check.sh at SessionStart records level + stamp after warning, so the next
# mid-session call neither probes nor repeats; a failed sizes scan still warns.
rm -f "$LEVEL" "$STAMP"
OUT=$(printf '{"session_id":"sid1","hook_event_name":"SessionStart","source":"compact"}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/disk-check.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
check "disk-check.sh warned, wrote level and stamp" '[[ "$OUT" == *"Low disk space"* ]] && [ "$(cat "$LEVEL")" = CRITICAL ] && [ -f "$STAMP" ]'
P=$(probes); OUT=$(run CRIT)
check "the mid-session call after it: not due, no repeat" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]]'
echo OK > "$LEVEL"
OUT=$(printf '{"session_id":"sid1"}' | HOME="$T/home" MV_FAKE=CRITNOSCAN bash "$T/disk-check.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
check "disk-check.sh with a failed sizes scan still warns and records" '[[ "$OUT" == *"Low disk space"* && "$OUT" == *"did not finish"* ]] && [ "$(cat "$LEVEL")" = CRITICAL ]'
echo OK > "$LEVEL"
printf '{"session_id":"sid1"}' | HOME="$T/home" MV_FAKE=FAIL bash "$T/disk-check.sh" >/dev/null 2>&1
check "disk-check.sh with a failed reading leaves the level alone" '[ "$(cat "$LEVEL")" = OK ]'
OUT=$(printf '{"session_id":"sid1","agent_id":"child"}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/disk-check.sh" 2>/dev/null)
check "disk-check.sh for a subagent's SessionStart: silent, parent state untouched" '[ -z "$OUT" ] && [ "$(cat "$LEVEL")" = OK ]'
OUT=$(printf '{}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/disk-check.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
check "disk-check.sh with no session id still warns" '[[ "$OUT" == *"Low disk space"* ]]'

rm -f "$T/home/.megavibe/scripts/disk-watch.sh"
due; OUT=$(run CRIT); RC=$?
check "no disk-watch.sh installed: silent, hook exits 0" '[[ "$OUT" != *"Low disk space"* ]] && [ "$RC" -eq 0 ]'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
