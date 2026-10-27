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
{ echo 'set -euo pipefail; YELLOW=; DIM=; RESET=; NORMALIZED_FROM=${NORMALIZED_FROM:-}'
  awk '/^# Never in the home directory/ {f=1} f {print} f && /^fi$/ {exit}' "$REPO/megavibe"
  echo 'echo PASSED'; } > "$rblk"
check "refusal block extracted" 'grep -q -- "-ef \"\$HOME\"" "$rblk"'
out=$(cd "$T/h" && HOME="$T/h" bash "$rblk" 2>&1); rc=$?
check "launcher refuses to start in HOME" '[ $rc = 1 ] && ! printf "%s" "$out" | grep -q PASSED'
out=$(cd "$T/CASE" 2>/dev/null && HOME="$T/Case" bash "$rblk" 2>&1); rc=$?
[ -d "$T/CASE" ] && check "launcher refuses a case variant of HOME" '[ $rc = 1 ]'
out=$(cd "$T/proj" && HOME="$T/h" bash "$rblk" 2>&1); rc=$?
out=$(cd "$T/h" && HOME="$T/h" NORMALIZED_FROM="$T/h/sub" bash "$rblk" 2>&1)
check "a launch normalized up to ~ gets the --no-normalize hint" 'printf "%s" "$out" | grep -q -- "megavibe --no-normalize"'
out=$(cd "$T/h" && HOME="$T/h" bash "$rblk" 2>&1)
check "no hint when the launch was not moved to ~" '! printf "%s" "$out" | grep -q -- "--no-normalize"'
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

# 4. Umbrella folder note: names the repos whose own .agent/ log is newest.
ublk="$T/umbrella.sh"
{ echo 'set -euo pipefail; YELLOW=; DIM=; RESET='; sed -n '/^umbrella_note() {/,/^}/p' "$REPO/megavibe"; echo umbrella_note; } > "$ublk"
ago() { date -v-"$1" +%Y%m%d%H%M 2>/dev/null || date -d "$2 ago" +%Y%m%d%H%M; }
# mkev DIR HOURS_AGO: an event file named by its UTC write time, with that mtime
mkev() {
  local ts; ts=$(date -u -v-"$2"H +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -d "$2 hours ago" +%Y%m%dT%H%M%SZ)
  mkdir -p "$1"; : > "$1/$ts-t.md"; touch -t "$(ago "$2"H "$2 hours")" "$1/$ts-t.md"
}
repo() { mkdir -p "$1/.git" "$1/.agent/events"; }
U="$T/umb"; for x in a b c d; do mkdir -p "$U/$x/.git"; done
mkev "$U/a/.agent/events" 0; mkev "$U/b/.agent/events" 72
mkdir -p "$U/w" "$U/real-agent/events"; printf 'gitdir: /somewhere/repo.git/worktrees/w\n' > "$U/w/.git"; mkev "$U/w/.agent/events" 0
mkev "$U/real-agent/events" 0; ln -s ../real-agent "$U/d/.agent"
mkdir -p "$U/nogd"; : > "$U/nogd/.git"
out=$(cd "$U" && bash "$ublk" 2>&1); rc=$?
check "umbrella note runs under set -euo pipefail" '[ $rc = 0 ]'
check "umbrella note counts repos, not worktrees or a .git without gitdir" 'printf "%s" "$out" | grep -q "holds 4 repos\."'
check "umbrella note lists newest own logs first" 'printf "%s" "$out" | grep -q "newest first: a (today), b (3d ago)"'
check "umbrella note skips worktrees and symlinked .agent" '! printf "%s" "$out" | grep -q "w (" && ! printf "%s" "$out" | grep -q "d ("'
check "umbrella note suggests cd and --add-dir" 'printf "%s" "$out" | grep -q -- "--add-dir"'
/bin/rm -rf "$U/c" "$U/d"; out=$(cd "$U" && bash "$ublk" 2>&1)
check "two repos: no note" '[ -z "$out" ]'
mkdir -p "$T/empty-umb"; out=$(cd "$T/empty-umb" && bash "$ublk" 2>&1); rc=$?
check "no repos: silent, no unbound-array error" '[ $rc = 0 ] && [ -z "$out" ]'
# GNU stat: -f is --file-system, prints filesystem info and fails on the format.
G="$T/gnubin"; mkdir -p "$G"
printf '#!/bin/sh\nif [ "$1" = "-f" ]; then echo "  File: \\"$3\\""; echo "    ID: 0 Namelen: 255"; exit 1; fi\n[ "$1" = "-c" ] && exec date +%%s\nexit 1\n' > "$G/stat"; chmod +x "$G/stat"
U2="$T/umb2"; for x in p q r; do repo "$U2/$x"; mkev "$U2/$x/.agent/events" 0; done
out=$(cd "$U2" && PATH="$G:$PATH" bash "$ublk" 2>&1); rc=$?
check "GNU stat does not abort the launcher" '[ $rc = 0 ] && printf "%s" "$out" | grep -q "p (today)"'
# Six repos logged hours apart: the newest five are shown, the oldest is not.
U3="$T/umb3"; i=0; for x in f1 f2 f3 f4 f5 f6; do i=$((i+1)); repo "$U3/$x"; mkev "$U3/$x/.agent/events" "$i"; done
out=$(cd "$U3" && bash "$ublk" 2>&1)
check "ordering uses the full timestamp, not the rounded day" 'printf "%s" "$out" | grep -q "f1 (today), f2 (today), f3 (today), f4 (today), f5 (today)" && ! printf "%s" "$out" | grep -q "f6"'
repo "$U3/fut"; : > "$U3/fut/.agent/events/20300101T000000Z-x.md"; touch -t 203001010000 "$U3/fut/.agent/events/20300101T000000Z-x.md"
out=$(cd "$U3" && bash "$ublk" 2>&1)
check "a future timestamp shows as today, not a negative age" 'printf "%s" "$out" | grep -q "fut (today)" && ! printf "%s" "$out" | grep -q "(-"'
# Freshly initialised repos (empty events dir, or only .DS_Store) do not push out a real log.
U4="$T/umb4"; for x in e1 e2 e3; do repo "$U4/$x"; done
for x in s1 s2 s3; do repo "$U4/$x"; : > "$U4/$x/.agent/events/.DS_Store"; : > "$U4/$x/.agent/events/notes.txt"; done
repo "$U4/real"; mkev "$U4/real/.agent/events" 30
out=$(cd "$U4" && bash "$ublk" 2>&1)
check "events dirs without an event file are not listed" 'printf "%s" "$out" | grep -q "newest first: real (1d ago)$"'
# A fold removes old events and refreshes the dir mtime; the age stays the newest event's.
repo "$U4/folded"; mkev "$U4/folded/.agent/events" 360; mkev "$U4/folded/.agent/events" 960
/bin/rm -f "$(ls -d "$U4"/folded/.agent/events/* | head -1)"; touch "$U4/folded/.agent/events"
out=$(cd "$U4" && bash "$ublk" 2>&1)
check "a fold does not make a repo look active today" 'printf "%s" "$out" | grep -q "real (1d ago), folded (15d ago)"'
# A repo name starting with a dash is listed, not read as a stat option.
repo "$U4/-dash"; mkev "$U4/-dash/.agent/events" 0
out=$(cd "$U4" && bash "$ublk" 2>&1)
check "a repo named -dash is listed" 'printf "%s" "$out" | grep -q -- "-dash (today)"'
# A launch in ~ gets no umbrella advice (the launcher refuses right after).
out=$(cd "$U4" && HOME="$U4" bash "$ublk" 2>&1)
check "no umbrella note in HOME" '[ -z "$out" ]'
check "launcher note names the settings file found, not settings.json" '! grep -q "remove it from ~/.claude/settings.json" "$REPO/megavibe"'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
