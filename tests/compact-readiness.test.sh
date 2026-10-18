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
  MEGAVIBE_READY_TASKS_MIN_EVENTS MEGAVIBE_BG_CHECK_SECS \
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
    ("task blocking disabled", hook + "compact-readiness.sh",
     "elif count or len(newer) >= minimum:", "elif False:"),
    ("active-stop guard removed", hook + "compaction-autopilot.sh",
     '  [ "$ACTIVE" = "true" ] && exit 0', "  :"),
    ("subagent guard removed", hook + "compaction-autopilot.sh",
     '[ -z "$(printf \'%s\' "$INPUT" | jq -r \'.agent_id // ""\' 2>/dev/null)" ] || exit 0',
     ":"),
    ("soft reminder every call", hook + "compaction-autopilot.sh",
     'if [ "$N" -eq 0 ] || [ $(( N % REMIND_EVERY )) -eq 0 ]; then',
     "if true; then"),
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
    (root / "tests").mkdir()
    shutil.copy2(repo / "tests/compact-readiness.test.sh", root / "tests")
    path = root / filename
    source = path.read_text()
    if old not in source:
        sys.exit("Mutation target missing: " + label)
    path.write_text(source.replace(old, new))
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
has() { if printf '%s' "$OUT" | grep -Fq -- "$1"; then ok; else bad "$2"; fi; }
lacks() { if printf '%s' "$OUT" | grep -Fq -- "$1"; then bad "$2"; else ok; fi; }
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
  for h in compact-readiness on-pre-compact compaction-autopilot log-tool-event redact-secrets; do
    # Redirect home references only in scratch copies; leave caller home alone.
    sed 's/${HOME}/${TEST_HOME}/g; s/$HOME/$TEST_HOME/g' \
      "$HOOKS/$h.sh" > "$P/.claude/hooks/$h.sh"
    chmod +x "$P/.claude/hooks/$h.sh"
  done
  printf '# Decisions\n' > "$P/.agent/DECISIONS.md"
  printf '# Tasks\n| T1 | open | blocked on review |\n' > "$P/.agent/TASKS.md"
  DONE="$P/.agent/LOGS/.closeout-done.$SID12"
  BLOCKED="$P/.agent/LOGS/.closeout-blocked.$SID12"
  COUNT="$P/.agent/LOGS/.closeout-count.$SID12"
  CP="$P/.agent/.registers-checkpoint"
  QUEUE="$P/.agent/LOGS/pending-decisions.$SID12.jsonl"
  TR="$P/transcript.jsonl"
}
usage() {
  printf '{"type":"assistant","message":{"usage":{"input_tokens":%s}}}\n' "$1" > "$TR"
  echo 1000000 > "$P/.agent/LOGS/.ctx-size.$SID12"
}
AP() {
  OUT=$(cd "$P" && printf '{"hook_event_name":"%s","session_id":"%s","transcript_path":"%s"%s}' \
    "$1" "$SID" "$TR" "${2:-}" | /bin/bash .claude/hooks/compaction-autopilot.sh 2>&1)
  RC=$?
}
mark() { R --session "$SID" --mark --force "$@"; eq "$RC" 0 "mark succeeds"; }
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
eq "$(cat "$CP")" "" "empty checkpoint"
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
R --session "$SID" --mark
eq "$RC" 1 "mark refuses blockers"
has "Checkpoint unchanged" "refusal explains remedy"
absent "$CP" "refused mark did not certify"
mark
eq "$(cat "$CP")" "$LAST" "complete newest filename"
R --session "$SID"
eq "$RC" 0 "same-second covered event stays covered"
event 000 "DECISION: lexically earlier."
R --session "$SID"
eq "$RC" 0 "earlier same-second event stays covered"
event 002 "D23: choose a bounded queue."
python3 - "$P" <<'PY'
from pathlib import Path
import os, sys
for p in (Path(sys.argv[1]) / ".agent/events").iterdir():
    os.utime(p, (100, 100))
PY
R --session "$SID"
eq "$RC" 1 "later suffix reopens despite identical old mtimes"
has "1 marked-decision events" "one later marker"
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

echo "== Findings 5 and 6: identity and append-only handling"
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
pending "2026-10-18T12:00:01+00:00"
cp "$QUEUE" "$T/original-queue"
printf '{"status":"pending","title":"other session"}\n' \
  > "$P/.agent/LOGS/pending-decisions.${OTHER:0:12}.jsonl"
R --session "$SID"
eq "$RC" 1 "own pending row blocks"
has "--mark --staged-handled" "actionable remedy"
echo "Recorded review item" >> "$P/.agent/DECISIONS.md"
R --session "$SID"
eq "$RC" 1 "register write alone does not acknowledge queue"
R --session "$SID" --mark --staged-handled
eq "$RC" 0 "offered remedy succeeds"
has "Appended status: handled-by-session" "append reported"
eq "$(head -1 "$QUEUE")" "$(cat "$T/original-queue")" "original row unchanged"
eq "$(wc -l < "$QUEUE" | tr -d ' ')" 2 "one marker appended"
R --session "$SID"
eq "$RC" 0 "handled rows clear; other session stays informational"
pending "2026-10-18T12:00:02+00:00"
R --session "$SID"
eq "$RC" 1 "later append not swallowed by marker"
fresh
event 001 "progress"
mark
pending "2026-10-18T11:59:59+00:00"
R --session "$SID"
eq "$RC" 0 "older pending row does not block"
pending "2026-10-18T12:00:00+00:00"
R --session "$SID"
eq "$RC" 0 "equal staged timestamp is covered"
pending "2026-10-18T12:00:00.000001+00:00"
R --session "$SID"
eq "$RC" 1 "fractionally later pending row needs acknowledgement"
R --session "$SID" --mark --staged-handled
eq "$RC" 0 "same-second queue has working remedy"

echo "== Background heartbeat coverage"
fresh
NOW=$(date +%s)
printf '{"id":"job","kind":"shell","nudged":%s}\n' "$NOW" \
  > "$P/.agent/LOGS/.bg-tasks.$SID.jsonl"
R --session "$SID"
eq "$RC" 1 "recent missing heartbeat blocks"
has "background shell task job" "task named"
R --session "$SID12"
eq "$RC" 1 "unambiguous prefix finds heartbeat"
printf '{"id":"old","nudged":%s}\n{"id":"quiet","nudged":0}\n' "$((NOW - 5000))" \
  > "$P/.agent/LOGS/.bg-tasks.$SID.jsonl"
R --session "$SID"
eq "$RC" 0 "old or absent nudge informs"
has "earlier heartbeat nudge" "old nudge visible"

echo "== Finding 10: missing values terminate"
fresh
for option in --project --session --decisions-since; do
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
R --decisions-since "$T/no-checkpoint"
eq "$RC" 2 "missing explicit checkpoint"
R --staged-handled
eq "$RC" 2 "handling requires mark"

echo "== Findings 3, 4, 8: done flag and bounded scans"
fresh
usage 900000
event 001 "DECISION: retain the local format."
touch "$DONE" "$P/.agent/DECISIONS.md"
AP PostToolUse
eq "$RC" 0 "autopilot handles readiness exit 1"
has "open again" "touch cannot silence stale done"
has "Readiness now:" "rearm report"
absent "$DONE" "stale done removed"
mark
touch "$DONE"
AP PostToolUse
eq "$OUT" "" "checkpoint covers same-second close-out"
exists "$DONE" "covered done kept"
event 002 "DECISION: add validation."
touch "$BLOCKED"
usage 960000
AP Stop
eq "$OUT" "" "rearm preserves once-only block guard"
exists "$BLOCKED" "hard flag retained"
absent "$DONE" "later filename invalidates done"
mkdir -p "$T/bin"
REAL_GREP=$(command -v grep)
export REAL_GREP GREP_TRACE="$T/grep-trace"
cat > "$T/bin/grep" <<'SH'
#!/bin/bash
if [ "${1:-}" = "-lE" ]; then printf 'scan\n' >> "$GREP_TRACE"; fi
exec "$REAL_GREP" "$@"
SH
chmod +x "$T/bin/grep"
ORIGINAL_PATH="$PATH"
export PATH="$T/bin:$PATH"
mark
touch "$DONE"
: > "$GREP_TRACE"
AP PostToolUse
eq "$(wc -l < "$GREP_TRACE" | tr -d ' ')" 0 "covered checkpoint skips scan"
for n in $(seq 1000 1999); do event "$n" "progress"; done
: > "$GREP_TRACE"
AP PostToolUse
eq "$OUT" "" "new nondecision events retain done"
eq "$(wc -l < "$GREP_TRACE" | tr -d ' ')" 1 "1000 files use one grep"
event 9999 "DECISION: add a limit."
: > "$GREP_TRACE"
AP PostToolUse
has "open again" "later decision rearms"
eq "$(wc -l < "$GREP_TRACE" | tr -d ' ')" 1 "rearm report reuses probe"
export PATH="$ORIGINAL_PATH"

echo "== Finding 9: three guard regressions"
fresh
usage 960000
AP Stop ',"stop_hook_active":true'
eq "$OUT" "" "active Stop at 96 percent silent"
absent "$BLOCKED" "active Stop leaves fresh flag absent"
AP Stop
has '"decision": "block"' "ordinary Stop at 96 percent blocks"
has "Readiness now:" "hard block report"
AP Stop
eq "$OUT" "" "hard block once only"
fresh
usage 960000
AP Stop ',"agent_id":"child"'
eq "$OUT" "" "subagent Stop above threshold silent"
absent "$BLOCKED" "subagent cannot set parent block flag"
AP PostToolUse ',"agent_id":"child"'
eq "$OUT" "" "subagent tool use above threshold silent"
absent "$COUNT" "subagent cannot advance parent count"
fresh
usage 900000
AP PostToolUse
has "Context is at 90%" "first soft reminder"
for n in $(seq 2 25); do
  AP PostToolUse
  eq "$OUT" "" "call $n does not repeat reminder"
done
AP PostToolUse
has "Context is at 90%" "call 26 reminds"
export MEGAVIBE_CLOSEOUT_REMIND_EVERY=00
AP PostToolUse
eq "$RC" 2 "zero reminder interval rejected"
unset MEGAVIBE_CLOSEOUT_REMIND_EVERY
export MEGAVIBE_CLOSEOUT_SOFT_PCT=085
AP PostToolUse
eq "$RC" 0 "leading-zero percentage decimal"
unset MEGAVIBE_CLOSEOUT_SOFT_PCT
fresh
usage 500000
touch "$DONE"
event 001 "DECISION: below threshold."
AP PostToolUse
eq "$OUT" "" "below threshold no nudge"
exists "$DONE" "below threshold flag untouched"

echo "== Report integration and resilience"
fresh
event 001 "DECISION: ship the verified result."
OUT=$(cd "$P" && printf '{"session_id":"%s","transcript_path":"/nonexistent"}' "$SID" |
  /bin/bash .claude/hooks/on-pre-compact.sh 2>/dev/null)
eq "$?" 0 "pre-compact hook exits successfully"
has '"systemMessage"' "legacy message preserved"
OUT=$(cat "$P/.agent/LOGS/pre-compact-alert.$SID12.md")
has "COMPACT READINESS (exit 1" "alert carries exit"
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
for code in 1 2 127; do
  fresh
  usage 960000
  printf '#!/bin/bash\nexit %s\n' "$code" > "$P/.claude/hooks/compact-readiness.sh"
  AP Stop
  eq "$RC" 0 "readiness exit $code does not trigger hook error"
  has '"decision": "block"' "readiness failure preserves bounded instruction"
done

echo "compact-readiness tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
