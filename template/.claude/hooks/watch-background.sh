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
[ "${MEGAVIBE_BG_WATCH:-1}" = "0" ] && exit 0

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
  for f in "${TMPDIR:-/tmp}"/claude-"$uid"/*/*/tasks/"$1".output \
           /private/tmp/claude-"$uid"/*/*/tasks/"$1".output \
           /tmp/claude-"$uid"/*/*/tasks/"$1".output; do
    [ -e "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 0
}

# ---------------------------------------------------------------- PostToolUse
if [ "$EVENT" = "PostToolUse" ]; then
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

  jq -nc --arg id "$ID" --arg p "$OUT" --arg k "$KIND" --argjson t "$NOW" \
    '{id:$id, path:$p, kind:$k, started:$t, nudged:0}' >> "$STATE" 2>/dev/null || true

  # The loop is built by jq so the path is shell-quoted whatever it contains.
  # No path resolved → no loop: a loop on a placeholder reports 0 bytes
  # forever, which reads as a hang and gets a healthy task killed.
  if [ -n "$OUT" ]; then
    if [ "$KIND" = "bash" ]; then
      LOOP=$(jq -nr --arg p "$OUT" --arg id "$ID" --argjson s "$BEAT_SECS" '
        "f=" + ($p|@sh) + "; last=0; while sleep " + ($s|tostring) + "; do s=$(wc -c <\"$f\" 2>/dev/null | tr -d \" \" || echo 0); printf '"'"'bg " + $id + ": %s bytes (+%s) | %s\\n'"'"' \"$s\" \"$((s-last))\" \"$(tail -c 200 \"$f\" 2>/dev/null | tr '"'"'\\n'"'"' '"'"' '"'"')\"; last=$s; done"')
      READ="Each beat is the byte delta and the tail. Judge it against what the task IS: a build or test run at +0 for two beats is hung; a server idling at +0 is healthy; a file that keeps growing with the same lines repeating is a crashloop. Read the output file before acting, then act — kill it, fix it, or say it is fine."
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

REG=$(printf '%s' "$INPUT" | jq -c '.background_tasks // [] | map(select(type=="object"))' 2>/dev/null || echo "[]")
[ "$REG" != "[]" ] || { : > "$STATE" 2>/dev/null; exit 0; }

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
[ -n "$RESULT" ] || exit 0

DUE=$(printf '%s' "$RESULT" | jq -c '.due' 2>/dev/null || echo "[]")
if [ "$DUE" = "[]" ]; then
  printf '%s' "$RESULT" | jq -c '.rows[] | {id, path, kind, started, nudged}' > "$STATE.tmp.$$" 2>/dev/null \
    && mv -f "$STATE.tmp.$$" "$STATE" 2>/dev/null
  rm -f "$STATE.tmp.$$" 2>/dev/null
  exit 0
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
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
