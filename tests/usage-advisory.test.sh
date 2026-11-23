#!/bin/bash
# /bin/bash tests/usage-advisory.test.sh — fixtures only: temp project, stub usage-route.sh, temp MEGAVIBE_HOME.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$REPO/template/.claude/hooks/usage-advisory.sh"
OLD_HOOK="${OLD_HOOK:-}"   # optional: a copy of the pre-change hook to compare against
T=$(mktemp -d "${TMPDIR:-/tmp}/usage-advisory.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
P="$T/proj"; mkdir -p "$P/.agent/LOGS" "$T/mv/scripts" "$T/home" "$T/tmpdir"
export TMPDIR="$T/tmpdir"
export HOME="$T/home" MEGAVIBE_HOME="$T/mv"
unset MEGAVIBE_ROUTER
cat > "$T/mv/scripts/usage-route.sh" <<'STUB'
#!/bin/bash
case "$1" in
  band) [ -n "${STUB_BAND_FAIL:-}" ] && exit 3; echo "${STUB_BAND:-normal}" ;;
  balance) echo "${STUB_BALANCE:--|}" ;;
  advisory) echo "${STUB_ADVISORY:-}" ;;
  sprint-advice)
    [ -n "${STUB_SPRINT_SLEEP:-}" ] && { { sleep "$STUB_SPRINT_SLEEP" & }; sleep "$STUB_SPRINT_SLEEP"; }
    [ -n "${STUB_SPRINT:-}" ] && printf '%s\n' "$STUB_SPRINT" ;;
  forecast) if [ "${MEGAVIBE_ROUTER_PROVIDER:-claude}" = codex ]; then echo "${STUB_FC_CODEX:-}"; else echo "${STUB_FC_CLAUDE:-}"; fi ;;
  pace)
    if [ -n "${STUB_SLEEP:-}" ]; then
      [ -n "${STUB_CHILD:-}" ] && { sleep "$STUB_SLEEP" & }   # a child that inherits stdout and outlives the stub
      sleep "$STUB_SLEEP"
    fi
    if [ "${MEGAVIBE_ROUTER_PROVIDER:-claude}" = codex ]; then echo "${STUB_PACE_CODEX:-codex||||||}"; else echo "${STUB_PACE_CLAUDE:-claude||||||}"; fi ;;
esac
STUB
FLAG="$P/.agent/LOGS/.usage-band.s1"
reset() { rm -f "$FLAG"; unset STUB_SLEEP STUB_CHILD STUB_SPRINT STUB_SPRINT_SLEEP STUB_FC_CLAUDE STUB_FC_CODEX STUB_BAND STUB_BALANCE STUB_ADVISORY STUB_BAND_FAIL; export STUB_PACE_CLAUDE='claude||||||' STUB_PACE_CODEX='codex||||||'; }
# pace line: provider|used|elapsed|linear|recent_rate|recent_proj|remaining
claude_pace() { export STUB_PACE_CLAUDE="claude|$1|$2|$3|$4|$5|3"; }
codex_pace() { export STUB_PACE_CODEX="codex|$1|$2|$3|$4|$5|3"; }
ev() { jq -nc --arg e "$1" '{hook_event_name:$e,session_id:"s1"}'; }
run() { (cd "$P" && bash "${H:-$HOOK}"); }
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

reset; claude_pace 50 40 147 '' ''; codex_pace 60 30 222 '' ''
o=$(ev SessionStart | run | ctx)
check 'SessionStart, known: exact line with both basis words' '[[ "$o" == *"usage router: projections claude 147 (linear), codex 222 (linear)"* ]]'

reset; claude_pace 50 40 147 90 120; codex_pace 60 30 222 '' ''
o=$(ev SessionStart | run | ctx)
check 'linear headline, recent shown beside it (the band and balance decide on linear)' '[[ "$o" == *"claude 147 (linear; recent 120)"* ]] && [[ "$o" == *"codex 222 (linear)"* ]]'
reset; claude_pace 50 40 147 90 120; codex_pace 60 30 222 '' ''; export STUB_FC_CLAUDE='claude|50|0.6|109.4|-14.4|0.5|6h+24h'
o=$(ev SessionStart | run | ctx)
check 'forecast leads the headline, linear shown beside it; a side without a forecast keeps linear' '[[ "$o" == *"claude 109 (forecast; linear 147)"* ]] && [[ "$o" == *"codex 222 (linear)"* ]]'
reset; claude_pace 50 40 '' 90 120; codex_pace 60 30 222 '' ''
o=$(ev SessionStart | run | ctx)
check 'recent alone still shows' '[[ "$o" == *"claude 50 (used; recent 120)"* ]]'
reset; claude_pace 50 40 147.9 '' ''; codex_pace 60 30 222 '' ''
o=$(ev SessionStart | run | ctx)
check 'truncated like the balance sentence (147.9 -> 147)' '[[ "$o" == *"claude 147 (linear)"* ]]'
reset; claude_pace 50 40 '' '' ''; codex_pace 61 30 '' '' ''
o=$(ev SessionStart | run | ctx)
check 'used when no projection' '[[ "$o" == *"claude 50 (used)"* ]] && [[ "$o" == *"codex 61 (used)"* ]]'
reset; claude_pace 50 40 147 '' ''
o=$(ev SessionStart | run | ctx)
check 'one unknown: speaks, other says unknown' '[[ "$o" == *"claude 147 (linear), codex unknown"* ]]'
reset
o=$(ev SessionStart | run)
check 'both unknown, normal band: silent' '[ -z "$o" ]'

reset; export STUB_BAND=under STUB_ADVISORY='upgrade.'
o=$(ev SessionStart | run | ctx)
check 'advisory band, projections unknown: advisory and a line with unknown' '[[ "$o" == "upgrade. usage router: projections claude unknown, codex unknown" ]] || [[ "$o" == *"upgrade."* && "$o" == *"projections claude unknown, codex unknown"* ]]'

reset; claude_pace 50 40 147 '' ''; codex_pace 60 30 222 '' ''
ev PreToolUse | run | ctx >/dev/null
o=$(ev PreToolUse | run)
check 'Agent path: identical state is silent' '[ -z "$o" ]'
reset; claude_pace 50 40 147 '' ''; codex_pace 60 30 222 '' ''
o=$(ev PreToolUse | run | ctx)
check 'Agent path: first call speaks' '[[ "$o" == *"claude 147 (linear), codex 222 (linear)"* ]]'
codex_pace 60 30 228 '' ''
o=$(ev PreToolUse | run)
check 'move inside the same 10-point bucket: silent' '[ -z "$o" ]'
codex_pace 60 30 131 '' ''
o=$(ev PreToolUse | run)
check 'every projection at 100 or more is one bucket: silent' '[ -z "$o" ]'
codex_pace 60 30 95 '' ''
o=$(ev PreToolUse | run | ctx)
check 'move to another bucket: speaks again' '[[ "$o" == *"codex 95 (linear)"* ]]'
printf 'normal:-' > "$FLAG"
o=$(ev PreToolUse | run | ctx)
check 'legacy two-field flag: speaks' '[[ "$o" == *"projections claude 147"* ]]'
printf 'normal' > "$FLAG"
o=$(ev PreToolUse | run | ctx)
check 'legacy bare-band flag: speaks' '[[ "$o" == *"projections claude 147"* ]]'

reset; claude_pace 50 40 147 '' ''; codex_pace 60 30 222 '' ''; export STUB_BAND_FAIL=1
o=$(ev SessionStart | run)
check 'failed band call: no projections line (as before: silent)' '[ -z "$o" ]'
unset STUB_BAND_FAIL

# bounded pace calls
reset; claude_pace 50 40 147 '' ''; codex_pace 60 30 222 '' ''; export STUB_SLEEP=30
s=$SECONDS; o=$(ev SessionStart | run); e=$((SECONDS - s))
check "slow pace stub: finishes in under 8 s ($e s), unknown" '[ "$e" -lt 8 ] && [ -z "$o" ]'
reset; claude_pace 50 40 147 '' ''; codex_pace 60 30 222 '' ''; export STUB_SLEEP=30 STUB_CHILD=1
s=$SECONDS; o=$(ev SessionStart | run); e=$((SECONDS - s))
check "slow stub with background child holding stdout: under 8 s ($e s)" '[ "$e" -lt 8 ] && [ -z "$o" ]'
echo "worst-case hook time: ${e}s"
reset; claude_pace 50 40 147 '' ''; codex_pace 60 30 222 '' ''
mkdir -p "$T/nobin"; for c in bash jq cat cut mkdir rm mktemp tr awk sed head printf; do p=$(command -v "$c") && [ -x "$p" ] && ln -sf "$p" "$T/nobin/$c"; done
o=$(ev SessionStart | (cd "$P" && PATH="$T/nobin" /bin/bash "$HOOK"); echo "rc=$?")
check 'no perl on PATH: exit 0, unknown, silent' '[ "$o" = "rc=0" ]'
check 'no temp files left behind' '[ -z "$(ls "$TMPDIR" | grep usage-pace)" ]'

# a bucket move under an unchanged band and preference re-sends only the projections line
reset; export STUB_BAND=under STUB_ADVISORY='upgrade advice.' STUB_BALANCE='claude|lean on claude.'; claude_pace 50 40 75 '' ''; codex_pace 60 30 222 '' ''
ev PreToolUse | run | ctx >/dev/null
claude_pace 50 40 69 '' ''
o=$(ev PreToolUse | run | ctx)
check 'bucket move, same band and preference: projections line only' '[ "$o" = "usage router: projections claude 69 (linear), codex 222 (linear)" ]'
# existing behaviour unchanged when projections are unknown (needs the old hook)
if [ -n "$OLD_HOOK" ] && [ -f "$OLD_HOOK" ]; then
  for case_ in "over|-|over advice." "under|-|under advice." "normal|codex|" "normal|claude|"; do
    IFS='|' read -r b p a <<<"$case_"
    for evn in SessionStart PreToolUse; do
      reset; export STUB_BAND=$b STUB_ADVISORY="$a" STUB_BALANCE="$p|lean on $p."
      [ "$p" = "-" ] && export STUB_BALANCE='-|'
      n=$(ev $evn | H="$HOOK" run | ctx); rm -f "$FLAG"
      old=$(ev $evn | H="$OLD_HOOK" run | ctx)
      stripped="${n% usage router: projections claude unknown, codex unknown}"
      stripped="${stripped#usage router: projections claude unknown, codex unknown}"
      check "unchanged vs old hook: $b/$p/$evn" '[ "$stripped" = "$old" ]'
    done
  done
fi

# ---- end-of-window sprint advice (usage-route.sh sprint-advice) ---------------------------------------------------
SC='usage sprint: Claude weekly window resets in 2.5 h. Top model tier on the hardest open work.'
SX='usage sprint: Codex weekly window resets in 1.0 h. Top model tier on the hardest open work.'
reset; claude_pace 90 98 91 '' ''; codex_pace 60 30 75 '' ''
ev PreToolUse | run | ctx >/dev/null; k0=$(cat "$FLAG")
check 'no sprint: the flag keeps its four fields (nothing changes for a session that never sprints)' '[ "$k0" = "normal:-:9:7" ]'
export STUB_SPRINT="$SC"
o=$(ev PreToolUse | run | ctx)
check 'sprint starts mid-session: the advice is spoken, with the projections line' '[[ "$o" == *"$SC"* ]] && [[ "$o" == *"projections claude 91"* ]]'
check 'sprint state is in the flag' '[ "$(cat "$FLAG")" = "normal:-:9:7:sc" ]'
o=$(ev PreToolUse | run)
check 'same sprint state: silent' '[ -z "$o" ]'
claude_pace 90 98 81 '' ''
o=$(ev PreToolUse | run | ctx)
check 'bucket move inside a sprint: projections line only' '[ "$o" = "usage router: projections claude 81 (linear), codex 75 (linear)" ]'
o=$(ev SessionStart | run | ctx)
check 'SessionStart restates the sprint advice' '[[ "$o" == *"$SC"* ]]'
export STUB_SPRINT="$SC
$SX"
o=$(ev PreToolUse | run | ctx)
check 'second subscription joins: both sentences' '[[ "$o" == *"$SC"* ]] && [[ "$o" == *"$SX"* ]] && [ "$(cat "$FLAG")" = "normal:-:8:7:scx" ]'
unset STUB_SPRINT
o=$(ev PreToolUse | run | ctx)
check 'sprint over (reset or target reached): withdrawn once, in words' '[[ "$o" == *"end-of-window sprint advice no longer applies"* ]] && [ "$(cat "$FLAG")" = "normal:-:8:7" ]'
o=$(ev PreToolUse | run)
check 'after the withdrawal: silent' '[ -z "$o" ]'
reset; export STUB_BAND=over STUB_ADVISORY='over advice.' STUB_SPRINT="$SC"; claude_pace 90 98 91 '' ''
o=$(ev SessionStart | run | ctx)
check 'over band and sprint together: band advice first, then the sprint sentence' '[[ "$o" == "over advice. $SC"* ]]'
reset; export STUB_SPRINT='something else entirely'; claude_pace 90 98 91 '' ''
o=$(ev SessionStart | run | ctx)
check 'output that is not a sprint sentence is never relayed' '[[ "$o" != *"something else"* ]] && [ "$(cat "$FLAG")" = "normal:-:9:u" ]'
reset; export STUB_SPRINT="$SC" STUB_SPRINT_SLEEP=30; claude_pace 90 98 91 '' ''
s=$SECONDS; o=$(ev SessionStart | run | ctx); e=$((SECONDS - s))
check "slow sprint call with a child holding stdout: under 10 s ($e s), no sprint text" '[ "$e" -lt 10 ] && [[ "$o" != *"usage sprint"* ]]'
reset; export STUB_SPRINT="$SC" STUB_BAND_FAIL=1
o=$(ev SessionStart | run)
check 'failed band call: silent, sprint included' '[ -z "$o" ]'
unset STUB_BAND_FAIL
check 'no temp files left behind (sprint)' '[ -z "$(ls "$TMPDIR" | grep usage-)" ]'
printf 'usage-advisory: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
