#!/bin/bash
# DO NOT use set -e — hook must be resilient to transient failures.
_hook_error() {
  local msg="read-delta.sh failed at line $1: $2"
  echo "$msg" >> "${HOME:-/tmp}/.megavibe/hook-errors.log" 2>/dev/null
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
# Triggered by: PreToolUse (Read) to answer, and PostToolUse (Read) to
# record. Exit 0 always (advisory).
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
# Mechanism, split across the two events:
#   PreToolUse  — sha256 the file, compare to the last row for this
#                 (file_path, session, agent) that is marked confirmed. On a
#                 hit, write a small stub and rewrite file_path to it. On a
#                 miss, pass the file through and append a PENDING row
#                 holding that hash and this call's tool_use_id.
#   PostToolUse — append a CONFIRMED row, but only given evidence that the
#                 read was whole, that the response describes this file,
#                 that the pending row belongs to this very call, and that
#                 the bytes actually delivered hash to what the row claims.
#
# Nothing is promoted or deleted: the cache is append-only and the pending
# row stays where it is. It can only ever be spent by a call presenting the
# same tool_use_id — the code enforces the match, not the uniqueness, which
# rests on the harness issuing an id per call. A degenerate or missing id is
# therefore treated as no receipt at all.
#
# A row answers a Read only if it says confirmed:true. That is positive
# proof, not the absence of a marker, so rows written by older versions of
# this hook — which recorded at PreToolUse, BEFORE the read ran — never
# answer one, even though they sit in the same cache file after an upgrade.
#
# Recording on PostToolUse is the point, not an implementation detail. A row
# written at PreToolUse claims a Read happened that may not have: denied at
# the permission prompt, interrupted with ESC, or failed. The next Read of
# that path would then be answered with a stub for content that never
# entered the context. Measured: a Read of a nonexistent path fires no
# PostToolUse event at all, and an over-size read is routed to
# PostToolUseFailure, so this event does encode "the tool returned".
#
# "The tool returned" is NOT the same as "the reader has the file", which is
# what the stub asserts. The recording branch therefore checks three further
# things rather than assuming them: that the response describes a whole read
# of this file, that a pending row from this same call vouches for it, and
# that the delivered bytes hash to what the row will claim. Each came from a
# review that reproduced the false stub that check prevents; see each one.
#
# On a hit, PostToolUse sees the REWRITTEN path (the stub) in tool_input,
# which the recursion guard below skips — so a hit records nothing and the
# row keeps the timestamp of the read that actually delivered the content.
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
#   - Files below MIN_BYTES, where the stub costs more than it saves
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
# Deliberate cost, not a bug: a Read cannot be answered from a row that does
# not exist yet, so two Reads of the same path issued together — before
# either has completed — both pass the file through. A pending row could
# answer the second, but it describes content that has not been delivered,
# which is the one thing this hook must never assert.
#
# Known residuals, in two groups.
#
# Things this hook does NOT do, which cost tokens and nothing else:
#   - A file above the Read tool's token cap is never confirmed, so it is
#     never deduplicated — the benefit is absent exactly where a re-read is
#     most expensive. Closing that needs page-level bookkeeping, which is a
#     different design.
#   - A cache line that is not valid JSON is skipped rather than aborting
#     the lookup, so a partial write costs one re-read, not the session's
#     caching.
#
# Things that can still produce a false stub. All the same shape: something
# removes content from a context without firing a hook this file can see, so
# a row outlives what it describes.
#   - Only main-thread compaction is covered, via PreCompact. A subagent's
#     own context compacting does not fire it, and neither does time-based
#     microcompaction, which is CONFIRMED present in Claude Code 2.1.274:
#     `tengu_time_based_microcompact` clears old tool results while keeping
#     recent ones, on the main thread, with no hook event. Its gating and
#     default are not established. This is the residual most likely to
#     bite, because it needs no subagent and no explicit command, and it
#     targets the OLDEST reads — exactly the ones a re-Read wants.
#
#     Two things bound it. The stub now tells a reader that finds nothing
#     above to re-read and say so, which turns silent data loss into a
#     recoverable miss for EVERY residual here. And a confirmed row expires
#     (CACHE_TTL_SECS), so a row cannot answer for a read old enough to
#     have been cleared underneath it.
#   - /rewind truncates the conversation and fires no hook event at all (the
#     binary's event list is PreToolUse, PostToolUse, PreCompact, PostCompact,
#     Stop, Notification, SessionStart). If it keeps the session id, which is
#     likely and unverified, the cache survives a rewind that discarded the
#     reads it describes.
#   - /clear appears safe by accident rather than by guard: it starts a new
#     transcript with a new session id, so the cache filename rotates. No
#     SessionStart matcher for it is registered, so nothing enforces that.
#
# Registration: BOTH events, in .claude/settings.json. Registered on only
# PreToolUse, every miss still appends a pending row that nothing will ever
# confirm, so the cache grows and never answers anything — the hook does no
# harm and no good. On only PostToolUse there is no pending row to authorise
# anything, so it records nothing. Neither is unsafe, and neither is
# detectable except by noticing that re-Reads are never stubbed.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
command -v shasum &>/dev/null || exit 0

# The stub itself costs ~650 bytes, so caching a file smaller than a few
# times that LOSES tokens while claiming to save them. Measured: a 211-byte
# file produced a 650-byte stub announcing a ~52 token saving. Break-even is
# around 700 bytes; this floor is set well clear of it.
MIN_BYTES=3000

# A confirmed row stops answering after this long. Nothing in the harness
# tells this hook that a tool result was evicted from the context — see the
# residuals above — so age is the only bound available on how wrong a row
# can be.
CACHE_TTL_SECS=3600

INPUT=$(cat)

# One parse, not nine. This hook fires on every Read, and on the recording
# event the payload carries the file's entire content — so a jq process per
# field meant re-parsing 150KB nine times over. Measured on a 152KB payload:
# nine calls 37ms, one call 5ms.
#
# Fields are NUL-separated because a file path legitimately contains spaces,
# tabs and newlines, and NUL is the one byte a JSON string cannot hold. Read
# with `read -r -d ""`, not eval: this is untrusted input, and no escaping
# scheme has to be correct if nothing is ever evaluated.
#
# SUB_MARKER is computed inside this expression on purpose. It distinguishes
# an agent_id that is ABSENT from one that is empty, which the `// ""` that
# produces AGENT_ID necessarily erases. It watches agent_id only: agent_type
# is also present on the MAIN thread of a `claude --agent` session (the hook
# schema says to use agent_id, not agent_type, to tell the two apart), so
# keying on it switched the cache off for such a session entirely.
{
  IFS= read -r -d "" TOOL_NAME
  IFS= read -r -d "" EVENT
  IFS= read -r -d "" TOOL_UID
  IFS= read -r -d "" FILE
  IFS= read -r -d "" OFFSET
  IFS= read -r -d "" LIMIT
  IFS= read -r -d "" SID
  IFS= read -r -d "" AGENT_ID
  IFS= read -r -d "" SUB_MARKER
} < <(printf '%s' "$INPUT" | jq -j '
  [ (.tool_name // ""),
    (.hook_event_name // ""),
    (.tool_use_id // ""),
    (.tool_input.file_path // ""),
    (.tool_input.offset // 0 | tostring),
    (.tool_input.limit // 0 | tostring),
    (.session_id // "default"),
    ((.agent_id // .agentId // "") | tostring),
    (if ((.agent_id // .agentId) != null)
       then "1" else "0" end)
  ] | map(. + "\u0000") | join("")' 2>/dev/null) || true

TOOL_NAME="${TOOL_NAME:-}"
[ "$TOOL_NAME" = "Read" ] || exit 0

# Which half of the job this invocation is. Only the two events this hook is
# registered for do anything; a payload from anywhere else exits rather than
# emitting an updatedInput nothing consumes, or appending a row nothing will
# confirm. A hook registered only on PreToolUse (an older settings.json that
# never re-ran init.sh) is NOT rescued by the answering branch: answering
# needs a confirmed row, only the recording event writes one, so such a setup
# accumulates pending rows and never stubs anything.
EVENT="${EVENT:-}"
case "$EVENT" in
  PostToolUse|PreToolUse|"") ;;
  *) exit 0 ;;
esac

# The id of THIS tool call. Measured: PreToolUse and PostToolUse carry the
# same tool_use_id for one Read, and it is unique per call. That makes it a
# receipt for one specific read rather than a claim about the file in
# general, which is the only thing that can safely authorise a cache row.
# Sanitising can strip an id down to something short enough to collide, so a
# degenerate one is treated as no id at all: no pending row, no confirmation.
TOOL_UID=$(printf '%s' "${TOOL_UID:-}" | tr -cd 'A-Za-z0-9_-' | cut -c1-64)
[ ${#TOOL_UID} -ge 8 ] || TOOL_UID=""

FILE="${FILE:-}"
OFFSET="${OFFSET:-0}"
LIMIT="${LIMIT:-0}"
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
# -L because shasum and wc -l follow symlinks: without it a symlink is
# measured as its own path length, so the file is never cached and, for a
# long enough target path, the stub would print a wrong size.
# GNU first, then validate: GNU stat reads -f as --file-system and prints a
# filesystem block for "$FILE" on stdout while exiting 1, so the BSD form
# tried first leaves that block prefixed to the fallback's answer and the
# numeric test below fails on every Linux machine.
SIZE=$(stat -Lc %s "$FILE" 2>/dev/null || true)
case "$SIZE" in ''|*[!0-9]*) SIZE=$(stat -Lf %z "$FILE" 2>/dev/null || echo "0") ;; esac
SIZE="${SIZE:-0}"
[ "$SIZE" -ge "$MIN_BYTES" ] 2>/dev/null || exit 0

# Sanitised because SID reaches a filename; a session_id containing a slash
# would otherwise point the cache at a directory that does not exist.
SID=$(printf '%s' "${SID:-default}" | tr -cd 'A-Za-z0-9-' | cut -c1-12)
SID="${SID:-default}"

# Subagent tool calls carry agent_id; the main thread has none, and keys as
# "main". The cache row stores the id VERBATIM — jq --arg makes any string
# safe there, and an exact key is the whole point: sanitising or truncating
# it would let two agents share a cache scope, which is the bug this key
# exists to prevent. Only the stub FILENAME needs a safe form, so that is a
# hash of the id rather than a stripped version of it.
AGENT_ID=$(printf '%s' "${AGENT_ID:-}" | tr -d '\n')
[ "$AGENT_ID" = "null" ] && AGENT_ID=""
SUB_MARKER="${SUB_MARKER:-}"

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
NOW_EPOCH=$(date +%s 2>/dev/null | tr -cd '0-9')
NOW_EPOCH="${NOW_EPOCH:-0}"
# No clock, no TTL: with now=0 every row would pass the age check, so the one
# bound on a stale row would be gone. Pass the file through instead.
[ "$NOW_EPOCH" -gt 0 ] 2>/dev/null || exit 0

if [ "$EVENT" = "PostToolUse" ]; then
  # --- Record. Three things must be true, each checked against evidence.
  #
  # 1. The reader got the WHOLE file. A Read past the tool's token cap
  #    returns a page and says so; recording the whole-file hash then makes
  #    the next Read a stub for lines that never arrived. Measured shape:
  #    tool_response.file carries numLines, totalLines, startLine, and on a
  #    truncated read the extra key truncatedByTokenCap.
  #
  #    totalLines is also checked against this file's own line count, so the
  #    proof is "the response describes THIS file" and not merely "the
  #    response agrees with itself". Presence of a field says nothing about
  #    its meaning: if a future version reported totalLines per page, page
  #    one would satisfy numLines == totalLines with every check passing.
  #    Measured, totalLines is the newline count plus one; the looser of the
  #    two is accepted because that last line is a counting convention.
  WC_L=$(wc -l < "$FILE" 2>/dev/null | tr -cd '0-9')
  WC_L="${WC_L:-0}"
  COMPLETE=$(echo "$INPUT" | jq -r --argjson wc "${WC_L:-0}" --arg path "$FILE" '
    (.tool_response.file // empty) as $f
    | if ($f | type) != "object" then "0"
      elif ($f.truncatedByTokenCap // false) then "0"
      elif (($f.numLines | type) == "number")
       and (($f.totalLines | type) == "number")
       and (($f.startLine | type) == "number")
       and (($f.content | type) == "string")
       and ($f.filePath == $path)
       and ($f.startLine == 1)
       and ($f.numLines == $f.totalLines)
       and (($f.totalLines == $wc) or ($f.totalLines == $wc + 1)) then "1"
      else "0" end' 2>/dev/null || echo "0")

  if [ "$COMPLETE" != "1" ]; then
    # A truncated or short read is the ordinary reason to be here and is not
    # worth a word. A tool_response that HAS a file object but not the keys
    # this check needs is different: it means the payload shape moved and the
    # cache has silently stopped working. Say so once per session, because
    # "look here first" is useless advice if there is nothing to look at.
    if echo "$INPUT" | jq -e '(.tool_response.file | type) == "object"
         and ((.tool_response.file.numLines | type) != "number"
           or (.tool_response.file.totalLines | type) != "number"
           or (.tool_response.file.startLine | type) != "number"
           or (.tool_response.file.content | type) != "string"
           or (.tool_response.file.filePath | type) != "string")' >/dev/null 2>&1; then
      SHAPE_FLAG=".agent/LOGS/.read-delta-shape.${SID}"
      if [ ! -e "$SHAPE_FLAG" ]; then
        : > "$SHAPE_FLAG" 2>/dev/null || true
        mkdir -p "${HOME:-/tmp}/.megavibe" 2>/dev/null || true
        echo "$(date -u +%FT%TZ) read-delta.sh: tool_response.file is missing a field this hook needs (numLines/totalLines/startLine/content/filePath) — re-Read caching is off for this session" \
          >> "${HOME:-/tmp}/.megavibe/hook-errors.log" 2>/dev/null || true
      fi
    fi
    exit 0
  fi

  # 2. This row is authorised by THIS read, not by some earlier one. The
  #    pending row PreToolUse left carries the tool_use_id of the call it
  #    belongs to, so it cannot be spent by a different Read that happens to
  #    arrive at the same hash. Matching on (file, agent, hash) alone made
  #    the pending row a session-lifetime bearer token: a denied, truncated
  #    or abandoned read left one behind, and any later read of a file that
  #    returned to that byte state — a branch switch, an undo, a formatter
  #    round-trip — could spend it and confirm content nobody had read.
  [ -n "$TOOL_UID" ] || exit 0
  PENDING=$(grep -F -- "$TOOL_UID" "$CACHE" 2>/dev/null \
    | jq -Rrc --arg f "$FILE" --arg a "$AGENT" --arg h "$HASH" --arg u "$TOOL_UID" \
        'fromjson? // empty
         | select(.file == $f and .agent == $a and .hash == $h and .uid == $u and (.pending // false) == true)' \
        2>/dev/null \
    | tail -1)
  [ -n "$PENDING" ] || exit 0

  # 3. The bytes the READER got are the bytes this row will describe. Checks
  #    1 and 2 both look at the file on disk, so neither sees a write that
  #    was reverted before PostToolUse ran: a formatter loop, a git stash and
  #    pop, a build that rewrites and restores. The reader would hold the
  #    intermediate version while the row described the original, and the
  #    next Read would be told it already had content it never saw.
  #
  #    tool_response.file.content is what was actually delivered. Measured:
  #    it is byte-identical to the file for every shape tested, except that
  #    the Read tool strips carriage returns — a full `tr -d '\r'`, not a
  #    CRLF-to-LF rewrite, confirmed against a lone mid-line CR. A CRLF file
  #    therefore matches the \r-stripped form and stays cacheable instead of
  #    being silently dropped.
  #
  #    That tolerance is an ASSUMPTION about the tool, not a property of
  #    this file: it is safe only while the transform is exactly \r-removal,
  #    because then the bytes accepted here are the bytes a later Read of
  #    the same disk state returns. If a future Read normalises anything
  #    else — CRLF only, a BOM, tabs — this branch would accept a copy that
  #    is not what a re-read delivers, and the stub would be false with
  #    nothing reporting it. Re-measure before trusting it across an
  #    upgrade.
  CONTENT_HASH=$(echo "$INPUT" | jq -j '.tool_response.file.content // ""' 2>/dev/null \
    | shasum -a 256 2>/dev/null | awk '{print $1}' | tr -cd 'a-f0-9')
  if [ "$CONTENT_HASH" != "$HASH" ]; then
    CRLF_HASH=$(tr -d '\r' < "$FILE" 2>/dev/null | shasum -a 256 2>/dev/null | awk '{print $1}' | tr -cd 'a-f0-9')
    [ -n "$CONTENT_HASH" ] && [ "$CONTENT_HASH" = "$CRLF_HASH" ] || exit 0
  fi
  #
  # The pending row is left where it is. Nothing promotes or deletes it; it
  # simply can never be spent again, because its uid belongs to a call that
  # is now over. Never emit JSON here: PostToolUse output rewrites nothing.
  { jq -nc --arg f "$FILE" --arg h "$HASH" --arg ts "$NOW" --argjson sz "$SIZE" --arg a "$AGENT" \
      --argjson at "${NOW_EPOCH:-0}" \
      '{file:$f, hash:$h, ts:$ts, at:$at, size:$sz, agent:$a, confirmed:true}' >> "$CACHE"; } 2>/dev/null || true
  exit 0
fi

# Look up this agent's last entry for this file. The cheap prefilter greps the
# bare content digest rather than the path. Two reasons: a path is stored
# JSON-escaped, so a literal grep for one containing a quote or backslash
# never matches it; and the digest narrows to rows whose content is the very
# thing we would claim is unchanged, so reads of other files — or of other
# versions of this file — cannot push the row we need out of the tail window.
# Nothing is parsed out of the grep: jq makes every decision, filtering on
# path, agent, confirmation and age. A row with no timestamp is one written
# before the TTL existed, and it expires rather than being trusted.
LAST_HASH=""
LAST_TS=""
if [ -f "$CACHE" ]; then
  LAST_ENTRY=$(grep -F -- "$HASH" "$CACHE" 2>/dev/null \
    | tail -200 \
    | jq -Rrc --arg f "$FILE" --arg a "$AGENT" \
        --argjson now "${NOW_EPOCH:-0}" --argjson ttl "${CACHE_TTL_SECS:-3600}" \
        'fromjson? // empty
         | select(.file == $f and .agent == $a and .confirmed == true
                  and (.at | type) == "number" and ($now - .at) <= $ttl)' \
        2>/dev/null \
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

If you cannot find that content above, this cache is WRONG and you have
not read this file: call Read again with offset=1 to bypass the cache,
and say so. The same applies if you need fresh line numbers after an
edit, or only a slice.
STUBEOF

  # Emit the updatedInput. hookSpecificOutput is the current format for
  # PreToolUse input modification (v2.0.10+).
  jq -nc --arg path "$STUB" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: {file_path: $path}}}'
  exit 0
fi

# Cache miss (new file, changed content, or a reader who has not seen it).
# Pass the real file through and leave a PENDING row stamped with this call's
# tool_use_id: it records the hash as it is right now, and PostToolUse will
# only accept it for the SAME call at the SAME hash. A pending row never
# answers a Read, and one left behind by a denied, interrupted or truncated
# read can never be spent by a later one.
[ -n "$TOOL_UID" ] || exit 0
{ jq -nc --arg f "$FILE" --arg h "$HASH" --arg ts "$NOW" --argjson sz "$SIZE" --arg a "$AGENT" --arg u "$TOOL_UID" \
    --argjson at "${NOW_EPOCH:-0}" \
    '{file:$f, hash:$h, ts:$ts, at:$at, size:$sz, agent:$a, uid:$u, pending:true}' >> "$CACHE"; } 2>/dev/null || true

exit 0
