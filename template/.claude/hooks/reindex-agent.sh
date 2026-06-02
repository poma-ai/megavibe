#!/bin/bash
# Megavibe — keep the poma-memory index fresh as .agent/ changes.
#
# Without this, .agent/.poma-memory.db only updates on a manual `poma_index`, so
# semantic recall (augment-search.sh) drifts stale: new FULL_CONTEXT / DECISIONS
# / LESSONS / RESEARCH content stays invisible until someone reindexes by hand.
#
# Strategy: a debounced FULL `poma-memory index .agent/`. poma-memory's update_file
# skips unchanged files by mtime (append-only fast path for the rest), so a full
# scan is cheap (~0.4s idle, re-chunks only what changed) AND catches every write
# path — the Write/Edit tools AND Bash `>>` appends (how the protocol usually
# appends to .agent/). A targeted Edit-only `--file` hook would miss those.
#
# Triggered by: PostToolUse (Edit|Write|MultiEdit|Bash)
#
# Safe: never blocks (exit 0 always). No-op outside megavibe projects / without
# poma-memory. Self-bootstraps the index on first run if the db doesn't exist yet.
_hook_error() {
  echo "reindex-agent.sh failed at line $1: $2" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

[ -d ".agent" ] || exit 0
command -v poma-memory &>/dev/null || exit 0

# Debounce: at most one reindex per DEBOUNCE seconds. The stamp is project-level
# (not session-scoped) so concurrent sessions in the same project also coordinate,
# which limits SQLite write contention on the shared db.
DEBOUNCE=20
STAMP=".agent/LOGS/.reindex-stamp"
mkdir -p .agent/LOGS 2>/dev/null || true
NOW=$(date +%s)
LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
[ "$((NOW - LAST))" -ge "$DEBOUNCE" ] || exit 0
echo "$NOW" > "$STAMP" 2>/dev/null || true

# mtime-gated full scan — re-chunks only changed files; errors are non-fatal
# (e.g. a transient SQLite lock from a concurrent run resolves next window).
poma-memory index .agent/ >/dev/null 2>&1 || true
exit 0
