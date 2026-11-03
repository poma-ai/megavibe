#!/bin/bash
# /bin/bash tests/update-auto-install.test.sh
# An update of an existing install (`megavibe update`, /megavibe-restart) runs
# the downloaded setup.sh with --update, and under --update setup never asks:
# not "Automatic or Custom?", not "Install X?", not the login pause, not the
# Gemini key. With a terminal attached those prompts blocked a restart until
# someone typed 1 (2026-11-03). --update also keeps the installed selection:
# a component is refreshed only when it is already there, where --auto-install
# would install every optional component a Custom user had declined.
# Part 1 runs do_update's GitHub arm with stubbed git/curl; part 2 runs the
# lifted prompt logic of setup.sh under a pty. Nothing reaches the network.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/update-auto.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }

SYS="/usr/bin:/bin"
for tool in sed awk perl; do
  PATH="$SYS" command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool missing" >&2; exit 0; }
done

# under_tty <logfile> <cmd...>: run cmd with a real terminal on stdin, bounded.
# BSD/macOS script takes the command as positional words; util-linux wants -c.
# Exit status is the command's (util-linux needs -e for that). script's own
# stdin is /dev/null: macOS script refuses a socket there ("tcgetattr/ioctl:
# Operation not supported on socket"), and an agent's shell often has one; the
# child still gets the pty, so `[ -t 0 ]` is true inside and the pty's input
# ends at once, so an un-guarded read returns instead of hanging the test.
HAVE_TTY=0
if PATH="$SYS" command -v script >/dev/null 2>&1; then
  HAVE_TTY=1
  if PATH="$SYS" script --version >/dev/null 2>&1; then
    under_tty() { local log="$1"; shift; local q; q=$(printf '%q ' "$@"); perl -e 'alarm shift; exec @ARGV' 60 script -q -e -c "$q" /dev/null >"$log" 2>&1 </dev/null; }
  else
    under_tty() { local log="$1"; shift; perl -e 'alarm shift; exec @ARGV' 60 script -q /dev/null "$@" >"$log" 2>&1 </dev/null; }
  fi
else
  echo "skip: script(1) missing, tty cases not run" >&2
fi

# ---- part 1: the launcher passes --update ----------------------------------
# git stub: `clone` lays down a fake download whose setup.sh records its argv
# and whether stdin is a terminal; everything else answers like an empty repo.
mkdir -p "$T/bin"
cat > "$T/bin/git" <<'EOF'
#!/bin/bash
for a in "$@"; do
  if [ "$a" = clone ]; then
    dest="${@: -1}"; mkdir -p "$dest/template"
    printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "$SETUP_ARGS"\n[ -t 0 ] && echo tty >> "$SETUP_ARGS"\nexit 0\n' > "$dest/setup.sh"
    exit 0
  fi
done
echo ""; exit 0
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
echo "deadbeefcafe"
EOF
chmod +x "$T/bin/git" "$T/bin/curl"

# The function under test, lifted from the launcher, with its collaborators stubbed.
HAR="$T/harness.sh"
{
  echo 'set -u'
  echo 'BOLD=""; RESET=""; GREEN=""; RED=""; YELLOW=""'
  echo 'get_source_repo() { echo "$T/nosrc"; }'
  echo 'is_git_source() { return 1; }'
  echo 'collect_changelog() { :; }'
  echo 'GITHUB_API=http://127.0.0.1:9/sha; GITHUB_REPO=poma-ai/megavibe'
  echo 'VERSION_FILE="$T/version"; MEGAVIBE_HOME="$T/mvh"; UPDATE_AVAILABLE_FILE="$T/upd"'
  sed -n '/^do_update() {/,/^}/p' "$REPO/megavibe"
  echo 'do_update'
} > "$HAR"
mkdir -p "$T/mvh"
check "do_update was lifted from the launcher" 'grep -q "^do_update() {" "$HAR"'
check "the lifted harness parses (the sed lift closes the function)" 'bash -n "$HAR" 2>/dev/null'

export T SETUP_ARGS="$T/setup.args"
if [ "$HAVE_TTY" -eq 1 ]; then
  ( cd "$T" && export PATH="$T/bin:$SYS" HOME="$T" TMPDIR="$T" && under_tty "$T/out" bash "$HAR" ); rc=$?
  check "with a terminal: the updater exited 0" '[ "$rc" = 0 ] || { cat "$T/out"; false; }'
  check "with a terminal: setup was run" '[ -s "$SETUP_ARGS" ]'
  check "with a terminal: setup saw a tty, so only the flag can keep it quiet" 'grep -qx tty "$SETUP_ARGS"'
  check "with a terminal: setup got --update" 'grep -qx -- --update "$SETUP_ARGS"'
  check "with a terminal: setup did not get --auto-install" '! grep -qx -- --auto-install "$SETUP_ARGS"'
fi
# The first run recorded the hash, which would make the second say "Already up to date".
rm -f "$SETUP_ARGS" "$T/version"
( cd "$T" && env PATH="$T/bin:$SYS" HOME="$T" TMPDIR="$T" SETUP_ARGS="$SETUP_ARGS" bash "$HAR" ) >"$T/out2" 2>&1 </dev/null; rc=$?
check "without a terminal: the updater exited 0" '[ "$rc" = 0 ] || { cat "$T/out2"; false; }'
check "without a terminal: setup got --update too" 'grep -qx -- --update "$SETUP_ARGS"'
check "the version file records the downloaded hash" '[ "$(cat "$T/version" 2>/dev/null)" = deadbeefcafe ]'

# ---- part 2: setup.sh under --update asks nothing and keeps the selection ---
# Lift section 0 (the mode question) and the four should_install_* functions.
# The prompt lines themselves are what is under test, so they stay verbatim.
SH="$T/setup-lifted.sh"
{
  echo 'set -u'
  sed -n '/^# ─── 0\. Define installation mode/,/^# ─── 1\. Install tools/p' "$REPO/setup.sh"
  for f in codex gemini telegram playwright; do sed -n "/^should_install_$f() {/,/^}/p" "$REPO/setup.sh"; done
  cat <<'EOF'
for f in codex gemini telegram playwright; do
  if "should_install_$f"; then echo "$f: install"; else echo "$f: keep-out"; fi
done
echo "LIFTED-DONE"
EOF
} > "$SH"
check "section 0 and the four should_install_* were lifted" '[ "$(grep -c "^should_install_" "$SH")" = 4 ] && grep -q "How do you want to install" "$SH"'
check "the lifted setup parses" 'bash -n "$SH" 2>/dev/null'

# Nothing installed: an empty PATH dir, a MEGAVIBE_HOME without telegram-bot.py.
mkdir -p "$T/empty" "$T/mvh2"
if [ "$HAVE_TTY" -eq 1 ]; then
  ( cd "$T" && export PATH="$T/empty:$SYS" MEGAVIBE_HOME="$T/mvh2" && under_tty "$T/lift.out" bash "$SH" --update ); rc=$?
  check "--update on a tty: finished (no prompt blocked it)" '[ "$rc" = 0 ] && grep -q LIFTED-DONE "$T/lift.out" || { cat "$T/lift.out"; false; }'
  check "--update on a tty: never printed the mode question" '! grep -q "How do you want to install" "$T/lift.out"'
  check "--update on a tty: never printed an Install X? question" '! grep -q "Install .*? \[Y/n\]" "$T/lift.out"'
  check "--update on a tty: absent components stay out" '[ "$(grep -c ": keep-out" "$T/lift.out")" = 4 ]'
  # The control: without the flag the same tty run asks the mode question (the
  # pty's stdin ends here, so the read returns at once instead of blocking).
  ( cd "$T" && export PATH="$T/empty:$SYS" MEGAVIBE_HOME="$T/mvh2" && under_tty "$T/lift-ctl.out" bash "$SH" ); rc=$?
  check "control, no flag on a tty: the mode question is asked" 'grep -q "How do you want to install" "$T/lift-ctl.out"'
fi
# Present components are refreshed: a telegram-bot.py in MEGAVIBE_HOME, a codex on PATH.
mkdir -p "$T/have"; printf '#!/bin/bash\nexit 0\n' > "$T/have/codex"; chmod +x "$T/have/codex"; : > "$T/mvh2/telegram-bot.py"
( cd "$T" && env PATH="$T/have:$SYS" MEGAVIBE_HOME="$T/mvh2" bash "$SH" --update ) >"$T/lift2.out" 2>&1 </dev/null
check "--update: present codex and telegram are refreshed, absent gemini and playwright stay out" 'grep -qx "codex: install" "$T/lift2.out" && grep -qx "telegram: install" "$T/lift2.out" && grep -qx "gemini: keep-out" "$T/lift2.out" && grep -qx "playwright: keep-out" "$T/lift2.out"'

# The two first-install waits further down carry the guard (their blocks need
# a real install to reach, so they are checked by text).
check "the login pause is skipped under --update" 'grep -q "^  \[ \"\$UPDATE_MODE\" -eq 1 \] || \[ ! -t 0 \] || read -p \"  Press Enter to continue" "$REPO/setup.sh"'
check "the Gemini key block is skipped under --update" 'grep -q "^if \[ \"\$UPDATE_MODE\" -eq 0 \] && \[ \"\$GEMINI_INSTALLED\" -eq 1 \]" "$REPO/setup.sh"'
# Eight prompts: mode, four Install X?, the login pause, the key (tty and /dev/tty).
check "every read in setup.sh is one of the eight known prompts" '[ "$(grep -c "[^a-z_]read \(-[rs] \)*-p \"" "$REPO/setup.sh")" = 8 ]'

printf 'update-auto-install: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
