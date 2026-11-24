#!/bin/bash
# DO NOT use set -e — this helper must be resilient to transient failures.
trap 'exit 0' ERR
set -u

# Megavibe — the mid-session disk check, run by log-tool-event.sh under a kernel
# lock (perl flock on $DISK_LOCK_FILE) and a deadline (perl alarm), once per
# MEGAVIBE_DISK_CHECK_MINS minutes of tool activity. Everything it prints to
# stdout is the message for the model; nothing when there is nothing to say.
#
# Env (set by the caller): DISK_SCRIPT (disk-watch.sh), DISK_LEVEL_FILE,
# DISK_STAMP_FILE, DISK_MINS. Inside the lock: re-test the stamp (another call
# may have just checked), touch it, probe one word from disk-watch.sh (OK, LOW,
# CRITICAL or UNKNOWN; one bounded df, no scan), compare with the recorded
# level and update it. Compare and update happen here, under the lock, so one
# transition is reported once and an older reading cannot overwrite a newer
# one. The sizes scan (`check`) runs only on a transition INTO LOW or CRITICAL.
# UNKNOWN keeps the previous level and says nothing: a failed measurement is
# not a recovery. The first reading of a session is never announced as one.

: "${DISK_SCRIPT:?}" "${DISK_LEVEL_FILE:?}" "${DISK_STAMP_FILE:?}" "${DISK_MINS:?}"

age() {  # seconds since the file's mtime; status 1 when unknown
  local m
  m=$(stat -f %m "$1" 2>/dev/null) || m=$(stat -c %Y "$1" 2>/dev/null) || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( $(date +%s) - m ))
}
if a=$(age "$DISK_STAMP_FILE") && [ "$a" -lt $((DISK_MINS * 60)) ]; then exit 0; fi
touch "$DISK_STAMP_FILE" 2>/dev/null || true

TMP="${DISK_STAMP_FILE}.probe.$$"
# Probe and scan write to a file, not a pipe: a command substitution would wait
# for every holder of the pipe, so a stalled grandchild (a df on a dead mount)
# would outlive the alarm; a file lets the deadline end the wait.
perl -e 'alarm shift; exec @ARGV' 10 bash "$DISK_SCRIPT" level > "$TMP" 2>/dev/null || true
NOW=$(tr -d ' \n' < "$TMP" 2>/dev/null); rm -f "$TMP" 2>/dev/null || true
case "$NOW" in OK|LOW|CRITICAL) ;; *) NOW=UNKNOWN ;; esac
PREV=$(cat "$DISK_LEVEL_FILE" 2>/dev/null | tr -d ' \n')
case "$PREV" in OK|LOW|CRITICAL) ;; *) PREV=UNKNOWN ;; esac
scratch_report() {
# The session's own scratch against its budget (default 2 GB, MEGAVIBE_SCRATCH_BUDGET_GB; 0 off): tell the
# session to clean up when it first crosses the budget and again each time it grows another GB past the
# size last reported, whatever the disk's free space is. One bounded du per folder, inside the deadline.
if [ -n "${DISK_SESSION_ID:-}" ]; then
  SRC=0   # `|| SRC=$?` below: a bare nonzero status would fire the ERR trap before it is read
  SCR_FILE="${DISK_STAMP_FILE%/*}/.scratch-reported.${DISK_SESSION_ID}"
  perl -e 'alarm shift; exec @ARGV' 10 bash "$DISK_SCRIPT" scratch --kb "$DISK_SESSION_ID" > "$TMP" 2>/dev/null || SRC=$?
  if [ "$SRC" = 3 ]; then
    SKB=$(head -1 "$TMP" 2>/dev/null | cut -f1); case "$SKB" in ''|*[!0-9]*) SKB=0 ;; esac
    LAST=$(cat "$SCR_FILE" 2>/dev/null | tr -d ' \n'); case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
    if [ "$LAST" -eq 0 ] || [ "$SKB" -ge $((LAST + 1048576)) ]; then
      printf '%s' "$SKB" > "$SCR_FILE" 2>/dev/null || true
      printf '%s\n' "## Session scratch over budget" "$(head -1 "$TMP" 2>/dev/null | cut -f2-)" \
        "A round is not done while its copies exist. Remove what finished rounds and runs left (review copies, venvs, build output, task output): \`TMPDIR=<your scratchpad> ~/.megavibe/scripts/review-copy.sh list\` and \`remove\` for reader copies, \`scratch-own.sh list\` / \`clean-unit\` with this session ID for session-owned temp entries. Something large you must keep: move it to megavibe-deliverables/ or name it and its size in your report. The Stop check will not let this turn end as done until it is under budget or you have said so."
    fi
  elif [ "$SRC" = 0 ]; then
    rm -f "$SCR_FILE" 2>/dev/null || true   # under budget: forget the reported size (a timeout or unknown keeps it)
  fi
  if [ "$NOW" = LOW ] || [ "$NOW" = CRITICAL ]; then
    if perl -e 'alarm shift; exec @ARGV' 6 bash "$DISK_SCRIPT" scratch-other "$DISK_SESSION_ID" > "$TMP" 2>/dev/null; then
      cat "$TMP" 2>/dev/null || true
    fi
  fi
  rm -f "$TMP" 2>/dev/null || true
fi
}
trap 'scratch_report; exit 0' EXIT
[ "$NOW" = UNKNOWN ] && exit 0
[ "$NOW" = "$PREV" ] && exit 0
if [ "$NOW" = OK ]; then
  [ "$PREV" != UNKNOWN ] && echo "disk: free space is back above the warn threshold."
  printf '%s' "$NOW" > "$DISK_LEVEL_FILE" 2>/dev/null || true
  exit 0
fi
perl -e 'alarm shift; exec @ARGV' 8 bash "$DISK_SCRIPT" check > "$TMP" 2>/dev/null || true
OUT=$(cat "$TMP" 2>/dev/null); rm -f "$TMP" 2>/dev/null || true
[ -n "$OUT" ] || OUT="disk: free space is $NOW (the sizes scan did not finish in time)."
printf '%s\n' "## Low disk space (mid-session check: $NOW)" "$OUT" \
  "Your own scratchpad counts: reviewer repo copies, venvs and model downloads from finished rounds are yours to trash now (a delete moves them to the Trash; tell the user the Trash needs emptying to free the space). Do not delete anything you did not create; at CRITICAL, say so before any job that writes gigabytes."
printf '%s' "$NOW" > "$DISK_LEVEL_FILE" 2>/dev/null || true   # cached only after the warning is out: a kill before this repeats it next time
exit 0
