#!/bin/bash
# /bin/bash tests/trash.test.sh
# The Trash ledger and review (scripts/trash.sh, scripts/trash-review.py,
# hooks/trash-watch.sh), the real-delete guard in block-dangerous-bash.sh and the
# rm-to-trash.sh rewrite, and the Trash greenlight (scripts/trash-empty.sh, its
# gate in block-dangerous-bash.sh, setup.sh's ask-rule merge, and the provenance decision: sections 7-10). Uses a
# fake Trash, a fake rmtrash and fake HOMEs: nothing here touches ~/.Trash,
# ~/.megavibe or ~/.claude, and the real trash-empty.sh is never run from its
# install path (the tests run copies installed under a scratch HOME).
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


# 7. The first net in block-dangerous-bash.sh. The lock is the script itself (sections 8 and 10: it runs only when
# Claude Code's shell was asked for exactly the asked command); this hook lets that one spelling reach the permission
# prompt and refuses the commands that name the script, so the agent gets a clear message instead of a later refusal.
gt() {  # gt <exit status wanted> <command text> <name> [env VAR=value ...]
  local want=$1 cmd=$2 name=$3 got; shift 3
  got=$(bd "$cmd" "$@")
  if [ "$got" = "$want" ]; then ok; else bad "$name (wanted $want, got $got)"; fi
}
SC='~/.megavibe/scripts/trash-empty.sh'
U=/Users   # a literal /Users/<name>/ in a tracked file trips scripts/leak-scan.sh
gt 0 "$SC" "gate: the asked spelling reaches the prompt"
gt 0 "$SC --all" "gate: --all reaches the prompt"
gt 0 "  $SC" "gate: leading blanks"
gt 0 "$SC"$'\n' "gate: trailing newline"
gt 2 "bash $SC" "gate: bash <script> refused"
gt 2 "sh $SC" "gate: sh <script> refused"
gt 2 "$U/x/.megavibe/scripts/trash-empty.sh" "gate: absolute spelling refused"
gt 2 '$HOME/.megavibe/scripts/trash-empty.sh' "gate: \$HOME spelling refused"
gt 2 '${HOME}/.megavibe/scripts/trash-empty.sh' "gate: \${HOME} spelling refused"
gt 2 "env X=1 $SC" "gate: env prefix refused"
gt 2 "X=1 $SC" "gate: assignment prefix refused"
gt 2 "HOME=/tmp/x $SC" "gate: HOME= prefix refused"
gt 2 "sh -c '$SC'" "gate: sh -c refused"
gt 2 "bash -c \"$SC\"" "gate: bash -c refused"
gt 2 ". $SC" "gate: . <script> refused"
gt 2 "source $SC" "gate: source <script> refused"
gt 2 "$SC && echo ok" "gate: && refused"
gt 2 "echo hi; $SC" "gate: another command in the same call refused"
gt 2 "$SC;" "gate: trailing ; refused"
gt 2 "$SC # why" "gate: trailing comment refused"
gt 2 "$SC --all --now" "gate: extra flag refused"
gt 2 "$SC --yes" "gate: --yes refused"
gt 2 "$SC"$'\nls' "gate: a second line refused"
gt 2 "$SC"$'\n--all' "gate: a newline is not a blank before --all"
gt 2 "$SC"$' \\\n--all' "gate: a continuation before --all refused"
gt 2 "$SC --all && echo done" "gate: --all then another command refused"
gt 2 "cp $SC /tmp/x" "gate: cp refused"
gt 2 "ln -s $SC /tmp/x" "gate: ln -s refused"
gt 2 "cat $SC" "gate: reading it with cat is an over-block (use the Read tool)"
gt 2 'git commit -m "add trash-empty"' "gate: documented over-block, asserted so a change is deliberate"
gt 2 "git add scripts/trash-empty.sh" "gate: documented over-block (git add the directory instead)"
gt 0 "git add scripts/" "gate: git add of the directory allowed"
gt 2 "~/.megavibe/scripts/trash-em*.sh" "gate: glob after trash-em refused"
gt 2 "~/.megavibe/scripts/trash-e*" "gate: trash-e* refused"
gt 2 "~/.megavibe/scripts/trash-{empty,x}.sh" "gate: brace expansion that spells the name refused"
gt 2 '~/.megavibe/scripts/"trash"-"empty".sh' "gate: quoted pieces refused"
gt 2 "~/.megavibe/scripts/tr''ash-empty.sh" "gate: empty quotes inside the name refused"
gt 2 '~/.megavibe/scripts/t\rash-empty.sh' "gate: backslash inside the name refused"
gt 2 '~/.megavibe/scripts/TRASH-EMPTY.SH' "gate: upper case refused"
gt 2 "~/.megavibe/scripts/tra\\"$'\n'"sh-empty.sh" "gate: line continuation inside the name refused"
gt 2 "cd ~/.megavibe/scripts && ./trash-empty.sh" "gate: cd then the name refused"
gt 2 "python3 -c \"import subprocess; subprocess.run(['$U/x/.megavibe/scripts/trash-empty.sh'])\"" "gate: interpreter spelling refused"
gt 2 "~/.m*/scripts/t*-e*sh" "gate: a globbed dot directory that can complete to .megavibe refused"
gt 2 "~/.meg?vibe/scripts/x" "gate: ? in the dot directory refused"
gt 2 'echo hi; $HOME/.m?gavibe/scripts/x' "gate: \$HOME with a ? glob refused"
gt 2 "osascript -e 'tell application \"Terminal\" to do script \"~/.megavibe/scripts/x\"'" "gate: osascript naming ~/.megavibe refused"
gt 2 "open -a Terminal ~/.megavibe/scripts/x.sh" "gate: a new Terminal window naming ~/.megavibe refused"
gt 2 "launchctl submit -l x -- ~/.megavibe/scripts/x" "gate: launchctl naming ~/.megavibe refused"
# Not names of the script: ordinary commands the first cut over-blocked.
gt 0 "ls ~/.m2/repository/*" "gate: a Maven glob allowed"
gt 0 "du -sh ~/.m2/*" "gate: du of ~/.m2 allowed"
gt 0 "cat ~/.mcp*.json" "gate: ~/.mcp*.json allowed"
gt 0 'ls $HOME/.mozilla/firefox/*.default' "gate: a Firefox profile glob allowed"
gt 0 "cat trash-events.log" "gate: trash-events.log allowed"
gt 0 "echo trash-export" "gate: trash-export allowed"
gt 0 "ls ~/.megavibe/scripts/*.sh" "gate: listing the scripts directory by glob allowed"
gt 0 "for f in ~/.megavibe/scripts/*.sh; do :; done" "gate: a loop over the scripts directory allowed"
gt 0 "cd ~/.megavibe/scripts && ls" "gate: cd into the scripts directory allowed"
gt 0 "osascript -e 'display dialog \"hi\"'" "gate: an unrelated osascript allowed"
gt 0 "python3 ~/.megavibe/scripts/trash-review.py status" "gate: trash-review.py status still allowed"
gt 0 "python3 ~/.megavibe/scripts/trash-review.py droppable --json" "gate: trash-review.py droppable allowed"
gt 0 "bash ~/.megavibe/scripts/trash.sh -rf /tmp/x" "gate: trash.sh still allowed"
gt 0 "~/.megavibe/scripts/codex-review.sh --as-reviewer --prompt x f.md" "gate: other scripts in the directory still allowed"
gt 0 "ls ~/.megavibe/scripts/" "gate: listing the directory allowed"
gt 0 "cd ~/dev/megavibe && git status" "gate: cd into a repo named megavibe allowed"
gt 0 "cd $U/x/dev/megavibe/scripts && ls" "gate: cd into the repo's own scripts allowed"
gt 0 "ls ~/.claude/*.md" "gate: a glob under ~/.claude allowed"
gt 0 "cat ~/.cache/*" "gate: a glob under another dot directory allowed"
gt 0 "ls ~/.*" "gate: a lone ~/.* allowed"
gt 0 "bash -n scripts/*.sh" "gate: a repo-relative scripts glob allowed"
gt 0 "ls $U/x/dev/megavibe/scripts/*.sh" "gate: the repo's own scripts glob allowed"
gt 0 "git status" "gate: unrelated command allowed"
# First net only: these reach the script (they name nothing the hook can see). Each is covered in section 10, where the
# script refuses them because Claude Code's shell was not asked for exactly the asked command.
gt 0 "cd -P ~/.megavibe/scripts && ./tr*h-e* --all" "net only: cd -P then a glob (the script refuses it: section 10)"
gt 0 "cd -- ~/.megavibe/scripts; ./tr*h-e*" "net only: cd -- then a glob"
gt 0 "env -C ~/.megavibe/scripts ./tr*h-e*" "net only: env -C"
gt 0 'D=~/.megavibe/scripts; $D/tr*h-e*' "net only: a variable holding the directory"
gt 0 "find ~/.megavibe/scripts -name 'tr*h-e*' -exec {} \\;" "net only: find -exec"
gt 0 "~//.megavibe//scripts/t*-e*.sh --all" "net only: doubled slashes and a glob"
# Without python3 the gate still decides (it is bash and grep only), and the crude fallback further down would
# otherwise refuse the asked form (it greps for the word "trash-empty").
mkdir -p "$T/nopy"
for _t in jq tr grep cat sed awk head tail basename dirname wc date uname; do ln -sf "$(command -v $_t)" "$T/nopy/$_t"; done
check "no-python PATH really has no python3" '( hash -r; PATH="$T/nopy:/bin"; ! command -v python3 >/dev/null 2>&1 )'
gt 0 "$SC" "gate without python3: asked spelling reaches the prompt" PATH="$T/nopy:/bin"
gt 0 "$SC --all" "gate without python3: --all reaches the prompt" PATH="$T/nopy:/bin"
gt 2 "bash $SC" "gate without python3: bash <script> refused" PATH="$T/nopy:/bin"
gt 2 'git commit -m "add trash-empty"' "gate without python3: over-block kept" PATH="$T/nopy:/bin"
gt 0 "python3 ~/.megavibe/scripts/trash-review.py status" "gate without python3: trash-review.py status allowed" PATH="$T/nopy:/bin"
# The Trash guard behind it is unchanged: the generic emptying forms are still refused.
gt 2 "trash-empty" "trash guard: the command word trash-empty refused"
gt 2 "osascript -e 'tell application \"Finder\" to empty the trash'" "trash guard: Finder empty refused"

# 8. trash-empty.sh itself. Every test runs a scratch COPY installed under a fake HOME, made from the real script by
# replacing the few marked one-line test points (the home the user database would name, the managed-settings path, the
# OS name, the provenance gate, the interleaving hook). The deletion, the claim, the rules check and the environment
# handling are the real code. MEGAVIBE_TRASH_DIR and MEGAVIBE_TRASH_LEDGER_DIR stay exported at the top of this file
# on purpose: the script has to ignore them.
RAW_TE="$REPO/scripts/trash-empty.sh"
check "trash-empty.sh passes bash -n and is executable with a -p shebang" 'bash -n "$RAW_TE" && [ -x "$RAW_TE" ] && [ "$(head -n 1 "$RAW_TE")" = "#!/bin/bash -p" ]'
for _m in TE_OS TE_MANAGED TE_GATE TE_HOME TE_HOOK; do
  check "the test point $_m is one line in the real script" '[ "$(grep -c "# $_m\$" "$RAW_TE")" = 1 ]'
done
RULES_JSON='{"permissions":{"ask":["Bash(~/.megavibe/scripts/trash-empty.sh *)","Bash(*trash-empty*)"]}}'
HOOKDIR="$T/hooks"; mkdir -p "$HOOKDIR"
mk_copy() {  # mk_copy <dest> <home> [nogate|gate] [hook 0|1] [os name]
  local dest=$1 h=$2 gate=${3:-nogate} hook=${4:-0} osn=${5:-darwin} sedf="$T/te.sed"
  {
    printf 's|^MANAGED = .*|MANAGED = "%s"  # TE_MANAGED|\n' "$T/managed.json"
    printf 's|^def db_home(): .*|def db_home(): return "%s"  # TE_HOME|\n' "$h"
    printf 's|^OS_NAME = .*|OS_NAME = "%s"  # TE_OS|\n' "$osn"
    if [ "$gate" = nogate ]; then printf 's|^REQUIRE_PROVENANCE = .*|REQUIRE_PROVENANCE = False  # TE_GATE|\n'; fi
    if [ "$hook" = 1 ]; then
      printf 's|^def _hook(point, \\*\\*kw): .*|def _hook(point, **kw): exec(open("%s/" + point + ".py").read(), dict(globals(), **kw)) if os.path.exists("%s/" + point + ".py") else None  # TE_HOOK|\n' "$HOOKDIR" "$HOOKDIR"
    fi
  } > "$sedf"
  sed -f "$sedf" "$RAW_TE" > "$dest"; chmod +x "$dest"
}
mk_home() {  # mk_home <dir> [settings json] [nogate|gate] [hook 0|1] [os name]: a complete fake HOME with a copy installed
  local h=$1
  mkdir -p "$h/.Trash" "$h/.megavibe/scripts" "$h/.megavibe/trash" "$h/.claude"
  cp "$REPO/scripts/trash-review.py" "$h/.megavibe/scripts/"
  mk_copy "$h/.megavibe/scripts/trash-empty.sh" "$h" "${3:-nogate}" "${4:-0}" "${5:-darwin}"
  printf '%s\n' "${2:-$RULES_JSON}" > "$h/.claude/settings.json"
}
run_in() { local h=$1; shift; env -u CLAUDE_CONFIG_DIR HOME="$h" "$h/.megavibe/scripts/trash-empty.sh" "$@"; }
oid() { stat -f '%d %i' "$1"; }                                        # dev ino of the entry itself (lstat)
forge() {  # forge <home> <id> <trash_path> <"dev ino"> <original path> [decision]: a ledger row, and optionally a review decision
  local h=$1 dv in; dv=${4% *}; in=${4#* }
  jq -nc --arg id "$2" --arg tp "$3" --argjson dev "$dv" --argjson ino "$in" --arg path "$5" \
    '{ts:"t", id:$id, path:$path, kind:"file", trash_path:$tp, dev:$dev, ino:$ino, kb:1, cwd:"/", session:""}' >> "$h/.megavibe/trash/ledger.jsonl"
  if [ -n "${6:-}" ]; then
    jq -nc --arg id "$2" --arg a "$6" '{id:$id, ts:"t", action:$a, ok:true, detail:"forged"}' >> "$h/.megavibe/trash/reviewed.jsonl"
  fi
}
H="$T/th"; mk_home "$H"
te()  { run_in "$H" "$@"; }
tr_() { env HOME="$H" MEGAVIBE_TRASH_DIR="$H/.Trash" MEGAVIBE_TRASH_LEDGER_DIR="$H/.megavibe/trash" bash "$TR" "$@"; }
rv_() { env HOME="$H" MEGAVIBE_TRASH_DIR="$H/.Trash" MEGAVIBE_TRASH_LEDGER_DIR="$H/.megavibe/trash" python3 "$H/.megavibe/scripts/trash-review.py" "$@"; }
ids_() { python3 -c 'import json,sys; print(" ".join(json.loads(l)["id"] for l in sys.stdin if json.loads(l)["path"].endswith(sys.argv[1])))' "$1"; }
mark_() {  # mark_ <action> <path suffix>...: one group per call, then apply (the real review)
  local act=$1 sfx; shift
  local idl; idl=$(for sfx in "$@"; do rv_ pending --all --json | ids_ "$sfx"; done | tr '\n' ' ')
  python3 -c 'import json,sys; print(json.dumps({"groups":[{"label":"t","ids":sys.argv[1:]}]}))' $idl > "$T/tg.json"
  local code; code=$(rv_ group "$T/tg.json" | sed -n 's/^\[\(G[0-9a-f]*\)\].*/\1/p' | head -n 1)
  printf '{"decisions":[{"group":"%s","action":"%s"}]}' "$code" "$act" > "$T/td.json"
  rv_ apply "$T/td.json" >/dev/null
}
lsT() { ls -A "$H/.Trash" | LC_ALL=C sort; }
check "the rewritten copy points at the scratch home and managed file" 'grep -q "^def db_home(): return \"$H\"" "$H/.megavibe/scripts/trash-empty.sh" && grep -q "^MANAGED = \"$T/managed.json\"" "$H/.megavibe/scripts/trash-empty.sh"'
TW="$T/tw"; mkdir -p "$TW/dropdir/sub" "$TW/keep-me" "$TW/pending-me" "$T/outside"
echo d > "$TW/dropdir/sub/f"; echo k > "$TW/keep-me/f"; echo p > "$TW/pending-me/f"
echo own > "$H/.Trash/own.txt"
tr_ -r "$TW/dropdir" "$TW/keep-me" "$TW/pending-me"
mark_ droppable "/dropdir"; mark_ keep "/keep-me"
check "droppable lists exactly the marked item" '[ "$(rv_ droppable --json | wc -l | tr -d " ")" = 1 ] && rv_ droppable | grep -q "/dropdir$"'
check "droppable --json carries id, trash_path, dev, ino, kb, path" 'rv_ droppable --json | jq -e "has(\"id\") and has(\"trash_path\") and has(\"dev\") and has(\"ino\") and has(\"kb\") and has(\"path\")" >/dev/null'
check "status points at the script" 'rv_ status | grep -q "marked droppable: ~/.megavibe/scripts/trash-empty.sh frees them"'
GT_BEFORE=$(ls -A "$MEGAVIBE_TRASH_DIR" | LC_ALL=C sort | tr '\n' '|'); GL_BEFORE=$(cat "$MEGAVIBE_TRASH_LEDGER_DIR/reviewed.jsonl" 2>/dev/null | wc -c | tr -d ' ')
out=$(te 2>&1); rc=$?
check "droppable mode: exit 0" '[ $rc = 0 ]'
check "droppable mode: the marked item is gone" '! ls "$H/.Trash" | grep -q "^dropdir mv-"'
check "droppable mode: kept, pending and the human own items remain" 'ls "$H/.Trash" | grep -q "^keep-me mv-" && ls "$H/.Trash" | grep -q "^pending-me mv-" && [ "$(cat "$H/.Trash/own.txt")" = own ]'
check "droppable mode: nothing outside the fake HOME was touched (inherited env ignored)" '[ "$(ls -A "$MEGAVIBE_TRASH_DIR" | LC_ALL=C sort | tr "\n" "|")" = "$GT_BEFORE" ] && [ "$(cat "$MEGAVIBE_TRASH_LEDGER_DIR/reviewed.jsonl" 2>/dev/null | wc -c | tr -d " ")" = "$GL_BEFORE" ]'
check "droppable mode: reviewed.jsonl gains an emptied row for it" 'jq -e "select(.action==\"emptied\" and .ok==true)" "$H/.megavibe/trash/reviewed.jsonl" >/dev/null'
check "droppable mode: status no longer lists it" '! rv_ status | grep -q "marked droppable"'
check "droppable mode: the summary names what happened" 'printf "%s" "$out" | grep -q "^mode=droppable emptied=1 failed=0 skipped=0"'
check "droppable mode: empty.log has the line, with the user" 'grep -q " user=$(id -un) mode=droppable emptied=1 failed=0" "$H/.megavibe/trash/empty.log"'
check "droppable mode: no quarantine directory is left in the Trash" '! ls -A "$H/.Trash" | grep -q "^.megavibe-empty-"'
n0=$(wc -l < "$H/.megavibe/trash/empty.log" | tr -d ' ')
out=$(te 2>&1); rc=$?
check "nothing droppable: exit 0 and says so" '[ $rc = 0 ] && printf "%s" "$out" | grep -q "nothing marked droppable"'
check "nothing droppable: one log line per run, even this one" '[ "$(wc -l < "$H/.megavibe/trash/empty.log" | tr -d " ")" = $((n0 + 1)) ]'
check "nothing droppable: the Trash is unchanged" 'ls "$H/.Trash" | grep -q "^keep-me mv-"'
# an entry that is a symlink: the link goes, its target stays
mkdir -p "$T/linktarget"; echo precious > "$T/linktarget/f"; ln -s "$T/linktarget" "$TW/lnk"
tr_ "$TW/lnk"; mark_ droppable "/lnk"
out=$(te 2>&1); rc=$?
check "symlink in the Trash: the link is removed, exit 0" '[ $rc = 0 ] && ! ls -A "$H/.Trash" | grep -q "^lnk mv-"'
check "symlink in the Trash: its target is intact" '[ "$(cat "$T/linktarget/f")" = precious ]'
# a replaced entry (same name, other object): the script's own check refuses it
echo r > "$TW/swap"; tr_ "$TW/swap"; mark_ droppable "/swap"
SWT=$(ls "$H/.Trash" | grep '^swap mv-'); mv "$H/.Trash/$SWT" "$T/swap-rescued"; echo impostor > "$H/.Trash/$SWT"
out=$(te 2>&1); rc=$?
check "replaced entry: skipped and reported, exit 1" '[ $rc = 1 ] && printf "%s" "$out" | grep -q "replaced since it was marked droppable"'
check "replaced entry: the replacement survives" '[ "$(cat "$H/.Trash/$SWT")" = impostor ]'
/bin/rm -f "$H/.Trash/$SWT"
# a failing delete is reported, recorded as not ok, the rest of that entry keeps its name, and the next item still goes
mkdir -p "$TW/stuck/sub"; echo s > "$TW/stuck/sub/f"; echo n > "$TW/next"
tr_ -r "$TW/stuck" "$TW/next"; mark_ droppable "/stuck" "/next"
STK=$(ls "$H/.Trash" | grep '^stuck mv-'); chmod 500 "$H/.Trash/$STK/sub"
out=$(te 2>&1); rc=$?
check "a delete that fails: exit 1, the next item still goes" '[ $rc = 1 ] && ! ls "$H/.Trash" | grep -q "^next mv-" && printf "%s" "$out" | grep -q "emptied=1 failed=1"'
check "a failed delete is recorded ok:false and the rest gets its name back" 'jq -e "select(.action==\"emptied\" and .ok==false)" "$H/.megavibe/trash/reviewed.jsonl" >/dev/null && [ -d "$H/.Trash/$STK" ]'
check "a failed delete leaves no quarantine behind" '! ls -A "$H/.Trash" | grep -q "^.megavibe-empty-"'
chmod -R u+w "$H/.Trash/$STK" 2>/dev/null
# the failed row is not a decision: the item is still droppable and goes once the cause is fixed
rv_ droppable | grep -q "/stuck$"; rcd=$?
te >/dev/null 2>&1
check "after the cause is fixed the same item goes" '[ $rcd = 0 ] && ! ls "$H/.Trash" | grep -q "^stuck mv-"'
# --all: everything in the Trash, including what no ledger knows
printf 'x' > "$H/.Trash/-n"; printf 'y' > "$H/.Trash/has space"; mkdir -p "$H/.Trash/adir/in"; echo z > "$H/.Trash/adir/in/f"
printf 'nl' > "$H/.Trash/$(printf 'new\nline')"
out=$(te --all 2>&1); rc=$?
check "--all: exit 0 and the Trash is empty" '[ $rc = 0 ] && [ -z "$(ls -A "$H/.Trash")" ]'
check "--all: a file named -n, a name with a space, a newline name and a user directory are gone" 'printf "%s" "$out" | grep -q "^emptied: \"-n\"$" && printf "%s" "$out" | grep -q "^emptied: \"has space\"$" && printf "%s" "$out" | grep -q "^emptied: \"new\\\\nline\"$"'
check "--all: ledger items get emptied rows, so nothing stays pending" 'rv_ status | grep -q "^0 unreviewed" && jq -e "select(.action==\"emptied\" and .ok==true and .path != \"\")" "$H/.megavibe/trash/reviewed.jsonl" >/dev/null'
check "--all: logged as mode=all" 'grep -q "mode=all emptied=" "$H/.megavibe/trash/empty.log"'
check "--all on an empty Trash: exit 0" 'te --all >/dev/null 2>&1'
# usage
out=$(te --yes 2>&1); rc=$?; check "--yes: usage error 2" '[ $rc = 2 ] && printf "%s" "$out" | grep -q usage'
te --all --yes >/dev/null 2>&1; rc=$?; check "--all --yes: usage error 2" '[ $rc = 2 ]'
te -h >/dev/null 2>&1; rc=$?; check "-h: usage error 2" '[ $rc = 2 ]'
te --dry-run >/dev/null 2>&1; rc=$?; check "--dry-run does not exist: 2" '[ $rc = 2 ]'
# the review procedure offers the script, only in its asked spelling, and never --all unprompted
mkdir -p "$T/projg/.agent"; echo h > "$TW/h1"; tr_ "$TW/h1"
out=$(cd "$T/projg" && echo '{"session_id":"s-greenlight"}' | env HOME="$H" MEGAVIBE_TRASH_DIR="$H/.Trash" MEGAVIBE_TRASH_LEDGER_DIR="$H/.megavibe/trash" MEGAVIBE_TRASH_REVIEW_COUNT=1 bash "$HOOKS/trash-watch.sh")
check "the review procedure ends with the greenlight step" 'printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext | test(\"6\\\\. If .*trash-empty\\\\.sh.*Never add .*--all\")" >/dev/null'
check "the review procedure no longer says only the user empties the Trash" '! printf "%s" "$out" | jq -r ".hookSpecificOutput.additionalContext" | grep -q "only the user empties it"'

# Codex's inputs, and the interleavings. Each uses its own fake home and a hand-written ledger.
H7="$T/th7"; mk_home "$H7"; echo victim > "$H7/.Trash/kept.txt"; echo mine > "$H7/.Trash/target.txt"
ln -s "$H7/.Trash" "$H7/.Trash/self"
forge "$H7" selfsym "$H7/.Trash/self/" "$(oid "$H7/.Trash/self/")" "/orig/self" droppable
out=$(run_in "$H7" 2>&1); rc=$?
check "a trailing-slash self symlink recorded as droppable: skipped, nothing else in the Trash is touched" '[ $rc = 1 ] && [ "$(cat "$H7/.Trash/kept.txt")" = victim ] && [ "$(cat "$H7/.Trash/target.txt")" = mine ] && [ -L "$H7/.Trash/self" ]'
H8="$T/th8"; mk_home "$H8"; echo a > "$H8/.Trash/droppable-a"; echo b > "$H8/.Trash/kept-b"
FSEP=$'\037'; KB_DEV=$(oid "$H8/.Trash/kept-b" | cut -d' ' -f1); KB_INO=$(oid "$H8/.Trash/kept-b" | cut -d' ' -f2)
INJ="normal"$'\n'"forged${FSEP}${KB_DEV}${FSEP}${KB_INO}${FSEP}1${FSEP}/original/victim${FSEP}$H8/.Trash/kept-b"$'\n'"end"
forge "$H8" idA "$H8/.Trash/droppable-a" "$(oid "$H8/.Trash/droppable-a")" "$INJ" droppable
forge "$H8" idB "$H8/.Trash/kept-b" "$(oid "$H8/.Trash/kept-b")" "/orig/b" keep
out=$(run_in "$H8" 2>&1); rc=$?
check "newline and field separators in a recorded path inject nothing: the droppable item goes, the kept one stays" '[ $rc = 0 ] && [ ! -e "$H8/.Trash/droppable-a" ] && [ "$(cat "$H8/.Trash/kept-b")" = b ]'
H9="$T/th9"; mk_home "$H9"; NLN=$(printf 'odd\nname\037x'); printf 'z' > "$H9/.Trash/$NLN"
forge "$H9" idN "$H9/.Trash/$NLN" "$(oid "$H9/.Trash/$NLN")" "/orig/odd" droppable
out=$(run_in "$H9" 2>&1); rc=$?
check "a Trash name with a newline and a separator is emptied correctly" '[ $rc = 0 ] && [ -z "$(ls -A "$H9/.Trash")" ]'
H10="$T/th10"; mk_home "$H10"; echo o > "$H10/.Trash/obj"
forge "$H10" idOld "$H10/.Trash/obj" "$(oid "$H10/.Trash/obj")" "/orig/obj" droppable
forge "$H10" idNew "$H10/.Trash/obj" "$(oid "$H10/.Trash/obj")" "/orig/obj" keep
out=$(run_in "$H10" 2>&1); rc=$?
check "two records for one object, one droppable and one kept: skipped, kept" '[ $rc = 1 ] && [ "$(cat "$H10/.Trash/obj")" = o ] && printf "%s" "$out" | grep -q "not marked droppable"'
H11="$T/th11"; mk_home "$H11"; echo o > "$H11/.Trash/obj"
forge "$H11" idOld "$H11/.Trash/obj" "$(oid "$H11/.Trash/obj")" "/orig/obj" restore
forge "$H11" idNew "$H11/.Trash/obj" "$(oid "$H11/.Trash/obj")" "/orig/obj" droppable
run_in "$H11" >/dev/null 2>&1; rc=$?
check "an older record that was restored does not block a newer droppable one" '[ $rc = 0 ] && [ ! -e "$H11/.Trash/obj" ]'
# a ledger entry outside the Trash, or through a symlinked directory, is never followed
H2="$T/th2"; mk_home "$H2"; echo victim > "$T/outside/victim"; mkdir -p "$T/outside/dir"; echo v2 > "$T/outside/dir/victim"; ln -s "$T/outside/dir" "$H2/.Trash/via"
forge "$H2" f1 "$T/outside/victim" "$(oid "$T/outside/victim")" "/x" droppable
forge "$H2" f2 "$H2/.Trash/via/victim" "$(oid "$T/outside/dir/victim")" "/x" droppable
forge "$H2" f3 "$H2/.Trash/../th2/.Trash/x" "1 1" "/x" droppable
out=$(run_in "$H2" 2>&1); rc=$?
check "a trash_path outside the Trash, through a symlinked directory or with .. : skipped, files kept, exit 1" '[ $rc = 1 ] && [ "$(cat "$T/outside/victim")" = victim ] && [ "$(cat "$T/outside/dir/victim")" = v2 ] && printf "%s" "$out" | grep -c "not a direct child" | grep -q 3'
# the check/use races, simulated by a hook that exists only in the rewritten test copy
H12="$T/th12"; mk_home "$H12" "$RULES_JSON" nogate 1; echo orig > "$H12/.Trash/item"
forge "$H12" idR "$H12/.Trash/item" "$(oid "$H12/.Trash/item")" "/orig/item" droppable
printf '%s\n' 'os.rename(home + "/.Trash/" + name, home + "/aside-" + name)' 'open(home + "/.Trash/" + name, "w").write("impostor")' > "$HOOKDIR/after_check.py"
out=$(run_in "$H12" 2>&1); rc=$?
/bin/rm -f "$HOOKDIR/after_check.py"
check "replaced after the check: the claim finds another object, puts it back, deletes nothing" '[ $rc = 1 ] && [ "$(cat "$H12/.Trash/item")" = impostor ] && [ "$(cat "$H12/aside-item")" = orig ] && printf "%s" "$out" | grep -q "replaced since it was marked"'
H13="$T/th13"; mk_home "$H13" "$RULES_JSON" nogate 1; echo orig > "$H13/.Trash/item"; mkdir -p "$T/swapout"; echo outside > "$T/swapout/item"
forge "$H13" idS "$H13/.Trash/item" "$(oid "$H13/.Trash/item")" "/orig/item" droppable
printf '%s\n' 'os.rename(home + "/.Trash", home + "/Trash.orig")' "os.symlink(\"$T/swapout\", home + \"/.Trash\")" > "$HOOKDIR/after_open_trash.py"
out=$(run_in "$H13" 2>&1); rc=$?
/bin/rm -f "$HOOKDIR/after_open_trash.py"
check ".Trash swapped for a symlink after it was opened: the reviewed item goes, the file outside survives" '[ $rc = 0 ] && [ "$(cat "$T/swapout/item")" = outside ] && [ ! -e "$H13/Trash.orig/item" ]'
H14="$T/th14"; mk_home "$H14" "$RULES_JSON" nogate 1; echo orig > "$H14/.Trash/item"
forge "$H14" idC "$H14/.Trash/item" "$(oid "$H14/.Trash/item")" "/orig/item" droppable
printf '%s\n' 'open(home + "/.Trash/" + name, "w").write("late")' > "$HOOKDIR/after_claim.py"
out=$(run_in "$H14" 2>&1); rc=$?
/bin/rm -f "$HOOKDIR/after_claim.py"
check "a new file at the old name after the claim is not touched by the delete" '[ $rc = 0 ] && [ "$(cat "$H14/.Trash/item")" = late ]'

# where it may run from
echo keep > "$H/.Trash/guard.txt"
mkdir -p "$T/other-home"
env HOME="$T/other-home" "$H/.megavibe/scripts/trash-empty.sh" >/dev/null 2>&1; rc=$?
check "another HOME than the user database names: exit 3" '[ $rc = 3 ]'
cp "$H/.megavibe/scripts/trash-empty.sh" "$T/copy.sh"; env -u CLAUDE_CONFIG_DIR HOME="$H" "$T/copy.sh" >/dev/null 2>&1; rc=$?
check "a copy elsewhere: exit 3" '[ $rc = 3 ]'
ln -s "$H/.megavibe/scripts/trash-empty.sh" "$T/ln.sh"; env -u CLAUDE_CONFIG_DIR HOME="$H" "$T/ln.sh" >/dev/null 2>&1; rc=$?
check "a symlink to it: exit 3" '[ $rc = 3 ]'
ln -s trash-empty.sh "$H/.megavibe/scripts/alias.sh"; env -u CLAUDE_CONFIG_DIR HOME="$H" "$H/.megavibe/scripts/alias.sh" >/dev/null 2>&1; rc=$?
check "a symlink beside it in the install directory: exit 3" '[ $rc = 3 ]'
cp "$H/.megavibe/scripts/trash-empty.sh" "$H/.megavibe/scripts/other-name.sh"; env -u CLAUDE_CONFIG_DIR HOME="$H" "$H/.megavibe/scripts/other-name.sh" >/dev/null 2>&1; rc=$?
check "a copy under another name in the install directory: exit 3" '[ $rc = 3 ]'
env -u CLAUDE_CONFIG_DIR HOME="$H" bash "$H/.megavibe/scripts/trash-empty.sh" >/dev/null 2>&1; rc=$?
check "bash <script> is refused (privileged mode is what keeps the environment out): exit 3" '[ $rc = 3 ]'
env -u CLAUDE_CONFIG_DIR HOME="$H" sh "$H/.megavibe/scripts/trash-empty.sh" >/dev/null 2>&1; rc=$?
check "sh <script> is refused: exit 3" '[ $rc = 3 ]'
out=$(env -u CLAUDE_CONFIG_DIR HOME="$H" bash -c '. "$1"; echo "after-source rc=$? opts=$-"' x "$H/.megavibe/scripts/trash-empty.sh" 2>&1)
check "sourced: refused, and the caller's shell goes on" 'printf "%s" "$out" | grep -q "after-source rc=3"'
H15="$T/th15"; mk_home "$H15" "$RULES_JSON" gate; echo keep > "$H15/.Trash/k"
env -u CLAUDE_CONFIG_DIR HOME="$H15" bash -p -c '. "$0" --all' "$H15/.megavibe/scripts/trash-empty.sh" >/dev/null 2>&1; rc=$?
check "bash -p -c '. \$0 --all' with the real gate: nothing is deleted, not approved (exit 5)" '[ $rc = 5 ] && [ "$(cat "$H15/.Trash/k")" = keep ]'
check "none of the refusals touched the Trash" '[ "$(cat "$H/.Trash/guard.txt")" = keep ]'
H16="$T/th16"; mk_home "$H16" "$RULES_JSON" nogate 0 linux
run_in "$H16" >/dev/null 2>&1; rc=$?; check "not Darwin: exit 3" '[ $rc = 3 ]'
H3="$T/th3"; mk_home "$H3"; /bin/rmdir "$H3/.Trash"
run_in "$H3" >/dev/null 2>&1; rc=$?; check "no ~/.Trash: exit 3" '[ $rc = 3 ]'
mkdir -p "$T/realtrash"; echo q > "$T/realtrash/q"; ln -s "$T/realtrash" "$H3/.Trash"
run_in "$H3" --all >/dev/null 2>&1; rc=$?
check "~/.Trash is a symlink: exit 3, the target is untouched" '[ $rc = 3 ] && [ "$(cat "$T/realtrash/q")" = q ]'

# the permission rules must be installed, as real arrays of strings
H4="$T/th4"; mk_home "$H4" '{"permissions":{"allow":["Read"]}}'; echo keep > "$H4/.Trash/k"
te4() { run_in "$H4" "$@"; }
set_rules() { printf '%s\n' "$1" > "$H4/.claude/settings.json"; }
must4() {  # must4 <name> <settings json>: exit 4 and nothing deleted
  set_rules "$2"; te4 --all >/dev/null 2>&1; local rc=$?
  if [ $rc = 4 ] && [ -e "$H4/.Trash/k" ]; then ok; else bad "$1 (wanted 4 and the file kept, got $rc)"; fi
}
must4 "no ask rules: exit 4" '{"permissions":{"allow":["Read"]}}'
must4 "only the catch-all rule: exit 4" '{"permissions":{"ask":["Bash(*trash-empty*)"]}}'
must4 "only the path rule: exit 4" '{"permissions":{"ask":["Bash(~/.megavibe/scripts/trash-empty.sh *)"]}}'
must4 "the rules under allow instead of ask: exit 4" '{"permissions":{"allow":["Bash(*trash-empty*)","Bash(~/.megavibe/scripts/trash-empty.sh *)"]}}'
must4 "ask is a string: exit 4" '{"permissions":{"ask":"Bash(*trash-empty*)"}}'
must4 "ask is an object holding the rule strings as values: exit 4" '{"permissions":{"ask":{"a":"Bash(~/.megavibe/scripts/trash-empty.sh *)","b":"Bash(*trash-empty*)"}}}'
must4 "the rules inside a nested list: exit 4" '{"permissions":{"ask":[["Bash(~/.megavibe/scripts/trash-empty.sh *)","Bash(*trash-empty*)"]]}}'
must4 "permissions is a string: exit 4" '{"permissions":"Bash(*trash-empty*)"}'
must4 "settings is a list: exit 4" '["Bash(*trash-empty*)"]'
must4 "settings that are not JSON: exit 4" 'not json'
/bin/rm -f "$H4/.claude/settings.json"; te4 --all >/dev/null 2>&1; rc=$?
check "no settings file: exit 4" '[ $rc = 4 ] && [ -e "$H4/.Trash/k" ]'
mkdir -p "$T/cfg-rules"; printf '%s\n' "$RULES_JSON" > "$T/cfg-rules/settings.json"; set_rules '{}'
env HOME="$H4" CLAUDE_CONFIG_DIR="$T/cfg-rules" "$H4/.megavibe/scripts/trash-empty.sh" --all >/dev/null 2>&1; rc=$?
check "rules only in a CLAUDE_CONFIG_DIR: ignored, exit 4" '[ $rc = 4 ] && [ -e "$H4/.Trash/k" ]'
mkdir -p "$T/cfg-bare"; echo '{}' > "$T/cfg-bare/settings.json"; set_rules "$RULES_JSON"
env HOME="$H4" CLAUDE_CONFIG_DIR="$T/cfg-bare" "$H4/.megavibe/scripts/trash-empty.sh" --all >/dev/null 2>&1; rc=$?
check "rules in ~/.claude, an empty CLAUDE_CONFIG_DIR: ignored, the real settings decide, exit 0" '[ $rc = 0 ] && [ ! -e "$H4/.Trash/k" ]'
echo keep2 > "$H4/.Trash/k2"; set_rules '{}'; printf '%s\n' "$RULES_JSON" > "$T/managed.json"
te4 --all >/dev/null 2>&1; rc=$?
check "rules in the managed settings file are enough: exit 0" '[ $rc = 0 ] && [ ! -e "$H4/.Trash/k2" ]'
/bin/rm -f "$T/managed.json"

# a hostile environment changes nothing: -p, a fixed PATH, a wiped environment, tools from fixed directories
H17="$T/th17"; mk_home "$H17" '{}'; echo keep > "$H17/.Trash/k"; mkdir -p "$T/evil"
for _t in python3 jq dirname basename uname id ps find stat date awk head sed env; do
  printf '#!/bin/sh\ntouch "%s/evil.marker"\nexit 0\n' "$T" > "$T/evil/$_t"; chmod +x "$T/evil/$_t"
done
printf 'touch "%s/bashenv.marker"\n' "$T" > "$T/evil/bashenv.sh"
/bin/rm -f "$T/evil.marker" "$T/bashenv.marker" "$T/fn.marker"
env HOME="$H17" PATH="$T/evil:$PATH" \
  bash -c 'builtin() { touch "'"$T"'/fn.marker"; }; jq() { return 0; }; exit() { touch "'"$T"'/fn.marker"; }; export -f builtin jq exit; exec /usr/bin/env BASH_ENV="$1" ENV="$1" PYTHONPATH="$2" PYTHONSTARTUP="$1" "$0" --all' "$H17/.megavibe/scripts/trash-empty.sh" "$T/evil/bashenv.sh" "$T/evil" >/dev/null 2>&1; rc=$?
check "hostile PATH, BASH_ENV, PYTHON*, exported builtin/jq/exit functions and no rules: still exit 4, the file kept" '[ $rc = 4 ] && [ -e "$H17/.Trash/k" ]'
check "hostile environment: none of the planted tools, startup files or functions ran" '[ ! -e "$T/evil.marker" ] && [ ! -e "$T/bashenv.marker" ] && [ ! -e "$T/fn.marker" ]'
printf '%s\n' "$RULES_JSON" > "$H17/.claude/settings.json"; echo lost > "$H17/.Trash/dropme"
forge "$H17" idE "$H17/.Trash/dropme" "$(oid "$H17/.Trash/dropme")" "/orig/dropme" droppable
env HOME="$H17" PATH="$T/evil:$PATH" \
  bash -c 'builtin() { touch "'"$T"'/fn.marker"; }; jq() { return 0; }; export -f builtin jq; exec /usr/bin/env BASH_ENV="$1" PYTHONPATH="$2" "$0"' "$H17/.megavibe/scripts/trash-empty.sh" "$T/evil/bashenv.sh" "$T/evil" >/dev/null 2>&1; rc=$?
check "hostile environment with the rules installed: the legitimate run still works and deletes only the droppable item" '[ $rc = 0 ] && [ ! -e "$H17/.Trash/dropme" ] && [ "$(cat "$H17/.Trash/k")" = keep ] && [ ! -e "$T/evil.marker" ] && [ ! -e "$T/bashenv.marker" ] && [ ! -e "$T/fn.marker" ]'

# a gate-enabled copy: the real provenance check. This test process has no matching Claude Code shell above it.
H18="$T/th18"; mk_home "$H18" "$RULES_JSON" gate; echo keep > "$H18/.Trash/k"; echo d > "$H18/.Trash/dd"
forge "$H18" idG "$H18/.Trash/dd" "$(oid "$H18/.Trash/dd")" "/orig/dd" droppable
out=$(run_in "$H18" 2>&1); rc=$?
check "the real gate from this test: refused with exit 5, nothing deleted" '[ $rc = 5 ] && [ -e "$H18/.Trash/dd" ] && [ -e "$H18/.Trash/k" ] && printf "%s" "$out" | grep -q "Finder"'
run_in "$H18" --all >/dev/null 2>&1; rc=$?
check "the real gate, --all: refused with exit 5" '[ $rc = 5 ] && [ -e "$H18/.Trash/k" ]'
if [ -x /usr/bin/script ]; then
  /usr/bin/script -q /dev/null env -u CLAUDE_CONFIG_DIR HOME="$H18" "$H18/.megavibe/scripts/trash-empty.sh" --all >/dev/null 2>&1; rc=$?
  check "even with a terminal on stdin the gate refuses (a process started outside Claude Code is never approved)" '[ $rc = 5 ] && [ -e "$H18/.Trash/k" ]'
fi
env -i HOME="$H18" /bin/bash -c '"$0" --all' "$H18/.megavibe/scripts/trash-empty.sh" >/dev/null 2>&1; rc=$?
check "a shell with an empty environment: refused with exit 5" '[ $rc = 5 ] && [ -e "$H18/.Trash/k" ]'

# 9. setup.sh: the ask-rule merge and the opt-in managed-settings step. The helpers are cut out of setup.sh
# (from trash_ask_rules() to the --trash-greenlight-managed dispatch) and run on scratch files, never on the real
# settings; msudo is a stub that records the call and fails, so no sudo is ever involved.
SETUP_FN="$T/setup-fn.sh"
{
  echo 'set -uo pipefail; YELLOW=; RESET=; info(){ echo "$1"; }; ok(){ echo "ok: $1"; }; warn(){ echo "warn: $1"; }; fail(){ echo "fail: $1"; }'
  echo 'msudo(){ echo "msudo called: $*" >> "$MSUDO_LOG"; return 1; }'
  sed -n '/^trash_ask_rules()/,/^if \[ "\${1:-}" = "--trash-greenlight-managed" \]/p' "$REPO/setup.sh" | sed '$d'
} > "$SETUP_FN"
check "the extracted setup.sh helpers define the merge and the managed step" 'grep -q "^merge_trash_ask()" "$SETUP_FN" && grep -q "^trash_greenlight_managed()" "$SETUP_FN" && bash -n "$SETUP_FN"'
export MSUDO_LOG="$T/msudo.log"
S1="$T/s1"; mkdir -p "$S1"
printf '%s\n' '{"permissions":{"allow":["Read","Bash(git status)"],"ask":["Bash(rm *)"],"defaultMode":"dontAsk"},"env":{"A":"1"},"statusLine":{"type":"command"}}' > "$S1/settings.json"
mt() { ( . "$SETUP_FN"; "$@" ); }
out=$(HOME="$S1" mt merge_trash_ask "$S1/settings.json" "scratch" 2>&1); rc=$?
check "ask-rule merge: exit 0 and reports it" '[ $rc = 0 ] && printf "%s" "$out" | grep -q "^ok: Trash greenlight: ask rules"'
check "ask-rule merge: the user own ask rule is kept, first" '[ "$(jq -r ".permissions.ask[0]" "$S1/settings.json")" = "Bash(rm *)" ]'
check "ask-rule merge: the three rules are added" '[ "$(jq -r ".permissions.ask | length" "$S1/settings.json")" = 4 ] && jq -e ".permissions.ask | index(\"Bash(*trash-empty*)\") != null and index(\"Bash(~/.megavibe/scripts/trash-empty.sh *)\") != null and index(\"Bash($S1/.megavibe/scripts/trash-empty.sh *)\") != null" "$S1/settings.json" >/dev/null'
check "ask-rule merge: allow, defaultMode, env and statusLine are untouched" '[ "$(jq -c ".permissions.allow" "$S1/settings.json")" = "[\"Read\",\"Bash(git status)\"]" ] && [ "$(jq -r ".permissions.defaultMode, .env.A, .statusLine.type" "$S1/settings.json" | tr "\n" " ")" = "dontAsk 1 command " ]'
check "ask-rule merge: a backup of the old file was made" '[ "$(ls "$S1"/settings.json.pre-trashask-* | wc -l | tr -d " ")" = 1 ] && jq -e ".permissions.ask == [\"Bash(rm *)\"]" "$S1"/settings.json.pre-trashask-* >/dev/null'
cp "$S1/settings.json" "$S1/after-first.json"
out=$(HOME="$S1" mt merge_trash_ask "$S1/settings.json" "scratch" 2>&1); rc=$?
check "ask-rule merge: second run is a no-op (skip message, identical bytes, no new backup)" '[ $rc = 0 ] && printf "%s" "$out" | grep -q "already present" && cmp -s "$S1/settings.json" "$S1/after-first.json" && [ "$(ls "$S1"/settings.json.pre-trashask-* | wc -l | tr -d " ")" = 1 ]'
check "ask-rule merge: the script accepts what setup.sh wrote (producer and consumer agree)" 'H5="$T/th5"; mk_home "$H5" "$(cat "$S1/settings.json")"; echo k > "$H5/.Trash/k"; run_in "$H5" --all >/dev/null 2>&1 && [ ! -e "$H5/.Trash/k" ]'
check "ask-rule merge: no temp file is left beside the settings" '[ -z "$(ls "$S1" | grep "settings.json.tmp")" ]'
S3="$T/s3"; mkdir -p "$S3"; printf '%s\n' '{"env":{"SECRET":"x"}}' > "$S3/settings.json"; chmod 600 "$S3/settings.json"
HOME="$S1" mt merge_trash_ask "$S3/settings.json" "scratch" >/dev/null 2>&1
check "ask-rule merge: a 0600 settings file stays 0600, and so does its backup" '[ "$(stat -f %Lp "$S3/settings.json")" = 600 ] && [ "$(stat -f %Lp "$S3"/settings.json.pre-trashask-*)" = 600 ]'
S4="$T/s4"; mkdir -p "$S4"
printf '%s\n' '{"permissions":{"ask":{"a":"Bash(~/.megavibe/scripts/trash-empty.sh *)","b":"Bash(*trash-empty*)","c":"Bash(/x/.megavibe/scripts/trash-empty.sh *)"}}}' > "$S4/obj.json"; cp "$S4/obj.json" "$S4/obj.orig"
out=$(HOME="$S1" mt merge_trash_ask "$S4/obj.json" "scratch" 2>&1)
check "ask-rule merge: the rules stored as object values are NOT 'already present'; the file is left untouched with a warning" 'cmp -s "$S4/obj.json" "$S4/obj.orig" && printf "%s" "$out" | grep -q "^warn: could not add" && ! printf "%s" "$out" | grep -q "already present"'
printf '%s\n' '["a"]' > "$S4/list.json"; cp "$S4/list.json" "$S4/list.orig"
out=$(HOME="$S1" mt merge_trash_ask "$S4/list.json" "scratch" 2>&1)
check "ask-rule merge: a settings file that is a list is left untouched with a warning" 'cmp -s "$S4/list.json" "$S4/list.orig" && printf "%s" "$out" | grep -q "^warn: could not add"'
printf '%s\n' '{"permissions":"x"}' > "$S4/str.json"; cp "$S4/str.json" "$S4/str.orig"
out=$(HOME="$S1" mt merge_trash_ask "$S4/str.json" "scratch" 2>&1)
check "ask-rule merge: permissions that is a string is left untouched with a warning" 'cmp -s "$S4/str.json" "$S4/str.orig" && printf "%s" "$out" | grep -q "^warn: could not add"'
S2="$T/s2"; HOME="$S1" mt merge_trash_ask "$S2/settings.json" "scratch" >/dev/null 2>&1
check "ask-rule merge: a missing file is created with the rules, mode 600" '[ "$(jq -r ".permissions.ask | length" "$S2/settings.json")" = 3 ] && [ "$(stat -f %Lp "$S2/settings.json")" = 600 ]'
printf '%s\n' '{"env":{"A":"1"}}' > "$S2/nopermissions.json"; HOME="$S1" mt merge_trash_ask "$S2/nopermissions.json" "scratch" >/dev/null 2>&1
check "ask-rule merge: a file without a permissions block gains one, env kept" '[ "$(jq -r "(.permissions.ask | length), .env.A" "$S2/nopermissions.json" | tr "\n" " ")" = "3 1 " ]'
printf '%s\n' '{"permissions":{"ask":"Bash(rm *)"}}' > "$S2/bad.json"; cp "$S2/bad.json" "$S2/bad.orig"
out=$(HOME="$S1" mt merge_trash_ask "$S2/bad.json" "scratch" 2>&1)
check "ask-rule merge: permissions.ask that is not a list is left untouched with a warning" 'cmp -s "$S2/bad.json" "$S2/bad.orig" && printf "%s" "$out" | grep -q "^warn: could not add"'
printf 'not json' > "$S2/notjson.json"; cp "$S2/notjson.json" "$S2/notjson.orig"
out=$(HOME="$S1" mt merge_trash_ask "$S2/notjson.json" "scratch" 2>&1)
check "ask-rule merge: a file that is not JSON is left untouched with a warning" 'cmp -s "$S2/notjson.json" "$S2/notjson.orig" && printf "%s" "$out" | grep -q "^warn: could not add"'
printf '%s\n' '{"permissions":{"allow":["Read"]}}' > "$S2/real.json"; ln -s real.json "$S2/link.json"
HOME="$S1" mt merge_trash_ask "$S2/link.json" "scratch" >/dev/null 2>&1
check "ask-rule merge: a symlinked settings.json stays a symlink and the target is updated" '[ -L "$S2/link.json" ] && [ "$(jq -r ".permissions.ask | length" "$S2/real.json")" = 3 ]'
# managed settings: opt-in, fake target, never sudo
MG="$T/mg/ClaudeCode/managed-settings.json"
out=$(HOME="$S1" MEGAVIBE_MANAGED_SETTINGS_FILE="$MG" mt trash_greenlight_managed 2>&1); rc=$?
check "managed: a missing file (and directory) is created with the rules, mode 644, exit 0" '[ $rc = 0 ] && [ "$(jq -r ".permissions.ask | length" "$MG")" = 3 ] && [ "$(stat -f %Lp "$MG")" = 644 ] && printf "%s" "$out" | grep -q "/status"'
check "managed: it never asked for sudo where the directory is writable" '[ ! -e "$MSUDO_LOG" ]'
check "managed: the script accepts the managed file alone (no user rules at all)" 'H6="$T/th6"; mk_home "$H6" "{}"; cp "$MG" "$T/managed.json"; echo k > "$H6/.Trash/k"; run_in "$H6" --all >/dev/null 2>&1; rc6=$?; /bin/rm -f "$T/managed.json"; [ $rc6 = 0 ] && [ ! -e "$H6/.Trash/k" ]'
cp "$MG" "$T/mg.after"
out=$(HOME="$S1" MEGAVIBE_MANAGED_SETTINGS_FILE="$MG" mt trash_greenlight_managed 2>&1); rc=$?
check "managed: second run is a no-op" '[ $rc = 0 ] && printf "%s" "$out" | grep -q "already present" && cmp -s "$MG" "$T/mg.after"'
MG2="$T/mg2/managed-settings.json"; mkdir -p "$T/mg2"; printf '%s\n' '{"permissions":{"ask":["Bash(rm *)"],"deny":["Bash(curl *)"]},"allowManagedHooksOnly":false}' > "$MG2"
HOME="$S1" MEGAVIBE_MANAGED_SETTINGS_FILE="$MG2" mt trash_greenlight_managed >/dev/null 2>&1; rc=$?
check "managed: an existing file is merged (other keys and rules kept) and backed up" '[ $rc = 0 ] && [ "$(jq -r ".permissions.ask | length" "$MG2")" = 4 ] && [ "$(jq -r ".permissions.deny[0], .allowManagedHooksOnly" "$MG2" | tr "\n" " ")" = "Bash(curl *) false " ] && [ -f "$MG2.megavibe-backup" ]'
jq '.extra = 1 | .permissions.ask = [.permissions.ask[0]]' "$MG2" > "$MG2.new" && mv "$MG2.new" "$MG2"
HOME="$S1" MEGAVIBE_MANAGED_SETTINGS_FILE="$MG2" mt trash_greenlight_managed >/dev/null 2>&1
check "managed: the backup is made once and keeps the ORIGINAL, not the second edit" '[ "$(jq -c ".permissions.ask" "$MG2.megavibe-backup")" = "[\"Bash(rm *)\"]" ] && ! jq -e ".extra" "$MG2.megavibe-backup" >/dev/null 2>&1 && [ "$(jq -r ".extra" "$MG2")" = 1 ]'
printf '%s\n' '{"permissions":{"ask":{"a":"Bash(~/.megavibe/scripts/trash-empty.sh *)","b":"Bash(*trash-empty*)"}}}' > "$T/mg2/obj.json"; cp "$T/mg2/obj.json" "$T/mg2/obj.orig"
out=$(HOME="$S1" MEGAVIBE_MANAGED_SETTINGS_FILE="$T/mg2/obj.json" mt trash_greenlight_managed 2>&1); rc=$?
check "managed: rules stored as object values are not 'already present': refused, untouched" '[ $rc = 1 ] && cmp -s "$T/mg2/obj.json" "$T/mg2/obj.orig" && ! printf "%s" "$out" | grep -q "already present"'
MG3="$T/mg3/managed-settings.json"; mkdir -p "$T/mg3"; printf 'garbage' > "$MG3"
out=$(HOME="$S1" MEGAVIBE_MANAGED_SETTINGS_FILE="$MG3" mt trash_greenlight_managed 2>&1); rc=$?
check "managed: a file that is not JSON is refused, untouched" '[ $rc = 1 ] && [ "$(cat "$MG3")" = garbage ] && printf "%s" "$out" | grep -q "not valid JSON"'
mkdir -p "$T/mg4"; chmod 500 "$T/mg4"
out=$(HOME="$S1" MEGAVIBE_MANAGED_SETTINGS_FILE="$T/mg4/managed-settings.json" mt trash_greenlight_managed 2>&1); rc=$?
chmod 700 "$T/mg4"
check "managed: where the directory is not writable it goes through msudo (stubbed to fail): exit 1, nothing written" '[ $rc = 1 ] && [ ! -e "$T/mg4/managed-settings.json" ] && grep -q "msudo called: mkdir -p $T/mg4" "$MSUDO_LOG"'
check "managed: --trash-greenlight-managed is dispatched before any install step in setup.sh" '[ "$(grep -n "^if \[ \"\${1:-}\" = \"--trash-greenlight-managed\" \]" "$REPO/setup.sh" | cut -d: -f1)" -lt "$(grep -n "^NEEDS_LOGIN=()" "$REPO/setup.sh" | cut -d: -f1)" ]'
check "setup.sh and the launcher both install trash-empty.sh" 'grep -q "scripts/trash-empty.sh\" \"\$MEGAVIBE_HOME\|SCRIPT_DIR/scripts/trash-empty.sh" "$REPO/setup.sh" && grep -q "REPO_DIR/scripts/trash-empty.sh" "$REPO/megavibe"'
check "the launcher has the trash-greenlight subcommand" 'grep -q "\"\${1:-}\" = \"trash-greenlight\"" "$REPO/megavibe"'
# The whole settings sequence, not only the new helpers: step 5 (statusLine + attribution) runs first and used to
# replace the file with a 0644 copy and break a symlinked settings.json.
STEP5="$T/step5.sh"
{ echo 'set -u; ok(){ echo "ok: $1"; }; warn(){ echo "warn: $1"; }; fail(){ echo "fail: $1"; }'
  sed -n '/^USER_SETTINGS=/,/^# ─── 5a/p' "$REPO/setup.sh" | sed '$d'
} > "$STEP5"
check "the extracted step 5 block parses and defines the merge" 'bash -n "$STEP5" && grep -q "^MEGAVIBE_SETTINGS=" "$STEP5"'
S5="$T/s5"; mkdir -p "$S5/.claude"; printf '%s\n' '{"env":{"SECRET":"x"},"permissions":{"ask":["Bash(rm *)"]}}' > "$S5/.claude/settings.json"; chmod 600 "$S5/.claude/settings.json"
( umask 022; HOME="$S5" bash "$STEP5" >/dev/null 2>&1 ); rc=$?
check "step 5 on a 0600 settings.json under umask 022: still 0600, statusLine added, env and permissions kept, no temp left" '[ $rc = 0 ] && [ "$(stat -f %Lp "$S5/.claude/settings.json")" = 600 ] && [ "$(jq -r ".statusLine.type, .env.SECRET, .permissions.ask[0]" "$S5/.claude/settings.json" | tr "\n" " ")" = "command x Bash(rm *) " ] && [ ! -e "$S5/.claude/settings.json.tmp" ]'
S6="$T/s6"; mkdir -p "$S6/.claude" "$S6/dotfiles"; printf '%s\n' '{"env":{"A":"1"}}' > "$S6/dotfiles/settings.json"; ln -s "$S6/dotfiles/settings.json" "$S6/.claude/settings.json"
( umask 022; HOME="$S6" bash "$STEP5" >/dev/null 2>&1 )
check "step 5 on a symlinked settings.json: still a symlink, the target is updated" '[ -L "$S6/.claude/settings.json" ] && [ "$(jq -r ".statusLine.type, .env.A" "$S6/dotfiles/settings.json" | tr "\n" " ")" = "command 1 " ]'


# 10. Provenance: the decision "was this process started by Claude Code's Bash tool with exactly the asked command"
# is a pure function over the process table, the command lines and the signer, so it is tested here on fixture chains.
# (A real Claude Code shell cannot be started from a test; section 8 shows the real gate refusing from here.)
TE_PROG="$T/te_prog.py"
sed -n '/^#--- TE_PY BEGIN/,/^#--- TE_PY END/p' "$REPO/scripts/trash-empty.sh" > "$TE_PROG"
check "the embedded python program was extracted and compiles" '[ -s "$TE_PROG" ] && python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$TE_PROG"'
cat > "$T/prov_test.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("te", sys.argv[1]); te = importlib.util.module_from_spec(spec); spec.loader.exec_module(te)
ASKED = "~/.megavibe/scripts/trash-empty.sh"
ZSH = ("/bin/zsh -c source /opt/u/.claude/shell-snapshots/snapshot-zsh-1792582976889-ivotnz.sh 2>/dev/null || true && "
       "setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL 2>/dev/null || true && { \\builtin unalias -- 'unsetenv'; "
       "\\builtin unset -f -- 'unsetenv'; } >/dev/null 2>&1 || true && eval '%s' < /dev/null && pwd -P >| /tmp/claude-780a-cwd")
BASH = ("/bin/bash -c source /opt/u/.claude/shell-snapshots/snapshot-bash-1792-abc.sh 2>/dev/null || true && "
        "shopt -u extglob 2>/dev/null || true && eval '%s' < /dev/null && pwd -P >| /tmp/claude-1b2c-cwd")
REAL, FAKE = "/real/claude", "/tmp/fake/claude"
n_ok = n_bad = 0


def case(name, got, want_ok):
    global n_ok, n_bad
    if (got is None) == want_ok:
        n_ok += 1
    else:
        n_bad += 1
        print("FAIL: %s (got %r)" % (name, got))


def chain(cmd, mode="droppable", top_comm="claude", top_exe=REAL, team_of=None):
    table = {100: (99, "/usr/bin/python3"), 99: (98, "/bin/bash"), 98: (97, "/bin/zsh"), 97: (96, top_comm), 96: (95, "/bin/bash"), 95: (1, "login")}
    teams = {REAL: te.CLAUDE_TEAM, FAKE: ""} if team_of is None else team_of
    return te.provenance(table, lambda p: cmd if p == 98 else "", lambda p: top_exe if p == 97 else "/x/%d" % p,
                         lambda e: teams.get(e, ""), 100, mode)


def q(s):                       # a command payload as the harness quotes it
    return s.replace("'", "'\\''")


# the asked command, both harness shapes, both modes
case("zsh harness, exact form", chain(ZSH % ASKED), True)
case("bash harness, exact form", chain(BASH % ASKED), True)
case("zsh harness, --all", chain(ZSH % (ASKED + " --all"), "all"), True)
case("bash harness, --all", chain(BASH % (ASKED + " --all"), "all"), True)
case("zsh -l -c", chain((ZSH % ASKED).replace("/bin/zsh -c", "/bin/zsh -l -c")), True)
case("a trailing newline in the payload (ps shows \\012)", chain(ZSH % (ASKED + "\\012")), True)
case("a leading newline in the payload", chain(ZSH % ("\\012" + ASKED)), True)
# the mode must agree with the run
case("text has --all, run is droppable", chain(ZSH % (ASKED + " --all"), "droppable"), False)
case("text has no --all, run is --all", chain(ZSH % ASKED, "all"), False)
# every other text, including the reviewers' spellings
for name, text in [
    ("bash <script>", "bash " + ASKED), ("sh <script>", "sh " + ASKED), ("env prefix", "env X=1 " + ASKED), ("assignment prefix", "X=1 " + ASKED),
    ("function then the script", "f(){ :; }; " + ASKED), ("sourced", ". " + ASKED), ("&& more", ASKED + " && echo hi"), ("; more", ASKED + "; echo hi"),
    ("comment", ASKED + " # why"), ("--all then junk", ASKED + " --all --now"), ("--yes", ASKED + " --yes"),
    ("doubled slashes and a glob", "~//.megavibe//scripts/t*-e*.sh --all"), ("cd -P then a glob", "cd -P ~/.megavibe/scripts && ./tr*h-e* --all"),
    ("cd -- then a glob", "cd -- ~/.megavibe/scripts; ./tr*h-e*"), ("env -C", "env -C ~/.megavibe/scripts ./tr*h-e*"),
    ("a variable", "D=~/.megavibe/scripts; $D/tr*h-e*"), ("find -exec", "find ~/.megavibe/scripts -name 'tr*h-e*' -exec {} \\;"),
    ("absolute path", "/opt/u/.megavibe/scripts/trash-empty.sh"), ("$HOME path", "$HOME/.megavibe/scripts/trash-empty.sh"),
    ("sh -c", "sh -c '" + ASKED + "'"), ("name only in a comment", "# " + ASKED + "\n./tr*h-e*"),
    ("echo of the name", "echo " + ASKED), ("two asked forms", ASKED + "\n" + ASKED),
]:
    case("refused: " + name, chain(ZSH % q(text), "all" if "--all" in text else "droppable"), False)
# a payload that tries to fake the harness's own quoting is rendered with '\'' and never matches
fake_payload = "echo x; eval '" + ASKED + "' < /dev/null"
case("a payload that contains the eval text itself", chain(ZSH % q(fake_payload)), False)
case("a payload that closes the quote and appends", chain((ZSH % ASKED).replace("' < /dev/null", "'\\'' ; echo pwned ; '\\'''  < /dev/null")), False)
# the shape of the harness itself
case("trailing junk after < /dev/null", chain((ZSH % ASKED) + " && echo pwned"), False)
case("not a -c shell", chain((ZSH % ASKED).replace("-c source", "source")), False)
case("a shell that is not zsh or bash", chain((ZSH % ASKED).replace("/bin/zsh", "/bin/sh")), False)
case("the eval payload is not single-quoted", chain((ZSH % ASKED).replace("eval '", 'eval "').replace("' < /dev/null", '" < /dev/null')), False)
case("no eval at all", chain("/bin/zsh -c " + ASKED), False)
case("empty command line", chain(""), False)
# who is above
case("no claude above", te.provenance({100: (99, "/usr/bin/python3"), 99: (98, "/bin/bash"), 98: (97, "/bin/zsh"), 97: (1, "login")},
                                      lambda p: ZSH % ASKED, lambda p: REAL, lambda e: te.CLAUDE_TEAM, 100, "droppable"), False)
case("a process called claude that is not signed by Anthropic (a renamed shell, daemonised)", chain(ZSH % ASKED, top_exe=FAKE), False)
case("a claude signed by someone else", chain(ZSH % ASKED, team_of={REAL: "ABCDE12345"}), False)
case("the signer cannot be read", chain(ZSH % ASKED, team_of={}), False)
case("a basename that only contains claude", chain(ZSH % ASKED, top_comm="/usr/bin/claude-wrapper"), False)
case("claude by path is claude", chain(ZSH % ASKED, top_comm="/opt/u/.local/share/claude/versions/2.1.311/claude"), True)
case("claude is the script's direct parent: no harness shell",
     te.provenance({100: (99, "/usr/bin/python3"), 99: (98, "/bin/bash"), 98: (1, "claude")}, lambda p: ZSH % ASKED, lambda p: REAL, lambda e: te.CLAUDE_TEAM, 100, "droppable"), False)
case("claude is the python program's parent",
     te.provenance({100: (99, "/usr/bin/python3"), 99: (1, "claude")}, lambda p: ZSH % ASKED, lambda p: REAL, lambda e: te.CLAUDE_TEAM, 100, "droppable"), False)
# a look-alike BELOW the real claude: the topmost claude decides, and its harness text is what counts
table = {100: (99, "/usr/bin/python3"), 99: (98, "/bin/bash"), 98: (97, "/bin/zsh"), 97: (96, "claude"), 96: (95, "/bin/zsh"), 95: (94, "claude"), 94: (1, "login")}
cmds = {98: ZSH % ASKED, 96: ZSH % q("echo the agent's own command")}
exes = {97: FAKE, 95: REAL}
case("a fake claude below the real one whose argv carries the name: the real harness text decides",
     te.provenance(table, lambda p: cmds.get(p, ""), lambda p: exes.get(p, ""), lambda e: {REAL: te.CLAUDE_TEAM}.get(e, ""), 100, "droppable"), False)
cmds[96] = ZSH % ASKED
case("the same chain when the real harness text IS the asked form",
     te.provenance(table, lambda p: cmds.get(p, ""), lambda p: exes.get(p, ""), lambda e: {REAL: te.CLAUDE_TEAM}.get(e, ""), 100, "droppable"), True)
cycle = {100: (99, "/usr/bin/python3"), 99: (98, "/bin/bash"), 98: (99, "/bin/zsh")}
case("a cycle in the process table ends", te.provenance(cycle, lambda p: ZSH % ASKED, lambda p: REAL, lambda e: te.CLAUDE_TEAM, 100, "droppable"), False)
deep = {i: (i - 1, "/bin/sh") for i in range(1000, 100, -1)}; deep[100] = (1, "login")
case("a very deep chain ends", te.provenance(deep, lambda p: "", lambda p: "", lambda e: "", 1000, "droppable"), False)
# the real accessors (not the claude check, which needs a real Claude Code ancestor)
tab = te.ps_table()
case("ps_table lists this process and its parent", None if os.getpid() in tab and tab[os.getpid()][0] == os.getppid() else "missing", True)
case("ps_cmd shows this process", None if "python" in te.ps_cmd(os.getpid()).lower() else "no python in " + te.ps_cmd(os.getpid()), True)
case("ps_exe names an existing executable file", None if os.path.isfile(te.ps_exe(os.getpid())) else repr(te.ps_exe(os.getpid())), True)
case("an Apple-signed binary is not Anthropic's", None if te.team_of("/bin/zsh") != te.CLAUDE_TEAM else "claimed", True)
case("a path that does not exist has no signer", None if te.team_of("/nonexistent/claude") == "" else "claimed", True)
# if this test happens to run under a real Claude Code, its signature must verify as Anthropic's
cur, seen = os.getpid(), set()
while cur > 1 and cur in tab and cur not in seen:
    seen.add(cur)
    if os.path.basename(tab[cur][1].strip()) == "claude":
        case("a real claude ancestor verifies as Anthropic's signed binary", None if te.team_of(te.ps_exe(cur)) == te.CLAUDE_TEAM else "team " + te.team_of(te.ps_exe(cur)), True)
    cur = tab[cur][0]
print("PROVENANCE %d passed %d failed" % (n_ok, n_bad))
PY
prov_out=$(python3 -I "$T/prov_test.py" "$TE_PROG" 2>&1)
printf '%s\n' "$prov_out" | grep '^FAIL' | while IFS= read -r l; do printf '%s\n' "$l"; done
pn=$(printf '%s\n' "$prov_out" | sed -n 's/^PROVENANCE \([0-9]*\) passed \([0-9]*\) failed$/\1/p'); pf=$(printf '%s\n' "$prov_out" | sed -n 's/^PROVENANCE \([0-9]*\) passed \([0-9]*\) failed$/\2/p')
if [ -n "$pn" ]; then PASS=$((PASS + pn)); FAIL=$((FAIL + pf)); else bad "provenance tests did not run: $prov_out"; fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
