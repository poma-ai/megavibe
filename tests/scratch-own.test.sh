#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
OWN=$REPO/scripts/scratch-own.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/scratch-own-test.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T"; rm -rf "$T"' EXIT
export HOME=$T/home TMPDIR=$T/tmp CLAUDE_CODE_SESSION_ID=unit-test
unset CLAUDE_CODE_TMPDIR
mkdir -p "$HOME" "$TMPDIR/mv-old" "$HOME/outside"
# Session root discovery is confined to private fixtures, including the fallback root.
mkdir -p "$HOME/.megavibe/scripts"
cp "$OWN" "$HOME/.megavibe/scripts/"
OWN=$HOME/.megavibe/scripts/scratch-own.sh
export TEST_ROOTS="$T/session roots"$'\n'"$T/fallback"
cat > "$HOME/.megavibe/scripts/scratch-root.sh" <<'SH'
#!/bin/bash
case "$1" in
  roots) printf '%s\n' "$TEST_ROOTS" ;;
  base) printf '%s\n' "$TMPDIR" ;;
esac
SH
chmod +x "$HOME/.megavibe/scripts/scratch-root.sh"
touch "$HOME/outside/keep"
"$OWN" stamp "$CLAUDE_CODE_SESSION_ID"
stamp=$HOME/.megavibe/scratch-start/$CLAUDE_CODE_SESSION_ID
sleep 2
now=$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp")
"$OWN" stamp "$CLAUDE_CODE_SESSION_ID"
[[ $(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp") == "$now" ]]
# APFS can lower birth time when mtime is backdated. Keep the stamp older
# than the synthetic mtime, and age the fixtures before registering them.
age() {
  python3 - "$@" <<'AGE'
import os
import sys
for venv in sys.argv[1:]:
    for root, dirs, files in os.walk(venv, topdown=False):
        for path in [root] + [os.path.join(root, name) for name in dirs + files]:
            os.utime(path, (946684800, 946684800), follow_symlinks=False)
AGE
}
mkdir "$T/venvs"
(
  export TMPDIR="$T/venvs"
  "$OWN" stamp venv-test
  "$OWN" stamp venv-other
  touch -t 199912310000 "$HOME/.megavibe/scratch-start/"{venv-test,venv-other}
  for name in "user venv" user-aged other-venv unit-venv end-venv recent-venv; do
    python3 -m venv --without-pip "$TMPDIR/$name"
    touch "$TMPDIR/$name/keep"
  done
  age "$TMPDIR/user-aged" "$TMPDIR/end-venv" "$TMPDIR/other-venv"
  "$OWN" clean-end venv-test
  [[ -f "$TMPDIR/user-aged/keep" ]] || { echo "FAIL: clean-end removed a user venv"; exit 1; }
  "$OWN" clean-unit venv-test
  [[ -f "$TMPDIR/user venv/keep" ]] || { echo "FAIL: clean-unit removed a user venv"; exit 1; }

  "$OWN" register venv-other "$TMPDIR/other-venv"
  "$OWN" register venv-test "$TMPDIR/unit-venv" "$TMPDIR/end-venv" "$TMPDIR/recent-venv"
  "$OWN" list venv-test > "$HOME/registered-list"
  grep -Fq "$TMPDIR/unit-venv" "$HOME/registered-list"
  ln -s "$TMPDIR/unit-venv" "$TMPDIR/venv-link"
  for path in "$TMPDIR/venv-link/" "$HOME/outside" "$TMPDIR/unit-venv/bin"; do
    if "$OWN" register venv-test "$path" 2>/dev/null; then
      echo "FAIL: registered an invalid path: $path"
      exit 1
    fi
  done
  "$OWN" clean-unit "" 2>/dev/null || [[ $? == 4 ]]
  "$OWN" clean-end "" 2>/dev/null || [[ $? == 4 ]]
  [[ -d "$TMPDIR/unit-venv" && -d "$TMPDIR/end-venv" && -d "$TMPDIR/other-venv" ]]
  "$OWN" clean-end venv-test
  [[ ! -e "$TMPDIR/end-venv" && -f "$TMPDIR/recent-venv/keep" && -f "$TMPDIR/user-aged/keep" && -f "$TMPDIR/other-venv/keep" ]]

  # Neither a replacement directory nor a replacement symlink inherits registration.
  mkdir "$TMPDIR/reused" "$TMPDIR/replaced-with-link"
  "$OWN" register venv-test "$TMPDIR/reused" "$TMPDIR/replaced-with-link"
  mv "$TMPDIR/reused" "$T/previous-registered"
  mv "$TMPDIR/replaced-with-link" "$T/previous-link-path"
  mkdir "$TMPDIR/reused"
  ln -s "$HOME/outside" "$TMPDIR/replaced-with-link"
  "$OWN" clean-unit venv-test
  [[ ! -e "$TMPDIR/unit-venv" && ! -e "$TMPDIR/recent-venv" && -f "$TMPDIR/other-venv/keep" ]]
  [[ -d "$TMPDIR/reused" && -L "$TMPDIR/replaced-with-link" && -f "$HOME/outside/keep" ]]
)
mkdir -p "$TMPDIR"/{venv,pip-build,codex-example-scratch.A,mv-recent,mv-unit,mv-bad,unrelated,pytest-of-test/pytest-1,pytest-of-test/pytest-current,mv-review-copy.mine,mv-review-copy.theirs,mv-review-copy.legacy,mv-review-copy.stale,claude-review-scratch.live,codex-review-scratch.dead}
touch "$TMPDIR/venv/pyvenv.cfg" "$TMPDIR/mv-recent/new" "$TMPDIR/mv-generated-file"
chmod a-w "$HOME/outside/keep"
ln "$HOME/outside/keep" "$TMPDIR/mv-unit/hardlink"
copy=$(bash "$REPO/scripts/review-copy.sh" make --repo "$REPO" README.md)
[[ $(head -1 "$copy/.megavibe-review-copy") == mv-review-copy-v1 ]]
[[ $(sed -n '2p' "$copy/.megavibe-review-copy") == "session $CLAUDE_CODE_SESSION_ID" ]]
printf '%s\n' "$$" > "$TMPDIR/claude-review-scratch.live/.pid"
printf 'mv-review-copy-v1\nsession unit-test\n' > "$TMPDIR/mv-review-copy.mine/.megavibe-review-copy"
printf 'mv-review-copy-v1\nsession someone-else\n' > "$TMPDIR/mv-review-copy.theirs/.megavibe-review-copy"
printf 'mv-review-copy-v1\nsource example\n' > "$TMPDIR/mv-review-copy.legacy/.megavibe-review-copy"
ln -s "$HOME/outside" "$TMPDIR/mv-link"
ln -s "$HOME/outside" "$TMPDIR/mv-review-copy.stale/link"
printf 'mv-review-copy-v1\nsession aged\n' > "$TMPDIR/mv-review-copy.stale/.megavibe-review-copy"
touch "$TMPDIR/mv-old"
if "$OWN" register "$CLAUDE_CODE_SESSION_ID" "$TMPDIR/mv-old" 2>/dev/null; then
  echo "FAIL: registered an entry born before the stamp"
  exit 1
fi
mkdir "$HOME/bin"
cat > "$HOME/bin/du" <<'SH'
#!/bin/bash
case "${@: -1}" in */mv-bad) printf '9000000\t%s\n' "${@: -1}"; exit 1 ;; esac
exec /usr/bin/du "$@"
SH
# Reviewer liveness comes from the fixture's PID or these scan results.
cat > "$HOME/bin/ps" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$HOME/bin/lsof" <<'SH'
#!/bin/bash
printf 'n/\n'
SH
chmod +x "$HOME"/bin/*
export PATH="$HOME/bin:$PATH"
sleep 1 &
dead=$!
wait "$dead"
printf '%s\n' "$dead" > "$TMPDIR/codex-review-scratch.dead/.pid"
mkdir "$TMPDIR/codex-review-scratch.unrecorded"
"$OWN" register "$CLAUDE_CODE_SESSION_ID" "$TMPDIR/mv-unit" "$TMPDIR/mv-bad" "$TMPDIR/mv-generated-file"

rc=0
"$OWN" list "$CLAUDE_CODE_SESSION_ID" > "$HOME/list" 2>"$HOME/errors" || rc=$?
[[ $rc == 4 ]]
grep -q 'skipped.*mv-bad' "$HOME/errors"
for name in mv-unit mv-generated-file mv-review-copy.mine codex-review-scratch.dead; do
  grep -Fq "/$name" "$HOME/list"
done
if grep -Eq '/(venv|pip-build|codex-example-scratch.A|mv-recent|mv-old|mv-link|mv-bad|unrelated|pytest-1|pytest-current|mv-review-copy.theirs|mv-review-copy.legacy|claude-review-scratch.live|codex-review-scratch.unrecorded|pytest-of-test)$' "$HOME/list"; then exit 1; fi
"$OWN" other 20 > "$HOME/other" 2>/dev/null || [[ $? == 4 ]]
grep -Eq $'^[0-9]+\t[0-9]+\tpytest-of-test$' "$HOME/other"
for name in venv pip-build codex-example-scratch.A mv-recent mv-review-copy.theirs mv-review-copy.legacy claude-review-scratch.live codex-review-scratch.unrecorded; do
  grep -Fq "$name" "$HOME/other"
done
if grep -Eq 'mv-review-copy.mine|pytest-1' "$HOME/other"; then exit 1; fi

"$OWN" stamp aged
touch -t 199912310000 "$HOME/.megavibe/scratch-start/aged"
touch -t 200001010000 "$TMPDIR/mv-review-copy.stale" "$TMPDIR/mv-review-copy.stale/.megavibe-review-copy"
touch -h -t 200001010000 "$TMPDIR/mv-review-copy.stale/link"
# Check the registered hook's real entry point, including stderr-only reporting.
mkdir -p "$HOME/.megavibe/scripts" "$HOME/project/.agent"
hook=$REPO/template/.claude/hooks/scratch-end.sh
(cd "$HOME/project" && printf '{"session_id":"aged"}' | bash "$hook") > "$HOME/stdout" 2>"$HOME/end"
[[ ! -s "$HOME/stdout" && ! -d "$TMPDIR/mv-review-copy.stale" && -d "$TMPDIR/mv-recent" && -f "$HOME/outside/keep" ]]
[[ $(wc -l < "$HOME/end") -eq 1 ]]
grep -q 'removed 1 entries' "$HOME/end"
chmod -R a-w "$TMPDIR/mv-review-copy.mine"
"$OWN" clean-unit "$CLAUDE_CODE_SESSION_ID" > "$HOME/unit" 2>/dev/null || [[ $? == 4 ]]
for name in mv-unit mv-generated-file mv-review-copy.mine codex-review-scratch.dead; do
  [[ ! -e "$TMPDIR/$name" ]]
done
for name in venv pip-build codex-example-scratch.A mv-recent mv-old mv-link mv-bad unrelated pytest-of-test/pytest-1 pytest-of-test/pytest-current mv-review-copy.theirs mv-review-copy.legacy claude-review-scratch.live codex-review-scratch.unrecorded; do
  [[ -e "$TMPDIR/$name" ]]
done
[[ -f "$HOME/outside/keep" && ! -w "$HOME/outside/keep" && ! -e "$copy" ]]
# A matching marker identifies the session for measurement. Cleanup also
# requires a valid start stamp and an entry created after it.
(
  export TMPDIR="$T/old-marker"
  mkdir -p "$TMPDIR/mv-review-copy.old"
  printf 'mv-review-copy-v1\nsession later\n' > "$TMPDIR/mv-review-copy.old/.megavibe-review-copy"
  sleep 1
  "$OWN" stamp later
  "$OWN" clean-unit later > "$HOME/old-marker"
  [[ -d "$TMPDIR/mv-review-copy.old" ]] || { echo "FAIL: cleanup removed a marked copy born before the stamp"; exit 1; }
)
(
  export TMPDIR="$T/odd-stamp"
  mkdir -p "$TMPDIR/mv-review-copy.unstamped"
  printf 'mv-review-copy-v1\nsession absent\n' > "$TMPDIR/mv-review-copy.unstamped/.megavibe-review-copy"
  "$OWN" clean-unit absent > "$HOME/absent" 2>/dev/null || [[ $? == 4 ]]
  [[ -d "$TMPDIR/mv-review-copy.unstamped" ]] || { echo "FAIL: missing stamp allowed cleanup"; exit 1; }
)
(
  export TMPDIR="$T/odd-sid"
  mkdir -p "$TMPDIR"
  "$OWN" stamp hook
  sleep 1
  mkdir "$TMPDIR/mv-review-copy.hook"
  printf 'mv-review-copy-v1\nsession hook\n' > "$TMPDIR/mv-review-copy.hook/.megavibe-review-copy"
  touch -t 199912310000 "$HOME/.megavibe/scratch-start/hook"
  touch -t 200001010000 "$TMPDIR/mv-review-copy.hook" "$TMPDIR/mv-review-copy.hook/.megavibe-review-copy"
  (cd "$HOME/project" && printf '%s' '{"session_id":"hook\n"}' | bash "$hook") 2>/dev/null
  [[ -d "$TMPDIR/mv-review-copy.hook" ]] || { echo "FAIL: a newline-terminated SID selected another session for cleanup"; exit 1; }
)
(
  export TMPDIR="$T/alias"
  "$OWN" stamp alias
  sleep 1
  mkdir -p "$HOME/outside/pip-build"
  TMPDIR="$HOME/outside" "$OWN" register alias "$HOME/outside/pip-build"
  ln -s "$HOME/outside" "$TMPDIR"
  "$OWN" clean-unit alias > "$HOME/alias" 2>/dev/null || [[ $? == 4 ]]
  [[ -d "$HOME/outside/pip-build" ]] || { echo "FAIL: cleanup followed a symlinked temp base"; exit 1; }
)
(
  export TMPDIR="$T/zero-stamp"
  mkdir -p "$TMPDIR"
  "$OWN" stamp zero
  sleep 1
  mkdir "$TMPDIR/mv-existing"
  "$OWN" register zero "$TMPDIR/mv-existing"
  python3 -c 'import os, sys; os.utime(sys.argv[1], (0, 0))' "$HOME/.megavibe/scratch-start/zero"
  "$OWN" clean-unit zero > "$HOME/zero" 2>/dev/null || [[ $? == 4 ]]
  [[ -d "$TMPDIR/mv-existing" ]] || { echo "FAIL: epoch stamp allowed cleanup"; exit 1; }
)
(
  export TMPDIR="$T/invalid-reviewer"
  "$OWN" stamp reviewer
  sleep 1
  mkdir -p "$TMPDIR/codex-review-scratch.invalid"
  printf '9999999999\n' > "$TMPDIR/codex-review-scratch.invalid/.pid"
  rc=0
  "$OWN" clean-unit reviewer > "$HOME/reviewer-out" 2> "$HOME/reviewer-error" || rc=$?
  [[ $rc == 4 && -d "$TMPDIR/codex-review-scratch.invalid" ]] || {
    echo "FAIL: malformed reviewer PID was not handled as an incomplete cleanup"
    exit 1
  }
)
(
  export TMPDIR="$T/bad-base"
  mkdir "$TMPDIR"
  "$OWN" stamp bad-base
  sleep 1
  mkdir "$TMPDIR/mv-keep"
  "$OWN" register bad-base "$TMPDIR/mv-keep"
  TMPDIR="$TMPDIR/missing/.." "$OWN" clean-unit bad-base > "$HOME/bad-base" 2>/dev/null || [[ $? == 4 ]]
  [[ -d "$TMPDIR/mv-keep" ]] || { echo "FAIL: a nonexistent temp base was interpreted as its parent"; exit 1; }
)
touch "$HOME/project/.agent/DECISIONS.md" "$HOME/project/.agent/LESSONS.md"
start=$REPO/template/.claude/hooks/on-session-start.sh
(cd "$HOME/project" && printf '%s' '{"source":"startup","session_id":"other\n"}' | bash "$start") >/dev/null
[[ ! -e "$HOME/.megavibe/scratch-start/other" ]] || { echo "FAIL: malformed startup SID stamped another session"; exit 1; }
failed=0
check() {
  if ! "$@"; then
    printf 'FAIL: %s\n' "$*" >&2
    failed=1
  fi
}
mkdir "$TMPDIR/default-register"
check bash -c 'cd "$TMPDIR" && "$1" register default-register' _ "$OWN"
"$OWN" list "$CLAUDE_CODE_SESSION_ID" > "$HOME/default-list" 2>/dev/null || [[ $? == 4 ]]
check grep -Fq "$TMPDIR/default-register" "$HOME/default-list"
if (unset CLAUDE_CODE_SESSION_ID; "$OWN" register "$TMPDIR/default-register") 2>"$HOME/no-sid"; then
  echo 'FAIL: register accepted a path without a session ID' >&2
  failed=1
fi
check grep -Fq CLAUDE_CODE_SESSION_ID "$HOME/no-sid"

root="$T/session roots"
project="$root/project"
session="$project/pad"
fallback="$T/fallback/project/pad"
mkdir -p "$session"/{tasks,pinned/nested,resume} "$fallback" "$project/another" "$project/PAD-CASE" \
  "$root/x" "$project/"{'a b',-r,'*',a/b,ab,$'pad\n'} "$HOME/outside/pad"
touch "$session"/{tasks/output,cwd,.keep,pinned/nested/.keep,resume/new} \
  "$fallback/old" "$project/PAD-CASE/old" "$project/old" "$HOME/outside/pad/old" \
  {"$root/x","$project/"{'a b',-r,'*',a/b,ab,another,$'pad\n'}}/old
ln -s "$HOME/outside/pad" "$session/link"
ln -s "$HOME/outside" "$root/project-link"
mkdir "$root/session-link"
ln -s "$HOME/outside/pad" "$root/session-link/pad"
age "$root" "$T/fallback" "$HOME/outside/pad"
python3 - "$session/resume/new" <<'PYTHON'
import os, sys, time
recent = time.time() - 1800
os.utime(sys.argv[1], (recent, recent))
PYTHON
printf 'task output\n' > "$session/tasks/output"
touch -t 200001010000 "$session/tasks/output"
touch "$HOME/outside/pad/.keep"
chmod -R a-w "$session/tasks"

"$OWN" clean-unit pad > "$HOME/pad-unit"
check test -f "$session/tasks/output"
for bad in '../x' 'a b' '-r' '*' '' 'a/b' $'pad\n' 'a.b'; do
  "$OWN" clean-end "$bad" > "$HOME/bad-out" 2>/dev/null || [[ $? == 4 ]]
done
for file in "$root/x/old" "$project/old" "$project/"{'a b',-r,'*',a/b,ab,another,$'pad\n'}/old "$session/tasks/output"; do
  check test -f "$file"
done
(cd "$HOME/project" && printf '{"session_id":"pad"}' | bash "$hook") > "$HOME/pad-out" 2>"$HOME/pad-end"
check test ! -s "$HOME/pad-out"
check test ! -e "$session/tasks"
check test ! -e "$session/cwd"
check test ! -L "$session/link"
check test ! -e "$fallback"
check test -f "$session/.keep"
check test -f "$session/pinned/nested/.keep"
check test -f "$session/resume/new"
check test -f "$project/another/old"
"$OWN" clean-end pad-case 2>"$HOME/case-end"
check test -f "$project/PAD-CASE/old"
check test -f "$HOME/outside/pad/old"
check test "$(wc -l < "$HOME/pad-end" | tr -d ' ')" = 1
check grep -Eq 'scratchpad [1-9][0-9]* entries, [1-9][0-9]* kB' "$HOME/pad-end"
# A shared-base scan must not bypass the scratchpad's retention rules,
# even if TMPDIR points at the session directory and a copy is attributed.
overlap="$project/overlap"
copy="$overlap/mv-review-copy.pinned"
mkdir -p "$copy"
"$OWN" stamp overlap
touch -t 199912310000 "$HOME/.megavibe/scratch-start/overlap"
printf 'mv-review-copy-v1\nsession overlap\n' > "$copy/.megavibe-review-copy"
touch "$copy/.keep"
age "$copy"
TMPDIR="$overlap" "$OWN" clean-end overlap 2>"$HOME/overlap-end"
check test -f "$copy/.keep"
# Failure of the shared-temp scan must still leave a SessionEnd summary
# and allow cleanup in a valid session root.
mkdir "$project/broken-base"
touch "$project/broken-base/old"
age "$project/broken-base"
rc=0
TMPDIR="$T/missing" "$OWN" clean-end broken-base 2>"$HOME/broken-base-end" || rc=$?
check test "$rc" = 4
check test ! -e "$project/broken-base"
check grep -q 'scratchpad 1 entries' "$HOME/broken-base-end"
[[ $failed == 0 ]] || exit 1
printf 'scratch ownership and cleanup passed\n'
