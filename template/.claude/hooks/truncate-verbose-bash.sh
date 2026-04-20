#!/bin/bash
# DO NOT use set -e — hook must be resilient.
_hook_error() {
  local msg="truncate-verbose-bash.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — rewrite known-verbose Bash commands to cap their stdout
# BEFORE the tool runs, via PreToolUse updatedInput.
#
# Rationale: Claude Code PostToolUse hooks cannot modify non-MCP tool
# output (confirmed via hooks-guide audit 2026-04-20). By the time
# PostToolUse fires, the verbose stdout is already in Claude's context.
# The only viable truncation point is PreToolUse input rewriting.
#
# Allowlist is intentionally narrow. Each pattern is a command whose
# trailing lines (or leading lines) are almost always what matters:
#   npm install / npm ci  →  tee full output + tail 50 (errors at end)
#   git log -p [...]      →  head 500 (git stops writing on SIGPIPE)
#
# Triggered by: PreToolUse (Bash). Exit 0 always.
# Skips: any command that already contains a pipe, redirect, compound
#        operator, subshell, or process substitution (user/Claude is
#        already shaping output — don't second-guess).

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL" = "Bash" ] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$COMMAND" ] || exit 0

# Skip any command that already shapes output — user is explicit
case "$COMMAND" in
  *'|'*|*'>'*|*'<'*|*'&&'*|*'||'*|*';'*|*'$('*|*'`'*|*'<('*|*'>('*)
    exit 0
    ;;
esac

# Pattern-match the allowlist. Patterns use exact match OR "<prefix> *"
# (trailing space forces word boundary — avoids e.g. `npm install-test`).
STRATEGY=""
LIMIT=0
case "$COMMAND" in
  "npm install"|"npm install "*|"npm ci"|"npm ci "*)
    STRATEGY="tee-tail"
    LIMIT=50
    ;;
  "git log -p"|"git log -p "*|"git log --all -p"|"git log --all -p "*)
    STRATEGY="head"
    LIMIT=500
    ;;
esac

[ -n "$STRATEGY" ] || exit 0

mkdir -p ".agent/LOGS" 2>/dev/null || true

case "$STRATEGY" in
  tee-tail)
    TS=$(date +%s)
    LOG=".agent/LOGS/bash-${TS}.log"
    NEW_CMD="${COMMAND} 2>&1 | tee ${LOG} | tail -${LIMIT}"
    REASON="[megavibe truncate-verbose-bash] Output capped at ${LIMIT} trailing lines; full output teed to ${LOG} — Read it if you need more. Call Bash with your own pipe if you need a different shape next time."
    ;;
  head)
    NEW_CMD="${COMMAND} | head -${LIMIT}"
    REASON="[megavibe truncate-verbose-bash] Output capped at ${LIMIT} leading lines. Call Bash with your own pipe/pager if you need a larger window."
    ;;
esac

# Emit updatedInput (rewrites tool_input.command for the actual exec)
# plus additionalContext so Claude knows the rewrite happened and how to opt out.
jq -nc --arg cmd "$NEW_CMD" --arg ctx "$REASON" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: {command: $cmd}, additionalContext: $ctx}}'

exit 0
