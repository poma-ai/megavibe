#!/bin/bash
set -euo pipefail
trap 'exit 0' EXIT

[[ -d .agent ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v perl >/dev/null 2>&1 || exit 0
helper="$HOME/.megavibe/scripts/scratch-own.sh"
[[ -x "$helper" ]] || exit 0
sid=$(jq -er '.session_id | select(type == "string" and test("\\A[A-Za-z0-9-]+\\z"))' 2>/dev/null) || exit 0

# Keep shutdown bounded even when a scratch volume stops responding.
{ perl -e 'alarm shift; exec @ARGV' 8 "$helper" clean-end "$sid" >&3 || true; } 3>&2 2>/dev/null
