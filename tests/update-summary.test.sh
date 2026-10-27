#!/bin/bash
# /bin/bash tests/update-summary.test.sh
# The update note: a bounded Haiku summary written at update time, shown once as a
# SessionStart systemMessage by announce-update.sh, with commit subjects as the
# fallback; and the launcher no longer types a first prompt for the user.
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
CL="$H/.update-changelog"; SM="$H/.update-summary"
export ANTHROPIC_API_KEY=sk-ant-test-not-real
unset MEGAVIBE_UPDATE_SUMMARY MEGAVIBE_UPDATE_SUMMARY_TIMEOUT

# --- stubs -------------------------------------------------------------------
# ok: records how it was called, prints a canned note. slow: sleeps past the bound.
# fail: exits 1. noisy: control characters and too many lines.
mkdir -p "$T/ok" "$T/slow" "$T/fail" "$T/noisy" "$T/none"
cat > "$T/ok/claude" <<'STUB'
#!/bin/bash
{ echo "ARGS: $*"; echo "CWD: $(pwd)"; echo "AGENT_HERE: $([ -e .agent ] && echo yes || echo no)"
  echo "KEY: ${ANTHROPIC_API_KEY:-unset}"; echo "STDIN<<"; cat; echo ">>"; } >> "$STUB_LOG"
printf 'Hooks now sync on every launch.\nThe update note no longer types a prompt for you.\n'
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
echo "partial output that must not be used"
exit 1
STUB
cat > "$T/noisy/claude" <<'STUB'
#!/bin/bash
printf '\n\nFirst line \033[31mred\033[0m and more text here.\n'
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "line $i of a long answer"; done
STUB
chmod +x "$T"/ok/claude "$T"/slow/claude "$T"/fail/claude "$T"/noisy/claude

# --- a source repo with commits ----------------------------------------------
SRC="$T/src"; mkdir -p "$SRC/template" && touch "$SRC/setup.sh"
git -C "$SRC" init -q -b main
git -C "$SRC" config user.email t@example.com; git -C "$SRC" config user.name t
commit() {  # commit <subject> [body]
  echo "$1" >> "$SRC/template/f.txt"; git -C "$SRC" add -A
  if [ -n "${2:-}" ]; then git -C "$SRC" commit -q -m "$1" -m "$2"; else git -C "$SRC" commit -q -m "$1"; fi
}
commit "base commit"
BASE=$(git -C "$SRC" rev-parse HEAD)
commit "Hooks sync on every launch" "The launcher now re-syncs hooks before it starts claude.

Co-authored-by: megavibe <megavibe@example.com>
Claude-Session: https://claude.ai/code/session_SECRETTRAILER"
commit "Update note is a message, not a typed prompt"
commit "Fix quoting in the restart path"
HEAD1=$(git -C "$SRC" rev-parse HEAD)

# --- harness: the launcher's own functions, run as the launcher runs them ---------
HAR="$T/harness.sh"
{
  echo 'set -euo pipefail'
  echo "MEGAVIBE_HOME='$H'; CHANGELOG_FILE='$CL'; UPDATE_SUMMARY_FILE='$SM'; GITHUB_REPO=x/y"
  echo "BOLD=; YELLOW=; GREEN=; RED=; DIM=; RESET=; UPDATE_SUMMARY_TEXT="
  for fn in is_git_source run_bounded condense_commits summarize_update git_commit_detail collect_changelog; do
    sed -n "/^$fn() {/,/^}/p" "$REPO/megavibe"
  done
  echo 'collect_changelog "$@"'
} > "$HAR"
bash -n "$HAR" || { echo "harness did not extract" >&2; exit 2; }

collect() {  # collect <stubdir> <old> <new> [env assignments...]; stub log in $T/log
  local d="$1" old="$2" new="$3"; shift 3
  rm -f "$T/log" "$T/log.pid1" "$T/log.pid2"
  env PATH="$d:$SYS" HOME="$T/home" STUB_LOG="$T/log" "$@" bash "$HAR" "${COLLECT_SRC:-$SRC}" "$old" "$new" >"$T/collect.out" 2>&1
}
announce() {  # announce [dir]: run the hook in a megavibe project, print its stdout
  local p="${1:-$T/proj}"; mkdir -p "$p/.agent"
  ( cd "$p" && env PATH="$SYS" HOME="$T/home" MEGAVIBE_HOME="$H" bash "$HOOK" 2>/dev/null )
}
reset() { rm -f "$H"/.update-* ; }

# 1. Summary generated, stored, keyed, and the claude call is the bounded no-tools shape.
reset; collect "$T/ok" "$BASE" "$HEAD1"; rc=$?
NEW8=$(printf '%s' "$HEAD1" | cut -c1-8)
check "collect_changelog exits 0" '[ $rc = 0 ]'
check "summary file keyed to the new version" '[ "$(head -n 1 "$SM")" = "megavibe-update-summary: $NEW8" ]'
check "summary body is the model output" 'grep -q "Hooks now sync on every launch." "$SM"'
check "changelog written too" 'head -n 1 "$CL" | grep -q "^megavibe updated: .* -> $NEW8 (3 commits)"'
check "one claude call" '[ "$(grep -c "^ARGS:" "$T/log")" = 1 ]'
check "print mode, haiku, no tools" 'grep -q "^ARGS: -p --model haiku --tools  --no-session-persistence" "$T/log"'
check "no session persistence, no skills, no MCP, no settings sources" 'a=$(grep "^ARGS:" "$T/log"); case "$a" in *--no-session-persistence*--disable-slash-commands*--strict-mcp-config*--setting-sources*) true ;; *) false ;; esac'
check "runs from a scratch directory with no .agent" 'grep -q "^AGENT_HERE: no" "$T/log" && ! grep "^CWD:" "$T/log" | grep -q "$REPO"'
check "API key masked for the call" 'grep -q "^KEY: unset" "$T/log"'
check "prompt carries the commit subjects and bodies" 'grep -q "Hooks sync on every launch" "$T/log" && grep -q "re-syncs hooks before it starts claude" "$T/log"'
check "prompt drops the attribution trailers" '! grep -q "SECRETTRAILER\|Co-authored-by" "$T/log"'
check "prompt tells the model the log is data" 'grep -q "DATA copied from commit messages" "$T/log"'

# 2. The hook shows it once, as a systemMessage only.
out=$(announce)
check "hook prints one JSON object" 'printf "%s" "$out" | jq -e . >/dev/null'
check "systemMessage carries the summary and the count" 'printf "%s" "$out" | jq -r .systemMessage | grep -q "megavibe updated (3 commits)" && printf "%s" "$out" | jq -r .systemMessage | grep -q "The update note no longer types a prompt for you."'
check "nothing is handed to the model" '[ "$(printf "%s" "$out" | jq -r "keys | join(\",\")")" = systemMessage ]'
check "claimed: changelog and summary both gone" '[ ! -e "$CL" ] && [ ! -e "$SM" ] && ! ls "$H"/.update-*claimed* >/dev/null 2>&1'
out2=$(announce)
check "second session: silent" '[ -z "$out2" ]'

# 3. Nothing changed: no summary, no changelog, no message, no claude call.
reset; collect "$T/ok" "$HEAD1" "$HEAD1"; rc=$?
check "same version: exit 0" '[ $rc = 0 ]'
check "same version: no files, no claude call" '[ ! -e "$CL" ] && [ ! -e "$SM" ] && [ ! -e "$T/log" ]'
check "same version: hook silent" '[ -z "$(announce)" ]'

# 4. claude fails: no summary, launch path still 0, hook falls back to subjects.
reset; collect "$T/fail" "$BASE" "$HEAD1"; rc=$?
check "failing claude: exit 0" '[ $rc = 0 ]'
check "failing claude: no summary stored, partial output not used" '[ ! -e "$SM" ] && [ -f "$CL" ]'
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
check "timeout: no summary, changelog intact" '[ ! -e "$SM" ] && [ -f "$CL" ]'
sleep 1
p1=$(cat "$T/log.pid1" 2>/dev/null || echo 0); p2=$(cat "$T/log.pid2" 2>/dev/null || echo 0)
check "timeout: the stub and its child are gone" '! kill -0 "$p1" 2>/dev/null && ! kill -0 "$p2" 2>/dev/null && [ "$p1" != 0 ] && [ "$p2" != 0 ]'
check "timeout: hook falls back to subjects" 'announce | jq -r .systemMessage | grep -q "^- Hooks sync on every launch"'

# 6. Switched off, or no claude / garbage timeout value.
reset; collect "$T/ok" "$BASE" "$HEAD1" MEGAVIBE_UPDATE_SUMMARY=0; rc=$?
check "MEGAVIBE_UPDATE_SUMMARY=0: exit 0, claude never called, changelog kept" '[ $rc = 0 ] && [ ! -e "$T/log" ] && [ ! -e "$SM" ] && [ -f "$CL" ]'
reset; collect "$T/none" "$BASE" "$HEAD1"; rc=$?
check "no claude on PATH: exit 0, fallback only" '[ $rc = 0 ] && [ ! -e "$SM" ] && [ -f "$CL" ]'
reset; collect "$T/ok" "$BASE" "$HEAD1" MEGAVIBE_UPDATE_SUMMARY_TIMEOUT=banana; rc=$?
check "unparseable timeout falls back to the default and still summarises" '[ $rc = 0 ] && [ -f "$SM" ]'
mkdir -p "$T/noperl"
for tool in bash git jq awk sed tr head tail cut mktemp cat env mv rm date wc grep find mkdir dirname sleep touch printf; do
  p=$(PATH="$SYS" command -v "$tool" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$T/noperl/$tool"
done
ln -sf "$T/ok/claude" "$T/noperl/claude"
reset; collect "$T/noperl" "$BASE" "$HEAD1" PATH="$T/noperl"; rc=$?
check "no perl: exit 0, no claude call (the bound cannot be enforced)" '[ $rc = 0 ] && [ ! -e "$T/log" ] && [ -f "$CL" ]'

# 7. Model output is sanitised and capped before it is stored and shown.
reset; collect "$T/noisy" "$BASE" "$HEAD1"; rc=$?
check "noisy output: stored" '[ $rc = 0 ] && [ -f "$SM" ]'
check "noisy output: no escape bytes stored" '! LC_ALL=C grep -q "$(printf "\033")" "$SM"'
check "noisy output: leading blank lines trimmed, at most 8 body lines" '[ "$(sed -n 2p "$SM" | cut -c1-10)" = "First line" ] && [ "$(tail -n +2 "$SM" | wc -l | tr -d " ")" -le 8 ]'

# 8. A summary for another version is never shown against this changelog.
reset; collect "$T/ok" "$BASE" "$HEAD1" >/dev/null
printf 'megavibe-update-summary: deadbeef\nstale note from an older range\n' > "$SM"
msg=$(announce | jq -r .systemMessage)
check "mismatched key: summary ignored, subjects shown" '! printf "%s" "$msg" | grep -q "stale note" && printf "%s" "$msg" | grep -q "^- Fix quoting"'
check "mismatched key: left in place for its own changelog" '[ -f "$SM" ]'
reset

# 9. Two updates with no session between: one chained range, one summary keyed to the latest.
commit "Second update lands" "Adds a thing."
HEAD2=$(git -C "$SRC" rev-parse HEAD)
reset; collect "$T/ok" "$BASE" "$HEAD1" >/dev/null; collect "$T/ok" "$HEAD1" "$HEAD2" >/dev/null
check "chained: changelog spans the whole range" 'head -n 1 "$CL" | grep -q "^megavibe updated: $(printf %s "$BASE" | cut -c1-8) -> $(printf %s "$HEAD2" | cut -c1-8) (4 commits)"'
check "chained: the second call saw both updates" 'grep -q "Hooks sync on every launch" "$T/log" && grep -q "Second update lands" "$T/log"'
check "chained: summary keyed to the latest version" '[ "$(head -n 1 "$SM")" = "megavibe-update-summary: $(printf %s "$HEAD2" | cut -c1-8)" ]'
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

# 11. Hook guards: outside a megavibe project it does nothing; an old changelog is dropped; two sessions, one note.
collect "$T/ok" "$BASE" "$HEAD1" >/dev/null
out=$( cd "$T" && mkdir -p plain && cd plain && env PATH="$SYS" HOME="$T/home" MEGAVIBE_HOME="$H" bash "$HOOK" 2>/dev/null )
check "no .agent: silent, nothing consumed" '[ -z "$out" ] && [ -f "$CL" ] && [ -f "$SM" ]'
touch -t 202001010000 "$CL"
check "changelog older than a week: silent" '[ -z "$(announce)" ]'
check "changelog older than a week: dropped with its summary" '[ ! -e "$CL" ] && [ ! -e "$SM" ]'
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
check "curl route: exit 0, summary keyed to the new version" '[ $rc = 0 ] && [ "$(head -n 1 "$SM")" = "megavibe-update-summary: bbbbbbbb" ] && head -n 1 "$CL" | grep -q "(2 commits)"'
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

# 14. Syntax of everything touched.
check "bash -n megavibe" 'bash -n "$REPO/megavibe"'
check "bash -n announce-update.sh" 'bash -n "$HOOK"'

printf 'update-summary tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
