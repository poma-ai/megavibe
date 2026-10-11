#!/bin/bash
_hook_error() {
  local msg="after-edit.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  jq -n --arg msg "$msg" '{systemMessage: $msg}' 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — run project-defined verification after file edits
# Triggered by: PostToolUse (Edit|Write)
# Runs .claude/verify.sh if it exists in the project. No-op otherwise.
#
# To enable: create .claude/verify.sh in your project with your lint/format/test commands.
# Example .claude/verify.sh:
#   #!/bin/bash
#   npx prettier --write "$1"   # $1 = the edited file path
#   npx eslint "$1"
#
# A ready-made example ships alongside this hook as .claude/verify.sh.example — it
# strips invisible/exotic Unicode from edited text files. Enable it with:
#   cp .claude/verify.sh.example .claude/verify.sh && chmod +x .claude/verify.sh

# Only act if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

VERIFY_SCRIPT=".claude/verify.sh"

# No verify script = no-op
[ -x "$VERIFY_SCRIPT" ] || exit 0

# Require jq for extracting the file path
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# A PostToolUse hook's plain stdout and its stderr on exit 0 reach neither the
# model nor, by default, the user, so a failing verify.sh used to go unseen.
# Its failure goes to the model as additionalContext (tail-capped well under
# the 10,000-character limit) and to the user as a one-line systemMessage.
if [ -n "$FILE_PATH" ]; then
  if ! VOUT=$("$VERIFY_SCRIPT" "$FILE_PATH" 2>&1); then
    VOUT=$(printf '%s' "$VOUT" | tail -c 4000)
    jq -n --arg ctx "verify.sh failed for ${FILE_PATH}. Fix this before moving on. Output (last 4000 bytes):
${VOUT}" --arg msg "megavibe: verify.sh failed for ${FILE_PATH}" \
      '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}' 2>/dev/null || true
  fi
fi
