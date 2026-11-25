#!/bin/bash
# Review regressions, using scratch HOME and simulated ancestry.
# RESTART_TEST_REPO can point at an untouched HEAD copy to verify regressions.
set -euo pipefail
REPO=${RESTART_TEST_REPO:-$(cd "$(dirname "$0")/.." && pwd -P)}
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-lifecycle.XXXXXX")
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" MEGAVIBE_HOME="$T/home/.megavibe" CLAUDE_CONFIG_DIR="$T/home/.claude"
export MEGAVIBE_RESTART_MARKER="$MEGAVIBE_HOME/request" MEGAVIBE_RESTART_OWNER=fixture-owner MEGAVIBE_RESTART_WRAPPER_PID=$$
export FIXTURE="$T" FIXTURE_PROCESS=100
mkdir -p "$T/bin" "$MEGAVIBE_HOME/scripts" "$CLAUDE_CONFIG_DIR/sessions" "$T/project/.agent/LOGS"
cp "$REPO/scripts/restart.sh" "$MEGAVIBE_HOME/scripts/"
export PATH="$T/bin:$PATH"
# The owner PID is simulated; never consult a host process that reused 100.
kill() { if [ "${1:-}" = -0 ] && [ "${2:-}" = 100 ]; then [ "${OWNER_ALIVE:-0}" = 1 ]; else builtin kill "$@"; fi; }
export -f kill
cat > "$T/bin/ps" <<'STUB'
#!/bin/bash
case "$*" in
  '-o ppid= -p '*)
    case "$4" in
      100) echo "$MEGAVIBE_RESTART_WRAPPER_PID" ;;
      200) echo 100 ;;
      *) if [ "${REPLACING:-0}" = 1 ] || [ -f "$CLAUDE_CONFIG_DIR/sessions/$MEGAVIBE_RESTART_WRAPPER_PID.json" ]; then echo "$MEGAVIBE_RESTART_WRAPPER_PID"; else echo "$FIXTURE_PROCESS"; fi ;;
    esac ;;
  '-axo '*) [ "${FAIL_SCAN:-0}" = 0 ] || exit 1; echo '300 100 Wed Nov 25 10:00:00 2026 server' ;;
  *) exit 1 ;;
esac
STUB
printf '#!/bin/bash\nexit 1\n' > "$T/bin/tmux"
printf '#!/bin/bash\nexit 8\n' > "$T/bin/claude"
chmod +x "$T/bin/"*
cd "$T/project"
: > .agent/DECISIONS.md; : > .agent/LESSONS.md
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
helper() { bash "$MEGAVIBE_HOME/scripts/restart.sh" "$@"; }
field() { jq -r "$1" "$MEGAVIBE_RESTART_MARKER" 2>/dev/null || true; }
arm() {
  unset MEGAVIBE_RESTART_PICKUP
  export FIXTURE_PROCESS=100
  rm -f "$CLAUDE_CONFIG_DIR/sessions/$$.json"
  printf '{"sessionId":"%s"}\n' "$1" > "$CLAUDE_CONFIG_DIR/sessions/100.json"
  helper request "$1" 100 >/dev/null
  GEN=$(field .generation)
}
complete() { helper complete "$1" 100 "$GEN"; }
start() { printf '{"source":"resume","session_id":"%s"}\n' "$1" | bash "$REPO/template/.claude/hooks/on-session-start.sh"; }
end() { printf '{"session_id":"%s"}\n' "$1" | bash "$REPO/template/.claude/hooks/on-session-end.sh"; }
pickup() {
  export MEGAVIBE_RESTART_PICKUP=$GEN
  REPLACING=1 helper replace "$1" 2>/dev/null || true
  printf '{"sessionId":"%s"}\n' "$1" > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
}
arm absent
rc=0; complete absent > "$T/out" 2>&1 || rc=$?
check 'P1 complete fails without exit confirmation' '[ "$rc" != 0 ] && [ -s .agent/sessions/absent/restart-handover.txt ]'
check 'P1 rejection is one line with a manual command' '[ "$(wc -l < "$T/out" | tr -d " ")" = 1 ] && grep -q "megavibe --resume absent" "$T/out"'
arm failed-capture
echo 'Purpose: re-arm the hourly build monitor.' >> .agent/sessions/failed-capture/restart-handover.txt
cp .agent/sessions/failed-capture/restart-handover.txt "$T/notes-before"
rc=0; FAIL_SCAN=1 helper capture failed-capture 100 > "$T/out" 2>&1 || rc=$?
check 'P1 failed process capture cannot confirm exit' '[ "$rc" != 0 ]'
check 'failed capture keeps the current handover and notes intact' 'cmp -s "$T/notes-before" .agent/sessions/failed-capture/restart-handover.txt'
rc=0; complete failed-capture > "$T/out" 2>&1 || rc=$?
check 'P1 complete rejects a failed capture and retains evidence' '[ "$rc" != 0 ] && find .agent/sessions/failed-capture -name "restart-handover*.txt" | read -r _'
out=$(start failed-capture)
check 'manual resume after failed capture has no automatic reminder' '[ -z "$out" ]'
arm failed-capture
check 'second request carries notes from the failed capture' 'grep -q "Purpose: re-arm the hourly build monitor." .agent/sessions/failed-capture/restart-handover.txt'
helper capture failed-capture 100
complete failed-capture
pickup failed-capture
out=$(start failed-capture)
check 'second restart reminder includes notes from the failed capture' 'printf "%s" "$out" | jq -e '\''.hookSpecificOutput.additionalContext | contains("Purpose: re-arm the hourly build monitor.")'\'' >/dev/null'
arm bound
helper capture bound 100
for mismatch in generation wrapper pid session; do
  rc=0
  case "$mismatch" in
    generation) helper complete bound 100 old-generation > "$T/out" 2>&1 || rc=$? ;;
    wrapper) MEGAVIBE_RESTART_OWNER=wrong helper complete bound 100 "$GEN" > "$T/out" 2>&1 || rc=$? ;;
    pid) helper complete bound 200 "$GEN" > "$T/out" 2>&1 || rc=$? ;;
    session) helper complete another-session 100 "$GEN" > "$T/out" 2>&1 || rc=$? ;;
  esac
  check "P1 confirmation rejects mismatching $mismatch" '[ "$rc" != 0 ]'
done
rc=0; OWNER_ALIVE=1 complete bound > "$T/out" 2>&1 || rc=$?
check 'P1 confirmation cannot bypass a still-live owning process' '[ "$rc" != 0 ] && grep -q "has not exited" "$T/out"'
printf '{"sessionId":"changed-after-capture"}' > "$CLAUDE_CONFIG_DIR/sessions/100.json"
rc=0; complete bound > "$T/out" 2>&1 || rc=$?
check 'P1 session change after capture invalidates confirmation' '[ "$rc" != 0 ] && grep -q "conversation changed" "$T/out"'
arm clear-event
printf '{"session_id":"clear-event","reason":"clear"}' | bash "$REPO/template/.claude/hooks/on-session-end.sh" > "$T/out" 2>&1
rc=0; complete clear-event >> "$T/out" 2>&1 || rc=$?
check 'P1 clear event cancels even before registry id changes' '[ "$rc" != 0 ] && grep -q "conversation changed" "$T/out"'
# The actual launcher must propagate complete failure and must not re-exec.
sed -n '/^restart_after_exit() {/,/^}/p' "$REPO/megavibe" > "$T/restart-fn"
source "$T/restart-fn"
do_update() { :; }
restore_launch_parent() { :; }
BOLD= RESET= YELLOW= GREEN= NORMALIZE=1 REPO_DIR= VERSION_FILE="$T/version" INIT_SCRIPT="$T/init" CLAUDE_PID=100
printf 'exit 0\n' > "$T/init"
printf '#!/bin/bash\ntouch "$FIXTURE/reexecuted"\n' > "$MEGAVIBE_HOME/megavibe"
chmod +x "$MEGAVIBE_HOME/megavibe"
arm launcher-missing
# Run in a subshell with matching simulated wrapper to avoid replacing the test.
( bash -c 'echo "$PPID"' > "$T/wrapper-pid"
  read -r MEGAVIBE_RESTART_WRAPPER_PID < "$T/wrapper-pid"
  export MEGAVIBE_RESTART_WRAPPER_PID
  if jq -e . "$MEGAVIBE_RESTART_MARKER" >/dev/null 2>&1; then
    jq --arg p "$MEGAVIBE_RESTART_WRAPPER_PID" '.wrapperPid=$p' "$MEGAVIBE_RESTART_MARKER" > "$T/record"
    mv "$T/record" "$MEGAVIBE_RESTART_MARKER"
  fi
  restart_after_exit ) > "$T/out" 2>&1 || true
check 'P1 launcher never resumes after missing confirmation' '[ ! -e "$T/reexecuted" ] && grep -q "start by hand" "$T/out"'
arm parent
cp "$MEGAVIBE_RESTART_MARKER" "$T/marker-before"
cp .agent/sessions/parent/restart-handover.txt "$T/handover-before"
printf '{"sessionId":"child"}' > "$CLAUDE_CONFIG_DIR/sessions/200.json"
FIXTURE_PROCESS=200 end child > "$T/out" 2>&1
check 'P2 inherited child exit leaves parent marker and handover untouched' 'cmp -s "$T/marker-before" "$MEGAVIBE_RESTART_MARKER" && cmp -s "$T/handover-before" .agent/sessions/parent/restart-handover.txt'
FIXTURE_PROCESS=200 helper cancel parent 100 > "$T/out" 2>&1 || true
check 'P2 child cannot cancel parent even with supplied owner PID' 'cmp -s "$T/marker-before" "$MEGAVIBE_RESTART_MARKER"'
printf '{"sessionId":"parent"}' > "$CLAUDE_CONFIG_DIR/sessions/200.json"
FIXTURE_PROCESS=200 end parent > "$T/out" 2>&1
check 'P2 child with same session id still cannot capture' 'cmp -s "$T/marker-before" "$MEGAVIBE_RESTART_MARKER" && cmp -s "$T/handover-before" .agent/sessions/parent/restart-handover.txt'
printf '{"sessionId":"after-clear"}' > "$CLAUDE_CONFIG_DIR/sessions/100.json"
end after-clear > "$T/out" 2>&1
check 'P2 owning clear cancels with notice and keeps capture' 'grep -q "conversation changed" "$T/out" && [ -s .agent/sessions/parent/restart-handover.txt ] && [ "$(cat .agent/sessions/parent/restart-handover.status)" = not-restarted ]'
rc=0; complete parent >> "$T/out" 2>&1 || rc=$?
check 'P1 owning clear never confirms or prints a duplicate notice' '[ "$rc" != 0 ] && [ "$(wc -l < "$T/out" | tr -d " ")" = 1 ]'
arm replacement
helper capture replacement 100
complete replacement
check 'P2 complete stays pending and not-restarted before launch' '[ "$(field .state)" = pending ] && [ "$(cat .agent/sessions/replacement/restart-handover.status)" = not-restarted ]'
# Run the shipped launch function against a Claude that fails before SessionStart.
sed -n '/^launch_claude() {/,/^}/p' "$REPO/megavibe" > "$T/launch-fn"
source "$T/launch-fn"
export MEGAVIBE_RESTART_PICKUP=$GEN MEGAVIBE_SCRATCH_FOLLOWS_PROJECT=0
REPLACING=1 launch_claude --resume replacement & replacement_pid=$!
wait "$replacement_pid" || true
check 'P2 failed replacement launch retains not-restarted status' '[ "$(cat .agent/sessions/replacement/restart-handover.status)" = not-restarted ]'
unset MEGAVIBE_RESTART_PICKUP
out=$(start replacement)
check 'P2 later unrelated manual resume never gets failed-launch reminder' '[ -z "$out" ]'
arm wrong-pickup
helper capture wrong-pickup 100
complete wrong-pickup
pickup wrong-pickup
out=$(MEGAVIBE_RESTART_PICKUP=other start wrong-pickup)
check 'P2 wrong generation cannot confirm replacement pickup' '[ -z "$out" ] && [ "$(cat .agent/sessions/wrong-pickup/restart-handover.status)" = not-restarted ]'
out=$(start other-session)
check 'P2 wrong session cannot confirm replacement pickup' '[ -z "$out" ] && [ "$(cat .agent/sessions/wrong-pickup/restart-handover.status)" = not-restarted ]'
# Interrupt a real delivery after claim acquisition, before output can complete.
arm interrupted
helper capture interrupted 100
complete interrupted
pickup interrupted
python3 - "$MEGAVIBE_HOME/scripts/restart.sh" "$GEN" <<'INTERRUPT'
import os, pathlib, signal, subprocess, sys, time
script, generation = sys.argv[1:]
claim = pathlib.Path('.agent/sessions/interrupted/restart-handover.' + generation + '.delivering')
# Force a blocking stdout open before Python's write using a full pipe. The
# generation claim tells us the delivering Python owns the kernel lock.
r, w = os.pipe()
os.set_blocking(w, False)
try:
    while True: os.write(w, b'x' * 4096)
except BlockingIOError:
    pass
os.set_blocking(w, True)
p = subprocess.Popen(['bash', script, 'show', 'interrupted'], stdout=w, stderr=subprocess.DEVNULL)
owner = None
for _ in range(200):
    try:
        owner = int(claim.read_text())
        break
    except (FileNotFoundError, ValueError): time.sleep(.01)
if owner is not None:
    os.kill(owner, signal.SIGKILL)
else:
    # HEAD has the unrecoverable directory claim; simulate its exact leftover.
    legacy = pathlib.Path('.agent/sessions/interrupted/restart-handover.delivering')
    legacy.mkdir(exist_ok=True)
    p.kill()
p.wait(timeout=5)
os.close(w); os.close(r)
INTERRUPT
out=$(helper show interrupted || true)
check 'P2 interrupted delivery recovers the dead owner and emits reminder' 'printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext" >/dev/null'
check 'P2 recovered delivery is consumed only after output succeeds' '[ -z "$(helper show interrupted || true)" ]'
arm interrupted
helper capture interrupted 100
complete interrupted
pickup interrupted
out=$(helper show interrupted || true)
check 'P2 abandoned claim never suppresses a later generation' 'printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext" >/dev/null'
rm -f "$MEGAVIBE_RESTART_MARKER"
export REAL_JQ="$(command -v jq)"
cat > "$T/bin/jq" <<'JQ'
#!/bin/bash
echo jq >> "$FIXTURE/ordinary-jq"
exec "$REAL_JQ" "$@"
JQ
chmod +x "$T/bin/jq"
printf '{"hook_event_name":"Stop","session_id":"ordinary","stop_hook_active":true,"background_tasks":[]}' | MEGAVIBE_BG_WATCH=0 MEGAVIBE_DISK_WATCH=0 bash "$REPO/template/.claude/hooks/watch-background.sh"
check 'P2 ordinary disabled Stop creates no restart file' '[ ! -e .agent/LOGS/.restart-tasks.ordinary.json ] && [ ! -d .agent/sessions/ordinary ]'
check 'P2 ordinary disabled Stop keeps its single existing JSON parse' '[ "$(wc -l < "$T/ordinary-jq" | tr -d " ")" = 1 ]'
# Compare the changed startup/resume registration and registry reader to main,
# counting actual jq processes (settings extraction is outside the count).
unset MEGAVIBE_RESTART_PICKUP
mkdir -p "$T/main" .claude/hooks
git -C "$REPO" show main:template/.claude/hooks/on-session-start.sh > "$T/main/start.sh"
git -C "$REPO" show main:template/.claude/settings.json > "$T/main/settings.json"
git -C "$REPO" show main:scripts/sessions.sh > "$T/main/sessions.sh"
cat > .claude/hooks/on-session-start.sh <<'HOOK'
#!/bin/bash
echo invoked >> "$FIXTURE/start-invocations"
exec bash "$START_HOOK"
HOOK
chmod +x .claude/hooks/on-session-start.sh
for source in startup resume; do
  for version in main current; do
    if [ "$version" = main ]; then
      export START_HOOK="$T/main/start.sh"
      settings="$T/main/settings.json"
    else
      export START_HOOK="$REPO/template/.claude/hooks/on-session-start.sh"
      settings="$REPO/template/.claude/settings.json"
    fi
    commands=$("$REAL_JQ" -r --arg source "$source" '.hooks.SessionStart[] | .matcher as $m | select($source | test("^(" + $m + ")$")) | .hooks[].command | select(contains("on-session-start.sh"))' "$settings")
    : > "$T/ordinary-jq"; : > "$T/start-invocations"
    while IFS= read -r command; do
      [ -n "$command" ] || continue
      printf '{"source":"%s","session_id":"ordinary"}' "$source" | bash -c "$command" > "$T/out"
    done <<< "$commands"
    wc -l < "$T/ordinary-jq" | tr -d ' ' > "$T/$version-count"
  done
  check "ordinary $source adds no jq processes compared with main" 'cmp -s "$T/main-count" "$T/current-count"'
done
check 'ordinary resume gate never invokes the startup hook' '[ ! -s "$T/start-invocations" ]'
MEGAVIBE_RESTART_PICKUP=fixture bash -c "$commands" <<<'{"source":"resume","session_id":"ordinary"}' > "$T/out"
check 'resume gate invokes the startup hook when pickup is pending' '[ -s "$T/start-invocations" ]'
rm -f "$CLAUDE_CONFIG_DIR/sessions/200.json"
printf '{"pid":100,"sessionId":"ordinary"}' > "$CLAUDE_CONFIG_DIR/sessions/100.json"
printf '{"pid":%s,"sessionId":"another"}' "$$" > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
for version in main current; do
  if [ "$version" = main ]; then script="$T/main/sessions.sh"; else script="$REPO/scripts/sessions.sh"; fi
  : > "$T/ordinary-jq"
  OWNER_ALIVE=1 bash "$script" --status > "$T/out"
  wc -l < "$T/ordinary-jq" | tr -d ' ' > "$T/$version-count"
done
check 'session status adds no jq processes per registry entry compared with main' 'cmp -s "$T/main-count" "$T/current-count" && [ "$(cat "$T/current-count")" = 6 ]'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
