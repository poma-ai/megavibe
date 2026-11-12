#!/bin/bash
# /bin/bash tests/amass.test.sh
# scripts/amass.sh against FAKE claude (AMASS_CLAUDE) and codex (PATH): nothing
# here calls a real model or sends anything. The fake records the flags, the environment and the prompt of
# every call, so the safety properties (no tools, no settings, no API key, bounded input,
# lens last, identical prefix for copies) are asserted, not assumed.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
AM="$REPO/scripts/amass.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/amass-test.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap '/bin/rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; [ -z "${AMASS_TEST_DEBUG:-}" ] || printf '%s\n' "--- out: ${out:-}" >&2; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

command -v jq >/dev/null 2>&1 && command -v perl >/dev/null 2>&1 || { echo "SKIP: needs jq and perl"; exit 0; }

# The fake: logs argv/env/prompt per call under $FAKE_LOG, answers by $FAKE_MODE.
cat > "$T/fake-claude" <<'EOF'
#!/bin/bash
. "$(dirname "$0")/conf.sh" 2>/dev/null || true
if [ "${1:-}" = auth ]; then
  [ -z "${FAKE_LOG:-}" ] || env | cut -d= -f1 | sort >> "$FAKE_LOG/auth_envnames"
  case "${FAKE_AUTH:-sub}" in
    apikey) echo '{"loggedIn":true,"authMethod":"apiKey"}' ;;
    broken) exit 1 ;;
    *) echo '{"loggedIn":true,"authMethod":"claude.ai"}' ;;
  esac
  exit 0
fi
n=$(ls "$FAKE_LOG" 2>/dev/null | grep -c '^call_')
id=$((n + 1)); d="$FAKE_LOG/call_$id.$$"; mkdir -p "$d"
printf '%s\n' "$@" > "$d/argv"
printf '%s\n' "${ANTHROPIC_API_KEY:-<unset>}" > "$d/apikey"
printf '%s\n' "${CLAUDE_CODE_USE_BEDROCK:-<unset>}" > "$d/bedrock"
pwd > "$d/cwd"
env | cut -d= -f1 | sort > "$d/envnames"
cat > "$d/prompt"
if [ -n "${FAKE_DEDUPE_FAIL:-}" ] && grep -q 'dedupe stage' "$d/prompt"; then echo "boom" >&2; exit 1; fi
case "${FAKE_MODE:-ok}" in
  nul) jq -n '[{"type":"result","is_error":false,"result":"F1 | P1 | a:1 | before\u0000after | why\nF2 | P2 | a:2 | ok | why","total_cost_usd":0.005}]'; exit 0 ;;
  fail) echo "boom" >&2; exit 1 ;;
  slow) sleep 6 ;;
  hang) echo $$ > "$d/pid"; sleep 30 & echo $! > "$d/child"; wait; exit 0 ;;
  garbled) echo "not json"; exit 0 ;;
  iserror) printf '[{"type":"result","is_error":true,"result":"x","total_cost_usd":0.1}]'; exit 0 ;;
  markdown) jq -n '[{"type":"result","is_error":false,"result":"F1 | P2 | a.sh:1 | plain | because\n- **F2** | P1 | a.sh:9 | bold bullet | because\na stray continuation line","total_cost_usd":0.005}]'; exit 0 ;;
  prose) jq -n '[{"type":"result","is_error":false,"result":"I looked at it and found nothing wrong.","total_cost_usd":0.004}]'; exit 0 ;;
esac
if grep -q 'dedupe stage' "$d/prompt"; then
  ids=$(grep -E '^[A-Za-z0-9_-]+_[0-9]+\.F[0-9]+ \|' "$d/prompt" | cut -d' ' -f1)
  case "${FAKE_DEDUPE:-all}" in
    all) body=$(printf 'C1 | P2 | everything | members: %s\n' "$(echo "$ids" | paste -sd, -)") ;;
    partial) first=$(echo "$ids" | head -1); body=$(printf 'C1 | P2 | only first | members: %s\n' "$first") ;;
    dup) first=$(echo "$ids" | head -1); body=$(printf 'C1 | P2 | all | members: %s\nC2 | P2 | again | members: %s\n' "$(echo "$ids" | paste -sd, -)" "$first") ;;
    inflate) body=$(cat <<'INFLATE'
C1 | P2 | one finding listed three times | members: x_1.F1,x_1.F1,x_1.F1
C2 | P2 | two distinct findings | members: y_1.F1,y_1.F2
C3 | P2 | only invented ids | members: ghost_1.F1,ghost_1.F2,ghost_1.F3
INFLATE
    ) ;;
    clusters) body=$(cat <<'CLUSTERS'
C9 | P2 | vague concern | members: , , [no-input]
C2 | P1 | another vague concern | members: y_1.F2,y_2.F1,y_2.F2 [no-input]
C8 | P2 | no members supplied [no-input]
C7 | P2 | call("a|b", n=7) returns "[no-input]" | members: whole_1.F1,whole_1.F2,x_1.F1,x_1.F2
C10 | P1 | call(0) fails | members: x_2.F1,x_2.F2,y_1.F1
CLUSTERS
    ) ;;
  esac
  jq -n --arg r "$body" '[{"type":"system"},{"type":"result","is_error":false,"result":$r,"total_cost_usd":0.01}]'
else
  jq -n '[{"type":"system"},{"type":"result","is_error":false,"result":"F1 | P2 | a.sh:1 | boom on empty input | because\nF2 | P1 | a.sh:9 | race | because","total_cost_usd":0.005}]'
fi
EOF
chmod +x "$T/fake-claude"
# the same fake with every cost field removed (a response without cost metadata)
cat > "$T/fake-nocost" <<'EOF'
#!/bin/bash
B=$(dirname "$0")/fake-claude
if [ "${1:-}" = auth ]; then exec "$B" "$@"; fi
"$B" "$@" | jq -c 'map(del(.total_cost_usd))'
EOF
chmod +x "$T/fake-nocost"
export FAKE_BASE="$T/fake-claude"
export AMASS_CLAUDE="$T/fake-claude" AMASS_STAGGER=0
export AMASS_LEDGER="$T/ledger.jsonl"
# The default provider is auto, which would pick up any real codex on this machine and read the real usage
# history: until section 11 installs a fake codex, codex is absent, and usage-route is a stub that prints
# whatever PACE_CLAUDE / PACE_CODEX hold (empty: unknown; PACE_FAIL=1: the probe fails).
export AMASS_CODEX="$T/no-such-codex"
cat > "$T/usage-stub" <<'STUB'
#!/bin/bash
[ -z "${PACE_FAIL:-}" ] || exit 1
case "${MEGAVIBE_ROUTER_PROVIDER:-}" in
  claude) [ -z "${PACE_CLAUDE:-}" ] || printf '%s\n' "$PACE_CLAUDE" ;;
  codex) [ -z "${PACE_CODEX:-}" ] || printf '%s\n' "$PACE_CODEX" ;;
esac
exit 0
STUB
chmod +x "$T/usage-stub"
export MEGAVIBE_AMASS_USAGE_ROUTE="$T/usage-stub"
unset PACE_CLAUDE PACE_CODEX PACE_FAIL MEGAVIBE_AMASS_SPLIT
# pace LINEAR RECENT USED -> a usage-route.sh pace line (provider|used|elapsed|linear|rate|recent|remaining)
pace() { printf 'x|%s|50|%s|1|%s|3' "$3" "$1" "$2"; }
export ANTHROPIC_API_KEY=example-placeholder-not-a-key CLAUDE_CODE_USE_BEDROCK=1
export ANTHROPIC_CUSTOM_HEADERS=$'Authorization:\nx-api-key: example-placeholder' ANTHROPIC_FOUNDRY_API_KEY=example AWS_BEARER_TOKEN_BEDROCK=example ANTHROPIC_FUTURE_SWITCH=1 CLAUDE_CODE_USE_ANYTHING=1

printf 'alpha\nbeta\n' > "$T/a.txt"; printf 'gamma\n' > "$T/b.txt"

# The worker runs in an allow-listed environment, so the fake cannot be steered through environment
# variables. It reads its settings from conf.sh next to it; fk writes them for one command, then resets.
defconf() { { printf 'export FAKE_LOG=%q\n' "${FAKE_LOG:-}"; printf 'export FAKE_OUTSIDE=%q\n' "${FAKE_OUTSIDE:-}"; } > "$T/conf.sh"; }
fk() {
  defconf
  while [ "$1" != -- ]; do printf 'export %s=%q\n' "${1%%=*}" "${1#*=}" >> "$T/conf.sh"; shift; done
  shift
  "$@"; local rc=$?
  defconf
  return $rc
}
newlog() { FAKE_LOG="$T/log.$1"; export FAKE_LOG; rm -rf "$FAKE_LOG"; mkdir -p "$FAKE_LOG"; defconf; }
calls() { ls "$FAKE_LOG" | grep -c '^call_'; }

# 1. syntax and bash 3.2
check "bash -n" '/bin/bash -n "$AM"'
check "no bashisms past 3.2 (mapfile/readarray/declare -A/wait -n)" '! grep -nE "mapfile|readarray|declare -A|wait -n|\$\{[A-Za-z_]+,,\}" "$AM"'

# 2. dry run sends nothing
newlog 1
out=$("$AM" run --out "$T/o1" --change "c" --lens x=text1 --lens y=text2 --copies 2 --whole 1 --dry-run "$T/a.txt" 2>&1); rc=$?
check "dry run exits 0" '[ $rc -eq 0 ]'
check "dry run sent nothing" '[ "$(calls)" = 0 ]'
check "dry run reports 3 prompts / 5 calls" 'echo "$out" | grep -q "3 prompts, 5 calls"'

# 3. real run through the fake
newlog 2
out=$("$AM" run --out "$T/o2" --change "a change" --lens x=text1 --lens y=text2 --copies 2 --whole 1 "$T/a.txt" "$T/b.txt" 2>&1); rc=$?
check "run exits 0" '[ $rc -eq 0 ]'
check "5 calls made" '[ "$(calls)" = 5 ]'
check "summary: 5 ok, worker cost 0.025" 'echo "$out" | grep -q "runs 5, ok 5, failed 0" && echo "$out" | grep -q "worker cost \$0.0250"'
check "the ledger got one run line without any key material" 'grep -c "\"cmd\":\"run\"" "$AMASS_LEDGER" | grep -qx 1 && ! grep -q "example-placeholder" "$AMASS_LEDGER" && jq -e ".calls == 5 and .ok == 5 and .model == \"haiku\"" "$AMASS_LEDGER" >/dev/null'
check "findings counted (2 per run)" '[ "$(awk -F"\t" "{s+=\$4} END{print s}" "$T/o2/runs.tsv")" = 10 ]'
check "list files written" '[ -s "$T/o2/lists/x_1.md" ] && [ -s "$T/o2/lists/whole_1.md" ]'
first=$(ls -d "$FAKE_LOG"/call_* | head -1)
check "no tools" 'grep -qx -- "--tools" "$first/argv" && sed -n "/^--tools\$/{n;p;}" "$first/argv" | grep -qx ""'
check "no settings sources" 'sed -n "/^--setting-sources\$/{n;p;}" "$first/argv" | grep -qx ""'
check "strict mcp, no session, no slash commands" 'grep -qx -- "--strict-mcp-config" "$first/argv" && grep -qx -- "--no-session-persistence" "$first/argv" && grep -qx -- "--disable-slash-commands" "$first/argv"'
check "json output and model haiku" 'grep -qx -- "json" "$first/argv" && sed -n "/^--model\$/{n;p;}" "$first/argv" | grep -qx haiku'
check "API key and cloud switch removed from every call" '[ "$(cat "$FAKE_LOG"/call_*/apikey | sort -u)" = "<unset>" ] && [ "$(cat "$FAKE_LOG"/call_*/bedrock | sort -u)" = "<unset>" ]'
check "the worker sees an allow-listed environment: no ANTHROPIC, AWS or cloud-switch variable, PATH and HOME present" '! cat "$FAKE_LOG"/call_*/envnames | grep -qE "ANTHROPIC|AWS_|CLAUDE_CODE_USE" && grep -qx PATH "$first/envnames" && grep -qx HOME "$first/envnames"'
check "the login check runs in the same allow-listed environment" '[ -s "$FAKE_LOG/auth_envnames" ] && ! grep -qE "ANTHROPIC|AWS_|CLAUDE_CODE_USE" "$FAKE_LOG/auth_envnames"'
check "calls run in the empty work dir, not the caller dir" '[ "$(cat "$first/cwd")" = "$T/o2/work" ]'
check "files inlined, in order" 'grep -q "===== FILE $T/a.txt =====" "$first/prompt" && grep -q "alpha" "$first/prompt" && grep -q "gamma" "$first/prompt"'
check "lens text is last" 'tail -2 "$FAKE_LOG"/call_*/prompt | grep -q "Report only defects that fit this lens: text1"'
bl=$(wc -c < "$T/o2/base.txt" | tr -d ' ')
check "every prompt starts with the byte-identical shared base (cache sharing)" 'head -c "$bl" "$T/o2/prompts/x.txt" | cmp -s - "$T/o2/base.txt" && head -c "$bl" "$T/o2/prompts/y.txt" | cmp -s - "$T/o2/base.txt" && head -c "$bl" "$T/o2/prompts/whole.txt" | cmp -s - "$T/o2/base.txt"'
check "the two copies of a lens received the same bytes" 'a=$(grep -l text1 "$FAKE_LOG"/call_*/prompt | sed -n 1p); b=$(grep -l text1 "$FAKE_LOG"/call_*/prompt | sed -n 2p); [ -n "$a" ] && [ -n "$b" ] && cmp -s "$a" "$b"'
check "summary subcommand agrees" '"$AM" summary --out "$T/o2" | grep -q "runs 5, ok 5"'

# 4. dedupe
out=$("$AM" dedupe --out "$T/o2" 2>&1); rc=$?
check "dedupe exits 0" '[ $rc -eq 0 ]'
check "dedupe: all ids covered, none re-added" 'echo "$out" | grep -q "0 findings omitted by the model" && echo "$out" | grep -q "0 duplicated ids"'
check "dedupe prompt lists 10 findings with run-qualified ids" '[ "$(grep -c "^[a-z]*_[0-9]*\.F[0-9]* |" "$T/o2/dedupe_in.txt")" = 10 ]'
check "old marker-free dedupe shape gets a member count" 'grep -qx "C1 | P2 | n=10 | everything | members: whole_1.F1,whole_1.F2,x_1.F1,x_1.F2,x_2.F1,x_2.F2,y_1.F1,y_1.F2,y_2.F1,y_2.F2" "$T/o2/clusters.md"'
rm -rf "$T/o2/dedupe_"* "$T/o2/clusters"* "$T/o2/members_"*
out=$(fk FAKE_DEDUPE=partial -- "$AM" dedupe --out "$T/o2" 2>&1)
check "omitted ids are re-added in a CUNK cluster (nothing lost)" 'echo "$out" | grep -q "9 findings omitted" && grep -q "^CUNK" "$T/o2/clusters.md" && [ "$(grep -o "_[0-9]*\.F[0-9]*" "$T/o2/clusters.md" | wc -l | tr -d " ")" = 10 ]'
check "the fallback cluster is counted and sorted too" 'head -1 "$T/o2/clusters.md" | grep -q "^CUNK | ? | n=9 |"'
rm -rf "$T/o2/dedupe_"* "$T/o2/clusters"* "$T/o2/members_"*
out=$(fk FAKE_DEDUPE=dup -- "$AM" dedupe --out "$T/o2" 2>&1)
check "duplicated ids are reported" 'echo "$out" | grep -q "1 duplicated ids"'
rm -rf "$T/o2/dedupe_"* "$T/o2/clusters"* "$T/o2/members_"*
out=$(fk FAKE_DEDUPE=inflate -- "$AM" dedupe --out "$T/o2" 2>&1)
check "n counts distinct findings: a finding listed three times is n=1, not n=3" 'grep -q "^C1 | P2 | n=1 |" "$T/o2/clusters.md"'
check "invented ids are not support: n=0" 'grep -q "^C3 | P2 | n=0 |" "$T/o2/clusters.md"'
check "a cluster with two distinct findings outranks one finding repeated" '[ "$(grep -n "^C2 " "$T/o2/clusters.md" | cut -d: -f1)" -lt "$(grep -n "^C1 " "$T/o2/clusters.md" | cut -d: -f1)" ]'
check "the original references and diagnostics are kept" 'grep -q "^C1 .*members: x_1.F1,x_1.F1,x_1.F1" "$T/o2/clusters.md" && echo "$out" | grep -q "unknown ids"'

# 5. refusals and failures
newlog 3
"$AM" run --out "$T/o3" --lens x=t --max-input-kb 0 "$T/a.txt" >/dev/null 2>&1; rc=$?
check "oversize input refused (exit 2) before any call" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ]'
head -c 3000 /dev/zero > "$T/bin.dat"
"$AM" run --out "$T/o3b" --lens x=t "$T/bin.dat" >/dev/null 2>&1; rc=$?
check "binary file refused" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ]'
"$AM" run --out "$T/o2" --lens x=t "$T/a.txt" >/dev/null 2>&1; rc=$?
check "an existing run directory is not reused" '[ $rc -eq 2 ]'
"$AM" run --lens x=t "$T/a.txt" >/dev/null 2>&1; rc=$?
check "missing --out refused" '[ $rc -eq 2 ]'
"$AM" run --out "$T/o3c" --lens "bad name=t" "$T/a.txt" >/dev/null 2>&1; rc=$?
check "bad lens name refused" '[ $rc -eq 2 ]'
"$AM" run --out "$T/o3d" --lens x=t --lens x=u "$T/a.txt" >/dev/null 2>&1; rc=$?
check "duplicate lens name refused" '[ $rc -eq 2 ]'
"$AM" run --out "$T/o3e" --model "--evil" --lens x=t "$T/a.txt" >/dev/null 2>&1; rc=$?
check "option-looking model refused" '[ $rc -eq 2 ]'
"$AM" run --out "$T/o3f" --no-lens --whole 0 "$T/a.txt" >/dev/null 2>&1; rc=$?
check "nothing to run refused" '[ $rc -eq 2 ]'
newlog 4
out=$("$AM" run --out "$T/o4" --no-lens --whole 2 "$T/a.txt" 2>&1); rc=$?
check "--no-lens with --whole works on bash 3.2 (empty lens array)" '[ $rc -eq 0 ] && [ "$(calls)" = 2 ]'
newlog 5
out=$(fk FAKE_MODE=fail -- "$AM" run --out "$T/o5" --lens x=t --copies 2 "$T/a.txt" 2>&1); rc=$?
check "all calls failing exits 3 and says so" '[ $rc -eq 3 ] && echo "$out" | grep -q "failed 2" && echo "$out" | grep -q "no call succeeded"'
newlog 6
out=$(fk FAKE_MODE=iserror -- "$AM" run --out "$T/o6" --lens x=t "$T/a.txt" 2>&1); rc=$?
check "is_error result counts as a failure, cost not trusted" '[ $rc -eq 3 ] && grep -q "bad-output" "$T/o6/runs.tsv"'
newlog 7
out=$(fk FAKE_MODE=garbled -- "$AM" run --out "$T/o7" --lens x=t "$T/a.txt" 2>&1); rc=$?
check "garbled output is a failure, not a crash" '[ $rc -eq 3 ] && grep -q "bad-output" "$T/o7/runs.tsv"'
newlog 8
start=$(date +%s)
out=$(fk FAKE_MODE=slow -- "$AM" run --out "$T/o8" --lens x=t --timeout 1 "$T/a.txt" 2>&1); rc=$?
dur=$(( $(date +%s) - start ))
check "a hanging call is killed by the timeout and reported" '[ $rc -eq 3 ] && [ $dur -lt 5 ] && grep -q "fail(rc=" "$T/o8/runs.tsv"'

# 6. regressions for the ship-round findings
# 6a. a saved Console key (or an unverifiable login) is refused before anything is sent
newlog 9
out=$(fk FAKE_AUTH=apikey -- "$AM" run --out "$T/o9" --lens x=t "$T/a.txt" 2>&1); rc=$?
check "an API-key login is refused before any worker call" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ] && echo "$out" | grep -q "not a claude.ai subscription login"'
out=$(fk FAKE_AUTH=broken -- "$AM" run --out "$T/o9b" --lens x=t "$T/a.txt" 2>&1); rc=$?
check "an unverifiable login is refused (fails closed)" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ] && echo "$out" | grep -q "cannot verify the login"'
check "dedupe checks the login too" 'fk FAKE_AUTH=apikey -- "$AM" dedupe --out "$T/o2" >/dev/null 2>&1; [ $? -eq 2 ]'
# 6b. no finding is lost silently: markdown formatting is parsed, the rest is counted and reported
newlog 10
out=$(fk FAKE_MODE=markdown -- "$AM" run --out "$T/o10" --lens x=t --copies 2 "$T/a.txt" 2>&1); rc=$?
check "bold/bullet finding lines are counted (2 per run)" '[ $rc -eq 0 ] && [ "$(awk -F"\t" "{s+=\$4} END{print s}" "$T/o10/runs.tsv")" = 4 ]'
check "stray lines are counted and reported, not dropped silently" 'echo "$out" | grep -q "unparsed lines 2" && [ "$(awk -F"\t" "{s+=\$5} END{print s}" "$T/o10/runs.tsv")" = 2 ]'
out=$(fk FAKE_MODE=markdown -- "$AM" dedupe --out "$T/o10" 2>&1)
check "dedupe takes the bold finding and reports the unparsed lines" '[ "$(grep -c "^x_[0-9]*\.F[0-9]* |" "$T/o10/dedupe_in.txt")" = 4 ] && echo "$out" | grep -q "2 response lines were not in the finding format" && grep -q "stray continuation" "$T/o10/dedupe_unparsed.txt"'
newlog 11
out=$(fk FAKE_MODE=prose -- "$AM" run --out "$T/o11" --lens x=t "$T/a.txt" 2>&1); rc=$?
check "prose with no finding line fails instead of passing as zero findings" '[ $rc -eq 3 ] && grep -q "fail(unformatted)" "$T/o11/runs.tsv"'
# 6c. cost accounting covers failed calls and dedupe
check "a failed call that reported a cost is still counted" 'grep -q "	0.1	fail" "$T/o6/runs.tsv"'
out=$("$AM" summary --out "$T/o2" 2>&1)
check "summary shows dedupe calls and the combined total" 'echo "$out" | grep -q "dedupe calls" && echo "$out" | grep -q "total cost"'
rm -rf "$T/o2/dedupe_"* "$T/o2/clusters"* "$T/o2/members_"*
"$AM" dedupe --out "$T/o2" >/dev/null 2>&1; "$AM" dedupe --out "$T/o2" >/dev/null 2>&1
check "repeated dedupes are all accounted for" '[ "$(wc -l < "$T/o2/dedupe_cost.tsv" | tr -d " ")" = 2 ]'
# 6d. the output directory is claimed exclusively
newlog 12
mkdir -p "$T/o12-empty"
"$AM" run --out "$T/o12-empty" --lens x=t "$T/a.txt" >/dev/null 2>&1; rc=$?
check "an existing (even empty) directory is refused" '[ $rc -eq 2 ]'
ln -s "$T/a.txt" "$T/o12-link"
"$AM" run --out "$T/o12-link" --lens x=t "$T/a.txt" >/dev/null 2>&1; rc=$?
check "an existing symlink is refused" '[ $rc -eq 2 ] && [ ! -d "$T/a.txt" ]'
"$AM" run --out "$T/o12-race" --lens x=t "$T/a.txt" >/dev/null 2>&1 & p1=$!
"$AM" run --out "$T/o12-race" --lens x=t "$T/b.txt" >/dev/null 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
check "two simultaneous runs on one new --out: exactly one wins" '[ $(( (r1 == 0) + (r2 == 0) )) -eq 1 ]'
check "a nested new --out is created" '"$AM" run --out "$T/deep/er/o12" --lens x=t "$T/a.txt" >/dev/null 2>&1 && [ -s "$T/deep/er/o12/runs.tsv" ]'
"$AM" run --out "$T/o12-dry" --lens x=t --dry-run "$T/a.txt" >/dev/null 2>&1
check "a dry run does not claim the output directory" '[ ! -e "$T/o12-dry" ] && "$AM" run --out "$T/o12-dry" --lens x=t "$T/a.txt" >/dev/null 2>&1'
# 6e. bounds
"$AM" dedupe --out "$T/o2" --timeout 0 >/dev/null 2>&1; rc=$?
check "dedupe --timeout 0 is refused" '[ $rc -eq 2 ]'
newlog 13
printf 'x\n' > "$T/tiny.txt"
"$AM" run --out "$T/o13" --change c --lens "big=$(head -c 900 /dev/zero | tr '\0' 'l')" --max-input-kb 1 "$T/tiny.txt" >/dev/null 2>&1; rc=$?
check "the input cap covers base plus lens text, not the base alone" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ]'

# 7. regressions for the second ship round
# 7a. a lenses file: last line without a newline counts; an empty one is refused, never turned into whole runs
printf 'x|only requested lens' > "$T/lens-nonl.txt"
out=$("$AM" run --out "$T/o14" --lenses-file "$T/lens-nonl.txt" --copies 1 --dry-run "$T/a.txt" 2>&1)
check "an unterminated last lens line is read" 'echo "$out" | grep -q "1 prompts, 1 calls"'
printf '# nothing here\n' > "$T/lens-empty.txt"
"$AM" run --out "$T/o14b" --lenses-file "$T/lens-empty.txt" --dry-run "$T/a.txt" >/dev/null 2>&1; rc=$?
check "a lenses file with no lens is refused" '[ $rc -eq 2 ]'
# 7b. lens names that differ only in case collide on macOS: refused
"$AM" run --out "$T/o14c" --lens x=a --lens X=b --dry-run "$T/a.txt" >/dev/null 2>&1; rc=$?
check "lens names differing only in case are refused" '[ $rc -eq 2 ]'
"$AM" run --out "$T/o14d" --lens Whole=a --dry-run "$T/a.txt" >/dev/null 2>&1; rc=$?
check "the reserved name is reserved in any case" '[ $rc -eq 2 ]'
# 7c. NUL in a response is removed, not allowed to truncate the finding
newlog 14
out=$(fk FAKE_MODE=nul -- "$AM" run --out "$T/o15" --lens x=t --copies 1 "$T/a.txt" 2>&1)
fk FAKE_MODE=nul -- "$AM" dedupe --out "$T/o15" >/dev/null 2>&1
check "a NUL inside a finding does not cut it short" 'grep -q "before" "$T/o15/lists/x_1.md" && grep -q "beforeafter" "$T/o15/dedupe_in.txt" && echo "$out" | grep -q "findings 2"'
# 7d. unknown costs are shown as unknown, never as zero
newlog 15
out=$(AMASS_CLAUDE="$T/fake-nocost" "$AM" run --out "$T/o16" --lens x=t --copies 2 "$T/a.txt" 2>&1)
check "worker calls without a cost are reported as unknown" 'echo "$out" | grep -q "2 call(s) with unknown cost"'
check "the usage ledger writes null for an incomplete run cost, with the known subtotal and the count" 'tail -1 "$AMASS_LEDGER" | jq -e ".cost == null and .cost_known == 0 and .cost_unknown_calls == 2" >/dev/null'
out=$(AMASS_CLAUDE="$T/fake-nocost" "$AM" dedupe --out "$T/o16" 2>&1); out2=$("$AM" summary --out "$T/o16" 2>&1)
check "an unknown dedupe cost makes the totals PARTIAL" 'echo "$out2" | grep -q "PARTIAL" && echo "$out2" | grep -q "unknown cost"'
check "the dedupe ledger line carries null and the unknown count" 'tail -1 "$AMASS_LEDGER" | jq -e ".cmd == \"dedupe\" and .cost == null and .cost_unknown_calls == 1" >/dev/null'
# 7e. a failed dedupe still reaches the usage ledger
newlog 16
before=$(grep -c . "$AMASS_LEDGER")
fk FAKE_DEDUPE_FAIL=1 -- "$AM" dedupe --out "$T/o2" >/dev/null 2>&1; rc=$?
check "a failed dedupe exits 3 and is in the usage ledger with ok=0" '[ $rc -eq 3 ] && [ "$(grep -c . "$AMASS_LEDGER")" = $((before + 1)) ] && tail -1 "$AMASS_LEDGER" | jq -e ".cmd == \"dedupe\" and .ok == 0" >/dev/null'
# 7f. unparsed lines of failed responses are in the summary
newlog 17
out=$(fk FAKE_MODE=prose -- "$AM" run --out "$T/o17" --lens x=t --copies 1 "$T/a.txt" 2>&1)
check "unparsed lines of a failed (unformatted) response are counted in the summary" 'echo "$out" | grep -q "unparsed lines 1"'
# 7h. dedupe refuses a run directory that is not finished (no completion marker)
cp -R "$T/o2" "$T/o2u" && mv "$T/o2u/.complete" "$T/o2u/.complete.off"
"$AM" dedupe --out "$T/o2u" >/dev/null 2>&1; rc=$?
check "dedupe on an unfinished run (no .complete marker) is refused" '[ $rc -eq 2 ]'
check "a finished run carries the marker" '[ -e "$T/o2/.complete" ] && [ ! -e "$T/o2/.complete.tmp" ]'
# 7i. a file whose name starts with - is a file, not an option, and is read from the file, not from stdin
mkdir -p "$T/dash" && printf 'dash-file-content\n' > "$T/dash/-n"
( cd "$T/dash" && "$AM" run --out "$T/o18" --lens x=t --copies 1 --timeout 20 -- -n < /dev/null >/dev/null 2>&1 ); rc=$?
check "a file named -n is inlined by its content" '[ $rc -eq 0 ] && grep -q "dash-file-content" "$T/o18/base.txt" && grep -q "===== FILE ./-n =====" "$T/o18/base.txt"'
# 7g. one dedupe at a time per run directory; the cap covers the whole prompt
mkdir "$T/o2/.dedupe.lock"
"$AM" dedupe --out "$T/o2" >/dev/null 2>&1; rc=$?
check "a second dedupe on the same run directory is refused while one holds the lock" '[ $rc -eq 2 ]'
rmdir "$T/o2/.dedupe.lock"
"$AM" dedupe --out "$T/o2" --max-input-kb 1 >/dev/null 2>&1; rc=$?
check "the dedupe cap counts the instructions, not only the findings" '[ $rc -eq 2 ]'
check "the lock is released after a dedupe" '[ ! -d "$T/o2/.dedupe.lock" ]'

# 7j. a decimal-comma locale must not change the cost accounting (awk reads and writes numbers by locale)
if locale -a 2>/dev/null | grep -qi '^de_DE'; then
  newlog 19
  out=$(LC_ALL=de_DE.UTF-8 "$AM" run --out "$T/o19" --lens x=t --copies 2 "$T/a.txt" 2>&1)
  check "under a decimal-comma locale the worker cost is summed correctly" 'echo "$out" | grep -q "worker cost \$0.0100"'
  check "under a decimal-comma locale the ledger stays numeric" 'tail -1 "$AMASS_LEDGER" | jq -e ".cost == 0.01 and .cost_known == 0.01 and .cost_unknown_calls == 0" >/dev/null'
  LC_ALL=de_DE.UTF-8 "$AM" dedupe --out "$T/o19" >/dev/null 2>&1
  out2=$(LC_ALL=de_DE.UTF-8 "$AM" summary --out "$T/o19" 2>&1)
  check "under a decimal-comma locale the combined total is right" 'echo "$out2" | grep -q "total cost \$0.0200" && ! echo "$out2" | grep -q "PARTIAL"'
else
  echo "note: decimal-comma locale test skipped (no de_DE locale here)"
fi

# 8. support counts, stable model ids, and advisory no-input markers.
newlog clusters
out=$(fk FAKE_DEDUPE=clusters -- "$AM" dedupe --out "$T/o2" 2>&1); rc=$?
cat > "$T/expected-clusters" <<'EOF'
C7 | P2 | n=4 | call("a|b", n=7) returns "[no-input]" | members: whole_1.F1,whole_1.F2,x_1.F1,x_1.F2
C10 | P1 | n=3 | call(0) fails | members: x_2.F1,x_2.F2,y_1.F1
C2 | P1 | n=3 | another vague concern | members: y_1.F2,y_2.F1,y_2.F2 [no-input]
C8 | P2 | n=0 | no members supplied | members:  [no-input]
C9 | P2 | n=0 | vague concern | members:  [no-input]
EOF
check "clusters sorted by count descending then id in C order, ids unchanged" '[ $rc -eq 0 ] && cmp -s "$T/expected-clusters" "$T/o2/clusters.md"'
check "pipes, n= and a quoted marker in text are preserved literally" 'head -1 "$T/expected-clusters" > "$T/expected-first"; head -1 "$T/o2/clusters.md" | cmp -s - "$T/expected-first"'
check "zero and missing member lists are retained with n=0" '[ "$(grep -c "| n=0 |" "$T/o2/clusters.md")" = 2 ]'
check "flagged and unflagged clusters both survive" 'grep -Fxq "C2 | P1 | n=3 | another vague concern | members: y_1.F2,y_2.F1,y_2.F2 [no-input]" "$T/o2/clusters.md" && grep -Fxq "C10 | P1 | n=3 | call(0) fails | members: x_2.F1,x_2.F2,y_1.F1" "$T/o2/clusters.md"'
check "markers are never counted as member ids" 'echo "$out" | grep -q "0 findings omitted.*0 duplicated ids, 0 unknown ids" && [ "$(wc -l < "$T/o2/members_seen.txt" | tr -d " ")" = 10 ]'
check "dedupe prints the exact sorted cluster lines" 'printf "%s\n" "$out" | grep "^C" | cmp -s - "$T/expected-clusters"'
out2=$("$AM" summary --out "$T/o2" 2>&1)
check "summary prints the exact sorted cluster lines" 'printf "%s\n" "$out2" | grep "^C" | cmp -s - "$T/expected-clusters"'
check "dedupe prompt defines concrete failing input and the advisory marker" 'grep -qF "[no-input]" "$T/o2/dedupe_prompt.txt" && grep -q "specific input value, call or state" "$T/o2/dedupe_prompt.txt" && grep -q "never drop" "$T/o2/dedupe_prompt.txt"'
fk FAKE_DEDUPE=clusters -- "$AM" dedupe --out "$T/o2" >/dev/null 2>&1
check "repeated dedupe keeps the same order and ids" 'cmp -s "$T/expected-clusters" "$T/o2/clusters.md"'

# 9. Context is separate from reviewed files, but shares validation and size limits.
newlog context
mkdir "$T/context"
printf 'space-content\n' > "$T/context/has space"
printf 'dash-context\n' > "$T/context/-n"
newline=$'line\nbreak'
printf 'newline-content\n' > "$T/context/$newline"
out=$(cd "$T/context" && "$AM" run --out "$T/context-out" --no-lens --whole 1 "$T/a.txt" --context 'has space' "$newline" --context -n --context "$T/a.txt" 2>&1); rc=$?
check "repeatable multi-file context works with empty lens arrays on bash 3.2" '[ $rc -eq 0 ] && [ "$(calls)" = 1 ]'
{
  printf '\n===== FILE %s =====\nalpha\nbeta\n' "$T/a.txt"
  printf '\n===== CONTEXT ./has space =====\nspace-content\n'
  printf '\n===== CONTEXT ./%s =====\nnewline-content\n' "$newline"
  printf '\n===== CONTEXT ./-n =====\ndash-context\n'
  printf '\n===== CONTEXT %s =====\nalpha\nbeta\n' "$T/a.txt"
} > "$T/expected-context"
check "context filenames with spaces, dashes and newlines have exact blocks after reviewed files" 'tail -c "$(wc -c < "$T/expected-context")" "$T/context-out/base.txt" | cmp -s - "$T/expected-context"'
check "a reviewed file also passed as context keeps both roles" '[ "$(grep -c "^alpha$" "$T/context-out/base.txt")" = 2 ] && grep -qF "===== FILE $T/a.txt =====" "$T/context-out/base.txt" && grep -qF "===== CONTEXT $T/a.txt =====" "$T/context-out/base.txt"'
check "task says context is not under review and findings concern reviewed files" 'grep -q "callers, callees, tests of the changed functions" "$T/context-out/base.txt" && grep -q "not under review" "$T/context-out/base.txt" && grep -q "findings must be about the reviewed files" "$T/context-out/base.txt"'
printf 'Custom task\n' > "$T/context-task"
"$AM" run --out "$T/context-custom" --task-file "$T/context-task" --no-lens --whole 1 --context "$T/b.txt" -- "$T/a.txt" >/dev/null 2>&1; rc=$?
check "custom tasks and -- still preserve context guidance and reviewed files" '[ $rc -eq 0 ] && grep -q "not under review" "$T/context-custom/base.txt" && grep -qF "===== FILE $T/a.txt =====" "$T/context-custom/base.txt"'
newlog context-cap
head -c 3000 /dev/zero | tr '\0' x > "$T/context-big"
"$AM" run --out "$T/context-control" --no-lens --whole 1 --max-input-kb 2 --dry-run "$T/a.txt" >/dev/null 2>&1; control=$?
out=$("$AM" run --out "$T/context-cap" --no-lens --whole 1 --max-input-kb 2 "$T/a.txt" --context "$T/context-big" 2>&1); rc=$?
check "context counts toward input cap before any login or model call" '[ $control -eq 0 ] && [ $rc -eq 2 ] && echo "$out" | grep -q "above --max-input-kb 2" && [ "$(calls)" = 0 ] && [ ! -e "$FAKE_LOG/auth_envnames" ]'
printf 'before\0after' > "$T/context/-binary"
out=$(cd "$T/context" && "$AM" run --out "$T/context-nul" --no-lens --whole 1 "$T/a.txt" --context -binary 2>&1); rc=$?
check "dash context containing NUL is refused as binary before calls" '[ $rc -eq 2 ] && echo "$out" | grep -q "contains NUL bytes" && [ "$(calls)" = 0 ]'
out=$("$AM" run --out "$T/context-missing" "$T/a.txt" --context "$T/not-present" 2>&1); rc=$?
check "missing context refused with path and read diagnostic" '[ $rc -eq 2 ] && echo "$out" | grep -qF "cannot read $T/not-present" && [ "$(calls)" = 0 ]'
out=$("$AM" run --out "$T/context-dir" "$T/a.txt" --context "$T/context" 2>&1); rc=$?
check "directory context refused" '[ $rc -eq 2 ] && echo "$out" | grep -qF "cannot read $T/context" && [ "$(calls)" = 0 ]'
printf 'unreadable\n' > "$T/context-unreadable"; chmod 000 "$T/context-unreadable"
out=$("$AM" run --out "$T/context-perms" "$T/a.txt" --context "$T/context-unreadable" 2>&1); rc=$?
if [ ! -r "$T/context-unreadable" ]; then
  check "unreadable context refused before calls" '[ $rc -eq 2 ] && echo "$out" | grep -qF "cannot read $T/context-unreadable" && [ "$(calls)" = 0 ]'
else
  echo "note: unreadable context test skipped (user can read mode 000 files)"
fi
chmod 600 "$T/context-unreadable"
out=$("$AM" run --out "$T/context-empty" "$T/a.txt" --context 2>&1); rc=$?
check "empty context group refused with useful diagnostic" '[ $rc -eq 2 ] && echo "$out" | grep -qF -- "--context needs FILE"'
out=$("$AM" run --out "$T/context-option" "$T/a.txt" --context --dry-run 2>&1); rc=$?
check "context cannot consume the next long option as a filename" '[ $rc -eq 2 ] && echo "$out" | grep -qF -- "--context needs FILE"'
out=$("$AM" run --out "$T/context-only" --context "$T/a.txt" 2>&1); rc=$?
check "context alone does not populate the empty reviewed-file array" '[ $rc -eq 2 ] && echo "$out" | grep -q "no FILE to inline"'
check "the diagnostic explains that files after --context are context" 'echo "$out" | grep -qF -- "put the reviewed files before --context"'
out=$("$AM" run --out "$T/no-files-no-context" 2>&1); rc=$?
check "without any context the plain diagnostic stays" '[ $rc -eq 2 ] && echo "$out" | grep -q "no FILE to inline" && ! echo "$out" | grep -qF -- "--context"'

# 10. User-facing caveats and the pre-created-output refusal are explicit.
out=$("$AM" --help 2>&1)
for doc in help readme; do
  if [ "$doc" = help ]; then printf '%s\n' "$out" > "$T/doc"; else cp "$REPO/README-amass.md" "$T/doc"; fi
  check "$doc documents model labels and both measured precision ranges" 'grep -q "model.*labels\|labels.*model" "$T/doc" && grep -q "15-20" "$T/doc" && grep -q "40 percent" "$T/doc"'
  check "$doc documents diff scope and caller/callee context" 'grep -q "inside the diff" "$T/doc" && grep -q "callers and callees.*--context" "$T/doc"'
  check "$doc documents --out must not exist and exit 2" 'grep -q -- "--out.*must not exist" "$T/doc" && grep -q "pre-creates.*exit 2" "$T/doc"'
  check "$doc documents normal counted parse failures" 'grep -q "3-5 of 18.*failing to parse.*normal.*counted" "$T/doc"'
done
mkdir "$T/precreated"
out=$("$AM" run --out "$T/precreated" --no-lens --whole 1 "$T/a.txt" 2>&1); rc=$?
check "pre-created --out fails with exit 2 and an explanation" '[ $rc -eq 2 ] && echo "$out" | grep -q "already exists.*new --out"'

# 11. Codex is always a fake on PATH, configured through the same conf.sh.
unset MEGAVIBE_AMASS_CODEX_PRICE
mkdir "$T/bin"
cat > "$T/bin/codex" <<'EOF'
#!/bin/bash
# Capture the real environment BEFORE conf.sh supplies fake-only settings.
names=$(env | cut -d= -f1 | sort)
. "$(dirname "$0")/../conf.sh"
if [ "${2:-}" = --help ]; then
  printf '%s\n' "$names" > "$FAKE_LOG/help_envnames"
  pwd > "$FAKE_LOG/help_cwd"
  echo '      --skip-git-repo-check'
  [ "${FAKE_CX:-}" = noignore ] || echo '      --ignore-rules'
  [ "${FAKE_CX:-}" = noignore ] || echo '      --ignore-user-config'
  [ "${FAKE_CX:-}" != helpfail ]; exit $?
fi
if [ "${1:-}" = login ]; then
  printf '%s\n' "$names" > "$FAKE_LOG/login_envnames"
  case ${FAKE_CX:-} in
    apikey) echo 'Logged in using an API key' >&2 ;;
    loggedout) echo 'Not logged in' >&2; exit 1 ;;
    loginfail) exit 1 ;;
    *) echo 'Logged in using ChatGPT' >&2 ;;
  esac
  exit 0
fi
d="$FAKE_LOG/call_$$"; mkdir "$d"
printf '%s\n' "$@" > "$d/argv"
printf '%s\n' "$names" > "$d/envnames"
pwd > "$d/cwd"
cat > "$d/prompt"
answer=''
while [ $# -gt 0 ]; do
  case $1 in --output-last-message) answer=$2; shift ;; esac
  shift
done
printf '%s\n' "$answer" > "$d/output"
case ${FAKE_CX:-} in
  slow)
    echo $$ > "$d/pid"
    sleep 30 & echo $! > "$d/child"
    wait; exit 0 ;;
  nofile) exit 0 ;;
  fail) echo boom >&2; exit 1 ;;
esac
if grep -q 'dedupe stage' "$d/prompt"; then
  ids=$(grep -E '^[A-Za-z0-9_-]+_[0-9]+\.F[0-9]+ \|' "$d/prompt" | cut -d' ' -f1 | paste -sd, -)
  printf 'C1 | P2 | everything | members: %s\n' "$ids" > "$answer"
else
  printf 'F1 | P2 | a.sh:1 | boom on empty input | because\nF2 | P1 | a.sh:9 | race | because\n' > "$answer"
fi
if [ "${FAKE_CX:-}" != notokens ]; then
  # cached_input_tokens is part of input_tokens, never added a second time.
  echo '{"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":1000,"output_tokens":34}}'
fi
EOF
chmod +x "$T/bin/codex"
export PATH="$T/bin:$PATH"
unset AMASS_CODEX
export OPENAI_API_KEY=example OPENAI_BASE_URL=https://example.invalid OPENAI_ORG_ID=example OPENAI_CUSTOM_HEADERS=example CODEX_API_KEY=example AZURE_OPENAI_API_KEY=example CODEX_FUTURE_TOKEN=example
export CODEX_HOME="$T/codex-home"
mkdir "$CODEX_HOME" "$T/scratch"
# Force scratch paths under the disposable fixture, and assert none survives any exit.
export TMPDIR="$T/scratch"
clean_scratch() { [ -z "$(ls -A "$T/scratch")" ] || { [ -z "${AMASS_TEST_DEBUG:-}" ] || ls -A "$T/scratch" >&2; return 1; }; }
cxrun() { "$AM" run --provider codex --out "$T/cx-$1" --no-lens --whole 1 "${@:2}" "$T/a.txt"; }
newlog cx
out=$(cxrun ok 2>&1); rc=$?
check "codex default run works with empty lens/context arrays on bash 3.2" '[ $rc -eq 0 ] && [ "$(calls)" = 1 ]'
first=$(ls -d "$FAKE_LOG"/call_* 2>/dev/null | head -1)
check "codex is headless, read-only, never approves, ignores rules, ephemeral, stdin prompt" '[ -n "$first" ] && grep -qx exec "$first/argv" && grep -qx read-only "$first/argv" && grep -qx "approval_policy=\"never\"" "$first/argv" && grep -qx -- --ignore-rules "$first/argv" && grep -qx -- --skip-git-repo-check "$first/argv" && grep -qx -- --ephemeral "$first/argv" && tail -1 "$first/argv" | grep -qx -- - && grep -q alpha "$first/prompt"'
check "codex defaults to the full luna id and writes final answer in the run dir" '[ -n "$first" ] && grep -qx gpt-5.6-luna "$first/argv" && grep -qF "$T/cx-ok/raw/" "$first/output" && [ -s "$(cat "$first/output")" ]'
check "codex login and workers exclude all planted credentials, endpoints, headers" '[ -n "$first" ] && ! cat "$first/envnames" "$FAKE_LOG/login_envnames" "$FAKE_LOG/help_envnames" | grep -qE "OPENAI|ANTHROPIC|AWS_|CODEX_API_KEY|CODEX_FUTURE|CLAUDE_CODE_USE" && grep -qx CODEX_HOME "$first/envnames" && grep -qx HOME "$first/envnames" && grep -qx PATH "$first/envnames"'
check "codex runs outside project/output and cleans scratch after success" '[ -n "$first" ] && grep -qF "$T/scratch/" "$first/cwd" && [ ! -d "$(cat "$first/cwd")" ] && clean_scratch'
check "codex records tokens without inventing cost" 'tail -1 "$AMASS_LEDGER" | jq -e ".provider == \"codex\" and .tokens == 1234 and .cost == null" >/dev/null && echo "$out" | grep -q "tokens 1234" && ! echo "$out" | grep -q "\$0\.000"'
out=$(cxrun model --model gpt-6-luna 2>&1); rc=$?
check "codex --model overrides default" '[ $rc -eq 0 ] && cat "$FAKE_LOG"/call_*/argv | grep -qx gpt-6-luna'
for mode in helpfail apikey loggedout loginfail; do
  newlog "cx-$mode"
  out=$(fk "FAKE_CX=$mode" -- cxrun "$mode" 2>&1); rc=$?
  check "codex $mode refuses before any worker and cleans scratch" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ] && echo "$out" | grep -qE "exec --help|ChatGPT|verify.*login" && clean_scratch'
done
# An isolated PATH has the shell utilities but cannot possibly find a real codex.
mkdir "$T/no-codex"
for utility in bash jq perl dirname mkdir cat tr cmp wc mktemp sed rm chmod pwd; do
  ln -s "$(command -v "$utility")" "$T/no-codex/$utility"
done
out=$(PATH="$T/no-codex" cxrun missing 2>&1); rc=$?
check "missing codex refuses clearly and cleans scratch" '[ $rc -eq 2 ] && echo "$out" | grep -q "codex" && clean_scratch'
for mode in nofile fail notokens; do
  newlog "cx-$mode"
  out=$(fk "FAKE_CX=$mode" -- cxrun "$mode" 2>&1); rc=$?
  if [ "$mode" = notokens ]; then
    check "missing token event stays unknown, never zero" '[ $rc -eq 0 ] && tail -1 "$AMASS_LEDGER" | jq -e ".provider == \"codex\" and .tokens == null and .cost == null" >/dev/null && echo "$out" | grep -q "tokens unknown"'
  else
    check "codex $mode counts a failed worker and no usable result" '[ $rc -eq 3 ] && echo "$out" | grep -q "ok 0, failed 1"'
  fi
  check "codex cleans scratch after $mode" 'clean_scratch'
done
newlog cx-slow
start=$(date +%s)
out=$(fk FAKE_CX=slow -- cxrun slow --timeout 1 2>&1); rc=$?
dur=$(( $(date +%s) - start ))
check "codex timeout is supervised, counted, and scratch cleaned" '[ $rc -eq 3 ] && [ $dur -lt 6 ] && grep -q "fail(rc=124)" "$T/cx-slow/runs.tsv" && clean_scratch'
check "codex timeout kills worker and child" '[ "$(calls)" = 1 ] && ! kill -0 "$(cat "$FAKE_LOG"/call_*/pid)" 2>/dev/null && ! kill -0 "$(cat "$FAKE_LOG"/call_*/child)" 2>/dev/null'
# Cancellation must forward through shell workers to the supervised process group.
newlog cx-cancel
defconf
printf 'export FAKE_CX=slow\n' >> "$T/conf.sh"
"$AM" run --provider codex --out "$T/cx-cancel" --no-lens --whole 1 "$T/a.txt" > "$T/cancel.log" 2>&1 & cancel_pid=$!
tries=0
while [ "$tries" -lt 100 ] && ! ls "$FAKE_LOG"/call_*/child >/dev/null 2>&1; do sleep 0.05; tries=$((tries + 1)); done
kill -TERM "$cancel_pid" 2>/dev/null
wait "$cancel_pid"; rc=$?
defconf
check "cancelling codex cleans scratch and kills worker descendants" '[ $rc -eq 143 ] && [ "$(calls)" = 1 ] && clean_scratch && ! kill -0 "$(cat "$FAKE_LOG"/call_*/pid)" 2>/dev/null && ! kill -0 "$(cat "$FAKE_LOG"/call_*/child)" 2>/dev/null'
newlog cx-invalid
out=$(cxrun dash --model --evil 2>&1); rc=$?
check "codex rejects option-looking models before calling" '[ $rc -eq 2 ] && echo "$out" | grep -q "bad --model" && [ "$(calls)" = 0 ] && clean_scratch'
for verb in run dedupe; do
  out=$("$AM" "$verb" --provider other --out "$T/cx-ok" 2>&1); rc=$?
  check "$verb rejects an invalid provider" '[ $rc -eq 2 ] && echo "$out" | grep -q -- "--provider must be"'
done
newlog cx-parallel
out=$("$AM" run --provider codex --out "$T/cx-parallel" --lens x=one --lens y=two --copies 2 --parallel 4 "$T/a.txt" 2>&1); rc=$?
check "parallel codex workers write four distinct final-answer files" '[ $rc -eq 0 ] && [ "$(calls)" = 4 ] && [ "$(cat "$FAKE_LOG"/call_*/output | sort -u | wc -l | tr -d " ")" = 4 ] && echo "$out" | grep -q "runs 4, ok 4" && clean_scratch'
out=$("$AM" dedupe --provider codex --out "$T/cx-ok" 2>&1); rc=$?
check "codex dedupe preserves cluster format and accounting" '[ $rc -eq 0 ] && grep -qx "C1 | P2 | n=2 | everything | members: whole_1.F1,whole_1.F2" "$T/cx-ok/clusters.md" && tail -1 "$AMASS_LEDGER" | jq -e ".provider == \"codex\" and .cmd == \"dedupe\" and .tokens == 1234 and .cost == null" >/dev/null && clean_scratch'
out=$("$AM" summary --out "$T/cx-ok" 2>&1)
check "standalone summary remembers codex token usage including dedupe" 'echo "$out" | grep -q "tokens 1234" && echo "$out" | grep -q "total tokens 2468"'
# A second attempt must not accept the previous dedupe answer.
out=$(fk FAKE_CX=nofile -- "$AM" dedupe --provider codex --out "$T/cx-ok" 2>&1); rc=$?
check "missing dedupe answer cannot reuse stale final output" '[ $rc -eq 3 ] && tail -1 "$AMASS_LEDGER" | jq -e ".ok == 0" >/dev/null && clean_scratch'
out=$(MEGAVIBE_AMASS_CODEX_PRICE=2 cxrun priced 2>&1); rc=$?
check "explicit USD per million price produces only a labelled estimate" '[ $rc -eq 0 ] && tail -1 "$AMASS_LEDGER" | jq -e ".tokens == 1234 and .cost == 0.002468" >/dev/null && echo "$out" | grep -q "estimated cost"'
out=$(MEGAVIBE_AMASS_CODEX_PRICE=invalid cxrun badprice 2>&1); rc=$?
check "invalid codex price is refused" '[ $rc -eq 2 ] && echo "$out" | grep -q MEGAVIBE_AMASS_CODEX_PRICE && clean_scratch'
head -c 200000 /dev/zero | tr '\0' x > "$T/medium"
out=$("$AM" run --provider codex --out "$T/cx-medium" --no-lens --whole 1 --dry-run "$T/medium" 2>&1); rc=$?
check "codex default input cap accepts 200 KB" '[ $rc -eq 0 ] && clean_scratch'
head -c 410000 /dev/zero | tr '\0' x > "$T/large"
out=$("$AM" run --provider codex --out "$T/cx-large" --no-lens --whole 1 --dry-run "$T/large" 2>&1); rc=$?
check "codex default cap is 400 KB with luna reason and dry scratch cleanup" '[ $rc -eq 2 ] && echo "$out" | grep -q "max-input-kb 400" && echo "$out" | grep -q "272K" && clean_scratch'
out=$("$AM" run --provider claude --out "$T/cx-claude-cap" --no-lens --whole 1 --dry-run "$T/medium" 2>&1); rc=$?
check "claude still defaults to 150 KB and Haiku reason, and a refused dry run leaves no scratch" '[ $rc -eq 2 ] && echo "$out" | grep -q "max-input-kb 150" && echo "$out" | grep -q "Haiku" && clean_scratch'

out=$("$AM" --help)
for doc in help readme; do
  if [ "$doc" = help ]; then printf '%s\n' "$out" > "$T/doc"; else cp "$REPO/README-amass.md" "$T/doc"; fi
  check "$doc explains provider routing, full model ids and unknown comparative precision" 'grep -q -- "--provider" "$T/doc" && grep -q "gpt-5.6-luna" "$T/doc" && grep -q "gpt-6-luna" "$T/doc" && grep -q "headroom" "$T/doc" && grep -q "unknown until compared" "$T/doc"'
done

# 12. Mixed runs: both providers in one run, split inversely to the projected usage.
ncl() { ls -d "$FAKE_LOG"/call_*/apikey 2>/dev/null | wc -l | tr -d ' '; }
ncx() { ls -d "$FAKE_LOG"/call_*/output 2>/dev/null | wc -l | tr -d ' '; }
splitline() { "$AM" run --out "$T/sl-unused" --no-lens --whole "$1" --dry-run "${@:2}" "$T/a.txt" 2>&1 | grep '^split:'; }
PC150=$(pace 100 150 10); PX225=$(pace 100 225 10)
out=$(PACE_CLAUDE=$PC150 PACE_CODEX=$PX225 splitline 10)
check "P 150 vs 225 over 10 calls prints claude 6, codex 4 with both projections (also in --dry-run)" '[ "$out" = "split: claude 6 (haiku), codex 4 (gpt-5.6-luna); projections claude 150 (recent), codex 225 (recent)" ]'
newlog mix1
out=$(PACE_CLAUDE=$PC150 PACE_CODEX=$PX225 "$AM" run --out "$T/mx1" --no-lens --whole 10 "$T/a.txt" 2>&1); rc=$?
check "the default (auto) run with both usable sends 6 Claude and 4 Codex calls and prints the split before sending" '[ $rc -eq 0 ] && [ "$(ncl)" = 6 ] && [ "$(ncx)" = 4 ] && echo "$out" | grep -q "^split: claude 6 (haiku), codex 4"'
check "runs.tsv has a provider column on every row, and a .provider file per call" '[ "$(awk -F"\t" "NF == 7 && (\$7 == \"claude\" || \$7 == \"codex\")" "$T/mx1/runs.tsv" | wc -l | tr -d " ")" = 10 ] && [ "$(awk -F"\t" "\$7 == \"claude\"" "$T/mx1/runs.tsv" | wc -l | tr -d " ")" = 6 ] && [ "$(cat "$T"/mx1/raw/*.provider | sort | uniq -c | tr -s " " | tr "\n" ";")" = " 6 claude; 4 codex;" ]'
check "the ledger got one line per provider used, each with its own model and calls" '[ "$(tail -2 "$AMASS_LEDGER" | jq -r ".provider + \":\" + .model + \":\" + (.calls|tostring)" | sort | tr "\n" " ")" = "claude:haiku:6 codex:gpt-5.6-luna:4 " ]'
check "the mixed summary shows each provider and totals (claude cost, codex tokens)" 'echo "$out" | grep -q "^runs 10, ok 10, failed 0" && echo "$out" | grep -q "^claude: worker calls 6, ok 6, findings 12, cost \$0.030000" && echo "$out" | grep -q "^codex: worker calls 4, ok 4, findings 8, tokens 4936, cost unknown" && echo "$out" | grep -q "^total: claude cost \$0.030000; codex tokens 4936"'
check "the summary subcommand reads the same mixed run" '"$AM" summary --out "$T/mx1" | grep -q "^codex: worker calls 4"'
check "claude workers kept their flags and codex workers theirs in a mixed run" '[ "$(cat "$FAKE_LOG"/call_*/argv | grep -c -x -- "--tools")" = 6 ] && [ "$(cat "$FAKE_LOG"/call_*/argv | grep -c -x -- "--ephemeral")" = 4 ]'
out=$(PACE_CLAUDE=$PC150 PACE_CODEX=$PX225 "$AM" dedupe --out "$T/mx1" 2>&1); rc=$?
check "dedupe with both usable picks the lower projection (claude 150 < codex 225), says which and why" '[ $rc -eq 0 ] && echo "$out" | grep -q "^dedupe: provider claude (projections claude 150 (recent), codex 225 (recent)" && tail -1 "$AMASS_LEDGER" | jq -e ".cmd == \"dedupe\" and .provider == \"claude\"" >/dev/null'
check "clusters of a mixed run show provider support" 'grep -q "n=20 (claude 12, codex 8)" "$T/mx1/clusters.md"'
rm -rf "$T/mx1/dedupe_"* "$T/mx1/clusters"* "$T/mx1/members_"*
out=$(PACE_CLAUDE=$(pace 100 300 10) PACE_CODEX=$PX225 "$AM" dedupe --out "$T/mx1" 2>&1); rc=$?
check "dedupe takes codex when its projection is lower, and runs it" '[ $rc -eq 0 ] && echo "$out" | grep -q "^dedupe: provider codex" && tail -1 "$AMASS_LEDGER" | jq -e ".cmd == \"dedupe\" and .provider == \"codex\" and .model == \"gpt-5.6-luna\"" >/dev/null'
out=$("$AM" summary --out "$T/mx1" 2>&1)
check "the mixed summary includes a codex dedupe" 'echo "$out" | grep -q "^dedupe codex: calls 1, tokens 1234"'
rm -rf "$T/mx1/dedupe_"* "$T/mx1/clusters"* "$T/mx1/members_"*
out=$(PACE_CLAUDE=$PC150 "$AM" dedupe --out "$T/mx1" --provider codex 2>&1)
check "dedupe --provider codex overrides the projection choice" 'tail -1 "$AMASS_LEDGER" | jq -e ".cmd == \"dedupe\" and .provider == \"codex\"" >/dev/null && ! echo "$out" | grep -q "^dedupe: provider"'
# the projection source: recent, else linear, else used, else unknown; clamped
out=$(PACE_CLAUDE=$(pace 150 300 10) PACE_CODEX=$(pace 225 "" 10) splitline 10)
check "recent beats linear, linear beats used" 'echo "$out" | grep -q "projections claude 300 (recent), codex 225 (linear)"'
out=$(PACE_CLAUDE=$(pace "" "" 150) PACE_CODEX=$(pace "" "" 225) splitline 10)
check "used is the last resort" 'echo "$out" | grep -q "claude 6 (haiku), codex 4 (gpt-5.6-luna); projections claude 150 (used), codex 225 (used)"'
out=$(PACE_CLAUDE=$(pace "" 5 10) PACE_CODEX=$(pace "" 5000 10) splitline 10)
check "projections are clamped to 10..1000 and the diversity floor keeps one call on the heavy side" 'echo "$out" | grep -q "claude 9 (haiku), codex 1 (gpt-5.6-luna); projections claude 10 (recent), codex 1000 (recent)"'
out=$(PACE_CLAUDE=$(pace "" 5000 10) PACE_CODEX=$(pace "" 10 10) splitline 10)
check "the floor works the other way too" 'echo "$out" | grep -q "claude 1 (haiku), codex 9 (gpt-5.6-luna)"'
out=$(PACE_CLAUDE=$(pace "" 100 10) splitline 10)
check "one unknown side takes the other's projection (equal weight) and is shown as unknown" 'echo "$out" | grep -q "claude 5 (haiku), codex 5 (gpt-5.6-luna); projections claude 100 (recent), codex ? (unknown)"'
out=$(splitline 5)
check "both unknown: 1:1, and Claude takes the extra call of an odd total" 'echo "$out" | grep -q "split: claude 3 (haiku), codex 2 (gpt-5.6-luna); projections claude ? (unknown), codex ? (unknown)"'
out=$(PACE_FAIL=1 splitline 4)
check "a failing usage-route means unknown, not a crash" 'echo "$out" | grep -q "split: claude 2 (haiku), codex 2 (gpt-5.6-luna)"'
out=$(PACE_CLAUDE=garbage PACE_CODEX='x|abc|2|def|1|ghi|3' splitline 4)
check "garbled pace output means unknown" 'echo "$out" | grep -q "split: claude 2 (haiku), codex 2 (gpt-5.6-luna); projections claude ? (unknown), codex ? (unknown)"'
out=$(MEGAVIBE_AMASS_USAGE_ROUTE="$T/no-such-route" splitline 4)
check "a missing usage-route means unknown" 'echo "$out" | grep -q "split: claude 2 (haiku), codex 2 (gpt-5.6-luna)"'
out=$(splitline 1)
check "a single call goes to the larger weight (a tie: claude)" 'echo "$out" | grep -q "claude 1 (haiku), codex 0"'
out=$(PACE_CLAUDE=$(pace "" 400 10) PACE_CODEX=$(pace "" 100 10) splitline 1)
check "a single call goes to codex when its projection is lower" 'echo "$out" | grep -q "claude 0 (haiku), codex 1"'
# overrides
out=$(splitline 10 --split 1:0)
check "--split 1:0 puts every call on claude (no floor for a zero weight)" '[ "$out" = "split: override 1:0; claude 10 (haiku), codex 0 (gpt-5.6-luna)" ]'
out=$(splitline 10 --split 0:5)
check "--split 0:5 puts every call on codex" 'echo "$out" | grep -q "claude 0 (haiku), codex 10"'
out=$(MEGAVIBE_AMASS_SPLIT=1:3 splitline 8)
check "MEGAVIBE_AMASS_SPLIT sets the split" 'echo "$out" | grep -q "split: override 1:3; claude 2 (haiku), codex 6"'
out=$(MEGAVIBE_AMASS_SPLIT=1:3 splitline 8 --split 3:1)
check "the flag wins over the environment" 'echo "$out" | grep -q "split: override 3:1; claude 6 (haiku), codex 2"'
out=$(splitline 10 --split 1:100)
check "a nonzero weight keeps the diversity floor" 'echo "$out" | grep -q "claude 1 (haiku), codex 9"'
for bad_split in 1 a:b 0:0 1:2:3 -1:2 1:; do
  "$AM" run --out "$T/sl-bad" --no-lens --whole 2 --dry-run --split "$bad_split" "$T/a.txt" >/dev/null 2>&1; rc=$?
  check "invalid --split '$bad_split' is refused" '[ $rc -eq 2 ]'
done
MEGAVIBE_AMASS_SPLIT=0:0 "$AM" run --out "$T/sl-bad" --no-lens --whole 2 --dry-run "$T/a.txt" >/dev/null 2>&1; rc=$?
check "an invalid MEGAVIBE_AMASS_SPLIT is refused" '[ $rc -eq 2 ]'
"$AM" run --out "$T/sl-bad" --provider claude --split 1:1 --no-lens --whole 2 --dry-run "$T/a.txt" >/dev/null 2>&1; rc=$?
check "--split with a single explicit provider is refused" '[ $rc -eq 2 ]'
newlog mix2
out=$(MEGAVIBE_AMASS_SPLIT=1:0 "$AM" run --out "$T/mx2" --no-lens --whole 4 "$T/a.txt" 2>&1); rc=$?
check "a split with a zero weight sends nothing to that provider and writes one ledger line" '[ $rc -eq 0 ] && [ "$(ncl)" = 4 ] && [ "$(ncx)" = 0 ] && tail -1 "$AMASS_LEDGER" | jq -e ".provider == \"claude\" and .calls == 4" >/dev/null'
# models
newlog mix3
out=$("$AM" run --out "$T/mx3" --no-lens --whole 4 --claude-model sonnet --codex-model gpt-6-luna "$T/a.txt" 2>&1); rc=$?
check "--claude-model and --codex-model pick the model of each provider" '[ $rc -eq 0 ] && cat "$FAKE_LOG"/call_*/argv | grep -qx sonnet && cat "$FAKE_LOG"/call_*/argv | grep -qx gpt-6-luna && ! cat "$FAKE_LOG"/call_*/argv | grep -qx haiku && echo "$out" | grep -q "claude 2 (sonnet), codex 2 (gpt-6-luna)"'
for pv in mix auto; do
  newlog mix4
  out=$("$AM" run --out "$T/mx4$pv" --provider "$pv" --model sonnet --no-lens --whole 4 "$T/a.txt" 2>&1); rc=$?
  check "--model with a mixed run ($pv) is refused and points to the two flags, nothing sent" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ] && echo "$out" | grep -q -- "--claude-model and --codex-model"'
done
newlog mix5
out=$(AMASS_CODEX="$T/no-such-codex" "$AM" run --out "$T/mx5" --model sonnet --no-lens --whole 2 "$T/a.txt" 2>&1); rc=$?
check "--model works when auto resolves to a single provider" '[ $rc -eq 0 ] && sed -n "/^--model\$/{n;p;}" "$FAKE_LOG"/call_*/argv | grep -qx sonnet'
# availability
newlog mix6
n0=$(grep -c . "$AMASS_LEDGER")
out=$(AMASS_CODEX="$T/no-such-codex" "$AM" run --out "$T/mx6" --no-lens --whole 3 "$T/a.txt" 2>&1); rc=$?
check "auto with codex missing: one warning line naming it, everything on claude, one ledger line" '[ $rc -eq 0 ] && [ "$(echo "$out" | grep -c "warning")" = 1 ] && echo "$out" | grep -q "warning: codex is not usable" && [ "$(ncl)" = 3 ] && [ "$(ncx)" = 0 ] && [ "$(grep -c . "$AMASS_LEDGER")" = $((n0 + 1)) ] && [ "$(awk -F"\t" "\$7 != \"claude\"" "$T/mx6/runs.tsv" | wc -l | tr -d " ")" = 0 ]'
newlog mix7
out=$(fk FAKE_AUTH=apikey -- "$AM" run --out "$T/mx7" --no-lens --whole 3 "$T/a.txt" 2>&1); rc=$?
check "auto with the claude login unusable: one warning naming it, everything on codex" '[ $rc -eq 0 ] && echo "$out" | grep -q "warning: claude is not usable" && [ "$(ncl)" = 0 ] && [ "$(ncx)" = 3 ] && [ -s "$T/mx7/provider" ] && clean_scratch'
newlog mix8
out=$(fk FAKE_AUTH=apikey FAKE_CX=apikey -- "$AM" run --out "$T/mx8" --no-lens --whole 3 "$T/a.txt" 2>&1); rc=$?
check "auto with neither usable dies and names both" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ] && echo "$out" | grep -q "no usable provider" && echo "$out" | grep -q "claude.ai" && echo "$out" | grep -q "ChatGPT" && clean_scratch'
newlog mix9
out=$(AMASS_CODEX="$T/no-such-codex" "$AM" run --out "$T/mx9" --provider mix --no-lens --whole 3 "$T/a.txt" 2>&1); rc=$?
check "mix with codex missing dies and nothing is sent" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ] && echo "$out" | grep -q "mix needs both providers" && clean_scratch'
out=$(fk FAKE_AUTH=apikey -- "$AM" run --out "$T/mx9b" --provider mix --no-lens --whole 3 "$T/a.txt" 2>&1); rc=$?
check "mix with the claude login unusable dies and nothing is sent" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ] && clean_scratch'
# the input cap
head -c 160000 /dev/zero | tr '\0' x > "$T/m160"
newlog mix10
out=$("$AM" run --out "$T/mx10" --provider mix --no-lens --whole 2 --dry-run "$T/m160" 2>&1); rc=$?
check "the mixed cap is 150 KB (the stricter one)" '[ $rc -eq 2 ] && echo "$out" | grep -q "max-input-kb 150"'
out=$("$AM" run --out "$T/mx10" --provider mix --no-lens --whole 2 --max-input-kb 200 --dry-run "$T/m160" 2>&1); rc=$?
check "an explicit cap lifts it" '[ $rc -eq 0 ]'
out=$("$AM" run --out "$T/mx10" --no-lens --whole 2 "$T/m160" 2>&1); rc=$?
check "auto with both usable refuses 160 KB before sending anything" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ] && echo "$out" | grep -q "max-input-kb 150"'
out=$(AMASS_CODEX="$T/no-such-codex" "$AM" run --out "$T/mx10b" --no-lens --whole 2 --dry-run "$T/m160" 2>&1); rc=$?
check "a dry run checks no login, so auto plans for both and applies the mixed cap" '[ $rc -eq 2 ] && echo "$out" | grep -q "max-input-kb 150"'
head -c 200000 /dev/zero | tr '\0' x > "$T/m200"
out=$(fk FAKE_AUTH=apikey -- "$AM" run --out "$T/mx10c" --no-lens --whole 1 "$T/m200" 2>&1); rc=$?
check "auto that resolves to codex alone takes codex's 400 KB cap" '[ $rc -eq 0 ] && echo "$out" | grep -q "warning: claude is not usable"'
# interleaving: every lens tends to get both providers
newlog mix11
out=$("$AM" run --out "$T/mx11" --lens a=1 --lens b=2 --lens c=3 --lens d=4 --lens e=5 --lens f=6 --copies 2 "$T/a.txt" 2>&1); rc=$?
miss=0
for l in a b c d e f; do
  [ "$(cat "$T/mx11/raw/${l}_1.provider" "$T/mx11/raw/${l}_2.provider" | sort -u | wc -l | tr -d ' ')" = 2 ] || miss=$((miss + 1))
done
check "six lenses, two copies, 1:1: every lens got both providers (even prompt count included)" '[ $rc -eq 0 ] && [ "$miss" = 0 ] && [ "$(ncl)" = 6 ] && [ "$(ncx)" = 6 ]'
c0=$(calls)
out=$("$AM" run --out "$T/mx11b" --lens a=1 --lens b=2 --lens c=3 --copies 3 --dry-run "$T/a.txt" 2>&1)
check "a dry run plans (claude 5, codex 4 of 9) without sending" '[ "$(calls)" = "$c0" ] && echo "$out" | grep -q "^split: claude 5 (haiku), codex 4"'
# cancelling a mixed run reaps the codex workers and descendants
newlog mix12
defconf
printf 'export FAKE_CX=slow\n' >> "$T/conf.sh"
"$AM" run --out "$T/mx12" --no-lens --whole 4 "$T/a.txt" > "$T/mx-cancel.log" 2>&1 & cancel_pid=$!
tries=0
while [ "$tries" -lt 200 ] && ! ls "$FAKE_LOG"/call_*/child >/dev/null 2>&1; do sleep 0.05; tries=$((tries + 1)); done
kill -TERM "$cancel_pid" 2>/dev/null
wait "$cancel_pid"; rc=$?
defconf
alive_cx=0
for f in "$FAKE_LOG"/call_*/pid "$FAKE_LOG"/call_*/child; do
  [ -f "$f" ] || continue
  if kill -0 "$(cat "$f")" 2>/dev/null; then alive_cx=$((alive_cx + 1)); fi
done
# Codex calls pin a low reasoning effort unless --codex-effort says otherwise.
eff_argv=$(cat "$FAKE_LOG"/call_*/argv 2>/dev/null)
check "codex calls pass model_reasoning_effort=low by default" 'printf "%s\n" "$eff_argv" | grep -qx "model_reasoning_effort=\"low\""'
check "a bad --codex-effort is refused before anything is sent" '! "$AM" run --provider codex --codex-effort huge --out "$T/eff-bad" "$T/a.txt" >/dev/null 2>&1 && [ ! -e "$T/eff-bad" ]'
check "cancelling a mixed run exits 143, leaves no fake codex worker or child alive, and cleans scratch" '[ $rc -eq 143 ] && [ "$alive_cx" = 0 ] && ls "$FAKE_LOG"/call_*/pid >/dev/null 2>&1 && clean_scratch'
# docs
out=$("$AM" --help)
for doc in help readme; do
  if [ "$doc" = help ]; then printf '%s\n' "$out" > "$T/doc"; else cp "$REPO/README-amass.md" "$T/doc"; fi
  check "$doc documents mixed runs: auto, the split rule, the override and the two model flags" 'grep -q -- "--provider auto" "$T/doc" && grep -q -- "--split" "$T/doc" && grep -q "MEGAVIBE_AMASS_SPLIT" "$T/doc" && grep -q -- "--claude-model" "$T/doc" && grep -q -- "--codex-model" "$T/doc" && grep -q "150 KB" "$T/doc"'
done
check "the delegation rule says amass mixes Claude and Codex calls" 'grep -q "mixes Claude (Haiku) and Codex (luna) calls" "$REPO/template/.claude/rules/delegation.md"'

# 13. Review fixes: provider pin, supervised and reaped Claude workers, bounded pace probe, summaries, dedupe provider.
cxargv() { cat $(ls -d "$FAKE_LOG"/call_*/output 2>/dev/null | sed 's|/output$|/argv|'); }
wait_children() { # count
  local tries=0 c
  while [ "$tries" -lt 200 ]; do
    c=$(ls "$FAKE_LOG"/call_*/child 2>/dev/null | wc -l | tr -d ' ')
    [ "$c" -ge "$1" ] && return 0
    sleep 0.05; tries=$((tries + 1))
  done
  return 1
}
nalive() { # counts live pids named in pid/child files of the current log
  local f n=0
  for f in "$FAKE_LOG"/call_*/pid "$FAKE_LOG"/call_*/child; do
    [ -f "$f" ] || continue
    if kill -0 "$(cat "$f")" 2>/dev/null; then n=$((n + 1)); fi
  done
  echo "$n"
}
# F1: the built-in Codex provider is pinned on every call, worker and dedupe
newlog f1
out=$(PACE_CLAUDE=$PC150 PACE_CODEX=$PX225 "$AM" run --out "$T/f1" --no-lens --whole 4 "$T/a.txt" 2>&1)
"$AM" dedupe --provider codex --out "$T/f1" >/dev/null 2>&1
nx=$(ls -d "$FAKE_LOG"/call_*/output | wc -l | tr -d ' ')
check "every Codex worker and dedupe call pins the built-in provider" '[ "$nx" -ge 3 ] && [ "$(cxargv | grep -cx "model_provider=\"openai\"")" = "$nx" ]'
# F2: cancelling reaps Claude workers and their children too
newlog f2
defconf; printf 'export FAKE_MODE=hang\n' >> "$T/conf.sh"
"$AM" run --provider claude --out "$T/f2" --no-lens --whole 2 "$T/a.txt" > "$T/f2.log" 2>&1 & cancel_pid=$!
wait_children 1
kill -TERM "$cancel_pid" 2>/dev/null; wait "$cancel_pid"; rc=$?
defconf
check "cancelling a claude-only run exits 143 and leaves no claude worker or child alive" '[ $rc -eq 143 ] && ls "$FAKE_LOG"/call_*/child >/dev/null 2>&1 && [ "$(nalive)" = 0 ]'
newlog f2b
defconf; printf 'export FAKE_MODE=hang\n' >> "$T/conf.sh"
# a background job starts with SIGINT ignored; restore the default the way a terminal's foreground job has it
perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$AM" run --provider claude --out "$T/f2b" --no-lens --whole 1 "$T/a.txt" > "$T/f2b.log" 2>&1 & cancel_pid=$!
wait_children 1
kill -INT "$cancel_pid" 2>/dev/null; wait "$cancel_pid"; rc=$?
defconf
check "INT on a claude-only run exits 130 and reaps the worker" '[ $rc -eq 130 ] && [ "$(nalive)" = 0 ]'
newlog f2c
defconf; printf 'export FAKE_MODE=hang\n' >> "$T/conf.sh"
start=$(date +%s)
out=$("$AM" run --provider claude --out "$T/f2c" --no-lens --whole 1 --timeout 1 "$T/a.txt" 2>&1); rc=$?
dur=$(( $(date +%s) - start ))
defconf
check "a claude timeout is rc 124 and kills the worker's child" '[ $rc -eq 3 ] && [ $dur -lt 6 ] && grep -q "fail(rc=124)" "$T/f2c/runs.tsv" && [ "$(nalive)" = 0 ]'
newlog f2d
defconf; printf 'export FAKE_MODE=hang\nexport FAKE_CX=slow\n' >> "$T/conf.sh"
"$AM" run --out "$T/f2d" --no-lens --whole 4 "$T/a.txt" > "$T/f2d.log" 2>&1 & cancel_pid=$!
wait_children 2
kill -TERM "$cancel_pid" 2>/dev/null; wait "$cancel_pid"; rc=$?
defconf
ncpid=$(ls -d "$FAKE_LOG"/call_*/apikey 2>/dev/null | sed 's|/apikey$|/pid|' | while read -r f; do [ -f "$f" ] && echo x; done | wc -l | tr -d ' ')
check "cancelling a mixed run reaps claude and codex workers alike" '[ $rc -eq 143 ] && [ "$ncpid" -ge 1 ] && [ "$(nalive)" = 0 ] && clean_scratch'
# F3: a blocked pace probe is bounded and its leftovers are killed
cat > "$T/usage-block" <<'STUB'
#!/bin/bash
sleep 90 & echo $! >> "$PROBE_PIDS"
wait
STUB
chmod +x "$T/usage-block"
export PROBE_PIDS="$T/probe.pids"; : > "$PROBE_PIDS"
start=$(date +%s)
out=$(AMASS_PROBE_TIMEOUT=2 MEGAVIBE_AMASS_USAGE_ROUTE="$T/usage-block" "$AM" run --out "$T/f3" --no-lens --whole 2 --dry-run "$T/a.txt" 2>&1); rc=$?
dur=$(( $(date +%s) - start ))
lv=0; for p in $(cat "$PROBE_PIDS"); do kill -0 "$p" 2>/dev/null && lv=$((lv + 1)); done
check "a blocked pace probe is cut at its timeout, projections are unknown, nothing is left running" '[ $rc -eq 0 ] && [ $dur -lt 12 ] && echo "$out" | grep -q "projections claude ? (unknown), codex ? (unknown)" && [ "$lv" = 0 ] && clean_scratch'
# F4: the summary follows the providers actually used
newlog f4
out=$("$AM" run --out "$T/f4a" --no-lens --whole 1 --split 0:1 "$T/a.txt" 2>&1)
check "a mixed-mode run whose calls all went to codex prints the codex summary" 'echo "$out" | grep -q "tokens 1234" && ! echo "$out" | grep -q "worker cost"'
out=$(PACE_CLAUDE=$(pace "" 400 10) PACE_CODEX=$(pace "" 100 10) "$AM" run --out "$T/f4b" --no-lens --whole 1 "$T/a.txt" 2>&1)
check "one call on the lower-projection codex prints the codex summary, not a zero claude cost" 'echo "$out" | grep -q "tokens 1234" && ! echo "$out" | grep -q "worker cost"'
check "the summary subcommand agrees" '"$AM" summary --out "$T/f4b" | grep -q "tokens 1234"'
# F5: dedupe follows a forced provider, and --model needs a single provider
newlog f5
"$AM" run --provider claude --out "$T/f5a" --no-lens --whole 2 "$T/a.txt" >/dev/null 2>&1
out=$(PACE_CLAUDE=$(pace "" 300 10) PACE_CODEX=$(pace "" 100 10) "$AM" dedupe --out "$T/f5a" 2>&1)
check "plain dedupe after a --provider claude run stays on claude although codex has the lower projection" 'tail -1 "$AMASS_LEDGER" | jq -e ".cmd == \"dedupe\" and .provider == \"claude\"" >/dev/null'
"$AM" run --provider codex --out "$T/f5b" --no-lens --whole 2 "$T/a.txt" >/dev/null 2>&1
out=$(PACE_CLAUDE=$(pace "" 100 10) PACE_CODEX=$(pace "" 300 10) "$AM" dedupe --out "$T/f5b" 2>&1)
check "plain dedupe after a --provider codex run stays on codex" 'tail -1 "$AMASS_LEDGER" | jq -e ".cmd == \"dedupe\" and .provider == \"codex\"" >/dev/null'
out=$("$AM" dedupe --provider claude --out "$T/f5b" 2>&1)
check "an explicit dedupe --provider still overrides the recorded one" 'tail -1 "$AMASS_LEDGER" | jq -e ".cmd == \"dedupe\" and .provider == \"claude\"" >/dev/null'
newlog f5c
out=$("$AM" dedupe --model sonnet --out "$T/mx1" 2>&1); rc=$?
check "dedupe --model with two usable providers dies and points to the two flags" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ] && echo "$out" | grep -q -- "--claude-model and --codex-model"'
# F6: --ignore-rules only where this codex has it
newlog f6
out=$(cxrun ign 2>&1)
check "--ignore-rules is passed when codex exec --help lists it" 'cxargv | grep -qx -- --ignore-rules'
newlog f6b
out=$(fk FAKE_CX=noignore -- cxrun noign 2>&1); rc=$?
check "--ignore-rules is left off for a codex whose help lacks it, and the call still runs" '[ $rc -eq 0 ] && [ "$(calls)" = 1 ] && ! cxargv | grep -qx -- --ignore-rules'
# R2: the user's codex config (base URLs, providers, MCP, notify) is not loaded where codex supports it
newlog r2a
out=$(cxrun iuc 2>&1)
check "--ignore-user-config is passed when codex exec --help lists it" 'cxargv | grep -qx -- --ignore-user-config'
newlog r2b
out=$(fk FAKE_CX=noignore -- cxrun noiuc 2>&1); rc=$?
check "--ignore-user-config is left off for a codex whose help lacks it, and the call still runs" '[ $rc -eq 0 ] && [ "$(calls)" = 1 ] && ! cxargv | grep -qx -- --ignore-user-config'
# R2: --model under auto must name a model of the provider that remains
newlog r2c
out=$(fk FAKE_AUTH=apikey -- "$AM" run --model sonnet --out "$T/r2c" --no-lens --whole 2 "$T/a.txt" 2>&1); rc=$?
check "auto falling back to codex refuses a Claude --model instead of passing it to codex" '[ $rc -eq 2 ] && [ "$(calls)" = 0 ] && echo "$out" | grep -q -- "--model sonnet"'
# R2: --help ends with the usage block, not a dangling heading
out=$("$AM" --help 2>&1)
check "--help does not end on a dangling heading" '! echo "$out" | tail -1 | grep -q "Why it is built"'
# F7: docs say Codex workers are sandboxed, not tool-less
for doc in "$REPO/README-amass.md" "$REPO/README.md" "$REPO/template/.claude/rules/delegation.md"; do
  check "$(basename "$doc") says Codex workers run in a read-only sandbox and can read local files" 'grep -i "amass" "$doc" | grep -qi "read-only sandbox" && grep -i "amass\|codex worker" "$doc" | grep -qi "read local files\|read files"'
done

printf 'amass.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
