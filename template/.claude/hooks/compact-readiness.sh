#!/bin/bash
# compact-readiness — is it safe to compact? A few plain lines; exit 0 = ready,
# 1 = not ready (each blocking line says what is missing), 2 = cannot tell.
#
# Why this exists (measured 2026-10-18 on one real autonomous session): the
# protocol's staleness counter (log-tool-event.sh) resets on ANY .agent/*.md
# write, so an event appended every few minutes — by the session or by the
# context watcher — keeps it at zero while DECISIONS.md and TASKS.md go stale
# for a day; the watcher STAGES decisions to a file nobody in the session reads;
# and the close-out flag of compaction-autopilot.sh is per fill cycle, which
# without a compaction can be days. Nothing compared the registers against the
# event log. This does, by reading files only — no backend, no network — so it
# is cheap enough for a hook and plain enough to run by hand.
#
# What is checked (B = blocks readiness, I = information only):
#   B  decision-like events newer than DECISIONS.md (keyword match on the
#      write-once event files; a line that only mentions DECISIONS.md itself,
#      i.e. a record of recording, does not count)
#   B  TASKS.md older than the newest event by more than a lag, with events in
#      between (mtime: a watcher note is a write too, so this under-reports)
#   B  decisions staged by the context watcher and still pending review
#   B  background tasks found without a heartbeat at a recent turn end
#   I  this session's WORKING_CONTEXT (age; over an hour means /rehydrate
#      will be required after the compaction — it is rebuilt, not lost)
#   I  uncommitted work (survives a compaction; the event log should say what
#      it is for)
#
# Usage:
#   compact-readiness.sh [--project DIR] [--session ID]
#   compact-readiness.sh --decisions-since FILE [--project DIR]
#       prints the number of decision-like events newer than FILE's mtime;
#       exit 1 when there are any, 0 when none (compaction-autopilot.sh uses
#       this to let a close-out flag expire)
#
# The session is --session, else $CLAUDE_CODE_SESSION_ID (set in the Bash
# tool), else the session whose tool-call counter was touched last; the first
# line says which. Full id or the 12-character prefix the flag files use.
#
# Env: MEGAVIBE_READY_DECISION_RE (ERE, case-sensitive), MEGAVIBE_READY_TASKS_LAG_MIN
# (default 60), MEGAVIBE_READY_TASKS_MIN_EVENTS (default 3), MEGAVIBE_BG_CHECK_SECS
# (the heartbeat interval watch-background.sh uses; a task nudged within twice
# that is "found without a heartbeat").
#
# Not set -e: a report has to come out even when one probe fails.
set -u

PROJECT="."
SESSION=""
SINCE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-.}"; shift 2 ;;
    --session) SESSION="${2:-}"; shift 2 ;;
    --decisions-since) SINCE_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "compact-readiness: unknown argument: $1" >&2; exit 2 ;;
  esac
done
cd "$PROJECT" 2>/dev/null || { echo "compact-readiness: cannot cd to $PROJECT" >&2; exit 2; }
[ -d ".agent" ] || { echo "compact-readiness: no .agent/ in $(pwd) — not a megavibe project"; exit 2; }

NOW=$(date +%s 2>/dev/null | tr -cd '0-9'); NOW="${NOW:-0}"
[ "$NOW" -gt 0 ] || { echo "compact-readiness: cannot read the clock"; exit 2; }

# Decision-like: the protocol's own vocabulary. Case-sensitive on purpose:
# "DECISIONS.md" must not match "decision", and "default a value" must not
# match the D-block's "default B". Lines that name DECISIONS.md are records of
# recording and are skipped (see decision_like_count).
DEFAULT_RE='[Dd]ecided|[Dd]ecision|(^|[^[:alnum:]_])D[0-9]{1,3}([^[:alnum:]_]|$)|(^|[^[:alnum:]_])[Cc]hose(n)?([^[:alnum:]_]|$)|[Aa]greed|[Vv]erdict|[Mm]y default|default if unanswered|default [A-D]([^[:alnum:]_]|$)'
RE="${MEGAVIBE_READY_DECISION_RE:-$DEFAULT_RE}"
LAG_MIN="${MEGAVIBE_READY_TASKS_LAG_MIN:-60}";      case "$LAG_MIN" in ''|*[!0-9]*) LAG_MIN=60 ;; esac
MIN_EVENTS="${MEGAVIBE_READY_TASKS_MIN_EVENTS:-3}"; case "$MIN_EVENTS" in ''|*[!0-9]*) MIN_EVENTS=3 ;; esac
CHECK_SECS="${MEGAVIBE_BG_CHECK_SECS:-300}";        case "$CHECK_SECS" in ''|*[!0-9]*) CHECK_SECS=300 ;; esac
[ "$CHECK_SECS" -ge 60 ] || CHECK_SECS=60
[ "$CHECK_SECS" -le 600 ] || CHECK_SECS=600

mtime_epoch() {  # file -> epoch, 0 when unreadable
  local m
  m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s' "$m"
}
epoch_name() {  # epoch -> the UTC stamp event files are named with
  date -u -r "$1" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -d "@$1" +%Y%m%dT%H%M%SZ 2>/dev/null || echo ""
}
name_epoch() {  # event file name -> epoch from its stamp; the file's mtime when date cannot parse it
  local s="${1:0:16}" e=""
  case "$s" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
      e=$(date -u -j -f '%Y%m%dT%H%M%SZ' "$s" +%s 2>/dev/null \
          || date -u -d "${s:0:4}-${s:4:2}-${s:6:2} ${s:9:2}:${s:11:2}:${s:13:2}" +%s 2>/dev/null || echo "") ;;
  esac
  case "$e" in ''|*[!0-9]*) e=$(mtime_epoch ".agent/events/$1") ;; esac
  printf '%s' "$e"
}
fmt_age() {  # seconds -> "3d 4h" | "4h 05m" | "12m"
  local s="$1"; [ "$s" -ge 0 ] 2>/dev/null || s=0
  if [ "$s" -ge 86400 ]; then printf '%dd %dh' $((s / 86400)) $(((s % 86400) / 3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh %02dm' $((s / 3600)) $(((s % 3600) / 60))
  else printf '%dm' $((s / 60)); fi
}
plural() { [ "$1" -eq 1 ] && printf '%s' "$2" || printf '%s' "$3"; }

# Event files, by name: the stamp is UTC and write-once, so lexical order is
# chronological and survives a sync that rewrites mtimes. Names outside the
# pattern are ignored.
EVENTS=$(ls -1 .agent/events 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z-' | LC_ALL=C sort)
N_EVENTS=0; [ -n "$EVENTS" ] && N_EVENTS=$(printf '%s\n' "$EVENTS" | wc -l | tr -d ' ')
NEWEST=""; [ -n "$EVENTS" ] && NEWEST=$(printf '%s\n' "$EVENTS" | tail -1)

events_newer_than() {  # epoch -> names of events whose stamp is later than it
  local cut; cut=$(epoch_name "$1")
  [ -n "$cut" ] && [ -n "$EVENTS" ] || return 0
  printf '%s\n' "$EVENTS" | awk -v c="$cut" '$0 > c'
}
decision_like_count() {  # names on stdin -> number of files with a decision-like line that is not about DECISIONS.md
  local n=0 f
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f ".agent/events/$f" ] || continue
    if grep -E "$RE" ".agent/events/$f" 2>/dev/null | grep -q -v 'DECISIONS\.md'; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

# --- --decisions-since FILE: the one-number mode ----------------------------
if [ -n "$SINCE_FILE" ]; then
  [ -e "$SINCE_FILE" ] || { echo "compact-readiness: no such file: $SINCE_FILE" >&2; exit 2; }
  N=$(events_newer_than "$(mtime_epoch "$SINCE_FILE")" | decision_like_count)
  echo "$N"
  [ "$N" -eq 0 ] && exit 0 || exit 1
fi

# --- which session -----------------------------------------------------------
SID_HOW=""
if [ -n "$SESSION" ]; then SID_HOW="--session"
elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then SESSION="$CLAUDE_CODE_SESSION_ID"; SID_HOW="CLAUDE_CODE_SESSION_ID"
else
  _c=$(ls -t .agent/LOGS/.tool-call-counter.* 2>/dev/null | grep -v '\.lock$' | head -1)
  if [ -n "$_c" ]; then SESSION="${_c##*/.tool-call-counter.}"; SID_HOW="newest tool-call counter"; fi
fi
SESSION=$(printf '%s' "$SESSION" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
case "$SESSION" in .|..) SESSION="" ;; esac
SID12="${SESSION:0:12}"

BLOCK=""   # blocking lines
INFO=""    # information lines
NB=0
block() { BLOCK="${BLOCK}
- [!] $1"; NB=$((NB + 1)); }
info()  { INFO="${INFO}
- [i] $1"; }

# --- DECISIONS.md against the events ----------------------------------------
if [ -f .agent/DECISIONS.md ]; then
  DM=$(mtime_epoch .agent/DECISIONS.md)
  SINCE=$(events_newer_than "$DM"); NS=0; [ -n "$SINCE" ] && NS=$(printf '%s\n' "$SINCE" | wc -l | tr -d ' ')
  ND=$(printf '%s\n' "$SINCE" | decision_like_count)
  L="DECISIONS.md written $(fmt_age $((NOW - DM))) ago; ${NS} $(plural "$NS" event events) since, ${ND} look$(plural "$ND" s '') like $(plural "$ND" 'a decision' decisions)"
  if [ "$ND" -gt 0 ]; then block "$L — record them in .agent/DECISIONS.md (what was decided and why), then it is current"
  else info "$L"; fi
else
  block "DECISIONS.md is missing — create .agent/DECISIONS.md with this session's decisions"
fi

# --- TASKS.md against the newest event --------------------------------------
if [ -f .agent/TASKS.md ]; then
  TM=$(mtime_epoch .agent/TASKS.md)
  SINCE=$(events_newer_than "$TM"); NS=0; [ -n "$SINCE" ] && NS=$(printf '%s\n' "$SINCE" | wc -l | tr -d ' ')
  if [ -n "$NEWEST" ]; then
    NE=$(name_epoch "$NEWEST"); LAG=$((NE - TM)); [ "$LAG" -ge 0 ] || LAG=0
    L="TASKS.md written $(fmt_age $((NOW - TM))) ago, newest event $(fmt_age $((NOW - NE))) ago; ${NS} $(plural "$NS" event events) in between (mtime: a watcher note is a write too)"
    if [ "$LAG" -gt $((LAG_MIN * 60)) ] && [ "$NS" -ge "$MIN_EVENTS" ]; then
      block "$L — update .agent/TASKS.md: status of each item and who each open one is blocked on (lag over ${LAG_MIN}m)"
    else info "$L"; fi
  else
    info "TASKS.md written $(fmt_age $((NOW - TM))) ago; no events in .agent/events"
  fi
else
  block "TASKS.md is missing — create .agent/TASKS.md with what is open and who each item is blocked on"
fi

# --- decisions the watcher staged and nobody reviewed ------------------------
pending_in() {  # file -> number of rows with status pending
  if command -v jq >/dev/null 2>&1; then jq -r 'select(.status == "pending") | 1' "$1" 2>/dev/null | wc -l | tr -d ' '
  else grep -c '"status": *"pending"' "$1" 2>/dev/null || echo 0; fi
}
P_MINE=0; P_OTHER=0; P_FILES=""
for f in .agent/LOGS/pending-decisions.*.jsonl; do
  [ -f "$f" ] || continue
  n=$(pending_in "$f"); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ] || continue
  fs="${f##*/pending-decisions.}"; fs="${fs%.jsonl}"
  if [ -n "$SID12" ] && [ "$fs" = "$SID12" ]; then P_MINE=$((P_MINE + n)); P_FILES="${P_FILES:+$P_FILES, }$f"
  else P_OTHER=$((P_OTHER + n)); fi
done
if [ -n "$SID12" ]; then
  if [ "$P_MINE" -gt 0 ]; then
    block "${P_MINE} $(plural "$P_MINE" decision decisions) staged by the context watcher from this session, pending review (${P_FILES}) — review them (python3 ~/.megavibe/scripts/review-decisions.py --session ${SID12}) or record the real ones in .agent/DECISIONS.md yourself$([ "$P_OTHER" -gt 0 ] && printf '; %s more from other sessions' "$P_OTHER")"
  elif [ "$P_OTHER" -gt 0 ]; then
    info "no staged decisions from this session; ${P_OTHER} from other sessions still pending review (review-decisions.py --list)"
  else
    info "no decisions staged by the context watcher await review"
  fi
else
  if [ $((P_MINE + P_OTHER)) -gt 0 ]; then
    block "$((P_MINE + P_OTHER)) $(plural $((P_MINE + P_OTHER)) decision decisions) staged by the context watcher pending review (session unknown, all counted) — python3 ~/.megavibe/scripts/review-decisions.py"
  else info "no decisions staged by the context watcher await review"; fi
fi

# --- background tasks without a heartbeat ------------------------------------
# watch-background.sh records {id, kind, started, nudged} per task this session
# started and rewrites the file at each turn end to the tasks still alive;
# nudged is when a turn end last found the task with no heartbeat. Coverage is
# only known at a turn boundary, so a nudge older than two intervals is
# reported, not counted.
BG_FILE=""
if [ -n "$SESSION" ]; then
  for f in ".agent/LOGS/.bg-tasks.${SESSION}.jsonl" .agent/LOGS/.bg-tasks."${SID12}"*.jsonl; do
    [ -f "$f" ] && { BG_FILE="$f"; break; }
  done
fi
if [ -n "$BG_FILE" ] && [ -s "$BG_FILE" ] && command -v jq >/dev/null 2>&1; then
  NT=0; NOHB=0; OLDHB=""
  while IFS=$'\t' read -r id kind started nudged; do
    [ -n "$id" ] || continue
    case "$started" in ''|*[!0-9]*) started=0 ;; esac
    case "$nudged" in ''|*[!0-9]*) nudged=0 ;; esac
    NT=$((NT + 1))
    if [ "$nudged" -gt 0 ]; then
      if [ $((NOW - nudged)) -le $((CHECK_SECS * 2)) ]; then
        NOHB=$((NOHB + 1))
        block "background ${kind} task ${id} (started $(fmt_age $((NOW - started))) ago) was found without a heartbeat $(fmt_age $((NOW - nudged))) ago — arm a Monitor on its output, or TaskStop it"
      else
        OLDHB="${OLDHB:+$OLDHB, }${kind} ${id} (no heartbeat $(fmt_age $((NOW - nudged))) ago)"
      fi
    fi
  done < <(jq -r 'select(type == "object") | [(.id // ""), (.kind // "?"), (.started // 0 | tostring), (.nudged // 0 | tostring)] | @tsv' "$BG_FILE" 2>/dev/null)
  if [ "$NT" -gt 0 ]; then
    info "${NT} background $(plural "$NT" task tasks) recorded alive at the last turn end$([ "$NOHB" -gt 0 ] && printf ', %s without a heartbeat' "$NOHB")${OLDHB:+; earlier nudges: $OLDHB}; coverage is known only at a turn end"
  else info "no background tasks recorded for this session"; fi
elif [ -n "$SESSION" ]; then
  info "no background tasks recorded for this session"
else
  info "background tasks: session unknown, not checked"
fi

# --- this session's WORKING_CONTEXT ------------------------------------------
WC=""
if [ -n "$SESSION" ]; then
  for d in ".agent/sessions/${SESSION}" .agent/sessions/"${SID12}"*; do
    [ -s "$d/WORKING_CONTEXT.md" ] && { WC="$d/WORKING_CONTEXT.md"; break; }
  done
fi
if [ -n "$WC" ]; then
  WA=$((NOW - $(mtime_epoch "$WC")))
  if [ "$WA" -gt 3600 ]; then info "WORKING_CONTEXT ${WC} written $(fmt_age "$WA") ago (over 1h: /rehydrate will be required after the compaction; it is rebuilt from .agent/, not lost)"
  else info "WORKING_CONTEXT ${WC} written $(fmt_age "$WA") ago (fresh: /rehydrate will be optional)"; fi
elif [ -n "$SESSION" ]; then
  info "no WORKING_CONTEXT for session ${SESSION} under .agent/sessions/ (/rehydrate will be required after the compaction)"
else
  info "WORKING_CONTEXT: session unknown, not checked"
fi

# --- uncommitted work ----------------------------------------------------------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  NU=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' '); NU="${NU:-0}"
  if [ "$NU" -gt 0 ]; then info "uncommitted work: ${NU} $(plural "$NU" path paths) (git status --porcelain; survives the compaction — the event log should say what it is for)"
  else info "uncommitted work: none"; fi
else
  info "uncommitted work: not a git repository"
fi

# --- verdict -------------------------------------------------------------------
WHO="session ${SESSION:-unknown}${SID_HOW:+ [$SID_HOW]}"
if [ "$NB" -gt 0 ]; then
  echo "compact-readiness: NOT READY — ${NB} blocking $(plural "$NB" item items) (${WHO}; ${N_EVENTS} events in .agent/events)${BLOCK}${INFO}"
  exit 1
fi
echo "compact-readiness: READY (${WHO}; ${N_EVENTS} events in .agent/events)${INFO}"
exit 0
