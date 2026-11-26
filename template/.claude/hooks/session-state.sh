#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
# What a dispatched session is doing right now: thinking, working (with the tool), waiting for you, idle, ended.
# `megavibe dispatch` shows it in the cockpit, in `status` and in `tick`, so a session that needs an answer is seen without
# attaching to every window. Registered for UserPromptSubmit, PreToolUse, PostToolUse(Failure), Notification, Stop and
# SessionEnd with the event named in Claude Code's payload (hook_event_name).
# Only sessions that dispatch started carry MEGAVIBE_DISPATCH_QUEUE; any other session returns at the first line, before
# reading anything, so the hook costs nothing outside manager mode. Advisory: always exits 0, prints nothing.
#
# State file: $MEGAVIBE_HOME/status/<session id>, one line: <epoch now> <state> <epoch the state began> <detail>, tab separated.
# Metadata only: the tool name and a short, control-stripped hint of its command or file, never output or prompts.

[ -n "${MEGAVIBE_DISPATCH_QUEUE:-}" ] || exit 0
[ -d "${CLAUDE_PROJECT_DIR:-.}/.agent" ] || exit 0
command -v jq &>/dev/null || exit 0

INFO=$(cat | jq -r '[(.hook_event_name // "" | tostring), (.session_id // "" | tostring), (.tool_name // ""), ((.tool_input.command // .tool_input.file_path // .tool_input.pattern // .tool_input.url // .tool_input.description // "") | tostring), (.message // "" | tostring)] | map(gsub("[\u0001-\u001f]"; " ")) | join("\u001f")' 2>/dev/null) || exit 0
# a unit separator, not a tab: tab is whitespace to `read`, so an empty tool name would swallow its delimiter and shift the fields
IFS=$'\037' read -r HEV SID TOOL HINT MSG <<< "$INFO"
# the event comes from Claude Code's own payload (init.sh quotes a registered command as one word, so it cannot carry an argument);
# an explicit argument, used by the tests, overrides it
EVENT="${1:-}"
if [ -z "$EVENT" ]; then
  case "$HEV" in UserPromptSubmit) EVENT=prompt ;; PreToolUse) EVENT=pre ;; PostToolUse|PostToolUseFailure) EVENT=post ;; Notification) EVENT=notify ;; Stop) EVENT=stop ;; SessionEnd) EVENT=end ;; esac
fi
[[ $SID =~ ^[0-9A-Za-z-]{8,64}$ ]] || exit 0

STATE=""; DETAIL=""
clean() { printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-"${2:-60}"; }
case "$EVENT" in
  prompt) STATE=thinking ;;
  pre)
    case "$TOOL" in
      AskUserQuestion) STATE=input; DETAIL="a question for you" ;;
      *) STATE=working; DETAIL=$(clean "$TOOL${HINT:+ $HINT}") ;;
    esac ;;
  post) STATE=thinking ;;
  notify)
    # Claude Code's notification for a permission prompt; the idle-prompt notice is not news (Stop already said idle)
    case "$MSG" in *ermission*|*approv*|*"needs your"*) STATE=input; DETAIL=$(clean "$MSG") ;; *) exit 0 ;; esac ;;
  stop) STATE=idle ;;
  end) STATE=ended ;;
  *) exit 0 ;;
esac

DIR="${MEGAVIBE_HOME:-$HOME/.megavibe}/status"
mkdir -p "$DIR" 2>/dev/null && chmod 700 "$DIR" 2>/dev/null
[ -d "$DIR" ] || exit 0
F="$DIR/$SID"; NOW=$(date +%s); SINCE=$NOW
if [ -f "$F" ] && [ ! -L "$F" ]; then
  IFS=$'\t' read -r _ OLD OLDSINCE _ < "$F" 2>/dev/null
  [ "$OLD" != "$STATE" ] || { [[ $OLDSINCE =~ ^[0-9]+$ ]] && SINCE="$OLDSINCE"; }
fi
if [ "$STATE" = ended ]; then rm -f "$F" 2>/dev/null; exit 0; fi
printf '%s\t%s\t%s\t%s\n' "$NOW" "$STATE" "$SINCE" "$DETAIL" > "$F.$$" 2>/dev/null && mv -f "$F.$$" "$F" 2>/dev/null
exit 0
