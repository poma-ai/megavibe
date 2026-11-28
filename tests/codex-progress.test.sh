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
hook() { printf '{"hook_event_name":"PostToolUse","session_id":"cp-test-1","tool_name":"Bash","tool_input":{"run_in_background":true,"command":%s,"description":"d"},"tool_response":{"backgroundTaskId":"bt1"}}' "$(printf '%s' "$1" | jq -Rs .)" \
  | (cd "$T/p" && HOME="$T/h" CLAUDE_PROJECT_DIR="$T/p" bash "$REPO/template/.claude/hooks/watch-background.sh") | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null; }
o=$(hook 'codex exec -C /work/alpha go'); [[ "$o" == *"--path  --since"* && "$o" == *'--file "$F" --brief'* && "$o" != *"/work/alpha"* ]] && ok || bad "hook never parses -C, pins by --path: $o"
o=$(hook 'codex exec -C /work/alpha "Check git -C /work/beta status"'); [[ "$o" != *"/work/beta"* ]] && ok || bad "a -C inside prompt text selects nothing: $o"
o=$(hook 'codex exec -C /work/alpha>job.log fixture'); [[ "$o" != *"job.log"* ]] && ok || bad "redirection not injected into the loop: $o"
o=$(hook 'bash ~/.megavibe/scripts/codex-review.sh --as-reviewer x'); [[ "$o" == *"codex-review-scratch"* ]] && ok || bad "review runs use the scratch glob: $o"
o=$(hook 'amass.sh run --provider codex x'); [[ "$o" == *"Background bash task bt1"*"Monitor"* && "$o" != *"codex-progress"* ]] && ok || bad "amass is not a rollout job (and still gets the output heartbeat): $o"
# Since the session-id validation the hook ignores a payload without a valid session_id
# (Claude Code always sends one); every payload above carries one, so a negative check
# above cannot pass on an empty answer.
# The same payload with a session_id is the positive control: it must answer, so the empty
# answer without one comes from the session check and not from the payload or a crash.
o=$(printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"run_in_background":true,"command":"codex exec go","description":"d"},"tool_response":{"backgroundTaskId":"bt9"}}' | (cd "$T/p" && HOME="$T/h" CLAUDE_PROJECT_DIR="$T/p" bash "$REPO/template/.claude/hooks/watch-background.sh")); rc=$?
c=$(hook 'codex exec go'); [ "$rc" -eq 0 ] && [ -z "$o" ] && [[ "$c" == *"codex-progress"* ]] && ok || bad "a payload without session_id is ignored (rc $rc: $o; control: $c)"
o=$(hook 'codex exec --ephemeral -C /work/alpha go'); [[ "$o" != *"codex-progress"* ]] && ok || bad "an ephemeral run writes no rollout"
o=$(hook 'make test'); [[ "$o" != *"codex-progress"* ]] && ok || bad "non-codex command keeps the output heartbeat"
# the generated loop: one match is pinned, two are reported as ambiguous (never one picked)
loop=$(hook 'codex exec -C /work/alpha go' | sed -n '/^P=/p' | sed "s#~/.megavibe/scripts/codex-progress.sh#$S#; s/while sleep [0-9]*; do/for _ in 1; do/; s/--since [0-9]*/--since 0/")
o=$(bash -c "$loop" 2>&1); [[ "$o" == *"codex bt1: codex-progress: ambiguous"* ]] && ok || bad "several fresh rollouts are reported ambiguous: $o"
E="$T/one"; mkdir -p "$E/sessions/$(date +%Y/%m/%d)"; mk "$E/sessions/$(date +%Y/%m/%d)/rollout-only.jsonl" /work/alpha solo
o=$(CODEX_HOME="$E" bash -c "$loop" 2>&1); [[ "$o" == *"codex bt1: +"*"bytes | idle"*"found solo bug"* ]] && ok || bad "a single rollout is pinned: $o"
# a helper path with spaces (HOME) still runs; a subagent's Codex task gets rollout advice
SP="$T/First Last/.megavibe/scripts"; mkdir -p "$SP"; cp "$S" "$SP/codex-progress.sh"
loop2=$(hook 'codex exec -C /work/alpha go' | sed -n '/^P=/p' | sed "s#~/.megavibe/scripts/codex-progress.sh#'$SP/codex-progress.sh'#; s/while sleep [0-9]*; do/for _ in 1; do/; s/--since [0-9]*/--since 0/")
o=$(CODEX_HOME="$E" bash -c "$loop2" 2>&1); [[ "$o" == *"found solo bug"* ]] && ok || bad "helper path with spaces: $o"
o=$(printf '{"hook_event_name":"PostToolUse","session_id":"cp-test-1","tool_name":"Bash","agent_id":"ag1","tool_input":{"run_in_background":true,"command":"codex exec go","description":"d"},"tool_response":{"backgroundTaskId":"bt2"}}' | (cd "$T/p" && HOME="$T/h" CLAUDE_PROJECT_DIR="$T/p" bash "$REPO/template/.claude/hooks/watch-background.sh") | jq -r '.hookSpecificOutput.additionalContext')
[[ "$o" == *"codex-progress.sh --path --since"* ]] && ok || bad "subagent Codex advice: $o"
"$S" --days 0 >/dev/null 2>&1; [ $? -eq 2 ] && ok || bad "--days 0 is a usage error"
o=$(printf '{"hook_event_name":"PostToolUse","session_id":"cp-test-1","tool_name":"Bash","tool_input":{"run_in_background":true,"command":"codex exec go","description":"d"},"tool_response":{"backgroundTaskId":"x'"'"';touch pwn;'"'"'"}}' | (cd "$T/p" && HOME="$T/h" CLAUDE_PROJECT_DIR="$T/p" bash "$REPO/template/.claude/hooks/watch-background.sh") 2>&1)
[ -z "$o" ] && ok || bad "a task id with shell metacharacters gets no generated loop: $o"
# Codex is recognised by the command word of a segment, never by text elsewhere
o=$(hook 'codex exec -C /work/main "Fix scripts/codex-review.sh"'); [[ "$o" == *"codex-progress.sh"* && "$o" != *"codex-review-scratch"* ]] && ok || bad "a prompt naming codex-review.sh does not narrow to review dirs: $o"
o=$(hook "rg 'codex exec' README.md"); [[ "$o" != *"codex-progress"* ]] && ok || bad "a search for the text codex exec is not a Codex job: $o"
o=$(hook 'bash ~/.megavibe/scripts/codex-review.sh --as-reviewer --no-amass "input over 150 KB" --prompt review README.md'); [[ "$o" == *"codex-review-scratch"* ]] && ok || bad "a --no-amass review is still a Codex job: $o"
o=$(hook 'codex exec "Fix amass support"'); [[ "$o" == *"codex-progress.sh"* ]] && ok || bad "a prompt mentioning amass keeps the rollout heartbeat: $o"
o=$(hook 'cd /repo && /bin/bash scripts/codex-review.sh --as-reviewer --prompt-file b.txt > log 2>&1; echo $? > rc'); [[ "$o" == *"codex-review-scratch"* ]] && ok || bad "cd ... && bash codex-review.sh --as-reviewer is a review job: $o"
o=$(hook 'FOO=1 codex exec -s workspace-write -C /w go'); [[ "$o" == *"codex-progress.sh"* && "$o" != *"codex-review-scratch"* ]] && ok || bad "env-prefixed codex exec is a Codex job, not a review: $o"
o=$(hook 'bash scripts/codex-review.sh --prompt x'); [[ "$o" == *"codex-progress.sh"* && "$o" != *"codex-review-scratch"* ]] && ok || bad "a non-reviewer codex-review.sh call is not narrowed: $o"
o=$(hook 'codex exec "Explain the --ephemeral option"'); [[ "$o" == *"codex-progress.sh"* ]] && ok || bad "--ephemeral inside a quoted prompt does not count: $o"
o=$(hook 'bash ~/.megavibe/scripts/codex-review.sh --as-reviewer --strict --prompt x'); [[ "$o" == *"codex-progress.sh"* && "$o" != *"codex-review-scratch"* ]] && ok || bad "--strict review is not narrowed to scratch dirs: $o"
o=$(hook "printf '%s\\n' 'codex exec is documented here'"); [[ "$o" != *"codex-progress"* ]] && ok || bad "printing the text codex exec is not a Codex job: $o"
o=$(hook 'codex exec --ephemeral go'); [[ "$o" != *"codex-progress"* ]] && ok || bad "a real --ephemeral flag still excludes"
o=$(hook 'echo "x; codex exec y"'); [[ "$o" != *"codex-progress"* ]] && ok || bad "a separator inside quotes does not start a Codex segment: $o"
o=$(hook 'bash codex-review.sh --prompt "review it" --as-reviewer --strict'); [[ "$o" == *"codex-progress.sh"* && "$o" != *"codex-review-scratch"* ]] && ok || bad "--strict after a quoted value still counts: $o"
o=$(hook 'codex exec --model "gpt x" --ephemeral go'); [[ "$o" != *"codex-progress"* ]] && ok || bad "--ephemeral after a quoted value still excludes: $o"
o=$(hook "rg '; codex exec' notes.md"); [[ "$o" != *"codex-progress"* ]] && ok || bad "rg for quoted '; codex exec' is not a Codex job: $o"
o=$(hook 'bash codex-review.sh --as-reviewer --no-amass "input over 150 KB" --strict --prompt x'); [[ "$o" == *"codex-progress.sh"* && "$o" != *"codex-review-scratch"* ]] && ok || bad "--strict after a quoted --no-amass reason is seen: $o"
o=$(hook "echo 'a | codex-review.sh --as-reviewer'"); [[ "$o" != *"codex-progress"* ]] && ok || bad "a quoted pipe into codex-review.sh is prose: $o"
o=$(hook '( codex exec -C /work/project "do work" ) > job.log 2>&1; echo $? > job.rc'); [[ "$o" == *"codex-progress.sh"* ]] && ok || bad "a Codex job in a subshell is recognised: $o"
o=$(hook '{ codex exec go; } > job.log'); [[ "$o" == *"codex-progress.sh"* ]] && ok || bad "a Codex job in a { group } is recognised: $o"
o=$(MEGAVIBE_CODEX_SCRATCH=0 hook 'bash scripts/codex-review.sh --as-reviewer --prompt x'); [[ "$o" == *"codex-progress.sh"* && "$o" != *"codex-review-scratch"* ]] && ok || bad "an inherited MEGAVIBE_CODEX_SCRATCH=0 is honoured: $o"
o=$(hook "rg '&&' scripts/codex-review.sh"); [[ "$o" != *"codex-progress"* ]] && ok || bad "a quoted && pattern is not a separator: $o"
o=$(hook '"/bin/bash" scripts/codex-review.sh --as-reviewer --prompt x'); [[ "$o" == *"codex-review-scratch"* ]] && ok || bad "a quoted interpreter path still counts: $o"
o=$(hook "rg ';' scripts/codex-review.sh"); [[ "$o" != *"codex-progress"* ]] && ok || bad "a quoted ; pattern is not a separator: $o"
echo "codex-progress tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
