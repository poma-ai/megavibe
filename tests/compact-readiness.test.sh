#!/bin/bash
# Tests for compact-readiness.sh and the three hooks that carry its report.
# Self-contained: builds a throwaway project under mktemp, points HOME at a
# scratch dir (hooks write ~/.megavibe/hook-errors.log), never touches the
# repo or any real project. Run: bash tests/compact-readiness.test.sh
# Exit 0 when every assertion passed.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOKS="$REPO/template/.claude/hooks"
T=$(mktemp -d "${TMPDIR:-/tmp}/mv-ready.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.megavibe"
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW MEGAVIBE_LAUNCH_VERSION MEGAVIBE_READY_DECISION_RE \
      MEGAVIBE_READY_TASKS_LAG_MIN MEGAVIBE_READY_TASKS_MIN_EVENTS MEGAVIBE_BG_CHECK_SECS MEGAVIBE_CLOSEOUT 2>/dev/null
export CLAUDE_CODE_SESSION_ID=""   # the harness sets this in the Bash tool; each case decides

P="$T/proj"; SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"; SID12="${SID:0:12}"
NOW=$(date +%s)
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      | /'; }
assert_rc()      { [ "$1" -eq "$2" ] && ok || bad "$3 — exit $1, want $2" "${4:-}"; }
assert_has()     { printf '%s' "$1" | grep -q -- "$2" && ok || bad "$3 — missing: $2" "$1"; }
assert_lacks()   { printf '%s' "$1" | grep -q -- "$2" && bad "$3 — present but should not be: $2" "$1" || ok; }

# epoch -> UTC stamp an event is named with; touch a file to NOW-secs
stamp()     { date -u -r "$1" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -d "@$1" +%Y%m%dT%H%M%SZ; }
touch_ago() { local e=$((NOW - $2)); touch -t "$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$e" +%Y%m%d%H%M.%S)" "$1"; }
N_EV=0
event_ago() {  # secs text... -> one event file stamped NOW-secs
  local secs="$1"; shift
  N_EV=$((N_EV + 1))
  printf '%s\n' "$@" > "$P/.agent/events/$(stamp $((NOW - secs)))-testhost-$(printf '%06d' "$N_EV").md"
}
fresh_project() {
  rm -rf "$P"; mkdir -p "$P/.agent/events" "$P/.agent/LOGS" "$P/.agent/sessions" "$P/.claude/hooks"
  for h in compact-readiness.sh on-pre-compact.sh compaction-autopilot.sh log-tool-event.sh redact-secrets.sh; do
    cp "$HOOKS/$h" "$P/.claude/hooks/$h"; chmod +x "$P/.claude/hooks/$h"
  done
  printf '# Decisions\n\n| # | Decision | Rationale | Date |\n' > "$P/.agent/DECISIONS.md"
  printf '# Tasks\n\n| # | Task | Acceptance criteria | Status |\n' > "$P/.agent/TASKS.md"
  N_EV=0
}
R() { (cd "$P" && bash .claude/hooks/compact-readiness.sh "$@" 2>&1); }

echo "== 1. fresh registers, no events: READY"
fresh_project
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 0 "fresh project is ready" "$OUT"
assert_has "$OUT" "compact-readiness: READY" "verdict line"
assert_has "$OUT" "session ${SID} \[--session\]" "says which session and how"
assert_has "$OUT" "no WORKING_CONTEXT for session" "WC missing is information"
assert_has "$OUT" "not a git repository" "no git is information"
assert_lacks "$OUT" '\[!\]' "nothing blocking"

echo "== 2. decision-like events newer than DECISIONS.md block; records of recording do not"
fresh_project
touch_ago "$P/.agent/DECISIONS.md" 7200
event_ago 3600 "Appended 3 decisions to .agent/DECISIONS.md and tidied the table."   # about recording: skipped
event_ago 3000 "Reviewed the default branch settings; nothing to change."            # bare 'default': not a decision
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 0 "records of recording and bare 'default' do not block" "$OUT"
assert_has "$OUT" "2 events since, 0 look like decisions" "counts events but no decisions"
event_ago 1800 "D22 answered: option B. Recorded in STATUS."
event_ago 1200 "Decision: keep the VM until 19:18Z for the E3 run; default B at ~20:00Z."
event_ago 600  "Notes mention DECISIONS.md on one line." "Chosen: the second variant."  # one line is about recording, the other is not
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 1 "decision-like events block" "$OUT"
assert_has "$OUT" "NOT READY — 1 blocking item" "one blocking item"
assert_has "$OUT" "5 events since, 3 look like decisions" "three of five events are decision-like"
assert_has "$OUT" '\[!\] DECISIONS.md written 2h 00m ago' "age and marker"
touch "$P/.agent/DECISIONS.md"
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 0 "a DECISIONS.md newer than the events is current" "$OUT"

echo "== 3. --decisions-since FILE: the autopilot's one-number probe"
F="$T/flag"; : > "$F"; touch_ago "$F" 1500
OUT=$(R --decisions-since "$F"); RC=$?
assert_rc "$RC" 1 "two decision-like events newer than the flag" "$OUT"
[ "$OUT" = "2" ] && ok || bad "prints the count 2" "$OUT"
touch "$F"
OUT=$(R --decisions-since "$F"); RC=$?
assert_rc "$RC" 0 "nothing newer than a fresh flag" "$OUT"
[ "$OUT" = "0" ] && ok || bad "prints 0" "$OUT"
OUT=$(R --decisions-since "$T/does-not-exist"); RC=$?
assert_rc "$RC" 2 "missing file is 'cannot tell'" "$OUT"

echo "== 4. TASKS.md lag: blocks over the lag with enough events in between, tunable"
fresh_project
touch_ago "$P/.agent/TASKS.md" 7200
event_ago 3000 "progress note one"; event_ago 2400 "progress note two"
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 0 "two events in between is under the minimum" "$OUT"
event_ago 1800 "progress note three"
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 1 "three events over a 60m lag block" "$OUT"
assert_has "$OUT" '\[!\] TASKS.md written 2h 00m ago, newest event 30m ago; 3 events in between' "lag line"
assert_has "$OUT" "lag over 60m" "names the threshold"
OUT=$(cd "$P" && MEGAVIBE_READY_TASKS_LAG_MIN=300 bash .claude/hooks/compact-readiness.sh --session "$SID" 2>&1); RC=$?
assert_rc "$RC" 0 "a 300m lag threshold clears it" "$OUT"
OUT=$(cd "$P" && MEGAVIBE_READY_TASKS_MIN_EVENTS=4 bash .claude/hooks/compact-readiness.sh --session "$SID" 2>&1); RC=$?
assert_rc "$RC" 0 "a minimum of 4 events clears it" "$OUT"

echo "== 5. decisions the watcher staged: this session blocks, other sessions inform"
fresh_project
printf '{"title":"x","status":"pending"}\n{"title":"y","status":"accepted"}\n{"title":"z","status":"pending"}\n' > "$P/.agent/LOGS/pending-decisions.${SID12}.jsonl"
printf '{"title":"o","status":"pending"}\n' > "$P/.agent/LOGS/pending-decisions.ffffffff-000.jsonl"
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 1 "pending rows of this session block" "$OUT"
assert_has "$OUT" '\[!\] 2 decisions staged by the context watcher from this session, pending review (.agent/LOGS/pending-decisions.'"${SID12}"'.jsonl)' "count and file"
assert_has "$OUT" "review-decisions.py --session ${SID12}" "names the review command"
assert_has "$OUT" "1 more from other sessions" "other sessions counted"
OUT=$(R --session "ffffffff-111"); RC=$?
assert_rc "$RC" 0 "a session with no staged rows of its own: the other sessions' rows are information" "$OUT"
assert_has "$OUT" "3 from other sessions still pending review" "other sessions are information for a session with none"
rm -f "$P/.agent/LOGS/pending-decisions.${SID12}.jsonl"
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 0 "no pending rows of this session: ready" "$OUT"
OUT=$(cd "$P" && CLAUDE_CODE_SESSION_ID="" bash .claude/hooks/compact-readiness.sh 2>&1); RC=$?
assert_rc "$RC" 1 "session unknown: every pending row counts" "$OUT"
assert_has "$OUT" "session unknown, all counted" "says so"

echo "== 6. background tasks: a recent nudge blocks, an old one or none informs"
fresh_project
BG="$P/.agent/LOGS/.bg-tasks.${SID}.jsonl"
printf '{"id":"t1","path":"/x/t1.output","kind":"bash","started":%s,"nudged":%s}\n' $((NOW - 3600)) $((NOW - 120)) > "$BG"
printf '{"id":"t2","path":"/x/t2.output","kind":"agent","started":%s,"nudged":%s}\n' $((NOW - 7200)) $((NOW - 5000)) >> "$BG"
printf '{"id":"t3","path":"","kind":"bash","started":%s,"nudged":0}\n' $((NOW - 100)) >> "$BG"
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 1 "a task nudged 2m ago blocks" "$OUT"
assert_has "$OUT" '\[!\] background bash task t1 (started 1h 00m ago) was found without a heartbeat 2m ago' "names the task"
assert_has "$OUT" "3 background tasks recorded alive at the last turn end, 1 without a heartbeat; earlier nudges: agent t2 (no heartbeat 1h 23m ago)" "summary line"
OUT=$(R --session "$SID12"); RC=$?
assert_rc "$RC" 1 "the 12-char prefix finds the same file" "$OUT"
printf '{"id":"t3","path":"","kind":"bash","started":%s,"nudged":0}\n' $((NOW - 100)) > "$BG"
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 0 "a task never nudged is information" "$OUT"
assert_has "$OUT" '\[i\] 1 background task recorded alive at the last turn end; coverage is known only at a turn end' "information line"

echo "== 7. WORKING_CONTEXT age and git state are information"
fresh_project
mkdir -p "$P/.agent/sessions/$SID"; echo "ctx" > "$P/.agent/sessions/$SID/WORKING_CONTEXT.md"; touch_ago "$P/.agent/sessions/$SID/WORKING_CONTEXT.md" 7200
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 0 "an old WORKING_CONTEXT does not block" "$OUT"
assert_has "$OUT" "WORKING_CONTEXT .agent/sessions/${SID}/WORKING_CONTEXT.md written 2h 00m ago (over 1h: /rehydrate will be required" "age and consequence"
touch "$P/.agent/sessions/$SID/WORKING_CONTEXT.md"
OUT=$(R --session "$SID12")
assert_has "$OUT" "(fresh: /rehydrate will be optional)" "fresh WC found through the 12-char prefix"
printf '.agent/\n.claude/\n' > "$P/.gitignore"
(cd "$P" && git init -q && git add .gitignore && git -c user.email=t@example.invalid -c user.name=t commit -q -m init)
echo x > "$P/dirty.txt"
OUT=$(R --session "$SID"); RC=$?
assert_rc "$RC" 0 "uncommitted work does not block" "$OUT"
assert_has "$OUT" "uncommitted work: 1 path (git status --porcelain" "counts paths"

echo "== 8. session detection and errors"
fresh_project
: > "$P/.agent/LOGS/.tool-call-counter.${SID12}"; : > "$P/.agent/LOGS/.tool-call-counter.${SID12}.lock"
OUT=$(cd "$P" && CLAUDE_CODE_SESSION_ID="" bash .claude/hooks/compact-readiness.sh 2>&1)
assert_has "$OUT" "session ${SID12} \[newest tool-call counter\]" "falls back to the newest counter, ignoring .lock"
OUT=$(cd "$P" && CLAUDE_CODE_SESSION_ID="$SID" bash .claude/hooks/compact-readiness.sh 2>&1)
assert_has "$OUT" "session ${SID} \[CLAUDE_CODE_SESSION_ID\]" "takes the Bash tool's session id"
OUT=$(R --session '../../etc'); RC=$?
assert_has "$OUT" "session ....etc" "path characters are stripped from a session id"
OUT=$(R --bogus); RC=$?
assert_rc "$RC" 2 "unknown argument" "$OUT"
OUT=$(cd "$T" && bash "$HOOKS/compact-readiness.sh"); RC=$?
assert_rc "$RC" 2 "no .agent/: cannot tell" "$OUT"
OUT=$(R --project "$T"); RC=$?
assert_rc "$RC" 2 "--project without .agent/: cannot tell" "$OUT"

echo "== 9. on-pre-compact.sh carries the report into the alert file"
fresh_project
touch_ago "$P/.agent/DECISIONS.md" 7200; event_ago 600 "Decision: ship it."
OUT=$(cd "$P" && printf '{"session_id":"%s","transcript_path":"/nonexistent"}' "$SID" | bash .claude/hooks/on-pre-compact.sh 2>/dev/null); RC=$?
assert_rc "$RC" 0 "hook exits 0" "$OUT"
ALERT=$(cat "$P/.agent/LOGS/pre-compact-alert.${SID12}.md" 2>/dev/null)
assert_has "$ALERT" "COMPACT READINESS (exit 1 from .claude/hooks/compact-readiness.sh" "alert file names the check and its exit"
assert_has "$ALERT" "1 looks like a decision" "the readiness lines are in the alert file"
assert_has "$ALERT" "Newest .agent/events entry:" "the rest of the report is still there"
assert_has "$OUT" '"systemMessage"' "legacy systemMessage still emitted"
OUT=$(cd "$T" && echo '{}' | bash "$HOOKS/on-pre-compact.sh" 2>&1); RC=$?
assert_rc "$RC" 0 "no .agent/: silent no-op" "$OUT"
[ -z "$OUT" ] && ok || bad "no output outside a project" "$OUT"

echo "== 10. compaction-autopilot.sh: the close-out flag expires on a newer decision-like event"
fresh_project
TR="$T/transcript.jsonl"
printf '{"type":"assistant","message":{"usage":{"input_tokens":900000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$TR"
echo 1000000 > "$P/.agent/LOGS/.ctx-size.${SID12}"
DONE="$P/.agent/LOGS/.closeout-done.${SID12}"
AP() { (cd "$P" && printf '{"hook_event_name":"%s","session_id":"%s","transcript_path":"%s"%s}' "$1" "$SID" "$TR" "${2:-}" | bash .claude/hooks/compaction-autopilot.sh 2>/dev/null); }
: > "$DONE"; touch_ago "$DONE" 3600
event_ago 1800 "Decision: switch the scorer to whitelist-only units."
OUT=$(AP PostToolUse); RC=$?
assert_rc "$RC" 0 "hook exits 0" "$OUT"
[ -z "$OUT" ] && [ -e "$DONE" ] && ok || bad "DECISIONS.md written after the close-out and after the event: the flag stands" "$OUT"
touch_ago "$P/.agent/DECISIONS.md" 7200
OUT=$(AP PostToolUse); RC=$?
assert_rc "$RC" 0 "hook exits 0" "$OUT"
assert_has "$OUT" "Context is at 90%" "soft nudge fires at 90% although a flag existed"
assert_has "$OUT" "but 1 event(s) since then look like decisions, so it is open again" "says why the flag expired"
assert_has "$OUT" "Readiness now:" "carries the report"
assert_has "$OUT" "compact-readiness: NOT READY" "the report says not ready"
assert_has "$OUT" "Run .claude/hooks/compact-readiness.sh and act on each" "step 4 names the check"
[ ! -e "$DONE" ] && ok || bad "the stale flag was removed" "$(ls -la "$DONE")"
: > "$DONE"   # a flag newer than every event stands
OUT=$(AP PostToolUse); RC=$?
assert_rc "$RC" 0 "hook exits 0" "$OUT"
[ -z "$OUT" ] && ok || bad "a current close-out flag silences the soft nudge" "$OUT"
[ -e "$DONE" ] && ok || bad "the current flag is kept"
printf '{"type":"assistant","message":{"usage":{"input_tokens":500000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$TR"
touch_ago "$DONE" 3600
OUT=$(AP PostToolUse); RC=$?
[ -z "$OUT" ] && [ -e "$DONE" ] && ok || bad "below the soft line the flag is not even probed" "$OUT"
rm -f "$DONE"
OUT=$(AP Stop ',"stop_hook_active":true'); RC=$?
[ -z "$OUT" ] && ok || bad "stop_hook_active: never block" "$OUT"
printf '{"type":"assistant","message":{"usage":{"input_tokens":960000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$TR"
OUT=$(AP Stop); RC=$?
assert_has "$OUT" '"decision": "block"' "hard block at 96%"
assert_has "$OUT" "Readiness now:" "the block carries the report"
OUT=$(AP Stop); RC=$?
[ -z "$OUT" ] && ok || bad "the hard block fires once per session" "$OUT"

echo "== 11. log-tool-event.sh: tier 2 nudge carries the report (watcher off)"
fresh_project
printf '{"type":"assistant","message":{"usage":{"input_tokens":800000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$TR"
echo 1000000 > "$P/.agent/LOGS/.ctx-size.${SID12}"
touch_ago "$P/.agent/DECISIONS.md" 7200; event_ago 600 "Decision: ship it."
OUT=$(cd "$P" && printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"%s","transcript_path":"%s","tool_input":{"command":"true"},"tool_response":{}}' "$SID" "$TR" | bash .claude/hooks/log-tool-event.sh 2>/dev/null); RC=$?
assert_rc "$RC" 0 "hook exits 0" "$OUT"
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_has "$CTX" "🟠 Context ~800K" "tier 2 fired"
assert_has "$CTX" "🧭 compact-readiness: NOT READY" "tier 2 carries the report"
assert_has "$CTX" "1 looks like a decision" "with its lines"

echo
echo "compact-readiness tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
