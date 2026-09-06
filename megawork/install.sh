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

B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; DIM=$'\033[2m'; R=$'\033[0m'
say(){ echo "$*"; }
ok(){ echo "  ${G}✓${R} $*"; }
uhoh(){ echo "  ${Y}!${R} $*"; }
die(){ echo ""; echo "  Sorry — $*"; echo "  Setup did not complete. Anything already installed is harmless, and running"; echo "  this same command again is safe. Send this message to whoever shared the link."; exit 1; }

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

# ── 2b. Node, if the Mac has none ───────────────────────────────────
# The helpers (Gemini CLI, its MCP bridge, Codex) are npm packages, and
# setup.sh assumes npm exists. A stock Mac has no Node at all, so on such a Mac
# the whole harness step silently installed nothing ("0 components installed")
# and the assistant had no Gemini tool even with a valid key. Fetch Node's
# official LTS tarball into the engine — no Homebrew, no sudo, no Xcode dialog —
# and put it on PATH for this install and for every later session (the launcher
# adds the same directory).
ENGINE_DIR="${MEGAWORK_HOME:-$HOME/.megawork}"
NODE_DIR="$ENGINE_DIR/tools/node"
# Rename an old-name engine BEFORE anything below creates ~/.megawork: init.sh
# only migrates when the new path does not exist yet, and a stray mkdir here
# would leave the person's history, folder pointer and key behind.
[ -d "$HOME/.megavibe-nondev" ] && [ ! -e "$ENGINE_DIR" ] && mv "$HOME/.megavibe-nondev" "$ENGINE_DIR" 2>/dev/null
if [ -x "$NODE_DIR/bin/npm" ]; then export PATH="$NODE_DIR/bin:$PATH"; fi
# Not just "is there an npm": the Gemini CLI needs Node 20+, and an old Node
# installs it with a warning and then dies with a SyntaxError at first use.
NODE_MIN=20
_node_major(){ node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }
if ! command -v npm &>/dev/null || [ "$(_node_major)" -lt "$NODE_MIN" ]; then
  say "  Downloading a component the helpers need (Node, ~240 MB; with the helpers the folder grows to ~600 MB) — a minute or two…"
  # The real CPU, not the shell's: a Terminal running under Rosetta reports
  # x86_64 from `uname -m` on an Apple Silicon Mac.
  _arch=x64; [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] && _arch=arm64
  # Newest LTS from Node's own index. jq ships with macOS 15+; the sed form is
  # only a fallback for older Macs, and a pinned version backs both (v24.20.0
  # was the LTS "Krypton" on 2026-09-06; tarball verified to exist).
  _idx=$(curl -fsSL --max-time 20 https://nodejs.org/dist/index.json 2>/dev/null || true)
  _ver=""
  if [ -n "$_idx" ] && command -v jq &>/dev/null; then
    _ver=$(printf '%s' "$_idx" | jq -r '[.[] | select(.lts != false)][0].version // empty' 2>/dev/null || true)
  elif [ -n "$_idx" ]; then
    # 60 lines back: the "files" array alone is ~25 comma-separated items.
    _ver=$(printf '%s\n' "$_idx" | tr ',' '\n' | grep -m1 -B60 '"lts":"[A-Z]' | sed -n 's/.*"version":"\(v[0-9.]*\)".*/\1/p' | tail -1 || true)
  fi
  case "$_ver" in v[0-9]*.[0-9]*.[0-9]*) ;; *) _ver="v24.20.0" ;; esac
  # An engine Node from an earlier install that is still on the current LTS
  # major is fine; one that has fallen a major behind is refreshed.
  if [ -x "$NODE_DIR/bin/node" ] && [ "$(_node_major)" -ge "$NODE_MIN" ] \
     && [ "$(_node_major)" -ge "$(printf '%s' "$_ver" | sed 's/^v\([0-9]*\).*/\1/')" ]; then
    export PATH="$NODE_DIR/bin:$PATH"; _skip_node=1
  fi
  # Download and unpack into a scratch dir, then swap into place: a Ctrl-C or a
  # dropped connection must not leave a half-extracted node/ that a later run
  # trusts. Leftovers from earlier failed runs are cleared first.
  mkdir -p "$ENGINE_DIR/tools" 2>/dev/null; rm -rf "$ENGINE_DIR/tools"/node-v*-darwin-* "$ENGINE_DIR/tools/.node-stage" 2>/dev/null
  _stage=""; [ "${_skip_node:-0}" = 1 ] || _stage=$(mktemp -d "$ENGINE_DIR/tools/.node-stage.XXXXXX" 2>/dev/null || echo "")
  if [ "${_skip_node:-0}" = 1 ]; then :
  elif [ -n "$_stage" ] \
     && curl -fsSL --max-time 300 "https://nodejs.org/dist/$_ver/node-$_ver-darwin-$_arch.tar.gz" 2>/dev/null \
          | tar -xz -C "$_stage" 2>/dev/null \
     && [ -x "$_stage/node-$_ver-darwin-$_arch/bin/node" ] \
     && "$_stage/node-$_ver-darwin-$_arch/bin/node" -v >/dev/null 2>&1 \
     && rm -rf "$NODE_DIR" && mv "$_stage/node-$_ver-darwin-$_arch" "$NODE_DIR"; then
    # Managed Macs (Jamf, Santa) can refuse binaries carrying a quarantine flag.
    xattr -dr com.apple.quarantine "$NODE_DIR" 2>/dev/null || true
    export PATH="$NODE_DIR/bin:$PATH"
    ok "Node $_ver ready (kept in ${ENGINE_DIR/#$HOME/\~}/tools)"
  else
    uhoh "Could not fetch Node — the second-opinion helpers will be missing; everything else works"
  fi
  rm -rf "$_stage" 2>/dev/null
fi

# ── 3. The harness ──────────────────────────────────────────────────
# Megawork is not a stripped-down Claude: the whole point is that a colleague
# gets the same machinery a developer does — second opinions from Gemini and
# Codex, and POMA's own semantic memory over their documents — just wrapped so
# they never see any of it. megavibe's installer already knows how to put those
# on a Mac, so reuse it rather than reimplementing a lesser version.
if [ -f "$SRC/setup.sh" ]; then
  say "  Setting up the machinery (this is the longest part)…"
  # A stable log path, so "some optional parts did not install" can actually be
  # looked at afterwards — a mktemp name is gone from everyone's memory by then.
  mkdir -p "${MEGAWORK_HOME:-$HOME/.megawork}/logs" 2>/dev/null
  HARNESS_LOG="${MEGAWORK_HOME:-$HOME/.megawork}/logs/harness-install.log"
  bash "$SRC/setup.sh" --harness-only </dev/null >"$HARNESS_LOG" 2>&1 \
    && ok "Machinery ready" \
    || uhoh "Some optional parts did not install — it still works, just with fewer helpers (details: $HARNESS_LOG)"
  echo "  ${DIM:-}$(grep -cE '^\s*(✓|ok)' "$HARNESS_LOG" 2>/dev/null || true) components installed${R}"
fi

# ── 4. Hand off to the real installer (it asks where the folder goes) ─
# Ctrl-C during an optional step inside init.sh (the key paste) must not kill
# this script too — the closing instructions below are for the parts that DID
# get set up. init.sh handles the interrupt itself and continues.
trap 'echo' INT
MEGAWORK_WRAPPED=1 bash "$SRC/megawork/init.sh" "$@" || {
  trap - INT; echo ""
  echo "  Sorry — setup stopped before it finished. Some parts may be in place;"
  echo "  running this same command again is safe and picks up where it left off."
  echo "  Send this message to whoever shared the link."; exit 1; }
trap - INT

# ── 4. Sign in, if needed ───────────────────────────────────────────
ENGINE="${MEGAWORK_HOME:-$HOME/.megawork}"
echo ""
# Test for the SUCCESS token. The old `grep -qv "Not logged in"` was true for
# any extra line claude printed, so the sign-in step was skipped almost always.
# Signed in if the reply carries the token; ALSO signed in if the output says
# nothing about logging in (a refusal or a wrapper line is not a login problem).
# Only an explicit not-logged-in verdict earns the sign-in step — that step
# launches a plain `claude`, which is an unsandboxed developer session.
PROBE=$( (cd "$HOME" && perl -e 'alarm 60; exec @ARGV' claude --model haiku -p "reply with exactly: LOGIN-OK" </dev/null 2>&1) || true)
if [ -n "$TTY_IN" ] && ! printf '%s' "$PROBE" | grep -q "LOGIN-OK" \
   && printf '%s' "$PROBE" | grep -qiE 'not logged in|please log in|/login|invalid api key|authentication'; then
  echo "${B}One thing left: signing in${R}"
  echo "  A browser window will open. Sign in with your work Google account."
  echo "  ${DIM:-}When the browser says you are signed in, come back here and press Ctrl-D.${R}"
  ask "  Press Enter when you're ready… " _
  claude < "$TTY_IN" || true
fi

echo ""
echo "${B}You're set.${R}"
echo ""
if [ -d "/Applications/Megawork.app" ]; then
  echo "  1. Open ${B}Megawork${R} from your Applications folder"
  echo "     (drag it to the Dock so it's always there)"
else
  echo "  1. Open Terminal and type: ${B}megawork${R}"
fi
echo "  2. Say hello, and tell it what you're working on"
echo ""
echo "  Your folder is: $(cat "$ENGINE/data-dir" 2>/dev/null || echo "$HOME/Megawork")"
echo "  Put things you'd like help with into its ${B}Inbox${R}."
echo ""
echo "  If anything looks wrong later, run:  ${B}megawork-doctor${R}"
echo ""
