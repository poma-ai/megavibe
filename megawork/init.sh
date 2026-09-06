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
D=$'\033[2m'; R=$'\033[0m'

# This profile used to be called megavibe-nondev. Move an existing install
# across rather than leaving someone with two half-configured copies.
OLD_ENGINE="$HOME/.megavibe-nondev"
if [ -d "$OLD_ENGINE" ] && [ ! -d "${MEGAWORK_HOME:-$HOME/.megawork}" ]; then
  mv "$OLD_ENGINE" "${MEGAWORK_HOME:-$HOME/.megawork}" 2>/dev/null \
    && echo "  ✓ moved your existing setup over from the old name"
  rm -f "$HOME/.local/bin/megavibe-nondev" "$HOME/.local/bin/nondev-"* 2>/dev/null
  rm -rf "/Applications/Megavibe Nondev.app" "/Applications/Megavibe.app" 2>/dev/null
  # Their folder comes along untouched: the moved engine still carries data-dir,
  # and the "keeping your existing folder" step below points at it.
fi

# Ask the human, not stdin: piped installs (curl | bash) hand us the script on
# stdin, so prompts must go to the controlling terminal.
# MEGAWORK_NONINTERACTIVE is the only reliable way for a caller to say "ask
# nobody anything". Redirecting stdin from /dev/null is NOT enough: the
# /dev/tty fallback below re-opens the terminal, so an unattended re-run (e.g.
# megawork-update) would still stop on a prompt — with its own stdout pointed
# at /dev/null, leaving a person staring at a browser and a silent terminal.
TTY_IN=""
NONINTERACTIVE=0
case "${MEGAWORK_NONINTERACTIVE:-}" in 1|true|yes) NONINTERACTIVE=1 ;; esac
if [ "$NONINTERACTIVE" -eq 0 ]; then
  [ -t 0 ] && TTY_IN="/dev/stdin"
  if [ -z "$TTY_IN" ] && ( : < /dev/tty ) 2>/dev/null; then TTY_IN="/dev/tty"; fi
fi
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

# An install that already exists keeps the folder it already has. Re-running the
# installer is how a colleague picks up a fix (their megawork-update may itself
# be the broken thing), and asking "where should the folder live?" a second time
# invites a different answer — which would repoint the engine at a new empty
# folder and leave every document they have behind at the old path. Only an
# explicit --data or --gdrive may move it.
if [ "$DATA_EXPLICIT" -eq 0 ] && [ "$USE_GDRIVE" -eq 0 ]; then
  EXISTING_DATA=$(cat "$ENGINE/data-dir" 2>/dev/null || echo "")
  if [ -n "$EXISTING_DATA" ] && [ -d "$EXISTING_DATA" ]; then
    DATA="$EXISTING_DATA"; DATA_EXPLICIT=1
    ok "keeping your existing folder ($DATA)"
  fi
fi

# ─── Where should the folder live? ──────────────────────────────────
# Non-technical people mostly live in Google Drive, and "which Drive folder"
# is the one setup question they have a real opinion about. Detect the actual
# options on this Mac and let them point at one, rather than guessing.
FOLDER_NAME="${FOLDER_NAME:-$APPNAME}"   # renamed: the folder follows the app

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
rm -f "$ENGINE/bin/mint-gemini-key.sh" 2>/dev/null || true   # shipped briefly in 9b587f2; minting is an admin task now
chmod +x "$ENGINE/bin/megawork" "$ENGINE/bin/megawork-doctor" "$ENGINE/bin/megawork-mode" "$ENGINE/bin/megawork-folder" "$ENGINE/bin/megawork-connect" "$ENGINE/bin/megawork-update"
mkdir -p "$DATA"
DATA_REAL=$(cd "$DATA" && pwd -P)
printf '%s\n' "$DATA_REAL" > "$ENGINE/data-dir"

# Stamp the installed version, or every fresh install is told within a week
# that "a newer version is available" and sent to megawork-update for nothing.
# A checkout knows its own commit; a tarball has to ask GitHub (20s cap), and if
# that fails the launcher treats "unknown" as "do not nag".
# Only trust git when the checkout IS this repo — a tarball extracted under
# someone's unrelated repo would otherwise inherit that repo's HEAD.
_ver=""
if [ "$(git -C "$SRC" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$SRC/.." && pwd -P)" ]; then
  _ver=$(git -C "$SRC" rev-parse --short=7 HEAD 2>/dev/null || true)
fi
[ -n "$_ver" ] || _ver=$(curl -fsSL --max-time 20 \
  "https://api.github.com/repos/poma-ai/megavibe/commits?path=megawork&per_page=1" 2>/dev/null \
  | sed -n 's/.*"sha": *"\([0-9a-f]\{7\}\).*/\1/p' | head -1)
[ -n "$_ver" ] && printf '%s\n' "$_ver" > "$ENGINE/version"

# Render the seatbelt profile with resolved absolute paths. Seatbelt matches on
# REAL paths, so a symlinked location (e.g. /tmp -> /private/tmp) must be
# resolved or the rules silently fail to match.
ENGINE_REAL=$(cd "$ENGINE" && pwd -P)
HOME_REAL=$(cd "$HOME" && pwd -P)
# Not sed: `&` in a replacement means "the whole match", so a shared drive
# called "Kunden & Projekte" rendered a sandbox rule pointing at
# "Kunden @DATA@ Projekte" — the assistant then could not write to its own
# folder. `|` in a path would break the delimiter too. Bash substitution is
# literal on both counts.
render(){
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//@DATA@/$DATA_REAL}
    line=${line//@ENGINE@/$ENGINE_REAL}
    line=${line//@HOME@/$HOME_REAL}
    printf '%s\n' "$line"
  done < "$1" > "$2"
}
# Connections the person switched on live in these rendered files, so carry
# them across the re-render: Apple Mail is "the Mail deny line is absent".
MAIL_WAS_ON=0
if [ -f "$ENGINE/policy/sandbox.sb" ] && ! grep -q "(subpath \"$HOME_REAL/Library/Mail\")" "$ENGINE/policy/sandbox.sb"; then MAIL_WAS_ON=1; fi
# ...and the tool pre-approvals megawork-connect added for services it connected.
EXTRA_ALLOW="[]"
if [ -f "$ENGINE/policy/settings.json" ] && command -v jq &>/dev/null; then
  EXTRA_ALLOW=$(jq -c '.permissions.allow // []' "$ENGINE/policy/settings.json" 2>/dev/null || echo "[]")
fi
render "$SRC/template/sandbox.sb.template"         "$ENGINE/policy/sandbox.sb"
render "$SRC/template/policy/settings.json.template" "$ENGINE/policy/settings.json"
if [ "$MAIL_WAS_ON" -eq 1 ]; then
  grep -v "(subpath \"$HOME_REAL/Library/Mail\")" "$ENGINE/policy/sandbox.sb" > "$ENGINE/policy/sandbox.sb.tmp" \
    && mv "$ENGINE/policy/sandbox.sb.tmp" "$ENGINE/policy/sandbox.sb"
fi
if [ "$EXTRA_ALLOW" != "[]" ] && command -v jq &>/dev/null; then
  # Only rewrite when something is actually missing: jq re-serialises the whole
  # file, so an unconditional pass makes run 2 differ from run 1 in whitespace.
  MISSING=$(jq -c --argjson extra "$EXTRA_ALLOW" '.permissions.allow as $a | $extra | map(select(startswith("mcp__") and (. as $x | $a | index($x) | not)))' "$ENGINE/policy/settings.json" 2>/dev/null || echo "[]")
  if [ "$MISSING" != "[]" ] && [ -n "$MISSING" ]; then
    jq --argjson m "$MISSING" '.permissions.allow += $m' "$ENGINE/policy/settings.json" > "$ENGINE/policy/settings.json.tmp" 2>/dev/null \
      && mv "$ENGINE/policy/settings.json.tmp" "$ENGINE/policy/settings.json"
  fi
fi
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

  # Move the old app aside first, not away: if the new one cannot land, put it back.
  OLD_APP=""; [ -e "$APP" ] && { OLD_APP="$STAGE_DIR/previous.app"; mv "$APP" "$OLD_APP" 2>/dev/null || OLD_APP=""; }
  if mv "$STAGE" "$APP" 2>/dev/null || { [ -n "$OLD_APP" ] && mv "$OLD_APP" "$APP" 2>/dev/null; false; }; then
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

# ─── Gemini key, if an admin left one ───────────────────────────────
# Three places, in order: the environment the admin installed with, the private
# overlay, or an existing engine key. Never a prompt — see setup.sh --harness-only.
if [ -z "${GEMINI_API_KEY:-}" ]; then
  for _src in "${MEGAWORK_OVERLAY:-$HOME/.megavibe/personal/megawork}/gemini-key" "$ENGINE/policy/gemini-key"; do
    [ -s "$_src" ] && { GEMINI_API_KEY=$(tr -d '[:space:]' < "$_src"); break; }
  done
fi
if [ -n "${GEMINI_API_KEY:-}" ]; then
  printf '%s\n' "$GEMINI_API_KEY" > "$ENGINE/policy/gemini-key"
  chmod 600 "$ENGINE/policy/gemini-key"
  ok "Gemini backend configured (second opinions on long documents)"
fi

# ─── Backends ───────────────────────────────────────────────────────
# Gemini is part of the profile (README.md "Backends"): the assistant leans on
# it for long documents. The key is POMA's — issued by an admin from a BILLED
# project, because that is the only way prompts stay out of Google's training
# data (a Workspace login does not do it for the API), and because the free
# tier is 20 requests a day. Nothing is minted here and no browser opens: the
# key is taken from the overlay or the environment above, or pasted once.
#
# UPDATES ARE NOT INSTALLS. megawork-update re-runs this file with
# MEGAWORK_NONINTERACTIVE, so an update that finds no key leaves it alone;
# `megawork-connect gemini` is the repair path and runs this same code.
GEMINI_STATE="ok"
if [ -z "${GEMINI_API_KEY:-}" ]; then
  GEMINI_STATE="missing"
  if interactive && [ -x "$ENGINE/bin/megawork-connect" ]; then
    echo ""
    echo "  Second opinions (one key to paste — ${MEGAWORK_ADMIN_NAME:-your admin} has it)"
    # Ctrl-C here must not take the whole install down with it: without the
    # trap, SIGINT reaches this script and install.sh too, and the person never
    # sees the closing instructions for the parts that DID get set up.
    trap 'echo' INT
    MEGAWORK_HOME="$ENGINE" "$ENGINE/bin/megawork-connect" gemini < "$TTY_IN" && GEMINI_STATE="ok" || GEMINI_STATE="missing"
    trap - INT
  fi
fi
[ "$GEMINI_STATE" = "ok" ] || echo "  ${D:-}(second opinions not set up — the rest works; add later with: megawork-connect gemini)${R:-}"

if [ -z "${MEGAWORK_WRAPPED:-}" ]; then
  echo ""
  echo "Done. Next:"
  echo "  1. run 'claude' once and sign in"
  if [ -d "/Applications/${APPNAME}.app" ]; then
    echo "  2. drag ${APPNAME} from /Applications to the Dock"
  else
    echo "  2. start it with: $ENGINE/bin/megawork"
  fi
  echo "  3. open it and try: \"what can you help me with?\""
fi
