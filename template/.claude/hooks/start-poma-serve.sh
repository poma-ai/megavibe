#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="start-poma-serve.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — keep one warm poma-memory search daemon per machine (idempotent)
# Triggered by: SessionStart (matchers: startup, resume)
#
# Why: every `poma-memory search` reloads the embedding model and re-reads every
# stored embedding — measured 0.52s per call, of which the actual search is under
# 10ms. augment-search.sh fires on every Grep, Glob and shell content-search, and
# an umbrella session (MEGAVIBE_EXTRA_AGENT_DIRS) pays it once per root. With a
# resident daemon the same search is ~30ms.
#
# Nothing else has to change: `poma-memory search` talks to the socket when one
# is there and runs in-process when it is not, so the hooks are identical either
# way and a dead daemon costs correctness nothing — only speed.
#
# ONE daemon per machine, not per session: the db path travels in each request,
# so a single warm process serves every project and every extra .agent root. It
# exits on its own after 30 idle minutes.
#
# Behavior: on by default. Set MEGAVIBE_POMA_SERVE=0 to opt out.
# Find it:  tmux attach -t poma-serve      Kill it: tmux kill-session -t poma-serve
# It logs spawn outcomes to .agent/LOGS/poma-serve-spawn.log

# Only act if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Opt-out gate
[ "${MEGAVIBE_POMA_SERVE:-1}" != "0" ] || exit 0

# Prerequisites: poma-memory with a `serve` subcommand, and tmux. Any missing →
# silent skip; searches then run in-process exactly as they did before.
POMA_BIN=$(command -v poma-memory 2>/dev/null) || exit 0
[ -n "$POMA_BIN" ] || exit 0
command -v tmux &>/dev/null || exit 0
"$POMA_BIN" serve --help >/dev/null 2>&1 || exit 0   # older poma-memory: no serve

TMUX_SESSION="poma-serve"
SPAWN_LOG=".agent/LOGS/poma-serve-spawn.log"
mkdir -p .agent/LOGS 2>/dev/null || true

# Ask the daemon itself, not tmux. `tmux has-session` says nothing about whether
# the process inside it is alive: with `remain-on-exit on` a crashed daemon
# leaves a dead pane in a live session, and has-session would report healthy
# forever. The ping also carries the version, which is the only way to notice
# that an upgraded poma-memory is still being served by a daemon started from
# the old build — a stale daemon answers every request happily with old code.
LIVE_VERSION=""
if command -v python3 &>/dev/null; then
  LIVE_VERSION=$(python3 - <<'PY' 2>/dev/null || true
import json, os, socket, sys
sock = os.environ.get("XDG_RUNTIME_DIR")
sock = os.path.join(sock, "poma-memory.sock") if sock else \
    os.path.join(os.path.expanduser("~"), ".poma-memory", "serve.sock")
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(3)
        s.connect(sock)
        s.sendall(b'{"op": "ping"}\n')
        try:
            s.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    print(json.loads(buf).get("version", ""))
except Exception:
    pass
PY
)
fi

WANT_VERSION=$("$POMA_BIN" --version 2>/dev/null | tr -d '[:space:]')
[ -n "$WANT_VERSION" ] || WANT_VERSION="$LIVE_VERSION"   # no --version: skip the check

if [ -n "$LIVE_VERSION" ]; then
  if [ "$LIVE_VERSION" = "$WANT_VERSION" ]; then
    exit 0                                   # healthy and current
  fi
  # Serving an old build: replace it rather than leave stale behaviour in place.
  echo "$(date -u +%FT%TZ) restarting poma-serve: daemon ${LIVE_VERSION} != installed ${WANT_VERSION}" \
    >> "$SPAWN_LOG" 2>/dev/null || true
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
elif tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  # A session exists but nothing answers on the socket — a dead pane, or a
  # daemon that died mid-start. Clear it so the spawn below can take over.
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
fi

# Not disowned, not nohup'd: a named tmux session is findable and killable, which
# a process reparented to launchd is not. --idle-timeout means it also reaps
# itself when the machine goes quiet.
#
# The absolute path matters: a tmux session inherits the tmux SERVER's
# environment, frozen from whichever shell first started it, which may predate
# this PATH entirely. `command -v` above proves poma-memory is on OUR PATH and
# says nothing about the daemon's, so pass the resolved binary.
if tmux new-session -d -s "$TMUX_SESSION" \
     "'$POMA_BIN' serve --idle-timeout 1800" 2>>"$SPAWN_LOG"; then
  echo "$(date -u +%FT%TZ) spawn ok: $POMA_BIN serve" >> "$SPAWN_LOG" 2>/dev/null || true
else
  echo "$(date -u +%FT%TZ) spawn failed: $POMA_BIN serve" >> "$SPAWN_LOG" 2>/dev/null || true
fi

exit 0
