#!/usr/bin/env bash
# amass-gate.sh — the amass sweep before a reader round is MECHANICAL, not a thing to remember.
#
# delegation.md ("Cut rounds before cutting readers") says: run `amass.sh run` + `dedupe` on the
# frozen candidate, triage the leads by execution, fix, and only then start a reader round. That
# rule was skipped almost every time it relied on being remembered, so codex-review.sh and
# claude-review.sh call this under --as-reviewer and refuse (exit 6) without one of:
#   - an `amass.sh run` recorded in the amass ledger for THIS project within the window
#     (MEGAVIBE_AMASS_GATE_MINS, default 120; the ledger row is written only by a run that
#     reached a model, so --dry-run does not count), or
#   - `--no-amass "<reason>"` on THAT review call (input over the 150 KB cap, a pure prose change,
#     an urgent hotfix review after the ship). It authorizes only that call, and is recorded as a
#     ledger row, so a pattern of waivers is visible, not silent.
# Re-sweep after a fix batch: a sweep older than the window no longer counts, and a fix round
# takes longer than the window only in slow sessions; run the sweep again, it costs cents.
#
#   amass-gate.sh check             exit 0 passes, 6 blocks (prints why and the command to run)
#   amass-gate.sh waive "<reason>"  record a waiver (reason of 3+ characters; exit 2 if it could not be recorded)
# Project key = the full working directory ($PWD; rows from before it was recorded fall back to the
# basename). Known limits: a reminder with a recorded escape hatch, not authentication (the caller
# controls the env switch and the ledger path), and it checks the sweep's age, not that the sweep covered
# the candidate now under review. MEGAVIBE_AMASS_GATE=0 switches
# the gate off (a setting, like MEGAVIBE_REVIEWERS, not a failure). Fails OPEN on anything that
# is not a clear "no sweep" (no jq): a broken helper must never silence a reviewer.
set -uo pipefail

LEDGER=${AMASS_LEDGER:-$HOME/.megavibe/amass-usage.jsonl}
MINS=${MEGAVIBE_AMASS_GATE_MINS:-120}
case $MINS in ''|*[!0-9]*|??????*) MINS=120 ;; esac
PROJ=$(basename "$PWD")

cmd=${1:-check}
case $cmd in
  waive)
    reason=$(printf '%s' "${2:-}" | tr -d '[:cntrl:]' | cut -c1-200)
    [ "${#reason}" -ge 3 ] || { echo "amass-gate: --no-amass needs a reason (3+ characters)" >&2; exit 2; }
    command -v jq >/dev/null 2>&1 || { echo "amass-gate: jq missing, waiver not recorded" >&2; exit 2; }
    mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "$PROJ" --arg c "$PWD" --arg r "$reason" \
      '{ts:$ts,cmd:"waive",project:$p,cwd:$c,reason:$r}' >> "$LEDGER" 2>/dev/null \
      || { echo "amass-gate: could not write the waiver to $LEDGER" >&2; exit 2; }
    echo "amass-gate: waiver recorded for $PROJ: $reason" >&2
    ;;
  check)
    [ "${MEGAVIBE_AMASS_GATE:-1}" = 0 ] && exit 0
    command -v jq >/dev/null 2>&1 || { echo "amass-gate: jq missing, gate skipped" >&2; exit 0; }
    now=$(date +%s)
    ok=0
    if [ -r "$LEDGER" ]; then
      # line by line: one malformed row must not disable the gate for every other row
      ok=$(jq -R -r --arg p "$PROJ" --arg c "$PWD" --argjson cut $((now - MINS * 60)) \
        'fromjson? | select(type == "object" and .cmd == "run" and ((.cwd // "") == $c or ((.cwd // "") == "" and .project == $p))
           and ((.ts | tostring | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0) >= $cut)) | 1' "$LEDGER" 2>/dev/null | wc -l | tr -d ' ') || ok=0
    fi
    case $ok in ''|*[!0-9]*) exit 0 ;; esac   # unreadable ledger content: fail open
    [ "$ok" -gt 0 ] && exit 0
    cat >&2 <<EOF
amass-gate: no amass sweep recorded for project "$PROJ" in the last $MINS minutes, so this reader round is refused.
Run the sweep on the frozen candidate first (cents; delegation.md, "Cut rounds before cutting readers"):
  ~/.megavibe/scripts/amass.sh run --out <dir> --change "<what changed, what to hunt>" FILE... [--context FILE...]
  ~/.megavibe/scripts/amass.sh dedupe --out <dir>     # then triage the clusters by running their exact inputs
or, when a sweep cannot apply (input over 150 KB, a prose-only change), pass --no-amass "<reason>" to the review call: it is recorded.
EOF
    exit 6
    ;;
  *) echo "usage: amass-gate.sh check | waive <reason>" >&2; exit 2 ;;
esac
