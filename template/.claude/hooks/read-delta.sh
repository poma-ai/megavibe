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
# matches the previous Read by THIS AGENT in this session, rewrite the
# tool's file_path (via PreToolUse updatedInput) to a small stub file
# that tells Claude the content is unchanged and to refer to the earlier
# read above.
#
# Triggered by: PreToolUse (Read). Exit 0 always (advisory).
# Rationale: Claude frequently re-reads the same file across turns to
# "re-check" its state. Full re-reads of unchanged files duplicate
# tokens already in the conversation. Stubbing the re-read costs the
# line numbers of that read (the stub says how to get them back) and
# saves the content, which is already above.
#
# The one invariant: a stub must never claim content the READING CONTEXT
# does not have. Every branch here is written to fail towards passing the
# real file through, because a wasted re-read costs tokens and a false
# stub costs the reader the document without telling anyone.
#
# Mechanism:
#   - Compute sha256 of current file
#   - Compare to last cached hash for this (file_path, session, agent)
#   - On hit: write a small stub file, rewrite file_path to the stub
#   - On miss or first read: append {file, hash, ts, size, agent} to cache,
#     pass through
#
# The key includes the AGENT, not just the session. A subagent has its own
# fresh context window and shares neither the parent's conversation nor its
# session_id-keyed read history, so keying on the session alone told a
# freshly spawned reviewer that a file it had never read was "unchanged since
# your previous Read" — handing it an empty view of a document it was asked
# to review against, with no visible error. `agent_id` is present in the hook
# payload for subagent tool calls and absent for the main thread, which keys
# as "main".
#
# Skips:
#   - Non-Read tools
#   - Missing/empty files
#   - Partial reads (offset or limit set — user explicitly wants slice)
#   - Image/PDF/binary extensions (resize-image.sh handles those)
#   - Tiny files (below MIN_BYTES — overhead not worth it)
#   - Reads of the stub file itself (recursion guard)
#
# Cache file: .agent/LOGS/read-cache.${SID}.jsonl (one per session, every
#             row tagged with the agent that read it). A row with no tag was
#             written before this key existed and could have come from either
#             the main thread or a subagent, so it matches NOTHING and is
#             simply re-read once — guessing "main" for it would hand the
#             main thread a stub for a file only a subagent had read.
#             on-pre-compact.sh deletes this file, and must derive ${SID}
#             exactly as it is derived here or the invalidation misses.
# Stub file:  .agent/LOGS/read-stub.${SID}.${AGENT_SLUG}.${FILE_SLUG}.txt —
#             one per agent AND per file. Both halves are needed: per-agent
#             so two subagents can't clobber each other, per-file because
#             several Reads in ONE assistant turn are hooked before any of
#             them runs, and a single stub per agent meant the last one
#             written answered all of them (a Read of A returning a stub
#             that named B).
#
# The cache is dropped by on-pre-compact.sh: compaction removes the earlier
# Read from the context window while the row would survive it, and a stub
# that says "already in your context above" must never outlive the content
# it points at.
#
# Known residuals, both fail towards a false stub and neither is closed here:
#   - The row is written at PreToolUse, before the Read is known to have
#     happened. A Read denied at the permission prompt or interrupted leaves
#     a row, so the NEXT read of that path is a stub for content that never
#     entered context. The fix is to record on PostToolUse(Read), which
#     fires only when the tool actually ran. Deferred on frequency, NOT on
#     cost: it needs a denial or an interrupt followed by a retry of the
#     same path in the same session. The cost is in fact small — the
#     template already registers a PostToolUse(Read) matcher, and init.sh
#     replaces the hooks block wholesale, so there is no migration to write.
#   - Only main-thread compaction is covered, via PreCompact. A subagent's
#     own context compacting does not fire it. Nor, probably, does the
#     time-based mid-turn eviction of old tool results that the installed
#     Claude Code binary carries strings for (`tengu_time_based_microcompact`)
#     — unverified either way, and the more likely of the two to bite,
#     because it is on the main thread and needs no long-running subagent.

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

# Sanitised because SID reaches a filename; a session_id containing a slash
# would otherwise point the cache at a directory that does not exist.
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | tr -cd 'A-Za-z0-9-' | cut -c1-12)
SID="${SID:-default}"

# Subagent tool calls carry agent_id; the main thread has none, and keys as
# "main". The cache row stores the id VERBATIM — jq --arg makes any string
# safe there, and an exact key is the whole point: sanitising or truncating
# it would let two agents share a cache scope, which is the bug this key
# exists to prevent. Only the stub FILENAME needs a safe form, so that is a
# hash of the id rather than a stripped version of it.
AGENT_ID=$(echo "$INPUT" | jq -r '(.agent_id // .agentId // "") | tostring' 2>/dev/null | tr -d '\n')
[ "$AGENT_ID" = "null" ] && AGENT_ID=""
SUB_MARKER=$(echo "$INPUT" \
  | jq -r 'if ((.agent_id // .agentId // .agent_type // .agentType) != null) then "1" else "0" end' \
  2>/dev/null || echo "")

if [ -n "$AGENT_ID" ]; then
  # Prefixed so no agent can key as the main thread, whatever its id is.
  AGENT="agent:${AGENT_ID}"
  AGENT_SLUG=$(printf '%s' "$AGENT_ID" | shasum -a 256 2>/dev/null | cut -c1-16)
  AGENT_SLUG="${AGENT_SLUG:-agent}"
elif [ "$SUB_MARKER" = "1" ]; then
  # Marked as a subagent, but with no id to scope the cache by. Pass the real
  # file through: the safe answer for a reading context we cannot identify is
  # the content, never a stub asserting the reader already has it. This is the
  # branch that keeps a future field rename from silently restoring the bug.
  exit 0
else
  AGENT="main"
  AGENT_SLUG="main"
fi

mkdir -p ".agent/LOGS" 2>/dev/null || true
CACHE=".agent/LOGS/read-cache.${SID}.jsonl"

# shasum prefixes its output line with a backslash and escapes the path when
# the filename contains a backslash or newline, so the first field is not
# always the bare digest. Strip to hex and insist on a full one — anything
# else and we pass the file through rather than key the cache on a fragment.
HASH=$(shasum -a 256 "$FILE" 2>/dev/null | awk '{print $1}' | tr -cd 'a-f0-9')
[ ${#HASH} -eq 64 ] || exit 0

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Look up this agent's last entry for this file. The cheap prefilter greps the
# bare content digest rather than the path. Two reasons: a path is stored
# JSON-escaped, so a literal grep for one containing a quote or backslash
# never matches it; and the digest narrows to rows whose content is the very
# thing we would claim is unchanged, so reads of other files — or of other
# versions of this file — cannot push the row we need out of the tail window.
# Nothing is parsed out of the grep: jq makes every decision, filtering on
# path and agent.
LAST_HASH=""
LAST_TS=""
if [ -f "$CACHE" ]; then
  LAST_ENTRY=$(grep -F -- "$HASH" "$CACHE" 2>/dev/null \
    | tail -200 \
    | jq -rc --arg f "$FILE" --arg a "$AGENT" \
        'select(.file == $f and .agent == $a)' 2>/dev/null \
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
  FILE_SLUG=$(printf '%s' "$FILE" | shasum -a 256 2>/dev/null | cut -c1-12)
  FILE_SLUG="${FILE_SLUG:-file}"
  STUB="${STUB_DIR}/read-stub.${SID}.${AGENT_SLUG}.${FILE_SLUG}.txt"

  # A stub is consumed by the Read that follows this hook within the same
  # turn, so anything of this agent's left over from an hour ago is litter.
  # Scoped to this session and agent: never touches another reader's stub.
  find "$STUB_DIR" -maxdepth 1 -name "read-stub.${SID}.${AGENT_SLUG}.*.txt" \
    -mmin +60 -delete 2>/dev/null || true

  cat > "$STUB" 2>/dev/null <<STUBEOF || exit 0
[megavibe read-delta cache hit]

File:     $FILE
SHA256:   $HASH
Size:     $SIZE bytes
Previous: $LAST_TS (this agent, this session)
Now:      $NOW

The file is unchanged since your own previous Read of this path earlier
in this conversation. Re-reading would duplicate ~$((SIZE / 4)) tokens of
content already in your context above.

If you need fresh line numbers (e.g. after an Edit just made) or a
specific slice, call Read with offset/limit to bypass this cache.
STUBEOF

  # Record the hit so ts is refreshed (same hash)
  jq -nc --arg f "$FILE" --arg h "$HASH" --arg ts "$NOW" --argjson sz "$SIZE" --arg a "$AGENT" \
    '{file:$f, hash:$h, ts:$ts, size:$sz, agent:$a, hit:true}' >> "$CACHE" 2>/dev/null || true

  # Emit the updatedInput. hookSpecificOutput is the current format for
  # PreToolUse input modification (v2.0.10+).
  jq -nc --arg path "$STUB" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: {file_path: $path}}}'
  exit 0
fi

# Cache miss (new file or content changed). Record and pass through.
jq -nc --arg f "$FILE" --arg h "$HASH" --arg ts "$NOW" --argjson sz "$SIZE" --arg a "$AGENT" \
  '{file:$f, hash:$h, ts:$ts, size:$sz, agent:$a, hit:false}' >> "$CACHE" 2>/dev/null || true

exit 0
