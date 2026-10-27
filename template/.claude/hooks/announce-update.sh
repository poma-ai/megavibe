#!/bin/bash
# DO NOT use set -e — a hook must never fail the turn.
set -u

# Megavibe — tell the user what an update actually changed.
#
# `megavibe update` (and the /megavibe-restart path, which runs it) leaves two
# files under ~/.megavibe:
#   .update-changelog  commit subjects plus the deployed files that changed
#   .update-summary    a short plain-language note written at update time by
#                      `claude -p --model haiku`; its first line names the
#                      version it describes. Absent when none could be made.
# This hook shows the note once, at session start, as a systemMessage: text for
# the user to read. No turn is started, nothing is typed for them, and nothing
# goes into the model's context. With no usable note it shows a few commit
# subjects instead.
#
# Claimed with mv, not read-then-delete: two sessions starting at once would
# otherwise both announce. mv is atomic, so exactly one wins and the loser
# exits silently. The changelog is the claim; the summary is taken only after
# winning it, and only when it is keyed to the same version as the changelog.
#
# Triggered by: SessionStart (matcher: startup|resume). Exit 0 always.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0

MV_HOME="${MEGAVIBE_HOME:-${HOME:-/tmp}/.megavibe}"
CHANGELOG="$MV_HOME/.update-changelog"
SUMMARY="$MV_HOME/.update-summary"

# A hook killed between the mv and the read orphans its claim permanently,
# taking the announcement with it. Reap stale ones rather than accumulating a
# file per crash. A summary nobody claimed within the changelog's own week (its
# changelog was dropped, or never written) has nothing left to attach to.
find "$MV_HOME" -maxdepth 1 \( -name '.update-changelog.claimed.*' -o -name '.update-summary.claimed.*' \) -mtime +1 -delete 2>/dev/null
find "$MV_HOME" -maxdepth 1 -name '.update-summary' -mtime +7 -delete 2>/dev/null

[ -f "$CHANGELOG" ] || exit 0

# An update nobody has opened a session since is worth announcing; one from a
# fortnight ago is noise that survived because the user works in a project
# megavibe was never inited into.
if [ -n "$(find "$CHANGELOG" -mtime +7 2>/dev/null)" ]; then
  rm -f "$CHANGELOG" "$SUMMARY" 2>/dev/null
  exit 0
fi

CLAIM="$CHANGELOG.claimed.$$"
SUMCLAIM="$SUMMARY.claimed.$$"
mv "$CHANGELOG" "$CLAIM" 2>/dev/null || exit 0
trap 'rm -f "$CLAIM" "$SUMCLAIM" 2>/dev/null' EXIT
RAW=$(cat "$CLAIM" 2>/dev/null || echo "")
[ -n "$RAW" ] || exit 0

# "megavibe updated: <old> -> <new> (<n> commits)"
HDR=$(printf '%s\n' "$RAW" | head -n 1)
NEW=$(printf '%s' "$HDR" | sed -n 's/^megavibe updated: [0-9a-f][0-9a-f]* -> \([0-9a-f][0-9a-f]*\).*/\1/p')
COUNT=$(printf '%s' "$HDR" | sed -n 's/.*(\([0-9][0-9]*\) commits).*/\1/p')

# Control characters out of anything that reaches the terminal: commit subjects
# are written by whoever can push, and the summary derives from them.
clean() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }

NOTE=""
if [ -n "$NEW" ] && [ -f "$SUMMARY" ] \
   && [ "$(head -n 1 "$SUMMARY" 2>/dev/null)" = "megavibe-update-summary: $NEW" ] \
   && mv "$SUMMARY" "$SUMCLAIM" 2>/dev/null; then
  NOTE=$(tail -n +2 "$SUMCLAIM" 2>/dev/null | clean | head -n 8 | head -c 1500)
fi

if [ -z "$(printf '%s' "$NOTE" | tr -d '[:space:]')" ]; then
  # No note: the first few commit subjects, which is all a changelog line can
  # honestly be. The "Commits:" block runs to the first blank line; a "  ... "
  # line is the writer's own truncation marker, not a commit.
  SUBJ=$(printf '%s\n' "$RAW" | awk '/^Commits:$/ { f = 1; next } f && /^$/ { exit } f && !/^  \.\.\. / { print }' | clean)
  TOTAL=$(printf '%s\n' "$SUBJ" | grep -c . 2>/dev/null)
  TOTAL="${TOTAL:-0}"
  NOTE=$(printf '%s\n' "$SUBJ" | grep . | head -n 5 | cut -c1-100 | sed 's/^/- /')
  if [ -n "$NOTE" ] && [ "${COUNT:-$TOTAL}" -gt 5 ] 2>/dev/null; then
    NOTE="$NOTE
- ... and $(( ${COUNT:-$TOTAL} - 5 )) more"
  fi
fi
[ -n "$(printf '%s' "$NOTE" | tr -d '[:space:]')" ] || exit 0

case "${COUNT:-}" in
  1) TITLE="megavibe updated (1 commit)" ;;
  ''|*[!0-9]*) TITLE="megavibe updated" ;;
  *) TITLE="megavibe updated ($COUNT commits)" ;;
esac

jq -nc --arg m "$TITLE
$NOTE" '{systemMessage: $m}'
exit 0
