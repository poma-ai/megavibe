#!/bin/bash

# Megavibe statusline — shows model + context usage percentage
# Installed to ~/.claude/statusline.sh by setup.sh
# Input: JSON on stdin from Claude Code (model, context_window, etc.)

INPUT=$(cat)

MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "?"')
PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

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
  # if you don't know the daemon exists or that it can die. revive-watcher.sh
  # heals this on the next tool call, so a brief flicker at startup is normal;
  # a persistent warning means autosave is genuinely down.
  if [ -n "$SID" ] \
     && [ "${MEGAVIBE_WATCHER:-1}" != "0" ] \
     && command -v tmux >/dev/null 2>&1 \
     && [ -x "$HOME/.megavibe/scripts/context-watcher.py" ] \
     && ! tmux has-session -t "mvw-${SID}" 2>/dev/null; then
    WARN=' \033[0;31m⚠ autosave off\033[0m'
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
