#!/bin/bash
# Offline launcher regressions; optionally pass an older launcher to prove failure.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
LAUNCHER="${1:-$REPO/megavibe}"
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-launcher-help.XXXXXX")
trap '/bin/rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
PASS=0 FAIL=0 CASE=0
COMMIT=0123456789abcdef0123456789abcdef01234567
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "$CALLS"
if [ "$*" = 'auth status' ]; then
  echo '{"loggedIn":true}'
else
  printf '%s\n' "$@" > "$CLAUDE_ARGS"
fi
STUB
# Any accidental update/probe is recorded and cannot reach the network.
for tool in curl npm codex gemini poma-memory; do
  cat > "$T/bin/$tool" <<'STUB'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$FORBIDDEN"
exit 1
STUB
done
chmod +x "$T/bin/"*

setup_case() {
  CASE=$((CASE + 1))
  ROOT="$T/$CASE"
  TEST_HOME="$ROOT/home"
  INSTALL="$TEST_HOME/.megavibe"
  PROJECT="$ROOT/project"
  mkdir -p "$TEST_HOME/.claude" "$INSTALL" "$PROJECT"
  printf 'megavibe-v3\n' > "$TEST_HOME/.claude/CLAUDE.md"
  cp "$LAUNCHER" "$INSTALL/megavibe"
  printf '%s\n' "$COMMIT" > "$INSTALL/version"
  # An overdue update must stay overdue, even when help runs inside the install.
  printf '0\n' > "$INSTALL/.last-update-check"
  cat > "$INSTALL/init.sh" <<'STUB'
#!/bin/bash
echo 'Bootstrapping Megavibe in: .'
mkdir -p .claude/hooks .agent
echo synced > .claude/hooks/test.sh
STUB
  case "$1" in
    fresh) CWD="$PROJECT" ;;
    existing)
      CWD="$PROJECT"
      mkdir -p "$PROJECT/.claude/hooks" "$PROJECT/.agent"
      echo keep > "$PROJECT/.claude/hooks/test.sh"
      echo keep > "$PROJECT/.agent/TASKS.md" ;;
    install) CWD="$INSTALL" ;;
  esac
}
snapshot() {
  # Include hidden directories and file contents, not just visible filenames.
  (cd "$CWD" && find . -print | LC_ALL=C sort)
  (cd "$CWD" && find . -type f -exec cksum {} \; | LC_ALL=C sort)
  (cd "$TEST_HOME" && find . -print | LC_ALL=C sort)
  (cd "$TEST_HOME" && find . -type f -exec cksum {} \; | LC_ALL=C sort)
}
launch() {
  snapshot > "$ROOT/before"
  RC=0
  OUT=$(cd "$CWD" && env -i HOME="$TEST_HOME" PATH="$T/bin:$PATH" \
    CALLS="$ROOT/calls" CLAUDE_ARGS="$ROOT/args" FORBIDDEN="$ROOT/forbidden" \
    MEGAVIBE_ROUTER=0 MEGAVIBE_STYLE=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$@" /bin/bash "$INSTALL/megavibe" ${ARGV[@]+"${ARGV[@]}"} </dev/null 2>&1) || RC=$?
  snapshot > "$ROOT/after"
}
unchanged() {
  cmp -s "$ROOT/before" "$ROOT/after" &&
    [ ! -e "$ROOT/calls" ] && [ ! -e "$ROOT/forbidden" ]
}
check() {
  local label="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); printf 'PASS %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s (exit %s)\n%s\n' "$label" "$RC" "$OUT"
  fi
}
help_ok() {
  [ "$RC" = 0 ] && [ "${OUT%%$'\n'*}" = 'Usage: megavibe [subcommand | options | claude-args...]' ] &&
    [ "$(printf '%s\n' "$OUT" | wc -l)" -lt 60 ] &&
    [[ "$OUT" == *'claude --help'* ]] && unchanged
}
version_ok() {
  [ "$RC" = 0 ] && [ "$OUT" = "$1" ] && unchanged
}
refused() {
  [ "$RC" != 0 ] &&
    [ "$OUT" = 'megavibe: refusing to bootstrap the Megavibe install directory; cd into a project first.' ] && unchanged
}

for location in fresh existing install; do
  for spelling in --help -h help; do
    setup_case "$location"
    ARGV=("$spelling")
    launch
    check "$location: $spelling is read-only" help_ok
  done
  for spelling in --version -V version; do
    setup_case "$location"
    ARGV=("$spelling")
    launch
    check "$location: $spelling reads installed commit" version_ok 'megavibe 01234567'
    rm -f "$INSTALL/version"
    launch
    check "$location: $spelling without record" version_ok 'megavibe unknown'
  done
done

setup_case fresh
printf '%s %s\n' "$COMMIT" '2026-01-02' > "$INSTALL/version"
ARGV=(--version)
launch
check 'optional recorded date' version_ok 'megavibe 01234567 (2026-01-02)'

setup_case fresh
mkdir -p "$TEST_HOME/custom-install"
printf 'abcdef0123456789abcdef0123456789abcdef01\n' > "$TEST_HOME/custom-install/version"
ARGV=(--version)
launch MEGAVIBE_HOME="$TEST_HOME/custom-install"
check 'overridden home supplies the installed commit' version_ok 'megavibe abcdef01'

setup_case fresh
ARGV=(--version)
# An override must win over the default home's record, without requiring setup.
launch MEGAVIBE_HOME="$TEST_HOME/uninstalled"
check 'missing overridden home remains absent' version_ok 'megavibe unknown'
ARGV=(--help)
launch MEGAVIBE_HOME="$TEST_HOME/uninstalled"
check 'help works before installation' help_ok

for spelling in --help -h help --version -V version; do
  setup_case fresh
  # Ordinary launches retain their update behavior; skip it for this compatibility check.
  date +%s > "$INSTALL/.last-update-check"
  ARGV=(--model x "$spelling")
  launch
  printf '%s\n' --dangerously-skip-permissions --remote-control --model x "$spelling" > "$ROOT/expected"
  check "later $spelling reaches Claude unchanged" \
    test "$RC:$(cat "$ROOT/args" 2>/dev/null)" = "0:$(cat "$ROOT/expected")"
done

for invocation in fresh continue resume no-normalize parallel; do
  setup_case install
  case "$invocation" in
    fresh) ARGV=() ;;
    continue) ARGV=(--continue) ;;
    resume) ARGV=(--resume example-session) ;;
    no-normalize) ARGV=(--no-normalize) ;;
    parallel) ARGV=(--parallel-branch review --no-stash) ;;
  esac
  launch
  check "install refuses $invocation before any writes" refused
done

setup_case install
ln -s "$INSTALL" "$ROOT/install-link"
CWD="$ROOT/install-link"
ARGV=(--model x)
launch
check 'install guard recognizes symlink paths' refused

# These dispatch before the guard and remain usable from the install directory.
for subcommand in node auth tick sessions; do
  setup_case install
  mkdir -p "$INSTALL/scripts"
  case "$subcommand" in
    node) helper=megavibe-node ;;
    auth) helper=claude-auth-check ;;
    *) helper="$subcommand" ;;
  esac
  printf 'echo dispatched\n' > "$INSTALL/scripts/$helper.sh"
  ARGV=("$subcommand")
  launch
  check "install still dispatches $subcommand" version_ok dispatched
done

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
