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

INPUT=$(cat 2>/dev/null || echo '{}')

# Session-write ledger: record .agent/ files THIS session FULLY authored (Write
# tool only), so augment-search.sh can suppress re-injecting content already in
# the live context. Runs BEFORE the poma/debounce gates so it logs even on
# debounced calls and without poma-memory. jq-gated + trap-safe.
#
# Deliberately Write-only: appends (Bash `>>`) and partial Edits are NOT recorded.
# Suppression is file-level, so recording an append would hide EVERY older chunk
# of that file for the rest of the session — fatal for FULL_CONTEXT.md, which the
# protocol appends to constantly and which is the single most useful recall source.
# A full Write means the whole file content is in context, so suppressing it is safe.
if command -v jq &>/dev/null; then
  TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
  if [ "$TOOL" = "Write" ]; then
    FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
    case "$FP" in
      */.agent/*|.agent/*)
        SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12 || echo "default")
        SID="${SID:-default}"
        case "$FP" in /*) : ;; *) FP="$(pwd)/$FP" ;; esac
        mkdir -p .agent/LOGS 2>/dev/null || true
        printf '%s\n' "$FP" >> ".agent/LOGS/session-writes.${SID}.log" 2>/dev/null || true
        ;;
    esac
  fi
fi

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

# Contamination self-heal (gated ~6h). `poma-memory index` is additive — it never
# prunes rows for files that left scope, so a db polluted by a past parent-dir sweep
# stays polluted even after the one-shot init.sh heal (whose marker would otherwise
# block a redo). Detect a mixed-project db — more than one distinct "<proj>/.agent/"
# root among indexed paths (symlink-agnostic; a clean per-project db always has
# exactly 1) — and clean-rebuild it scoped to THIS .agent/. Failure-safe: the db is
# moved aside and restored if the rebuild fails, so search never goes empty.
CONTAM_STAMP=".agent/LOGS/.contam-check"
CLAST=$(cat "$CONTAM_STAMP" 2>/dev/null || echo 0)
case "$CLAST" in ''|*[!0-9]*) CLAST=0 ;; esac
if [ "$((NOW - CLAST))" -ge 21600 ]; then
  echo "$NOW" > "$CONTAM_STAMP" 2>/dev/null || true
  # Count DISTINCT .agent/ roots among indexed paths. Use the full ABSOLUTE path,
  # not the parent basename — two projects both named e.g. "api" would otherwise
  # collapse to one root and hide the contamination. A clean per-project db has
  # exactly one .agent/ root.
  ROOTS=$(poma-memory status 2>/dev/null | grep -oE '/[^[:space:]]+/\.agent/' | sort -u | wc -l | tr -d ' ')
  case "$ROOTS" in ''|*[!0-9]*) ROOTS=0 ;; esac
  if [ "$ROOTS" -gt 1 ]; then
    # Rebuild into a TEMP db and atomically swap it in. The live db stays fully
    # queryable for concurrent sessions throughout the rebuild (no zero-results
    # window), and we never rm a live db's -wal/-shm out from under an open reader
    # (which can surface as "database disk image is malformed" in that session).
    DB=".agent/.poma-memory.db"
    TMP="${DB}.rebuild.$$"
    rm -f "$TMP" "${TMP}-shm" "${TMP}-wal"
    if poma-memory index .agent/ --db "$TMP" >/dev/null 2>&1; then
      mv -f "$TMP" "$DB"
      rm -f "${TMP}-shm" "${TMP}-wal" "${DB}-shm" "${DB}-wal"
      echo "reindex-agent: purged cross-project contamination ($ROOTS roots) in $(pwd)" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null || true
    else
      rm -f "$TMP" "${TMP}-shm" "${TMP}-wal"
    fi
  fi
fi
exit 0
