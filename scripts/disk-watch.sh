#!/bin/bash
# Megavibe — free-disk-space watch. One cheap `df`, no network, writes nothing.
#
#   disk-watch.sh check         silent when space is fine; when LOW or CRITICAL, one
#                               status line plus the biggest places to look
#   disk-watch.sh watch [secs]  loop for Monitor (default 60 s, minimum 30): prints only
#                               when free space moves by STEP GB or the level changes
#   disk-watch.sh top           the biggest places to look, sizes only
#   disk-watch.sh level         one word for a caller that keeps its own state: OK, LOW,
#                               CRITICAL, or UNKNOWN when df could not answer (one bounded df,
#                               no directory scan)
#
# Env: MEGAVIBE_SCRATCH_BUDGET_GB (2; the session's own scratch, 0 = off),
#      MEGAVIBE_DISK_WARN_GB (unset: the larger of 40 GB and 15 percent of the volume), MEGAVIBE_DISK_CRIT_GB (8), MEGAVIBE_DISK_STEP_GB (1),
#      MEGAVIBE_DISK_PATH (default $HOME — the volume whose free space is measured).
#      GB here is 1024^3 bytes, as `df -h` counts it.
#
# It only reports. Nothing here deletes, and `top` lists sizes for the user to decide on.
set -u

# Whole numbers only, no leading zeros (bash reads 08 as bad octal), capped so the
# arithmetic below cannot overflow. Anything else falls back to the default.
_int() {
  case "${1:-}" in ''|*[!0-9]*) echo "$2"; return ;; esac
  local v="${1#"${1%%[!0]*}"}"; v="${v:-0}"
  [ "${#v}" -gt 6 ] && { echo "$2"; return; }
  echo "$v"
}
# Warn line: MEGAVIBE_DISK_WARN_GB when set (a fixed number of GB); otherwise the larger of 40 GB
# and 15 percent of the volume, so a big disk is warned early too (a 460 GB disk at 69 GB).
WARN_FIXED=$(_int "${MEGAVIBE_DISK_WARN_GB:-}" 0); [ "$WARN_FIXED" -ge 1 ] || WARN_FIXED=0
WARN=$WARN_FIXED; [ "$WARN" -ge 1 ] || WARN=40
CRIT=$(_int "${MEGAVIBE_DISK_CRIT_GB:-}" 8);  [ "$WARN_FIXED" -lt 1 ] || [ "$CRIT" -le "$WARN" ] || CRIT=$WARN   # without a fixed warn line, level() clamps per volume
STEP=$(_int "${MEGAVIBE_DISK_STEP_GB:-}" 1);  [ "$STEP" -ge 1 ] || STEP=1
P="${MEGAVIBE_DISK_PATH:-$HOME}"
KB_PER_GB=1048576
TAB=$(printf '\t')

# Run a command for at most N seconds where perl or timeout exists (a stalled mount must
# not hang a session start); unbounded otherwise.
bounded() {
  local n=$1; shift
  if command -v perl &>/dev/null; then perl -MPOSIX -e '
    $seconds = shift; $pid = fork; exit 125 unless defined $pid;
    if (!$pid) { POSIX::setpgid(0, 0); exec @ARGV or exit 127 }
    POSIX::setpgid($pid, $pid);
    $SIG{ALRM} = sub { kill "KILL", -$pid; exit 124 };
    alarm $seconds; waitpid($pid, 0);
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$n" "$@"
  elif command -v timeout &>/dev/null; then timeout "$n" "$@"
  else "$@"; fi
}

# df -Pk row: "<fs, may contain spaces> <total> <used> <avail> <N%> <mount, may contain spaces>".
# Anchor on the N% field rather than counting columns from the left.
# Prints "<avail kB>\t<total kB>\t<mount>" for the path ($1, default $P).
df_row() { bounded 3 df -Pk "${1:-$P}" 2>/dev/null | awk 'NR==2 { for (i = 5; i <= NF; i++) if ($i ~ /^[0-9]+%$/ && $(i-1) ~ /^-?[0-9]+$/ && $(i-2) ~ /^[0-9]+$/ && $(i-3) ~ /^[0-9]+$/) { cap = i; break }
  if (cap) { m = ""; for (j = cap + 1; j <= NF; j++) m = m (j > cap + 1 ? " " : "") $j; print $(cap-1) "\t" $(cap-3) "\t" m } }'; }
row_avail() { printf '%s' "${1%%"$TAB"*}"; }
row_rest() { printf '%s' "${1#*"$TAB"}"; }
row_total() { local r; r=$(row_rest "$1"); printf '%s' "${r%%"$TAB"*}"; }
row_mount() { local r; r=$(row_rest "$1"); printf '%s' "${r#*"$TAB"}"; }
# The volume the session scratch lives on, when CLAUDE_CODE_TMPDIR / MEGAVIBE_DATA_DIR moved it off /tmp
# and onto a different volume than $P. Prints that df row, or nothing.
scratch_row() {
  local b r
  b=$(bounded 3 "$(dirname "$0")/scratch-root.sh" base 2>/dev/null) || return 0
  [ -n "$b" ] || return 0
  r=$(df_row "$b") || return 0; [ -n "$r" ] || return 0
  [ "$(row_mount "$r")" = "$(row_mount "$1")" ] && return 0
  printf '%s' "$r"
}
gb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }
warn_kb_for() { # total kB -> the warn line in kB for that volume (exact: no rounding to whole GB)
  if [ "$WARN_FIXED" -ge 1 ]; then echo $((WARN_FIXED * KB_PER_GB)); return; fi
  local t=${1:-0} w; case "$t" in ''|*[!0-9]*) t=0 ;; esac
  w=$((t * 15 / 100)); [ "$w" -ge $((40 * KB_PER_GB)) ] || w=$((40 * KB_PER_GB)); echo "$w"
}
warn_gb_for() { gb "$(warn_kb_for "${1:-0}")"; }
crit_kb_for() { # total kB -> the critical line in kB for that volume (never above its warn line)
  local c=$((CRIT * KB_PER_GB)) w; w=$(warn_kb_for "${1:-0}"); [ "$c" -le "$w" ] || c=$w; echo "$c"
}
level() { # kb [previous level] [total kB]: leave a worse level only once clear of its threshold by STEP
  local kb=$1 prev=${2:-} warn crit step=$((STEP * KB_PER_GB))
  warn=$(warn_kb_for "${3:-0}"); crit=$(crit_kb_for "${3:-0}")
  if [ "$kb" -lt "$crit" ]; then echo CRITICAL
  elif [ "$prev" = CRITICAL ] && [ "$kb" -lt $((crit + step)) ]; then echo CRITICAL
  elif [ "$kb" -lt "$warn" ]; then echo LOW
  elif [ "$prev" = LOW ] && [ "$kb" -lt $((warn + step)) ]; then echo LOW
  else echo OK; fi
}

top() {
  local c out="" skipped=0 sz
  SECONDS=0   # total budget for the scan: a session start must not wait on a slow disk
  local tmpglob="/tmp/claude-*"; [ -L /tmp ] && tmpglob=""   # /tmp is a symlink to /private/tmp on macOS: count it once
  # A session temp root moved by CLAUDE_CODE_TMPDIR / MEGAVIBE_DATA_DIR is listed too.
  local movedbase=""; movedbase=$(bounded 3 "$(dirname "$0")/scratch-root.sh" base 2>/dev/null) || movedbase=""
  case "$movedbase" in /tmp|/private/tmp) movedbase="" ;; esac
  local -a moved=(); [ -n "$movedbase" ] && moved=("$movedbase"/claude-*)
  for c in "$HOME/.Trash" "$HOME/.local/share/Trash" /private/tmp/claude-* $tmpglob ${moved[@]+"${moved[@]}"} \
           "$PWD/.agent/ASSETS" "$PWD/.agent/LOGS" "$PWD/.worktrees" "$PWD/.venv" "$PWD/node_modules" \
           "$HOME/.megavibe/logs" "$HOME/.cache"; do
    [ -d "$c" ] || continue
    # Each du gets at most the budget that is left (3 s each, 5 s in all), so the
    # whole scan ends by the budget instead of starting a full du at 4.9 s.
    left=$((5 - SECONDS)); [ "$left" -gt 3 ] && left=3
    if [ "$left" -le 0 ]; then skipped=$((skipped + 1)); continue; fi
    sz=$(bounded "$left" du -sk "$c" 2>/dev/null | awk 'NR==1 && $1 ~ /^[0-9]+$/ { print $1 }')
    if [ -z "$sz" ]; then skipped=$((skipped + 1)); continue; fi
    out="$out$sz$TAB$c
"
  done
  printf '%s' "$out" | awk -F'\t' -v h="$HOME" 'NF == 2 && $1 >= 102400 {
      p = $2; if (h != "" && index(p, h) == 1) p = "~" substr(p, length(h) + 1)
      printf "%d\t%s\n", $1, p }' | sort -rn | head -6 | awk -F'\t' -v sk="$skipped" '
    BEGIN { print "Biggest places to look (sizes only, nothing was deleted):" }
    { printf "  %6.1f GB  %s\n", $1 / 1048576, $2 }
    END { if (NR == 0) print "  none over 100 MB in the usual places"
          if (sk > 0) printf "  (%d location(s) could not be sized in time)\n", sk }'
}

status_line() { # kb mount level [label] [total kB]
  printf '%s: %s GB free on %s — %s (warn < %s GB, critical < %s GB)\n' "${4:-disk}" "$(gb "$1")" "$2" "$3" "$(warn_gb_for "${5:-0}")" "$(gb "$(crit_kb_for "${5:-0}")")"
}
worse() { # two level words -> the worse
  local w
  for w in CRITICAL LOW OK; do
    if [ "$1" = "$w" ] || [ "$2" = "$w" ]; then echo "$w"; return; fi
  done
  echo "${1:-OK}"
}

# The session's own scratch: <session temp root>/<project slug>/<session id>/ under every root
# scratch-root.sh names (scratchpad, task output, anything the harness put there for this session).
# Budget in GB: MEGAVIBE_SCRATCH_BUDGET_GB (default 2; 0 switches the budget off).
BUDGET=$(_int "${MEGAVIBE_SCRATCH_BUDGET_GB:-}" 2)
scratch_dirs() {
  local sid=$1 roots r project d phys seen=$'\n' failed=0
  case "$sid" in ''|*[!A-Za-z0-9-]*) return 4 ;; esac
  roots=$(bounded 3 "$(dirname "$0")/scratch-root.sh" roots) || return 4
  [ -n "$roots" ] || return 4
  while IFS= read -r r; do
    [ -e "$r" ] || { [ ! -L "$r" ] || failed=4; continue; }
    [ -d "$r" ] && [ -r "$r" ] && [ -x "$r" ] || { failed=4; continue; }
    for project in "$r"/*; do
      [ -d "$project" ] || continue
      [ -x "$project" ] || { failed=4; continue; }
      d=$project/$sid
      [ -d "$d" ] && [ ! -L "$d" ] || continue
      phys=$(cd -P -- "$d" 2>/dev/null && pwd -P) || { failed=4; continue; }
      case "$phys" in *$'\n'*|*$'\t'*) failed=4; continue ;; esac
      case "$seen" in *$'\n'"$phys"$'\n'*) continue ;; esac
      seen="$seen$phys"$'\n'; printf '%s\n' "$phys"
    done
  done <<< "$roots"
  return "$failed"
}
SCR_UNKNOWN=0
scratch_kb() {
  local sid=$1 dirs own row d p total=0 k covered
  SCR_UNKNOWN=0
  case "$sid" in ''|*[!A-Za-z0-9-]*) SCR_UNKNOWN=1; echo 0; return ;; esac
  dirs=$(scratch_dirs "$sid") || SCR_UNKNOWN=1
  own=$(bounded 6 "$(dirname "$0")/scratch-own.sh" list "$sid") || SCR_UNKNOWN=1
  while IFS="$TAB" read -r k p; do
    [ -n "$k" ] || continue
    case "$k" in *[!0-9]*) SCR_UNKNOWN=1; continue ;; esac
    covered=0
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$p" in "$d"/*) covered=1 ;; esac
    done <<< "$dirs"
    [ "$covered" = 0 ] && total=$((total + k))
  done <<< "$own"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    covered=0
    while IFS="$TAB" read -r k p; do
      [ -n "$p" ] || continue
      case "$d" in "$p"|"$p"/*) covered=1 ;; esac
    done <<< "$own"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$d" in "$p"/*) covered=1 ;; esac
    done <<< "$dirs"
    [ "$covered" = 0 ] || continue
    row=$(bounded 5 du -sk "$d" 2>/dev/null) || { SCR_UNKNOWN=1; continue; }
    k=${row%%"$TAB"*}
    case "$k" in ''|*[!0-9]*) SCR_UNKNOWN=1; continue ;; esac
    [ "$row" = "$k$TAB$d" ] || { SCR_UNKNOWN=1; continue; }
    total=$((total + k))
  done <<< "$dirs"
  echo "$total"
}

scratch_other() {
  local rows dirs rc=0 kb age name
  dirs=$(scratch_dirs "$1") || rc=$?
  rows=$(CLAUDE_CODE_SESSION_ID="$1" MEGAVIBE_SCRATCH_SESSION_DIRS="$dirs" \
    bounded 5 "$(dirname "$0")/scratch-own.sh" other 3) || rc=$?
  printf 'other temp usage:'
  while IFS="$TAB" read -r kb age name; do
    [ -n "$kb" ] || continue
    printf ' %s (%s kB, %s min old);' "$name" "$kb" "$age"
  done <<< "$rows"
  if [ "$rc" != 0 ]; then printf ' measurement incomplete'
  elif [ -z "$rows" ]; then printf ' none'; fi
  printf '\n'
}

case "${1:-check}" in
  check)
    row=$(df_row); srow=$(scratch_row "$row"); slvl=OK; lvl=OK; kb=0; mnt=""
    [ -n "$row" ] || [ -n "$srow" ] || exit 0
    if [ -n "$row" ]; then kb=$(row_avail "$row"); mnt=$(row_mount "$row"); lvl=$(level "$kb" "" "$(row_total "$row")"); fi
    [ -n "$srow" ] && slvl=$(level "$(row_avail "$srow")" "" "$(row_total "$srow")")
    [ "$lvl" = OK ] && [ "$slvl" = OK ] && exit 0
    if [ "$lvl" != OK ]; then status_line "$kb" "$mnt" "$lvl" disk "$(row_total "$row")"; fi
    if [ -n "$srow" ] && [ "$slvl" != OK ]; then
      status_line "$(row_avail "$srow")" "$(row_mount "$srow")" "$slvl" "scratch disk" "$(row_total "$srow")"
    elif [ -n "$srow" ]; then
      printf 'scratch disk: %s GB free on %s (session scratch is moved here; fine)\n' "$(gb "$(row_avail "$srow")")" "$(row_mount "$srow")"
    fi
    top
    ;;
  top) top ;;
  scratch) # [--kb] [session id]: this session's own scratch size, one line (with --kb, "<kB><TAB><line>"); exit 3 when over the budget
    withkb=0; [ "${2:-}" = "--kb" ] && { withkb=1; shift; }
    sid=${2:-${CLAUDE_CODE_SESSION_ID:-}}
    unknown=0
    if [ "$BUDGET" -lt 1 ]; then kb=0; else
      out=$(scratch_kb "$sid"; echo "unknown=$SCR_UNKNOWN"); kb=$(printf '%s' "$out" | head -1); unknown=${out##*unknown=}
    fi
    line=$(printf "scratch: %s GB in this session's own folders (budget %s GB)" "$(gb "$kb")" "$BUDGET")
    [ "$unknown" = 0 ] || line="$line (measurement incomplete)"
    if [ "$withkb" = 1 ]; then printf '%s\t%s\n' "$kb" "$line"
    else printf '%s\n' "$line"; scratch_other "$sid"; fi
    [ "$unknown" = 1 ] && exit 4
    [ "$BUDGET" -ge 1 ] && [ "$kb" -gt $((BUDGET * KB_PER_GB)) ] && exit 3
    exit 0 ;;
  scratch-kb) scratch_kb "${2:-${CLAUDE_CODE_SESSION_ID:-}}"; [ "$SCR_UNKNOWN" = 0 ] || exit 4 ;;
  scratch-other) scratch_other "${2:-${CLAUDE_CODE_SESSION_ID:-}}" ;;
  level)
    row=$(df_row); srow=$(scratch_row "$row")
    [ -n "$row" ] || [ -n "$srow" ] || { echo UNKNOWN; exit 0; }
    lvl=""; [ -n "$row" ] && lvl=$(level "$(row_avail "$row")" "" "$(row_total "$row")")
    if [ -n "$srow" ]; then slvl=$(level "$(row_avail "$srow")" "" "$(row_total "$srow")"); if [ -n "$lvl" ]; then lvl=$(worse "$lvl" "$slvl"); else lvl=$slvl; fi; fi
    echo "$lvl"
    ;;
  watch)
    iv=$(_int "${2:-}" 60); [ "$iv" -ge 30 ] || iv=30
    last_kb=""; last_skb=""; last_lvl=""; last_plvl=""; last_slvl=""; fails=0
    while :; do
      row=$(df_row); srow=$(scratch_row "$row")
      if [ -z "$row" ] && [ -z "$srow" ]; then
        fails=$((fails + 1))
        [ "$fails" -ge 3 ] && { echo "disk: cannot read free space on $P, watch stopped"; exit 1; }
      else
        fails=0; lvl=""; kb=""; skb=""; delta=""; sx=""
        plvl=""; slvl=""
        if [ -n "$row" ]; then kb=$(row_avail "$row"); plvl=$(level "$kb" "$last_plvl" "$(row_total "$row")"); lvl=$plvl; fi
        if [ -n "$srow" ]; then   # the scratch volume counts too: each volume keeps its own hysteresis, the report shows the worse
          skb=$(row_avail "$srow"); slvl=$(level "$skb" "$last_slvl" "$(row_total "$srow")")
          if [ -n "$lvl" ]; then lvl=$(worse "$lvl" "$slvl"); else lvl=$slvl; fi
          sx=$(printf ', scratch disk %s GB free' "$(gb "$skb")")
        fi
        if [ -n "$kb" ] && [ -n "$last_kb" ]; then delta=$(awk -v a="$kb" -v b="$last_kb" 'BEGIN { printf " (%+.1f GB)", (a - b) / 1048576 }'); fi
        moved=0
        if { [ -z "$last_kb" ] && [ -z "$last_skb" ]; } || [ "$lvl" != "$last_lvl" ]; then moved=1
        else
          if [ -n "$kb" ] && [ -n "$last_kb" ]; then d=$((kb - last_kb)); [ "$d" -lt 0 ] && d=$((-d)); [ "$d" -ge $((STEP * KB_PER_GB)) ] && moved=1; fi
          if [ -n "$skb" ] && [ -n "$last_skb" ]; then d=$((skb - last_skb)); [ "$d" -lt 0 ] && d=$((-d)); [ "$d" -ge $((STEP * KB_PER_GB)) ] && moved=1; fi
        fi
        last_plvl=$plvl; last_slvl=$slvl   # every successful poll advances each volume's own hysteresis
        if [ "$moved" = 1 ]; then
          if [ -n "$kb" ]; then printf 'disk: %s GB free%s%s — %s\n' "$(gb "$kb")" "$delta" "$sx" "$lvl"
          else printf 'disk: primary volume unreadable%s — %s\n' "$sx" "$lvl"; fi
          [ "$lvl" != OK ] && [ "$lvl" != "$last_lvl" ] && top
          last_kb=$kb; last_skb=$skb; last_lvl=$lvl
        fi
      fi
      sleep "$iv"
    done
    ;;
  *) echo "usage: disk-watch.sh check | top | level | scratch [session id] | watch [secs]" >&2; exit 2 ;;
esac
