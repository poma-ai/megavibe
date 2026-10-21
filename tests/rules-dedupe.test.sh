#!/bin/bash
# /bin/bash tests/rules-dedupe.test.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
H="$REPO/template/.claude/hooks/rules-dedupe.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/rules-dedupe.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

TPL="$T/tpl"; mkdir -p "$TPL"; echo a > "$TPL/a.md"; echo b > "$TPL/b.md"
mkproj() {  # mkproj <dir> [rules...]: a megavibe project carrying template copies
  mkdir -p "$1/.claude/rules" "$1/.agent/events"; shift_dir="$1"; shift
  for r in "$@"; do cp "$TPL/$r" "$shift_dir/.claude/rules/$r"; done
}

# 1. Basic: a child of a megavibe parent drops its identical copies; idempotent.
P="$T/p"; C="$P/c"; mkproj "$P" a.md b.md; mkproj "$C" a.md b.md
echo mine > "$C/.claude/rules/own.md"
out=$(bash "$H" "$C" "$TPL")
check "copies removed" '[ ! -e "$C/.claude/rules/a.md" ] && [ ! -e "$C/.claude/rules/b.md" ]'
check "reports" '[ -n "$out" ]'
check "non-template rule untouched" '[ "$(cat "$C/.claude/rules/own.md")" = mine ]'
check "parent untouched" '[ -f "$P/.claude/rules/a.md" ] && [ -f "$P/.claude/rules/b.md" ]'
out=$(bash "$H" "$C" "$TPL")
check "second run silent" '[ -z "$out" ]'
check "second run: still removed" '[ ! -e "$C/.claude/rules/a.md" ]'

# 2. Criterion 1, safety net: the parent loses a copy -> the child reinstalls its own.
mv "$P/.claude/rules/a.md" "$T/a.saved"
bash "$H" "$C" "$TPL" >/dev/null
check "reinstalled when parent lost it" 'cmp -s "$C/.claude/rules/a.md" "$TPL/a.md"'
mv "$T/a.saved" "$P/.claude/rules/a.md"
bash "$H" "$C" "$TPL" >/dev/null
check "removed again once parent has it" '[ ! -e "$C/.claude/rules/a.md" ]'

# 3. Criterion 2: an edited own copy is kept.
echo edited > "$C/.claude/rules/a.md"
bash "$H" "$C" "$TPL" >/dev/null
check "edited copy kept (session start)" '[ "$(cat "$C/.claude/rules/a.md")" = edited ]'
bash "$H" --init "$C" "$TPL" >/dev/null
check "stale copy removed under --init (init always overwrote it)" '[ ! -e "$C/.claude/rules/a.md" ]'

# 4. Criterion 2: a git-tracked own copy is kept.
G="$P/g"; mkproj "$G" a.md; git -C "$G" init -q; git -C "$G" add .claude/rules/a.md
bash "$H" "$G" "$TPL" >/dev/null
check "tracked copy kept" '[ -f "$G/.claude/rules/a.md" ]'

# 5. A stale parent copy does not cover (hook mode); --init refreshes it and then covers.
echo old > "$P/.claude/rules/b.md"
bash "$H" "$C" "$TPL" >/dev/null
check "stale parent: child gets its own" 'cmp -s "$C/.claude/rules/b.md" "$TPL/b.md"'
bash "$H" --init "$C" "$TPL" >/dev/null
check "--init: parent refreshed" 'cmp -s "$P/.claude/rules/b.md" "$TPL/b.md"'
check "--init: child copy removed" '[ ! -e "$C/.claude/rules/b.md" ]'

# 6. A parent that is not a megavibe project does not cover.
N="$T/n"; NC="$N/c"; mkdir -p "$N/.claude/rules"; cp "$TPL/a.md" "$N/.claude/rules/"; mkproj "$NC" a.md
bash "$H" "$NC" "$TPL" >/dev/null
check "non-megavibe parent: copy kept" '[ -f "$NC/.claude/rules/a.md" ]'
mkdir -p "$N/.agent"; bash "$H" "$NC" "$TPL" >/dev/null
check "parent .agent without events (a template): copy kept" '[ -f "$NC/.claude/rules/a.md" ]'

# 7. Unreadable or symlinked parent copy does not cover.
U="$T/u"; UC="$U/c"; mkproj "$U" a.md; mkproj "$UC" a.md; chmod 000 "$U/.claude/rules/a.md"
bash "$H" "$UC" "$TPL" >/dev/null
check "unreadable parent copy: own kept" '[ -f "$UC/.claude/rules/a.md" ]'
chmod 644 "$U/.claude/rules/a.md"
mv "$U/.claude/rules/a.md" "$T/ua.md"; ln -s "$T/ua.md" "$U/.claude/rules/a.md"
bash "$H" "$UC" "$TPL" >/dev/null
check "symlinked parent copy: own kept" '[ -f "$UC/.claude/rules/a.md" ]'

# 8. Worktree shape: .claude symlinked to the main checkout -> no-op.
M="$T/main"; mkproj "$M" a.md; W="$P/wt"; mkdir -p "$W/.agent/events"; ln -s "$M/.claude" "$W/.claude"
bash "$H" "$W" "$TPL" >/dev/null
check "worktree: main's copy untouched" '[ -f "$M/.claude/rules/a.md" ]'
W2="$P/wt2"; mkdir -p "$W2/.claude" "$W2/.agent/events"; ln -s "$M/.claude/rules" "$W2/.claude/rules"
bash "$H" "$W2" "$TPL" >/dev/null
check "linked rules dir: untouched" '[ -f "$M/.claude/rules/a.md" ]'

# 9. Own copy is a symlink (to the parent's file): kept, not followed.
S="$P/s"; mkproj "$S"; ln -s "$P/.claude/rules/a.md" "$S/.claude/rules/a.md"
bash "$H" "$S" "$TPL" >/dev/null
check "own symlink kept" '[ -L "$S/.claude/rules/a.md" ] && [ -f "$P/.claude/rules/a.md" ]'

# 10. Logical path under the parent, physical path not: not covered on both, so kept.
X="$T/x"; mkproj "$X" a.md; ln -s "$X" "$P/xlink"
bash "$H" "$P/xlink" "$TPL" >/dev/null
check "alias path without physical cover: kept" '[ -f "$X/.claude/rules/a.md" ]'

# 11. $HOME as the parent never covers.
HH="$T/home"; HC="$HH/proj"; mkproj "$HH" a.md; mkproj "$HC" a.md
HOME="$HH" bash "$H" "$HC" "$TPL" >/dev/null
check "HOME parent: own kept" '[ -f "$HC/.claude/rules/a.md" ]'

# 12. Junk and missing pieces: exit 0, nothing written.
bash "$H" "$T/nonexistent" "$TPL"; rc=$?
check "missing project: exit 0" '[ "$rc" = 0 ]'
L="$T/lone"; mkdir -p "$L/.claude"
bash "$H" "$L" "$TPL" >/dev/null; rc=$?
check "no .agent: nothing installed" '[ "$rc" = 0 ] && [ ! -e "$L/.claude/rules" ]'
L2="$T/lone2"; mkproj "$L2"
bash "$H" "$L2" "$T/no-template" >/dev/null; rc=$?
check "no template dir: exit 0, nothing" '[ "$rc" = 0 ] && [ -z "$(ls -A "$L2/.claude/rules")" ]'

# 13. Lone project (no megavibe parent): hook installs missing, --init refreshes stale.
bash "$H" "$L2" "$TPL" >/dev/null
check "lone: missing installed" 'cmp -s "$L2/.claude/rules/a.md" "$TPL/a.md"'
echo stale > "$L2/.claude/rules/b.md"
bash "$H" "$L2" "$TPL" >/dev/null
check "lone, hook mode: stale left" '[ "$(cat "$L2/.claude/rules/b.md")" = stale ]'
bash "$H" --init "$L2" "$TPL" >/dev/null
check "lone, --init: stale refreshed" 'cmp -s "$L2/.claude/rules/b.md" "$TPL/b.md"'

# 14. init.sh end to end: parent run dedupes nested projects, skips a template dir.
R="$T/r"; RC="$R/child"; RT="$R/tool/template"
mkdir -p "$R" "$RC" "$RT/.claude/rules" "$RT/.agent"
HOME="$T/h2" bash "$REPO/init.sh" "$RC" > "$T/i1.log" 2>&1; rc1=$?
cp "$REPO/template/.claude/rules/delegation.md" "$RT/.claude/rules/"
HOME="$T/h2" bash "$REPO/init.sh" "$R" > "$T/i2.log" 2>&1; rc2=$?
check "init.sh child then parent: rc 0" '[ "$rc1" = 0 ] && [ "$rc2" = 0 ] || { tail -5 "$T/i1.log" "$T/i2.log"; false; }'
check "parent carries rules" '[ -f "$R/.claude/rules/delegation.md" ]'
check "nested child deduped by parent run" '[ ! -e "$RC/.claude/rules/delegation.md" ]'
check "template dir untouched" '[ -f "$RT/.claude/rules/delegation.md" ]'
HOME="$T/h2" bash "$REPO/init.sh" "$RC" > "$T/i3.log" 2>&1; rc3=$?
check "init.sh on child again: rc 0, still no copy" '[ "$rc3" = 0 ] && [ ! -e "$RC/.claude/rules/delegation.md" ]'
check "init.sh on child again: no rules line printed" '! grep -q "^  rules:" "$T/i3.log"'

echo "rules-dedupe tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
