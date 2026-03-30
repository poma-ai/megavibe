#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
set -uo pipefail

# Megavibe — augment Grep with poma-memory vector search
# Triggered by: PreToolUse (Grep)
#
# When Claude searches for something, this hook silently runs a poma-memory
# search with the same query and injects any relevant .agent/ context as
# additionalContext. Claude sees both native Grep results + semantic matches.
#
# This makes project context automatically available during exploration
# without Claude needing to explicitly call poma-memory.
#
# Performance: model2vec semantic search on <10K vectors takes <10ms.
# No timeout needed (macOS lacks `timeout` command — was silently breaking this hook).

# Only run if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Find poma-memory (bundled preferred, pip fallback)
POMA_SCRIPT="$HOME/.megavibe/poma_memory.py"
POMA_CMD=""
PYCMD=$(cat "$HOME/.megavibe/python-cmd" 2>/dev/null || echo "python3")
if [ -f "$POMA_SCRIPT" ]; then
  POMA_CMD="$PYCMD $POMA_SCRIPT"
elif command -v poma-memory &>/dev/null; then
  POMA_CMD="poma-memory"
else
  exit 0
fi

# Check index exists (no point searching an empty index)
[ -f ".agent/.poma-memory.db" ] || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // ""' 2>/dev/null || echo "")

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

# Inject as additionalContext — Claude sees this alongside Grep results
jq -n --arg ctx "📎 Related project context (from .agent/ memory):
$RESULTS" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $ctx
  }
}'
