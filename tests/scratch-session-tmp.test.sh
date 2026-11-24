#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/mv-t.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" CLAUDE_ENV_FILE="$T/env" CLAUDE_CODE_TMPDIR="$T"
mkdir -p "$HOME/.megavibe/scripts" "$T/project"
cp "$REPO"/scripts/{scratch-own,scratch-root,disk-watch}.sh "$HOME/.megavibe/scripts/"
# Keep root discovery inside the fixture even on SessionEnd.
mv "$HOME/.megavibe/scripts/scratch-root.sh" "$HOME/.megavibe/scripts/real-root.sh"
cat > "$HOME/.megavibe/scripts/scratch-root.sh" <<'ROOTS'
#!/bin/bash
case "$1" in roots) set -- root ;; esac
exec "${0%/*}/real-root.sh" "$@"
ROOTS
chmod +x "$HOME/.megavibe/scripts/scratch-root.sh"
OWN="$HOME/.megavibe/scripts/scratch-own.sh"
HOOK="$REPO/template/.claude/hooks/scratch-tmpdir.sh"
ROOT="$T/claude-$(id -u)"
SID=abcdefgh-first
EXPECTED="$ROOT/t/abcdefgh"
failed=0
hook() { (cd "$T/project" && printf '{"session_id":"%s"}\n' "$1" | bash "$HOOK"); }
touch "$CLAUDE_ENV_FILE"
TMPDIR="$T/pinned" hook "$SID"
[[ ! -s "$CLAUDE_ENV_FILE" ]]
MEGAVIBE_SESSION_TMPDIR=0 TMPDIR=/tmp hook "$SID"
[[ ! -s "$CLAUDE_ENV_FILE" ]]
CLAUDE_ENV_FILE="$T/project" TMPDIR=/tmp hook "$SID"
[[ ! -e "$EXPECTED" ]]
TMPDIR=/tmp hook "$SID"
TMPDIR=/tmp hook "$SID"
[[ $(wc -l < "$CLAUDE_ENV_FILE") -eq 2 ]]
source "$CLAUDE_ENV_FILE"
[[ "$TMPDIR" = "$EXPECTED" && "$(cat "$EXPECTED/.sid")" = "$SID" ]]
python3 - "$TMPDIR" <<'PY'
import errno, os, socket, stat, sys
path = sys.argv[1]
assert stat.S_IMODE(os.stat(path).st_mode) == 0o700
with socket.socket(socket.AF_UNIX) as sock:
    assert len(os.fsencode(path + "/ctl.sock")) < 90
    try:
        sock.bind(path + "/ctl.sock")
    except OSError as exc:
        if exc.errno != errno.EPERM or os.environ.get("TEST_SOCKET_SANDBOX") != "1":
            raise
        print("SKIP: sandbox forbids binding AF_UNIX sockets")
PY
other=other-session
TMPDIR=/tmp hook "$other"
other_dir="$ROOT/t/other-se"
: > "$CLAUDE_ENV_FILE"
TMPDIR=/tmp hook abcdefgh-second
[[ ! -s "$CLAUDE_ENV_FILE" && "$(cat "$EXPECTED/.sid")" = "$SID" ]]
long="$T/$(printf '%0105d' 0)"
mkdir "$long"
CLAUDE_CODE_TMPDIR="$long" TMPDIR=/tmp hook long-session
[[ ! -s "$CLAUDE_ENV_FILE" && ! -e "$long/claude-$(id -u)" ]]
quote_base="$T/it's ok"
mkdir "$quote_base"
CLAUDE_CODE_TMPDIR="$quote_base" TMPDIR=/tmp hook quote-session
(
  source "$CLAUDE_ENV_FILE"
  [[ "$TMPDIR" = "$quote_base/claude-$(id -u)/t/quote-se" ]]
)
quote_dir="$quote_base/claude-$(id -u)/t/quote-se"
mv "$quote_dir" "$T/quote-original"
(
  umask 000
  source "$CLAUDE_ENV_FILE"
  python3 -c 'import os, stat; info = os.stat(os.environ["TMPDIR"]); assert stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700'
) || { echo 'FAIL: sourcing the env file did not recreate TMPDIR with mode 700'; failed=1; }
if [[ -d "$quote_dir" ]]; then rmdir "$quote_dir"; fi
ln -s "$T/missing-target" "$quote_dir"
(source "$CLAUDE_ENV_FILE")
[[ -L "$quote_dir" && ! -e "$T/missing-target" ]]
: > "$CLAUDE_ENV_FILE"
ln -s "$T/project" "$ROOT/t/symlink-"
TMPDIR=/tmp hook symlink-session
[[ ! -s "$CLAUDE_ENV_FILE" && ! -e "$T/project/.sid" ]]

awk 'BEGIN { for(i=0;i<300000;i++) print "fixture" }' > "$EXPECTED/data"
DW="$HOME/.megavibe/scripts/disk-watch.sh"
[[ "$("$DW" scratch-kb "$SID")" -ge 2000 ]]
[[ "$("$DW" scratch-kb abcdefgh-second)" = 0 ]]
"$OWN" clean-unit abcdefgh-second
"$OWN" clean-end abcdefgh-second
[[ -f "$EXPECTED/data" && -d "$other_dir" ]]
"$OWN" clean-end "$SID"
[[ -f "$EXPECTED/data" ]]
find "$EXPECTED" -exec touch -t 200001010000 {} +
"$OWN" clean-end "$SID"
[[ ! -e "$EXPECTED" && -d "$other_dir" ]]
TMPDIR=/tmp hook "$SID"
mkdir -p "$EXPECTED/nested"
touch "$EXPECTED/nested/.keep" "$EXPECTED/data"
ln -s "$T/project" "$EXPECTED/project-link"
"$OWN" clean-unit "$SID"
[[ -f "$EXPECTED/data" && -f "$EXPECTED/nested/.keep" ]]
mv "$EXPECTED/nested/.keep" "$T/keep"
reviewer="$EXPECTED/nested/codex-review-scratch.active"
mkdir -p "$reviewer"
printf '%s\n' "$$" > "$reviewer/.pid"
touch "$reviewer/work" "$EXPECTED/nested/disposable" "$EXPECTED/disposable"
"$OWN" clean-unit "$SID"
if [[ ! -f "$reviewer/work" || ! -f "$reviewer/.pid" ||
      -e "$EXPECTED/nested/disposable" || -e "$EXPECTED/disposable" ||
      -e "$EXPECTED/data" || -L "$EXPECTED/project-link" ]]; then
  echo 'FAIL: clean-unit must preserve active reviewer scratch and clear other contents'
  failed=1
fi
if [[ -d "$reviewer" ]]; then
  rm -r "$reviewer"
  rmdir "$EXPECTED/nested"
fi
if [[ ! -d "$EXPECTED" || "$(cat "$EXPECTED/.sid")" != "$SID" ||
      "$(ls -A "$EXPECTED")" != .sid ]]; then
  echo 'FAIL: clean-unit did not leave only the session marker in TMPDIR'
  failed=1
else
  find "$EXPECTED" -exec touch -t 200001010000 {} +
  "$OWN" clean-end "$SID"
  [[ ! -e "$EXPECTED" ]]
fi
[[ -d "$other_dir" && -d "$T/project" ]]
[[ "$failed" -eq 0 ]] || exit 1
TMPDIR=/tmp hook "$SID"
if python3 -m pytest --version >/dev/null 2>&1; then
  cat > "$T/project/test_temp.py" <<'PY'
import os
from pathlib import Path

def test_location(tmp_path):
    assert Path(os.environ["TMPDIR"]) in tmp_path.parents
    (tmp_path / "fixture").write_bytes(b"x" * 4096)
PY
  for run in 1 2 3 4; do
    (cd "$T/project" && python3 -m pytest -q -p no:cacheprovider test_temp.py)
    du -sk "$TMPDIR"/pytest-of-*/pytest-"$((run-1))"
  done
  retained=$(find "$TMPDIR"/pytest-of-* -type d -name 'pytest-[0-9]*' | wc -l)
  [[ "$retained" -eq 3 ]]
  du -sk "$TMPDIR"/pytest-of-*
else
  echo 'SKIP: python3 has no pytest'
fi
echo 'PASS: session TMPDIR path, attribution and cleanup'
