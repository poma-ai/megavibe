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
# Usable means an existing, writable, absolute directory. An unmounted disk has no folder, so
# the answer falls back to today's paths rather than a stray folder on the boot disk.
# With the variable unset the output is the default and nothing else changes.
set -u

UIDN=$(id -u 2>/dev/null || echo 0)
case "$(uname -s 2>/dev/null)" in Darwin) DEFBASE=/private/tmp ;; *) DEFBASE=/tmp ;; esac

usable() { case "${1:-}" in /*) [ -d "$1" ] && [ -w "$1" ] ;; *) false ;; esac; }
base() { if usable "${CLAUDE_CODE_TMPDIR:-}"; then printf '%s' "${CLAUDE_CODE_TMPDIR%/}"; else printf '%s' /tmp; fi; }
root() { if usable "${CLAUDE_CODE_TMPDIR:-}"; then printf '%s/claude-%s' "${CLAUDE_CODE_TMPDIR%/}" "$UIDN"; else printf '%s/claude-%s' "$DEFBASE" "$UIDN"; fi; }

case "${1:-root}" in
  root) root; echo ;;
  roots)
    r=$(root)
    resolver="$(dirname "$0")/scratch-volume.py"
    if [[ -f "$resolver" ]] && command -v python3 >/dev/null 2>&1; then
      exec python3 "$resolver" discover . "$r" "$DEFBASE/claude-$UIDN"
    fi
    printf '%s\n' "$r"
    [[ "$r" = "$DEFBASE/claude-$UIDN" ]] || printf '%s\n' "$DEFBASE/claude-$UIDN"
    ;;
  base) base; echo ;;
  *) echo "usage: scratch-root.sh root|roots|base" >&2; exit 2 ;;
esac
