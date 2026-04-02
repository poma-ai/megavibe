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

# Only act if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

VERIFY_SCRIPT=".claude/verify.sh"

# No verify script = no-op
[ -x "$VERIFY_SCRIPT" ] || exit 0

# Require jq for extracting the file path
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -n "$FILE_PATH" ]; then
  if ! "$VERIFY_SCRIPT" "$FILE_PATH" 2>&1; then
    echo "verify.sh failed for: $FILE_PATH" >&2
  fi
fi
