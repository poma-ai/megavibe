#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/mv-o.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" TMPDIR="$T/tmp" TEST_ROOT="$T/root" TEST_ALIAS="$T/alias" TEST_USER_TEMP="$T/user-temp"
S="$HOME/.megavibe/scripts"
OWN="$S/scratch-own.sh"
HOOK="$REPO/template/.claude/hooks/scratch-orphans.sh"
mkdir -p "$S" "$T/bin" "$HOME/.claude/sessions" "$TMPDIR" "$T/.agent" "$T/outside/-project/00000000-0000-0000-0000-00000000000e"
ln -s "$T/outside" "$TEST_ALIAS"
# Isolate both discovery mechanisms so the test cannot sweep live scratch or pytest state.
sed '/^def system_temp():/,/^$/c\
def system_temp():\
    return os.environ["TEST_USER_TEMP"]\
\
' "$REPO/scripts/scratch-own.sh" > "$OWN"
cat > "$S/scratch-root.sh" <<'ROOTS'
#!/bin/bash
case "$1" in
  roots) printf '%s\n' "$TEST_ROOT" "$TEST_ALIAS" ;;
  base) printf '%s\n' "$TMPDIR" ;;
esac
ROOTS
chmod +x "$OWN" "$S/scratch-root.sh"
P="$TEST_ROOT/-project"
Y="$TEST_USER_TEMP/pytest-of-$(id -un)"
current=00000000-0000-0000-0000-000000000001
live=00000000-0000-0000-0000-000000000002
idle=00000000-0000-0000-0000-000000000003
dead=00000000-0000-0000-0000-000000000004
reused=00000000-0000-0000-0000-000000000005
recent=00000000-0000-0000-0000-000000000006
orphan=00000000-0000-0000-0000-000000000007
old_parent=00000000-0000-0000-0000-000000000008
guarded=00000000-0000-0000-0000-000000000009
linked=00000000-0000-0000-0000-00000000000A
foreign=00000000-0000-0000-0000-00000000000b
foreign_child=00000000-0000-0000-0000-00000000000c
hook_orphan=00000000-0000-0000-0000-00000000000d
mkdir -p "$P"/{$current,$live,$idle,$dead,$reused,$recent,$orphan,$old_parent,$guarded/nested,-odd,$linked} "$TEST_ROOT/free-folder/notes" \
  "$TEST_ROOT/t"/{tempdead,tempidle,badmark0} "$Y"/{pytest-0,pytest-1,pytest-2,pytest-not-number}
printf '%s\n' tempdead-session > "$TEST_ROOT/t/tempdead/.sid"
printf '%s\n' tempidle-session > "$TEST_ROOT/t/tempidle/.sid"
printf '%s\n' another-session > "$TEST_ROOT/t/badmark0/.sid"
touch "$P/$guarded/nested/.keep" "$T/outside/data" "$Y"/pytest-{0,1,2}/fixture
ln -s "$T/outside" "$P/$linked/external"
ln -s pytest-2 "$Y/pytest-current"
export TEST_START='Mon Nov 23 15:31:16 2026'
cat > "$T/bin/ps" <<'PS'
#!/bin/bash
if [[ "${TZ:-}" = UTC ]]; then
  printf '%s\n' "$TEST_START"
else
  printf '%s\n' "Mon Nov 23 16:31:16 2026"
fi
PS
chmod +x "$T/bin/ps"
export PATH="$T/bin:$PATH"
export TZ=UTC
start=$TEST_START
record() { jq -n --arg sid "$1" --argjson pid "$2" --arg start "$3" \
  '{sessionId:$sid,pid:$pid,procStart:$start}' > "${RECORD_DIR:-$HOME/.claude/sessions}/$1.json"; }
# Give each regression its own scratch root so all failures are visible in one run.
unset CLAUDE_CONFIG_DIR
failures=0
for scenario in timezone custom sibling invalid-start invalid-custom attribution; do
  (
    export TEST_ROOT="$T/$scenario" TEST_USER_TEMP="$T/$scenario-no-pytest"
    target="$TEST_ROOT/-project/$live"
    record_dir="$HOME/.claude/sessions"
    case "$scenario" in
      timezone) export TZ=Europe/Berlin ;;
      custom|invalid-custom)
        export CLAUDE_CONFIG_DIR="$T/custom-config"
        record_dir="$CLAUDE_CONFIG_DIR/sessions"
        ;;
      sibling) record_dir="$HOME/.claude-work/sessions" ;;
      attribution) target="$TEST_ROOT/-personal-notes/notes" ;;
    esac
    mkdir -p "$target" "$record_dir"
    touch "$target/live-work"
    find "$TEST_ROOT" -exec touch -t 200001010000 {} +
    if [[ "$scenario" != attribution ]]; then
      recorded=$start
      if [[ "$scenario" = invalid-start || "$scenario" = invalid-custom ]]; then
        recorded='Mon Nov 31 15:31:16 2026'
      fi
      RECORD_DIR="$record_dir" record "$live" "$$" "$recorded"
      if [[ "$scenario" = invalid-* ]]; then
        mkdir "$TEST_ROOT/-project/$dead"
        touch -t 200001010000 "$TEST_ROOT/-project/$dead"
      fi
    fi
    "$OWN" sweep-orphans "$current" > /dev/null 2>"$T/$scenario.report"
    rm -f "$record_dir/$live.json"
    [[ -f "$target/live-work" ]] || exit 1
    case "$scenario" in
      invalid-*)
        [[ -d "$TEST_ROOT/-project/$dead" &&
           $(cat "$T/$scenario.report") = 'scratch-own: skipped session scratch sweep due to 1 invalid session record(s)' ]]
        ;;
      attribution) grep -Eq '/-personal-notes/notes: [0-9]+ kB$' "$T/$scenario.report" ;;
    esac
  ) || { echo "FAIL: $scenario orphan protection" >&2; failures=1; }
done
[[ "$failures" -eq 0 ]] || exit 1
record "$live" "$$" "$start"
record "$idle" "$$" "$start"
record tempidle-session "$$" "$start"
record "$reused" "$$" 'Thu Jan 1 00:00:00 1970'
bash -c 'exit 0' &
dead_pid=$!
wait "$dead_pid"
record "$dead" "$dead_pid" "$start"
if [[ $(id -u) = 0 ]]; then
  mkdir "$P/$foreign" "$P/$foreign_child"
  touch "$P/$foreign_child/fixture"
  chown 1 "$P/$foreign" "$P/$foreign_child/fixture"
fi
python3 - "$TEST_ROOT" "$T/outside" "$Y" <<'PY'
import os, sys
for top in sys.argv[1:]:
    for root, dirs, files in os.walk(top, topdown=False):
        for path in [root] + [os.path.join(root, name) for name in dirs + files]:
            os.utime(path, (946684800, 946684800), follow_symlinks=False)
PY
touch "$P/$recent" "$P/$live" "$P/$old_parent/new-child" "$Y/pytest-2/fixture"
exec 9< "$Y/pytest-1/fixture"
MEGAVIBE_SCRATCH_ORPHAN_HOURS=0 "$OWN" sweep-orphans "$current"
[[ -d "$P/$dead" && -d "$Y/pytest-0" ]]
damaged="$HOME/.claude/sessions/damaged.json"
printf '{"sessionId":' > "$damaged"
"$OWN" sweep-orphans "$current" >/dev/null 2>"$T/damaged-report"
[[ -d "$P/$dead" && -d "$TEST_ROOT/t/tempdead" ]] || {
  echo "FAIL: session scratch removed with a damaged record" >&2
  exit 1
}
[[ $(cat "$T/damaged-report") = 'scratch-own: skipped session scratch sweep due to 1 invalid session record(s)' ]] || exit 1
if command -v lsof >/dev/null; then [[ ! -e "$Y/pytest-0" ]] || exit 1; fi
rm "$damaged"
rc=0
out=$("$OWN" sweep-orphans "$current" 2>"$T/report") || rc=$?
if [[ $(id -u) != 0 ]]; then [[ $rc = 0 ]]; else [[ $rc = 4 ]]; fi
[[ "$out" =~ ^freed\ [0-9]+\ MB\ from\ 5\ ended\ sessions$ ]]
grep -Eq 'free-folder.*[0-9]+ kB' "$T/report"
for sid in "$current" "$live" "$idle" "$recent" "$old_parent" "$guarded" -odd; do [[ -d "$P/$sid" ]]; done
for sid in "$dead" "$reused" "$orphan" "$linked"; do [[ ! -e "$P/$sid" ]] || exit 1; done
[[ -d "$TEST_ROOT/free-folder/notes" && -f "$T/outside/data" && -d "$TEST_ALIAS/-project/00000000-0000-0000-0000-00000000000e" ]]
[[ ! -e "$TEST_ROOT/t/tempdead" && -d "$TEST_ROOT/t/tempidle" && -d "$TEST_ROOT/t/badmark0" ]]
if [[ $(id -u) = 0 ]]; then [[ -d "$P/$foreign" && -f "$P/$foreign_child/fixture" ]]; fi
[[ -d "$Y/pytest-1" && -d "$Y/pytest-2" && -L "$Y/pytest-current" && -d "$Y/pytest-not-number" ]]
if command -v lsof >/dev/null; then [[ ! -e "$Y/pytest-0" ]]; else [[ -d "$Y/pytest-0" ]]; fi
exec 9<&-
mkdir "$P/$hook_orphan"
[[ -z $(cd "$TMPDIR" && printf '{"session_id":"%s"}\n' "$current" | bash "$HOOK") ]]
touch -t 200001010000 "$P/$hook_orphan"
(cd "$T" && printf '{"session_id":"%s"}\n' "$current" | bash "$HOOK") | grep -q 'freed .* from 1 ended sessions'
[[ ! -e "$P/$hook_orphan" ]]
printf '#!/bin/bash\nexec sleep 30\n' > "$OWN"
python3 - "$HOOK" "$T" <<'PY'
import subprocess, sys
result = subprocess.run(["bash", sys.argv[1]], cwd=sys.argv[2], timeout=8,
                        input=b'{"session_id":"current"}', capture_output=True)
assert result.returncode == 0 and not result.stdout, result
PY
echo 'PASS: orphan age, liveness, safety, pytest class and hook deadline'
