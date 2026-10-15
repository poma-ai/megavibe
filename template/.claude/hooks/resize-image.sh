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
# Copies live in a private per-user dir under $TMPDIR (mode 700, owned by the
# user, not a symlink), never inside the project, so nothing a project or a
# clone can write is ever shown as a copy and pruning cannot reach project
# files. (A Read of that path may prompt for permission outside bypass mode,
# and fail under -p or dontAsk; every megavibe launcher runs in bypass mode.)
# A copy is keyed by the original's CONTENT hash, written to a temp file, checked
# (decodes, fits the limit) and only then renamed into place, so a partial or
# foreign file is never shown; copies untouched for about two days are pruned
# (find -mtime +1). JPEG input stays JPEG, everything else becomes PNG (sips cannot write WebP or GIF).
# An image the tool cannot read passes through untouched, as before.
#
# Uses: sips (macOS built-in) or ImageMagick (Linux/Windows)

# Require jq
command -v jq &>/dev/null || exit 0
[ -d ".agent" ] || exit 0

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
  *.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp|*.tiff|*.tif|*.heic|*.heif) ;;
  *) exit 0 ;;
esac

MAX_DIM=1800

# Dimensions "W H" of the FIRST frame (an animated GIF or multi-page TIFF has
# several; only frame 0 is ever shown). Empty when the tool cannot read it.
_dims() {
  case "$RESIZE_TOOL" in
    sips)
      local w h
      w=$(sips -g pixelWidth "$1" 2>/dev/null | awk '$1=="pixelWidth:"{print $2; exit}')
      h=$(sips -g pixelHeight "$1" 2>/dev/null | awk '$1=="pixelHeight:"{print $2; exit}')
      [ -n "$w" ] && [ -n "$h" ] && echo "$w $h"; return 0 ;;
    magick)  magick identify -format "%w %h" "$1[0]" 2>/dev/null || true ;;
    convert) identify -format "%w %h" "$1[0]" 2>/dev/null || true ;;
  esac
}
_is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

DIMS=$(_dims "$ABS")
WIDTH=${DIMS%% *}; HEIGHT=${DIMS##* }
_is_int "$WIDTH" && _is_int "$HEIGHT" || exit 0
[ "$WIDTH" -gt "$MAX_DIM" ] || [ "$HEIGHT" -gt "$MAX_DIM" ] || exit 0

# Where the copy goes: a private per-user dir (mode 700, owned by us, not a
# symlink) under $TMPDIR.
OUT_DIR="${TMPDIR:-/tmp}"
# Never create parent directories: a missing TMPDIR means no cache.
[ -d "$OUT_DIR" ] || exit 0
# A $TMPDIR inside the project would put the mkdir, chmod and prune below within
# reach of project files: use no cache dir at all then, and touch nothing,
# before anything is created (physical paths, so links do not hide it). The
# cost: no resize in that setup, the image is Read as is (a known limit; keep
# TMPDIR outside the project).
_PHYS_TMP=$(cd -P "$OUT_DIR" 2>/dev/null && pwd -P) || exit 0
_PHYS_ROOT=$(cd -P "$ROOT" 2>/dev/null && pwd -P) || exit 0
case "$_PHYS_TMP/" in "$_PHYS_ROOT"/*) exit 0 ;; esac
OUT_DIR="${OUT_DIR%/}/megavibe-resized-$(id -u)"
mkdir -m 700 -p "$OUT_DIR" 2>/dev/null || exit 0
[ -O "$OUT_DIR" ] && [ ! -L "$OUT_DIR" ] || exit 0
_PHYS_OUT=$(cd -P "$OUT_DIR" 2>/dev/null && pwd -P) || exit 0
# The derived cache dir itself must not be the project root or inside it (a
# project directory named like the cache dir, under TMPDIR).
case "$_PHYS_OUT/" in "$_PHYS_ROOT"/*) exit 0 ;; esac
# mkdir -m does not tighten a dir that already exists: force it.
chmod 700 "$OUT_DIR" 2>/dev/null || exit 0
# Reading a file that lives in the cache dir itself (under any spelling of the
# path) is never ours to touch: no prune, no copy.
_PHYS_IN=$(cd -P "$(dirname "$ABS")" 2>/dev/null && pwd -P) || exit 0
[ "$_PHYS_IN" != "$_PHYS_OUT" ] || exit 0
# Prune only what this hook writes (never the file being read).
find "$OUT_DIR" -maxdepth 1 -type f \( -name '*.png' -o -name '*.jpg' -o -name '.tmp.*' \) ! -samefile "$ABS" -mtime +1 -delete 2>/dev/null || true

# Content key: a copy can only ever be reused for byte-identical input.
_key() { { shasum -a 1 "$1" 2>/dev/null || sha1sum "$1" 2>/dev/null; } | awk '{print $1}' | tr -cd 'a-f0-9' | cut -c1-16; }
KEY=$(_key "$ABS")
[ -n "$KEY" ] || exit 0
case "$(echo "${ABS##*.}" | tr '[:upper:]' '[:lower:]')" in
  jpg|jpeg) OUT_EXT="jpg"; SIPS_FMT="jpeg" ;;
  *)        OUT_EXT="png"; SIPS_FMT="png" ;;
esac
STEM=$(printf '%s' "$(basename "${ABS%.*}")" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)
DEST="$_PHYS_OUT/$STEM.$KEY.$OUT_EXT"   # absolute, even for a relative TMPDIR
# The input is itself the destination (a project link to a cache file): the
# publish below would overwrite the very file being read.
[ "$ABS" -ef "$DEST" ] && exit 0

# A copy is good when it is a regular file (not a link), decodes, and fits.
_good() {
  # ours only: a file another user planted (e.g. while the dir was looser)
  # is never shown as the copy
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
  local d w h; d=$(_dims "$1"); w=${d%% *}; h=${d##* }
  _is_int "$w" && _is_int "$h" && [ "$w" -gt 0 ] && [ "$h" -gt 0 ] \
    && [ "$w" -le "$MAX_DIM" ] && [ "$h" -le "$MAX_DIM" ]
}

if ! _good "$DEST"; then
  TMP_BASE=$(mktemp "$OUT_DIR/.tmp.XXXXXX" 2>/dev/null) || exit 0
  TMP_OUT="$TMP_BASE.$OUT_EXT"
  case "$RESIZE_TOOL" in
    sips)    sips -s format "$SIPS_FMT" --resampleHeightWidthMax "$MAX_DIM" "$ABS" --out "$TMP_OUT" &>/dev/null || true ;;
    magick)  magick "$ABS[0]" -resize "${MAX_DIM}x${MAX_DIM}>" "$TMP_OUT" &>/dev/null || true ;;
    convert) convert "$ABS[0]" -resize "${MAX_DIM}x${MAX_DIM}>" "$TMP_OUT" &>/dev/null || true ;;
  esac
  rm -f "$TMP_BASE" 2>/dev/null || true
  # The input must not have changed while it was converted, or the copy would be
  # filed under the wrong content key.
  if [ "$(_key "$ABS")" = "$KEY" ] && _good "$TMP_OUT"; then
    # A planted link at DEST must not make mv drop the file into its target dir.
    [ -L "$DEST" ] && rm -f "$DEST" 2>/dev/null
    if [ -d "$DEST" ]; then rm -f "$TMP_OUT"; exit 0; fi
    mv -f "$TMP_OUT" "$DEST" 2>/dev/null || { rm -f "$TMP_OUT"; exit 0; }
  else
    rm -f "$TMP_OUT" 2>/dev/null || true
    exit 0
  fi
fi
_good "$DEST" || exit 0
touch "$DEST" 2>/dev/null || true   # a reused copy must not age out under the Read

# Redirect the Read: same tool_input, file_path swapped for the copy.
printf '%s' "$INPUT" | jq -c --arg path "$DEST" --arg orig "$ABS" --arg w "$WIDTH" --arg h "$HEIGHT" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {file_path: $path}), additionalContext: ("megavibe resize-image: " + $orig + " is " + $w + "x" + $h + " px; this Read shows a copy scaled to fit 1800 px (" + $path + "). The original file is unchanged.")}}' 2>/dev/null
exit 0
