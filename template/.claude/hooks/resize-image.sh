#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
set -uo pipefail

# Megavibe — auto-resize oversized images before Claude reads them
# Triggered by: PreToolUse (Read)
#
# Claude's API has a 2000px dimension limit when multiple images are in
# conversation. This hook catches oversized images on Read and resizes
# them in-place (via macOS sips) before they enter the conversation.
# Once an oversized image is in context, there's no way to fix it.

# Only macOS (sips is built-in)
command -v sips &>/dev/null || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

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

# Get dimensions
WIDTH=$(sips -g pixelWidth "$FILE_PATH" 2>/dev/null | awk '/pixelWidth/{print $2}')
HEIGHT=$(sips -g pixelHeight "$FILE_PATH" 2>/dev/null | awk '/pixelHeight/{print $2}')

[ -n "$WIDTH" ] && [ -n "$HEIGHT" ] || exit 0

if [ "$WIDTH" -gt "$MAX_DIM" ] || [ "$HEIGHT" -gt "$MAX_DIM" ]; then
  sips --resampleHeightWidthMax "$MAX_DIM" "$FILE_PATH" &>/dev/null || exit 0
fi
