#!/bin/bash
# usage-probe.sh: `megavibe usage probe ...`. Keeps the Codex weekly-usage reading fresh. Codex writes a
# rate_limits record into its sessions folder only when it is called, so between real jobs the reading
# ages and the forecast (usage-route.sh forecast) goes stale. One probe is a minimal `codex exec` call
# (cheapest model, read-only, scratch directory, about 15K mostly cached input tokens, 5 output tokens).
# WHO RUNS IT: the node (template/node/node.sh, every 5 minutes) calls `run --every 30` on a Mac where the
# Personal Assistant is switched on (pa.on); that is the only caller. Plain megavibe use with no PA never
# runs it, and nothing here installs a scheduler or runs launchctl.
#
#   run [--every MIN]   one probe now; with --every, only when the last probe is MIN or more minutes old.
#                       Always skipped when a Codex reading under 15 min old exists or codex is unavailable.
#   status              the last probe lines and whether this Mac's node runs it (pa.on)
#
# Probe model: MEGAVIBE_PROBE_MODEL (default gpt-6-luna). If that model is not on the plan the call is retried
# once with the user's own configured model. Test seams: MEGAVIBE_HOME, MEGAVIBE_CODEX_HOME, MEGAVIBE_CODEX_BIN.
set -uo pipefail

MH="${MEGAVIBE_HOME:-$HOME/.megavibe}"
U="$MH/usage"
CODEX="${MEGAVIBE_CODEX_BIN:-codex}"
CH="${MEGAVIBE_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}"
say() { printf '%s\n' "$*"; }

# bounded SECS CMD...: CMD in its own process group; at the deadline the whole group is ended (TERM, then KILL) and the
# exit status is 142; after a normal exit anything CMD left behind is ended too. Never touches a process outside the group.
bounded() {
  perl -e 'my $t = shift; my $pid = fork(); exit 127 unless defined $pid;
    if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; select(undef, undef, undef, 1.5); kill "KILL", -$pid; waitpid($pid, 0); exit 142 };
    alarm $t; waitpid($pid, 0); my $s = $?; alarm 0; kill "KILL", -$pid;
    exit($s & 127 ? 128 + ($s & 127) : $s >> 8)' "$@"
}

cmd_status() {
  if [ -e "$MH/node/pa.on" ]; then say "probe: on (pa.on is set; the node runs it every 30 minutes)"; else say "probe: off (no PA on this Mac; the node does not run it)"; fi
  [ -f "$U/probe.log" ] && tail -n 3 "$U/probe.log"
  return 0
}

cmd_run() {
  local every=""
  if [ "${1:-}" = "--every" ]; then
    every="${2:-}"; case "$every" in ''|*[!0-9]*) say "usage: run [--every MINUTES]"; return 2 ;; esac
  fi
  mkdir -p "$U" 2>/dev/null || return 0
  if [ -n "$every" ] && [ -f "$U/probe.stamp" ] && [ -z "$(find "$U/probe.stamp" -mmin +$((every - 1)) 2>/dev/null)" ]; then
    say "skip: last probe is under $every min old"; return 0
  fi
  { command -v "$CODEX" >/dev/null 2>&1 && bounded 20 "$CODEX" exec --help >/dev/null 2>&1; } || { say "skip: codex exec not available"; return 0; }
  LOCK="$U/probe.lock"; local lock="$LOCK"
  # a lock older than 10 min is a dead run's; never two probes at once
  if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null; fi
  mkdir "$lock" 2>/dev/null || { say "skip: a probe is running"; return 0; }
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  if [ -d "$CH/sessions" ] && [ -n "$(find "$CH/sessions" -type f -name 'rollout-*.jsonl' -mmin -15 2>/dev/null | head -n 1)" ]; then
    say "skip: a Codex reading is under 15 min old"; return 0
  fi
  local d rc model="${MEGAVIBE_PROBE_MODEL:-gpt-6-luna}"
  d=$(mktemp -d "${TMPDIR:-/tmp}/usage-probe.XXXXXX") || return 0
  ( cd "$d" || exit 1
    bounded 120 "$CODEX" exec -m "$model" -s read-only --skip-git-repo-check -c model_reasoning_effort=low "Reply with the single word ok." </dev/null >/dev/null 2>&1 ); rc=$?
  # retry once with the configured model only when the first call failed fast (a model not on the plan); a timeout is not retried
  if [ "$rc" != 0 ] && [ "$rc" != 142 ] && [ "$rc" != 124 ]; then
    model=configured
    ( cd "$d" || exit 1
      bounded 120 "$CODEX" exec -s read-only --skip-git-repo-check -c model_reasoning_effort=low "Reply with the single word ok." </dev/null >/dev/null 2>&1 ); rc=$?
  fi
  rm -r "$d" 2>/dev/null
  : > "$U/probe.stamp"
  printf '%s rc=%s model=%s\n' "$(date '+%F %T')" "$rc" "$model" >> "$U/probe.log"
  if [ "$(wc -l < "$U/probe.log" | tr -d ' ')" -gt 400 ]; then
    tail -n 200 "$U/probe.log" > "$U/probe.log.$$" && mv -f "$U/probe.log.$$" "$U/probe.log"
  fi
  return 0
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  status) cmd_status ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
