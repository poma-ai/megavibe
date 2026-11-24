#!/bin/bash
# /bin/bash tests/review-copy.test.sh — review-copy.sh: the cheap frozen copy, and no leftovers on any exit path.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
RC=$REPO/scripts/review-copy.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/review-copy-test.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
export HOME=$T/home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TMPDIR=$T/tmp
export GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME" "$TMPDIR"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
PASS=0 FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
left() { ls -d "$TMPDIR"/mv-review-* 2>/dev/null | wc -l | tr -d ' '; }

P=$T/proj; mkdir -p "$P/src" "$P/node_modules/dep" && cd "$P" || exit 2
git init -q . && printf 'node_modules/\n*.log\n' > .gitignore
echo one > src/a.txt; echo two > src/b.txt; git add -A && git commit -qm init
head -c 3000000 /dev/zero > big.bin; git add big.bin; git commit -qm big
echo EDIT > src/a.txt; echo new > src/c.txt; echo dep > node_modules/dep/x.js; echo log > run.log
C=$(bash "$RC" make) || C=''
check "make prints a directory" '[ -d "$C" ]'
check "edited tracked file is in the copy" '[ "$(cat "$C/src/a.txt")" = EDIT ]'
check "untracked, not ignored file is in the copy" '[ -f "$C/src/c.txt" ]'
check "node_modules is not copied" '[ ! -e "$C/node_modules" ]'
check "ignored log is not copied" '[ ! -e "$C/run.log" ]'
check "no .git in the copy" '[ ! -e "$C/.git" ]'
check "a file over the limit is skipped and listed" '[ ! -e "$C/big.bin" ] && grep -q "^big.bin" "$C/.megavibe-review-copy"'
check "the working tree and index are untouched" '[ "$(git status --porcelain | wc -l | tr -d " ")" = 2 ] && git diff --cached --quiet'
check "list shows the copy" 'bash "$RC" list | grep -q "$C"'
C2=$(bash "$RC" make src/b.txt)
check "PATH limits the copy" '[ -f "$C2/src/b.txt" ] && [ ! -e "$C2/src/a.txt" ]'
bash "$RC" remove "$C" "$C2"
check "remove deletes both copies" '[ ! -e "$C" ] && [ ! -e "$C2" ]'
check "nothing is left in the temp folder after remove" '[ "$(left)" = 0 ]'
# a write-protected copy (claude-review makes its reader copies read-only) is still removed
C3=$(bash "$RC" make); chmod -R a-w "$C3"
bash "$RC" remove "$C3"; check "a write-protected copy (files and directories) is removed" '[ $? -eq 0 ] && [ ! -e "$C3" ]'
# refusals
mkdir "$TMPDIR/mv-review-copy.fake"; mkdir "$T/other"; touch "$T/other/.megavibe-review-copy"
ln -s "$T/other" "$TMPDIR/mv-review-copy.link"
bash "$RC" remove "$TMPDIR/mv-review-copy.fake" 2>/dev/null; check "refuses a folder without the marker" '[ $? -ne 0 ] && [ -d "$TMPDIR/mv-review-copy.fake" ]'
bash "$RC" remove "$TMPDIR/mv-review-copy.link" 2>/dev/null; check "refuses a symlink and leaves its target" '[ -d "$T/other" ]'
bash "$RC" remove "$T/other" 2>/dev/null; check "refuses a name it does not make" '[ -d "$T/other" ]'
rmdir "$TMPDIR/mv-review-copy.fake"; rm -f "$TMPDIR/mv-review-copy.link"
# failure paths leave nothing
cd "$T" && mkdir notgit && cd notgit
bash "$RC" make >/dev/null 2>&1; check "make outside git fails" '[ $? -ne 0 ]'
check "the failed make left nothing" '[ "$(left)" = 0 ]'
check "a failed make with an inherited KEEP still leaves nothing" '(cd "$T/notgit" && KEEP=1 bash "$RC" make >/dev/null 2>&1); [ "$(left)" = 0 ]'
check "--max-file-kb must be a sane number" '! bash "$RC" make --max-file-kb 99999999999 >/dev/null 2>&1 && [ "$(left)" = 0 ]'
# --- hostile repositories (found by the ship round): none of this may touch anything outside the copy
H=$T/hostile; mkdir -p "$H" && cd "$H" && git init -q . && echo base > a.txt && git add -A && git commit -qm init
VICTIM=$T/victim.txt; echo precious > "$VICTIM"
# a directory name ending in a newline followed by an absolute path component
mkdir -p "$H/x
$T"; head -c 3000000 /dev/zero > "$H/x
$T/victim.txt"
echo ok > "$H/x
$T/small"
C=$(bash "$RC" make) || C=''
check "newline-in-name directory does not delete an outside file" '[ -f "$VICTIM" ] && [ "$(cat "$VICTIM")" = precious ]'
check "that copy still holds the small file and not the oversized one" '[ -n "$C" ] && [ "$(find "$C" -name small -print0 | tr -cd "\\0" | wc -c | tr -d " ")" = 1 ] && [ "$(find "$C" -name victim.txt -print0 | tr -cd "\\0" | wc -c | tr -d " ")" = 0 ]'
[ -n "$C" ] && bash "$RC" remove "$C"; rm -rf "$H/x
$T"
# symlinks named like the metadata files, pointing outside
OUT1=$T/out1; OUT2=$T/out2; echo keep1 > "$OUT1"; echo keep2 > "$OUT2"
ln -s "$OUT2" "$H/.megavibe-review-copy"; ln -s "$OUT1" "$H/other-link"
C=$(bash "$RC" make) || C=''
check "a metadata-named symlink does not redirect writes" '[ "$(cat "$OUT2")" = keep2 ]'
check "symlinks are not copied" '[ -n "$C" ] && [ ! -e "$C/other-link" ] && [ -f "$C/.megavibe-review-copy" ] && [ ! -L "$C/.megavibe-review-copy" ] && head -1 "$C/.megavibe-review-copy" | grep -q mv-review-copy-v1'
[ -n "$C" ] && bash "$RC" remove "$C"; rm -f "$H/.megavibe-review-copy" "$H/other-link"
# export-ignore must not hide a changed file; a staged file matching an ignore rule stays
printf 'a.txt export-ignore\n' > "$H/.gitattributes"; echo changed > "$H/a.txt"
printf '*.gen\n' > "$H/.gitignore"; echo g > "$H/forced.gen"; git add -f forced.gen
C=$(bash "$RC" make) || C=''
check "export-ignore does not drop a changed file" '[ -f "$C/a.txt" ] && [ "$(cat "$C/a.txt")" = changed ]'
check "a staged file matching an ignore rule is kept" '[ -f "$C/forced.gen" ]'
[ -n "$C" ] && bash "$RC" remove "$C"
# a tracked directory swapped for a symlink to elsewhere: refuse, never copy the target's files
mkdir -p "$H/dd" "$T/elsewhere"; echo t > "$H/dd/f.txt"; git -C "$H" add dd >/dev/null; git -C "$H" commit -qm dd >/dev/null; echo secret > "$T/elsewhere/f.txt"
mv "$H/dd" "$H/dd.real"; ln -s "$T/elsewhere" "$H/dd"
bash "$RC" make >/dev/null 2>&1; check "a symlinked directory in the path is refused" '[ $? -ne 0 ] && [ "$(left)" = 0 ]'
rm -f "$H/dd"; mv "$H/dd.real" "$H/dd"
bash "$RC" make --max-file-kb 08 >/dev/null 2>&1; check "a leading-zero --max-file-kb is read as decimal" '[ $? -eq 0 ]'; for c in $(bash "$RC" list | cut -f2); do bash "$RC" remove "$c"; done
# "." and "./sub" work; a path that matches nothing is an error, not an empty copy; an unreadable file is skipped
C=$(bash "$RC" make .) || C=''; check "make . copies the whole repository" '[ -f "$C/a.txt" ]'; [ -n "$C" ] && bash "$RC" remove "$C"
C=$(bash "$RC" make ./dd) || C=''; check "make ./dd copies that directory only" '[ -f "$C/dd/f.txt" ] && [ ! -e "$C/a.txt" ]'; [ -n "$C" ] && bash "$RC" remove "$C"
bash "$RC" make nosuchpath >/dev/null 2>&1; check "a path that matches nothing fails" '[ $? -ne 0 ] && [ "$(left)" = 0 ]'
echo hidden > "$H/locked.txt"; chmod 000 "$H/locked.txt"
C=$(bash "$RC" make) || C=''; check "an unreadable file is skipped, the rest is copied" '[ -n "$C" ] && [ ! -e "$C/locked.txt" ] && [ -f "$C/a.txt" ] && grep -q "locked.txt (unreadable)" "$C/.megavibe-review-copy"'
[ -n "$C" ] && bash "$RC" remove "$C"; chmod 644 "$H/locked.txt"; rm -f "$H/locked.txt"
# TMPDIR inside the repository does not nest the copies
mkdir -p "$H/tmpin"; C1=$(TMPDIR="$H/tmpin" bash "$RC" make) || C1=''; C2=$(TMPDIR="$H/tmpin" bash "$RC" make) || C2=''
check "a second copy does not contain the first (TMPDIR inside the repo)" '[ -n "$C2" ] && [ ! -e "$C2/tmpin" ]'
[ -n "$C1" ] && TMPDIR="$H/tmpin" bash "$RC" remove "$C1"; [ -n "$C2" ] && TMPDIR="$H/tmpin" bash "$RC" remove "$C2"; rm -rf "$H/tmpin"
# macOS: a literal ._name file next to a file with an extended attribute is copied, and so is a file with a big resource fork
if command -v xattr >/dev/null 2>&1; then
  echo a > "$H/abc"; echo dot > "$H/._abc"; xattr -w user.test v "$H/abc" 2>/dev/null || true
  head -c 3000000 /dev/zero > "$T/fork.bin"; echo f > "$H/forked"; xattr -wx com.apple.ResourceFork "$(head -c 200000 /dev/zero | xxd -p | tr -d '\n')" "$H/forked" 2>/dev/null || true
  C=$(bash "$RC" make) || C=''
  check "a literal ._abc file and an attribute-carrying file are both copied" '[ -f "$C/abc" ] && [ -f "$C/._abc" ] && [ -f "$C/forked" ]'
  [ -n "$C" ] && bash "$RC" remove "$C"; rm -f "$H/abc" "$H/._abc" "$H/forked"
fi
# a directory name ending in a newline is copied, not refused
NLD=$(printf 'tn\nX'); NLD=${NLD%X}
mkdir -p "$H/$NLD"; echo n > "$H/$NLD/f"
C=$(bash "$RC" make) || C=''
check "a trailing-newline directory name is copied" '[ -n "$C" ] && [ -f "$C/$NLD/f" ]'
[ -n "$C" ] && bash "$RC" remove "$C"; rm -rf "$H/$NLD"
# a repository directory named like the marker cannot break the marker: it is skipped and the copy stays removable
mkdir -p "$H/.megavibe-review-copy"; echo m > "$H/.megavibe-review-copy/f"
C=$(bash "$RC" make) || C=''
check "a marker-named directory in the repo is skipped, the copy is valid and removable" '[ -n "$C" ] && [ -f "$C/.megavibe-review-copy" ] && bash "$RC" remove "$C" && [ ! -e "$C" ]'
rm -rf "$H/.megavibe-review-copy"
# a file one byte over the cap is skipped (the cap is exact, not floored to whole KB)
head -c 2049 /dev/zero > "$H/over.bin"; head -c 2048 /dev/zero > "$H/exact.bin"
C=$(bash "$RC" make --max-file-kb 2) || C=''
check "a file one byte over the cap is skipped, one at the cap is kept" '[ ! -e "$C/over.bin" ] && [ -f "$C/exact.bin" ]'
[ -n "$C" ] && bash "$RC" remove "$C"; rm -f "$H/over.bin" "$H/exact.bin"
# remove: symlinked ancestor, symlinked marker, wrong magic
mkdir -p "$T/real/mv-review-copy.zz" && printf 'mv-review-copy-v1\n' > "$T/real/mv-review-copy.zz/.megavibe-review-copy" && echo data > "$T/real/mv-review-copy.zz/f"
ln -s "$T/real" "$TMPDIR/linkdir"
bash "$RC" remove "$TMPDIR/linkdir/mv-review-copy.zz" 2>/dev/null; check "remove refuses a copy reached through a symlinked directory" '[ -f "$T/real/mv-review-copy.zz/f" ]'
rm -f "$TMPDIR/linkdir"
mkdir "$TMPDIR/mv-review-copy.m1" && ln -s "$OUT1" "$TMPDIR/mv-review-copy.m1/.megavibe-review-copy"
bash "$RC" remove "$TMPDIR/mv-review-copy.m1" 2>/dev/null; check "remove refuses a symlinked marker" '[ -d "$TMPDIR/mv-review-copy.m1" ]'
rmdir "$TMPDIR/mv-review-copy.m1" 2>/dev/null || { rm -f "$TMPDIR/mv-review-copy.m1/.megavibe-review-copy"; rmdir "$TMPDIR/mv-review-copy.m1"; }
mkdir "$TMPDIR/mv-review-copy.m2"; echo nonsense > "$TMPDIR/mv-review-copy.m2/.megavibe-review-copy"
bash "$RC" remove "$TMPDIR/mv-review-copy.m2" 2>/dev/null; check "remove refuses a marker without the magic line" '[ -d "$TMPDIR/mv-review-copy.m2" ]'
rm -rf "$TMPDIR/mv-review-copy.m2"
check "no work directories are left behind" '[ "$(ls -d "$TMPDIR"/mv-review-work.* 2>/dev/null | wc -l | tr -d " ")" = 0 ]'
cd "$T"
printf '%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
