#!/bin/bash
# usage-probe.sh: `megavibe usage probe ...`. Keeps the Codex weekly-usage reading fresh. Codex writes a
# rate_limits record into its sessions folder only when it is called, so between real jobs the reading
# ages and the forecast (usage-route.sh forecast) goes stale. One probe is a minimal `codex exec` call
# (cheapest model, read-only, scratch directory, about 15K mostly cached input tokens, 5 output tokens).
# OPT-IN: nothing here is scheduled or runs until `megavibe usage probe install` and the user loads the
# LaunchAgent it prints. A fresh install of megavibe makes no background Codex call.
#
#   install [MINUTES]   write the LaunchAgent (default every 30 min, 10 to 1440) and print the load line
#                       for the user to run (megavibe never runs launchctl itself)
#   run                 one probe now (what the LaunchAgent runs); skipped when a Codex reading is under 15 min old
#   status              installed, loaded, last probe lines
#   uninstall           print the line that stops it (and the plist to delete)
#
# Probe model: MEGAVIBE_PROBE_MODEL (default gpt-6-luna). If that model is not on the plan the call is retried
# once with the user's own configured model. Test seams: MEGAVIBE_HOME, MEGAVIBE_CODEX_HOME, MEGAVIBE_CODEX_BIN,
# MEGAVIBE_PROBE_PLIST.
set -uo pipefail

MH="${MEGAVIBE_HOME:-$HOME/.megavibe}"
U="$MH/usage"
LABEL=com.megavibe.usage-probe
PLIST="${MEGAVIBE_PROBE_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
CODEX="${MEGAVIBE_CODEX_BIN:-codex}"
CH="${MEGAVIBE_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}"
say() { printf '%s\n' "$*"; }
die() { printf 'megavibe usage probe: %s\n' "$*" >&2; exit 1; }

# the directory of the codex that install found (npm-global and user-local installs are outside the default PATH), then the usual ones
probe_path() {
  local c d=""; c=$(command -v "$CODEX" 2>/dev/null) && case "$c" in /*) d="$(dirname "$c"):" ;; esac
  printf '%s/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' "$d"
}

# settings chosen at install time that the scheduled run must see too: the probe model and the Codex home
probe_env_extra() {
  local x; x() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  [ -z "${MEGAVIBE_PROBE_MODEL:-}" ] || printf '<key>MEGAVIBE_PROBE_MODEL</key><string>%s</string>' "$(x "$MEGAVIBE_PROBE_MODEL")"
  [ -z "${MEGAVIBE_CODEX_HOME:-${CODEX_HOME:-}}" ] || printf '<key>CODEX_HOME</key><string>%s</string>' "$(x "${MEGAVIBE_CODEX_HOME:-$CODEX_HOME}")"
}

plist_text() {
  local x; x() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  local self; self="$MH/scripts/usage-probe.sh"
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$(x "$self")</string><string>run</string></array>
  <key>EnvironmentVariables</key><dict><key>MEGAVIBE_HOME</key><string>$(x "$MH")</string><key>PATH</key><string>$(x "$(probe_path)")</string>$(probe_env_extra)</dict>
  <key>RunAtLoad</key><false/>
  <key>StartInterval</key><integer>$(( ${1:-30} * 60 ))</integer>
  <key>StandardOutPath</key><string>$(x "$U/probe.launchd.log")</string>
  <key>StandardErrorPath</key><string>$(x "$U/probe.launchd.log")</string>
</dict></plist>
PL
}

cmd_install() {
  local mins="${1:-30}"
  case "$mins" in ''|*[!0-9]*) die "install: MINUTES must be a whole number" ;; esac
  [ "$mins" -ge 10 ] && [ "$mins" -le 1440 ] || die "install: MINUTES must be 10 to 1440"
  [ "$(uname -s)" = Darwin ] || die "install: LaunchAgents are macOS only; on another system run '$0 run' from your own scheduler"
  mkdir -p "$U" "$(dirname "$PLIST")" || die "cannot create $U"
  local new; new=$(plist_text "$mins")
  if command -v plutil >/dev/null 2>&1; then
    printf '%s\n' "$new" > "$PLIST.tmp" && plutil -lint -s "$PLIST.tmp" || { rm -f "$PLIST.tmp"; die "the plist does not pass plutil -lint; nothing installed"; }
    rm -f "$PLIST.tmp"
  fi
  if [ -f "$PLIST" ] && [ "$(cat "$PLIST")" = "$new" ]; then say "skip   $PLIST (current)"
  else printf '%s\n' "$new" > "$PLIST.tmp" && mv -f "$PLIST.tmp" "$PLIST" && say "wrote  $PLIST (every $mins min)"; fi
  say "Each probe is one tiny Codex call (about 15K mostly cached input tokens). Load it yourself, in Terminal (megavibe does not run launchctl):"
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && say "  launchctl bootout gui/$(id -u)/$LABEL"
  say "  launchctl bootstrap gui/$(id -u) $(printf '%q' "$PLIST")"
}

cmd_status() {
  if [ -f "$PLIST" ]; then say "probe: LaunchAgent written ($PLIST)"; else say "probe: not installed (off; megavibe usage probe install)"; fi
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then say "probe: loaded"; else say "probe: not loaded"; fi
  [ -f "$U/probe.log" ] && tail -n 3 "$U/probe.log"
  return 0
}

cmd_uninstall() {
  say "Stop it yourself, in Terminal (megavibe does not run launchctl):"
  say "  launchctl bootout gui/$(id -u)/$LABEL"
  say "then delete $PLIST"
}

cmd_run() {
  { command -v "$CODEX" >/dev/null 2>&1 && perl -e 'alarm 20; exec @ARGV' "$CODEX" exec --help >/dev/null 2>&1; } || { say "skip: codex exec not available"; return 0; }
  mkdir -p "$U" 2>/dev/null || return 0
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
    perl -e 'alarm 120; exec @ARGV' "$CODEX" exec -m "$model" -s read-only --skip-git-repo-check -c model_reasoning_effort=low "Reply with the single word ok." </dev/null >/dev/null 2>&1 ); rc=$?
  # retry once with the configured model only when the first call failed fast (a model not on the plan); a timeout is not retried
  if [ "$rc" != 0 ] && [ "$rc" != 142 ] && [ "$rc" != 124 ]; then
    model=configured
    ( cd "$d" || exit 1
      perl -e 'alarm 120; exec @ARGV' "$CODEX" exec -s read-only --skip-git-repo-check -c model_reasoning_effort=low "Reply with the single word ok." </dev/null >/dev/null 2>&1 ); rc=$?
  fi
  rm -r "$d" 2>/dev/null
  printf '%s rc=%s model=%s\n' "$(date '+%F %T')" "$rc" "$model" >> "$U/probe.log"
  if [ "$(wc -l < "$U/probe.log" | tr -d ' ')" -gt 400 ]; then
    tail -n 200 "$U/probe.log" > "$U/probe.log.$$" && mv -f "$U/probe.log.$$" "$U/probe.log"
  fi
  return 0
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  run) cmd_run ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
