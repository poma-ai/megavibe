#!/usr/bin/env bash
# Measure what a session actually cost, from the Claude Code transcript.
#
# Claude Code writes one JSONL per session to
# ~/.claude/projects/<slugified-cwd>/<session-id>.jsonl. That is ground truth —
# this script only adds it up. Nothing here estimates.
#
# The one trap: a transcript line is a CONTENT BLOCK, not an API response. A
# reply with a thinking block and two tool calls is three lines, each carrying
# an identical copy of `message.usage`. Summing lines inflates every token
# figure by 2-3x, varying per session, so responses are deduplicated by
# `message.id` before anything is added.
#
# The token numbers are NOT interchangeable:
#   context total — per-window peaks summed. Compaction throws the window away
#                   and starts again, so a session that compacted twice occupied
#                   three windows. Equal to peak context when nothing compacted.
#   peak context  — the fullest single window. Comparable to a task
#                   notification's `subagent_tokens` (measured within 4%).
#   generated     — output tokens. What the model actually produced.
#   new material  — input + output + the cache creation that grew the window.
#                   A prefix-cache rebuild reports the whole window as cache
#                   creation again; that repeat is excluded. Distinct content
#                   that entered the window. Compare THIS against an estimate.
#   processed     — + cache reads. Everything the API saw, re-sent each turn, so
#                   it scales with turn count rather than with work done.
#
# usage: session-cost.sh [--session ID] [--dir PROJECT] [--base GIT_REF] [--json]
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "session-cost: jq required" >&2; exit 1; }

SESSION=""; PROJECT="$PWD"; BASE=""; JSON=0
need_value() { [ "$2" -ge 2 ] || { echo "session-cost: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --session) need_value "$1" $#; SESSION="$2"; shift 2 ;;
    --dir)     need_value "$1" $#; PROJECT="$2"; shift 2 ;;
    --base)    need_value "$1" $#; BASE="$2";    shift 2 ;;
    --json)    JSON=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "session-cost: unknown argument: $1" >&2; exit 2 ;;
  esac
done

PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || { echo "session-cost: no such directory" >&2; exit 1; }
SLUG="$(printf '%s' "$PROJECT" | sed 's|[/._]|-|g')"
# macOS resolves /tmp to /private/tmp, and Claude Code slugs whichever spelling
# it was launched with. Try the other one, and keep whichever won — the
# subagent lookup below builds on the same slug.
if [ ! -d "$HOME/.claude/projects/$SLUG" ]; then
  for alt in "-private$SLUG" "${SLUG#-private}"; do
    [ -d "$HOME/.claude/projects/$alt" ] && { SLUG="$alt"; break; }
  done
fi
PDIR="$HOME/.claude/projects/$SLUG"
[ -d "$PDIR" ] || { echo "session-cost: no transcripts for $PROJECT (looked in $PDIR)" >&2; exit 1; }

if [ -n "$SESSION" ]; then
  T="$PDIR/$SESSION.jsonl"
  [ -f "$T" ] || { echo "session-cost: no transcript $T" >&2; exit 1; }
else
  # Newest by mtime: the live session is the one still being appended to.
  # `|| true`: an empty dir makes ls exit 1, and under pipefail+errexit that
  # kills the script before the error message below can explain why.
  T="$(ls -t "$PDIR"/*.jsonl 2>/dev/null | head -1 || true)"
  [ -n "$T" ] || { echo "session-cost: no transcripts in $PDIR" >&2; exit 1; }
fi
SID="$(basename "$T" .jsonl)"

# Shared by the session and each subagent: collapse content-block lines into one
# record per API response, in chronological order, dropping the zero-usage
# `<synthetic>` entries Claude Code writes for interrupts, API errors and
# "Login expired" — their context reads as 0 and would look like a compaction.
read -r -d '' RESPONSES <<'JQ' || true
def responses:
  # Walk every entry in order. A `<synthetic>` assistant entry (interrupt, API
  # error, expired login) carries zero usage and is dropped. A user entry with
  # isCompactSummary:true is the compaction marker Claude Code writes: the next
  # response after it opens a new window, so it is carried as `reset` on that
  # response. Key on message.id, falling back to a row counter — a shared
  # literal fallback would collapse every response in a transcript that lacks
  # ids into one. Assumes one id = one response: across 240 transcripts no id
  # ever recurs non-contiguously, so first-occurrence position is the slot.
  reduce .[] as $m ({order: [], by: {}, reset: false, n: 0};
      if ($m.isCompactSummary // false) == true then .reset = true
      elif ($m.type == "assistant") and ($m.message.usage != null)
           and (($m.message.model // "") != "<synthetic>") then
        .n += 1
        | ($m.message.id // ("row-" + (.n|tostring))) as $id
        | ($m.message.usage.output_tokens // 0) as $o
        | if .by[$id] == null then
            .order += [$id]
            | .by[$id] = { i:  ($m.message.usage.input_tokens // 0),
                           cc: ($m.message.usage.cache_creation_input_tokens // 0),
                           cr: ($m.message.usage.cache_read_input_tokens // 0),
                           o:  $o,
                           reset: .reset }
            | .reset = false
          else
            .by[$id].o = ([.by[$id].o, $o] | max)
          end
      else . end)
  | . as $acc | [ $acc.order[] | $acc.by[.] ];

# Split the responses into context windows and, in the same pass, add up the
# material that actually entered them.
#
# Windows: a compaction discards the window and starts again, so one max
# under-reports a session that compacted — the pre-compact window is simply
# absent from it. The marker (isCompactSummary, carried as `reset`) is the
# ground truth and is used whenever the transcript has one. Without any marker
# the fallback is the drop itself: context collapsing below 60% of the previous
# response. Measured across 233 transcripts, that ratio is NOT a clean
# separator — prefix-cache rebuilds sit at 0.74–0.77 and a marker-confirmed
# reset at 0.79 — which is why the marker wins wherever it exists. Both zero
# guards stay: a zero must neither open a window nor be the next baseline.
#
# New material: cache_creation_input_tokens is not a per-turn delta. When the
# prefix cache expires (about five idle minutes) the whole window is rewritten
# and reported as cache creation, so summing it counts the same content again
# on every rebuild — measured at 3–7x inflation on real sessions. Each
# response's cache creation is therefore capped at the context growth since
# the previous response (the whole context for the first response of a
# window), which is the part that is genuinely new.
def windows:
  (any(.[]; .reset)) as $has_marker
  | reduce .[] as $v ({segs: [], nm: 0};
      ($v.i + $v.cr + $v.cc) as $ctx
      | (if (.segs | length) == 0 then true
         elif $v.reset and $has_marker then true
         elif ($has_marker | not) and (.segs[-1][-1] > 0) and ($ctx > 0)
              and ($ctx < (.segs[-1][-1] * 0.6)) then true
         else false end) as $new
      | (if $new then 0 else .segs[-1][-1] end) as $prev
      | .nm += $v.i + $v.o + ([$v.cc, ([0, ($ctx - $prev)] | max)] | min)
      | if $new then .segs += [[$ctx]]
        else .segs = (.segs[0:-1] + [.segs[-1] + [$ctx]]) end);
JQ

STATS="$(jq -s "$RESPONSES"'
  (responses) as $r
  # A user entry is a real human turn only when it is not a harness injection.
  # Tool results, slash-command expansions, bash-mode echoes and the startup
  # caveat all arrive as user entries; a pasted image makes a real message
  # array-shaped, so array content is read for text rather than dropped.
  | [ .[] | select(.type=="user")
          | select((.isMeta // false) == false)
          | select((.isCompactSummary // false) == false)
          | select(.toolUseResult == null)
          | { txt: (if (.message.content|type) == "string" then .message.content
                     else ([.message.content[]? | select(.type=="text") | .text] | join(" ")) end),
              img: (if (.message.content|type) == "array"
                    then ([.message.content[]? | select(.type=="image")] | length) else 0 end) }
          # An image with no caption is still a turn. The leading-anchored
          # patterns are anchored on purpose: a human asking about a task
          # notification quotes the tag mid-message and must still count.
          | select((.txt | length) > 0 or .img > 0)
          | select(.txt | test("^<task-notification>|^\\[SYSTEM NOTIFICATION|^<command-name>|^<local-command|^<bash-|^Caveat:|^\\[Request interrupted") | not) ] as $h
  | [ .[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") ] as $t
  | [ .[] | .timestamp // empty ] as $ts
  | [ $r[] | (.i + .cr + .cc) ] as $ctx
  | ($r | windows) as $w
  | $w.segs as $segments
  | {
      human_turns:   ($h | length),
      responses:     ($r | length),
      tool_calls:    ($t | length),
      generated:     ([$r[].o]  | add // 0),
      fresh_input:   ([$r[].i]  | add // 0),
      cache_created: ([$r[].cc] | add // 0),
      cache_read:    ([$r[].cr] | add // 0),
      peak_context:  ($ctx | max // 0),
      windows:       ($segments | length),
      window_peaks:  ([$segments[] | max]),
      context_total: ([$segments[] | max] | add // 0),
      started:       ($ts | first // ""),
      ended:         ($ts | last // "")
    }
  | .new_material = $w.nm
  | .processed    = (.fresh_input + .cache_created + .cache_read + .generated)
' "$T")"

# Subagents run in their own windows; their cost is real but is not this
# session's context. The canonical location is beside the session transcript and
# survives /clear and --resume; the scratchpad copies are symlinks mixed in with
# background-Bash output that is not a transcript at all.
SUB='{"runs":0,"generated":0,"new_material":0,"peak_context":0}'
runs=0; gen=0; new=0; peak=0
for f in "$PDIR/$SID/subagents"/agent-*.jsonl; do
  [ -f "$f" ] || continue
  one="$(jq -s "$RESPONSES"'(responses) as $r | select(($r|length) > 0)
    | { generated:    ([$r[].o] | add // 0),
        new_material: (($r | windows) | .nm),
        peak_context: ([$r[] | (.i + .cr + .cc)] | max // 0) }' "$f" 2>/dev/null)" || continue
  [ -n "$one" ] || continue
  runs=$((runs + 1))
  gen=$((gen + $(printf '%s' "$one" | jq '.generated')))
  new=$((new + $(printf '%s' "$one" | jq '.new_material')))
  # max, not sum: these are independent windows, so a sum is not a peak.
  p=$(printf '%s' "$one" | jq '.peak_context'); [ "$p" -gt "$peak" ] && peak=$p
done
[ "$runs" -gt 0 ] && SUB="$(jq -n --argjson r "$runs" --argjson g "$gen" --argjson n "$new" --argjson p "$peak" \
  '{runs:$r, generated:$g, new_material:$n, peak_context:$p}')"

# /clear, --resume and /megavibe-restart each start a NEW transcript file, while
# compaction does not. A feature spanning one of those is only half-measured
# here, and nothing else would say so. Count only transcripts touched since the
# base commit: nearly every project has old ones, and a note that fires every
# run is indistinguishable from the one time it matters.
SIBLINGS=0
# `-newermt` takes a formatted date, NOT @epoch: BSD find rejects "@1789157607"
# with "Can't parse date/time" and 2>/dev/null hides it, so the count silently
# reads 0 forever. (%cI is rejected too — the T separator fails.) An interactive
# shell here has a `find` function routing to bfs, which does accept @epoch, so
# this only reproduces by running the script the way the script runs.
if [ -n "$BASE" ] && BASE_DATE="$(git -C "$PROJECT" log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M:%S' "$BASE" 2>/dev/null)" && [ -n "$BASE_DATE" ]; then
  # `|| true`: grep exits 1 when it filters everything out, which under
  # pipefail+errexit would kill the script here. Same trap as the ls and git
  # pipelines above.
  SIBLINGS=$( { find "$PDIR" -maxdepth 1 -name '*.jsonl' -newermt "$BASE_DATE" 2>/dev/null \
    | grep -vF "$T" || true; } | wc -l | tr -d ' ')
fi

DIFF='{"base":null,"files":0,"insertions":0,"deletions":0,"uncommitted_paths":0}'
if [ -n "$BASE" ]; then
  if ! git -C "$PROJECT" rev-parse --verify "$BASE" >/dev/null 2>&1; then
    echo "session-cost: cannot resolve --base '$BASE' in $PROJECT — skipping the diff" >&2
  else
    # rev-parse passing does not mean base...HEAD works: with no merge base git
    # exits 128. Capture that status rather than letting zeros read as "no
    # changes", which is the opposite of what a failed diff means.
    if NUMSTAT="$(git -C "$PROJECT" diff --numstat "$BASE"...HEAD 2>/dev/null)"; then
      read -r f i d <<<"$(printf '%s\n' "$NUMSTAT" \
        | awk 'NF { if ($1 ~ /^[0-9]+$/) ins+=$1; if ($2 ~ /^[0-9]+$/) del+=$2; n++ } END { print n+0, ins+0, del+0 }')"
      # base...HEAD is commit-based, so work still in the tree is invisible.
      # --untracked-files=no: a scratch file that will never be committed is
      # not work missing from the diff, and "commit first" is wrong advice for it.
      DIRTY="$( { git -C "$PROJECT" status --porcelain --untracked-files=no 2>/dev/null || true; } | wc -l | tr -d ' ')"
      DIFF="$(jq -n --arg b "$BASE" --argjson f "${f:-0}" --argjson i "${i:-0}" --argjson d "${d:-0}" \
        --argjson u "${DIRTY:-0}" '{base:$b, files:$f, insertions:$i, deletions:$d, uncommitted_paths:$u}')"
    else
      echo "session-cost: git diff $BASE...HEAD failed (no merge base?) — skipping the diff" >&2
    fi
  fi
fi

OUT="$(jq -n --arg sid "$SID" --arg t "$T" --argjson s "$STATS" --argjson sub "$SUB" \
  --argjson diff "$DIFF" --argjson sib "$SIBLINGS" \
  '{session:$sid, transcript:$t, main:$s, subagents:$sub, diff:$diff, sibling_transcripts:$sib}')"

if [ "$JSON" -eq 1 ]; then printf '%s\n' "$OUT"; exit 0; fi

# Nothing measurable is a fact, not a row of zeros. A zero table reads as a
# session that did no work.
if [ "$(printf '%s' "$OUT" | jq '.main.responses')" -eq 0 ]; then
  echo "session-cost: $SID has no measurable API responses — nothing to report"
  exit 0
fi

printf '%s' "$OUT" | jq -r '
  def n: tostring | if length > 3 then ((.[:length-3] | n) + "," + .[length-3:]) else . end;
  "session        \(.session)",
  "human turns    \(.main.human_turns)",
  "api responses  \(.main.responses)   tool calls \(.main.tool_calls)",
  "",
  (if .main.windows > 1 then
     "context total  \(.main.context_total|n)   (\(.main.windows) windows — compaction reset it \(.main.windows - 1)x)",
     "  per window   \([.main.window_peaks[]|n]|join(" + "))"
   else empty end),
  "peak context   \(.main.peak_context|n)   (fullest single window)",
  "generated      \(.main.generated|n)   (output tokens)",
  "new material   \(.main.new_material|n)   (compare this to an estimate)",
  "processed      \(.main.processed|n)   (incl. cache reads, scales with turns)",
  "",
  (if .subagents.runs > 0 then
     "subagents      \(.subagents.runs) run(s), \(.subagents.new_material|n) new material, \(.subagents.generated|n) generated (separate windows)"
   else "subagents      none" end),
  (if .diff.base then
     "diff vs \(.diff.base)  \(.diff.files) files, +\(.diff.insertions) -\(.diff.deletions)"
   else empty end),
  (if (.diff.uncommitted_paths // 0) > 0 then
     "               \(.diff.uncommitted_paths) path(s) still uncommitted and NOT in that diff"
   else empty end),
  (if .sibling_transcripts > 0 then
     "note           \(.sibling_transcripts) other transcript(s) for this project — /clear, --resume and /megavibe-restart each start a new one, so a feature spanning a restart is only half measured here"
   else empty end),
  "",
  "started        \(.main.started)",
  "ended          \(.main.ended)"'
