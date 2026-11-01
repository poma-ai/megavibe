#!/bin/bash
# /bin/bash tests/claude-auth-check.test.sh
# The login-lifetime check reads a credentials record (the keychain on a Mac, else a
# file; here a fixture through MEGAVIBE_CLAUDE_CREDENTIALS) and warns when the
# refresh token will not outlast the horizon. No secret is ever printed.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/auth-check.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
NOW=1793541600
SECRET="sk-ant-oat01-THISMUSTNEVERBEPRINTED0000000000000000000000"

# creds FILE ACCESS_OFFSET_H REFRESH_OFFSET_H [unit]: a Claude Code credentials record
creds() {
  local a r unit="${4:-ms}"
  a=$(awk -v n="$NOW" -v h="$2" -v u="$unit" 'BEGIN { v = n + h * 3600; printf "%d", (u == "ms" ? v * 1000 : v) }')
  r=$(awk -v n="$NOW" -v h="$3" -v u="$unit" 'BEGIN { v = n + h * 3600; printf "%d", (u == "ms" ? v * 1000 : v) }')
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s","expiresAt":%s,"refreshTokenExpiresAt":%s,"scopes":["user:inference"],"subscriptionType":"max"}}\n' "$SECRET" "$SECRET" "$a" "$r" > "$1"
}
RC=0
run() {   # run FILE [args...]: sets o (output) and RC (exit status), no subshell
  local f="$1"; shift
  o=$(MEGAVIBE_NOW=$NOW MEGAVIBE_CLAUDE_CREDENTIALS="$f" bash "$REPO/scripts/claude-auth-check.sh" "$@" 2>&1); RC=$?
}

creds "$T/ok.json" 4 600
run "$T/ok.json"
check "ok: exit 0" '[ "$RC" = 0 ]'
check "ok: both figures and the horizon ($o)" '[[ "$o" == *"access token 4.0 h, refresh token 600.0 h (ok for the next 12 h)"* ]]'
check "ok: no secret in the output" '[[ "$o" != *"$SECRET"* ]]'
run "$T/ok.json" --quiet
check "ok --quiet: silent" '[ -z "$o" ] && [ "$RC" = 0 ]'

creds "$T/soon.json" 1 5
run "$T/soon.json"
check "refresh in 5 h: exit 1 and the warning ($o)" '[ "$RC" = 1 ] && [[ "$o" == *"REFRESH TOKEN EXPIRES INSIDE 12 h"* ]]'
check "refresh in 5 h: names the remedies" '[[ "$o" == *"/login"* ]] && [[ "$o" == *"setup-token"* ]]'
run "$T/soon.json" 4
check "refresh in 5 h with a 4 h horizon: fine" '[ "$RC" = 0 ] && [[ "$o" == *"(ok for the next 4 h)"* ]]'
run "$T/soon.json" --quiet
check "warning is printed even with --quiet" '[ "$RC" = 1 ] && [ -n "$o" ]'

creds "$T/expired.json" -9 -1
run "$T/expired.json"
check "expired refresh token: exit 1, says EXPIRED ($o)" '[ "$RC" = 1 ] && [[ "$o" == *"REFRESH TOKEN EXPIRED"* ]]'

creds "$T/sec.json" 4 600 s
run "$T/sec.json"
check "epoch seconds read the same as milliseconds" '[ "$RC" = 0 ] && [[ "$o" == *"refresh token 600.0 h"* ]]'

printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":%s}}\n' "$SECRET" "$(( (NOW + 3600) * 1000 ))" > "$T/norefresh.json"
run "$T/norefresh.json"
check "no refresh field: exit 1, n/a ($o)" '[ "$RC" = 1 ] && [[ "$o" == *"refresh token n/a"* ]] && [[ "$o" == *"no refresh token"* ]]'

run "$T/missing.json"
check "missing file: exit 2" '[ "$RC" = 2 ] && [[ "$o" == *"no Claude Code credentials"* ]]'
printf 'not json\n' > "$T/garbage.json"
run "$T/garbage.json"
check "unreadable record: exit 2" '[ "$RC" = 2 ]'
run "$T/ok.json" --bogus
check "unknown argument: exit 2" '[ "$RC" = 2 ]'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
