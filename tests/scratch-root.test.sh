#!/bin/bash
# /bin/bash tests/scratch-root.test.sh — scratch-root.sh (CLAUDE_CODE_TMPDIR honoured, default unchanged) and
# disk-watch.sh (relative warn line, critical clamp, signed df, mount names, moved root in the sizes scan).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/scratch-root-test.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0 FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
SR=$REPO/scripts/scratch-root.sh DW=$REPO/scripts/disk-watch.sh
U=$(id -u); case "$(uname -s)" in Darwin) DEF=/private/tmp ;; *) DEF=/tmp ;; esac
unset CLAUDE_CODE_TMPDIR MEGAVIBE_DISK_WARN_GB MEGAVIBE_DISK_CRIT_GB

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
a=${FAKE_AVAIL:-900000000}; t=${FAKE_TOTAL:-1000000000}
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/x $t $((t - a)) $a $((100 - a * 100 / t))% /"
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
check "461 GB disk with 69.5 GB free is OK (no rounding to whole GB)" '[ "$(FAKE_TOTAL=$((461*GB)) FAKE_AVAIL=$((69*GB+GB/2)) lvl)" = OK ]'
check "461 GB disk with 69.0 GB free is LOW" '[ "$(FAKE_TOTAL=$((461*GB)) FAKE_AVAIL=$((69*GB)) lvl)" = LOW ]'
check "MEGAVIBE_DISK_CRIT_GB=50 on a 460 GB disk: 45 GB free is CRITICAL (not clamped to the default warn line)" '[ "$(MEGAVIBE_DISK_CRIT_GB=50 FAKE_TOTAL=$((460*GB)) FAKE_AVAIL=$((45*GB)) lvl)" = CRITICAL ]'
check "check prints the critical line it classifies with (50 GB)" 'MEGAVIBE_DISK_CRIT_GB=50 PATH="$T/bin:$PATH" FAKE_TOTAL=$((460*GB)) FAKE_AVAIL=$((45*GB)) bash "$DW" check | head -1 | grep -q "critical < 50.0 GB"'
# a mount name that ends in N% is not taken for the capacity column
mkdir -p "$T/bin4"; printf '#!/bin/bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/x 482344960 434110464 48234496 90%% /Volumes/SSD 100%%"\n' > "$T/bin4/df"; chmod +x "$T/bin4/df"
check "a mount named 'SSD 100%' still parses (46 GB free of 460 GB: LOW)" '[ "$(PATH="$T/bin4:$PATH" bash "$DW" level)" = LOW ]'
# negative available space parses and is CRITICAL
mkdir -p "$T/bin5"; printf '#!/bin/bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/x 1000000 1001024 -1024 101%% /Volumes/full"\n' > "$T/bin5/df"; chmod +x "$T/bin5/df"
check "negative available space parses and is CRITICAL" '[ "$(PATH="$T/bin5:$PATH" bash "$DW" level)" = CRITICAL ]'
# a failing df is UNKNOWN, never OK
mkdir -p "$T/bin6"; printf '#!/bin/bash\nexit 1\n' > "$T/bin6/df"; chmod +x "$T/bin6/df"
check "a failing df gives UNKNOWN" '[ "$(PATH="$T/bin6:$PATH" bash "$DW" level)" = UNKNOWN ]'

# a moved root with a space in its path is listed by the sizes scan
mkdir -p "$T/my disk/claude-$U/-p/x"; head -c 105000000 /dev/zero > "$T/my disk/claude-$U/-p/x/f"
check "top lists a moved root whose path has a space" 'CLAUDE_CODE_TMPDIR="$T/my disk" bash "$DW" top | grep -q "my disk"'
check "with the variable unset the moved root is not listed" '! bash "$DW" top | grep -q "my disk"'
# watch-background.sh finds a background task's output file under a moved root
mkdir -p "$T/home/.megavibe/scripts" "$T/p/.agent/LOGS" "$T/p/.claude/hooks" "$T/moved/claude-$U/-proj/sess/tasks"
cp "$SR" "$T/home/.megavibe/scripts/"; cp "$REPO/template/.claude/hooks/watch-background.sh" "$T/p/.claude/hooks/"
echo x > "$T/moved/claude-$U/-proj/sess/tasks/tmv1.output"
hk() { printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"s1","tool_input":{"run_in_background":true,"command":"sleep 5","description":"d"},"tool_response":{"backgroundTaskId":"tmv1"}}' \
  | (cd "$T/p" && env HOME="$T/home" "$@" bash .claude/hooks/watch-background.sh); }
check "the task output path under a moved root is found" 'hk CLAUDE_CODE_TMPDIR="$T/moved" | jq -r .hookSpecificOutput.additionalContext | grep -q "$T/moved/claude-$U/-proj/sess/tasks/tmv1.output"'
check "with the variable unset that path is not found" '! hk | jq -r .hookSpecificOutput.additionalContext | grep -q "$T/moved/claude-$U"'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
