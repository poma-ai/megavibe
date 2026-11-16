#!/bin/bash
# /bin/bash tests/codex-progress.test.sh
# codex-progress.sh reads a Codex rollout (fixture in a scratch CODEX_HOME): selection by
# --cwd/--latest/--file, last assistant messages and commands, --brief, a partial first
# tail line and junk lines tolerated, no match exits 1. watch-background.sh arms the
# rollout heartbeat (not the .output tail) for a background Codex command.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/codex-prog.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
S="$REPO/scripts/codex-progress.sh"
export CODEX_HOME="$T/codex"
D="$CODEX_HOME/sessions/$(date +%Y/%m/%d)"; mkdir -p "$D"
mk() { # file cwd
  { printf '{"type":"session_meta","payload":{"cwd":"%s"}}\n' "$2"
    printf '{"type":"turn_context","payload":{"model":"gpt-x"}}\n'
    printf 'junk not json\n'
    printf '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"found %s bug"}]}}\n' "$3"
    printf '{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"cmd\\":\\"ls %s\\"}"}}\n' "$3"
  } > "$1"; }
mk "$D/rollout-a.jsonl" /work/alpha one; sleep 1; mk "$D/rollout-b.jsonl" /work/beta two
o=$("$S" --last 2); [[ "$o" == *"found two bug"* && "$o" == *"ls two"* && "$o" == *"gpt-x"* ]] && ok || bad "latest picks newest and prints message, command, model: $o"
o=$("$S" --cwd /work/alpha --brief); [[ "$o" == *"rollout-a.jsonl"* && "$o" == *"found one bug"* ]] && ok || bad "--cwd selects by recorded cwd: $o"
o=$("$S" --file "$D/rollout-a.jsonl" --brief); [[ "$o" == *"rollout-a.jsonl"* ]] && ok || bad "--file: $o"
"$S" --cwd /nowhere >/dev/null 2>&1; [ $? -eq 1 ] && ok || bad "no match exits 1"
"$S" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok || bad "unknown flag exits 2"
# a rollout over the 6 MB tail window still reports the last message
{ cat "$D/rollout-b.jsonl"; for _ in $(seq 1 3000); do printf '{"type":"event_msg","payload":{"type":"token_count","pad":"%02000d"}}\n' 0; done
  printf '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"tail marker"}]}}\n'; } > "$D/rollout-big.jsonl"
sleep 1; touch "$D/rollout-big.jsonl"
o=$("$S" --file "$D/rollout-big.jsonl" --brief); [[ "$o" == *"tail marker"* ]] && ok || bad "big file tail: $o"
# the background-task hook arms the rollout heartbeat for a Codex command, the output tail otherwise
mkdir -p "$T/p/.agent"
hook() { printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"run_in_background":true,"command":"%s","description":"d"},"tool_response":{"backgroundTaskId":"bt1"}}' "$1" \
  | (cd "$T/p" && HOME="$T/h" CLAUDE_PROJECT_DIR="$T/p" bash "$REPO/template/.claude/hooks/watch-background.sh") | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null; }
o=$(hook 'codex exec -C /work/alpha go'); [[ "$o" == *"codex-progress.sh --cwd /work/alpha --brief"* ]] && ok || bad "hook arms codex heartbeat with -C dir: $o"
o=$(hook 'bash ~/.megavibe/scripts/codex-review.sh --as-reviewer x'); [[ "$o" == *"codex-progress.sh --latest --brief"* ]] && ok || bad "hook arms --latest without -C: $o"
o=$(hook 'make test'); [[ "$o" != *"codex-progress"* ]] && ok || bad "non-codex command keeps the output heartbeat"
echo "codex-progress tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
