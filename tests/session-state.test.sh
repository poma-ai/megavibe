#!/bin/bash
# /bin/bash tests/session-state.test.sh
# template/.claude/hooks/session-state.sh: the state file a dispatched session leaves for `megavibe dispatch`.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
H="$REPO/template/.claude/hooks/session-state.sh"
command -v jq >/dev/null || { echo "skip: jq not installed"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/session-state-test.XXXXXX") || exit 2
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
mkdir -p "$T/proj/.agent" "$T/mv"
SID=11111111-2222-3333-4444-555555555555; F="$T/mv/status/$SID"
run() { # run EVENT JSON [extra env...]
  local ev="$1" json="$2"; shift 2
  printf '%s' "$json" | env CLAUDE_PROJECT_DIR="$T/proj" MEGAVIBE_HOME="$T/mv" "$@" bash "$H" "$ev"; echo $? > "$T/rc"
}
field() { awk -F'\t' -v c="$1" '{ print $c }' "$F"; }

run pre '{"session_id":"'$SID'","tool_name":"Bash","tool_input":{"command":"npm test"}}' MEGAVIBE_DISPATCH_QUEUE=q
check "pre: working with the tool and its command" '[ "$(cat "$T/rc")" = 0 ] && [ "$(field 2)" = working ] && [ "$(field 4)" = "Bash npm test" ]'
S0=$(field 3)
run post '{"session_id":"'$SID'","tool_name":"Bash"}' MEGAVIBE_DISPATCH_QUEUE=q
check "post: thinking again" '[ "$(field 2)" = thinking ]'
check "since moves with the state" '[ "$(field 3)" -ge "$S0" ]'
SINCE=$(field 3); sleep 1
run pre '{"session_id":"'$SID'","tool_name":"Read","tool_input":{"file_path":"/a/b"}}' MEGAVIBE_DISPATCH_QUEUE=q
run pre '{"session_id":"'$SID'","tool_name":"Read","tool_input":{"file_path":"/a/c"}}' MEGAVIBE_DISPATCH_QUEUE=q
check "the same state twice keeps its start time" '[ "$(field 2)" = working ] && [ "$(field 3)" -gt "$SINCE" ] && [ "$(field 1)" -ge "$(field 3)" ]'
run notify '{"session_id":"'$SID'","message":"Claude needs your permission to use Bash"}' MEGAVIBE_DISPATCH_QUEUE=q
check "permission notification: input with the message" '[ "$(field 2)" = input ] && [[ "$(field 4)" == *permission* ]]'
run notify '{"session_id":"'$SID'","message":"Claude is waiting for your input"}' MEGAVIBE_DISPATCH_QUEUE=q
check "idle-prompt notification changes nothing" '[ "$(field 2)" = input ]'
run pre '{"session_id":"'$SID'","tool_name":"AskUserQuestion","tool_input":{}}' MEGAVIBE_DISPATCH_QUEUE=q
check "AskUserQuestion: input" '[ "$(field 2)" = input ]'
run stop '{"session_id":"'$SID'"}' MEGAVIBE_DISPATCH_QUEUE=q
check "stop: idle" '[ "$(field 2)" = idle ]'
run prompt '{"session_id":"'$SID'"}' MEGAVIBE_DISPATCH_QUEUE=q
check "prompt: thinking" '[ "$(field 2)" = thinking ]'
run pre '{"session_id":"'$SID'","tool_name":"Bash","tool_input":{"command":"printf \"a\\nb\\tc\"; echo \u001b[31mred"}}' MEGAVIBE_DISPATCH_QUEUE=q
check "one line, no control characters, capped" '[ "$(wc -l < "$F" | tr -d " ")" = 1 ] && ! LC_ALL=C grep -q "$(printf "\033")" "$F" && [ "$(field 4 | wc -c | tr -d " ")" -le 62 ]'
run end '{"session_id":"'$SID'"}' MEGAVIBE_DISPATCH_QUEUE=q
check "end: the file goes" '[ ! -e "$F" ]'

# the event from Claude Code's own payload, with no argument (how init.sh registers it)
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"'$SID'","tool_name":"Grep","tool_input":{"pattern":"foo"}}' | env CLAUDE_PROJECT_DIR="$T/proj" MEGAVIBE_HOME="$T/mv" MEGAVIBE_DISPATCH_QUEUE=q bash "$H"
check "hook_event_name PreToolUse without an argument: working" '[ "$(field 2)" = working ] && [ "$(field 4)" = "Grep foo" ]'
printf '%s' '{"hook_event_name":"Stop","session_id":"'$SID'"}' | env CLAUDE_PROJECT_DIR="$T/proj" MEGAVIBE_HOME="$T/mv" MEGAVIBE_DISPATCH_QUEUE=q bash "$H"
check "hook_event_name Stop without an argument: idle" '[ "$(field 2)" = idle ]'
printf '%s' '{"hook_event_name":"SessionEnd","session_id":"'$SID'"}' | env CLAUDE_PROJECT_DIR="$T/proj" MEGAVIBE_HOME="$T/mv" MEGAVIBE_DISPATCH_QUEUE=q bash "$H"
check "hook_event_name SessionEnd: the file goes" '[ ! -e "$F" ]'

# no-ops: outside dispatch, outside a megavibe project, a bad session id, a symlinked state file, an unknown event
run pre '{"session_id":"'$SID'","tool_name":"Bash"}'
check "without MEGAVIBE_DISPATCH_QUEUE nothing is written" '[ "$(cat "$T/rc")" = 0 ] && [ ! -e "$F" ]'
printf '%s' '{"session_id":"'$SID'","tool_name":"Bash"}' | env CLAUDE_PROJECT_DIR="$T/none" MEGAVIBE_HOME="$T/mv" MEGAVIBE_DISPATCH_QUEUE=q bash "$H" pre
check "without .agent/ nothing is written" '[ ! -e "$F" ]'
run pre '{"session_id":"../../x","tool_name":"Bash"}' MEGAVIBE_DISPATCH_QUEUE=q
check "a session id with a path in it is refused" '[ "$(cat "$T/rc")" = 0 ] && [ -z "$(ls "$T/mv/status" 2>/dev/null)" ]'
run bogus '{"session_id":"'$SID'"}' MEGAVIBE_DISPATCH_QUEUE=q
check "an unknown event writes nothing" '[ ! -e "$F" ]'
mkdir -p "$T/mv/status"; ln -s "$T/elsewhere" "$F"
run pre '{"session_id":"'$SID'","tool_name":"Bash"}' MEGAVIBE_DISPATCH_QUEUE=q
check "a symlink in the state dir is replaced, never written through" '[ ! -e "$T/elsewhere" ]'
printf 'not json' | env CLAUDE_PROJECT_DIR="$T/proj" MEGAVIBE_HOME="$T/mv" MEGAVIBE_DISPATCH_QUEUE=q bash "$H" pre; rc=$?
check "garbage on stdin exits 0" '[ $rc = 0 ]'
check "hook is executable and prints nothing" '[ -x "$H" ] && [ -z "$(printf "%s" "{\"session_id\":\"$SID\"}" | env CLAUDE_PROJECT_DIR="$T/proj" MEGAVIBE_HOME="$T/mv" MEGAVIBE_DISPATCH_QUEUE=q bash "$H" stop)" ]'

# registered in the template for every event it needs
for ev in UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure Notification Stop SessionEnd; do
  check "template settings register it for $ev" 'jq -e --arg e "$ev" "[.hooks[\$e][]?.hooks[]?.command] | any(test(\"session-state.sh\"))" "$REPO/template/.claude/settings.json" >/dev/null'
done
check "init.sh installs it" 'grep -q "session-state.sh" "$REPO/init.sh"'

rm -r "$T"
printf '%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
