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
touch "$HOME/outside/keep"
"$OWN" stamp "$CLAUDE_CODE_SESSION_ID"
stamp=$HOME/.megavibe/scratch-start/$CLAUDE_CODE_SESSION_ID
sleep 2
now=$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp")
"$OWN" stamp "$CLAUDE_CODE_SESSION_ID"
[[ $(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp") == "$now" ]]
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

rc=0
"$OWN" list "$CLAUDE_CODE_SESSION_ID" > "$HOME/list" 2>"$HOME/errors" || rc=$?
[[ $rc == 4 ]]
grep -q 'skipped.*mv-bad' "$HOME/errors"
for name in venv pip-build codex-example-scratch.A mv-recent mv-unit mv-generated-file pytest-1 mv-review-copy.mine mv-review-copy.legacy claude-review-scratch.live codex-review-scratch.dead; do
  grep -Fq "/$name" "$HOME/list"
done
if grep -Eq '/(mv-old|mv-link|mv-bad|unrelated|pytest-current|mv-review-copy.theirs)$|/pytest-of-test$' "$HOME/list"; then exit 1; fi
"$OWN" other 20 > "$HOME/other" 2>/dev/null || [[ $? == 4 ]]
grep -Eq $'^[0-9]+\t[0-9]+\tpytest-of-test$' "$HOME/other"
grep -q 'mv-review-copy.theirs' "$HOME/other"
if grep -Eq 'mv-review-copy.mine|pytest-1' "$HOME/other"; then exit 1; fi

"$OWN" stamp aged
touch -t 199912310000 "$HOME/.megavibe/scratch-start/aged"
touch -t 200001010000 "$TMPDIR/mv-review-copy.stale" "$TMPDIR/mv-review-copy.stale/.megavibe-review-copy"
touch -h -t 200001010000 "$TMPDIR/mv-review-copy.stale/link"
# Check the registered hook's real entry point, including stderr-only reporting.
mkdir -p "$HOME/.megavibe/scripts" "$HOME/project/.agent"
cp "$OWN" "$REPO/scripts/scratch-root.sh" "$HOME/.megavibe/scripts/"
hook=$REPO/template/.claude/hooks/scratch-end.sh
(cd "$HOME/project" && printf '{"session_id":"aged"}' | bash "$hook") > "$HOME/stdout" 2>"$HOME/end"
[[ ! -s "$HOME/stdout" && ! -d "$TMPDIR/mv-review-copy.stale" && -d "$TMPDIR/mv-recent" && -f "$HOME/outside/keep" ]]
[[ $(wc -l < "$HOME/end") -eq 1 ]]
grep -q 'removed 1 entries' "$HOME/end"
chmod -R a-w "$TMPDIR/mv-review-copy.mine"
"$OWN" clean-unit "$CLAUDE_CODE_SESSION_ID" > "$HOME/unit" 2>/dev/null || [[ $? == 4 ]]
for name in venv pip-build codex-example-scratch.A mv-recent mv-unit mv-generated-file pytest-of-test/pytest-1 mv-review-copy.mine mv-review-copy.legacy codex-review-scratch.dead; do
  [[ ! -e "$TMPDIR/$name" ]]
done
for name in mv-old mv-link mv-bad unrelated pytest-of-test pytest-of-test/pytest-current mv-review-copy.theirs claude-review-scratch.live; do
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
  ln -s "$HOME/outside" "$TMPDIR"
  "$OWN" clean-unit alias > "$HOME/alias" 2>/dev/null || [[ $? == 4 ]]
  [[ -d "$HOME/outside/pip-build" ]] || { echo "FAIL: cleanup followed a symlinked temp base"; exit 1; }
)
(
  export TMPDIR="$T/zero-stamp"
  mkdir -p "$TMPDIR/mv-existing"
  "$OWN" stamp zero
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
  TMPDIR="$TMPDIR/missing/.." "$OWN" clean-unit bad-base > "$HOME/bad-base" 2>/dev/null || [[ $? == 4 ]]
  [[ -d "$TMPDIR/mv-keep" ]] || { echo "FAIL: a nonexistent temp base was interpreted as its parent"; exit 1; }
)
touch "$HOME/project/.agent/DECISIONS.md" "$HOME/project/.agent/LESSONS.md"
start=$REPO/template/.claude/hooks/on-session-start.sh
(cd "$HOME/project" && printf '%s' '{"source":"startup","session_id":"other\n"}' | bash "$start") >/dev/null
[[ ! -e "$HOME/.megavibe/scratch-start/other" ]] || { echo "FAIL: malformed startup SID stamped another session"; exit 1; }
printf 'scratch ownership and cleanup passed\n'
