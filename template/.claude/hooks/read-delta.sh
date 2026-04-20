#!/bin/bash
# DO NOT use set -e — hook must be resilient to transient failures.
_hook_error() {
  local msg="read-delta.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — re-Read cache. On a Read of a file whose content hash
# matches the previous Read this session, rewrite the tool's file_path
# (via PreToolUse updatedInput) to a small stub file that tells Claude
# the content is unchanged and to refer to the earlier read above.
#
# Triggered by: PreToolUse (Read). Exit 0 always (advisory).
# Rationale: Claude frequently re-reads the same file across turns to
# "re-check" its state. Full re-reads of unchanged files duplicate
# tokens already in the conversation. Stubbing the re-read saves
# context with zero information loss.
#
# Mechanism:
#   - Compute sha256 of current file
#   - Compare to last cached hash for this (file_path, session)
#   - On hit: write a small stub file, rewrite file_path to the stub
#   - On miss or first read: append {file, hash, ts, size} to cache, pass through
#
# Skips:
#   - Non-Read tools
#   - Missing/empty files
#   - Partial reads (offset or limit set — user explicitly wants slice)
#   - Image/PDF/binary extensions (resize-image.sh handles those)
#   - Tiny files (below MIN_BYTES — overhead not worth it)
#   - Reads of the stub file itself (recursion guard)
#
# Cache file: .agent/LOGS/read-cache.${SID}.jsonl
# Stub file:  .agent/LOGS/read-stub.${SID}.txt (rewritten on every hit)

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
command -v shasum &>/dev/null || exit 0

MIN_BYTES=200

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Read" ] || exit 0

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // 0' 2>/dev/null || echo "0")
LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // 0' 2>/dev/null || echo "0")
[ -n "$FILE" ] || exit 0

# Only full-file reads. Partial reads (offset/limit) bypass the cache —
# the user is explicitly asking for a slice, not the whole file.
[ "$OFFSET" = "0" ] && [ "$LIMIT" = "0" ] || exit 0

[ -f "$FILE" ] || exit 0

# Recursion guard: never stub a Read of the stub file itself
case "$FILE" in
  */read-stub.*.txt) exit 0 ;;
esac

# Skip image/PDF/binary extensions (resize-image.sh handles images;
# re-reading binaries across turns is rare and the hash cost is wasted)
# Portable case-insensitive extension check (bash 3.2 compatible for macOS)
EXT=$(echo "$FILE" | awk -F. '{print tolower($NF)}')
case "$EXT" in
  png|jpg|jpeg|gif|webp|pdf|svg|ico|heic|bmp|tiff|tif|zip|tar|gz|bz2|xz|7z|mp3|mp4|mov|avi|wav|flac|ogg)
    exit 0
    ;;
esac

# Skip tiny files — hash + stub overhead not worth it
SIZE=$(stat -f %z "$FILE" 2>/dev/null || stat -c %s "$FILE" 2>/dev/null || echo "0")
SIZE="${SIZE:-0}"
[ "$SIZE" -ge "$MIN_BYTES" ] 2>/dev/null || exit 0

SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
SID="${SID:-default}"

mkdir -p ".agent/LOGS" 2>/dev/null || true
CACHE=".agent/LOGS/read-cache.${SID}.jsonl"

HASH=$(shasum -a 256 "$FILE" 2>/dev/null | awk '{print $1}')
[ -n "$HASH" ] || exit 0

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Look up last entry for this file. Grep narrows candidate lines cheaply;
# jq then filters precisely (avoids false matches when one path is a
# substring of another).
LAST_HASH=""
LAST_TS=""
if [ -f "$CACHE" ]; then
  LAST_ENTRY=$(grep -F -- "$FILE" "$CACHE" 2>/dev/null \
    | tail -20 \
    | jq -rc --arg f "$FILE" 'select(.file == $f)' 2>/dev/null \
    | tail -1)
  if [ -n "$LAST_ENTRY" ]; then
    LAST_HASH=$(echo "$LAST_ENTRY" | jq -r '.hash // ""' 2>/dev/null || echo "")
    LAST_TS=$(echo "$LAST_ENTRY" | jq -r '.ts // ""' 2>/dev/null || echo "")
  fi
fi

if [ -n "$LAST_HASH" ] && [ "$HASH" = "$LAST_HASH" ]; then
  # Cache hit — rewrite file_path to a stub file so Claude sees a
  # tiny pointer instead of the full content she already has above.
  STUB_DIR=$(cd ".agent/LOGS" && pwd) 2>/dev/null || exit 0
  STUB="${STUB_DIR}/read-stub.${SID}.txt"

  cat > "$STUB" <<STUBEOF
[megavibe read-delta cache hit]

File:     $FILE
SHA256:   $HASH
Size:     $SIZE bytes
Previous: $LAST_TS (this session)
Now:      $NOW

The file is unchanged since your previous Read of this path earlier in
this conversation. Re-reading would duplicate ~$((SIZE / 4)) tokens of
content already in your context above.

If you need fresh line numbers (e.g. after an Edit just made) or a
specific slice, call Read with offset/limit to bypass this cache.
STUBEOF

  # Record the hit so ts is refreshed (same hash)
  jq -nc --arg f "$FILE" --arg h "$HASH" --arg ts "$NOW" --argjson sz "$SIZE" \
    '{file:$f, hash:$h, ts:$ts, size:$sz, hit:true}' >> "$CACHE" 2>/dev/null || true

  # Emit the updatedInput. hookSpecificOutput is the current format for
  # PreToolUse input modification (v2.0.10+).
  jq -nc --arg path "$STUB" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: {file_path: $path}}}'
  exit 0
fi

# Cache miss (new file or content changed). Record and pass through.
jq -nc --arg f "$FILE" --arg h "$HASH" --arg ts "$NOW" --argjson sz "$SIZE" \
  '{file:$f, hash:$h, ts:$ts, size:$sz, hit:false}' >> "$CACHE" 2>/dev/null || true

exit 0
