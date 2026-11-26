#!/bin/bash
# /bin/bash tests/worktree-lock.test.sh
# The launcher's session lock is per working tree. A linked worktree links .agent/ back to the main checkout
# (`megavibe worktree`, `megavibe dispatch`); a lock kept in the shared .agent/ made every worktree session stop at the
# "Another megavibe session is active here" branch-name prompt, which a detached tmux window cannot answer.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/worktree-lock.XXXXXX") || exit 2
LOCK_PID=
cleanup() { [ -z "$LOCK_PID" ] || { kill "$LOCK_PID" 2>/dev/null; wait "$LOCK_PID" 2>/dev/null; }; /bin/rm -rf "$T"; }
trap cleanup EXIT
T=$(cd "$T" && pwd -P)
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
export HOME="$T/home" MEGAVIBE_HOME="$T/install" PATH="$T/bin:$PATH"
export MEGAVIBE_ROUTER=0 MEGAVIBE_STYLE=0 GIT_CONFIG_NOSYSTEM=1
unset MEGAVIBE_PARALLEL_BRANCH MEGAVIBE_PARALLEL_STASH BASH_ENV MEGAVIBE_PARENT_SESSION
mkdir -p "$HOME/.claude" "$MEGAVIBE_HOME" "$T/bin"
printf 'megavibe-v3\n' > "$HOME/.claude/CLAUDE.md"
cp "${MEGAVIBE_UNDER_TEST:-$REPO/megavibe}" "$MEGAVIBE_HOME/megavibe"; : > "$MEGAVIBE_HOME/init.sh"; date +%s > "$MEGAVIBE_HOME/.last-update-check"
cat > "$T/bin/claude" <<'STUB'
#!/bin/bash
if [ "$*" = "auth status" ]; then echo '{"loggedIn":true}'; else printf '%s\n' "$@" > "$CLAUDE_ARGS"; fi
STUB
chmod +x "$T/bin/claude"
sleep 120 & LOCK_PID=$!; export LOCK_PID
cat > "$T/bin/ps" <<'STUB'
#!/bin/bash
if [ "$*" = "-p $LOCK_PID -o comm=" ]; then echo claude; else exec /bin/ps "$@"; fi
STUB
chmod +x "$T/bin/ps"

P="$T/proj"; git init -q -b main "$P" 2>/dev/null || git init -q "$P"; cd "$P" || exit 2
git config user.email t@t; git config user.name t; echo a > a; git add a; git commit -qm init
mkdir -p .agent .claude
W="$T/proj-issue-1"; git worktree add -q -b dispatch/issue-1 "$W" HEAD
ln -s "$P/.agent" "$W/.agent"; ln -s "$P/.claude" "$W/.claude"
launch() { ( cd "$1" && shift && bash "$MEGAVIBE_HOME/megavibe" --no-normalize "$@" </dev/null >"$T/out" 2>"$T/err" ); }
live() { mkdir -p "$1"; printf '{"pid":%s,"branch":"x"}\n' "$LOCK_PID" > "$1/metadata.json"; }

live "$P/.agent/.session-lock.d"
export CLAUDE_ARGS="$T/args1"; launch "$W" 'task'; RC=$?
check "a live session in the main checkout does not stop a worktree session (rc=$RC)" '[ "$RC" = 0 ] && [ -s "$CLAUDE_ARGS" ] && ! grep -q "Another megavibe session" "$T/out" "$T/err"'
check "the main checkout's lock is untouched when the worktree session ends" '[ -f "$P/.agent/.session-lock.d/metadata.json" ]'
check "the worktree session's own lock is gone after it ends" '[ -z "$(ls "$(git -C "$W" rev-parse --absolute-git-dir)" | grep megavibe-session-lock)" ]'

GD=$(git -C "$W" rev-parse --absolute-git-dir); live "$GD/megavibe-session-lock.d"
export CLAUDE_ARGS="$T/args2"; : > "$CLAUDE_ARGS"; rm -f "$CLAUDE_ARGS"; launch "$W" 'task'
check "a second session in the SAME worktree is still refused" '[ ! -s "$CLAUDE_ARGS" ] && grep -q "Another megavibe session" "$T/out"'
/bin/rm -rf "$GD/megavibe-session-lock.d"

/bin/rm -rf "$P/.agent/.session-lock.d"; export CLAUDE_ARGS="$T/args3"; live "$P/.agent/.session-lock.d"; rm -f "$CLAUDE_ARGS"; launch "$P" 'task'
check "a second session in the main checkout is still refused" '[ ! -s "$CLAUDE_ARGS" ] && grep -q "Another megavibe session" "$T/out"'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
