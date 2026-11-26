#!/bin/bash
# Offline regressions; pass an older launcher to demonstrate the original writes.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
LAUNCHER="${1:-$REPO/megavibe}"
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-work-copy.XXXXXX")
trap '/bin/rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
PASS=0 FAIL=0 CASE=0 SKIP=0
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'STUB'
#!/bin/bash
if [ "$*" = 'auth status' ]; then
  echo '{"loggedIn":true}'
else
  printf '%s\n' "$@" > "$CALLS/claude"
fi
STUB
cat > "$T/bin/git" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS/git"
case " $* " in
  *' rev-parse --git-dir '*) echo .git; exit 0 ;;
  *' rev-parse --show-toplevel '*) pwd -P; exit 0 ;;
  *' worktree list '*) printf '%s main\n' "$PWD"; exit 0 ;;
  *' worktree add '*) mkdir -p "${@: -1}"; exit 0 ;;
  *' worktree remove '*) rm -rf "$3"; exit 0 ;;
  *' rev-parse HEAD '*) echo 0123456789abcdef0123456789abcdef01234567; exit 0 ;;
  *' rev-list --count '*) echo 0; exit 0 ;;
  *' pull '*) exit 0 ;;
esac
exit 1
STUB
for tool in tmux curl npm codex gemini poma-memory; do
  cat > "$T/bin/$tool" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS/${0##*/}"
exit 1
STUB
done
chmod +x "$T/bin/"*

fixture() {
  CASE=$((CASE + 1))
  ROOT="$T/$CASE"
  TEST_HOME="$ROOT/home"
  INSTALL="$TEST_HOME/.megavibe"
  SOURCE="$ROOT/work copy"
  PROJECT="$ROOT/project"
  mkdir -p "$INSTALL/scripts" "$SOURCE/scripts" "$PROJECT" "$ROOT/calls" \
    "$TEST_HOME/.claude" "$ROOT/config" "$TEST_HOME/.local/bin"
  mkdir "$SOURCE/.git"
  cp "$REPO/scripts/memory-config.sh" "$REPO/scripts/reviewers.sh" "$INSTALL/scripts/"
  cp "$LAUNCHER" "$INSTALL/megavibe"
  cp "$LAUNCHER" "$SOURCE/megavibe"
  # Different bytes ensure the old launcher's self-update/re-exec path is exercised.
  printf '\n# work copy fixture\n' >> "$SOURCE/megavibe"
  chmod +x "$INSTALL/megavibe" "$SOURCE/megavibe"
  cp "$REPO/init.sh" "$SOURCE/init.sh"
  cp "$REPO/scripts/guard-run.sh" "$SOURCE/scripts/guard-run.sh"
  cp -R "$REPO/template" "$SOURCE/template"
  printf '<!-- megavibe-v3 -->\nnew protocol\n<!-- /megavibe-v3 -->\n' > "$SOURCE/template/CLAUDE.md"
  cat > "$SOURCE/setup.sh" <<'STUB'
#!/bin/bash
printf 'called\n' > "$CALLS/setup"
exit 77
STUB
  cp "$SOURCE/setup.sh" "$INSTALL/setup.sh"
  cp "$SOURCE/init.sh" "$INSTALL/init.sh"
  printf '\n# installed init fixture\n' >> "$INSTALL/init.sh"
  cp "$SOURCE/scripts/guard-run.sh" "$INSTALL/scripts/guard-run.sh"
  cp -R "$SOURCE/template" "$INSTALL/template"
  printf '<!-- megavibe-v3 -->\nold protocol\n<!-- /megavibe-v3 -->\n' > "$INSTALL/template/CLAUDE.md"
  cp "$INSTALL/template/CLAUDE.md" "$TEST_HOME/.claude/CLAUDE.md"
  printf 'old statusline\n' > "$TEST_HOME/.claude/statusline.sh"
  printf '3\n' > "$INSTALL/version"
  printf '0\n' > "$INSTALL/.last-update-check"
  printf 'diverged:old\n' > "$INSTALL/.update-available"
  printf 'old notice\n' > "$INSTALL/.cli-downgrade-notice"
  # Put the PA outside the install too: following its link must not change its hooks.
  mkdir -p "$ROOT/personal/.agent" "$ROOT/personal/.claude/hooks"
  printf '{}\n' > "$ROOT/personal/.claude/settings.json"
  printf 'old hook\n' > "$ROOT/personal/.claude/hooks/block-dangerous-bash.sh"
  ln -s "$ROOT/personal" "$INSTALL/personal"
  ln -s ../../.megavibe/megavibe "$TEST_HOME/.local/bin/megavibe"
  ENTRY="$SOURCE/megavibe"
}
snapshot() {
  (cd "$1" && find . -print | LC_ALL=C sort &&
    find . -type f -exec cksum {} \; | LC_ALL=C sort)
}
launch() {
  RC=0
  # Command substitution waits for inherited output pipes from background work too.
  OUT=$(cd "$PROJECT" && env -i HOME="$TEST_HOME" MEGAVIBE_HOME="$INSTALL" \
    CLAUDE_CONFIG_DIR="$ROOT/config" PATH="$T/bin:$PATH" CALLS="$ROOT/calls" \
    MEGAVIBE_ROUTER=0 MEGAVIBE_STYLE=0 MEGAVIBE_INIT_SKIP_HEAL=1 \
    MEGAVIBE_SCRATCH_FOLLOWS_PROJECT=0 MEGAVIBE_TTY_PROMPT=1 \
    /bin/bash "$ENTRY" "$@" </dev/null 2>"$ROOT/stderr") || RC=$?
}
check() {
  local label="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "PASS $label"
  else FAIL=$((FAIL + 1)); echo "FAIL $label (exit $RC)"; cat "$ROOT/stderr"; fi
}
notice() {
  [ "$(wc -l < "$ROOT/stderr" | tr -d ' ')" = 1 ] &&
    grep -q 'work copy' "$ROOT/stderr" &&
    grep -q 'installed megavibe.*left untouched' "$ROOT/stderr" &&
    grep -Fq "bash $(printf '%q' "$SOURCE/setup.sh")" "$ROOT/stderr"
}

for spelling in path symlink identical hardlink; do
  fixture
  case "$spelling" in
    symlink)
      ln -s 'work copy' "$ROOT/source-dir"
      ln -s source-dir/megavibe "$ROOT/entry"
      ENTRY="$ROOT/entry" ;;
    identical) rmdir "$SOURCE/.git"; cp "$INSTALL/megavibe" "$SOURCE/megavibe" ;;
    hardlink) rm "$SOURCE/megavibe"; ln "$INSTALL/megavibe" "$SOURCE/megavibe" ;;
  esac
  snapshot "$INSTALL" > "$ROOT/install-before"
  snapshot "$TEST_HOME/.claude" > "$ROOT/global-before"
  snapshot "$ROOT/personal" > "$ROOT/personal-before"
  launch --resume example-session
  snapshot "$INSTALL" > "$ROOT/install-after"
  snapshot "$TEST_HOME/.claude" > "$ROOT/global-after"
  snapshot "$ROOT/personal" > "$ROOT/personal-after"
  check "$spelling: installed tree checksums unchanged" cmp -s "$ROOT/install-before" "$ROOT/install-after"
  check "$spelling: global protocol and statusline unchanged" cmp -s "$ROOT/global-before" "$ROOT/global-after"
  check "$spelling: personal hooks and settings unchanged" cmp -s "$ROOT/personal-before" "$ROOT/personal-after"
  check "$spelling: exactly one stderr notice with quoted setup command" notice
  check "$spelling: stops before initialization or Claude" test "$RC:$(find "$PROJECT" -mindepth 1 -print):$(cat "$ROOT/calls/claude" 2>/dev/null || true)" = '1::'
  check "$spelling: no update check, fetch or tool installs" test "$(find "$ROOT/calls" -type f -print)" = ''
done

for spelling in cli-link installed-link; do
  fixture
  # A normal install retains source-repo sync, including wrapper replacement.
  printf '%s\n' "$SOURCE" > "$INSTALL/source-repo"
  date +%s > "$INSTALL/.last-update-check"
  ENTRY="$TEST_HOME/.local/bin/megavibe"
  if [ "$spelling" = installed-link ]; then
    mv "$INSTALL/megavibe" "$ROOT/installed-launcher"
    ln -s ../../installed-launcher "$INSTALL/megavibe"
    # INSTALL is home/.megavibe, so this relative link resolves through home/..
  fi
  launch --resume example-session
  check "$spelling: installed launcher still launches" test "$RC" = 0
  check "$spelling: wrapper still syncs" cmp -s "$SOURCE/megavibe" "$INSTALL/megavibe"
  check "$spelling: scripts still sync" cmp -s "$SOURCE/init.sh" "$INSTALL/init.sh"
  check "$spelling: protocol still syncs" cmp -s "$SOURCE/template/CLAUDE.md" "$TEST_HOME/.claude/CLAUDE.md"
  check "$spelling: personal hooks still sync" cmp -s "$SOURCE/template/.claude/hooks/block-dangerous-bash.sh" "$ROOT/personal/.claude/hooks/block-dangerous-bash.sh"
  check "$spelling: no work-copy notice" test "$(grep -c 'work copy' "$ROOT/stderr" || true)" = 0
done

fixture
rm -rf "$INSTALL" "$TEST_HOME/.claude"
launch --resume example-session
check 'non-interactive first-time repo launch refuses' test "$RC" = 1
check 'first-time refusal gives one setup command' notice
check 'first-time refusal does not run setup or create installation' test "$([ -e "$ROOT/calls/setup" ] || [ -e "$INSTALL" ] || [ -e "$TEST_HOME/.claude" ]; echo $?)" = 1

# Even a deliberately symlinked installed launcher must not bootstrap a repo
# non-interactively when only the repo's setup.sh is available.
fixture
rm "$INSTALL/megavibe" "$INSTALL/init.sh" "$INSTALL/setup.sh"
ln -s "$SOURCE/megavibe" "$INSTALL/megavibe"
launch --resume example-session
check 'installed repo symlink also refuses non-interactive first-time setup' test "$RC" = 1
check 'installed repo symlink is still a work copy' notice
check 'installed repo symlink never calls setup' test ! -e "$ROOT/calls/setup"

# Explicit update dispatch remains available from a work copy.
fixture
launch update
check 'explicit update still pulls the source checkout' grep -q 'pull --ff-only -q origin main' "$ROOT/calls/git"
check 'explicit update exits normally without work-copy refusal' test "$RC:$(cat "$ROOT/stderr")" = '0:'


# An environment override cannot make a checkout authenticate itself.
for marker in directory file; do
  for protocol in present missing; do
    fixture
    if [ "$marker" = file ]; then rmdir "$SOURCE/.git"; printf 'gitdir: ../git-store\n' > "$SOURCE/.git"; fi
    INSTALL="$SOURCE"
    [ "$protocol" = present ] || rm "$TEST_HOME/.claude/CLAUDE.md"
    snapshot "$TEST_HOME" > "$ROOT/home-before"
    snapshot "$SOURCE" > "$ROOT/source-before"
    launch --resume example-session
    snapshot "$TEST_HOME" > "$ROOT/home-after"
    snapshot "$SOURCE" > "$ROOT/source-after"
    check "override, .git $marker, protocol $protocol: refuses checkout" notice
    check "override, .git $marker, protocol $protocol: no writes or setup" \
      test "$RC:$(cmp -s "$ROOT/home-before" "$ROOT/home-after"; echo $?):$(cmp -s "$ROOT/source-before" "$ROOT/source-after"; echo $?):$(find "$ROOT/calls" -type f -print)" = '1:0:0:'
  done
done

# Both automatic setup branches require a terminal, even for an installed file.
for arm in installed fallback; do
  fixture
  ENTRY="$INSTALL/megavibe"
  rm "$TEST_HOME/.claude/CLAUDE.md"
  if [ "$arm" = fallback ]; then
    rmdir "$SOURCE/.git"
    rm "$INSTALL/megavibe" "$INSTALL/setup.sh"
    ln -s "$SOURCE/megavibe" "$INSTALL/megavibe"
    ENTRY="$SOURCE/megavibe"
  fi
  launch --resume example-session
  check "$arm setup: nonterminal refusal" test "$RC" = 1
  check "$arm setup: explicit setup remedy" grep -Fq 'setup requires a terminal; run explicitly: bash ' "$ROOT/stderr"
  check "$arm setup: never runs setup" test ! -e "$ROOT/calls/setup"
done

# Test real settings writers and worktree dispatch; stub node's external effects.
for command in 'memory set docs_ask 1' 'memory unset docs_ask' 'reviewers set reviewer' \
    'worktree review' 'worktree remove review' 'node install' 'node session start test' \
    'assistant' 'personal' 'trash-greenlight' 'tick' 'usage probe run'; do
  fixture
  mkdir -p "$PROJECT/.agent" "$ROOT/project-review"
  printf '{"env":{"MEGAVIBE_MEMORY_DOCS_ASK":"0"}}\n' > "$TEST_HOME/.claude/settings.json"
  for helper in megavibe-node tick usage-probe; do
    printf '#!/bin/bash\necho called > "$CALLS/helper"\n' > "$INSTALL/scripts/$helper.sh"
  done
  snapshot "$TEST_HOME" > "$ROOT/home-before"
  snapshot "$PROJECT" > "$ROOT/project-before"
  snapshot "$ROOT/project-review" > "$ROOT/worktree-before"
  launch $command
  snapshot "$TEST_HOME" > "$ROOT/home-after"
  snapshot "$PROJECT" > "$ROOT/project-after"
  if [ -d "$ROOT/project-review" ]; then snapshot "$ROOT/project-review" > "$ROOT/worktree-after"; else echo removed > "$ROOT/worktree-after"; fi
  check "$command: refused before dispatch" notice
  check "$command: no writes or helpers" test "$RC:$(cmp -s "$ROOT/home-before" "$ROOT/home-after"; echo $?):$(cmp -s "$ROOT/project-before" "$ROOT/project-after"; echo $?):$(cmp -s "$ROOT/worktree-before" "$ROOT/worktree-after"; echo $?):$(find "$ROOT/calls" -type f -print)" = '1:0:0:0:'
done

for command in 'memory' 'memory list' 'reviewers' 'reviewers list' 'worktree' 'worktree list' 'help' 'version'; do
  fixture
  snapshot "$TEST_HOME" > "$ROOT/home-before"
  snapshot "$PROJECT" > "$ROOT/project-before"
  launch $command
  snapshot "$TEST_HOME" > "$ROOT/home-after"
  snapshot "$PROJECT" > "$ROOT/project-after"
  check "$command: work-copy listing works without writes" test "$RC:$(cmp -s "$ROOT/home-before" "$ROOT/home-after"; echo $?):$(cmp -s "$ROOT/project-before" "$ROOT/project-after"; echo $?):$(cat "$ROOT/stderr")" = '0:0:0:'
done

for spelling in custom case-alias hardlink-outside; do
  fixture
  date +%s > "$INSTALL/.last-update-check"
  case "$spelling" in
    custom) mv "$INSTALL" "$ROOT/custom install"; INSTALL="$ROOT/custom install"; ENTRY="$INSTALL/megavibe" ;;
    case-alias)
      ENTRY="$INSTALL/MEGAVIBE"
      if [ ! -f "$ENTRY" ]; then
        echo 'SKIP case alias: scratch filesystem is case-sensitive'
        SKIP=$((SKIP + 1)); continue
      fi ;;
    hardlink-outside)
      # No .git here: directory identity alone must reject this hard link.
      ln "$INSTALL/megavibe" "$ROOT/megavibe"
      ENTRY="$ROOT/megavibe" ;;
  esac
  launch --resume example-session
  if [ "$spelling" = hardlink-outside ]; then
    check 'hard link outside installation: refused without dispatch' test "$RC:$(find "$ROOT/calls" -type f -print)" = '1:'
    check 'hard link outside installation: work-copy notice' grep -q 'work copy' "$ROOT/stderr"
  else
    check "$spelling: installed launch succeeds" test "$RC" = 0
    check "$spelling: reaches Claude" test -f "$ROOT/calls/claude"
  fi
done

fixture
launch update --check
check 'update --check stays exempt' test "$RC:$(grep -c 'work copy' "$ROOT/stderr" || true)" = '0:0'

printf '%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
