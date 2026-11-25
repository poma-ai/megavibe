#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-guard-launch.XXXXXX")
trap '/bin/rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
export HOME="$T/home" MEGAVIBE_INIT_SKIP_HEAL=1
unset MEGAVIBE_HOME MEGAVIBE_ALLOW_KILL MEGAVIBE_ALLOW_REMOVE_LAUNCH MEGAVIBE_ALLOW_MISSING_LAUNCH CLAUDE_PROJECT_DIR TMUX
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
  local cwd="$1" hook="$2" command="$3" tool="${4:-Bash}"
  RC=0
  OUT=$(cd "$cwd" && {
    if [ "$tool" = Bash ]; then
      payload "$cwd" "$command"
    else
      jq -n --arg cwd "$cwd" --arg tool "$tool" --arg path "$cwd/example.txt" \
        '{cwd:$cwd, hook_event_name:"PreToolUse", tool_name:$tool,
          tool_input:{file_path:$path, content:"test", old_string:"old", new_string:"new"}}'
    fi
  } | "$WRAPPER" "$hook" 2>&1) || RC=$?
}

tripwire='launch directory or its .claude is gone: finish and exit this session; the guards cannot be trusted here; start a new session from a project directory'
mkdir -p "$T/moved/.claude/hooks" "$T/empty/.claude/hooks" "$T/deleted" "$T/intact/.claude/hooks"
mv "$T/moved" "$T/moved-away"
mv "$T/empty" "$T/empty-away"
mkdir "$T/empty"
rmdir "$T/deleted"
for name in block-dangerous-bash rm-to-trash enforce-pr-format block-stray-working-context block-permission-hooks; do
  tool=Bash
  case "$name" in
    block-stray-working-context) tool=Write ;;
    block-permission-hooks) tool=Edit ;;
  esac
  for root in moved empty recreated deleted project; do
    wrapped "$T" "$T/$root/.claude/hooks/$name.sh" 'echo hello' "$tool"
    check "tripwire blocks $name ($root)" verdict 2 "$tripwire"
  done
done
missing="$T/deleted/.claude/hooks/block-dangerous-bash.sh"
wrapped "$T" "$missing" 'MEGAVIBE_ALLOW_MISSING_LAUNCH=1 echo hello'
check 'command text cannot bypass the tripwire' verdict 2 "$tripwire"
RC=0
OUT=$(payload "$T" 'echo hello' | jq '.MEGAVIBE_ALLOW_MISSING_LAUNCH = "1"' | "$WRAPPER" "$missing" 2>&1) || RC=$?
check 'payload field cannot bypass the tripwire' verdict 2 "$tripwire"
MEGAVIBE_ALLOW_MISSING_LAUNCH=1 wrapped "$T" "$missing" 'sudo pkill -9 node'
check 'hook environment allows template fallback with a guarded payload' verdict 2 'Blocked:'
check 'fallback names the template copy' verdict 2 'guard block-dangerous-bash.sh: project copy missing, running the template copy'
MEGAVIBE_ALLOW_MISSING_LAUNCH=1 wrapped "$T" "$missing" 'echo hello'
check 'hook environment allows template fallback with a benign payload' verdict 0 'running the template copy'
wrapped "$T" "$T/intact/.claude/hooks/block-dangerous-bash.sh" 'echo hello'
check 'single missing hook falls back and allows benign input' verdict 0 'running the template copy'
wrapped "$T" "$T/intact/.claude/hooks/block-dangerous-bash.sh" 'sudo pkill -9 node'
check 'single missing hook falls back and blocks guarded input' verdict 2 'Blocked:'
wrapped "$T" "$T/intact/.claude/hooks/missing.sh" 'echo hello'
check 'missing project and template guards fail closed' verdict 2 'no executable project or template copy found'
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

cp "$T/probe.sh" "$T/intact/.claude/hooks/probe.sh"
mkdir "$T/deleted-cwd"
run_probe() (
  case "$1" in
    elsewhere) export CLAUDE_PROJECT_DIR="$T/recreated" ;;
    missing)
      export CLAUDE_PROJECT_DIR="$T/deleted"
      cd "$T/deleted-cwd" && rmdir "$T/deleted-cwd"
      ;;
  esac
  exec "$WRAPPER" "$T/intact/.claude/hooks/probe.sh" argument
)
for project_env in unset elsewhere missing; do
  RC=0
  OUT=$(printf 'payload\n' | run_probe "$project_env" 2>&1) || RC=$?
  check "registered executable runs with project environment $project_env" verdict 7 'argument payload'
done

# The registered path can belong to a different checkout with shared settings.
for root in moved empty deleted; do
  CLAUDE_PROJECT_DIR="$T/$root" wrapped "$T" "$T/intact/.claude/hooks/block-dangerous-bash.sh" 'echo hello'
  check "session-root tripwire blocks after launch directory is $root" verdict 2 "$tripwire"
done
CLAUDE_PROJECT_DIR="$T/intact" wrapped "$T" "$missing" 'echo hello'
check 'session hooks directory with a missing file uses the template' verdict 0 'running the template copy'
CLAUDE_PROJECT_DIR="$T/deleted" MEGAVIBE_ALLOW_MISSING_LAUNCH=1 wrapped "$T" "$missing" 'echo hello'
check 'hook environment bypasses the session-root tripwire' verdict 0 'running the template copy'
RC=0
OUT=$(printf 'payload\n' | CLAUDE_PROJECT_DIR="$T/intact" "$WRAPPER" "$T/deleted/.claude/hooks/probe.sh" argument 2>&1) || RC=$?
check 'missing registration runs the session copy with stdin and arguments' verdict 7 'argument payload'

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
project="$T/fresh project"
registered=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(endswith("/block-dangerous-bash.sh\""))' "$project/.claude/settings.json")
RC=0
OUT=$(payload "$project" 'sudo pkill -9 node' | HOME="$T/init-home" bash -c "$registered" 2>&1) || RC=$?
check 'init-registered wrapper invokes the project guard' verdict 2 'Blocked:'
mv "$project/.claude" "$T/init-claude-away"
RC=0
OUT=$(payload "$project" 'echo hello' | HOME="$T/init-home" bash -c "$registered" 2>&1) || RC=$?
check 'init-registered wrapper trips after .claude is moved' verdict 2 "$tripwire"
HOME="$T/plain-home" bash "$REPO/init.sh" "$T/plain" > "$T/init.log" 2> "$T/init.err"
check 'init uses plain absolute paths when installation is impossible' settings_match "$T/plain" ''
check 'init warns on stderr when the wrapper cannot be installed' grep -Fxq \
  "guard-run.sh not installed: PreToolUse guards fall back to plain hook paths and fail open if the project's .claude is removed" "$T/init.err"

mkdir -p "$T/repo/.agent"
git -C "$T/repo" init -q
git -C "$T/repo" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm Initial
(cd "$T/repo" && bash "$REPO/megavibe" worktree review) > "$T/worktree.log" 2>&1
# A second linked worktree rewrites the main checkout's shared registrations.
HOME="$T/init-home" bash "$REPO/init.sh" "$T/repo" > "$T/init.log" 2>&1
git -C "$T/repo" worktree add --detach -q "$T/repo-feature" HEAD
ln -s "$T/repo/.claude" "$T/repo-feature/.claude"
HOME="$T/init-home" bash "$REPO/init.sh" "$T/repo-feature" > "$T/init.log" 2>&1
check 'linked worktree init writes its paths to shared settings' settings_match "$T/repo-feature" "$runner"
registered=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(endswith("/block-dangerous-bash.sh\""))' "$T/repo/.claude/settings.json")
mv "$T/repo-feature" "$T/repo-feature-away"
RC=0
OUT=$(payload "$T/repo" 'echo hello' | HOME="$T/init-home" CLAUDE_PROJECT_DIR="$T/repo" bash -c "$registered" 2>&1) || RC=$?
check 'main checkout allows benign input after the registered worktree moves' verdict 0 'running the session copy'
RC=0
OUT=$(payload "$T/repo" 'sudo pkill -9 node' | HOME="$T/init-home" CLAUDE_PROJECT_DIR="$T/repo" bash -c "$registered" 2>&1) || RC=$?
check 'main checkout still blocks guarded input after the registered worktree moves' verdict 2 'Blocked: pkill/killall'

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

guard "bash -c 'git worktree remove repo-other'"
check 'linked launch allows git worktree remove inside shell text' verdict 0

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
