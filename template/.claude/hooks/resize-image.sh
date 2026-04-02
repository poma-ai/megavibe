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
# conversation. This hook catches oversized images on Read and resizes
# them in-place before they enter the conversation.
# Once an oversized image is in context, there's no way to fix it.
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
[ -f "$FILE_PATH" ] || exit 0

# Only image files (case-insensitive via tr)
EXT=$(echo "$FILE_PATH" | tr '[:upper:]' '[:lower:]')
case "$EXT" in
  *.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp|*.tiff|*.tif) ;;
  *) exit 0 ;;
esac

MAX_DIM=1800

case "$RESIZE_TOOL" in
  sips)
    WIDTH=$(sips -g pixelWidth "$FILE_PATH" 2>/dev/null | awk '/pixelWidth/{print $2}')
    HEIGHT=$(sips -g pixelHeight "$FILE_PATH" 2>/dev/null | awk '/pixelHeight/{print $2}')
    [ -n "$WIDTH" ] && [ -n "$HEIGHT" ] || exit 0
    if [ "$WIDTH" -gt "$MAX_DIM" ] || [ "$HEIGHT" -gt "$MAX_DIM" ]; then
      sips --resampleHeightWidthMax "$MAX_DIM" "$FILE_PATH" &>/dev/null || exit 0
    fi
    ;;
  magick)
    # ImageMagick v7
    DIMS=$(magick identify -format "%w %h" "$FILE_PATH" 2>/dev/null || echo "")
    WIDTH=$(echo "$DIMS" | awk '{print $1}')
    HEIGHT=$(echo "$DIMS" | awk '{print $2}')
    [ -n "$WIDTH" ] && [ -n "$HEIGHT" ] || exit 0
    if [ "$WIDTH" -gt "$MAX_DIM" ] || [ "$HEIGHT" -gt "$MAX_DIM" ]; then
      magick "$FILE_PATH" -resize "${MAX_DIM}x${MAX_DIM}>" "$FILE_PATH" &>/dev/null || exit 0
    fi
    ;;
  convert)
    # ImageMagick v6
    DIMS=$(identify -format "%w %h" "$FILE_PATH" 2>/dev/null || echo "")
    WIDTH=$(echo "$DIMS" | awk '{print $1}')
    HEIGHT=$(echo "$DIMS" | awk '{print $2}')
    [ -n "$WIDTH" ] && [ -n "$HEIGHT" ] || exit 0
    if [ "$WIDTH" -gt "$MAX_DIM" ] || [ "$HEIGHT" -gt "$MAX_DIM" ]; then
      convert "$FILE_PATH" -resize "${MAX_DIM}x${MAX_DIM}>" "$FILE_PATH" &>/dev/null || exit 0
    fi
    ;;
esac
