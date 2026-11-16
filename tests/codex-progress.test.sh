#!/bin/bash
# /bin/bash tests/codex-progress.test.sh
# codex-progress.sh reads a Codex rollout (fixture in a scratch CODEX_HOME): selection by
# exact --cwd / --latest / --file, --path refusing ambiguity, --since, no candidate cap,
# a bounded tail, junk lines tolerated. watch-background.sh arms the pinned rollout
# heartbeat for a background Codex command (not the empty .output tail), without
# injecting redirections from the command into the generated loop.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/codex-prog.XXXXXX") || exit 2
trap 'rm -r "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
S="$REPO/scripts/codex-progress.sh"
export CODEX_HOME="$T/codex"
D="$CODEX_HOME/sessions/$(date +%Y/%m/%d)"; mkdir -p "$D"
mk() { # file cwd text
  { printf '{"type":"session_meta","payload":{"cwd":"%s","timestamp":"%s"}}\n' "$2" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    printf '{"type":"turn_context","payload":{"model":"gpt-x"}}\n'
    printf 'junk not json\n'
    printf '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"found %s bug"}]}}\n' "$3"
    printf '{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"cmd\\":\\"ls %s\\"}"}}\n' "$3"
  } > "$1"; }
mk "$D/rollout-a.jsonl" /work/alpha one; sleep 1; mk "$D/rollout-b.jsonl" /work/beta two
o=$("$S" --last 2); [[ "$o" == *"found two bug"* && "$o" == *"ls two"* && "$o" == *"gpt-x"* ]] && ok || bad "latest picks newest and prints message, command, model: $o"
o=$("$S" --cwd /work/alpha --brief); [[ "$o" == idle*"found one bug"* ]] && ok || bad "--cwd selects by recorded cwd: $o"
o=$("$S" --file "$D/rollout-a.jsonl" --brief); [[ "$o" == *"found one bug"* ]] && ok || bad "--file: $o"
"$S" --cwd /nowhere >/dev/null 2>&1; [ $? -eq 1 ] && ok || bad "no match exits 1"
"$S" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok || bad "unknown flag exits 2"
# a rollout larger than the 6 MB tail window still reports the last message
{ cat "$D/rollout-b.jsonl"; for _ in $(seq 1 3000); do printf '{"type":"event_msg","payload":{"type":"token_count","pad":"%02000d"}}\n' 0; done
  printf '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"tail marker"}]}}\n'; } > "$D/rollout-big.jsonl"
o=$("$S" --file "$D/rollout-big.jsonl" --brief); [[ "$o" == *"tail marker"* ]] && ok || bad "big file tail: $o"
# exact cwd, not substring; --path refuses ambiguity; --since skips older jobs; no 40-file cap
mk "$D/rollout-c.jsonl" /work/alpha-other three
[ "$("$S" --cwd /work/alpha --path)" = "$D/rollout-a.jsonl" ] && ok || bad "exact cwd (alpha must not match alpha-other)"
cp "$D/rollout-a.jsonl" "$D/rollout-a2.jsonl"; "$S" --cwd /work/alpha --path >/dev/null 2>&1; [ $? -eq 3 ] && ok || bad "two matches exit 3"
rm "$D/rollout-a2.jsonl"
for i in $(seq 1 45); do mk "$D/rollout-z$i.jsonl" "/work/other$i" x; done
[ "$("$S" --cwd /work/alpha --path)" = "$D/rollout-a.jsonl" ] && ok || bad "matching rollout found behind 45 newer ones"
"$S" --cwd /work/alpha --path --since $(( $(date +%s) + 3600 )) >/dev/null 2>&1; [ $? -ne 0 ] && ok || bad "--since in the future matches nothing"
mk "$D/rollout-q.jsonl" /work/quote "Remaining 08 bytes"; o=$("$S" --file "$D/rollout-q.jsonl" --brief); [[ "$o" == idle*bytes* ]] && ok || bad "brief shape: $o"
# the hook
mkdir -p "$T/p/.agent"
hook() { printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"run_in_background":true,"command":%s,"description":"d"},"tool_response":{"backgroundTaskId":"bt1"}}' "$(printf '%s' "$1" | jq -Rs .)" \
  | (cd "$T/p" && HOME="$T/h" CLAUDE_PROJECT_DIR="$T/p" bash "$REPO/template/.claude/hooks/watch-background.sh") | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null; }
o=$(hook 'codex exec -C /work/alpha go'); [[ "$o" == *"--path --cwd '/work/alpha' --since"* && "$o" == *'--file "$F" --brief'* ]] && ok || bad "hook pins by -C dir: $o"
o=$(hook 'codex exec -C /work/alpha>job.log fixture'); [[ "$o" != *"job.log"* ]] && ok || bad "redirection not injected into the loop: $o"
o=$(hook 'bash ~/.megavibe/scripts/codex-review.sh --as-reviewer x'); [[ "$o" == *"codex-review-scratch"* ]] && ok || bad "review runs use the scratch glob: $o"
o=$(hook 'amass.sh run --provider claude x'); [[ "$o" != *"codex-progress"* ]] && ok || bad "amass is not a Codex rollout job"
o=$(hook 'make test'); [[ "$o" != *"codex-progress"* ]] && ok || bad "non-codex command keeps the output heartbeat"
# the generated loop runs one pinned beat (script from the repo, sleep replaced, since 0)
loop=$(hook 'codex exec -C /work/alpha go' | sed -n '/^P=/p' | sed "s#~/.megavibe/scripts/codex-progress.sh#$S#; s/while sleep [0-9]*; do/for _ in 1; do/; s/--since [0-9]*/--since 0/")
o=$(bash -c "$loop" 2>&1); [[ "$o" == *"codex bt1: +"*"bytes | idle"* ]] && ok || bad "loop runs one pinned beat: $o"
echo "codex-progress tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
