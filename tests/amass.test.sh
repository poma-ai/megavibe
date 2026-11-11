#!/bin/bash
# /bin/bash tests/amass.test.sh
# scripts/amass.sh against a FAKE claude on AMASS_CLAUDE: nothing here calls the real
# claude or sends anything. The fake records the flags, the environment and the prompt of
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
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
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

printf 'amass.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
