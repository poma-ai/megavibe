#!/usr/bin/env bash
# Provision megavibe-nondev. Normally reached via the self-serve one-liner
# (nondev/install-nondev.sh), which downloads this and hands off to it.
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
# Usage: bash nondev/init-nondev.sh [--data DIR] [--gdrive [FolderName]]
#                                   [--folder-name NAME] [--name "App Name"] [--no-app]
#
# With no --data and a terminal, it asks where the folder should live and lists
# the Google Drive locations (including shared drives) it finds on this Mac.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ENGINE="${MEGAVIBE_NONDEV_HOME:-$HOME/.megavibe-nondev}"
DATA="$HOME/megavibe-nondev"
APPNAME="Megavibe Nondev"
MAKE_APP=1
USE_GDRIVE=0
DATA_EXPLICIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --data)   DATA="$2"; DATA_EXPLICIT=1; shift 2 ;;
    --gdrive) USE_GDRIVE=1
              case "${2:-}" in -*|"") shift ;; *) FOLDER_NAME="$2"; shift 2 ;; esac ;;
    --folder-name) FOLDER_NAME="$2"; shift 2 ;;
    --name)   APPNAME="$2"; shift 2 ;;
    --no-app) MAKE_APP=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ok(){ echo "  ✓ $*"; }

# Ask the human, not stdin: piped installs (curl | bash) hand us the script on
# stdin, so prompts must go to the controlling terminal.
TTY_IN=""
[ -t 0 ] && TTY_IN="/dev/stdin"
if [ -z "$TTY_IN" ] && ( : < /dev/tty ) 2>/dev/null; then TTY_IN="/dev/tty"; fi
ask(){ # ask "prompt" varname ; leaves var empty when there is nobody to ask
  local _p="$1" _v="$2" _a=""
  if [ -n "$TTY_IN" ]; then read -r -p "$_p" _a < "$TTY_IN" || _a=""; fi
  printf -v "$_v" '%s' "$_a"
}
interactive(){ [ -n "$TTY_IN" ]; }

# Google Drive as the native home: many non-technical people already live there,
# and it makes the folder reachable from their phone and shareable with others.
# Snapshots deliberately live in the engine, so sync never sees them.
if [ "$USE_GDRIVE" -eq 1 ] && [ "$DATA_EXPLICIT" -eq 1 ]; then
  echo "  ! --gdrive and --data are mutually exclusive; keeping --data" >&2
  USE_GDRIVE=0
fi

# ─── Where should the folder live? ──────────────────────────────────
# Non-technical people mostly live in Google Drive, and "which Drive folder"
# is the one setup question they have a real opinion about. Detect the actual
# options on this Mac and let them point at one, rather than guessing.
FOLDER_NAME="${FOLDER_NAME:-Megavibe}"

gdrive_roots() {   # every My Drive + every Shared drive, one per line
  local r
  for r in "$HOME/Library/CloudStorage/GoogleDrive-"*/"My Drive"; do
    [ -d "$r" ] && printf '%s\n' "$r"
  done
  for r in "$HOME/Library/CloudStorage/GoogleDrive-"*/"Shared drives"/*; do
    [ -d "$r" ] && printf '%s\n' "$r"
  done
}

if [ "$USE_GDRIVE" -eq 1 ]; then
  _first=$(gdrive_roots | head -1 || true)
  if [ -n "$_first" ]; then
    DATA="$_first/$FOLDER_NAME"
    echo "  using Google Drive: $DATA"
  else
    echo "  ! Google Drive for Desktop not found — falling back to $DATA"
    echo "    (install Drive, sign in, then re-run with --gdrive)"
  fi
elif [ "$DATA_EXPLICIT" -eq 0 ] && interactive; then
  # Interactive install with no location given: offer what actually exists.
  _opts=(); _labels=()
  _opts+=("$HOME/$FOLDER_NAME");  _labels+=("Home folder — simple, stays on this Mac")
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    _opts+=("$r/$FOLDER_NAME")
    case "$r" in
      *"Shared drives"*) _labels+=("Google Drive (shared drive: $(basename "$r")) — the team can see it") ;;
      *) _labels+=("Google Drive ($(basename "$(dirname "$r")" | sed 's/^GoogleDrive-//')) — reachable from their phone") ;;
    esac
  done < <(gdrive_roots)

  echo ""
  echo "  Where should the working folder live?"
  for i in "${!_opts[@]}"; do printf '    %d) %s\n      %s\n' "$((i+1))" "${_opts[$i]}" "${_labels[$i]}"; done
  printf '    %d) somewhere else (type a path)\n' "$(( ${#_opts[@]} + 1 ))"
  echo ""
  ask "  Choose [1]: " _pick
  _pick="${_pick:-1}"
  if [ "$_pick" = "$(( ${#_opts[@]} + 1 ))" ]; then
    ask "  Full path to the folder: " _custom
    [ -n "$_custom" ] && DATA="${_custom/#\~/$HOME}"
  elif [ "$_pick" -ge 1 ] 2>/dev/null && [ "$_pick" -le "${#_opts[@]}" ]; then
    DATA="${_opts[$((_pick-1))]}"
  fi
  echo "  → $DATA"
fi

case "$DATA" in
  *"Mobile Documents"*|*"/iCloud"*)
    echo "  ! that folder is in iCloud, which can lock files mid-session — Google Drive or the home folder is safer" >&2 ;;
esac

# ─── Engine (control plane) ─────────────────────────────────────────
mkdir -p "$ENGINE/policy" "$ENGINE/prompts" "$ENGINE/bin" "$ENGINE/logs"
# Policy files are left read-only (below) so a stray edit is obvious; make them
# writable again first, or re-running the installer dies on the copy and leaves
# a half-updated engine (found by running init twice).
chmod u+w "$ENGINE/policy/"*.json "$ENGINE/policy/sandbox.sb" 2>/dev/null || true
mkdir -p "$ENGINE/hooks"
cp "$SRC/template/hooks/"*.sh "$ENGINE/hooks/" && chmod +x "$ENGINE/hooks/"*.sh
# Keep the templates with the engine so the folder can be moved later on a
# machine that has no copy of the repo (see bin/nondev-folder).
mkdir -p "$ENGINE/templates/policy"
cp "$SRC/template/sandbox.sb.template"          "$ENGINE/templates/"
cp "$SRC/template/policy/settings.json.template" "$ENGINE/templates/policy/"
cp "$SRC/template/policy/mcp.json"      "$ENGINE/policy/mcp.json"
cp "$SRC/template/CLAUDE-nondev.md"     "$ENGINE/prompts/CLAUDE-nondev.md"
cp "$SRC/bin/megavibe-nondev"           "$ENGINE/bin/megavibe-nondev"
cp "$SRC/bin/nondev-doctor"             "$ENGINE/bin/nondev-doctor"
cp "$SRC/bin/nondev-mode"               "$ENGINE/bin/nondev-mode"
cp "$SRC/bin/nondev-folder"             "$ENGINE/bin/nondev-folder"
cp "$SRC/bin/nondev-connect"            "$ENGINE/bin/nondev-connect"
chmod +x "$ENGINE/bin/megavibe-nondev" "$ENGINE/bin/nondev-doctor" "$ENGINE/bin/nondev-mode" "$ENGINE/bin/nondev-folder" "$ENGINE/bin/nondev-connect"
mkdir -p "$DATA"
DATA_REAL=$(cd "$DATA" && pwd -P)
printf '%s\n' "$DATA_REAL" > "$ENGINE/data-dir"

# Render the seatbelt profile with resolved absolute paths. Seatbelt matches on
# REAL paths, so a symlinked location (e.g. /tmp -> /private/tmp) must be
# resolved or the rules silently fail to match.
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

Want it somewhere else — a Google Drive folder, say? Open the app and just ask,
or run: nondev-folder --list
TXT
ok "folder ready at $DATA"

# Claude Code asks whether you trust the files in a new directory. For someone
# non-technical, being asked to vouch for their own documents folder is both
# confusing and meaningless — the admin already decided this by installing. Mark
# it accepted up front so the first launch is just the assistant saying hello.
if command -v python3 &>/dev/null; then
  python3 - "$DATA_REAL" <<'TRUST' 2>/dev/null || true
import json, os, sys
path = os.path.expanduser("~/.claude.json")
try:
    cfg = json.load(open(path)) if os.path.exists(path) else {}
except Exception:
    sys.exit(0)                      # never damage an unreadable config
cfg.setdefault("projects", {}).setdefault(sys.argv[1], {})["hasTrustDialogAccepted"] = True
tmp = path + ".nondev-tmp"
with open(tmp, "w") as fh:
    json.dump(cfg, fh, indent=2)
os.replace(tmp, path)
TRUST
  ok "folder pre-approved (no trust question on first launch)"
fi

# ─── CLI shortcut ───────────────────────────────────────────────────
mkdir -p "$HOME/.local/bin"
ln -sf "$ENGINE/bin/megavibe-nondev" "$HOME/.local/bin/megavibe-nondev"
ln -sf "$ENGINE/bin/nondev-doctor"  "$HOME/.local/bin/nondev-doctor"
ln -sf "$ENGINE/bin/nondev-mode"    "$HOME/.local/bin/nondev-mode"
ln -sf "$ENGINE/bin/nondev-folder"  "$HOME/.local/bin/nondev-folder"
ln -sf "$ENGINE/bin/nondev-connect" "$HOME/.local/bin/nondev-connect"
# ~/.local/bin is NOT on a stock macOS PATH, so "just run megavibe-nondev"
# would be a lie on a clean machine. Persist it, idempotently.
if ! command -v megavibe-nondev &>/dev/null; then
  for _rc in "$HOME/.zprofile" "$HOME/.zshrc"; do
    if [ -f "$_rc" ] || [ "$_rc" = "$HOME/.zprofile" ]; then
      grep -q 'megavibe-nondev PATH' "$_rc" 2>/dev/null || \
        printf '\n# megavibe-nondev PATH\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$_rc"
      break
    fi
  done
  export PATH="$HOME/.local/bin:$PATH"
fi
ok "commands installed: megavibe-nondev, nondev-doctor, nondev-mode, nondev-folder, nondev-connect"

# One machine, one protocol. A nondev session is not --restricted, so a
# user-level classic megavibe protocol would otherwise leak developer rules
# (.agent writes, git discipline, spinouts) into the plain-language assistant.
if [ -f "$HOME/.claude/CLAUDE.md" ]; then
  echo ""
  echo "  You already have the developer version of megavibe on this Mac."
  echo "  Both can live here — the simple assistant is told to ignore the"
  echo "  developer rules, and it does. If you never use the developer version,"
  echo "  setting it aside makes the assistant a shade cleaner."
  echo "  (Nothing is deleted either way; 'nondev-mode off' puts it back.)"
  if interactive; then
    ask "  Keep the developer version fully working? [Y/n] " _pk
    case "${_pk:-y}" in
      [nN]*) bash "$ENGINE/bin/nondev-mode" on ;;
      *)     echo "  ✓ keeping both — nothing changed" ;;
    esac
  else
    echo "  → keeping both (run 'nondev-mode on' later if you prefer)"
  fi
fi

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
    set w to do script "clear; '$ENGINE/bin/megavibe-nondev'"
    try
        set custom title of w to "$APPNAME"
    end try
end tell
APPLESCRIPT
    # Stage first, swap only on success — otherwise a failed re-run leaves the
    # colleague with a dead Dock icon and no launcher.
    # The staged path MUST end in .app: osacompile picks its output format from
    # the extension, and without it you get a plain compiled script, not a bundle.
    STAGE_DIR=$(mktemp -d); STAGE="$STAGE_DIR/${APPNAME}.app"
    if osacompile -o "$STAGE" "$TMP_SCPT" 2>/dev/null && rm -rf "$APP" && mv "$STAGE" "$APP"; then
      # Branding comes from a private overlay, never from this repo: megavibe is
      # public and MIT, so company logos and named pilots do not belong in it.
      # Point MEGAVIBE_NONDEV_OVERLAY at your own dir, or use the default below.
      OVERLAY="${MEGAVIBE_NONDEV_OVERLAY:-$HOME/.megavibe/personal/nondev}"
      if [ -f "$OVERLAY/icon.icns" ]; then
        # osacompile no longer ships a default applet.icns, so create the
        # Resources dir and register the icon rather than copying into thin air.
        mkdir -p "$APP/Contents/Resources"
        if cp "$OVERLAY/icon.icns" "$APP/Contents/Resources/applet.icns" 2>/dev/null; then
          /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string applet" \
            "$APP/Contents/Info.plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile applet" \
               "$APP/Contents/Info.plist" 2>/dev/null || true
          touch "$APP"
          # The Dock caches icons per bundle path; without a nudge it keeps
          # showing the generic applet icon even though the icns is in place.
          killall Dock 2>/dev/null || true
          ok "icon applied"
        else
          echo "  ! could not apply the icon (harmless)"
        fi
      fi
      ok "launcher created: $APP  (drag it to the Dock)"
    else
      echo "  ! could not create the launcher app (existing app left untouched)"
      echo "    it can still be started by running: $ENGINE/bin/megavibe-nondev"
    fi
    rm -rf "$STAGE_DIR"; rm -f "$TMP_SCPT" "${TMP_SCPT%.applescript}"
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
  if interactive && command -v gcloud &>/dev/null; then
    ask "  Mint a free one from this Mac's Google login now? [y/N] " _ans
    case "${_ans:-n}" in
      [yY]*) bash "$SRC/../scripts/mint-gemini-key.sh" --write-rc \
               || echo "  ! minting failed — Claude-only for now (that is fine)" ;;
      *) echo "  skipped — Claude-only for now (that is fine)" ;;
    esac
  else
    echo "  skipped — Claude works on its own; add one later with scripts/mint-gemini-key.sh"
  fi
fi

if [ -z "${MEGAVIBE_NONDEV_WRAPPED:-}" ]; then
  echo ""
  echo "Done. Next:"
  echo "  1. run 'claude' once and sign in"
  echo "  2. drag ${APPNAME} from /Applications to the Dock"
  echo "  3. open it and try: \"what can you help me with?\""
fi
