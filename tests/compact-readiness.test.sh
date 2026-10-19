#!/bin/bash
# /bin/bash tests/compact-readiness.test.sh [--mutations]
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOKS="$REPO/template/.claude/hooks"
T=$(mktemp -d "${TMPDIR:-/tmp}/register-check.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
export TEST_HOME="$T/home"
mkdir -p "$TEST_HOME/.megavibe"
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW MEGAVIBE_LAUNCH_VERSION \
  MEGAVIBE_READY_DECISION_RE MEGAVIBE_READY_TASKS_LAG_MIN \
  MEGAVIBE_READY_TASKS_MIN_EVENTS MEGAVIBE_READY_ADVISORY_LIMIT MEGAVIBE_BG_CHECK_SECS \
  MEGAVIBE_CLOSEOUT MEGAVIBE_CLOSEOUT_SOFT_PCT MEGAVIBE_CLOSEOUT_HARD_PCT \
  MEGAVIBE_CLOSEOUT_REMIND_EVERY 2>/dev/null
export CLAUDE_CODE_SESSION_ID=""
export MEGAVIBE_WATCHER=0

if [ "${1:-}" = "--mutations" ]; then
  python3 - "$REPO" "$T" <<'PY'
from pathlib import Path
import re
import shutil
import subprocess
import sys

repo, scratch = map(Path, sys.argv[1:])
hook = "template/.claude/hooks/"
mutations = [
    ("decision detection disabled", hook + "compact-readiness.sh",
     'MARKER = r"^(DECISION:|D[0-9]+( |:)|Decided:)"',
     'MARKER = r"^NEVER_A_MARKER:"'),
    ("task finding disabled", hook + "compact-readiness.sh",
     "elif count or len(newer) >= minimum:", "elif False:"),
    ("coverage record ignored", hook + "compact-readiness.sh",
     "n not in covered", 'n > max(covered, default="")'),
]
def run(root):
    return subprocess.run(["/bin/bash", str(root / "tests/compact-readiness.test.sh")],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
baseline = run(repo)
print(baseline.stdout, end="")
if baseline.returncode:
    sys.exit("Baseline must pass before mutation testing")
for index, (label, filename, old, new) in enumerate(mutations):
    root = scratch / str(index)
    shutil.copytree(repo / "template/.claude/hooks", root / "template/.claude/hooks")
    shutil.copytree(repo / "scripts", root / "scripts")
    shutil.copy2(repo / "README.md", root / "README.md")
    shutil.copy2(repo / "template/CLAUDE.md", root / "template/CLAUDE.md")
    (root / "tests").mkdir()
    shutil.copy2(repo / "tests/compact-readiness.test.sh", root / "tests")
    path = root / filename
    source = path.read_text()
    if old not in source:
        sys.exit("Mutation target missing: " + label)
    source = source.replace(old, new)
    path.write_text(source)
    result = run(root)
    match = re.search(r"(\d+) passed, (\d+) failed", result.stdout)
    if not match or not int(match[2]) or result.returncode != 1:
        print(result.stdout)
        sys.exit("Mutation survived or harness failed: " + label)
    print("%s: %s failed" % (label, match[2]))
PY
  exit $?
fi

P="$T/project"
SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
SID12="${SID:0:12}"
SIBLING="aaaaaaaa-bbbb-ffff-ffff-ffffffffffff"
OTHER="ffffffff-0000-1111-2222-333333333333"
PASS=0; FAIL=0; OUT=""; RC=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n%s\n' "$1" "$OUT"; }
eq() { if [ "$1" = "$2" ]; then ok; else bad "$3 (got $1, want $2)"; fi; }
has() { if printf '%s' "$OUT" | grep -F -- "$1" >/dev/null; then ok; else bad "$2"; fi; }
lacks() { if printf '%s' "$OUT" | grep -F -- "$1" >/dev/null; then bad "$2"; else ok; fi; }
exists() { if [ -e "$1" ]; then ok; else bad "$2"; fi; }
absent() { if [ -e "$1" ]; then bad "$2"; else ok; fi; }
R() { OUT=$(cd "$P" && /bin/bash .claude/hooks/compact-readiness.sh "$@" 2>&1); RC=$?; }
event() {
  LAST="20261018T120000Z-host-$1.md"
  shift
  printf '%s\n' "$@" > "$P/.agent/events/$LAST"
}
fresh() {
  rm -rf "$P"
  mkdir -p "$P/.agent/events" "$P/.agent/LOGS" "$P/.agent/sessions" "$P/.claude/hooks"
  for h in compact-readiness on-pre-compact compaction-autopilot log-tool-event redact-secrets agent-log watch-background; do
    # Redirect home references only in scratch copies; leave caller home alone.
    sed 's/${HOME}/${TEST_HOME}/g; s/$HOME/$TEST_HOME/g' \
      "$HOOKS/$h.sh" > "$P/.claude/hooks/$h.sh"
    chmod +x "$P/.claude/hooks/$h.sh"
  done
  printf '# Decisions\n' > "$P/.agent/DECISIONS.md"
  printf '# Tasks\n| T1 | open | blocked on review |\n' > "$P/.agent/TASKS.md"
  CP="$P/.agent/.registers-checkpoint"
  QUEUE="$P/.agent/LOGS/pending-decisions.$SID12.jsonl"
  TR="$P/transcript.jsonl"
}
usage() {
  printf '{"type":"assistant","message":{"usage":{"input_tokens":%s}}}\n' "$1" > "$TR"
  echo 1000000 > "$P/.agent/LOGS/.ctx-size.$SID12"
}
mark() { R --session "$SID" --mark "$@"; eq "$RC" 0 "mark succeeds"; }
pending() {
  printf '{"status":"pending","session_id":"%s","staged_at":"%s","title":"review item"}\n' \
    "$SID12" "$1" >> "$QUEUE"
}

echo "== Fresh project and informational checks"
fresh
R --session "$SID"
eq "$RC" 0 "fresh project ready"
has "compact-readiness: READY" "ready verdict"
has "session $SID [--session]" "explicit identity"
has "no WORKING_CONTEXT" "missing working context informs"
lacks "[!]" "no blockers"
absent "$CP" "reading does not write checkpoint"
R --session "$SID" --mark
eq "$RC" 0 "empty-event checkpoint allowed"
eq "$(cat "$CP")" "covered-through " "empty coverage record"
mkdir -p "$P/.agent/sessions/$SID"
echo context > "$P/.agent/sessions/$SID/WORKING_CONTEXT.md"
R --session "$SID12"
has "/rehydrate optional" "unambiguous prefix finds context"
python3 - "$P/.agent/sessions/$SID/WORKING_CONTEXT.md" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time()-7200, time.time()-7200))
PY
R --session "$SID"
eq "$RC" 0 "old context does not block"
has "/rehydrate required" "old context reported"
(cd "$P" && git init -q)
R --session "$SID"
has "uncommitted work:" "git state reported"

echo "== Findings 1, 4, 7: markers, citations and same-second ordering"
fresh
event 001 "DECISION: supersede D22 in DECISIONS.md; use a local store."
R --session "$SID"
eq "$RC" 1 "decision citing register blocks"
has "[!] DECISIONS.md" "decision blocker"
has "[!] TASKS.md" "one decision requires task reconciliation"
mark
eq "$(head -1 "$CP")" "covered-through $LAST" "complete newest filename"
R --session "$SID"
eq "$RC" 0 "same-second covered event stays covered"
event 000 "DECISION: lexically earlier."
R --session "$SID"
eq "$RC" 1 "earlier same-second append remains uncovered"
event 002 "D23: choose a bounded queue."
python3 - "$P" <<'PY'
from pathlib import Path
import os, sys
for p in (Path(sys.argv[1]) / ".agent/events").iterdir():
    os.utime(p, (100, 100))
PY
R --session "$SID"
eq "$RC" 1 "later suffix reopens despite identical old mtimes"
has "2 marked-decision events" "both new identities remain uncovered"
mark
event 003 "D24 chosen with a reason."
event 004 "Decided: retain the interface."
R --session "$SID"
has "2 marked-decision events" "alternate markers"
mark
for prose in "No decisions were made" "vitamin D3" \
  "The default A record TTL is 300 seconds" "DECIDED: retain the interface" \
  "We selected a local store because offline access is required"; do
  event 005 "$prose"
  R --session "$SID"
  eq "$RC" 0 "unstructured prose alone never blocks"
  has "advisory" "loose match printed"
done

echo "== Findings 2 and 11: task currency and decimal settings"
fresh
event 001 "T1 finished"
event 002 "T1 verified"
R --session "$SID"
eq "$RC" 0 "under default threshold"
event 003 "T1 shipped"
R --session "$SID"
eq "$RC" 1 "three events block tasks"
has "[!] TASKS.md" "task blocker"
printf '\n<!-- watcher notes -->\nT99: unrelated note\n' >> "$P/.agent/TASKS.md"
touch "$P/.agent/DECISIONS.md" "$P/.agent/TASKS.md"
R --session "$SID"
eq "$RC" 1 "watcher write cannot mask T1"
has "[!] TASKS.md" "touching both registers cannot clear blocker"
export MEGAVIBE_READY_TASKS_MIN_EVENTS=08
R --session "$SID"
eq "$RC" 0 "08 is decimal eight"
for n in 004 005 006 007 008; do event "$n" "progress"; done
R --session "$SID"
eq "$RC" 1 "eight events meet decimal threshold"
for n in bad -1 0 999999999999999999999; do
  export MEGAVIBE_READY_TASKS_MIN_EVENTS="$n"
  R --session "$SID"
  eq "$RC" 2 "invalid setting rejected"
done
unset MEGAVIBE_READY_TASKS_MIN_EVENTS
export MEGAVIBE_BG_CHECK_SECS=08
R --session "$SID"
eq "$RC" 1 "08 heartbeat setting does not drop task check"
unset MEGAVIBE_BG_CHECK_SECS
export MEGAVIBE_READY_TASKS_LAG_MIN=08
R --session "$SID"
eq "$RC" 2 "retired lag setting explicitly rejected"
unset MEGAVIBE_READY_TASKS_LAG_MIN

echo "== Findings 5 and 6: session identity"
fresh
touch "$P/.agent/LOGS/.tool-call-counter.$SID12"
touch "$P/.agent/LOGS/.tool-call-counter.${OTHER:0:12}"
R
eq "$RC" 2 "two recent counters require identity"
has "ambiguous session: pass --session" "ambiguity message"
export CLAUDE_CODE_SESSION_ID="$SID"
R
eq "$RC" 0 "environment identifies session"
export CLAUDE_CODE_SESSION_ID=""
mkdir -p "$P/.agent/sessions/$SIBLING"
echo sibling > "$P/.agent/sessions/$SIBLING/WORKING_CONTEXT.md"
NOW=$(date +%s)
printf '{"id":"job","kind":"shell","nudged":%s}\n' "$NOW" \
  > "$P/.agent/LOGS/.bg-tasks.$SIBLING.jsonl"
R --session "$SID"
eq "$RC" 0 "full id never loads sibling heartbeat"
has "no WORKING_CONTEXT for session $SID" "full id never loads sibling context"
mkdir -p "$P/.agent/sessions/$SID"
R --session "$SID12"
eq "$RC" 2 "ambiguous prefix rejected"
fresh
touch "$P/.agent/LOGS/.tool-call-counter.$SID12"
touch "$P/.agent/LOGS/.tool-call-counter.$SID12.lock"
R
eq "$RC" 0 "single counter resolves; lock ignored"
has "recent tool-call counter" "counter identity explained"
echo "== Background heartbeat coverage"
fresh
NOW=$(date +%s)
printf '{"id":"job","kind":"shell","path":"","started":1,"nudged":%s}\n' "$NOW" \
  > "$P/.agent/LOGS/.bg-tasks.$SID.jsonl"
printf '{"session_id":"%s","background_tasks":[{"id":"job","status":"running"}]}\n' "$SID" > "$P/live.json"
R --session "$SID" --hook-input "$P/live.json"
eq "$RC" 1 "live missing heartbeat blocks"
has "background shell task job" "task named"
R --session "$SID12" --hook-input "$P/live.json"
eq "$RC" 1 "unambiguous prefix finds heartbeat"
# A live entry may carry "command": null; watch-background.sh reads it as "" (.command // ""), so must this.
printf '{"session_id":"%s","background_tasks":[{"id":"job","status":"running","command":null},{"id":"m","status":"running","command":null}]}\n' "$SID" > "$P/live.json"
R --session "$SID" --hook-input "$P/live.json"
eq "$RC" 1 "null live commands still yield a finding, not exit 2"
has "background shell task job" "task named with null commands"
printf '{"session_id":"%s","background_tasks":[{"id":"job","status":"running","command":null},{"id":"m","status":"running","command":"tail -f job.out"}]}\n' "$SID" > "$P/live.json"
R --session "$SID" --hook-input "$P/live.json"
eq "$RC" 0 "null command on the covered task keeps the heartbeat visible"
printf '{"id":"old","nudged":%s}\n{"id":"quiet","nudged":0}\n' "$((NOW - 5000))" \
  > "$P/.agent/LOGS/.bg-tasks.$SID.jsonl"
R --session "$SID"
eq "$RC" 0 "old or absent nudge informs"
has "earlier heartbeat nudge" "old nudge visible"

echo "== Finding 10: missing values terminate"
fresh
for option in --project --session --hook-input --fold-before; do
  OUT=$(python3 - "$P/.claude/hooks/compact-readiness.sh" "$option" <<'PY'
import subprocess, sys
try:
    r = subprocess.run(["/bin/bash", sys.argv[1], sys.argv[2]],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, timeout=3)
    print(r.stdout, end="")
    sys.exit(r.returncode)
except subprocess.TimeoutExpired:
    print("option parser timed out")
    sys.exit(124)
PY
)
  RC=$?
  eq "$RC" 2 "bare $option"
done
R --bogus
eq "$RC" 2 "unknown argument"
R --project "$T"
eq "$RC" 2 "no project state"
for option in --force --staged-handled --decisions-since; do
  R "$option"
  eq "$RC" 2 "removed option rejected"
done
R --session ""
eq "$RC" 2 "empty identity rejected"
R --session ../escape
eq "$RC" 2 "unsafe identity rejected"

echo "== Report integration and resilience"
fresh
event 001 "DECISION: ship the verified result."
OUT=$(cd "$P" && printf '{"session_id":"%s","transcript_path":"/nonexistent"}' "$SID" |
  /bin/bash .claude/hooks/on-pre-compact.sh 2>/dev/null)
eq "$?" 0 "pre-compact hook exits successfully"
has '"systemMessage"' "legacy message preserved"
OUT=$(cat "$P/.agent/LOGS/pre-compact-alert.$SID12.md")
has "COMPACT READINESS — ADVISORY (exit 1" "alert carries exit"
has "1 marked-decision events" "alert carries count"
has "Newest .agent/events entry:" "existing alert preserved"
# The pre-compact hook stamps the post-compaction cooldown, which silences tier nudges by design; start a fresh project for the tier path.
fresh
event 001 "DECISION: ship the verified result."
usage 800000
OUT=$(cd "$P" && printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"%s","transcript_path":"%s","tool_input":{"command":"true"},"tool_response":{}}' \
  "$SID" "$TR" | /bin/bash .claude/hooks/log-tool-event.sh 2>/dev/null)
eq "$?" 0 "tool hook exits successfully"
has "Context ~800K" "tier two nudge"
has "compact-readiness: NOT READY" "tier carries report"
has "record coverage" "tier names remedy"
# The nudge budget is on the JSON-escaped form: control characters escape at 6 chars each (ship round 2, P3).
fresh
ESC=$(printf '\033%.0s' $(seq 1 200))
for i in $(seq 1 25); do event "$(printf '%03d' "$i")" "We selected ${ESC} this"; done
usage 800000
OUT=$(cd "$P" && printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"%s","transcript_path":"%s","tool_input":{"command":"true"},"tool_response":{}}' \
  "$SID" "$TR" | /bin/bash .claude/hooks/log-tool-event.sh 2>/dev/null)
eq "$?" 0 "tool hook survives control characters"
has "report truncated" "escaped report is truncated"
[ "${#OUT}" -le 10000 ]; eq "$?" 0 "serialized hook output stays under the 10,000-character delivery limit (${#OUT})"
echo "== Round 2 P2-4: folding refuses uncovered events and prunes coverage"
fresh
printf 'DECISION: old unreviewed decision\n' > "$P/.agent/events/20260901T000000Z-host-old.md"
OUT=$(cd "$P" && /bin/bash .claude/hooks/agent-log.sh fold --before 2026-10-01 2>&1); RC=$?
eq "$RC" 2 'fold refuses uncovered decision'
exists "$P/.agent/events/20260901T000000Z-host-old.md" 'refused fold retains event'
R --session "$SID"
eq "$RC" 1 'refused fold retains readiness blocker'
mark
OUT=$(cd "$P" && /bin/bash .claude/hooks/agent-log.sh fold --before 2026-10-01 2>&1); RC=$?
eq "$RC" 0 'covered fold succeeds'
absent "$P/.agent/events/20260901T000000Z-host-old.md" 'covered event moved'
OUT=$(cat "$P/.agent/snapshot.md")
has 'DECISION: old unreviewed decision' 'snapshot preserves history'
has 'registers-fold-cutoff: 20261001' 'snapshot records pruning cutoff'
OUT=$(cat "$CP")
lacks '20260901' 'fold prunes obsolete coverage identity'
printf 'DECISION: late old arrival\n' > "$P/.agent/events/20260901T000000Z-host-late.md"
R --session "$SID"
eq "$RC" 1 'late pre-cutoff identity still blocks'
mark
R --session "$SID"
eq "$RC" 0 'late old reviewed identity stays covered until folded'
printf 'DECISION: preserve this byte: \377\n' > "$P/.agent/events/20260902T000000Z-host-bytes.md"
R --session "$SID"
eq "$RC" 1 'event with invalid UTF-8 still reports its decision'
mark
OUT=$(cd "$P" && /bin/bash .claude/hooks/agent-log.sh fold --before 2026-10-01 2>&1); RC=$?
eq "$RC" 0 'fold of an invalid UTF-8 event succeeds'
absent "$P/.agent/events/20260902T000000Z-host-bytes.md" 'invalid UTF-8 event moved'
bytes() { python3 -c 'import sys; d = open(sys.argv[1], "rb").read(); print(d.count(b"\xff"), d.count(b"\xef\xbf\xbd"))' "$1"; }
eq "$(bytes "$P/.agent/snapshot.md")" "1 0" 'fold copies event bytes unchanged (no replacement character)'
OUT=$(cat "$P/.agent/snapshot.md")
has 'DECISION: late old arrival' 'second fold keeps earlier history'

echo "== Round 2 P2-5: live Monitor overrides historical nudge"
fresh
printf '{"id":"job","path":"/fixture/job.output","kind":"shell","started":1,"nudged":%s}\n' "$(date +%s)" \
  > "$P/.agent/LOGS/.bg-tasks.$SID.jsonl"
R --session "$SID"
eq "$RC" 0 'historical nudge alone is advisory'
has '[ADVISORY]' 'historical nudge labelled advisory'
printf '{"hook_event_name":"Stop","session_id":"%s","background_tasks":[{"id":"job","status":"running"},{"id":"monitor","status":"running","command":"tail /fixture/job.output"}]}\n' "$SID" > "$P/live.json"
OUT=$(cd "$P" && /bin/bash .claude/hooks/watch-background.sh < live.json 2>&1)
eq "$OUT" '' 'real background watcher accepts Monitor'
R --session "$SID" --hook-input "$P/live.json"
eq "$RC" 0 'live coverage clears readiness blocker immediately'
has 'earlier heartbeat nudge' 'historical nudge remains advisory'
echo "== Round 2 P2-6: bounded advisories"
fresh
usage 960000
python3 - "$P/.agent/events/20261018T120000Z-host-noise.md" <<'PYNOISE'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(('We selected '+('x'*2048)+'\n')*1300)
PYNOISE
R --session "$SID"
REPORT="$T/advisory-report"
printf '%s\n' "$OUT" > "$REPORT"
OUT=$(python3 - "$REPORT" <<'PYBOUND'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
lines=[line for line in text.splitlines() if line.startswith('- [ADVISORY]')]
assert len(lines)==21, len(lines)
assert max(map(len,lines))<=200
assert 'and 1280 more' in text
assert len(text)<6000
print('20 previews; 200 characters maximum; and 1280 more')
PYBOUND
)
eq "$?" 0 'large advisory report is bounded'
echo "== Round 2 P3-7: authoritative short session identity"
fresh
SHORT=abcdefabcdef
mkdir -p "$P/.agent/sessions/$SHORT" "$P/.agent/sessions/$SHORT-other"
printf '{"id":"short-job","kind":"shell","started":1,"nudged":0}\n' > "$P/.agent/LOGS/.bg-tasks.$SHORT.jsonl"
printf '{"session_id":"%s","background_tasks":[{"id":"short-job","status":"running"}]}\n' "$SHORT" > "$P/live.json"
R --session "$SHORT" --hook-input "$P/live.json"
eq "$RC" 1 'exact short session sees own live blocker'
has "session $SHORT [--session]" 'exact short identity retained'
has 'short-job' 'exact short task found'

echo "== Round 2 P3-8: code fences and CRLF"
fresh
event 001 '```text' 'DECISION: fixture only' 'D3: fixture' 'Decided: example' '```'
R --session "$SID"
eq "$RC" 0 'fenced markers do not block'
has '0 marked-decision events' 'fenced markers not counted'
event 002 '````' '```' 'DECISION: nested fence example' '````'
R --session "$SID"
eq "$RC" 0 'shorter nested fence does not close outer fence'
printf '```\r\nDECISION: fixture\r\n```\r\nDECISION: actual decision\r\n' > "$P/.agent/events/$LAST"
R --session "$SID"
eq "$RC" 1 'outside CRLF marker still blocks'

echo "== Round 2 P3-9: missing Python and integration reports"
mkdir -p "$T/no-python"
python3 - "$T/no-python" <<'PYPATH'
import os, pathlib, sys
root=pathlib.Path(sys.argv[1])
for directory in os.get_exec_path():
    p=pathlib.Path(directory)
    if not p.is_dir(): continue
    for executable in p.iterdir():
        try:
            if executable.name.startswith('python') or not executable.is_file(): continue
            target=root/executable.name
            if not target.exists(): target.symlink_to(executable.resolve())
        except PermissionError:
            continue
PYPATH
eq "$?" 0 'no-Python PATH fixture built'
fresh
SAVED_PATH="$PATH"
export PATH="$T/no-python"
R --session "$SID"
eq "$RC" 2 'missing Python exits two'
has 'python3 is required' 'direct dependency diagnostic'
OUT=$(cd "$P" && printf '{"session_id":"%s"}' "$SID" | /bin/bash .claude/hooks/on-pre-compact.sh 2>/dev/null)
eq "$?" 0 'precompact remains resilient without Python'
OUT=$(cat "$P/.agent/LOGS/pre-compact-alert.$SID12.md")
has 'unable to check: python3 is required' 'precompact surfaces dependency failure'
export PATH="$SAVED_PATH"
fresh
usage 800000
export PATH="$T/no-python"
OUT=$(cd "$P" && printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"%s","transcript_path":"%s","tool_input":{"command":"true"},"tool_response":{}}' \
  "$SID" "$TR" | /bin/bash .claude/hooks/log-tool-event.sh 2>/dev/null)
eq "$?" 0 'tool hook remains resilient without Python'
has 'unable to check: python3 is required' 'tool hook surfaces dependency failure'
export PATH="$SAVED_PATH"

echo "== Round 3 P2-1: real writers and unexpected event names"
fresh
OUT=$(python3 - "$REPO" "$P" <<'PYWRITERS'
import importlib.util, pathlib, sys
repo, project = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('watcher', repo/'scripts/context-watcher.py')
watcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watcher)
for host in ('Björn-Mac.local', '東京²Ⅷ.local', '---'):
    watcher.socket.gethostname = lambda: host
    watcher.append_event(project/'.agent', 'DECISION: from another machine\n')
PYWRITERS
)
eq "$?" 0 'real Unicode watcher writes succeed'
OUT=$(cd "$P" && printf 'DECISION: shell writer\n' | /bin/bash .claude/hooks/agent-log.sh append 2>&1)
eq "$?" 0 'real shell writer succeeds'
R --session "$SID"
eq "$RC" 1 'all writer names are checked'
has '4 marked-decision events' 'Unicode, fallback and hash names counted'
mark
R --session "$SID"
eq "$RC" 0 'Unicode coverage identities round trip'
has "0 uncovered events" "all writer identities covered"
printf 'DECISION: do not hide this\n' > "$P/.agent/events/unexpected.md"
R --session "$SID"
eq "$RC" 2 'unexpected event name prevents false readiness'
has 'unexpected event filename:' 'unexpected filename diagnostic'
rm "$P/.agent/events/unexpected.md"
for name in unexpected.txt .DS_Store; do   # not events: render and fold never read them, so the report ignores them
  printf 'DECISION: do not hide this\n' > "$P/.agent/events/$name"
  R --session "$SID"
  eq "$RC" 0 "non-event entry $name is ignored"
  has "0 uncovered events" "non-event entry $name is not counted"
  rm "$P/.agent/events/$name"
done

echo "== Missing registers and live findings survive marking"
fresh
for register in DECISIONS TASKS; do
  mv "$P/.agent/$register.md" "$T/$register.saved"
  event "$register" 'DECISION: reviewed event'
  R --session "$SID" --mark
  eq "$RC" 1 'mark still reports missing register'
  has "$register.md is missing" 'missing file named'
  exists "$CP" 'coverage recorded independently'
  mv "$T/$register.saved" "$P/.agent/$register.md"
done
printf '{"id":"job","kind":"shell","started":1,"nudged":0}\n' > "$P/.agent/LOGS/.bg-tasks.$SID.jsonl"
printf '{"session_id":"%s","background_tasks":[{"id":"job","status":"running"}]}\n' "$SID" > "$P/live.json"
R --session "$SID" --hook-input "$P/live.json" --mark
eq "$RC" 1 'mark does not clear live heartbeat finding'
has 'without a heartbeat' 'live finding explained'
printf '{"session_id":"%s","background_tasks":[]}\n' "$SID" > "$P/live.json"
mark --hook-input "$P/live.json"

echo "== Round 3 P2-3: registry first-seen age and freshest path"
fresh
NOW=$(date +%s)
BG="$P/.agent/LOGS/.bg-tasks.$SID.jsonl"
printf '{"id":"job","kind":"shell","path":"/old","started":%s,"nudged":9}\n{"id":"job","kind":"shell","path":"/new","started":%s,"nudged":0}\n' "$((NOW - 600))" "$NOW" > "$BG"
cp "$BG" "$T/bg-before"
printf '{"hook_event_name":"Stop","session_id":"%s","background_tasks":[{"id":"job","status":"running"}]}\n' "$SID" > "$P/live.json"
R --session "$SID" --hook-input "$P/live.json"
eq "$RC" 1 'first readiness observation uses original registry age'
has 'without a heartbeat' 're-registration cannot reset age'
eq "$(cat "$BG")" "$(cat "$T/bg-before")" 'readiness never invents a first-seen timestamp'
OUT=$(cd "$P" && /bin/bash .claude/hooks/watch-background.sh < live.json 2>&1)
has '10 min, no heartbeat' 'real watcher agrees with first-seen age'
OUT=$(cat "$BG")
has '"path":"/new"' 'real watcher retains freshest path'
# Reverse file order: freshness is by registration time, not row position.
{ tail -1 "$T/bg-before"; head -1 "$T/bg-before"; } > "$BG"
printf '{"session_id":"%s","background_tasks":[{"id":"job","status":"running"},{"id":"monitor","status":"running","command":"tail /new"}]}\n' "$SID" > "$P/live.json"
R --session "$SID" --hook-input "$P/live.json"
eq "$RC" 0 'freshest path establishes live coverage even in reverse row order'
has 'earlier heartbeat nudge' 'latest nudge survives re-registration'
printf '{"id":"job","kind":"shell","nudged":0}\n' > "$BG"
R --session "$SID" --hook-input "$P/live.json"
eq "$RC" 2 'missing registry age is never replaced with readiness time'
has 'missing or invalid registry start time' 'missing age diagnostic'

echo "== Round 3 P3-4: inline backticks do not open a fence"
fresh
event 001 '```literal```' 'DECISION: actual decision'
R --session "$SID"
eq "$RC" 1 'inline backticks cannot hide following marker'
has '1 marked-decision events' 'following real decision counted'

echo "== Round 2 P2-1: late lower-suffix identity"
fresh
event ffffff 'DECISION: first reviewed decision'
mark
event 000001 'DECISION: later arrival with lower suffix'
R --session "$SID"
eq "$RC" 1 'lower-suffix identity stays uncovered'

echo "== Queue counts, alias discovery and read-only reports"
fresh
pending '2026-10-18T11:59:59Z'
pending '2026-10-18T12:00:00Z'
pending '2026-10-18T12:00:00.000001Z'
cp "$QUEUE" "$T/queue-before"
R --session "$OTHER" --mark
eq "$RC" 0 'another session can record event coverage'
R --session "$SID"
eq "$RC" 1 'all pending timestamps reported'
has "3 pending decisions for this session: .agent/LOGS/${QUEUE##*/}" 'count and path'
lacks ROW_ID 'no row identities'
R --session "$SID" --mark
eq "$RC" 1 'mark leaves queue finding'
eq "$(cat "$QUEUE")" "$(cat "$T/queue-before")" 'queue unchanged by mark'
absent "$QUEUE.lock" 'no queue lock created'
absent "$P/.agent/LOGS/.readiness-shown.$SID.json" 'no receipt created'
fresh
printf '{"status":"pending","session_id":"%s"}\n' "$SID" > "$P/.agent/LOGS/pending-decisions.$SID.jsonl"
touch "$P/.agent/LOGS/.tool-call-counter.$SID12"
for identity in "$SID" "$SID12" ''; do
  if [ -n "$identity" ]; then R --session "$identity"; else R; fi
  eq "$RC" 1 'full queue discovered without session or background directories'
  has '1 pending decisions for this session' 'alias counts full queue'
done
printf '{"status":"pending","session_id":"%s"}\n' "$SIBLING" > "$P/.agent/LOGS/pending-decisions.$SIBLING.jsonl"
R --session "$SID12"
eq "$RC" 2 'full queue filenames establish colliding identities'
R
eq "$RC" 2 'counter inference detects queue collision'
R --session "$SID"
eq "$RC" 1 'explicit full identity counts only own queue'
has '1 pending decisions for this session' 'sibling separated'
pending '2026-10-18T12:00:00Z'
for identity in "$SID" "$SIBLING"; do
  R --session "$identity"
  eq "$RC" 2 'full id cannot own a shared legacy queue'
  has 'ownership unknown' 'collision reported without migration advice'
done
fresh
pending '2026-10-18T12:00:00Z'
event 001 'DECISION: not reviewed'
OUT=$(python3 - "$P" "$SID" <<'PYREAD'
from pathlib import Path
import subprocess, sys
root=Path(sys.argv[1])
def state():
    return {str(p.relative_to(root)):(p.read_bytes(),p.stat().st_mtime_ns)
            for p in root.rglob('*') if p.is_file()}
before=state()
r=subprocess.run(['/bin/bash','.claude/hooks/compact-readiness.sh','--session',sys.argv[2]],
                 cwd=root, capture_output=True, text=True)
assert r.returncode == 1, r.stdout+r.stderr
assert state() == before, 'report wrote state'
print('report leaves file contents, mtimes and file set unchanged')
PYREAD
)
eq "$?" 0 'report is read-only, including queue and checkpoint locks'
# A partial append is uncertainty, never a zero-pending assertion.
printf '{"status":' >> "$QUEUE"
R --session "$SID"
eq "$RC" 2 'partial queue append reports inability to check'
fresh
echo legacy-filename > "$CP"
R --session "$SID" --mark
eq "$RC" 2 'legacy checkpoint rejected without migration'
eq "$(cat "$CP")" legacy-filename 'legacy checkpoint unchanged'

echo "== Tier cadence and dependency failure bounds"
tool_report() {
  OUT=$(cd "$P" && printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"%s","transcript_path":"%s","tool_input":{"command":"true"},"tool_response":{}}' \
    "$SID" "$TR" | /bin/bash .claude/hooks/log-tool-event.sh 2>/dev/null)
  RC=$?
}
fresh
event 001 'DECISION: retained fixture'
usage 800000
tool_report
has 'compact-readiness: NOT READY' 'tier two carries report'
tool_report
lacks 'compact-readiness:' 'same tier does not repeat report'
usage 960000
tool_report
has 'compact-readiness: NOT READY' 'tier three carries report'
tool_report
lacks 'compact-readiness:' 'tier three does not repeat report'
for code in 1 2 127; do
  fresh
  usage 800000
  printf '#!/bin/bash\nexit %s\n' "$code" > "$P/.claude/hooks/compact-readiness.sh"
  tool_report
  eq "$RC" 0 "report exit $code does not fail tool hook"
  has 'unable to check (no report)' 'silent dependency failure surfaced'
  OUT=$(cd "$P" && printf '{"session_id":"%s"}' "$SID" | /bin/bash .claude/hooks/on-pre-compact.sh 2>/dev/null)
  eq "$?" 0 'precompact survives report failure'
  OUT=$(cat "$P/.agent/LOGS/pre-compact-alert.$SID12.md")
  has "unable to check (exit $code; no report)" 'alert preserves failure'
done
fresh
usage 800000
printf '#!/bin/bash\nprintf "%%020000d" 0\nexit 2\n' > "$P/.claude/hooks/compact-readiness.sh"
tool_report
has '[report truncated;' 'large helper failure bounded'
eq "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext | length < 7000')" true 'tier payload bounded'

echo "== Documented advisory protocol"
for doc in "$REPO/README.md" "$REPO/template/CLAUDE.md"; do
  OUT=$(cat "$doc")
  has 'This check is advisory' 'advisory contract'
  has 'covered-through <newest filename>' 'coverage format'
  has 'MEGAVIBE_READY_TASKS_MIN_EVENTS' 'event threshold'
  has 'fold cutoff' 'coverage pruning'
  has 'It never certifies readiness or acknowledges pending rows' 'mark scope'
  lacks '--staged-handled' 'acknowledgement instructions removed'
done

echo "compact-readiness tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
