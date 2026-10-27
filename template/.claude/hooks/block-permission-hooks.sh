#!/bin/bash
# DO NOT use set -e — exit 2 = block, exit 0 = allow, exit 1 = hook error.
set -u

# Megavibe — block writing a PermissionRequest hook into Claude Code's configuration.
# Triggered by: PreToolUse (Write|Edit|MultiEdit)
#
# A PermissionRequest hook is run by Claude Code instead of asking the user, and it can answer
# Yes. That would answer the approval prompt in front of ~/.megavibe/scripts/trash-empty.sh (the
# one script that really deletes) without the human, so trash-empty.sh also refuses to run while
# such a hook is visible in a settings file. This hook is the cheap other half: it refuses the write.
#
# It looks at what is written to a settings file (any *settings*.json), a plugin hooks.json, and
# the frontmatter files under .claude/agents, .claude/skills and .claude/commands: new text that
# mentions PermissionRequest is refused, and so is any other edit to a file that already
# configures one (remove it by hand). The Bash route (jq, a redirect) is covered by a text rule in
# block-dangerous-bash.sh. A net, not a wall: writing the same configuration with an interpreter
# one-liner, a plugin install or a second Claude Code started with other settings is not caught
# (README, "Trash greenlight", Not covered).
#
# Runs in every project it is registered in (safety is not project-specific): no .agent guard.
# No-op when jq is missing.

command -v jq &>/dev/null || exit 0

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0

BASENAME="${FILE_PATH##*/}"
LOWER_PATH=$(printf '%s' "$FILE_PATH" | tr '[:upper:]' '[:lower:]')
LOWER_BASE=$(printf '%s' "$BASENAME" | tr '[:upper:]' '[:lower:]')
CARRIES=0
case "$LOWER_BASE" in
  *settings*.json|hooks.json) CARRIES=1 ;;
  *.md) case "$LOWER_PATH" in */.claude/agents/*|*/.claude/skills/*|*/.claude/commands/*) CARRIES=1 ;; esac ;;
esac
[ "$CARRIES" = 1 ] || exit 0

NEW_TEXT=$(printf '%s' "$INPUT" | jq -r '[.tool_input.content, .tool_input.new_string, (.tool_input.edits[]?.new_string)] | map(select(. != null)) | join("\n")' 2>/dev/null || echo "")
OLD_TEXT=$(printf '%s' "$INPUT" | jq -r '[.tool_input.old_string, (.tool_input.edits[]?.old_string)] | map(select(. != null)) | join("\n")' 2>/dev/null || echo "")

BLOCK=""
if printf '%s' "$NEW_TEXT" | grep -qi 'permissionrequest'; then
  BLOCK="the new text mentions PermissionRequest"
elif [ "$TOOL_NAME" != "Write" ] && [ -f "$FILE_PATH" ] && grep -qi 'permissionrequest' "$FILE_PATH" 2>/dev/null \
     && ! printf '%s' "$OLD_TEXT" | grep -qi 'permissionrequest'; then
  BLOCK="$BASENAME already configures a PermissionRequest hook, and this edit does not remove it"
fi
[ -n "$BLOCK" ] || exit 0

REASON="Blocked: ${BLOCK} (${FILE_PATH}). A PermissionRequest hook answers Claude Code's permission prompts for the user, including the one in front of ~/.megavibe/scripts/trash-empty.sh, so it is not something to write on the user's behalf. Ask the user to add or change it themselves, or leave it out."
jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
echo "$REASON" >&2
exit 2
