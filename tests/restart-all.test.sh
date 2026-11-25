#!/bin/bash
# Scratch HOME, entirely stubbed ps/tmux; no real process or tmux object is touched.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-restart-all.XXXXXX")
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" MEGAVIBE_HOME="$T/home/.megavibe" CLAUDE_CONFIG_DIR="$T/home/.claude" FIXTURE="$T"
mkdir -p "$T/bin" "$MEGAVIBE_HOME/launches" "$CLAUDE_CONFIG_DIR/sessions" "$T/project with spaces/.agent"
export PATH="$T/bin:$PATH"
# Session discovery uses kill -0 only. No live jobs are needed for these fixtures.
kill() { [ "${1:-}" = -0 ] && [ "${2:-}" != "${DEAD_PID:-none}" ]; }
export -f kill
cat > "$T/bin/ps" <<'STUB'
#!/bin/bash
case "$*" in
  '-o lstart= -p '*) [ "${FAIL_PS:-0}" = 0 ] || exit 1; echo 'Wed Nov 25 10:00:00 2026' ;;
  '-o pgid=,tpgid= -p 700') echo '700 701' ;;
  '-o pgid=,tpgid= -p '*) echo '100 100' ;;
  '-o ppid= -p '*)
    case "$4" in
      100) if [ "${BAD_WRAPPER:-0}" = 1 ]; then echo 10; else echo 101; fi ;;
      200|300|400|500|600|700|800|900) echo "$(( $4 + 1 ))" ;;
      101|201|301|401|501|601|701|801|901) echo 10 ;;
      10) echo 1 ;;
      *) echo 100 ;;
    esac ;;
  '-axo pid=,ppid=,lstart=,command=') echo '100 10 Wed Nov 25 10:00:00 2026 claude' ;;
  *) exit 1 ;;
esac
STUB
cat > "$T/bin/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$FIXTURE/tmux-calls"
if [ "$1" = list-panes ]; then exit 0; fi
[ "$1" = -S ] && [ "$2" = /example/tmux.sock ] || exit 8
shift 2
case "$1" in
  display-message)
    pane=$4
    case "$pane" in
      %400) echo '%999 999 0 0 12' ;;
      *) echo "$pane 10 ${COPY_MODE:-0} 0 12" ;;
    esac ;;
  capture-pane)
    [ "$5" = -S ] && [ "$6" = 12 ] && [ "$7" = -E ] && [ "$8" = 12 ] || exit 9
    case "$4" in %600) echo '❯ draft text' ;; *) echo '❯ ' ;; esac
    if [ "${RACE:-0}" = 1 ] && [ "$4" = %100 ]; then
      jq '.status = "busy"' "$CLAUDE_CONFIG_DIR/sessions/100.json" > "$FIXTURE/changed"
      mv "$FIXTURE/changed" "$CLAUDE_CONFIG_DIR/sessions/100.json"
    fi ;;
  send-keys)
    [ "${FAIL_SEND:-0}" = 0 ] || exit 1
    printf '%s\n' "$*" >> "$FIXTURE/sent" ;;
  *) exit 7 ;;
esac
STUB
chmod +x "$T/bin/"*
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
now=$(date +%s)
for pid in 100 200 300 400 500 600 700 800 900; do
  state=idle; pane="%$pid"; socket=/example/tmux.sock; protocol=1
  case "$pid" in 200) state=busy ;; 300) pane=; socket= ;; 500) state=unknown ;; 900) protocol=0 ;; esac
  jq -n --argjson pid "$pid" --argjson now "$now" --arg cwd "$T/project with spaces" --arg state "$state" \
    '{pid:$pid,sessionId:("sid-"+($pid|tostring)),name:"fixture",cwd:$cwd,status:$state,startedAt:($now*1000),procStart:(if $pid == 800 then null else "Wed Nov 25 10:00:00 2026" end)}' > "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
  jq -n --argjson pid "$pid" --argjson now "$now" --arg pane "$pane" --arg socket "$socket" --argjson protocol "$protocol" \
    '{pid:$pid,startedAt:$now,launcher:"megavibe",wrapperPid:($pid+1),restartProtocol:$protocol,pane:$pane,socket:$socket}' > "$MEGAVIBE_HOME/launches/$pid.json"
done
run() { bash "$REPO/scripts/restart-all.sh" "$@"; }
out=$(run --dry-run)
check 'dry run finds live recorded sessions with one result each and final count' '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 10 ] && [[ "$out" == *"1 would restart, 8 skipped"* ]]'
check 'caller is considered last' '[ "$(printf "%s\n" "$out" | tail -2 | head -1)" = "sid-100 (pid 100): would restart" ]'
check 'dry run writes neither handovers nor restart markers and sends no input' '[ ! -e "$T/sent" ] && [ ! -d "$T/project with spaces/.agent/sessions" ] && ! compgen -G "$MEGAVIBE_HOME/.restart-session*" >/dev/null'
check 'busy and unknown sessions skipped' '[[ "$out" == *"sid-200 (pid 200): skipped: busy"* ]] && [[ "$out" == *"sid-500 (pid 500): skipped: busy"* ]]'
check 'non-tmux and unmatched panes skipped' '[[ "$out" == *"sid-300 (pid 300): skipped: not in tmux"* ]] && [[ "$out" == *"sid-400 (pid 400): skipped: pane cannot be matched"* ]]'
check 'draft input and foreground child skipped' '[[ "$out" == *"sid-600 (pid 600): skipped: idle prompt cannot be established"* ]] && [[ "$out" == *"sid-700 (pid 700): skipped: foreground process group"* ]]'
check 'unknown identity and legacy launchers skipped' '[[ "$out" == *"sid-800 (pid 800): skipped: live process identity"* ]] && [[ "$out" == *"sid-900 (pid 900): skipped: launcher predates"* ]]'
out=$(run --others --dry-run)
check 'others explicitly excludes actual ancestor session' '[[ "$out" == *"sid-100 (pid 100): skipped: caller excluded"* ]] && [[ "$out" == *"0 would restart, 9 skipped"* ]]'
out=$(COPY_MODE=1 run --dry-run)
check 'copy mode is never sent input' '[[ "$out" == *"0 would restart, 9 skipped"* ]]'
out=$(FAIL_PS=1 run --dry-run)
check 'ps unavailable is busy/unknown, never idle' '[[ "$out" == *"0 would restart, 9 skipped"* ]]'
out=$(run)
check 'real run captures before submitting exit to exact pane' '[ "$(cat "$MEGAVIBE_HOME/.restart-session.101")" = sid-100 ] && [ -f "$T/project with spaces/.agent/sessions/sid-100/restart-handover.txt" ] && [ "$(cat "$T/sent")" = "$(printf "%s\n" "send-keys -t %100 -l /exit" "send-keys -t %100 Enter")" ] && [[ "$out" == *"1 restarted, 8 skipped"* ]]'
check 'no interrupt, kill, stop or tmux creation commands' '! grep -Eq "C-c|C-d|kill|stop|new-session|new-window" "$T/tmux-calls"'
out=$(FAIL_SEND=1 run)
check 'failed send is listed and disarms marker' '[[ "$out" == *"sid-100 (pid 100): skipped: could not submit"* ]] && [ ! -e "$MEGAVIBE_HOME/.restart-session.101" ]'
out=$(DEAD_PID=100 run --dry-run)
check 'dead registry entries are not candidates' '[[ "$out" != *"sid-100"* ]]'
out=$(CLAUDE_CODE_SESSION_ID=sid-200 run --others --dry-run)
check 'stale inherited id cannot select the caller' '[[ "$out" == *"sid-100 (pid 100): skipped: caller excluded"* ]]'
out=$(BAD_WRAPPER=1 run --dry-run)
check 'wrapper must also be in the pane ancestry' '[[ "$out" == *"sid-100 (pid 100): skipped: pane cannot be matched"* ]]'
out=$(RACE=1 run)
check 'session becoming busy during capture is skipped and disarmed' '[[ "$out" == *"sid-100 (pid 100): skipped: busy"* ]] && [ ! -e "$MEGAVIBE_HOME/.restart-session.101" ]'
jq '.status = "idle"' "$CLAUDE_CONFIG_DIR/sessions/100.json" > "$T/changed"; mv "$T/changed" "$CLAUDE_CONFIG_DIR/sessions/100.json"
jq '.status = "idle"' "$CLAUDE_CONFIG_DIR/sessions/200.json" > "$T/changed"; mv "$T/changed" "$CLAUDE_CONFIG_DIR/sessions/200.json"
: > "$T/sent"
out=$(run)
check 'multiple eligible sessions get distinct markers, caller input last' '[ "$(cat "$MEGAVIBE_HOME/.restart-session.101")" = sid-100 ] && [ "$(cat "$MEGAVIBE_HOME/.restart-session.201")" = sid-200 ] && [ "$(head -1 "$T/sent")" = "send-keys -t %200 -l /exit" ] && [ "$(tail -1 "$T/sent")" = "send-keys -t %100 Enter" ] && [[ "$out" == *"2 restarted, 7 skipped"* ]]'
# command discovery failure, without exposing any real tmux binary on PATH.
command() { [ "$*" != '-v tmux' ] || return 1; builtin command "$@"; }
export -f command
rc=0; out=$(run --dry-run 2>&1) || rc=$?
check 'without tmux reports why and exits nonzero' '[ "$rc" != 0 ] && [[ "$out" == *"tmux is unavailable"* ]]'
unset -f command
rc=0; run --bad >/dev/null 2>&1 || rc=$?
check 'unknown option rejected' '[ "$rc" = 2 ]'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
