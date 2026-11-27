#!/usr/bin/env bash
# amass-gate.sh — the amass sweep before a reader round is MECHANICAL, not a thing to remember.
#
# the delegation skill ("Cut rounds before cutting readers") says: run `amass.sh run` + `dedupe` on the
# frozen candidate, triage the leads by execution, fix, and only then start a reader round. That
# rule was skipped almost every time it relied on being remembered, so codex-review.sh and
# claude-review.sh call this under --as-reviewer and refuse (exit 6) without one of:
#   - an `amass.sh run` recorded in the amass ledger for THIS directory within the window
#     (MEGAVIBE_AMASS_GATE_MINS, default 120; the ledger row is written only by a run that
#     reached a model, so --dry-run does not count) AND of THIS candidate: in a git checkout the
#     run row carries a fingerprint (a tree hash of the tracked content, every `.agent/` and
#     `megavibe-deliverables/` left out, taken when the sweep froze its input), and a run of
#     another fingerprint does not count. A fix edit or fix commit after the sweep therefore
#     needs a new sweep (it costs cents); committing exactly the swept content does not.
#   - `--no-amass "<category>[: note]"` on THAT review call. Only three categories exist, and the
#     script checks the first two against the files handed to the reviewer:
#       oversize  the review files (data files such as .csv/.log/images left out) exceed 140 KB
#                 (amass.sh caps its whole prompt, head and context included, at 150 KB)
#       prose     every file, and every path inside a .patch/.diff, is prose or data
#                 (.md .markdown .txt .rst .adoc .org .csv .tsv .log .pdf .png .jpg .jpeg)
#       hotfix    accepted unchecked, but a sweep is owed: `status` lists it until a sweep runs
#                 in that directory (for 7 days, so a deleted worktree does not nag forever).
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
CAP=143360   # 140 KB: amass.sh caps its whole prompt (head, change text, context) at 150 KB
OK_EXT=" md markdown txt rst adoc org csv tsv log pdf png jpg jpeg "
DATA_EXT=" csv tsv log pdf png jpg jpeg "

fingerprint() {
  # The CONTENT of the tracked files, not the commit: a tree hash of HEAD's index updated with
  # every tracked edit (git add -u on a copy of the index, so the stat cache keeps it fast; the copy
  # keeps the index's mtime, `cp -p`, or git's racy-clean check misses a same-second edit), with
  # every .agent/ and megavibe-deliverables/ dropped. Committing or amending exactly the swept
  # content keeps the fingerprint; a fix edit or a fix commit changes it. Independent of diff
  # settings (diff.external, color). Writes blob objects as `git stash create` does; any failure
  # prints nothing, and the gate then falls back to the window.
  local top idx tmp t
  top=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || return 0
  git -C "$top" rev-parse -q --verify HEAD >/dev/null 2>&1 || return 0
  idx=$(git -C "$top" rev-parse --path-format=absolute --git-path index 2>/dev/null) || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/amass-fp.XXXXXX") || return 0
  if [ -f "$idx" ]; then cp -p "$idx" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }; else : > "$tmp"; fi
  t=$( cd "$top" && export GIT_INDEX_FILE="$tmp" && { [ -s "$tmp" ] || git read-tree HEAD; } \
       && git add -u -- . 2>/dev/null \
       && git rm --cached -r -q --ignore-unmatch -- ':(glob)**/.agent/**' ':(glob)**/megavibe-deliverables/**' >/dev/null 2>&1 \
       && git write-tree 2>/dev/null )
  rm -f "$tmp" "$tmp.lock" 2>/dev/null
  [ -n "$t" ] && printf 'tree:%s' "$t"
}
ext_of() { local b=${1##*/}; case $b in *.*) printf '%s' "${b##*.}" | tr 'A-Z' 'a-z' ;; esac; }
# every path a patch touches, from each header form git writes (renames, copies, binary and
# mode-only changes have no ---/+++ lines); quotes around escaped names are dropped
patch_paths() {
  local r
  for r in 's#^diff --git a/.* b/(.*)$#\1#p' 's#^\+\+\+ b/(.*)$#\1#p' 's#^--- a/(.*)$#\1#p' 's#^(rename|copy) (from|to) (.*)$#\3#p' \
           's#^Binary files a/(.*) and b/.* differ$#\1#p' 's#^Binary files .* and b/(.*) differ$#\1#p'; do
    tr -d '"' < "$1" | sed -nE "$r"
  done | sed 's/[[:space:]]*$//' | sort -u
}
in_set() { [ -n "$1" ] && case $2 in *" $1 "*) return 0 ;; esac; return 1; }

case ${1:-check} in
  fingerprint) fingerprint; echo ;;
  waive)
    reason=$(printf '%s' "${2:-}" | tr -d '[:cntrl:]' | cut -c1-200); shift 2 2>/dev/null || shift $#
    cat=$(printf '%s' "$reason" | sed -nE 's/^[[:space:]]*([A-Za-z]+)([[:space:]:,].*)?$/\1/p' | tr 'A-Z' 'a-z')
    case $cat in
      oversize)
        total=0; n=0
        for f in "$@"; do
          [ -f "$f" ] || continue; in_set "$(ext_of "$f")" "$DATA_EXT" && continue
          total=$((total + $(wc -c < "$f"))); n=$((n + 1))
        done
        [ "$total" -gt "$CAP" ] || { echo "amass-gate: --no-amass oversize refused: the review files come to $((total / 1024)) KB ($n non-data files), not over 140 KB. Sweep them (amass.sh run; raise --max-input-kb if its prompt is just over 150 KB), or split them by file group." >&2; exit 2; } ;;
      prose)
        [ $# -gt 0 ] || { echo "amass-gate: --no-amass prose refused: no files were passed to check" >&2; exit 2; }
        for f in "$@"; do
          e=$(ext_of "$f")
          if [ "$e" = patch ] || [ "$e" = diff ]; then
            paths=$(patch_paths "$f" 2>/dev/null)
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
  oversize  the review files exceed 140 KB (checked)    prose  only prose/data files change (checked)
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
      echo "amass-gate: the sweep recorded here in the last $MINS minutes was of other content (a tracked edit or a fix commit since), so this reader round is refused. Sweep the current candidate:" >&2
    else
      echo "amass-gate: no amass sweep recorded for \"$PWD\" in the last $MINS minutes, so this reader round is refused." >&2
      echo "Run the sweep on the frozen candidate first (cents; the delegation skill, \"Cut rounds before cutting readers\"):" >&2
    fi
    cat >&2 <<'EOF'
  ~/.megavibe/scripts/amass.sh run --out <dir> --change "<what changed, what to hunt>" FILE... [--context FILE...]
  ~/.megavibe/scripts/amass.sh dedupe --out <dir>     # then triage the clusters by running their exact inputs
Waivers exist only for --no-amass "oversize: ..." (files over 140 KB), "prose: ..." (prose-only change), both checked, and "hotfix: ..." (a sweep is then owed).
EOF
    exit 6
    ;;
  status)
    h=${2:-24}; case $h in ''|*[!0-9]*) h=24 ;; esac
    command -v jq >/dev/null 2>&1 && [ -r "$LEDGER" ] || exit 0
    grep -E '"cmd": *"(waive|run)"' "$LEDGER" 2>/dev/null | jq -R -s -r --argjson now "$(date +%s)" --argjson cut $(( $(date +%s) - h * 3600 )) --arg h "$h" '
      [split("\n")[] | fromjson? | select(type == "object")
        | . + {t: ((.ts // "") | tostring | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0)}]
      | to_entries | map(.value + {i: .key}) as $rows
      | [$rows[] | select(.cmd == "waive" and .t >= $cut)] as $w
      | [$rows[] | select(.cmd == "waive" and (.category // "") == "hotfix" and .t >= ($now - 7 * 86400)) as $x
          | select(any($rows[]; .cmd == "run" and ((.ok | tonumber? // 0) > 0) and .cwd == $x.cwd and .i > $x.i) | not) | $x.project] | unique as $owed
      | if ($w | length) == 0 and ($owed | length) == 0 then empty else
          "amass waivers (last \($h) h): \($w | length)"
          + (if ($w | length) > 0 then " (" + ($w | group_by(.category // "unchecked") | map("\(.[0].category // "unchecked") \(length)") | join(", ")) + ")" else "" end)
          + (if ($owed | length) > 0 then "; hotfix sweeps owed: " + ($owed | join(", ")) else "" end)
        end' 2>/dev/null
    ;;
  *) echo "usage: amass-gate.sh check | waive <reason> [FILE...] | fingerprint | status [HOURS]" >&2; exit 2 ;;
esac
