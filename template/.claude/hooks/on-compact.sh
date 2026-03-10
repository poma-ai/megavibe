#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
# jq or file operations can fail on edge cases; the hook must still emit output.
set -uo pipefail

# Megavibe — auto re-hydrate context after compaction
# Triggered by: SessionStart (matcher: "compact")
# Only acts when source === "compact" (Claude Code auto-compacted the context)
#
# Strategy:
# - Always inject: DECISIONS.md + TASKS.md + LESSONS.md (structured, small)
# - FULL_CONTEXT.md < 10KB: also inject raw (no AI needed)
# - FULL_CONTEXT.md >= 10KB: inject rehydration instructions for Claude to
#   call Gemini MCP → GEMINI_API_KEY curl → Codex MCP (fallback chain)
#
# Improvements over v1:
# - LESSONS.md injected (was missing)
# - Raw FULL_CONTEXT for small files (was never injected)
# - No-cliff rule: Gemini output >= input size or 400 lines, whichever smaller
# - Source-of-truth guard: always compact from raw FULL_CONTEXT.md, not old WC
# - poma-memory search suggestion for targeted context augmentation
#
# CRITICAL: Gemini must always read raw .agent/FULL_CONTEXT.md from disk
# (the append-only source of truth), NEVER from a previous WORKING_CONTEXT.md.
#
# Session isolation: rehydration flag and WORKING_CONTEXT are session-scoped.

# Redirect stderr to debug log (avoids confusing Claude Code's hook capture)
exec 2>".agent/LOGS/on-compact-debug.log" 2>/dev/null || exec 2>/dev/null

# Only act if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

mkdir -p ".agent/LOGS"

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // ""')

# Only act on compaction events
[ "$SOURCE" = "compact" ] || exit 0

echo "on-compact.sh fired at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2

# Extract session ID for scoping
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' | cut -c1-12)
SESSION_DIR=".agent/sessions/${SID}"
mkdir -p "$SESSION_DIR"

WC_PATH="${SESSION_DIR}/WORKING_CONTEXT.md"
INSTRUCTIONS_FILE=".agent/LOGS/rehydration-instructions.${SID}.md"

# --- Read structured files (always small, always injected) ---
DECISIONS=$(cat .agent/DECISIONS.md 2>/dev/null || echo "(empty)")
TASKS=$(cat .agent/TASKS.md 2>/dev/null || echo "(empty)")
LESSONS=$(cat .agent/LESSONS.md 2>/dev/null || echo "(empty)")

# --- Check FULL_CONTEXT.md size ---
FULL_CONTEXT_SIZE=$(wc -c < .agent/FULL_CONTEXT.md 2>/dev/null || echo "0")
FULL_CONTEXT_SIZE=$(echo "$FULL_CONTEXT_SIZE" | tr -d ' ')
FULL_CONTEXT_LINES=$(wc -l < .agent/FULL_CONTEXT.md 2>/dev/null || echo "0")
FULL_CONTEXT_LINES=$(echo "$FULL_CONTEXT_LINES" | tr -d ' ')

echo "FULL_CONTEXT: ${FULL_CONTEXT_SIZE} bytes, ${FULL_CONTEXT_LINES} lines" >&2

# --- The Gemini prompt (reused in both MCP and curl instructions) ---
GEMINI_PROMPT="Read this full context log (${FULL_CONTEXT_LINES} lines) and produce a focused WORKING CONTEXT summary.

Rules:
- Output MUST be at least as long as the input or 400 lines, whichever is SMALLER. Do not over-compress small inputs.
- PRESERVE: all open/in-progress tasks, recent decisions, architectural context, lessons learned, current goal, risks, unknowns.
- REMOVE: resolved issues, old debugging notes, completed task details, duplicate status updates, superseded decisions.
- Structure with sections: Goal, Constraints, Key Decisions (table), What's Done (brief), Open Tasks (with acceptance criteria), Risks/Unknowns, Next Actions (3 steps).
- CRITICAL: you are reading the RAW append-only FULL_CONTEXT.md. Never regenerate from a previous WORKING_CONTEXT."

# --- Build additionalContext based on size ---

if [ "$FULL_CONTEXT_LINES" -le 10 ]; then
  # === BOOTSTRAP: .agent/ files are empty ===
  echo "Strategy: bootstrap (empty .agent/ files)" >&2
  touch ".agent/LOGS/.needs-rehydration.${SID}"

  CONTEXT="⚠️ CONTEXT WAS JUST COMPACTED — .agent/ FILES ARE EMPTY

Your session ID is: ${SID}
Your session-scoped WORKING_CONTEXT is at: ${WC_PATH}

The .agent/ context files were never populated during this session.
The compaction summary above is your ONLY source of context. Before continuing:

1. IMMEDIATELY write a summary of the compaction above to .agent/FULL_CONTEXT.md (append after the header). Include: goal, key decisions, files changed, current state, what was being worked on.
2. Update .agent/DECISIONS.md with any decisions from the summary.
3. Update .agent/TASKS.md with pending tasks from the summary.
4. Then follow the re-hydration steps below to regenerate ${WC_PATH}.

DO NOT skip these steps. The compaction summary will be lost if you don't externalize it now.

--- DECISIONS.md ---
${DECISIONS}

--- TASKS.md ---
${TASKS}

--- LESSONS.md ---
${LESSONS}"

elif [ "$FULL_CONTEXT_SIZE" -lt 10240 ]; then
  # === SMALL: inject raw FULL_CONTEXT directly (no AI needed) ===
  echo "Strategy: raw injection (${FULL_CONTEXT_SIZE} bytes < 10KB)" >&2
  FULL_CONTEXT=$(cat .agent/FULL_CONTEXT.md 2>/dev/null || echo "")

  CONTEXT="✅ CONTEXT RECOVERED — FULL_CONTEXT.md injected raw (${FULL_CONTEXT_LINES} lines, small enough to include directly).

Your session ID is: ${SID}
Your session-scoped WORKING_CONTEXT is at: ${WC_PATH}
For 100% recall: .agent/FULL_CONTEXT.md on disk (${FULL_CONTEXT_LINES} lines, ${FULL_CONTEXT_SIZE} bytes)

--- DECISIONS.md ---
${DECISIONS}

--- TASKS.md ---
${TASKS}

--- LESSONS.md ---
${LESSONS}

--- FULL_CONTEXT.md (raw) ---
${FULL_CONTEXT}"

else
  # === NORMAL: instruct Claude to call Gemini/Codex for focused summary ===
  echo "Strategy: rehydration instructions (${FULL_CONTEXT_SIZE} bytes, ${FULL_CONTEXT_LINES} lines)" >&2
  touch ".agent/LOGS/.needs-rehydration.${SID}"

  CONTEXT="⚠️ CONTEXT WAS JUST COMPACTED — RE-HYDRATION REQUIRED

Your session ID is: ${SID}
Your session-scoped WORKING_CONTEXT is at: ${WC_PATH}
Full context on disk: .agent/FULL_CONTEXT.md (${FULL_CONTEXT_LINES} lines, ${FULL_CONTEXT_SIZE} bytes — the append-only source of truth)
Full instructions also saved at: ${INSTRUCTIONS_FILE}

## Re-hydration steps

0. **poma-memory augmentation** (if available): call poma_search with key terms from TASKS.md to get targeted context. Include results when calling the backend in step 1.

1. **Try Gemini MCP first:** call mcp__gemini-cli__ask-gemini with this prompt:

   @.agent/FULL_CONTEXT.md
   ${GEMINI_PROMPT}

2. **If Gemini MCP fails** and \$GEMINI_API_KEY is set, use it via Bash:
   curl -s \"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\$GEMINI_API_KEY\" \\
     -H 'Content-Type: application/json' \\
     -d '{\"contents\":[{\"parts\":[{\"text\":\"<paste FULL_CONTEXT.md content + prompt above>\"}]}]}'

3. **If both Gemini paths fail**, fall back to Codex MCP with the same prompt and file content.

4. **Write** the result to ${WC_PATH} and **read it back**.

IMPORTANT: Do NOT use \$GEMINI_API_KEY for Claude or OpenAI — those always use subscription logins.

Here are the structured files to orient you immediately:

--- DECISIONS.md ---
${DECISIONS}

--- TASKS.md ---
${TASKS}

--- LESSONS.md ---
${LESSONS}"
fi

# --- Write durable backup (in case additionalContext injection fails) ---
cat > "$INSTRUCTIONS_FILE" << INSTREOF
$CONTEXT
INSTREOF
echo "Wrote rehydration instructions to ${INSTRUCTIONS_FILE}" >&2

echo "Emitting additionalContext (${#CONTEXT} chars)" >&2

# Return additionalContext in the correct SessionStart structured output format
jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
