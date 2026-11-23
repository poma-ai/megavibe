#!/bin/bash
# /bin/bash tests/node-sessions.test.sh
# The session register of scripts/megavibe-node.sh (`megavibe node session ...`): start, add, check,
# resume, done, drop, list. Liveness is a tmux window user option, so this runs a REAL tmux, on a
# private server only: every tmux call here and in the script under test goes through a wrapper on
# PATH that runs `env -u TMUX <tmux> -L <own socket> -f /dev/null` (inside tmux, TMUX points at the
# live server and wins over TMUX_TMPDIR; -L with TMUX removed does not). The test stops before doing
# anything else if the server it reached is not its own. It uses no tmux kill verb at all: it ends
# the pane processes it started, by pid, and the server exits when its last session closes.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
REAL_TMUX=$(command -v tmux) || { echo "skip: tmux not installed"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/node-sess-test.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
SOCK="mvtest-$$"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }

B="$T/bin"; mkdir -p "$B"
printf '#!/bin/bash\n[ -z "${TMUX_BROKEN:-}" ] || { echo "protocol version mismatch" >&2; exit 1; }\n[ -z "${TMUX_NOSERVER:-}" ] || { echo "no server running on /nowhere" >&2; exit 1; }\nexec env -u TMUX -u TMUX_PANE "%s" -L "%s" -f /dev/null "$@"\n' "$REAL_TMUX" "$SOCK" > "$B/tmux"
# megavibe stub: one line per call, then it stays alive like a session would.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/megavibe.calls"\nexec sleep 600\n' "$T" > "$B/megavibe"
printf '#!/bin/bash\necho testmac\n' > "$B/scutil"
printf '#!/bin/bash\necho Darwin\n' > "$B/uname"
printf '#!/bin/bash\n[ "$1" = print ] && exit 113\nexit 0\n' > "$B/launchctl"
chmod +x "$B"/*
export PATH="$B:$PATH"
export HOME="$T/home" MEGAVIBE_HOME="$T/home/.megavibe"
mkdir -p "$MEGAVIBE_HOME/personal"
N="$MEGAVIBE_HOME/node"; S="$N/sessions"

# Ends every pane of the private server (processes this test started) by pid: HUP first, because an
# interactive shell (the window megavibe-node.sh creates with a new tmux session) ignores TERM; KILL for
# what is left. The server then exits by itself; its socket file stays behind and is removed at the end.
end_panes() {
  local p i
  for p in $(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null); do kill -HUP "$p" 2>/dev/null; done
  for i in 1 2 3 4 5 6; do tmux has-session 2>/dev/null || return 0; sleep 0.5; done
  for p in $(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
}
SP=""
cleanup() {
  end_panes
  case "$SP" in */"$SOCK") tmux has-session 2>/dev/null || rm -f "$SP" ;; esac
  rm -rf "$T"
}
trap cleanup EXIT
gone() {   # gone STAMP: wait up to 5 s until no window carries that stamp
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do tmux list-windows -a -F '#{@mv_session}' 2>/dev/null | grep -qxF -- "$1" || return 0; sleep 0.5; done; return 1
}
pane_of() { tmux list-windows -a -F '#{@mv_session} #{pane_pid}' | awk -v n="$1" '$1 == n { print $2 }'; }
ctl() { o=$(bash "$REPO/scripts/megavibe-node.sh" "$@" 2>&1); RC=$?; }
called() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do grep -q -- "$1" "$T/megavibe.calls" 2>/dev/null && return 0; sleep 0.5; done; return 1; }   # the stub writes its line when the window starts
rec() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$S/$1" 2>/dev/null; }

tmux new-session -d -s main -n shell sleep 600 || { echo "could not start the private tmux server"; exit 2; }
SP=$(tmux display-message -p '#{socket_path}')
case "$SP" in */"$SOCK") ;; *) echo "ABORT: tmux answered from $SP, not from the private socket $SOCK"; exit 2 ;; esac

ctl session check
check "check before install: nothing registered, exit 0 ($o)" '[ "$RC" = 0 ] && [[ "$o" == ok* ]]'
ctl install
D="$T/proj a"; mkdir -p "$D"; TASK="$T/task alpha.md"; echo "do it" > "$TASK"

# ── start ─────────────────────────────────────────────────────────────
ctl session start alpha --dir "$D" --task "$TASK" --model sonnet
SID=$(rec alpha sid)
check "start: exit 0, registered as running with folder, task, started, id ($o)" '[ "$RC" = 0 ] && [ "$(rec alpha state)" = running ] && [ "$(rec alpha dir)" = "$D" ] && [ "$(rec alpha task)" = "$TASK" ] && [ -n "$(rec alpha started)" ] && [[ "$SID" =~ ^[0-9a-f-]{36}$ ]]'
check "start: a window named after the session, stamped with it" 'tmux list-windows -t main -F "#{window_name} #{@mv_session}" | grep -qx "alpha alpha"'
check "start: megavibe gets the name, model, chosen id and a prompt naming the task and the PA" 'called "^--name alpha --model sonnet --session-id $SID Read the task file $TASK and carry it out fully.*Personal Assistant"'
check "start: the window runs in the given folder" '[ "$(tmux list-windows -a -F "#{@mv_session} #{pane_current_path}" | sed -n "s/^alpha //p")" = "$D" ]'
ctl session start alpha --dir "$D" --task "$TASK"
check "start again while it runs: refused, one window ($o)" '[ "$RC" = 1 ] && [ "$(tmux list-windows -a -F "#{@mv_session}" | grep -cx alpha)" = 1 ]'
ctl session start beta --dir "$D" --task "$T/missing.md"
check "start without the task file: refused, nothing registered or started" '[ "$RC" = 1 ] && [ ! -e "$S/beta" ] && ! tmux list-windows -a -F "#{@mv_session}" | grep -qx beta'
ctl session start '../x' --dir "$D" --task "$TASK"; check "start with a path as name: refused" '[ "$RC" = 1 ] && [ ! -e "$N/x" ]'
ctl session start beta --dir "$D" --task "$TASK" --model '--dangerous'; check "start with an option as model: refused" '[ "$RC" = 1 ] && [ ! -e "$S/beta" ]'
ctl session start beta --dir "$D" --task; check "start with a missing option value: refused" '[ "$RC" = 1 ] && [ ! -e "$S/beta" ]'
TMUX_BROKEN=1 ctl session start beta --dir "$D" --task "$TASK"
check "start while tmux cannot answer: refused (a running copy could not be ruled out)" '[ "$RC" = 1 ] && [ ! -e "$S/beta" ] && [[ "$o" == *"cannot tell"* ]]'
ctl session start beta --dir "$D" --task "$TASK" --window w-beta --prompt "custom brief"
check "start beta with its own window name and prompt" '[ "$RC" = 0 ] && tmux list-windows -t main -F "#{window_name} #{@mv_session}" | grep -qx "w-beta beta" && called "^--name beta --session-id $(rec beta sid) custom brief\$"'

# ── check ─────────────────────────────────────────────────────────────
ctl session check
check "check: both alive, exit 0 ($o)" '[ "$RC" = 0 ] && [[ "$o" == "ok: 2 session"* ]]'
tmux rename-window -t main:w-beta renamed
tmux new-window -d -t main: -n alpha2 sleep 600
kill "$(pane_of alpha)"; gone alpha
tmux rename-window -t main:alpha2 alpha
ctl session check
check "check: alpha vanished (exit 1), listed with its task and the resume line ($o)" '[ "$RC" = 1 ] && [[ "$o" == "VANISHED (1 of 2)"* ]] && [[ "$o" == *"task:   $TASK"* ]] && [[ "$o" == *"megavibe node session resume alpha"* ]]'
check "check: a renamed window keeps its session; another window with the old name does not count" '[[ "$o" != *beta* ]]'
ctl session check; check "check: still listed on the next run (until resumed or marked)" '[ "$RC" = 1 ]'
ctl session list
check "list: alpha VANISHED, beta running ($o)" '[[ "$o" == *"VANISHED  alpha"* ]] && [[ "$o" == *"running   beta"* ]]'
TMUX_BROKEN=1 ctl session check
check "check while tmux cannot answer: exit 2, nothing called vanished ($o)" '[ "$RC" = 2 ] && [[ "$o" == UNKNOWN* ]] && [[ "$o" != *VANISHED* ]]'
# A tmux socket file removed from /tmp while its server runs: tmux says "no server", the sessions live.
TMUX_NOSERVER=1 ctl session check
check "tmux says no server while beta's process lives: beta is UNSEEN, not vanished; alpha still vanished ($o)" '[ "$RC" = 1 ] && [[ "$o" == *"VANISHED (1 of 2)"* ]] && [[ "$o" == *"UNSEEN (1 of 2)"*beta* ]]'
TMUX_NOSERVER=1 ctl session resume beta
check "resume of an unseen session: refused, its process is alive ($o)" '[ "$RC" = 1 ] && [[ "$o" == *"still alive"* ]]'
ctl session resume alpha --frehs; check "resume with a mistyped option: refused, nothing started" '[ "$RC" = 1 ] && ! tmux list-windows -a -F "#{@mv_session}" | grep -qx alpha'
ctl session start eps --dir "$D" --task "$TASK" --prompt "--dangerously-x"; check "start with a prompt that starts with a dash: refused" '[ "$RC" = 1 ] && [ ! -e "$S/eps" ]'
ctl status; check "status counts the registered sessions" '[[ "$o" == *"2 registered as running"* ]]'

# ── resume, done, drop ────────────────────────────────────────────────
ctl session resume beta; check "resume of a session that still runs: refused" '[ "$RC" = 1 ] && [ "$(tmux list-windows -a -F "#{@mv_session}" | grep -cx beta)" = 1 ]'
ctl session start alpha --dir "$D" --task "$TASK"; check "start of a vanished session: refused, points to resume" '[ "$RC" = 1 ] && [[ "$o" == *"session resume alpha"* ]]'
ctl session resume alpha
check "resume: the recorded conversation, same name and model, in a new stamped window ($o)" '[ "$RC" = 0 ] && called "^--name alpha --model sonnet --resume $SID Your session ended unexpectedly.*$TASK.*Personal Assistant" && [ "$(tmux list-windows -a -F "#{@mv_session}" | grep -cx alpha)" = 1 ] && [ "$(rec alpha sid)" = "$SID" ] && [ -n "$(rec alpha resumed)" ]'
ctl session check; check "check after the resume: ok" '[ "$RC" = 0 ]'
TMUX_NOSERVER=1 ctl session check
check "no visible window, every process alive: exit 2, nothing called vanished ($o)" '[ "$RC" = 2 ] && [[ "$o" == "UNSEEN (2 of 2)"* ]] && [[ "$o" != *VANISHED* ]]'
chmod 500 "$S"; ctl session start zeta --dir "$D" --task "$TASK"; chmod 700 "$S"
check "start with an unwritable register: nothing started ($o)" '[ "$RC" = 1 ] && ! tmux list-windows -a -F "#{@mv_session}" | grep -qx zeta'
kill "$(pane_of alpha)"; gone alpha
ctl session resume alpha --fresh
check "resume --fresh: a new conversation with the continue brief, id replaced" '[ "$RC" = 0 ] && called "^--name alpha --model sonnet --session-id $(rec alpha sid) A previous session working on the task in $TASK" && [ "$(rec alpha sid)" != "$SID" ]'
ctl session done beta
check "done: state done" '[ "$RC" = 0 ] && [ "$(rec beta state)" = done ] && [ -n "$(rec beta ended)" ]'
kill "$(pane_of beta)"; gone beta
ctl session check; check "check: a session marked done is not reported when its window goes ($o)" '[ "$RC" = 0 ] && [[ "$o" == "ok: 1 session"* ]]'
ctl session resume beta; check "resume of a done session: refused" '[ "$RC" = 1 ]'
ctl session start beta --dir "$D" --task "$TASK"; check "a done name can be started again" '[ "$RC" = 0 ] && [ "$(rec beta state)" = running ] && [ -z "$(rec beta ended)" ]'
ctl session drop beta; check "drop: state dropped, no longer checked" '[ "$(rec beta state)" = dropped ]'
ctl session done nosuch; check "done for an unknown name: refused" '[ "$RC" = 1 ]'

# ── add: a session that already runs in a window ──────────────────────
tmux new-window -d -t main: -n manual -c "$D" sleep 600
ctl session add gamma --window main:manual --task "$TASK"
check "add: window stamped, registered with the window's folder ($o)" '[ "$RC" = 0 ] && tmux list-windows -a -F "#{window_name} #{@mv_session}" | grep -qx "manual gamma" && [ "$(rec gamma state)" = running ] && [ "$(rec gamma dir)" = "$D" ]'
ctl session add delta --window main:manual --task "$TASK"; check "add onto a window of another session: refused" '[ "$RC" = 1 ] && [ ! -e "$S/delta" ]'
ctl session add delta --window main:nowhere --task "$TASK"; check "add with no such window: refused" '[ "$RC" = 1 ] && [ ! -e "$S/delta" ]'
ctl session add delta --window main:shell --task "$TASK" --sid nope; check "add with a bad id: refused" '[ "$RC" = 1 ] && [ ! -e "$S/delta" ]'
tmux new-window -d -t main: -n twin sleep 600; tmux new-window -d -t main: -n twin sleep 600
ctl session add delta --window main:twin --task "$TASK"; check "add with two windows of that name: refused, none stamped" '[ "$RC" = 1 ] && [ ! -e "$S/delta" ] && ! tmux list-windows -a -F "#{@mv_session}" | grep -qx delta'
TW=$(tmux list-windows -t main -F '#{window_id} #{window_name}' | awk '$2 == "twin" { print $1; exit }')
ctl session add delta --window "$TW" --task "$TASK" --dir "$D" --sid 11111111-2222-4333-8444-555555555555
check "add by window id, with a known conversation id ($o)" '[ "$RC" = 0 ] && [ "$(rec delta window)" = "$TW" ] && [ "$(rec delta sid)" = 11111111-2222-4333-8444-555555555555 ]'
ctl session drop delta

# ── the whole tmux server gone (the incident) ─────────────────────────
end_panes
for i in 1 2 3 4 5 6 7 8 9 10; do tmux has-session -t main 2>/dev/null || break; sleep 0.5; done
check "the private server has exited" '! tmux has-session -t main 2>/dev/null'
ctl session check
check "check with no tmux server: every running session is reported, with the reason ($o)" '[ "$RC" = 1 ] && [[ "$o" == "VANISHED (2 of 2)"*"no tmux server"* ]] && [[ "$o" == *alpha* ]] && [[ "$o" == *gamma* ]]'
ctl session resume gamma
check "resume with no server: the node's tmux session is created again; no known conversation -> a new one ($o)" '[ "$RC" = 0 ] && tmux list-windows -t main -F "#{@mv_session}" | grep -qx gamma && called "^--name gamma --session-id $(rec gamma sid) A previous session"'
SP=$(tmux display-message -p '#{socket_path}')
check "the server that came back is the private one" '[[ "$SP" == */"$SOCK" ]]'
ctl session check; check "check: gamma back, alpha still vanished" '[ "$RC" = 1 ] && [[ "$o" == "VANISHED (1 of 2)"* ]] && [[ "$o" != *gamma* ]]'

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
