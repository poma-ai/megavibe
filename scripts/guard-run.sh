#!/bin/bash
set -euo pipefail

hook=${1:-}
if [ "$#" -gt 0 ]; then shift; fi
name=${hook##*/}
if [[ ! "$name" =~ ^[A-Za-z0-9._-]+\.sh$ || "$name" == *..* ]]; then
  printf 'guard runner: invalid hook name %q\n' "$name" >&2
  exit 2
fi

if [[ -f "$hook" && -x "$hook" ]]; then
  [[ "$hook" == */* ]] || hook="./$hook"
  exec -- "$hook" "$@"
fi

fallback="${MEGAVIBE_HOME:-$HOME/.megavibe}/template/.claude/hooks/$name"
if [[ -f "$fallback" && -x "$fallback" ]]; then
  printf 'guard %s: project copy missing, running the template copy\n' "$name" >&2
  exec -- "$fallback" "$@"
fi
printf 'guard %s: no executable project or template copy found\n' "$name" >&2
exit 2
