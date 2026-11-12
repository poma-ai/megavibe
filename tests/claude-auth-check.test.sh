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
SECRET="EXAMPLE-token-value-that-must-never-be-printed-0000"   # EXAMPLE: the leak scanner's placeholder convention

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
check "no refresh field, access token 1 h: exit 1, n/a ($o)" '[ "$RC" = 1 ] && [[ "$o" == *"refresh token n/a"* ]] && [[ "$o" == *"no refresh token recorded and the access token does not outlast 12 h"* ]]'
printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":%s}}\n' "$SECRET" "$(( (NOW + 400 * 3600) * 1000 ))" > "$T/longlived.json"
run "$T/longlived.json"
check "no refresh field, long-lived access token: fine ($o)" '[ "$RC" = 0 ] && [[ "$o" == *"long-lived token"* ]]'
run "$T/ok.json" 1.2.3
check "HOURS must be a number: exit 2" '[ "$RC" = 2 ]'

run "$T/missing.json"
check "missing file: exit 2" '[ "$RC" = 2 ] && [[ "$o" == *"no Claude Code credentials"* ]]'
o=$(CLAUDE_CODE_OAUTH_TOKEN="$SECRET" MEGAVIBE_NOW=$NOW MEGAVIBE_CLAUDE_CREDENTIALS="$T/missing.json" bash "$REPO/scripts/claude-auth-check.sh" 2>&1); RC=$?
check "no record but a token in the environment (setup-token): fine, nothing printed from it ($o)" '[ "$RC" = 0 ] && [[ "$o" == *"long-lived token from the environment"* ]] && [[ "$o" != *"$SECRET"* ]]'
o=$(CLAUDE_CODE_OAUTH_TOKEN="$SECRET" MEGAVIBE_NOW=$NOW MEGAVIBE_CLAUDE_CREDENTIALS="$T/expired.json" bash "$REPO/scripts/claude-auth-check.sh" 2>&1); RC=$?
check "an environment token wins over an expired record" '[ "$RC" = 0 ] && [[ "$o" == *"long-lived token"* ]]'
printf 'not json\n' > "$T/garbage.json"
run "$T/garbage.json"
check "unreadable record: exit 2" '[ "$RC" = 2 ]'
run "$T/ok.json" --bogus
check "unknown argument: exit 2" '[ "$RC" = 2 ]'


# --- `claude auth status` first; a stale stored record is "unknown", never "expired" ---
EMAIL="someone@example.invalid"
# status FILE HOURS_FROM_NOW [loggedIn] [authMethod]
status() {
  local iso
  iso=$(awk -v n="$NOW" -v h="$2" 'BEGIN { printf "%d", n + h * 3600 }')
  iso=$(date -u -r "$iso" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$iso" +%Y-%m-%dT%H:%M:%S.000Z)
  printf '{"loggedIn":%s,"authMethod":"%s","email":"%s","loginExpiresAt":"%s"}\n' "${3:-true}" "${4:-claude.ai}" "$EMAIL" "$iso" > "$1"
}
runs() {   # runs STATUS_FILE CREDS_FILE [args...]
  local st="$1" f="$2"; shift 2
  o=$(MEGAVIBE_NOW=$NOW MEGAVIBE_CLAUDE_AUTH_STATUS="$st" MEGAVIBE_CLAUDE_CREDENTIALS="$f" bash "$REPO/scripts/claude-auth-check.sh" "$@" 2>&1); RC=$?
}
# The reported case: access expiry 0 (read as 1970) and a refresh expiry weeks in the past.
printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s","expiresAt":0,"refreshTokenExpiresAt":%s}}\n' "$SECRET" "$SECRET" "$(( (NOW - 1244 * 3600) * 1000 ))" > "$T/stale.json"
status "$T/st-ok.json" 400
runs "$T/st-ok.json" "$T/stale.json"
check "status valid + stale record: login hours from status, exit 0 ($o)" '[ "$RC" = 0 ] && [[ "$o" == *"login 400.0 h left (claude auth status) (ok for the next 12 h)"* ]] && [[ "$o" != *EXPIRED* ]]'
check "status: no email and no secret printed" '[[ "$o" != *"$EMAIL"* ]] && [[ "$o" != *"$SECRET"* ]]'
runs "$T/st-ok.json" "$T/stale.json" --quiet
check "status ok --quiet: silent" '[ -z "$o" ] && [ "$RC" = 0 ]'
status "$T/st-soon.json" 5
runs "$T/st-soon.json" "$T/ok.json"
check "status login in 5 h: exit 1 and the warning ($o)" '[ "$RC" = 1 ] && [[ "$o" == *"LOGIN EXPIRES INSIDE 12 h"* ]]'
status "$T/st-past.json" -2
runs "$T/st-past.json" "$T/ok.json"
check "status login past: LOGIN EXPIRED" '[ "$RC" = 1 ] && [[ "$o" == *"LOGIN EXPIRED"* ]]'
status "$T/st-out.json" 400 false
runs "$T/st-out.json" "$T/ok.json"
check "status not logged in: exit 1, says so" '[ "$RC" = 1 ] && [[ "$o" == *"not logged in"* ]]'
status "$T/st-api.json" 400 true apiKey
runs "$T/st-api.json" "$T/ok.json"
check "status other auth method: exit 0, no lifetime" '[ "$RC" = 0 ] && [[ "$o" == *"not a claude.ai login"* ]]'
printf 'not json\n' > "$T/st-garbage.json"
runs "$T/st-garbage.json" "$T/ok.json"
check "unusable status: falls back to the stored record ($o)" '[ "$RC" = 0 ] && [[ "$o" == *"refresh token 600.0 h"* ]]'
printf '{"loggedIn":true,"authMethod":"claude.ai"}\n' > "$T/st-noexp.json"
runs "$T/st-noexp.json" "$T/ok.json"
check "logged in without an expiry: unknown, exit 2, record not consulted ($o)" '[ "$RC" = 2 ] && [[ "$o" == *"lifetime unknown"* ]] && [[ "$o" != *"refresh token"* ]]'
runs "$T/st-noexp.json" "$T/stale.json"
check "logged in without an expiry + stale record: never EXPIRED" '[ "$RC" = 2 ] && [[ "$o" != *EXPIRED* ]]'
printf '{"loggedIn":true,"authMethod":"claude.ai","loginExpiresAt":"not a date"}\n' > "$T/st-baddate.json"
runs "$T/st-baddate.json" "$T/stale.json"
check "unparsable expiry + stale record: unknown, never EXPIRED" '[ "$RC" = 2 ] && [[ "$o" != *EXPIRED* ]]'
iso=$(date -u -r "$((NOW + 400 * 3600))" +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null || date -u -d "@$((NOW + 400 * 3600))" +%Y-%m-%dT%H:%M:%S+00:00)
printf '{"loggedIn":true,"authMethod":"claude.ai","loginExpiresAt":"%s"}\n' "$iso" > "$T/st-offset.json"
runs "$T/st-offset.json" "$T/stale.json"
check "a +00:00 offset parses" '[ "$RC" = 0 ] && [[ "$o" == *"login 400.0 h left"* ]]'
printf '{"loggedIn":true,"loginExpiresAt":"%s"}\n' "$iso" > "$T/st-nomethod.json"
runs "$T/st-nomethod.json" "$T/stale.json"
check "no authMethod field: still checked by expiry" '[ "$RC" = 0 ] && [[ "$o" == *"login 400.0 h left"* ]]'
# The real CLI exits 1 when logged out, with valid JSON on stdout: a fake `claude` and a fake
# `security` on PATH, so neither the real login nor the real keychain is touched.
FB="$T/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\nprintf "%%s\\n" "{\\"loggedIn\\":false,\\"authMethod\\":\\"none\\"}"\nexit 1\n' > "$FB/claude"
creds "$T/fake-ok.json" 8 600
printf '#!/bin/sh\ncat "%s"\n' "$T/fake-ok.json" > "$FB/security"
chmod +x "$FB/claude" "$FB/security"
o=$(PATH="$FB:$PATH" HOME="$T/home" MEGAVIBE_NOW=$NOW bash "$REPO/scripts/claude-auth-check.sh" 2>&1); RC=$?
check "real-CLI shape: logged out (exit 1 + JSON) is not logged in, even with a valid stored record ($o)" '[ "$RC" = 1 ] && [[ "$o" == *"not logged in"* ]]'
printf '#!/bin/sh\nexit 1\n' > "$FB/claude"
o=$(PATH="$FB:$PATH" HOME="$T/home" MEGAVIBE_NOW=$NOW bash "$REPO/scripts/claude-auth-check.sh" 2>&1); RC=$?
check "status call gives nothing: stored record answers and says so ($o)" '[ "$RC" = 0 ] && [[ "$o" == *"refresh token 600.0 h"* ]] && [[ "$o" == *"unavailable"* ]]'
printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s","expiresAt":%s,"refreshTokenExpiresAt":0}}\n' "$SECRET" "$SECRET" "$(( (NOW + 3600) * 1000 ))" > "$T/refunk.json"
run "$T/refunk.json"
check "refresh token stored with expiry 0: unknown, exit 2, no re-login alarm ($o)" '[ "$RC" = 2 ] && [[ "$o" == *"expiry is unknown"* ]] && [[ "$o" != *"/login"* ]]'
iso2=$(date -u -r "$((NOW + 400 * 3600 + 7200))" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "@$((NOW + 400 * 3600 + 7200))" +%Y-%m-%dT%H:%M:%S)
printf '{"loggedIn":true,"authMethod":"claude.ai","loginExpiresAt":"%s+02:00"}\n' "$iso2" > "$T/st-plus2.json"
runs "$T/st-plus2.json" "$T/stale.json"
check "a +02:00 offset is applied ($o)" '[ "$RC" = 0 ] && [[ "$o" == *"login 400.0 h left"* ]]'
printf '{"loggedIn":true,"authMethod":"claude.ai","loginExpiresAt":%s}\n' "$(( (NOW + 400 * 3600) * 1000 ))" > "$T/st-num.json"
runs "$T/st-num.json" "$T/stale.json"
check "a numeric epoch in milliseconds is read" '[ "$RC" = 0 ] && [[ "$o" == *"login 400.0 h left"* ]]'
o=$(bash "$REPO/scripts/claude-auth-check.sh" -h 2>&1)
check "help shows the whole header" '[[ "$o" == *"MEGAVIBE_NOW pins the clock"* ]]'
# Without a usable status, a zero or pre-2001 expiry is unknown, never expired.
printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s","expiresAt":0,"refreshTokenExpiresAt":0}}\n' "$SECRET" "$SECRET" > "$T/zero.json"
run "$T/zero.json"
check "record with zero expiries: unknown, exit 2, never EXPIRED ($o)" '[ "$RC" = 2 ] && [[ "$o" == *"lifetime unknown"* ]] && [[ "$o" != *EXPIRED* ]]'
printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s","expiresAt":0,"refreshTokenExpiresAt":%s}}\n' "$SECRET" "$SECRET" "$(( (NOW + 600 * 3600) * 1000 ))" > "$T/acc0.json"
run "$T/acc0.json"
check "record with access 0 and a valid refresh: access n/a, ok" '[ "$RC" = 0 ] && [[ "$o" == *"access token n/a, refresh token 600.0 h"* ]]'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
