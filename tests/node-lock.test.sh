#!/bin/bash
# Bash 3.2: real flock, scratch HOME/node, stub helpers; no real sessions or secrets.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/node-lock-test.XXXXXX") || exit 2
PASS=0; FAIL=0; RUN=""; HOLDER=""
cleanup() {
  [ -z "$RUN" ] || { rm -f "$HOME/block" "$HOME/check-block" "$HOME/secret-block" "$HOME/warning-block"; wait "$RUN" 2>/dev/null; }
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

fresh stale
# Fixture owns exactly one lock; no process inspection, clock override or real tmux.
perl -e 'use Fcntl ":flock"; open(my $f, ">>", $ARGV[0]) or die $!;
  flock($f, LOCK_EX) or die $!; utime time-1900, time-1900, $f;
  open(my $r, ">", $ARGV[1]) or die $!; close $r; sleep 300;' "$N/.lock" "$HOME/held" & HOLDER=$!
ready "$HOME/held" || exit 2
echo 'retained restart details' > "$N/restart-note.txt"
inode=$(perl -e 'print((stat $ARGV[0])[1])' "$N/.lock")
echo 'NODE_PEERS=a b c d e f g h i j' > "$N/node.conf"
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

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
