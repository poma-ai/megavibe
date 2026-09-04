#!/usr/bin/env bash
# PreToolUse(Write|Edit) — keep a copy of every file before it is changed, so
# "undo the last change" always works for someone who has never heard of git.
set -uo pipefail
command -v jq &>/dev/null || exit 0
IN=$(cat); F=$(printf '%s' "$IN" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$F" ] && [ -f "$F" ] || exit 0
DATA="${MEGAWORK_DATA:-$PWD}"
# Snapshots live in the ENGINE, not the data folder: when the folder is a
# Google Drive / iCloud location, writing dozens of copies into it would sync
# them to the cloud and clutter what the colleague sees.
SNAPDIR="${MEGAWORK_ENGINE:-$HOME/.megawork}/snapshots"
case "$F" in "$DATA"/*) ;; *) exit 0 ;; esac          # only our own folder
case "$F" in *"/snapshots/"*) exit 0 ;; esac            # never snapshot snapshots
STAMP=$(date +%Y%m%d-%H%M%S)
REL="${F#$DATA/}"
DEST="$SNAPDIR/$STAMP/$REL"
# First copy in a batch WINS: Claude often fires several Edits on one file
# within the same second, and overwriting would leave "undo" restoring a
# half-changed version instead of the original.
mkdir -p "$(dirname "$DEST")" 2>/dev/null
[ -e "$DEST" ] || cp -p "$F" "$DEST" 2>/dev/null
# Keep the last 40 snapshot batches; this runs on every write, so stay cheap.
# BSD head rejects negative counts, so pruning never ran and snapshots grew
# without bound. Reverse-sort by name (timestamps sort lexically) and drop all
# but the newest 40.
ls -1d "$SNAPDIR/"*/ 2>/dev/null | sort -r | tail -n +41 | while IFS= read -r d; do rm -rf "$d"; done
exit 0
