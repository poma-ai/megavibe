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
case "$*" in
  '-axo pid=,ppid=,lstart=,command=') cat "$FIXTURE/processes" ;;
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
helper observe alpha 100
cat > "$T/processes" <<'DATA'
100 10 Wed Nov 25 10:00:00 2026 claude
200 100 Wed Nov 25 10:01:00 2026 test-server --host 127.0.0.1
300 1 Wed Nov 25 10:02:00 2026 long-build
400 1 Wed Nov 25 10:03:00 2026 monitor-output
500 1 Wed Nov 25 09:00:00 2026 unrelated
DATA
printf '[{"id":"bg1","command":"test-build","started":123,"path":"/example/build.output"}]' > .agent/LOGS/.restart-tasks.alpha.json
out=$(helper request alpha 100)
f=.agent/sessions/alpha/restart-handover.txt
check 'request captures tasks and arms only own marker' '[ "$(cat "$MEGAVIBE_RESTART_MARKER")" = alpha ] && [ ! -e "$MEGAVIBE_HOME/.restart-session" ] && grep -q "test-build" "$f" && grep -q "start: 123; output: /example/build.output" "$f"'
check 'bound and previously observed detached processes classified' 'grep -q "session-bound: ends" "$f" && grep -q "named tmux build:%3: survives" "$f" && grep -q "reparented/detached: survives" "$f" && ! grep -q unrelated "$f"'
echo 'Purpose: scheduled prompt checks the build every hour; re-arm if still needed.' >> "$f"
cp "$f" "$T/before"
helper capture alpha 100
check 'recapture keeps model notes and pre-exit snapshot' 'cmp -s "$f" "$T/before"'
out=$(hook '{"source":"resume","session_id":"alpha"}')
check 'resume reminder works in otherwise empty project' 'printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext | contains(\"Before the restart you had these running:\") and contains(\"say which you dropped\") and contains(\"scheduled prompt\")" >/dev/null'
check 'shown once and original file retained' '[ -d .agent/sessions/alpha/restart-handover.shown ] && [ -f "$f" ] && [ -z "$(hook '\''{"source":"resume","session_id":"alpha"}'\'')" ]'
check 'other conversation has no reminder' '[ -z "$(hook '\''{"source":"resume","session_id":"beta"}'\'')" ]'
check 'compact does not consume a handover' '[ -z "$(hook '\''{"source":"compact","session_id":"alpha"}'\'')" ]'
helper request alpha 100 >/dev/null
check 'next restart archives shown generation and carries model notes' '[ ! -e .agent/sessions/alpha/restart-handover.shown ] && ls .agent/sessions/alpha/restart-handover.*.txt >/dev/null && grep -q "Purpose:" "$f"'
out=$(hook '{"source":"startup","session_id":"alpha"}')
check 'startup reminder also works with no project knowledge' 'printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext" >/dev/null'
check 'traversal id rejected' '! helper request ../bad 100 >/dev/null 2>&1 || [ ! -e .agent/bad ]'
helper observe reuse 100
# Same pid, different start time must not be inherited.
sed 's/400 1 Wed Nov 25 10:03:00/400 1 Wed Nov 25 11:03:00/' "$T/processes" > "$T/new"
mv "$T/new" "$T/processes"
helper request reuse 100 >/dev/null
check 'reused pid is not attributed' '! grep -q "PID 400" .agent/sessions/reuse/restart-handover.txt'
# Unknown-id fallback still arms the wrapper, but cannot invent a session directory.
out=$(helper request 2>&1)
check 'missing id fallback is a single line' '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 1 ] && [[ "$out" == *"fall back to --continue"* ]] && [ -f "$MEGAVIBE_RESTART_MARKER" ]'
# Use the real watch hook with harmless inputs and disk checking disabled.
export MEGAVIBE_BG_WATCH=0 MEGAVIBE_DISK_WATCH=0
printf '{"hook_event_name":"Stop","session_id":"registry","background_tasks":[{"id":"monitor1","status":"running","command":"watch-output","startTime":44,"outputFile":"/example/watch.output"},{"id":"done1","status":"completed","command":"finished"}]}' | bash "$REPO/template/.claude/hooks/watch-background.sh"
helper request registry 100 >/dev/null
check 'registry captures Monitor even with nudging disabled, excludes completed tasks' 'grep -q watch-output .agent/sessions/registry/restart-handover.txt && ! grep -q finished .agent/sessions/registry/restart-handover.txt && grep -q "start: 44" .agent/sessions/registry/restart-handover.txt'
cp .agent/LOGS/.restart-tasks.registry.json "$T/registry-before"
printf '{"hook_event_name":"Stop","session_id":"registry","transcript_path":"/example/registry/subagents/agent-worker.jsonl","background_tasks":[]}' | bash "$REPO/template/.claude/hooks/watch-background.sh"
check 'subagent Stop cannot erase parent registry snapshot' 'cmp -s "$T/registry-before" .agent/LOGS/.restart-tasks.registry.json'
# SessionEnd captures on an armed restart, while ordinary exits stay inert.
rm -f "$MEGAVIBE_RESTART_MARKER"
printf '{"session_id":"ordinary"}' | bash "$REPO/template/.claude/hooks/on-session-end.sh"
check 'ordinary SessionEnd creates no handover' '[ ! -e .agent/sessions/ordinary/restart-handover.txt ]'
: > "$MEGAVIBE_RESTART_MARKER"
printf '{"session_id":"ending"}' | bash "$REPO/template/.claude/hooks/on-session-end.sh"
check 'armed SessionEnd preserves full id and creates handover before cleanup' '[ "$(cat "$MEGAVIBE_RESTART_MARKER")" = ending ] && [ -f .agent/sessions/ending/restart-handover.txt ]'
rm -f "$MEGAVIBE_RESTART_MARKER"
: > "$MEGAVIBE_HOME/.restart-session"
printf '{"session_id":"legacy-ending"}' | bash "$REPO/template/.claude/hooks/on-session-end.sh"
check 'SessionEnd consumes legacy marker exactly once' '[ "$(cat "$MEGAVIBE_RESTART_MARKER")" = legacy-ending ] && [ ! -e "$MEGAVIBE_HOME/.restart-session" ]'
# PostToolUse evidence supplies start time/command even before the next Stop.
export MEGAVIBE_BG_WATCH=1
printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"posttool","tool_input":{"run_in_background":true,"command":"build-example"},"tool_response":{"backgroundTaskId":"job123"}}' | bash "$REPO/template/.claude/hooks/watch-background.sh" >/dev/null
helper request posttool 100 >/dev/null
check 'PostToolUse saves command and start time' 'grep -q build-example .agent/sessions/posttool/restart-handover.txt && ! grep -q "start: unknown" .agent/sessions/posttool/restart-handover.txt'
printf '{"hook_event_name":"Stop","session_id":"posttool","background_tasks":[]}' | bash "$REPO/template/.claude/hooks/watch-background.sh" >/dev/null
check 'empty live registry clears finished task evidence' '[ "$(jq length .agent/LOGS/.restart-tasks.posttool.json)" = 0 ]'
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
launch_restart 1 >/dev/null
check 'legacy update restart uses known id instead of most recent' '[ "$(cat "$T/exec-args")" = "$(printf "%s\n" --resume owned)" ]'
rm "$CLAUDE_CONFIG_DIR/sessions/100.json"
: > "$MEGAVIBE_RESTART_MARKER"
out=$(launch_restart 1 2>&1)
check 'launcher unknown-id fallback warns and continues' '[ "$(cat "$T/exec-args")" = --continue ] && [ "$(printf "%s" "$out" | grep -c "session id unavailable")" = 1 ]'
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
