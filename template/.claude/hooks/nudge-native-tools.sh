#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="nudge-native-tools.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — nudge Claude toward native Read/Grep/Glob when it reaches for
# shell equivalents (cat/head/tail/grep/rg/ls/tree/find/fd).
#
# Triggered by: PreToolUse (Bash). Exit 0 always — never blocks.
# Rationale: transcript analysis across 914 sessions showed ~1M tokens/year
# burned on shell cat/grep/ls/find calls that should have been native tools.
# Native tools are already compact AND trigger augment-search via poma-memory.
#
# Design:
#   * Only nudges on SIMPLE invocations — anything with a pipe, redirect,
#     subshell, or shell operator is left alone (legit shell use).
#   * Dedupes once per category per session (no nag-spam).
#   * Emits systemMessage via JSON stdout (authoritative per decision 65).

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$COMMAND" ] || exit 0

# Skip anything with shell operators — pipelines, redirects, chaining,
# command substitution, subshells, process substitution. These are all
# legitimate reasons to stay in Bash (you can't pipe native tools).
case "$COMMAND" in
  *'|'*|*'>'*|*'<'*|*'&&'*|*'||'*|*';'*|*'$('*|*'`'*|*'<('*|*'>('*)
    exit 0
    ;;
esac

# Classify the command by its leading executable.
# Uses leading-word match to avoid false positives on path substrings.
LEAD=$(echo "$COMMAND" | awk '{print $1}')
CATEGORY=""
SUGGEST=""
case "$LEAD" in
  cat|head|tail|bat|less|more)
    CATEGORY="read"
    SUGGEST="Use the Read tool instead of shell '$LEAD' — Read supports offset/limit and doesn't pipe raw bytes through context."
    ;;
  grep|rg|ripgrep|ack|ag)
    CATEGORY="grep"
    SUGGEST="Use the Grep tool instead of shell '$LEAD' — the Grep tool is compressed and auto-triggers poma-memory augmentation on .agent/ context."
    ;;
  ls|tree|eza|exa)
    CATEGORY="ls"
    SUGGEST="Use the Glob tool instead of shell '$LEAD' — Glob returns compact, mtime-sorted paths and handles recursive patterns like '**/*.ts'."
    ;;
  find|fd|fdfind)
    CATEGORY="find"
    SUGGEST="Use the Glob tool instead of shell '$LEAD' — Glob handles '**/' recursion and name patterns without the verbose find syntax."
    ;;
esac

[ -n "$CATEGORY" ] || exit 0

# Per-session dedup — only nudge once per category per session.
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
SID="${SID:-default}"
NUDGE_DIR=".agent/LOGS"
mkdir -p "$NUDGE_DIR" 2>/dev/null || true
SEEN_FLAG="${NUDGE_DIR}/.nudge-native-${CATEGORY}.${SID}"
if [ -f "$SEEN_FLAG" ]; then
  exit 0
fi
touch "$SEEN_FLAG" 2>/dev/null || true

# Emit nudge as systemMessage. The Bash call still runs — this is advisory.
jq -n --arg msg "[megavibe] $SUGGEST (Bash allowed — this is a one-time nudge per category per session.)" \
  '{systemMessage: $msg}' 2>/dev/null || true

exit 0
