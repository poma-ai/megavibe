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
[ "$NOW" = UNKNOWN ] && exit 0
[ "$NOW" = "$PREV" ] && exit 0
printf '%s' "$NOW" > "$DISK_LEVEL_FILE" 2>/dev/null || true
if [ "$NOW" = OK ]; then
  [ "$PREV" != UNKNOWN ] && echo "disk: free space is back above the warn threshold."
  exit 0
fi
perl -e 'alarm shift; exec @ARGV' 8 bash "$DISK_SCRIPT" check > "$TMP" 2>/dev/null || true
OUT=$(cat "$TMP" 2>/dev/null); rm -f "$TMP" 2>/dev/null || true
[ -n "$OUT" ] || OUT="disk: free space is $NOW (the sizes scan did not finish in time)."
printf '%s\n' "## Low disk space (mid-session check: $NOW)" "$OUT" \
  "Your own scratchpad counts: reviewer repo copies, venvs and model downloads from finished rounds are yours to trash now (a delete moves them to the Trash; tell the user the Trash needs emptying to free the space). Do not delete anything you did not create; at CRITICAL, say so before any job that writes gigabytes."
exit 0
