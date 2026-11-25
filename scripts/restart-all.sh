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
command -v tmux >/dev/null 2>&1 || { echo 'megavibe restart-all: tmux is unavailable.' >&2; exit 1; }
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
  if [ "$others" = 1 ] && [ "$sid" = "$self" ]; then
    reason='caller excluded (--others)'
  elif ! [[ "$sid" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
    reason='invalid session id'
  elif [ "$(printf '%s' "$row" | jq -r '.launch.restartProtocol // 0')" != 1 ]; then
    reason='launcher predates scoped restart; restart it manually once'
  else
    pane=$(printf '%s' "$row" | jq -r '.launch.pane // ""')
    socket=$(printf '%s' "$row" | jq -r '.launch.socket // ""')
    if [ -z "$pane" ] || [ -z "$socket" ]; then reason='not in tmux'; fi
  fi
  # tmux cannot compare the editor and submit input atomically. Even an armed
  # marker cannot exclude a later user draft or a multiline editor. Fail closed.
  [ -n "$reason" ] || reason='automatic pane input unavailable; run /megavibe-restart in this session, then type /exit'
  printf '%s (pid %s): skipped: %s\n' "$label" "$pid" "$reason"
  skipped=$((skipped + 1))
done < <(printf '%s' "$rows" | jq -c --arg self "$self" '[.[] | select(.by == "megavibe")] | sort_by(.id == $self, .started) | .[]')
if [ "$dry" = 1 ]; then action='would restart'; else action='restarted'; fi
printf '%s %s, %s skipped\n' 0 "$action" "$skipped"
