#!/bin/bash

# Megavibe statusline — shows model + context usage percentage
# Installed to ~/.claude/statusline.sh by setup.sh
# Input: JSON on stdin from Claude Code (model, context_window, etc.)

INPUT=$(cat)

MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "?"')
PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

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

echo -e "${MODEL} ${BAR} ${COLOR}${PCT}%${RESET}"
