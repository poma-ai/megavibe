#!/bin/bash
# All removal happens inside this test's mktemp directory, with a fake HOME.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TOOL=${WORKTREES_AUDIT_TOOL:-$REPO/scripts/worktrees-audit.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/worktrees-audit-test.XXXXXX")
T=$(cd "$T" && pwd -P)
PAUSED_PID=''
cleanup() {
  if [[ -n $PAUSED_PID ]]; then
    touch "$T/commit-release"
    wait "$PAUSED_PID" || :
  fi
  rm -rf -- "$T"
}
trap cleanup EXIT
export HOME=$T/home TMPDIR=$T/tmp
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
unset MEGAVIBE_HOME
mkdir -p "$HOME/dev/_wt" "$TMPDIR"
export GIT_AUTHOR_NAME='Test User' GIT_COMMITTER_NAME='Test User'
export GIT_AUTHOR_EMAIL='user@example.com' GIT_COMMITTER_EMAIL='user@example.com'
PASS=0 FAIL=0
check() {
  local label=$1
  shift
  if "$@"; then PASS=$((PASS + 1));
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label"; fi
}
field() {
  local path
  printf -v path '%q' "$1"
  AUDIT_PATH="$path" awk -F '\t' -v col="$2" '$1 == ENVIRON["AUDIT_PATH"] {print $col; exit}' "$T/audit"
}
verdict() { [[ $(field "$1" 9) == "$2" ]]; }
nonzero_unpushed() { [[ $(field "$1" 4) =~ ^[1-9][0-9]*$ ]]; }
run() { (cd "$MAIN" && /bin/bash "$TOOL" "$@"); }
git init -q --bare "$T/remote.git"
git clone -q "$T/remote.git" "$T/main" 2> "$T/clone.err"
MAIN=$T/main
WT=$HOME/dev/_wt
git -C "$MAIN" checkout -q -b main
printf 'base\n' > "$MAIN/file"
printf 'ignored-file\n' > "$MAIN/.gitignore"
# A fixture records stdin and argv, without relying on jq or the live hook.
mkdir -p "$MAIN/.claude/hooks"
cat > "$MAIN/.claude/hooks/agent-log.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $1 == append && $2 == --project && $3 == "$TEST_PROJECT" ]]
cat >> "$TEST_EVENTS"
EOF
git -C "$MAIN" add .
git -C "$MAIN" commit -qm initial
git -C "$MAIN" push -q -u origin main
git --git-dir="$T/remote.git" symbolic-ref HEAD refs/heads/main
git -C "$MAIN" remote set-head origin -a >/dev/null
export TEST_EVENTS=$T/events TEST_PROJECT=$MAIN
: > "$TEST_EVENTS"
for name in safe tracked untracked local locked parked ignored current; do
  git -C "$MAIN" worktree add -q -b "$name" "$WT/$name" main
done
printf 'merged feature\n' > "$WT/safe/feature"
git -C "$WT/safe" add feature
git -C "$WT/safe" commit -qm feature
git -C "$MAIN" merge -q --no-ff safe -m 'merge feature'
git -C "$MAIN" push -q origin main
git -C "$MAIN" worktree add -q --detach "$WT/detached" origin/main
git -C "$MAIN" worktree add -q -b spaces "$WT/with space" main
printf 'modified\n' >> "$WT/tracked/file"
printf 'untracked\n' > "$WT/untracked/new"
printf 'ignored\n' > "$WT/ignored/ignored-file"
printf 'local only\n' >> "$WT/local/file"
git -C "$WT/local" commit -qam local-only
git -C "$MAIN" worktree lock "$WT/locked" --reason 'keep this'
printf 'parked\n' >> "$WT/parked/file"
git -C "$WT/parked" commit -qam parked
git -C "$WT/parked" push -q -u origin parked
# Detached remote commit need not be merged into default.
git -C "$MAIN" worktree add -q --detach "$WT/detached-side" origin/parked
git -C "$MAIN" worktree add -q --detach "$WT/detached-local" local
run audit > "$T/audit"
for name in safe detached detached-side current 'with space'; do check "$name SAFE" verdict "$WT/$name" SAFE; done
for name in tracked untracked local locked parked ignored detached-local; do check "$name KEEP" verdict "$WT/$name" KEEP; done
check 'main KEEP' verdict "$MAIN" KEEP
check 'local-only commit counted (requires HEAD --not --remotes)' nonzero_unpushed "$WT/local"
check 'detached local-only commit counted' nonzero_unpushed "$WT/detached-local"
check 'untracked-only dirty counted' test "$(field "$WT/untracked" 3)" = 1
check 'tracked dirty counted' test "$(field "$WT/tracked" 3)" = 1
check 'pushed parked branch has zero unpushed' test "$(field "$WT/parked" 4)" = 0
check 'pushed parked branch is unmerged' test "$(field "$WT/parked" 5)" = no
check 'lock reported' test "$(field "$WT/locked" 8)" = yes
check 'detached branch reported' test "$(field "$WT/detached" 7)" = detached
check 'last commit date reported' test "$(field "$WT/safe" 6)" != '?'
git -C "$MAIN" symbolic-ref --delete refs/remotes/origin/HEAD
run audit > "$T/audit"
check 'server default works without local origin/HEAD' verdict "$WT/safe" SAFE
git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/parked
run audit > "$T/audit"
check 'stale origin/HEAD cannot authorize removal' verdict "$WT/parked" KEEP
git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
run remove-safe --dry-run > "$T/dry"
for name in safe detached detached-side tracked untracked local locked parked ignored current 'with space' detached-local; do
  check "dry-run retains $name" test -d "$WT/$name"
done
check 'dry-run logs nothing' test ! -s "$TEST_EVENTS"
check 'dry-run frees nothing' grep -q '^Freed: 0 KiB' "$T/dry"

# Inject failures into actual Git commands; every candidate must remain KEEP.
export REAL_GIT
REAL_GIT=$(command -v git)
mkdir "$T/bin"
cat > "$T/bin/git" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ -n ${TRACE_GIT:-} ]]; then printf '%s\n' "$*" >> "$TRACE_GIT"; fi
if [[ -n ${CHECK_INTENT:-} && " $* " == *' worktree remove '* ]]; then
  "$REAL_PERL" -MJSON::PP -e '
    open my $f, "<", $ARGV[0] or exit 1; my @lines=<$f>; @lines or exit 1;
    my $e=decode_json($lines[-1]);
    $e->{status} eq "intent" && $e->{path} eq $ARGV[1] && -d $ARGV[1] or exit 1;
  ' "$HOME/.megavibe/worktrees-audit-removals.jsonl" "${!#}"
  printf 'intent verified before removal\n' >> "$CHECK_INTENT"
fi
if [[ -n ${SLOW_GIT:-} && " $* " == *" $SLOW_GIT "* ]]; then sleep 90; fi
if [[ -n ${FETCH_COUNT:-} && " $* " == *' fetch '* ]]; then
  n=0
  [[ ! -f $FETCH_COUNT ]] || n=$(cat "$FETCH_COUNT")
  n=$((n + 1)); printf '%s\n' "$n" > "$FETCH_COUNT"
  [[ $n != 2 ]] || exit 128
fi
if [[ -n ${RACE_PATH:-} && " $* " == *' worktree list '* ]]; then
  n=0
  [[ ! -f $RACE_COUNT ]] || n=$(cat "$RACE_COUNT")
  n=$((n + 1)); printf '%s\n' "$n" > "$RACE_COUNT"
  if [[ $n == 2 ]]; then
    if [[ ${RACE_KIND:-dirty} == lock ]]; then
      gd=$("$REAL_GIT" -C "$RACE_PATH" rev-parse --absolute-git-dir)
      : > "$gd/index.lock"
    elif [[ ${RACE_KIND:-dirty} == common-lock ]]; then
      gd=$("$REAL_GIT" -C "$RACE_PATH" rev-parse --git-common-dir)
      : > "$gd/refs/heads/main.lock"
    elif [[ ${RACE_KIND:-dirty} == operation ]]; then
      gd=$("$REAL_GIT" -C "$RACE_PATH" rev-parse --absolute-git-dir)
      mkdir -p "$gd/sequencer"
    else
      printf 'changed during audit\n' >> "$RACE_PATH/file"
      if [[ ${RACE_KIND:-dirty} == commit ]]; then "$REAL_GIT" -C "$RACE_PATH" commit -qam 'local race'; fi
    fi
  fi
fi
case " $* " in
  *" ${FAIL_GIT:-impossible-command} "*) exit 128 ;;
esac
exec "$REAL_GIT" "$@"
EOF
chmod +x "$T/bin/git"
export REAL_PERL
REAL_PERL=$(command -v perl)
cat > "$T/bin/perl" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ ${FAIL_LOCK_SCAN:-0} == 1 && "$*" == *'my $budget'* ]]; then exit 1; fi
if [[ -n ${READONLY_LOG:-} && ${!#} == intent ]]; then
  # Opening succeeds; the real encoder must detect the rejected write/flush.
  exec "$REAL_PERL" "$@" 1< "$READONLY_LOG"
fi
exec "$REAL_PERL" "$@"
EOF
chmod +x "$T/bin/perl"
for failure in status log merge-base ls-files 'ls-files --stage -z'; do
  (cd "$MAIN" && PATH="$T/bin:$PATH" FAIL_GIT=$failure /bin/bash "$TOOL" remove-safe > "$T/failure" 2>&1)
  check "$failure failure retains safe branch" test -d "$WT/safe"
  check "$failure failure retains detached" test -d "$WT/detached"
done
(cd "$MAIN" && PATH="$T/bin:$PATH" FAIL_GIT=for-each-ref /bin/bash "$TOOL" remove-safe --dry-run > "$T/audit")
check 'remote reachability failure keeps detached' verdict "$WT/detached" KEEP
(cd "$MAIN" && PATH="$T/bin:$PATH" FAIL_GIT=remove /bin/bash "$TOOL" remove-safe > "$T/refused" 2> "$T/refused.err")
check 'refused removal retains SAFE tree' test -d "$WT/safe"
check 'refused removal logs nothing' test ! -s "$TEST_EVENTS"
check 'refused removal frees nothing' grep -q '^Freed: 0 KiB' "$T/refused"
check 'refused removal logs intent then refused' perl -MJSON::PP -e '
  open my $f, "<", $ARGV[0] or exit 1; my @e=map { decode_json($_) } <$f>;
  @e > 0 && @e % 2 == 0 or exit 1;
  while (@e) { my ($i, $o)=splice @e, 0, 2;
    $i->{status} eq "intent" && $o->{status} eq "refused" && $i->{path} eq $o->{path} or exit 1;
  }
' "$HOME/.megavibe/worktrees-audit-removals.jsonl"

for kind in dirty commit operation; do
  git -C "$MAIN" worktree add -q -b "race-$kind" "$WT/race-$kind" main
  (cd "$MAIN" && PATH="$T/bin:$PATH" RACE_PATH="$WT/race-$kind" RACE_COUNT="$T/count-$kind" RACE_KIND=$kind \
    /bin/bash "$TOOL" remove-safe --dry-run > "$T/race-$kind")
  check "recheck rejects newly $kind tree" awk -F '\t' -v p="$WT/race-$kind" '$1 == p && $9 == "KEEP" {found=1} END {exit !found}' "$T/race-$kind"
  check "recheck does not offer changed $kind tree" awk -F '\t' -v p="$WT/race-$kind" '$1 == "WOULD_REMOVE" && $2 == p {bad=1} END {exit bad}' "$T/race-$kind"
done
for flag in assume-unchanged skip-worktree; do
  git -C "$MAIN" worktree add -q -b "$flag" "$WT/$flag" main
  git -C "$WT/$flag" update-index "--$flag" file
  printf 'hidden change\n' >> "$WT/$flag/file"
done
run audit > "$T/audit"
check 'assume-unchanged hides no unsafe removal' verdict "$WT/assume-unchanged" KEEP
check 'skip-worktree hides no unsafe removal' verdict "$WT/skip-worktree" KEEP

# Run from a nested directory inside an otherwise SAFE worktree.
mkdir -p "$WT/current/nested"
(cd "$WT/current/nested" && /bin/bash "$TOOL" audit > "$T/audit")
check 'current worktree KEEP from subdirectory' verdict "$WT/current" KEEP
# Use the fixture hook in the current project for removal events.
export TEST_PROJECT=$WT/current
(cd "$WT/current/nested" && /bin/bash "$TOOL" remove-safe > "$T/removed")
check 'current worktree survives removal' test -d "$WT/current"
check 'main survives removal' test -d "$MAIN"
for name in safe detached detached-side 'with space'; do check "SAFE $name removed" test ! -e "$WT/$name"; done
for name in tracked untracked local locked parked ignored detached-local race-dirty race-commit race-operation assume-unchanged skip-worktree; do check "KEEP $name survives" test -d "$WT/$name"; done
check 'local commit still present' git -C "$WT/local" cat-file -e HEAD
check 'one event per removal' test "$(wc -l < "$TEST_EVENTS" | tr -d ' ')" = 4
check 'durable event in addition to each hook event' perl -MJSON::PP -e '
  open my $f, "<", $ARGV[0] or exit 1;
  my @removed=grep { decode_json($_)->{status} eq "removed" } <$f>; exit !(@removed == 4);
' "$HOME/.megavibe/worktrees-audit-removals.jsonl"
check 'event contains SHA and size' grep -Eq 'sha=[0-9a-f]+ size_kib=[0-9]+' "$TEST_EVENTS"
check 'event contains path and branch' grep -q 'path=.*branch=' "$TEST_EVENTS"
check 'freed size printed' grep -Eq '^Freed: [1-9][0-9]* KiB' "$T/removed"

# Discovery is additive, deduplicated, and follows linked-worktree .git files.
git init -q "$T/extra/repo"
git -C "$T/extra/repo" checkout -q -b main
printf 'extra\n' > "$T/extra/repo/file"
git -C "$T/extra/repo" add file
git -C "$T/extra/repo" commit -qm extra
run audit --root "$T/extra" --root "$MAIN" > "$T/audit"
check 'extra root discovered' verdict "$T/extra/repo" KEEP
check 'duplicate common dirs reported once' test "$(awk -F '\t' -v p="$MAIN" '$1 == p {n++} END {print n}' "$T/audit")" = 1
(cd "$T" && /bin/bash "$TOOL" audit > "$T/audit")
check 'HOME worktree discovers owner outside HOME' verdict "$MAIN" KEEP
run audit --min-mb 999999 > "$T/filtered"
check 'size filter' test "$(wc -l < "$T/filtered" | tr -d ' ')" = 1
check 'reject invalid numeric option' bash -c '! /bin/bash "$1" audit --min-mb nope >/dev/null 2>&1' _ "$TOOL"

# Missing metadata must never inherit the parent repository's state.
git -C "$MAIN" worktree add -q -b broken "$WT/broken" main
mv "$WT/broken/.git" "$T/broken.git-link"
run audit > "$T/audit"
check 'broken worktree KEEP' verdict "$WT/broken" KEEP
mv "$T/broken.git-link" "$WT/broken/.git"
git -C "$WT/broken" mv file renamed
printf 'new\n' > "$WT/broken/line
break"
run audit > "$T/audit"
check 'rename counted once and newline filename counted' test "$(field "$WT/broken" 3)" = 2

# No current project means no hook to invoke; absence is silent.
(cd "$T" && /bin/bash "$TOOL" remove-safe > "$T/no-hook" 2> "$T/no-hook.err")
check 'missing log hook is silent' test ! -s "$T/no-hook.err"
check 'missing log hook still removes SAFE tree' test ! -d "$WT/current"

# Every safety regression uses its own repository, local server and fake HOME.
SAVED_HOME=$HOME SAVED_MAIN=$MAIN SAVED_WT=$WT
fresh() {
  HOME=$T/cases/$1/home
  MAIN=$T/cases/$1/main
  WT=$HOME/dev/_wt
  SERVER=$T/cases/$1/server.git
  mkdir -p "$WT"
  git init -q --bare "$SERVER"
  git clone -q "$SERVER" "$MAIN" 2>/dev/null
  git -C "$MAIN" checkout -q -b main
  printf 'base\n' > "$MAIN/file"
  git -C "$MAIN" add file
  git -C "$MAIN" commit -qm base
  git -C "$MAIN" push -q -u origin main
  git --git-dir="$SERVER" symbolic-ref HEAD refs/heads/main
  git -C "$MAIN" remote set-head origin -a >/dev/null
}
reason() { [[ $(field "$1" 10) == *"$2"* ]]; }

fresh git-locks
git -C "$MAIN" worktree add -q -b safe "$WT/safe" main
GD=$(git -C "$WT/safe" rev-parse --absolute-git-dir)
mkdir -p "$GD/refs/heads/nested" "$MAIN/.git/refs/heads/nested"
for lock in "$GD/index.lock" "$GD/HEAD.lock" "$GD/other.lock" \
  "$GD/refs/heads/nested/topic.lock" "$MAIN/.git/refs/heads/nested/topic.lock" \
  "$MAIN/.git/packed-refs.lock" "$MAIN/.git/shallow.lock" "$MAIN/.git/config.lock"; do
  : > "$lock"
  run remove-safe > "$T/audit"
  check "$lock KEEP" verdict "$WT/safe" KEEP
  check "$lock git-lock reason" reason "$WT/safe" git-lock
  check "$lock survives" test -d "$WT/safe"
  rm "$lock"
done
(cd "$MAIN" && PATH="$T/bin:$PATH" FAIL_LOCK_SCAN=1 /bin/bash "$TOOL" remove-safe > "$T/audit")
check 'failed lock scan KEEP' verdict "$WT/safe" KEEP
check 'failed lock scan reason' reason "$WT/safe" git-lock
check 'failed lock scan removes nothing' test -d "$WT/safe"
# A metadata symlink must not be followed, even if it would loop forever.
ln -s "$GD" "$GD/loop"
run remove-safe > "$T/audit"
check 'symlinked metadata fails closed' reason "$WT/safe" git-lock
check 'symlinked metadata preserves worktree' test -d "$WT/safe"
rm "$GD/loop"
# Exceeding the depth bound must keep the tree, not silently truncate the scan.
deep=$GD/deep
for ((n=0; n<34; n++)); do deep=$deep/d; done
mkdir -p "$deep"
run remove-safe > "$T/audit"
check 'bounded lock scan fails closed' reason "$WT/safe" git-lock
check 'bounded lock scan preserves worktree' test -d "$WT/safe"
rm -rf "$GD/deep"
for kind in lock common-lock; do
  (cd "$MAIN" && PATH="$T/bin:$PATH" RACE_PATH="$WT/safe" RACE_COUNT="$T/count-$kind" RACE_KIND=$kind \
    /bin/bash "$TOOL" remove-safe > "$T/audit")
  check "$kind initially SAFE" verdict "$WT/safe" SAFE
  check "$kind recheck KEEP with git-lock" awk -F '\t' -v p="$WT/safe" \
    '$1 == p && $9 == "KEEP" && $10 ~ /git-lock/ {found=1} END {exit !found}' "$T/audit"
  check "$kind recheck removes nothing" test -d "$WT/safe"
  rm -f "$GD/index.lock" "$MAIN/.git/refs/heads/main.lock"
done

fresh paused-commit
git -C "$MAIN" worktree add -q -b safe "$WT/safe" main
GD=$(git -C "$WT/safe" rev-parse --absolute-git-dir)
cat > "$MAIN/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
set -euo pipefail
touch "$COMMIT_READY"
while [[ ! -e $COMMIT_RELEASE ]]; do sleep 0.1; done
EOF
chmod +x "$MAIN/.git/hooks/pre-commit"
COMMIT_READY="$T/commit-ready" COMMIT_RELEASE="$T/commit-release" \
  git -C "$WT/safe" commit -a --allow-empty -qm paused > "$T/commit.out" 2>&1 &
PAUSED_PID=$!
for ((n=0; n<100; n++)); do
  [[ ! -e $T/commit-ready ]] || break
  sleep 0.1
done
check 'commit reached pre-commit hook' test -e "$T/commit-ready"
check 'paused real commit holds index.lock' test -f "$GD/index.lock"
check 'paused real commit has clean status' test -z "$(git -C "$WT/safe" status --porcelain)"
run remove-safe > "$T/audit"
check 'paused real commit KEEP' verdict "$WT/safe" KEEP
check 'paused real commit git-lock reason' reason "$WT/safe" git-lock
check 'paused real commit worktree survives' test -d "$WT/safe"
touch "$T/commit-release"
if wait "$PAUSED_PID"; then rc=0; else rc=$?; fi
PAUSED_PID=''
check 'paused real commit completes successfully' test "$rc" = 0

fresh pending
git -C "$MAIN" worktree add -q -b rebasing "$WT/rebasing" main
printf 'feature\n' > "$WT/rebasing/feature"
git -C "$WT/rebasing" add feature
git -C "$WT/rebasing" commit -qm feature
git -C "$WT/rebasing" push -q origin rebasing
printf 'precious edits\n' >> "$WT/rebasing/file"
if git -C "$WT/rebasing" rebase --autostash --exec false main > "$T/rebase" 2>&1; then
  printf 'FAIL: rebase fixture did not pause\n'; exit 1
fi
GD=$(git -C "$WT/rebasing" rev-parse --absolute-git-dir)
check 'paused rebase really has autostash' test -s "$GD/rebase-merge/autostash"
check 'paused rebase has clean status' test -z "$(git -C "$WT/rebasing" status --porcelain)"
run remove-safe > "$T/audit"
check 'paused autostash rebase survives' test -d "$WT/rebasing"
check 'paused rebase KEEP' verdict "$WT/rebasing" KEEP
for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer AUTO_MERGE MERGE_AUTOSTASH autostash; do
  git -C "$MAIN" worktree add -q --detach "$WT/op-$marker" main
  gd=$(git -C "$WT/op-$marker" rev-parse --absolute-git-dir)
  case "$marker" in rebase-*|sequencer) mkdir -p "$gd/$marker" ;; *) git -C "$MAIN" rev-parse HEAD > "$gd/$marker" ;; esac
done
run remove-safe > "$T/audit"
for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer AUTO_MERGE MERGE_AUTOSTASH autostash; do
  check "$marker pending operation survives" test -d "$WT/op-$marker"
  check "$marker pending reason" reason "$WT/op-$marker" pending-operation
done

fresh identity
git -C "$MAIN" worktree add -q -b mixed "$WT/MixedCase" main
mkdir -p "$WT/MixedCase/nested"
if [[ -d $WT/mixedcase ]]; then
  (cd "$WT/mixedcase/nested" && /bin/bash "$TOOL" remove-safe > "$T/audit")
  check 'case alias current worktree survives' test -d "$WT/MixedCase"
  check 'case alias has current reason' reason "$WT/MixedCase" current-worktree
else
  printf 'SKIP: case-insensitive directory identity (filesystem is case-sensitive)\n'
fi
# A nested repository changes --show-toplevel; containment must still protect it.
git init -q "$WT/MixedCase/nested/repo"
(cd "$WT/MixedCase/nested/repo" && /bin/bash "$TOOL" audit > "$T/audit")
check 'containing worktree has current reason' reason "$WT/MixedCase" current-worktree

fresh deleted-remote
git -C "$MAIN" worktree add -q -b side "$WT/side" main
printf 'side\n' >> "$WT/side/file"
git -C "$WT/side" commit -qam side
git -C "$WT/side" push -q origin side
git -C "$WT/side" checkout -q --detach
git --git-dir="$SERVER" update-ref -d refs/heads/side
run remove-safe > "$T/audit"
check 'deleted server branch cannot authorize detached removal' test -d "$WT/side"
check 'deleted server branch KEEP' verdict "$WT/side" KEEP

fresh rollback
BASE=$(git -C "$MAIN" rev-parse HEAD)
printf 'later\n' >> "$MAIN/file"
git -C "$MAIN" commit -qam later
git -C "$MAIN" push -q origin main
git -C "$MAIN" worktree add -q -b rolled-back "$WT/rolled-back" main
git --git-dir="$SERVER" update-ref refs/heads/main "$BASE"
run remove-safe > "$T/audit"
check 'server rollback cannot authorize removal' test -d "$WT/rolled-back"
check 'server rollback KEEP' verdict "$WT/rolled-back" KEEP

fresh stale-default
git -C "$MAIN" worktree add -q -b side "$WT/side" main
printf 'side\n' >> "$WT/side/file"
git -C "$WT/side" commit -qam side
git -C "$WT/side" push -q origin side
git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/side
git -C "$MAIN" fetch -q --prune origin
run remove-safe > "$T/audit"
check 'stale symbolic default cannot authorize removal' test -d "$WT/side"
check 'stale symbolic default KEEP' verdict "$WT/side" KEEP

fresh named-detached
git -C "$MAIN" worktree add -q -b detached "$WT/named" main
printf 'side\n' >> "$WT/named/file"
git -C "$WT/named" commit -qam side
git -C "$WT/named" push -q origin detached
run remove-safe > "$T/audit"
check 'unmerged branch named detached survives' test -d "$WT/named"
check 'branch named detached KEEP' verdict "$WT/named" KEEP

fresh submodules
git init -q "$T/submodule-source"
printf '.env\n' > "$T/submodule-source/.gitignore"
git -C "$T/submodule-source" add .gitignore
git -C "$T/submodule-source" commit -qm module
git -C "$MAIN" -c protocol.file.allow=always submodule add -q "$T/submodule-source" module
git -C "$MAIN" commit -qam submodule
git -C "$MAIN" push -q origin main
git -C "$MAIN" worktree add -q -b module-tree "$WT/module-tree" main
git -C "$WT/module-tree" -c protocol.file.allow=always submodule update --init -q
printf 'private\n' > "$WT/module-tree/module/.env"
# Git status hides both ordinary files and dotfiles inside an uninitialized
# gitlink. These pushed, otherwise clean trees must never become candidates.
for file in notes.txt .env; do
  tree=$WT/uninitialized-$file
  git -C "$MAIN" worktree add -q -b "uninitialized-$file" "$tree" main
  printf 'precious local data\n' > "$tree/module/$file"
  check "uninitialized $file has no module .git" test ! -e "$tree/module/.git"
  check "uninitialized $file is hidden from status" test -z "$(git -C "$tree" status --porcelain=v1 --ignored --untracked-files=all --ignore-submodules=none)"
done
run remove-safe > "$T/audit" 2> "$T/submodule.err"
check 'initialized submodule KEEP' verdict "$WT/module-tree" KEEP
check 'initialized submodule reason' reason "$WT/module-tree" submodule
check 'ignored submodule file survives' test -f "$WT/module-tree/module/.env"
for file in notes.txt .env; do
  tree=$WT/uninitialized-$file
  check "uninitialized $file KEEP" verdict "$tree" KEEP
  check "uninitialized $file has only submodule reason" test "$(field "$tree" 10)" = submodule
  check "uninitialized $file survives removal" test -f "$tree/module/$file"
done

fresh durable-log
git -C "$MAIN" worktree add -q -b logged "$WT/logged" main
(cd "$MAIN" && PATH="$T/bin:$PATH" CHECK_INTENT="$T/intent-checked" /bin/bash "$TOOL" remove-safe > "$T/audit")
check 'flushed intent readable before removal starts' grep -q 'intent verified before removal' "$T/intent-checked"
check 'intent permits successful removal' test ! -d "$WT/logged"
LOG=$HOME/.megavibe/worktrees-audit-removals.jsonl
check 'removal without hook creates durable log' test -s "$LOG"
check 'durable event has required fields' perl -MJSON::PP -e '
  open my $f, "<", $ARGV[0] or exit 1; my @lines=<$f>; @lines == 2 or exit 1;
  my @status=("intent", "removed");
  for my $line (@lines) {
    my $e=decode_json($line); for (qw(time repo path branch sha size status)) { exists $e->{$_} or exit 1 }
    $e->{status} eq shift(@status) && $e->{path} eq $ARGV[1] && $e->{branch} eq "logged"
      && $e->{sha} =~ /^[0-9a-f]+$/ && $e->{size} > 0 or exit 1;
  }
' "$LOG" "$WT/logged"
check 'durable log mode is private' perl -e 'exit !(((stat $ARGV[0])[2] & 0777) == 0600)' "$LOG"
# The override and JSON escaping work without a project hook, too.
git -C "$MAIN" worktree add -q -b quoted "$WT/quote\"and
newline" main
(cd "$MAIN" && MEGAVIBE_HOME="$HOME/custom-log" /bin/bash "$TOOL" remove-safe > "$T/audit")
check 'custom log destination and JSON escaping' perl -MJSON::PP -e '
  open my $f, "<", $ARGV[0] or exit 1; my @lines=<$f>; @lines == 2 or exit 1;
  for (@lines) { decode_json($_)->{path} eq $ARGV[1] or exit 1 }
' "$HOME/custom-log/worktrees-audit-removals.jsonl" "$WT/quote\"and
newline"

fresh rejected-append
git -C "$MAIN" worktree add -q -b safe "$WT/safe" main
mkdir -p "$HOME/.megavibe"
LOG=$HOME/.megavibe/worktrees-audit-removals.jsonl
: > "$LOG"
: > "$T/append-trace"
(cd "$MAIN" && PATH="$T/bin:$PATH" READONLY_LOG="$LOG" TRACE_GIT="$T/append-trace" \
  /bin/bash "$TOOL" remove-safe > "$T/audit" 2> "$T/append.err")
check 'rejected append preserves worktree' test -d "$WT/safe"
check 'rejected append reports KEEP log-write-failed' awk -F '\t' -v p="$WT/safe" \
  '$1 == p && $9 == "KEEP" && $10 == "log-write-failed" {found=1} END {exit !found}' "$T/audit"
check 'rejected append never calls remove' awk '/ worktree remove / {bad=1} END {exit bad}' "$T/append-trace"
check 'rejected append frees nothing' grep -q '^Freed: 0 KiB' "$T/audit"
check 'rejected append leaves log empty' test ! -s "$LOG"
check 'rejected append reaches real encoder write' grep -Eq 'log (write|flush|close):' "$T/append.err"

fresh unwritable-log
git -C "$MAIN" worktree add -q -b safe "$WT/safe" main
mkdir -p "$HOME/.megavibe"
chmod 500 "$HOME/.megavibe"
if run remove-safe > "$T/audit" 2> "$T/log-error"; then rc=0; else rc=$?; fi
chmod 700 "$HOME/.megavibe"
check 'unwritable log refuses command' test "$rc" != 0
check 'unwritable log removes nothing' test -d "$WT/safe"
check 'unwritable log clear message' grep -Ei -q 'removal log.*(writ|open)|writ.*removal log' "$T/log-error"
: > "$HOME/.megavibe/worktrees-audit-removals.jsonl"
chmod 400 "$HOME/.megavibe/worktrees-audit-removals.jsonl"
if run remove-safe > "$T/audit" 2> "$T/log-error"; then rc=0; else rc=$?; fi
check 'unwritable existing log refuses command' test "$rc" != 0
check 'unwritable existing log removes nothing' test -d "$WT/safe"
chmod 600 "$HOME/.megavibe/worktrees-audit-removals.jsonl"

fresh remote-failure
git -C "$MAIN" worktree add -q -b safe "$WT/safe" main
for failure in fetch ls-remote; do
  (cd "$MAIN" && PATH="$T/bin:$PATH" FAIL_GIT=$failure /bin/bash "$TOOL" remove-safe > "$T/audit" 2>/dev/null)
  check "$failure failure removes nothing" test -d "$WT/safe"
  check "$failure failure remote-unverified" reason "$WT/safe" remote-unverified
done
# Offline mode is accepted and never touches the remote.
: > "$T/offline-trace"
if (cd "$MAIN" && PATH="$T/bin:$PATH" TRACE_GIT="$T/offline-trace" /bin/bash "$TOOL" remove-safe --offline > "$T/audit" 2> "$T/offline.err"); then rc=0; else rc=$?; fi
check 'offline option accepted' test "$rc" = 0
check 'offline removes nothing' test -d "$WT/safe"
check 'offline remote-unverified' reason "$WT/safe" remote-unverified
check 'offline skips fetch and ls-remote' awk '/ (fetch|ls-remote) / {bad=1} END {exit bad}' "$T/offline-trace"
run audit --offline > "$T/audit"
check 'offline audit also keeps safe tree' verdict "$WT/safe" KEEP
git --git-dir="$SERVER" symbolic-ref HEAD refs/heads/missing
run remove-safe > "$T/audit"
check 'unverifiable server default removes nothing' test -d "$WT/safe"
check 'unverifiable server default reason' reason "$WT/safe" remote-unverified
git -C "$MAIN" remote remove origin
run remove-safe > "$T/audit"
check 'no remote is unverified' reason "$WT/safe" remote-unverified

fresh recheck-remote
git -C "$MAIN" worktree add -q -b safe "$WT/safe" main
(cd "$MAIN" && PATH="$T/bin:$PATH" FETCH_COUNT="$T/fetch-count" /bin/bash "$TOOL" remove-safe > "$T/audit")
check 'remote recheck failure removes nothing' test -d "$WT/safe"
check 'remote verified again before removal' test "$(cat "$T/fetch-count")" = 2
check 'remote recheck reports KEEP' awk -F '\t' -v p="$WT/safe" '$1 == p && $9 == "KEEP" && $10 ~ /remote-unverified/ {found=1} END {exit !found}' "$T/audit"

fresh multiple-remotes
git clone -q --bare "$SERVER" "$T/second-server.git"
git -C "$MAIN" remote add backup "$T/second-server.git"
git -C "$MAIN" worktree add -q -b side "$WT/side" main
printf 'side\n' >> "$WT/side/file"
git -C "$WT/side" commit -qam side
git -C "$WT/side" push -q backup side
git -C "$WT/side" checkout -q --detach
run audit > "$T/audit"
check 'verified second remote supplies reachability' verdict "$WT/side" SAFE
git --git-dir="$T/second-server.git" update-ref -d refs/heads/side
run remove-safe > "$T/audit"
check 'second remote is pruned before removal' test -d "$WT/side"
check 'deleted second remote branch KEEP' verdict "$WT/side" KEEP
git -C "$MAIN" remote set-url backup "$T/no-such-remote.git"
run audit > "$T/audit"
check 'unavailable secondary remote fails closed' reason "$WT/side" remote-unverified

fresh fetch-scope
git -C "$MAIN" worktree add -q -b safe "$WT/safe" main
git -C "$MAIN" branch preserved
git -C "$MAIN" tag preserved-tag
BASE=$(git -C "$MAIN" rev-parse preserved)
git -C "$MAIN" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
git -C "$MAIN" config fetch.pruneTags true
git -C "$MAIN" config remote.origin.pruneTags true
run audit > "$T/audit"
check 'explicit fetch scope still verifies remote' verdict "$WT/safe" SAFE
check 'fetch does not prune local branch' test "$(git -C "$MAIN" rev-parse preserved)" = "$BASE"
check 'fetch does not prune local tag' test "$(git -C "$MAIN" rev-parse preserved-tag)" = "$BASE"

fresh timeout
git -C "$MAIN" worktree add -q -b safe "$WT/safe" main
for command in fetch ls-remote; do
  started=$SECONDS
  (cd "$MAIN" && PATH="$T/bin:$PATH" SLOW_GIT=$command /bin/bash "$TOOL" audit > "$T/audit")
  elapsed=$((SECONDS - started))
  check "$command times out within bound" test "$elapsed" -lt 60
  check "$command timeout KEEP" verdict "$WT/safe" KEEP
  check "$command timeout reason" reason "$WT/safe" remote-unverified
done

HOME=$SAVED_HOME MAIN=$SAVED_MAIN WT=$SAVED_WT

mkdir -p "$T/scratch/old/repo/.git" "$T/scratch/old/venv" "$T/scratch/recent"
printf 'venv\n' > "$T/scratch/old/venv/pyvenv.cfg"
dd if=/dev/zero of="$T/scratch/old/repo/data" bs=1024 count=32 2>/dev/null
touch -t 200001010000 "$T/scratch/old"
run scratch --days 3 --root "$T/scratch" > "$T/scratch-report"
check 'old scratch directory reported' grep -q "$T/scratch/old$" "$T/scratch-report"
check 'recent scratch directory omitted' bash -c '! grep -q "$1" "$2"' _ "$T/scratch/recent" "$T/scratch-report"
check 'repo copy reported' grep -q "$T/scratch/old/repo$" "$T/scratch-report"
check 'virtualenv reported' grep -q "$T/scratch/old/venv$" "$T/scratch-report"
check 'scratch remains intact' test -f "$T/scratch/old/repo/data"
for i in 1 2 3 4 5 6; do mkdir -p "$T/scratch/old/copy-$i/.git"; done
touch -t 200001010000 "$T/scratch/old"
run scratch --days 3 --root "$T/scratch" > "$T/top-five"
check 'top five limit' awk '/TOP_5_/ {seen=1; next} seen {n++} END {exit n != 5}' "$T/top-five"
check 'top five sorted largest first' awk '/TOP_5_/ {seen=1; prev=1e30; next} seen {if ($1 > prev) bad=1; prev=$1} END {exit bad}' "$T/top-five"
for dir in .cache/uv .cache/huggingface .colima .pyenv Library/Caches; do mkdir -p "$HOME/$dir"; done
run caches > "$T/caches"
check 'five caches plus command' test "$(wc -l < "$T/caches" | tr -d ' ')" = 6
check 'sanctioned uv command' grep -q 'uv cache prune' "$T/caches"
check 'cache preserved' test -d "$HOME/.cache/uv"
run --help > "$T/help"
check 'help explains immediate deletion' grep -q 'does NOT go through the Trash' "$T/help"
# --- grafts, replace refs and inherited Git overrides (fresh fixtures) ---
SAVED_HOME=$HOME SAVED_MAIN=$MAIN SAVED_WT=$WT
reason_is() { [[ $(field "$1" 10) == "$2" ]]; }
fresh grafts
git -C "$MAIN" worktree add -q -b g1 "$WT/g1" main
git -C "$MAIN" worktree add -q -b lw "$WT/lw" main
printf 'local\n' > "$WT/lw/l"; git -C "$WT/lw" add l; git -C "$WT/lw" commit -qm local-only
run audit > "$T/audit"
check 'control: clean pushed tree is SAFE' verdict "$WT/g1" SAFE
check 'control: local-only commit is unpushed' reason "$WT/lw" unpushed
mkdir -p "$MAIN/.git/info"
printf '%s %s\n' "$(git -C "$MAIN" rev-parse origin/main)" "$(git -C "$WT/lw" rev-parse HEAD)" > "$MAIN/.git/info/grafts"
run audit > "$T/audit"
check 'grafted local commit is KEEP' verdict "$WT/lw" KEEP
check 'grafts make a clean tree KEEP' verdict "$WT/g1" KEEP
check 'grafts reason' reason_is "$WT/g1" grafts
: > "$MAIN/.git/info/grafts"
run audit > "$T/audit"
check 'empty grafts file is still KEEP' reason_is "$WT/g1" grafts
run remove-safe > "$T/removed"
check 'grafts: remove-safe removes nothing' test -d "$WT/g1"
mv "$MAIN/.git/info/grafts" "$T/grafts-off"
run audit > "$T/audit"
check 'grafts file gone: SAFE again' verdict "$WT/g1" SAFE
ZERO=$(git -C "$MAIN" commit-tree "$(git -C "$MAIN" rev-parse 'main^{tree}')" -m replacement)
git -C "$MAIN" replace "$(git -C "$MAIN" rev-parse main)" "$ZERO"
run audit > "$T/audit"
check 'replace ref makes a clean tree KEEP' reason_is "$WT/g1" replace-refs
run remove-safe > "$T/removed"
check 'replace ref: remove-safe removes nothing' test -d "$WT/g1"
git -C "$MAIN" replace -d "$(git -C "$MAIN" rev-parse main)" >/dev/null
run audit > "$T/audit"
check 'replace ref deleted: SAFE again' verdict "$WT/g1" SAFE

# An external graft file must not fake reachability, detached or named.
fresh ext-graft
git -C "$MAIN" worktree add -q --detach "$WT/dg" main
printf 'local\n' > "$WT/dg/l"; git -C "$WT/dg" add l; git -C "$WT/dg" commit -qm local-only
git -C "$MAIN" worktree add -q -b ng "$WT/ng" main
printf 'local\n' > "$WT/ng/l"; git -C "$WT/ng" add l; git -C "$WT/ng" commit -qm local-only
printf '%s %s\n' "$(git -C "$MAIN" rev-parse origin/main)" "$(git -C "$WT/dg" rev-parse HEAD)" > "$T/ext-grafts"
GIT_GRAFT_FILE="$T/ext-grafts" run audit > "$T/audit"
check 'external GIT_GRAFT_FILE: detached local commit stays KEEP' reason "$WT/dg" detached-not-on-remote
GIT_GRAFT_FILE="$T/ext-grafts" run remove-safe > "$T/removed"
check 'external GIT_GRAFT_FILE: detached worktree not removed' test -d "$WT/dg"
printf '%s %s\n' "$(git -C "$MAIN" rev-parse origin/main)" "$(git -C "$WT/ng" rev-parse HEAD)" > "$T/ext-grafts"
GIT_GRAFT_FILE="$T/ext-grafts" run audit > "$T/audit"
check 'external GIT_GRAFT_FILE: named local commit stays unpushed' reason "$WT/ng" unpushed

# Injected configuration must not redirect origin to a remote that has the commit.
fresh ext-config
git -C "$MAIN" worktree add -q -b lc "$WT/lc" main
printf 'local\n' > "$WT/lc/l"; git -C "$WT/lc" add l; git -C "$WT/lc" commit -qm local-only
git clone -q --bare "$SERVER" "$T/decoy.git"
git -C "$WT/lc" push -q "$T/decoy.git" lc:main
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0="$T/decoy.git" run audit > "$T/audit"
check 'GIT_CONFIG_COUNT cannot redirect origin' verdict "$WT/lc" KEEP
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0="$T/decoy.git" run remove-safe > "$T/removed"
check 'GIT_CONFIG_COUNT: worktree not removed' test -d "$WT/lc"
GIT_CONFIG_PARAMETERS="'remote.origin.url'='$T/decoy.git'" run audit > "$T/audit"
check 'GIT_CONFIG_PARAMETERS cannot redirect origin' verdict "$WT/lc" KEEP
HOME=$SAVED_HOME MAIN=$SAVED_MAIN WT=$SAVED_WT

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL == 0 ]]
