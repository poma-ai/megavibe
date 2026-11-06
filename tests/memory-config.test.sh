#!/bin/bash
# /bin/bash tests/memory-config.test.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
S="$REPO/scripts/memory-config.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/memory-config.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }
run() { HOME="$T/h" "$@" bash "$S" 2>&1; }  # run [env...]: script under the scratch HOME
settings() { mkdir -p "$T/h/.claude"; printf '%s' "$1" > "$T/h/.claude/settings.json"; }

mkdir -p "$T/h"
eq "no settings file prints nothing" "$(run env)" ""
settings '{"env":{"MEGAVIBE_MEMORY_SERVER":"shared","MEGAVIBE_MEMORY_DOCS":"docs.srv","MEGAVIBE_MEMORY_GENERAL":"acme/general"}}'
eq "plain tokens printed" "$(run env)" "$(printf 'MEGAVIBE_MEMORY_SERVER=shared\nMEGAVIBE_MEMORY_DOCS=docs.srv\nMEGAVIBE_MEMORY_GENERAL=acme/general')"
settings '{"env":{"MEGAVIBE_MEMORY_SERVER":"","MEGAVIBE_MEMORY_DOCS":null}}'
eq "empty and null mean unset" "$(run env)" ""
settings '{"env":{"MEGAVIBE_MEMORY_DOCS_ASK":0,"MEGAVIBE_MEMORY_SERVER":"a b","MEGAVIBE_MEMORY_COMPANY":["x"]}}'
eq "non-token and non-string values are INVALID by name" "$(run env | sort)" "$(printf 'INVALID MEGAVIBE_MEMORY_COMPANY\nINVALID MEGAVIBE_MEMORY_DOCS_ASK\nINVALID MEGAVIBE_MEMORY_SERVER')"
settings '{"env":{"MEGAVIBE_MEMORY_SERVER":"line\nbreak"}}'
eq "newline in value is INVALID" "$(run env)" "INVALID MEGAVIBE_MEMORY_SERVER"
settings '{"env":{"UNRELATED":"x"}}'
eq "unrelated keys are not echoed" "$(run env)" ""
settings '{not json'
eq "unreadable settings is UNAVAILABLE" "$(run env)" "UNAVAILABLE (settings.json unreadable)"

# The environment and the project are not sources.
settings '{"env":{}}'
eq "shell env is IGNORED by name only" "$(run env MEGAVIBE_MEMORY_SERVER=evil)" "IGNORED MEGAVIBE_MEMORY_SERVER"
settings '{"env":{"MEGAVIBE_MEMORY_SERVER":"mine"}}'
eq "file value wins over shell env, no IGNORED" "$(run env MEGAVIBE_MEMORY_SERVER=evil)" "MEGAVIBE_MEMORY_SERVER=mine"
mkdir -p "$T/proj/.claude"; printf '%s' '{"env":{"MEGAVIBE_MEMORY_SERVER":"evil"}}' > "$T/proj/.claude/settings.json"
out=$(cd "$T/proj" && HOME="$T/h" CLAUDE_PROJECT_DIR="$T/proj" bash "$S" 2>&1)
eq "project settings and CLAUDE_PROJECT_DIR are not read" "$out" "MEGAVIBE_MEMORY_SERVER=mine"
out=$(HOME="$T/h" MEGAVIBE_MEMORY_SERVER=evil$'\n'injected bash "$S" 2>&1)
eq "env value never reaches output" "$out" "MEGAVIBE_MEMORY_SERVER=mine"
eq "CLAUDE_CONFIG_DIR gives a fixed NOTE" "$(run env CLAUDE_CONFIG_DIR="$T/x" | tail -1)" "NOTE CLAUDE_CONFIG_DIR is set; only the default ~/.claude/settings.json is read"
eq "relative HOME is UNAVAILABLE" "$(HOME=rel bash "$S" 2>&1)" "UNAVAILABLE (cannot resolve the user's home)"
eq "unset HOME is UNAVAILABLE" "$(env -u HOME bash "$S" 2>&1)" "UNAVAILABLE (cannot resolve the user's home)"
eq "always exits 0" "$(HOME=rel bash "$S" >/dev/null 2>&1; echo $?)" "0"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
