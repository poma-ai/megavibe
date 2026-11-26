#!/bin/bash
# Ordinary resumes must not read stdin or spawn any subprocesses.
[ -n "${MEGAVIBE_RESTART_PICKUP:-}" ] || exit 0

# Older installations can lack either dependency. Leave the pickup pending.
[ -f "${MEGAVIBE_HOME:-$HOME/.megavibe}/scripts/restart.sh" ] || exit 0
_restart_start_hook="${BASH_SOURCE[0]%/*}/on-session-start.sh"
[ -f "$_restart_start_hook" ] || exit 0
exec bash "$_restart_start_hook"
