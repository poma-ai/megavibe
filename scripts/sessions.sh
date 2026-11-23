#!/bin/bash
# sessions.sh — the live Claude sessions on this machine as a tree, and the orphans among them.
#
#   megavibe sessions            live sessions, children under the session that launched them
#   megavibe sessions --orphans  only the orphans: sessions launched by a session that has ended
#   megavibe sessions --status   one line for the session-start hook; prints nothing without orphans
#
# Reads Claude Code's session registry (<config dir>/sessions/<pid>.json) and the launch records the
# `megavibe` wrapper writes ($MEGAVIBE_HOME/launches/<pid>.json). A record is joined to a session by pid
# and accepted only when its start time agrees with the registry's (pid reuse). The parent is found by
# the pid the record holds, else by session id: a session's id changes on /clear while its pid stays,
# so an id alone would call a live parent ended. Only sessions megavibe launched with a parent are
# linked: a session you started yourself has none, and `claude -p` workers leave no record. Read-only.
# Names and paths are reduced to a safe character set before they are printed, and further (no spaces,
# short) in --status, because that line is read by a model. One unreadable file is skipped, never the list.
set -euo pipefail

MEGAVIBE_HOME="${MEGAVIBE_HOME:-$HOME/.megavibe}"
REG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
LAUNCHES="$MEGAVIBE_HOME/launches"

mode=list
case "${1:-}" in
  ""|list) mode=list ;;
  --orphans) mode=orphans ;;
  --status) mode=status ;;
  -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: megavibe sessions [--orphans|--status]" >&2; exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  [ "$mode" = status ] && exit 0
  echo "megavibe sessions: jq is required" >&2
  exit 1
fi

regs=""; launchlines=""
for f in "$REG"/*.json; do
  [ -f "$f" ] || continue
  pid=$(basename "$f" .json)
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  [ "$pid" -gt 1 ] || continue
  kill -0 "$pid" 2>/dev/null || continue
  line=$(jq -c --argjson fp "$pid" 'select(type == "object" and .pid == $fp and (.sessionId | type) == "string")' "$f" 2>/dev/null) || line=""
  if [ -n "$line" ]; then
    regs+="$line"$'\n'
    if [ -f "$LAUNCHES/$pid.json" ]; then
      rec=$(jq -c --argjson fp "$pid" 'select(type == "object" and .pid == $fp and (.startedAt | type) == "number")' "$LAUNCHES/$pid.json" 2>/dev/null) || rec=""
      if [ -n "$rec" ]; then launchlines+="$rec"$'\n'; fi
    fi
  fi
done

if [ -z "$regs" ]; then
  [ "$mode" = list ] && echo "no live Claude sessions"
  exit 0
fi

launches=$(printf '%s' "$launchlines" | jq -s 'map({key: (.pid | tostring), value: .}) | from_entries' 2>/dev/null) || launches='{}'

out=$(printf '%s' "$regs" | jq -s -r --argjson L "$launches" --arg home "$HOME" --argjson now "$(date +%s)" --arg mode "$mode" '
  def clean: tostring | gsub("[^A-Za-z0-9._ -]"; "?") | .[0:40];
  def terse: tostring | gsub("[^A-Za-z0-9._-]"; "") | .[0:24];
  def path: tostring | (if ($home | length) > 0 and startswith($home) then "~" + .[($home | length):] else . end)
    | gsub("[^A-Za-z0-9._/~ -]"; "?") | .[0:60];
  def base: split("/") | map(select(length > 0)) | (last // "");
  def age: if . == 0 then "-" else
      (($now - (. / 1000 | floor)) | if . < 0 then 0 else . end) as $s
      | if $s < 60 then "\($s)s" elif $s < 3600 then "\($s / 60 | floor)m" elif $s < 86400 then "\($s / 3600 | floor)h" else "\($s / 86400 | floor)d" end
    end;
  [ .[] | . as $s
    | ($L[($s.pid | tostring)]) as $r
    | (($r != null) and (($s.startedAt | type) == "number") and ((($r.startedAt * 1000) - $s.startedAt) | fabs) < 300000) as $m
    | (if $m and (($r.parentSessionId | type) == "string") and $r.parentSessionId != $s.sessionId
       then ($r.parentSessionId | gsub("[^A-Za-z0-9-]"; "?") | .[0:64]) else null end) as $par
    | { pid: $s.pid, id: $s.sessionId, name: ($s.name // "?" | clean), state: ($s.status // "?" | clean),
        started: (if ($s.startedAt | type) == "number" then $s.startedAt else 0 end), dir: ($s.cwd // "" | path),
        by: (if $m then "megavibe" else "-" end), parent: $par,
        ppid: (if $par != null and (($r.parentPid | type) == "number") then $r.parentPid else null end) } ] as $base
  | ($base | map(
      . as $x
      | (if $x.ppid != null then ($base | map(select(.pid == $x.ppid and .id != $x.id)) | .[0].id)
         elif $x.parent != null then ($base | map(select(.id == $x.parent and .id != $x.id)) | .[0].id)
         else null end) as $up
      | $x + {up: $up, orphan: ($x.parent != null and $up == null)})) as $rows
  | ($rows | map(select(.orphan))) as $orph
  | def line($d): (("  " * $d) + (if $d > 0 then "└ " else "" end) + .name) + "\t\(.pid)\t\(.state)\t\(.started | age)\t\(.by)\t\(.dir)"
      + (if .orphan then "\tORPHAN: started by \(.parent[0:8]), which has ended" else "" end);
    def tree($d): . as $n | line($d),
      (if $d < 8 then ($rows | map(select(.up == $n.id)) | sort_by(.started) | .[] | tree($d + 1)) else empty end);
    if $mode == "status" then
      (if ($orph | length) == 0 then empty
       else "\($orph | length) running session(s) were started by a session that has ended: " + ($orph | map("\(.name | terse) (pid \(.pid), \(.dir | base | terse))") | join("; ")) + ". Tell the user; do not stop them yourself."
       end)
    elif $mode == "orphans" then
      (if ($orph | length) == 0 then "no orphaned sessions" else ($orph[] | "\(.name)\t\(.pid)\t\(.dir)\tstarted by \(.parent[0:8]), which has ended") end)
    else
      "NAME\tPID\tSTATE\tAGE\tSTARTED BY\tDIR",
      ($rows | map(select(.up == null)) | sort_by(.started) | .[] | tree(0))
    end
' 2>/dev/null) || out=""

if [ "$mode" = status ]; then
  if [ -n "$out" ]; then printf '%s\n' "$out"; fi
  exit 0
fi
if command -v column >/dev/null 2>&1; then
  printf '%s\n' "$out" | column -t -s "$(printf '\t')"
else
  printf '%s\n' "$out"
fi
