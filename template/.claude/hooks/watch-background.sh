#!/bin/bash
# DO NOT use set -e — a hook must never fail the turn.
set -u

# Megavibe — a background task nobody is watching is a task that can crashloop
# forever.
#
# The harness notifies when a background task COMPLETES. A task that hangs, or
# restarts itself in a loop, never completes, so the notification never comes
# and silence looks exactly like progress. Sessions have waited on that silence
# for an hour. The fix is a heartbeat: something that wakes the main thread on
# a clock, with fresh evidence, whether or not the task has finished.
#
# Three handlers, one script:
#   PostToolUse(Bash, run_in_background) — record the task; tell Claude to arm
#       a Monitor heartbeat on its output file now, with the loop to paste.
#   PostToolUse(Agent, async) — same for a subagent, on its transcript symlink.
#   PostToolUse(Monitor) — a Monitor whose command names a recorded task's id
#       or output path covers that task; mark it.
#   Stop — for every recorded task older than CHECK_SECS with no completion
#       notification in the transcript, and no heartbeat covering it, block the
#       stop ONCE with "read the output file now and judge". At most once per
#       CHECK_SECS per task, and never when stop_hook_active is set (that stop
#       is the one this hook already caused). A Stop hook cannot wake Claude
#       later; it can only refuse to let the turn end on "waiting". The
#       heartbeat is the mechanism, this is the net under it.
#
# State: .agent/LOGS/.bg-tasks.${SID}.jsonl, one row per task:
#   {id, path, kind, started, covered, nudged}
# Rewritten on Stop with completed tasks dropped. Per session, so two sessions
# in one checkout never nudge each other about the other's tasks.
#
# Env: MEGAVIBE_BG_CHECK_SECS (default 300) — the interval, both for the
# heartbeat Claude is told to arm and for how long a task may go unchecked
# before a Stop is blocked. MEGAVIBE_BG_WATCH=0 switches the hook off.
#
# Triggered by: PostToolUse (Bash|Agent|Monitor), Stop. Exit 0 always.

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
[ "${MEGAVIBE_BG_WATCH:-1}" = "0" ] && exit 0

CHECK_SECS="${MEGAVIBE_BG_CHECK_SECS:-300}"
case "$CHECK_SECS" in ''|*[!0-9]*) CHECK_SECS=300 ;; esac
[ "$CHECK_SECS" -ge 60 ] || CHECK_SECS=60
# The heartbeat sleeps a little under the check interval so a task that is
# heartbeating is never also nudged for being unchecked.
BEAT_SECS=$((CHECK_SECS - 60))
[ "$BEAT_SECS" -ge 30 ] || BEAT_SECS=30

INPUT=$(cat 2>/dev/null || echo "")
[ -n "$INPUT" ] || exit 0

{
  IFS= read -r -d "" EVENT
  IFS= read -r -d "" TOOL
  IFS= read -r -d "" SID
  IFS= read -r -d "" TRANSCRIPT
  IFS= read -r -d "" STOP_ACTIVE
} < <(printf '%s' "$INPUT" | jq -j '
  [ (.hook_event_name // ""), (.tool_name // ""), (.session_id // "default"),
    (.transcript_path // ""), (.stop_hook_active // false | tostring)
  ] | map(. + "\u0000") | join("")' 2>/dev/null) || true
EVENT="${EVENT:-}"; TOOL="${TOOL:-}"; TRANSCRIPT="${TRANSCRIPT:-}"; STOP_ACTIVE="${STOP_ACTIVE:-false}"

SID=$(printf '%s' "${SID:-default}" | tr -cd 'A-Za-z0-9-' | cut -c1-12)
SID="${SID:-default}"
mkdir -p ".agent/LOGS" 2>/dev/null || true
STATE=".agent/LOGS/.bg-tasks.${SID}.jsonl"
NOW=$(date +%s 2>/dev/null | tr -cd '0-9'); NOW="${NOW:-0}"
[ "$NOW" -gt 0 ] || exit 0

record() {  # id path kind
  jq -nc --arg id "$1" --arg p "$2" --arg k "$3" --argjson t "$NOW" \
    '{id:$id, path:$p, kind:$k, started:$t, covered:false, nudged:0}' >> "$STATE" 2>/dev/null || true
}

# ---------------------------------------------------------------- PostToolUse
if [ "$EVENT" = "PostToolUse" ]; then
  RESP=$(printf '%s' "$INPUT" | jq -r '.tool_response | tostring' 2>/dev/null || echo "")

  case "$TOOL" in
    Bash)
      BG=$(printf '%s' "$INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null || echo false)
      [ "$BG" = "true" ] || exit 0
      ID=$(printf '%s' "$INPUT" | jq -r '.tool_response.backgroundTaskId // ""' 2>/dev/null || echo "")
      [ -n "$ID" ] || ID=$(printf '%s' "$RESP" | sed -n 's/.*background with ID: \([A-Za-z0-9_-]*\).*/\1/p' | head -1)
      [ -n "$ID" ] || exit 0
      OUT=$(printf '%s' "$RESP" | sed -n 's/.*written to: \([^ ]*\.output\).*/\1/p' | head -1)
      [ -n "$OUT" ] || OUT="(see the tool result)"
      record "$ID" "$OUT" "bash"
      DESC=$(printf '%s' "$INPUT" | jq -r '.tool_input.description // "background task"' 2>/dev/null | cut -c1-80)
      LOOP="f='$OUT'; last=0; while sleep $BEAT_SECS; do s=\$(wc -c <\"\$f\" 2>/dev/null | tr -d ' ' || echo 0); printf 'bg $ID: %s bytes (+%s) | %s\\n' \"\$s\" \"\$((s-last))\" \"\$(tail -c 200 \"\$f\" 2>/dev/null | tr '\\n' ' ')\"; last=\$s; done"
      MSG="Background task $ID started ($DESC). Output: $OUT. Do NOT end your turn waiting for it: a task that hangs or crashloops never sends a completion notification, and silence looks like progress. Arm a heartbeat NOW with the Monitor tool (description: 'heartbeat $ID', timeout_ms = the task's budget, at most 3600000), command:
$LOOP
Each beat wakes you with the byte delta and the tail: +0 for several beats is a hang, a growing file with repeating lines is a crashloop — read the output file and act on either. When the completion notification arrives, TaskStop the heartbeat. If the task is expected to finish inside $BEAT_SECS seconds, say so in one line instead of arming one."
      ;;
    Agent)
      # An async spawn reports "agentId: <id>" and "output_file: <path>"; a
      # synchronous one returns the result inline and needs no heartbeat.
      ID=$(printf '%s' "$RESP" | sed -n 's/.*agentId: \([A-Za-z0-9_-]*\).*/\1/p' | head -1)
      [ -n "$ID" ] || exit 0
      OUT=$(printf '%s' "$RESP" | sed -n 's/.*output_file: \([^ ]*\.output\).*/\1/p' | head -1)
      [ -n "$OUT" ] || OUT="(see the tool result)"
      record "$ID" "$OUT" "agent"
      LOOP="f='$OUT'; last=0; while sleep $BEAT_SECS; do n=\$(wc -l <\"\$f\" 2>/dev/null | tr -d ' ' || echo 0); t=\$(tail -1 \"\$f\" 2>/dev/null | jq -r '[.message.content[]? | select(.type==\"tool_use\") | .name] | join(\",\")' 2>/dev/null); printf 'agent $ID: %s entries (+%s) | last tools: %s\\n' \"\$n\" \"\$((n-last))\" \"\${t:-none}\"; last=\$n; done"
      MSG="Subagent $ID started. Do NOT end your turn waiting for it: a subagent that loops or stalls never completes, and silence looks like progress. Arm a heartbeat NOW with the Monitor tool (description: 'heartbeat $ID', timeout_ms = its budget, at most 3600000), command:
$LOOP
Never Read that transcript whole — it is the subagent's full JSONL. +0 entries for several beats is a stall; the same tool names repeating for many beats is a loop — SendMessage the agent or TaskStop it. When its completion notification arrives, TaskStop the heartbeat."
      ;;
    Monitor)
      # Mark every recorded task whose id or output path the Monitor names.
      [ -f "$STATE" ] || exit 0
      CMD=$(printf '%s' "$INPUT" | jq -r '(.tool_input.command // "") + " " + (.tool_input.description // "")' 2>/dev/null || echo "")
      [ -n "$CMD" ] || exit 0
      TMP="$STATE.tmp.$$"
      jq -c --arg cmd "$CMD" 'select(type=="object") | (.id // "") as $id | (.path // "") as $p
        | if ($id != "" and ($cmd | contains($id))) or ($p != "" and ($cmd | contains($p))) then .covered = true else . end' "$STATE" > "$TMP" 2>/dev/null && mv -f "$TMP" "$STATE" 2>/dev/null
      rm -f "$TMP" 2>/dev/null
      exit 0
      ;;
    *) exit 0 ;;
  esac

  jq -nc --arg m "$MSG" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  exit 0
fi

# ----------------------------------------------------------------------- Stop
[ "$EVENT" = "Stop" ] || exit 0
[ -f "$STATE" ] || exit 0
[ -s "$STATE" ] || exit 0
# This stop was caused by a block from a Stop hook (ours or another). Never
# block again inside that cycle, or the turn can never end.
[ "$STOP_ACTIVE" = "true" ] && exit 0

# Drop tasks whose completion notification is in the transcript. A grep per
# task, not a parse: the transcript can be tens of MB.
LIVE=""
while IFS= read -r row; do
  [ -n "$row" ] || continue
  id=$(printf '%s' "$row" | jq -r '.id // ""' 2>/dev/null); [ -n "$id" ] || continue
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && grep -qF "<task-id>${id}</task-id>" "$TRANSCRIPT" 2>/dev/null; then
    continue
  fi
  LIVE="${LIVE}${row}
"
done < "$STATE"
printf '%s' "$LIVE" > "$STATE" 2>/dev/null || true
[ -n "$LIVE" ] || exit 0

# The oldest unchecked, uncovered task older than the interval.
DUE=$(printf '%s' "$LIVE" | jq -c --argjson now "$NOW" --argjson secs "$CHECK_SECS" \
  'select(type=="object") | select(.covered != true) | select(($now - .started) >= $secs) | select(($now - (.nudged // 0)) >= $secs)' 2>/dev/null | head -1)
[ -n "$DUE" ] || exit 0

ID=$(printf '%s' "$DUE" | jq -r '.id'); OUT=$(printf '%s' "$DUE" | jq -r '.path'); KIND=$(printf '%s' "$DUE" | jq -r '.kind')
AGE=$(( (NOW - $(printf '%s' "$DUE" | jq -r '.started')) / 60 ))

# Record the nudge before emitting it, so a crash between the two costs a
# nudge rather than repeating one.
TMP="$STATE.tmp.$$"
printf '%s' "$LIVE" | jq -c --arg id "$ID" --argjson now "$NOW" 'if .id == $id then .nudged = $now else . end' > "$TMP" 2>/dev/null && mv -f "$TMP" "$STATE" 2>/dev/null
rm -f "$TMP" 2>/dev/null

if [ "$KIND" = "agent" ]; then
  HOW="Check its progress without reading the transcript whole: \`wc -l\` and the last entry's tool names (tail -1 | jq). No growth is a stall, the same tools repeating is a loop: SendMessage or TaskStop it."
else
  HOW="Read the tail of that file now (tail -c 2000). No growth is a hang; repeating restart, traceback or retry lines are a crashloop: kill it or fix it, do not keep waiting."
fi
REASON="Background $KIND task $ID has run for ${AGE} min with no completion notification and no heartbeat watching it (output: $OUT). $HOW Then arm a Monitor heartbeat on it (every ${BEAT_SECS}s, byte or entry delta plus tail) so the next check does not depend on you remembering, and report in one line. Silence is not success."
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
