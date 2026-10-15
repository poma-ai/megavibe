#!/bin/bash
# deliverables-index.sh — keep a 1:1 phone copy of megavibe-deliverables/ honest.
#
# A session sends the folder's files to the user with SendUserFile (the user reads on a
# phone / Remote Control and cannot open laptop folders). This script is the bookkeeping:
# a ledger of what was sent, skipped or mirrored, and an INDEX.md that lists EVERY entry
# of the folder with its state, so nothing is silently missing.
#
#   deliverables-index.sh unsent                   entries not yet sent, skipped or mirrored (date order)
#   deliverables-index.sh mark NAME STATE...       record a state (sent YYYY-MM-DD | skipped: reason | URL), then rebuild INDEX.md
#   deliverables-index.sh index                    rebuild INDEX.md
#   deliverables-index.sh --dir DIR ...            folder (default ./megavibe-deliverables, or $MEGAVIBE_DELIVERABLES_DIR)
#
# Entries are the folder's top-level files and directories, minus STATUS.md, README.md,
# INDEX.md and dot files. The ledger is DIR/.mirror (one `name<TAB>state` line per call,
# the last line for a name wins). INDEX.md lines: `name | date | size | state`.
# Only the folder is ever written. Names with control characters are skipped with a note
# on stderr; a state is cut to one line of 200 printable characters.
set -euo pipefail

DIR="${MEGAVIBE_DELIVERABLES_DIR:-megavibe-deliverables}"
if [ "${1:-}" = "--dir" ]; then [ $# -ge 2 ] || { echo "error: --dir needs a value" >&2; exit 2; }; DIR="$2"; shift 2; fi
CMD="${1:-index}"; [ $# -gt 0 ] && shift
[ -d "$DIR" ] || { echo "error: no such folder: $DIR" >&2; exit 1; }
LEDGER="$DIR/.mirror"
CR=$(printf '\r'); TAB=$(printf '\t')

entries() {   # sorted entry names, one per line
  local f n
  for f in "$DIR"/* ; do
    [ -e "$f" ] || continue
    n=${f##*/}
    case "$n" in STATUS.md|README.md|INDEX.md) continue ;; esac
    case "$n" in *[[:cntrl:]]*) echo "note: skipped a name with control characters" >&2; continue ;; esac
    printf '%s\n' "$n"
  done | LC_ALL=C sort
}

state_of() {  # last ledger state for $1, else "unsent"
  local s=""
  if [ -f "$LEDGER" ]; then
    s=$(awk -F'\t' -v n="$1" '$1 == n { s = $2 } END { print s }' "$LEDGER" 2>/dev/null || true)
  fi
  [ -n "$s" ] && printf '%s' "$s" || printf 'unsent'
}

date_of() {   # leading YYYY-MM-DD of the name, else the modification date
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) printf '%s' "${1:0:10}" ;;
    *) date -r "$DIR/$1" +%Y-%m-%d 2>/dev/null || printf '?' ;;
  esac
}

size_of() {
  if [ -d "$DIR/$1" ]; then printf 'dir'; else wc -c < "$DIR/$1" | tr -d ' '; fi
}

build_index() {
  local tmp n
  tmp=$(mktemp "$DIR/.INDEX.XXXXXX")
  {
    echo "# Index of megavibe-deliverables"
    echo
    echo "Written by deliverables-index.sh, never by hand. One line per entry: name | date | size | state."
    echo "State: sent <date> (delivered with SendUserFile), skipped: <reason>, a URL (hosted mirror), or unsent."
    echo
    while IFS= read -r n; do
      printf '%s | %s | %s | %s\n' "$n" "$(date_of "$n")" "$(size_of "$n")" "$(state_of "$n")"
    done < <(entries)
  } > "$tmp"
  mv -f "$tmp" "$DIR/INDEX.md"
}

case "$CMD" in
  unsent)
    while IFS= read -r n; do
      [ "$(state_of "$n")" = unsent ] && printf '%s\n' "$n"
    done < <(entries) || true ;;
  index) build_index; echo "wrote $DIR/INDEX.md" ;;
  mark)
    [ $# -ge 2 ] || { echo "usage: deliverables-index.sh mark NAME STATE..." >&2; exit 2; }
    NAME="$1"; shift
    case "$NAME" in */*|.*|""|*[[:cntrl:]]*) echo "error: NAME must be one entry of the folder (no slash, no leading dot)" >&2; exit 2 ;; esac
    case "$NAME" in STATUS.md|README.md|INDEX.md) echo "error: $NAME is not an indexed entry" >&2; exit 2 ;; esac
    [ -e "$DIR/$NAME" ] || { echo "error: no such entry in $DIR: $NAME" >&2; exit 1; }
    STATE=$(printf '%s' "$*" | tr -d '\r' | tr '\t\n' '  ' | LC_ALL=C tr -cd ' -~' | cut -c1-200)
    [ -n "$STATE" ] || { echo "error: empty state" >&2; exit 2; }
    printf '%s\t%s\n' "$NAME" "$STATE" >> "$LEDGER"
    build_index ;;
  -h|--help) awk 'NR >= 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0" ;;
  *) echo "usage: deliverables-index.sh unsent | mark NAME STATE... | index [--dir DIR first]" >&2; exit 2 ;;
esac
