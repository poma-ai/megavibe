#!/bin/bash
# /bin/bash tests/tick.test.sh
# One watch tick against a fake `gh` (canned JSON per endpoint): the window is exact and
# moves only when the tick marks it; your own and bot activity is left out; people from
# the config are marked; an open review request is listed every tick; auth and gh
# failures are reported, not retried.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/tick.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
NOW=1793544000            # 2026-11-01T14:40:00Z; the default window starts 40 min earlier, 14:00:00Z
mkdir -p "$T/fix" "$T/bin" "$T/mv/personal"

# --- fixtures: times relative to the window --------------------------------
cat > "$T/fix/pulls.json" <<'EOF'
[{"number":7,"title":"fix: the frame keeps its picture","updated_at":"2026-11-01T14:30:00Z","user":{"login":"alice"},"state":"open","draft":false},
 {"number":9,"title":"my own push","updated_at":"2026-11-01T14:20:00Z","user":{"login":"me"},"state":"open","draft":false},
 {"number":10,"title":"bot bump","updated_at":"2026-11-01T14:25:00Z","user":{"login":"linkbot[bot]"},"state":"open","draft":false},
 {"number":8,"title":"old one","updated_at":"2026-11-01T13:00:00Z","user":{"login":"alice"},"state":"closed","draft":false}]
EOF
cat > "$T/fix/reviews7.json" <<'EOF'
[{"user":{"login":"alice"},"state":"APPROVED","submitted_at":"2026-11-01T14:31:00Z","body":"Looks good\nnow"},
 {"user":{"login":"me"},"state":"CHANGES_REQUESTED","submitted_at":"2026-11-01T14:32:00Z","body":"mine"},
 {"user":{"login":"carol"},"state":"COMMENTED","submitted_at":"2026-11-01T13:50:00Z","body":"before the window"}]
EOF
cat > "$T/fix/issues.json" <<'EOF'
[{"user":{"login":"bob"},"created_at":"2026-11-01T14:10:00Z","html_url":"https://example.test/pr/7#c1","body":"Could you look at the P1?"},
 {"user":{"login":"me"},"created_at":"2026-11-01T14:12:00Z","html_url":"https://example.test/pr/7#c2","body":"my own comment"},
 {"user":{"login":"linkbot[bot]"},"created_at":"2026-11-01T14:13:00Z","html_url":"https://example.test/pr/7#c3","body":"<!-- linkback -->"},
 {"user":{"login":"bob"},"created_at":"2026-11-01T13:30:00Z","html_url":"https://example.test/pr/7#c0","body":"too old"}]
EOF
cat > "$T/fix/pullcomments.json" <<'EOF'
[{"user":{"login":"alice"},"created_at":"2026-11-01T14:15:00Z","html_url":"https://example.test/pr/7#r1","body":"line 12: off by one"}]
EOF
cat > "$T/fix/search.json" <<'EOF'
[{"repository":{"nameWithOwner":"org/a"},"number":7,"title":"fix: the frame keeps its picture","updatedAt":"2026-11-01T14:30:00Z"},
 {"repository":{"nameWithOwner":"org/other"},"number":3,"title":"not watched","updatedAt":"2026-11-01T14:30:00Z"}]
EOF
# the fake gh: serves a fixture per endpoint shape; GH_SHIM_FAIL=1 fails the identity call
cat > "$T/bin/gh" <<EOF
#!/bin/bash
FIX="$T/fix"
case "\$*" in
  "api user --jq .login") [ "\${GH_SHIM_FAIL:-0}" = 1 ] && exit 1; echo me ;;
  "search prs "*) cat "\$FIX/search.json" ;;
  "api repos/org/a/pulls?"*) cat "\$FIX/pulls.json" ;;
  "api repos/org/a/pulls/7/reviews") cat "\$FIX/reviews7.json" ;;
  "api repos/org/a/pulls/"*"/reviews") echo '[]' ;;
  "api repos/org/a/issues/comments?"*) cat "\$FIX/issues.json" ;;
  "api repos/org/a/pulls/comments?"*) cat "\$FIX/pullcomments.json" ;;
  *) echo "gh shim: unexpected call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
# credentials fixtures for the auth section (no secret values needed by the check)
creds() { printf '{"claudeAiOauth":{"expiresAt":%s,"refreshTokenExpiresAt":%s}}\n' "$(( (NOW + 4 * 3600) * 1000 ))" "$(( (NOW + $1 * 3600) * 1000 ))" > "$2"; }
creds 600 "$T/creds-ok.json"; creds 2 "$T/creds-soon.json"
printf 'TICK_REPOS="org/a"\nTICK_PEOPLE="alice"\n' > "$T/mv/personal/tick.conf"

tick() {   # tick [args...]: a tick with the fake gh and pinned clock; TICK_NOW, TICK_CREDS, TICK_LINEAR, TICK_BOTS, GH_SHIM_FAIL pass through
  env -i PATH="$PATH" HOME="$T" MEGAVIBE_HOME="$T/mv" MEGAVIBE_NOW="${TICK_NOW:-$NOW}" MEGAVIBE_GH="$T/bin/gh" \
    MEGAVIBE_CLAUDE_CREDENTIALS="${TICK_CREDS:-$T/creds-ok.json}" MEGAVIBE_USAGE_FILE="$T/none.jsonl" MEGAVIBE_CODEX_HOME="$T/nocodex" \
    MEGAVIBE_TICK_CONF="${TICK_CONF:-$T/mv/personal/tick.conf}" TICK_LINEAR="${TICK_LINEAR:-}" TICK_BOTS="${TICK_BOTS:-}" GH_SHIM_FAIL="${GH_SHIM_FAIL:-0}" \
    bash "$REPO/scripts/tick.sh" "$@" 2>&1
}

# --- first tick: the 40-minute default window ------------------------------
o=$(tick)
check "first line: five items need action ($(printf '%s' "$o" | head -1))" '[ "$(printf "%s" "$o" | head -1)" = "tick default: NEEDS ACTION (5) | window 2026-11-01T14:00:00Z..2026-11-01T14:40:00Z" ]'
check "auth line, fine" '[[ "$o" == *"auth: access token 4.0 h, refresh token 600.0 h (ok for the next 12 h)"* ]] && [[ "$o" != *"! auth"* ]]'
check "usage line without readings says so" '[[ "$o" == *"usage: Claude: no reading | Codex: no reading"* ]]'
check "review request listed" '[[ "$o" == *"  RR #7 fix: the frame keeps its picture  (review requested from you)"* ]]'
check "unwatched repo's review request not listed" '[[ "$o" != *"#3"* ]]'
check "PR by a watched person is marked" '[[ "$o" == *"! PR #7 open updated by alice 14:30Z: fix: the frame keeps its picture"* ]]'
check "own PR left out" '[[ "$o" != *"#9"* ]]'
check "bot PR and bot comment left out" '[[ "$o" != *"[bot]"* ]]'
check "PR outside the window left out" '[[ "$o" != *"#8"* ]]'
check "review by a watched person, body on one line" '[[ "$o" == *"! review #7 approved by alice 14:31Z: Looks good now"* ]]'
check "own review and pre-window review left out" '[[ "$o" != *"mine"* ]] && [[ "$o" != *"carol"* ]]'
check "issue comment by someone else, unmarked" '[[ "$o" == *"  comment by bob 14:10Z https://example.test/pr/7#c1: Could you look at the P1?"* ]]'
check "pre-window comment left out" '[[ "$o" != *"too old"* ]]'
check "review comment by a watched person, marked" '[[ "$o" == *"! comment by alice 14:15Z https://example.test/pr/7#r1: line 12: off by one"* ]]'
check "no linear section unless switched on" '[[ "$o" != *"linear"* ]]'
check "the tick marked its window" '[ "$(cat "$T/mv/tick/default.last" 2>/dev/null)" = "$NOW" ]'
check "the gh login was cached" '[ "$(cat "$T/mv/tick/gh-user" 2>/dev/null)" = me ]'

# --- second tick 30 minutes later: window starts where the first one marked --
o=$(TICK_NOW=$((NOW + 1800)) tick)
check "second tick: only the open review request remains ($(printf '%s' "$o" | head -1))" '[ "$(printf "%s" "$o" | head -1)" = "tick default: NEEDS ACTION (1) | window 2026-11-01T14:40:00Z..2026-11-01T15:10:00Z" ]'
check "second tick: nothing repeated" '[[ "$o" != *"PR #7"* ]] && [[ "$o" != *"comment by"* ]]'
check "second tick: marked again" '[ "$(cat "$T/mv/tick/default.last")" = "$((NOW + 1800))" ]'

# --- options ----------------------------------------------------------------
: > "$T/mv/tick/default.last"   # an empty mark reads as a first run: back to the 40-minute window for the option checks
o=$(tick --name dry --no-mark)
check "--no-mark leaves no state" '[ ! -e "$T/mv/tick/dry.last" ] && [[ "$o" == "tick dry: NEEDS ACTION (5)"* ]]'
o=$(tick --no-mark --since 2026-11-01T14:29:00Z)
check "--since ISO narrows the window ($(printf '%s' "$o" | head -1))" '[[ "$o" == "tick default: NEEDS ACTION (3) | window 2026-11-01T14:29:00Z.."* ]] && [[ "$o" != *"comment by bob"* ]]'
o=$(tick --no-mark --since $((NOW - 60)))
check "--since epoch: one minute window, only the review request" '[[ "$o" == "tick default: NEEDS ACTION (1)"* ]]'
o=$(tick --no-mark --since tomorrow)
check "bad --since: exit 2" '[[ "$o" == *"--since takes"* ]]'
o=$(TICK_CREDS="$T/creds-soon.json" tick --no-mark)
check "login about to expire: counted and marked ! ($(printf '%s' "$o" | head -1))" '[[ "$o" == "tick default: NEEDS ACTION (6)"* ]] && [[ "$o" == *"! auth: access token 4.0 h, refresh token 2.0 h -> REFRESH TOKEN EXPIRES INSIDE 12 h"* ]]'
o=$(env -i PATH="$PATH" HOME="$T" MEGAVIBE_GH="$T/nowhere/gh" MEGAVIBE_HOME="$T/mv" MEGAVIBE_NOW=$NOW MEGAVIBE_CLAUDE_CREDENTIALS="$T/creds-ok.json" MEGAVIBE_USAGE_FILE="$T/none.jsonl" MEGAVIBE_CODEX_HOME="$T/nocodex" bash "$REPO/scripts/tick.sh" --no-mark 2>&1)
check "no gh: skipped, quiet" '[[ "$o" == "tick default: quiet"* ]] && [[ "$o" == *"github: gh not installed (skipped)"* ]]'
o=$(TICK_CONF="$T/none.conf" tick --no-mark)
check "no repos anywhere: says so" '[[ "$o" == *"github: no repos configured"* ]]'
o=$(TICK_CONF="$T/none.conf" tick --no-mark org/a)
check "repos from arguments, nobody marked" '[[ "$o" == *"  PR #7 open updated by alice"* ]] && [[ "$o" != *"! PR"* ]]'
mkdir -p "$T/mv2/personal"; cp "$T/mv/personal/tick.conf" "$T/mv2/personal/"
o=$(env -i PATH="$PATH" HOME="$T" GH_SHIM_FAIL=1 MEGAVIBE_HOME="$T/mv2" MEGAVIBE_NOW=$NOW MEGAVIBE_GH="$T/bin/gh" MEGAVIBE_CLAUDE_CREDENTIALS="$T/creds-ok.json" MEGAVIBE_USAGE_FILE="$T/none.jsonl" MEGAVIBE_CODEX_HOME="$T/nocodex" bash "$REPO/scripts/tick.sh" --no-mark 2>&1)
check "gh cannot identify you: reported once, nothing else called ($(printf '%s' "$o" | head -1))" '[[ "$o" == "tick default: NEEDS ACTION (1)"* ]] && [[ "$o" == *"! github: gh cannot reach GitHub as you"* ]] && [[ "$o" != *"PR #7"* ]]'
o=$(TICK_LINEAR=1 tick --no-mark)
check "linear on without a key: skipped" '[[ "$o" == *"linear: no key"* ]]'
o=$(TICK_BOTS=1 tick --no-mark)
check "TICK_BOTS=1 lists bot activity" '[[ "$o" == *"linkbot[bot]"* ]]'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
