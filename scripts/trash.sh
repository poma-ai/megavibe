#!/bin/bash
# rm-compatible front end to the Trash that records what went where.
#
# rm-to-trash.sh rewrites `rm` to this script when it is installed. Same flags as
# rm; trash-review.py `trash` renames each operand into the Trash as
# "<name> mv-<id>" and writes a ledger line per item (original path, that exact
# Trash entry, its inode), which the trash-watch.sh hook reads to ask the user what
# to do with it. Options it does not handle (-i, -I, -x, ...), a missing python3,
# or no Trash directory go to rmtrash unrecorded: the delete still lands in the
# Trash, it just cannot be reviewed from the ledger.
set -u

REVIEW="$(cd "$(dirname "$0")" && pwd)/trash-review.py"
if command -v python3 &>/dev/null && [[ -f "$REVIEW" ]]; then
  python3 "$REVIEW" trash "$@"
  rc=$?
  # 3: not handled, nothing touched. 126/127 and signals: python3 itself is broken (a pyenv
  # shim naming an uninstalled version) or was killed; rmtrash then does what is left, and an
  # operand already moved simply no longer exists. Every other status is rm's own answer.
  [[ $rc -eq 3 || $rc -eq 126 || $rc -eq 127 || $rc -gt 128 ]] || exit "$rc"
fi

RMTRASH=$(command -v rmtrash 2>/dev/null || true)
if [[ -z "$RMTRASH" ]]; then
  echo "trash.sh: rmtrash is not installed; refusing to delete (brew install rmtrash)" >&2
  exit 1
fi
exec "$RMTRASH" "$@"
