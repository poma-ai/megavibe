#!/usr/bin/env bash
# Print the MEGAVIBE_MEMORY_* settings a session may trust, one KEY=value per line.
#
# Claude Code applies a project's committed .claude/settings.json (and
# settings.local.json) env block to the session, over the user's own, so a cloned
# repo can point shared-memory queries at a server its author chose. The process
# env, the working directory and git state are all things that repo can steer
# (HOME, GIT_DIR, CLAUDE_PROJECT_DIR, a subfolder cwd, a case-variant path on a
# case-insensitive filesystem), so none of them is consulted. The only source is
# the user-level settings file, located through the passwd database, never through
# $HOME or any other variable. A value there is printed only when it is a plain
# token, so it cannot carry text into the model's context.
#
# Consequence: a variable exported in a shell or set in a project's own settings
# is NOT honoured. Put these in ~/.claude/settings.json (env block).
#
# An empty value means unset. A known variable found in the process env but not
# in the file prints `IGNORED KEY` (name only). No jq, no readable user settings, an unresolvable
# home: prints `UNAVAILABLE (reason)` and nothing else (feature off). Always
# exits 0.

# No -e on purpose: every path must end in exit 0 with whatever it printed.
set -uo pipefail

# Resolve the commands used here from fixed system locations and drop exported
# functions under the names this script calls, plus the startup hooks. Best
# effort only: BASH_ENV is read before line one, and a function under a builtin's
# name (set, unset, exit, [) is not covered; the README lists this as a limit.
PATH=/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin
unset BASH_ENV ENV
unset -f id jq printf eval compgen grep 2>/dev/null

command -v jq &>/dev/null || { echo "UNAVAILABLE (jq not found)"; exit 0; }

nohome() { echo "UNAVAILABLE (cannot resolve the user's home)"; exit 0; }
user=$(id -un 2>/dev/null) || nohome
case "$user" in ''|-*|*[!A-Za-z0-9._@-]*) nohome ;; esac
home=$(eval "printf '%s' ~$user" 2>/dev/null) || nohome
case "$home" in /*) ;; *) nohome ;; esac

settings="$home/.claude/settings.json"

if [ -f "$settings" ] && ! jq -e . "$settings" &>/dev/null; then
  echo "UNAVAILABLE (settings.json unreadable)"
  exit 0
fi

names=$([ -f "$settings" ] && jq -r '
  (.env // {})
  | if type == "object" then
      to_entries[]
      | select((.key | test("^MEGAVIBE_MEMORY_[A-Za-z0-9_]+$")) and (.key | contains("\n") | not))
      | .value as $v
      | select($v != null and $v != "")
      | if (($v | type) == "string" and ($v | test("^[A-Za-z0-9._:/@-]{1,100}$")) and ($v | contains("\n") | not)) then "\(.key)=\($v)" else "INVALID \(.key)" end
    else empty end
' "$settings" 2>/dev/null)
[ -z "$names" ] || printf '%s\n' "$names"
present=$([ -f "$settings" ] && jq -r '(.env // {}) | if type == "object" then keys[] else empty end' "$settings" 2>/dev/null)

# Known names present in the process env but absent from the user file are not
# honoured; say so by name (never by value) so the user can move them. A key the
# file has with any value, empty included, is the user's own and is not reported.
# Only the known names are checked, so a repo cannot make the script echo text
# of its choosing.
for k in MEGAVIBE_MEMORY_SERVER MEGAVIBE_MEMORY_DOCS MEGAVIBE_MEMORY_DOCS_ASK MEGAVIBE_MEMORY_GENERAL MEGAVIBE_MEMORY_COMPANY; do
  compgen -e 2>/dev/null | grep -x "$k" >/dev/null || continue
  grep -qx "$k" <<<"$present" || echo "IGNORED $k"
done
# Claude Code reads another config dir when CLAUDE_CONFIG_DIR is set, and managed
# settings can set env too; this script reads neither. A fixed notice, not the
# variable's value, so nothing repo-chosen reaches the model.
compgen -e 2>/dev/null | grep -x CLAUDE_CONFIG_DIR >/dev/null && echo "NOTE CLAUDE_CONFIG_DIR is set; only the default ~/.claude/settings.json is read"
exit 0
