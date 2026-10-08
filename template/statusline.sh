#!/bin/bash

# Megavibe statusline — shows model + context usage percentage
# Installed to ~/.claude/statusline.sh by setup.sh
# Input: JSON on stdin from Claude Code (model, context_window, etc.)

INPUT=$(cat)

MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "?"')
PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

# Subscription usage history for scripts/usage-route.sh. rate_limits.{five_hour,
# seven_day}.{used_percentage,resets_at} is account-wide, present only for
# subscribers and only after the first API response. One row per change or per
# five minutes, a plain O_APPEND write (a row is far below PIPE_BUF). Every step
# is allowed to fail: the statusline must never block on this.
RL_OUT=$(echo "$INPUT" | jq -r --argjson t "$(date +%s)" --arg sid "$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | cut -c1-12)" '
  select(.rate_limits != null)
  | {t:$t, sid:$sid,
     fh:{p:.rate_limits.five_hour.used_percentage, r:.rate_limits.five_hour.resets_at},
     sd:{p:.rate_limits.seven_day.used_percentage, r:.rate_limits.seven_day.resets_at}} as $r
  | ([$r.fh.p, $r.sd.p] | @csv), ($r | tojson)' 2>/dev/null) || RL_OUT=""
if [ -n "$RL_OUT" ]; then
  RL_KEY=${RL_OUT%%$'\n'*}; RL_ROW=${RL_OUT#*$'\n'}
  RL_DIR="${MEGAVIBE_HOME:-$HOME/.megavibe}/usage"; RL_LAST="$RL_DIR/.claude-last"
  RL_NOW=$(date +%s); RL_PREV=$(cat "$RL_LAST" 2>/dev/null || true)
  RL_PTS=${RL_PREV#* }
  case "$RL_PTS" in ''|*[!0-9]*) RL_PTS=0 ;; esac   # a damaged cache must not reach the arithmetic
  case "$RL_NOW" in ''|*[!0-9]*) RL_NOW=0 ;; esac
  if [ "${RL_PREV%% *}" != "$RL_KEY" ] || [ "$((RL_NOW - RL_PTS))" -ge 300 ]; then
    mkdir -p "$RL_DIR" 2>/dev/null \
      && printf '%s\n' "$RL_ROW" >> "$RL_DIR/claude.jsonl" 2>/dev/null \
      && printf '%s %s\n' "$RL_KEY" "$RL_NOW" > "$RL_LAST.$$" 2>/dev/null \
      && mv -f "$RL_LAST.$$" "$RL_LAST" 2>/dev/null || true
  fi
fi

# Cache the real context_window_size for PostToolUse hooks (which can't see
# this stdin). One write per change; reused by log-tool-event.sh tier math.
WARN=""
if [ -d ".agent" ]; then
  SID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | cut -c1-12)
  CTX_SIZE=$(echo "$INPUT" | jq -r '.context_window.context_window_size // 0' 2>/dev/null)
  if [ -n "$SID" ] && [ "${CTX_SIZE:-0}" -gt 0 ] 2>/dev/null; then
    CTX_FILE=".agent/LOGS/.ctx-size.${SID}"
    if [ ! -f "$CTX_FILE" ] || [ "$(cat "$CTX_FILE" 2>/dev/null)" != "$CTX_SIZE" ]; then
      mkdir -p .agent/LOGS 2>/dev/null
      echo "$CTX_SIZE" > "$CTX_FILE" 2>/dev/null
    fi
  fi

  # Autosave health: the context-watcher daemon keeps .agent/ fresh between
  # turns. If it SHOULD be running (not opted out, prereqs present) but its
  # tmux session is gone, say so in plain language — a bare % tells you nothing
  # if you don't know the daemon exists or that it can die.
  #
  # Startup grace: the watcher is spawned at SessionStart but often loses a
  # transcript race; revive-watcher.sh heals it on the FIRST tool call. So a
  # fresh session shows the daemon down until then. Don't cry wolf during that
  # window — record first-seen time per session and only warn once the session
  # is old enough (45s) that the watcher genuinely should be up. A persistent
  # warning past that means autosave is really down.
  if [ -n "$SID" ] \
     && [ "${MEGAVIBE_WATCHER:-1}" != "0" ] \
     && command -v tmux >/dev/null 2>&1 \
     && [ -x "$HOME/.megavibe/scripts/context-watcher.py" ] \
     && ! tmux has-session -t "mvw-${SID}" 2>/dev/null; then
    SEEN_FILE=".agent/LOGS/.statusline-seen.${SID}"
    NOW=$(date +%s 2>/dev/null || echo 0)
    FIRST="$NOW"
    if [ -f "$SEEN_FILE" ]; then
      FIRST=$(cat "$SEEN_FILE" 2>/dev/null || echo "$NOW")
    else
      mkdir -p .agent/LOGS 2>/dev/null
      echo "$NOW" > "$SEEN_FILE" 2>/dev/null
    fi
    if [ "$((NOW - FIRST))" -ge 45 ] 2>/dev/null; then
      WARN=' \033[0;31m⚠ autosave off\033[0m'
    fi
  fi
fi

BAR_WIDTH=10
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))

BAR=""
[ "$FILLED" -gt 0 ] && BAR=$(printf "%${FILLED}s" | tr ' ' '▓')
[ "$EMPTY" -gt 0 ] && BAR="${BAR}$(printf "%${EMPTY}s" | tr ' ' '░')"

# Color the percentage: green < 60, yellow 60-80, red > 80
if [ "$PCT" -gt 80 ]; then
  COLOR='\033[0;31m'
elif [ "$PCT" -gt 60 ]; then
  COLOR='\033[0;33m'
else
  COLOR='\033[0;32m'
fi
RESET='\033[0m'

echo -e "${MODEL} ${BAR} ${COLOR}${PCT}%${RESET}${WARN}"
