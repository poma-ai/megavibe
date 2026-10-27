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
# the frontmatter files under .claude/agents, .claude/skills and .claude/commands:
#   - Write: content that mentions PermissionRequest is refused;
#   - Edit and MultiEdit: the edits are applied to the file as it is now, and the result is refused
#     if it mentions PermissionRequest at least as often as the file did (so adding one, splitting
#     the word across two edits, or editing around a hook that is already there are all refused;
#     deleting a hook, which lowers the count, is allowed);
#   - a JSON \u escape in a json write is refused (it can spell the key without the name appearing),
#     and written JSON that parses is checked with its escapes decoded.
# The Bash route (jq, a redirect) is covered by a text rule in block-dangerous-bash.sh. A net, not a
# wall: writing the same configuration with an interpreter one-liner, a plugin install or a second
# Claude Code started with other settings is not caught (README, "Trash greenlight", Not covered).
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
CARRIES=0 ; IS_JSON=0
case "$LOWER_BASE" in
  *settings*.json|hooks.json) CARRIES=1 ; IS_JSON=1 ;;
  *.md) case "$LOWER_PATH" in */.claude/agents/*|*/.claude/skills/*|*/.claude/commands/*) CARRIES=1 ;; esac ;;
esac
[ "$CARRIES" = 1 ] || exit 0

has_key() { grep -qi 'permissionrequest'; }
count_key() { grep -oi 'permissionrequest' | wc -l | tr -d ' '; }

NEW_TEXT=$(printf '%s' "$INPUT" | jq -r '[.tool_input.content, .tool_input.new_string, (.tool_input.edits[]?.new_string)] | map(select(. != null)) | join("\n")' 2>/dev/null || echo "")

BLOCK=""
if [ "$IS_JSON" = 1 ] && printf '%s' "$NEW_TEXT" | grep -q '\\[uU]00'; then
  BLOCK="the new text contains a JSON \\u escape, which can spell PermissionRequest without the name appearing (write the characters themselves)"
elif printf '%s' "$NEW_TEXT" | has_key; then
  BLOCK="the new text mentions PermissionRequest"
elif [ "$IS_JSON" = 1 ] && DECODED=$(printf '%s' "$NEW_TEXT" | jq -r '[(paths | map(tostring) | join(".")), (.. | strings)] | .[]' 2>/dev/null) \
     && printf '%s' "$DECODED" | has_key; then
  BLOCK="the new JSON spells PermissionRequest once its escapes are decoded"
elif [ "$TOOL_NAME" != "Write" ] && [ -f "$FILE_PATH" ]; then
  # Apply the edits to the file as it is now and compare how often the word occurs before and after.
  EDITS=$(printf '%s' "$INPUT" | jq -c 'if .tool_name == "Edit" then [{old_string: .tool_input.old_string, new_string: .tool_input.new_string, replace_all: (.tool_input.replace_all // false)}] else (.tool_input.edits // []) end' 2>/dev/null || echo "[]")
  RESULT=$(jq -rn --rawfile cur "$FILE_PATH" --argjson edits "$EDITS" '
      reduce $edits[] as $e ($cur;
        if ($e.old_string // "") == "" then .
        else (split($e.old_string)) as $p
             | if ($p | length) < 2 then .
               elif ($e.replace_all // false) then ($p | join($e.new_string // ""))
               else ($p[0] + ($e.new_string // "") + ($p[1:] | join($e.old_string)))
               end
        end)' 2>/dev/null || echo "")
  AFTER=$(printf '%s' "$RESULT" | count_key)
  BEFORE=$(count_key < "$FILE_PATH")
  if [ "${AFTER:-0}" -gt 0 ] && [ "${AFTER:-0}" -ge "${BEFORE:-0}" ]; then
    BLOCK="after this edit ${BASENAME} would still configure a PermissionRequest hook (it mentions it ${AFTER} time(s), it did ${BEFORE}), and the edit does not remove one"
  fi
fi
[ -n "$BLOCK" ] || exit 0

REASON="Blocked: ${BLOCK} (${FILE_PATH}). A PermissionRequest hook answers Claude Code's permission prompts for the user, including the one in front of ~/.megavibe/scripts/trash-empty.sh, so it is not something to write on the user's behalf. Ask the user to add or change it themselves, or leave it out."
jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
echo "$REASON" >&2
exit 2
