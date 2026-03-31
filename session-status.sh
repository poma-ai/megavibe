#!/bin/bash
set -euo pipefail

# session-status.sh — show active megavibe sessions across all registered projects
# Used by the personal assistant to answer "what sessions are running?"

MEGAVIBE_HOME="$HOME/.megavibe"
PROJECTS_FILE="$MEGAVIBE_HOME/projects.json"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
RESET='\033[0m'

# Collect all project dirs: registered projects + personal
declare -a DIRS=()
declare -a NAMES=()

# Personal assistant
if [ -d "$MEGAVIBE_HOME/personal/.agent" ]; then
  DIRS+=("$MEGAVIBE_HOME/personal")
  NAMES+=("personal")
fi

# Registered projects
if [ -f "$PROJECTS_FILE" ] && command -v jq &>/dev/null; then
  while IFS=$'\t' read -r name dir; do
    if [ -d "$dir/.agent" ]; then
      DIRS+=("$dir")
      NAMES+=("$name")
    fi
  done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$PROJECTS_FILE" 2>/dev/null)
fi

if [ ${#DIRS[@]} -eq 0 ]; then
  echo "No megavibe projects found."
  exit 0
fi

# Check each project
FOUND_ANY=false

for i in "${!DIRS[@]}"; do
  dir="${DIRS[$i]}"
  name="${NAMES[$i]}"
  lock_meta="$dir/.agent/.session-lock.d/metadata.json"

  if [ -f "$lock_meta" ]; then
    pid=$(jq -r '.pid // 0' "$lock_meta" 2>/dev/null || echo "0")
    if kill -0 "$pid" 2>/dev/null; then
      sid=$(jq -r '.session_id // "?"' "$lock_meta" 2>/dev/null)
      branch=$(jq -r '.branch // "?"' "$lock_meta" 2>/dev/null)
      started=$(jq -r '.started // "?"' "$lock_meta" 2>/dev/null)
      tty=$(jq -r '.tty // "?"' "$lock_meta" 2>/dev/null)

      if ! $FOUND_ANY; then
        FOUND_ANY=true
      fi

      echo -e "${GREEN}ACTIVE${RESET}  $name"
      echo "        Branch: $branch | PID: $pid | TTY: $tty"
      echo "        Started: $started"
      if [ "$sid" != "?" ] && [ "$sid" != "pending" ]; then
        echo "        Session: $sid"
      fi
      echo ""
    fi
  fi
done

# Also show idle projects with pending tasks
for i in "${!DIRS[@]}"; do
  dir="${DIRS[$i]}"
  name="${NAMES[$i]}"
  lock_meta="$dir/.agent/.session-lock.d/metadata.json"
  tasks_file="$dir/.agent/TASKS.md"

  # Skip if active (already shown above)
  if [ -f "$lock_meta" ]; then
    pid=$(jq -r '.pid // 0' "$lock_meta" 2>/dev/null || echo "0")
    if kill -0 "$pid" 2>/dev/null; then
      continue
    fi
  fi

  if [ -f "$tasks_file" ]; then
    open=$(grep -cE '\| pending|\| in.progress' "$tasks_file" 2>/dev/null || true)
    done_count=$(grep -cE '\| done|\| completed' "$tasks_file" 2>/dev/null || true)
    if [ "${open:-0}" -gt 0 ] 2>/dev/null; then
      echo -e "${YELLOW}IDLE${RESET}    $name — ${open} open task(s), ${done_count:-0} done"
    else
      echo -e "${DIM}IDLE${RESET}    $name — all tasks complete"
    fi
  else
    echo -e "${DIM}IDLE${RESET}    $name"
  fi
done

if ! $FOUND_ANY; then
  echo ""
  echo "No active sessions."
fi
