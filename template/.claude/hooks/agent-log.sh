#!/bin/bash
# agent-log — append-only project context, without a shared mutable file.
#
# The problem this replaces: every session and every machine appended to one
# `.agent/FULL_CONTEXT.md`, coordinated by an flock on a sibling `.lock` file.
# That works between processes on one Mac and cannot work at all across two,
# because a file-level sync (iCloud, Dropbox, Drive) resolves divergence by
# picking a whole-file winner. The loser's entries disappear with no conflict
# copy and no error — from the file the protocol calls durable.
#
# A lock cannot fix that; two machines cannot lock a synced file. So don't share
# a mutable file. Each entry becomes its own immutable file:
#
#   .agent/snapshot.md         older entries, folded — rewritten only by `fold`
#   .agent/events/<ts>-<host>-<rand>.md   one entry, written once, never edited
#   .agent/FULL_CONTEXT.md     DERIVED: snapshot + every event, in order
#
# Nobody ever writes the same path twice, so no transport has anything to
# reconcile — and many small write-once files is the case cloud sync handles
# well. FULL_CONTEXT.md stays exactly where every reader already expects it,
# but it is now a rendered view: safe to clobber, reproducible from the events,
# and no longer worth syncing.
#
# Usage:
#   agent-log append [--project DIR]                  # entry text on stdin
#   agent-log render [--project DIR]
#   agent-log fold [--before YYYY-MM-DD] [--project DIR]
#   agent-log path [--project DIR]
set -euo pipefail

PROJECT="."
BEFORE=""
CMD="${1:-}"
[ $# -gt 0 ] && shift

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --before)  BEFORE="$2";  shift 2 ;;
    *) shift ;;
  esac
done

AGENT_DIR="$PROJECT/.agent"
LOG_DIR="$AGENT_DIR/events"
SNAPSHOT="$AGENT_DIR/snapshot.md"
RENDERED="$AGENT_DIR/FULL_CONTEXT.md"

[ -d "$AGENT_DIR" ] || { echo "agent-log: no .agent/ in $PROJECT" >&2; exit 1; }

# One-time migration. An existing FULL_CONTEXT.md is real history that predates
# the event log, so it becomes the base of the snapshot rather than being
# rendered away. Idempotent: only fires when there is no snapshot yet.
migrate_legacy() {
  mkdir -p "$LOG_DIR"
  # Adopt when there is no snapshot yet, FULL_CONTEXT.md has content, and no
  # event has been recorded. Emptiness of events/ is the test, NOT its absence:
  # init.sh creates the directory on every run, so an absence check would skip
  # migration on every existing project and the first render would replace
  # their history with nothing.
  if [ ! -e "$SNAPSHOT" ] && [ -s "$RENDERED" ] && [ -z "$(find "$LOG_DIR" -name '*.md' -print -quit 2>/dev/null)" ]; then
    tmp="$(mktemp "$AGENT_DIR/.snapshot.XXXXXX")" || return 1
    cat "$RENDERED" > "$tmp"
    mv -f "$tmp" "$SNAPSHOT"
    echo "agent-log: adopted $(wc -l < "$SNAPSHOT" | tr -d ' ') existing lines as $SNAPSHOT" >&2
  fi
  [ -e "$SNAPSHOT" ] || : > "$SNAPSHOT"
}

# Rebuild the derived view. Written to a temp and renamed, so a reader never
# sees a half-built file and two machines rendering at once cannot interleave.
render() {
  local tmp rc=0
  tmp="$(mktemp "$AGENT_DIR/.FULL_CONTEXT.XXXXXX")" || return 1
  {
    if [ -s "$SNAPSHOT" ]; then cat "$SNAPSHOT" || rc=1; fi
    # Filenames lead with a UTC timestamp, so lexical order is chronological.
    for f in "$LOG_DIR"/*.md; do
      [ -e "$f" ] || continue
      cat "$f" || rc=1
    done
  } > "$tmp"
  # Never publish a view we could not build completely — a truncated
  # FULL_CONTEXT.md reads as history that was deleted.
  if [ "$rc" != 0 ]; then
    rm -f "$tmp"
    echo "agent-log: render failed, left $RENDERED untouched" >&2
    return 1
  fi
  mv -f "$tmp" "$RENDERED"
}

case "$CMD" in
  append)
    migrate_legacy
    staged="$(mktemp "$AGENT_DIR/.entry.XXXXXX")" || exit 1
    cat > "$staged"
    if [ ! -s "$staged" ] || [ -z "$(tr -d '[:space:]' < "$staged")" ]; then
      rm -f "$staged"
      exit 0
    fi
    # Timestamp orders the entry; host and random suffix keep two writers in the
    # same second from ever choosing the same name.
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    host="$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || echo host)"
    host="$(printf '%s' "$host" | tr -cd '[:alnum:]' | cut -c1-12)"
    rand="$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo $RANDOM)"
    out="$LOG_DIR/${ts}-${host:-host}-${rand}.md"
    # A fresh unique path: no lock, nothing to race with, nothing to overwrite.
    mv -f "$staged" "$out"
    render
    echo "$out"
    ;;

  render)
    migrate_legacy
    render
    echo "$RENDERED"
    ;;

  fold)
    # Compaction without deletion: old entries move into the snapshot instead of
    # being line-edited out of a file nobody can reconstruct.
    migrate_legacy
    cutoff="${BEFORE:-$(date -u -v-30d +%Y-%m-%d 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%d)}"
    cutoff_ts="$(printf '%s' "$cutoff" | tr -d '-')"
    moved=0
    tmp="$(mktemp "$AGENT_DIR/.snapshot.XXXXXX")" || exit 1
    folded="$(mktemp "$AGENT_DIR/.folded.XXXXXX")" || exit 1
    cat "$SNAPSHOT" > "$tmp" 2>/dev/null || true
    for f in "$LOG_DIR"/*.md; do
      [ -e "$f" ] || continue
      day="$(basename "$f" | cut -c1-8)"
      if [ "$day" \< "$cutoff_ts" ]; then
        cat "$f" >> "$tmp"
        printf '%s\n' "$f" >> "$folded"
        moved=$((moved + 1))
      fi
    done
    # Land the snapshot BEFORE removing anything. Deleting as we copied meant an
    # interrupted fold lost those entries from the snapshot and the event log
    # both; this way the worst case is a duplicate, which a re-fold cannot cause
    # because the files are already gone.
    mv -f "$tmp" "$SNAPSHOT"
    while IFS= read -r f; do [ -n "$f" ] && rm -f "$f"; done < "$folded"
    rm -f "$folded"
    render
    echo "agent-log: folded $moved entries older than $cutoff into $SNAPSHOT"
    ;;

  path)
    echo "$LOG_DIR"
    ;;

  *)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
