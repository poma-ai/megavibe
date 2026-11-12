#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
# Subscription-first routing, mid-session half: when Claude subscription usage is
# running hot (or capacity will be lost at reset), or Codex has room Claude lacks (or
# the reverse), tell the model once per state per session how to spend subagents. The launch half is `megavibe` + scripts/usage-route.sh.
# Triggered by: SessionStart (startup|resume|clear|compact) and PreToolUse (Agent). The
# PreToolUse context lands after that call chose its model, so it steers the calls after it.
# Advisory only; never blocks, always exits 0.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
UR="${MEGAVIBE_HOME:-$HOME/.megavibe}/scripts/usage-route.sh"
[ -f "$UR" ] || exit 0
[ "${MEGAVIBE_ROUTER:-1}" = "0" ] && exit 0

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "PreToolUse"' 2>/dev/null)
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
case "$SID" in ''|.|..|*[!A-Za-z0-9._-]*) SID="default" ;; esac

BAND=$(bash "$UR" band 2>/dev/null)
FLAG=".agent/LOGS/.usage-band.$SID"
PREVKEY=""; [ -f "$FLAG" ] && PREVKEY=$(cat "$FLAG" 2>/dev/null)   # regular files only: a FIFO here must not hang a hook
case "$PREVKEY" in *:*) ;; ?*) PREVKEY="$PREVKEY:-" ;; esac     # a flag from before the balance existed is a bare band
# Flag = band:prefer:claude-bucket:codex-bucket. A flag with fewer fields is a legacy one and counts as changed.
IFS=: read -r PB PP _ <<<"$PREVKEY"
# Which subscription should optional work lean on? "prefer|sentence", prefer = claude | codex | -
# (the last preference goes in, so the rule can hold it until the gap really closes)
BAL=$(MEGAVIBE_BALANCE_PREV="$PP" bash "$UR" balance 2>/dev/null); PREF="${BAL%%|*}"; BALMSG="${BAL#*|}"
case "$PREF" in claude|codex) ;; *) PREF="-"; BALMSG="" ;; esac
KEY="$BAND:$PREF"
# Both subscriptions' projections, only behind a working band call. The headline is what the band and
# balance decide on (the linear projection, else used percent), truncated like the balance sentence;
# the recent-rate projection, where there is one, is shown beside it.
# Each pace call is bounded (3 s) and writes to a file, so a lingering child cannot hold the hook open.
PROJMSG=""; PROJKNOWN=0
proj() {   # provider -> "value|basis" or "unknown"
  local f u lp rp v="" basis="" extra=""
  f=$(mktemp "${TMPDIR:-/tmp}/usage-pace.XXXXXX" 2>/dev/null) || { echo unknown; return; }
  trap 'rm -f "$f"' EXIT TERM
  if command -v perl &>/dev/null; then
    MEGAVIBE_ROUTER_PROVIDER="$1" perl -e 'alarm 3; exec @ARGV' bash "$UR" pace >"$f" 2>/dev/null </dev/null
  fi
  IFS='|' read -r _ u _ lp _ rp _ <"$f" 2>/dev/null
  rm -f "$f"
  num() { case "$1" in ''|*[!0-9.]*|*.*.*|.) return 1 ;; esac; }
  if num "$lp"; then v=$lp; basis=linear; elif num "$u"; then v=$u; basis=used; elif num "$rp"; then v=$rp; basis=recent; fi
  [ -n "$v" ] || { echo unknown; return; }
  if [ "$basis" != recent ] && num "$rp"; then extra="; recent $(awk -v v="$rp" 'BEGIN { printf "%d", v }')"; fi
  echo "$(awk -v v="$v" 'BEGIN { printf "%d", v }')|$basis$extra"
}
# 10-point buckets, everything at 100 or more in one (it is over either way), so a projection that
# falls hour by hour early in the week does not re-speak every hour.
bucket() { case "$1" in unknown) echo u ;; *) local b=$(( ${1%%|*} / 10 )); [ "$b" -gt 10 ] && b=10; echo "$b" ;; esac; }
fmt() { case "$1" in unknown) echo unknown ;; *) echo "${1%%|*} (${1#*|})" ;; esac; }
if [ -n "$BAND" ]; then
  CP=$(proj claude); XP=$(proj codex)
  KEY="$KEY:$(bucket "$CP"):$(bucket "$XP")"
  PROJMSG="usage router: projections claude $(fmt "$CP"), codex $(fmt "$XP")"
  { [ "$CP" != unknown ] || [ "$XP" != unknown ]; } && PROJKNOWN=1
fi
# SessionStart (a fresh session, /clear, a compaction) always restates a non-normal state: the
# model may have lost the earlier advisory. PreToolUse speaks only when the state changed.
if [ "$EVENT" != "SessionStart" ] && [ "$KEY" = "$PREVKEY" ]; then exit 0; fi
mkdir -p .agent/LOGS 2>/dev/null
{ [ ! -e "$FLAG" ] || [ -f "$FLAG" ]; } && printf '%s' "$KEY" > "$FLAG" 2>/dev/null
MSG=""
case "$BAND" in over|under) MSG=$(bash "$UR" advisory 2>/dev/null) ;; esac
[ -n "$BALMSG" ] && MSG="${MSG:+$MSG }$BALMSG"
# Retract what no longer holds, band and balance independently: a band that just ended (or a balance
# preference that is gone) must not linger in the session. A flag from before the balance existed is a bare band.
RETRACT=""
case "$PB" in over|under) [ "$BAND" = normal ] && RETRACT="Claude usage is back in the normal range; the earlier subagent model advice no longer applies." ;; esac
case "$PP" in claude|codex) [ "$PREF" = "-" ] && RETRACT="${RETRACT:+$RETRACT }The earlier balance advice (which subscription optional work should lean on) no longer applies." ;; esac
[ -n "$RETRACT" ] && MSG="usage router: $RETRACT${MSG:+ $MSG}"
# The projections line rides along whenever the hook speaks, and alone when at least one is known.
if [ -n "$PROJMSG" ] && { [ -n "$MSG" ] || [ "$PROJKNOWN" = 1 ]; }; then MSG="${MSG:+$MSG }$PROJMSG"; fi
[ -n "$MSG" ] || exit 0
jq -n --arg ev "$EVENT" --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}' 2>/dev/null
exit 0
