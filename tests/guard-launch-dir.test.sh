#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-guard-launch.XXXXXX")
trap '/bin/rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
export HOME="$T/home" MEGAVIBE_INIT_SKIP_HEAL=1
unset MEGAVIBE_HOME MEGAVIBE_ALLOW_KILL MEGAVIBE_ALLOW_REMOVE_LAUNCH CLAUDE_PROJECT_DIR TMUX
WRAPPER="$HOME/.megavibe/scripts/guard-run.sh"
HOOKS="$REPO/template/.claude/hooks"
mkdir -p "$HOME/.megavibe/"{scripts,template/.claude} "$T/recreated/.agent" "$T/project/.claude/hooks"
cp -R "$HOOKS" "$HOME/.megavibe/template/.claude/"
if [ -f "$REPO/scripts/guard-run.sh" ]; then cp "$REPO/scripts/guard-run.sh" "$WRAPPER"; fi
mv "$T/project/.claude/hooks" "$T/old-hooks"

PASS=0 FAIL=0
check() {
  local label="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    printf 'PASS %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n' "$label"
  fi
}
payload() {
  jq -n --arg cwd "$1" --arg cmd "$2" \
    '{cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$cmd}}'
}
verdict() {
  [ "$RC" = "$1" ] && [[ "$OUT" == *"${2:-}"* ]] || {
    printf '  got status %s, output %s\n' "$RC" "$OUT"
    return 1
  }
}
wrapped() {
  local cwd="$1" hook="$2" command="$3"
  RC=0
  OUT=$(cd "$cwd" && payload "$cwd" "$command" | "$WRAPPER" "$hook" 2>&1) || RC=$?
}

wrapped "$T/recreated" /nonexistent/proj/.claude/hooks/block-dangerous-bash.sh 'sudo pkill -9 node'
check 'fallback blocks from recreated launch directory' verdict 2 'Blocked:'
check 'fallback names the template copy' verdict 2 'guard block-dangerous-bash.sh: project copy missing, running the template copy'
wrapped "$T/project" "$T/project/.claude/hooks/block-dangerous-bash.sh" 'sudo pkill -9 node'
check 'fallback blocks when the hooks directory is gone' verdict 2 'Blocked:'
wrapped "$T/recreated" /nonexistent/proj/.claude/hooks/block-dangerous-bash.sh 'echo hello'
check 'fallback allows benign input' verdict 0
wrapped "$T/recreated" /nonexistent/proj/.claude/hooks/missing.sh 'echo hello'
check 'missing project and template guards fail closed' verdict 2 'missing.sh'
wrapped "$T/recreated" ../x 'echo hello'
check 'invalid basename fails closed' verdict 2 'invalid'
wrapped "$T/recreated" /nonexistent/proj/.claude/hooks/invalid..sh 'echo hello'
check 'basename containing two dots fails closed' verdict 2 'invalid'
wrapped "$T/recreated" /nonexistent/proj/.claude/hooks/subdir/ 'echo hello'
check 'trailing slash leaves an invalid fallback name' verdict 2 'invalid'

printf '#!/bin/bash\nread -r line\nprintf "%%s %%s\\n" "$1" "$line"\nexit 7\n' > "$T/probe.sh"
chmod +x "$T/probe.sh"
RC=0
OUT=$(printf 'payload\n' | "$WRAPPER" "$T/probe.sh" argument 2>&1) || RC=$?
check 'project executable receives stdin and arguments and returns its own status' verdict 7 'argument payload'

settings_match() {
  local project="$1" runner="$2"
  jq -e --arg root "$project" --arg runner "$runner" \
    --slurpfile template "$REPO/template/.claude/settings.json" '
    def commands: [.hooks | to_entries[] | .key as $event | .value[] |
      .hooks[] | [$event, .command]];
    commands == ($template[0] | commands | map(
      .[1] as $path |
      .[1] = ((if .[0] == "PreToolUse" and ($path | test("/(block-dangerous-bash|rm-to-trash|enforce-pr-format|block-stray-working-context|block-permission-hooks)\\.sh$"))
               then $runner else "" end) + "\"" + $root + "/" + $path + "\"")
    ))' "$project/.claude/settings.json" >/dev/null
}
runner='"$HOME/.megavibe/scripts/guard-run.sh" '
mkdir -p "$T/init-home" "$T/fresh project" "$T/existing/.claude" "$T/plain" "$T/plain-home/.megavibe"
printf '{"permissions":{"allow":["Read"]}}\n' > "$T/existing/.claude/settings.json"
touch "$T/plain-home/.megavibe/scripts"
for project in "$T/fresh project" "$T/existing"; do
  HOME="$T/init-home" bash "$REPO/init.sh" "$project" > "$T/init.log" 2>&1
  check "init registers only blocking guards via the wrapper (${project##*/})" settings_match "$project" "$runner"
  cp "$project/.claude/settings.json" "$T/settings.before"
  HOME="$T/init-home" bash "$REPO/init.sh" "$project" > "$T/init.log" 2>&1
  check "second init is byte-identical (${project##*/})" cmp -s "$T/settings.before" "$project/.claude/settings.json"
done
check 'init installs an executable wrapper' test -x "$T/init-home/.megavibe/scripts/guard-run.sh"
HOME="$T/plain-home" bash "$REPO/init.sh" "$T/plain" > "$T/init.log" 2> "$T/init.err"
check 'init uses plain absolute paths when installation is impossible' settings_match "$T/plain" ''
check 'init warns on stderr when the wrapper cannot be installed' grep -Fxq \
  "guard-run.sh not installed: PreToolUse guards fall back to plain hook paths and fail open if the project's .claude is removed" "$T/init.err"

mkdir -p "$T/repo/.agent"
git -C "$T/repo" init -q
git -C "$T/repo" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm Initial
(cd "$T/repo" && bash "$REPO/megavibe" worktree review) > "$T/worktree.log" 2>&1
mkdir -p "$T/repo-review/sub" "$T/bin"
export REAL_GIT=$(command -v git)
cat > "$T/bin/git" <<'STUB'
#!/bin/bash
if [ "${1:-} ${2:-}" = 'worktree remove' ]; then
  echo 'Unexpected attempt to remove a fixture worktree' >&2
  exit 99
fi
exec "$REAL_GIT" "$@"
STUB
cat > "$T/bin/rm" <<'STUB'
#!/bin/bash
echo 'Unexpected attempt to delete a fixture file' >&2
exit 99
STUB
chmod +x "$T/bin/"*
RC=0
OUT=$(cd "$T/repo-review/sub" && PATH="$T/bin:$PATH" bash "$REPO/megavibe" worktree remove review 2>&1) || RC=$?
check 'launcher refuses from inside the target worktree' verdict 1 'current directory'
RC=0
OUT=$(cd "$T/repo" && CLAUDE_PROJECT_DIR="$T/repo-review/sub" PATH="$T/bin:$PATH" bash "$REPO/megavibe" worktree remove review 2>&1) || RC=$?
check 'launcher refuses from outside the launch worktree' verdict 1 'launch directory'

guard() {
  RC=0
  OUT=$(payload "${3:-$T}" "$1" | CLAUDE_PROJECT_DIR="${4-$T/repo-review}" \
    MEGAVIBE_ALLOW_REMOVE_LAUNCH="${2:-0}" bash "$HOOKS/block-dangerous-bash.sh" 2>&1) || RC=$?
}

git -C "$T/repo" worktree add --detach -q "$T/repo-other" HEAD
git -C "$T/repo" config core.ignorecase true
mkdir "$T/repo/repo-review"
for command in \
  'git worktree remove repo-review' \
  'git worktree remove -- ./repo-review' \
  'git worktree remove repo-review/' \
  'git worktree remove REPO-REVIEW' \
  'git worktree remove repo-other' \
  "git worktree remove '$T/repo-review'" \
  "git -C '$T/repo' worktree remove --force -- repo-other" \
  "cd '$T/repo' && git -C . worktree remove repo-other" \
  'MEGAVIBE_ALLOW_REMOVE_LAUNCH=1 git worktree remove repo-review' \
  'env MEGAVIBE_ALLOW_REMOVE_LAUNCH=1 git worktree remove repo-review' \
  'export MEGAVIBE_ALLOW_REMOVE_LAUNCH=1; git worktree remove repo-review'; do
  guard "$command" 0 "$T/repo"
  check "linked launch blocks ${command//"$T"/<scratch>}" verdict 2 'Finish and exit this session'
done
guard 'git worktree prune' 0 "$T/repo-review"
check 'linked launch allows git worktree prune' verdict 0
guard 'git worktree remove repo-review' 1 "$T/repo"
check 'linked launch honors the hook environment override' verdict 0
guard 'git worktree remove repo-review' 0 "$T/repo" "$T/repo"
check 'main checkout launch allows git worktree remove' verdict 0
guard 'git worktree remove repo-review' 0 "$T/repo" "$T/missing"
check 'missing launch directory allows git worktree remove' verdict 0
guard 'git worktree remove repo-review' 0 "$T/repo" "$T"
check 'non-Git launch directory allows git worktree remove' verdict 0

ln -s "$T/repo-review" "$T/launch-link"
touch "$T/repo-review/file"
mkdir -p "$T/other/nested" "$T/target"
for command in \
  "rm -r '$T/repo-review'" \
  "rm -rf '$T/repo-review/..'" \
  'rm -r launch-link' \
  'rm -r repo-review' \
  "cd 'other/nested' && rm -r ../../repo-review" \
  'mv repo-review x' \
  'mv -- other repo-review x' \
  'mv -t other repo-review' \
  'mv -ttarget repo-review' \
  'mv --target-directory=other repo-review' \
  'trash.sh repo-review' \
  '~/.megavibe/scripts/trash.sh repo-review' \
  'rmtrash repo-review' \
  'MEGAVIBE_ALLOW_REMOVE_LAUNCH=1 rm -r repo-review' \
  'env MEGAVIBE_ALLOW_REMOVE_LAUNCH=1 mv repo-review x' \
  'export MEGAVIBE_ALLOW_REMOVE_LAUNCH=1; rmtrash repo-review'; do
  guard "$command"
  check "launch path blocks ${command//"$T"/<scratch>}" verdict 2 'Finish and exit this session'
done
for command in 'rm repo-review/file' 'rm -r other' 'rm missing/..' \
  'mv other x' 'mv other repo-review' 'mv -t repo-review other' \
  'echo rm -r repo-review' 'command -v rm repo-review'; do
  guard "$command"
  check "launch path allows $command" verdict 0
done
guard 'rm ""' 0 "$T/repo-review"
check 'empty operand does not match the launch directory' verdict 0
if [[ "$T/REPO-REVIEW" -ef "$T/repo-review" ]]; then
  guard 'rm -r REPO-REVIEW'
  check 'launch path matches a case variant on a case-insensitive volume' verdict 2 'Finish and exit this session'
fi
guard 'rm -r repo-review' 1
check 'launch path honors the hook environment override' verdict 0
guard 'rm -r repo' 0 "$T" "$T/repo"
check 'launch path protects the main checkout too' verdict 2 'Finish and exit this session'
guard 'rm -r other' 0 "$T" "$T/other"
check 'launch path protects a non-Git project too' verdict 2 'Finish and exit this session'
guard 'rm -r repo-review' 0 "$T" "$T/launch-link"
check 'launch path resolves a symlinked project directory' verdict 2 'Finish and exit this session'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
