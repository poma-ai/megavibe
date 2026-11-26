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
case "$1 $2" in
  "repo view") echo '{"nameWithOwner":"o/r"}' ;;
  "issue view") n=$3; [ "$n" != 99 ] || { echo "no such issue" >&2; exit 1; }
    st=OPEN; [ "$n" != 98 ] || st=CLOSED
    printf '{"title":"Fix thing %s\\twith a tab","body":"body of %s\\nline two","url":"https://github.com/o/r/issues/%s","state":"%s"}\n' "$n" "$n" "$n" "$st" ;;
  "issue list") echo "$*" >> "$LISTCALLS"; case "$*" in *"--label ready"*) printf '7\n9\n1\n' ;; esac ;;
  "pr list") [ ! -f "$PRFILE" ] || grep -F "$4" "$PRFILE" | head -1 | cut -d' ' -f2 ;;
esac
EOS
chmod +x "$B"/*; export PATH="$B:$PATH" HOME="$T/home" MEGAVIBE_HOME="$T/home/.megavibe" PRFILE="$T/prs" LISTCALLS="$T/list.calls"; unset CLAUDE_CODE_SESSION_ID
mkdir -p "$HOME" "$MEGAVIBE_HOME"
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

printf '%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
