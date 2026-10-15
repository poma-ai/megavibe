#!/bin/bash
# second-opinion.sh — a second opinion on a hard, well-posed problem, from Codex.
#
# For a stuck Fable/Opus session or subtask: send the problem plus the facts you have
# gathered, ask for (1) the most likely causes, ranked, with their evidence, and (2) what
# the reader would check that you have not. Measured 2026-10-09 (the Codex model benchmark
# in megavibe-deliverables): gpt-6-astra at high effort gave the best second opinion on a
# well-posed hard problem, fastest; xhigh added time, not quality. This is a SECOND
# OPINION, not a review: it does not gate anything (use codex-review.sh --as-reviewer for
# reviews), and weighing the answer is still the caller's job.
#
# Usage:
#   second-opinion.sh --problem "what is wrong / what you tried" [--model M] [--timeout N]
#                     [--out FILE] [FILE...]
# FILE... are the facts: logs, a failing test, the relevant source, a diff. They are appended
# to the prompt by codex-review.sh. Codex runs in a throwaway scratch directory (the project
# stays read-only, no network) so it can run what you give it. The answer goes to stdout (and
# --out). Run it in the background for a long call. Model: --model, else
# $MEGAVIBE_SECOND_OPINION_MODEL, else gpt-6-astra; if the default model is not on the plan
# the call is retried ONCE with the user's own configured model.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROBLEM=""; MODEL=""; TIMEOUT=900; OUT=""; FILES=()
need(){ [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --problem) need "$@"; PROBLEM="$2"; shift 2 ;;
    --model)   need "$@"; MODEL="$2"; shift 2 ;;
    --timeout) need "$@"; TIMEOUT="$2"; shift 2 ;;
    --out)     need "$@"; OUT="$2"; shift 2 ;;
    -h|--help) awk 'NR >= 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    --)        shift; FILES+=("$@"); break ;;
    -*)        echo "unknown arg: $1" >&2; exit 2 ;;
    *)         FILES+=("$1"); shift ;;
  esac
done
[ -n "$(printf '%s' "$PROBLEM" | tr -d '[:space:]')" ] || { echo "error: --problem is required" >&2; exit 2; }
[ -x "$HERE/codex-review.sh" ] || [ -f "$HERE/codex-review.sh" ] || { echo "error: codex-review.sh not found next to this script" >&2; exit 1; }
case "$TIMEOUT" in ''|*[!0-9]*) echo "error: --timeout must be a number" >&2; exit 2 ;; esac

PROMPT=$(cat <<EOF
You are giving a second opinion to an engineer who is stuck on a hard problem. You have not seen their work: judge only from what is below and from what you can run in your scratch directory, and say what you could not verify.

PROBLEM AND WHAT HAS BEEN TRIED:
$PROBLEM

Answer in exactly two parts.
1. Most likely causes, ranked, each with the evidence for it and the evidence against it.
2. What would you check that they have not? Concrete commands, inspections or experiments, cheapest first.
Be specific and short. Do not restate the problem. Do not give generic advice.
EOF
)

EXPLICIT_MODEL="$MODEL"
[ -n "$MODEL" ] || MODEL="${MEGAVIBE_SECOND_OPINION_MODEL:-gpt-6-astra}"
call() {  # $1 = model or empty
  bash "$HERE/codex-review.sh" --scratch ${1:+--model "$1"} --effort high --timeout "$TIMEOUT" \
    ${OUT:+--out "$OUT"} --prompt "$PROMPT" ${FILES[@]+"${FILES[@]}"}
}
set +e
call "$MODEL" 2>"${TMPDIR:-/tmp}/second-opinion.$$.err"
RC=$?
set -e
if [ "$RC" -eq 1 ] && [ -z "$EXPLICIT_MODEL" ] && [ -z "${MEGAVIBE_SECOND_OPINION_MODEL:-}" ]; then
  # most likely the default model is not on this plan: once, with the user's own model
  echo "note: $MODEL failed ($(tail -1 "${TMPDIR:-/tmp}/second-opinion.$$.err" | cut -c1-160)); retrying once with the configured model" >&2
  set +e; call "" 2>"${TMPDIR:-/tmp}/second-opinion.$$.err"; RC=$?; set -e
fi
cat "${TMPDIR:-/tmp}/second-opinion.$$.err" >&2 || true
rm -f "${TMPDIR:-/tmp}/second-opinion.$$.err"
exit "$RC"
