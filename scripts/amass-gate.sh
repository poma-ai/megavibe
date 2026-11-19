#!/usr/bin/env bash
# amass-gate.sh — the amass sweep before a reader round is MECHANICAL, not a thing to remember.
#
# delegation.md ("Cut rounds before cutting readers") says: run `amass.sh run` + `dedupe` on the
# frozen candidate, triage the leads by execution, fix, and only then start a reader round. That
# rule was skipped almost every time it relied on being remembered, so codex-review.sh and
# claude-review.sh call this under --as-reviewer and refuse (exit 6) without one of:
#   - an `amass.sh run` recorded in the amass ledger for THIS directory within the window
#     (MEGAVIBE_AMASS_GATE_MINS, default 120; the ledger row is written only by a run that
#     reached a model, so --dry-run does not count) AND of THIS candidate: in a git checkout the
#     run row carries a fingerprint (HEAD plus the tracked working-tree diff, `.agent/` and
#     `megavibe-deliverables/` left out), and a run of another fingerprint does not count. A fix
#     commit or a fix edit after the sweep therefore needs a new sweep; it costs cents.
#   - `--no-amass "<category>[: note]"` on THAT review call. Only three categories exist, and the
#     script checks the first two against the files handed to the reviewer:
#       oversize  the review files (data files such as .csv/.log/images left out) exceed 150 KB
#       prose     every file, and every path inside a .patch/.diff, is prose or data
#                 (.md .markdown .txt .rst .adoc .org .csv .tsv .log .pdf .png .jpg .jpeg)
#       hotfix    accepted unchecked, but a sweep is owed: `status` lists it until a sweep runs
#                 in that directory.
#     Anything else ("sweep ran earlier on the branch", "small diff", "another author's PR") is
#     refused (exit 2): an audit on 2026-11-19 found about 52 of 71 free-text waivers outside the
#     documented exemptions, and readers found defects in most of the waived re-review rounds.
#     A waiver authorizes only that call and is recorded as a ledger row.
#
#   amass-gate.sh check                       exit 0 passes, 6 blocks (prints why and the command to run)
#   amass-gate.sh waive "<reason>" [FILE...]  record a waiver; exit 2 refuses it
#   amass-gate.sh fingerprint                 print this directory's candidate fingerprint (empty outside git)
#   amass-gate.sh status [HOURS]              one line on waivers in the last HOURS (24), owed hotfix sweeps; silent when none
# Project key = the full working directory ($PWD; rows from before it was recorded fall back to the
# basename). Known limits: a reminder with a recorded escape hatch, not authentication (the caller
# controls the env switch and the ledger path); outside a git checkout, and for untracked files, only
# the window applies; the category checks trust the file list the caller passed. A run counts only if
# at least one of its calls succeeded. MEGAVIBE_AMASS_GATE=0 switches the gate off (a setting, like
# MEGAVIBE_REVIEWERS, not a failure). Fails OPEN on anything that is not a clear "no sweep" (no jq):
# a broken helper must never silence a reviewer.
set -uo pipefail

LEDGER=${AMASS_LEDGER:-$HOME/.megavibe/amass-usage.jsonl}
MINS=${MEGAVIBE_AMASS_GATE_MINS:-120}
case $MINS in ''|*[!0-9]*|??????*) MINS=120 ;; esac
PROJ=$(basename "$PWD")
CAP=153600
OK_EXT=" md markdown txt rst adoc org csv tsv log pdf png jpg jpeg "
DATA_EXT=" csv tsv log pdf png jpg jpeg "

fingerprint() {
  local top h d
  top=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || return 0
  h=$(git -C "$top" rev-parse HEAD 2>/dev/null) || return 0
  d=$(git -C "$top" diff HEAD --binary -- . ':(exclude).agent' ':(exclude)megavibe-deliverables' 2>/dev/null | shasum -a 256 | cut -c1-16)
  printf '%s:%s' "$h" "$d"
}
ext_of() { local b=${1##*/}; case $b in *.*) printf '%s' "${b##*.}" | tr 'A-Z' 'a-z' ;; esac; }
in_set() { [ -n "$1" ] && case $2 in *" $1 "*) return 0 ;; esac; return 1; }

case ${1:-check} in
  fingerprint) fingerprint; echo ;;
  waive)
    reason=$(printf '%s' "${2:-}" | tr -d '[:cntrl:]' | cut -c1-200); shift 2 2>/dev/null || shift $#
    cat=$(printf '%s' "$reason" | sed -E 's/^[[:space:]]*([A-Za-z]*).*/\1/' | tr 'A-Z' 'a-z')
    case $cat in
      oversize)
        total=0; n=0
        for f in "$@"; do
          [ -f "$f" ] || continue; in_set "$(ext_of "$f")" "$DATA_EXT" && continue
          total=$((total + $(wc -c < "$f"))); n=$((n + 1))
        done
        [ "$total" -gt "$CAP" ] || { echo "amass-gate: --no-amass oversize refused: the review files come to $((total / 1024)) KB ($n non-data files), not over 150 KB. Sweep them, or split them by file group." >&2; exit 2; } ;;
      prose)
        [ $# -gt 0 ] || { echo "amass-gate: --no-amass prose refused: no files were passed to check" >&2; exit 2; }
        for f in "$@"; do
          e=$(ext_of "$f")
          if [ "$e" = patch ] || [ "$e" = diff ]; then
            paths=$(sed -nE 's#^\+\+\+ b/(.*)$#\1#p; s#^--- a/(.*)$#\1#p' "$f" 2>/dev/null | sed 's/[[:space:]]*$//' | sort -u)
            [ -n "$paths" ] || { echo "amass-gate: --no-amass prose refused: $f names no changed paths" >&2; exit 2; }
            while IFS= read -r p; do
              in_set "$(ext_of "$p")" "$OK_EXT" || { echo "amass-gate: --no-amass prose refused: $f changes $p, which is not prose" >&2; exit 2; }
            done <<< "$paths"
          else
            in_set "$e" "$OK_EXT" || { echo "amass-gate: --no-amass prose refused: $f is not prose" >&2; exit 2; }
          fi
        done ;;
      hotfix) ;;
      *) cat >&2 <<'EOF'
amass-gate: --no-amass refused: the reason must start with oversize, prose or hotfix (e.g. --no-amass "prose: README wording").
  oversize  the review files exceed 150 KB (checked)    prose  only prose/data files change (checked)
  hotfix    urgent fix reviewed after the ship (a sweep is owed and shown at session start)
A re-review after a fix round, a small diff or another author's PR is not a waiver: run the sweep, it costs cents.
EOF
         exit 2 ;;
    esac
    command -v jq >/dev/null 2>&1 || { echo "amass-gate: jq missing, waiver not recorded; proceeding" >&2; exit 0; }
    mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "$PROJ" --arg c "$PWD" --arg r "$reason" --arg k "$cat" \
      '{ts:$ts,cmd:"waive",category:$k,project:$p,cwd:$c,reason:$r}' >> "$LEDGER" 2>/dev/null \
      || { echo "amass-gate: WARNING could not record the waiver in $LEDGER; proceeding (the ledger is the only record of it)" >&2; exit 0; }
    echo "amass-gate: $cat waiver recorded for $PROJ: $reason" >&2
    ;;
  check)
    [ "${MEGAVIBE_AMASS_GATE:-1}" = 0 ] && exit 0
    command -v jq >/dev/null 2>&1 || { echo "amass-gate: jq missing, gate skipped" >&2; exit 0; }
    if [ -e "$LEDGER" ] && [ ! -r "$LEDGER" ]; then
      echo "amass-gate: $LEDGER exists but cannot be read, gate skipped" >&2; exit 0
    fi
    now=$(date +%s); fp=$(fingerprint); recent=0; ok=0
    if [ -r "$LEDGER" ]; then
      # line by line: one malformed row must not disable the gate for every other row
      sel=$(jq -R -r --arg p "$PROJ" --arg c "$PWD" --argjson cut $((now - MINS * 60)) \
        'fromjson? | select(type == "object" and .cmd == "run" and ((.ok | tonumber? // 0) > 0) and ((.cwd // "") == $c or ((.cwd // "") == "" and .project == $p))
           and ((.ts | tostring | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0) >= $cut)) | (if (.fingerprint // "") == "" then "-" else .fingerprint end)' "$LEDGER" 2>/dev/null) || exit 0
      recent=$(printf '%s' "$sel" | grep -c . || true)
      # a row without a fingerprint ("-": an older amass.sh, or a run outside git) counts by the window alone
      ok=$(printf '%s\n' "$sel" | awk -v fp="$fp" '$0 == "" {next} $0 == "-" || fp == "" || $0 == fp {n++} END {print n+0}')
    fi
    case $ok in ''|*[!0-9]*) exit 0 ;; esac   # unreadable ledger content: fail open
    [ "$ok" -gt 0 ] && exit 0
    if [ "${recent:-0}" -gt 0 ]; then
      echo "amass-gate: the sweep recorded here in the last $MINS minutes was of another candidate (a commit or a tracked edit since), so this reader round is refused. Sweep the current candidate:" >&2
    else
      echo "amass-gate: no amass sweep recorded for \"$PWD\" in the last $MINS minutes, so this reader round is refused." >&2
      echo "Run the sweep on the frozen candidate first (cents; delegation.md, \"Cut rounds before cutting readers\"):" >&2
    fi
    cat >&2 <<'EOF'
  ~/.megavibe/scripts/amass.sh run --out <dir> --change "<what changed, what to hunt>" FILE... [--context FILE...]
  ~/.megavibe/scripts/amass.sh dedupe --out <dir>     # then triage the clusters by running their exact inputs
Waivers exist only for --no-amass "oversize: ..." (files over 150 KB), "prose: ..." (prose-only change), both checked, and "hotfix: ..." (a sweep is then owed).
EOF
    exit 6
    ;;
  status)
    h=${2:-24}; case $h in ''|*[!0-9]*) h=24 ;; esac
    command -v jq >/dev/null 2>&1 && [ -r "$LEDGER" ] || exit 0
    jq -R -s -r --argjson cut $(( $(date +%s) - h * 3600 )) --arg h "$h" '
      [split("\n")[] | fromjson? | select(type == "object")
        | . + {t: ((.ts // "") | tostring | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0)}] as $rows
      | [$rows[] | select(.cmd == "waive" and .t >= $cut)] as $w
      | [$rows[] | select(.cmd == "waive" and (.category // "") == "hotfix") as $x
          | select(any($rows[]; .cmd == "run" and ((.ok | tonumber? // 0) > 0) and .cwd == $x.cwd and .t >= $x.t) | not) | $x.project] | unique as $owed
      | if ($w | length) == 0 and ($owed | length) == 0 then empty else
          "amass waivers (last \($h) h): \($w | length)"
          + (if ($w | length) > 0 then " (" + ($w | group_by(.category // "unchecked") | map("\(.[0].category // "unchecked") \(length)") | join(", ")) + ")" else "" end)
          + (if ($owed | length) > 0 then "; hotfix sweeps owed: " + ($owed | join(", ")) else "" end)
        end' "$LEDGER" 2>/dev/null
    ;;
  *) echo "usage: amass-gate.sh check | waive <reason> [FILE...] | fingerprint | status [HOURS]" >&2; exit 2 ;;
esac
