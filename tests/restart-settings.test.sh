#!/bin/bash
# Real init/upgrade and the launcher's unchanged personal settings comparison.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-restart-settings.XXXXXX")
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
export HOME="$T/home with spaces" MEGAVIBE_INIT_SKIP_HEAL=1
export MEGAVIBE_HOME="$HOME/.megavibe"
unset MEGAVIBE_RESTART_PICKUP
mkdir -p "$MEGAVIBE_HOME/scripts" "$MEGAVIBE_HOME/personal"
PASS=0 FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }

# Simulate a project installed before the pickup registration existed.
cp "$REPO/init.sh" "$MEGAVIBE_HOME/init.sh"
cp "$REPO/scripts/guard-run.sh" "$MEGAVIBE_HOME/scripts/"
cp -R "$REPO/template" "$MEGAVIBE_HOME/template"
git -C "$REPO" show origin/main:template/.claude/settings.json > "$MEGAVIBE_HOME/template/.claude/settings.json"
rm -f "$MEGAVIBE_HOME/template/.claude/hooks/restart-pickup.sh"
PROJECT="$MEGAVIBE_HOME/personal"
SETTINGS="$PROJECT/.claude/settings.json"
bash "$MEGAVIBE_HOME/init.sh" "$PROJECT" > "$T/old-init.log" 2>&1
check 'older project has no pickup hook' '[ ! -e "$PROJECT/.claude/hooks/restart-pickup.sh" ]'

# These commands end in a hook path: suffix expansion used to corrupt both.
mkdir -p "$PROJECT/.claude/hooks"
printf '#!/bin/bash\nexit 0\n' > "$PROJECT/.claude/hooks/custom.sh"
jq --arg status '/opt/status/.claude/hooks/status.sh' --arg custom "$PROJECT/.claude/hooks/custom.sh" '
  .statusLine = {type:"command", command:$status}
  | .hooks.UserPromptSubmit = ([{hooks:[{type:"command", command:$custom}]}] + .hooks.UserPromptSubmit)
  | .env.RESTART_SETTINGS_TEST = "preserved"
' "$SETTINGS" > "$T/settings"
cp "$T/settings" "$SETTINGS"
jq -j '.statusLine.command' "$SETTINGS" > "$T/status-before"
jq -j '.hooks.UserPromptSubmit[0].hooks[0].command' "$SETTINGS" > "$T/custom-before"
jq -S . "$SETTINGS" > "$T/before"

# Exercise setup's actual full-template copy, including the new hook file.
{
  for function in resolve_link atomic_install_dir; do
    sed -n "/^$function() {/,/^}/p" "$REPO/setup.sh"
  done
  sed -n '/^atomic_install_dir "\$SCRIPT_DIR\/template" /p' "$REPO/setup.sh"
} > "$T/setup-template.sh"
SCRIPT_DIR="$REPO" bash "$T/setup-template.sh"
check 'setup deploys the executable pickup hook' 'cmp -s "$REPO/template/.claude/hooks/restart-pickup.sh" "$MEGAVIBE_HOME/template/.claude/hooks/restart-pickup.sh" && [ -x "$MEGAVIBE_HOME/template/.claude/hooks/restart-pickup.sh" ]'
bash "$MEGAVIBE_HOME/init.sh" "$PROJECT" > "$T/new-init.log" 2>&1
check 're-init installs the new registered hook in an older project' 'cmp -s "$PROJECT/.claude/hooks/restart-pickup.sh" "$REPO/template/.claude/hooks/restart-pickup.sh" && [ -x "$PROJECT/.claude/hooks/restart-pickup.sh" ]'
jq -j '.statusLine.command' "$SETTINGS" > "$T/status-after"
jq -j '.hooks.UserPromptSubmit[0].hooks[0].command' "$SETTINGS" > "$T/custom-after"
check 'preserved absolute statusLine is byte-identical after re-init' 'cmp -s "$T/status-before" "$T/status-after"'
check 'preserved custom hook command is byte-identical after re-init' 'cmp -s "$T/custom-before" "$T/custom-after"'
jq -S '.hooks.SessionStart |= map(select(any(.hooks[]; .command | contains("restart-pickup.sh")) | not))' "$SETTINGS" > "$T/after"
check 'upgrade changes only the new resume registration' 'cmp -s "$T/before" "$T/after"'
cp "$SETTINGS" "$T/once"
bash "$MEGAVIBE_HOME/init.sh" "$PROJECT" > "$T/repeat-init.log" 2>&1
check 'another init leaves all settings byte-identical' 'cmp -s "$T/once" "$SETTINGS"'

# Run the actual launcher sync block twice, without launching real Claude.
awk '/^if \[ -d "\$MEGAVIBE_HOME\/personal\/\.agent"/ {copy=1} copy {print} copy && /^fi$/ {exit}' "$REPO/megavibe" > "$T/personal-sync.sh"
check 'extracted the complete launcher comparison' 'grep -q "def expand" "$T/personal-sync.sh" && grep -q "personal-init.log" "$T/personal-sync.sh"'
bash "$T/personal-sync.sh" > "$T/first-sync.log" 2>&1
check 'first launch records a successful personal sync' '[ -s "$MEGAVIBE_HOME/.personal-synced" ] && grep -q "Syncing the personal" "$T/first-sync.log"'
bash "$T/personal-sync.sh" > "$T/second-sync.log" 2>&1
check 'second launch performs no personal sync' '[ ! -s "$T/second-sync.log" ] && cmp -s "$T/once" "$SETTINGS"'

# A fresh personal assistant must also satisfy both file and settings checks.
mv "$PROJECT" "$MEGAVIBE_HOME/older personal"
mkdir -p "$PROJECT"
bash "$MEGAVIBE_HOME/init.sh" "$PROJECT" > "$T/fresh-init.log" 2>&1
bash "$T/personal-sync.sh" > "$T/fresh-sync.log" 2>&1
check 'fresh personal project satisfies the launcher comparison immediately' '[ ! -s "$T/fresh-sync.log" ]'
bash "$T/personal-sync.sh" > "$T/fresh-second.log" 2>&1
check 'fresh personal project second launch performs no sync' '[ ! -s "$T/fresh-second.log" ]'

# A pipe whose writer remains open catches any attempt to read stdin. Poison
# PATH catches jq, cat, bash or any other subprocess on the ordinary path.
python3 - "$PROJECT/.claude/hooks/restart-pickup.sh" "$T" <<'PY'
import os, pathlib, subprocess, sys
hook, tmp = map(pathlib.Path, sys.argv[1:])
poison = tmp / 'poison'
poison.mkdir()
calls = tmp / 'unexpected-subprocess'
for name in ('jq', 'cat', 'bash', 'dirname'):
    stub = poison / name
    stub.write_text('#!/bin/bash\necho called >> "$CALLS"\nexit 99\n')
    stub.chmod(0o755)
for value in (None, ''):
    env = dict(os.environ, PATH=str(poison), CALLS=str(calls))
    env.pop('MEGAVIBE_RESTART_PICKUP', None)
    if value is not None:
        env['MEGAVIBE_RESTART_PICKUP'] = value
    read, write = os.pipe()
    try:
        proc = subprocess.Popen(['/bin/bash', str(hook)], stdin=read,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        try:
            out, err = proc.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            raise AssertionError('ordinary resume read stdin')
        assert (proc.returncode, out, err) == (0, b'', b'')
        assert not calls.exists(), 'ordinary resume spawned a subprocess'
    finally:
        os.close(read)
        os.close(write)
PY
check 'unset and empty pickup exit silently without reading stdin or spawning jq' '[ ! -e "$T/unexpected-subprocess" ]'

command=$(jq -r '.hooks.SessionStart[] | .hooks[] | .command | select(contains("restart-pickup.sh"))' "$SETTINGS")
rc=0
MEGAVIBE_RESTART_PICKUP=pending bash -c "$command" </dev/null > "$T/output" 2>&1 || rc=$?
check 'missing restart helper is silent and exits zero' '[ "$rc" = 0 ] && [ ! -s "$T/output" ]'
cat > "$MEGAVIBE_HOME/scripts/restart.sh" <<'HELPER'
#!/bin/bash
printf 'pickup: %s %s\n' "$1" "$2"
HELPER
rc=0
(cd "$PROJECT" && MEGAVIBE_RESTART_PICKUP=pending bash -c "$command" <<<'{"source":"resume","session_id":"space-path"}') > "$T/output" 2>&1 || rc=$?
check 'installed command delegates to existing code through paths with spaces' '[ "$rc" = 0 ] && [ "$(cat "$T/output")" = "pickup: show space-path" ]'
mv "$PROJECT/.claude/hooks/on-session-start.sh" "$T/start-hook"
rc=0
MEGAVIBE_RESTART_PICKUP=pending bash -c "$command" </dev/null > "$T/output" 2>&1 || rc=$?
check 'missing startup hook in an older project is silent and exits zero' '[ "$rc" = 0 ] && [ ! -s "$T/output" ]'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
