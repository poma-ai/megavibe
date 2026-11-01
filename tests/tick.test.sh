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
 {"number":11,"title":"touched after the cutoff","updated_at":"2026-11-01T14:40:01Z","user":{"login":"carol"},"state":"open","draft":false},
 {"number":8,"title":"old one","updated_at":"2026-11-01T13:00:00Z","user":{"login":"alice"},"state":"closed","draft":false}]
EOF
cat > "$T/fix/reviews7.json" <<'EOF'
[{"user":{"login":"alice"},"state":"APPROVED","submitted_at":"2026-11-01T14:31:00Z","body":"Looks good\nnow"},
 {"user":{"login":"me"},"state":"CHANGES_REQUESTED","submitted_at":"2026-11-01T14:32:00Z","body":"mine"},
 {"user":{"login":"carol"},"state":"COMMENTED","submitted_at":"2026-11-01T13:50:00Z","body":"before the window"}]
EOF
cat > "$T/fix/reviews11.json" <<'EOF'
[{"user":{"login":"alice"},"state":"APPROVED","submitted_at":"2026-11-01T14:30:30Z","body":null}]
EOF
cat > "$T/fix/issues.json" <<'EOF'
[{"user":null,"created_at":"2026-11-01T14:11:00Z","html_url":"https://example.test/pr/7#c9","body":"ghost account"},
{"user":{"login":"bob"},"created_at":"2026-11-01T14:10:00Z","html_url":"https://example.test/pr/7#c1","body":"Could you look at the P1?"},
 {"user":{"login":"bob"},"created_at":"2026-11-01T14:40:00Z","html_url":"https://example.test/pr/7#c4","body":"at the mark: Grüße"},
 {"user":{"login":"bob"},"created_at":"2026-11-01T14:40:01Z","html_url":"https://example.test/pr/7#c5","body":"one second after the mark"},
 {"user":{"login":"me"},"created_at":"2026-11-01T14:12:00Z","html_url":"https://example.test/pr/7#c2","body":"my own comment"},
 {"user":{"login":"linkbot[bot]"},"created_at":"2026-11-01T14:13:00Z","html_url":"https://example.test/pr/7#c3","body":"<!-- linkback -->"},
 {"user":{"login":"bob"},"created_at":"2026-11-01T13:30:00Z","html_url":"https://example.test/pr/7#c0","body":"too old"}]
EOF
cat > "$T/fix/pullcomments.json" <<'EOF'
[{"user":{"login":"alice"},"created_at":"2026-11-01T14:15:00Z","html_url":"https://example.test/pr/7#r1","body":"line 12: off by one"}]
EOF
cat > "$T/fix/search.json" <<'EOF'
[{"repository":{"nameWithOwner":"Org/A"},"number":7,"title":"fix: the frame keeps its picture","updatedAt":"2026-11-01T14:30:00Z"},
 {"repository":{"nameWithOwner":"org/other"},"number":3,"title":"not watched","updatedAt":"2026-11-01T14:30:00Z"}]
EOF
# the fake gh: serves a fixture per endpoint shape. GH_SHIM_FAIL=1 fails the identity call,
# GH_SHIM_FAIL=comments fails the issue-comments call, GH_SHIM_PAGES=1 serves 100 in-window
# PRs on page 1 and the fixture on page 2 (the paging loop must fetch both).
cat > "$T/bin/gh" <<EOF
#!/bin/bash
FIX="$T/fix"
case "\$*" in
  "api user --jq .login") [ "\${GH_SHIM_FAIL:-0}" = 1 ] && exit 1; echo me ;;
  "search prs "*) q=\$(printf '%s\\n' "\$@" | awk 'p{q=q "repo:" \$0 " "; p=0} \$0=="--repo"{p=1} END{print length(q)}'); [ "\$q" -le 256 ] || { echo "gh shim: \$q characters of repo qualifiers" >&2; exit 1; }
    case "\$*" in *"--repo org/a "*) if [ "\${GH_SHIM_RRNUM:-0}" = 1 ]; then echo '[{"repository":{"nameWithOwner":"org/a"},"number":7,"title":12345,"updatedAt":"x"}]'; else cat "\$FIX/search.json"; fi ;; *) echo '[]' ;; esac ;;
  "api repos/org/a/pulls?"*"&page=1")
    if [ "\${GH_SHIM_PAGES:-0}" = 1 ]; then jq -c '[range(100) | {number: (1000 + .), title: "bulk \\(.)", updated_at: "2026-11-01T14:35:00Z", user: {login: "carol"}, state: "open", draft: false}]' -n
    else cat "\$FIX/pulls.json"; fi ;;
  "api repos/org/a/pulls?"*"&page=2") cat "\$FIX/pulls.json" ;;
  "api repos/org/a/pulls/7/reviews?"*) cat "\$FIX/reviews7.json" ;;
  "api repos/org/a/pulls/11/reviews?"*) cat "\$FIX/reviews11.json" ;;
  "api repos/org/a/pulls/"*"/reviews?"*) echo '[]' ;;
  "api repos/org/a/issues/comments?"*"&page=1") [ "\${GH_SHIM_FAIL:-0}" = comments ] && { echo '{"message":"Bad credentials"}'; exit 1; }
    if [ "\${GH_SHIM_MANY:-0}" = 1 ]; then jq -c -n '[range(70) | {user: {login: "bob"}, created_at: "2026-11-01T14:2\\(. % 10):00Z", html_url: "https://example.test/i/\\(.)", body: "bulk comment \\(.)"}]'; else cat "\$FIX/issues.json"; fi ;;
  "api repos/org/a/pulls/comments?"*"&page=1") cat "\$FIX/pullcomments.json" ;;
  "api repos/"*"/pulls?"*|"api repos/"*"/comments?"*|"api repos/"*"/reviews?"*) echo '[]' ;;
  *) echo "gh shim: unexpected call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
cat > "$T/bin/curl" <<EOF
#!/bin/bash
# fake curl: config on stdin (never printed), -w suffix honoured; CURL_SHIM picks the answer
cfg=\$(cat); printf '%s' "\$cfg" > "$T/curl-cfg.last"
case "\${CURL_SHIM:-ok}" in
  ok) printf '{"data":{"viewer":{"id":"u1","name":"Me"},"comments":{"nodes":[{"createdAt":"2026-11-01T14:20:00.123Z","url":"https://linear.test/c1","user":{"id":"u2","name":"Alice A"},"issue":{"identifier":"PRJ-1"},"body":"please check"},{"createdAt":"2026-11-01T14:21:00.000Z","url":"https://linear.test/c2","user":{"id":"u3","name":"Me"},"issue":{"identifier":"PRJ-2"},"body":"same display name, other person"},{"createdAt":"2026-11-01T14:22:00.000Z","url":"https://linear.test/c3","user":{"id":"u1","name":"Me"},"issue":{"identifier":"PRJ-3"},"body":"my own"}]}}}'; printf '\n200' ;;
  errors) printf '{"data":{"comments":{"nodes":[]}},"errors":[{"message":"EXAMPLE-reflected-key-would-be-here"}]}'; printf '\n200' ;;
  http500) printf '{"message":"upstream"}'; printf '\n500' ;;
  exit28) printf '{"data":{"viewer":{"name":"Me"},"comments":{"nodes":[]}}}'; printf '\n200'; exit 28 ;;
esac
EOF
chmod +x "$T/bin/curl"
# credentials fixtures for the auth section (no secret values needed by the check)
creds() { printf '{"claudeAiOauth":{"expiresAt":%s,"refreshTokenExpiresAt":%s}}\n' "$(( (NOW + 4 * 3600) * 1000 ))" "$(( (NOW + $1 * 3600) * 1000 ))" > "$2"; }
creds 600 "$T/creds-ok.json"; creds 2 "$T/creds-soon.json"
printf 'TICK_REPOS="org/a"\nTICK_PEOPLE="alice"\n' > "$T/mv/personal/tick.conf"

tick() {   # tick [args...]: a tick with the fake gh and pinned clock; TICK_NOW, TICK_CREDS, TICK_LINEAR, TICK_BOTS, GH_SHIM_FAIL pass through
  env -i PATH="$PATH" HOME="$T" TMPDIR="${TICK_TMPDIR:-$T}" MEGAVIBE_HOME="$T/mv" MEGAVIBE_NOW="${TICK_NOW:-$NOW}" MEGAVIBE_GH="$T/bin/gh" MEGAVIBE_CURL="$T/bin/curl" LINEAR_API_KEY="${TICK_LKEY:-}" \
    MEGAVIBE_CLAUDE_CREDENTIALS="${TICK_CREDS:-$T/creds-ok.json}" MEGAVIBE_USAGE_FILE="$T/none.jsonl" MEGAVIBE_CODEX_HOME="$T/nocodex" \
    MEGAVIBE_TICK_CONF="${TICK_CONF:-$T/mv/personal/tick.conf}" TICK_LINEAR="${TICK_LINEAR:-}" TICK_BOTS="${TICK_BOTS:-}" GH_SHIM_FAIL="${GH_SHIM_FAIL:-0}" GH_SHIM_PAGES="${GH_SHIM_PAGES:-0}" GH_SHIM_RRNUM="${GH_SHIM_RRNUM:-0}" GH_SHIM_MANY="${GH_SHIM_MANY:-0}" CURL_SHIM="${CURL_SHIM:-ok}" \
    bash "$REPO/scripts/tick.sh" "$@" 2>&1
}

# --- first tick: the 40-minute default window ------------------------------
o=$(tick)
check "first line: eight items need action ($(printf '%s' "$o" | head -1))" '[ "$(printf "%s" "$o" | head -1)" = "tick default: NEEDS ACTION (8) | window 2026-11-01T14:00:00Z..2026-11-01T14:40:00Z" ]'
check "a review inside the window on a PR touched after the cutoff is found; the PR line itself is not" '[[ "$o" == *"! review #11 approved by alice 14:30Z: "* ]] && [[ "$o" != *"PR #11"* ]]'
check "a comment whose account is gone (user null) is listed as such and breaks nothing" '[[ "$o" == *"  comment by (no account) 14:11Z https://example.test/pr/7#c9: ghost account"* ]] && [[ "$o" == *"#c1"* ]]'
check "auth line, fine" '[[ "$o" == *"auth: access token 4.0 h, refresh token 600.0 h (ok for the next 12 h)"* ]] && [[ "$o" != *"! auth"* ]]'
check "usage line without readings says so" '[[ "$o" == *"usage: Claude: no reading | Codex: no reading"* ]]'
check "review request listed" '[[ "$o" == *"  RR #7 fix: the frame keeps its picture  (review requested from you)"* ]]'
check "unwatched repo's review request not listed" '[[ "$o" != *"#3"* ]]'
check "PR by a watched person is marked, author named" '[[ "$o" == *"! PR #7 open (author alice) updated 14:30Z: fix: the frame keeps its picture"* ]]'
check "own PR left out" '[[ "$o" != *"#9"* ]]'
check "comment stamped exactly at the mark belongs to this tick, multibyte intact" '[[ "$o" == *"comment by bob 14:40Z https://example.test/pr/7#c4: at the mark: Grüße"* ]]'
check "comment one second after the mark is not in this window" '[[ "$o" != *"#c5"* ]]'
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
check "second tick: the review request, the one-second-after comment and the PR touched after the cutoff ($(printf '%s' "$o" | head -1))" '[ "$(printf "%s" "$o" | head -1)" = "tick default: NEEDS ACTION (3) | window 2026-11-01T14:40:00Z..2026-11-01T15:10:00Z" ] && [[ "$o" == *"PR #11"* ]]'
check "second tick: the at-the-mark comment is not repeated, the later one appears once" '[[ "$o" != *"#c4"* ]] && [[ "$o" == *"#c5"* ]]'
check "second tick: nothing repeated" '[[ "$o" != *"PR #7"* ]] && [[ "$o" != *"#c1"* ]]'
check "second tick: marked again" '[ "$(cat "$T/mv/tick/default.last")" = "$((NOW + 1800))" ]'

# --- options ----------------------------------------------------------------
rm -f "$T/mv/tick/default.last" "$T/mv/tick/default.pending"   # back to a first-run window for the option checks (an EMPTY mark would now count as corrupt)
o=$(tick --name dry --no-mark)
check "--no-mark leaves no state" '[ ! -e "$T/mv/tick/dry.last" ] && [[ "$o" == "tick dry: NEEDS ACTION (8)"* ]]'
o=$(tick --no-mark --since 2026-11-01T14:29:00Z)
check "--since ISO narrows the window ($(printf '%s' "$o" | head -1))" '[[ "$o" == "tick default: NEEDS ACTION (5) | window 2026-11-01T14:29:00Z.."* ]] && [[ "$o" != *"#c1"* ]]'
o=$(tick --no-mark --since $((NOW - 60)))
check "--since epoch: one minute window, the review request and the at-the-mark comment" '[[ "$o" == "tick default: NEEDS ACTION (2)"* ]]'
o=$(tick --no-mark --since tomorrow)
check "bad --since: exit 2" '[[ "$o" == *"--since takes"* ]]'
o=$(TICK_CREDS="$T/creds-soon.json" tick --no-mark)
check "login about to expire: counted and marked ! ($(printf '%s' "$o" | head -1))" '[[ "$o" == "tick default: NEEDS ACTION (9)"* ]] && [[ "$o" == *"! auth: access token 4.0 h, refresh token 2.0 h -> REFRESH TOKEN EXPIRES INSIDE 12 h"* ]]'
o=$(env -i PATH="$PATH" HOME="$T" MEGAVIBE_GH="$T/nowhere/gh" MEGAVIBE_HOME="$T/mv" MEGAVIBE_NOW=$NOW MEGAVIBE_CLAUDE_CREDENTIALS="$T/creds-ok.json" MEGAVIBE_USAGE_FILE="$T/none.jsonl" MEGAVIBE_CODEX_HOME="$T/nocodex" bash "$REPO/scripts/tick.sh" --no-mark 2>&1)
check "no gh: reported, INCOMPLETE, not quiet" '[[ "$o" == "tick default: NEEDS ACTION (1), INCOMPLETE"* ]] && [[ "$o" == *"! github: gh is not installed"* ]]'
o=$(TICK_CONF="$T/none.conf" tick --no-mark)
check "no repos anywhere and Linear off: nothing to watch is an action item" '[[ "$o" == "tick default: NEEDS ACTION (1) |"* ]] && [[ "$o" == *"! github: nothing to watch"* ]]'
o=$(TICK_CONF="$T/none.conf" tick --no-mark org/a)
check "repos from arguments, nobody marked" '[[ "$o" == *"  PR #7 open (author alice)"* ]] && [[ "$o" != *"! PR"* ]]'
mkdir -p "$T/mv2/personal"; cp "$T/mv/personal/tick.conf" "$T/mv2/personal/"
o=$(env -i PATH="$PATH" HOME="$T" GH_SHIM_FAIL=1 MEGAVIBE_HOME="$T/mv2" MEGAVIBE_NOW=$NOW MEGAVIBE_GH="$T/bin/gh" MEGAVIBE_CLAUDE_CREDENTIALS="$T/creds-ok.json" MEGAVIBE_USAGE_FILE="$T/none.jsonl" MEGAVIBE_CODEX_HOME="$T/nocodex" bash "$REPO/scripts/tick.sh" --no-mark 2>&1)
check "gh cannot identify you: reported once, nothing else called ($(printf '%s' "$o" | head -1))" '[[ "$o" == "tick default: NEEDS ACTION (1)"* ]] && [[ "$o" == *"! github: gh cannot reach GitHub as you"* ]] && [[ "$o" != *"PR #7"* ]]'
rm -f "$T/mv/tick/default.last"
o=$(GH_SHIM_FAIL=comments tick)
check "a failed call: reported, first line INCOMPLETE, the rest still listed ($(printf '%s' "$o" | head -1))" '[[ "$o" == "tick default: NEEDS ACTION (5), INCOMPLETE"* ]] && [[ "$o" == *"incomplete: issues comments org/a (page 1) failed (gh exit 1"* ]] && [[ "$o" == *"PR #7"* ]]'
check "a failed call keeps the window (no mark written) and records its start" '[ ! -s "$T/mv/tick/default.last" ] && [ "$(cat "$T/mv/tick/default.pending")" = "$((NOW - 2400))" ]'
o=$(TICK_NOW=$((NOW + 1800)) tick)
check "the next successful tick starts where the failed one started ($(printf '%s' "$o" | head -1))" '[[ "$o" == "tick default: NEEDS ACTION (10) | window 2026-11-01T14:00:00Z..2026-11-01T15:10:00Z"* ]] && [ "$(cat "$T/mv/tick/default.last")" = "$((NOW + 1800))" ] && [ ! -e "$T/mv/tick/default.pending" ]'
rm -f "$T/mv/tick/default.last"
o=$(TICK_TMPDIR="$T/nowhere" tick)
check "no scratch file possible: nothing checked, INCOMPLETE, no mark ($(printf '%s' "$o" | head -1))" '[[ "$o" == "tick default: NEEDS ACTION (1), INCOMPLETE"* ]] && [[ "$o" == *"no scratch file for failure tracking"* ]] && [[ "$o" != *"PR #7"* ]] && [ ! -s "$T/mv/tick/default.last" ]'
o=$(GH_SHIM_PAGES=1 tick --no-mark --since $((NOW - 2400)))
check "a full first page fetches the second; past 30 PRs the reviews are listed as unchecked, no INCOMPLETE ($(printf '%s' "$o" | head -1))" '[[ "$o" == "tick default: NEEDS ACTION (107) | window"* ]] && [[ "$o" == *"PR #1000"* ]] && [[ "$o" == *"more lines in this repo: see"* ]] && [[ "$o" != *"PR #1099"* ]] && [[ "$o" == *"reviews not checked on 74 more updated PRs: #1030"* ]] && [[ "$o" != *"truncated"* ]]'
o=$(TICK_LINEAR=1 tick --no-mark)
check "linear on without a key: a misconfiguration, INCOMPLETE" '[[ "$o" == *", INCOMPLETE |"* ]] && [[ "$o" == *"! linear: switched on but no key"* ]]'
o=$(TICK_LINEAR=1 TICK_LKEY='EXAMPLE-k"e\y' tick --no-mark --since $((NOW - 2400)))
check "linear comment listed, viewer left out by id, a same-named other person kept, millisecond stamp read" '[[ "$o" == *"  PRJ-1 by Alice A 14:20Z https://linear.test/c1: please check"* ]] && [[ "$o" == *"PRJ-2 by Me 14:21Z"* ]] && [[ "$o" != *"PRJ-3"* ]]'
check "the key reaches curl escaped on stdin, never in argv" '[ "$(cat "$T/curl-cfg.last")" = "header = \"Authorization: EXAMPLE-k\\\"e\\\\y\"" ]'
check "the key is nowhere in the report" '[[ "$o" != *"EXAMPLE-k"* ]]'
for mode in errors http500 exit28; do
  o=$(CURL_SHIM=$mode TICK_LINEAR=1 TICK_LKEY=EXAMPLE-key tick --since $((NOW - 2400)))
  check "linear $mode: INCOMPLETE, fixed diagnostic, no reflected text, no mark" '[[ "$o" == *", INCOMPLETE |"* ]] && [[ "$o" == *"! linear: query failed (curl exit"* ]] && [[ "$o" != *"reflected"* ]] && [ ! -s "$T/mv/tick/default.last" ]'
done
o=$(TICK_BOTS=1 tick --no-mark --since $((NOW - 2400)))
check "TICK_BOTS=1 lists bot activity" '[[ "$o" == *"linkbot[bot]"* ]]'
o=$(tick --no-mark --since $((NOW - 2400)) org/a nodash)
check "a malformed repo name is a reported misconfiguration, the good repo still checked" '[[ "$o" == *", INCOMPLETE |"* ]] && [[ "$o" == *"! github nodash: not of the form org/repo"* ]] && [[ "$o" == *"PR #7"* ]]'

# --- round-4 cases: cut lines keep nothing, state failures, pending vs last, reset, names, search groups --
rm -f "$T/mv/tick/default.last" "$T/mv/tick/default.pending"
o=$(GH_SHIM_MANY=1 tick)
check "70 comments: all counted, 60 lines shown, the rest in the report file, window advanced ($(printf '%s' "$o" | head -1))" '[[ "$o" == "tick default: NEEDS ACTION (75) | window"* ]] && [[ "$o" == *"more lines in this repo: see $T/mv/tick/default.report"* ]] && [ "$(grep -c "bulk comment" "$T/mv/tick/default.report")" = 70 ] && [ "$(cat "$T/mv/tick/default.last")" = "$NOW" ] && [ ! -e "$T/mv/tick/default.pending" ]'
mkdir -p "$T/mv3/personal" "$T/mv3/tick"; cp "$T/mv/personal/tick.conf" "$T/mv3/personal/"; chmod 555 "$T/mv3/tick"
o=$(env -i PATH="$PATH" HOME="$T" TMPDIR="$T" MEGAVIBE_HOME="$T/mv3" MEGAVIBE_NOW=$NOW MEGAVIBE_GH="$T/bin/gh" MEGAVIBE_CLAUDE_CREDENTIALS="$T/creds-ok.json" MEGAVIBE_USAGE_FILE="$T/none.jsonl" MEGAVIBE_CODEX_HOME="$T/nocodex" bash "$REPO/scripts/tick.sh" 2>&1)
chmod 755 "$T/mv3/tick"
check "unwritable state dir: reported, INCOMPLETE, no mark ($(printf '%s' "$o" | head -1))" '[[ "$o" == *", INCOMPLETE |"* ]] && [[ "$o" == *"! state: cannot record the window start"* ]] && [ ! -e "$T/mv3/tick/default.last" ]'
printf '%s\n' "$((NOW - 600))" > "$T/mv/tick/default.last"; printf '%s\n' "$((NOW - 2400))" > "$T/mv/tick/default.pending"
o=$(tick)
check "an older pending start beats a newer mark ($(printf '%s' "$o" | head -1); state: $(ls "$T/mv/tick" | tr '\n' ' '))" '[[ "$o" == *"| window 2026-11-01T14:00:00Z..2026-11-01T14:40:00Z"* ]] && [ ! -e "$T/mv/tick/default.pending" ] && [ "$(cat "$T/mv/tick/default.last")" = "$NOW" ]'
o=$(GH_SHIM_FAIL=comments TICK_NOW=$((NOW + 1800)) tick)
check "a failed tick writes the pending start before polling (the mark stays) ($(printf '%s' "$o" | head -1))" '[ "$(cat "$T/mv/tick/default.pending")" = "$NOW" ] && [ "$(cat "$T/mv/tick/default.last")" = "$NOW" ]'
o=$(TICK_NOW=$((NOW + 3600)) tick --since $((NOW - 2400)))
check "--since never moves the marks" '[ "$(cat "$T/mv/tick/default.pending")" = "$NOW" ] && [ "$(cat "$T/mv/tick/default.last")" = "$NOW" ]'
o=$(TICK_NOW=$((NOW + 100)) tick --reset)
check "--reset abandons the unfinished span ($o)" '[[ "$o" == "tick default: window reset; the next tick starts at 2026-11-01T14:41:40Z" ]] && [ ! -e "$T/mv/tick/default.pending" ] && [ "$(cat "$T/mv/tick/default.last")" = "$((NOW + 100))" ]'
o=$(tick --name "my proj" --no-mark --since $((NOW - 2400)))
check "a name with a space is sanitised, not replaced by default" '[[ "$o" == "tick my_proj: "* ]]'
o=$(GH_SHIM_RRNUM=1 tick --no-mark --since $((NOW - 2400)))
check "a review-request row with a numeric title is still listed" '[[ "$o" != *"INCOMPLETE"* ]] && [[ "$o" == *"RR #7 12345  (review requested from you)"* ]]'
o=$(tick --no-mark --since $((NOW - 2400)) org/a org/b org/c org/d org/e org/f org/g org/h org/i org/j org/k org/l)
check "twelve repos: the review-request search runs in groups of five, nothing incomplete ($(printf '%s' "$o" | head -1))" '[[ "$o" != *"INCOMPLETE"* ]] && [[ "$o" == *"RR #7"* ]] && [[ "$o" == *"github org/l: nothing new"* ]]'
o=$(tick --no-mark --since $((NOW - 2400)) 2>&1 >/dev/null)
check "no shell errors on stderr" '[ -z "$o" ]'
# round-5 cases: unreadable state, long repo names, dry-run report, missing operands
printf '%s\n' "$((NOW - 7200))" > "$T/mv/tick/default.last"; chmod 000 "$T/mv/tick/default.last"
o=$(tick)
chmod 644 "$T/mv/tick/default.last"
check "an unreadable mark: reported, INCOMPLETE, nothing marked ($(printf '%s' "$o" | head -1))" '[[ "$o" == *", INCOMPLETE |"* ]] && [[ "$o" == *"! state: cannot read $T/mv/tick/default.last"* ]] && [ "$(cat "$T/mv/tick/default.last")" = "$((NOW - 7200))" ] && [ ! -e "$T/mv/tick/default.pending" ]'
printf 'garbage\n' > "$T/mv/tick/default.last"
o=$(tick)
check "a corrupt mark: reported, nothing marked" '[[ "$o" == *"! state: cannot read"* ]] && [ "$(cat "$T/mv/tick/default.last")" = garbage ]'
rm -f "$T/mv/tick/default.last"
long=""; for i in 1 2 3 4 5 6; do long="$long org/a-very-long-repository-name-number-$i-with-many-characters-in-it"; done
o=$(tick --no-mark --since $((NOW - 2400)) org/a $long)
check "long repository names: the search is split by query length, nothing incomplete ($(printf '%s' "$o" | head -1))" '[[ "$o" != *"INCOMPLETE"* ]] && [[ "$o" == *"RR #7"* ]]'
o=$(GH_SHIM_MANY=1 tick --no-mark --since $((NOW - 2400)))
check "a dry run with cut lines still writes the report it points at" '[[ "$o" == *"more lines in this repo: see $T/mv/tick/default.report"* ]] && [ "$(grep -c "bulk comment" "$T/mv/tick/default.report")" = 70 ]'
o=$(tick --name 2>&1); rc=$?
check "a missing option value is refused" '[[ "$o" == *"--name needs a value"* ]]'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
