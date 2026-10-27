#!/bin/bash
# /bin/bash tests/trash.test.sh
# The Trash ledger and review (scripts/trash.sh, scripts/trash-review.py,
# hooks/trash-watch.sh), the real-delete guard in block-dangerous-bash.sh and the
# rm-to-trash.sh rewrite. Uses a fake Trash and a fake rmtrash: nothing here
# touches ~/.Trash or ~/.megavibe.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOKS="$REPO/template/.claude/hooks"
T=$(mktemp -d "${TMPDIR:-/tmp}/trash-test.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap '/bin/rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

export MEGAVIBE_TRASH_DIR="$T/Trash" MEGAVIBE_TRASH_LEDGER_DIR="$T/ledger" MEGAVIBE_TRASH_BACKUP_DIR="$T/backup"
mkdir -p "$MEGAVIBE_TRASH_DIR"
# Fake rmtrash: moves each operand into the fake Trash, renaming a clash the way rmtrash does.
cat > "$T/fake-rmtrash" <<'EOF'
#!/bin/bash
rc=0; done_opts=0
for a in "$@"; do
  if [[ $done_opts = 0 && $a == -- ]]; then done_opts=1; continue; fi
  if [[ $done_opts = 0 && $a == -* ]]; then continue; fi
  [[ -e $a || -L $a ]] || { echo "fake-rmtrash: $a: missing" >&2; rc=1; continue; }
  b=$(basename "$a"); d="$MEGAVIBE_TRASH_DIR/$b"
  s=${b%.*}; e=${b#"$s"}; n=0
  while [[ -e $d ]]; do n=$((n + 1)); d="$MEGAVIBE_TRASH_DIR/$s 12-00-00-00$n$e"; done
  mv "$a" "$d"
done
exit $rc
EOF
chmod +x "$T/fake-rmtrash"
mkdir -p "$T/bin"; mv "$T/fake-rmtrash" "$T/bin/rmtrash"; export PATH="$T/bin:$PATH"   # the stand-in IS rmtrash on PATH
TR="$REPO/scripts/trash.sh"
RV="python3 $REPO/scripts/trash-review.py"
ids() { python3 -c 'import json,sys; print(" ".join(json.loads(l)["id"] for l in sys.stdin if json.loads(l)["path"].endswith(sys.argv[1])))' "$1"; }

# 1. Wrapper: records originals and Trash locations, keeps rmtrash's exit status.
W="$T/work"; mkdir -p "$W/d/sub" "$W/x"; echo a > "$W/a.txt"; echo d > "$W/d/sub/f"; echo other > "$W/x/a.txt"
echo old > "$MEGAVIBE_TRASH_DIR/a.txt"            # forces a clash rename for one of the two a.txt
bash "$TR" -rf "$W/a.txt" "$W/d" "$W/x/a.txt"; rc=$?
check "wrapper exit 0" '[ $rc = 0 ]'
check "files gone" '[ ! -e "$W/a.txt" ] && [ ! -e "$W/d" ] && [ ! -e "$W/x/a.txt" ]'
check "three ledger lines" '[ "$(wc -l < "$MEGAVIBE_TRASH_LEDGER_DIR/ledger.jsonl" | tr -d " ")" = 3 ]'
check "every trash_path exists" 'python3 -c "import json,os,sys; sys.exit(0 if all(os.path.exists(json.loads(l)[\"trash_path\"]) for l in open(\"$MEGAVIBE_TRASH_LEDGER_DIR/ledger.jsonl\")) else 1)"'
check "distinct trash paths" '[ "$(python3 -c "import json; print(len({json.loads(l)[\"trash_path\"] for l in open(\"$MEGAVIBE_TRASH_LEDGER_DIR/ledger.jsonl\")}))")" = 3 ]'
bash "$TR" "$W/missing" 2>/dev/null; rc=$?
check "wrapper passes failure through" '[ $rc != 0 ]'
check "missing operand not recorded" '[ "$(wc -l < "$MEGAVIBE_TRASH_LEDGER_DIR/ledger.jsonl" | tr -d " ")" = 3 ]'
check "status counts 3" '$RV status | grep -q "^3 unreviewed"'

# 2. Apply by registered group: keep, restore, backup, droppable. Nothing deletes.
grp() {  # grp <label> <id>...: registers one group, prints "<code>\t<summary>"
  local l=$1; shift
  python3 -c 'import json,sys; print(json.dumps({"groups":[{"label":sys.argv[1],"ids":sys.argv[2:]}]}))' "$l" "$@" > "$T/g.json"
  $RV group "$T/g.json" | sed -n 1p | python3 -c 'import sys,re; l=sys.stdin.read(); s=l.split("  (")[0]; print(re.match(r"\[(G\w+)\]",s).group(1)+"\t"+s)'
}
dec() { printf '{"decisions":[{"group":"%s","action":"%s"}]}' "$1" "$2" > "$T/dec.json"; $RV apply "$T/dec.json"; }
P=$($RV pending --json)
A=$(printf '%s\n' "$P" | ids "/work/a.txt"); D=$(printf '%s\n' "$P" | ids "/work/d"); X=$(printf '%s\n' "$P" | ids "/x/a.txt")
GA=$(grp "a" "$A" | cut -f1); GD=$(grp "d" "$D" | cut -f1)
dec "$GA" restore >/dev/null; dec "$GD" backup >/dev/null
check "restored" '[ "$(cat "$W/a.txt")" = a ]'
check "backed up keeps the original path" '[ "$(cat "$MEGAVIBE_TRASH_BACKUP_DIR"/*/"${W#/}/d/sub/f")" = d ]'
check "unknown group refused" '! dec Gnope keep >/dev/null'
GX=$(grp "x" "$X"); GXC=$(printf '%s' "$GX" | cut -f1); GXS=$(printf '%s' "$GX" | cut -f2-)
check "summary names the group code" 'printf "%s" "$GXS" | grep -q "^\[$GXC\] 1 item"'
XT=$(python3 -c 'import json,sys; print(next(json.loads(l)["trash_path"] for l in open(sys.argv[1]) if json.loads(l)["id"]==sys.argv[2]))' "$MEGAVIBE_TRASH_LEDGER_DIR/ledger.jsonl" "$X")
dec "$GXC" drop >/dev/null 2>&1; rc=$?
check "drop is not an action: nothing deleted" '[ $rc != 0 ] && [ -e "$XT" ]'
dec "$GXC" droppable >/dev/null
check "droppable leaves it in the Trash and reports it" '[ -e "$XT" ] && $RV status | grep -q "^1 item(s).*marked droppable"'
check "user's own Trash item untouched" '[ "$(cat "$MEGAVIBE_TRASH_DIR/a.txt")" = old ]'
check "nothing pending" '$RV status | grep -q "^0 unreviewed"'
echo b > "$W/b"; bash "$TR" "$W/b"; echo again > "$W/b"
GB=$(grp "b" "$($RV pending --json | ids "/work/b")" | cut -f1)
dec "$GB" restore >/dev/null; rc=$?
check "restore refuses to overwrite" '[ $rc != 0 ] && [ "$(cat "$W/b")" = again ] && $RV pending | grep -q "/work/b"'
dec "$GB" keep >/dev/null
check "keep marks reviewed, leaves it in the Trash" '$RV status | grep -q "^0 unreviewed" && ls "$MEGAVIBE_TRASH_DIR" | grep -q "^b mv-"'

# 2b. Regressions from the review rounds.
mkdir -p "$W/build" "$W/audits"; echo build > "$W/build/r.txt"; echo audit > "$W/audits/r.txt"
bash "$TR" "$W/build/r.txt" "$W/audits/r.txt"
GBU=$(grp "build" "$($RV pending --json | ids "/build/r.txt")" | cut -f1)
dec "$GBU" restore >/dev/null
check "same basename: each id keeps its own file" '[ "$(cat "$W/build/r.txt")" = build ] && [ ! -e "$W/audits/r.txt" ]'
AUI=$($RV pending --json | ids "/audits/r.txt"); GAU=$(grp "audit" "$AUI" | cut -f1)
AT=$(python3 -c 'import json,sys; print(next(json.loads(l)["trash_path"] for l in open(sys.argv[1]) if json.loads(l)["id"]==sys.argv[2]))' "$MEGAVIBE_TRASH_LEDGER_DIR/ledger.jsonl" "$AUI")
mv "$AT" "$T/rescued"; echo "user file" > "$AT"
out=$(dec "$GAU" restore 2>&1)
check "stale id never moves a replacement entry" '[ "$(cat "$AT")" = "user file" ] && [ "$(cat "$W/audits/r.txt" 2>/dev/null)" != "user file" ] && printf "%s" "$out" | grep -q "gone or was replaced"'
echo u > "$W/u1"; bash "$TR" "$W/u1"; GU=$(grp "u" "$($RV pending --json | ids "/work/u1")" | cut -f1)
printf '{"decisions":[{"group":"%s","action":"keep"},{"group":"%s","action":"restore"}]}' "$GU" "$GU" > "$T/dup.json"
$RV apply "$T/dup.json" >/dev/null 2>&1; rc=$?
check "duplicate decisions: nothing applied" '[ $rc != 0 ] && $RV pending | grep -q "/work/u1"'
mkdir -p "$W/bk"; echo one > "$W/bk/f"; bash "$TR" "$W/bk/f"
BKI=$($RV pending --json | ids "/bk/f"); GBK=$(grp "bk" "$BKI" | cut -f1)
BD="$MEGAVIBE_TRASH_BACKUP_DIR/$(date +%Y-%m-%d)/${W#/}/bk"; mkdir -p "$BD"; echo x > "$BD/f"; echo y > "$BD/f.$BKI"
dec "$GBK" backup >/dev/null; rc=$?
check "backup never overwrites; the Trash copy stays" '[ $rc != 0 ] && [ "$(cat "$BD/f")" = x ] && [ "$(cat "$BD/f.$BKI")" = y ] && $RV pending | grep -q "/bk/f"'
mkdir -p "$W/pp"; echo p > "$W/pp/f"; bash "$TR" "$W/pp/f"; rmdir "$W/pp"; echo blocker > "$W/pp"
GP=$(grp "pp" "$($RV pending --json | ids "/pp/f")" | cut -f1)
dec "$GP" restore >/dev/null 2>&1; rc=$?
check "failed restore (parent is a file) leaves it in the Trash, still pending" '[ $rc != 0 ] && $RV pending | grep -q "/pp/f" && [ -z "$(ls "$MEGAVIBE_TRASH_LEDGER_DIR/claim" 2>/dev/null)" ]'
LI=$($RV pending --json | ids "/pp/f")
LT=$(python3 -c 'import json,sys; print(next(json.loads(l)["trash_path"] for l in open(sys.argv[1]) if json.loads(l)["id"]==sys.argv[2]))' "$MEGAVIBE_TRASH_LEDGER_DIR/ledger.jsonl" "$LI")
mkdir -p "$MEGAVIBE_TRASH_LEDGER_DIR/claim"; mv "$LT" "$MEGAVIBE_TRASH_LEDGER_DIR/claim/$LI"
dec "$GU" keep >/dev/null 2>&1
check "an interrupted claim is put back by the next apply" '[ -e "$LT" ] && $RV pending | grep -q "/pp/f"'
mkdir -p "$W/real/sub"; ln -s "$W/real/sub" "$W/link"; echo v > "$W/real/victim"
bash "$TR" "$W/link/../victim"
check "symlink then .. : the real path is recorded" '$RV pending | grep -q "$W/real/victim"'
mkdir -p "$W/dd"
bash "$TR" "$W/dd" 2>/dev/null; rc=$?
check "directory without -r refused, left in place" '[ $rc != 0 ] && [ -d "$W/dd" ]'
bash "$TR" -f "$W/nothing-here"; rc=$?
check "-f on a missing file: exit 0" '[ $rc = 0 ]'
echo i > "$W/ii"; bash "$TR" -i "$W/ii" </dev/null
check "-i goes to rmtrash" '[ ! -e "$W/ii" ]'
mkdir -p "$W/sl/sl"; bash "$TR" -r "$W/sl/"; rc=$?
check "trailing slash trashes the directory itself" '[ $rc = 0 ] && [ ! -e "$W/sl" ] && $RV pending | grep -q "$W/sl\$"'
mkdir -p "$W/tgt"; ln -s "$W/tgt" "$W/lnk"; bash "$TR" -r "$W/lnk/" 2>/dev/null; rc=$?
check "trailing slash on a symlink refused" '[ $rc != 0 ] && [ -L "$W/lnk" ] && [ -d "$W/tgt" ]'
mkdir -p "$W/od"; ( cd "$W" && echo m > ./-r && bash "$TR" od -r 2>/dev/null ); rc=$?
check "options end at the first operand (rm od -r)" '[ $rc != 0 ] && [ -d "$W/od" ] && [ ! -e "$W/-r" ]'
bash "$TR" 2>/dev/null; rc=$?
check "no operands: usage error 64" '[ $rc = 64 ]'
bash "$TR" -f; rc=$?
check "-f, no operands: 0" '[ $rc = 0 ]'
echo l > "$W/lf"; MEGAVIBE_TRASH_LEDGER_DIR="$W/lf-not-a-dir" bash -c 'touch "$MEGAVIBE_TRASH_LEDGER_DIR"; bash "$0" "$1"' "$TR" "$W/lf" 2>/dev/null; rc=$?
check "ledger failure keeps the delete's exit status" '[ $rc = 0 ] && [ ! -e "$W/lf" ]'
export MEGAVIBE_TRASH_REVIEW_COUNT=1
echo k > "$W/k1"; bash "$TR" "$W/k1"; $RV nudge >/dev/null
printf '{"groups":[{"label":"all","ids":[%s]}]}' "$($RV pending --json | python3 -c 'import json,sys; print(",".join(json.dumps(json.loads(l)["id"]) for l in sys.stdin))')" > "$T/all.json"
GALL=$($RV group "$T/all.json" | sed -n 1p | sed 's/^\[\(G[0-9a-f]*\)\].*/\1/')
dec "$GALL" keep >/dev/null
$RV nudge >/dev/null
echo k > "$W/k2"; bash "$TR" "$W/k2"
check "re-armed after a review" '[ -n "$($RV nudge)" ]'
unset MEGAVIBE_TRASH_REVIEW_COUNT

# 2c. Round-4 regressions.
echo v > "$W/victim"
MEGAVIBE_TRASH_DIR="$T/no-such-trash" bash "$TR" -f "$W/victim" 2>/dev/null; rc=$?
check "a missing MEGAVIBE_TRASH_DIR refuses instead of falling back" '[ $rc != 0 ] && [ -e "$W/victim" ]'
check "no env override selects the fallback program" '! grep -q MEGAVIBE_RMTRASH "$REPO/scripts/trash.sh" "$REPO/scripts/trash-review.py"'
XV="$T/xvol"; mkdir -p "$XV"; ln -s /etc/hosts "$XV/link"
out=$(python3 - "$REPO/scripts/trash-review.py" "$XV" <<'PY'
import errno, importlib.util as u, os, sys
s = u.spec_from_file_location("tr", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
real = m.rename_noreplace; calls = []
def fake(src, dst):
    calls.append(dst)
    if len(calls) == 1:
        raise OSError(errno.EXDEV, "cross-device")
    return real(src, dst)
m.rename_noreplace = fake
d = sys.argv[2]
moved = m.move_noreplace(os.path.join(d, "link"), os.path.join(d, "copy"))
print(moved, os.path.islink(os.path.join(d, "copy")), os.readlink(os.path.join(d, "copy")), os.path.islink(os.path.join(d, "link")))
PY
)
check "cross-volume: a symlink is copied as a symlink and the source is kept" '[ "$out" = "False True /etc/hosts True" ]'
mkdir -p "$MEGAVIBE_TRASH_LEDGER_DIR/claim"; echo s > "$MEGAVIBE_TRASH_LEDGER_DIR/claim/stray"
check "status reports stranded claims" '$RV status | grep -q "stranded"'
/bin/rm -f "$MEGAVIBE_TRASH_LEDGER_DIR/claim/stray"
export MEGAVIBE_TRASH_REVIEW_COUNT=1
echo a > "$W/na"; bash "$TR" "$W/na"; $RV nudge >/dev/null
GNA=$(grp "na" "$($RV pending --json | ids "/work/na")" | cut -f1); dec "$GNA" keep >/dev/null
echo b > "$W/nb"; bash "$TR" "$W/nb"
check "a review between two deletes does not hide the next crossing" '[ -n "$($RV nudge)" ]'
unset MEGAVIBE_TRASH_REVIEW_COUNT

# 2d. Round-5 regressions.
bash "$TR" -rf ""; rc=$?
check "rm -rf \"\": exit 0 like BSD rm" '[ $rc = 0 ]'
bash "$TR" "" 2>/dev/null; rc=$?
check "rm \"\": exit 1" '[ $rc = 1 ]'
echo o > "$W/occ"; bash "$TR" "$W/occ"
OI=$($RV pending --json | ids "/work/occ"); GO=$(grp "occ" "$OI" | cut -f1)
OT=$(python3 -c 'import json,sys; print(next(json.loads(l)["trash_path"] for l in open(sys.argv[1]) if json.loads(l).get("id")==sys.argv[2]))' "$MEGAVIBE_TRASH_LEDGER_DIR/ledger.jsonl" "$OI")
mkdir -p "$MEGAVIBE_TRASH_LEDGER_DIR/claim"; mv "$OT" "$MEGAVIBE_TRASH_LEDGER_DIR/claim/$OI"; echo squatter > "$OT"
dec "$GU" keep >/dev/null 2>&1
check "a stranded claim whose Trash name is taken goes back under a fresh name" '[ -z "$(ls "$MEGAVIBE_TRASH_LEDGER_DIR/claim")" ] && [ "$(cat "$OT")" = squatter ] && $RV pending | grep -q "/work/occ"'
dec "$GO" restore >/dev/null
check "and can still be restored from there" '[ "$(cat "$W/occ")" = o ]'
FV="$T/fifo-src"; mkdir -p "$FV/d"; mkfifo "$FV/d/pipe"
out=$(python3 - "$REPO/scripts/trash-review.py" "$FV" <<'PY'
import errno, importlib.util as u, os, sys
s = u.spec_from_file_location("tr", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
real = m.rename_noreplace; n = [0]
def fake(src, dst):
    n[0] += 1
    if n[0] == 1: raise OSError(errno.EXDEV, "cross-device")
    return real(src, dst)
m.rename_noreplace = fake
try:
    m.move_noreplace(os.path.join(sys.argv[2], "d"), os.path.join(sys.argv[2], "copy"))
    print("copied")
except OSError as e:
    print("refused", os.path.isdir(os.path.join(sys.argv[2], "d")), os.path.exists(os.path.join(sys.argv[2], "copy")))
PY
)
check "cross-volume copy of a tree with a FIFO is refused, not hung" '[ "$out" = "refused True False" ]'

# 2e. Round-6 regressions.
LONG=$(python3 -c 'print("n" * 250)'); echo l > "$W/$LONG"; bash "$TR" "$W/$LONG"; rc=$?
check "a 250-byte name is trashed and recorded (name cut to fit)" '[ $rc = 0 ] && [ ! -e "$W/$LONG" ] && $RV pending | grep -q "$LONG"'
echo k > "$W/kr"; bash "$TR" "$W/kr"; GKR=$(grp "kr" "$($RV pending --json | ids "/work/kr")" | cut -f1)
dec "$GKR" keep >/dev/null; dec "$GKR" restore >/dev/null; rc=$?
check "Keep now, Restore later still works" '[ $rc = 0 ] && [ "$(cat "$W/kr")" = k ]'
check "pending --all lists kept items" '$RV pending --all | grep -q "/work/b"'
mkdir -p "$W/rl"; ln -s / "$W/rl/root-link"; bash "$TR" "$W/rl/root-link"; rc=$?
check "a symlink to / is just a link: trashed" '[ $rc = 0 ] && [ ! -L "$W/rl/root-link" ]'
mkdir -p "$W/ne/x"; out=$(bash "$TR" -d "$W/ne" 2>&1); rc=$?
check "rm -d on a non-empty dir says Directory not empty" '[ $rc = 1 ] && printf "%s" "$out" | grep -q "Directory not empty"'

# 2f. Round-7 regressions.
echo dk > "$W/dk"; bash "$TR" "$W/dk"; GDK=$(grp "dk" "$($RV pending --json | ids "/work/dk")" | cut -f1)
dcount() { local n; n=$($RV status | sed -n 's/^\([0-9]*\) item(s).*marked droppable.*/\1/p'); echo "${n:-0}"; }
d0=$(dcount); dec "$GDK" droppable >/dev/null; d1=$(dcount); dec "$GDK" keep >/dev/null; d2=$(dcount)
check "a later Keep cancels droppable" '[ "$d1" = $((d0 + 1)) ] && [ "$d2" = "$d0" ]'
mkdir -p "$T/badpy"; printf '#!/bin/sh\nexit 127\n' > "$T/badpy/python3"; chmod +x "$T/badpy/python3"
echo bp > "$W/bp"; PATH="$T/badpy:$PATH" bash "$TR" "$W/bp"; rc=$?
check "a broken python3 falls back to rmtrash instead of failing every rm" '[ $rc = 0 ] && [ ! -e "$W/bp" ]'

# 3. Nudge: once per crossing, re-armed after a review.
export MEGAVIBE_TRASH_REVIEW_COUNT=2
for i in 1 2; do echo $i > "$W/n$i"; done; bash "$TR" "$W/n1" "$W/n2"
check "nudges at the threshold" '[ -n "$($RV nudge)" ]'
check "silent the second time" '[ -z "$($RV nudge)" ]'
echo 3 > "$W/n3"; bash "$TR" "$W/n3"
check "silent below the next crossing" '[ -z "$($RV nudge)" ]'
echo 4 > "$W/n4"; bash "$TR" "$W/n4"
check "nudges again after another threshold" '[ -n "$($RV nudge)" ]'

# 4. The hook: main thread only, JSON with the procedure.
PROJ="$T/proj"; mkdir -p "$PROJ/.agent" "$T/home/.megavibe/scripts"
cp "$REPO/scripts/trash-review.py" "$T/home/.megavibe/scripts/"
echo 5 > "$W/n5"; echo 6 > "$W/n6"; bash "$TR" "$W/n5" "$W/n6"
out=$(cd "$PROJ" && echo '{"agent_id":"x"}' | HOME="$T/home" bash "$HOOKS/trash-watch.sh")
check "hook silent for a subagent" '[ -z "$out" ]'
out=$(cd "$PROJ" && echo '{}' | HOME="$T/home" bash "$HOOKS/trash-watch.sh")
check "hook emits the review procedure" 'printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext | test(\"AskUserQuestion\")" >/dev/null'
out=$(cd "$PROJ" && echo '{}' | HOME="$T/home" bash "$HOOKS/trash-watch.sh")
check "hook silent once nudged" '[ -z "$out" ]'
out=$(cd "$PROJ" && echo '{"session_id":"s-one"}' | HOME="$T/home" bash "$HOOKS/trash-watch.sh")
check "a review deferred by one session is raised again in the next" 'printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext" >/dev/null'
out=$(cd "$PROJ" && echo '{"session_id":"s-one"}' | HOME="$T/home" bash "$HOOKS/trash-watch.sh")
check "and only once in that session" '[ -z "$out" ]'
out=$(cd "$PROJ" && echo '{"session_id":"s-two"}' | HOME="$T/home" bash "$HOOKS/trash-watch.sh")
check "a third session is told too" '[ -n "$out" ]'
err=$(cd "$PROJ" && echo '{}' | HOME="$T/home" MEGAVIBE_TRASH_LEDGER_DIR="$T/l2" bash -c 'mkdir -p "$MEGAVIBE_TRASH_LEDGER_DIR"; echo "{}" > "$MEGAVIBE_TRASH_LEDGER_DIR/ledger.jsonl"; bash "$0"; bash "$0"' "$HOOKS/trash-watch.sh" 2>&1 >/dev/null)
check "hook quiet on stderr before the first review" '[ -z "$err" ]'
unset MEGAVIBE_TRASH_REVIEW_COUNT

# 5. Real-delete guard.
bd() { printf '%s' "$1" | jq -Rs '{tool_input:{command:.}}' | env "${@:2}" bash "$HOOKS/block-dangerous-bash.sh" 2>/dev/null; echo $?; }
check "python heredoc rmtree blocked" '[ "$(bd "python3 - <<EOF
import shutil
shutil.rmtree(\"/tmp/x\")
EOF")" = 2 ]'
check "python -c os.remove blocked" '[ "$(bd "python3 -c \"import os; os.remove(\x27/tmp/x\x27)\"")" = 2 ]'
SUBP="python3 -c \"import subprocess; subprocess.run(['rm', '-rf', '/tmp/x'])\""
check "python subprocess rm blocked" '[ "$(bd "$SUBP")" = 2 ]'
check "node rmSync blocked" '[ "$(bd "node -e \"require(\x27fs\x27).rmSync(\x27x\x27,{recursive:true})\"")" = 2 ]'
check "perl unlink blocked" '[ "$(bd "perl -e \"unlink \$_ for glob q(*.log)\"")" = 2 ]'
check "find -delete blocked" '[ "$(bd "find /tmp/x -name \"*.log\" -delete")" = 2 ]'
check "unlink blocked" '[ "$(bd "unlink /tmp/x")" = 2 ]'
check "git clean -fd blocked" '[ "$(bd "git clean -fd")" = 2 ]'
check "bash -c find -delete blocked" '[ "$(bd "bash -c \"find . -delete\"")" = 2 ]'
FSRM="node -e \"const fs=require('fs'); fs.rm('x',{recursive:true},()=>{});\""
check "node fs.rm blocked" '[ "$(bd "$FSRM")" = 2 ]'
BINRM="python3 -c \"import subprocess; subprocess.run(['/bin/rm','-rf','x'])\""
check "python /bin/rm subprocess blocked" '[ "$(bd "$BINRM")" = 2 ]'
check "redirect before unlink blocked" '[ "$(bd "2>/dev/null unlink x")" = 2 ]'
check "find -exec unlink blocked" '[ "$(bd "find x -type f -exec unlink {} \;")" = 2 ]'
check "git clean -f -- -notes blocked" '[ "$(bd "git clean -f -- -notes")" = 2 ]'
check "documented over-block: an interpreter word next to a delete API, even as text" '[ "$(bd "echo python3 os.remove")" = 2 ]'
check "rg for an API without an interpreter word allowed" '[ "$(bd "rg -n os.remove scripts/")" = 0 ]'
check "uv run python rmtree blocked" '[ "$(bd "uv run python -c \"import shutil; shutil.rmtree(1)\"")" = 2 ]'
check "find with escaped parens -delete blocked" '[ "$(bd "find x \\( -type f -delete \\)")" = 2 ]'
check "quoted substitution unlink blocked" '[ "$(bd "echo \"\$(unlink x)\"")" = 2 ]'
check "bash heredoc find -delete blocked" '[ "$(bd "bash <<EOF
find x -delete
EOF")" = 2 ]'
SHT="python3 -c \"import subprocess; subprocess.run('rm -rf x', shell=True)\""
check "python shell=True rm blocked" '[ "$(bd "$SHT")" = 2 ]'
REQ="node -e \"require('fs').rm('x',()=>{})\""
check "require(fs).rm blocked" '[ "$(bd "$REQ")" = 2 ]'
check "from os import remove blocked" '[ "$(bd "python3 -c \"from os import remove; remove(1)\"")" = 2 ]'
check "uv run --project . python3 rmtree blocked" '[ "$(bd "uv run --project . python3 -c \"import shutil; shutil.rmtree(1)\"")" = 2 ]'
check "backslash-newline split interpreter blocked" '[ "$(bd "pyth\\
on3 -c \"import shutil; shutil.rmtree(1)\"")" = 2 ]'
ESCQ='python3 -c "import os; os.remove(\"x\")"'
check "escaped quote in python -c blocked (tokenizer fails closed)" '[ "$(bd "$ESCQ")" = 2 ]'
EVQ="node --eval='require(\"fs\").rmSync(\"x\")'"
check "node --eval= with a mid-word quote blocked" '[ "$(bd "$EVQ")" = 2 ]'
NIMP="node --input-type=module -e 'import {rm} from \"node:fs/promises\"; await rm(\"x\")'"
check "node imported rm blocked" '[ "$(bd "$NIMP")" = 2 ]'
NDES="node -e 'const {rm}=require(\"fs/promises\"); rm(\"x\")'"
check "node destructured rm blocked" '[ "$(bd "$NDES")" = 2 ]'
check "npx rimraf blocked" '[ "$(bd "npx rimraf dist")" = 2 ]'
check "perl rmdir blocked" '[ "$(bd "perl -e \"rmdir q(x)\"")" = 2 ]'
check "eval unlink blocked" '[ "$(bd "eval '\''unlink x'\''")" = 2 ]'
check "grouped find -exec unlink blocked" '[ "$(bd "find x \\( -type f \\) -exec unlink {} \\;")" = 2 ]'
check "rm -P blocked" '[ "$(bd "rm -P x")" = 2 ]'
check "shred blocked" '[ "$(bd "shred -u x")" = 2 ]'
check "srm blocked" '[ "$(bd "srm x")" = 2 ]'
check "rm with a -P-looking operand after a file allowed" '[ "$(bd "rm x -Pnotes")" = 0 ]'
check "commit message about find -delete allowed" '[ "$(bd "git commit -m '\''Block find x -delete in the guard'\''")" = 0 ]'
check "single-quoted \$(unlink) is text, allowed" '[ "$(bd "printf %s '\''\$(unlink x)'\''")" = 0 ]'
check "plain node build allowed" '[ "$(bd "node build.js")" = 0 ]'
NESTED="bash -c 'python3 -c \"import os; os.remove(\\\"x\\\")\"'"
check "nested escaped-quote python in bash -c blocked" '[ "$(bd "$NESTED")" = 2 ]'
check "env bash heredoc unlink blocked" '[ "$(bd "env bash <<EOF
unlink x
EOF")" = 2 ]'
check "cat heredoc with \$(unlink) blocked" '[ "$(bd "cat <<EOF
\$(unlink x)
EOF")" = 2 ]'
FPY="find . \\( -name x \\) -exec python3 -c 'import os,sys; os.unlink(sys.argv[1])' {} \\;"
check "find -exec python3 os.unlink blocked" '[ "$(bd "$FPY")" = 2 ]'
NML="node --input-type=module -e 'import {rm} from \"node:fs/promises\";
await rm(\"x\")'"
check "multi-line node import rm blocked" '[ "$(bd "$NML")" = 2 ]'
check "find -exec sh -c rm blocked" '[ "$(bd "find . -name x -exec sh -c '\''rm \"\$1\"'\'' _ {} \\;")" = 2 ]'
check "xargs sh -c rm blocked" '[ "$(bd "ls | xargs -I{} sh -c '\''rm -rf {}'\''")" = 2 ]'
check "bash -c rm blocked" '[ "$(bd "bash -c '\''rm -rf /tmp/x'\''")" = 2 ]'
check "import os as o; o.remove blocked" '[ "$(bd "python3 -c \"import os as o; o.remove(1)\"")" = 2 ]'
check "git clean -e value is not -n" '[ "$(bd "git clean -fd -e -notes")" = 2 ]'
check "echo rimraf allowed" '[ "$(bd "echo rimraf")" = 0 ]'
check "rg rimraf allowed" '[ "$(bd "rg rimraf package.json")" = 0 ]'
check "python list.remove allowed" '[ "$(bd "python3 -c \"a=[1]; a.remove(1)\"")" = 0 ]'
check "bash -c without rm allowed" '[ "$(bd "bash -c '\''ls -la'\''")" = 0 ]'
check "bash heredoc rm blocked" '[ "$(bd "bash <<'\''EOF'\''
rm -rf victim
EOF")" = 2 ]'
check "bash -c for-loop rm blocked" '[ "$(bd "bash -c '\''for f in v; do rm -f \"\$f\"; done'\''")" = 2 ]'
check "sh -c exec rm blocked" '[ "$(bd "sh -c '\''exec rm -rf victim'\''")" = 2 ]'
check "bash -c with escaped quotes then rm blocked" '[ "$(bd "bash -c \"printf \\\"ok\\n\\\"; rm -rf victim\"")" = 2 ]'
check "bash -c ls | xargs rm blocked" '[ "$(bd "bash -c '\''ls | xargs rm'\''")" = 2 ]'
check "pipe into sh blocked" '[ "$(bd "echo '\''rm x'\'' | sh")" = 2 ]'
check "awk system rm blocked" '[ "$(bd "ls | awk '\''{system(\"rm -rf \" \$1)}'\''")" = 2 ]'
check "git clean -nd && git clean -fd blocked" '[ "$(bd "git clean -nd && git clean -fd")" = 2 ]'
check "git clean -fd -enode_modules blocked" '[ "$(bd "git clean -fd -enode_modules")" = 2 ]'
check "git first does not exempt a later bash -c find -delete" '[ "$(bd "git status; bash -c \"find . -name v -delete\"")" = 2 ]'
check "git first does not exempt a later \$(unlink)" '[ "$(bd "git status; echo \"\$(unlink victim)\"")" = 2 ]'
check "if unlink blocked" '[ "$(bd "if unlink victim; then true; fi")" = 2 ]'
check "nice -n 5 unlink blocked" '[ "$(bd "nice -n 5 unlink victim")" = 2 ]'
check "sudo -u root unlink blocked" '[ "$(bd "sudo -u root unlink victim")" = 2 ]'
check "log append naming an API (no interpreter run) allowed" '[ "$(bd "printf '\''python shutil.rmtree is blocked'\'' | ./agent-log.sh append")" = 0 ]'
check "commit message naming find -delete allowed" '[ "$(bd "git commit -m '\''block find x -delete'\''")" = 0 ]'
check "plain rm with a bash script after it allowed" '[ "$(bd "rm -rf build && bash build.sh")" = 0 ]'
QSUB="result=\"\$(python3 -c 'import os; os.unlink(\"victim\")')\""
check "interpreter inside a quoted \$( ) blocked" '[ "$(bd "$QSUB")" = 2 ]'
check "bash -c inside a quoted \$( ) blocked" '[ "$(bd "echo \"\$(bash -c '\''rm -rf victim'\'')\"")" = 2 ]'
check "find -exec ... \\; -delete blocked" '[ "$(bd "find . -name v -exec test -f {} \\; -delete")" = 2 ]'
check "git clean -dfenode_modules blocked" '[ "$(bd "git clean -dfenode_modules")" = 2 ]'
check "/bin/rm inside bash -c blocked" '[ "$(bd "bash -c '\''/bin/rm -rf victim'\''")" = 2 ]'
check "\\rm -P blocked" '[ "$(bd "\\rm -P victim")" = 2 ]'
check "env -S rm blocked" '[ "$(bd "env -S '\''rm -rf victim'\''")" = 2 ]'
SPF="python3 -c 'import subprocess; subprocess.run([\"find\", \"victim\", \"-delete\"])'"
check "python subprocess find -delete blocked" '[ "$(bd "$SPF")" = 2 ]'
check "python os.system git clean blocked" '[ "$(bd "python3 -c \"import os; os.system('\''git clean -fdx'\'')\"")" = 2 ]'
check "trap rm EXIT blocked" '[ "$(bd "T=\$(mktemp -d); trap '\''rm -rf \"\$T\"'\'' EXIT")" = 2 ]'
check "eval rm blocked" '[ "$(bd "eval rm x")" = 2 ]'
check "echo rm x | sh blocked" '[ "$(bd "echo rm x | sh")" = 2 ]'
check "quoted rm at command position blocked" '[ "$(bd "\"rm\" x")" = 2 ]'
check "rm held in a variable blocked" '[ "$(bd "RM=rm; \$RM x")" = 2 ]'
check "\$(which rm) blocked" '[ "$(bd "\$(which rm) x")" = 2 ]'
check "git rm -f blocked" '[ "$(bd "git rm -f notes.md")" = 2 ]'
check "__import__ os remove blocked" '[ "$(bd "python3 -c \"__import__('\''os'\'').remove('\''x'\'')\"")" = 2 ]'
check "git rm without -f allowed" '[ "$(bd "git rm notes.md")" = 0 ]'
check "commit message heredoc through cat allowed" '[ "$(bd "git commit -m \"\$(cat <<'\''EOF'\''
use rm -rf, find -delete and git clean -f in bash scripts
EOF
)\"")" = 0 ]'
check "notes heredoc through cat allowed" '[ "$(bd "cat > notes.md <<'\''EOF'\''
rimraf x; shred y; python and rm
EOF")" = 0 ]'
check "cleanup() function with trap allowed" '[ "$(bd "cleanup() { rm -rf \"\$T\"; }; trap cleanup EXIT")" = 0 ]'
PATH_IN="bash -c true;$(python3 -c 'print(" 2>&1" * 60 + " xargs" + " " * 4000)')"
t0=$SECONDS; bd "$PATH_IN" >/dev/null; t1=$SECONDS
check "pathological input finishes within the guard's time bound" '[ $((t1 - t0)) -le 4 ]'
check "guard inactive without rmtrash (rm would be real anyway)" '[ "$(PATH=/usr/bin:/bin bd "git clean -fd")" = 0 ]'
check "heredoc piped into bash blocked" '[ "$(bd "cat <<'\''EOF'\'' | bash
rm -rf victim
EOF")" = 2 ]'
check "heredoc fed to bash after the marker blocked" '[ "$(bd "<<'\''EOF'\'' bash
find . -name v -delete
EOF")" = 2 ]'
BTQ="result=\"\`python3 -c 'import os; os.unlink(\"victim\")'\`\""
check "interpreter inside quoted backticks blocked" '[ "$(bd "$BTQ")" = 2 ]'
check "git clean -dfe -notes blocked" '[ "$(bd "git clean -dfe -notes")" = 2 ]'
check "r\\m blocked" '[ "$(bd "r\\m victim")" = 2 ]'
check "\\rm -f allowed (rm-to-trash rewrites it)" '[ "$(bd "\\rm -f victim")" = 0 ]'
check "git rm -rf --cached allowed" '[ "$(bd "git rm -rf --cached .idea")" = 0 ]'
mkdir -p "$T/h2/.megavibe/scripts"; cp "$REPO/scripts/trash.sh" "$T/h2/.megavibe/scripts/"; chmod +x "$T/h2/.megavibe/scripts/trash.sh"
check "guard inactive without rmtrash even when trash.sh is installed" '[ "$(bd "git clean -fd" HOME="$T/h2" PATH=/usr/bin:/bin)" = 0 ]'
check "xargs unlink (operands on stdin) blocked" '[ "$(bd "find victim -type f -print0 | xargs -0 -n 1 unlink")" = 2 ]'
check "parallel shred blocked" '[ "$(bd "ls | parallel shred")" = 2 ]'
check "fd -x rm blocked" '[ "$(bd "fd -e tmp -x rm")" = 2 ]'
check "a comment cannot make git clean a dry run" '[ "$(bd "git clean -fd # previewed with -n")" = 2 ]'
check "a comment cannot add --cached to git rm -f" '[ "$(bd "git rm -f victim # use --cached to keep local files")" = 2 ]'
check "a heredoc piped on to a shell after its terminator blocked" '[ "$(bd "cat <<'\''EOF'\'' |
rm -rf victim
EOF
bash")" = 2 ]'
check "quotes in an unquoted heredoc do not hide a substitution" '[ "$(bd "cat <<EOF
'\''\$(unlink victim)'\''
EOF")" = 2 ]'
check "quoted -delete still counts" '[ "$(bd "find victim '\''-delete'\''")" = 2 ]'
check "quoted -fd still counts" '[ "$(bd "git clean \"-fd\"")" = 2 ]'
check "rm split by a line continuation blocked" '[ "$(bd "r\\
m -f victim")" = 2 ]'
check "git clean without -f (config) blocked" '[ "$(bd "git -c clean.requireForce=false clean -d")" = 2 ]'
check "a hyphenated heredoc marker does not hide later lines" '[ "$(bd "cat > n.md <<'\''END-X'\''
note
END-X
find . -name '\''*.o'\'' -delete")" = 2 ]'
check "<< in arithmetic does not hide later lines" '[ "$(bd "echo \$((1 << SHIFT))
git clean -fdx")" = 2 ]'
check "xargs grep for rm text allowed" '[ "$(bd "git ls-files | xargs grep -n \"rm -rf\"")" = 0 ]'
check "xargs sh -c with quoted rm still blocked" '[ "$(bd "ls | xargs -I{} sh -c '\''rm -rf {}'\''")" = 2 ]'
check "a line continuation between words allowed" '[ "$(bd "git status \\
  --short")" = 0 ]'
check "a # inside a word is not a comment" '[ "$(bd "git clean -fd -e notes#1")" = 2 ]'
P=$'echo "foo\n# bar"; unlink x'; check "a # inside a multi-line double quote is not a comment" '[ "$(bd "$P")" = 2 ]'
P=$'echo \'foo\n# bar\'; git clean -fd'; check "a # inside a multi-line single quote is not a comment" '[ "$(bd "$P")" = 2 ]'
P=$'echo hi # foo \\\ngit clean -fd'; check "a comment ending in a backslash does not swallow the next line" '[ "$(bd "$P")" = 2 ]'
P=$'echo hi # foo \\\nfind . -delete'; check "... nor a find -delete on it" '[ "$(bd "$P")" = 2 ]'
P=$'ls | xargs -I{} "rm" {}'; check "xargs \"rm\" blocked" '[ "$(bd "$P")" = 2 ]'
P=$'ls | xargs -n1 \'rm\''; check "xargs 'rm' blocked" '[ "$(bd "$P")" = 2 ]'
P=$'true;r\\\nm -f x'; check "r\<nl>m after ; blocked" '[ "$(bd "$P")" = 2 ]'
P=$'(r\\\nm -f x)'; check "r\<nl>m in a subshell blocked" '[ "$(bd "$P")" = 2 ]'
P=$'echo $(r\\\nm -f x)'; check "r\<nl>m in $( ) blocked" '[ "$(bd "$P")" = 2 ]'
P=$'r\\\n\\\nm -f x'; check "r\<nl>\<nl>m blocked" '[ "$(bd "$P")" = 2 ]'
P=$'git ls-files | xargs grep -n unlink'; check "xargs grep for unlink text allowed" '[ "$(bd "$P")" = 0 ]'
P=$'echo ${x:- #}; unlink x'; check "# inside a parameter expansion is not a comment" '[ "$(bd "$P")" = 2 ]'
P=$'fd -HIx rm'; check "fd -HIx rm blocked" '[ "$(bd "$P")" = 2 ]'
P=$'fdfind -e tmp -x rm'; check "fdfind -x rm blocked" '[ "$(bd "$P")" = 2 ]'
P=$'echo "a << Q"\nunlink x\nQ'; check "<< inside quotes is not a heredoc" '[ "$(bd "$P")" = 2 ]'
P=$'find . -exec "rm" {} +'; check "find -exec \"rm\" blocked" '[ "$(bd "$P")" = 2 ]'
P=$'git status # then git clean -fd'; check "a real comment still hides its text" '[ "$(bd "$P")" = 0 ]'
P=$'git log \\\n  --oneline -1'; check "a continuation between words still allowed" '[ "$(bd "$P")" = 0 ]'
P=$'find . | xargs sudo unlink'; check "xargs sudo unlink blocked" '[ "$(bd "$P")" = 2 ]'
P=$'find . | xargs -0 nice unlink'; check "xargs -0 nice unlink blocked" '[ "$(bd "$P")" = 2 ]'
P=$'find . | xargs env X=1 unlink'; check "xargs env X=1 unlink blocked" '[ "$(bd "$P")" = 2 ]'
P=$'find . | xargs -n1 command unlink'; check "xargs command unlink blocked" '[ "$(bd "$P")" = 2 ]'
P=$'arch -arm64 unlink x'; check "arch unlink blocked" '[ "$(bd "$P")" = 2 ]'
P=$'git commit -m "$(cat <<\'EOF\'\nSay "hi" and "bye\nunlink x\nEOF\n)"'; check "a commit heredoc with an odd number of double quotes is prose" '[ "$(bd "$P")" = 0 ]'
P=$'echo "$(bash <<\'EOF\'\nunlink x\nEOF\n)"'; check "a heredoc run by bash inside quoted \$( ) still blocked" '[ "$(bd "$P")" = 2 ]'
P=$'gfind victim -delete'; check "gfind -delete blocked" '[ "$(bd "$P")" = 2 ]'
P=$'git grep -n \'shutil.rmtree\' -- python/'; check "grep for rmtree under python/ allowed" '[ "$(bd "$P")" = 0 ]'
P=$'grep -R -n \'os.remove\' node/'; check "grep for os.remove under node/ allowed" '[ "$(bd "$P")" = 0 ]'
P=$'git commit -m \'fix: RM=rm fallback\''; check "commit message naming RM=rm allowed" '[ "$(bd "$P")" = 0 ]'
P=$'git commit -m \'Document $(which rm) lookup\''; check "commit message naming \$(which rm) allowed" '[ "$(bd "$P")" = 0 ]'
P=$'RM=$(which rm); $RM x'; check "RM=\$(which rm) still blocked" '[ "$(bd "$P")" = 2 ]'
P=$'command "rm" victim'; check "command \"rm\" blocked" '[ "$(bd "$P")" = 2 ]'
P=$'"/bin/rm" victim'; check "\"/bin/rm\" blocked" '[ "$(bd "$P")" = 2 ]'
P=$'command r\\m victim'; check "command r\\m blocked" '[ "$(bd "$P")" = 2 ]'
P=$'git commit -m "Block \\`find -delete\\` and \\`unlink\\`"'; check "escaped backticks in a commit message are text" '[ "$(bd "$P")" = 0 ]'
P=$'git commit -m "Refuse \\`git clean -f\\`"'; check "escaped backticks naming git clean are text" '[ "$(bd "$P")" = 0 ]'
P=$'echo "`unlink x`"'; check "real backticks in double quotes still run, blocked" '[ "$(bd "$P")" = 2 ]'
P=$'"$(which rm)" victim'; check "quoted \$(which rm) blocked" '[ "$(bd "$P")" = 2 ]'
P=$'command $(which rm) victim'; check "command \$(which rm) blocked" '[ "$(bd "$P")" = 2 ]'
P=$'sudo $(which rm) victim'; check "sudo \$(which rm) blocked" '[ "$(bd "$P")" = 2 ]'
P=$'find . -exec $(which rm) {} +'; check "find -exec \$(which rm) blocked" '[ "$(bd "$P")" = 2 ]'
P=$'echo don\\\'t; RM=rm; $RM victim; echo don\\\'t'; check "an escaped apostrophe opens no quote" '[ "$(bd "$P")" = 2 ]'
P=$'command -v "rm"'; check "command -v \"rm\" is a lookup, allowed" '[ "$(bd "$P")" = 0 ]'
P=$'git commit -m \'Block (command "rm" victim) bypass\''; check "parentheses inside a quoted message are text" '[ "$(bd "$P")" = 0 ]'
P=$'git commit -m \'Document $(which rm) lookup\''; check "single-quoted \$(which rm) is text" '[ "$(bd "$P")" = 0 ]'
P=$'$(command -v rm) victim'; check "\$(command -v rm) blocked" '[ "$(bd "$P")" = 2 ]'
P=$'"$(command -v rm)" victim'; check "quoted \$(command -v rm) blocked" '[ "$(bd "$P")" = 2 ]'
P=$'$(type -p rm) victim'; check "\$(type -p rm) blocked" '[ "$(bd "$P")" = 2 ]'
P=$'command -v rm'; check "plain command -v rm allowed" '[ "$(bd "$P")" = 0 ]'
check "git clean -n allowed" '[ "$(bd "git clean -nd")" = 0 ]'
check "python without deletes allowed" '[ "$(bd "python3 -c \"print(1)\"")" = 0 ]'
check "commit message mentioning rmtree allowed" '[ "$(bd "git commit -m \"replace shutil.rmtree with rmtrash\"")" = 0 ]'
check "find without -delete allowed" '[ "$(bd "find . -name \"*.log\"")" = 0 ]'
check "plain rm allowed (rewritten elsewhere)" '[ "$(bd "rm -rf /tmp/x")" = 0 ]'
check "human escape hatch" '[ "$(bd "unlink /tmp/x" MEGAVIBE_ALLOW_REAL_DELETE=1)" = 0 ]'
check "inline prefix is not the escape hatch" '[ "$(bd "MEGAVIBE_ALLOW_REAL_DELETE=1 unlink /tmp/x")" = 2 ]'

# 6. rm-to-trash: every rm goes to the recording wrapper; the old scratch skip is opt-in.
if command -v rmtrash >/dev/null; then
  cp "$REPO/scripts/trash.sh" "$T/home/.megavibe/scripts/"; chmod +x "$T/home/.megavibe/scripts/trash.sh"
  rt() { local o; o=$(printf '%s' "$1" | jq -Rs '{tool_name:"Bash",tool_input:{command:.}}' | env HOME="$T/home" "${@:2}" bash "$HOOKS/rm-to-trash.sh")
         if [ -z "$o" ]; then echo UNCHANGED; else printf '%s' "$o" | jq -r '.hookSpecificOutput.updatedInput.command'; fi; }
  check "tmp rm goes to the wrapper" '[ "$(rt "rm -rf /tmp/mv-scratch-x")" = "$T/home/.megavibe/scripts/trash.sh -rf /tmp/mv-scratch-x" ]'
  check "scratch skip is opt-in" '[ "$(rt "rm -rf /tmp/mv-scratch-x" MEGAVIBE_RM_SCRATCH_REAL=1)" = UNCHANGED ]'
  check "durable path goes to the wrapper" '[ "$(rt "rm -rf /opt/mv-nobody/x")" = "$T/home/.megavibe/scripts/trash.sh -rf /opt/mv-nobody/x" ]'
  check "rm-to-trash: -W-looking filename after an operand still goes to the Trash" '[ "$(rt "rm -rf /opt/mv-nobody/x -Wnotes")" = "$T/home/.megavibe/scripts/trash.sh -rf /opt/mv-nobody/x -Wnotes" ]'
  check "rm-to-trash: parallel --halt now,fail=1 rm is rewritten" '[ "$(rt "parallel --halt now,fail=1 rm ::: /opt/mv-nobody/a")" = "parallel --halt now,fail=1 $T/home/.megavibe/scripts/trash.sh ::: /opt/mv-nobody/a" ]'
  check "rm-to-trash: parallel --joblog f rm is rewritten" '[ "$(rt "parallel --joblog jobs.log rm ::: /opt/mv-nobody/a")" = "parallel --joblog jobs.log $T/home/.megavibe/scripts/trash.sh ::: /opt/mv-nobody/a" ]'
  check "rm-to-trash: parallel rm is rewritten" '[ "$(rt "parallel rm ::: /opt/mv-nobody/a /opt/mv-nobody/b")" = "parallel $T/home/.megavibe/scripts/trash.sh ::: /opt/mv-nobody/a /opt/mv-nobody/b" ]'
  check "rm-to-trash: /usr/bin/env rm is rewritten" '[ "$(rt "/usr/bin/env rm /opt/mv-nobody/x")" = "/usr/bin/env $T/home/.megavibe/scripts/trash.sh /opt/mv-nobody/x" ]'
  /bin/rm -f "$T/home/.megavibe/scripts/trash.sh"
  check "without the wrapper, plain rmtrash" '[ "$(rt "rm /opt/mv-nobody/x")" = "$(command -v rmtrash) /opt/mv-nobody/x" ]'
else
  echo "skip: rmtrash not installed, rm-to-trash checks not run"
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
