#!/bin/bash
# Bash 3.2: real flock, scratch HOME/node, stub helpers; no real sessions or secrets.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/node-lock-test.XXXXXX") || exit 2
PASS=0; FAIL=0; RUN=""; HOLDER=""
cleanup() {
  [ -z "$RUN" ] || { rm -f "$HOME/block" "$HOME/check-block" "$HOME/secret-block" "$HOME/warning-block" "$HOME/git-block"; wait "$RUN" 2>/dev/null; }
  [ -z "$HOLDER" ] || { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }
  for f in "$T"/home-*/children; do
    [ -f "$f" ] || continue
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$f"
  done
  rm -rf "$T"
}
trap cleanup EXIT
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
ready() { local i; for i in {1..100}; do [ -e "$1" ] && return 0; /bin/sleep 0.05; done; return 1; }
B="$T/bin"; mkdir -p "$B"
cat > "$B/spawn" <<'STUB'
#!/bin/bash
# Inspect every inherited descriptor, including bash's possible saved copies.
perl -e '
  my @lock = stat "$ENV{MEGAVIBE_HOME}/node/.lock";
  for (3..63) {
    open(my $f, "<&=", $_) or next; my @s = stat $f;
    if (@s && $s[0] == $lock[0] && $s[1] == $lock[1]) {
      open(my $out, ">>", "$ENV{HOME}/leaked"); print $out "lock descriptor $_\n";
    }
  }
'
[ -f "$HOME/spawn" ] || exit 0
mkdir "$HOME/spawned-$1" 2>/dev/null || exit 0
/bin/sleep 300 </dev/null >/dev/null 2>&1 &
echo "$!" >> "$HOME/children"
STUB
cat > "$B/tmux" <<'STUB'
#!/bin/bash
"$MEGAVIBE_NODE_TEST_BIN/spawn" tmux
[ "${CLI_NO_PA:-}" != 1 ] || [ "$1" != has-session ] || exit 1
case "$1" in
  list-windows) echo fixture ;;
  list-sessions) printf 'main\nmegavibe-personal\n' ;;
esac
STUB
cat > "$B/uname" <<'STUB'
#!/bin/bash
"$MEGAVIBE_NODE_TEST_BIN/spawn" uname
echo Linux
STUB
printf '#!/bin/bash\necho fixture\n' > "$B/scutil"
printf '#!/bin/bash\nexit 1\n' > "$B/megavibe"
printf '#!/bin/bash\necho "$*" >> "$HOME/launchctl.calls"\nexit 113\n' > "$B/launchctl"
chmod +x "$B"/*
export MEGAVIBE_NODE_TEST_BIN="$B" PATH="$B:/usr/bin:/bin:/usr/sbin:/sbin"
fresh() {
  export HOME="$T/home-$1" MEGAVIBE_HOME="$T/home-$1/install" CLAUDE_CONFIG_DIR="$T/home-$1/config"
  N="$MEGAVIBE_HOME/node"
  mkdir -p "$N" "$MEGAVIBE_HOME/scripts" "$HOME/.local/bin" "$CLAUDE_CONFIG_DIR"
  cp "${NODE_UNDER_TEST:-$REPO/template/node/node.sh}" "$N/node.sh"
  : > "$N/node.conf"
  cat > "$MEGAVIBE_HOME/scripts/claude-auth-check.sh" <<'STUB'
#!/bin/bash
echo work >> "$HOME/work"
: > "$HOME/entered"
while [ -e "$HOME/block" ]; do /bin/sleep 0.05; done
exit 0
STUB
  chmod +x "$MEGAVIBE_HOME/scripts/claude-auth-check.sh"
}
node() { /bin/bash "$N/node.sh" </dev/null > "$HOME/stdout" 2> "$HOME/stderr"; RC=$?; }
free_lock() { perl -e 'use Fcntl ":flock"; open(my $f, ">>", $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX|LOCK_NB) ? 0 : 1)' "$N/.lock"; }
contend() {
  local i pid pids="" failed=0
  for i in {1..24}; do
    /bin/bash "$N/node.sh" </dev/null > "$HOME/contend-$i.stdout" 2> "$HOME/contend-$i.stderr" &
    pids="$pids $!"
  done
  for pid in $pids; do wait "$pid" || failed=1; done
  return "$failed"
}

fresh children
touch "$HOME/spawn"
node
check 'first run works and starts two long-lived helper children' '[ "$RC" = 0 ] && [ "$(wc -l < "$HOME/children" | tr -d " ")" = 2 ] && [ -s "$HOME/work" ]'
check 'children remain alive after node exits' '( while read -r pid; do kill -0 "$pid" || exit 1; done < "$HOME/children" )'
check 'neither tmux nor other helpers inherit any copy of the lock fd' '[ ! -e "$HOME/leaked" ]'
check 'lock released while children remain alive' 'free_lock'
node
check 'next run obtains lock and does its work' '[ "$RC" = 0 ] && [ "$(wc -l < "$HOME/work" | tr -d " ")" = 2 ]'

fresh concurrent
touch "$HOME/block"
/bin/bash "$N/node.sh" </dev/null > "$HOME/first.stdout" 2> "$HOME/first.stderr" & RUN=$!
ready "$HOME/entered" || exit 2
check 'live worker keeps parent lock held' '! free_lock'
node
check 'brief concurrent run exits quietly without work or notice' '[ "$RC" = 0 ] && [ "$(wc -l < "$HOME/work" | tr -d " ")" = 1 ] && [ ! -s "$N/node.log" ] && [ ! -e "$N/restart-note.txt" ] && [ ! -s "$HOME/stderr" ]'
kill -TERM "$RUN"; /bin/sleep 0.1
check 'TERM to waiting parent does not release a working run lock' '! free_lock'
rm "$HOME/block"; wait "$RUN"; RUN=""
check 'lock released when actual worker finishes' 'free_lock'

fresh wake-progress
touch "$N/pa.on" "$HOME/secret-block" "$HOME/block"
cat > "$HOME/.local/bin/secret" <<'STUB'
#!/bin/bash
: > "$HOME/secret-entered"
while [ -e "$HOME/secret-block" ]; do /bin/sleep 0.05; done
exit 0
STUB
chmod +x "$HOME/.local/bin/secret"
/bin/bash "$N/node.sh" </dev/null > "$HOME/first.stdout" 2> "$HOME/first.stderr" & RUN=$!
ready "$HOME/secret-entered" || exit 2
# Simulate sleep during sync, then let the worker advance to the auth step.
touch -t 202001010000 "$N/.lock"
rm "$HOME/secret-block"
ready "$HOME/entered" || exit 2
check 'live worker refreshes an old lock when it advances a step' '! free_lock && perl -e '\''exit(time - (stat $ARGV[0])[9] > 10)'\'' "$N/.lock"'
node
check 'contender after worker progress emits no stuck-lock log or notice' '[ "$RC" = 0 ] && [ "$(wc -l < "$HOME/work" | tr -d " ")" = 1 ] && [ ! -s "$N/node.log" ] && [ ! -e "$N/restart-note.txt" ]'
rm "$HOME/block"; wait "$RUN"; RUN=""

fresh stale
# Fixture owns exactly one lock; no process inspection, clock override or real tmux.
perl -e 'use Fcntl ":flock"; open(my $f, ">>", $ARGV[0]) or die $!;
  flock($f, LOCK_EX) or die $!; utime time-1900, time-1900, $f;
  open(my $r, ">", $ARGV[1]) or die $!; close $r; sleep 300;' "$N/.lock" "$HOME/held" & HOLDER=$!
ready "$HOME/held" || exit 2
echo 'retained restart details' > "$N/restart-note.txt"
inode=$(perl -e 'print((stat $ARGV[0])[1])' "$N/.lock")
# 100 peers give a 2900 s bound: 1000 s of slack above the fixture's age.
{ printf 'NODE_PEERS='; for peer in {1..100}; do printf 'p%s ' "$peer"; done; printf '\n'; } > "$N/node.conf"
node
check 'contention bound includes configured peer deadlines' '[ ! -s "$N/node.log" ] && ! grep -q "^Node lock:" "$N/restart-note.txt" && [ ! -e "$HOME/work" ]'
: > "$N/node.conf"
# Repeat the first-notice race, not just updates to an already present notice.
# Check each burst before a later run has a chance to repair duplicate lines.
for round in {1..8}; do
  printf 'retained restart details\nSecret sync succeeded since start: yes\n' > "$N/restart-note.txt"
  contend; RC=$?
  check "contention burst $round retains exactly one notice and all other lines" '[ "$RC" = 0 ] && [ "$(grep -c "^Node lock:" "$N/restart-note.txt")" = 1 ] && grep -qx "retained restart details" "$N/restart-note.txt" && grep -qx "Secret sync succeeded since start: yes" "$N/restart-note.txt"'
done
node; node
check 'old held lock logs once across repeated runs' '[ "$RC" = 0 ] && [ "$(grep -c "long-lived process holds" "$N/node.log")" = 1 ]'
check 'notice names lock, preserves existing restart details, and work stays excluded' 'grep -qF "$N/.lock" "$N/restart-note.txt" && grep -q "long-lived process holds" "$N/restart-note.txt" && grep -qx "retained restart details" "$N/restart-note.txt" && [ ! -e "$HOME/work" ]'
check 'old lock inode is neither renamed nor removed' '[ "$inode" = "$(perl -e '\''print((stat $ARGV[0])[1])'\'' "$N/.lock")" ] && ! free_lock'
out=$(/bin/bash "$REPO/scripts/megavibe-node.sh" status 2>/dev/null)
check 'node status displays retained lock notice' '[[ "$out" == *"Node lock:"*"long-lived process holds"* ]]'
check 'node status queries only the launchctl stub' 'grep -qx "print gui/$(id -u)/com.megavibe.node" "$HOME/launchctl.calls"'
touch -t 202001010000 "$N/.once-node-lock"; node
check 'warning repeats after the hourly interval' '[ "$(grep -c "long-lived process holds" "$N/node.log")" = 2 ] && [ "$(grep -c "^Node lock:" "$N/restart-note.txt")" = 1 ]'
printf 'Node lock: obsolete duplicate\nNode lock: another obsolete duplicate\n' >> "$N/restart-note.txt"
node
check 'notice replaces all old copies even within the hourly log interval' '[ "$(grep -c "^Node lock:" "$N/restart-note.txt")" = 1 ] && ! grep -q "obsolete duplicate" "$N/restart-note.txt" && [ "$(grep -c "long-lived process holds" "$N/node.log")" = 2 ]'
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=""
node
check 'acquisition refreshes age, clears resolved warning and preserves other notice text' '[ -s "$HOME/work" ] && ! grep -q "^Node lock:" "$N/restart-note.txt" && grep -qx "retained restart details" "$N/restart-note.txt" && perl -e '\''exit(time - (stat $ARGV[0])[9] > 10)'\'' "$N/.lock"'

fresh writers
# Pause the actual holder before each writer; contenders still execute the
# complete failed-acquisition path with real flock and an artificially old age.
echo 1 > "$N/last-alive"
touch "$N/pa.on" "$HOME/check-block" "$HOME/secret-block" "$HOME/block"
cat > "$MEGAVIBE_HOME/scripts/megavibe-node.sh" <<'STUB'
#!/bin/bash
: > "$HOME/check-entered"
while [ -e "$HOME/check-block" ]; do /bin/sleep 0.05; done
echo 'retained session check details'
STUB
cat > "$HOME/.local/bin/secret" <<'STUB'
#!/bin/bash
: > "$HOME/secret-entered"
while [ -e "$HOME/secret-block" ]; do /bin/sleep 0.05; done
exit 0
STUB
chmod +x "$HOME/.local/bin/secret"
/bin/bash "$N/node.sh" </dev/null > "$HOME/holder.stdout" 2> "$HOME/holder.stderr" & RUN=$!
ready "$HOME/check-entered" || exit 2
touch -t 202001010000 "$N/.lock"
contend
check 'contenders create one notice while the holder checks restart sessions' '[ "$(grep -c "^Node lock:" "$N/restart-note.txt")" = 1 ]'
rm "$HOME/check-block"
ready "$HOME/secret-entered" || exit 2
check 'restart writer preserves the contender notice alongside new session details' '[ "$(grep -c "^Node lock:" "$N/restart-note.txt")" = 1 ] && grep -qx "retained session check details" "$N/restart-note.txt" && grep -q "^back after " "$N/restart-note.txt"'
# Race secret_note with a fresh burst of contenders, then check both updates.
contend & burst=$!
rm "$HOME/secret-block"
ready "$HOME/entered" || exit 2
wait "$burst"
rm "$HOME/block"
wait "$RUN"; RUN=""
check 'secret writer and contenders preserve each others updates' '[ "$(grep -c "^Node lock:" "$N/restart-note.txt")" = 1 ] && [ "$(grep -c "^Secret sync succeeded since start:" "$N/restart-note.txt")" = 1 ] && grep -qx "Secret sync succeeded since start: yes" "$N/restart-note.txt" && grep -qx "retained session check details" "$N/restart-note.txt"'
check 'atomic note writers leave no temporary files or write errors' '! compgen -G "$N/restart-note.txt.*" >/dev/null && [ ! -s "$HOME/holder.stderr" ] && ! cat "$HOME"/contend-*.stderr | grep -q .'
node
check 'next acquisition clears the notice while retaining session and secret details' '! grep -q "^Node lock:" "$N/restart-note.txt" && grep -qx "retained session check details" "$N/restart-note.txt" && grep -qx "Secret sync succeeded since start: yes" "$N/restart-note.txt"'

fresh delayed
perl -e 'use Fcntl ":flock"; open(my $f, ">>", $ARGV[0]) or die $!;
  flock($f, LOCK_EX) or die $!; utime time-1900, time-1900, $f;
  open(my $r, ">", $ARGV[1]) or die $!; close $r; sleep 300;' "$N/.lock" "$HOME/held" & HOLDER=$!
ready "$HOME/held" || exit 2
printf 'retained restart details\nNode lock: old warning\n' > "$N/restart-note.txt"
# Delay a contender after it observes the old age, before it writes the notice.
cat > "$B/date" <<'STUB'
#!/bin/bash
if [ "${DELAY_LOCK_WARNING:-}" = 1 ] && [ "$1" = '+%F %T' ]; then
  : > "$HOME/warning-entered"
  while [ -e "$HOME/warning-block" ]; do /bin/sleep 0.05; done
fi
exec /bin/date "$@"
STUB
chmod +x "$B/date"
touch "$HOME/warning-block"
DELAY_LOCK_WARNING=1 /bin/bash "$N/node.sh" </dev/null > "$HOME/delayed.stdout" 2> "$HOME/delayed.stderr" & RUN=$!
ready "$HOME/warning-entered" || exit 2
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=""
node
check 'successful acquisition clears the notice before a delayed contender resumes' '! grep -q "^Node lock:" "$N/restart-note.txt" && grep -qx "retained restart details" "$N/restart-note.txt"'
rm "$HOME/warning-block"
wait "$RUN"; RUN=""
check 'delayed contender cannot restore a resolved lock notice' '! grep -q "^Node lock:" "$N/restart-note.txt" && grep -qx "retained restart details" "$N/restart-note.txt" && [ ! -s "$HOME/delayed.stderr" ]'
rm "$B/date"

fresh secret
touch "$N/pa.on"
# Outside the startup retry window, so every run makes exactly one attempt.
echo 1 > "$N/.started-at"
cat > "$HOME/.local/bin/secret" <<'STUB'
#!/bin/bash
[ "$*" = sync ] || exit 99
echo 'EXAMPLE_VALUE_STDOUT'
[ ! -e "$HOME/succeed" ] || exit 0
echo 'EXAMPLE_VALUE_STDERR' >&2
if [ -e "$HOME/short" ]; then
  echo 'secret: age is not installed (brew install age)' >&2
  exit 23
fi
perl -e 'print STDERR "x" x 20000, "\n"; for (1..80) { print STDERR "secret: Keychain write for EXAMPLE_$_ did not verify\n" }'
exit 17
STUB
chmod +x "$HOME/.local/bin/secret"
node
F="$N/secret-sync-failed.txt"
check 'failure retains actual exit status and last stderr lines' 'grep -qx "exit status: 17" "$F" && grep -q "EXAMPLE_80 did not verify" "$F" && ! grep -q "EXAMPLE_1 did not verify" "$F"'
check 'failure file bounded to status plus 20 lines and 4 KiB stderr' '[ "$(wc -l < "$F")" -le 21 ] && [ "$(wc -c < "$F")" -le 4128 ]'
check 'failure file permissions are owner-only' 'perl -e '\''exit(((stat $ARGV[0])[2] & 0777) != 0600)'\'' "$F"'
touch "$HOME/short"; node
check 'next failure replaces previous report and suppresses arbitrary values before writing' 'grep -qx "exit status: 23" "$F" && grep -q "age is not installed" "$F" && grep -q "unrecognized diagnostic" "$F" && ! grep -q EXAMPLE_80 "$F" && ! grep -R -q EXAMPLE_VALUE "$N"'
touch "$HOME/succeed"; node
check 'success removes failure report and scratch stderr files' '[ ! -e "$F" ] && ! compgen -G "$N/.secret-stderr.*" >/dev/null'
rm "$HOME/succeed"; node
rm "$N/pa.on"; node
check 'removing pa.on after a failed sync removes the stale failure report' '[ "$RC" = 0 ] && [ ! -e "$F" ]'
touch "$N/pa.on"; node
rm "$HOME/.local/bin/secret"; node
check 'removing the secrets tool after a failed sync removes the stale failure report' '[ "$RC" = 0 ] && [ ! -e "$F" ]'


# An old unlocked inode after sleep is not evidence of contention.
fresh wake
touch -t 202001010000 "$N/.lock"
node
check 'wake after hours without a run refreshes a free lock without a lock notice' '[ "$RC" = 0 ] && [ -s "$HOME/work" ] && ! grep -q "Node lock:" "$N/node.log" "$N/restart-note.txt" 2>/dev/null && perl -e '\''exit(time - (stat $ARGV[0])[9] > 10)'\'' "$N/.lock"'

# Shorten only the scratch copy's helper alarm; production deadlines stay intact.
short_bound() {
  sed 's/alarm shift;/alarm 1; shift;/' "$N/node.sh" > "$N/node.short"
  mv "$N/node.short" "$N/node.sh"
}
seconds() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
within_bound() { perl -e 'exit($ARGV[1] - $ARGV[0] > 4)' "$1" "$2"; }
fresh secret-descendant
short_bound
touch "$N/pa.on"
echo 1 > "$N/.started-at"
cat > "$HOME/.local/bin/secret" <<'STUB'
#!/bin/bash
# The child keeps stderr open well beyond the helper's one-second test alarm.
/bin/sleep 8 >/dev/null &
echo "$!" >> "$HOME/children"
echo 'secret: age is not installed (brew install age)' >&2
exec /bin/sleep 8
STUB
chmod +x "$HOME/.local/bin/secret"
start=$(seconds); node; end=$(seconds)
check 'secret capture returns at the helper deadline despite a child holding stderr' 'within_bound "$start" "$end" && [ "$RC" = 0 ] && kill -0 "$(head -1 "$HOME/children")"'
check 'timed-out sync writes filtered partial diagnostics and alarm exit status' 'grep -qx "exit status: 142" "$N/secret-sync-failed.txt" && grep -q "age is not installed" "$N/secret-sync-failed.txt" && ! compgen -G "$N/.secret-stderr.*" >/dev/null'
check 'secret descendant cannot retain lock after timed-out capture' 'free_lock'
rm "$N/pa.on"
start=$(seconds); node; end=$(seconds)
check 'next run works while the secret descendant is alive' 'within_bound "$start" "$end" && [ "$(wc -l < "$HOME/work" | tr -d " ")" = 2 ] && kill -0 "$(head -1 "$HOME/children")"'

# Exercise the actual capture primitive with both helper success and timeout.
# The child holds stdout even after the helper exits; it must never own the
# substitution pipe. On old code bounded_output is absent: bounded reproduces it.
fresh stdout-descendant
short_bound
sed -n '/^bounded()/,/^restart_note()/p' "$N/node.sh" | sed '$d' > "$HOME/bounds.sh"
cat > "$HOME/output-helper" <<'STUB'
#!/bin/bash
: > "$HOME/helper-created"
/bin/sleep 8 >&1 2>/dev/null &
echo "$!" >> "$HOME/children"
echo partial-output
[ "$1" != timeout ] || exec /bin/sleep 8
exit 23
STUB
chmod +x "$HOME/output-helper"
for mode in exit timeout; do
  start=$(seconds)
  value=$(/bin/bash -c 'umask 022; N="$MEGAVIBE_HOME/node"; source "$HOME/bounds.sh"; declare -F bounded_output >/dev/null || bounded_output() { bounded "$@"; }; bounded_output 60 "$HOME/output-helper" "$1"' test "$mode" 2>/dev/null)
  rc=$?; end=$(seconds)
  expected=23; [ "$mode" != timeout ] || expected=142
  check "stdout capture: $mode preserves output/status without waiting for descendants" 'within_bound "$start" "$end" && [ "$rc" = "$expected" ] && [ "$value" = partial-output ]'
done
check 'stdout capture removes temporary files' '! compgen -G "$N/.bounded-output.*" >/dev/null'
check 'stdout capture preserves the helper umask (including for new tmux sessions)' 'perl -e '\''exit(((stat $ARGV[0])[2] & 0777) != 0644)'\'' "$HOME/helper-created"'

# CLI paths: real scratch repositories, with a wrapper that checks *every* fd
# and starts children that would retain the flock on the unchanged CLI.
REAL_GIT=$(command -v git); export REAL_GIT CLI_NO_PA=1
cat > "$B/git" <<'STUB'
#!/bin/bash
args=("$@"); [ "${1:-}" != -C ] || shift 2
while [ "${1:-}" = -c ]; do shift 2; done
"$MEGAVIBE_NODE_TEST_BIN/spawn" "git-$1"
if [ "$1" = check-ignore ]; then
  : > "$HOME/git-entered"
  while [ -e "$HOME/git-block" ]; do /bin/sleep 0.05; done
fi
[ "${GIT_FAIL_VERB:-}" != "$1" ] || exit 37
exec "$REAL_GIT" "${args[@]}"
STUB
chmod +x "$B/git"
ctl() { /bin/bash "${CLI_UNDER_TEST:-$REPO/scripts/megavibe-node.sh}" "$@" > "$HOME/cli.stdout" 2> "$HOME/cli.stderr"; RC=$?; }
fresh cli-init
mkdir -p "$MEGAVIBE_HOME/personal"
echo notes > "$MEGAVIBE_HOME/personal/CLAUDE.md"
touch "$HOME/spawn"
origin="$MEGAVIBE_HOME/personal-memory.git"
ctl memory init
check 'CLI memory init succeeds with background git children and no inherited lock copies' '[ "$RC" = 0 ] && [ -s "$HOME/children" ] && [ ! -e "$HOME/leaked" ] && free_lock'
ctl memory init
check 'CLI already initialized path, including check-ignore, releases lock with live children' '[ "$RC" = 0 ] && [ -e "$HOME/spawned-git-check-ignore" ] && [ ! -e "$HOME/leaked" ] && free_lock && ( while read -r pid; do kill -0 "$pid" || exit 1; done < "$HOME/children" )'
# Verify the waiting parent keeps ownership until the worker and cleanup finish.
touch "$HOME/git-block"; rm "$HOME/git-entered"
/bin/bash "${CLI_UNDER_TEST:-$REPO/scripts/megavibe-node.sh}" memory init > "$HOME/cli.stdout" 2> "$HOME/cli.stderr" & RUN=$!
ready "$HOME/git-entered" || exit 2
check 'CLI worker keeps parent lock held while git works' '! free_lock'
kill -TERM "$RUN"; /bin/sleep 0.1
check 'CLI waiting parent defers TERM while the worker owns the operation' '! free_lock'
rm "$HOME/git-block"; wait "$RUN"; rc=$?; RUN=""
check 'CLI worker completion preserves success and releases lock' '[ "$rc" = 0 ] && free_lock'
ctl takeover
check 'CLI takeover helpers and started sessions cannot inherit lock' '[ "$RC" = 0 ] && [ ! -e "$HOME/leaked" ] && free_lock'
ctl handback
check 'CLI handback helpers cannot inherit lock' '[ "$RC" = 0 ] && [ ! -e "$HOME/leaked" ] && free_lock'

fresh cli-clone
mkdir -p "$MEGAVIBE_HOME/personal"
touch "$HOME/spawn"
ctl memory clone "$origin"
check 'CLI clone closes lock for direct git init and all clone helpers' '[ "$RC" = 0 ] && [ -f "$MEGAVIBE_HOME/personal/CLAUDE.md" ] && [ ! -e "$HOME/leaked" ] && free_lock'
ctl memory clone "$origin"
check 'CLI already cloned path also releases lock' '[ "$RC" = 0 ] && [ ! -e "$HOME/leaked" ] && free_lock'

fresh cli-init-failure
mkdir -p "$MEGAVIBE_HOME/personal"
echo notes > "$MEGAVIBE_HOME/personal/CLAUDE.md"
touch "$HOME/spawn"
GIT_FAIL_VERB=commit ctl memory init
check 'CLI init preserves failing helper status and runs EXIT cleanup before releasing lock' '[ "$RC" = 37 ] && [ ! -e "$MEGAVIBE_HOME/personal/.git" ] && grep -q "half-made repo" "$HOME/cli.stderr" && [ ! -e "$HOME/leaked" ] && free_lock'
fresh cli-clone-failure
mkdir -p "$MEGAVIBE_HOME/personal"
touch "$HOME/spawn"
GIT_FAIL_VERB=fetch ctl memory clone "$origin"
check 'CLI clone preserves failure and removes half-made repo in worker EXIT cleanup' '[ "$RC" = 1 ] && [ ! -e "$MEGAVIBE_HOME/personal/.git" ] && grep -q "half-made repo" "$HOME/cli.stderr" && [ ! -e "$HOME/leaked" ] && free_lock'
rm "$B/git"
unset CLI_NO_PA

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
