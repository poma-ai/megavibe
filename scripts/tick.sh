#!/usr/bin/env bash
# tick.sh — one unattended watch tick: what changed since the last tick, and whether
# the session can keep running. Deterministic, no model calls, bounded network use.
# The /watch skill schedules it as a recurring prompt; the session acts on the report.
#
#   tick.sh [--name NAME] [--since EPOCH|ISO8601] [--no-mark] [org/repo ...]
#
# Report (plain text, first line first):
#   tick NAME: NEEDS ACTION (n) | window <from>..<to>        or   tick NAME: quiet | window ...
#   auth:   scripts/claude-auth-check.sh at TICK_AUTH_HOURS (default 12): the refresh token
#           is what keeps an unattended session alive; a warning here goes to the user NOW
#   usage:  both subscriptions' weekly windows (N% used, the projection for the end of
#           the window, time to reset) and `usage-route.sh balance` when it has a preference
#   github: per repo, since the last tick: PRs updated by others, review requests addressed
#           to you (always listed while open), reviews, issue and review comments by others.
#           Your own activity is left out; lines by TICK_PEOPLE are marked "!".
#   linear: comments since the last tick, when TICK_LINEAR=1 and a key is available.
#
# Config, sourced from ~/.megavibe/personal/tick.conf (private; never in a repo) or the
# environment:
#   TICK_REPOS="org/a org/b"      repos to watch (arguments override)
#   TICK_PEOPLE="login1 login2"   GitHub logins whose activity is marked "!"
#   TICK_BOTS=1                   also list *[bot] accounts (left out by default)
#   TICK_AUTH_HOURS=12            warn when the refresh token expires inside this
#   TICK_GH_USER=login            your GitHub login (default: `gh api user`, cached)
#   TICK_LINEAR=1                 also read Linear comments
#   TICK_LINEAR_KEY_FILE=path     file holding the Linear API key ($LINEAR_API_KEY wins)
#   TICK_LINEAR_PEOPLE="Name1 Name2"   Linear display names marked "!"
#   TICK_DEFAULT_WINDOW=2400      seconds looked back on a first run (default 40 min)
#
# State: ~/.megavibe/tick/NAME.last holds the epoch of the last marked tick, so the window
# is exact rather than "about the interval"; --no-mark leaves it alone (a dry run).
# Exit 0 always. A failed gh or curl call is reported in its section and NOT retried: a
# polling loop that hammers an API on an auth failure is the failure mode this avoids.
# Test seams: MEGAVIBE_HOME, MEGAVIBE_NOW, MEGAVIBE_TICK_CONF, MEGAVIBE_GH (the gh
# command), MEGAVIBE_LINEAR_URL, plus usage-route.sh's and claude-auth-check.sh's own.
set -uo pipefail

MV="${MEGAVIBE_HOME:-$HOME/.megavibe}"
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
CONF="${MEGAVIBE_TICK_CONF:-$MV/personal/tick.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && [ ! -L "$CONF" ] && . "$CONF"
NAME="default"; SINCE_ARG=""; MARK=1; REPOS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift ;;
    --since) SINCE_ARG="${2:-}"; shift ;;
    --no-mark) MARK=0 ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) echo "tick: unknown option $1" >&2; exit 2 ;;
    *) REPOS+=("$1") ;;
  esac
  shift
done
case "$NAME" in ''|.|..|*[!A-Za-z0-9._-]*) NAME="default" ;; esac
[ "${#REPOS[@]}" -gt 0 ] || { for r in ${TICK_REPOS:-}; do REPOS+=("$r"); done; }
NOW="${MEGAVIBE_NOW:-$(date +%s 2>/dev/null)}"
case "$NOW" in ''|*[!0-9]*) echo "tick: cannot read the clock" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "tick $NAME: jq is required"; exit 0; }

iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; }
hm() { local t="${1%Z}"; t="${t#*T}"; printf '%s' "${t%:*}Z"; }   # 2026-11-01T10:11:17Z -> 10:11Z
human() { local s="$1"; if [ "$s" -ge 172800 ]; then echo "$((s / 86400))d"; elif [ "$s" -ge 3600 ]; then echo "$((s / 3600))h"; else echo "$(( s / 60 > 1 ? s / 60 : 1 ))m"; fi; }
clip() { cut -c1-"${1:-200}"; }

STATE_DIR="$MV/tick"; LAST_FILE="$STATE_DIR/$NAME.last"
SINCE=""
if [ -n "$SINCE_ARG" ]; then
  case "$SINCE_ARG" in
    *[!0-9]*) SINCE=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$SINCE_ARG" +%s 2>/dev/null || date -u -d "$SINCE_ARG" +%s 2>/dev/null) ;;
    *) SINCE="$SINCE_ARG" ;;
  esac
  case "$SINCE" in ''|*[!0-9]*) echo "tick: --since takes epoch seconds or YYYY-MM-DDTHH:MM:SSZ" >&2; exit 2 ;; esac
elif [ -f "$LAST_FILE" ] && [ ! -L "$LAST_FILE" ]; then
  SINCE=$(head -c 20 "$LAST_FILE" 2>/dev/null | tr -dc '0-9')
fi
case "$SINCE" in ''|*[!0-9]*) SINCE=$((NOW - ${TICK_DEFAULT_WINDOW:-2400})) ;; esac
[ "$SINCE" -lt "$NOW" ] || SINCE=$((NOW - 60))
SINCE_ISO=$(iso "$SINCE"); NOW_ISO=$(iso "$NOW")
NEED=0; OUT=""
say() { OUT="${OUT}${1}"$'\n'; }

# --- auth -------------------------------------------------------------------
AC="$SELF_DIR/claude-auth-check.sh"; [ -f "$AC" ] || AC="$MV/scripts/claude-auth-check.sh"
if [ -f "$AC" ]; then
  a=$(bash "$AC" "${TICK_AUTH_HOURS:-12}" 2>/dev/null); rc=$?
  case "$rc" in 0) say "auth: ${a#claude-auth: }" ;; *) NEED=$((NEED + 1)); say "! auth: ${a#claude-auth: }" ;; esac
else
  say "auth: claude-auth-check.sh not installed (skipped)"
fi

# --- usage ------------------------------------------------------------------
UR="$SELF_DIR/usage-route.sh"; [ -f "$UR" ] || UR="$MV/scripts/usage-route.sh"
if [ -f "$UR" ]; then
  fmt_status() {   # $1 label, $2 status line band|used|proj|rem|stale|reason
    local b u p r s _ ; IFS='|' read -r b u p r s _ <<<"$2"
    [ -n "$u" ] || { printf '%s: no reading' "$1"; return; }
    printf '%s %s%% used' "$1" "$u"
    [ -n "$p" ] && printf ' (~%s%% by week end)' "$p"
    case "$r" in ''|*[!0-9]*) ;; *) printf ', resets in %s' "$(human "$r")" ;; esac
    [ "$s" = 1 ] && printf ' [stale reading]'
    case "$b" in over|under) printf ' [%s]' "$b" ;; esac
  }
  cl=$(MEGAVIBE_ROUTER_PROVIDER=claude bash "$UR" status --peek 2>/dev/null)
  cx=$(MEGAVIBE_ROUTER_PROVIDER=codex bash "$UR" status --peek 2>/dev/null)
  bal=$(bash "$UR" balance --peek 2>/dev/null); pref="${bal%%|*}"
  line="usage: $(fmt_status Claude "$cl") | $(fmt_status Codex "$cx")"
  case "$pref" in claude|codex) line="$line | lean optional work on $pref" ;; esac
  say "$line"
fi

# --- github -----------------------------------------------------------------
GH="${MEGAVIBE_GH:-gh}"
if [ "${#REPOS[@]}" -eq 0 ]; then
  say "github: no repos configured (TICK_REPOS, or pass org/repo)"
elif ! command -v "$GH" >/dev/null 2>&1; then
  say "github: gh not installed (skipped)"
else
  ME="${TICK_GH_USER:-}"
  if [ -z "$ME" ] && [ -f "$STATE_DIR/gh-user" ] && [ ! -L "$STATE_DIR/gh-user" ]; then ME=$(head -c 80 "$STATE_DIR/gh-user" 2>/dev/null | tr -dc 'A-Za-z0-9-'); fi
  GH_OK=1
  if [ -z "$ME" ]; then
    ME=$("$GH" api user --jq .login 2>/dev/null | tr -dc 'A-Za-z0-9-')
    if [ -n "$ME" ]; then mkdir -p "$STATE_DIR" 2>/dev/null && { [ ! -e "$STATE_DIR/gh-user" ] || [ -f "$STATE_DIR/gh-user" ]; } && printf '%s' "$ME" > "$STATE_DIR/gh-user" 2>/dev/null
    else GH_OK=0; say "! github: gh cannot reach GitHub as you (gh auth status); nothing checked, not retried"; NEED=$((NEED + 1)); fi
  fi
  if [ "$GH_OK" = 1 ]; then
    # Review requests addressed to you are listed while open, whatever their age: a request
    # needs an answer until it has one. Filtered to the watched repos.
    RR=$("$GH" search prs --review-requested=@me --state=open --limit 50 --json repository,number,title,updatedAt 2>/dev/null \
      | jq -r '.[] | "\(.repository.nameWithOwner)\t\(.number)\t\(.title)"' 2>/dev/null)
    PEOPLE=" ${TICK_PEOPLE:-} "; BOTS="${TICK_BOTS:-0}"   # *[bot] accounts are noise unless TICK_BOTS=1
    mark() { case "$PEOPLE" in *" $1 "*) printf '! ' ;; *) printf '  ' ;; esac; }
    for repo in "${REPOS[@]}"; do
      case "$repo" in */*) ;; *) say "github $repo: not org/repo (skipped)"; continue ;; esac
      lines=""
      while IFS=$'\t' read -r rrepo rnum rtitle; do
        [ "$rrepo" = "$repo" ] || continue
        lines="${lines}  RR #${rnum} ${rtitle}  (review requested from you)"$'\n'; NEED=$((NEED + 1))
      done <<<"$RR"
      # PRs by most recent update; those touched inside the window by someone else, plus the
      # reviews submitted on them inside the window (the reviews API has no `since`).
      prs=$("$GH" api "repos/$repo/pulls?state=all&sort=updated&direction=desc&per_page=30" 2>/dev/null) || { lines="${lines}  gh api failed for $repo (auth or network); not retried"$'\n'; NEED=$((NEED + 1)); prs="[]"; }
      while IFS=$'\t' read -r num title upd user state draft; do
        [ -n "$num" ] || continue
        [ "$user" = "$ME" ] || { lines="${lines}$(mark "$user")PR #${num} ${state}${draft:+ draft} updated by ${user} $(hm "$upd"): $(printf '%s' "$title" | clip 80)"$'\n'; NEED=$((NEED + 1)); }
      done < <(printf '%s' "$prs" | jq -r --arg s "$SINCE_ISO" --arg bots "$BOTS" '.[] | select(.updated_at > $s and ($bots == "1" or (.user.login | test("\\[bot\\]$") | not))) | [.number, .title, .updated_at, .user.login, .state, (if .draft then "1" else "" end)] | @tsv' 2>/dev/null)
      for num in $(printf '%s' "$prs" | jq -r --arg s "$SINCE_ISO" '.[] | select(.updated_at > $s) | .number' 2>/dev/null | head -10); do
        while IFS=$'\t' read -r ruser rstate rat rbody; do
          [ -n "$ruser" ] || continue
          lines="${lines}$(mark "$ruser")review #${num} ${rstate} by ${ruser} $(hm "$rat"): $(printf '%s' "$rbody" | clip 100)"$'\n'; NEED=$((NEED + 1))
        done < <("$GH" api "repos/$repo/pulls/$num/reviews" 2>/dev/null | jq -r --arg s "$SINCE_ISO" --arg me "$ME" --arg bots "$BOTS" '.[] | select(.submitted_at > $s and .user.login != $me and ($bots == "1" or (.user.login | test("\\[bot\\]$") | not))) | [.user.login, (.state | ascii_downcase), .submitted_at, (.body | gsub("[\\r\\n]+"; " "))] | @tsv' 2>/dev/null)
      done
      for kind in issues pulls; do
        while IFS=$'\t' read -r cuser cat curl cbody; do
          [ -n "$cuser" ] || continue
          lines="${lines}$(mark "$cuser")comment by ${cuser} $(hm "$cat") ${curl}: $(printf '%s' "$cbody" | clip 160)"$'\n'; NEED=$((NEED + 1))
        done < <("$GH" api "repos/$repo/$kind/comments?since=$SINCE_ISO&per_page=50&sort=created&direction=desc" 2>/dev/null | jq -r --arg s "$SINCE_ISO" --arg me "$ME" --arg bots "$BOTS" '.[] | select(.created_at > $s and .user.login != $me and ($bots == "1" or (.user.login | test("\\[bot\\]$") | not))) | [.user.login, .created_at, .html_url, (.body | gsub("[\\r\\n]+"; " "))] | @tsv' 2>/dev/null)
      done
      if [ -n "$lines" ]; then say "github $repo:"; OUT="${OUT}${lines}"; else say "github $repo: nothing new"; fi
    done
  fi
fi

# --- linear -----------------------------------------------------------------
if [ "${TICK_LINEAR:-0}" = 1 ]; then
  key="${LINEAR_API_KEY:-}"
  [ -z "$key" ] && [ -n "${TICK_LINEAR_KEY_FILE:-}" ] && [ -f "$TICK_LINEAR_KEY_FILE" ] && key=$(head -c 200 "$TICK_LINEAR_KEY_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$key" ]; then
    say "linear: no key (LINEAR_API_KEY or TICK_LINEAR_KEY_FILE); skipped"
  elif ! command -v curl >/dev/null 2>&1; then
    say "linear: curl not installed (skipped)"
  else
    q=$(jq -n --arg s "$SINCE_ISO" '{query: "{ viewer { name } comments(first: 30, orderBy: createdAt, filter: {createdAt: {gt: \"\($s)\"}}) { nodes { createdAt url user { name } issue { identifier } body } } }"}')
    resp=$(curl -sS --max-time 20 "${MEGAVIBE_LINEAR_URL:-https://api.linear.app/graphql}" -H "Authorization: $key" -H 'Content-Type: application/json' -d "$q" 2>/dev/null)
    if ! printf '%s' "$resp" | jq -e '.data.comments.nodes | type == "array"' >/dev/null 2>&1; then
      say "! linear: query failed ($(printf '%s' "$resp" | jq -r '.errors[0].message // "no or bad answer"' 2>/dev/null | clip 80)); not retried"; NEED=$((NEED + 1))
    else
      LP=" ${TICK_LINEAR_PEOPLE:-} "
      lines=""
      while IFS=$'\t' read -r lat lname lid lurl lbody; do
        [ -n "$lat" ] || continue
        m="  "; case "$LP" in *" $lname "*) m="! " ;; esac
        lines="${lines}${m}${lid} by ${lname} $(hm "$lat") ${lurl}: $(printf '%s' "$lbody" | clip 160)"$'\n'; NEED=$((NEED + 1))
      done < <(printf '%s' "$resp" | jq -r '.data.viewer.name as $me | .data.comments.nodes[] | select((.user.name // "") != $me) | [.createdAt, (.user.name // "?"), (.issue.identifier // "?"), (.url // ""), (.body | gsub("[\\r\\n]+"; " "))] | @tsv' 2>/dev/null)
      if [ -n "$lines" ]; then say "linear:"; OUT="${OUT}${lines}"; else say "linear: nothing new"; fi
    fi
  fi
fi

# --- report + mark ----------------------------------------------------------
if [ "$NEED" -gt 0 ]; then head="tick $NAME: NEEDS ACTION ($NEED)"; else head="tick $NAME: quiet"; fi
printf '%s | window %s..%s\n' "$head" "$SINCE_ISO" "$NOW_ISO"
printf '%s' "$OUT"
if [ "$MARK" = 1 ] && mkdir -p "$STATE_DIR" 2>/dev/null && { [ ! -e "$LAST_FILE" ] || [ -f "$LAST_FILE" ]; }; then
  printf '%s\n' "$NOW" > "$LAST_FILE.$$" 2>/dev/null && mv -f "$LAST_FILE.$$" "$LAST_FILE" 2>/dev/null || rm -f "$LAST_FILE.$$" 2>/dev/null
fi
exit 0
