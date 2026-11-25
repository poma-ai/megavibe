#!/bin/bash
# Report sessions requiring a manual restart; never inject pane input.
set -euo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
MEGAVIBE_HOME="${MEGAVIBE_HOME:-$HOME/.megavibe}"
dry=0; others=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    --others) others=1 ;;
    *) echo 'usage: megavibe restart-all [--dry-run] [--others]' >&2; exit 2 ;;
  esac
done
rows=$(bash "$BASE/sessions.sh" --json)
# Find the actual caller by ancestry; never trust a tmux server's inherited SID.
p=$PPID; self=''
for ((n=0; n<32; n++)); do
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] || break
  self=$(printf '%s' "$rows" | jq -r --argjson p "$p" '.[] | select(.pid == $p) | .id')
  [ -z "$self" ] || break
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') || break
done
skipped=0
# Keep raw paths inside JSON, never split them on whitespace or evaluate them.
while IFS= read -r row; do
  pid=$(printf '%s' "$row" | jq -r '.pid')
  sid=$(printf '%s' "$row" | jq -r '.id')
  label=$(printf '%s' "$row" | jq -r '.id | gsub("[^A-Za-z0-9-]"; "?")')
  reason=''; pane=''; socket=''
  name=$(printf '%s' "$row" | jq -r '.name')
  cwd=$(printf '%s' "$row" | jq -r '.cwd')
  pane=$(printf '%s' "$row" | jq -r '.launch.pane // ""')
  socket=$(printf '%s' "$row" | jq -r '.launch.socket // ""')
  location=unknown
  if [ -n "$pane" ] && [ -n "$socket" ] && command -v tmux >/dev/null 2>&1; then
    # -N never starts a server; display-message is a read-only format query.
    location=$(tmux -N -S "$socket" display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index} (#{pane_id})' 2>/dev/null) || location=unknown
  elif [ -n "$pane" ]; then
    location="$pane (recorded; location unavailable)"
  fi
  if [ "$others" = 1 ] && [ "$sid" = "$self" ]; then
    reason='caller excluded (--others)'
  elif ! [[ "$sid" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
    reason='invalid session id'
  elif [ "$(printf '%s' "$row" | jq -r '.launch.restartProtocol // 0')" != 2 ]; then
    reason='launcher predates scoped restart; restart it manually once'
  elif [ -z "$pane" ] || [ -z "$socket" ]; then
    reason='not in tmux'
  fi
  # tmux cannot compare the editor and submit input atomically. Even an armed
  # marker cannot exclude a later user draft or a multiline editor. Fail closed.
  [ -n "$reason" ] || reason='automatic pane input unavailable; run /megavibe-restart in this session, then type /exit'
  printf '%s (pid %s): skipped: %s; name=%q; project=%q; pane=%q; ' "$label" "$pid" "$reason" "$name" "$cwd" "$location"
  if [[ "$sid" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
    printf 'in session: /megavibe-restart then /exit; by hand after exit: cd -- %q && megavibe --resume %q\n' "$cwd" "$sid"
  else
    printf 'by hand after exit: cd -- %q && megavibe --resume\n' "$cwd"
  fi
  skipped=$((skipped + 1))
done < <(printf '%s' "$rows" | jq -c --arg self "$self" '. | sort_by(.id == $self, .started) | .[]')
if [ "$dry" = 1 ]; then action='would restart'; else action='restarted'; fi
printf '%s %s, %s skipped\n' 0 "$action" "$skipped"
