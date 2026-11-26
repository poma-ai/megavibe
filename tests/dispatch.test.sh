#!/bin/bash
# /bin/bash tests/dispatch.test.sh
# scripts/megavibe-dispatch.sh against a scratch repo with a bare origin, a stub gh and a stub megavibe,
# on a PRIVATE tmux server (every tmux call goes through a wrapper on PATH that runs `env -u TMUX tmux -L
# <own socket>`). No tmux kill verb is used: panes started here are ended by pid and the server exits with
# its last session.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
REAL_TMUX=$(command -v tmux) || { echo "skip: tmux not installed"; exit 0; }
command -v jq >/dev/null || { echo "skip: jq not installed"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/dispatch-test.XXXXXX") || exit 2; T=$(cd "$T" && pwd -P)
SOCK="mvdtest-${T##*.}-$$"; PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
B="$T/bin"; mkdir -p "$B"
printf '#!/bin/bash\nexec env -u TMUX -u TMUX_PANE "%s" -L "%s" -f /dev/null "$@"\n' "$REAL_TMUX" "$SOCK" > "$B/tmux"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/megavibe.calls"\nexec sleep 600\n' "$T" > "$B/megavibe"
cat > "$B/gh" <<'EOS'
#!/bin/bash
# stub gh: issues 21 (title "VAGUE", asks the model-stub to flag it) and 22 (same, but opened by a bot); state in $LABELS ("N label") and $T files
jqx=""; a=("$@"); for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" != --jq ] || jqx="${a[i+1]}"; done
emit() { if [ -n "$jqx" ]; then jq -r "$jqx"; else cat; fi; }
case "$1 $2" in
  "repo view") echo '{"nameWithOwner":"o/r"}' ;;
  "issue view") n=$3; [ "$n" != 99 ] || { echo "no such issue" >&2; exit 1; }
    st=OPEN; [ "$n" != 98 ] || st=CLOSED; [ ! -f "$CLOSED" ] || ! grep -qx "$n" "$CLOSED" || st=CLOSED
    t="Fix thing $n"; case "$n" in 21|22) t="VAGUE $n" ;; esac
    au='{"login":"alice","is_bot":false}'; [ "$n" != 22 ] || au='{"login":"dependabot","is_bot":true}'
    lab=$(awk -v n="$n" '$1 == n { print $2 }' "$LABELS" 2>/dev/null | jq -R . | jq -s -c 'map({name: .})')
    jq -n -c --arg t "$t" --arg b "body of $n"$'\nline two' --arg u "https://github.com/o/r/issues/$n" --arg s "$st" --argjson l "${lab:-[]}" --argjson au "$au" --argjson num "$n" \
      '{number: $num, title: ($t + "\twith a tab"), body: $b, url: $u, state: $s, labels: $l, author: $au, comments: []}' | emit ;;
  "issue list") echo "$*" >> "$LISTCALLS"
    case "$*" in
      *"--label ready"*) printf '7\n9\n1\n' ;;
      *"--label needs-info"*|*"--label waiting"*) lab=needs-info; case "$*" in *waiting*) lab=waiting ;; esac
        awk -v l="$lab" '$2 == l { print $1 }' "$LABELS" 2>/dev/null | grep -vxF -f "$CLOSED" - 2>/dev/null || true ;;
    esac ;;
  "issue comment") n=$3; for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" != --body-file ] || cp "${a[i+1]}" "$T/comment.$n"; done
    echo "https://github.com/o/r/issues/$n#issuecomment-1" ;;
  "issue edit") n=$3; for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" != --add-label ] || echo "$n ${a[i+1]}" >> "$LABELS"; done ;;
  "label list") cat "$LABELEXIST" 2>/dev/null | jq -R '{name: .}' | jq -s -c . | emit ;;
  "label create") echo "$3" >> "$LABELEXIST" ;;
  "pr list") [ ! -f "$PRFILE" ] || grep -F "$4" "$PRFILE" | head -1 | cut -d' ' -f2 ;;
esac
EOS
cat > "$B/claude" <<'EOS'
#!/bin/bash
# stub claude: `auth status` says subscription; `-p` reads the prompt and answers fenced JSON, flagging VAGUE issues
if [ "$1" = auth ]; then if [ "$(cat "$HOME/claude.mode" 2>/dev/null)" = apikey ]; then echo '{"authMethod":"api_key"}'; else echo '{"authMethod":"claude.ai"}'; fi; exit 0; fi
p=$(cat); echo "$*" > "$HOME/claude.args"; printf '%s' "$p" > "$HOME/claude.prompt"; m=$(cat "$HOME/claude.mode" 2>/dev/null)
case "$p" in
  *'"title":"VAGUE'*) r=$'```json\n{"ready": false, "questions": ["What should the result look like? ping @evil", "Which version fails?"]}\n```' ;;
  *) r='{"ready": true, "questions": []}' ;;
esac
[ "$m" != broken ] || { echo "boom" >&2; exit 1; }
jq -n -c --arg r "$r" '{type: "result", is_error: false, result: $r}'
EOS
chmod +x "$B"/*; export PATH="$B:$PATH" HOME="$T/home" MEGAVIBE_HOME="$T/home/.megavibe" PRFILE="$T/prs" LISTCALLS="$T/list.calls" LABELS="$T/labels" LABELEXIST="$T/label.exist" CLOSED="$T/closed" T="$T"; unset CLAUDE_CODE_SESSION_ID
mkdir -p "$HOME" "$MEGAVIBE_HOME"; : > "$CLOSED"; : > "$LABELS"
end_panes() { local p i; [ "${OWN:-0}" = 1 ] || return 0
  for p in $(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null); do kill -HUP "$p" 2>/dev/null; done
  for i in 1 2 3 4 5 6; do tmux has-session 2>/dev/null || return 0; sleep 0.5; done
  for p in $(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done; }
cleanup() { end_panes; sleep 1; rm -rf "$T"; }; trap cleanup EXIT
tmux new-session -d -s guard sleep 600 || { echo "could not start private tmux"; exit 2; }
case "$(tmux display-message -p '#{socket_path}')" in */"$SOCK") OWN=1 ;; *) echo "ABORT: not the private socket"; exit 2 ;; esac

git init -q --bare "$T/origin.git"; git init -q -b main "$T/work/proj" 2>/dev/null || { mkdir -p "$T/work"; git init -q -b main "$T/work/proj"; }
P="$T/work/proj"; cd "$P" || exit 2
git config user.email t@t; git config user.name t; echo a > a; git add a; git commit -qm init
git remote add origin "$T/origin.git"; git push -q origin main; mkdir -p .agent .claude
D() { bash "$REPO/scripts/megavibe-dispatch.sh" "$@" 2>&1; }
Q="$MEGAVIBE_HOME/dispatch/proj"
called() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do grep -q -- "$1" "$T/megavibe.calls" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
st() { awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c }' "$Q/queue.tsv"; }

o=$(D add 1); check "add before start refuses ($o)" '[[ "$o" == *"no dispatcher yet"* ]]'
o=$(D start --max 2 --model sonnet); RC=$?
check "start: dispatcher window opened in session mvd-proj ($o)" '[ $RC = 0 ] && tmux list-windows -t =mvd-proj -F "#{window_name}" | grep -qx dispatcher'
check "start: dispatcher named, model passed, prompt points at ROLE.md" 'called "^--no-normalize --name dispatcher-proj --model sonnet You are the megavibe dispatcher for queue proj.*dispatch/ROLE.md"'
o=$(D start --max 2); check "start twice: no second dispatcher ($o)" '[[ "$o" == *"already runs"* ]] && [ "$(tmux list-windows -t =mvd-proj | wc -l | tr -d " ")" = 1 ]'

o=$(D add 1 https://github.com/o/r/issues/2 3 99 98 1)
check "add: three queued, unreadable and closed ones skipped, duplicate noted ($o)" '[ "$(st 1 2)" = queued ] && [ "$(st 2 2)" = queued ] && [ "$(st 3 2)" = queued ] && [ -z "$(st 99 2)" ] && [ -z "$(st 98 2)" ] && [[ "$o" == *"issue 1: already in the queue"* ]] && [[ "$o" == *"issue 98: not open"* ]]'
check "add: title kept on one line (tab removed)" '[ "$(awk -F"\t" "NF != 8" "$Q/queue.tsv" | wc -l | tr -d " ")" = 0 ]'
check "add: task file holds the issue text fenced, the branch, the PR rule and the report line" 'grep -q "line two" "$Q/tasks/issue-1.md" && grep -q "dispatch/issue-1" "$Q/tasks/issue-1.md" && grep -q "Closes #1" "$Q/tasks/issue-1.md" && grep -q "dispatcher-proj" "$Q/tasks/issue-1.md"'

o=$(D tick); RC=$?
check "tick: starts exactly max=2 sessions, third stays queued ($o)" '[ $RC = 0 ] && [ "$(st 1 2)" = running ] && [ "$(st 2 2)" = running ] && [ "$(st 3 2)" = queued ]'
W1="$T/work/proj-issue-1"
check "tick: worktree cut from origin/main on branch dispatch/issue-1, context linked" '[ "$(git -C "$W1" rev-parse --abbrev-ref HEAD)" = dispatch/issue-1 ] && [ "$(git -C "$W1" rev-parse HEAD)" = "$(git -C "$P" rev-parse origin/main)" ] && [ -L "$W1/.agent" ] && [ -L "$W1/.claude" ]'
check "tick: windows issue-1 and issue-2 exist, megavibe got name, model and the task prompt" 'tmux list-windows -t =mvd-proj -F "#{window_name}" | grep -qx issue-1 && called "^--no-normalize --name proj-issue-1 --model sonnet --session-id [0-9a-f-]\{36\} Use the work-ticket skill on the task file $Q/tasks/issue-1.md.*dispatcher-proj"'
check "status: lists running with idle time" 'D status | grep -q "^running .*#1 .*idle 0m"'
check "peek: works on a running window, refuses a missing one" 'D peek 1 >/dev/null && ! D peek 3 >/dev/null'

# a session ends with a PR; the slot is refilled
pid=$(tmux list-windows -t =mvd-proj -F '#{window_name} #{pane_pid}' | awk '$1 == "issue-1" { print $2 }'); kill -HUP "$pid"; sleep 1
echo "dispatch/issue-1 https://github.com/o/r/pull/11" > "$PRFILE"
o=$(D tick)
check "tick: ended session with a PR becomes pr with its URL, slot refilled with issue 3 ($o)" '[ "$(st 1 2)" = pr ] && [ "$(st 1 7)" = "https://github.com/o/r/pull/11" ] && [ "$(st 3 2)" = running ]'
pid=$(tmux list-windows -t =mvd-proj -F '#{window_name} #{pane_pid}' | awk '$1 == "issue-2" { print $2 }'); kill -HUP "$pid"; sleep 1
o=$(D tick); [ -z "${DBG:-}" ] || { echo "--- $o"; tmux list-windows -t =mvd-proj -F "#{window_name} #{pane_pid} #{pane_dead}"; }
check "tick: ended session without a PR becomes ended and says so ($o)" '[ "$(st 2 2)" = ended ] && [[ "$o" == *"NO pull request"* ]]'
o=$(D requeue 2); check "requeue: ended goes back to queued; a running one is refused" '[ "$(st 2 2)" = queued ] && ! D requeue 3 >/dev/null'
D max 1 >/dev/null; o=$(D tick); check "max 1 with one running: nothing new starts ($o)" '[ "$(st 2 2)" = queued ] && [[ "$o" == *"1 running (max 1)"* ]]'
D done 1 >/dev/null; D drop 2 >/dev/null; check "done/drop set states" '[ "$(st 1 2)" = done ] && [ "$(st 2 2)" = dropped ]'
check "a dropped issue can be queued again" 'D add 2 | grep -q "queued" && [ "$(st 2 2)" = queued ]'
check "the main checkout was never touched" '[ "$(git -C "$P" rev-parse --abbrev-ref HEAD)" = main ] && [ -z "$(git -C "$P" status --porcelain | grep -v "^??")" ]'

o=$(D add --label ready --label p1 --limit 5)
check "add --label: gh asked for open issues with both labels and the limit ($(cat "$LISTCALLS"))" 'grep -q -- "--label ready --label p1 --state open --limit 5" "$LISTCALLS"'
check "add --label: new ones queued, the one already known skipped ($o)" '[ "$(st 7 2)" = queued ] && [ "$(st 9 2)" = queued ] && [[ "$o" == *"issue 1: already in the queue"* ]] && [[ "$o" == *"3 open issue(s)"* ]]'
o=$(D add --label nothing); check "add --label with no match is fine ($o)" '[[ "$o" == *"0 open issue(s)"* ]]'
check "add with nothing to add or a bad option refuses" '! D add >/dev/null && ! D add --bogus >/dev/null && ! D add --limit x 1 >/dev/null'

check "no skill configured: task file has no Implementation skill line" '! grep -q "^Implementation skill:" "$Q/tasks/issue-1.md"'
D start --skill implement-and-review >/dev/null; D add 5 >/dev/null
check "start --skill: later task files carry the Implementation skill line" 'grep -qx "Implementation skill: implement-and-review" "$Q/tasks/issue-5.md"'
check "start --skill rejects an unusable name" '! D start --skill "a b" >/dev/null'
check "the work-ticket skill ships and is self-contained (names no other skill)" '[ -f "$REPO/template/.claude/skills/work-ticket/SKILL.md" ] && ! grep -q "implement-and-review" "$REPO/template/.claude/skills/work-ticket/SKILL.md"'

D max 20 >/dev/null; D add 11 >/dev/null; D tick >/dev/null
o=$(D block 11); check "block: frees the slot, window stays ($o)" '[ "$(st 11 2)" = blocked ] && tmux list-windows -t =mvd-proj -F "#{window_name}" | grep -qx issue-11'
o=$(D requeue 11); check "requeue of a blocked issue whose window is still open is refused ($o)" '[ "$(st 11 2)" = blocked ] && [[ "$o" == *"still has its window open"* ]]'
pid=$(tmux list-windows -t =mvd-proj -F '#{window_name} #{pane_pid}' | awk '$1 == "issue-11" { print $2 }'); kill -HUP "$pid"; sleep 1
o=$(D requeue 11); check "requeue after the window closed rewrites the task file and queues it ($o)" '[ "$(st 11 2)" = queued ] && grep -q "body of 11" "$Q/tasks/issue-11.md"'
for s in work-ticket triage-ticket; do check "skill $s: front matter name and no mention of another skill's name" 'head -2 "$REPO/template/.claude/skills/$s/SKILL.md" | grep -qx "name: $s" && ! grep -q "implement-and-review" "$REPO/template/.claude/skills/$s/SKILL.md"'; done
check "work-ticket and the task file both route missing info to the issue, the author and the marker" 'grep -q "megavibe:needs-info" "$REPO/template/.claude/skills/work-ticket/SKILL.md" && grep -q "ask for it on the issue" "$Q/tasks/issue-5.md"'

# ── pre-check, label flow ─────────────────────────────────────────────
rm -f "$HOME/claude.prompt"
o=$(D add 21 22 20); o2=$(D tick); W=$(tmux list-windows -t =mvd-proj -F "#{window_name}")
check "precheck: a vague issue is blocked without a session, a clear one starts ($o2)" '[ "$(st 21 2)" = blocked ] && ! grep -qx issue-21 <<<"$W" && [ "$(st 20 2)" = running ] && grep -qx issue-20 <<<"$W"'
check "precheck: the call is tool-less, settings-less, sessionless" 'grep -q -- "--no-session-persistence --disable-slash-commands --strict-mcp-config --setting-sources" "$HOME/claude.args" && grep -q -- "--tools" "$HOME/claude.args"'
check "precheck: the comment mentions the author, numbers the questions, neutralises a model-written mention, carries the marker and the label name" 'head -c 6 "$T/comment.21" | grep -q "^@alice" && grep -q "^1\. What should the result look like" "$T/comment.21" && grep -q "^2\. Which version fails" "$T/comment.21" && ! grep -q "@evil" "$T/comment.21" && grep -q "(at) evil" "$T/comment.21" && grep -q "megavibe:needs-info" "$T/comment.21" && grep -q "needs-info" "$T/comment.21"'
check "precheck: the label was created and put on the issue; the comment URL is kept" 'grep -qx needs-info "$LABELEXIST" && grep -qx "21 needs-info" "$LABELS" && [[ "$(st 21 7)" == *issuecomment* ]]'
check "precheck: a bot author is not mentioned" 'grep -q "^to start work" "$T/comment.22" && ! grep -q "@dependabot" "$T/comment.22"'

rm -f "$HOME/claude.prompt"; o=$(D tick)
check "tick again: a blocked issue is not asked about twice, no model call" '[ ! -f "$HOME/claude.prompt" ] && [ "$(ls "$T"/comment.21* | wc -l | tr -d " ")" = 1 ]'

grep -v "^21 " "$LABELS" > "$LABELS.n"; mv "$LABELS.n" "$LABELS"; rm -f "$HOME/claude.prompt"
o=$(D tick); W=$(tmux list-windows -t =mvd-proj -F "#{window_name}")
check "label removed: the issue goes and starts without a second check ($o)" '[ "$(st 21 2)" = running ] && grep -qx issue-21 <<<"$W" && [ ! -f "$HOME/claude.prompt" ] && grep -q "line two" "$Q/tasks/issue-21.md"'
check "a task file names the waiting label" 'grep -qx "Needs-info label: needs-info" "$Q/tasks/issue-21.md"'

echo 22 > "$CLOSED"; o=$(D tick)
check "a blocked issue closed meanwhile is dropped, not started ($o)" '[ "$(st 22 2)" = dropped ]'
: > "$CLOSED"

echo broken > "$HOME/claude.mode"; D add 23 >/dev/null; o2=$(D tick)
check "claude failing: the issue is let through ($o2)" '[ "$(st 23 2)" = running ] && [[ "$o2" == *"precheck skipped (the claude call failed"* ]]'
echo apikey > "$HOME/claude.mode"; D add 24 >/dev/null; o2=$(D tick)
check "an API-key login is refused for the check, the issue is let through ($o2)" '[ "$(st 24 2)" = running ] && [[ "$o2" == *"not a claude.ai subscription login"* ]]'
echo ok > "$HOME/claude.mode"

echo "25 needs-info" >> "$LABELS"; D add 25 >/dev/null; o=$(D tick)
check "an issue that already carries the label is blocked without a model call ($o)" '[ "$(st 25 2)" = blocked ] && [[ "$o" == *"already carries"* ]]'
grep -v "^11 " "$LABELS" > "$LABELS.n"; mv "$LABELS.n" "$LABELS"
D done 20 >/dev/null; o=$(D block 20)
check "block adds the label to the issue ($o)" 'grep -qx "20 needs-info" "$LABELS"'

D start --no-precheck --needs-label waiting >/dev/null
check "start --no-precheck --needs-label: stored" '[ "$(awk -F= "\$1 == \"precheck\" { print \$2 }" "$Q/conf")" = off ] && [ "$(awk -F= "\$1 == \"label\" { print \$2 }" "$Q/conf")" = waiting ]'
D drop 22 >/dev/null; D add 22 >/dev/null; o=$(D tick)
check "precheck off: the vague issue starts anyway ($o)" '[ "$(st 22 2)" = running ]'
check "an unusable label name is refused" '! D start --needs-label "a b" >/dev/null'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
