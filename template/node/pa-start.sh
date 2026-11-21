#!/bin/bash
# pa-start.sh: the one launcher of the Personal Assistant (PA). Run inside the tmux session
# megavibe-personal, by `megavibe assistant` and by the node (node.sh) alike. Starts a fresh PA through
# the megavibe wrapper that rebuilds from its notes; nothing depends on resuming an old conversation.
# Model: PA_MODEL in the node folder's node.conf (unset: megavibe's own choice); switch with /model
# inside the session.
# MEGAVIBE_NODE_TEST_BIN: tests put stub binaries first on PATH. Nothing else reads it.
# The inherited PATH comes first (a claude under an npm prefix or nvm must stay reachable for
# `megavibe assistant`); the standard directories are only appended, for the LaunchAgent's sparse PATH.
export PATH="${MEGAVIBE_NODE_TEST_BIN:+$MEGAVIBE_NODE_TEST_BIN:}${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
MH="${MEGAVIBE_HOME:-$HOME/.megavibe}"
cd "$MH/personal" || exit 1
PA_MODEL=$(awk 'index($0, "PA_MODEL=") == 1 { v = substr($0, 10) } END { print v }' "$MH/node/node.conf" 2>/dev/null)
if ! [[ $PA_MODEL =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]; then
  PA_MODEL=""
  [ -d "$MH/node" ] && printf '%s node.conf: PA_MODEL has an unusable value; using the default\n' "$(date '+%F %T')" >> "$MH/node/node.log"
fi
# A detached session cannot answer the workspace-trust dialog, so accept it once, the first time only
# (without jq it cannot tell, and runs the preflight every start, as `megavibe assistant` always did).
if ! command -v jq >/dev/null 2>&1 || [ "$(jq -r --arg d "$PWD" '.projects[$d].hasTrustDialogAccepted // false' "$HOME/.claude.json" 2>/dev/null)" != true ]; then
  # Bounded: a preflight that hangs would leave the PA's tmux session alive and never restarted.
  perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or exit 127' 60 claude -p --dangerously-skip-permissions "echo ok" >/dev/null 2>&1 < /dev/null || true
fi
# --no-normalize: the PA runs in its own folder even when $HOME is a git repo (dotfiles); the wrapper
# would otherwise move to that repo root and refuse to run in the home directory.
exec megavibe --no-normalize ${PA_MODEL:+--model "$PA_MODEL"} --name "Personal Assistant" "You were just started fresh (a restart or a first start). Run /rehydrate now, then read megavibe-deliverables/STATUS.md and the newest files in megavibe-deliverables/ if they exist, then tell the user in one line that you are back and what is open."
