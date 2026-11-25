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

if [[ "$hook" == /* && "$hook" == */.claude/hooks/"$name" && ${MEGAVIBE_ALLOW_MISSING_LAUNCH:-} != 1 ]]; then
  project_root=${hook%/.claude/hooks/"$name"}
  if [[ ! -d "$project_root/.claude/hooks" ]]; then
    printf '%s\n' 'launch directory or its .claude is gone: finish and exit this session; the guards cannot be trusted here; start a new session from a project directory' >&2
    exit 2
  fi
fi

fallback="${MEGAVIBE_HOME:-$HOME/.megavibe}/template/.claude/hooks/$name"
if [[ -f "$fallback" && -x "$fallback" ]]; then
  printf 'guard %s: project copy missing, running the template copy\n' "$name" >&2
  exec -- "$fallback" "$@"
fi
printf 'guard %s: no executable project or template copy found\n' "$name" >&2
exit 2
