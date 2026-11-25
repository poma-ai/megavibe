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
      n=$(cat "$FIXTURE/captures" 2>/dev/null || echo 0)
      n=$((n+1)); echo "$n" > "$FIXTURE/captures"
      [ "$n" = 2 ] || exit 0
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
check 'dry run reports every session and no restart promises' '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 10 ] && [[ "$out" == *"0 would restart, 9 skipped"* ]]'
check 'caller is considered last' '[[ "$(printf "%s\n" "$out" | tail -2 | head -1)" == "sid-100 (pid 100): skipped:"* ]]'
check 'dry run never creates requests or handovers' '[ ! -e "$T/sent" ] && [ ! -d "$T/project with spaces/.agent/sessions" ] && ! compgen -G "$MEGAVIBE_HOME/.restart-session*" >/dev/null'
out=$(run --others)
check 'others excludes actual ancestor' '[[ "$out" == *"sid-100 (pid 100): skipped: caller excluded"* ]]'
out=$(run)
check 'idle pane gets no automatic input or restarted claim' '[ ! -e "$T/sent" ] && [[ "$out" == *"0 restarted, 9 skipped"* ]]'
rm -f "$T/sent"
out=$(RACE=1 run)
check 'busy transition during capture gets no input' '[ ! -e "$T/sent" ] && [[ "$out" == *"0 restarted, 9 skipped"* ]]'
check 'batch cancellation cannot leave a capture or marker' '[ ! -d "$T/project with spaces/.agent/sessions" ] && ! compgen -G "$MEGAVIBE_HOME/.restart-session*" >/dev/null'
out=$(DEAD_PID=100 run --dry-run)
check 'dead registry entries are not candidates' '[[ "$out" != *"sid-100"* ]]'
out=$(CLAUDE_CODE_SESSION_ID=sid-200 run --others --dry-run)
check 'inherited id cannot select the caller' '[[ "$out" == *"sid-100 (pid 100): skipped: caller excluded"* ]]'
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
