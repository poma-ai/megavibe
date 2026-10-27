#!/bin/bash
# DO NOT use set -e — a hook must never fail the turn.
set -u

# Megavibe — tell the user what an update actually changed.
#
# `megavibe update` (and the /megavibe-restart path, which runs it) publishes one
# immutable file per update, ~/.megavibe/update-notes/<old8>-<new8>, and this
# hook shows what is pending once, at session start, as ONE systemMessage: text
# for the user to read. No turn is started, nothing is typed for them, and
# nothing goes into the model's context.
#
# A record, read here by position (never by searching for markers: commit
# subjects are untrusted text and come last):
#   line 1     ts: <epoch>         when the update started; orders the records
#   line 2     megavibe updated: <old8> -> <new8> (<n> commits)
#   line 3     summary: <k>        k = 0..8
#   next k     a plain-language note made at update time by `claude -p --model haiku`
#   then       a blank line, "Commits:" with the subjects, the deployed files
# With no note it shows the first few commit subjects instead. Older launchers
# wrote the same thing without line 1 (and, the oldest, without line 3), as the
# single file ~/.megavibe/.update-changelog; that is still read, once.
#
# Why this cannot race: the launcher only ever adds a new file under its own
# name and never reads, extends or deletes another update's; this hook takes
# each pending file with its own mv into a directory only it knows. mv is atomic
# per file, so a record goes to exactly one session, a file another session took
# first is skipped, and a record published while this runs is simply found by the
# next session. Two updates that finish out of order are two records, both shown,
# oldest first. This hook never waits for anything.
#
# Needs jq to build the message. Without it nothing is shown and the records
# wait (they are dropped unshown after a week).
#
# Triggered by: SessionStart (matcher: startup|resume). Exit 0 always.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0

MV_HOME="${MEGAVIBE_HOME:-${HOME:-/tmp}/.megavibe}"
NOTES="$MV_HOME/update-notes"
LEGACY="$MV_HOME/.update-changelog"
[ -d "$NOTES" ] || [ -f "$LEGACY" ] || exit 0

# Everything below is byte-wise (LC_ALL=C): awk, cut and tr abort on text that
# is not valid UTF-8 in a UTF-8 locale, and commit subjects are whatever someone
# typed. jq repairs a stray invalid byte into U+FFFD when it builds the JSON.
export LC_ALL=C

MAXLINES=40      # the whole message, about
MAXBYTES=3000
MAXFILES=50      # records taken in one go

# Housekeeping. A hook killed after taking its files leaves its private
# directory; a launcher killed mid-write leaves a temp file. A record nobody
# showed for a week is dropped unshown: a project megavibe was never inited into
# never announces anything, and a fortnight-old update is noise.
if [ -d "$NOTES" ]; then
  find "$NOTES" -maxdepth 1 -type f \( -name '.tmp.*' -mtime +1 -o -name '????????-????????' -mtime +7 \) -delete 2>/dev/null
fi
find "$MV_HOME" -maxdepth 1 -type d -name '.update-claim.*' -mtime +1 -exec rm -rf {} + 2>/dev/null
[ -z "$(find "$LEGACY" -mtime +7 2>/dev/null)" ] || rm -f "$LEGACY" 2>/dev/null

CLAIMDIR="$MV_HOME/.update-claim.$$"
mkdir "$CLAIMDIR" 2>/dev/null || exit 0
trap 'rm -rf "$CLAIMDIR" 2>/dev/null' EXIT

# Take whatever is pending. Only names that are exactly <8 hex>-<8 hex> count.
NAMES=""
n=0
if [ -d "$NOTES" ]; then
  for p in "$NOTES"/*; do
    name="${p##*/}"
    case "$name" in ????????-????????) ;; *) continue ;; esac
    case "$name" in *[!0-9a-f-]*) continue ;; esac
    [ -f "$p" ] || continue
    [ "$n" -lt "$MAXFILES" ] || break
    mv "$p" "$CLAIMDIR/$name" 2>/dev/null || continue   # another session got it
    NAMES="$NAMES $name"; n=$((n + 1))
  done
fi
if [ -f "$LEGACY" ] && mv "$LEGACY" "$CLAIMDIR/legacy" 2>/dev/null; then
  NAMES="$NAMES legacy"
fi
[ -n "$NAMES" ] || exit 0

HAVE_ICONV=0
command -v iconv >/dev/null 2>&1 && HAVE_ICONV=1

# Control characters out of anything that reaches the terminal. First iconv -c
# drops every invalid UTF-8 sequence, so what is removed next cannot join stray
# bytes into a new character (c2 c2 85 9b would become c2 9b, a CSI, once c2 85
# went); then C0 and DEL (tab and newline stay), the C1 range U+0080-U+009F, and
# the invisible format and bidi controls U+200B-U+200F, U+2028-U+202E,
# U+2066-U+2069 and U+FEFF. The awk loops until nothing more matches, which also
# covers a machine without iconv. Commit subjects are written by whoever can
# push, and the note derives from them.
clean() {
  if [ "$HAVE_ICONV" = 1 ]; then iconv -c -f UTF-8 -t UTF-8 2>/dev/null; else cat; fi \
    | tr -d '\000-\010\013-\037\177' \
    | awk '{ while (gsub(/\302[\200-\237]|\342\200[\213-\217\250-\256]|\342\201[\246-\251]|\357\273\277/, "")) { } print }'
}

# render <file>: sets TS and writes the record's block to <file>.blk. Returns 1
# for a record that cannot be read as an announcement.
TS=0
render() {
  local f="$1" raw l1 off=0 hdr ids o nw cnt line2 k=0 note subj total c title
  TS=0
  raw=$(cat "$f" 2>/dev/null) || return 1
  l1=$(printf '%s\n' "$raw" | sed -n 1p)
  case "$l1" in 'ts: '[0-9]*) TS="${l1#ts: }"; off=1 ;; esac
  case "$TS" in ''|*[!0-9]*) TS=0 ;; esac
  [ "${#TS}" -le 12 ] || TS=0
  hdr=$(printf '%s\n' "$raw" | sed -n "$((off + 1))p")
  ids=$(printf '%s' "$hdr" | sed -n 's/^megavibe updated: \([0-9a-f][0-9a-f]*\) -> \([0-9a-f][0-9a-f]*\).*/\1 \2/p')
  [ -n "$ids" ] || return 1
  o=$(printf '%s' "${ids% *}" | cut -c1-8); nw=$(printf '%s' "${ids#* }" | cut -c1-8)
  cnt=$(printf '%s' "$hdr" | sed -n 's/.*(\([0-9][0-9]*\) commits).*/\1/p')
  # The line after the header says how many note lines follow; anything else
  # (an oldest launcher's blank line) means none.
  line2=$(printf '%s\n' "$raw" | sed -n "$((off + 2))p")
  case "$line2" in 'summary: '[0-8]) k="${line2#summary: }" ;; esac
  note=""
  if [ "$k" -gt 0 ]; then
    note=$(printf '%s\n' "$raw" | sed -n "$((off + 3)),$((off + 2 + k))p" | clean | head -c 1500)
  fi
  if [ -z "$(printf '%s' "$note" | tr -d '[:space:]')" ]; then
    # No note: the first few commit subjects, which is all a changelog line can
    # honestly be. The "Commits:" block runs to the first blank line; a "  ... "
    # line is the writer's own truncation marker, not a commit. The note's lines
    # are skipped by position first.
    subj=$(printf '%s\n' "$raw" | tail -n +"$((off + 3 + k))" | awk '/^Commits:$/ { f = 1; next } f && /^$/ { exit } f && !/^  \.\.\. / { print }' | clean)
    total=$(printf '%s\n' "$subj" | grep -c . 2>/dev/null)
    total="${total:-0}"
    note=$(printf '%s\n' "$subj" | grep . | head -n 5 | cut -c1-100 | sed 's/^/- /')
    if [ -n "$note" ] && [ "${cnt:-$total}" -gt 5 ] 2>/dev/null; then
      note="$note
- ... and $(( ${cnt:-$total} - 5 )) more"
    fi
  fi
  [ -n "$(printf '%s' "$note" | tr -d '[:space:]')" ] || return 1
  case "$cnt" in
    1) c=" (1 commit)" ;;
    ''|*[!0-9]*) c="" ;;
    *) c=" ($cnt commits)" ;;
  esac
  title="megavibe updated ${o}→${nw}${c}"
  printf '%s\n%s\n' "$title" "$note" > "$f.blk"
}

# Oldest first by the record's own timestamp, ties by name.
ORDER=""
for name in $NAMES; do
  if render "$CLAIMDIR/$name"; then
    ORDER="$ORDER$TS $name
"
  fi
done
SORTED=$(printf '%s' "$ORDER" | sort -k1,1n -k2,2)

# One message, about MAXLINES lines and MAXBYTES bytes. Records that do not fit go
# back, untouched, for the next session (the first one always shows). A name
# the launcher republished in the meantime wins: mv -n leaves it alone.
MSG=""; MLINES=0; MBYTES=0; SHOWN=0; LEFT=0
while read -r _ name; do
  [ -n "$name" ] || continue
  blk=$(cat "$CLAIMDIR/$name.blk" 2>/dev/null)
  bl=$(printf '%s\n' "$blk" | wc -l | tr -d ' ')
  bb=${#blk}
  if [ "$LEFT" -gt 0 ] || { [ "$SHOWN" -gt 0 ] && { [ $((MLINES + bl + 1)) -gt "$MAXLINES" ] || [ $((MBYTES + bb + 1)) -gt "$MAXBYTES" ]; }; }; then
    if [ "$name" = legacy ]; then mv -n "$CLAIMDIR/legacy" "$LEGACY" 2>/dev/null; else mv -n "$CLAIMDIR/$name" "$NOTES/$name" 2>/dev/null; fi
    LEFT=$((LEFT + 1))
    continue
  fi
  if [ "$SHOWN" -gt 0 ]; then MSG="$MSG

$blk"; MLINES=$((MLINES + bl + 1)); MBYTES=$((MBYTES + bb + 1)); else MSG="$blk"; MLINES=$bl; MBYTES=$bb; fi
  SHOWN=$((SHOWN + 1))
done <<EOF
$SORTED
EOF
[ "$SHOWN" -gt 0 ] || exit 0
if [ "$LEFT" -gt 0 ]; then
  if [ "$LEFT" = 1 ]; then MSG="$MSG

... and 1 more update, shown at your next session start"; else MSG="$MSG

... and $LEFT more updates, shown at your next session start"; fi
fi

jq -nc --arg m "$MSG" '{systemMessage: $m}'
exit 0
