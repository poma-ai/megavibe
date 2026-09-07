#!/bin/bash
# DO NOT use set -e — a hook must never fail the turn.
set -u

# Megavibe — nudge to restart when this session is running stale hooks/agents.
#
# Hooks, subagents and the appended system prompt are read once, at process
# launch. When another session (or the 24h auto-check) updates megavibe, the
# running process keeps the OLD ones until it is relaunched. The wrapper writes
# the new version to ~/.megavibe/.update-applied; the launch version is in
# $MEGAVIBE_LAUNCH_VERSION. When they differ, this process is stale.
#
# This fires on Stop — the turn boundary, a harmless phase between commands —
# and prints one line, once per session. It never blocks and never forces an
# exit: the restart stays a /megavibe-restart the human chooses to run.
#
# Triggered by: Stop. Exit 0 always.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0

MV_HOME="${MEGAVIBE_HOME:-${HOME:-/tmp}/.megavibe}"
APPLIED="$MV_HOME/.update-applied"
[ -f "$APPLIED" ] || exit 0

LAUNCH="${MEGAVIBE_LAUNCH_VERSION:-}"
# No baseline, or it says "unknown" → can't tell staleness, stay silent.
case "$LAUNCH" in ""|unknown) exit 0 ;; esac

NEWVER=$(cat "$APPLIED" 2>/dev/null || echo "")
[ -n "$NEWVER" ] || exit 0
[ "$NEWVER" != "$LAUNCH" ] || exit 0   # already current

INPUT=$(cat 2>/dev/null || echo "")
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
[ -n "$SID" ] || SID=default

# Once per session: the flag is keyed by session AND the version we nudged
# toward, so a second, newer update in the same session nudges again.
FLAG="$MV_HOME/.restart-nudged.${SID}.${NEWVER}"
[ -e "$FLAG" ] && exit 0
# If we can't record that we nudged, stay silent rather than nag every turn.
: > "$FLAG" 2>/dev/null || exit 0

MSG="megavibe updated since this session started — its hooks, agents and style prompt are the older ones. Run /megavibe-restart to update and resume this conversation with the new ones (it sets a marker, then has you /exit; the wrapper relaunches with --continue). A bare /exit will NOT do it. Nothing forces this; finish what you are doing first."
jq -nc --arg m "$MSG" '{systemMessage: $m}'
exit 0
