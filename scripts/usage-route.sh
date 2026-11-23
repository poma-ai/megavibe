#!/usr/bin/env bash
# usage-route.sh — subscription-first routing from the Claude usage history.
#
#   usage-route.sh claude     one line: band|model|effort|reason (| not tab: read collapses empty tab fields)
#   usage-route.sh advisory   one sentence for a session, or nothing in the normal band
#   usage-route.sh band       just the band name (over | normal | under)
#   usage-route.sh codex      the same line for Codex: band||effort|reason (effort is always empty: reviews use the config's own)
#   usage-route.sh codex-band just the Codex band name
#   usage-route.sh balance    one line: prefer|sentence — which subscription optional work (digests, exploration,
#                             second opinions) should lean on; prefer is claude, codex or - (no preference)
#                             decided on each side's effective projection: the router projection, else the straight-line
#                             estimate (from 5% of the window), else the used percent; a side at 85 or more is never leaned on
#   usage-route.sh status     band|used|proj|rem|stale|reason for the weekly window of $MEGAVIBE_ROUTER_PROVIDER (claude, default, or codex)
#   usage-route.sh pace       provider|used|elapsed_pct|linear_proj|recent_pts_per_day|recent_proj|remaining_days
#                             display only; linear from 5% elapsed, recent from samples within the last 6h that span at least 2h
#   usage-route.sh forecast   provider|used|fc_pace_per_h|forecast|spare|spend_per_h|basis (recent-pace forecast, see below; read-only)
#   usage-route.sh status-pace internal: status fields followed by pace fields from one history snapshot
#   usage-route.sh sprint     provider|state|hours_left|used|forecast|spare|spend_per_h|basis|reason|five_hour_used (end-of-window sprint, see below; read-only)
#   usage-route.sh sprint-advice  one sentence per subscription in the sprint state (Claude, then Codex), else nothing
#
# Recent-pace forecast (added 2026-11-22; extra trailing fields, nothing existing changed): pace = 0.6 x the 6-hour
# pace + 0.4 x the 24-hour pace inside the current window (whichever has no readings is "unknown", never zero;
# both unknown: the window average, basis "week"); forecast = used + pace x hours_left; spare = target - forecast
# (target 95, MEGAVIBE_USAGE_TARGET); spend = points per hour that would reach the target exactly. Reported by the
# new `forecast` mode only: status and pace lines are byte-identical to before.
# A pace span needs readings at least 2 h apart (whole-percent resolution), a drop in the window makes it
# unreliable (unknown), a stale reading or a missing window means no forecast at all. The bands still decide on the
# straight-line projection (hysteresis and the `under` guard were tuned on it); balance and the advisory use the forecast.
#
# End-of-window sprint (added 2026-11-23; advice only, no band, launch or balance decision reads it): quota left at a
# reset is lost, and in the last hours the forecast is short-range enough to spend down to a tighter margin than
# the week-long 95 target allows. state is `sprint` when ALL hold, else `-` with the reason in the last field:
#   outside      the weekly window has more than MEGAVIBE_SPRINT_HOURS (4) hours left, under 10 minutes left
#                (nothing useful can start, and the per-hour figure would be absurd), or no live window
#   no-forecast  no recent-pace forecast, or the newest reading is over 20 minutes old (Codex writes one only
#                when called; an old reading under-states use and is no basis for spending the last points)
#   5h-hot       the five-hour window is at 85 or more: top-tier work would only hit that limit
#   no-room      less than two points between the forecast, or the used percent, and the sprint target
#                (MEGAVIBE_SPRINT_TARGET, 99; a whole number below 100, so the 100 backstop is never the aim):
#                a whole-percent reading can be almost a point low and other sessions spend from the same
#                account; or the ordinary target is not below the sprint target
#   off          MEGAVIBE_SPRINT=0
# The sprint's pace is conservative: it also includes the steepest rise of 2 points or more from any reading in the
# 90 minutes before the newest reading to that reading, rated (rise + 1) over its span floored at 15 minutes
# (whole-percent readings; a single one-point tick is noise; an earlier dip does not switch it off; basis suffix
# `+burst`), and the forecast is projected from the newest reading to the reset, not from now.
# Known gap: a Codex history whose uncached scan takes over 2 s (the advice's per-provider alarm) reports `unknown`
# for Codex, and the hook then keeps the state it last told (fails closed: no new advice, no false advice).
# With no usage data at all the line is `provider|-|||||||` (no reason either); a provider without a five-hour
# reading is not held back by the 5h-hot rule.
# spare = sprint target - forecast; spend = points per hour from now, for the whole account, that would reach the
# sprint target. Both are estimates. Inside the window the Codex reading is re-read past the two-minute cache, so
# a reading written since (100 included) ends the state at the next call.
#
# Input: ~/.megavibe/usage/claude.jsonl, appended by template/statusline.sh from the
# statusline's account-wide rate_limits (five_hour / seven_day used_percentage and
# resets_at). Claude Code has no usage API, so the history is the only source.
# Codex: the newest rate_limits records Codex wrote into ~/.codex/sessions/**/rollout-*.jsonl
# (weekly window, ChatGPT-login only). Only THIS machine's calls appear there, so a Codex
# used from elsewhere under-reads; a reading counts as stale after 24h (Claude: 6h).
# The same band engine and thresholds run on it, with its own state file.
#
# Bands: over (used up or running hot: cut model/effort, pin subagents down), normal
# (no effect), under (capacity that will be lost at reset: upgrade the model).
# Hysteresis keeps it from flapping: `over` enters at once; it leaves 30 minutes after its
# leave thresholds first hold (a remembered reading of 85% or more holds until the window
# resets or the projection falls with elapsed time, and a fresh window still waits out the
# 30 minutes; an `over` entered on pace in the week's first quarter is held until the projection
# takes over at 25% elapsed); `under` needs two qualifying evaluations 30 minutes apart and lasts only while its
# qualifying reading holds (the 5h window that justified it resetting ends it). Escape hatches:
# MEGAVIBE_ROUTER=0, or delete route-state.json.
# Missing, malformed or reset-window data is the normal band, so the router can only ever
# change today's behaviour on evidence. A reading older than 6h inside a live window still
# counts toward `over` (usage only grows inside a window) but never toward `under`. Exit status is always 0.
#
# Test seams: MEGAVIBE_USAGE_FILE, MEGAVIBE_USAGE_STATE, MEGAVIBE_NOW,
# MEGAVIBE_USER_SETTINGS, MEGAVIBE_CODEX_HOME, MEGAVIBE_CODEX_STATE. Tuning: MEGAVIBE_ROUTER_UP (model for `under`, default opus).
set -uo pipefail

MV="${MEGAVIBE_HOME:-$HOME/.megavibe}"
FILE="${MEGAVIBE_USAGE_FILE:-$MV/usage/claude.jsonl}"
STATE="${MEGAVIBE_USAGE_STATE:-$MV/usage/route-state.json}"
NOW="${MEGAVIBE_NOW:-$(date +%s 2>/dev/null)}"
SETTINGS="${MEGAVIBE_USER_SETTINGS:-$HOME/.claude/settings.json}"
UP="${MEGAVIBE_ROUTER_UP:-opus}"
MODE="${1:-claude}"; PEEK=0; [ "${2:-}" = "--peek" ] && PEEK=1   # --peek: report, never advance the hysteresis state
case "$MODE" in pace|forecast|sprint|sprint-advice) PEEK=1 ;; esac   # display must never update routing state or trim history
FCMODE=0; case "$MODE" in forecast|sprint) FCMODE=1 ;; esac          # modes that read the long history a forecast needs
FSTALE=""; SPRINT_BURST=0                                            # set by sprint mode only, never taken from the environment
SPRINT_FRESH=0; [ "$MODE" = sprint ] && [ "${_MEGAVIBE_SPRINT_FRESH:-}" = 1 ] && SPRINT_FRESH=1   # internal: sprint re-running itself past the Codex cache
PROVIDER="${MEGAVIBE_ROUTER_PROVIDER:-claude}"; STALE=21600
case "$MODE" in codex|codex-band) PROVIDER=codex ;; esac
if [ "$PROVIDER" = codex ]; then
  FILE=""; STATE="${MEGAVIBE_CODEX_STATE:-$MV/usage/codex-route-state.json}"; STALE=86400
fi

# Codex rows in the history's shape ({t, sd:{p,r}, fh:{p,r}}) from the six most recently written rollout files
# of the last 8 days (by mtime, sorted over the whole list: a resumed session keeps appending to an old file).
# Bounded: at most 1 MB read per file, and the result is cached for 2 minutes (the hook runs on every Agent call).
# Every usable row is kept (a slice could drop the window's highest reading). Invalid evidence is dropped before it can count: a negative or non-numeric reading, a reading dated in the
# future; a window listed twice keeps the HIGHER usage, so entry order can never turn 95% into spare capacity.
codex_row() {
  local root="${MEGAVIBE_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}/sessions" f cache="$MV/usage/codex-row.cache" nf=6 nl=200 nb=1048576
  # the forecast needs 24 h of readings: a probe writes one rollout file per call, so six files are only about 3 h
  [ "$FCMODE" != 1 ] || { nf=60 nl=3000 nb=16777216; cache="$MV/usage/codex-row-forecast.cache"; }
  [ -d "$root" ] || return 0
  # The cache is skipped when a test pins the clock (MEGAVIBE_NOW): fixtures change between calls. It is also
  # skipped for the sprint decision inside the window (SPRINT_FRESH): a reading written since must count.
  if [ -z "${MEGAVIBE_NOW:-}" ] && [ "$SPRINT_FRESH" != 1 ] && [ -f "$cache" ] && [ ! -L "$cache" ]; then
    local at; at=$(head -n 1 "$cache" 2>/dev/null)
    case "$at" in ''|*[!0-9]*) ;; *) if [ "$((NOW - at))" -ge 0 ] && [ "$((NOW - at))" -lt 120 ]; then tail -n +2 "$cache" 2>/dev/null; return 0; fi ;; esac
  fi
  local -a sf; if stat -c %Y / >/dev/null 2>&1; then sf=(-c '%Y %n'); else sf=(-f '%m %N'); fi
  # `find -exec ... +` runs the command once per chunk, so sorting INSIDE it (ls -t) is only right per chunk:
  # print "mtime path" per file and sort the whole list instead.
  local rows
  rows=$(perl -e 'alarm 3; exec @ARGV' find -H "$root" -type f -name 'rollout-*.jsonl' -mtime -8 -exec stat "${sf[@]}" {} + 2>/dev/null \
    | sort -rn | head -n "$nf" | cut -d' ' -f2- | while IFS= read -r f; do
    [ -f "$f" ] && tail -c "$nb" "$f" 2>/dev/null | grep -a '"rate_limits"' | tail -n "$nl"
  done | jq -cR --argjson now "$NOW" 'fromjson? | select(type == "object") | (.payload.rate_limits? // null) as $rl
      | select(($rl | type) == "object" and (($rl.limit_id // "codex") == "codex"))
      | ((.timestamp? // "") | tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0) as $t
      | select($t <= $now + 300)
      | {t: $t}
        + (reduce ([$rl.primary?, $rl.secondary?][]
                   | select(type == "object" and (.used_percent | type) == "number" and .used_percent >= 0 and .used_percent <= 1000 and (.resets_at | type) == "number")
                   | {key: (if .window_minutes == 10080 then "sd" elif .window_minutes == 300 then "fh" else empty end), value: {p: .used_percent, r: ((.resets_at / 60 | floor) * 60)}}) as $e
             ({}; .[$e.key] = (if .[$e.key] == null or $e.value.p > .[$e.key].p then $e.value else .[$e.key] end)))
      | select(length > 1)' 2>/dev/null \
    | jq -sc 'select(length > 0) | sort_by(.t)' 2>/dev/null)
  # An empty result is cached too (an API-key login has rollouts and no rate_limits: do not re-walk the tree on every call).
  if [ -z "${MEGAVIBE_NOW:-}" ] && [ "$MODE" != sprint ] && { [ ! -e "$cache" ] || [ -f "$cache" ]; } && mkdir -p "$MV/usage" 2>/dev/null; then
    { printf '%s\n' "$NOW"; printf '%s\n' "$rows"; } > "$cache.$$" 2>/dev/null && mv -f "$cache.$$" "$cache" 2>/dev/null || rm -f "$cache.$$" 2>/dev/null
  fi
  [ -n "$rows" ] && printf '%s\n' "$rows"
  return 0
}

none() {   # no evidence: the normal band, in the shape of the mode asked for
  case "$MODE" in advisory) ;; status-pace) printf 'normal||||||%s||||||\n' "$PROVIDER" ;; pace) printf '%s||||||\n' "$PROVIDER" ;; forecast) printf '%s||||||\n' "$PROVIDER" ;; sprint) printf '%s|-||||||||\n' "$PROVIDER" ;; sprint-advice) ;; band|codex-band) echo normal ;; status) echo 'normal|||||' ;; balance) echo '-|' ;; *) printf 'normal|||\n' ;; esac
  exit 0
}
# Pace has no routing fallback: without jq it is silent, and never blocks a caller.
case "$MODE" in pace|forecast|sprint-advice) command -v jq >/dev/null 2>&1 || exit 0 ;; esac
command -v jq >/dev/null 2>&1 || { { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; }; }
case "$NOW" in ''|*[!0-9]*) { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; } ;; esac

# The decision engine selects the window exactly as status always has. Only then
# sort its observations for a display rate; never pick a second window by timestamp.
emit_pace() {
  LC_ALL=C jq -r --arg provider "$PROVIDER" --argjson now "$NOW" --argjson stale "$STALE" --argjson decision "$DECISION" '
    def sec: if . > 100000000000 then . / 1000 else . end;
    def rounded: . * 1000 | round / 1000;
    def blank: [$provider, "", "", "", "", "", ""];
    $decision.wk as $w | ($decision.mx.sd.r // 0) as $reset
    | [ .[] | select(type == "object")
        | select((.t | type) == "number" and (.sd.p? | type) == "number" and (.sd.r? | type) == "number")
        | {t, p: .sd.p, r: (.sd.r | sec)}
        # Compare to the selected epoch, not the previous sample: jitter cannot chain
        # unrelated windows together. Three minutes accommodates second/minute rounding.
        | select((.r - $reset | fabs) <= 180)
        | select(.t > 0 and .t <= $now and .t >= $reset - 604800 and .p >= 0 and .p <= 1000) ]
    | sort_by(.t)
    # Keep duplicate timestamps until after checking for drops. A drop anywhere in
    # the retained window makes its recent trend unreliable, even after a recovery.
    | reduce .[] as $x ({first: null, last: null, reliable: true};
        if .last != null and $x.p < .last.p then .reliable = false else . end
        | if (.first == null or .first.t == $x.t) and $x.t >= $now - 21600 then .first = $x else . end
        | .last = $x)
    | .first as $first | .last as $last | .reliable as $reliable
    | if $w == null or $last == null then blank
      elif $w.stale or $now - $last.t > $stale or $reset <= $now or $reset > $now + 604800 then blank
      else ($reset - $now) as $rem | (604800 - $rem) as $elapsed
        # A remembered maximum or a differing jitter sample is not a dated anchor
        # for the selected usage. Suppress the recent estimate if it cannot agree.
        | (if $reliable and $first != null and $last.t - $first.t >= 7200 and $last.p == $w.used
           then ($last.p - $first.p) * 86400 / ($last.t - $first.t) else null end) as $rate
        | [$provider, $w.used, ($elapsed / 6048 | rounded),
           (if $elapsed >= 30240 then ($w.used * 604800 / $elapsed | rounded) else "" end),
           (if $rate != null then ($rate | rounded) else "" end),
           (if $rate != null then ($last.p + $rate * ($reset - $last.t) / 86400 | rounded) else "" end),
           ($rem / 86400 | rounded)]
      end | map(tostring) | join("|")
  ' <<<"$HISTORY" 2>/dev/null
}

# the target is a whole number from 1 to 999, else 95
TARGET=95; case "${MEGAVIBE_USAGE_TARGET:-}" in ""|*[!0-9]*|0*) ;; *) [ "${#MEGAVIBE_USAGE_TARGET}" -le 4 ] && [ "$MEGAVIBE_USAGE_TARGET" -le 999 ] && TARGET=$MEGAVIBE_USAGE_TARGET ;; esac
# the sprint target is a whole number from 1 to 99, else 99; the sprint window a whole number of hours from 1 to 24, else 4
STARGET=99; case "${MEGAVIBE_SPRINT_TARGET:-}" in ""|*[!0-9]*|0*) ;; *) [ "${#MEGAVIBE_SPRINT_TARGET}" -le 2 ] && STARGET=$MEGAVIBE_SPRINT_TARGET ;; esac
SHOURS=4; case "${MEGAVIBE_SPRINT_HOURS:-}" in ""|*[!0-9]*|0*) ;; *) [ "${#MEGAVIBE_SPRINT_HOURS}" -le 2 ] && [ "$MEGAVIBE_SPRINT_HOURS" -le 24 ] && SHOURS=$MEGAVIBE_SPRINT_HOURS ;; esac
# Recent-pace forecast of the selected weekly window: pace|forecast|spare|spend_per_h|basis (all empty when unknown).
# FSTALE (sprint mode) tightens how old the newest reading may be; TARGET is whatever the caller measures against.
emit_forecast() {
  LC_ALL=C jq -r --argjson now "$NOW" --argjson stale "${FSTALE:-$STALE}" --argjson burst "${SPRINT_BURST:-0}" --argjson decision "$DECISION" --argjson target "$TARGET" '
    def sec: if . > 100000000000 then . / 1000 else . end;
    def r1: . * 10 | round / 10;
    $decision.wk as $w | ($decision.mx.sd.r // 0) as $reset
    | [ .[] | select(type == "object")
        | select((.t | type) == "number" and (.sd.p? | type) == "number" and (.sd.r? | type) == "number")
        | {t, p: .sd.p, r: (.sd.r | sec)}
        | select((.r - $reset | fabs) <= 180)
        | select(.t > 0 and .t <= $now and .t >= $reset - 604800 and .p >= 0 and .p <= 1000) ] | sort_by(.t) as $rows
    | if $w == null or ($rows | length) == 0 or $w.stale or $reset <= $now or $reset > $now + 604800 then "||||"
      else
        ($rows | last) as $last
        | # like the straight line, nothing before 5 percent of the window has elapsed (8.4 h): whole-percent readings are too coarse
        if $now - $last.t > $stale or $last.p != $w.used or ((604800 - ($reset - $now)) < 30240) then "||||"
          else
            ($rows | [.[] | .p] | . as $ps | [range(1; length) | select($ps[.] < $ps[. - 1])] | length == 0) as $mono
            | ($reset - $now) / 3600 as $left
            | ((604800 - ($reset - $now)) / 3600) as $el
            # pace over the last h hours before now: from the earliest reading inside those h hours, 2 h or more before the newest
            # (a sparse history must not stretch the 6 h pace over days); none such is unknown, never zero
            | def pace($h):
                if ($mono | not) then null
                else ([$rows[] | select(.t >= $now - $h * 3600)] | first) as $b   # the earliest reading inside the horizon, never one from before it
                  | if $b == null or $last.t - $b.t < 7200 then null else (($last.p - $b.p) / (($last.t - $b.t) / 3600)) end
                end;
              pace(6) as $r6 | pace(24) as $r24
            | (if $el >= 1 then $w.used / $el else null end) as $wk
            | (if $r6 != null and $r24 != null then {v: (0.6 * $r6 + 0.4 * $r24), b: "6h+24h"}
               elif $r6 != null then {v: $r6, b: "6h"}
               elif $r24 != null then {v: $r24, b: "24h"}
               elif $wk != null then {v: $wk, b: "week"} else null end) as $pc0
            # Sprint mode only: a rise of 2 points or more inside the last 90 minutes, over whatever span (the blended
            # paces need readings 2 h apart and miss a burst that has just started, which is what a session spending
            # in the sprint looks like), raises the pace to that rate.
            | (if $burst == 1 and $pc0 != null then
                 # Conservative sprint pace. Whole-percent readings: a displayed rise of r points can be anywhere from r-1
                 # to r+1, so every rise of 2 points or more (a single one-point tick is noise: the statusline writes a row
                 # on every whole-percent change) from a reading in the 90 minutes before the NEWEST reading to
                 # that reading is rated (r+1) over its span, the span floored at 15 minutes, whatever came before it (an earlier dip does not switch this
                 # off) and however long ago the newest reading was taken (the evidence ages with new readings only).
                 # the reading just before the newest counts whatever its age: after an idle gap the first new reading can carry a jump
                 # Equal repeat readings at the current level do not erase a burst: the rise is measured to the FIRST reading
                 # at that level (the trailing run of equal readings starts there) and counts while that reading is recent.
                 (([range(0; $rows | length) | select($rows[.].p != $last.p)] | last) as $li
                  | (if $li == null then $rows[0] else $rows[$li + 1] end) as $anc
                  | if $anc.t < $now - 5400 then null
                    else (([$rows[] | select(.t < $anc.t)] | last) as $before
                      | [$rows[] | select((.t >= $anc.t - 5400 or .t == $before.t) and .t < $anc.t and ($anc.p - .p) >= 2)
                        | (($anc.p - .p + 1) / (([($anc.t - .t), 900] | max) / 3600))] | max) end)
               else null end) as $rb
            | (if $rb != null and $rb > $pc0.v then {v: $rb, b: ($pc0.b + "+burst")} else $pc0 end) as $pc
            | if $pc == null then "||||"
              else ([$pc.v, 0] | max) as $rate
                # The sprint projects from the newest reading, not from now: usage between the two is not in any reading.
                | (if $burst == 1 then (($reset - $last.t) / 3600) else $left end) as $span
                | ($w.used + $rate * $span) as $fc
                | [($rate * 1000 | round / 1000),
                   # the sprint rounds the forecast up and the spare down: a margin must not be rounded into existence
                   (if $burst == 1 then ([$fc, 999] | min | . * 10 | ceil / 10) else ([$fc, 999] | min | r1) end),
                   (if $burst == 1 then ($target - $fc | . * 10 | floor / 10) else ($target - $fc | r1) end),
                   (if $left > 0 then
                      # the sprint starts from the estimated use NOW (the newest reading plus the pace since it) and rounds down
                      (if $burst == 1 then ($w.used + $rate * (([($now - $last.t), 0] | max) / 3600)) else $w.used end) as $cur
                      | [($target - $cur) / $left, 0] | max | . * 100 | (if $burst == 1 then floor else round end) / 100
                    else 0 end), $pc.b]
                | map(tostring) | join("|")
              end
          end
      end
  ' <<<"$HISTORY" 2>/dev/null
}

if [ "$MODE" = sprint-advice ]; then
  # One sentence per subscription in the sprint state. Advice for the session; nothing here changes a band,
  # the launch model or the balance preference.
  [ "${MEGAVIBE_SPRINT:-1}" != 0 ] || exit 0
  for p in claude codex; do
    # each provider's call is bounded on its own (2 s); one that cannot run or times out is reported as unknown,
    # never as "not sprinting", so a slow Codex read cannot hide that Claude's sprint ended (or the reverse)
    pf=$(mktemp "${TMPDIR:-/tmp}/usage-sprint-adv.XXXXXX" 2>/dev/null) || pf=""
    pp=""; st=""
    if [ -n "$pf" ] && command -v perl >/dev/null 2>&1 && ( MEGAVIBE_ROUTER_PROVIDER=$p perl -e 'alarm 2; exec @ARGV' bash "$0" sprint >"$pf" 2>/dev/null </dev/null ) 2>/dev/null; then
      IFS='|' read -r pp st hl u fc spare spend _ _ fhu <"$pf" || true
    fi
    [ -z "$pf" ] || rm -f "$pf"
    if [ "${pp:-}" != "$p" ]; then printf 'usage sprint-unknown: %s\n' "$([ "$p" = codex ] && echo Codex || echo Claude)"; continue; fi
    [ "${st:-}" = sprint ] || continue
    LC_ALL=C awk -v who="$p" -v hl="$hl" -v u="$u" -v fc="$fc" -v spare="$spare" -v spend="$spend" -v fhu="${fhu:-}" -v t="$STARGET" -v ot="$TARGET" 'BEGIN {
      printf "usage sprint: %s weekly window resets in %s h at %d%% used, recent-pace forecast ~%d%%: about %s points spare to %d%% (%s points per hour from now, for the whole account, would reach it; both are estimates from whole-percent readings, so count each unit'"'"'s own cost against the spare points)%s. ", (who == "codex" ? "Codex" : "Claude"), hl, u, fc, spare, t, spend, (fhu ~ /^[0-9]+([.][0-9]+)?$/ ? sprintf("; its five-hour window is at %d%%, and a unit must fit that too", fhu) : "")
      printf "End-of-window exception: put this subscription'"'"'s top model tier on the hardest open work (for that work only, this outranks an over band'"'"'s advice to pin models down) for as long as `%s` reports sprint for this subscription, keep one point of the spare in reserve, and re-read it before each unit; inside this window %d%% replaces the %d%% target for this subscription only. ", (who == "codex" ? "MEGAVIBE_ROUTER_PROVIDER=codex usage-route.sh sprint" : "usage-route.sh sprint"), t, ot
      printf "Mechanical work stays on cheap models; the 100%% backstop and the review floor are unchanged.\n" }'
  done
  exit 0
fi

if [ "$MODE" = balance ]; then
  # Where should OPTIONAL work (digests, exploration, second opinions) lean? Each subscription's weekly
  # window projects its end-of-window use; spend the one with room. The reviewer floor never moves.
  # Hysteresis: a preference is entered at a 20-point gap and kept until the gap falls under 10. The caller (the
  # advisory hook) passes its last preference in MEGAVIBE_BALANCE_PREV; without it the rule is a plain 20.
  pk=""; [ "$PEEK" = 1 ] && pk="--peek"
  IFS='|' read -r cb cu cp _ cs _ _ _ _ clp crate crp _ < <(MEGAVIBE_ROUTER_PROVIDER=claude bash "$0" status-pace $pk 2>/dev/null) || true
  IFS='|' read -r xb xu xp _ xs _ _ _ _ xlp xrate xrp _ < <(MEGAVIBE_ROUTER_PROVIDER=codex bash "$0" status-pace $pk 2>/dev/null) || true
  IFS='|' read -r _ _ _ cff _ _ _ < <(MEGAVIBE_ROUTER_PROVIDER=claude bash "$0" forecast 2>/dev/null) || true
  IFS='|' read -r _ _ _ xff _ _ _ < <(MEGAVIBE_ROUTER_PROVIDER=codex bash "$0" forecast 2>/dev/null) || true
  LC_ALL=C awk -v cff="${cff:-}" -v xff="${xff:-}" -v clp="${clp:-}" -v crp="${crp:-}" -v crate="${crate:-}" -v xlp="${xlp:-}" -v xrp="${xrp:-}" -v xrate="${xrate:-}" \
    -v cb="${cb:-}" -v cu="${cu:-}" -v cp="${cp:-}" -v xb="${xb:-}" -v xu="${xu:-}" -v xp="${xp:-}" -v cs="${cs:-0}" -v xs="${xs:-0}" -v prev="${MEGAVIBE_BALANCE_PREV:-}" '
  function estimate(label, used, proj, linear, recent, rate, stale, fc, text) {
    text = sprintf("%s %d%% used", label, used)
    if (fc != "") text = text sprintf(" (recent-pace forecast ~%d%% by week end)", fc)
    if (proj != "") text = text sprintf(" (linear estimate ~%d%% by week end)", proj)
    else if (linear != "") text = text sprintf(" [linear estimate ~%d%%]", linear)
    else text = text " [linear estimate unavailable]"
    if (recent != "" && rate ~ /^[0-9]+([.][0-9]+)?$/) text = text sprintf(" (recent estimate ~%d%% at %s pts/day)", recent, rate)
    if (stale == 1) text = text " [stale reading]"
    return text
  }
  BEGIN {
    if (cu == "" || xu == "") { print "-|"; exit }
    # Effective projection: the router projection, else the straight-line estimate (from 5 percent of the
    # window), else the used percent. The straight-line estimate matters early in a window, where the router
    # has no projection yet: used percent alone made a subscription 0.6 days into its week look like headroom.
    if (clp !~ /^[0-9]+([.][0-9]+)?$/) clp = ""; if (xlp !~ /^[0-9]+([.][0-9]+)?$/) xlp = ""   # numbers only
    # The recent-pace forecast (usage-route.sh forecast) leads when it exists: it follows the current pace, not the week average.
    if (cff !~ /^[0-9]+([.][0-9]+)?$/) cff = ""; if (xff !~ /^[0-9]+([.][0-9]+)?$/) xff = ""
    cj = (cff != "" ? cff : (cp != "" ? cp : (clp != "" ? clp : cu))) + 0; xj = (xff != "" ? xff : (xp != "" ? xp : (xlp != "" ? xlp : xu))) + 0
    known = ((cff != "" || cp != "" || clp != "") && (xff != "" || xp != "" || xlp != ""))
    pref = "-"
    if (cb == "over" && xb == "over") { print "-|"; exit }          # nowhere to lean
    if (cb == "over" && xb != "over") pref = "codex"
    else if (xb == "over" && cb != "over") pref = "claude"
    else if (known && cj - xj >= (prev == "codex" ? 10 : 20)) pref = "codex"     # enter at 20 points, leave at 10
    else if (known && xj - cj >= (prev == "claude" ? 10 : 20)) pref = "claude"
    # Never lean on a subscription already projected to end near its limit.
    if ((pref == "codex" && xj >= 85) || (pref == "claude" && cj >= 85)) pref = "-"
    # An old reading only under-states use (it grows inside a window): never send work to a subscription
    # whose figure is stale, only away from one.
    if ((pref == "codex" && xs == 1) || (pref == "claude" && cs == 1)) pref = "-"
    if (pref == "-") { print "-|"; exit }
    st = estimate("Claude", cu, cp, clp, crp, crate, cs, cff) "; " estimate("Codex", xu, xp, xlp, xrp, xrate, xs, xff)
    hot = (cb == "over" || xb == "over") ? " (one is running hot)" : ""
    to = (pref == "codex" ? "Codex" : "the Claude subagents")
    printf "%s|usage balance: %s%s. Lean optional work (digests, exploration, second opinions) on %s; the review floor does not move.\n", pref, st, hot, to
  }'
  exit 0
fi

ROW=""; HISTORY="[]"
if [ "$PROVIDER" = codex ]; then
  ROW=$(codex_row); HISTORY="${ROW:-[]}"
elif [ -f "$FILE" ] && [ -r "$FILE" ]; then
  if [ "$MODE" = pace ] || [ "$MODE" = status-pace ] || [ "$FCMODE" = 1 ]; then
    # One read for both outputs. Slice raw lines before parsing, exactly as status
    # does, so malformed rows cannot change which 50 lines the router considers.
    RAW=$(tail -n 5000 "$FILE" 2>/dev/null && printf 'x') || none
    RAW=${RAW%x}   # preserve trailing blank lines stripped by command substitution
    HISTORY=$(printf '%s' "$RAW" | jq -cR 'fromjson? | select(type == "object")' 2>/dev/null | jq -sc '.' 2>/dev/null) || none
    [ -n "$HISTORY" ] || none
    ROW=$(printf '%s' "$RAW" | tail -n 50 | jq -cR 'fromjson? | select(type == "object")' 2>/dev/null | jq -sc 'select(length > 0)' 2>/dev/null) || none
  else
    ROW=$(tail -n 50 "$FILE" 2>/dev/null | jq -cR 'fromjson? | select(type == "object")' 2>/dev/null | jq -sc 'select(length > 0)' 2>/dev/null)
  fi
fi
PREV=$( [ -f "$STATE" ] && cat "$STATE" 2>/dev/null | jq -sc 'map(select(type == "object")) | last // empty' 2>/dev/null)
[ -n "$ROW" ] || { { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; }; }
[ -n "$PREV" ] || PREV='{}'

# shellcheck disable=SC2016
DECISION=$(jq -c --argjson now "$NOW" --argjson stale "$STALE" --argjson prev "$PREV" '
  def sec: if . > 100000000000 then . / 1000 else . end;      # a resets_at in milliseconds
  # A window is live while its resets_at is ahead. Rows from idle sessions can be logged late
  # and carry an old window, so liveness (not append order) picks the window: the newest live
  # row names it, and usage only grows inside a window, so the highest reading of it is current.
  # The highest reading of a live window is also kept in the state file, keyed by its reset
  # time in seconds, so a flood of later rows outside the 50-row slice read here, or a
  # seconds/ms mismatch, cannot hide it. With no live row at all the remembered reading stands
  # alone and counts as stale (no basis for `under`).
  def pick($k):
    [.[] | select(((.[$k].r? // null) | type) == "number" and ((.[$k].p? // null) | type) == "number" and .[$k].p >= 0 and ((.t? // 0) | type) == "number" and (.t? // 0) <= $now + 300 and ((.[$k].r | sec) > $now))] as $live   # a row without a numeric, non-negative reading, or dated in the future, is not evidence
    | (($prev.mx[$k]? // null) | if type == "object" and (.r | type) == "number" and (.p | type) == "number" and .r > $now then . else null end) as $alone
    | if ($live | length) == 0 then (if $alone == null then null else {p: $alone.p, r: $alone.r, t: 0} end)
      else ($live | last) as $l | ($l[$k].r | sec) as $rn
        | ([$live[] | select((.[$k].r | sec) == $rn) | .[$k].p | select(type == "number")] | max) as $p0
        | ($prev.mx[$k]? // null) as $m
        | {p: (if ($m | type) == "object" and $m.r == $rn and ($m.p | type) == "number" then ([$p0, $m.p] | max) else $p0 end),
           r: $rn, t: ([$live[] | select((.[$k].r | sec) == $rn) | .t | select(type == "number")] | max // 0)} end;   # freshness = the newest row of that window
  def win($w; $len):
    if ($w | type) != "object" or ($w.p | type) != "number" or ($w.r | type) != "number" then null
    else (($w.r | sec) - $now) as $rem
      | ((1 - $rem / $len) | if . < 0 then 0 elif . > 1 then 1 else . end) as $el
      | {r: ($w.r | sec), used: $w.p, rem: $rem, el: $el, proj: (if $el >= 0.25 then $w.p / $el else null end),
         stale: (($now - ($w.t | tonumber? // 0)) > $stale)}      # old reading in a live window: still a floor for `over`, no basis for `under`
    end;
  def human($s): if $s >= 172800 then "\($s / 86400 | floor)d"
                 elif $s >= 3600 then "\($s / 3600 | floor)h" else "\([$s / 60 | floor, 1] | max)m" end;
  win(pick("fh"); 18000) as $fh | win(pick("sd"); 604800) as $sd
  | (if ($prev.band | type) == "string" then $prev.band else "normal" end) as $cur
  | (($prev.since | numbers) // 0) as $since | (($prev.calm | numbers) // 0) as $calm   # a damaged state file is read as "no state"
  | ((($prev.pend | numbers) // 0) | if ($now - .) > 7200 then 0 else . end) as $pend    # a pending `under` evaluation lapses after 2h
  # Early week (no projection before 25% elapsed): a straight-line pace is the yardstick. 64% used
  # at day 1.2 (a pace of ~380%) read as normal until 2026-10-27; now 30 points ahead of the line
  # enters `over`, and an early `over` at 22.5% or more is not released before 25%: the projection
  # decides then (a release line rising with time would hand over to a stricter projection and
  # flap). Below 22.5% the projection at 25% would be under 90 anyway, so a 5-hour `over`, a new
  # week or an inherited `over` still leaves after the usual 30 minutes.
  | (($sd != null and ($sd.used >= 90 or ($sd.proj != null and $sd.proj > 100) or ($sd.el < 0.25 and $sd.used > 100 * $sd.el + 30)))
     or ($fh != null and $fh.used >= 85)) as $over_in
  | (($sd == null or ($sd.used < 85 and ($sd.proj == null or $sd.proj < 90) and ($sd.el >= 0.25 or $sd.used < 22.5)))
     and ($fh == null or $fh.used < 70)) as $over_out
  | ($sd != null and ($sd.used >= 75 or ($sd.proj != null and $sd.proj > 85)
                      or ($sd.el < 0.25 and $sd.used > 100 * $sd.el + 15))) as $under_out   # early week: no projection yet, so compare with a straight-line pace
  | (($sd != null and ($sd.stale | not) and (($sd.proj != null and $sd.proj < 70) or ($sd.rem <= 129600 and $sd.used < 60)))
     or ($fh != null and ($fh.stale | not) and $fh.rem <= 3600 and $fh.used < 50)) as $under_cand
  | ($under_cand and ($under_out | not)) as $under_in
  # c = when `over` first qualified to leave (readings below the leave thresholds); it resets whenever they stop qualifying
  | (if ($fh == null and $sd == null) then {b: "normal", s: ($since | if $cur == "normal" then . else $now end), p: 0, c: 0}        # no live window: no evidence at all
     elif $over_in then {b: "over", s: $now, p: 0, c: 0}
     elif $cur == "over" and ($over_out | not) then {b: "over", s: $since, p: 0, c: 0}
     elif $cur == "over" and ($calm == 0 or ($now - $calm) < 1800) then {b: "over", s: $since, p: 0, c: (if $calm == 0 then $now else $calm end)}
     elif $under_in then
       (if $cur == "under" then {b: "under", s: $since, p: 0, c: 0}
        elif $pend > 0 and ($now - $pend) >= 1800 then {b: "under", s: $now, p: 0, c: 0}
        else {b: "normal", s: ($since | if $cur == "normal" then . else $now end), p: (if $pend > 0 then $pend else $now end), c: 0} end)
     else {b: "normal", s: ($since | if $cur == "normal" then . else $now end), p: 0, c: 0} end) as $n
  | (if $n.b == "over" then (if $fh != null and $fh.used >= 85 then "5h" else "7d" end)
     elif ($sd != null and $sd.rem <= 129600 and $sd.used < 60) or ($sd != null and $sd.proj != null and $sd.proj < 70) then "7d" else "5h" end) as $which
  | (if $which == "5h" then $fh else $sd end) as $w0
  | (if $w0 != null then [$which, $w0] elif $which == "5h" then ["7d", $sd] else ["5h", $fh] end) as $pair   # a held band may have lost its own window to a reset
  | {band: $n.b, since: $n.s, pend: $n.p, calm: $n.c,
     mx: {fh: ($fh | if . == null then null else {r: .r, p: .used} end), sd: ($sd | if . == null then null else {r: .r, p: .used} end)},
     wk: ($sd | if . == null then null else {used, proj, rem, stale} end),
     reason: (if $pair[1] == null then "" else "\($pair[0]) \($pair[1].used | floor)% used, resets in \(human($pair[1].rem))" end)}
' <<<"$ROW" 2>/dev/null) || none
[ -n "$DECISION" ] || { { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; }; }

BAND=$(jq -r '.band' <<<"$DECISION" 2>/dev/null) || none
[ -n "$BAND" ] || none
REASON=$(jq -r '.reason' <<<"$DECISION" 2>/dev/null) || none
NEWSTATE=$(jq -c '{band, since, pend, calm, mx}' <<<"$DECISION")
# keep the history bounded: past 2 MB, keep the newest 5000 rows
if [ "$PEEK" = 0 ] && [ -f "$FILE" ] && [ "$(wc -c < "$FILE" 2>/dev/null | tr -d ' ')" -gt 2097152 ] 2>/dev/null; then
  tail -n 5000 "$FILE" > "$FILE.$$" 2>/dev/null && mv -f "$FILE.$$" "$FILE" 2>/dev/null || rm -f "$FILE.$$" 2>/dev/null
fi
if [ "$PEEK" = 0 ] && { [ ! -e "$STATE" ] || [ -f "$STATE" ]; } && [ "$NEWSTATE" != "$(jq -c '{band: (.band // "normal"), since: (.since // 0), pend: (.pend // 0), calm: (.calm // 0), mx: {fh: (.mx.fh? // null), sd: (.mx.sd? // null)}}' <<<"$PREV" 2>/dev/null)" ]; then
  if mkdir -p "$(dirname "$STATE")" 2>/dev/null && printf '%s\n' "$NEWSTATE" > "$STATE.$$" 2>/dev/null; then
    mv -f "$STATE.$$" "$STATE" 2>/dev/null || rm -f "$STATE.$$" 2>/dev/null
  fi
fi

if [ "$MODE" = forecast ]; then
  FC=$(emit_forecast) || FC=""; [ -n "$FC" ] || FC="||||"
  printf '%s|%s|%s\n' "$PROVIDER" "$(jq -r '(.wk.used // "")' <<<"$DECISION")" "$FC"
  exit 0
fi
if [ "$MODE" = sprint ]; then
  IFS='|' read -r s_used s_rem s_fh < <(jq -r '[(.wk.used // ""), (.wk.rem // ""), (.mx.fh.p // "")] | map(tostring) | join("|")' <<<"$DECISION" 2>/dev/null) || true
  s_in=$(LC_ALL=C awk -v r="${s_rem:-}" -v h="$SHOURS" 'BEGIN { if (r !~ /^[0-9]+([.][0-9]+)?$/ || r + 0 <= 0) print "none"; else if (r + 0 < 600) print "out"; else if (r + 0 <= h * 3600) print "in"; else print "out" }')
  s_hl=""; [ "$s_in" = none ] || s_hl=$(LC_ALL=C awk -v r="$s_rem" 'BEGIN { printf "%.1f", r / 3600 }')
  if [ "${MEGAVIBE_SPRINT:-1}" = 0 ]; then printf '%s|-|%s|%s|||||off|%s\n' "$PROVIDER" "$s_hl" "${s_used:-}" "${s_fh:-}"; exit 0; fi
  if [ "$s_in" != in ]; then printf '%s|-|%s|%s|||||outside|%s\n' "$PROVIDER" "$s_hl" "${s_used:-}" "${s_fh:-}"; exit 0; fi
  # inside the window a cached Codex reading is not good enough: run once more past the cache
  if [ "$PROVIDER" = codex ] && [ "$SPRINT_FRESH" != 1 ] && [ -z "${MEGAVIBE_NOW:-}" ]; then
    fresh=$(_MEGAVIBE_SPRINT_FRESH=1 MEGAVIBE_ROUTER_PROVIDER=codex bash "$0" sprint 2>/dev/null)
    case "$fresh" in codex\|*) printf '%s\n' "$fresh"; exit 0 ;; esac   # a re-run that printed nothing falls through to this pass
  fi
  OT=$TARGET; TARGET=$STARGET; SPRINT_BURST=1; FSTALE=1200; [ "$STALE" -ge 1200 ] || FSTALE=$STALE
  FC=$(emit_forecast) || FC=""
  IFS='|' read -r _ s_fc s_spare s_spend s_basis <<<"${FC:-||||}"
  s_reason=$(LC_ALL=C awk -v fc="$s_fc" -v spare="$s_spare" -v used="${s_used:-}" -v fh="${s_fh:-}" -v t="$STARGET" -v ot="$OT" 'BEGIN {
    if (fc !~ /^[0-9]+([.][0-9]+)?$/) print "no-forecast"
    else if (fh ~ /^[0-9]+([.][0-9]+)?$/ && fh + 0 >= 85) print "5h-hot"
    else if (spare + 0 < 2 || used + 0 > t - 2 || ot + 0 >= t + 0) print "no-room"
    else print "ok" }')
  s_state="-"; [ "$s_reason" != ok ] || s_state=sprint
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$PROVIDER" "$s_state" "$s_hl" "${s_used:-}" "$s_fc" "$s_spare" "$s_spend" "$s_basis" "$s_reason" "${s_fh:-}"
  exit 0
fi
if [ "$MODE" = pace ]; then
  PACE=$(emit_pace) || none
  [ -n "$PACE" ] || none
  printf '%s\n' "$PACE"
  exit 0
fi
if [ "$MODE" = status ] || [ "$MODE" = status-pace ]; then
  STATUS=$(jq -r --arg b "$BAND" --arg r "$REASON" '[$b, (.wk.used // "" | if type == "number" then floor else . end), (.wk.proj // "" | if type == "number" then floor else . end), (.wk.rem // "" | if type == "number" then floor else . end), (.wk.stale // false | if . then 1 else 0 end), $r] | map(tostring) | join("|")' <<<"$DECISION" 2>/dev/null) || none
  # Never append pace to a missing status prefix: it would shift every column.
  [ -n "$STATUS" ] || none
  if [ "$MODE" = status-pace ]; then
    PACE=$(emit_pace) || PACE=""
    [ -n "$PACE" ] || PACE="$PROVIDER||||||"
    printf '%s|%s\n' "$STATUS" "$PACE"
  else printf '%s\n' "$STATUS"; fi
  exit 0
fi
if [ "$MODE" = codex-band ]; then printf '%s\n' "$BAND"; exit 0; fi
if [ "$MODE" = codex ]; then
  # Advice only: the band and its reason. The effort field stays empty since 2026-10-11 (the automatic
  # xhigh for reviews was removed: no better in a blind benchmark, and it timed out on real large reviews);
  # the field is kept so callers that read four fields keep working.
  EFF=""
  printf '%s||%s|%s\n' "$BAND" "$EFF" "$REASON"
  exit 0
fi
if [ "$MODE" = band ]; then printf '%s\n' "$BAND"; exit 0; fi

if [ "$MODE" = advisory ]; then
  [ -n "$REASON" ] || exit 0
  case "$BAND" in
    over)  printf 'usage router: Claude %s. Pass model:"haiku" (digest, extract) or model:"sonnet" to every subagent and never let one inherit the session model; the reviewer subagent stays as pinned.\n' "$REASON" ;;
    under) printf 'usage router: Claude %s. Capacity left unused at reset is lost: let judgment-heavy subagents inherit the session model instead of pinning Sonnet.\n' "$REASON" ;;
  esac
  exit 0
fi

rank_model() { case "$1" in *haiku*) echo 1;; *sonnet*) echo 2;; *opus*) echo 3;; *fable*) echo 4;; *) echo 0;; esac; }
rank_effort() { case "$1" in low) echo 1;; medium) echo 2;; high) echo 3;; xhigh) echo 4;; max) echo 5;; *) echo 0;; esac; }
CUR_M=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null); CUR_E=$(jq -r '.effortLevel // empty' "$SETTINGS" 2>/dev/null)
RM=$(rank_model "$CUR_M"); RE=$(rank_effort "$CUR_E"); MODEL=""; EFFORT=""
case "$BAND" in
  over)  { [ "$RM" -eq 0 ] || [ "$RM" -gt 2 ]; } && MODEL="sonnet"
         { [ "$RE" -eq 0 ] || [ "$RE" -gt 2 ]; } && EFFORT="medium" ;;
  under) [ "$RM" -ge 1 ] && [ "$RM" -lt "$(rank_model "$UP")" ] && MODEL="$UP" ;;
esac
printf '%s|%s|%s|%s\n' "$BAND" "$MODEL" "$EFFORT" "$REASON"
exit 0
