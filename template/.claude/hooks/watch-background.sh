#!/bin/bash
# DO NOT use set -e — a hook must never fail the turn.
set -u

# Megavibe — a background task nobody is watching is a task that can crashloop
# forever.
#
# The harness notifies when a background task COMPLETES. A task that hangs, or
# restarts itself in a loop, never completes, so the notification never comes
# and silence looks exactly like progress. Sessions have waited an hour on
# that silence. The fix is a heartbeat: something that wakes the main thread
# on a clock, with fresh evidence, whether or not the task has finished.
#
# Two handlers, one script:
#   PostToolUse(Bash run_in_background | async Agent) — record when the task
#       started, and tell Claude to arm a Monitor heartbeat on its output
#       file now, with the exact loop to paste.
#   Stop — the harness hands every Stop hook `background_tasks`: the live
#       registry, each entry {id, type, status, description, command}. For
#       every RUNNING task older than CHECK_SECS with no other running task
#       whose command names it (that is what a heartbeat looks like from
#       here), block the stop once with "read the output now and judge". Once
#       per interval, all overdue tasks in one reason, and never when
#       stop_hook_active is set — that stop is the one this hook caused.
#       A Stop hook cannot wake Claude later; it can only refuse to let a
#       turn end on "waiting". The heartbeat is the mechanism, this is the
#       net under it.
#
# Measured payload shapes (2.1.27x), because the text Claude sees is composed
# by the harness and never reaches a hook:
#   Bash bg   tool_response = {backgroundTaskId, stdout:"", stderr:"", ...}
#             — no path. The output file exists at launch under
#             <tmp>/claude-<uid>/<cwd slug>/<launch id>/tasks/<id>.output.
#   Agent     tool_response = {isAsync:true, status:"async_launched",
#             agentId, outputFile, ...}; a synchronous run has no agentId.
#   Monitor   registry entry type "shell", command = the loop.
#   Stop      background_tasks = [{id, type: "shell"|"subagent", status,
#             description, command}], only tasks still known to the harness.
#
# State: .agent/LOGS/.bg-tasks.${SID}.jsonl — {id, path, kind, started,
# nudged} per task, appended at start, rewritten at Stop to the registry's
# live set. The registry says what is alive; this file only remembers when
# each task began and when it was last nudged. Per session, so two sessions
# in one checkout never nudge each other. PostToolUse only appends and Stop
# never overlaps a tool call, so no lock is needed.
#
# Env: MEGAVIBE_BG_CHECK_SECS sets the interval, clamped to 60..600 — a
# task may go at most that long unchecked, and the heartbeat Claude is told
# to arm beats 60 s under it so a heartbeating task is never also nudged.
# MEGAVIBE_BG_WATCH=0 switches the hook off.
#
# Triggered by: PostToolUse (Bash|Agent), Stop. Exit 0 always.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
BG_OFF=0; [ "${MEGAVIBE_BG_WATCH:-1}" = "0" ] && BG_OFF=1   # opts out of the background-task checks only; the scratch check at Stop follows MEGAVIBE_DISK_WATCH

CHECK_SECS="${MEGAVIBE_BG_CHECK_SECS:-300}"
case "$CHECK_SECS" in ''|*[!0-9]*) CHECK_SECS=300 ;; esac
[ "$CHECK_SECS" -ge 60 ] || CHECK_SECS=60
[ "$CHECK_SECS" -le 600 ] || CHECK_SECS=600
BEAT_SECS=$((CHECK_SECS - 60))
[ "$BEAT_SECS" -ge 30 ] || BEAT_SECS=30

INPUT=$(cat 2>/dev/null || echo "")
[ -n "$INPUT" ] || exit 0

{
  IFS= read -r -d "" EVENT
  IFS= read -r -d "" TOOL
  IFS= read -r -d "" SID
  IFS= read -r -d "" STOP_ACTIVE
} < <(printf '%s' "$INPUT" | jq -j '
  [ (.hook_event_name // ""), (.tool_name // ""), (.session_id // "default"),
    (.stop_hook_active // false | tostring)
  ] | map(. + "\u0000") | join("")' 2>/dev/null) || true
EVENT="${EVENT:-}"; TOOL="${TOOL:-}"; STOP_ACTIVE="${STOP_ACTIVE:-false}"

SID=$(printf '%s' "${SID:-default}" | tr -cd 'A-Za-z0-9-' | cut -c1-64)
SID="${SID:-default}"
mkdir -p ".agent/LOGS" 2>/dev/null || true
STATE=".agent/LOGS/.bg-tasks.${SID}.jsonl"
NOW=$(date +%s 2>/dev/null | tr -cd '0-9'); NOW="${NOW:-0}"
[ "$NOW" -gt 0 ] || exit 0

task_file() {  # id -> the harness's output file for it, or ""
  local uid f
  uid=$(id -u 2>/dev/null || echo 0)
  local mv=""
  if command -v perl >/dev/null 2>&1; then   # root lookup, glob and file test on a moved volume: one 3 s deadline, local paths still searched on a timeout
    mv=$(perl -e 'alarm shift; exec @ARGV' 3 bash -c 'r=$("$1" root 2>/dev/null) || exit 0; for f in "$r"/*/*/tasks/"$2".output; do [ -e "$f" ] && { printf "%s" "$f"; exit 0; }; done' _ "$HOME/.megavibe/scripts/scratch-root.sh" "$1" 2>/dev/null) || mv=""
  fi
  [ -z "$mv" ] || { printf '%s' "$mv"; return 0; }
  for f in "${TMPDIR:-/tmp}"/claude-"$uid"/*/*/tasks/"$1".output \
           /private/tmp/claude-"$uid"/*/*/tasks/"$1".output \
           /tmp/claude-"$uid"/*/*/tasks/"$1".output; do
    [ -e "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 0
}

# ---------------------------------------------------------------- PostToolUse
if [ "$EVENT" = "PostToolUse" ]; then
  [ "$BG_OFF" = 1 ] && exit 0
  case "$TOOL" in
    Bash)
      BG=$(printf '%s' "$INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null || echo false)
      [ "$BG" = "true" ] || exit 0
      ID=$(printf '%s' "$INPUT" | jq -r '.tool_response.backgroundTaskId // ""' 2>/dev/null || echo "")
      [ -n "$ID" ] || ID=$(printf '%s' "$INPUT" | jq -r '.tool_response | tostring' 2>/dev/null \
                          | sed -n 's/.*background with ID: \([A-Za-z0-9_-]*\).*/\1/p' | head -1)
      [ -n "$ID" ] || exit 0
      OUT=$(task_file "$ID")
      KIND=bash
      CMDTXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
      DESC=$(printf '%s' "$INPUT" | jq -r '.tool_input.description // "background task"' 2>/dev/null | cut -c1-80)
      ;;
    Agent)
      ID=$(printf '%s' "$INPUT" | jq -r 'select(.tool_response | type == "object")
             | select(.tool_response.status == "async_launched" or .tool_response.isAsync == true)
             | .tool_response.agentId // ""' 2>/dev/null || echo "")
      [ -n "$ID" ] || exit 0
      OUT=$(printf '%s' "$INPUT" | jq -r '.tool_response.outputFile // ""' 2>/dev/null || echo "")
      [ -n "$OUT" ] && [ -e "$OUT" ] || OUT=$(task_file "$ID")
      KIND=agent
      DESC=$(printf '%s' "$INPUT" | jq -r '.tool_response.description // .tool_input.description // "subagent"' 2>/dev/null | cut -c1-80)
      ;;
    *) exit 0 ;;
  esac
  # The id is pasted into generated shell text below: accept only the harness's own id shape.
  case $ID in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac

  # A Codex job is recognised by the COMMAND WORD of a segment, never by text anywhere in the
  # line: a prompt, a search pattern or a flag value that mentions codex must not turn an ordinary
  # task into one, nor hide a real one. The line is tokenised quote-aware (python3 shlex, as in
  # block-dangerous-bash.sh) and split at && || ; | & ( ) (a subshell or { group is a segment of its own). `codex exec` (not --ephemeral, which writes
  # no rollout), codex-review.sh, second-opinion.sh. Only codex-review.sh --as-reviewer without
  # --strict / MEGAVIBE_CODEX_SCRATCH=0 runs in a codex-review-scratch.* dir, which narrows the
  # search. Without python3, or on a line shlex cannot parse, nothing is a Codex job (the ordinary
  # output-file heartbeat applies).
  CODEXJOB=0; CSCRATCH=0
  if [ "$KIND" = "bash" ] && [ -n "${CMDTXT:-}" ] && command -v python3 >/dev/null 2>&1; then
    _cx=$(MV_CMD="$CMDTXT" python3 -I -c '
import os, shlex
try:
    lx = shlex.shlex(os.environ["MV_CMD"], posix=False, punctuation_chars=";&|()")
    lx.whitespace_split = True
    toks = list(lx)
except ValueError:
    print("0 0"); raise SystemExit
segs, cur = [], []
for t in toks:
    if t and set(t) <= set(";&|()"):
        segs.append(cur); cur = []
    else:
        cur.append(t)
segs.append(cur)
job = scratch = 0
for w in segs:
    # posix=False keeps quotes on a quoted token, so a quoted "&&" or "--strict" is never an
    # operator or a flag; only the command word itself is unquoted for comparison
    i = 1 if w[:1] == ["{"] else 0
    while i < len(w) and "=" in w[i] and not w[i].startswith("-") and (w[i][0].isalpha() or w[i][0] == "_"):
        i += 1
    env = w[:i]
    if i < len(w) and os.path.basename(w[i].strip(chr(34) + chr(39))) in ("bash", "sh", "zsh", "command", "exec"):
        i += 1
    if i >= len(w):
        continue
    cmd, rest = os.path.basename(w[i].strip(chr(34) + chr(39))), w[i + 1:]
    if cmd == "codex" and rest[:1] == ["exec"] and "--ephemeral" not in rest:
        job = 1
    elif cmd == "codex-review.sh":
        job = 1
        if "--as-reviewer" in rest and "--strict" not in rest and "MEGAVIBE_CODEX_SCRATCH=0" not in env and os.environ.get("MEGAVIBE_CODEX_SCRATCH") != "0":
            scratch = 1
    elif cmd == "second-opinion.sh":
        job = 1
print(job, scratch)
' 2>/dev/null) || _cx="0 0"
    CODEXJOB=${_cx%% *}; CSCRATCH=${_cx##* }
    case $CODEXJOB$CSCRATCH in [01][01]) ;; *) CODEXJOB=0; CSCRATCH=0 ;; esac
  fi

  # A subagent's calls carry an agent_id. It has no Monitor tool and its cache
  # expires after 5 minutes, so it gets the 170 s wait-slice rule (spinouts.md)
  # instead of a heartbeat, and its task is not recorded for the parent's Stop check.
  AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null || echo "")
  if [ -n "$AGENT_ID" ]; then
    MSG="Background $KIND task $ID started${OUT:+. Output: $OUT}. Do not arm a Monitor (a subagent may not have one, and a long wait spends its 5 minute cache) and do not wait longer than 170 s in one tool call (your prompt cache expires after 5 minutes). Wait in slices: one Bash call with timeout 200000 that loops until the job's rc file is non-empty or SECONDS passes 170, then prints the rc, the log's byte count and its tail. Judge the log against what the job is (a build or test run that has not grown for two slices is hung, a server idling is healthy, repeating lines are a crashloop) and act on it. If the job has no rc file (or is an agent), check the output file's size and tail instead of an rc. If you would wait more than about 35 minutes in total, report the command, its log path and its rc path to the parent and stop."
    [ "$CODEXJOB" = 1 ] && MSG="$MSG This is a Codex job: its log and rc file show start-up errors and the exit status, but its progress is in its rollout. In each slice also run ~/.megavibe/scripts/codex-progress.sh --path --since $((NOW - 120)) once to find the job's rollout (exit 3 lists several: pick yours), then ~/.megavibe/scripts/codex-progress.sh --file <rollout> --brief for idle seconds and its last message. Unchanged bytes are a reason to look, not proof of a hang."
    jq -nc --arg m "$MSG" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
    exit 0
  fi

  jq -nc --arg id "$ID" --arg p "$OUT" --arg k "$KIND" --argjson t "$NOW" \
    '{id:$id, path:$p, kind:$k, started:$t, nudged:0}' >> "$STATE" 2>/dev/null || true

  # The loop is built by jq so the path is shell-quoted whatever it contains.
  # No path resolved → no loop: a loop on a placeholder reports 0 bytes
  # forever, which reads as a hang and gets a healthy task killed.
  if [ -n "$OUT" ] || [ "$CODEXJOB" = 1 ]; then
    if [ "$KIND" = "bash" ]; then
      LOOP=$(jq -nr --arg p "$OUT" --arg id "$ID" --argjson s "$BEAT_SECS" '
        "f=" + ($p|@sh) + "; last=0; while sleep " + ($s|tostring) + "; do s=$(wc -c <\"$f\" 2>/dev/null | tr -d \" \" || echo 0); printf '"'"'bg " + $id + ": %s bytes (+%s) | %s\\n'"'"' \"$s\" \"$((s-last))\" \"$(tail -c 200 \"$f\" 2>/dev/null | tr '"'"'\\n'"'"' '"'"' '"'"')\"; last=$s; done"')
      READ="Each beat is the byte delta and the tail. Judge it against what the task IS: a build or test run at +0 for two beats is hung; a server idling at +0 is healthy; a file that keeps growing with the same lines repeating is a crashloop. Read the output file before acting, then act — kill it, fix it, or say it is fine."
      # A Codex job's stdout is usually redirected, so its .output file stays empty and
      # `-o FILE` holds only the final message: the real progress log is the rollout
      # under ~/.codex/sessions. Watch that instead (codex-progress.sh --brief).
      if [ "$CODEXJOB" = 1 ]; then
        # No command parsing: the command text cannot tell which rollout is this job's
        # (a quoted prompt may contain "-C" or "git -C"). The loop looks for rollouts that
        # started shortly before this hook ran, pins one only when exactly one exists, and
        # says "ambiguous" otherwise; a review run is narrowed to the scratch-dir glob.
        CSEL=""
        [ "$CSCRATCH" = 1 ] && CSEL="--cwd '*/codex-review-scratch.*'"
        SINCE=$((NOW - 120))
        LOOP="P=~/.megavibe/scripts/codex-progress.sh; F=; last=0; while sleep $BEAT_SECS; do if [ -z \"\$F\" ]; then F=\$(\"\$P\" --path $CSEL --since $SINCE 2>&1) || { printf 'codex $ID: %s\\n' \"\$(printf %s \"\$F\" | head -c 300 | tr '\\n' ' ')\"; F=; continue; }; fi; b=\$(wc -c <\"\$F\" | tr -d ' '); printf 'codex $ID: +%s bytes | %s\\n' \"\$((b-last))\" \"\$(\"\$P\" --file \"\$F\" --brief | cut -c1-300)\"; last=\$b; done"
        READ="This is a Codex job: its Bash .output file is empty when stdout is redirected and -o FILE holds only the final message, so this heartbeat reads the job's rollout under ~/.codex/sessions through codex-progress.sh (the first beats may say 'no matching rollout yet'). It pins one rollout; if it says ambiguous (several Codex jobs started together), run ~/.megavibe/scripts/codex-progress.sh --path $CSEL --since $SINCE yourself, pick the job's file, and re-arm with --file. +0 bytes is a reason to look, not proof of a hang: Codex can reason for minutes without writing an event. Read the idle seconds and the last message, check the process is alive (ps), and keep the job unless it is idle past about 10 minutes or its process is gone. The job's own log and rc file still carry start-up errors and the exit status."
      fi
    else
      LOOP=$(jq -nr --arg p "$OUT" --arg id "$ID" --argjson s "$BEAT_SECS" '
        "f=" + ($p|@sh) + "; last=0; while sleep " + ($s|tostring) + "; do n=$(wc -l <\"$f\" 2>/dev/null | tr -d \" \" || echo 0); t=$(tail -1 \"$f\" 2>/dev/null | jq -r '"'"'[.message.content[]? | select(.type==\"tool_use\") | .name] | join(\",\")'"'"' 2>/dev/null); printf '"'"'agent " + $id + ": %s entries (+%s) | last tools: %s\\n'"'"' \"$n\" \"$((n-last))\" \"${t:-none}\"; last=$n; done"')
      READ="Each beat is the transcript's entry delta and the last tools it called. +0 entries for two beats is a stall; the same tool names for many beats is a loop — SendMessage the agent or TaskStop it. Never Read that .output file whole: it is the subagent's full JSONL transcript."
    fi
    ARM="Arm a heartbeat NOW with the Monitor tool (if Monitor is not in your tool set, ToolSearch \"select:Monitor\" first). description: \"heartbeat $ID\"; timeout_ms: the task's budget, at most 3600000; command:
$LOOP
$READ When the task's completion notification arrives, TaskStop the heartbeat. If Monitor is unavailable, run the same loop with a fixed beat count through Bash run_in_background instead — its completion is then the wake-up."
  else
    ARM="Arm a heartbeat NOW with the Monitor tool on the output file named in the tool result: every ${BEAT_SECS}s print its byte count, the delta since the last beat, and its tail. Judge each beat against what the task is (a build at +0 is hung, an idle server at +0 is fine, repeating lines are a crashloop), read the file before acting, and TaskStop the heartbeat when the completion notification arrives."
  fi
  MSG="Background $KIND task $ID started ($DESC)${OUT:+. Output: $OUT}. Do NOT end your turn waiting for it: a task that hangs or crashloops never sends a completion notification, and silence looks like progress. $ARM"
  jq -nc --arg m "$MSG" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  exit 0
fi

# ----------------------------------------------------------------------- Stop
[ "$EVENT" = "Stop" ] || exit 0
# This stop was caused by a block from a Stop hook (ours or another). Never
# block again inside that cycle, or the turn can never end.
[ "$STOP_ACTIVE" = "true" ] && exit 0

# The session's own scratch over its budget (default 2 GB, MEGAVIBE_SCRATCH_BUDGET_GB; 0 off; opt out
# with MEGAVIBE_DISK_WATCH=0): refuse "done" once, the way an unwatched task does. The block repeats only
# when the scratch has grown another 256 MB since the last one, so a session that cleaned up, moved the
# large thing to a deliverable, or named it and its size in its report is not blocked again.
DW="${HOME:-}/.megavibe/scripts/disk-watch.sh"
SCR_REASON=""; SCR_KB=0; SCR_ST=""
# One block for everything this Stop has to say: the scratch reason and the background-task reason travel
# together, because the second Stop of a cycle (stop_hook_active) exits at once and would swallow whichever
# check came second. The scratch latch is recorded before the block is printed: if it cannot be written,
# a block would repeat on every Stop.
emit_stop() {  # extra reason text (may be empty); exits
  local r="$1" json
  if [ -n "$SCR_REASON" ]; then r="${SCR_REASON}${r:+

$r}"; fi
  [ -n "$r" ] || exit 0
  json=$(jq -nc --arg r "$r" '{decision: "block", reason: $r}' 2>/dev/null) || json=""
  if [ -n "$json" ]; then
    if [ -n "$SCR_REASON" ] && [ -n "$SCR_ST" ] && ! printf '%s' "$SCR_KB" > "$SCR_ST" 2>/dev/null; then
      # latch not writable: drop the scratch part so it cannot repeat on every Stop, keep the rest
      r=${r#"$SCR_REASON"}; r=${r#$'\n\n'}; SCR_REASON=""
      [ -n "$r" ] && json=$(jq -nc --arg r "$r" '{decision: "block", reason: $r}' 2>/dev/null) || json=""
    fi
    [ -z "$json" ] || printf '%s\n' "$json"
  fi
  exit 0
}
SCR_SID=$(printf '%s' "$INPUT" | jq -er '.session_id | select(type == "string" and test("^[A-Za-z0-9-]{1,64}$"))' 2>/dev/null) || SCR_SID=""
if [ "${MEGAVIBE_DISK_WATCH:-1}" != "0" ] && [ -x "$DW" ] && [ -n "$SCR_SID" ] &&
   command -v perl >/dev/null 2>&1 &&
   [ -z "$(printf '%s' "$INPUT" | jq -r '.agent_id // .agent_type // ""' 2>/dev/null || echo unknown)" ]; then
  SCR_RC=0   # one 8 s deadline for the whole probe (resolving roots, globbing, du); a timeout (rc 142) lets Stop pass
  SCR_ROW=$(perl -e '
    pipe(my $reader, my $writer) or exit 125;
    my $pid = fork; exit 125 unless defined $pid;
    if (!$pid) { close $reader; open STDOUT, ">&", $writer or exit 125;
                 close $writer; exec @ARGV or exit 127 }
    close $writer;
    $SIG{ALRM} = sub { kill "KILL", $pid; exit 124 };
    alarm 8; local $/; my $row = <$reader>; waitpid($pid, 0);
    my $status = $?; print $row if defined $row; exit($status & 127 ? 125 : $status >> 8);
  ' bash "$DW" scratch --kb "$SCR_SID" 2>/dev/null) || SCR_RC=$?
  SCR_KB=${SCR_ROW%%$'\t'*}; SCR_LINE=${SCR_ROW#*$'\t'}; case "$SCR_KB" in ''|*[!0-9]*) SCR_KB=0 ;; esac
  if [ "$SCR_RC" -eq 3 ]; then
    SCR_ST=".agent/LOGS/.scratch-stopped.${SID}"
    SCR_LAST=$(cat "$SCR_ST" 2>/dev/null | tr -d ' \n'); case "$SCR_LAST" in ''|*[!0-9]*) SCR_LAST=0 ;; esac
    if [ "$SCR_KB" -ge $((SCR_LAST + 262144)) ]; then
      SCR_REASON="This session's own scratch is over its budget: ${SCR_LINE}. A round is not done while its copies exist. Remove what finished rounds and runs left (use scratch-own.sh list / clean-unit for session-owned temp entries and review-copy.sh remove for copies inside the session scratchpad). If something large must stay, move it to megavibe-deliverables/ or name it and its size in your report, then finish: this check does not repeat until the scratch grows another 256 MB."
    else
      SCR_REASON=""
    fi
  elif [ "$SCR_RC" -eq 0 ]; then
    rm -f ".agent/LOGS/.scratch-stopped.${SID}" 2>/dev/null || true   # a timed-out measurement (rc 124/142) keeps the latch
  fi
fi

[ "$BG_OFF" = 1 ] && emit_stop ""
REG=$(printf '%s' "$INPUT" | jq -c '.background_tasks // [] | map(select(type=="object"))' 2>/dev/null || echo "[]")
[ "$REG" != "[]" ] || { : > "$STATE" 2>/dev/null; emit_stop ""; }

# Join the registry's running tasks with what this session recorded. A task
# the registry no longer lists is over; a running task this file never saw
# (started before the hook was installed, or in a session that shares the
# checkout) is not ours to judge. A running task is COVERED when another
# running task's command names its id or its output path — that is what an
# armed heartbeat looks like from here, and it stops being true the moment
# the heartbeat exits, times out or is stopped.
STATE_JSON=$(jq -sc 'map(select(type=="object"))' "$STATE" 2>/dev/null || echo "[]")
RESULT=$(jq -nc --argjson reg "$REG" --argjson st "$STATE_JSON" --argjson now "$NOW" --argjson secs "$CHECK_SECS" '
  ($reg | map(select(.status == "running"))) as $live
  | ($live | map(.id)) as $ids
  # One row per id. A task re-registered under the same id (the harness
  # adopts one after a worker restart) must keep the earliest start and the
  # latest nudge, and the freshest path.
  | ($st | map(select(.id as $i | $ids | index($i)))
        | group_by(.id)
        | map({id: .[0].id, kind: .[0].kind,
               path: (max_by(.started).path),
               started: (map(.started) | min),
               nudged: (map(.nudged) | max)})) as $base
  | ($live | map({key: .id, value: (.command // "")}) | from_entries) as $cmd
  | ($live | map(.command // "")) as $cmds
  | ($base | map(
       . as $r
       # Covered: the command of some running task names this one. That is what an
       # armed heartbeat looks like from here.
       | .covered = ([$cmds[] | select(. != "" and (contains($r.id) or ($r.path != "" and contains($r.path))))] | length > 0)
       # A watcher: the command of this task names another watched task — the
       # documented fallback runs the heartbeat through run_in_background, and
       # a watcher does not need a watcher.
       | .watcher = ([$base[] | select(.id != $r.id) | . as $o
                       | ($cmd[$r.id] // "") | select(. != "" and (contains($o.id) or ($o.path != "" and contains($o.path))))] | length > 0)
       | .age = ($now - .started)
       | .due = ((.covered | not) and (.watcher | not) and .age >= $secs and ($now - .nudged) >= $secs))) as $rows
  | {rows: $rows, due: ($rows | map(select(.due)))}' 2>/dev/null) || exit 0
[ -n "$RESULT" ] || emit_stop ""

DUE=$(printf '%s' "$RESULT" | jq -c '.due' 2>/dev/null || echo "[]")
if [ "$DUE" = "[]" ]; then
  printf '%s' "$RESULT" | jq -c '.rows[] | {id, path, kind, started, nudged}' > "$STATE.tmp.$$" 2>/dev/null \
    && mv -f "$STATE.tmp.$$" "$STATE" 2>/dev/null
  rm -f "$STATE.tmp.$$" 2>/dev/null
  emit_stop ""
fi

# Record the nudge before emitting it, so a crash between the two costs a
# nudge rather than repeating one.
printf '%s' "$RESULT" | jq -c --argjson now "$NOW" '.rows[] | if .due then .nudged = $now else . end | {id, path, kind, started, nudged}' > "$STATE.tmp.$$" 2>/dev/null \
  && mv -f "$STATE.tmp.$$" "$STATE" 2>/dev/null
rm -f "$STATE.tmp.$$" 2>/dev/null

LIST=$(printf '%s' "$DUE" | jq -r '.[] | "- \(.kind) task \(.id), \(.age / 60 | floor) min, no heartbeat" + (if .path != "" then " — output: \(.path)" else "" end)' 2>/dev/null)
REASON="Background tasks are running with no completion notification and no heartbeat watching them:
$LIST
For each: read the output now (tail -c 2000 for a bash task; for a subagent, wc -l and the last entry's tool names — never the whole transcript). Judge it against what the task is: a build at +0 growth is hung, an idle server at +0 is fine, repeating restart or traceback lines are a crashloop — act on that, do not keep waiting. Then arm a Monitor heartbeat on each (every ${BEAT_SECS}s: byte or entry delta plus tail) so the next check does not depend on you remembering, and report in one line per task. Silence is not success. (MEGAVIBE_BG_WATCH=0 switches this check off; MEGAVIBE_BG_CHECK_SECS sets the interval, 60–600.)"
emit_stop "$REASON"
