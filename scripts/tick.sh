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
#   github: per repo, inside the window: PRs updated (author named; your own PRs left out),
#           review requests addressed to you (always listed while open), reviews and issue /
#           review comments by others. [bot] accounts left out; TICK_PEOPLE marked "!".
#           Lists are paged (up to 2,000 PRs or comments per repo and window, reviews on up to
#           30 updated PRs); past that the tick is incomplete. At most 60 lines per repo.
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
# is exact, half-open (last, now]; --no-mark leaves it alone (a dry run). A failed or
# truncated gh / curl call is reported in its section, NOT retried (a polling loop that
# hammers an API on an auth failure is the failure mode this avoids), the first line says
# INCOMPLETE and the window is NOT advanced (its start is kept in NAME.pending until a tick
# completes), so nothing is silently skipped. A misconfiguration (gh missing, a malformed
# repo, Linear on without a key) is reported the same way, never as "quiet". Exit 0 after a
# tick; 2 only for a bad option, a bad --since or an unreadable clock (nothing was checked).
# A mark in the future (clock moved) falls back to a 60-second window.
# Test seams: MEGAVIBE_HOME, MEGAVIBE_NOW, MEGAVIBE_TICK_CONF, MEGAVIBE_GH (the gh
# command), MEGAVIBE_CURL, MEGAVIBE_LINEAR_URL, plus usage-route.sh's and claude-auth-check.sh's own.
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
# An incomplete tick writes the start of the window it could not finish to NAME.pending, so
# that even a FIRST tick (no mark yet) keeps its start instead of defaulting again next time.
PENDING_FILE="$STATE_DIR/$NAME.pending"
case "$SINCE" in ''|*[!0-9]*) [ -f "$PENDING_FILE" ] && [ ! -L "$PENDING_FILE" ] && SINCE=$(head -c 20 "$PENDING_FILE" 2>/dev/null | tr -dc '0-9') ;; esac
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
# Every call's status and body are checked. A failed or truncated call marks the tick
# INCOMPLETE: it is reported, nothing is retried, and the window is NOT advanced, so the
# next tick covers the same span again instead of silently dropping what the failed call
# would have returned.
INCOMPLETE=0
GH="${MEGAVIBE_GH:-gh}"
# The helpers below run inside command substitutions, where a variable set is lost, so an
# incomplete check is recorded in a notes file and folded into the report by the main shell.
NOTES=$(mktemp "${TMPDIR:-/tmp}/tick-notes.XXXXXX" 2>/dev/null) || NOTES=""
PAGES=""; [ -n "$NOTES" ] && { PAGES=$(mktemp "${TMPDIR:-/tmp}/tick-pages.XXXXXX" 2>/dev/null) || PAGES=""; }
trap '[ -n "$NOTES" ] && rm -f "$NOTES"; [ -n "$PAGES" ] && rm -f "$PAGES"' EXIT
note() { printf '  %s\n' "$1" >> "$NOTES" 2>/dev/null || INCOMPLETE=1; }
flush_notes() {   # -> appends the recorded notes to $lines and marks the tick incomplete
  if [ -s "$NOTES" ]; then INCOMPLETE=1; lines="${lines}$(cat "$NOTES")"$'\n'; : > "$NOTES"; fi
}
gh_json() {   # gh_json LABEL ARGS... -> prints a JSON array, or records the failure and returns 1
  local label="$1" out rc; shift
  out=$("$GH" "$@" 2>/dev/null); rc=$?
  if [ "$rc" != 0 ] || ! printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    note "incomplete: ${label} failed (gh exit ${rc}; auth, network or scope); not retried, window kept"
    return 1
  fi
  printf '%s' "$out"
}
gh_pages() {   # gh_pages LABEL PATH MAXPAGES [STOPKEY]: concatenated pages of 100; stops when a page is short or
               # (STOPKEY given) the last item's STOPKEY is at or before the window start; marks truncation past MAXPAGES.
               # Pages are collected in a file and joined with `jq -s`: a page never goes through argv (macOS caps it).
  local label="$1" path="$2" max="$3" key="${4:-}" page=1 chunk n last rc=0
  : > "$PAGES" 2>/dev/null || { note "incomplete: ${label}: cannot write the page file; window kept"; printf '[]'; return 1; }
  while :; do
    chunk=$(gh_json "$label (page $page)" api "${path}&per_page=100&page=${page}") || { rc=1; break; }
    printf '%s\n' "$chunk" >> "$PAGES" 2>/dev/null || { note "incomplete: ${label}: cannot write the page file; window kept"; rc=1; break; }
    n=$(printf '%s' "$chunk" | jq 'length' 2>/dev/null); [ -n "$n" ] || n=0
    [ "$n" -lt 100 ] && break
    if [ -n "$key" ]; then
      last=$(printf '%s' "$chunk" | jq -r --arg k "$key" '.[-1][$k] // ""' 2>/dev/null)
      if [ -n "$last" ] && { [ "$last" \< "$SINCE_ISO" ] || [ "$last" = "$SINCE_ISO" ]; }; then break; fi
    fi
    page=$((page + 1))
    if [ "$page" -gt "$max" ]; then
      note "incomplete: ${label} truncated after $((max * 100)) items; window kept"; break
    fi
  done
  jq -sc 'add // []' "$PAGES" 2>/dev/null || { note "incomplete: ${label}: pages unreadable; window kept"; printf '[]'; rc=1; }
  return $rc
}
rows() {   # rows LABEL JQ_FILTER <json: the filter's output lines, or a note and nothing (a jq failure is never silent)
  local label="$1" f="$2" out
  out=$(jq -r --arg s "$SINCE_ISO" --arg n "$NOW_ISO" --arg me "${ME:-}" --arg bots "${BOTS:-0}" "$JQW $f" 2>/dev/null) || { note "incomplete: ${label}: unreadable answer; window kept"; return 1; }
  printf '%s' "$out"
}
if [ -z "$NOTES" ] || [ -z "$PAGES" ]; then
  # Without the scratch files a failed call could not be recorded, so nothing is checked.
  INCOMPLETE=1; say "! github/linear: no scratch file for failure tracking (TMPDIR unwritable?); checks skipped, window kept"; NEED=$((NEED + 1))
elif [ "${#REPOS[@]}" -eq 0 ]; then
  if [ "${TICK_LINEAR:-0}" = 1 ]; then say "github: no repos configured (TICK_REPOS, or pass org/repo); Linear only"
  else NEED=$((NEED + 1)); say "! github: nothing to watch: no repos configured (TICK_REPOS, or pass org/repo) and TICK_LINEAR is off"; fi
elif ! command -v "$GH" >/dev/null 2>&1; then
  INCOMPLETE=1; NEED=$((NEED + 1)); say "! github: gh is not installed, so the repos cannot be checked; window kept"
else
  ME="${TICK_GH_USER:-}"
  if [ -z "$ME" ] && [ -f "$STATE_DIR/gh-user" ] && [ ! -L "$STATE_DIR/gh-user" ]; then ME=$(head -c 80 "$STATE_DIR/gh-user" 2>/dev/null | tr -dc 'A-Za-z0-9-'); fi
  GH_OK=1
  if [ -z "$ME" ]; then
    ME=$("$GH" api user --jq .login 2>/dev/null | tr -dc 'A-Za-z0-9-')
    if [ -n "$ME" ]; then mkdir -p "$STATE_DIR" 2>/dev/null && { [ ! -e "$STATE_DIR/gh-user" ] || [ -f "$STATE_DIR/gh-user" ]; } && printf '%s' "$ME" > "$STATE_DIR/gh-user" 2>/dev/null
    else GH_OK=0; INCOMPLETE=1; say "! github: gh cannot reach GitHub as you (gh auth status); nothing checked, not retried, window kept"; NEED=$((NEED + 1)); fi
  fi
  if [ "$GH_OK" = 1 ]; then
    PEOPLE=" ${TICK_PEOPLE:-} "; BOTS="${TICK_BOTS:-0}"   # *[bot] accounts are noise unless TICK_BOTS=1
    mark() { case "$PEOPLE" in *" $1 "*) printf '! ' ;; *) printf '  ' ;; esac; }
    # jq: the window is half-open, (since, now]: an item stamped exactly at the mark belongs to
    # the tick that made the mark and never to the next one. GitHub stamps are whole seconds.
    # Accepted: an item that becomes visible only after the mark, with a stamp before it (API
    # lag), is missed. SHORTCUT: no overlap + dedup; add one if a missed item is ever observed.
    # Fields can be null (a deleted account, a bodiless review): every one is defaulted, and a
    # comment from a gone account is still activity, listed as "(no account)".
    JQW='def login: (.user.login // "(no account)"); def inwin($k): ((.[$k] // "") > $s and (.[$k] // "") <= $n); def human: ($bots == "1" or (login | test("\\[bot\\]$") | not));'
    # Review requests addressed to you are listed while open, whatever their age: a request
    # needs an answer until it has one. The search is scoped to the watched repos; at the
    # limit the tick is incomplete (a request past it would stay unseen).
    lines=""
    RR_REPO_ARGS=(); for repo in "${REPOS[@]}"; do case "$repo" in */*) RR_REPO_ARGS+=(--repo "$repo") ;; esac; done
    RR=$(gh_json "review-request search" search prs --review-requested=@me --state=open --limit 100 "${RR_REPO_ARGS[@]}" --json repository,number,title,updatedAt) || RR='[]'
    RR_N=$(printf '%s' "$RR" | jq 'length' 2>/dev/null); [ "${RR_N:-0}" -ge 100 ] && note "incomplete: 100 or more open review requests on the watched repos; window kept"
    flush_notes; PRELUDE="$lines"
    for repo in "${REPOS[@]}"; do
      case "$repo" in */*) ;; *) INCOMPLETE=1; NEED=$((NEED + 1)); say "! github $repo: not of the form org/repo, not checked; window kept"; continue ;; esac
      lines=""
      while IFS=$'\t' read -r rnum rtitle; do
        [ -n "$rnum" ] || continue
        lines="${lines}  RR #${rnum} ${rtitle}  (review requested from you)"$'\n'; NEED=$((NEED + 1))
      done <<<"$(printf '%s' "$RR" | jq -r --arg r "$repo" '.[] | select((.repository.nameWithOwner // "") == $r) | [.number, ((.title // "") | .[0:80])] | @tsv' 2>/dev/null)"
      # PRs by most recent update, inside the window. The list API names the AUTHOR, not who
      # caused the update, so a PR you authored is left out (you follow it anyway; what others
      # do on it shows up below as reviews and comments) and the line says "author", not "by".
      prs=$(gh_pages "PR list $repo" "repos/$repo/pulls?state=all&sort=updated&direction=desc" 20 updated_at) || true
      PR_ROWS=$(printf '%s' "$prs" | rows "PR list $repo" '.[] | select(inwin("updated_at") and human) | [.number, ((.title // "") | gsub("[\\r\\n\\t]+"; " ") | .[0:80]), (.updated_at // ""), login, (.state // ""), (if .draft then "1" else "" end)] | @tsv') || PR_ROWS=""
      while IFS=$'\t' read -r num title upd user state draft; do
        [ -n "$num" ] || continue
        [ "$user" = "$ME" ] || { lines="${lines}$(mark "$user")PR #${num} ${state}${draft:+ draft} (author ${user}) updated $(hm "$upd"): ${title}"$'\n'; NEED=$((NEED + 1)); }
      done <<<"$PR_ROWS"
      # Reviews submitted inside the window, looked for on every PR updated SINCE the window
      # start with no upper bound (a PR touched again after the cutoff would otherwise hide a
      # review inside the window for good); the window applies to the review's own stamp. One
      # call per PR, at most 30 PRs, the rest reported as incomplete.
      k=0
      CAND=$(printf '%s' "$prs" | rows "PR list $repo" '.[] | select((.updated_at // "") > $s) | .number') || CAND=""
      for num in $CAND; do
        k=$((k + 1))
        if [ "$k" -gt 30 ]; then note "incomplete: reviews checked on 30 PRs only; window kept"; break; fi
        rv=$(gh_json "reviews of #$num" api "repos/$repo/pulls/$num/reviews?per_page=100") || continue
        [ "$(printf '%s' "$rv" | jq 'length' 2>/dev/null)" = 100 ] && note "incomplete: #$num has 100 or more reviews; window kept"
        RV_ROWS=$(printf '%s' "$rv" | rows "reviews of #$num" '.[] | select(inwin("submitted_at") and login != $me and human) | [login, ((.state // "") | ascii_downcase), (.submitted_at // ""), ((.body // "") | gsub("[\\r\\n\\t]+"; " ") | .[0:100])] | @tsv') || RV_ROWS=""
        while IFS=$'\t' read -r ruser rstate rat rbody; do
          [ -n "$ruser" ] || continue
          lines="${lines}$(mark "$ruser")review #${num} ${rstate} by ${ruser} $(hm "$rat"): ${rbody}"$'\n'; NEED=$((NEED + 1))
        done <<<"$RV_ROWS"
      done
      # Issue and review comments. `since` is on updated_at (an edited old comment comes back and
      # is dropped by created_at here, on purpose: an edit is not new activity).
      for kind in issues pulls; do
        cm=$(gh_pages "$kind comments $repo" "repos/$repo/$kind/comments?since=$SINCE_ISO&sort=created&direction=asc" 20) || true
        CM_ROWS=$(printf '%s' "$cm" | rows "$kind comments $repo" '.[] | select(inwin("created_at") and login != $me and human) | [login, (.created_at // ""), (.html_url // ""), ((.body // "") | gsub("[\\r\\n\\t]+"; " ") | .[0:160])] | @tsv') || CM_ROWS=""
        while IFS=$'\t' read -r cuser cat curl cbody; do
          [ -n "$cuser" ] || continue
          lines="${lines}$(mark "$cuser")comment by ${cuser} $(hm "$cat") ${curl}: ${cbody}"$'\n'; NEED=$((NEED + 1))
        done <<<"$CM_ROWS"
      done
      # Bounded output: the model reads this; past 60 lines a repo gets a count instead. The
      # incomplete notes are added after the cut, so they are never the lines that get dropped.
      ln=$(printf '%s' "$lines" | grep -c '' 2>/dev/null || echo 0)
      [ "$ln" -gt 60 ] && lines="$(printf '%s' "$lines" | head -60)"$'\n'"  ... and $((ln - 60)) more lines in this repo (run the tick with --since for the full list)"$'\n'
      flush_notes
      lines="${PRELUDE}${lines}"; PRELUDE=""
      if [ -n "$lines" ]; then say "github $repo:"; OUT="${OUT}${lines}"; else say "github $repo: nothing new"; fi
    done
    [ -n "$PRELUDE" ] && { say "github:"; OUT="${OUT}${PRELUDE}"; }   # a search note with no valid repo to hang it on
  fi
fi

# --- linear -----------------------------------------------------------------
CURL="${MEGAVIBE_CURL:-curl}"
if [ -z "$NOTES" ] || [ -z "$PAGES" ]; then
  :   # said above: no scratch file, nothing checked
elif [ "${TICK_LINEAR:-0}" = 1 ]; then
  key="${LINEAR_API_KEY:-}"
  [ -z "$key" ] && [ -n "${TICK_LINEAR_KEY_FILE:-}" ] && [ -f "$TICK_LINEAR_KEY_FILE" ] && key=$(head -c 200 "$TICK_LINEAR_KEY_FILE" 2>/dev/null)
  key=$(printf '%s' "$key" | tr -d '[:space:]')
  if [ -z "$key" ]; then
    INCOMPLETE=1; NEED=$((NEED + 1)); say "! linear: switched on but no key (LINEAR_API_KEY or TICK_LINEAR_KEY_FILE); not checked, window kept"
  elif ! command -v "$CURL" >/dev/null 2>&1; then
    INCOMPLETE=1; NEED=$((NEED + 1)); say "! linear: switched on but curl is not installed; not checked, window kept"
  else
    q=$(jq -n --arg s "$SINCE_ISO" --arg n "$NOW_ISO" '{query: "{ viewer { name } comments(first: 100, orderBy: createdAt, filter: {createdAt: {gt: \"\($s)\", lte: \"\($n)\"}}) { nodes { createdAt url user { name } issue { identifier } body } } }"}')
    # The key goes to curl as a config line on stdin (`-K -`), never in argv: argv is readable
    # by every process on the machine through `ps`. Quotes and backslashes in the value are
    # escaped the way curl's config parser reads them. The answer is accepted only when curl
    # exits 0, the HTTP status is 200, there is no `errors` key and the nodes are an array;
    # the diagnostic is fixed text (a server message could reflect the credential).
    kesc=$(printf '%s' "$key" | sed 's/[\\"]/\\&/g')
    http=""; resp=$(printf 'header = "Authorization: %s"\n' "$kesc" | "$CURL" -sS --max-time 20 -K - "${MEGAVIBE_LINEAR_URL:-https://api.linear.app/graphql}" -H 'Content-Type: application/json' -d "$q" -w '\n%{http_code}' 2>/dev/null); crc=$?
    http="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
    gql_err=$(printf '%s' "$resp" | jq -r 'if type == "object" and has("errors") then "yes" else "no" end' 2>/dev/null)
    if [ "$crc" != 0 ] || [ "$http" != 200 ] || [ "$gql_err" != no ] || ! printf '%s' "$resp" | jq -e '.data.comments.nodes | type == "array"' >/dev/null 2>&1; then
      INCOMPLETE=1; NEED=$((NEED + 1))
      say "! linear: query failed (curl exit ${crc}, HTTP ${http:-none}, GraphQL errors: ${gql_err:-unreadable}); not retried, window kept"
    else
      LP=" ${TICK_LINEAR_PEOPLE:-} "
      lines=""
      [ "$(printf '%s' "$resp" | jq '.data.comments.nodes | length' 2>/dev/null)" = 100 ] && note "incomplete: 100 or more comments in the window; window kept"
      while IFS=$'\t' read -r lat lname lid lurl lbody; do
        [ -n "$lat" ] || continue
        m="  "; case "$LP" in *" $lname "*) m="! " ;; esac
        lines="${lines}${m}${lid} by ${lname} $(hm "$lat") ${lurl}: ${lbody}"$'\n'; NEED=$((NEED + 1))
      done <<<"$(printf '%s' "$resp" | jq -r '(.data.viewer.name // "") as $me | .data.comments.nodes[] | select((.user.name // "") != $me) | [(.createdAt // ""), ((.user.name // "?") | gsub("[\\r\\n\\t]+"; " ")), (.issue.identifier // "?"), (.url // ""), ((.body // "") | gsub("[\\r\\n\\t]+"; " ") | .[0:160])] | @tsv' 2>/dev/null)"
      flush_notes
      if [ -n "$lines" ]; then say "linear:"; OUT="${OUT}${lines}"; else say "linear: nothing new"; fi
    fi
  fi
fi

# --- report + mark ----------------------------------------------------------
if [ "$NEED" -gt 0 ]; then head="tick $NAME: NEEDS ACTION ($NEED)"; else head="tick $NAME: quiet"; fi
[ "$INCOMPLETE" = 1 ] && head="$head, INCOMPLETE"
printf '%s | window %s..%s\n' "$head" "$SINCE_ISO" "$NOW_ISO"
printf '%s' "$OUT"
if [ "$MARK" = 1 ] && mkdir -p "$STATE_DIR" 2>/dev/null; then
  if [ "$INCOMPLETE" = 0 ]; then
    if { [ ! -e "$LAST_FILE" ] || [ -f "$LAST_FILE" ]; }; then
      printf '%s\n' "$NOW" > "$LAST_FILE.$$" 2>/dev/null && mv -f "$LAST_FILE.$$" "$LAST_FILE" 2>/dev/null || rm -f "$LAST_FILE.$$" 2>/dev/null
    fi
    [ -f "$PENDING_FILE" ] && rm -f "$PENDING_FILE" 2>/dev/null
  elif { [ ! -e "$PENDING_FILE" ] || [ -f "$PENDING_FILE" ]; }; then
    printf '%s\n' "$SINCE" > "$PENDING_FILE.$$" 2>/dev/null && mv -f "$PENDING_FILE.$$" "$PENDING_FILE" 2>/dev/null || rm -f "$PENDING_FILE.$$" 2>/dev/null
  fi
fi
exit 0
