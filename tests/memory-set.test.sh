#!/bin/bash
# /bin/bash tests/memory-set.test.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/memory-set.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }
H="$T/h"; mkdir -p "$H/.megavibe/scripts"; cp "$REPO/scripts/memory-config.sh" "$H/.megavibe/scripts/"
F="$H/.claude/settings.json"
mv_() { HOME="$H" bash "$REPO/megavibe" memory "$@" 2>&1; }
val() { jq -r "$1" "$F"; }

mv_ >/dev/null; eq "list on a fresh HOME exits 0" "$?" "0"
mv_ set server shared >/dev/null; eq "set server" "$(val '.env.MEGAVIBE_MEMORY_SERVER')" "shared"
mv_ set DOCS docs.srv >/dev/null; eq "key is case-insensitive" "$(val '.env.MEGAVIBE_MEMORY_DOCS')" "docs.srv"
mv_ set MEGAVIBE_MEMORY_GENERAL acme/general >/dev/null; eq "full key accepted" "$(val '.env.MEGAVIBE_MEMORY_GENERAL')" "acme/general"
mv_ set docs_ask 0 >/dev/null; eq "docs_ask written as a string" "$(val '.env.MEGAVIBE_MEMORY_DOCS_ASK|type')" "string"
eq "what is written is what memory-config.sh trusts" "$(HOME="$H" bash "$H/.megavibe/scripts/memory-config.sh" | LC_ALL=C sort | tr '\n' ' ')" "MEGAVIBE_MEMORY_DOCS=docs.srv MEGAVIBE_MEMORY_DOCS_ASK=0 MEGAVIBE_MEMORY_GENERAL=acme/general MEGAVIBE_MEMORY_SERVER=shared "
mv_ | grep -q 'MEGAVIBE_MEMORY_SERVER=shared'; eq "list shows the active values" "$?" "0"

mv_ set server 'bad value' >/dev/null; eq "refuses a non-token" "$?" "2"
mv_ set docs_ask yes >/dev/null; eq "refuses docs_ask other than 0/1" "$?" "2"
mv_ set server $'ok\nbad value' >/dev/null; eq "refuses a multi-line value" "$?" "2"
mv_ set server $'ok\n' >/dev/null; eq "refuses a trailing newline" "$?" "2"
mv_ set nope x >/dev/null; eq "refuses an unknown key" "$?" "2"
mv_ set server >/dev/null; eq "set without a value is a usage error" "$?" "2"
eq "refusals changed nothing" "$(val '.env.MEGAVIBE_MEMORY_SERVER')" "shared"

mv_ unset server >/dev/null; eq "unset removes the key" "$(val '.env|has("MEGAVIBE_MEMORY_SERVER")')" "false"
eq "other keys survive" "$(val '.env.MEGAVIBE_MEMORY_DOCS')" "docs.srv"

# Existing settings are preserved, and invalid JSON is refused, not replaced.
printf '%s' '{"permissions":{"allow":["Read"]},"env":{"KEEP":"1"}}' > "$F"
mv_ set server s2 >/dev/null
eq "unrelated settings preserved" "$(val '.permissions.allow[0] + .env.KEEP')" "Read1"
printf '%s' '{broken' > "$F"
mv_ set server s3 >/dev/null; eq "invalid JSON refused" "$?" "1"
eq "invalid JSON file untouched" "$(cat "$F")" "{broken"

# A symlinked settings.json stays a symlink and the target gets the write.
printf '%s' '{}' > "$T/dot.json"; ln -sf "$T/dot.json" "$F"
mv_ set server s4 >/dev/null
[ -L "$F" ] && ok || bad "symlink survives"
eq "write reaches the link target" "$(jq -r '.env.MEGAVIBE_MEMORY_SERVER' "$T/dot.json")" "s4"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
