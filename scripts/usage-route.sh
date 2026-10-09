#!/usr/bin/env bash
# usage-route.sh — subscription-first routing from the Claude usage history.
#
#   usage-route.sh claude     one line: band|model|effort|reason (| not tab: read collapses empty tab fields)
#   usage-route.sh advisory   one sentence for a session, or nothing in the normal band
#   usage-route.sh band       just the band name (over | normal | under)
#   usage-route.sh codex      the same line for Codex: band||effort|reason (effort only in `under`, for reviews)
#   usage-route.sh codex-band just the Codex band name
#   usage-route.sh balance    one line: prefer|sentence — which subscription optional work (digests, exploration,
#                             second opinions) should lean on; prefer is claude, codex or - (no preference)
#   usage-route.sh status     band|used|proj|rem|stale|reason for the weekly window of $MEGAVIBE_ROUTER_PROVIDER (claude, default, or codex)
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
# 30 minutes); `under` needs two qualifying evaluations 30 minutes apart and lasts only while its
# qualifying reading holds (the 5h window that justified it resetting ends it). Escape hatches:
# MEGAVIBE_ROUTER=0, or delete route-state.json.
# Missing, malformed or reset-window data is the normal band, so the router can only ever
# change today's behaviour on evidence. A reading older than 6h inside a live window still
# counts toward `over` (usage only grows inside a window) but never toward `under`. Exit status is always 0.
#
# Test seams: MEGAVIBE_USAGE_FILE, MEGAVIBE_USAGE_STATE, MEGAVIBE_NOW,
# MEGAVIBE_USER_SETTINGS, MEGAVIBE_CODEX_HOME, MEGAVIBE_CODEX_STATE, MEGAVIBE_CODEX_CONFIG. Tuning: MEGAVIBE_ROUTER_UP (model for `under`, default opus).
set -uo pipefail

MV="${MEGAVIBE_HOME:-$HOME/.megavibe}"
FILE="${MEGAVIBE_USAGE_FILE:-$MV/usage/claude.jsonl}"
STATE="${MEGAVIBE_USAGE_STATE:-$MV/usage/route-state.json}"
NOW="${MEGAVIBE_NOW:-$(date +%s 2>/dev/null)}"
SETTINGS="${MEGAVIBE_USER_SETTINGS:-$HOME/.claude/settings.json}"
UP="${MEGAVIBE_ROUTER_UP:-opus}"
MODE="${1:-claude}"; PEEK=0; [ "${2:-}" = "--peek" ] && PEEK=1   # --peek: report, never advance the hysteresis state
PROVIDER="${MEGAVIBE_ROUTER_PROVIDER:-claude}"; STALE=21600
case "$MODE" in codex|codex-band) PROVIDER=codex ;; esac
if [ "$PROVIDER" = codex ]; then
  FILE=""; STATE="${MEGAVIBE_CODEX_STATE:-$MV/usage/codex-route-state.json}"; STALE=86400
fi

# Codex rows in the history's shape ({t, sd:{p,r}, fh:{p,r}}) from the six most recently written rollout files
# of the last 8 days (by mtime, sorted over the whole list: a resumed session keeps appending to an old file).
# Bounded: at most 1 MB read per file, and the result is cached for 2 minutes (the hook runs on every Agent call).
# Invalid evidence is dropped before it can count: a negative or non-numeric reading, a reading dated in the
# future; a window listed twice keeps the HIGHER usage, so entry order can never turn 95% into spare capacity.
codex_row() {
  local root="${MEGAVIBE_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}/sessions" f cache="$MV/usage/codex-row.cache"
  [ -d "$root" ] || return 0
  # The cache is skipped when a test pins the clock (MEGAVIBE_NOW): fixtures change between calls.
  if [ -z "${MEGAVIBE_NOW:-}" ] && [ -f "$cache" ] && [ ! -L "$cache" ]; then
    local at; at=$(head -n 1 "$cache" 2>/dev/null)
    case "$at" in ''|*[!0-9]*) ;; *) if [ "$((NOW - at))" -ge 0 ] && [ "$((NOW - at))" -lt 120 ]; then tail -n +2 "$cache" 2>/dev/null; return 0; fi ;; esac
  fi
  local -a sf; if stat -c %Y / >/dev/null 2>&1; then sf=(-c '%Y %n'); else sf=(-f '%m %N'); fi
  # `find -exec ... +` runs the command once per chunk, so sorting INSIDE it (ls -t) is only right per chunk:
  # print "mtime path" per file and sort the whole list instead.
  local rows
  rows=$(find -H "$root" -type f -name 'rollout-*.jsonl' -mtime -8 -exec stat "${sf[@]}" {} + 2>/dev/null \
    | sort -rn | head -6 | cut -d' ' -f2- | while IFS= read -r f; do
    [ -f "$f" ] && tail -c 1048576 "$f" 2>/dev/null | grep '"rate_limits"' | tail -n 200
  done | jq -cR --argjson now "$NOW" 'fromjson? | select(type == "object") | (.payload.rate_limits? // null) as $rl
      | select(($rl | type) == "object" and (($rl.limit_id // "codex") == "codex"))
      | ((.timestamp? // "") | tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0) as $t
      | select($t <= $now + 300)
      | {t: $t}
        + (reduce ([$rl.primary?, $rl.secondary?][]
                   | select(type == "object" and (.used_percent | type) == "number" and .used_percent >= 0 and (.resets_at | type) == "number")
                   | {key: (if .window_minutes == 10080 then "sd" elif .window_minutes == 300 then "fh" else empty end), value: {p: .used_percent, r: .resets_at}}) as $e
             ({}; .[$e.key] = (if .[$e.key] == null or $e.value.p > .[$e.key].p then $e.value else .[$e.key] end)))
      | select(length > 1)' 2>/dev/null \
    | jq -sc 'select(length > 0) | sort_by(.t) | .[-12:]' 2>/dev/null)
  [ -n "$rows" ] || return 0
  if [ -z "${MEGAVIBE_NOW:-}" ] && { [ ! -e "$cache" ] || [ -f "$cache" ]; } && mkdir -p "$MV/usage" 2>/dev/null; then
    { printf '%s\n' "$NOW"; printf '%s\n' "$rows"; } > "$cache.$$" 2>/dev/null && mv -f "$cache.$$" "$cache" 2>/dev/null || rm -f "$cache.$$" 2>/dev/null
  fi
  printf '%s\n' "$rows"
}

none() {   # no evidence: the normal band, in the shape of the mode asked for
  case "$MODE" in advisory) ;; band|codex-band) echo normal ;; status) echo 'normal|||||' ;; balance) echo '-|' ;; *) printf 'normal|||\n' ;; esac
  exit 0
}
command -v jq >/dev/null 2>&1 || { { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; }; }
case "$NOW" in ''|*[!0-9]*) { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; } ;; esac

if [ "$MODE" = balance ]; then
  # Where should OPTIONAL work (digests, exploration, second opinions) lean? Each subscription's weekly
  # window projects its end-of-window use; spend the one with room. The reviewer floor never moves.
  # HACK: no hysteresis on the 20-point rule, so two projections hovering near 20 apart can flip the advice;
  # the hook speaks on each flip. Upgrade: remember the last preference in the state file and require 10.
  pk=""; [ "$PEEK" = 1 ] && pk="--peek"
  IFS='|' read -r cb cu cp _ cs _ < <(MEGAVIBE_ROUTER_PROVIDER=claude bash "$0" status $pk 2>/dev/null) || true
  IFS='|' read -r xb xu xp _ xs _ < <(MEGAVIBE_ROUTER_PROVIDER=codex bash "$0" status $pk 2>/dev/null) || true
  awk -v cb="${cb:-}" -v cu="${cu:-}" -v cp="${cp:-}" -v xb="${xb:-}" -v xu="${xu:-}" -v xp="${xp:-}" -v cs="${cs:-0}" -v xs="${xs:-0}" 'BEGIN {
    if (cu == "" || xu == "") { print "-|"; exit }
    cj = (cp == "" ? cu : cp) + 0; xj = (xp == "" ? xu : xp) + 0; known = (cp != "" && xp != "")
    pref = "-"
    if (cb == "over" && xb == "over") { print "-|"; exit }          # nowhere to lean
    if (cb == "over" && xb != "over") pref = "codex"
    else if (xb == "over" && cb != "over") pref = "claude"
    else if (known && cj - xj >= 20) pref = "codex"
    else if (known && xj - cj >= 20) pref = "claude"
    # Never lean on a subscription already projected to end near its limit.
    if ((pref == "codex" && xj >= 85) || (pref == "claude" && cj >= 85)) pref = "-"
    # An old reading only under-states use (it grows inside a window): never send work to a subscription
    # whose figure is stale, only away from one.
    if ((pref == "codex" && xs == 1) || (pref == "claude" && cs == 1)) pref = "-"
    if (pref == "-") { print "-|"; exit }
    st = (cp == "" ? sprintf("Claude %d%% used", cu) : sprintf("Claude projects ~%d%%", cj)) " of its week, " (xp == "" ? sprintf("Codex %d%% used", xu) : sprintf("Codex ~%d%%", xj))
    hot = (cb == "over" || xb == "over") ? " (one is running hot)" : ""
    to = (pref == "codex" ? "Codex" : "the Claude subagents")
    printf "%s|usage balance: %s%s. Lean optional work (digests, exploration, second opinions) on %s; the review floor does not move.\n", pref, st, hot, to
  }'
  exit 0
fi

ROW=""
if [ "$PROVIDER" = codex ]; then ROW=$(codex_row)
elif [ -f "$FILE" ] && [ -r "$FILE" ]; then ROW=$(tail -n 50 "$FILE" 2>/dev/null | jq -cR 'fromjson? | select(type == "object")' 2>/dev/null | jq -sc 'select(length > 0)' 2>/dev/null); fi
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
     else {b: "normal", s: ($since | if $cur == "normal" then . else $now end), p: 0, c: 0} end) as $n
  | (if $n.b == "over" then (if $fh != null and $fh.used >= 85 then "5h" else "7d" end)
     elif ($sd != null and $sd.rem <= 129600 and $sd.used < 60) or ($sd != null and $sd.proj != null and $sd.proj < 70) then "7d" else "5h" end) as $which
  | (if $which == "5h" then $fh else $sd end) as $w0
  | (if $w0 != null then [$which, $w0] elif $which == "5h" then ["7d", $sd] else ["5h", $fh] end) as $pair   # a held band may have lost its own window to a reset
  | {band: $n.b, since: $n.s, pend: $n.p, calm: $n.c,
     mx: {fh: ($fh | if . == null then null else {r: .r, p: .used} end), sd: ($sd | if . == null then null else {r: .r, p: .used} end)},
     wk: ($sd | if . == null then null else {used, proj, rem, stale} end),
     reason: (if $pair[1] == null then "" else "\($pair[0]) \($pair[1].used | floor)% used, resets in \(human($pair[1].rem))" end)}
' <<<"$ROW" 2>/dev/null)
[ -n "$DECISION" ] || { { [ "$MODE" = advisory ] && exit 0; [ "$MODE" = band ] && { echo normal; exit 0; }; none; }; }

BAND=$(jq -r '.band' <<<"$DECISION"); REASON=$(jq -r '.reason' <<<"$DECISION")
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

if [ "$MODE" = status ]; then
  jq -r --arg b "$BAND" --arg r "$REASON" '[$b, (.wk.used // "" | if type == "number" then floor else . end), (.wk.proj // "" | if type == "number" then floor else . end), (.wk.rem // "" | if type == "number" then floor else . end), (.wk.stale // false | if . then 1 else 0 end), $r] | map(tostring) | join("|")' <<<"$DECISION" 2>/dev/null
  exit 0
fi
if [ "$MODE" = codex-band ]; then printf '%s\n' "$BAND"; exit 0; fi
if [ "$MODE" = codex ]; then
  # `under` is the only band that acts: reviews think harder with capacity that would reset unspent.
  # `over` changes nothing here: the review floor does not drop, and a Codex that runs dry already falls to the subagent.
  EFF=""
  if [ "$BAND" = under ]; then
    CFG="${MEGAVIBE_CODEX_CONFIG:-${CODEX_HOME:-$HOME/.codex}/config.toml}"
    CUR=$(sed -n 's/^model_reasoning_effort[[:space:]]*=[[:space:]]*"\([a-z]*\)".*/\1/p' "$CFG" 2>/dev/null | head -n 1)
    case "$CUR" in xhigh|max) ;; *) EFF="xhigh" ;; esac
  fi
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
