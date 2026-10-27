#!/bin/bash
# /bin/bash tests/update-summary.test.sh
# The update note: a bounded Haiku summary made at update time, kept in ONE immutable
# file per update (update-notes/<old8>-<new8>) with the commit list, taken by
# announce-update.sh with a per-file mv and shown once as a SessionStart
# systemMessage, with commit subjects as the fallback; and the launcher no longer
# types a first prompt for the user.
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

H="$T/home/.megavibe"; mkdir -p "$H"
NOTES="$H/update-notes"
# Everything that could send the summary call to a console key or another provider.
export ANTHROPIC_API_KEY=fake-key-1234 ANTHROPIC_AUTH_TOKEN=fake-token-12 ANTHROPIC_BASE_URL=http://127.0.0.1:9
export CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_USE_FOUNDRY=1
unset MEGAVIBE_UPDATE_SUMMARY MEGAVIBE_UPDATE_SUMMARY_TIMEOUT MEGAVIBE_NOW

# --- stubs -------------------------------------------------------------------
# ok: records how it was called, answers like `claude -p --output-format json`.
# slow: sleeps past the bound. fail: exits 1. noisy: control characters, C1 and bidi
# controls, too many lines. leaky: answers, then leaves a child behind. The rest are
# answers that must not pass for a note.
STUBS="ok slow fail noisy leaky login iserr errres array partial twodocs session nested"
for s in $STUBS none; do mkdir -p "$T/$s"; done
cat > "$T/ok/claude" <<'STUB'
#!/bin/bash
{ echo "ARGS: $*"; echo "CWD: $(pwd)"; echo "AGENT_HERE: $([ -e .agent ] && echo yes || echo no)"
  echo "ENV: ${ANTHROPIC_API_KEY:-unset}|${ANTHROPIC_AUTH_TOKEN:-unset}|${ANTHROPIC_BASE_URL:-unset}|${CLAUDE_CODE_USE_BEDROCK:-unset}|${CLAUDE_CODE_USE_VERTEX:-unset}|${CLAUDE_CODE_USE_FOUNDRY:-unset}"
  echo "STDIN<<"; cat; echo ">>"; } >> "$STUB_LOG"
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
r=$(printf '\n\nFirst line \033[31mred\033[0m \302\233csi \302\205nel \342\200\256rlo \342\200\250ls \342\200\213zw \342\201\246iso \357\273\277bom and more text here.\n'; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "line $i of a long answer"; done)
jq -n --arg r "$r" '{type:"result",subtype:"success",is_error:false,result:$r}'
STUB
cat > "$T/leaky/claude" <<'STUB'
#!/bin/bash
cat > /dev/null
sleep 60 &
echo $! > "$STUB_LOG.pid3"
echo '{"type":"result","subtype":"success","is_error":false,"result":"A note from a claude that leaves a child behind."}'
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
# partial: a complete document, then garbage, exit 0.
cat > "$T/partial/claude" <<'STUB'
#!/bin/bash
cat > /dev/null
echo '{"type":"result","subtype":"success","is_error":false,"result":"Partial answer before output became invalid."}'
echo 'INVALID'
STUB
# twodocs: two complete documents; --output-format json is one.
cat > "$T/twodocs/claude" <<'STUB'
#!/bin/bash
cat > /dev/null
echo '{"type":"result","subtype":"success","is_error":false,"result":"First of two documents, which is one too many."}'
echo '{"type":"result","subtype":"success","is_error":false,"result":"Second of two documents."}'
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
# nested: while it "thinks", a whole later update starts, finishes and publishes.
cat > "$T/nested/claude" <<'STUB'
#!/bin/bash
cat >> "$STUB_LOG"
env PATH="$NESTED_OK:/usr/bin:/bin" HOME="$NESTED_HOME" STUB_LOG="$STUB_LOG.inner" MEGAVIBE_NOW="$NESTED_TS" bash "$NESTED_HAR" "$NESTED_SRC" "$NESTED_OLD" "$NESTED_NEW" > /dev/null 2>&1
echo '{"type":"result","subtype":"success","is_error":false,"result":"Outer update note, finished last."}'
STUB
for s in $STUBS; do chmod +x "$T/$s/claude"; done

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
commit "Second update lands" "Adds a thing."
HEAD2=$(git -C "$SRC" rev-parse HEAD)
h8() { printf '%s' "$1" | cut -c1-8; }
rec() { printf '%s/%s-%s' "$NOTES" "$(h8 "$1")" "$(h8 "$2")"; }   # the record for a range

# --- harness: the launcher's own functions, run as the launcher runs them ---------
FUNCS="is_git_source strip_controls run_bounded condense_commits summarize_update git_commit_detail collect_changelog"
HAR="$T/harness.sh"
{
  echo 'set -euo pipefail'
  echo "MEGAVIBE_HOME='$H'; NOTES_DIR='$NOTES'; GITHUB_REPO=x/y"
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
  rm -f "$T/log" "$T/log".pid? "$T/log.session" "$T/log.inner"
  env PATH="$d:$SYS" HOME="$T/home" STUB_LOG="$T/log" "$@" bash "$HAR" "${COLLECT_SRC:-$SRC}" "$old" "$new" >"$T/collect.out" 2>&1
}
announce() {  # announce [dir]: run the hook in a megavibe project, print its stdout
  local p="${1:-$T/proj}"; mkdir -p "$p/.agent"
  ( cd "$p" && env PATH="${ANNOUNCE_PATH:-$SYS}" HOME="$T/home" MEGAVIBE_HOME="$H" "${ANNOUNCE_ENV:-X=1}" bash "$HOOK" 2>/dev/null )
}
msgof() { jq -r .systemMessage 2>/dev/null; }
reset() { rm -rf "$NOTES" "$H"/.update-* ; }
note() {  # note <file>: the stored note, the k lines after "summary: k"
  local k; k=$(sed -n '3s/^summary: //p' "$1"); [ "${k:-0}" -gt 0 ] && sed -n "4,$((k + 3))p" "$1"
}
age() {  # age <file> <seconds>: set mtime that far in the past
  perl -e 'my $t = time - $ARGV[1]; utime($t, $t, $ARGV[0])' "$1" "$2"
}
mkrecord() {  # mkrecord <old8> <new8> <ts> <count> <note-or-empty> <subject...>
  local o="$1" n="$2" ts="$3" c="$4" nt="$5"; shift 5
  mkdir -p "$NOTES"
  { printf 'ts: %s\nmegavibe updated: %s -> %s (%s commits)\n' "$ts" "$o" "$n" "$c"
    if [ -n "$nt" ]; then printf 'summary: 1\n%s\n' "$nt"; else printf 'summary: 0\n'; fi
    printf '\nCommits:\n'; for s in "$@"; do printf '%s\n' "$s"; done; } > "$NOTES/$o-$n"
}
# nobad: reads text on stdin, fails if any control survives: ESC, C1 (c2 80-9f), the
# format and bidi controls U+200B-U+200F, U+2028-U+202E, U+2066-U+2069, U+FEFF.
nobad() { perl -0777 -ne 'exit(/\xc2[\x80-\x9f]|\xe2\x80[\x8b-\x8f\xa8-\xae]|\xe2\x81[\xa6-\xa9]|\xef\xbb\xbf|\x1b/ ? 1 : 0)'; }
# a tool directory without the named tools, for "this machine has no X" cases
toolsbut() {  # toolsbut <dir> <tool-to-leave-out>...
  local d="$1" tool skip x p; shift; mkdir -p "$d"
  for tool in bash git jq perl awk sed tr head tail cut mktemp cat env mv rm date wc grep find mkdir dirname sleep touch printf sort ls iconv cp cmp; do
    skip=0; for x in "$@"; do [ "$x" = "$tool" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    p=$(PATH="$SYS" command -v "$tool" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$d/$tool"
  done
}

# 1. Summary generated, stored in its own record, and the claude call is the bounded no-tools shape.
reset; collect "$T/ok" "$BASE" "$HEAD1" MEGAVIBE_NOW=1700000000; rc=$?
R=$(rec "$BASE" "$HEAD1"); NEW8=$(h8 "$HEAD1")
check "collect_changelog exits 0" '[ $rc = 0 ]'
check "one record named by its range, nothing else in the home" '[ -f "$R" ] && [ "$(ls -A "$NOTES" | wc -l | tr -d " ")" = 1 ] && [ "$(ls -A "$H")" = update-notes ]'
check "line 1 is the start time, line 2 names the range, line 3 counts the note" '[ "$(sed -n 1p "$R")" = "ts: 1700000000" ] && sed -n 2p "$R" | grep -q "^megavibe updated: $(h8 "$BASE") -> $NEW8 (3 commits)" && [ "$(sed -n 3p "$R")" = "summary: 2" ]'
check "the note is the model output" '[ "$(note "$R" | head -n 1)" = "Hooks now sync on every launch." ]'
check "the commit list follows the note" '[ -z "$(sed -n 6p "$R")" ] && [ "$(sed -n 7p "$R")" = "Commits:" ] && sed -n 8p "$R" | grep -q "Fix quoting in the restart path"'
check "one claude call" '[ "$(grep -c "^ARGS:" "$T/log")" = 1 ]'
check "print mode, haiku, json, no tools" 'grep -q "^ARGS: -p --model haiku --output-format json --tools  --no-session-persistence" "$T/log"'
check "no skills, no MCP, no settings sources" 'a=$(grep "^ARGS:" "$T/log"); case "$a" in *--disable-slash-commands*--strict-mcp-config*--setting-sources*) true ;; *) false ;; esac'
check "runs from a scratch directory with no .agent" 'grep -q "^AGENT_HERE: no" "$T/log" && ! grep "^CWD:" "$T/log" | grep -q "$REPO"'
check "key, token, base URL and provider switches all masked for the call" 'grep -q "^ENV: unset|unset|unset|unset|unset|unset$" "$T/log"'
check "prompt carries the commit subjects and bodies" 'grep -q "Hooks sync on every launch" "$T/log" && grep -q "re-syncs hooks before it starts claude" "$T/log"'
check "prompt drops the attribution trailers" '! grep -q "SECRETTRAILER\|Co-authored-by" "$T/log"'
check "prompt tells the model the log is data" 'grep -q "DATA copied from commit messages" "$T/log"'
check "launcher says a note is coming, not that Claude will summarise" 'grep -q "short note on what changed" "$T/collect.out" && ! grep -qi "claude will summari" "$T/collect.out"'

# 2. The hook shows it once, as a systemMessage only.
out=$(announce)
check "hook prints one JSON object" 'printf "%s" "$out" | jq -e . >/dev/null'
check "title names the range and the count, then the note" 'printf "%s" "$out" | msgof | head -n 1 | grep -q "^megavibe updated $(h8 "$BASE")→$NEW8 (3 commits)$" && printf "%s" "$out" | msgof | grep -q "The update note no longer types a prompt for you."'
check "nothing is handed to the model" '[ "$(printf "%s" "$out" | jq -r "keys | join(\",\")")" = systemMessage ]'
check "the commit list stays out of a message that has a note" '! printf "%s" "$out" | msgof | grep -q "^- "'
check "taken: the record and the private claim directory are gone" '[ ! -e "$R" ] && ! ls -d "$H"/.update-claim.* >/dev/null 2>&1'
check "second session: silent" '[ -z "$(announce)" ]'

# 3. Nothing changed: no record, no message, no claude call.
reset; collect "$T/ok" "$HEAD1" "$HEAD1"; rc=$?
check "same version: exit 0, no record, no claude call" '[ $rc = 0 ] && [ ! -e "$NOTES" ] && [ ! -e "$T/log" ]'
check "same version: hook silent" '[ -z "$(announce)" ]'
reset; collect "$T/ok" "not-a-hash" "also-not"; rc=$?
check "ids that are not hex cannot name a record: exit 0, nothing written" '[ $rc = 0 ] && [ ! -e "$NOTES" ] && [ ! -e "$T/log" ]'

# 4. claude fails: no note, launch path still 0, hook falls back to subjects.
reset; collect "$T/fail" "$BASE" "$HEAD1"; rc=$?
R=$(rec "$BASE" "$HEAD1")
check "failing claude: exit 0" '[ $rc = 0 ]'
check "failing claude: record written with summary: 0, partial output not used" '[ -f "$R" ] && [ "$(sed -n 3p "$R")" = "summary: 0" ] && ! grep -q "partial output" "$R"'
msg=$(announce | msgof)
check "fallback names the update" 'printf "%s" "$msg" | head -n 1 | grep -q "^megavibe updated .*→.* (3 commits)"'
check "fallback lists the commit subjects" 'printf "%s" "$msg" | grep -q "^- Hooks sync on every launch" && printf "%s" "$msg" | grep -q "^- Fix quoting in the restart path"'
check "fallback does not leak the base commit" '! printf "%s" "$msg" | grep -q "base commit"'
check "fallback shown once" '[ -z "$(announce)" ] && [ ! -e "$R" ]'

# 5. claude hangs: the bound holds, the whole process group dies, launch path still 0.
reset
start=$SECONDS
collect "$T/slow" "$BASE" "$HEAD1" MEGAVIBE_UPDATE_SUMMARY_TIMEOUT=2; rc=$?
took=$((SECONDS - start)); R=$(rec "$BASE" "$HEAD1")
check "timeout: exit 0" '[ $rc = 0 ]'
check "timeout: returned within the bound (took ${took}s)" '[ "$took" -lt 12 ]'
check "timeout: record published without a note" '[ -f "$R" ] && [ "$(sed -n 3p "$R")" = "summary: 0" ]'
sleep 1
p1=$(cat "$T/log.pid1" 2>/dev/null || echo 0); p2=$(cat "$T/log.pid2" 2>/dev/null || echo 0)
check "timeout: the stub and its child are gone" '! kill -0 "$p1" 2>/dev/null && ! kill -0 "$p2" 2>/dev/null && [ "$p1" != 0 ] && [ "$p2" != 0 ]'
check "timeout: hook falls back to subjects" 'announce | msgof | grep -q "^- Hooks sync on every launch"'

# 5b. A claude that answers and exits 0 but leaves a child behind: the group is killed on a normal exit too.
reset; collect "$T/leaky" "$BASE" "$HEAD1"; rc=$?
p3=$(cat "$T/log.pid3" 2>/dev/null || echo 0)
sleep 1
check "leaky claude: exit 0 and its note is used" '[ $rc = 0 ] && note "$(rec "$BASE" "$HEAD1")" | grep -q "leaves a child behind"'
check "leaky claude: the child it left behind is gone" '[ "$p3" != 0 ] && ! kill -0 "$p3" 2>/dev/null'

# 6. Switched off, or no claude.
reset; collect "$T/ok" "$BASE" "$HEAD1" MEGAVIBE_UPDATE_SUMMARY=0; rc=$?
check "MEGAVIBE_UPDATE_SUMMARY=0: exit 0, claude never called, record kept" '[ $rc = 0 ] && [ ! -e "$T/log" ] && [ "$(sed -n 3p "$(rec "$BASE" "$HEAD1")")" = "summary: 0" ]'
reset; collect "$T/none" "$BASE" "$HEAD1"; rc=$?
check "no claude on PATH: exit 0, fallback only" '[ $rc = 0 ] && [ "$(sed -n 3p "$(rec "$BASE" "$HEAD1")")" = "summary: 0" ]'
toolsbut "$T/noperl" perl; ln -sf "$T/ok/claude" "$T/noperl/claude"
reset; collect "$T/noperl" "$BASE" "$HEAD1" PATH="$T/noperl"; rc=$?
check "no perl: exit 0, no claude call (the bound cannot be enforced)" '[ $rc = 0 ] && [ ! -e "$T/log" ] && [ -f "$(rec "$BASE" "$HEAD1")" ]'
toolsbut "$T/nojq" jq; ln -sf "$T/ok/claude" "$T/nojq/claude"
reset; collect "$T/nojq" "$BASE" "$HEAD1" PATH="$T/nojq"; rc=$?
check "no jq: exit 0, no claude call (the answer cannot be read)" '[ $rc = 0 ] && [ ! -e "$T/log" ] && [ -f "$(rec "$BASE" "$HEAD1")" ]'

# 6b. The timeout setting is validated as text before any arithmetic, then clamped.
big=9223372036854775808
reset; collect "$T/ok" "$BASE" "$HEAD1" MEGAVIBE_UPDATE_SUMMARY_TIMEOUT=$big; rc=$?
check "huge timeout: exit 0, no bash arithmetic error" '[ $rc = 0 ] && ! grep -qi "integer expression\|syntax error\|value too great" "$T/collect.out"'
check "huge timeout: counts as the default 25 and still summarises" 'grep -q "up to 25s" "$T/collect.out" && [ "$(sed -n 3p "$(rec "$BASE" "$HEAD1")")" = "summary: 2" ]'
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

# 7. Model output is sanitised and capped before it is stored: C0, C1, format and bidi controls out.
reset; collect "$T/noisy" "$BASE" "$HEAD1"; rc=$?
R=$(rec "$BASE" "$HEAD1")
check "noisy output: stored" '[ $rc = 0 ] && [ "$(sed -n 3p "$R")" != "summary: 0" ]'
check "noisy output: no escape, C1, bidi or format control stored" 'nobad < "$R"'
check "noisy output: the text around them survives" 'note "$R" | grep -q "csi nel rlo ls zw iso bom and more text here"'
check "noisy output: leading blank lines trimmed, at most 8 note lines" '[ "$(note "$R" | head -n 1 | cut -c1-10)" = "First line" ] && [ "$(note "$R" | wc -l | tr -d " ")" -le 8 ] && [ "$(sed -n 3p "$R")" = "summary: 8" ]'

# 7b. The hook sanitises on its own, whatever a record holds: invalid UTF-8 that would JOIN into a
#     control once a neighbouring control is removed (c2 c2 85 9b -> c2 9b; c2 c2 9b 9b), nesting, and
#     each invisible control, in a note and in fallback subjects. Ordinary non-ASCII text is kept.
BAD1=$(printf 'text \302\302\205\233[31m text')
BAD2=$(printf 'sub \302\302\233\233 end')
BAD3=$(printf 'deep \302\302\302\205\233\233 end')
FMT=$(printf 'fmt \342\200\256rlo \342\200\250ls \342\200\213zw \342\201\246iso \357\273\277bom \302\233csi \033[0m end')
KEEP=$(printf 'keep caf\303\251 \342\200\224 dash')
mkrecord aaaaaaaa bbbbbbbb 100 5 "" "$BAD1" "$BAD2" "$BAD3" "$FMT" "$KEEP"
out=$(ANNOUNCE_ENV="LC_ALL=en_US.UTF-8" announce); msg=$(printf "%s" "$out" | msgof)
check "fallback subjects: valid JSON, nothing joined into a control" 'printf "%s" "$out" | jq -e . >/dev/null && printf "%s" "$msg" | nobad'
check "fallback subjects: the text around the removed bytes is kept" 'printf "%s" "$msg" | grep -q "^- text .*31m text$" && printf "%s" "$msg" | grep -q "^- sub  end$" && printf "%s" "$msg" | grep -q "^- fmt rlo ls zw iso bom csi \[0m end$"'
check "fallback subjects: ordinary non-ASCII text is kept" 'printf "%s" "$msg" | grep -q "^- keep caf$(printf "\303\251") $(printf "\342\200\224") dash$"'
mkdir -p "$NOTES"
{ printf 'ts: 100\nmegavibe updated: aaaaaaaa -> bbbbbbbb (4 commits)\nsummary: 4\n%s\n%s\n%s\n%s\n\nCommits:\nx\n' "$BAD1" "$BAD2" "$FMT" "$KEEP"; } > "$NOTES/aaaaaaaa-bbbbbbbb"
out=$(ANNOUNCE_ENV="LC_ALL=en_US.UTF-8" announce); msg=$(printf "%s" "$out" | msgof)
check "note lines: nothing joined into a control either" 'printf "%s" "$out" | jq -e . >/dev/null && printf "%s" "$msg" | nobad && printf "%s" "$msg" | grep -q "^text .*31m text$" && printf "%s" "$msg" | grep -q "^sub  end$" && printf "%s" "$msg" | grep -q "^fmt rlo ls zw iso bom csi \[0m end$" && printf "%s" "$msg" | grep -q "^keep caf$(printf "\303\251") $(printf "\342\200\224") dash$"'
toolsbut "$T/noiconv" iconv
mkrecord aaaaaaaa bbbbbbbb 100 5 "" "$BAD1" "$BAD2" "$BAD3" "$FMT" "$KEEP"
msg=$(ANNOUNCE_PATH="$T/noiconv" announce | msgof)
check "no iconv on the machine: the awk loop alone leaves no control (c2 c2 9b 9b and deeper nesting included)" 'printf "%s" "$msg" | nobad && printf "%s" "$msg" | grep -q "^- sub  end$" && printf "%s" "$msg" | grep -q "^- deep"'
reset

# 8. An answer that is an error is never a note, whatever the exit status; nor is half a document.
for stub in login iserr errres partial twodocs; do
  reset; collect "$T/$stub" "$BASE" "$HEAD1"; rc=$?
  R=$(rec "$BASE" "$HEAD1")
  check "$stub: exit 0" '[ $rc = 0 ]'
  check "$stub: not stored as a note" '[ "$(sed -n 3p "$R")" = "summary: 0" ] && ! grep -qi "api key\|overloaded\|/login\|partial answer\|two documents" "$R"'
  msg=$(announce | msgof)
  check "$stub: the message is the subject fallback" 'printf "%s" "$msg" | grep -q "^- Hooks sync on every launch" && ! printf "%s" "$msg" | grep -qi "api key\|overloaded\|/login\|partial answer\|two documents"'
done
reset; collect "$T/array" "$BASE" "$HEAD1"; rc=$?
check "older builds' array answer is read for its result message" '[ $rc = 0 ] && note "$(rec "$BASE" "$HEAD1")" | grep -q "array of messages"'
reset

# 9. Two updaters that finish OUT OF ORDER: the earlier one is still thinking when a later one starts,
#    finishes and publishes. Both records exist, none overwritten; one message shows both in the order the
#    updates happened (by start time), once.
collect "$T/nested" "$BASE" "$HEAD1" MEGAVIBE_NOW=1000 NESTED_OK="$T/ok" NESTED_HOME="$T/home" NESTED_HAR="$HAR" NESTED_SRC="$SRC" NESTED_OLD="$HEAD1" NESTED_NEW="$HEAD2" NESTED_TS=2000; rc=$?
RA=$(rec "$BASE" "$HEAD1"); RB=$(rec "$HEAD1" "$HEAD2")
check "out of order: both records exist, each whole" '[ $rc = 0 ] && [ -f "$RA" ] && [ -f "$RB" ] && [ "$(ls -A "$NOTES" | wc -l | tr -d " ")" = 2 ]'
check "out of order: the earlier update kept its own start time and note" '[ "$(sed -n 1p "$RA")" = "ts: 1000" ] && note "$RA" | grep -q "Outer update note" && [ "$(sed -n 1p "$RB")" = "ts: 2000" ]'
check "out of order: the later update was not extended with, or overwritten by, the earlier one" 'grep -q "Second update lands" "$RB" && ! grep -q "Hooks sync on every launch" "$RB" && head -n 2 "$RB" | tail -n 1 | grep -q "(1 commits)"'
msg=$(announce | msgof)
l1=$(printf "%s\n" "$msg" | grep -n "^megavibe updated $(h8 "$BASE")→" | cut -d: -f1); l2=$(printf "%s\n" "$msg" | grep -n "^megavibe updated $(h8 "$HEAD1")→" | cut -d: -f1)
check "out of order: one message, both shown, in the order the updates happened" '[ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ] && [ "$(printf "%s\n" "$msg" | grep -c "^megavibe updated ")" = 2 ]'
check "out of order: none repeated, none left" '[ -z "$(announce)" ] && [ "$(ls -A "$NOTES" | wc -l | tr -d " ")" = 0 ]'
# the same two, finishing in the order they started: same message
reset; collect "$T/ok" "$HEAD1" "$HEAD2" MEGAVIBE_NOW=2000 >/dev/null; collect "$T/ok" "$BASE" "$HEAD1" MEGAVIBE_NOW=1000 >/dev/null
msg2=$(announce | msgof)
check "ordering is by the record's start time, not by finish order" '[ "$(printf "%s\n" "$msg2" | grep -n "^megavibe updated" | head -n 1 | grep -c "$(h8 "$BASE")→")" = 1 ]'
reset
mkrecord ffffffff 11111111 100 1 "" "older by time"; mkrecord 00000000 ffffffff 200 1 "" "newer by time"
msg3=$(announce | msgof)
check "ordering ignores names: a later start sorts later whatever the names" '[ "$(printf "%s\n" "$msg3" | grep -n "^megavibe updated" | head -n 1 | grep -c "ffffffff→11111111")" = 1 ]'
mkrecord 22222222 33333333 100 1 "" "second by name"; mkrecord 11111111 22222222 100 1 "" "first by name"
msg3=$(announce | msgof)
check "equal start times: ties by name" '[ "$(printf "%s\n" "$msg3" | grep -n "^megavibe updated" | head -n 1 | grep -c "11111111→22222222")" = 1 ]'
reset

# 9b. Two sessions starting together, 25 times: every record is shown exactly once between them.
bad=0
for round in $(seq 1 25); do
  reset
  mkrecord aaaaaaaa bbbbbbbb 100 1 "ROUND$round FIRST note" "x"
  mkrecord bbbbbbbb cccccccc 200 1 "ROUND$round SECOND note" "y"
  mkdir -p "$T/p1/.agent" "$T/p2/.agent"
  ( announce "$T/p1" | msgof > "$T/r1" ) & ( announce "$T/p2" | msgof > "$T/r2" ) & wait
  a=$(cat "$T/r1" "$T/r2" | grep -c "ROUND$round FIRST note"); b=$(cat "$T/r1" "$T/r2" | grep -c "ROUND$round SECOND note")
  left=$(ls -A "$NOTES" 2>/dev/null | wc -l | tr -d ' '); claims=$(ls -d "$H"/.update-claim.* 2>/dev/null | wc -l | tr -d ' ')
  [ "$a" = 1 ] && [ "$b" = 1 ] && [ "$left" = 0 ] && [ "$claims" = 0 ] || { bad=$((bad + 1)); echo "round $round: first=$a second=$b left=$left claims=$claims"; }
done
check "two sessions in parallel x25: each record shown exactly once, nothing left or lost ($bad bad rounds)" '[ $bad = 0 ]'
reset

# 9c. A session starts while a later update is being summarised: it shows the earlier record and
#     does not wait; the later one is shown by the next session, once.
collect "$T/ok" "$BASE" "$HEAD1" MEGAVIBE_NOW=1000 >/dev/null
mkdir -p "$T/sess/.agent"
collect "$T/session" "$HEAD1" "$HEAD2" MEGAVIBE_NOW=2000 SESSION_PROJ="$T/sess" SESSION_HOME="$T/home" SESSION_MVH="$H" SESSION_HOOK="$HOOK"; rc=$?
during=$(msgof < "$T/log.session")
check "session mid-update: the updater exits 0" '[ $rc = 0 ]'
check "session mid-update: it showed the earlier record and not the one still being written" 'printf "%s" "$during" | grep -q "^megavibe updated $(h8 "$BASE")→" && ! printf "%s" "$during" | grep -q "^megavibe updated $(h8 "$HEAD1")→"'
msg=$(announce | msgof)
check "session mid-update: the next session shows the later record, and only it" 'printf "%s" "$msg" | grep -q "^megavibe updated $(h8 "$HEAD1")→$(h8 "$HEAD2")" && ! printf "%s" "$msg" | grep -q "^megavibe updated $(h8 "$BASE")→" && printf "%s" "$msg" | grep -q "written while another session started"'
check "session mid-update: then silence" '[ -z "$(announce)" ]'
reset

# 10. One message has a size cap; what does not fit waits, whole, for the next session.
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  long=$(printf 'Update %02d note, line one of a long note that takes space in the message.\n' "$i"; for j in 2 3 4 5 6 7 8; do printf 'Update %02d note line %s, filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler.\n' "$i" "$j"; done)
  mkdir -p "$NOTES"
  { printf 'ts: %s\nmegavibe updated: %08d -> %08d (3 commits)\nsummary: 8\n%s\n\nCommits:\nx\n' "$((100 + i))" "$i" "$((i + 1))" "$long"; } > "$NOTES/$(printf '%08d-%08d' "$i" "$((i + 1))")"
done
seen=""; sessions=0; ok=1
while [ $sessions -lt 30 ]; do
  out=$(announce); [ -n "$out" ] || break
  m=$(printf "%s" "$out" | msgof); sessions=$((sessions + 1))
  ml=$(printf "%s\n" "$m" | wc -l | tr -d ' '); mb=$(printf "%s" "$m" | wc -c | tr -d ' ')
  [ "$ml" -le 45 ] && [ "$mb" -le 3200 ] || { ok=0; echo "session $sessions: $ml lines $mb bytes"; }
  if [ $sessions = 1 ]; then first=$m; fi
  seen="$seen $(printf "%s\n" "$m" | grep -o 'Update [0-9][0-9] note, line one' | tr -d '\n' )"
done
check "cap: every message within about 40 lines and 3000 bytes" '[ $ok = 1 ]'
check "cap: the first message says how many are waiting" 'printf "%s" "$first" | grep -q "^\.\.\. and [0-9]* more updates, shown at your next session start$"'
check "cap: oldest first, spread over several sessions, all 12 shown exactly once" '[ $sessions -ge 4 ] && [ "$(printf "%s" "$seen" | grep -o "Update [0-9][0-9]" | sort | uniq | wc -l | tr -d " ")" = 12 ] && [ "$(printf "%s" "$seen" | grep -o "Update [0-9][0-9]" | wc -l | tr -d " ")" = 12 ] && printf "%s" "$first" | grep -q "Update 01 note" && ! printf "%s" "$first" | grep -q "Update 12 note"'
reset

# 11. Records older than a week are dropped unshown; younger ones in the same directory are shown.
mkrecord aaaaaaaa bbbbbbbb 100 1 "" "stale subject"; mkrecord bbbbbbbb cccccccc 200 1 "" "fresh subject"
age "$NOTES/aaaaaaaa-bbbbbbbb" $((8 * 86400))
msg=$(announce | msgof)
check "old record dropped unshown, fresh one shown" 'printf "%s" "$msg" | grep -q "^- fresh subject" && ! printf "%s" "$msg" | grep -q "stale subject" && [ ! -e "$NOTES/aaaaaaaa-bbbbbbbb" ]'
reset

# 12. The old launcher's single file is still read, once, and sorts before the new records.
{ printf 'megavibe updated: 11111111 -> 22222222 (2 commits)\n\nCommits:\nLegacy subject one\nLegacy subject two\n'; } > "$H/.update-changelog"
mkrecord 22222222 33333333 500 1 "" "Newer record subject"
msg=$(announce | msgof)
check "legacy single-file record: shown with its own title, before the newer record" 'printf "%s" "$msg" | grep -q "^megavibe updated 11111111→22222222 (2 commits)$" && printf "%s" "$msg" | grep -q "^- Legacy subject one" && [ "$(printf "%s\n" "$msg" | grep -n "^megavibe updated" | head -n 1 | grep -c 11111111)" = 1 ]'
check "legacy single-file record: consumed" '[ ! -e "$H/.update-changelog" ] && [ -z "$(announce)" ]'
{ printf 'megavibe updated: 11111111 -> 22222222 (2 commits)\nsummary: 1\nA legacy note.\n\nCommits:\nx\n'; } > "$H/.update-changelog"
check "legacy record with a note (the interim format) is shown too" 'announce | msgof | grep -q "^A legacy note\.$"'
reset

# 13. Hook guards: outside a megavibe project it does nothing; junk in the directory is left alone;
#     without jq nothing is shown and the records wait.
mkrecord aaaaaaaa bbbbbbbb 100 1 "" "a subject"
out=$( cd "$T" && mkdir -p plain && cd plain && env PATH="$SYS" HOME="$T/home" MEGAVIBE_HOME="$H" bash "$HOOK" 2>/dev/null )
check "no .agent: silent, nothing consumed" '[ -z "$out" ] && [ -f "$NOTES/aaaaaaaa-bbbbbbbb" ]'
out=$(ANNOUNCE_PATH="$T/nojq" announce)
check "no jq: silent, the record waits" '[ -z "$out" ] && [ -f "$NOTES/aaaaaaaa-bbbbbbbb" ] && ! ls -d "$H"/.update-claim.* >/dev/null 2>&1'
printf 'x\n' > "$NOTES/not-a-record"; printf 'x\n' > "$NOTES/zzzzzzzz-zzzzzzzz"; printf 'x\n' > "$NOTES/.tmp.1234"; mkdir -p "$NOTES/dddddddd-eeeeeeee"
printf 'x\n' > "$NOTES/.tmp.old"; age "$NOTES/.tmp.old" $((2 * 86400))
mkdir -p "$H/.update-claim.99999"; age "$H/.update-claim.99999" $((2 * 86400))
msg=$(announce | msgof)
check "only <8 hex>-<8 hex> files are taken" 'printf "%s" "$msg" | grep -q "^- a subject" && [ -f "$NOTES/not-a-record" ] && [ -f "$NOTES/zzzzzzzz-zzzzzzzz" ] && [ -f "$NOTES/.tmp.1234" ] && [ -d "$NOTES/dddddddd-eeeeeeee" ]'
check "stale temp files and abandoned claim directories are reaped, fresh ones kept" '[ ! -e "$NOTES/.tmp.old" ] && [ ! -e "$H/.update-claim.99999" ] && [ -f "$NOTES/.tmp.1234" ]'
reset

# 14. Fallback is short: five subjects and a count of the rest. Subjects cannot carry escapes.
for i in 1 2 3 4 5 6 7; do commit "Extra change $i"; done
commit "$(printf 'Escape \033[31mred\033[0m subject')"
HEAD3=$(git -C "$SRC" rev-parse HEAD)
reset; collect "$T/fail" "$HEAD2" "$HEAD3" >/dev/null
out=$(announce); msg=$(printf "%s" "$out" | msgof)
check "long fallback: header counts all commits" 'printf "%s" "$msg" | head -n 1 | grep -q "(8 commits)"'
check "long fallback: five subjects plus the remainder" '[ "$(printf "%s\n" "$msg" | grep -c "^- ")" = 6 ] && printf "%s" "$msg" | grep -q "^- \.\.\. and 3 more"'
check "long fallback: no escape bytes reach the message" 'printf "%s" "$msg" | nobad && printf "%s" "$msg" | grep -q "^- Escape .*red.* subject"'
reset

# 14b. A commit that is not valid UTF-8 must not lose the other subjects (awk, cut and tr abort on
#      it in a UTF-8 locale), nor the detail the model is given.
commit "Fine subject before"
git -C "$SRC" commit -q --allow-empty -m "$(printf 'Latin1 caf\351 \377\376 subject')" -m "$(printf 'body with bad bytes \377\376 and the gist stays')" 2>/dev/null
commit "Fine subject after"
HEAD4=$(git -C "$SRC" rev-parse HEAD)
reset; collect "$T/fail" "$HEAD3" "$HEAD4" >/dev/null
out=$(ANNOUNCE_ENV="LC_ALL=en_US.UTF-8" announce); msg=$(printf "%s" "$out" | msgof)
check "bad UTF-8 subject: the message is still valid JSON" 'printf "%s" "$out" | jq -e .systemMessage >/dev/null'
check "bad UTF-8 subject: the other subjects survive in a UTF-8 locale" 'printf "%s" "$msg" | grep -q "^- Fine subject before" && printf "%s" "$msg" | grep -q "^- Fine subject after" && printf "%s" "$msg" | grep -q "^- Latin1 caf"'
reset; collect "$T/ok" "$HEAD3" "$HEAD4" LC_ALL=en_US.UTF-8 >/dev/null
check "bad UTF-8 body: every commit still reaches the prompt" 'grep -aq "Fine subject before" "$T/log" && grep -aq "Fine subject after" "$T/log" && grep -aq "the gist stays" "$T/log" && [ "$(sed -n 3p "$(rec "$HEAD3" "$HEAD4")")" = "summary: 2" ]'
reset

# 15. condense_commits keeps every commit's gist and drops trailers.
body=$(printf 'x%.0s' $(seq 1 900))
cc=$(printf '\001one\n%s\n\nSigned-off-by: a\n\001two\n\001three\nshort body\n' "$body" | PATH="$SYS" bash -c "$(sed -n '/^condense_commits() {/,/^}/p' "$REPO/megavibe"); condense_commits")
check "condense: every subject present" 'printf "%s" "$cc" | grep -q "^\* one" && printf "%s" "$cc" | grep -q "^\* two" && printf "%s" "$cc" | grep -q "^\* three"'
check "condense: long body cut to a snippet" '[ "$(printf "%s" "$cc" | awk "length > 600" | wc -l | tr -d " ")" = 0 ] && printf "%s" "$cc" | grep -q "\.\.\.$"'
check "condense: trailers dropped" '! printf "%s" "$cc" | grep -q "Signed-off-by"'

# 15b. A curl install (no local history) summarises from the GitHub compare answer.
mkdir -p "$T/curlbin" "$T/nosrc"
cat > "$T/curlbin/curl" <<'STUB'
#!/bin/bash
cat "$CURL_JSON"
STUB
chmod +x "$T/curlbin/curl"
printf '%s\n' '{"total_commits":2,"commits":[{"commit":{"message":"First curl subject\n\nbody one for the curl route\n\nCo-authored-by: x <x@example.com>"}},{"commit":{"message":"Second curl subject"}}],"files":[{"filename":"template/a.sh","additions":3,"deletions":1},{"filename":"README.md","additions":9,"deletions":0}]}' > "$T/compare.json"
reset; COLLECT_SRC="$T/nosrc" collect "$T/ok" aaaaaaaa1111 bbbbbbbb2222 PATH="$T/ok:$T/curlbin:$SYS" CURL_JSON="$T/compare.json"; rc=$?
R="$NOTES/aaaaaaaa-bbbbbbbb"
check "curl route: exit 0, record named by the range, with a note" '[ $rc = 0 ] && sed -n 2p "$R" | grep -q "^megavibe updated: aaaaaaaa -> bbbbbbbb (2 commits)" && [ "$(sed -n 3p "$R")" = "summary: 2" ]'
check "curl route: bodies reach the prompt, trailers do not" 'grep -q "First curl subject" "$T/log" && grep -q "body one for the curl route" "$T/log" && grep -q "Second curl subject" "$T/log" && ! grep -q "Co-authored-by" "$T/log"'
check "curl route: deployed files only (README.md left out)" 'grep -q "template/a.sh (+3/-1)" "$T/log" && ! grep -q "README.md" "$T/log"'
reset

# 16. The launcher no longer types a prompt for the user, and keeps no claim/recovery machinery.
check "no ANNOUNCE_ARGS in the launcher" '! grep -q "ANNOUNCE_ARGS" "$REPO/megavibe"'
check "no announce_prompt_args in the launcher" '! grep -q "announce_prompt_args" "$REPO/megavibe"'
check "no auto-typed summary prompt in the launcher" '! grep -q "Summarise the megavibe update" "$REPO/megavibe"'
line=$(grep 'claude --dangerously-skip-permissions --remote-control' "$REPO/megavibe" | grep 'rc_name_prefix' | tail -n 1)
check "the claude launch line ends with the user's own args, no prompt after them" 'printf "%s\n" "$line" | grep -qF "\"\${CLAUDE_EXTRA_ARGS[@]}\"} &" && printf "%s" "$line" | grep -q "} &\$"'
check "the hook no longer asks the model to summarise" '! grep -q "additionalContext\|Open your next message" "$HOOK"'
check "no chaining, claiming or orphan recovery left in the launcher or the hook" '! grep -q "\.updating\|restore_orphan\|restore_changelog_claim\|CHANGELOG_FILE\|prev_old\|update-summary\|UPDATE_SUMMARY_FILE" "$REPO/megavibe" "$HOOK"'

# 16b. Comments and docs say what the code does.
check "README: timeout, once-only, billing, jq and expiry claims match the behaviour" 'grep -q "clamped to 1-120" "$REPO/README.md" && grep -q "one file per update" "$REPO/README.md" && grep -q "needs .jq." "$REPO/README.md" && grep -q "console API key" "$REPO/README.md" && grep -q "MEGAVIBE_UPDATE_SUMMARY=0" "$REPO/README.md" && grep -q "deleted lazily" "$REPO/README.md" && ! grep -q "25 seconds at most" "$REPO/README.md" && ! grep -q "update-summary\|claimed whole" "$REPO/README.md"'

# 17. Syntax of everything touched.
check "bash -n megavibe" 'bash -n "$REPO/megavibe"'
check "bash -n announce-update.sh" 'bash -n "$HOOK"'

printf 'update-summary tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
