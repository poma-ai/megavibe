#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="on-session-start.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  jq -n --arg msg "$msg" '{systemMessage: $msg}' 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — auto-orient on fresh session start
# Triggered by: SessionStart (matcher: "startup")
#
# Injects project knowledge (LESSONS + DECISIONS) on every session start.
# Task state is NOT injected automatically — the user runs /catchup for that.

# Only act if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // ""')

# Only act on fresh startup (not compact — that's handled by on-compact.sh)
[ "$SOURCE" = "startup" ] || exit 0

# NOTE: Context-watcher spawn moved to start-context-watcher.sh — that hook
# registers for SessionStart with matchers `startup` AND `resume`, so the
# watcher comes up on /megavibe-restart and `claude --continue` too. This
# hook stays gated on source=startup because the project-knowledge injection
# below is for fresh sessions only.

# Check if project has real context
DECISIONS_LINES=$(wc -l < ".agent/DECISIONS.md" 2>/dev/null || echo "0")
DECISIONS_LINES=$(echo "$DECISIONS_LINES" | tr -d ' ')
LESSONS_LINES=$(wc -l < ".agent/LESSONS.md" 2>/dev/null || echo "0")
LESSONS_LINES=$(echo "$LESSONS_LINES" | tr -d ' ')

# If nothing to orient with, skip silently
[ "$DECISIONS_LINES" -gt 5 ] || [ "$LESSONS_LINES" -gt 5 ] || exit 0

# Extract session ID
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

# Check for open tasks to tailor the message
OPEN_TASKS=$(grep -cE "\| pending|\| in.progress" ".agent/TASKS.md" 2>/dev/null || echo "0")
OPEN_TASKS=$(echo "$OPEN_TASKS" | tr -d ' ')

if [ "$OPEN_TASKS" -gt 0 ] 2>/dev/null; then
  TASK_HINT="There are ${OPEN_TASKS} open task(s) from previous work. Use \`/catchup\` to review them, or start your new task — project knowledge is loaded below."
else
  TASK_HINT="All previous tasks are complete. Project knowledge is loaded below — ready for a new task."
fi

# --- poma-memory: search for context related to open tasks ---
POMA_CONTEXT=""
if [ "$OPEN_TASKS" -gt 0 ] 2>/dev/null && [ -f ".agent/.poma-memory.db" ]; then
  if command -v poma-memory &>/dev/null; then
    POMA_CMD="poma-memory"
    # Extract open task names as search terms
    TASK_TERMS=$(grep -E "\| pending|\| in.progress" ".agent/TASKS.md" 2>/dev/null \
      | sed 's/|/\n/g' | sed -n '3p' | tr -d '[:space:]' | head -c 200)
    if [ -n "$TASK_TERMS" ]; then
      POMA_RESULTS=$($POMA_CMD search "$TASK_TERMS" --path .agent/ --top-k 5 2>/dev/null || echo "")
      if [ -n "$POMA_RESULTS" ] && [ "$POMA_RESULTS" != "No results found." ]; then
        POMA_CONTEXT="
--- poma-memory: context related to open tasks ---
${POMA_RESULTS}"
      fi
    fi
  fi
fi

# --- Subagent health check (single `claude mcp list` call, cached) ---
SUBAGENT_STATUS=""
MCP_LIST=$(claude mcp list 2>/dev/null || echo "")

mcp_status() {
  local name="$1"
  if echo "$MCP_LIST" | grep -qi "${name}.*Connected"; then
    echo "MCP connected"
  elif echo "$MCP_LIST" | grep -qi "$name"; then
    echo "MCP registered (not connected)"
  else
    echo ""
  fi
}

# Gemini
GEMINI_STATUS=$(mcp_status "gemini")
[ -z "$GEMINI_STATUS" ] && { command -v gemini &>/dev/null && GEMINI_STATUS="CLI only (no MCP)" || GEMINI_STATUS="not installed"; }

# Codex — CLI only. There is no Codex MCP server: codex-cli 0.154.0 deleted the
# `mcp-server` subcommand (2026-09-10). Reviews go through codex-review.sh.
#
# This ASSERTS the subcommand instead of assuming it, which is the whole lesson
# from that removal: an npm-global CLI that auto-updates will keep deleting
# things, and the resulting error (CONNECTION_CLOSED, or a TUI dying on
# "stdin is not a terminal") never names the real cause. A one-line probe here
# turns the next such removal into an obvious status line instead of a day of
# misread outages.
if command -v codex &>/dev/null; then
  CODEX_VER=$(codex --version 2>/dev/null || echo "")
  if codex exec --help >/dev/null 2>&1; then
    CODEX_STATUS="CLI via codex-review.sh"
  else
    CODEX_STATUS="INSTALLED BUT UNUSABLE — \`codex exec\` is gone; check codex-review.sh"
  fi
  [ -n "$CODEX_VER" ] && CODEX_STATUS="${CODEX_STATUS} (${CODEX_VER})"
else
  CODEX_STATUS="not installed"
fi

# --- Reviewer allow-list (non-negotiable 4) ---
# Its OWN row, deliberately not an overwrite of the Gemini/Codex rows above.
# Those say whether the backend works at all — for summaries, large context,
# /rehydrate — and MEGAVIBE_REVIEWERS says nothing about any of that. Writing
# "OFF" into them also erased the "INSTALLED BUT UNUSABLE" diagnosis this hook
# exists to surface.
REVIEWERS_SH="$HOME/.megavibe/scripts/reviewers.sh"
ACTIVE_REVIEWERS=""
# -f, not -x: the callers run it with `bash`, so the exec bit is not required,
# and a failed chmod during install would otherwise skip the check silently.
if [ -f "$REVIEWERS_SH" ]; then
  ACTIVE_REVIEWERS=$(bash "$REVIEWERS_SH" list 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
  # Empty means the helper failed (the pipeline ends in sed, which succeeds on
  # no input, so `||` cannot catch it). A broken helper must not report every
  # reviewer off and talk Claude out of reviewing.
  [ -n "$ACTIVE_REVIEWERS" ] || ACTIVE_REVIEWERS="reviewer gemini codex"
fi

# Order-insensitive: resolve() preserves the order the user typed, so a literal
# comparison against "reviewer gemini codex" called "codex gemini reviewer" a
# non-default set and nagged about it on every session start.
REVIEWER_ROW=""
REVIEWER_LINE=""
if [ -n "$ACTIVE_REVIEWERS" ]; then
  RV_SORTED=$(printf '%s\n' $ACTIVE_REVIEWERS | sort | tr '\n' ' ' | sed 's/ *$//')
  if [ "$RV_SORTED" = "codex gemini reviewer" ]; then
    REVIEWER_ROW="
| Reviewers (non-negotiable 4) | all three |"
  else
    REVIEWER_ROW="
| Reviewers (non-negotiable 4) | ${ACTIVE_REVIEWERS} |"
    REVIEWER_LINE="
Reviewers: only ${ACTIVE_REVIEWERS} are switched on. Do not ask any other one to review — \`--as-reviewer\` exits 4 for it, and that is a setting, not an outage. This limits REVIEWS only: Gemini and Codex stay available for /rehydrate, summaries and large-context work regardless. Change it with \`megavibe reviewers set\`."
  fi
fi

# Playwright
PLAYWRIGHT_STATUS=$(mcp_status "playwright")
[ -z "$PLAYWRIGHT_STATUS" ] && PLAYWRIGHT_STATUS="not installed"

# poma-memory
POMA_STATUS=$(mcp_status "poma-memory")
if [ -z "$POMA_STATUS" ]; then
  if command -v poma-memory &>/dev/null; then
    POMA_STATUS="CLI only (no MCP)"
  else
    POMA_STATUS="not installed"
  fi
fi

SUBAGENT_STATUS="
--- Subagent status ---
| Backend | Status |
|---------|--------|
| Gemini | ${GEMINI_STATUS} |
| Codex | ${CODEX_STATUS} |
| Playwright | ${PLAYWRIGHT_STATUS} |
| poma-memory | ${POMA_STATUS} |${REVIEWER_ROW}${REVIEWER_LINE}"

CONTEXT="## Megavibe — project knowledge

Your session ID is: ${SID_FULL}
WORKING_CONTEXT path: .agent/sessions/${SID_FULL}/WORKING_CONTEXT.md

${TASK_HINT}
${SUBAGENT_STATUS}

--- LESSONS.md ---
$(cat .agent/LESSONS.md 2>/dev/null || echo '(empty)')

--- DECISIONS.md (last 20 lines) ---
$(tail -20 .agent/DECISIONS.md 2>/dev/null || echo '(empty)')${POMA_CONTEXT}"

# Emit as systemMessage (authoritative — Claude treats it as system-level instruction)
jq -n --arg msg "$CONTEXT" '{systemMessage: $msg}'
