#!/usr/bin/env bash
# Self-serve installer for megawork.
#
#   curl -fsSL https://raw.githubusercontent.com/poma-ai/megavibe/main/megawork/install.sh | bash
#
# Written to be run by the person who will actually use it — no admin, no repo
# checkout, no jargon in the output. It fetches a tarball (no git required, so
# macOS never pops the Xcode developer-tools dialog), installs Claude Code if it
# is missing, and hands off to the folder picker.
#
# Coexistence: if this Mac already has classic megavibe, nothing about it is
# changed unless the person asks. Both work side by side.

set -uo pipefail

B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[0m'
say(){ echo "$*"; }
ok(){ echo "  ${G}✓${R} $*"; }
uhoh(){ echo "  ${Y}!${R} $*"; }
die(){ echo ""; echo "  Sorry — $*"; echo "  Nothing was changed. Send this message to whoever shared the link."; exit 1; }

# Prompts must come from the terminal: with `curl | bash`, stdin is the script.
TTY_IN=""
[ -t 0 ] && TTY_IN="/dev/stdin"
if [ -z "$TTY_IN" ] && ( : < /dev/tty ) 2>/dev/null; then TTY_IN="/dev/tty"; fi
ask(){ local _a=""; [ -n "$TTY_IN" ] && { read -r -p "$1" _a < "$TTY_IN" || _a=""; }; printf -v "$2" '%s' "$_a"; }

echo ""
echo "${B}Setting up your assistant${R}"
echo ""

[ "$(uname -s)" = "Darwin" ] || die "this only works on a Mac at the moment."

# ── 1. Claude ───────────────────────────────────────────────────────
if command -v claude &>/dev/null; then
  ok "Claude is already installed"
else
  say "  Installing Claude (this is the assistant itself)…"
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 \
    || die "Claude could not be installed. You may need to install it first from claude.ai/download."
  export PATH="$HOME/.local/bin:$PATH"
  command -v claude &>/dev/null || die "Claude installed but could not be found."
  ok "Claude installed"
fi

# ── 2. The files ────────────────────────────────────────────────────
SRC="${MEGAWORK_SRC:-}"
if [ -z "$SRC" ]; then
  say "  Downloading the assistant setup…"
  TMP=$(mktemp -d) || die "could not create a temporary folder."
  trap 'rm -rf "$TMP"' EXIT
  # Tarball, not git clone: git on a fresh Mac triggers the Xcode CLT prompt.
  curl -fsSL https://codeload.github.com/poma-ai/megavibe/tar.gz/refs/heads/main \
    | tar -xz -C "$TMP" 2>/dev/null || die "the download failed. Check the internet connection and try again."
  SRC=$(find "$TMP" -maxdepth 1 -type d -name 'megavibe-*' | head -1)
  [ -n "$SRC" ] && [ -d "$SRC/megawork" ] || die "the download looked wrong."
  ok "Downloaded"
fi

# ── 3. The harness ──────────────────────────────────────────────────
# Megawork is not a stripped-down Claude: the whole point is that a colleague
# gets the same machinery a developer does — second opinions from Gemini and
# Codex, and POMA's own semantic memory over their documents — just wrapped so
# they never see any of it. megavibe's installer already knows how to put those
# on a Mac, so reuse it rather than reimplementing a lesser version.
if [ -f "$SRC/setup.sh" ]; then
  say "  Setting up the machinery (this is the longest part)…"
  bash "$SRC/setup.sh" --harness-only </dev/null >/tmp/megawork-harness.log 2>&1 \
    && ok "Machinery ready" \
    || uhoh "Some optional parts did not install — it still works, just with fewer helpers"
  echo "  ${DIM:-}$(grep -cE '^\s*(✓|ok)' /tmp/megawork-harness.log 2>/dev/null || echo 0) components installed${R}"
fi

# ── 4. Hand off to the real installer (it asks where the folder goes) ─
MEGAWORK_WRAPPED=1 bash "$SRC/megawork/init.sh" "$@" || die "setup did not finish."

# ── 4. Sign in, if needed ───────────────────────────────────────────
ENGINE="${MEGAWORK_HOME:-$HOME/.megawork}"
echo ""
if [ -n "$TTY_IN" ] && ! (cd "$HOME" && perl -e 'alarm 60; exec @ARGV' claude --model haiku -p "ok" </dev/null 2>&1 | grep -qv "Not logged in"); then
  echo "${B}One thing left: signing in${R}"
  echo "  A browser window will open. Sign in with your work Google account."
  ask "  Press Enter when you're ready… " _
  claude < "$TTY_IN" || true
fi

echo ""
echo "${B}You're set.${R}"
echo ""
echo "  1. Open ${B}Megavibe${R} from your Applications folder"
echo "     (drag it to the Dock so it's always there)"
echo "  2. Say hello, and tell it what you're working on"
echo ""
echo "  Your folder is: $(cat "$ENGINE/data-dir" 2>/dev/null || echo "$HOME/Megavibe")"
echo "  Put things you'd like help with into its ${B}Inbox${R}."
echo ""
echo "  If anything looks wrong later, run:  ${B}megawork-doctor${R}"
echo ""
