#!/bin/bash
# /bin/bash tests/disk-midsession.test.sh
# The mid-session disk check: log-tool-event.sh decides a check is due when the
# session's stamp is missing or older than MEGAVIBE_DISK_CHECK_MINS minutes
# (one stat, no lock on the hot path) and runs disk-midsession.sh under a perl
# flock + alarm. The helper stamps, probes one level word, compares with the
# recorded level and updates it, scans sizes only on the way into a low level,
# speaks once per level change, treats a failed reading as no reading. Nothing
# runs for a subagent, in the post-compact grace window, when off, or without
# perl. disk-check.sh records level + stamp at SessionStart after warning.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/disk-mid.XXXXXX") || exit 2
trap 'rm -rf "$T"; [ -n "${HOLD_PID:-}" ] && kill "$HOLD_PID" 2>/dev/null' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo $((SECONDS * 1000)); }
old_file() { touch -t "$(date -v-10M +%Y%m%d%H%M.%S 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M.%S)" "$1"; }

mkdir -p "$T/proj/.agent/LOGS" "$T/home/.megavibe/scripts" "$T/hooks"
cp "$REPO/template/.claude/hooks/log-tool-event.sh" "$REPO/template/.claude/hooks/disk-midsession.sh" "$REPO/template/.claude/hooks/disk-check.sh" "$T/hooks/"
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
chmod +x "$T/home/.megavibe/scripts/disk-watch.sh" "$T"/hooks/*.sh
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
  printf '%s' "$payload" | HOME="$T/home" MV_FAKE="$1" bash "$T/hooks/log-tool-event.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}
due() { rm -f "$STAMP"; }          # no stamp: a check is due

due; OUT=$(run CRIT)
check "due + CRITICAL: nudge fires with the sizes report" '[[ "$OUT" == *"Low disk space"* && "$OUT" == *"7.0 GB free"* ]]'
check "the level file records CRITICAL, the stamp is set" '[ "$(cat "$LEVEL")" = CRITICAL ] && [ -f "$STAMP" ]'

P=$(probes); OUT=$(run CRIT Read)
check "a fresh stamp: no probe, no message" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]]'

due; OUT=$(run CRIT)
check "due, still CRITICAL: no repeat" '[[ "$OUT" != *"Low disk space"* ]]'

old_file "$STAMP"; P=$(probes); OUT=$(run OK)
check "a 10-minute-old stamp is due (default 5): one probe" '[ "$(probes)" = $((P + 1)) ]'
check "back to OK: one all-clear, level OK" '[[ "$OUT" == *"back above the warn threshold"* ]] && [ "$(cat "$LEVEL")" = OK ]'

old_file "$STAMP"; P=$(probes); OUT=$(MEGAVIBE_DISK_CHECK_MINS=15 run OK)
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

due; S0=$(now_ms); OUT=$(run HANG); S1=$(now_ms)
check "a hung disk-watch is cut off (deadline), level kept" '[ $((S1 - S0)) -lt 25000 ] && [[ "$OUT" != *"disk"* ]] && [ "$(cat "$LEVEL")" = CRITICAL ]'

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

# Parallel calls, all due: one probe, one message, all exit 0.
echo OK > "$LEVEL"; due; P=$(probes); N=0; rm -f "$T"/par.*
for _ in $(seq 1 60); do
  ( printf '{"session_id":"sid1","tool_name":"Bash","tool_input":{"command":"true"}}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/hooks/log-tool-event.sh" 2>/dev/null \
      | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null | grep -c 'Low disk space' > "$(mktemp "$T/par.XXXXXX")" ) &
done; wait
for f in "$T"/par.*; do N=$((N + $(cat "$f"))); done
check "60 parallel due calls: exactly one probe, exactly one message" '[ "$(probes)" = $((P + 1)) ] && [ "$N" -eq 1 ]'

# A kernel lock held by a live owner: the call skips at once (non-blocking).
echo OK > "$LEVEL"; due; P=$(probes)
perl -e 'use Fcntl qw(:flock); open(my $l, ">>", shift) or exit 1; flock($l, LOCK_EX) or exit 1; sleep 20' "$LOCK" &
HOLD_PID=$!; sleep 0.3
S0=$(now_ms); OUT=$(run CRIT); RC=$?; S1=$(now_ms)
check "live kernel lock: no probe, no message, exit 0, under 1 s" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]] && [ "$RC" -eq 0 ] && [ $((S1 - S0)) -lt 1000 ]'
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null; HOLD_PID=""
OUT=$(run CRIT)
check "the lock released by its owner's death: the check runs" '[[ "$OUT" == *"Low disk space"* ]]'

# The lock must be held for the helper's whole run: start a call whose probe
# hangs, then try to take the lock from outside while it runs.
echo OK > "$LEVEL"; due; P=$(probes)
( run HANG > /dev/null ) &
BG=$!; sleep 1.5
perl -e 'use Fcntl qw(:flock); open(my $l, ">>", shift) or exit 2; exit(flock($l, LOCK_EX|LOCK_NB) ? 0 : 1)' "$LOCK"; HELD=$?
wait "$BG" 2>/dev/null
check "the kernel lock is held while the helper runs (an outside taker fails)" '[ "$HELD" -eq 1 ]'
check "...and is free again afterwards" 'perl -e '"'"'use Fcntl qw(:flock); open(my $l, ">>", shift) or exit 2; exit(flock($l, LOCK_EX|LOCK_NB) ? 0 : 1)'"'"' "$LOCK"'

# A subagent payload without agent_id but with a subagent transcript path.
echo OK > "$LEVEL"; due; P=$(probes)
OUT=$(printf '{"session_id":"sid1","tool_name":"Read","tool_input":{"file_path":"x"},"transcript_path":"/x/sid1/subagents/agent-child.jsonl"}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/hooks/log-tool-event.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
check "a subagent call identified by its transcript path never checks" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]] && [ ! -f "$STAMP" ]'

# A probe that times out inside the helper must not leave descendants behind:
# a disk-watch stub whose `level` starts a long child and waits on it.
cat > "$T/home/.megavibe/scripts/disk-watch-orphan.sh" <<EOF
#!/bin/bash
case "\$1" in level) sleep 32 & MARK=\$!; echo "\$MARK" > "$T/orphan.pid"; wait \$MARK ;; esac
EOF
chmod +x "$T/home/.megavibe/scripts/disk-watch-orphan.sh"
cp "$T/home/.megavibe/scripts/disk-watch.sh" "$T/disk-watch.keep"; cp "$T/home/.megavibe/scripts/disk-watch-orphan.sh" "$T/home/.megavibe/scripts/disk-watch.sh"
echo OK > "$LEVEL"; due; S0=$(now_ms); OUT=$(run OK); S1=$(now_ms); sleep 0.5
ORPHAN=$(cat "$T/orphan.pid" 2>/dev/null); ALIVE=0; [ -n "$ORPHAN" ] && kill -0 "$ORPHAN" 2>/dev/null && ALIVE=1
check "a probe that times out leaves no descendant alive after the hook returns (and the hook returned within the deadline)" '[ "$ALIVE" -eq 0 ] && [ $((S1 - S0)) -lt 25000 ]'
[ -n "$ORPHAN" ] && kill "$ORPHAN" 2>/dev/null
cp "$T/disk-watch.keep" "$T/home/.megavibe/scripts/disk-watch.sh"

# GNU stat semantics (`stat -f` prints filesystem info and fails on %m): a
# fresh stamp must still count as fresh.
mkdir -p "$T/gnubin"
cat > "$T/gnubin/stat" <<'EOF'
#!/bin/bash
if [ "$1" = "-f" ]; then echo "  File: \"$3\"  ID: 1 Namelen: 255 Type: apfs"; exit 1; fi
if [ "$1" = "-c" ]; then exec /usr/bin/stat -f %m "$3"; fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$T/gnubin/stat"
echo OK > "$LEVEL"; touch "$STAMP"; P=$(probes); OUT=$(PATH="$T/gnubin:$PATH" run CRIT)
check "GNU-style stat: a fresh stamp is not due (no probe)" '[ "$(probes)" = "$P" ]'
due; P=$(probes); OUT=$(PATH="$T/gnubin:$PATH" run CRIT)
check "GNU-style stat: a missing stamp is due (one probe, message)" '[ "$(probes)" = $((P + 1)) ] && [[ "$OUT" == *"Low disk space"* ]]'

echo OK > "$LEVEL"; due; P=$(probes); OUT=$(MEGAVIBE_DISK_CHECK_MINS=0 run CRIT)
check "MEGAVIBE_DISK_CHECK_MINS=0 switches it off" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]]'
P=$(probes); OUT=$(MEGAVIBE_DISK_WATCH=0 run CRIT)
check "MEGAVIBE_DISK_WATCH=0 switches it off" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]]'

# Without perl there is no lock and no deadline: the check is skipped, the hook
# still exits 0.
mkdir -p "$T/noperl"; for b in bash jq cat tr grep awk sed date touch mkdir printf head tail wc sort cut tee find stat python3 flock; do p=$(command -v "$b" 2>/dev/null) && ln -s "$p" "$T/noperl/$b" 2>/dev/null; done
due; P=$(probes); OUT=$(PATH="$T/noperl" run CRIT); RC=$?
check "no perl: no check, hook exits 0" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]] && [ "$RC" -eq 0 ]'

# disk-check.sh at SessionStart records level + stamp after warning, so the next
# mid-session call neither probes nor repeats; a failed sizes scan still warns.
rm -f "$LEVEL" "$STAMP"
OUT=$(printf '{"session_id":"sid1","hook_event_name":"SessionStart","source":"compact"}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/hooks/disk-check.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
check "disk-check.sh warned, wrote level and stamp" '[[ "$OUT" == *"Low disk space"* ]] && [ "$(cat "$LEVEL")" = CRITICAL ] && [ -f "$STAMP" ]'
P=$(probes); OUT=$(run CRIT)
check "the mid-session call after it: not due, no repeat" '[ "$(probes)" = "$P" ] && [[ "$OUT" != *"Low disk space"* ]]'
echo OK > "$LEVEL"
OUT=$(printf '{"session_id":"sid1"}' | HOME="$T/home" MV_FAKE=CRITNOSCAN bash "$T/hooks/disk-check.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
check "disk-check.sh with a failed sizes scan still warns and records" '[[ "$OUT" == *"Low disk space"* && "$OUT" == *"did not finish"* ]] && [ "$(cat "$LEVEL")" = CRITICAL ]'
echo OK > "$LEVEL"
printf '{"session_id":"sid1"}' | HOME="$T/home" MV_FAKE=FAIL bash "$T/hooks/disk-check.sh" >/dev/null 2>&1
check "disk-check.sh with a failed reading leaves the level alone" '[ "$(cat "$LEVEL")" = OK ]'
OUT=$(printf '{"session_id":"sid1","agent_id":"child"}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/hooks/disk-check.sh" 2>/dev/null)
check "disk-check.sh for a subagent's SessionStart (agent_id): silent, parent state untouched" '[ -z "$OUT" ] && [ "$(cat "$LEVEL")" = OK ]'
OUT=$(printf '{"session_id":"sid1","source":"compact","transcript_path":"/x/sid1/subagents/agent-child.jsonl"}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/hooks/disk-check.sh" 2>/dev/null)
check "disk-check.sh for a subagent's compaction (transcript path): silent, parent state untouched" '[ -z "$OUT" ] && [ "$(cat "$LEVEL")" = OK ]'
OUT=$(printf '{}' | HOME="$T/home" MV_FAKE=CRIT bash "$T/hooks/disk-check.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
check "disk-check.sh with no session id still warns" '[[ "$OUT" == *"Low disk space"* ]]'

rm -f "$T/home/.megavibe/scripts/disk-watch.sh"
due; OUT=$(run CRIT); RC=$?
check "no disk-watch.sh installed: silent, hook exits 0" '[[ "$OUT" != *"Low disk space"* ]] && [ "$RC" -eq 0 ]'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
