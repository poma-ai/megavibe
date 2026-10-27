#!/bin/bash
# /bin/bash tests/legacy-hooks.test.sh
# megavibe never installs into, or runs in, $HOME; leftovers from an older launch
# in ~ are reported with what to remove, never removed by guesswork.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/legacy-hooks.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 2
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
mkdir -p "$T/h" "$T/proj"

# 1. init.sh refuses $HOME (plain, trailing slash, symlinked HOME, `.`, case variant) and exits 0.
for p in "$T/h" "$T/h/"; do
  HOME="$T/h" bash "$REPO/init.sh" "$p" >/dev/null 2>&1; rc=$?
  check "init.sh in HOME ($p) exits 0" '[ $rc = 0 ]'
  check "init.sh in HOME ($p) installs nothing" '[ ! -e "$T/h/.claude" ] && [ ! -e "$T/h/.agent" ]'
done
ln -s "$T/h" "$T/hl"
HOME="$T/hl" bash "$REPO/init.sh" "$T/h" >/dev/null 2>&1; rc=$?
check "HOME given as a symlink is still refused" '[ $rc = 0 ] && [ ! -e "$T/h/.claude" ]'
(cd "$T/h" && HOME="$T/h" bash "$REPO/init.sh" . >/dev/null 2>&1); rc=$?
check "init.sh . from inside HOME refused" '[ $rc = 0 ] && [ ! -e "$T/h/.claude" ]'
mkdir -p "$T/Case"
if [ -d "$T/CASE" ]; then   # case-insensitive volume (default APFS)
  HOME="$T/Case" bash "$REPO/init.sh" "$T/CASE" >/dev/null 2>&1; rc=$?
  check "a differently-cased spelling of HOME is refused" '[ $rc = 0 ] && [ ! -e "$T/Case/.claude" ]'
fi
HOME="$T/h" bash "$REPO/init.sh" "$T/proj" >/dev/null 2>&1; rc=$?
check "a normal project is still initialised" '[ $rc = 0 ] && [ -x "$T/proj/.claude/hooks/status-sync.sh" ]'

# 2. The launcher's refusal, extracted (from its comment to the first `fi`) and run.
rblk="$T/refuse.sh"
{ echo 'set -euo pipefail; YELLOW=; DIM=; RESET=; NORMALIZE=${NORMALIZE:-1}; GIT_ROOT=${GIT_ROOT:-}'
  awk '/^# Never in the home directory/ {f=1} f {print} f && /^fi$/ {exit}' "$REPO/megavibe"
  echo 'echo PASSED'; } > "$rblk"
check "refusal block extracted" 'grep -q -- "-ef \"\$HOME\"" "$rblk"'
out=$(cd "$T/h" && HOME="$T/h" bash "$rblk" 2>&1); rc=$?
check "launcher refuses to start in HOME" '[ $rc = 1 ] && ! printf "%s" "$out" | grep -q PASSED'
out=$(cd "$T/CASE" 2>/dev/null && HOME="$T/Case" bash "$rblk" 2>&1); rc=$?
[ -d "$T/CASE" ] && check "launcher refuses a case variant of HOME" '[ $rc = 1 ]'
out=$(cd "$T/proj" && HOME="$T/h" bash "$rblk" 2>&1); rc=$?
out=$(cd "$T/h" && HOME="$T/h" GIT_ROOT="$T/h" bash "$rblk" 2>&1)
check "a git repo at ~ gets the --no-normalize hint" 'printf "%s" "$out" | grep -q -- "megavibe --no-normalize"'
out=$(cd "$T/h" && HOME="$T/h" bash "$rblk" 2>&1)
check "no hint when ~ is not a repo" '! printf "%s" "$out" | grep -q -- "--no-normalize"'
check "the restart re-exec keeps --no-normalize" 'grep -q "exec bash \"\$MEGAVIBE_HOME/megavibe\" --no-normalize --continue" "$REPO/megavibe"'
out=$(cd "$T/proj" && HOME="$T/h" bash "$rblk" 2>&1); rc=$?
check "launcher starts in a project" '[ $rc = 0 ] && printf "%s" "$out" | grep -q PASSED'
check "refusal comes before the lock and init" '[ "$(grep -n "^# Never in the home directory" "$REPO/megavibe" | cut -d: -f1)" -lt "$(grep -n "^bash \"\$INIT_SCRIPT\" \.$" "$REPO/megavibe" | cut -d: -f1)" ] && [ "$(grep -n "^# Never in the home directory" "$REPO/megavibe" | cut -d: -f1)" -lt "$(grep -n "^acquire_lock || true" "$REPO/megavibe" | cut -d: -f1)" ]'

# 3. Leftovers of an older launch in ~: historic names are still removed, newer
#    ones are reported with the fix, never removed or archived by guesswork.
homeinstall() { mkdir -p "$1/.agent" "$1/.claude/hooks"; cp "$REPO"/template/.claude/hooks/*.sh "$1/.claude/hooks/"; }
settings() { jq -n --arg d "$1/.claude/hooks/" '{statusLine: {type: "command", command: "~/.claude/statusline.sh"},
  hooks: {PostToolUse: [{matcher: ".*", hooks: [{type: "command", command: ("\"" + $d + "status-sync.sh\"")},
                                                 {type: "command", command: ("\"" + $d + "log-tool-event.sh\"")}]}]}}' > "$1/.claude/settings.json"; }
sblk="$T/setup-cleanup.sh"
{ echo 'set -euo pipefail'; echo 'ok(){ echo "OK $1"; }; warn(){ echo "WARN $1"; }'
  printf 'SCRIPT_DIR=%q\n' "$REPO"; echo 'USER_SETTINGS="$HOME/.claude/settings.json"'
  sed -n '/^LEGACY_HOOK_DIR=/,$p' "$REPO/setup.sh" \
    | awk '{print} /^if \[ -d "\$LEGACY_HOOK_DIR" \]; then$/ {f=1} f && /^fi$/ {exit}'; } > "$sblk"
lblk="$T/launcher-heal.sh"
{ echo 'set -euo pipefail'
  sed -n '/^LEGACY_USER_HOOKS=/,$p' "$REPO/megavibe" \
    | awk '{print} /^if \[ -d "\$LEGACY_USER_HOOKS" \]; then$/ {f=1} f && /^fi$/ {exit}'; } > "$lblk"
for blk in "$sblk" "$lblk"; do
  n=$(basename "$blk" .sh); H="$T/$n"; homeinstall "$H"; settings "$H"
  out=$(HOME="$H" bash "$blk" 2>&1); rc=$?
  check "$n: runs" '[ $rc = 0 ]'
  check "$n: a historic name is still removed" '! jq -r ".. | .command? // empty" "$H/.claude/settings.json" | grep -q log-tool-event'
  check "$n: a newer name is kept" 'jq -r ".. | .command? // empty" "$H/.claude/settings.json" | grep -q status-sync'
  check "$n: the folder is not archived while referenced" '[ -d "$H/.claude/hooks" ]'
  check "$n: the warning names the launch from ~ and the fix" 'printf "%s" "$out" | grep -q "launch from ~" && printf "%s" "$out" | grep -q "remove every entry pointing into ~/.claude/hooks/ from the settings file(s) named above"'
  H2="$T/$n-noagent"; homeinstall "$H2"; rmdir "$H2/.agent"; settings "$H2"
  out=$(HOME="$H2" bash "$blk" 2>&1)
  check "$n: no ~/.agent, no launch-from-~ claim" '! printf "%s" "$out" | grep -q "launch from ~"'
  # After the user deletes the entries, the next run archives the folder.
  jq 'del(.hooks)' "$H/.claude/settings.json" > "$H/s.tmp" && mv "$H/s.tmp" "$H/.claude/settings.json"
  HOME="$H" bash "$blk" >/dev/null 2>&1
  check "$n: once the entries are gone the folder is archived" '[ ! -e "$H/.claude/hooks" ] && ls -d "$H"/.claude/hooks.legacy-* >/dev/null 2>&1'
done

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
