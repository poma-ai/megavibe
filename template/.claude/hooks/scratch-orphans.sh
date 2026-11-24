#!/bin/bash
set -euo pipefail
trap 'exit 0' EXIT
exec 2>/dev/null

[[ -d .agent && "${MEGAVIBE_SCRATCH_ORPHAN_HOURS:-24}" != 0 ]] || exit 0
helper="$HOME/.megavibe/scripts/scratch-own.sh"
[[ -x "$helper" ]] || exit 0
sid=$(jq -er 'select((.agent_id // "") == "") |
  .session_id | strings | select(test("\\A[A-Za-z0-9][A-Za-z0-9-]*\\z"))')
perl -e 'alarm shift; exec @ARGV' 6 "$helper" sweep-orphans "$sid"
