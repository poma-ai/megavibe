#!/usr/bin/env bash
# tick.sh — one unattended watch tick: what changed since the last tick, and whether
# the session can keep running. Deterministic, no model calls, bounded network use.
# The /watch skill schedules it as a recurring prompt; the session acts on the report.
#
#   tick.sh [--name NAME] [--since EPOCH|ISO8601] [--no-mark] [--reset] [org/repo ...]
#
# Report (plain text, first line first):
#   tick NAME: NEEDS ACTION (n) | window <from>..<to>        or   tick NAME: quiet | window ...
#   auth:   scripts/claude-auth-check.sh at TICK_AUTH_HOURS (default 12): the login lifetime
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
# State in ~/.megavibe/tick/: NAME.last is the end of the last complete window, so the window
# is exact, half-open (last, now]; NAME.pending is the start of a window a tick did not
# finish (written before polling, so a killed tick keeps it; the older of the two wins);
# NAME.report holds the full report when a repo's lines were cut. --no-mark and --since leave
# the marks alone (a dry run or a diagnostic window); --reset abandons an unfinished span on
# purpose (the next tick starts now). A failed or truncated gh / curl call is reported in its
# section, NOT retried (a polling loop that hammers an API on an auth failure is the failure
# mode this avoids), the first line says INCOMPLETE and the window is NOT advanced, so
# nothing is silently skipped; the review cap (30 PRs) instead lists the unchecked PRs and
# advances. A state file that exists but cannot be read is reported and nothing is marked. A misconfiguration (gh missing, a malformed repo, Linear on without a key) and a
# state file that cannot be written are reported the same way, never as "quiet". Exit 0
# after a tick; 2 only for a bad option, a bad --since or an unreadable clock (nothing was
# checked). A mark in the future (clock moved) falls back to a 60-second window.
# Test seams: MEGAVIBE_HOME, MEGAVIBE_NOW, MEGAVIBE_TICK_CONF, MEGAVIBE_GH (the gh
# command), MEGAVIBE_CURL, MEGAVIBE_LINEAR_URL, plus usage-route.sh's and claude-auth-check.sh's own.
set -uo pipefail

MV="${MEGAVIBE_HOME:-$HOME/.megavibe}"
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
CONF="${MEGAVIBE_TICK_CONF:-$MV/personal/tick.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && [ ! -L "$CONF" ] && . "$CONF"
NAME="default"; SINCE_ARG=""; MARK=1; RESET=0; REPOS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || { echo "tick: --name needs a value" >&2; exit 2; }; NAME="$2"; shift ;;
    --since) [ $# -ge 2 ] || { echo "tick: --since needs a value" >&2; exit 2; }; SINCE_ARG="$2"; MARK=0; shift ;;   # a diagnostic window: it never moves the marks
    --no-mark) MARK=0 ;;
    --reset) RESET=1 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) echo "tick: unknown option $1" >&2; exit 2 ;;
    *) REPOS+=("$1") ;;
  esac
  shift
done
# The name is a file name: characters outside [A-Za-z0-9._-] become "_" (never a silent
# fallback to "default", which would make two projects share one window).
NAME=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80); case "$NAME" in ''|.|..) NAME="default" ;; esac
[ "${#REPOS[@]}" -gt 0 ] || { for r in ${TICK_REPOS:-}; do REPOS+=("$r"); done; }
NOW="${MEGAVIBE_NOW:-$(date +%s 2>/dev/null)}"
case "$NOW" in ''|*[!0-9]*) echo "tick: cannot read the clock" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "tick $NAME: jq is required"; exit 0; }

iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; }
hm() { local t="${1%Z}"; t="${t#*T}"; printf '%s' "${t%:*}Z"; }   # 2026-11-01T10:11:17Z -> 10:11Z
human() { local s="$1"; if [ "$s" -ge 172800 ]; then echo "$((s / 86400))d"; elif [ "$s" -ge 3600 ]; then echo "$((s / 3600))h"; else echo "$(( s / 60 > 1 ? s / 60 : 1 ))m"; fi; }
clip() { cut -c1-"${1:-200}"; }

STATE_DIR="$MV/tick"; LAST_FILE="$STATE_DIR/$NAME.last"; PENDING_FILE="$STATE_DIR/$NAME.pending"; REPORT_FILE="$STATE_DIR/$NAME.report"
if [ "$RESET" = 1 ]; then
  # Abandon an unfinished span on purpose (a repo that stays unreadable would keep the window
  # forever): the next tick starts now.
  mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s\n' "$NOW" > "$LAST_FILE" 2>/dev/null && rm -f "$PENDING_FILE" 2>/dev/null \
    && { echo "tick $NAME: window reset; the next tick starts at $(iso "$NOW")"; exit 0; }
  echo "tick $NAME: cannot write $STATE_DIR" >&2; exit 2
fi
SINCE=""
if [ -n "$SINCE_ARG" ]; then
  case "$SINCE_ARG" in
    *[!0-9]*) SINCE=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$SINCE_ARG" +%s 2>/dev/null || date -u -d "$SINCE_ARG" +%s 2>/dev/null) ;;
    *) SINCE="$SINCE_ARG" ;;
  esac
  case "$SINCE" in ''|*[!0-9]*) echo "tick: --since takes epoch seconds or YYYY-MM-DDTHH:MM:SSZ" >&2; exit 2 ;; esac
else
  # NAME.last is the end of the last COMPLETE window; NAME.pending is the start of a window a
  # tick could not finish (written before polling, so a tick killed mid-way keeps it too). The
  # older of the two is the start: unfinished coverage is never skipped by a later mark.
  # A mark that exists but cannot be read, or holds no number, is NOT an absent mark: the
  # tick must not guess a window and then replace the state it could not read.
  read_mark() {   # read_mark FILE -> the epoch, "" when absent, "ERR" when present but unreadable or corrupt
    local v; [ -e "$1" ] || [ -L "$1" ] || { printf ''; return; }
    { [ -f "$1" ] && [ ! -L "$1" ] && v=$(head -c 20 "$1" 2>/dev/null) && [ -n "$v" ]; } || { printf 'ERR'; return; }
    v=$(printf '%s' "$v" | tr -dc '0-9'); [ -n "$v" ] && printf '%s' "$v" || printf 'ERR'
  }
  l=$(read_mark "$LAST_FILE"); pnd=$(read_mark "$PENDING_FILE"); STATE_UNREADABLE=""
  [ "$l" = ERR ] && { STATE_UNREADABLE="${STATE_UNREADABLE} $LAST_FILE"; l=""; }
  [ "$pnd" = ERR ] && { STATE_UNREADABLE="${STATE_UNREADABLE} $PENDING_FILE"; pnd=""; }
  if [ -n "$l" ] && [ -n "$pnd" ]; then SINCE=$(( l < pnd ? l : pnd )); else SINCE="${l:-$pnd}"; fi
fi
case "$SINCE" in ''|*[!0-9]*) SINCE=$((NOW - ${TICK_DEFAULT_WINDOW:-2400})) ;; esac
[ "$SINCE" -lt "$NOW" ] || SINCE=$((NOW - 60))
SINCE_ISO=$(iso "$SINCE"); NOW_ISO=$(iso "$NOW")
NEED=0; OUT=""; FULL=""; INCOMPLETE=0; STATE_LINES=""
say() { OUT="${OUT}${1}"$'\n'; FULL="${FULL}${1}"$'\n'; }   # FULL: the same report without the per-repo cut
if [ -n "${STATE_UNREADABLE:-}" ]; then
  INCOMPLETE=1; NEED=$((NEED + 1)); MARK=0
  STATE_LINES="! state: cannot read${STATE_UNREADABLE} (unreadable or not a number); fix or remove it (or --reset); nothing is marked, the window below is a guess"$'\n'
fi
# Record the start before polling: an unfinished tick (failed, truncated, killed) leaves it
# behind and the next tick starts there. A state directory that cannot be written is reported
# and makes the tick incomplete: a window that cannot be remembered is not a covered window.
if [ "$MARK" = 1 ]; then
  if mkdir -p "$STATE_DIR" 2>/dev/null && { [ ! -e "$PENDING_FILE" ] || [ -f "$PENDING_FILE" ]; } \
     && printf '%s\n' "$SINCE" > "$PENDING_FILE.$$" 2>/dev/null && mv -f "$PENDING_FILE.$$" "$PENDING_FILE" 2>/dev/null; then :
  else rm -f "$PENDING_FILE.$$" 2>/dev/null; INCOMPLETE=1; NEED=$((NEED + 1)); STATE_LINES="! state: cannot record the window start in $STATE_DIR; fix the directory, the window is kept"$'\n'; fi
fi

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
  fmt_status() {   # $1 label, $2 combined status/pace snapshot
    local b u p r s _ lp rate rp; IFS='|' read -r b u p r s _ _ _ _ lp rate rp _ <<<"$2"
    [ -n "$u" ] || { printf '%s: no reading' "$1"; return; }
    printf '%s %s%% used' "$1" "$u"
    if [ -n "$p" ]; then printf ' (linear estimate ~%s%% by week end)' "$p"
    elif [ -n "$lp" ]; then printf ' [linear estimate ~%s%%]' "${lp%%.*}"
    else printf ' [linear estimate unavailable]'; fi
    if [ -n "$rp" ] && [[ "$rate" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      printf ' (recent estimate ~%s%% at %s pts/day)' "${rp%%.*}" "$rate"
    fi
    case "$r" in ''|*[!0-9]*) ;; *) printf ', resets in %s' "$(human "$r")" ;; esac
    [ "$s" = 1 ] && printf ' [stale reading]'
    case "$b" in over|under) printf ' [%s]' "$b" ;; esac
  }
  cl=$(MEGAVIBE_ROUTER_PROVIDER=claude bash "$UR" status-pace --peek 2>/dev/null)
  cx=$(MEGAVIBE_ROUTER_PROVIDER=codex bash "$UR" status-pace --peek 2>/dev/null)
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
      note "incomplete: ${label} truncated after $((max * 100)) items; window kept"; rc=1; break
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
    lines=""; CUT=0
    # Searched in groups whose `repo:` qualifiers stay under about 200 characters (GitHub
    # caps a search query at 256), so long repository names get smaller groups.
    VALID=(); for repo in "${REPOS[@]}"; do case "$repo" in */*) VALID+=("$repo") ;; esac; done
    : > "$PAGES" 2>/dev/null || INCOMPLETE=1
    i=0; while [ "$i" -lt "${#VALID[@]}" ]; do
      RR_REPO_ARGS=(); j=0; qlen=0
      while [ "$((i + j))" -lt "${#VALID[@]}" ]; do
        r="${VALID[$((i + j))]}"; [ "$j" -gt 0 ] && [ "$((qlen + ${#r} + 6))" -gt 200 ] && break
        RR_REPO_ARGS+=(--repo "$r"); qlen=$((qlen + ${#r} + 6)); j=$((j + 1))
      done
      if chunk=$(gh_json "review-request search" search prs --review-requested=@me --state=open --limit 100 "${RR_REPO_ARGS[@]}" --json repository,number,title,updatedAt); then
        printf '%s\n' "$chunk" >> "$PAGES" 2>/dev/null || INCOMPLETE=1
        [ "$(printf '%s' "$chunk" | jq 'length' 2>/dev/null)" = 100 ] && note "incomplete: 100 or more open review requests in one group of repos; window kept"
      else INCOMPLETE=1; fi
      i=$((i + j))
    done
    RR=$(jq -sc 'add // []' "$PAGES" 2>/dev/null) || { RR='[]'; INCOMPLETE=1; note "incomplete: review-request search unreadable; window kept"; }
    flush_notes; PRELUDE="$lines"
    for repo in "${REPOS[@]}"; do
      case "$repo" in */*) ;; *) INCOMPLETE=1; NEED=$((NEED + 1)); say "! github $repo: not of the form org/repo, not checked; window kept"; continue ;; esac
      lines=""
      RR_ROWS=$(printf '%s' "$RR" | jq -r --arg r "$repo" '.[] | select(((.repository.nameWithOwner // "") | tostring | ascii_downcase) == ($r | ascii_downcase)) | [(.number // ""), ((.title // "") | tostring | .[0:80])] | @tsv' 2>/dev/null) || { RR_ROWS=""; note "incomplete: review requests for $repo unreadable; window kept"; }
      while IFS=$'\t' read -r rnum rtitle; do
        [ -n "$rnum" ] || continue
        lines="${lines}  RR #${rnum} ${rtitle}  (review requested from you)"$'\n'; NEED=$((NEED + 1))
      done <<<"$RR_ROWS"
      # PRs by most recent update, inside the window. The list API names the AUTHOR, not who
      # caused the update, so a PR you authored is left out (you follow it anyway; what others
      # do on it shows up below as reviews and comments) and the line says "author", not "by".
      # Every helper's status reaches the main shell: a failure is incomplete even if its note
      # could not be written (the notes file is diagnostics, not the record of the failure).
      prs=$(gh_pages "PR list $repo" "repos/$repo/pulls?state=all&sort=updated&direction=desc" 20 updated_at) || INCOMPLETE=1
      PR_ROWS=$(printf '%s' "$prs" | rows "PR list $repo" '.[] | select(inwin("updated_at") and human) | [(.number // ""), ((.title // "") | tostring | gsub("[\\r\\n\\t]+"; " ") | .[0:80]), (.updated_at // ""), login, (.state // ""), (if .draft then "1" else "" end)] | @tsv') || { PR_ROWS=""; INCOMPLETE=1; }
      while IFS=$'\t' read -r num title upd user state draft; do
        [ -n "$num" ] || continue
        [ "$user" = "$ME" ] || { lines="${lines}$(mark "$user")PR #${num} ${state}${draft:+ draft} (author ${user}) updated $(hm "$upd"): ${title}"$'\n'; NEED=$((NEED + 1)); }
      done <<<"$PR_ROWS"
      # Reviews submitted inside the window, looked for on every PR updated SINCE the window
      # start with no upper bound (a PR touched again after the cutoff would otherwise hide a
      # review inside the window for good); the window applies to the review's own stamp. One
      # call per PR, at most 30 PRs; the rest are LISTED as unchecked (an action line, not an
      # incomplete tick: a busy window would otherwise never advance).
      k=0; UNCHECKED=""
      CAND=$(printf '%s' "$prs" | rows "PR list $repo" '.[] | select((.updated_at // "") > $s) | (.number // empty)') || { CAND=""; INCOMPLETE=1; }
      for num in $CAND; do
        k=$((k + 1))
        if [ "$k" -gt 30 ]; then UNCHECKED="${UNCHECKED} #${num}"; continue; fi
        rv=$(gh_json "reviews of #$num" api "repos/$repo/pulls/$num/reviews?per_page=100") || { INCOMPLETE=1; continue; }
        [ "$(printf '%s' "$rv" | jq 'length' 2>/dev/null)" = 100 ] && note "incomplete: #$num has 100 or more reviews; window kept"
        RV_ROWS=$(printf '%s' "$rv" | rows "reviews of #$num" '.[] | select(inwin("submitted_at") and login != $me and human) | [login, ((.state // "") | tostring | ascii_downcase), (.submitted_at // ""), ((.body // "") | tostring | gsub("[\\r\\n\\t]+"; " ") | .[0:100])] | @tsv') || { RV_ROWS=""; INCOMPLETE=1; }
        while IFS=$'\t' read -r ruser rstate rat rbody; do
          [ -n "$ruser" ] || continue
          lines="${lines}$(mark "$ruser")review #${num} ${rstate} by ${ruser} $(hm "$rat"): ${rbody}"$'\n'; NEED=$((NEED + 1))
        done <<<"$RV_ROWS"
      done
      UNCHECKED_LINE=""; [ -n "$UNCHECKED" ] && { UNCHECKED_LINE="  reviews not checked on $((k - 30)) more updated PRs:${UNCHECKED} (30 per tick; check them by hand: gh pr view N --repo $repo --comments)"$'\n'; NEED=$((NEED + 1)); }
      # Issue and review comments. `since` is on updated_at (an edited old comment comes back and
      # is dropped by created_at here, on purpose: an edit is not new activity).
      for kind in issues pulls; do
        cm=$(gh_pages "$kind comments $repo" "repos/$repo/$kind/comments?since=$SINCE_ISO&sort=created&direction=asc" 20) || INCOMPLETE=1
        CM_ROWS=$(printf '%s' "$cm" | rows "$kind comments $repo" '.[] | select(inwin("created_at") and login != $me and human) | [login, (.created_at // ""), (.html_url // ""), ((.body // "") | tostring | gsub("[\\r\\n\\t]+"; " ") | .[0:160])] | @tsv') || { CM_ROWS=""; INCOMPLETE=1; }
        while IFS=$'\t' read -r cuser cat curl cbody; do
          [ -n "$cuser" ] || continue
          lines="${lines}$(mark "$cuser")comment by ${cuser} $(hm "$cat") ${curl}: ${cbody}"$'\n'; NEED=$((NEED + 1))
        done <<<"$CM_ROWS"
      done
      # Bounded output: the model reads this; past 60 lines a repo gets a count, and the full
      # report is written to NAME.report at the end (if that write fails, the window is kept).
      # The incomplete notes are added after the cut, so they are never the lines dropped.
      full_lines="$lines"
      ln=$(printf '%s' "$lines" | grep -c '' 2>/dev/null); ln=${ln:-0}
      [ "$ln" -gt 60 ] && { lines="$(printf '%s' "$lines" | head -60)"$'\n'"  ... and $((ln - 60)) more lines in this repo: see $REPORT_FILE"$'\n'; CUT=1; }
      lines="${lines}${UNCHECKED_LINE}"; full_lines="${full_lines}${UNCHECKED_LINE}"   # an action line, never cut
      flush_notes
      [ "$full_lines" != "$lines" ] && full_lines="${full_lines}$(printf '%s' "$lines" | grep '^  incomplete:')"$'\n'
      lines="${PRELUDE}${lines}"; full_lines="${PRELUDE}${full_lines}"; PRELUDE=""
      if [ -n "$lines" ]; then say "github $repo:"; OUT="${OUT}${lines}"; FULL="${FULL}${full_lines}"; else say "github $repo: nothing new"; fi
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
    q=$(jq -n --arg s "$SINCE_ISO" --arg n "$NOW_ISO" '{query: "{ viewer { id name } comments(first: 100, orderBy: createdAt, filter: {createdAt: {gt: \"\($s)\", lte: \"\($n)\"}}) { nodes { createdAt url user { id name } issue { identifier } body } } }"}')
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
      # Your own comments are left out by the viewer's ID (a display name can be shared).
      LN_ROWS=$(printf '%s' "$resp" | jq -r '(.data.viewer.id // "") as $meid | .data.comments.nodes[] | select($meid == "" or (.user.id // "") != $meid) | [(.createdAt // ""), ((.user.name // "?") | tostring | gsub("[\\r\\n\\t]+"; " ")), ((.issue.identifier // "?") | tostring), ((.url // "") | tostring), ((.body // "") | tostring | gsub("[\\r\\n\\t]+"; " ") | .[0:160])] | @tsv' 2>/dev/null) || { LN_ROWS=""; INCOMPLETE=1; note "incomplete: Linear answer unreadable; window kept"; }
      [ "$(printf '%s' "$resp" | jq '.data.comments.nodes | length' 2>/dev/null)" = 100 ] && note "incomplete: 100 or more comments in the window; window kept"
      while IFS=$'\t' read -r lat lname lid lurl lbody; do
        [ -n "$lat" ] || continue
        m="  "; case "$LP" in *" $lname "*) m="! " ;; esac
        lines="${lines}${m}${lid} by ${lname} $(hm "$lat") ${lurl}: ${lbody}"$'\n'; NEED=$((NEED + 1))
      done <<<"$LN_ROWS"
      flush_notes
      if [ -n "$lines" ]; then say "linear:"; OUT="${OUT}${lines}"; FULL="${FULL}${lines}"; else say "linear: nothing new"; fi
    fi
  fi
fi

# --- mark, then report ------------------------------------------------------
# Lines cut from the report live in NAME.report; if it cannot be written the cut items would
# be lost, so the window is kept in that case.
if [ "${CUT:-0}" = 1 ]; then
  if ! { mkdir -p "$STATE_DIR" 2>/dev/null && { [ ! -e "$REPORT_FILE" ] || [ -f "$REPORT_FILE" ]; } && printf '%s' "$FULL" > "$REPORT_FILE" 2>/dev/null; }; then
    if [ "$MARK" = 1 ]; then INCOMPLETE=1; NEED=$((NEED + 1)); STATE_LINES="${STATE_LINES}! state: cannot write $REPORT_FILE for the lines cut above; window kept"$'\n'
    else STATE_LINES="${STATE_LINES}  state: cannot write $REPORT_FILE; the cut lines are in this dry run only"$'\n'; fi
  fi
fi
# A complete tick moves NAME.last to now and clears NAME.pending, in that order: the pending
# start is removed only once the new mark is safely in place. A mark that cannot be written is
# reported, counted, and leaves the window as it was (the next tick repeats it: duplicates,
# never a gap). An incomplete tick leaves the pending start written before polling.
if [ "$MARK" = 1 ] && [ "$INCOMPLETE" = 0 ]; then
  if mkdir -p "$STATE_DIR" 2>/dev/null && { [ ! -e "$LAST_FILE" ] || [ -f "$LAST_FILE" ]; } \
     && printf '%s\n' "$NOW" > "$LAST_FILE.$$" 2>/dev/null && mv -f "$LAST_FILE.$$" "$LAST_FILE" 2>/dev/null; then
    rm -f "$PENDING_FILE" 2>/dev/null || STATE_LINES="${STATE_LINES}  state: $PENDING_FILE could not be removed; the next tick starts from it (duplicates, no gap)"$'\n'
  else
    rm -f "$LAST_FILE.$$" 2>/dev/null; INCOMPLETE=1; NEED=$((NEED + 1)); STATE_LINES="${STATE_LINES}! state: cannot write the window mark $LAST_FILE; the next tick repeats this window"$'\n'
  fi
fi
[ "$INCOMPLETE" = 1 ] && [ "$NEED" -eq 0 ] && NEED=1   # an incomplete tick is never "quiet"
if [ "$NEED" -gt 0 ]; then head="tick $NAME: NEEDS ACTION ($NEED)"; else head="tick $NAME: quiet"; fi
[ "$INCOMPLETE" = 1 ] && head="$head, INCOMPLETE"
printf '%s | window %s..%s\n' "$head" "$SINCE_ISO" "$NOW_ISO"
printf '%s%s' "$STATE_LINES" "$OUT"
exit 0
