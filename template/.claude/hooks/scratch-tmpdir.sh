#!/bin/bash
set -euo pipefail
trap 'exit 0' EXIT
exec 2>/dev/null

# Registration is project-scoped, including projects without an .agent directory.
[[ -n "${CLAUDE_ENV_FILE:-}" && "${MEGAVIBE_SESSION_TMPDIR:-1}" != 0 ]] || exit 0
helper="$HOME/.megavibe/scripts/scratch-own.sh"
[[ -x "$helper" ]] || exit 0
sid=$(jq -er '.session_id | strings | select(test("\\A[A-Za-z0-9][A-Za-z0-9-]*\\z"))')
perl -e 'alarm shift; exec @ARGV' 3 "$helper" session-tmpdir "$sid"
