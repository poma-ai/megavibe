#!/bin/bash
# record_launch writes ~/.megavibe/launches/<pid>.json when the wrapper starts claude.
# The function is extracted from the wrapper so the test runs the shipped code.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-launch-record.XXXXXX")
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

{ sed -n '/^is_session_ancestor() {/,/^}/p' "$REPO/megavibe"; sed -n '/^record_launch() {/,/^}/p' "$REPO/megavibe"; } > "$T/fn.sh"
grep -q '^record_launch() {' "$T/fn.sh" && grep -q '^is_session_ancestor() {' "$T/fn.sh" || fail "functions not found in megavibe"

# A stub `ps` gives the recording shell a fixed ancestry: <shell> -> 50001 -> 50002 -> init. The real chain is
# not usable here: this test normally runs under a real claude session. Pid 50001 plays the launching session;
# its registry file lives in a fake config dir ($T/cfg) and is written per case.
mkdir -p "$T/bin" "$T/cfg/sessions"
cat > "$T/bin/ps" <<'EOF'
#!/bin/bash
pid=$4
case "$pid" in 50001) echo 50002;; 50002) echo 1;; *) echo 50001;; esac
EOF
chmod +x "$T/bin/ps"
registry() { printf '{"pid":50001,"sessionId":"%s"}\n' "$1" > "$T/cfg/sessions/50001.json"; }
# Both claude launch sites must record, or sessions started on that path are unmarked.
[ "$(grep -c '^  record_launch "\$CLAUDE_PID"$' "$REPO/megavibe")" = 2 ] || fail "expected record_launch after both claude launches"

run() { # run <pid> [env assignments...]: source the function in a clean shell
  local pid="$1"; shift
  (cd "$T" && env -i PATH="$T/bin:$PATH" MEGAVIBE_HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" "$@" bash -c 'set -euo pipefail; source "$1"; record_launch "$2"' _ "$T/fn.sh" "$pid")
}
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

# Inherited session id is used when no explicit parent is set and an ancestor is that session's registered process.
registry bbbb-2222
run 4002 CLAUDE_CODE_SESSION_ID=bbbb-2222
[ "$(field .parentSessionId 4002)" = "bbbb-2222" ] || fail "inherited parent"

# An id the ancestor does not own (a stale value handed on by a shared tmux server) is ignored.
registry cccc-3333
run 4010 CLAUDE_CODE_SESSION_ID=bbbb-2222
[ "$(field .parentSessionId 4010)" = "null" ] || fail "foreign inherited id must be ignored"

# No registered ancestor at all: also ignored.
rm -f "$T/cfg/sessions/50001.json"
run 4012 CLAUDE_CODE_SESSION_ID=bbbb-2222
[ "$(field .parentSessionId 4012)" = "null" ] || fail "unregistered ancestry must be ignored"

# An explicitly empty MEGAVIBE_PARENT_SESSION means "no parent", even with a matching ancestor and inherited id.
registry bbbb-2222
run 4011 MEGAVIBE_PARENT_SESSION= CLAUDE_CODE_SESSION_ID=bbbb-2222
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
printf '{}\n' > "$T/home/launches/notes.json"
run 4005
if ! kill -0 "$dead" 2>/dev/null; then  # skip if the OS already reused the pid
  [ ! -e "$T/home/launches/$dead.json" ] || fail "dead record not pruned"
fi
[ -e "$T/home/launches/$live.json" ] || fail "live record was pruned"
[ -e "$T/home/launches/notes.json" ] || fail "a non-pid file was pruned"

# An unwritable home never fails the launch.
: > "$T/notadir"
env -i PATH="$PATH" MEGAVIBE_HOME="$T/notadir" bash -c 'set -euo pipefail; source "$1"; record_launch 4006; echo reached' _ "$T/fn.sh" | grep -q reached || fail "record_launch aborted the caller"

echo ok
