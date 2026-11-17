#!/bin/bash
# /bin/bash tests/repo-id.test.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
S="$REPO/scripts/repo-id.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/repo-id.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
mkdir -p "$T/h"
R="$T/r"; git init -q "$R"
id_of() { HOME="$T/h" bash "$S" "$R" 2>/dev/null; echo "rc=$?"; }
setremote() { git -C "$R" remote remove "$1" 2>/dev/null; git -C "$R" remote add "$1" "$2"; }
want() { # want <origin url> <expected id | exit1>
  setremote origin "$1"
  local got; got=$(id_of)
  if [ "$2" = exit1 ]; then [ "$got" = "rc=1" ] && ok || bad "$1 -> [$got] want exit 1"
  else [ "$got" = "$(printf '%s\nrc=0' "$2")" ] && ok || bad "$1 -> [$got] want $2"; fi
}

for u in 'user@github.com:Acme/Api.git' 'user@github.com:acme/api' 'https://github.com/Acme/Api.git' 'https://github.com/acme/api/' \
         'https://github.com/acme/api.git/' 'ssh://user@github.com/acme/api.git' 'ssh://user@host:2222/acme/api.git' \
         'https://user:pw@host:8443/acme/api' 'git://github.com/acme/api.git' 'host:acme/api' 'user@host:acme/api' 'https://[::1]/acme/api'; do
  want "$u" acme/api
done
for u in 'https://gitlab.com/grp/sub/api' 'https://dev.azure.com/o/p/_git/r' 'C:org/name' 'c:org/name' 'C:/org/name' 'C:\org\name' 'x:org/name' \
         'file:///a/b' '/a/b' './a/b' '../a/b' 'org/name' 'https://h/org_x/api' 'https://h/org.x/api' 'https://h/acme/api?x=1' \
         'https://h/acme/..' 'https://h/acme/.' 'https://h/%61cme/api' 'https://h/acme/ap i' 'https://h/ａcme/api' 'https://h/acme/api;id'; do
  want "$u" exit1
done

# No remote, and upstream beats origin.
git -C "$R" remote remove origin; [ "$(id_of)" = "rc=1" ] && ok || bad "no remote exits 1"
setremote origin 'https://github.com/fork/api'; setremote upstream 'https://github.com/acme/api'
[ "$(id_of)" = "$(printf 'acme/api\nrc=0')" ] && ok || bad "upstream beats origin"
git -C "$R" remote remove upstream

# Reserved shared labels: a repo with the same id as a shared scope gets none.
mkdir -p "$T/h/.claude"; printf '%s' '{"env":{"MEGAVIBE_MEMORY_GENERAL":"Acme/Api.git","MEGAVIBE_MEMORY_COMPANY":"acme/co"}}' > "$T/h/.claude/settings.json"
setremote origin 'https://github.com/acme/api'; [ "$(id_of)" = "rc=1" ] && ok || bad "reserved general label (padded/upper/.git) exits 1"
setremote origin 'https://github.com/acme/other'; [ "$(id_of)" = "$(printf 'acme/other\nrc=0')" ] && ok || bad "non-reserved id passes"

# Without memory-config.sh beside it the guard cannot run: exit 1, no output.
mkdir -p "$T/solo"; cp "$S" "$T/solo/repo-id.sh"
out=$(HOME="$T/h" bash "$T/solo/repo-id.sh" "$R" 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "missing sidecar exits 1 with empty output"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
