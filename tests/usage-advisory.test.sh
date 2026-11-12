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
  pace)
    if [ -n "${STUB_SLEEP:-}" ]; then
      [ -n "${STUB_CHILD:-}" ] && { sleep "$STUB_SLEEP" & }   # a child that inherits stdout and outlives the stub
      sleep "$STUB_SLEEP"
    fi
    if [ "${MEGAVIBE_ROUTER_PROVIDER:-claude}" = codex ]; then echo "${STUB_PACE_CODEX:-codex||||||}"; else echo "${STUB_PACE_CLAUDE:-claude||||||}"; fi ;;
esac
STUB
FLAG="$P/.agent/LOGS/.usage-band.s1"
reset() { rm -f "$FLAG"; unset STUB_SLEEP STUB_CHILD STUB_BAND STUB_BALANCE STUB_ADVISORY STUB_BAND_FAIL; export STUB_PACE_CLAUDE='claude||||||' STUB_PACE_CODEX='codex||||||'; }
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
printf 'usage-advisory: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
