#!/bin/bash
# /bin/bash tests/stale-source.test.sh
# init.sh and the launcher refuse to install from a checkout whose HEAD is a
# strict ancestor of the commit recorded in $MEGAVIBE_HOME/version (an old
# branch must not overwrite newer hooks and rules). Temp dirs and a fake HOME
# only; nothing touches the real ~/.megavibe or ~/.claude. No network.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/stale-source.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# Source repo: this tree, two commits (A older, B newer), plus a diverged side branch.
SRC="$T/src"; mkdir -p "$SRC"
for f in init.sh template; do cp -R "$REPO/$f" "$SRC/$f"; done
git -C "$SRC" init -q -b main
git -C "$SRC" add -A >/dev/null; git -C "$SRC" commit -q -m A
A=$(git -C "$SRC" rev-parse HEAD)
echo b > "$SRC/b.txt"; git -C "$SRC" add -A >/dev/null; git -C "$SRC" commit -q -m B
B=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q -b side "$A"; echo s > "$SRC/s.txt"; git -C "$SRC" add -A >/dev/null; git -C "$SRC" commit -q -m S
S=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q main
git -C "$SRC" worktree add -q "$T/wtA" "$A" 2>/dev/null
git -C "$SRC" worktree add -q "$T/wtB" "$B" 2>/dev/null
git -C "$SRC" worktree add -q "$T/wtS" "$S" 2>/dev/null

H="$T/home"; mkdir -p "$H/.claude"
# run_init <script-dir> <version-file-content|-missing-> [extra env]: fresh project each time.
run_init() {
  local dir=$1 ver=$2 proj; shift 2
  proj=$(mktemp -d "$T/proj.XXXXXX"); mkdir -p "$proj/.claude/hooks"
  echo keep > "$proj/.claude/hooks/pre-existing.sh"
  rm -rf "$H/.megavibe"; mkdir -p "$H/.megavibe"
  [ "$ver" = -missing- ] || printf '%s\n' "$ver" > "$H/.megavibe/version"
  LAST_PROJ=$proj
  env HOME="$H" MEGAVIBE_HOME="$H/.megavibe" "$@" bash "$dir/init.sh" "$proj" >"$T/out" 2>"$T/err"
  LAST_RC=$?
}
installed() { [ -d "$LAST_PROJ/.agent" ]; }

run_init "$T/wtA" "$B"
check "older checkout: exit 1" '[ "$LAST_RC" = 1 ]'
check "older checkout: project untouched" '! installed && [ "$(ls "$LAST_PROJ/.claude/hooks")" = pre-existing.sh ]'
check "refusal names checkout" 'grep -q "$T/wtA" "$T/err"'
check "refusal names both commits" 'grep -q "$A" "$T/err" && grep -q "$B" "$T/err"'
check "refusal lists the three ways out" 'grep -q "~/.megavibe/init.sh" "$T/err" && grep -q MEGAVIBE_INIT_ALLOW_STALE=1 "$T/err" && grep -qi "update this checkout" "$T/err"'
check "refusal goes to stderr only" '! grep -q MEGAVIBE_INIT_ALLOW_STALE "$T/out"'

run_init "$T/wtA" "$B" MEGAVIBE_INIT_ALLOW_STALE=1
check "ALLOW_STALE=1 proceeds" '[ "$LAST_RC" = 0 ] && installed'
run_init "$T/wtB" "$B"
check "same commit proceeds" '[ "$LAST_RC" = 0 ] && installed'
run_init "$T/wtA" "$A"
check "installed equals HEAD proceeds" '[ "$LAST_RC" = 0 ] && installed'
run_init "$T/wtB" "$A"
check "newer checkout proceeds" '[ "$LAST_RC" = 0 ] && installed'
run_init "$T/wtS" "$B"
check "diverged checkout proceeds" '[ "$LAST_RC" = 0 ] && installed'
run_init "$T/wtA" 3
check "version file '3' proceeds" '[ "$LAST_RC" = 0 ] && installed'
run_init "$T/wtA" -missing-
check "missing version file proceeds" '[ "$LAST_RC" = 0 ] && installed'
run_init "$T/wtA" "ffffffffffffffffffffffffffffffffffffffff"
check "commit unknown to this repo proceeds" '[ "$LAST_RC" = 0 ] && installed'
run_init "$T/wtA" "$B" MEGAVIBE_INIT_ALLOW_STALE=0
check "ALLOW_STALE=0 still refuses" '[ "$LAST_RC" = 1 ]'

# Non-git copy of the older tree.
rm -rf "$T/plain"; mkdir -p "$T/plain"; cp -R "$T/wtA/init.sh" "$T/wtA/template" "$T/plain/"
run_init "$T/plain" "$B"
check "non-git copy proceeds" '[ "$LAST_RC" = 0 ] && installed'

# Launcher: the decision function, lifted from megavibe.
FN=$(sed -n '/^repo_older_than_installed()/,/^}/p' "$REPO/megavibe")
check "launcher defines repo_older_than_installed" '[ -n "$FN" ]'
lau() { # <dir> <ver>
  rm -rf "$T/lh"; mkdir -p "$T/lh"
  [ "$2" = -missing- ] || printf '%s\n' "$2" > "$T/lh/version"
  ( MEGAVIBE_HOME="$T/lh"; VERSION_FILE="$MEGAVIBE_HOME/version"; eval "$FN"; repo_older_than_installed "$1" ) 2>/dev/null
}
check "launcher: older repo is stale" 'lau "$T/wtA" "$B"'
check "launcher: same commit not stale" '! lau "$T/wtB" "$B"'
check "launcher: newer repo not stale" '! lau "$T/wtB" "$A"'
check "launcher: diverged not stale" '! lau "$T/wtS" "$B"'
check "launcher: version '3' not stale" '! lau "$T/wtA" 3'
check "launcher: missing version not stale" '! lau "$T/wtA" -missing-'
check "launcher: unknown commit not stale" '! lau "$T/wtA" ffffffffffffffffffffffffffffffffffffffff'
check "launcher: non-git dir not stale" '! lau "$T/plain" "$B"'
check "launcher: guard runs before the first sync and clears REPO_DIR" 'g=$(grep -n "&& repo_older_than_installed \"\$REPO_DIR\"" "$REPO/megavibe" | head -1 | cut -d: -f1); w=$(grep -n "# Sync CLI wrapper" "$REPO/megavibe" | head -1 | cut -d: -f1); [ -n "$g" ] && [ -n "$w" ] && [ "$g" -lt "$w" ] && sed -n "$((g+1)),$((g+2))p" "$REPO/megavibe" | grep -q "REPO_DIR=\"\""'

printf 'stale-source: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
