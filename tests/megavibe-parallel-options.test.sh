#!/bin/bash
set -Eeuo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-parallel-options.XXXXXX")
LOCK_PID=
cleanup() {
  if [ -n "$LOCK_PID" ]; then
    kill "$LOCK_PID" 2>/dev/null || true
    wait "$LOCK_PID" 2>/dev/null || true
  fi
  /bin/rm -rf "$T"
}
trap cleanup EXIT
T=$(cd "$T" && pwd -P)
export HOME="$T/home" MEGAVIBE_HOME="$T/install" PATH="$T/bin:$PATH"
export MEGAVIBE_ROUTER=0 MEGAVIBE_STYLE=0 GIT_CONFIG_NOSYSTEM=1
unset MEGAVIBE_PARALLEL_BRANCH MEGAVIBE_PARALLEL_STASH BASH_ENV
mkdir -p "$HOME/.claude" "$MEGAVIBE_HOME" "$T/bin"
printf 'megavibe-v3\n' > "$HOME/.claude/CLAUDE.md"
# Use a deployed copy with a stub init and a fresh stamp to skip sync and updates.
cp "$REPO/megavibe" "$MEGAVIBE_HOME/megavibe"
: > "$MEGAVIBE_HOME/init.sh"
date +%s > "$MEGAVIBE_HOME/.last-update-check"
cat > "$T/bin/claude" <<'STUB'
#!/bin/bash
if [ "$*" = "auth status" ]; then
  echo '{"loggedIn":true}'
else
  printf '%s\n' "$@" > "$CLAUDE_ARGS"
fi
STUB
chmod +x "$T/bin/claude"
sleep 120 &
LOCK_PID=$!
export LOCK_PID
cat > "$T/bin/ps" <<'STUB'
#!/bin/bash
# Report the expected process name only for the test's real, live lock PID.
if [ "$*" = "-p $LOCK_PID -o comm=" ]; then
  echo claude
else
  exec /bin/ps "$@"
fi
STUB
chmod +x "$T/bin/ps"

trap 'printf "FAIL %s\n" "${CASE:-setup}" >&2; cat "$T/out" "$T/err" >&2' ERR
setup_case() {
  CASE="$1"
  export CLAUDE_ARGS="$T/$CASE.args"
  cd "$T"
  git init -q "$CASE"
  cd "$CASE"
  echo original > tracked
  git add tracked
  git -c user.name=Test -c user.email=test@example.invalid commit -qm Initial
  git config user.name Test
  git config user.email test@example.invalid
  echo changed > tracked
  if [ "${2:-live}" = live ]; then
    mkdir -p .agent/.session-lock.d
    printf '{"pid":%s}\n' "$LOCK_PID" > .agent/.session-lock.d/metadata.json
  fi
}
launch() {
  bash "$MEGAVIBE_HOME/megavibe" "$@" </dev/null >"$T/out" 2>"$T/err"
}
launch_interactive() {
  # Bash prints read -p prompts only when stdin is a terminal.
  python3 - "$MEGAVIBE_HOME/megavibe" "$@" >"$T/out" 2>"$T/err" <<'PY'
import os
import pty
import subprocess
import sys

master, slave = pty.openpty()
try:
    os.write(master, sys.argv[2].encode())
    sys.exit(subprocess.call(["bash", sys.argv[1], *sys.argv[3:]], stdin=slave))
finally:
    os.close(slave)
    os.close(master)
PY
}
branch_created() {
  git show-ref --verify --quiet "refs/heads/$1"
  [ "$(git -C "$MEGAVIBE_HOME/worktrees/$CASE-$1" branch --show-current)" = "$1" ]
}
no_parallel() {
  [ "$(git worktree list --porcelain | grep -c '^worktree ')" = 1 ]
  [ "$(git for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d ' ')" = 1 ]
}
no_prompt() {
  if grep -F -e 'Stash them first?' -e 'Branch name (or Ctrl+C to cancel):' "$T/out" "$T/err"; then
    return 1
  fi
}
unchanged() {
  [ -z "$(git stash list)" ]
  grep -Fxq changed tracked
}
pass() {
  printf 'PASS %s\n' "$CASE"
}

setup_case options
MEGAVIBE_PARALLEL_BRANCH=ignored MEGAVIBE_PARALLEL_STASH=invalid \
  launch --model sonnet --stash --parallel-branch 'review work!' --no-stash 'initial prompt'
no_prompt
branch_created review-work
unchanged
printf '%s\n' --dangerously-skip-permissions --remote-control --model sonnet 'initial prompt' > "$T/expected"
diff -u "$T/expected" "$CLAUDE_ARGS"
pass

setup_case stash
launch --parallel-branch=review --no-stash --stash
no_prompt
branch_created review
[ -n "$(git stash list)" ]
grep -Fxq original tracked
pass

setup_case default
launch --parallel-branch=review
no_prompt
branch_created review
unchanged
pass

setup_case invalid
for name in '!!!' '' '../invalid'; do
  if launch --parallel-branch "$name" --stash; then exit 1; fi
  grep -Fq 'invalid parallel branch name' "$T/err"
  no_prompt
  no_parallel
  unchanged
  [ ! -e "$CLAUDE_ARGS" ]
done
pass

setup_case empty-env
if MEGAVIBE_PARALLEL_BRANCH='' launch --stash; then exit 1; fi
grep -Fq 'invalid parallel branch name' "$T/err"
no_prompt
no_parallel
unchanged
pass

setup_case interactive
launch_interactive $'n\nreview\n'
grep -Fq 'Stash them first? [Y/n]' "$T/err"
grep -Fq 'Branch name (or Ctrl+C to cancel):' "$T/err"
branch_created review
unchanged
pass

setup_case stash-choice-only
launch_interactive $'review\n' --no-stash
if grep -Fq 'Stash them first?' "$T/err"; then exit 1; fi
grep -Fq 'Branch name (or Ctrl+C to cancel):' "$T/err"
branch_created review
unchanged
pass

setup_case unlocked none
launch --parallel-branch=review --stash
launch --no-stash
no_prompt
no_parallel
unchanged
printf '%s\n' --dangerously-skip-permissions --remote-control > "$T/expected"
diff -u "$T/expected" "$CLAUDE_ARGS"
if launch --parallel-branch; then exit 1; fi
grep -Fq -- '--parallel-branch requires a name' "$T/err"
pass

setup_case environment
if MEGAVIBE_PARALLEL_BRANCH=review MEGAVIBE_PARALLEL_STASH=invalid launch; then exit 1; fi
grep -Fq 'MEGAVIBE_PARALLEL_STASH must be' "$T/err"
no_parallel
unchanged
MEGAVIBE_PARALLEL_BRANCH='env review' MEGAVIBE_PARALLEL_STASH=yes launch
no_prompt
branch_created env-review
[ -n "$(git stash list)" ]
grep -Fxq original tracked
pass
