#!/bin/bash
set -euo pipefail
trap 'exit 0' EXIT
exec 2>/dev/null

helper="$HOME/.megavibe/scripts/scratch-own.sh"
[[ -x "$helper" ]] || exit 0
if [[ "${CLAUDE_CONFIG_DIR:-}" = /* && "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]]; then
  perl -e 'alarm shift; exec @ARGV' 1 "$helper" register-config-dir </dev/null || true
fi

# TMPDIR setup is project-scoped, including projects without an .agent directory.
[[ -n "${CLAUDE_ENV_FILE:-}" && "${MEGAVIBE_SESSION_TMPDIR:-1}" != 0 ]] || exit 0
sid=$(jq -er '.session_id | strings | select(test("\\A[A-Za-z0-9][A-Za-z0-9-]*\\z"))')
perl -e 'alarm shift; exec @ARGV' 3 "$helper" session-tmpdir "$sid"
