#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="resize-image.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  jq -n --arg msg "$msg" '{systemMessage: $msg}' 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — auto-resize oversized images before Claude reads them
# Triggered by: PreToolUse (Read)
#
# Claude's API has a 2000px dimension limit when multiple images are in
# conversation. This hook catches oversized images on Read, writes a resized
# COPY and points the Read at that copy (PreToolUse updatedInput) before the
# image enters the conversation. Once an oversized image is in context,
# there's no way to fix it.
#
# The ORIGINAL is never modified. Until 2026-10 the resize ran in place, which
# silently shrank 16 golden test crops the moment a reviewer looked at them.
# Copies live in .agent/LOGS/resized/ (local, gitignored, like read-delta's
# stubs) or, without .agent/, in $TMPDIR/megavibe-resized/; one copy per
# (path, mtime, size), reused until the original changes, pruned after a day.
#
# Uses: sips (macOS built-in) or ImageMagick (Linux/Windows)

# Require jq
command -v jq &>/dev/null || exit 0

# Need at least one image tool
RESIZE_TOOL=""
if command -v sips &>/dev/null; then
  RESIZE_TOOL="sips"
elif command -v magick &>/dev/null; then
  RESIZE_TOOL="magick"
elif command -v convert &>/dev/null; then
  # ImageMagick v6 (convert) — verify it's actually ImageMagick, not Windows convert.exe
  if convert --version 2>/dev/null | grep -qi imagemagick; then
    RESIZE_TOOL="convert"
  fi
fi
[ -n "$RESIZE_TOOL" ] || exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")

[ -n "$FILE_PATH" ] || exit 0
# Relative paths are resolved against the project dir, as the Read tool does.
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$FILE_PATH" in /*) ABS="$FILE_PATH" ;; *) ABS="$ROOT/$FILE_PATH" ;; esac
[ -f "$ABS" ] || exit 0

# Only image files (case-insensitive via tr)
EXT=$(echo "$ABS" | tr '[:upper:]' '[:lower:]')
case "$EXT" in
  *.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp|*.tiff|*.tif) ;;
  *) exit 0 ;;
esac

MAX_DIM=1800

# Where the resized copy goes.
if [ -d "$ROOT/.agent/LOGS" ]; then
  OUT_DIR="$ROOT/.agent/LOGS/resized"
else
  OUT_DIR="${TMPDIR:-/tmp}/megavibe-resized"
fi
MTIME=$(stat -f %m "$ABS" 2>/dev/null || stat -c %Y "$ABS" 2>/dev/null || echo 0)
SIZE=$(stat -f %z "$ABS" 2>/dev/null || stat -c %s "$ABS" 2>/dev/null || echo 0)
KEY=$(printf '%s|%s|%s' "$ABS" "$MTIME" "$SIZE" | { shasum 2>/dev/null || sha1sum; } | cut -c1-16)
SUFFIX=$(echo "${ABS##*.}" | tr '[:upper:]' '[:lower:]')
DEST="$OUT_DIR/$(basename "${ABS%.*}").$KEY.$SUFFIX"
mkdir -p "$OUT_DIR" 2>/dev/null || exit 0
find "$OUT_DIR" -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null || true

# Emit the redirect: same tool_input, file_path swapped for the copy.
_redirect() {
  [ -s "$DEST" ] || exit 0
  printf '%s' "$INPUT" | jq -c --arg path "$DEST" --arg orig "$ABS" --arg w "$1" --arg h "$2" '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {file_path: $path}), additionalContext: ("megavibe resize-image: " + $orig + " is " + $w + "x" + $h + " px; this Read shows a copy scaled to fit 1800 px (" + $path + "). The original file is unchanged.")}}' 2>/dev/null
  exit 0
}

case "$RESIZE_TOOL" in
  sips)
    WIDTH=$(sips -g pixelWidth "$ABS" 2>/dev/null | awk '/pixelWidth/{print $2}')
    HEIGHT=$(sips -g pixelHeight "$ABS" 2>/dev/null | awk '/pixelHeight/{print $2}')
    [ -n "$WIDTH" ] && [ -n "$HEIGHT" ] || exit 0
    if [ "$WIDTH" -gt "$MAX_DIM" ] || [ "$HEIGHT" -gt "$MAX_DIM" ]; then
      [ -s "$DEST" ] || sips --resampleHeightWidthMax "$MAX_DIM" "$ABS" --out "$DEST" &>/dev/null || exit 0
      _redirect "$WIDTH" "$HEIGHT"
    fi
    ;;
  magick)
    # ImageMagick v7
    DIMS=$(magick identify -format "%w %h" "$ABS" 2>/dev/null || echo "")
    WIDTH=$(echo "$DIMS" | awk '{print $1}')
    HEIGHT=$(echo "$DIMS" | awk '{print $2}')
    [ -n "$WIDTH" ] && [ -n "$HEIGHT" ] || exit 0
    if [ "$WIDTH" -gt "$MAX_DIM" ] || [ "$HEIGHT" -gt "$MAX_DIM" ]; then
      [ -s "$DEST" ] || magick "$ABS" -resize "${MAX_DIM}x${MAX_DIM}>" "$DEST" &>/dev/null || exit 0
      _redirect "$WIDTH" "$HEIGHT"
    fi
    ;;
  convert)
    # ImageMagick v6
    DIMS=$(identify -format "%w %h" "$ABS" 2>/dev/null || echo "")
    WIDTH=$(echo "$DIMS" | awk '{print $1}')
    HEIGHT=$(echo "$DIMS" | awk '{print $2}')
    [ -n "$WIDTH" ] && [ -n "$HEIGHT" ] || exit 0
    if [ "$WIDTH" -gt "$MAX_DIM" ] || [ "$HEIGHT" -gt "$MAX_DIM" ]; then
      [ -s "$DEST" ] || convert "$ABS" -resize "${MAX_DIM}x${MAX_DIM}>" "$DEST" &>/dev/null || exit 0
      _redirect "$WIDTH" "$HEIGHT"
    fi
    ;;
esac
