#!/bin/bash
# sessions.sh — the live Claude sessions on this machine as a tree, and the orphans among them.
#
#   megavibe sessions            live sessions, children under the session that launched them
#   megavibe sessions --orphans  only the orphans: sessions launched by a session that has ended
#   megavibe sessions --status   one line for the session-start hook; prints nothing without orphans
#
# Reads Claude Code's session registry (<config dir>/sessions/<pid>.json) and the launch records the
# `megavibe` wrapper writes ($MEGAVIBE_HOME/launches/<pid>.json). A record is joined to a session by pid
# and accepted only when its start time agrees with the registry's (pid reuse). Only sessions megavibe
# launched with a parent are linked: a session you started yourself has none, and `claude -p` workers
# have no record at all. Read-only. Names and paths are reduced to a safe character set before they are
# printed, because the hook line is read by a model.
set -euo pipefail

MEGAVIBE_HOME="${MEGAVIBE_HOME:-$HOME/.megavibe}"
REG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
LAUNCHES="$MEGAVIBE_HOME/launches"

mode=list
case "${1:-}" in
  ""|list) mode=list ;;
  --orphans) mode=orphans ;;
  --status) mode=status ;;
  -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: megavibe sessions [--orphans|--status]" >&2; exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  [ "$mode" = status ] && exit 0
  echo "megavibe sessions: jq is required" >&2
  exit 1
fi

regfiles=(); launchfiles=()
for f in "$REG"/*.json; do
  [ -f "$f" ] || continue
  pid=$(basename "$f" .json)
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  kill -0 "$pid" 2>/dev/null || continue
  regfiles+=("$f")
  if [ -f "$LAUNCHES/$pid.json" ]; then launchfiles+=("$LAUNCHES/$pid.json"); fi
done

if [ "${#regfiles[@]}" -eq 0 ]; then
  [ "$mode" = list ] && echo "no live Claude sessions"
  exit 0
fi

launches='{}'
if [ "${#launchfiles[@]}" -gt 0 ]; then
  launches=$(jq -s 'map(select(type == "object" and (.pid | type) == "number" and (.startedAt | type) == "number") | {key: (.pid | tostring), value: .}) | from_entries' "${launchfiles[@]}" 2>/dev/null) || launches='{}'
fi

out=$(jq -s -r --argjson L "$launches" --arg home "$HOME" --argjson now "$(date +%s)" --arg mode "$mode" '
  def clean: tostring | gsub("[^A-Za-z0-9._ -]"; "?") | .[0:40];
  def path: tostring | sub("^" + $home; "~") | gsub("[^A-Za-z0-9._/~ -]"; "?") | .[0:60];
  def age: ($now - (. / 1000 | floor)) as $s
    | if $s < 60 then "\($s)s" elif $s < 3600 then "\($s / 60 | floor)m" elif $s < 86400 then "\($s / 3600 | floor)h" else "\($s / 86400 | floor)d" end;
  [ .[] | select(type == "object" and (.pid | type) == "number" and (.sessionId | type) == "string")
    | . as $s
    | ($L[($s.pid | tostring)]) as $r
    | (($r != null) and (($s.startedAt | type) == "number") and ((($r.startedAt * 1000) - $s.startedAt) | fabs) < 300000) as $m
    | { pid: $s.pid, id: $s.sessionId, name: ($s.name // "?" | clean), state: ($s.status // "?" | clean),
        started: (if ($s.startedAt | type) == "number" then $s.startedAt else 0 end), dir: ($s.cwd // "" | path),
        by: (if $m then "megavibe" else "-" end),
        parent: (if $m and (($r.parentSessionId | type) == "string") then $r.parentSessionId else null end) } ]
  | . as $base | ($base | map(.id)) as $ids
  | map(. + {orphan: (.parent as $p | $p != null and (($ids | index($p)) == null))}) as $rows
  | ($rows | map(select(.orphan))) as $orph
  | def line($d): (("  " * $d) + (if $d > 0 then "└ " else "" end) + .name) + "\t\(.pid)\t\(.state)\t\(.started | age)\t\(.by)\t\(.dir)"
      + (if .orphan then "\tORPHAN: started by \(.parent[0:8]), which has ended" else "" end);
    def tree($d): . as $n | line($d),
      (if $d < 5 then ($rows | map(select(.parent == $n.id)) | sort_by(.started) | .[] | tree($d + 1)) else empty end);
    if $mode == "status" then
      (if ($orph | length) == 0 then empty
       else "\($orph | length) running session(s) were started by a session that has ended: " + ($orph | map("\(.name) (pid \(.pid), \(.dir))") | join("; ")) + ". Tell the user; do not stop them yourself."
       end)
    elif $mode == "orphans" then
      (if ($orph | length) == 0 then "no orphaned sessions" else ($orph[] | "\(.name)\t\(.pid)\t\(.dir)\tstarted by \(.parent[0:8]), which has ended") end)
    else
      "NAME\tPID\tSTATE\tAGE\tSTARTED BY\tDIR",
      ($rows | map(select(.parent == null or .orphan)) | sort_by(.started) | .[] | tree(0))
    end
' "${regfiles[@]}" 2>/dev/null) || out=""

if [ "$mode" = status ]; then
  [ -n "$out" ] && printf '%s\n' "$out"
  exit 0
fi
if command -v column >/dev/null 2>&1; then
  printf '%s\n' "$out" | column -t -s "$(printf '\t')"
else
  printf '%s\n' "$out"
fi
