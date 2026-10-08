#!/usr/bin/env bash
# usage-route.sh — subscription-first routing from the Claude usage history.
#
#   usage-route.sh claude     one line: band|model|effort|reason (| not tab: read collapses empty tab fields)
#   usage-route.sh advisory   one sentence for a session, or nothing in the normal band
#   usage-route.sh band       just the band name (over | normal | under)
#
# Input: ~/.megavibe/usage/claude.jsonl, appended by template/statusline.sh from the
# statusline's account-wide rate_limits (five_hour / seven_day used_percentage and
# resets_at). Claude Code has no usage API, so the history is the only source.
#
# Bands: over (used up or running hot: cut model/effort, pin subagents down), normal
# (no effect), under (capacity that will be lost at reset: upgrade the model).
# Hysteresis keeps it from flapping: `over` enters at once; it leaves 30 minutes after its
# leave thresholds first hold (a remembered reading of 85% or more holds until the window
# resets or the projection falls with elapsed time, and a fresh window still waits out the
# 30 minutes); `under` needs two qualifying evaluations 30 minutes apart. Escape hatches:
# MEGAVIBE_ROUTER=0, or delete route-state.json.
# Missing, malformed or reset-window data is the normal band, so the router can only ever
# change today's behaviour on evidence. A reading older than 6h inside a live window still
# counts toward `over` (usage only grows inside a window) but never toward `under`. Exit status is always 0.
#
# Test seams: MEGAVIBE_USAGE_FILE, MEGAVIBE_USAGE_STATE, MEGAVIBE_NOW,
# MEGAVIBE_USER_SETTINGS. Tuning: MEGAVIBE_ROUTER_UP (model for `under`, default opus).
set -uo pipefail

MV="${MEGAVIBE_HOME:-$HOME/.megavibe}"
FILE="${MEGAVIBE_USAGE_FILE:-$MV/usage/claude.jsonl}"
STATE="${MEGAVIBE_USAGE_STATE:-$MV/usage/route-state.json}"
NOW="${MEGAVIBE_NOW:-$(date +%s 2>/dev/null)}"
SETTINGS="${MEGAVIBE_USER_SETTINGS:-$HOME/.claude/settings.json}"
UP="${MEGAVIBE_ROUTER_UP:-opus}"
MODE="${1:-claude}"; PEEK=0; [ "${2:-}" = "--peek" ] && PEEK=1   # --peek: report, never advance the hysteresis state

none() { printf 'normal|||\n'; exit 0; }
command -v jq >/dev/null 2>&1 || { { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; }; }
case "$NOW" in ''|*[!0-9]*) { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; } ;; esac

ROW=""
[ -r "$FILE" ] && ROW=$(tail -n 50 "$FILE" 2>/dev/null | jq -cR 'fromjson? | select(type == "object")' 2>/dev/null | jq -sc 'select(length > 0)' 2>/dev/null)
PREV=$(cat "$STATE" 2>/dev/null | jq -sc 'map(select(type == "object")) | last // empty' 2>/dev/null)
[ -n "$ROW" ] || { { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; }; }
[ -n "$PREV" ] || PREV='{}'

# shellcheck disable=SC2016
DECISION=$(jq -c --argjson now "$NOW" --argjson prev "$PREV" '
  def sec: if . > 100000000000 then . / 1000 else . end;      # a resets_at in milliseconds
  # A window is live while its resets_at is ahead. Rows from idle sessions can be logged late
  # and carry an old window, so liveness (not append order) picks the window: the newest live
  # row names it, and usage only grows inside a window, so the highest reading of it is current.
  # The highest reading of a live window is also kept in the state file, keyed by its reset
  # time in seconds, so a flood of later rows outside the 50-row slice read here, or a
  # seconds/ms mismatch, cannot hide it. With no live row at all the remembered reading stands
  # alone and counts as stale (no basis for `under`).
  def pick($k):
    [.[] | select(((.[$k].r? // null) | type) == "number" and ((.[$k].r | sec) > $now))] as $live
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
         stale: (($now - ($w.t | tonumber? // 0)) > 21600)}      # old reading in a live window: still a floor for `over`, no basis for `under`
    end;
  def human($s): if $s >= 172800 then "\($s / 86400 | floor)d"
                 elif $s >= 3600 then "\($s / 3600 | floor)h" else "\([$s / 60 | floor, 1] | max)m" end;
  win(pick("fh"); 18000) as $fh | win(pick("sd"); 604800) as $sd
  | (if ($prev.band | type) == "string" then $prev.band else "normal" end) as $cur
  | (($prev.since | numbers) // 0) as $since | (($prev.calm | numbers) // 0) as $calm   # a damaged state file is read as "no state"
  | ((($prev.pend | numbers) // 0) | if ($now - .) > 7200 then 0 else . end) as $pend    # a pending `under` evaluation lapses after 2h
  | (($sd != null and ($sd.used >= 90 or ($sd.proj != null and $sd.proj > 100))) or ($fh != null and $fh.used >= 85)) as $over_in
  | (($sd == null or ($sd.used < 85 and ($sd.proj == null or $sd.proj < 90))) and ($fh == null or $fh.used < 70)) as $over_out
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
     elif $cur == "under" and ($under_out | not) and ($now - $since) < 21600 then {b: "under", s: $since, p: 0, c: 0}
     else {b: "normal", s: ($since | if $cur == "normal" then . else $now end), p: 0, c: 0} end) as $n
  | (if $n.b == "over" then (if $fh != null and $fh.used >= 85 then "5h" else "7d" end)
     elif ($sd != null and $sd.rem <= 129600 and $sd.used < 60) or ($sd != null and $sd.proj != null and $sd.proj < 70) then "7d" else "5h" end) as $which
  | (if $which == "5h" then $fh else $sd end) as $w0
  | (if $w0 != null then [$which, $w0] elif $which == "5h" then ["7d", $sd] else ["5h", $fh] end) as $pair   # a held band may have lost its own window to a reset
  | {band: $n.b, since: $n.s, pend: $n.p, calm: $n.c,
     mx: {fh: ($fh | if . == null then null else {r: .r, p: .used} end), sd: ($sd | if . == null then null else {r: .r, p: .used} end)},
     reason: (if $pair[1] == null then "" else "\($pair[0]) \($pair[1].used | floor)% used, resets in \(human($pair[1].rem))" end)}
' <<<"$ROW" 2>/dev/null)
[ -n "$DECISION" ] || { { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; }; }

BAND=$(jq -r '.band' <<<"$DECISION"); REASON=$(jq -r '.reason' <<<"$DECISION")
NEWSTATE=$(jq -c '{band, since, pend, calm, mx}' <<<"$DECISION")
# keep the history bounded: past 2 MB, keep the newest 5000 rows
if [ "$PEEK" = 0 ] && [ "$(wc -c < "$FILE" 2>/dev/null | tr -d ' ')" -gt 2097152 ] 2>/dev/null; then
  tail -n 5000 "$FILE" > "$FILE.$$" 2>/dev/null && mv -f "$FILE.$$" "$FILE" 2>/dev/null || rm -f "$FILE.$$" 2>/dev/null
fi
if [ "$PEEK" = 0 ] && [ "$NEWSTATE" != "$(jq -c '{band: (.band // "normal"), since: (.since // 0), pend: (.pend // 0), calm: (.calm // 0), mx: {fh: (.mx.fh? // null), sd: (.mx.sd? // null)}}' <<<"$PREV" 2>/dev/null)" ]; then
  if mkdir -p "$(dirname "$STATE")" 2>/dev/null && printf '%s\n' "$NEWSTATE" > "$STATE.$$" 2>/dev/null; then
    mv -f "$STATE.$$" "$STATE" 2>/dev/null || rm -f "$STATE.$$" 2>/dev/null
  fi
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
