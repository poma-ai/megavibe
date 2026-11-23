#!/bin/bash
# record_launch writes ~/.megavibe/launches/<pid>.json when the wrapper starts claude.
# The function is extracted from the wrapper so the test runs the shipped code.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-launch-record.XXXXXX")
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

sed -n '/^record_launch() {/,/^}/p' "$REPO/megavibe" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || fail "record_launch not found in megavibe"
# Both claude launch sites must record, or sessions started on that path are unmarked.
[ "$(grep -c '^  record_launch "\$CLAUDE_PID"$' "$REPO/megavibe")" = 2 ] || fail "expected record_launch after both claude launches"

run() { # run <pid> [env assignments...]: source the function in a clean shell
  local pid="$1"; shift
  env -i PATH="$PATH" MEGAVIBE_HOME="$T/home" "$@" bash -c 'set -euo pipefail; source "$1"; record_launch "$2"' _ "$T/fn.sh" "$pid"
}
field() { jq -r "$1" "$T/home/launches/$2.json"; }

# Explicit parent wins over the inherited session id.
run 4001 MEGAVIBE_PARENT_SESSION=aaaa-1111 CLAUDE_CODE_SESSION_ID=bbbb-2222
[ "$(field .parentSessionId 4001)" = "aaaa-1111" ] || fail "explicit parent"
[ "$(field .launcher 4001)" = "megavibe" ] || fail "launcher field"
[ "$(field '.startedAt|type' 4001)" = "number" ] || fail "startedAt type"
# Owner-only permissions (checked now: later runs prune these fake, dead pids).
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
[ "$(mode "$T/home/launches")" = 700 ] || fail "launches dir mode"
[ "$(mode "$T/home/launches/4001.json")" = 600 ] || fail "record mode"

# Inherited session id is used when no explicit parent is set.
run 4002 CLAUDE_CODE_SESSION_ID=bbbb-2222
[ "$(field .parentSessionId 4002)" = "bbbb-2222" ] || fail "inherited parent"

# No parent: still recorded, parent null (tells "started by megavibe" from a bare claude).
run 4003
[ "$(field .parentSessionId 4003)" = "null" ] || fail "no parent"

# A parent that is not a session id is dropped, never written.
run 4004 'MEGAVIBE_PARENT_SESSION=x"; touch pwned #'
[ "$(field .parentSessionId 4004)" = "null" ] || fail "invalid parent must be dropped"

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
