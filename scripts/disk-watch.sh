#!/bin/bash
# Megavibe — free-disk-space watch. One cheap `df`, no network, writes nothing.
#
#   disk-watch.sh check         silent when space is fine; when LOW or CRITICAL, one
#                               status line plus the biggest places to look
#   disk-watch.sh watch [secs]  loop for Monitor (default 60 s, minimum 30): prints only
#                               when free space moves by STEP GB or the level changes
#   disk-watch.sh top           the biggest places to look, sizes only
#
# Env: MEGAVIBE_DISK_WARN_GB (15), MEGAVIBE_DISK_CRIT_GB (8), MEGAVIBE_DISK_STEP_GB (1),
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
WARN=$(_int "${MEGAVIBE_DISK_WARN_GB:-}" 15); [ "$WARN" -ge 1 ] || WARN=15
CRIT=$(_int "${MEGAVIBE_DISK_CRIT_GB:-}" 8);  [ "$CRIT" -le "$WARN" ] || CRIT=$WARN
STEP=$(_int "${MEGAVIBE_DISK_STEP_GB:-}" 1);  [ "$STEP" -ge 1 ] || STEP=1
P="${MEGAVIBE_DISK_PATH:-$HOME}"
KB_PER_GB=1048576
TAB=$(printf '\t')

# Run a command for at most N seconds where perl or timeout exists (a stalled mount must
# not hang a session start); unbounded otherwise.
bounded() {
  local n=$1; shift
  if command -v perl &>/dev/null; then perl -e 'alarm shift; exec @ARGV' "$n" "$@"
  elif command -v timeout &>/dev/null; then timeout "$n" "$@"
  else "$@"; fi
}

# df -Pk row: "<fs, may contain spaces> <total> <used> <avail> <N%> <mount, may contain spaces>".
# Anchor on the N% field rather than counting columns from the left.
df_row() { bounded 3 df -Pk "$P" 2>/dev/null | awk 'NR==2 { for (i = NF; i >= 3; i--) if ($i ~ /^[0-9]+%$/) { cap = i; break }
  if (cap && $(cap-1) ~ /^[0-9]+$/) { m = ""; for (j = cap + 1; j <= NF; j++) m = m (j > cap + 1 ? " " : "") $j; print $(cap-1) "\t" m } }'; }
gb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }
level() { # kb [previous level]: leave a worse level only once clear of its threshold by STEP
  local kb=$1 prev=${2:-} warn=$((WARN * KB_PER_GB)) crit=$((CRIT * KB_PER_GB)) step=$((STEP * KB_PER_GB))
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
  for c in "$HOME/.Trash" "$HOME/.local/share/Trash" /private/tmp/claude-* $tmpglob \
           "$PWD/.agent/ASSETS" "$PWD/.agent/LOGS" "$PWD/.worktrees" "$PWD/.venv" "$PWD/node_modules" \
           "$HOME/.megavibe/logs" "$HOME/.cache"; do
    [ -d "$c" ] || continue
    if [ "$SECONDS" -ge 5 ]; then skipped=$((skipped + 1)); continue; fi
    sz=$(bounded 3 du -sk "$c" 2>/dev/null | awk 'NR==1 && $1 ~ /^[0-9]+$/ { print $1 }')
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

status_line() { # kb mount level
  printf 'disk: %s GB free on %s — %s (warn < %s GB, critical < %s GB)\n' "$(gb "$1")" "$2" "$3" "$WARN" "$CRIT"
}

case "${1:-check}" in
  check)
    row=$(df_row); [ -n "$row" ] || exit 0
    kb=${row%%"$TAB"*}; mnt=${row#*"$TAB"}
    lvl=$(level "$kb"); [ "$lvl" = OK ] && exit 0
    status_line "$kb" "$mnt" "$lvl"; top
    ;;
  top) top ;;
  watch)
    iv=$(_int "${2:-}" 60); [ "$iv" -ge 30 ] || iv=30
    last_kb=""; last_lvl=""; fails=0
    while :; do
      row=$(df_row)
      if [ -z "$row" ]; then
        fails=$((fails + 1))
        [ "$fails" -ge 3 ] && { echo "disk: cannot read free space on $P, watch stopped"; exit 1; }
      else
        fails=0; kb=${row%%"$TAB"*}; lvl=$(level "$kb" "$last_lvl")
        if [ -z "$last_kb" ]; then delta=""
        else delta=$(awk -v a="$kb" -v b="$last_kb" 'BEGIN { printf " (%+.1f GB)", (a - b) / 1048576 }'); fi
        moved=0
        if [ -z "$last_kb" ] || [ "$lvl" != "$last_lvl" ]; then moved=1
        else
          d=$((kb - last_kb)); [ "$d" -lt 0 ] && d=$((-d))
          [ "$d" -ge $((STEP * KB_PER_GB)) ] && moved=1
        fi
        if [ "$moved" = 1 ]; then
          printf 'disk: %s GB free%s — %s\n' "$(gb "$kb")" "$delta" "$lvl"
          [ "$lvl" != OK ] && [ "$lvl" != "$last_lvl" ] && top
          last_kb=$kb; last_lvl=$lvl
        fi
      fi
      sleep "$iv"
    done
    ;;
  *) echo "usage: disk-watch.sh check | top | watch [secs]" >&2; exit 2 ;;
esac
