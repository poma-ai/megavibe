#!/bin/bash
# /bin/bash tests/update-summary.test.sh
# The update note: a bounded Haiku summary made at update time, kept in ONE record
# with the commit list, shown once as a SessionStart systemMessage by
# announce-update.sh, with commit subjects as the fallback; and the launcher no
# longer types a first prompt for the user.
# The real `claude` is never reachable here: PATH is a stub directory plus /usr/bin:/bin.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$REPO/template/.claude/hooks/announce-update.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/update-summary.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }

SYS="/usr/bin:/bin"
if PATH="$SYS" command -v claude >/dev/null 2>&1; then
  echo "refusing to run: a real claude is on $SYS" >&2; exit 2
fi
for tool in git jq perl awk; do
  PATH="$SYS" command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool missing" >&2; exit 0; }
done
REAL_MV=$(PATH="$SYS" command -v mv); export REAL_MV

H="$T/home/.megavibe"; mkdir -p "$H"
CL="$H/.update-changelog"
export ANTHROPIC_API_KEY=fake-key-1234
unset MEGAVIBE_UPDATE_SUMMARY MEGAVIBE_UPDATE_SUMMARY_TIMEOUT

# --- stubs -------------------------------------------------------------------
# ok: records how it was called, answers like `claude -p --output-format json`.
# slow: sleeps past the bound. fail: exits 1. noisy: control characters, C1 controls,
# too many lines. The rest are answers that must not pass for a note.
mkdir -p "$T/ok" "$T/slow" "$T/fail" "$T/noisy" "$T/none" "$T/login" "$T/iserr" "$T/errres" "$T/array" "$T/session"
cat > "$T/ok/claude" <<'STUB'
#!/bin/bash
{ echo "ARGS: $*"; echo "CWD: $(pwd)"; echo "AGENT_HERE: $([ -e .agent ] && echo yes || echo no)"
  echo "KEY: ${ANTHROPIC_API_KEY:-unset}"; echo "STDIN<<"; cat; echo ">>"; } >> "$STUB_LOG"
printf '{"type":"result","subtype":"success","is_error":false,"result":"Hooks now sync on every launch.\\nThe update note no longer types a prompt for you.","session_id":"x"}\n'
STUB
cat > "$T/slow/claude" <<'STUB'
#!/bin/bash
echo $$ > "$STUB_LOG.pid1"
sleep 60 &
echo $! > "$STUB_LOG.pid2"
wait
STUB
cat > "$T/fail/claude" <<'STUB'
#!/bin/bash
echo '{"type":"result","is_error":false,"result":"partial output that must not be used"}'
exit 1
STUB
cat > "$T/noisy/claude" <<'STUB'
#!/bin/bash
cat > /dev/null
r=$(printf '\n\nFirst line \033[31mred\033[0m \302\233csi \302\205nel and more text here.\n'; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "line $i of a long answer"; done)
jq -n --arg r "$r" '{type:"result",subtype:"success",is_error:false,result:$r}'
STUB
cat > "$T/login/claude" <<'STUB'
#!/bin/bash
cat > /dev/null
echo "Invalid API key - Please run /login"
STUB
cat > "$T/iserr/claude" <<'STUB'
#!/bin/bash
cat > /dev/null
echo '{"type":"result","subtype":"success","is_error":true,"result":"The model is overloaded right now, please retry in a few minutes."}'
STUB
cat > "$T/errres/claude" <<'STUB'
#!/bin/bash
cat > /dev/null
echo '{"type":"result","subtype":"success","is_error":false,"result":"Invalid API key · Please run /login"}'
STUB
cat > "$T/array/claude" <<'STUB'
#!/bin/bash
cat > /dev/null
echo '[{"type":"system","subtype":"init"},{"type":"assistant","message":"x"},{"type":"result","subtype":"success","is_error":false,"result":"Older builds answer with an array of messages."}]'
STUB
# session: a claude whose "thinking" is interleaved with a SessionStart in another
# terminal -- it runs the announce hook while the updater waits on it.
cat > "$T/session/claude" <<'STUB'
#!/bin/bash
cat >> "$STUB_LOG"
mkdir -p "$SESSION_PROJ/.agent"
( cd "$SESSION_PROJ" && env PATH="/usr/bin:/bin" HOME="$SESSION_HOME" MEGAVIBE_HOME="$SESSION_MVH" bash "$SESSION_HOOK" ) > "$STUB_LOG.session" 2>/dev/null
echo '{"type":"result","subtype":"success","is_error":false,"result":"Summary written while another session started."}'
STUB
chmod +x "$T"/ok/claude "$T"/slow/claude "$T"/fail/claude "$T"/noisy/claude "$T"/login/claude "$T"/iserr/claude "$T"/errres/claude "$T"/array/claude "$T"/session/claude

# mv wrappers that interleave another actor at a chosen moment.
mkdir -p "$T/mvnewer" "$T/mvfail"
# After the hook claims the pending record, a newer record is published at once.
cat > "$T/mvnewer/mv" <<'STUB'
#!/bin/bash
"$REAL_MV" "$@" || exit $?
case "$*" in *.update-changelog.claimed.*) cp "$NEWER" "$NEWER_DEST" ;; esac
STUB
# The final publish of the new record fails.
cat > "$T/mvfail/mv" <<'STUB'
#!/bin/bash
case "$*" in *.update-changelog.tmp.*) exit 1 ;; esac
exec "$REAL_MV" "$@"
STUB
chmod +x "$T/mvnewer/mv" "$T/mvfail/mv"

# --- a source repo with commits ----------------------------------------------
SRC="$T/src"; mkdir -p "$SRC/template" && touch "$SRC/setup.sh"
git -C "$SRC" init -q -b main
git -C "$SRC" config user.email t@example.com; git -C "$SRC" config user.name t
commit() {  # commit <subject> [body]
  echo "$1" >> "$SRC/template/f.txt"; git -C "$SRC" add -A
  if [ -n "${2:-}" ]; then git -C "$SRC" commit -q -m "$1" -m "$2" 2>/dev/null; else git -C "$SRC" commit -q -m "$1" 2>/dev/null; fi
}
commit "base commit"
BASE=$(git -C "$SRC" rev-parse HEAD)
commit "Hooks sync on every launch" "The launcher now re-syncs hooks before it starts claude.

Co-authored-by: megavibe <megavibe@example.com>
Claude-Session: https://claude.ai/code/session_SECRETTRAILER"
commit "Update note is a message, not a typed prompt"
commit "Fix quoting in the restart path"
HEAD1=$(git -C "$SRC" rev-parse HEAD)
h8() { printf '%s' "$1" | cut -c1-8; }

# --- harness: the launcher's own functions, run as the launcher runs them ---------
FUNCS="is_git_source strip_controls run_bounded condense_commits summarize_update git_commit_detail restore_changelog_claim restore_orphan_changelog collect_changelog"
HAR="$T/harness.sh"
{
  echo 'set -euo pipefail'
  echo "MEGAVIBE_HOME='$H'; CHANGELOG_FILE='$CL'; GITHUB_REPO=x/y"
  echo "BOLD=; YELLOW=; GREEN=; RED=; DIM=; RESET=; UPDATE_SUMMARY_TEXT=; UPDATE_SUMMARY_LINES=0"
  for fn in $FUNCS; do
    sed -n "/^$fn() {/,/^}/p" "$REPO/megavibe"
  done
  echo 'collect_changelog "$@"'
} > "$HAR"
bash -n "$HAR" || { echo "harness did not extract" >&2; exit 2; }
HAR2="$T/harness2.sh"   # run_bounded alone
{ echo 'set -euo pipefail'; sed -n '/^run_bounded() {/,/^}/p' "$REPO/megavibe"; echo 'run_bounded "$@"'; } > "$HAR2"

collect() {  # collect <stubdir> <old> <new> [env assignments...]; stub log in $T/log
  local d="$1" old="$2" new="$3"; shift 3
  rm -f "$T/log" "$T/log.pid1" "$T/log.pid2" "$T/log.session"
  env PATH="$d:$SYS" HOME="$T/home" STUB_LOG="$T/log" "$@" bash "$HAR" "${COLLECT_SRC:-$SRC}" "$old" "$new" >"$T/collect.out" 2>&1
}
announce() {  # announce [dir]: run the hook in a megavibe project, print its stdout
  local p="${1:-$T/proj}"; mkdir -p "$p/.agent"
  ( cd "$p" && env PATH="${ANNOUNCE_PATH:-$SYS}" HOME="$T/home" MEGAVIBE_HOME="$H" "${ANNOUNCE_ENV:-X=1}" bash "$HOOK" 2>/dev/null )
}
reset() { rm -f "$H"/.update-* ; }
note() {  # the stored note: the k lines after "summary: k"
  local k; k=$(sed -n '2s/^summary: //p' "$CL"); [ "${k:-0}" -gt 0 ] && sed -n "3,$((k + 2))p" "$CL"
}
age() {  # age <file> <seconds>: set mtime that far in the past
  perl -e 'my $t = time - $ARGV[1]; utime($t, $t, $ARGV[0])' "$1" "$2"
}
mkrecord() {  # mkrecord <file> <old8> <new8> <count> <note-or-empty> <subject...>
  local f="$1" o="$2" n="$3" c="$4" nt="$5"; shift 5
  { printf 'megavibe updated: %s -> %s (%s commits)\n' "$o" "$n" "$c"
    if [ -n "$nt" ]; then printf 'summary: 1\n%s\n' "$nt"; else printf 'summary: 0\n'; fi
    printf '\nCommits:\n'; for s in "$@"; do printf '%s\n' "$s"; done; } > "$f"
}

# 1. Summary generated, stored in the one record, and the claude call is the bounded no-tools shape.
reset; collect "$T/ok" "$BASE" "$HEAD1"; rc=$?
NEW8=$(h8 "$HEAD1")
check "collect_changelog exits 0" '[ $rc = 0 ]'
check "one record, no second file" '[ -f "$CL" ] && [ "$(ls -A "$H" | wc -l | tr -d " ")" = 1 ]'
check "line 1 names the range, line 2 counts the note" 'head -n 1 "$CL" | grep -q "^megavibe updated: $(h8 "$BASE") -> $NEW8 (3 commits)" && [ "$(sed -n 2p "$CL")" = "summary: 2" ]'
check "the note is the model output" '[ "$(note | head -n 1)" = "Hooks now sync on every launch." ]'
check "the commit list follows the note" '[ -z "$(sed -n 5p "$CL")" ] && [ "$(sed -n 6p "$CL")" = "Commits:" ] && sed -n 7p "$CL" | grep -q "Fix quoting in the restart path"'
check "one claude call" '[ "$(grep -c "^ARGS:" "$T/log")" = 1 ]'
check "print mode, haiku, json, no tools" 'grep -q "^ARGS: -p --model haiku --output-format json --tools  --no-session-persistence" "$T/log"'
check "no skills, no MCP, no settings sources" 'a=$(grep "^ARGS:" "$T/log"); case "$a" in *--disable-slash-commands*--strict-mcp-config*--setting-sources*) true ;; *) false ;; esac'
check "runs from a scratch directory with no .agent" 'grep -q "^AGENT_HERE: no" "$T/log" && ! grep "^CWD:" "$T/log" | grep -q "$REPO"'
check "API key masked for the call" 'grep -q "^KEY: unset" "$T/log"'
check "prompt carries the commit subjects and bodies" 'grep -q "Hooks sync on every launch" "$T/log" && grep -q "re-syncs hooks before it starts claude" "$T/log"'
check "prompt drops the attribution trailers" '! grep -q "SECRETTRAILER\|Co-authored-by" "$T/log"'
check "prompt tells the model the log is data" 'grep -q "DATA copied from commit messages" "$T/log"'
check "launcher says a note is coming, not that Claude will summarise" 'grep -q "short note on what changed" "$T/collect.out" && ! grep -qi "claude will summari" "$T/collect.out"'

# 2. The hook shows it once, as a systemMessage only.
out=$(announce)
check "hook prints one JSON object" 'printf "%s" "$out" | jq -e . >/dev/null'
check "systemMessage carries the summary and the count" 'printf "%s" "$out" | jq -r .systemMessage | grep -q "megavibe updated (3 commits)" && printf "%s" "$out" | jq -r .systemMessage | grep -q "The update note no longer types a prompt for you."'
check "nothing is handed to the model" '[ "$(printf "%s" "$out" | jq -r "keys | join(\",\")")" = systemMessage ]'
check "the commit list stays out of a message that has a note" '! printf "%s" "$out" | jq -r .systemMessage | grep -q "^- "'
check "claimed: the record and its claim are gone" '[ ! -e "$CL" ] && ! ls "$H"/.update-changelog.* >/dev/null 2>&1'
out2=$(announce)
check "second session: silent" '[ -z "$out2" ]'

# 3. Nothing changed: no record, no message, no claude call.
reset; collect "$T/ok" "$HEAD1" "$HEAD1"; rc=$?
check "same version: exit 0" '[ $rc = 0 ]'
check "same version: no record, no claude call" '[ ! -e "$CL" ] && [ ! -e "$T/log" ]'
check "same version: hook silent" '[ -z "$(announce)" ]'

# 4. claude fails: no note, launch path still 0, hook falls back to subjects.
reset; collect "$T/fail" "$BASE" "$HEAD1"; rc=$?
check "failing claude: exit 0" '[ $rc = 0 ]'
check "failing claude: record written with summary: 0, partial output not used" '[ -f "$CL" ] && [ "$(sed -n 2p "$CL")" = "summary: 0" ] && ! grep -q "partial output" "$CL"'
out=$(announce)
msg=$(printf "%s" "$out" | jq -r .systemMessage)
check "fallback names the update" 'printf "%s" "$msg" | head -n 1 | grep -q "^megavibe updated (3 commits)"'
check "fallback lists the commit subjects" 'printf "%s" "$msg" | grep -q "^- Hooks sync on every launch" && printf "%s" "$msg" | grep -q "^- Fix quoting in the restart path"'
check "fallback does not leak the base commit" '! printf "%s" "$msg" | grep -q "base commit"'
check "fallback shown once" '[ -z "$(announce)" ] && [ ! -e "$CL" ]'

# 5. claude hangs: the bound holds, the whole process group dies, launch path still 0.
reset
start=$SECONDS
collect "$T/slow" "$BASE" "$HEAD1" MEGAVIBE_UPDATE_SUMMARY_TIMEOUT=2; rc=$?
took=$((SECONDS - start))
check "timeout: exit 0" '[ $rc = 0 ]'
check "timeout: returned within the bound (took ${took}s)" '[ "$took" -lt 12 ]'
check "timeout: record published without a note" '[ -f "$CL" ] && [ "$(sed -n 2p "$CL")" = "summary: 0" ]'
sleep 1
p1=$(cat "$T/log.pid1" 2>/dev/null || echo 0); p2=$(cat "$T/log.pid2" 2>/dev/null || echo 0)
check "timeout: the stub and its child are gone" '! kill -0 "$p1" 2>/dev/null && ! kill -0 "$p2" 2>/dev/null && [ "$p1" != 0 ] && [ "$p2" != 0 ]'
check "timeout: hook falls back to subjects" 'announce | jq -r .systemMessage | grep -q "^- Hooks sync on every launch"'

# 6. Switched off, or no claude.
reset; collect "$T/ok" "$BASE" "$HEAD1" MEGAVIBE_UPDATE_SUMMARY=0; rc=$?
check "MEGAVIBE_UPDATE_SUMMARY=0: exit 0, claude never called, record kept" '[ $rc = 0 ] && [ ! -e "$T/log" ] && [ -f "$CL" ] && [ "$(sed -n 2p "$CL")" = "summary: 0" ]'
reset; collect "$T/none" "$BASE" "$HEAD1"; rc=$?
check "no claude on PATH: exit 0, fallback only" '[ $rc = 0 ] && [ -f "$CL" ] && [ "$(sed -n 2p "$CL")" = "summary: 0" ]'
mkdir -p "$T/noperl"
for tool in bash git jq awk sed tr head tail cut mktemp cat env mv rm date wc grep find mkdir dirname sleep touch printf; do
  p=$(PATH="$SYS" command -v "$tool" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$T/noperl/$tool"
done
ln -sf "$T/ok/claude" "$T/noperl/claude"
reset; collect "$T/noperl" "$BASE" "$HEAD1" PATH="$T/noperl"; rc=$?
check "no perl: exit 0, no claude call (the bound cannot be enforced)" '[ $rc = 0 ] && [ ! -e "$T/log" ] && [ -f "$CL" ]'

# 6b. The timeout setting is validated as text before any arithmetic, then clamped.
big=9223372036854775808
reset; collect "$T/ok" "$BASE" "$HEAD1" MEGAVIBE_UPDATE_SUMMARY_TIMEOUT=$big; rc=$?
check "huge timeout: exit 0, no bash arithmetic error" '[ $rc = 0 ] && ! grep -qi "integer expression\|syntax error\|value too great" "$T/collect.out"'
check "huge timeout: counts as the default 25 and still summarises" 'grep -q "up to 25s" "$T/collect.out" && [ "$(sed -n 2p "$CL")" = "summary: 2" ]'
for pair in "0:1" "007:7" "999:120" "1000:25" "banana:25" "-5:25" "2.5:25" ":25"; do
  v=${pair%%:*}; want=${pair##*:}
  reset; collect "$T/ok" "$BASE" "$HEAD1" MEGAVIBE_UPDATE_SUMMARY_TIMEOUT="$v"; rc=$?
  check "timeout '$v' -> up to ${want}s" '[ $rc = 0 ] && grep -q "up to ${want}s" "$T/collect.out"'
done
# run_bounded clamps for itself: 0 would be `alarm 0`, i.e. no bound.
start=$SECONDS
env PATH="$SYS" bash "$HAR2" 0 /dev/null "$T/rbout" sleep 60 >/dev/null 2>&1; rc=$?
took=$((SECONDS - start))
check "run_bounded 0 is clamped to 1 s, not unbounded (rc $rc after ${took}s)" '[ $rc = 124 ] && [ "$took" -lt 10 ]'

# 7. Model output is sanitised and capped before it is stored and shown: C0 and C1 controls out.
reset; collect "$T/noisy" "$BASE" "$HEAD1"; rc=$?
check "noisy output: stored" '[ $rc = 0 ] && [ "$(sed -n 2p "$CL")" != "summary: 0" ]'
check "noisy output: no escape bytes stored" '! LC_ALL=C grep -q "$(printf "\033")" "$CL"'
check "noisy output: no C1 controls stored (U+009B, U+0085)" '! LC_ALL=C grep -q "$(printf "\302\233")" "$CL" && ! LC_ALL=C grep -q "$(printf "\302\205")" "$CL"'
check "noisy output: text around the C1 bytes survives" 'note | grep -q "csi nel and more text here"'
check "noisy output: leading blank lines trimmed, at most 8 note lines" '[ "$(note | head -n 1 | cut -c1-10)" = "First line" ] && [ "$(note | wc -l | tr -d " ")" -le 8 ] && [ "$(sed -n 2p "$CL")" = "summary: 8" ]'

# 7b. The hook sanitises on its own: C1 controls in a record it did not write.
mkrecord "$CL" aaaaaaaa bbbbbbbb 2 "$(printf 'note \302\233[31m with csi\033[0m')" "$(printf 'subject \302\233 one')" "plain two"
out=$(announce); msg=$(printf "%s" "$out" | jq -r .systemMessage)
check "hook: no C1 or ESC in a note" '! printf "%s" "$msg" | LC_ALL=C grep -q "$(printf "\302\233")" && ! printf "%s" "$msg" | LC_ALL=C grep -q "$(printf "\033")" && printf "%s" "$msg" | grep -q "note \[31m with csi"'
mkrecord "$CL" aaaaaaaa bbbbbbbb 2 "" "$(printf 'subject \302\233 one')" "plain two"
msg=$(announce | jq -r .systemMessage)
check "hook: no C1 in the fallback subjects" '! printf "%s" "$msg" | LC_ALL=C grep -q "$(printf "\302\233")" && printf "%s" "$msg" | grep -q "^- subject  one"'
reset

# 8. An answer that is an error is never a note, whatever the exit status.
for stub in login iserr errres; do
  reset; collect "$T/$stub" "$BASE" "$HEAD1"; rc=$?
  check "$stub: exit 0" '[ $rc = 0 ]'
  check "$stub: not stored as a note" '[ "$(sed -n 2p "$CL")" = "summary: 0" ] && ! grep -qi "api key\|overloaded\|/login" "$CL"'
  msg=$(announce | jq -r .systemMessage)
  check "$stub: the message is the subject fallback" 'printf "%s" "$msg" | grep -q "^- Hooks sync on every launch" && ! printf "%s" "$msg" | grep -qi "api key\|overloaded\|/login"'
done
reset; collect "$T/array" "$BASE" "$HEAD1"; rc=$?
check "older builds' array answer is read for its result message" '[ $rc = 0 ] && note | grep -q "array of messages"'
reset

# 9. Two updates with no session between: one chained range, one record, one note for the latest.
commit "Second update lands" "Adds a thing."
HEAD2=$(git -C "$SRC" rev-parse HEAD)
reset; collect "$T/ok" "$BASE" "$HEAD1" >/dev/null; collect "$T/ok" "$HEAD1" "$HEAD2" >/dev/null
check "chained: changelog spans the whole range" 'head -n 1 "$CL" | grep -q "^megavibe updated: $(h8 "$BASE") -> $(h8 "$HEAD2") (4 commits)"'
check "chained: the second call saw both updates" 'grep -q "Hooks sync on every launch" "$T/log" && grep -q "Second update lands" "$T/log"'
check "chained: one record, nothing left over" '[ "$(ls -A "$H" | wc -l | tr -d " ")" = 1 ]'
check "chained: announced once" 'announce | jq -r .systemMessage | grep -q "(4 commits)" && [ -z "$(announce)" ]'
reset

# 9b. Race: a session starts WHILE the second update is summarising. The updater claimed the
#     pending record first, so the session finds nothing (it never waits) and A->C is announced once.
mkdir -p "$T/sess/.agent"
collect "$T/ok" "$BASE" "$HEAD1" >/dev/null
collect "$T/session" "$HEAD1" "$HEAD2" SESSION_PROJ="$T/sess" SESSION_HOME="$T/home" SESSION_MVH="$H" SESSION_HOOK="$HOOK"; rc=$?
check "race (session during the summary): updater exits 0" '[ $rc = 0 ]'
check "race (session during the summary): that session announced nothing" '[ -f "$T/log.session" ] && [ ! -s "$T/log.session" ]'
check "race (session during the summary): the record is the whole range A->C" 'head -n 1 "$CL" | grep -q "^megavibe updated: $(h8 "$BASE") -> $(h8 "$HEAD2") (4 commits)" && note | grep -q "another session started"'
check "race (session during the summary): no claim file left behind" '! ls "$H"/.update-changelog.updating.* >/dev/null 2>&1'
out=$(announce)
check "race (session during the summary): the next session announces A->C once" 'printf "%s" "$out" | jq -r .systemMessage | grep -q "(4 commits)" && [ -z "$(announce)" ]'
reset

# 9c. Race, the other order: a session consumed the first update BEFORE the second one starts.
#     Then the second is B->C only; the first range is not announced again.
collect "$T/ok" "$BASE" "$HEAD1" >/dev/null
first=$(announce | jq -r .systemMessage)
collect "$T/ok" "$HEAD1" "$HEAD2" >/dev/null
check "race (session first): it announced the first update" 'printf "%s" "$first" | grep -q "(3 commits)"'
check "race (session first): the second record covers B->C only" 'head -n 1 "$CL" | grep -q "^megavibe updated: $(h8 "$HEAD1") -> $(h8 "$HEAD2") (1 commits)"'
check "race (session first): the first range is not in the prompt again" '! grep -q "Hooks sync on every launch" "$T/log" && grep -q "Second update lands" "$T/log"'
reset

# 9d. Race: a newer update is published right after a session claims its record. The session shows
#     the record it claimed, with its own note; the newer one (and its note) is announced next, whole.
mkrecord "$T/older.rec" aaaaaaaa bbbbbbbb 1 "NOTE FROM THE OLDER UPDATE" "- older subject"
mkrecord "$T/newer.rec" bbbbbbbb cccccccc 1 "NOTE FROM THE NEWER UPDATE" "- newer subject"
cp "$T/older.rec" "$CL"
export NEWER="$T/newer.rec" NEWER_DEST="$CL"
msg1=$(ANNOUNCE_PATH="$T/mvnewer:$SYS" announce | jq -r .systemMessage)
unset NEWER NEWER_DEST
check "race (newer published after the claim): the session showed the older note" 'printf "%s" "$msg1" | grep -q "NOTE FROM THE OLDER UPDATE" && ! printf "%s" "$msg1" | grep -q "NEWER"'
check "race (newer published after the claim): the newer record is still pending, whole" '[ -f "$CL" ] && cmp -s "$CL" "$T/newer.rec"'
msg2=$(announce | jq -r .systemMessage)
check "race (newer published after the claim): the next session shows the newer note" 'printf "%s" "$msg2" | grep -q "NOTE FROM THE NEWER UPDATE" && ! printf "%s" "$msg2" | grep -q "OLDER"'
reset

# 9e. If the new record cannot be published, the pending one is put back untouched.
collect "$T/ok" "$BASE" "$HEAD1" >/dev/null
cp "$CL" "$T/pending.rec"
collect "$T/ok" "$HEAD1" "$HEAD2" PATH="$T/ok:$T/mvfail:$SYS"; rc=$?
check "publish failure: exit 0" '[ $rc = 0 ]'
check "publish failure: the pending record is back, unchanged" '[ -f "$CL" ] && cmp -s "$CL" "$T/pending.rec"'
check "publish failure: no claim or temp file left" '[ "$(ls -A "$H" | wc -l | tr -d " ")" = 1 ]'
reset

# 9f. Nothing to write (unreachable range): a pending record that does not end at the installed
#     version is dropped; one that already describes it is kept.
mkrecord "$CL" aaaaaaaa bbbbbbbb 1 "" "stale"
collect "$T/ok" 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222; rc=$?
check "unreachable range: exit 0, the stale predecessor is dropped" '[ $rc = 0 ] && [ ! -e "$CL" ] && [ ! -e "$T/log" ] && ! ls "$H"/.update-changelog.* >/dev/null 2>&1'
mkrecord "$CL" aaaaaaaa "$(h8 "$HEAD2")" 1 "" "current"
collect "$T/ok" 1111111111111111111111111111111111111111 "$HEAD2"; rc=$?
check "unreachable range: a predecessor that ends at the installed version is kept" '[ $rc = 0 ] && grep -q "^current" "$CL" && ! ls "$H"/.update-changelog.updating.* >/dev/null 2>&1'
reset

# 9g. An updater killed while it held the pending record: the claim is put back once it is old
#     enough that no live updater can own it -- by the hook, and by the next updater.
mkrecord "$H/.update-changelog.updating.4242" "$(h8 "$BASE")" "$(h8 "$HEAD1")" 3 "" "Orphaned subject"
check "orphan claim just taken (a live updater): the hook leaves it alone" '[ -z "$(announce)" ] && [ -f "$H/.update-changelog.updating.4242" ]'
age "$H/.update-changelog.updating.4242" 3600
msg=$(announce | jq -r .systemMessage)
check "orphan claim an hour old: the hook restores and announces it" 'printf "%s" "$msg" | grep -q "^- Orphaned subject" && [ ! -e "$H/.update-changelog.updating.4242" ] && [ ! -e "$CL" ]'
collect "$T/ok" "$BASE" "$HEAD1" >/dev/null
mv "$CL" "$H/.update-changelog.updating.4343"; age "$H/.update-changelog.updating.4343" 3600
collect "$T/ok" "$HEAD1" "$HEAD2"; rc=$?
check "orphan claim an hour old: the next updater restores it and chains A->C" '[ $rc = 0 ] && head -n 1 "$CL" | grep -q "^megavibe updated: $(h8 "$BASE") -> $(h8 "$HEAD2") (4 commits)" && [ "$(ls -A "$H" | wc -l | tr -d " ")" = 1 ]'
reset

# 10. Fallback is short: five subjects and a count of the rest. Subjects cannot carry escapes.
for i in 1 2 3 4 5 6 7; do commit "Extra change $i"; done
commit "$(printf 'Escape \033[31mred\033[0m subject')"
HEAD3=$(git -C "$SRC" rev-parse HEAD)
reset; collect "$T/fail" "$HEAD2" "$HEAD3" >/dev/null
out=$(announce); msg=$(printf "%s" "$out" | jq -r .systemMessage)
check "long fallback: header counts all commits" 'printf "%s" "$msg" | head -n 1 | grep -q "(8 commits)"'
check "long fallback: five subjects plus the remainder" '[ "$(printf "%s\n" "$msg" | grep -c "^- ")" = 6 ] && printf "%s" "$msg" | grep -q "^- \.\.\. and 3 more"'
check "long fallback: no escape bytes reach the message" '! printf "%s" "$msg" | LC_ALL=C grep -q "$(printf "\033")" && printf "%s" "$msg" | grep -q "^- Escape .*red.* subject"'
reset

# 10b. A commit that is not valid UTF-8 must not lose the other subjects (awk, cut and tr abort on
#      it in a UTF-8 locale), nor the detail the model is given.
commit "Fine subject before"
git -C "$SRC" commit -q --allow-empty -m "$(printf 'Latin1 caf\351 \377\376 subject')" -m "$(printf 'body with bad bytes \377\376 and the gist stays')" 2>/dev/null
commit "Fine subject after"
HEAD4=$(git -C "$SRC" rev-parse HEAD)
reset; collect "$T/fail" "$HEAD3" "$HEAD4" >/dev/null
out=$(ANNOUNCE_ENV="LC_ALL=en_US.UTF-8" announce); msg=$(printf "%s" "$out" | jq -r .systemMessage 2>/dev/null)
check "bad UTF-8 subject: the message is still valid JSON" 'printf "%s" "$out" | jq -e .systemMessage >/dev/null'
check "bad UTF-8 subject: the other subjects survive in a UTF-8 locale" 'printf "%s" "$msg" | grep -q "^- Fine subject before" && printf "%s" "$msg" | grep -q "^- Fine subject after" && printf "%s" "$msg" | grep -q "^- Latin1 caf"'
reset; collect "$T/ok" "$HEAD3" "$HEAD4" LC_ALL=en_US.UTF-8 >/dev/null
check "bad UTF-8 body: every commit still reaches the prompt" 'grep -aq "Fine subject before" "$T/log" && grep -aq "Fine subject after" "$T/log" && grep -aq "the gist stays" "$T/log" && [ "$(sed -n 2p "$CL")" = "summary: 2" ]'
reset

# 11. Hook guards: outside a megavibe project it does nothing; an old record is dropped lazily; two sessions, one note.
collect "$T/ok" "$BASE" "$HEAD1" >/dev/null
out=$( cd "$T" && mkdir -p plain && cd plain && env PATH="$SYS" HOME="$T/home" MEGAVIBE_HOME="$H" bash "$HOOK" 2>/dev/null )
check "no .agent: silent, nothing consumed" '[ -z "$out" ] && [ -f "$CL" ]'
age "$CL" $((8 * 86400))
check "record older than a week: silent" '[ -z "$(announce)" ]'
check "record older than a week: dropped at that session start" '[ ! -e "$CL" ]'
collect "$T/ok" "$BASE" "$HEAD1" >/dev/null
mkdir -p "$T/p1/.agent" "$T/p2/.agent"
( announce "$T/p1" > "$T/r1" ) & ( announce "$T/p2" > "$T/r2" ) & wait
check "two sessions at once: exactly one announces" '[ "$(cat "$T/r1" "$T/r2" | grep -c systemMessage)" = 1 ]'
reset

# 12. condense_commits keeps every commit's gist and drops trailers.
body=$(printf 'x%.0s' $(seq 1 900))
cc=$(printf '\001one\n%s\n\nSigned-off-by: a\n\001two\n\001three\nshort body\n' "$body" | PATH="$SYS" bash -c "$(sed -n '/^condense_commits() {/,/^}/p' "$REPO/megavibe"); condense_commits")
check "condense: every subject present" 'printf "%s" "$cc" | grep -q "^\* one" && printf "%s" "$cc" | grep -q "^\* two" && printf "%s" "$cc" | grep -q "^\* three"'
check "condense: long body cut to a snippet" '[ "$(printf "%s" "$cc" | awk "length > 600" | wc -l | tr -d " ")" = 0 ] && printf "%s" "$cc" | grep -q "\.\.\.$"'
check "condense: trailers dropped" '! printf "%s" "$cc" | grep -q "Signed-off-by"'

# 12b. A curl install (no local history) summarises from the GitHub compare answer.
mkdir -p "$T/curlbin" "$T/nosrc"
cat > "$T/curlbin/curl" <<'STUB'
#!/bin/bash
cat "$CURL_JSON"
STUB
chmod +x "$T/curlbin/curl"
printf '%s\n' '{"total_commits":2,"commits":[{"commit":{"message":"First curl subject\n\nbody one for the curl route\n\nCo-authored-by: x <x@example.com>"}},{"commit":{"message":"Second curl subject"}}],"files":[{"filename":"template/a.sh","additions":3,"deletions":1},{"filename":"README.md","additions":9,"deletions":0}]}' > "$T/compare.json"
reset; COLLECT_SRC="$T/nosrc" collect "$T/ok" aaaaaaaa1111 bbbbbbbb2222 PATH="$T/ok:$T/curlbin:$SYS" CURL_JSON="$T/compare.json"; rc=$?
check "curl route: exit 0, record keyed to the new version with a note" '[ $rc = 0 ] && head -n 1 "$CL" | grep -q "^megavibe updated: aaaaaaaa -> bbbbbbbb (2 commits)" && [ "$(sed -n 2p "$CL")" = "summary: 2" ]'
check "curl route: bodies reach the prompt, trailers do not" 'grep -q "First curl subject" "$T/log" && grep -q "body one for the curl route" "$T/log" && grep -q "Second curl subject" "$T/log" && ! grep -q "Co-authored-by" "$T/log"'
check "curl route: deployed files only (README.md left out)" 'grep -q "template/a.sh (+3/-1)" "$T/log" && ! grep -q "README.md" "$T/log"'
reset

# 13. The launcher no longer types a prompt for the user.
check "no ANNOUNCE_ARGS in the launcher" '! grep -q "ANNOUNCE_ARGS" "$REPO/megavibe"'
check "no announce_prompt_args in the launcher" '! grep -q "announce_prompt_args" "$REPO/megavibe"'
check "no auto-typed summary prompt in the launcher" '! grep -q "Summarise the megavibe update" "$REPO/megavibe"'
line=$(grep 'claude --dangerously-skip-permissions --remote-control' "$REPO/megavibe" | grep 'rc_name_prefix' | tail -n 1)
check "the claude launch line ends with the user's own args, no prompt after them" 'printf "%s\n" "$line" | grep -qF "\"\${CLAUDE_EXTRA_ARGS[@]}\"} &" && printf "%s" "$line" | grep -q "} &\$"'
check "the hook no longer asks the model to summarise" '! grep -q "additionalContext\|Open your next message" "$HOOK"'
check "the second file is gone from the launcher and the hook" '! grep -q "update-summary\|UPDATE_SUMMARY_FILE" "$REPO/megavibe" "$HOOK"'

# 13b. Comments and docs say what the code does.
a=$(grep -n "^# Never fails an update" "$REPO/megavibe" | cut -d: -f1)
c=$(grep -n "^collect_changelog() {" "$REPO/megavibe" | cut -d: -f1)
r=$(grep -n "^run_bounded() {" "$REPO/megavibe" | cut -d: -f1)
check "'Never fails an update' sits on collect_changelog, not run_bounded" '[ -n "$a" ] && [ $((c - a)) -le 3 ] && [ "$a" -gt "$r" ]'
check "README: timeout and once-only claims match the behaviour" 'grep -q "clamped to 1-120" "$REPO/README.md" && grep -q "published whole and claimed whole" "$REPO/README.md" && grep -q "deleted lazily" "$REPO/README.md" && ! grep -q "25 seconds at most" "$REPO/README.md" && ! grep -q "update-summary" "$REPO/README.md"'

# 14. Syntax of everything touched.
check "bash -n megavibe" 'bash -n "$REPO/megavibe"'
check "bash -n announce-update.sh" 'bash -n "$HOOK"'

printf 'update-summary tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
