#!/usr/bin/env bash
# Provision megawork. Normally reached via the self-serve one-liner
# (megawork/install.sh), which downloads this and hands off to it.
#
# Creates:
#   ~/.megawork/      engine: policy, protocol, launcher   (control plane)
#   ~/megawork/       the colleague's four folders          (data plane)
#   /Applications/…app       Dock-able launcher                    (optional)
#
# The two planes are separate on purpose: the session can write the data folder
# but must never be able to rewrite its own guardrails. Kept out of
# ~/Desktop and ~/Documents so iCloud sync cannot lock the folders mid-session.
#
# Usage: bash megawork/init.sh [--data DIR] [--gdrive [FolderName]]
#                                   [--folder-name NAME] [--name "App Name"] [--no-app]
#
# With no --data and a terminal, it asks where the folder should live and lists
# the Google Drive locations (including shared drives) it finds on this Mac.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ENGINE="${MEGAWORK_HOME:-$HOME/.megawork}"
DATA="$HOME/megawork"
APPNAME="Megawork"
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

# This profile used to be called megavibe-nondev. Move an existing install
# across rather than leaving someone with two half-configured copies.
OLD_ENGINE="$HOME/.megavibe-nondev"
if [ -d "$OLD_ENGINE" ] && [ ! -d "${MEGAWORK_HOME:-$HOME/.megawork}" ]; then
  mv "$OLD_ENGINE" "${MEGAWORK_HOME:-$HOME/.megawork}" 2>/dev/null \
    && echo "  ✓ moved your existing setup over from the old name"
  rm -f "$HOME/.local/bin/megavibe-nondev" "$HOME/.local/bin/nondev-"* 2>/dev/null
  rm -rf "/Applications/Megavibe Nondev.app" "/Applications/Megavibe.app" 2>/dev/null
  # Bring their actual work across too — an engine without the folder it points
  # at would leave someone staring at an empty assistant.
  OLD_DATA=$(cat "${MEGAWORK_HOME:-$HOME/.megawork}/data-dir" 2>/dev/null || echo "")
  if [ -n "$OLD_DATA" ] && [ -d "$OLD_DATA" ] && [ "$OLD_DATA" != "$DATA" ]; then
    mkdir -p "$DATA"
    if command -v rsync &>/dev/null; then rsync -a "$OLD_DATA"/ "$DATA"/ 2>/dev/null
    else cp -R "$OLD_DATA"/. "$DATA"/ 2>/dev/null; fi
    echo "  ✓ brought your files across (the old folder is left in place)"
  fi
fi

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
mkdir -p "$ENGINE/policy" "$ENGINE/prompts" "$ENGINE/bin" "$ENGINE/logs" "$ENGINE/agent" "$ENGINE/snapshots"
# Policy files are left read-only (below) so a stray edit is obvious; make them
# writable again first, or re-running the installer dies on the copy and leaves
# a half-updated engine (found by running init twice).
chmod u+w "$ENGINE/policy/"*.json "$ENGINE/policy/sandbox.sb" 2>/dev/null || true
mkdir -p "$ENGINE/hooks"
cp "$SRC/template/hooks/"*.sh "$ENGINE/hooks/" && chmod +x "$ENGINE/hooks/"*.sh
# Keep the templates with the engine so the folder can be moved later on a
# machine that has no copy of the repo (see bin/megawork-folder).
mkdir -p "$ENGINE/templates/policy"
cp "$SRC/template/sandbox.sb.template"          "$ENGINE/templates/"
cp "$SRC/template/policy/settings.json.template" "$ENGINE/templates/policy/"
cp "$SRC/template/policy/mcp.json"      "$ENGINE/policy/mcp.json"
cp "$SRC/template/CLAUDE-megawork.md"     "$ENGINE/prompts/CLAUDE-megawork.md"
cp "$SRC/bin/megawork"           "$ENGINE/bin/megawork"
cp "$SRC/bin/megawork-doctor"             "$ENGINE/bin/megawork-doctor"
cp "$SRC/bin/megawork-mode"               "$ENGINE/bin/megawork-mode"
cp "$SRC/bin/megawork-folder"             "$ENGINE/bin/megawork-folder"
cp "$SRC/bin/megawork-connect"            "$ENGINE/bin/megawork-connect"
cp "$SRC/bin/megawork-update"             "$ENGINE/bin/megawork-update"
chmod +x "$ENGINE/bin/megawork" "$ENGINE/bin/megawork-doctor" "$ENGINE/bin/megawork-mode" "$ENGINE/bin/megawork-folder" "$ENGINE/bin/megawork-connect" "$ENGINE/bin/megawork-update"
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
or run: megawork-folder --list
TXT
ok "folder ready at $DATA"

# POMA's own chunker indexes what they put in the folder, so the assistant can
# find things by meaning rather than filename. Local, no cloud round-trip.
if command -v poma-memory &>/dev/null; then
  ( poma-memory index "$DATA" >/dev/null 2>&1 && \
    ok "documents indexed for search (POMA semantic memory)" ) || true
fi

# Claude Code asks whether you trust the files in a new directory. For someone
# non-technical, being asked to vouch for their own documents folder is both
# confusing and meaningless — the admin already decided this by installing. Mark
# it accepted up front so the first launch is just the assistant saying hello.
# jq, not python3: /usr/bin/python3 on a Mac without Xcode command line tools
# is a stub that pops an "install developer tools?" dialog and fails. jq ships
# with macOS 15 and later, which this profile requires anyway.
if command -v jq &>/dev/null; then
  CLAUDE_JSON="$HOME/.claude.json"
  [ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
  if jq -e . "$CLAUDE_JSON" >/dev/null 2>&1; then
    jq --arg d "$DATA_REAL" '.projects[$d].hasTrustDialogAccepted = true' "$CLAUDE_JSON" \
      > "$CLAUDE_JSON.megawork-tmp" 2>/dev/null \
      && mv "$CLAUDE_JSON.megawork-tmp" "$CLAUDE_JSON"
  fi
  ok "folder pre-approved (no trust question on first launch)"
fi

# ─── CLI shortcut ───────────────────────────────────────────────────
mkdir -p "$HOME/.local/bin"
ln -sf "$ENGINE/bin/megawork" "$HOME/.local/bin/megawork"
ln -sf "$ENGINE/bin/megawork-doctor"  "$HOME/.local/bin/megawork-doctor"
ln -sf "$ENGINE/bin/megawork-mode"    "$HOME/.local/bin/megawork-mode"
ln -sf "$ENGINE/bin/megawork-folder"  "$HOME/.local/bin/megawork-folder"
ln -sf "$ENGINE/bin/megawork-connect" "$HOME/.local/bin/megawork-connect"
ln -sf "$ENGINE/bin/megawork-update"  "$HOME/.local/bin/megawork-update"
# ~/.local/bin is NOT on a stock macOS PATH, so "just run megawork"
# would be a lie on a clean machine. Persist it, idempotently.
if ! command -v megawork &>/dev/null; then
  for _rc in "$HOME/.zprofile" "$HOME/.zshrc"; do
    if [ -f "$_rc" ] || [ "$_rc" = "$HOME/.zprofile" ]; then
      grep -q 'megawork PATH' "$_rc" 2>/dev/null || \
        printf '\n# megawork PATH\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$_rc"
      break
    fi
  done
  export PATH="$HOME/.local/bin:$PATH"
fi
ok "commands installed: megawork, megawork-doctor, megawork-mode, megawork-folder, megawork-connect, megawork-update"

# One machine, one protocol. A Megawork session is not --restricted, so a
# user-level classic megavibe protocol would otherwise leak developer rules
# (.agent writes, git discipline, spinouts) into the plain-language assistant.
if [ -f "$HOME/.claude/CLAUDE.md" ]; then
  echo ""
  echo "  You already have the developer version of megavibe on this Mac."
  echo "  Both can live here — the simple assistant is told to ignore the"
  echo "  developer rules, and it does. If you never use the developer version,"
  echo "  setting it aside makes the assistant a shade cleaner."
  echo "  (Nothing is deleted either way; 'megawork-mode off' puts it back.)"
  if interactive; then
    ask "  Keep the developer version fully working? [Y/n] " _pk
    case "${_pk:-y}" in
      [nN]*) bash "$ENGINE/bin/megawork-mode" on ;;
      *)     echo "  ✓ keeping both — nothing changed" ;;
    esac
  else
    echo "  → keeping both (run 'megawork-mode on' later if you prefer)"
  fi
fi

# ─── Dock-able launcher app ─────────────────────────────────────────
if [ "$MAKE_APP" -eq 1 ] && [ "$(uname -s)" = "Darwin" ]; then
  APP="/Applications/${APPNAME}.app"
  # Build the bundle by hand instead of using osacompile. An .app is just a
  # directory, and osacompile ad-hoc signs it — so writing our icon into
  # Contents/Resources broke the seal and macOS then ignored the icon entirely.
  # Owning the bundle means the icon is simply part of it from the start.
  OVERLAY="${MEGAWORK_OVERLAY:-$HOME/.megavibe/personal/megawork}"
  STAGE_DIR=$(mktemp -d); STAGE="$STAGE_DIR/${APPNAME}.app"
  mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

  cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>${APPNAME}</string>
  <key>CFBundleDisplayName</key><string>${APPNAME}</string>
  <key>CFBundleIdentifier</key><string>com.poma-ai.megawork</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundleIconFile</key><string>appicon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

  cat > "$STAGE/Contents/MacOS/launch" <<LAUNCH
#!/bin/bash
# Open a Terminal window on the assistant. Terminal, not the Claude desktop
# app: the desktop app would not apply the sandbox or the policy.
osascript -e 'tell application "Terminal"
    activate
    set w to do script "clear; \"$ENGINE/bin/megawork\""
    try
        set custom title of w to "${APPNAME}"
    end try
end tell'
LAUNCH
  chmod +x "$STAGE/Contents/MacOS/launch"

  if [ -f "$OVERLAY/icon.icns" ]; then
    cp "$OVERLAY/icon.icns" "$STAGE/Contents/Resources/appicon.icns"
  fi

  if rm -rf "$APP" && mv "$STAGE" "$APP"; then
    # Ad-hoc sign the finished bundle, so the seal matches what is inside it.
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    touch "$APP"; killall Dock 2>/dev/null || true
    [ -f "$APP/Contents/Resources/appicon.icns" ] && ok "launcher created with its icon: $APP" \
      || ok "launcher created: $APP (no icon in the overlay)"
    echo "    drag it to the Dock"
  else
    echo "  ! could not create the launcher app (existing app left untouched)"
    echo "    it can still be started by running: $ENGINE/bin/megawork"
  fi
  rm -rf "$STAGE_DIR"
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
    echo "  skipped — Claude works on its own, so this is optional"
  fi
fi

if [ -z "${MEGAWORK_WRAPPED:-}" ]; then
  echo ""
  echo "Done. Next:"
  echo "  1. run 'claude' once and sign in"
  echo "  2. drag ${APPNAME} from /Applications to the Dock"
  echo "  3. open it and try: \"what can you help me with?\""
fi
