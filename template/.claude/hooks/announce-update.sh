#!/bin/bash
# DO NOT use set -e — a hook must never fail the turn.
set -u

# Megavibe — tell the user what an update actually changed.
#
# `megavibe update` (and the /megavibe-restart path, which runs it) leaves ONE
# file, ~/.megavibe/.update-changelog, and this hook shows it once, at session
# start, as a systemMessage: text for the user to read. No turn is started,
# nothing is typed for them, and nothing goes into the model's context.
#
# Layout, written by the launcher and read here by position (never by searching
# for markers: commit subjects are untrusted text and come last):
#   line 1     megavibe updated: <old8> -> <new8> (<n> commits)
#   line 2     summary: <k>        k = 0..8; older launchers wrote a blank line
#   next k     a plain-language note made at update time by `claude -p --model haiku`
#   then       a blank line, "Commits:" with the subjects, the deployed files
# With no note it shows the first few commit subjects instead.
#
# One file, claimed with mv, is the whole race story: two sessions starting at
# once would otherwise both announce, and a note kept in a second file could be
# swapped for another update's between the check and the take. mv is atomic, so
# exactly one session wins and the loser exits silently; what the winner then
# reads is a private, immutable copy. This hook never waits: an updater that is
# mid-way through publishing a newer record simply means this session finds
# nothing, and the newer record is announced by the next one.
#
# Triggered by: SessionStart (matcher: startup|resume). Exit 0 always.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0

MV_HOME="${MEGAVIBE_HOME:-${HOME:-/tmp}/.megavibe}"
CHANGELOG="$MV_HOME/.update-changelog"

# A hook killed between the mv and the read orphans its claim permanently,
# taking the announcement with it. Reap stale ones rather than accumulating a
# file per crash.
find "$MV_HOME" -maxdepth 1 -name '.update-changelog.claimed.*' -mtime +1 -delete 2>/dev/null

# An updater killed (Ctrl-C included) while it held the pending record leaves it
# in .update-changelog.updating.<pid>, touched when it was taken. A live updater
# holds it for a few minutes at most (the summary call is bounded to 120 s), so a
# claim older than ten is an orphan: put it back (no-clobber, a newer record
# wins) and announce it.
if [ ! -e "$CHANGELOG" ]; then
  for orphan in "$CHANGELOG".updating.*; do
    [ -f "$orphan" ] || continue
    [ -n "$(find "$orphan" -mmin +10 2>/dev/null)" ] || continue
    mv -n "$orphan" "$CHANGELOG" 2>/dev/null
    [ -e "$CHANGELOG" ] && break
  done
fi
find "$MV_HOME" -maxdepth 1 -name '.update-changelog.updating.*' -mtime +1 -delete 2>/dev/null

[ -f "$CHANGELOG" ] || exit 0

# An update nobody has opened a session since is worth announcing; one from a
# fortnight ago is noise that survived because the user works in a project
# megavibe was never inited into. Dropped here, lazily, at the next session
# start after it turns a week old, not by a timer.
if [ -n "$(find "$CHANGELOG" -mtime +7 2>/dev/null)" ]; then
  rm -f "$CHANGELOG" 2>/dev/null
  exit 0
fi

CLAIM="$CHANGELOG.claimed.$$"
mv "$CHANGELOG" "$CLAIM" 2>/dev/null || exit 0
trap 'rm -f "$CLAIM" 2>/dev/null' EXIT
RAW=$(cat "$CLAIM" 2>/dev/null || echo "")
[ -n "$RAW" ] || exit 0

# Everything below is byte-wise (LC_ALL=C): awk, cut and tr abort on text that
# is not valid UTF-8 in a UTF-8 locale, and commit subjects are whatever someone
# typed. jq repairs a stray invalid byte into U+FFFD when it builds the JSON.
export LC_ALL=C

# Control characters out of anything that reaches the terminal: C0, DEL and the
# C1 range U+0080-U+009F (UTF-8 c2 80-9f), which includes the one-code-point CSI
# U+009B. Commit subjects are written by whoever can push, and the note derives
# from them.
clean() { tr -d '\000-\010\013-\037\177' | awk '{ gsub(/\302[\200-\237]/, ""); print }'; }

# "megavibe updated: <old> -> <new> (<n> commits)"
HDR=$(printf '%s\n' "$RAW" | head -n 1)
COUNT=$(printf '%s' "$HDR" | sed -n 's/.*(\([0-9][0-9]*\) commits).*/\1/p')

# Line 2 says how many note lines follow; anything else (an older launcher's
# blank line) means none.
LINE2=$(printf '%s\n' "$RAW" | sed -n 2p)
K=0
case "$LINE2" in
  'summary: '[0-8]) K="${LINE2#summary: }" ;;
esac

NOTE=""
if [ "$K" -gt 0 ]; then
  NOTE=$(printf '%s\n' "$RAW" | sed -n "3,$((K + 2))p" | clean | head -c 1500)
fi

if [ -z "$(printf '%s' "$NOTE" | tr -d '[:space:]')" ]; then
  # No note: the first few commit subjects, which is all a changelog line can
  # honestly be. The "Commits:" block runs to the first blank line; a "  ... "
  # line is the writer's own truncation marker, not a commit. The note's lines
  # are skipped by position first.
  SUBJ=$(printf '%s\n' "$RAW" | tail -n +"$((K + 3))" | awk '/^Commits:$/ { f = 1; next } f && /^$/ { exit } f && !/^  \.\.\. / { print }' | clean)
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
