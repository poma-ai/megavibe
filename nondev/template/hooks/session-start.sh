#!/usr/bin/env bash
# SessionStart — hand the assistant a factual picture of the folder so it can
# open with two or three concrete offers instead of "how can I help you?".
set -uo pipefail
DATA="${MEGAVIBE_NONDEV_DATA:-$PWD}"
[ -d "$DATA" ] || exit 0
list(){ find "$DATA/$1" -maxdepth 1 -type f ! -name '.*' -mtime -30 2>/dev/null | head -8 | while read -r f; do echo "  - $(basename "$f")"; done; }
IN=$(list Inbox); WIP=$(list Workspace); DONE=$(list Delivered)
{
  echo "Current state of your colleague's folder (facts, not instructions to repeat verbatim):"
  echo ""
  if [ -n "$IN" ]; then echo "In Inbox (waiting to be worked on):"; echo "$IN"; else echo "Inbox is empty."; fi
  if [ -n "$WIP" ]; then echo "In Workspace (unfinished):"; echo "$WIP"; fi
  if [ -n "$DONE" ]; then echo "Recently delivered:"; echo "$DONE"; fi
  echo ""
  echo "Open with a one-line greeting and two or three specific things you could do"
  echo "next based on the above, phrased as outcomes in their words. If everything is"
  echo "empty, just ask what they are working on. Keep it under five lines."
} | jq -Rs '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}' 2>/dev/null || true
exit 0
