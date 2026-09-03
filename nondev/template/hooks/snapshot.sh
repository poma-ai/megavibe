#!/usr/bin/env bash
# PreToolUse(Write|Edit) — keep a copy of every file before it is changed, so
# "undo the last change" always works for someone who has never heard of git.
# Snapshots live inside the data folder (.snapshots) because that is the only
# place the sandbox permits writes.
set -uo pipefail
command -v jq &>/dev/null || exit 0
IN=$(cat); F=$(printf '%s' "$IN" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$F" ] && [ -f "$F" ] || exit 0
DATA="${MEGAVIBE_NONDEV_DATA:-$PWD}"
# Snapshots live in the ENGINE, not the data folder: when the folder is a
# Google Drive / iCloud location, writing dozens of copies into it would sync
# them to the cloud and clutter what the colleague sees.
SNAPDIR="${MEGAVIBE_NONDEV_ENGINE:-$HOME/.megavibe-nondev}/snapshots"
case "$F" in "$DATA"/*) ;; *) exit 0 ;; esac          # only our own folder
case "$F" in *"/snapshots/"*) exit 0 ;; esac            # never snapshot snapshots
STAMP=$(date +%Y%m%d-%H%M%S)
REL="${F#$DATA/}"
DEST="$SNAPDIR/$STAMP/$REL"
mkdir -p "$(dirname "$DEST")" 2>/dev/null && cp -p "$F" "$DEST" 2>/dev/null
# Keep the last 40 snapshot batches; this runs on every write, so stay cheap.
ls -1d "$SNAPDIR/"*/ 2>/dev/null | head -n -40 | while read -r d; do rm -rf "$d"; done
exit 0
