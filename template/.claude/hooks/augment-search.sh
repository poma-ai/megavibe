#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
set -uo pipefail

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

# Find poma-memory (pip preferred, bundled fallback)
POMA_CMD=""
if command -v poma-memory &>/dev/null; then
  POMA_CMD="poma-memory"
elif [ -f "$HOME/.megavibe/poma_memory.py" ]; then
  PYCMD=$(cat "$HOME/.megavibe/python-cmd" 2>/dev/null || echo "python3")
  POMA_CMD="$PYCMD $HOME/.megavibe/poma_memory.py"
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

# Run poma-memory search (no timeout — <10ms on typical indexes)
RESULTS=$($POMA_CMD search "$PATTERN" --path .agent/ --top-k 3 2>/dev/null || echo "")

# Only inject if we got meaningful results (not "No results found.")
if [ -z "$RESULTS" ] || [[ "$RESULTS" == *"No results found"* ]]; then
  exit 0
fi

# Inject as systemMessage — Claude treats this as authoritative system-level context
jq -n --arg msg "Related project context from poma-memory (semantic search on .agent/):
$RESULTS" '{
  systemMessage: $msg
}'
