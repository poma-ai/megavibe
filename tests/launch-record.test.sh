#!/bin/bash
# record_launch writes ~/.megavibe/launches/<pid>.json when the wrapper starts claude.
# The function is extracted from the wrapper so the test runs the shipped code.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-launch-record.XXXXXX")
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

{ sed -n '/^has_claude_ancestor() {/,/^}/p' "$REPO/megavibe"; sed -n '/^record_launch() {/,/^}/p' "$REPO/megavibe"; } > "$T/fn.sh"
grep -q '^record_launch() {' "$T/fn.sh" && grep -q '^has_claude_ancestor() {' "$T/fn.sh" || fail "functions not found in megavibe"

# A stub `ps` gives the recording shell a fixed ancestry: <shell> -> 50001 (named $FAKE_COMM) -> 50002 -> init.
# The real chain is not usable here: this test normally runs under a real claude session.
mkdir -p "$T/bin"
cat > "$T/bin/ps" <<'EOF'
#!/bin/bash
field=$2; pid=$4
case "$field" in
  ppid=) case "$pid" in 50001) echo 50002;; 50002) echo 1;; *) echo 50001;; esac ;;
  comm=) case "$pid" in 50001) echo "${FAKE_COMM:-zsh}";; 50002) echo login;; esac ;;
esac
EOF
chmod +x "$T/bin/ps"
# Both claude launch sites must record, or sessions started on that path are unmarked.
[ "$(grep -c '^  record_launch "\$CLAUDE_PID"$' "$REPO/megavibe")" = 2 ] || fail "expected record_launch after both claude launches"

run() { # run <pid> [env assignments...]: source the function in a clean shell
  local pid="$1"; shift
  (cd "$T" && env -i PATH="$T/bin:$PATH" MEGAVIBE_HOME="$T/home" "$@" bash -c 'set -euo pipefail; source "$1"; record_launch "$2"' _ "$T/fn.sh" "$pid")
}
run_c() { run "$1" FAKE_COMM=/Users/x/.local/bin/claude "${@:2}"; }  # the launching shell is a child of a claude process
field() { jq -r "$1" "$T/home/launches/$2.json"; }

# Explicit parent wins over the inherited session id.
run 4001 MEGAVIBE_PARENT_SESSION=aaaa-1111 CLAUDE_CODE_SESSION_ID=bbbb-2222
[ "$(field .parentSessionId 4001)" = "aaaa-1111" ] || fail "explicit parent"
[ "$(field .launcher 4001)" = "megavibe" ] || fail "launcher field"
[ "$(field '.startedAt|type' 4001)" = "number" ] || fail "startedAt type"
# Owner-only permissions (checked now: later runs prune these fake, dead pids).
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }  # GNU first: `stat -f` succeeds on GNU with other output
[ "$(mode "$T/home/launches")" = 700 ] || fail "launches dir mode"
[ "$(mode "$T/home/launches/4001.json")" = 600 ] || fail "record mode"

# Inherited session id is used when no explicit parent is set and a claude process is an ancestor.
run_c 4002 CLAUDE_CODE_SESSION_ID=bbbb-2222
[ "$(field .parentSessionId 4002)" = "bbbb-2222" ] || fail "inherited parent"

# The same value with no claude ancestor (a stale id from a shared tmux server) is ignored.
run 4010 CLAUDE_CODE_SESSION_ID=bbbb-2222
[ "$(field .parentSessionId 4010)" = "null" ] || fail "stale inherited id must be ignored"

# An explicitly empty MEGAVIBE_PARENT_SESSION means "no parent", even under claude with an inherited id.
run_c 4011 MEGAVIBE_PARENT_SESSION= CLAUDE_CODE_SESSION_ID=bbbb-2222
[ "$(field .parentSessionId 4011)" = "null" ] || fail "empty explicit parent must mean none"

# No parent: still recorded, parent null (tells "started by megavibe" from a bare claude).
run 4003
[ "$(field .parentSessionId 4003)" = "null" ] || fail "no parent"

# A parent that is not a session id is dropped, never written.
run 4004 'MEGAVIBE_PARENT_SESSION=x"; touch pwned #'
[ "$(field .parentSessionId 4004)" = "null" ] || fail "invalid parent must be dropped"
[ ! -e "$T/pwned" ] || fail "parent id was executed"

# A bad pid writes nothing.
run 'abc' MEGAVIBE_PARENT_SESSION=aaaa-1111
[ ! -e "$T/home/launches/abc.json" ] || fail "non-numeric pid wrote a record"

# Records of dead processes are pruned; a live one is kept.
sleep 0 & dead=$!; wait "$dead" || true
printf '{"pid":%s}\n' "$dead" > "$T/home/launches/$dead.json"
live=$$
printf '{"pid":%s}\n' "$live" > "$T/home/launches/$live.json"
run 4005
[ ! -e "$T/home/launches/$dead.json" ] || fail "dead record not pruned"
[ -e "$T/home/launches/$live.json" ] || fail "live record was pruned"

# An unwritable home never fails the launch.
: > "$T/notadir"
env -i PATH="$PATH" MEGAVIBE_HOME="$T/notadir" bash -c 'set -euo pipefail; source "$1"; record_launch 4006; echo reached' _ "$T/fn.sh" | grep -q reached || fail "record_launch aborted the caller"

echo ok
