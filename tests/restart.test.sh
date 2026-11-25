#!/bin/bash
# Offline restart handover, hook and launcher regressions. Never talks to real tmux.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-restart.XXXXXX")
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" MEGAVIBE_HOME="$T/home/.megavibe" CLAUDE_CONFIG_DIR="$T/home/.claude"
mkdir -p "$T/bin" "$MEGAVIBE_HOME/scripts" "$CLAUDE_CONFIG_DIR/sessions" "$T/project/.agent/LOGS"
export PATH="$T/bin:$PATH" FIXTURE="$T"
cp "$REPO/scripts/restart.sh" "$MEGAVIBE_HOME/scripts/"
cat > "$T/bin/ps" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$FIXTURE/ps-calls"
case "$*" in
  '-axo pid=,ppid=,lstart=,command='|'-axo pid=,ppid=,lstart=,comm=') echo scan >> "$FIXTURE/scans"; cat "$FIXTURE/processes" ;;
  '-o ppid= -p '*) echo 1 ;;
  *) exit 1 ;;
esac
STUB
cat > "$T/bin/tmux" <<'STUB'
#!/bin/bash
case "$1" in
  list-panes) printf '300\tbuild:%%3\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/bin/"*
cd "$T/project"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
helper() { bash "$REPO/scripts/restart.sh" "$@"; }
hook() { printf '%s' "$1" | bash "$REPO/template/.claude/hooks/on-session-start.sh"; }
export MEGAVIBE_RESTART_MARKER="$MEGAVIBE_HOME/.restart-session.100"
cat > "$T/processes" <<'DATA'
100 10 Wed Nov 25 10:00:00 2026 claude
200 100 Wed Nov 25 10:01:00 2026 test-server --host 127.0.0.1
300 100 Wed Nov 25 10:02:00 2026 long-build
400 100 Wed Nov 25 10:03:00 2026 monitor-output
500 1 Wed Nov 25 09:00:00 2026 unrelated
DATA
helper request alpha 100 >/dev/null
cat > "$T/processes" <<'DATA'
100 10 Wed Nov 25 10:00:00 2026 claude
200 100 Wed Nov 25 10:01:00 2026 test-server --host 127.0.0.1
300 1 Wed Nov 25 10:02:00 2026 long-build
400 1 Wed Nov 25 10:03:00 2026 monitor-output
500 1 Wed Nov 25 09:00:00 2026 unrelated
DATA
printf '[{"id":"bg1","command":"test-build","started":123,"path":"/example/build.output"}]' > .agent/LOGS/.restart-tasks.alpha.json
out=$(helper capture alpha 100)
f=.agent/sessions/alpha/restart-handover.txt
check 'request captures tasks and arms only own marker' '[ "$(cat "$MEGAVIBE_RESTART_MARKER")" = alpha ] && [ ! -e "$MEGAVIBE_HOME/.restart-session" ] && grep -q "bg1" "$f" && grep -q "start: 123; output: /example/build.output" "$f"'
check 'survival is explicitly unverified' 'grep -q "expected to end with the session" "$f" && grep -q "may survive (not verified)" "$f" && ! grep -q ": survives session" "$f" && ! grep -q unrelated "$f"'
echo 'Purpose: scheduled prompt checks the build every hour; re-arm if still needed.' >> "$f"
helper capture alpha 100
check 'recapture keeps authored notes' 'grep -q Purpose: "$f"'
helper complete alpha 100 || true
out=$(hook '{"source":"resume","session_id":"alpha"}')
check 'resume reminder works in otherwise empty project' 'printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext | contains(\"Before the restart you had these running\") and contains(\"say which you dropped\") and contains(\"scheduled prompt\")" >/dev/null'
check 'shown once and original file retained' '[ -d .agent/sessions/alpha/restart-handover.shown ] && [ -f "$f" ] && [ -z "$(hook '\''{"source":"resume","session_id":"alpha"}'\'')" ]'
check 'other conversation has no reminder' '[ -z "$(hook '\''{"source":"resume","session_id":"beta"}'\'')" ]'
check 'compact does not consume a handover' '[ -z "$(hook '\''{"source":"compact","session_id":"alpha"}'\'')" ]'
helper request alpha 100 >/dev/null
check 'next restart archives shown generation and carries model notes' '[ ! -e .agent/sessions/alpha/restart-handover.shown ] && ls .agent/sessions/alpha/restart-handover.*.txt >/dev/null && grep -q "Purpose:" "$f"'
helper capture alpha 100
helper complete alpha 100 || true
out=$(hook '{"source":"startup","session_id":"alpha"}')
check 'startup reminder also works with no project knowledge' 'printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext" >/dev/null'
check 'traversal id rejected' '! helper request ../bad 100 >/dev/null 2>&1 || [ ! -e .agent/bad ]'
helper capture reuse 100
# Same pid, different start time must not be inherited.
sed 's/400 1 Wed Nov 25 10:03:00/400 1 Wed Nov 25 11:03:00/' "$T/processes" > "$T/new"
mv "$T/new" "$T/processes"
helper request reuse 100 >/dev/null
check 'reused pid is not attributed' '! grep -q "PID 400" .agent/sessions/reuse/restart-handover.txt'
# Missing identity must never arm a fallback restart.
rm -f "$MEGAVIBE_RESTART_MARKER"
rc=0; out=$(helper request 2>&1) || rc=$?
check 'unknown id skips without marker or continue fallback' '[ "$rc" != 0 ] && [[ "$out" == *"skipped: session id unavailable"* ]] && [ ! -e "$MEGAVIBE_RESTART_MARKER" ]'
# Use the real watch hook with harmless inputs and disk checking disabled.
export MEGAVIBE_BG_WATCH=0 MEGAVIBE_DISK_WATCH=0
printf '{"hook_event_name":"Stop","session_id":"registry","background_tasks":[{"id":"monitor1","status":"running","command":"watch-output","startTime":44,"outputFile":"/example/watch.output"},{"id":"done1","status":"completed","command":"finished"}]}' | bash "$REPO/template/.claude/hooks/watch-background.sh"
helper request registry 100 >/dev/null
check 'registry captures task metadata without commands, excludes completed tasks' 'grep -q monitor1 .agent/sessions/registry/restart-handover.txt && ! grep -q finished .agent/sessions/registry/restart-handover.txt && grep -q "start: 44" .agent/sessions/registry/restart-handover.txt'
cp .agent/LOGS/.restart-tasks.registry.json "$T/registry-before"
printf '{"hook_event_name":"Stop","session_id":"registry","transcript_path":"/example/registry/subagents/agent-worker.jsonl","background_tasks":[]}' | bash "$REPO/template/.claude/hooks/watch-background.sh"
check 'subagent Stop cannot erase parent registry snapshot' 'cmp -s "$T/registry-before" .agent/LOGS/.restart-tasks.registry.json'
# SessionEnd captures on an armed restart, while ordinary exits stay inert.
rm -f "$MEGAVIBE_RESTART_MARKER"
printf '{"session_id":"ordinary"}' | bash "$REPO/template/.claude/hooks/on-session-end.sh"
check 'ordinary SessionEnd creates no handover' '[ ! -e .agent/sessions/ordinary/restart-handover.txt ]'
echo ending > "$MEGAVIBE_RESTART_MARKER"
printf '{"session_id":"ending"}' | bash "$REPO/template/.claude/hooks/on-session-end.sh"
check 'armed SessionEnd preserves full id and creates handover before cleanup' '[ "$(cat "$MEGAVIBE_RESTART_MARKER")" = ending ] && [ -f .agent/sessions/ending/restart-handover.txt ]'
rm -f "$MEGAVIBE_RESTART_MARKER"
: > "$MEGAVIBE_HOME/.restart-session"
printf '{"session_id":"legacy-ending"}' | bash "$REPO/template/.claude/hooks/on-session-end.sh"
check 'unrelated SessionEnd ignores shared legacy marker' '[ ! -e "$MEGAVIBE_RESTART_MARKER" ] && [ -f "$MEGAVIBE_HOME/.restart-session" ] && [ ! -e .agent/sessions/legacy-ending/restart-handover.txt ]'
helper request before-clear 100 >/dev/null
printf '{"session_id":"after-clear"}' | bash "$REPO/template/.claude/hooks/on-session-end.sh"
check 'changed conversation at exit cancels the old request' '[ ! -e "$MEGAVIBE_RESTART_MARKER" ] && [ -z "$(helper show before-clear)" ] && grep -q not-restarted .agent/sessions/before-clear/restart-handover.status'
# PostToolUse evidence supplies task id/start time even before the next Stop.
export MEGAVIBE_BG_WATCH=1
printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"posttool","tool_input":{"run_in_background":true,"command":"build-example"},"tool_response":{"backgroundTaskId":"job123"}}' | bash "$REPO/template/.claude/hooks/watch-background.sh" >/dev/null
helper request posttool 100 >/dev/null
check 'PostToolUse saves safe metadata and start time' 'grep -q job123 .agent/sessions/posttool/restart-handover.txt && ! grep -q "start: unknown" .agent/sessions/posttool/restart-handover.txt'
printf '{"hook_event_name":"Stop","session_id":"posttool","background_tasks":[]}' | bash "$REPO/template/.claude/hooks/watch-background.sh" >/dev/null
check 'empty live registry clears finished task evidence' '[ "$(jq length .agent/LOGS/.restart-tasks.posttool.json)" = 0 ]'
printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"posttool","tool_input":{"run_in_background":true,"command":"curl --token FAKE_POST"},"tool_response":{"backgroundTaskId":"new-job"}}' | bash "$REPO/template/.claude/hooks/watch-background.sh" >/dev/null
helper capture posttool 100
check 'new task after empty Stop is captured without its command' 'grep -q new-job .agent/sessions/posttool/restart-handover.txt && ! rg FAKE_POST .agent/LOGS/.restart-tasks.posttool.json .agent/sessions/posttool'
printf '%s' '[{"id":"old","command":"curl --token FAKE_OLD","environment":{"X":"FAKE_ENV"}}]' > .agent/LOGS/.restart-tasks.posttool.json
printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"posttool","tool_input":{"run_in_background":true,"command":"curl --token FAKE_NEW"},"tool_response":{"backgroundTaskId":"newer-job"}}' | bash "$REPO/template/.claude/hooks/watch-background.sh" >/dev/null
check 'PostToolUse sanitizes retained legacy registry entries too' '! rg FAKE_ .agent/LOGS/.restart-tasks.posttool.json'
# Missing/incomplete observations must not turn into a claim of no running work.
helper request no-registry 100 >/dev/null
check 'missing registry explicitly reported' 'grep -q "Registry unavailable" .agent/sessions/no-registry/restart-handover.txt'
# Two sessions never consume each other's files.
helper request beta 100 >/dev/null
hook '{"source":"resume","session_id":"alpha"}' >/dev/null
check 'showing alpha leaves beta pending' '[ -f .agent/sessions/beta/restart-handover.txt ] && [ ! -e .agent/sessions/beta/restart-handover.shown ]'
# Startup without a handover produces no restart output.
: > .agent/DECISIONS.md; : > .agent/LESSONS.md
check 'ordinary startup stays silent in an empty project' '[ -z "$(hook '\''{"source":"startup","session_id":"ordinary"}'\'')" ]'
# Review regressions: credentials, stale generations, delivery budget and cost.
cat >> "$T/processes" <<'DATA'
600 100 Wed Nov 25 10:09:00 2026 curl --api-key FAKE_KEY --token=FAKE_TOKEN --secret FAKE_SECRET --password FAKE_PASSWORD -H 'Authorization: Bearer FAKE_BEARER' https://user:FAKE_URL@example.test
601 100 Wed Nov 25 10:10:00 2026 PRIVATE_ENV=FAKE_ENV command --auth FAKE_AUTH
DATA
printf '%s' '[{"id":"cred-task","command":"curl --token FAKE_REGISTRY", "environment":{"HOME":"FAKE_ENV"}, "description":"FAKE_DESCRIPTION"}]' > .agent/LOGS/.restart-tasks.credentials.json
helper request credentials 100 >/dev/null
check 'credentials absent at every restart persistence boundary' '! rg "FAKE_" .agent/sessions/credentials'
check 'handover and snapshots are owner-only' '[ "$(stat -c %a .agent/sessions/credentials/restart-handover.txt 2>/dev/null || stat -f %Lp .agent/sessions/credentials/restart-handover.txt)" = 600 ] && [ "$(stat -c %a .agent/sessions/credentials/restart-processes.json 2>/dev/null || stat -f %Lp .agent/sessions/credentials/restart-processes.json)" = 600 ]'
helper request cancelled 100 >/dev/null
helper cancel cancelled 100 || true
check 'cancelled capture is retained but never reminded' '[ -f .agent/sessions/cancelled/restart-handover.txt ] && grep -q not-restarted .agent/sessions/cancelled/restart-handover.status && [ -z "$(helper show cancelled)" ]'
helper request pending 100 >/dev/null
check 'uncompleted request is not an active reminder' '[ -z "$(helper show pending)" ]'
helper request delayed 100 >/dev/null
echo 'Purpose: keep authored notes.' >> .agent/sessions/delayed/restart-handover.txt
printf '[{"id":"newly-started-task"}]' > .agent/LOGS/.restart-tasks.delayed.json
sed '/^200 /d' "$T/processes" > "$T/new"; mv "$T/new" "$T/processes"
helper capture delayed 100
check 'exit capture refreshes tasks and removes disappeared processes, preserves notes' 'grep -q newly-started-task .agent/sessions/delayed/restart-handover.txt && ! grep -q "PID 200" .agent/sessions/delayed/restart-handover.txt && grep -q "Purpose:" .agent/sessions/delayed/restart-handover.txt'
helper complete delayed 100 || true
python3 - <<'LARGE'
from pathlib import Path
p=Path('.agent/sessions/delayed/restart-handover.txt')
with p.open('a') as f: f.write('x'*12722)
LARGE
out=$(helper show delayed)
check 'large reminder is bounded, counted, points to full retained file and marked shown' 'printf "%s" "$out" | jq -e '\''.hookSpecificOutput.additionalContext | length < 2000 and contains("restart-handover.txt") and contains("observations") and contains("Read the full")'\'' >/dev/null && [ -d .agent/sessions/delayed/restart-handover.shown ]'
helper request delivery 100 >/dev/null
helper capture delivery 100
helper complete delivery 100 || true
( printf() { case "${2:-}" in *hookSpecificOutput*) return 1 ;; *) builtin printf "$@" ;; esac; }; export -f printf; helper show delivery ) >/dev/null 2>&1 || true
check 'failed output does not consume reminder' '[ ! -e .agent/sessions/delivery/restart-handover.shown ]'
rm -f "$T/scans" "$T/ps-calls"
printf '{"hook_event_name":"Stop","session_id":"never-restarted","stop_hook_active":true,"background_tasks":[]}' | MEGAVIBE_BG_WATCH=0 MEGAVIBE_DISK_WATCH=0 bash "$REPO/template/.claude/hooks/watch-background.sh"
check 'ordinary disabled Stop does not scan processes or persist restart processes' '[ ! -e "$T/ps-calls" ] && [ ! -d .agent/sessions/never-restarted ]'
printf '%s' '{"hook_event_name":"Stop","session_id":"safe-registry","background_tasks":[{"id":"secret-job","status":"running","command":"curl --auth FAKE_WATCH","environment":{"X":"FAKE_ENV"},"description":"FAKE_DESCRIPTION"}]}' | MEGAVIBE_BG_WATCH=0 MEGAVIBE_DISK_WATCH=0 bash "$REPO/template/.claude/hooks/watch-background.sh"
check 'Stop registry drops commands descriptions and environment before persistence' '! rg FAKE_ .agent/LOGS/.restart-tasks.safe-registry.json'
# The shipped restart function, with all external actions stubbed, tests the
# exact argv at re-exec rather than merely grepping its implementation.
sed -n '/^restart_after_exit() {/,/^}/p' "$REPO/megavibe" > "$T/fn"
cat > "$MEGAVIBE_HOME/megavibe" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$FIXTURE/exec-args"
STUB
chmod +x "$MEGAVIBE_HOME/megavibe"
printf 'exit 0\n' > "$T/init"
launch_restart() {
  env BOLD= YELLOW= RESET= GREEN= NORMALIZE="$1" REPO_DIR= VERSION_FILE="$T/version" INIT_SCRIPT="$T/init" CLAUDE_PID=100 \
    bash -c 'source "$1"; do_update() { return 0; }; restore_launch_parent() { :; }; restart_after_exit' _ "$T/fn"
}
echo alpha > "$MEGAVIBE_RESTART_MARKER"
launch_restart 0 >/dev/null
check 're-exec resumes exact marker id and keeps no-normalize' '[ "$(cat "$T/exec-args")" = "$(printf "%s\n" --no-normalize --resume alpha)" ] && [ ! -f "$MEGAVIBE_RESTART_MARKER" ]'
printf '{"sessionId":"owned"}' > "$CLAUDE_CONFIG_DIR/sessions/100.json"
: > "$MEGAVIBE_HOME/.restart-session"
rm -f "$T/exec-args"
launch_restart 1 >/dev/null || true
check 'launcher ignores shared legacy marker even with registry id' '[ ! -e "$T/exec-args" ] && [ -f "$MEGAVIBE_HOME/.restart-session" ]'
rm "$CLAUDE_CONFIG_DIR/sessions/100.json"
: > "$MEGAVIBE_RESTART_MARKER"
rc=0; out=$(launch_restart 1 2>&1) || rc=$?
check 'launcher unknown-id skips instead of continuing' '[ "$rc" != 0 ] && [ ! -e "$T/exec-args" ] && [[ "$out" == *"skipped: session id unavailable"* ]]'
# Exercise both actual launcher branches, with only their outside services
# stubbed. This catches a resume branch accidentally bypassing restart handling.
sed -n '/^if $IS_RESUME; then/,/^# ─── Fresh start:/p' "$REPO/megavibe" > "$T/resume-branch"
sed -n '/^# Launch claude (foreground via wait/,$p' "$REPO/megavibe" > "$T/fresh-branch"
cat > "$T/branch-runner" <<'STUB'
set -euo pipefail
source "$FIXTURE/fn"
BOLD= YELLOW= RESET= GREEN= DIM= NORMALIZE=1 REPO_DIR= VERSION_FILE="$FIXTURE/version" INIT_SCRIPT="$FIXTURE/init"
IS_RESUME=true LOCK_DIR="$FIXTURE/no-lock" ROUTER_NOTE= STYLE_ARGS=() ROUTER_ARGS=()
do_update() { return 0; }
restore_launch_parent() { :; }
acquire_lock() { :; }
release_lock() { :; }
update_lock_pid() { :; }
record_launch() { echo recorded >> "$FIXTURE/recorded"; }
rc_name_prefix() { echo fixture; }
compute_router_args() { :; }
launch_claude() { printf '%s\n' exact-conversation > "$MEGAVIBE_RESTART_MARKER"; }
branch=$1; shift
source "$branch"
STUB
for branch in fresh resume; do
  rm -f "$T/exec-args" "$T/recorded"
  bash "$T/branch-runner" "$T/$branch-branch" --resume previous-conversation >/dev/null
  check "$branch launcher branch records and resumes exact conversation" '[ "$(cat "$T/exec-args")" = "$(printf "%s\n" --resume exact-conversation)" ] && [ "$(cat "$T/recorded")" = recorded ]'
done
check 'both installer paths ship restart helpers' 'grep -q '\''"$SCRIPT_DIR/scripts/restart.sh" "$SCRIPT_DIR/scripts/restart-all.sh"'\'' "$REPO/setup.sh" && grep -q '\''"$REPO_DIR/scripts/restart.sh" "$REPO_DIR/scripts/restart-all.sh"'\'' "$REPO/megavibe"'
check 'hook registered for resume as well as startup' 'jq -e '\''.hooks.SessionStart[] | select(any(.hooks[]; .command == ".claude/hooks/on-session-start.sh")) | .matcher == "startup|resume"'\'' "$REPO/template/.claude/settings.json" >/dev/null'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
