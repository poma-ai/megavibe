#!/bin/bash
# Only submit /exit after preparing a scoped restart, with positive idle evidence.
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
# Called before preparation and again immediately before input. Preparation can
# take time; a session that became busy in between must be left alone.
check_idle() {
  # Re-read identity/status immediately before acting, including pid-start check.
  if [ -z "$reason" ]; then
    fresh=$(bash "$BASE/sessions.sh" --json | jq -c --argjson p "$pid" --arg sid "$sid" '.[] | select(.pid == $p and .id == $sid)')
    if [ -z "$fresh" ] || [ "$(printf '%s' "$fresh" | jq -r '.processVerified')" != true ]; then
      reason='live process identity cannot be established'
    elif [ "$(printf '%s' "$fresh" | jq -r '.state')" != idle ]; then
      reason='busy (or idle status unknown)'
    fi
  fi
  if [ -z "$reason" ]; then
    # Explicit recorded socket: tmux environment/default server is not evidence.
    info=$(tmux -S "$socket" display-message -p -t "$pane" '#{pane_id} #{pane_pid} #{pane_in_mode} #{pane_dead} #{cursor_y}' 2>/dev/null) || info=''
    read -r actual root in_mode dead cursor <<< "$info"
    if [ "${actual:-}" != "$pane" ] || [ "${in_mode:-}" != 0 ] || [ "${dead:-}" != 0 ] || ! [[ "${cursor:-}" =~ ^[0-9]+$ ]]; then
      reason='pane cannot be matched or is in copy mode'
    else
      # Verify both ancestry and terminal foreground ownership. Any failed ps
      # query, wrapper/pane reuse, shell prompt or foreground tool means skip.
      p=$pid; matched=0; wrapper_matched=0
      wrapper=$(printf '%s' "$fresh" | jq -r '.launch.wrapperPid')
      for ((n=0; n<64; n++)); do
        [ "$p" != "$wrapper" ] || wrapper_matched=1
        [ "$p" != "$root" ] || { matched=1; break; }
        [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] || break
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') || break
      done
      groups=$(ps -o pgid=,tpgid= -p "$pid" 2>/dev/null) || groups=''
      read -r pg fg <<< "$groups"
      # An empty input editor only. A prompt with a draft must not be submitted.
      screen=$(tmux -S "$socket" capture-pane -p -t "$pane" -S "$cursor" -E "$cursor" 2>/dev/null) || screen=''
      if [ "$matched" != 1 ] || [ "$wrapper_matched" != 1 ]; then reason='pane cannot be matched to session'
      elif ! [[ "${pg:-}" =~ ^[0-9]+$ ]] || [ "$pg" != "${fg:-}" ] || [ "$pg" -le 1 ]; then reason='foreground process group is not the session own group'
      elif ! printf '%s\n' "$screen" | grep -Eq '^[[:space:]]*❯[[:space:]]*$'; then reason='idle prompt cannot be established'
      fi
    fi
  fi
  return 0
}
restarted=0; skipped=0
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
  [ -n "$reason" ] || check_idle
  if [ -z "$reason" ] && [ "$dry" = 0 ]; then
    cwd=$(printf '%s' "$fresh" | jq -r '.cwd')
    wrapper=$(printf '%s' "$fresh" | jq -r '.launch.wrapperPid')
    if ! [[ "$wrapper" =~ ^[0-9]+$ ]]; then
      reason='launcher identity unavailable'
    else
      marker="$MEGAVIBE_HOME/.restart-session.$wrapper"
      if ! (cd "$cwd" && TMUX="$socket,0,0" MEGAVIBE_RESTART_MARKER="$marker" bash "$BASE/restart.sh" request "$sid" "$pid" >/dev/null); then
        reason='could not write handover and restart marker'
      else
        check_idle
        if [ -z "$reason" ]; then
          if ! tmux -S "$socket" send-keys -t "$pane" -l '/exit' 2>/dev/null ||
             ! tmux -S "$socket" send-keys -t "$pane" Enter 2>/dev/null; then
            reason='could not submit restart command'
          fi
        fi
        [ -z "$reason" ] || rm -f "$marker"
      fi
    fi
  fi
  if [ -n "$reason" ]; then
    printf '%s (pid %s): skipped: %s\n' "$label" "$pid" "$reason"
    skipped=$((skipped + 1))
  else
    if [ "$dry" = 1 ]; then action='would restart'; else action='restarted (request sent)'; fi
    printf '%s (pid %s): %s\n' "$label" "$pid" "$action"
    restarted=$((restarted + 1))
  fi
done < <(printf '%s' "$rows" | jq -c --arg self "$self" '[.[] | select(.by == "megavibe")] | sort_by(.id == $self, .started) | .[]')
if [ "$dry" = 1 ]; then action='would restart'; else action='restarted'; fi
printf '%s %s, %s skipped\n' "$restarted" "$action" "$skipped"
