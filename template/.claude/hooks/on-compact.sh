#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
# jq or file operations can fail on edge cases; the hook must still emit output.
_hook_error() {
  local msg="on-compact.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  jq -n --arg msg "$msg" '{systemMessage: $msg}' 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — auto re-hydrate context after compaction
# Triggered by: SessionStart (matcher: "compact")
# Only acts when source === "compact" (after a compaction; documented for both
# automatic and manual /compact, though on-pre-compact.sh does not rely on it)
#
# Strategy (since 2026-10-11 nothing large is injected; see the end of the script):
# - Write the orientation to .agent/LOGS/rehydration-instructions.<sid>.md:
#   DECISIONS.md + TASKS.md + LESSONS.md + git state + the old WORKING_CONTEXT,
#   and the raw FULL_CONTEXT.md when it is under 10KB
# - Emit a short additionalContext: run /rehydrate (reviewers.sh digest-chain:
#   codex-review.sh → Claude subagent, or without Codex gemini-review.sh (capped)
#   → Claude subagent), or read a WORKING_CONTEXT written within the hour
#
# Improvements over v1:
# - LESSONS.md included (was missing)
# - Raw FULL_CONTEXT for small files (was never included)
# - No-cliff rule: backend output >= input size or 400 lines, whichever smaller
# - Source-of-truth guard: always compact from raw FULL_CONTEXT.md, not old WC
# - poma-memory search suggestion for targeted context augmentation
#
# CRITICAL: the backend must always read raw .agent/FULL_CONTEXT.md from disk
# (the append-only source of truth), NEVER from a previous WORKING_CONTEXT.md.
#
# Session isolation: rehydration flag and WORKING_CONTEXT are session-scoped.

# Only act if this is a Megavibe-initialized project with jq (both checked
# before the redirect below, which would otherwise touch files outside one)
[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0

# Redirect stderr to debug log (avoids confusing Claude Code's hook capture)
mkdir -p ".agent/LOGS" 2>/dev/null || true
exec 2>".agent/LOGS/on-compact-debug.log" 2>/dev/null || exec 2>/dev/null

# Require jq
command -v jq &>/dev/null || exit 0

mkdir -p ".agent/LOGS"

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // ""')

# Only act on compaction events
[ "$SOURCE" = "compact" ] || exit 0

echo "on-compact.sh fired at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2

# A subagent's compaction is not this session's: same guard as on-pre-compact.sh
# (subagents share the parent's session_id; the docs do not say whether this
# event fires for them, so both documented-adjacent signals are checked).
_OC_AGENT=$(echo "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null || echo "")
_OC_SIDF=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
[ -n "$_OC_SIDF" ] && case "$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" in */"$_OC_SIDF"/subagents/agent-*.jsonl) _OC_AGENT="${_OC_AGENT:-subagent-path}" ;; esac
if [ -n "$_OC_AGENT" ]; then echo "subagent compaction (${_OC_AGENT}): nothing to do" >&2; exit 0; fi

# Extract session ID for scoping
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' | cut -c1-12)
# Same gate as SID_FULL. `cut` bounds the LENGTH but not the content: a
# session_id of "../../../../" survives it intact, and this value is a path
# component in the flag filenames below.
case "$SID" in
  ''|.|..|*[!A-Za-z0-9._-]*) SID="default" ;;
esac
# The sessions DIRECTORY is keyed on the FULL session id, not the 12-char SID
# used for flat flag files. /rehydrate derives its path from session_id in the
# hook payload, so truncating here made the hook advertise one directory while
# the skill wrote another: the stale-context hint read an empty file, and
# .needs-rehydration never cleared because the file it watches was never the
# file that got written.
SID_FULL=$(echo "$INPUT" | jq -r '.session_id // "default"')
SID_FULL="${SID_FULL:-default}"
# Validate before it becomes a path component. session_id comes from the harness
# and is a UUID in practice, but this string is interpolated into mkdir/read
# targets, and "in practice" is not a boundary. Anything outside a safe charset
# — or a bare . / .. — falls back to the same "default" the missing-id case uses.
case "$SID_FULL" in
  ''|.|..|*[!A-Za-z0-9._-]*) SID_FULL="default" ;;
esac
SESSION_DIR=".agent/sessions/${SID_FULL}"
mkdir -p "$SESSION_DIR" 2>/dev/null || true

# Reset augment-search ledgers: compaction drops the just-written / already-seen
# content out of the live window, so re-injecting it becomes useful again. Without
# this reset, post-compaction recall would stay silent on exactly the context the
# summary just shed. (See augment-search.sh / reindex-agent.sh.)
rm -f ".agent/LOGS/injected.${SID}.log" ".agent/LOGS/session-writes.${SID}.log" 2>/dev/null || true

# Re-arm the compaction autopilot. Its flags are per-SESSION but the thing they
# describe is per-FILL-CYCLE: after a compaction the window is nearly empty and
# will fill again, so a .closeout-done left over from the previous cycle would
# silence the hook for the rest of the session — the exact failure it exists to
# prevent, reintroduced by its own success. Cleared here because this is the one
# hook that runs at the cycle boundary.
rm -f ".agent/LOGS/.closeout-done.${SID}"       ".agent/LOGS/.closeout-blocked.${SID}"       ".agent/LOGS/.closeout-count.${SID}"       ".agent/LOGS/.rehydrate-nudge.${SID}"       ".agent/LOGS/.rehydrate-blocked.${SID}" 2>/dev/null || true

WC_PATH="${SESSION_DIR}/WORKING_CONTEXT.md"
# Read-side migration. A session already running when this fix landed has its
# context in the old truncated directory, and compaction is exactly the moment
# that file is worth the most. Reads fall back to it; WC_PATH — the path
# advertised to Claude as the write target — stays canonical, so the next
# /rehydrate moves the session forward instead of deepening the split.
WC_READ="$WC_PATH"
[ -s "$WC_READ" ] || [ ! -s ".agent/sessions/${SID}/WORKING_CONTEXT.md" ] \
  || WC_READ=".agent/sessions/${SID}/WORKING_CONTEXT.md"
INSTRUCTIONS_FILE=".agent/LOGS/rehydration-instructions.${SID}.md"

# WC freshness gate: if /rehydrate ran within the last hour, the existing
# WORKING_CONTEXT is still useful and post-compact orientation injection is
# enough. Setting the rehydration flag here would just spawn a sticky nag
# that fires on every tool call until Claude *re-runs* /rehydrate — which
# Claude won't do if it (correctly) decides carryover context is sufficient.
# Skip the flag in that case; user can still invoke /rehydrate voluntarily.
WC_FRESH=0
# -s, not -f: /rehydrate's own failure path leaves an EMPTY WORKING_CONTEXT, and
# an empty file written a minute ago is not a working context.
if [ -f "$WC_READ" ] && [ -s "$WC_READ" ]; then
  WC_MTIME=$(stat -c %Y "$WC_READ" 2>/dev/null || stat -f %m "$WC_READ" 2>/dev/null || echo 0)
  NOW_TS=$(date +%s)
  WC_AGE=$(( NOW_TS - WC_MTIME ))
  [ "$WC_AGE" -lt 3600 ] 2>/dev/null && WC_FRESH=1
fi

# --- Read structured files (capped by bytes; they go into the orientation file
# below, which Claude reads on demand — NOT into the hook output, see the end
# of this script). DECISIONS
# in particular grows unbounded — at ~140KB it crowds out git state, tasks,
# and lessons entirely. Cap each section by BYTES (line-based tail is
# unbounded when individual lines are long, as they are in DECISIONS tables).
# Emit a pointer so Claude can Read the full file on demand.
_cap_inline() {
  local path="$1" max_bytes="$2"
  if [ ! -f "$path" ]; then
    echo "(empty)"
    return
  fi
  local size
  size=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
  size="${size:-0}"
  if [ "$size" -le "$max_bytes" ] 2>/dev/null; then
    cat "$path"
    return
  fi
  local total_lines
  total_lines=$(wc -l < "$path" 2>/dev/null | tr -d ' ')
  printf '...[truncated — showing last %s of %s bytes (%s lines total). Read %s for full content; the first line below may be partial.]...\n\n' \
    "$max_bytes" "$size" "$total_lines" "$path"
  tail -c "$max_bytes" "$path"
}
DECISIONS=$(_cap_inline .agent/DECISIONS.md 8192)
TASKS=$(_cap_inline .agent/TASKS.md 6144)
LESSONS=$(_cap_inline .agent/LESSONS.md 6144)

# --- Inline /catchup: git state + pre-compact WORKING_CONTEXT (if any) ---
# Folding catchup into the hook means post-compact Claude only has to run
# one slash command (/rehydrate). The catchup skill is still available for
# session-start orientation.
GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "(unknown)")
GIT_LOG=$(git log --oneline -10 2>/dev/null || echo "(no commits)")
GIT_DIFF_STAT=$(git diff --stat 2>/dev/null || echo "")
[ -z "$GIT_DIFF_STAT" ] && GIT_DIFF_STAT="(clean — no uncommitted changes)"

GIT_STATE="--- Git state ---
Branch: ${GIT_BRANCH}
Recent commits:
${GIT_LOG}
Uncommitted changes:
${GIT_DIFF_STAT}"

# Pre-compact WORKING_CONTEXT may still exist from before /compact fired.
# It's stale (compaction summary is now the source of truth) but useful as
# a what-was-I-doing hint. Truncate to 40 lines — even at 40 lines this is
# a stale hint, not authoritative; it goes into the orientation file.
OLD_WC=""
if [ -f "$WC_READ" ]; then
  OLD_WC_BODY=$(head -40 "$WC_READ" 2>/dev/null || echo "")
  if [ -n "$OLD_WC_BODY" ]; then
    OLD_WC="--- Pre-compact WORKING_CONTEXT.md (first 40 lines, stale hint only) ---
${OLD_WC_BODY}"
  fi
fi

# --- Check FULL_CONTEXT.md size ---
FULL_CONTEXT_SIZE=$(wc -c < .agent/FULL_CONTEXT.md 2>/dev/null || echo "0")
FULL_CONTEXT_SIZE=$(echo "$FULL_CONTEXT_SIZE" | tr -d ' ')
FULL_CONTEXT_LINES=$(wc -l < .agent/FULL_CONTEXT.md 2>/dev/null || echo "0")
FULL_CONTEXT_LINES=$(echo "$FULL_CONTEXT_LINES" | tr -d ' ')

echo "FULL_CONTEXT: ${FULL_CONTEXT_SIZE} bytes, ${FULL_CONTEXT_LINES} lines" >&2

# --- Build additionalContext based on size ---

# One freshness-dependent instruction, used by every strategy below and by the
# short message, so the orientation file never contradicts it.
if [ "$WC_FRESH" -eq 1 ]; then
  REHYDRATE_HINT="Your prior WORKING_CONTEXT (${WC_READ}) was written within the last hour
and is likely still valid. Treat it as your source of truth — running
/rehydrate now is OPTIONAL. If you decide carryover context is enough,
just continue working; the hooks will not remind you."
else
  REHYDRATE_HINT="Run /rehydrate — it regenerates ${WC_PATH} via the digest backend chain
(reviewers.sh digest-chain; full AI-powered recovery). Do /rehydrate BEFORE resuming any other
work. Until it completes, stale-context nags are suppressed for ~5 minutes
so you get a clean window."
fi

if [ "$FULL_CONTEXT_LINES" -le 10 ]; then
  # === BOOTSTRAP: .agent/ files are empty ===
  echo "Strategy: bootstrap (empty .agent/ files)" >&2

  CONTEXT="⚠️ CONTEXT WAS JUST COMPACTED — .agent/ FILES ARE EMPTY

Session: ${SID_FULL}
WORKING_CONTEXT path: ${WC_PATH}

The .agent/ context files were never populated during this session. The
compaction summary above is your ONLY source of context. Before continuing:

1. IMMEDIATELY record a summary of the compaction above with
   \`.claude/hooks/agent-log.sh append\` (entry text on stdin; never edit
   FULL_CONTEXT.md, it is rendered). Include: goal, key decisions, files
   changed, current state, what was being worked on.
2. Update .agent/DECISIONS.md with any decisions from the summary.
3. Update .agent/TASKS.md with pending tasks from the summary.
4. Then run /rehydrate — this is your only required slash command. It will
   regenerate ${WC_PATH} via Codex (full AI-powered recovery).

DO NOT skip steps 1–3. The compaction summary will be lost if you don't
externalize it now. Orientation (git state + /catchup equivalent) is inlined
below so you do NOT need to run /catchup separately.

${GIT_STATE}

--- DECISIONS.md ---
${DECISIONS}

--- TASKS.md ---
${TASKS}

--- LESSONS.md ---
${LESSONS}"

elif [ "$FULL_CONTEXT_SIZE" -lt 10240 ]; then
  # === SMALL: the orientation file carries the whole FULL_CONTEXT ===
  echo "Strategy: small log included in the orientation file (${FULL_CONTEXT_SIZE} bytes < 10KB)" >&2
  FULL_CONTEXT=$(cat .agent/FULL_CONTEXT.md 2>/dev/null || echo "")

  CONTEXT="✅ CONTEXT WAS COMPACTED — orientation below.

Session: ${SID_FULL}
WORKING_CONTEXT path: ${WC_PATH}
FULL_CONTEXT on disk: .agent/FULL_CONTEXT.md (${FULL_CONTEXT_LINES} lines, ${FULL_CONTEXT_SIZE} bytes — small enough to include below)

## Post-compact recovery

${REHYDRATE_HINT}

The catchup-equivalent (git state + .agent/ files) is included below, so
/catchup is not needed.

${GIT_STATE}

--- DECISIONS.md ---
${DECISIONS}

--- TASKS.md ---
${TASKS}

--- LESSONS.md ---
${LESSONS}

${OLD_WC}

--- FULL_CONTEXT.md (raw) ---
${FULL_CONTEXT}"

else
  # === NORMAL: instruct Claude to call the backend chain for a focused summary ===
  echo "Strategy: rehydration instructions (${FULL_CONTEXT_SIZE} bytes, ${FULL_CONTEXT_LINES} lines, wc_fresh=${WC_FRESH})" >&2


  CONTEXT="⚠️ CONTEXT WAS JUST COMPACTED

Session: ${SID_FULL}
WORKING_CONTEXT path: ${WC_PATH}
FULL_CONTEXT on disk: .agent/FULL_CONTEXT.md (${FULL_CONTEXT_LINES} lines, ${FULL_CONTEXT_SIZE} bytes — the append-only source of truth, too large to inline)
Durable backup of these instructions: ${INSTRUCTIONS_FILE}

## Post-compact recovery

${REHYDRATE_HINT}

Orientation (git state + structured .agent/ files) is included below so
/catchup is not needed separately.

${GIT_STATE}

--- DECISIONS.md ---
${DECISIONS}

--- TASKS.md ---
${TASKS}

--- LESSONS.md ---
${LESSONS}

${OLD_WC}"
fi

# --- Rehydration flag: one policy for every size ---
# Pending unless a non-empty WORKING_CONTEXT was written within the hour (then
# /rehydrate is optional and nothing reminds). An empty .agent/ always needs the
# recording steps, so the bootstrap case never counts as fresh. The nag count
# restarts with each compaction.
rm -f ".agent/LOGS/.rehydrate-nagcount.${SID}" 2>/dev/null || true
if [ "$FULL_CONTEXT_LINES" -gt 10 ] && [ "$WC_FRESH" -eq 1 ]; then
  rm -f ".agent/LOGS/.needs-rehydration.${SID}" 2>/dev/null || true
else
  echo 0 > ".agent/LOGS/.needs-rehydration.${SID}" 2>/dev/null || true
fi

# --- Record cooldown for proactive compaction ---
# log-tool-event.sh checks this timestamp to suppress nudges post-compaction
date +%s > ".agent/LOGS/.compact-ts.${SID}" 2>/dev/null || true

# --- Write the full orientation to a file ---
# This file, not the hook output, carries the orientation. Measured on 20 real
# compactions (2026-10-01..10): the full text was 19-28 KB, and Claude Code saved
# every one of them to disk and showed the model a 2 KB preview, so DECISIONS,
# TASKS, LESSONS and the old WORKING_CONTEXT never reached it. The output below
# stays small enough to be delivered whole and points here.
cat > "$INSTRUCTIONS_FILE" << INSTREOF
$CONTEXT
INSTREOF
echo "Wrote rehydration instructions to ${INSTRUCTIONS_FILE}" >&2

if [ "$FULL_CONTEXT_LINES" -le 10 ]; then
  SHORT="CONTEXT WAS JUST COMPACTED, and .agent/ is nearly empty: the compaction summary is your only record of this session. Before anything else:
1. Record the summary's essentials (goal, decisions, files changed, current state) with \`.claude/hooks/agent-log.sh append\` (text on stdin).
2. Update .agent/DECISIONS.md and .agent/TASKS.md from it.
3. Run /rehydrate (it writes ${WC_PATH})."
elif [ "$WC_FRESH" -eq 1 ]; then
  # WC_READ, not WC_PATH: a session from before the full-id fix keeps its WC in
  # the 12-character directory, and that is the file that was found fresh.
  SHORT="CONTEXT WAS JUST COMPACTED. Your WORKING_CONTEXT (${WC_READ}) was written within the last hour: Read it in full and continue. /rehydrate is optional (it writes ${WC_PATH})."
else
  SHORT="CONTEXT WAS JUST COMPACTED. Run /rehydrate before any other work: it rebuilds ${WC_PATH} from .agent/ and git. Then Read that file in full."
fi
# No branch name or commit subjects here: they are text a cloned repo controls,
# and this channel is read as instructions. They are in the orientation file.
SHORT="${SHORT}

Session: ${SID_FULL}

Full orientation (git state, DECISIONS, TASKS, LESSONS, the pre-compact WORKING_CONTEXT): Read ${INSTRUCTIONS_FILE}. Use it if /rehydrate cannot run; /catchup is not needed."
# The register-currency warning on-pre-compact.sh found, if any: the one part of
# its report that can contradict the records the model is about to trust.
REG_WARN_FILE=".agent/LOGS/.reg-warn.${SID}"
if [ -s "$REG_WARN_FILE" ]; then
  SHORT="${SHORT}

REGISTER CURRENCY: the records may describe a state the repo has left:$(head -c 1200 "$REG_WARN_FILE" 2>/dev/null)
Re-read TASKS §0 against git before repeating it as current."
fi
# The deliverables register on-pre-compact.sh found (open asks without a file).
ASK_WARN_FILE=".agent/LOGS/.ask-warn.${SID}"
if [ -s "$ASK_WARN_FILE" ]; then
  SHORT="${SHORT}

DELIVERABLES REGISTER (fixed text and counts, no file content): $(head -c 900 "$ASK_WARN_FILE" 2>/dev/null || true)"
fi
# Hard bound: a line that grows past it would put us back behind the preview.
[ "${#SHORT}" -le 3000 ] || SHORT="${SHORT:0:2990}
[...]"

echo "Emitting additionalContext (${#SHORT} chars; full orientation ${#CONTEXT} chars in file)" >&2

# additionalContext is what reaches the model; systemMessage is shown to the user
# only (the same split disk-check.sh and announce-update.sh use).
jq -n --arg ctx "$SHORT" --arg msg "megavibe: context compacted; orientation saved to ${INSTRUCTIONS_FILE}" \
  '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
