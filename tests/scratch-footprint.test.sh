#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/scratch-footprint.XXXXXX")
T=$(cd "$T" && pwd -P)
export HOME="$T/home" TMPDIR="$T/tmp" CLAUDE_CODE_TMPDIR="$T/boot scratch"
unset MEGAVIBE_HOME MEGAVIBE_DISK_PATH MEGAVIBE_DISK_WATCH MEGAVIBE_DISK_WARN_GB
export FIXTURE="$T" PATH="$T/bin:$PATH"
DW="$HOME/.megavibe/scripts/disk-watch.sh"
HOOK="$REPO/template/.claude/hooks/disk-check.sh"
WORKTREE="$HOME/.megavibe/worktrees/other project"
mkdir -p "$HOME/.megavibe/scripts" "$TMPDIR/mv-review-copy.fixture" "$TMPDIR/unrelated" \
  "$CLAUDE_CODE_TMPDIR/claude-$(id -u)" "$WORKTREE" "$T/bin" "$T/project/.agent"
cp "$REPO"/scripts/{disk-watch.sh,scratch-root.sh,scratch-own.sh,disk-footprint.py} "$HOME/.megavibe/scripts/"
touch "$WORKTREE/.git" "$TMPDIR/unrelated/keep" "$CLAUDE_CODE_TMPDIR/claude-$(id -u)/keep"
printf 'mv-review-copy-v1\nsession fixture\n' > "$TMPDIR/mv-review-copy.fixture/.megavibe-review-copy"
OWN="$HOME/.megavibe/scripts/scratch-own.sh"
"$OWN" stamp fixture
touch -t 200001010000 "$HOME/.megavibe/scratch-start/fixture"
mkdir -p "$T/old tmp/registered"
TMPDIR="$T/old tmp" "$OWN" register fixture "$T/old tmp/registered"
cat > "$T/bin/df" <<'EOS'
#!/bin/bash
if [[ -n "${DF_LOG:-}" ]]; then printf "df\n" >> "$DF_LOG"; fi
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/x 104857600 95420416 ${FAKE_FREE:-9437184} 91% /"
EOS
cat > "$T/bin/git" <<'EOS'
#!/bin/bash
[[ "$*" == *'worktree list --porcelain -z'* ]] || exit 1
printf 'worktree %s\0\0worktree %s\0\0' "$FIXTURE/outside" "$HOME/.megavibe/worktrees/other project"
EOS
cat > "$T/bin/du" <<'EOS'
#!/bin/bash
for path; do
  case "$path" in
    -* ) continue ;;
    */boot\ scratch/claude-*)
      k=$((${SCRATCH_GB:-50}*1048576))
      if [[ "${STALL:-0}" = 1 ]]; then
        sleep 20 &
        printf '%s\n' "$!" > "$FIXTURE/stalled.pid"
        wait "$!"
      fi
      ;;
    */mv-review-copy.fixture|*/registered) k=1048576 ;;
    */other\ project) k=$((3*1048576)) ;;
    */unrelated|*/outside) k=$((100*1048576)) ;;
    *) k=0 ;;
  esac
  printf '%s\t%s\n' "$k" "$path"
done
EOS
chmod +x "$T/bin/"*
cd "$T/project"
expected='megavibe: 55.0 GB of 91.0 GB used (scratch 50.0 GB, temp 2.0 GB, worktrees 3.0 GB) — major part'
out=$(bash "$DW" footprint)
[[ "$out" = "$expected" ]] || { printf 'unexpected footprint: %s\n' "$out"; exit 1; }
out=$(printf '{}' | bash "$HOOK")
jq -e --arg line "$expected" '.systemMessage | contains($line)' <<< "$out" >/dev/null
jq -e --arg line "$expected" '.hookSpecificOutput.additionalContext | contains($line)' <<< "$out" >/dev/null
out=$(SCRATCH_GB=20 bash "$DW" footprint)
[[ "$out" == *"25.0 GB of 91.0 GB used"* && "$out" == *"less than half" ]]
out=$(printf '{}' | CLAUDE_CODE_TMPDIR= DF_LOG="$T/healthy.df" STALL=1 FAKE_FREE=65011712 bash "$HOOK")
[[ -z "$out" && "$(cat "$T/healthy.df")" = df && ! -e "$T/stalled.pid" ]]
start=$(python3 -c 'import time; print(time.monotonic())')
out=$(STALL=1 bash "$DW" footprint)
elapsed=$(python3 -c 'import sys,time; print(round(time.monotonic()-float(sys.argv[1]),3))' "$start")
[[ "$out" == *incomplete* ]]
pid=$(cat "$T/stalled.pid")
for attempt in 1 2 3; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.03
done
if kill -0 "$pid" 2>/dev/null; then
  [[ "$(ps -p "$pid" -o stat=)" == Z* ]]
fi
awk -v elapsed="$elapsed" 'BEGIN { exit !(elapsed < 4) }'
[[ -f "$TMPDIR/unrelated/keep" && -f "$WORKTREE/.git" && -d "$T/old tmp/registered" &&
   -f "$TMPDIR/mv-review-copy.fixture/.megavibe-review-copy" &&
   -f "$CLAUDE_CODE_TMPDIR/claude-$(id -u)/keep" ]]
printf '%s\nstalled du returned in %ss\n' "$expected" "$elapsed"
