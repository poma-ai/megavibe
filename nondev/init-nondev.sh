#!/usr/bin/env bash
# Provision megavibe-nondev on a colleague's Mac. Run by an ADMIN, once.
#
# Creates:
#   ~/.megavibe-nondev/      engine: policy, protocol, launcher   (control plane)
#   ~/megavibe-nondev/       the colleague's four folders          (data plane)
#   /Applications/…app       Dock-able launcher                    (optional)
#
# The two planes are separate on purpose: the session can write the data folder
# but must never be able to rewrite its own guardrails. Kept out of
# ~/Desktop and ~/Documents so iCloud sync cannot lock the folders mid-session.
#
# Usage: bash nondev/init-nondev.sh [--data DIR] [--name "Display Name"] [--no-app]

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ENGINE="${MEGAVIBE_NONDEV_HOME:-$HOME/.megavibe-nondev}"
DATA="$HOME/megavibe-nondev"
APPNAME="Megavibe Nondev"
MAKE_APP=1

while [ $# -gt 0 ]; do
  case "$1" in
    --data)   DATA="$2"; shift 2 ;;
    --name)   APPNAME="$2"; shift 2 ;;
    --no-app) MAKE_APP=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ok(){ echo "  ✓ $*"; }

# ─── Engine (control plane) ─────────────────────────────────────────
mkdir -p "$ENGINE/policy" "$ENGINE/prompts" "$ENGINE/bin" "$ENGINE/logs"
# Policy files are left read-only (below) so a stray edit is obvious; make them
# writable again first, or re-running the installer dies on the copy and leaves
# a half-updated engine (found by running init twice).
chmod u+w "$ENGINE/policy/"*.json "$ENGINE/policy/sandbox.sb" 2>/dev/null || true
mkdir -p "$ENGINE/hooks"
cp "$SRC/template/hooks/"*.sh "$ENGINE/hooks/" && chmod +x "$ENGINE/hooks/"*.sh
cp "$SRC/template/policy/mcp.json"      "$ENGINE/policy/mcp.json"
cp "$SRC/template/CLAUDE-nondev.md"     "$ENGINE/prompts/CLAUDE-nondev.md"
cp "$SRC/bin/megavibe-nondev"           "$ENGINE/bin/megavibe-nondev"
cp "$SRC/bin/nondev-doctor"             "$ENGINE/bin/nondev-doctor"
chmod +x "$ENGINE/bin/megavibe-nondev" "$ENGINE/bin/nondev-doctor"
printf '%s\n' "$DATA" > "$ENGINE/data-dir"

# Render the seatbelt profile with resolved absolute paths. Seatbelt matches on
# REAL paths, so a symlinked location (e.g. /tmp -> /private/tmp) must be
# resolved or the rules silently fail to match.
DATA_REAL=$(mkdir -p "$DATA" && cd "$DATA" && pwd -P)
ENGINE_REAL=$(cd "$ENGINE" && pwd -P)
HOME_REAL=$(cd "$HOME" && pwd -P)
render(){ sed -e "s|@DATA@|$DATA_REAL|g" -e "s|@ENGINE@|$ENGINE_REAL|g" -e "s|@HOME@|$HOME_REAL|g" "$1" > "$2"; }
render "$SRC/template/sandbox.sb.template"         "$ENGINE/policy/sandbox.sb"
render "$SRC/template/policy/settings.json.template" "$ENGINE/policy/settings.json"
ok "engine installed in $ENGINE"

# The colleague must not be able to edit the policy from their own session;
# the jail already prevents it, but make the intent explicit on disk too.
chmod 444 "$ENGINE/policy/settings.json" "$ENGINE/policy/mcp.json" 2>/dev/null || true

# ─── Data folder (the product, as the colleague sees it) ────────────
mkdir -p "$DATA/Inbox" "$DATA/Workspace" "$DATA/Delivered" "$DATA/Library"
[ -f "$DATA/Read me first.txt" ] || cat > "$DATA/Read me first.txt" <<TXT
This folder is where you and your assistant work together.

  Inbox       Put things here you'd like help with.
  Workspace   Work in progress.
  Delivered   Finished results, ready to hand on.
  Library     Reference material to look things up in.

To start, open $APPNAME from your Dock and just say what you need —
in normal words. For example: "summarise the three PDFs I put in Inbox".

Your assistant can only see and change things inside this folder.
TXT
ok "folder ready at $DATA"

# ─── CLI shortcut ───────────────────────────────────────────────────
mkdir -p "$HOME/.local/bin"
ln -sf "$ENGINE/bin/megavibe-nondev" "$HOME/.local/bin/megavibe-nondev"
ln -sf "$ENGINE/bin/nondev-doctor"  "$HOME/.local/bin/nondev-doctor"
ok "commands installed: megavibe-nondev, nondev-doctor"

# ─── Dock-able launcher app ─────────────────────────────────────────
if [ "$MAKE_APP" -eq 1 ] && [ "$(uname -s)" = "Darwin" ]; then
  APP="/Applications/${APPNAME}.app"
  if command -v osacompile &>/dev/null; then
    TMP_SCPT=$(mktemp -t nondevapp).applescript
    # Open Terminal on the launcher. Terminal (not the Claude desktop app) is
    # deliberate: the desktop app does not honour these CLI flags, so it would
    # silently bypass the jail.
    cat > "$TMP_SCPT" <<APPLESCRIPT
tell application "Terminal"
    activate
    do script "clear; '$ENGINE/bin/megavibe-nondev'"
end tell
APPLESCRIPT
    rm -rf "$APP" 2>/dev/null || true
    if osacompile -o "$APP" "$TMP_SCPT" 2>/dev/null; then
      ok "launcher created: $APP  (drag it to the Dock)"
    else
      echo "  ! could not create the launcher app (needs write access to /Applications)"
      echo "    the colleague can still start it by running: megavibe-nondev"
    fi
    rm -f "$TMP_SCPT"
  fi
fi

# ─── Backends (optional, best effort) ───────────────────────────────
# Tier 1: whatever they are already signed into (claude.ai connectors, codex,
# an existing gemini setup) needs nothing from us — the session picks it up.
# Tier 2: mint a free, billing-less Gemini key from their OWN Google identity.
# Tier 3 (fallback): an admin hands over a key.
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f "$SRC/../scripts/mint-gemini-key.sh" ]; then
  echo ""
  echo "  Gemini backend: no key found."
  if [ -t 0 ] && [ -f "$HOME/.gemini/oauth_creds.json" ]; then
    read -r -p "  Mint a free one from this Mac's Google login now? [y/N] " _ans
    case "${_ans:-n}" in
      [yY]*) bash "$SRC/../scripts/mint-gemini-key.sh" --write-rc \
               || echo "  ! minting failed — Claude-only for now (that is fine)" ;;
      *) echo "  skipped — Claude-only for now (that is fine)" ;;
    esac
  else
    echo "  skipped — Claude works on its own; add one later with scripts/mint-gemini-key.sh"
  fi
fi

echo ""
echo "Done. Next, with the colleague present:"
echo "  1. run 'claude' once and sign them in"
echo "  2. drag ${APPNAME} from /Applications to the Dock"
echo "  3. open it and try: \"what can you help me with?\""
