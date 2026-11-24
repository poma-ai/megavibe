#!/bin/bash
# Megavibe — the cheap frozen copy a reader or a test needs, in place of `cp -R` of a whole repo.
#
#   review-copy.sh make [--repo DIR] [--max-file-kb N] [PATH...]
#       Prints the path of a new directory holding the working-tree contents of the files git
#       lists for the repository (tracked plus untracked files that are not ignored, edits
#       included; deleted files are absent): no .git, no ignored files (node_modules, virtualenvs,
#       build output, caches), no symlinks, nothing over --max-file-kb (default 2048; skipped names
#       are listed in the marker, newlines in a name shown as ?). With PATH... only those paths (relative to the repository top, not the current directory).
#       The copy goes under $TMPDIR (default /tmp): in a session, run it as
#       TMPDIR=<your scratchpad> review-copy.sh make ... so the copy counts against the session's
#       scratch budget, and pass the same TMPDIR to remove. A diff is the caller's to hand over
#       (git diff > file); the copy carries no history. A repository file named
#       .megavibe-review-copy is skipped.
#   review-copy.sh list [DIR]
#       Copies this script made directly under DIR (default: the temp folder), with sizes.
#   review-copy.sh remove DIR...
#       Removes copies this script made, for real (scratch is not user data and the Trash would keep
#       the blocks on the same disk), write-protected ones included. A copy qualifies only when it is
#       a real directory named mv-review-copy.* directly inside the temp folder, with a marker that is
#       a regular file holding this script's first line. Anything else is refused.
#
# Why: a reader needs the files, not the history and not the 0.7 GB of dependencies next to them;
# whole-repo copies per reader per round filled a disk (29 GB of session scratch in three days,
# 2026-11-23). A round is not done while its copies exist: remove them when it ends.
# The working tree and the index are not touched.
set -euo pipefail

MAGIC=mv-review-copy-v1
MARK=.megavibe-review-copy
TMPBASE=${TMPDIR:-/tmp}
case $TMPBASE in /*) ;; *) TMPBASE=$PWD/$TMPBASE ;; esac   # the copy is made from inside the repository: keep the base absolute
die() { echo "review-copy: $*" >&2; exit 2; }
if stat -c %s /dev/null >/dev/null 2>&1; then   # flavour detected once: GNU stat -c, else BSD stat -f
  fsize() { stat -c %s "$1" 2>/dev/null || echo 999999999999; }   # unknown size counts as over the cap
else
  fsize() { stat -f %z "$1" 2>/dev/null || echo 999999999999; }
fi
canon() { local o; o=$(cd -P -- "$1" 2>/dev/null && { pwd; printf x; }) || return 0; o=${o%x}; printf '%s' "${o%$'\n'}"; }   # the x keeps a trailing newline in the name

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  make)
    REPO=.; MAXKB=2048; PATHS=()
    while [ $# -gt 0 ]; do
      case $1 in
        --repo) REPO=${2:?}; shift 2 ;;
        --max-file-kb) MAXKB=${2:?}; shift 2 ;;
        --) shift; PATHS+=("$@"); break ;;
        -*) die "unknown option $1" ;;
        *) PATHS+=("$1"); shift ;;
      esac
    done
    case $MAXKB in ''|*[!0-9]*) die "--max-file-kb needs a number" ;; esac
    [ "${#MAXKB}" -le 7 ] || die "--max-file-kb is too large"
    MAXKB=$((10#$MAXKB))
    SPECS=()
    for p in ${PATHS[@]+"${PATHS[@]}"}; do
      while :; do case $p in ./*) p=${p#./} ;; *) break ;; esac; done
      if [ "$p" = . ]; then PATHS=(); SPECS=(); break; fi    # "." is the whole repository
      case "/$p/" in /../*|*/../*) die "path $p leaves the repository" ;; esac
      case $p in /*|'') die "path $p must be relative" ;; esac
      SPECS+=(":(top,literal)$p")
    done
    TOP=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || die "$REPO is not a git checkout"
    DEST=''; WORK=''; OK=''
    NWANT=${#PATHS[@]}
    # Every exit path (failure, INT, TERM) removes the half-made copy and the work directory; both
    # variables are set before the directories exist, so the trap never sees an unset name.
    cleanup() {
      [ -z "$WORK" ] || { chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf "$WORK" || true; }
      [ -n "$OK" ] || [ -z "$DEST" ] || { chflags -R nouchg "$DEST" 2>/dev/null || true; chmod -R u+rwX "$DEST" 2>/dev/null || true; rm -rf "$DEST" || true; }
    }
    trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    DEST=$(mktemp -d "$TMPBASE/mv-review-copy.XXXXXX") || die "cannot create a copy directory"
    WORK=$(mktemp -d "$TMPBASE/mv-review-work.XXXXXX") || die "cannot create a work directory"
    DESTR=$(canon "$DEST"); WORKR=$(canon "$WORK")
    git -C "$TOP" ls-files -z --cached --others --exclude-standard -- ${SPECS[@]+"${SPECS[@]}"} > "$WORK/all" || die "git ls-files failed"
    : > "$WORK/keep"; : > "$WORK/skipped"; NKEEP=0; LASTD=''; TOPR=$(canon "$TOP")
    PREVF=''
    while IFS= read -r -d '' f; do
      [ "$f" = "$PREVF" ] && continue; PREVF=$f   # a conflicted path is listed once per index stage
      case "$TOP/$f" in "$DESTR"/*|"$WORKR"/*) continue ;; esac   # TMPDIR inside the repository: never copy our own copies
      case "/$f" in */mv-review-copy.*/*|*/mv-review-work.*/*) continue ;; esac   # nor an earlier one
      if [ -d "$TOP/$f" ] && [ ! -L "$TOP/$f" ]; then printf '%s (submodule or nested repository: not copied)\n' "${f//[$'\n\r']/?}" >> "$WORK/skipped"; continue; fi
      if [ ! -f "$TOP/$f" ] || [ -L "$TOP/$f" ]; then continue; fi    # deleted or a symlink: never copied
      if [ ! -r "$TOP/$f" ]; then printf '%s (unreadable)\n' "${f//[$'\n\r']/?}" >> "$WORK/skipped"; continue; fi
      case $f in "$MARK"|"$MARK"/*) printf '%s (reserved name)\n' "$f" >> "$WORK/skipped"; continue ;; esac
      if [ "$(fsize "$TOP/$f")" -gt $((MAXKB * 1024)) ]; then printf '%s\n' "${f//[$'\n\r']/?}" >> "$WORK/skipped"; continue; fi
      # No kept file may sit below a symlinked directory (a checkout whose directory was swapped for a link):
      # check each directory once (git lists a directory's files together), NUL-safe.
      case $f in */*) d=${f%/*}; if [ "$d" != "$LASTD" ]; then
          [ "$(canon "$TOP/$d"; printf x)" = "$TOPR/${d}x" ] || die "refusing: ${d//[$'\n\r']/?} is a symlink or leaves the repository"
          LASTD=$d
        fi ;; esac
      printf '%s\0' "$f" >> "$WORK/keep"; NKEEP=$((NKEEP + 1))
    done < "$WORK/all"
    if [ "$NKEEP" -eq 0 ] && [ "$NWANT" -gt 0 ]; then die "none of the given paths matched a file"; fi
    if [ "$NKEEP" -gt 0 ]; then
      # cpio pass-through, not tar: macOS tar reads a literal ._name file as AppleDouble metadata and drops it
      # (and fails on a big resource fork); cpio -p copies the bytes, NUL-delimited names, modes kept.
      ( cd "$TOP" && COPYFILE_DISABLE=1 cpio -p0dm "$DESTR" < "$WORK/keep" >/dev/null 2>"$WORK/cpio.err" ) || die "copying the files failed: $(head -c 200 "$WORK/cpio.err" 2>/dev/null)"
      GOT=$(find "$DESTR" -type f -print0 | tr -cd '\0' | wc -c | tr -d ' ')
      [ "$GOT" = "$NKEEP" ] || die "incomplete copy: $GOT of $NKEEP files arrived: $(head -c 200 "$WORK/cpio.err" 2>/dev/null)"
    fi
    { printf '%s\n' "$MAGIC"
      if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then printf 'session %s\n' "${CLAUDE_CODE_SESSION_ID//[$'\n\r']/?}"; fi
      printf 'source %s\nmade %s\nfiles %s\n' "$TOP" "$(date +%Y-%m-%dT%H:%M:%S)" "$NKEEP"
      if [ -s "$WORK/skipped" ]; then echo "skipped (over ${MAXKB} KB, reserved or not a file):"; cat "$WORK/skipped"; fi; } > "$DEST/$MARK" || die "cannot write the copy's marker"
    [ -f "$DEST/$MARK" ] && [ ! -L "$DEST/$MARK" ] && [ "$(head -1 "$DEST/$MARK")" = "$MAGIC" ] || die "the copy's marker is not a regular file"
    OK=1
    printf '%s\n' "$DEST"
    ;;
  list)
    D=${1:-$TMPBASE}
    for c in "$D"/mv-review-copy.*; do
      [ -d "$c" ] && [ ! -L "$c" ] && [ -f "$c/$MARK" ] && [ ! -L "$c/$MARK" ] || continue
      printf '%s\t%s\n' "$(du -sk "$c" 2>/dev/null | awk '{print $1}')" "$c"
    done
    ;;
  remove)
    [ $# -gt 0 ] || die "remove needs a directory"
    rc=0
    ROOTS=("$(canon "$TMPBASE")" "$(canon /tmp)")
    for c in "$@"; do
      c=${c%/}
      case ${c##*/} in mv-review-copy.*) ;; *) echo "review-copy: refusing $c (not a copy this script names)" >&2; rc=1; continue ;; esac
      parent=$(canon "$(dirname -- "$c")"); ok=''
      for r in "${ROOTS[@]}"; do [ -n "$r" ] && [ "$parent" = "$r" ] && ok=1; done
      if [ -z "$ok" ]; then echo "review-copy: refusing $c (not directly inside the temp folder)" >&2; rc=1; continue; fi
      if [ -L "$c" ] || [ ! -d "$c" ] || [ -L "$c/$MARK" ] || [ ! -f "$c/$MARK" ] || [ "$(head -1 "$c/$MARK" 2>/dev/null)" != "$MAGIC" ]; then
        echo "review-copy: refusing $c (no valid marker, a symlink or missing)" >&2; rc=1; continue
      fi
      if command -v chflags >/dev/null 2>&1; then chflags -R nouchg "$c" 2>/dev/null || true; fi   # flags first: a locked directory refuses chmod
      chmod -R u+rwX "$c" 2>/dev/null || true
      # everything but the marker first: if this fails half way the marker stays and remove can be run again
      if find "$c" -mindepth 1 -maxdepth 1 ! -name "$MARK" -exec rm -rf {} + 2>/dev/null && rm -f "$c/$MARK" && rmdir "$c" 2>/dev/null; then :
      else echo "review-copy: could not remove $c completely (marker kept, run remove again)" >&2; rc=1; fi
    done
    exit $rc
    ;;
  *) echo "usage: review-copy.sh make [--repo DIR] [--max-file-kb N] [PATH...] | list [DIR] | remove DIR..." >&2; exit 2 ;;
esac
