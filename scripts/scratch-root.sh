#!/bin/bash
# Megavibe — where Claude Code keeps a session's temp files, for scripts that must find them.
#
#   scratch-root.sh root    $CLAUDE_CODE_TMPDIR/claude-<uid> when that variable names a usable
#                           folder, else the default (/private/tmp/claude-<uid> on macOS,
#                           /tmp/claude-<uid> elsewhere)
#   scratch-root.sh roots   every root worth scanning, one per line: the resolved one, then the
#                           default if different (sessions started before the variable was set
#                           leave their folders there), then safe roots on the project volume
#                           and previously used volumes
#   scratch-root.sh base    the folder holding Claude Code's claude-<hex>-cwd files and the
#                           claude-<uid> root: $CLAUDE_CODE_TMPDIR when usable, else /tmp
#
# Usable means an existing, readable, writable, searchable absolute directory below /.
# An unmounted disk has no folder, so the answer falls back to the default.
# With the variable unset the output is the default and nothing else changes.
set -u

UIDN=$(id -u 2>/dev/null || echo 0)
case "$(uname -s 2>/dev/null)" in Darwin) DEFBASE=/private/tmp ;; *) DEFBASE=/tmp ;; esac

usable() { case "${1:-}" in /*[!/]*) [ -d "$1" ] && [ -r "$1" ] && [ -w "$1" ] && [ -x "$1" ] ;; *) false ;; esac; }
base() { if usable "${CLAUDE_CODE_TMPDIR:-}"; then printf '%s' "${CLAUDE_CODE_TMPDIR%/}"; else printf '%s' /tmp; fi; }
root() { if usable "${CLAUDE_CODE_TMPDIR:-}"; then printf '%s/claude-%s' "${CLAUDE_CODE_TMPDIR%/}" "$UIDN"; else printf '%s/claude-%s' "$DEFBASE" "$UIDN"; fi; }

resolve_volume() {
  local operation=$1 resolver
  shift
  resolver="$(dirname "$0")/scratch-volume.py"
  [[ -f "$resolver" ]] && command -v python3 >/dev/null 2>&1 || return 1
  # A filesystem syscall can delay the resolver's own Python alarm handler.
  python3 - "$resolver" "$operation" "$@" <<'PY'
import contextlib
import os
import signal
import subprocess
import sys

resolver, operation, *args = sys.argv[1:]
command = [sys.executable, resolver, operation, *args]
if operation == "select":
    command = ["/bin/bash", "-c", """
base=$("$@") || exit $?
if [[ -n "$base" ]]; then
  if [[ -d "$base" && ! -L "$base" ]]; then
    printf '%s\n' "$base"
  else
    printf '%s\n' 'megavibe: project-volume scratch disappeared; using default scratch' >&2
    exit 1
  fi
fi
""", "_", *command]
worker = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True)
try:
    out, err = worker.communicate(timeout=3.25)
except subprocess.TimeoutExpired:
    with contextlib.suppress(ProcessLookupError):
        os.killpg(worker.pid, signal.SIGKILL)
    if operation == "select":
        print("megavibe: project-volume scratch selection timed out; using default scratch", file=sys.stderr)
    else:
        print("megavibe: scratch volume discovery timed out", file=sys.stderr)
    sys.exit(124)
sys.stdout.buffer.write(out)
sys.stderr.buffer.write(err)
sys.exit(worker.returncode)
PY
}

case "${1:-root}" in
  root) root; echo ;;
  roots)
    r=$(root)
    if roots=$(resolve_volume discover . "$r" "$DEFBASE/claude-$UIDN"); then
      printf '%s\n' "$roots"
    else
      printf '%s\n' "$r"
      [[ "$r" = "$DEFBASE/claude-$UIDN" ]] || printf '%s\n' "$DEFBASE/claude-$UIDN"
    fi
    ;;
  select-volume) resolve_volume select "$2" ;;
  base) base; echo ;;
  *) echo "usage: scratch-root.sh root|roots|base" >&2; exit 2 ;;
esac
