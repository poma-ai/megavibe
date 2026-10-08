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
# Hysteresis keeps it from flapping: `over` enters at once and leaves after 30 minutes
# below the leave thresholds; `under` needs two qualifying evaluations 30 minutes apart.
# Missing, stale, malformed or reset-window data is the normal band, so the router can
# only ever change today's behaviour on evidence. Exit status is always 0.
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
MODE="${1:-claude}"

none() { printf 'normal|||\n'; exit 0; }
command -v jq >/dev/null 2>&1 || { { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; }; }
case "$NOW" in ''|*[!0-9]*) { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; } ;; esac

ROW=""
[ -r "$FILE" ] && ROW=$(tail -n 50 "$FILE" 2>/dev/null | jq -cR 'fromjson? | select(type == "object")' 2>/dev/null | tail -n 1)
PREV=$(cat "$STATE" 2>/dev/null | jq -c 'select(type == "object")' 2>/dev/null)
[ -n "$ROW" ] || { { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; }; }
[ -n "$PREV" ] || PREV='{}'

# shellcheck disable=SC2016
DECISION=$(jq -c --argjson now "$NOW" --argjson prev "$PREV" '
  def win($w; $len; $t):
    if ($w | type) != "object" or ($w.p | type) != "number" or ($w.r | type) != "number" then null
    elif $w.r <= $now then null                       # that window already reset: fresh
    elif ($now - $t) > 21600 then null                # a reading older than 6h inside a live window
    else ($w.r - $now) as $rem
      | ((1 - $rem / $len) | if . < 0 then 0 elif . > 1 then 1 else . end) as $el
      | {used: $w.p, rem: $rem, el: $el, proj: (if $el >= 0.25 then $w.p / $el else null end)}
    end;
  def human($s): if $s >= 172800 then "\($s / 86400 | floor)d"
                 elif $s >= 3600 then "\($s / 3600 | floor)h" else "\([$s / 60 | floor, 1] | max)m" end;
  (.t // 0) as $t
  | win(.fh; 18000; $t) as $fh | win(.sd; 604800; $t) as $sd
  | ($prev.band // "normal") as $cur | ($prev.since // 0) as $since | ($prev.pend // 0) as $pend
  | (($sd != null and ($sd.used >= 90 or ($sd.proj != null and $sd.proj > 100))) or ($fh != null and $fh.used >= 85)) as $over_in
  | (($sd == null or ($sd.used < 85 and ($sd.proj == null or $sd.proj < 90))) and ($fh == null or $fh.used < 70)) as $over_out
  | ($sd != null and ($sd.used >= 75 or ($sd.proj != null and $sd.proj > 85))) as $under_out
  | (($sd != null and (($sd.proj != null and $sd.proj < 70) or ($sd.rem <= 129600 and $sd.used < 60)))
     or ($fh != null and $fh.rem <= 3600 and $fh.used < 50)) as $under_cand
  | ($under_cand and ($under_out | not)) as $under_in
  | (if $over_in then {b: "over", s: $now, p: 0}
     elif $cur == "over" and (($over_out | not) or ($now - $since) < 1800) then {b: "over", s: $since, p: 0}
     elif $under_in then
       (if $cur == "under" then {b: "under", s: $since, p: 0}
        elif $pend > 0 and ($now - $pend) >= 1800 then {b: "under", s: $now, p: 0}
        else {b: "normal", s: ($since | if $cur == "normal" then . else $now end), p: (if $pend > 0 then $pend else $now end)} end)
     elif $cur == "under" and ($under_out | not) then {b: "under", s: $since, p: 0}
     else {b: "normal", s: ($since | if $cur == "normal" then . else $now end), p: 0} end) as $n
  | (if $n.b == "over" then (if $fh != null and $fh.used >= 85 then "5h" else "7d" end)
     elif ($sd != null and $sd.rem <= 129600 and $sd.used < 60) or ($sd != null and $sd.proj != null and $sd.proj < 70) then "7d" else "5h" end) as $which
  | (if $which == "5h" then $fh else $sd end) as $w
  | {band: $n.b, since: $n.s, pend: $n.p,
     reason: (if $w == null then "" else "\($which) \($w.used | floor)% used, resets in \(human($w.rem))" end)}
' <<<"$ROW" 2>/dev/null)
[ -n "$DECISION" ] || { { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; }; }

BAND=$(jq -r '.band' <<<"$DECISION"); REASON=$(jq -r '.reason' <<<"$DECISION")
NEWSTATE=$(jq -c '{band, since, pend}' <<<"$DECISION")
if [ "$NEWSTATE" != "$(jq -c '{band: (.band // "normal"), since: (.since // 0), pend: (.pend // 0)}' <<<"$PREV" 2>/dev/null)" ]; then
  if mkdir -p "$(dirname "$STATE")" 2>/dev/null && printf '%s\n' "$NEWSTATE" > "$STATE.$$" 2>/dev/null; then
    mv -f "$STATE.$$" "$STATE" 2>/dev/null || rm -f "$STATE.$$" 2>/dev/null
  fi
fi

if [ "$MODE" = band ]; then printf '%s\n' "$BAND"; exit 0; fi

if [ "$MODE" = advisory ]; then
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
