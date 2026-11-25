#!/bin/bash
# record_launch writes ~/.megavibe/launches/<pid>.json when the wrapper starts claude.
# The function is extracted from the wrapper so the test runs the shipped code.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-launch-record.XXXXXX")
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

for fn in capture_launch_parent restore_launch_parent is_session_ancestor session_pid record_launch; do
  sed -n "/^$fn() {/,/^}/p" "$REPO/megavibe" >> "$T/fn.sh"
  grep -q "^$fn() {" "$T/fn.sh" || fail "$fn not found in megavibe"
done
# The early re-exec runs before session_pid exists: its functions without that one.
for fn in capture_launch_parent restore_launch_parent; do sed -n "/^$fn() {/,/^}/p" "$REPO/megavibe" >> "$T/early.sh"; done
# The wrapper must capture the variable once at the top, and put it back before each of its own re-execs.
[ "$(grep -c '^capture_launch_parent$' "$REPO/megavibe")" = 1 ] || fail "capture_launch_parent must be called once, at the top"
[ "$(grep -c '^ *restore_launch_parent$' "$REPO/megavibe")" = 2 ] || fail "restore_launch_parent must precede both self re-execs"

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
[ "$(grep -c '^ *record_launch "\$CLAUDE_PID"$' "$REPO/megavibe")" = 2 ] || fail "expected record_launch after both claude launches"

run() { # run <pid> [env assignments...]: source the function in a clean shell
  local pid="$1"; shift
  (cd "$T" && env -i PATH="$T/bin:$PATH" MEGAVIBE_HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" "$@" bash -c 'set -euo pipefail; source "$1"; capture_launch_parent; record_launch "$2"' _ "$T/fn.sh" "$pid")
}
probe() { # probe <snippet> [env assignments...]: run a snippet after capture_launch_parent, print what it prints
  local snippet="$1"; shift
  (cd "$T" && env -i PATH="$T/bin:$PATH" "$@" bash -c 'set -eu; source "$1"; capture_launch_parent; eval "$2"' _ "$T/fn.sh" "$snippet")
}
field() { jq -r "$1" "$T/home/launches/$2.json"; }

# Scoped restart metadata is retained for exact pane matching; no terminal
# mutation is performed while recording a launch.
run 4099 TMUX=/example/test.sock,123,0 TMUX_PANE=%7
[ "$(field .pane 4099)" = %7 ] || fail "restart pane"
[ "$(field .socket 4099)" = /example/test.sock ] || fail "restart socket"
[ "$(field .restartProtocol 4099)" = 1 ] || fail "restart protocol"
[[ "$(field .wrapperPid 4099)" =~ ^[0-9]+$ ]] || fail "restart wrapper pid"

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

# The variable must not reach claude or its tools, or a grandchild gets linked to its grandparent (found in review).
[ -z "$(probe 'bash -c "printf %s \"\${MEGAVIBE_PARENT_SESSION+leaked}\""' MEGAVIBE_PARENT_SESSION=grandparent-A)" ] || fail "MEGAVIBE_PARENT_SESSION leaked into the launched environment"
registry child-C
run 4020 MEGAVIBE_PARENT_SESSION=grandparent-A CLAUDE_CODE_SESSION_ID=child-C
[ "$(field .parentSessionId 4020)" = "grandparent-A" ] || fail "C's own launch keeps the explicit parent"
# ... so a launch G from C's tool (inherited env now has no MEGAVIBE_PARENT_SESSION) links to C.
run 4021 CLAUDE_CODE_SESSION_ID=child-C
[ "$(field .parentSessionId 4021)" = "child-C" ] || fail "grandchild must link to its parent"
# The parent's pid is recorded while a live session is registered under that id: /clear changes the id, not the pid.
printf '{"pid":%s,"sessionId":"dddd-4444","cwd":"/some/parent/dir"}\n' "$$" > "$T/cfg/sessions/$$.json"
run 4030 MEGAVIBE_PARENT_SESSION=dddd-4444
[ "$(field .parentPid 4030)" = "$$" ] || fail "parentPid of a live registered parent"
[ "$(field .parentCwd 4030)" = "/some/parent/dir" ] || fail "parentCwd of a live registered parent"
run 4031 MEGAVIBE_PARENT_SESSION=unknown-5555
[ "$(field .parentPid 4031)" = "null" ] || fail "parentPid of an unregistered parent"
[ "$(field .parentCwd 4031)" = "null" ] || fail "parentCwd of an unregistered parent"
sleep 0 & gone=$!; wait "$gone" || true
if ! kill -0 "$gone" 2>/dev/null; then  # skip if the OS already reused the pid
  printf '{"pid":%s,"sessionId":"eeee-5555"}\n' "$gone" > "$T/cfg/sessions/$gone.json"
  run 4032 MEGAVIBE_PARENT_SESSION=eeee-5555
  [ "$(field .parentPid 4032)" = "null" ] || fail "parentPid of a dead parent"
fi
run 4033
[ "$(field .parentPid 4033)" = "null" ] || fail "no parent, no parentPid"
[ "$(field .parentCwd 4033)" = "null" ] || fail "no parent, no parentCwd"
rm -f "$T/cfg/sessions/$$.json"

# The wrapper's own re-exec gets the value back, set-but-empty included, and nothing when it was never set.
[ "$(probe 'restore_launch_parent; printf %s "${MEGAVIBE_PARENT_SESSION-}"' MEGAVIBE_PARENT_SESSION=grandparent-A)" = "grandparent-A" ] || fail "restore"
[ "$(probe 'restore_launch_parent; printf %s "${MEGAVIBE_PARENT_SESSION+set}"' MEGAVIBE_PARENT_SESSION=)" = "set" ] || fail "restore of an empty value"
[ -z "$(probe 'restore_launch_parent; printf %s "${MEGAVIBE_PARENT_SESSION+set}"')" ] || fail "restore invented a value"

# F2: the re-exec carries the parent's pid and cwd resolved BEFORE the parent's /clear, so the restarted child
# still links to its live parent although the id it was launched with no longer resolves.
printf '{"pid":%s,"sessionId":"carry-A","cwd":"/carry/dir"}\n' "$$" > "$T/cfg/sessions/$$.json"
carried=$(probe 'restore_launch_parent; printf "%s\n" "MEGAVIBE_LAUNCH_PPID=$MEGAVIBE_LAUNCH_PPID" "MEGAVIBE_LAUNCH_PCWD=$MEGAVIBE_LAUNCH_PCWD"' MEGAVIBE_PARENT_SESSION=carry-A CLAUDE_CONFIG_DIR="$T/cfg")
printf '{"pid":%s,"sessionId":"carry-B","cwd":"/carry/dir"}\n' "$$" > "$T/cfg/sessions/$$.json"
run 4040 MEGAVIBE_PARENT_SESSION=carry-A $(printf '%s' "$carried" | tr '\n' ' ')
[ "$(field .parentPid 4040)" = "$$" ] || fail "a re-exec must carry the parent pid across the parent's /clear"
[ "$(field .parentCwd 4040)" = "/carry/dir" ] || fail "a re-exec must carry the parent cwd across the parent's /clear"
run 4041 MEGAVIBE_PARENT_SESSION=carry-A
[ "$(field .parentPid 4041)" = "null" ] || fail "without the carried values the old id no longer resolves"

# R1: the first launch records its parent; the parent then runs /clear (same pid, new id); the update-restart
# re-exec (restore_launch_parent) must still carry the parent, explicit or inferred from the ancestry.
# The test shell ($$) plays the live parent: only its registry file changes id.
reexec() { # reexec <first pid> <second pid> [env assignments...]: first launch, parent /clear, re-exec, second launch
  local out
  out=$(cd "$T" && env -i PATH="$T/bin:$PATH" MEGAVIBE_HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" "${@:3}" bash -c 'set -eu; source "$1"; capture_launch_parent; record_launch "$2"; printf "{\"pid\":%s,\"sessionId\":\"cleared-B\",\"cwd\":\"/r1\"}\n" "$3" > "$CLAUDE_CONFIG_DIR/sessions/$3.json"; restore_launch_parent; env | grep "^MEGAVIBE_[A-Z_]*=" | grep -v "^MEGAVIBE_HOME="' _ "$T/fn.sh" "$1" "$PARENT")
  (cd "$T" && env -i PATH="$T/bin:$PATH" MEGAVIBE_HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" $(printf '%s' "$out" | tr '\n' ' ') bash -c 'set -eu; source "$1"; capture_launch_parent; record_launch "$2"' _ "$T/fn.sh" "$2")
}
PARENT=$$
printf '{"pid":%s,"sessionId":"orig-A","cwd":"/r1"}\n' "$PARENT" > "$T/cfg/sessions/$PARENT.json"
reexec 4050 4051 MEGAVIBE_PARENT_SESSION=orig-A
[ "$(field .parentPid 4051)" = "$PARENT" ] || fail "R1 explicit: a parent that ran /clear before the re-exec must stay linked (got $(field .parentPid 4051))"
[ "$(field .parentSessionId 4051)" = "orig-A" ] || fail "R1 explicit: parentSessionId kept"
[ "$(field .parentCwd 4051)" = "/r1" ] || fail "R1 explicit: parentCwd kept"
rm -f "$T/cfg/sessions/$PARENT.json"

# R1, inferred parent: no MEGAVIBE_PARENT_SESSION, the id comes from CLAUDE_CODE_SESSION_ID while the nearest
# registered ancestor (a live sleep, via a stub ps) is that session; after its /clear the re-exec must still link to it.
sleep 30 & SL=$!
mkdir -p "$T/bin2"
printf '#!/bin/bash\n[ "$4" = %s ] && echo 1 || echo %s\n' "$SL" "$SL" > "$T/bin2/ps"; chmod +x "$T/bin2/ps"
printf '{"pid":%s,"sessionId":"orig-A","cwd":"/r1"}\n' "$SL" > "$T/cfg/sessions/$SL.json"
inf=$(cd "$T" && env -i PATH="$T/bin2:$PATH" MEGAVIBE_HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" CLAUDE_CODE_SESSION_ID=orig-A bash -c 'set -eu; source "$1"; capture_launch_parent; record_launch "$2"; printf "{\"pid\":%s,\"sessionId\":\"cleared-B\",\"cwd\":\"/r1\"}\n" "$3" > "$CLAUDE_CONFIG_DIR/sessions/$3.json"; restore_launch_parent; env | grep "^MEGAVIBE_[A-Z_]*=" | grep -v "^MEGAVIBE_HOME="' _ "$T/fn.sh" 4060 "$SL")
kill "$SL" 2>/dev/null || true; wait "$SL" 2>/dev/null || true
[ "$(field .parentSessionId 4060)" = "orig-A" ] || fail "R1 inferred: first launch must infer the parent (got $(field .parentSessionId 4060))"
case "$inf" in *MEGAVIBE_PARENT_SESSION=orig-A*MEGAVIBE_LAUNCH_PPID=$SL*|*MEGAVIBE_LAUNCH_PPID=$SL*MEGAVIBE_PARENT_SESSION=orig-A*) : ;; *) fail "R1 inferred: re-exec must carry the inferred parent and its pid (got: $inf)" ;; esac

# M1: an early re-exec (the self-update sync) runs before session_pid is defined in the file; it must still
# forward the pid and cwd resolved at first launch.
early=$(cd "$T" && env -i PATH="$T/bin:$PATH" MEGAVIBE_PARENT_SESSION=orig-A MEGAVIBE_LAUNCH_PPID=4242 MEGAVIBE_LAUNCH_PCWD=/r1 bash -c 'set -eu; source "$1"; capture_launch_parent; restore_launch_parent; env | grep "^MEGAVIBE_[A-Z_]*="' _ "$T/early.sh")
case "$early" in *MEGAVIBE_LAUNCH_PPID=4242*MEGAVIBE_LAUNCH_PCWD=/r1*|*MEGAVIBE_LAUNCH_PCWD=/r1*MEGAVIBE_LAUNCH_PPID=4242*) : ;; *) fail "M1: restore_launch_parent without session_pid must forward the carried pid and cwd (got: $early)" ;; esac

# R2: the wrapper removes an explicit parent from the environment but hands it (set, even empty) to the node
# script, which reads it once; unset stays unset. Real wrapper, stub node script.
mkdir -p "$T/nh/scripts"
printf '#!/bin/bash\nprintf "node:%%s\\n" "${MEGAVIBE_PARENT_SESSION-unset}"\n' > "$T/nh/scripts/megavibe-node.sh"
nodeenv() { (cd "$T" && env -i PATH="$PATH" HOME="$T" MEGAVIBE_HOME="$T/nh" "$@" bash "$REPO/megavibe" node status 2>&1 | tail -1); }
[ "$(nodeenv MEGAVIBE_PARENT_SESSION=abc-1)" = "node:abc-1" ] || fail "R2: node dispatch must carry an explicit parent"
[ "$(nodeenv MEGAVIBE_PARENT_SESSION=)" = "node:" ] || fail "R2: node dispatch must carry an explicit empty parent"
[ "$(nodeenv X=1)" = "node:unset" ] || fail "R2: node dispatch must not invent a parent"

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
