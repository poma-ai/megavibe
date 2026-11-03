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
# Exit status is the command's (util-linux needs -e for that). The deadline
# kills the whole process group (script, the shell on the pty, anything it
# started): a bare `alarm; exec script` signalled only script, and a child
# ignoring SIGHUP outlived the test. script's own
# stdin is /dev/null: macOS script refuses a socket there ("tcgetattr/ioctl:
# Operation not supported on socket"), and an agent's shell often has one; the
# child still gets the pty, so `[ -t 0 ]` is true inside and the pty's input
# ends at once, so an un-guarded read returns instead of hanging the test.
HAVE_TTY=0
# bounded <secs> <cmd...>: run cmd in its own process group; on the deadline
# TERM then KILL the group; exit with the command's status (142 on the deadline).
# script(1) puts its child in a NEW session on the pty, outside that group, so
# the group kill alone left a HUP/TERM-ignoring child alive. BOUND_PIDFILE, when
# set, names a file the inner command writes its pid to (under_tty arranges
# that); the deadline kills that pid's group too, and so does a normal exit.
bounded() { perl -e '$t=shift; $f=$ENV{BOUND_PIDFILE}; sub inner{ if($f && open(my $h,"<",$f)){ my $i=<$h>; close $h; if($i && $i=~/^(\d+)/){ kill "TERM",-$1; kill "TERM",$1; select(undef,undef,undef,0.3); kill "KILL",-$1; kill "KILL",$1 } } } $p=fork; if(!$p){setpgrp(0,0); exec @ARGV or exit 127} $SIG{ALRM}=sub{kill "TERM",-$p; select(undef,undef,undef,0.5); kill "KILL",-$p; inner(); waitpid $p,0; exit 142}; alarm $t; waitpid $p,0; $r=$?; alarm 0; inner(); exit(($r>>8)||($r&127 ? 128+($r&127) : 0))' "$@"; }
if PATH="$SYS" command -v script >/dev/null 2>&1; then
  HAVE_TTY=1
  # The inner command runs behind a shell that records its own pid for `bounded`
  # (that shell is the pty session leader; its group is what the kill reaches).
  # BOUND_SECS overrides the 60 s deadline (the survivor check uses 1).
  # A fresh pid file per call: a run that dies before writing it must not hand
  # the previous run's pid (possibly reused by now) to the cleanup.
  if PATH="$SYS" script --version >/dev/null 2>&1; then
    under_tty() { local log="$1"; shift; local pf="$T/inner.$RANDOM$RANDOM.pid" q; q=$(printf '%q ' bash -c 'echo $$ > "$0"; exec "$@"' "$pf" "$@"); BOUND_PIDFILE="$pf" bounded "${BOUND_SECS:-60}" script -q -e -c "$q" /dev/null >"$log" 2>&1 </dev/null; }
  else
    under_tty() { local log="$1"; shift; local pf="$T/inner.$RANDOM$RANDOM.pid"; BOUND_PIDFILE="$pf" bounded "${BOUND_SECS:-60}" script -q /dev/null bash -c 'echo $$ > "$0"; exec "$@"' "$pf" "$@" >"$log" 2>&1 </dev/null; }
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
    printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "$SETUP_ARGS"\n[ -t 0 ] && echo tty >> "$SETUP_ARGS"\nexit "${SETUP_RC:-0}"\n' > "$dest/setup.sh"
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
# A setup that fails (exit non-zero) is not an installed version: nothing is
# recorded, so the next update tries again instead of "Already up to date".
rm -f "$SETUP_ARGS" "$T/version"
( cd "$T" && env PATH="$T/bin:$SYS" HOME="$T" TMPDIR="$T" SETUP_ARGS="$SETUP_ARGS" SETUP_RC=1 bash "$HAR" ) >"$T/out3" 2>&1 </dev/null; rc=$?
check "setup exits 1: the updater fails and records no version" '[ "$rc" != 0 ] && [ ! -e "$T/version" ] && grep -q "Setup failed" "$T/out3"'
# No bare mv/rm onto an existing file is left in setup.sh: both ask on a
# terminal when the target is read-only (mv: "override ...?", rm likewise).
check "setup.sh has no bare mv or rm (every one is -f, or atomic_install)" '[ "$(grep -c "^[[:space:]]*mv \"" "$REPO/setup.sh")" = 0 ] && [ "$(grep -c "^[[:space:]]*rm \"" "$REPO/setup.sh")" = 0 ]'

# ---- part 2: setup.sh under --update asks nothing and keeps the selection ---
# Lift section 0 (the mode question) and the four should_install_* functions.
# The prompt lines themselves are what is under test, so they stay verbatim.
SH="$T/setup-lifted.sh"
{
  echo 'set -u'
  sed -n '/^UPDATE_MODE=0$/,/UPDATE_MODE=1$/p' "$REPO/setup.sh"
  sed -n '/^# ─── 0\. Define installation mode/,/^# ─── 1\. Install tools/p' "$REPO/setup.sh"
  for f in codex gemini telegram playwright; do sed -n "/^should_install_$f() {/,/^}/p" "$REPO/setup.sh"; done
  cat <<'EOF'
for f in codex gemini telegram playwright; do
  if "should_install_$f"; then echo "$f: install"; else echo "$f: keep-out"; fi
done
echo "LIFTED-DONE"
EOF
} > "$SH"
check "the --update parse, section 0 and the four should_install_* were lifted" '[ "$(grep -c "^should_install_" "$SH")" = 4 ] && grep -q "How do you want to install" "$SH" && grep -q "^UPDATE_MODE=0$" "$SH"'
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

# ---- part 3: no sudo password, no npx confirmation under --update ---------
# msudo is defined before any bootstrap can call it; lift the file head through
# its closing brace (the first column-zero "}" in setup.sh) and call it with a
# sudo stub that records its argv. The lift carries the --update parse, which
# must precede msudo for the pip/jq bootstrap to be covered.
MS="$T/msudo-lifted.sh"
{ echo 'set -u'; sed -n '1,/^}/p' "$REPO/setup.sh"; echo 'msudo probe-cmd; echo "MSUDO-DONE"; { env | grep -E "^(HOMEBREW_NO_ASK|PIP_NO_INPUT|GIT_TERMINAL_PROMPT|DEBIAN_FRONTEND|npm_config_yes)=" | sort; } || true'; } > "$MS"
check "the msudo lift parses and carries the --update parse ahead of msudo" 'bash -n "$MS" 2>/dev/null && [ "$(grep -n "^UPDATE_MODE=0$" "$MS" | cut -d: -f1)" -lt "$(grep -n "^msudo() {" "$MS" | cut -d: -f1)" ]'
mkdir -p "$T/sudo"; printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "$SUDO_ARGS"\nexit 0\n' > "$T/sudo/sudo"
printf '#!/bin/bash\necho 1000\n' > "$T/sudo/id"; chmod +x "$T/sudo/sudo" "$T/sudo/id"
export SUDO_ARGS="$T/sudo.args"
if [ "$HAVE_TTY" -eq 1 ]; then
  rm -f "$SUDO_ARGS"; ( cd "$T" && export PATH="$T/sudo:$SYS" && under_tty "$T/ms.out" bash "$MS" --update ); rc=$?
  check "--update on a tty: msudo runs sudo -n (no password prompt possible)" '[ "$rc" = 0 ] && [ "$(sed -n 1p "$SUDO_ARGS" 2>/dev/null)" = "-n" ] && grep -q "probe-cmd" "$SUDO_ARGS" || { cat "$T/ms.out"; false; }'
  # sudo's env_reset drops exported variables, so the apt switch must be on the
  # command line, behind env (a VAR=value argument needs SETENV in sudoers).
  check "--update: DEBIAN_FRONTEND crosses the sudo boundary on the command line (env), not only as an export" '[ "$(tr "\n" " " < "$SUDO_ARGS" 2>/dev/null)" = "-n env DEBIAN_FRONTEND=noninteractive probe-cmd " ]'
  check "--update: the tools' own non-interactive switches are exported (brew, pip, git, apt, npx)" '( tr -d "\r" < "$T/ms.out" > "$T/ms.lf"; for v in HOMEBREW_NO_ASK=1 PIP_NO_INPUT=1 GIT_TERMINAL_PROMPT=0 DEBIAN_FRONTEND=noninteractive npm_config_yes=true; do grep -q "^$v$" "$T/ms.lf" || exit 1; done )'
  rm -f "$SUDO_ARGS"; ( cd "$T" && export PATH="$T/sudo:$SYS" && under_tty "$T/ms-ctl.out" bash "$MS" ); rc=$?
  check "control, no flag on a tty: msudo runs plain sudo (a human may type the password)" '[ "$rc" = 0 ] && [ "$(sed -n 1p "$SUDO_ARGS" 2>/dev/null)" = "probe-cmd" ] || { cat "$T/ms-ctl.out"; false; }'
fi
# dpkg's conffile question has no environment switch, so an update installs no
# OS package at all for the optional Python/pip bootstrap (jq stays required).
check "--update installs no OS package for the optional Python and pip bootstraps" '[ "$(grep -c "an update does not install OS packages" "$REPO/setup.sh")" = 2 ] && grep -q "^if \[ -z \"\$PYTHON\" \] && \[ \"\$UPDATE_MODE\" -eq 1 \]; then" "$REPO/setup.sh" && grep -q "^  if \[ -z \"\$PIP\" \] && \[ \"\$UPDATE_MODE\" -eq 1 \]; then" "$REPO/setup.sh"'
check "npx playwright install never asks (--yes)" 'grep -q "npx --yes playwright install chromium 2>&1" "$REPO/setup.sh" && ! grep -q "if npx playwright install" "$REPO/setup.sh"'
if [ "$HAVE_TTY" -eq 1 ]; then
  # Through the real pty path: a shell that ignores HUP and TERM, with a sleep.
  ( export BOUND_SECS=1; under_tty "$T/surv.out" bash -c "trap '' HUP TERM; sleep 30 & echo \$! > '$T/surv.pid'; wait" ); rc=$?
  check "the deadline kills the pty session too (no survivor behind script)" '[ "$rc" = 142 ] && sleep 1 && [ -s "$T/surv.pid" ] && ! kill -0 "$(cat "$T/surv.pid")" 2>/dev/null'
fi

# ---- part 4: the protocol refresh onto a read-only ~/.claude/CLAUDE.md -----
# A bare mv onto a 0444 CLAUDE.md asked "override r--r--r-- ...? (y/n)" on a
# terminal. Lift the file head, resolve_link, atomic_install and the refresh
# block (CLAUDE_MD=... up to its elif), run it on a pty with a read-only
# fixture that has custom text outside the markers.
CM="$T/claudemd-lifted.sh"
{
  echo 'set -u'
  sed -n '1,/^}/p' "$REPO/setup.sh"
  sed -n '/^stat_mode() {/,/^}/p' "$REPO/setup.sh"
  sed -n '/^resolve_link() {/,/^}/p' "$REPO/setup.sh"
  sed -n '/^atomic_install() {/,/^}/p' "$REPO/setup.sh"
  echo 'SCRIPT_DIR="$CM_SRC"'
  sed -n '/^CLAUDE_MD="\$HOME\/\.claude\/CLAUDE\.md"$/,/^elif \[ -f "\$CLAUDE_MD" \]; then$/p' "$REPO/setup.sh" | sed '$d'
  echo 'fi; echo "CLAUDEMD-DONE"'
} > "$CM"
check "the CLAUDE.md refresh block was lifted with its helpers" 'bash -n "$CM" 2>/dev/null && grep -q "^atomic_install() {" "$CM" && grep -q "v3 refreshed" "$CM"'
mkdir -p "$T/cm/home/.claude" "$T/cm/src/template"
printf '<!-- megavibe-v3 -->\nNEW PROTOCOL TEXT\n<!-- /megavibe-v3 -->\n' > "$T/cm/src/template/CLAUDE.md"
printf 'MY CUSTOM RULES\n\n<!-- megavibe-v3 -->\nold protocol\n<!-- /megavibe-v3 -->\n' > "$T/cm/home/.claude/CLAUDE.md"
chmod 0444 "$T/cm/home/.claude/CLAUDE.md"
if [ "$HAVE_TTY" -eq 1 ]; then
  ( cd "$T" && export HOME="$T/cm/home" CM_SRC="$T/cm/src" PATH="$SYS" && under_tty "$T/cm.out" bash "$CM" --update ); rc=$?
  check "read-only CLAUDE.md on a tty: the refresh finished without asking" '[ "$rc" = 0 ] && grep -q CLAUDEMD-DONE "$T/cm.out" && ! grep -qi "override" "$T/cm.out" || { cat "$T/cm.out"; false; }'
  check "read-only CLAUDE.md: custom text kept, protocol block replaced, mode kept" 'grep -q "MY CUSTOM RULES" "$T/cm/home/.claude/CLAUDE.md" && grep -q "NEW PROTOCOL TEXT" "$T/cm/home/.claude/CLAUDE.md" && ! grep -q "old protocol" "$T/cm/home/.claude/CLAUDE.md" && [ ! -w "$T/cm/home/.claude/CLAUDE.md" ] && [ ! -e "$T/cm/home/.claude/CLAUDE.md.tmp" ]'
fi
chmod u+w "$T/cm/home/.claude/CLAUDE.md" 2>/dev/null

# The two first-install waits further down carry the guard (their blocks need
# a real install to reach, so they are checked by text).
check "the login pause is skipped under --update" 'grep -q "^  \[ \"\$UPDATE_MODE\" -eq 1 \] || \[ ! -t 0 \] || read -p \"  Press Enter to continue" "$REPO/setup.sh"'
check "the Gemini key block is skipped under --update" 'grep -q "^if \[ \"\$UPDATE_MODE\" -eq 0 \] && \[ \"\$GEMINI_INSTALLED\" -eq 1 \]" "$REPO/setup.sh"'
# Eight prompts: mode, four Install X?, the login pause, the key (tty and /dev/tty).
check "every read in setup.sh is one of the eight known prompts" '[ "$(grep -c "[^a-z_]read \(-[rs] \)*-p \"" "$REPO/setup.sh")" = 8 ]'

printf 'update-auto-install: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
