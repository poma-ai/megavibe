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
# A fifth field (s + c and/or x) is there only while a subscription is in its end-of-window sprint.
IFS=: read -r PB PP _ _ PS _ <<<"$PREVKEY"
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
  trap 'rm -f "$f"' EXIT
  if command -v perl &>/dev/null; then
    MEGAVIBE_ROUTER_PROVIDER="$1" perl -e 'alarm 3; exec @ARGV' bash "$UR" pace >"$f" 2>/dev/null </dev/null
  fi
  IFS='|' read -r _ u _ lp _ rp _ <"$f" 2>/dev/null
  # the recent-pace forecast (usage-route.sh forecast: provider|used|pace|forecast|spare|spend|basis); a stub or an
  # old script without the mode prints nothing usable and the headline stays the linear projection
  : >"$f"
  if command -v perl &>/dev/null; then
    MEGAVIBE_ROUTER_PROVIDER="$1" perl -e 'alarm 3; exec @ARGV' bash "$UR" forecast >"$f" 2>/dev/null </dev/null
  fi
  IFS='|' read -r _ _ _ fc _ <"$f" 2>/dev/null
  rm -f "$f"
  num() { case "$1" in ''|*[!0-9.]*|*.*.*|.) return 1 ;; esac; }
  if num "$fc"; then v=$fc; basis=forecast
  elif num "$lp"; then v=$lp; basis=linear; elif num "$u"; then v=$u; basis=used; elif num "$rp"; then v=$rp; basis=recent; fi
  [ -n "$v" ] || { echo unknown; return; }
  if [ "$basis" = forecast ] && num "$lp"; then extra="; linear $(awk -v v="$lp" 'BEGIN { printf "%d", v }')"
  elif [ "$basis" != recent ] && num "$rp"; then extra="; recent $(awk -v v="$rp" 'BEGIN { printf "%d", v }')"; fi
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
# End-of-window sprint (usage-route.sh sprint-advice): one sentence per subscription whose weekly window is in
# its last hours with room below the sprint target; nothing otherwise, and then the flag keeps its four fields.
# Bounded (5 s, each provider 2 s inside it) and written to a file like the pace calls, and skipped when the calls
# above already took 3 s, so the whole hook stays inside its 10 s deadline. Only lines that are sprint sentences are relayed.
SPR=""; SK=""
if [ -n "$BAND" ]; then
  src=1
  if [ "$SECONDS" -lt 3 ] && command -v perl &>/dev/null && sf=$(mktemp "${TMPDIR:-/tmp}/usage-sprint.XXXXXX" 2>/dev/null); then
    ( perl -e 'alarm 5; exec @ARGV' bash "$UR" sprint-advice --peek >"$sf" </dev/null; exit $? ) 2>/dev/null   # the subshell keeps bash's "Alarm clock" notice off the hook's stderr
    src=$?
    # whole sentences only: a line cut off by the deadline, or longer than any real one, lacks the closing words
    SPR=$(cut -c1-1200 "$sf" 2>/dev/null | grep -E '^usage sprint: (Claude|Codex) .*unchanged\.$' | head -n 2)
    UNK=$(cut -c1-80 "$sf" 2>/dev/null | grep -E '^usage sprint-unknown: (Claude|Codex)$')
    rm -f "$sf"
    # a provider whose own check could not run keeps the letter the session was last told; the others are decided now
    case "$SPR" in *"usage sprint: Claude "*) SK="c" ;; esac
    case "$UNK" in *Claude*) case "${PS:-}" in s*c*) SK="${SK:-c}" ;; esac ;; esac
    case "$SPR" in *"usage sprint: Codex "*) SK="${SK}x" ;; esac
    case "$UNK" in *Codex*) case "${PS:-}" in s*x) SK="${SK}x" ;; esac ;; esac
    [ -z "$SK" ] || { SK="s$SK"; SPR=$(printf '%s' "$SPR" | tr '\n' ' '); SPR="${SPR% }"; }
  fi
  # A call that could not run, timed out or failed says nothing about the sprint: keep the state the session was
  # last told (no sentence, no withdrawal) instead of reading silence as "the sprint is over".
  if [ "$src" != 0 ]; then SPR=""; SK=""; case "${PS:-}" in sc|sx|scx) SK="$PS" ;; esac; fi
  [ -z "$SK" ] || KEY="$KEY:$SK"
else
  # No band answer: nothing was checked, so the sprint state the session was last told stands.
  # (the whole previous flag is kept: a flag written from a failed lookup would put the sprint letters in the wrong field)
  # Only a flag that carries a sprint field is kept whole; a session that never sprinted keeps the ordinary behaviour.
  case "${PS:-}" in sc|sx|scx) SK="$PS"; [ -z "$PREVKEY" ] || KEY="$PREVKEY" ;; esac
fi
# SessionStart (a fresh session, /clear, a compaction) always restates a non-normal state: the
# model may have lost the earlier advisory. PreToolUse speaks only when the state changed.
if [ "$EVENT" != "SessionStart" ] && [ "$KEY" = "$PREVKEY" ]; then exit 0; fi
mkdir -p .agent/LOGS 2>/dev/null
{ [ ! -e "$FLAG" ] || [ -f "$FLAG" ]; } && printf '%s' "$KEY" > "$FLAG" 2>/dev/null
# Only a projection bucket moved (band and preference as before): the advice is unchanged, so
# say just the new numbers.
if [ "$EVENT" != "SessionStart" ] && [ "$BAND:$PREF" = "$PB:${PP%%:*}" ] && [ "$SK" = "${PS:-}" ] && [ -n "$PROJMSG" ]; then
  jq -n --arg ev "$EVENT" --arg ctx "$PROJMSG" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}' 2>/dev/null
  exit 0
fi
MSG=""
case "$BAND" in over|under) MSG=$(bash "$UR" advisory 2>/dev/null) ;; esac
[ -n "$BALMSG" ] && MSG="${MSG:+$MSG }$BALMSG"
[ -n "$SPR" ] && MSG="${MSG:+$MSG }$SPR"
# Retract what no longer holds, band and balance independently: a band that just ended (or a balance
# preference that is gone) must not linger in the session. A flag from before the balance existed is a bare band.
RETRACT=""
case "$PB" in over|under) [ "$BAND" = normal ] && RETRACT="Claude usage is back in the normal range; the earlier subagent model advice no longer applies." ;; esac
case "$PP" in claude|codex) [ "$PREF" = "-" ] && RETRACT="${RETRACT:+$RETRACT }The earlier balance advice (which subscription optional work should lean on) no longer applies." ;; esac
# A subscription that was sprinting and no longer is: say so by name (the other one may still be).
case "${PS:-}" in sc|sx|scx)
  GONE=""
  case "$PS" in *c*) case "$SK" in *c*) ;; *) GONE="Claude" ;; esac ;; esac
  case "$PS" in *x) case "$SK" in *x) ;; *) GONE="${GONE:+$GONE and }Codex" ;; esac ;; esac
  [ -n "$GONE" ] && RETRACT="${RETRACT:+$RETRACT }The earlier end-of-window sprint advice for $GONE no longer applies: its usual usage target and model advice are back." ;;
esac
[ -n "$RETRACT" ] && MSG="usage router: $RETRACT${MSG:+ $MSG}"
# The projections line rides along whenever the hook speaks, and alone when at least one is known.
if [ -n "$PROJMSG" ] && { [ -n "$MSG" ] || [ "$PROJKNOWN" = 1 ]; }; then MSG="${MSG:+$MSG }$PROJMSG"; fi
[ -n "$MSG" ] || exit 0
jq -n --arg ev "$EVENT" --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}' 2>/dev/null
exit 0
