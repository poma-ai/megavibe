#!/bin/bash
# /bin/bash tests/scratch-budget.test.sh — scratch-root.sh (CLAUDE_CODE_TMPDIR honoured, default unchanged),
# disk-watch.sh (relative warn line, scratch volume, session scratch budget), and the Stop check on the budget.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/scratch-budget-test.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
export HOME=$T/home TMPDIR=$T/tmp
mkdir -p "$HOME" "$TMPDIR"
unset MEGAVIBE_DISK_WATCH MEGAVIBE_BG_WATCH
PASS=0 FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
SR=$REPO/scripts/scratch-root.sh DW=$REPO/scripts/disk-watch.sh
U=$(id -u); case "$(uname -s)" in Darwin) DEF=/private/tmp ;; *) DEF=/tmp ;; esac
unset CLAUDE_CODE_TMPDIR MEGAVIBE_DISK_WARN_GB MEGAVIBE_SCRATCH_BUDGET_GB

# --- scratch-root.sh
check "unset: root is the default" '[ "$(bash "$SR" root)" = "$DEF/claude-$U" ]'
check "unset: base is /tmp" '[ "$(bash "$SR" base)" = /tmp ]'
check "unset: roots is just the default" '[ "$(bash "$SR" roots)" = "$DEF/claude-$U" ]'
mkdir -p "$T/moved"
check "set and usable: root moves" '[ "$(CLAUDE_CODE_TMPDIR=$T/moved bash "$SR" root)" = "$T/moved/claude-$U" ]'
check "set and usable: roots lists both, moved first" '[ "$(CLAUDE_CODE_TMPDIR=$T/moved bash "$SR" roots | tr "\n" " ")" = "$T/moved/claude-$U $DEF/claude-$U " ]'
check "set but missing (unmounted): falls back to the default" '[ "$(CLAUDE_CODE_TMPDIR=$T/nodisk bash "$SR" root)" = "$DEF/claude-$U" ]'
check "set but relative: falls back" '[ "$(CLAUDE_CODE_TMPDIR=moved bash "$SR" root)" = "$DEF/claude-$U" ]'
check "trailing slash is normalised" '[ "$(CLAUDE_CODE_TMPDIR=$T/moved/ bash "$SR" base)" = "$T/moved" ]'

# --- disk-watch.sh with a fake df
mkdir -p "$T/bin"
cat > "$T/bin/df" <<'EOS'
#!/bin/bash
p=${@: -1}
case "$p" in
  */moved*|*/scratchvol*) a=${FAKE_SCRATCH_AVAIL:-900000000}; t=${FAKE_SCRATCH_TOTAL:-1000000000}; m=/Volumes/dev ;;
  *) a=${FAKE_AVAIL:-900000000}; t=${FAKE_TOTAL:-1000000000}; m=/ ;;
esac
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/x $t $((t - a)) $a $((100 - a * 100 / t))% $m"
EOS
chmod +x "$T/bin/df"
lvl() { PATH="$T/bin:$PATH" bash "$DW" level; }
GB=1048576
check "460 GB disk, 60 GB free (13%): LOW at the relative line" '[ "$(FAKE_TOTAL=$((460*GB)) FAKE_AVAIL=$((60*GB)) lvl)" = LOW ]'
check "460 GB disk, 80 GB free (17%): OK" '[ "$(FAKE_TOTAL=$((460*GB)) FAKE_AVAIL=$((80*GB)) lvl)" = OK ]'
check "100 GB disk, 35 GB free: LOW (the 40 GB floor)" '[ "$(FAKE_TOTAL=$((100*GB)) FAKE_AVAIL=$((35*GB)) lvl)" = LOW ]'
check "100 GB disk, 45 GB free: OK" '[ "$(FAKE_TOTAL=$((100*GB)) FAKE_AVAIL=$((45*GB)) lvl)" = OK ]'
check "7 GB free is CRITICAL" '[ "$(FAKE_TOTAL=$((460*GB)) FAKE_AVAIL=$((7*GB)) lvl)" = CRITICAL ]'
check "MEGAVIBE_DISK_WARN_GB still fixes the line" '[ "$(MEGAVIBE_DISK_WARN_GB=10 FAKE_TOTAL=$((460*GB)) FAKE_AVAIL=$((60*GB)) lvl)" = OK ]'
check "check names the effective warn line" 'PATH="$T/bin:$PATH" FAKE_TOTAL=$((460*GB)) FAKE_AVAIL=$((60*GB)) bash "$DW" check | head -1 | grep -q "warn < 69.0 GB"'
# scratch volume on another disk: the boot disk is fine, the scratch volume is low
mkdir -p "$T/moved"
check "scratch volume low, boot fine: level is LOW" '[ "$(CLAUDE_CODE_TMPDIR=$T/moved FAKE_SCRATCH_TOTAL=$((1800*GB)) FAKE_SCRATCH_AVAIL=$((100*GB)) lvl)" = LOW ]'
check "check reports the scratch disk" 'CLAUDE_CODE_TMPDIR=$T/moved PATH="$T/bin:$PATH" FAKE_SCRATCH_TOTAL=$((1800*GB)) FAKE_SCRATCH_AVAIL=$((100*GB)) bash "$DW" check | grep -q "^scratch disk: .*LOW"'
check "both fine: silent and OK" '[ "$(CLAUDE_CODE_TMPDIR=$T/moved lvl)" = OK ] && [ -z "$(CLAUDE_CODE_TMPDIR=$T/moved PATH="$T/bin:$PATH" bash "$DW" check)" ]'
check "unset variable: no scratch line" '! PATH="$T/bin:$PATH" FAKE_AVAIL=$((7*GB)) bash "$DW" check | grep -q "scratch disk"'

# --- session scratch budget
SID=aaaaaaaa-1111-2222-3333-444444444444
"$REPO/scripts/scratch-own.sh" stamp "$SID"
S=$T/moved/claude-$U/-proj/$SID/scratchpad; mkdir -p "$S" "$T/moved/claude-$U/-proj/other-session"
head -c 3145728 /dev/zero > "$S/big.bin"; head -c 9000000 /dev/zero > "$T/moved/claude-$U/-proj/other-session/x.bin"
out=$(CLAUDE_CODE_TMPDIR=$T/moved MEGAVIBE_SCRATCH_BUDGET_GB=1 bash "$DW" scratch "$SID"); rc=$?
check "under budget: exit 0 and a line" '[ $rc -eq 0 ] && case $out in scratch:*) true ;; *) false ;; esac'
touch "$S/huge.bin"
cat > "$T/bin/du" <<'EOS'
#!/bin/bash
target=${@: -1}
if [ -f "$target/scratchpad/huge.bin" ] || [ -f "$target/other-huge" ]; then
  printf '1100000\t%s\n' "$target"
  exit 0
fi
exec /usr/bin/du "$@"
EOS
chmod +x "$T/bin/du"
export PATH="$T/bin:$PATH"
CLAUDE_CODE_TMPDIR=$T/moved MEGAVIBE_SCRATCH_BUDGET_GB=1 bash "$DW" scratch "$SID" >/dev/null; check "over budget: exit 3" '[ $? -eq 3 ]'
check "another session's scratch is not counted" '[ "$(CLAUDE_CODE_TMPDIR=$T/moved bash "$DW" scratch-kb other-session)" -lt 20000 ]'
CLAUDE_CODE_TMPDIR=$T/moved MEGAVIBE_SCRATCH_BUDGET_GB=0 bash "$DW" scratch "$SID" >/dev/null; check "budget 0 switches it off" '[ $? -eq 0 ]'
check "a bad session id yields nothing" '[ "$(CLAUDE_CODE_TMPDIR=$T/moved bash "$DW" scratch-kb "../x")" = 0 ]'

# a moved root with a space in its path is listed by the sizes scan
mkdir -p "$T/my disk/claude-$U/-p/x"; head -c 105000000 /dev/zero > "$T/my disk/claude-$U/-p/x/f"
check "top lists a moved root whose path has a space" 'CLAUDE_CODE_TMPDIR="$T/my disk" bash "$DW" top | grep -q "my disk"'

# exact thresholds: 461 GB disk, 69.5 GB free is above 15% (69.15 GB)
check "461 GB disk with 69.5 GB free is OK (no rounding to whole GB)" '[ "$(FAKE_TOTAL=$((461*GB)) FAKE_AVAIL=$((69*GB+GB/2)) lvl)" = OK ]'
check "461 GB disk with 69.0 GB free is LOW" '[ "$(FAKE_TOTAL=$((461*GB)) FAKE_AVAIL=$((69*GB)) lvl)" = LOW ]'
# a failing primary df does not hide a low scratch volume
cat > "$T/bin2df" <<'EOS'
#!/bin/bash
p=${@: -1}
case "$p" in */moved*) echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "/dev/x 1887436800 1782579200 104857600 95% /Volumes/dev" ;; *) exit 1 ;; esac
EOS
mkdir -p "$T/bin2"; mv "$T/bin2df" "$T/bin2/df"; chmod +x "$T/bin2/df"
check "primary df fails, scratch volume low: level LOW" '[ "$(CLAUDE_CODE_TMPDIR=$T/moved PATH="$T/bin2:$PATH" bash "$DW" level)" = LOW ]'
check "primary df fails, scratch volume low: check speaks" 'CLAUDE_CODE_TMPDIR=$T/moved PATH="$T/bin2:$PATH" bash "$DW" check | grep -q "^scratch disk: .*LOW"'
check "primary df fails and no scratch move: UNKNOWN" '[ "$(PATH="$T/bin2:$PATH" bash "$DW" level)" = UNKNOWN ]'
# a scratch volume reporting negative availability is CRITICAL, not dropped
mkdir -p "$T/bin5"; printf '#!/bin/bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/x 1000000 1001024 -1024 101%% /Volumes/full"\n' > "$T/bin5/df"; chmod +x "$T/bin5/df"
check "negative available space parses and is CRITICAL" '[ "$(PATH="$T/bin5:$PATH" bash "$DW" level)" = CRITICAL ]'
# a mount name that ends in N% is not taken for the capacity column
cat > "$T/bin4df" <<'EOS'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/x 482344960 434110464 48234496 90% /Volumes/SSD 100%"
EOS
mkdir -p "$T/bin4"; mv "$T/bin4df" "$T/bin4/df"; chmod +x "$T/bin4/df"
check "a mount named 'SSD 100%' still parses (46 GB free of 460 GB: LOW)" '[ "$(PATH="$T/bin4:$PATH" bash "$DW" level)" = LOW ]'
# watch keeps going and speaks about the scratch volume while the primary df fails
CLAUDE_CODE_TMPDIR=$T/moved PATH="$T/bin2:$PATH" perl -e 'alarm shift; exec @ARGV' 4 bash "$DW" watch 30 > "$T/watch" 2>&1
check "watch reports the scratch volume when the primary df fails" 'grep -q "scratch disk .* GB free.*LOW" "$T/watch"'
# a configured critical line above the default warn line is not clamped to it (50 GB critical, 460 GB disk, 45 GB free: CRITICAL)
check "MEGAVIBE_DISK_CRIT_GB=50 on a 460 GB disk: 45 GB free is CRITICAL" '[ "$(MEGAVIBE_DISK_CRIT_GB=50 FAKE_TOTAL=$((460*GB)) FAKE_AVAIL=$((45*GB)) lvl)" = CRITICAL ]'
# one session folder reached through two aliasing slug directories is counted once
ln -s "$T/moved/claude-$U/-proj" "$T/moved/claude-$U/-alias"
one=$(CLAUDE_CODE_TMPDIR=$T/moved bash "$DW" scratch-kb "$SID"); rm -f "$T/moved/claude-$U/-alias"
two=$(CLAUDE_CODE_TMPDIR=$T/moved bash "$DW" scratch-kb "$SID")
check "an aliased folder is not counted twice" '[ "$one" = "$two" ] && [ "$two" -gt 0 ]'
# the real mid-session helper reports an overage once (the ERR trap must not eat the status)
mkdir -p "$T/mid/LOGS"; MS=$REPO/template/.claude/hooks/disk-midsession.sh
mid() { CLAUDE_CODE_TMPDIR=$T/moved MEGAVIBE_SCRATCH_BUDGET_GB=1 DISK_SESSION_ID=$SID DISK_SCRIPT=$DW DISK_LEVEL_FILE=$T/mid/LOGS/level DISK_STAMP_FILE=$T/mid/LOGS/stamp DISK_MINS=5 bash "$MS" 2>&1; }
o=$(mid); check "midsession reports scratch over budget" 'printf "%s" "$o" | grep -q "Session scratch over budget"'
touch -t 200001010000 "$T/mid/LOGS/stamp"; o=$(mid); check "midsession does not repeat it at the same size" '! printf "%s" "$o" | grep -q "Session scratch over budget"'

# a du that cannot finish is "unknown" (exit 4), never "under budget"
mkdir -p "$T/bin3"; printf '#!/bin/bash\nexec sleep 30\n' > "$T/bin3/du"; chmod +x "$T/bin3/du"
CLAUDE_CODE_TMPDIR=$T/moved MEGAVIBE_SCRATCH_BUDGET_GB=1 PATH="$T/bin3:$PATH" bash "$DW" scratch "$SID" >/dev/null; check "du timeout: exit 4, not 0" '[ $? -eq 4 ]'

# --- the Stop check
mkdir -p "$T/home/.megavibe/scripts" "$T/p/.agent/LOGS" "$T/p/.claude/hooks"
cp "$SR" "$DW" "$REPO/scripts/scratch-own.sh" "$T/home/.megavibe/scripts/"; cp "$REPO/template/.claude/hooks/watch-background.sh" "$T/p/.claude/hooks/"
stop() { printf '{"hook_event_name":"Stop","session_id":"%s","stop_hook_active":false,"background_tasks":[]}' "$SID" \
  | (cd "$T/p" && HOME="$T/home" CLAUDE_CODE_TMPDIR=$T/moved MEGAVIBE_SCRATCH_BUDGET_GB=1 bash .claude/hooks/watch-background.sh); }
(
  SID=venv-budget
  "$REPO/scripts/scratch-own.sh" stamp "$SID"
  sleep 1
  python3 -m venv --without-pip "$TMPDIR/user-venv"
  touch "$TMPDIR/user-venv/other-huge"
  failed=0
  kb=$(CLAUDE_CODE_TMPDIR=$T/moved bash "$DW" scratch-kb "$SID")
  if [[ "$kb" != 0 ]]; then echo "FAIL: user venv contributes to session budget"; failed=1; fi
  if [[ -n "$(stop)" ]]; then echo "FAIL: user venv blocks Stop"; failed=1; fi
  report=$(CLAUDE_CODE_TMPDIR=$T/moved bash "$DW" scratch "$SID")
  if [[ "$report" != *"user-venv (1100000 kB,"* ]]; then
    echo "FAIL: user venv missing from other temp usage"
    failed=1
  fi
  [ "$failed" = 0 ]
)
check "a user venv only contributes to other temp usage" '[ $? -eq 0 ]'
rm -rf "$TMPDIR/user-venv"
o=$(stop); check "Stop over budget: block" 'printf "%s" "$o" | jq -e ".decision == \"block\"" >/dev/null'
o=$(stop); check "Stop again, same size: allowed (the session reported)" '[ -z "$o" ]'
check "an over-budget Stop leaves session scratch intact" '[ -f "$S/huge.bin" ]'
rm -f "$T/p/.agent/LOGS/.scratch-stopped.$SID"
o=$(MEGAVIBE_DISK_WATCH=0 stop)
check "Stop passes with disk watch off" '[ -z "$o" ]'
o=$(printf '{"hook_event_name":"Stop","session_id":"%s","agent_id":"test-reader","background_tasks":[]}' "$SID" |
    (cd "$T/p" && CLAUDE_CODE_TMPDIR=$T/moved MEGAVIBE_SCRATCH_BUDGET_GB=1 bash .claude/hooks/watch-background.sh))
check "Stop does not enforce the scratch budget on a subagent" '[ -z "$o" ]'
# one Stop block carries the scratch reason AND an overdue unwatched background task (the second Stop of a cycle exits at once)
rm -f "$T/p/.agent/LOGS/.scratch-stopped.$SID"
old_start=$(( $(date +%s) - 3600 ))
printf '{"id":"bt1","kind":"shell","path":"","started":%s,"nudged":0}\n' "$old_start" > "$T/p/.agent/LOGS/.bg-tasks.$SID.jsonl"
both=$(printf '{"hook_event_name":"Stop","session_id":"%s","stop_hook_active":false,"background_tasks":[{"id":"bt1","type":"shell","status":"running","command":"sleep 99"}]}' "$SID" \
  | (cd "$T/p" && HOME="$T/home" CLAUDE_CODE_TMPDIR=$T/moved MEGAVIBE_SCRATCH_BUDGET_GB=1 bash .claude/hooks/watch-background.sh))
check "one Stop block names both the scratch budget and the unwatched task" 'printf "%s" "$both" | jq -r .reason | grep -q "scratch is over its budget" && printf "%s" "$both" | jq -r .reason | grep -q "bt1"'
# MEGAVIBE_BG_WATCH=0 switches off the background-task checks only: the scratch check still blocks
rm -f "$T/p/.agent/LOGS/.scratch-stopped.$SID"
o=$(printf '{"hook_event_name":"Stop","session_id":"%s","stop_hook_active":false,"background_tasks":[]}' "$SID" \
  | (cd "$T/p" && HOME="$T/home" MEGAVIBE_BG_WATCH=0 CLAUDE_CODE_TMPDIR=$T/moved MEGAVIBE_SCRATCH_BUDGET_GB=1 bash .claude/hooks/watch-background.sh))
check "BG_WATCH=0 does not silence the scratch check" 'printf "%s" "$o" | jq -e ".decision == \"block\"" >/dev/null'
# Exercise both checks against the same overdue task and over-budget session.
stop_payload() { (cd "$T/p" && CLAUDE_CODE_TMPDIR=$T/moved MEGAVIBE_SCRATCH_BUDGET_GB=1 bash .claude/hooks/watch-background.sh); }
bg_state="$T/p/.agent/LOGS/.bg-tasks.$SID.jsonl"
overdue=$(printf '{"id":"bt1","kind":"shell","path":"","started":%s,"nudged":0}' "$old_start")
tasks='[{"id":"bt1","type":"shell","status":"running","command":"sleep 99"}]'
payload=$(jq -nc --arg sid "$SID" --argjson tasks "$tasks" '{hook_event_name:"Stop",session_id:$sid,background_tasks:$tasks}')
printf '%s\n' "$overdue" > "$bg_state"
o=$(printf '%s' "$payload" | MEGAVIBE_DISK_WATCH=0 stop_payload)
check "DISK_WATCH=0 keeps only the background block" '[[ "$o" == *bt1* && "$o" != *"scratch is over"* ]]'
rm -f "$T/p/.agent/LOGS/.scratch-stopped.$SID"
o=$(printf '%s' "$payload" | jq '.background_tasks=[] | .agent_type="main"' | stop_payload)
check "main Stop in a named agent session still checks scratch" '[[ "$o" == *"scratch is over"* ]]'
rm -f "$T/p/.agent/LOGS/.scratch-stopped.$SID"
for agent_fields in '{"agent_id":"a1"}' '{"transcript_path":"/x/SID/subagents/agent-a1.jsonl"}' '{"hook_event_name":"SubagentStop","agent_id":"a1","agent_type":"Explore"}'; do
  printf '%s\n' "$overdue" > "$bg_state"
  o=$(printf '%s' "$payload" | jq --argjson fields "${agent_fields/SID/$SID}" '. + $fields' | stop_payload)
  check "subagent Stop is silent ($agent_fields)" '[ -z "$o" ] && [ "$(cat "$bg_state")" = "$overdue" ]'
done
printf '%s\n' "$overdue" > "$T/p/.agent/LOGS/.bg-tasks.ab.jsonl"
o=$(printf '%s' "$payload" | jq '.session_id="a/b"' | stop_payload)
check "malformed session IDs cannot block on another session's tasks" '[ -z "$o" ] && [ "$(cat "$T/p/.agent/LOGS/.bg-tasks.ab.jsonl")" = "$overdue" ]'

# A named pipe in place of a latch must never delay Stop.
latch="$T/p/.agent/LOGS/.scratch-stopped.$SID"
rm -f "$latch"; mkfifo "$latch"
printf '%s' "$payload" | jq '.background_tasks=[]' > "$T/stop.json"
CLAUDE_CODE_TMPDIR=$T/moved MEGAVIBE_SCRATCH_BUDGET_GB=1 python3 - "$T" <<'PYTHON'
import os, signal, subprocess, sys
root = sys.argv[1]
with open(root + "/stop.json") as payload:
    hook = subprocess.Popen(["/bin/bash", ".claude/hooks/watch-background.sh"],
                            cwd=root + "/p", stdin=payload, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        out, _ = hook.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(hook.pid, signal.SIGKILL)
        hook.communicate()
        sys.exit(1)
    sys.exit(bool(hook.returncode or out))
PYTHON
check "Stop returns promptly and silently with a FIFO scratch latch" '[ $? -eq 0 ]'
rm -f "$latch"

# A symlinked project under the harness root does not own an external session directory.
mkdir -p "$T/external/$SID/scratchpad"
mv "$S/huge.bin" "$T/external/$SID/scratchpad/"
ln -s "$T/external" "$T/moved/claude-$U/-external"
o=$(stop)
check "an external project reached through a symlink cannot block Stop" '[ -z "$o" ]'
rm -f "$T/moved/claude-$U/-external"
mv "$T/external/$SID/scratchpad/huge.bin" "$S/"

# Simulate a disk probe with a child that outlives the Stop deadline.
# Keep its PID so the fixture can reap it even when this test fails.
installed="$HOME/.megavibe/scripts/disk-watch.sh"
mv "$installed" "$installed.keep"
cat > "$installed" <<'EOS'
#!/bin/bash
sleep 15 &
echo "$!" > "$PROBE_PID_FILE"
wait "$!"
EOS
chmod +x "$installed"
o=$(PROBE_PID_FILE="$T/probe.pid" stop)
pid=$(cat "$T/probe.pid")
alive=0
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  alive=1
  kill "$pid" 2>/dev/null
fi
check "Stop deadline leaves no probe child alive and allows Stop" '[ -n "$pid" ] && [ "$alive" = 0 ] && [ -z "$o" ]'
mv "$installed.keep" "$installed"

chmod -R u+rwX "$T/moved/claude-$U/-proj/$SID"; rm -f "$S/huge.bin"
o=$(stop); check "Stop under budget: allowed" '[ -z "$o" ]'
mkdir "$S/mv-review-copy.inside"
printf 'mv-review-copy-v1\nsession %s\n' "$SID" > "$S/mv-review-copy.inside/.megavibe-review-copy"
head -c 32768 /dev/zero > "$S/mv-review-copy.inside/data"
baseline=$(CLAUDE_CODE_TMPDIR=$T/moved bash "$DW" scratch-kb "$SID")
nested=$(TMPDIR="$S" CLAUDE_CODE_TMPDIR=$T/moved bash "$DW" scratch-kb "$SID")
check "an owned entry inside a measured session directory is counted once" '[ "$baseline" = "$nested" ]'
# A real partial measurement has a valid over-budget row and a failed own entry.
mkdir "$TMPDIR/mv-review-copy.partial" "$TMPDIR/unrelated"
printf 'mv-review-copy-v1\nsession %s\n' "$SID" > "$TMPDIR/mv-review-copy.partial/.megavibe-review-copy"
touch "$S/huge.bin" "$TMPDIR/unrelated/other-huge"
rm -f "$T/p/.agent/LOGS/.scratch-stopped.$SID"
mkdir "$T/partial"
cat > "$T/partial/du" <<'EOS'
#!/bin/bash
case "${@: -1}" in
  */mv-review-copy.partial) printf '1200000\t%s\n' "${@: -1}"; exit 1 ;;
esac
exec "$BASE_DU" "$@"
EOS
chmod +x "$T/partial/du"
export BASE_DU="$T/bin/du"
o=$(PATH="$T/partial:$PATH" stop)
check "Stop passes on a partial measurement even with a known over-budget subtotal" '[ -z "$o" ] && [ ! -e "$T/p/.agent/LOGS/.scratch-stopped.$SID" ]'
o=$(PATH="$T/bin3:$PATH" stop)
check "Stop passes on a timed-out measurement" '[ -z "$o" ] && [ ! -e "$T/p/.agent/LOGS/.scratch-stopped.$SID" ]'
mv "$T/home/.megavibe/scripts/scratch-own.sh" "$T/home/.megavibe/scripts/scratch-own.disabled"
o=$(stop)
check "Stop passes on an unknown ownership measurement" '[ -z "$o" ] && [ ! -e "$T/p/.agent/LOGS/.scratch-stopped.$SID" ]'
mv "$T/home/.megavibe/scripts/scratch-own.disabled" "$T/home/.megavibe/scripts/scratch-own.sh"
mv "$S/huge.bin" "$T/disabled-size"
o=$(stop)
check "Stop passes when only other temp is over budget" '[ -z "$o" ] && [ ! -e "$T/p/.agent/LOGS/.scratch-stopped.$SID" ]'
report=$(CLAUDE_CODE_TMPDIR=$T/moved bash "$DW" scratch "$SID")
check "scratch output reports other temp by name, size and age" 'printf "%s" "$report" | grep -q "other temp usage: unrelated (1100000 kB, [0-9]* min old)"'
touch -t 200001010000 "$T/mid/LOGS/stamp"
report=$(FAKE_AVAIL=$((7*GB)) mid)
check "periodic low-disk report names other temp entries" 'printf "%s" "$report" | grep -q "other temp usage: unrelated"'
check "checks leave own and other entries in place" '[ -f "$S/big.bin" ] && [ -f "$TMPDIR/mv-review-copy.partial/.megavibe-review-copy" ] && [ -f "$TMPDIR/unrelated/other-huge" ]'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
