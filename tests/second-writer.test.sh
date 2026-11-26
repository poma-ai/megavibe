#!/bin/bash
# The launcher refuses to resume a conversation that another live process still has open
# (two writers on one transcript lose messages; see the vendor's sessions page), names the
# holder and how to reach or fork it, and lets unknown state through. The functions are
# extracted from the wrapper so the test runs the shipped code. Scratch HOME, stub ps and
# kill, no real sessions, no tmux server: tmux is never called by the code under test.
set -euo pipefail
REPO=${SECOND_WRITER_TEST_REPO:-$(cd "$(dirname "$0")/.." && pwd -P)}
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-second-writer.XXXXXX")
trap 'rm -rf "$T"' EXIT

PASS=0 FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }

for fn in resume_target session_holder second_writer_message second_writer_gate; do
  sed -n "/^$fn() {/,/^}/p" "$REPO/megavibe" >> "$T/fn.sh"
done

export HOME="$T/home" MEGAVIBE_HOME="$T/home/.megavibe" CLAUDE_CONFIG_DIR="$T/home/.claude"
mkdir -p "$T/bin" "$CLAUDE_CONFIG_DIR/sessions" "$MEGAVIBE_HOME/launches"
# ps: lstart and comm per pid from files the cases write; PS_FAIL=1 makes it unreadable.
cat > "$T/bin/ps" <<'STUB'
#!/bin/bash
[ "${PS_FAIL:-0}" = 1 ] && exit 1
case "$1 $2 $3" in
  '-o lstart= -p') f="$FIXT/lstart.$4" ;;
  '-o comm= -p') f="$FIXT/comm.$4" ;;
  *) exit 1 ;;
esac
[ -f "$f" ] && cat "$f" || exit 1
STUB
# tmux must never be run by the check: any call is recorded and fails the run.
printf '#!/bin/bash\necho "$*" >> "$FIXT/tmux-called"\nexit 1\n' > "$T/bin/tmux"
chmod +x "$T/bin/"*
export FIXT="$T" PATH="$T/bin:$PATH"

# run SNIPPET: source the functions in a clean bash with `kill -0` answered from $ALIVE.
run() {
  ALIVE="${ALIVE:-}" bash -c '
    kill() { if [ "$1" = -0 ]; then case " $ALIVE " in *" $2 "*) return 0 ;; *) return 1 ;; esac; fi; builtin kill "$@"; }
    set -uo pipefail; source "$1"; eval "$2"' _ "$T/fn.sh" "$1"
}
reg() { # reg PID JSON
  printf '%s\n' "$2" > "$CLAUDE_CONFIG_DIR/sessions/$1.json"
}
reset() { rm -f "$CLAUDE_CONFIG_DIR/sessions/"* "$MEGAVIBE_HOME/launches/"* "$T"/lstart.* "$T"/comm.*; }
SID=0b6f6c1e-1111-4222-8333-444455556666

check 'all four functions are in the wrapper' '[ "$(grep -c "^[a-z_]*() {" "$T/fn.sh")" = 4 ]'

# resume_target
tgt() { run "resume_target $*"; }
check 'target: --resume ID' '[ "$(tgt --resume "$SID")" = "$SID" ]'
check 'target: -r ID' '[ "$(tgt -r "$SID")" = "$SID" ]'
check 'target: --resume=ID' '[ "$(tgt --resume="$SID")" = "$SID" ]'
check 'target: after other flags, with a prompt' '[ "$(tgt --model opus --resume "$SID" "hello there")" = "$SID" ]'
check 'target: bare --resume is the picker' '[ -z "$(tgt --resume)" ]'
check 'target: --resume followed by a flag is the picker' '[ -z "$(tgt --resume --model opus)" ]'
check 'target: --fork-session after it means a new id' '[ -z "$(tgt --resume "$SID" --fork-session)" ]'
check 'target: --fork-session before it means a new id' '[ -z "$(tgt --fork-session -r "$SID")" ]'
check 'target: a fresh launch has none' '[ -z "$(tgt --model opus "do the thing")" ]'
check 'target: --continue has none (not resolvable here)' '[ -z "$(tgt -c)" ]'

# session_holder
reset
reg 4101 "{\"pid\":4101,\"sessionId\":\"$SID\",\"kind\":\"interactive\",\"procStart\":\"Wed Nov 25 16:40:22 2026\",\"tmux\":\"main:@21.%21\"}"
echo 'Wed Nov 25 16:40:22 2026' > "$T/lstart.4101"
check 'holder: live process with matching start time' '[ "$(ALIVE=4101 run "session_holder $SID")" = "$(printf "4101\tmain:@21.%%21")" ]'
check 'holder: a different conversation is not held' '[ -z "$(ALIVE=4101 run "session_holder 99999999-0000-4000-8000-000000000000")" ]'
check 'holder: dead pid is a stale record' '[ -z "$(ALIVE= run "session_holder $SID")" ]'
echo 'Thu Nov 26 09:00:00 2026' > "$T/lstart.4101"
check 'holder: reused pid (start time differs) is stale' '[ -z "$(ALIVE=4101 run "session_holder $SID")" ]'
echo 'Wed Nov 25  16:40:22 2026 ' > "$T/lstart.4101"
check 'holder: whitespace in ps output is normalised' '[ -n "$(ALIVE=4101 run "session_holder $SID")" ]'
check 'holder: unreadable ps is unknown, not held' '[ -z "$(PS_FAIL=1 ALIVE=4101 run "session_holder $SID")" ]'
check 'holder: matches the transcript path form' '[ -n "$(ALIVE=4101 run "session_holder /x/projects/-p/$SID.jsonl")" ]'

reset
reg 4102 "{\"pid\":4102,\"sessionId\":\"$SID\",\"name\":\"Release work\"}"
echo claude > "$T/comm.4102"
check 'holder: no start time, process is claude' '[ -n "$(ALIVE=4102 run "session_holder $SID")" ]'
check 'holder: matches by session name' '[ -n "$(ALIVE=4102 run "session_holder \"Release work\"")" ]'
echo bash > "$T/comm.4102"
check 'holder: no start time, process is something else' '[ -z "$(ALIVE=4102 run "session_holder $SID")" ]'

reset
reg 4103 "{\"pid\":4103,\"sessionId\":\"$SID\",\"kind\":\"background\",\"procStart\":\"Wed Nov 25 16:40:22 2026\"}"
echo 'Wed Nov 25 16:40:22 2026' > "$T/lstart.4103"
check 'holder: a background session is left to Claude Code (it attaches)' '[ -z "$(ALIVE=4103 run "session_holder $SID")" ]'

reset
printf 'not json' > "$CLAUDE_CONFIG_DIR/sessions/4104.json"
reg notapid "{\"sessionId\":\"$SID\"}"
check 'holder: unreadable record and non-pid file name are skipped' '[ -z "$(ALIVE="4104 notapid" run "session_holder $SID")" ]'
rm -rf "$CLAUDE_CONFIG_DIR/sessions"
check 'holder: no registry directory' '[ -z "$(ALIVE=4101 run "session_holder $SID")" ]'
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"

# second_writer_message
reset
printf '{"pid":4101,"socket":"/example/tmux-sock"}\n' > "$MEGAVIBE_HOME/launches/4101.json"
msg=$(run "second_writer_message $SID \"\$(printf '4101\tmain:@21.%%21')\"")
check 'message: names the pid' 'printf "%s" "$msg" | grep -q "pid 4101"'
check 'message: read-only tmux view with the recorded socket' 'printf "%s" "$msg" | grep -qF "tmux -S /example/tmux-sock capture-pane -p -t %21"'
check 'message: how to go to it' 'printf "%s" "$msg" | grep -qF "attach -t main"'
check 'message: fork and fresh session' 'printf "%s" "$msg" | grep -qF -- "--resume $SID --fork-session" && printf "%s" "$msg" | grep -q "fresh session"'
check 'message: explicit override' 'printf "%s" "$msg" | grep -qF -- "--allow-second-writer"'
msg=$(run "second_writer_message $SID \"\$(printf '4101\t')\"")
check 'message: no tmux location says so instead of inventing one' 'printf "%s" "$msg" | grep -q "not in a tmux pane" && ! printf "%s" "$msg" | grep -q capture-pane'

# second_writer_gate: the launcher's decision
reset
reg 4101 "{\"pid\":4101,\"sessionId\":\"$SID\",\"procStart\":\"Wed Nov 25 16:40:22 2026\",\"tmux\":\"main:@21.%21\"}"
echo 'Wed Nov 25 16:40:22 2026' > "$T/lstart.4101"
rc=0; out=$(ALIVE=4101 run "ALLOW_SECOND_WRITER=0; second_writer_gate --resume $SID" 2>&1) || rc=$?
check 'gate: refuses a second writer by default (exit 3)' '[ "$rc" = 3 ] && printf "%s" "$out" | grep -q "still open"'
rc=0; out=$(ALIVE=4101 run "ALLOW_SECOND_WRITER=1; second_writer_gate --resume $SID" 2>&1) || rc=$?
check 'gate: the override lets it through with a warning' '[ "$rc" = 0 ] && printf "%s" "$out" | grep -q "second writer"'
rc=0; out=$(ALIVE=4101 run "ALLOW_SECOND_WRITER=0; second_writer_gate --resume $SID --fork-session" 2>&1) || rc=$?
check 'gate: a fork passes silently' '[ "$rc" = 0 ] && [ -z "$out" ]'
rc=0; out=$(ALIVE= run "ALLOW_SECOND_WRITER=0; second_writer_gate --resume $SID" 2>&1) || rc=$?
check 'gate: a stale lock (dead holder) passes silently' '[ "$rc" = 0 ] && [ -z "$out" ]'
rc=0; out=$(ALIVE=4101 run "ALLOW_SECOND_WRITER=0; second_writer_gate --model opus \"fresh work\"" 2>&1) || rc=$?
check 'gate: a fresh launch is untouched' '[ "$rc" = 0 ] && [ -z "$out" ]'
rc=0; out=$(ALIVE=4101 PATH="$T/nojq:/usr/bin:/bin" run "command() { [ \"\$2\" = jq ] && return 1; builtin command \"\$@\"; }; ALLOW_SECOND_WRITER=0; second_writer_gate --resume $SID" 2>&1) || rc=$?
check 'gate: without jq it cannot know, so it does not block' '[ "$rc" = 0 ]'
check 'tmux was never run' '[ ! -e "$T/tmux-called" ]'

# Wiring in the wrapper
W="$REPO/megavibe"
gate_line=$(grep -n '^second_writer_gate "\$@" || exit' "$W" | cut -d: -f1 | head -1)
lock_line=$(grep -n '^# ─── Session lock' "$W" | cut -d: -f1)
check 'wrapper: gate runs once, before the session lock and both launch paths' '[ -n "$gate_line" ] && [ "$(grep -c "^second_writer_gate " "$W")" = 1 ] && [ "$gate_line" -lt "$lock_line" ]'
check 'wrapper: the override flag is consumed, never passed to claude' 'grep -q "\"\$_a\" = \"--allow-second-writer\" ] && ALLOW_SECOND_WRITER=1" "$W" && grep -q "\"--allow-second-writer\" ] || CLAUDE_ARGV+=" "$W"'
check 'wrapper: help lists the override' 'bash "$W" --help | grep -q -- "--allow-second-writer"'
check 'wrapper: no longer claims Claude rejects a session in use' '! grep -q "Claude will reject" "$W"'

echo "second-writer: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
