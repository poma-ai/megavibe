#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="augment-search.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  jq -n --arg msg "$msg" '{systemMessage: $msg}' 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — augment Grep/Glob with poma-memory vector search
# Triggered by: PreToolUse (Grep, Glob)
#
# When Claude searches for something, this hook silently runs a poma-memory
# search with the same query and injects any relevant .agent/ context as a
# systemMessage. Claude sees both native results + semantic matches.
#
# systemMessage is more authoritative than additionalContext — Claude treats
# it as system-level instruction rather than advisory annotation.
#
# Performance: model2vec semantic search on <10K vectors takes <10ms.
# No timeout needed (macOS lacks `timeout` command — was silently breaking this hook).

# Only run if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Find poma-memory: prefer PATH, fall back to ~/.megavibe/{,.}venv/bin/.
# The venv path matters when pip_install_with_fallback (setup.sh) used a
# PEP 668 fallback and the symlink to ~/.local/bin/ never landed on PATH.
if command -v poma-memory &>/dev/null; then
  POMA_CMD="poma-memory"
elif [ -x "$HOME/.megavibe/venv/bin/poma-memory" ]; then
  POMA_CMD="$HOME/.megavibe/venv/bin/poma-memory"
elif [ -x "$HOME/.megavibe/.venv/bin/poma-memory" ]; then
  POMA_CMD="$HOME/.megavibe/.venv/bin/poma-memory"
else
  exit 0
fi

# Check index exists (no point searching an empty index)
[ -f ".agent/.poma-memory.db" ] || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")

# Extract search term based on tool type
PATTERN=""
if [[ "$TOOL_NAME" == "Grep" ]]; then
  PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // ""' 2>/dev/null || echo "")
elif [[ "$TOOL_NAME" == "Glob" ]]; then
  # Extract meaningful terms from glob pattern (e.g., "**/*.test.ts" → "test")
  RAW=$(echo "$INPUT" | jq -r '.tool_input.pattern // ""' 2>/dev/null || echo "")
  # Strip glob syntax to get searchable keywords
  PATTERN=$(echo "$RAW" | sed 's/\*\*\///g; s/\*//g; s/\.//g; s/\///g' | tr '-_' ' ')
fi

# Skip trivial patterns (too short to be meaningful)
[ "${#PATTERN}" -gt 3 ] || exit 0

# Skip if Claude is already searching inside .agent/ (avoid redundancy)
SEARCH_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // ""' 2>/dev/null || echo "")
if [[ "$SEARCH_PATH" == *".agent"* ]]; then
  exit 0
fi

# Run poma-memory search (no timeout — <10ms on typical indexes).
# Request extra results so the .agent/LOGS/ filter below can drop noise
# (stale rehydration-instructions, session state dumps) without starving
# the useful matches.
RAW_RESULTS=$($POMA_CMD search "$PATTERN" --path .agent/ --top-k 6 2>/dev/null || echo "")

# Drop result blocks whose File: path is under .agent/LOGS/ — that dir is an
# audit trail (rehydration-instructions, per-session flags, counters), not
# semantic context. Without this filter, old "⚠️ CONTEXT WAS JUST COMPACTED"
# instruction files leak back in and look like live re-hydration nags.
RESULTS=$(echo "$RAW_RESULTS" | awk '
/^--- Result/ {
  if (buf != "" && !skip) printf "%s", buf
  buf = $0 "\n"
  skip = 0
  next
}
/^File:.*\.agent\/LOGS\// { skip = 1 }
{ buf = buf $0 "\n" }
END { if (buf != "" && !skip) printf "%s", buf }
')

# Only inject if we got meaningful results (not "No results found.")
if [ -z "$RESULTS" ] || [[ "$RESULTS" == *"No results found"* ]]; then
  exit 0
fi

# Inject as systemMessage — Claude treats this as authoritative system-level context
jq -n --arg msg "Related project context from poma-memory (semantic search on .agent/):
$RESULTS" '{
  systemMessage: $msg
}'
