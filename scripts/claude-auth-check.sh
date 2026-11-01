#!/usr/bin/env bash
# claude-auth-check.sh — how long the Claude Code login lasts, for unattended runs.
#
#   claude-auth-check.sh [HOURS] [--quiet]
#
# One line, no secrets: the hours left on the access token and on the refresh token.
# The access token is short-lived (about 8 h) and Claude Code renews it on its own
# while the refresh token is valid, so a low access figure is normal. The refresh
# token (weeks) is the one that matters: when it lapses, every request fails with
# "Login expired", running subagents die, and /login is not available over Remote
# Control, so an unattended window ends with nobody to log in. Measured once
# (2026-10-31): a login that expired at 20:40 killed a fix agent mid-edit and left
# twenty scheduled ticks unprocessed until the laptop was opened the next morning.
#
# Exit 0: the refresh token outlasts HOURS (default 12). Exit 1: it expires inside
# HOURS, or is missing, or has expired. Exit 2: no credentials found. --quiet prints
# nothing on exit 0 (for hooks and ticks that only want the warning).
#
# Source: the macOS keychain entry "Claude Code-credentials" (what Claude Code writes
# on a Mac), else ~/.claude/.credentials.json (Linux; on a Mac that file can be an
# old copy, so the keychain wins when it exists). Nothing is printed from either but
# the two expiry times, as hours from now.
# Test seams: MEGAVIBE_CLAUDE_CREDENTIALS=<json file> reads that file instead of
# either source; MEGAVIBE_NOW pins the clock (epoch seconds).
set -uo pipefail

HOURS=12; QUIET=0
for a in "$@"; do
  case "$a" in
    --quiet|-q) QUIET=1 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    ''|*[!0-9.]*) echo "claude-auth: unknown argument: $a" >&2; exit 2 ;;
    *) HOURS="$a" ;;
  esac
done
NOW="${MEGAVIBE_NOW:-$(date +%s 2>/dev/null)}"
case "$NOW" in ''|*[!0-9]*) echo "claude-auth: cannot read the clock" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "claude-auth: jq is required" >&2; exit 2; }

json=""; src=""
if [ -n "${MEGAVIBE_CLAUDE_CREDENTIALS:-}" ]; then
  [ -f "$MEGAVIBE_CLAUDE_CREDENTIALS" ] && json=$(cat "$MEGAVIBE_CLAUDE_CREDENTIALS" 2>/dev/null); src="file"
else
  if [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v security >/dev/null 2>&1; then
    json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) && src="keychain"
  fi
  if [ -z "$json" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
    json=$(cat "$HOME/.claude/.credentials.json" 2>/dev/null); src="file"
  fi
fi
if [ -z "$json" ]; then
  echo "claude-auth: no Claude Code credentials found (keychain entry or ~/.claude/.credentials.json); not logged in?"
  exit 2
fi

# Hours left on each token (printed to one decimal); "n/a" when the field is missing. A value over
# 1e11 is milliseconds (what Claude Code writes); seconds are accepted too.
read -r ACC REF < <(printf '%s' "$json" | jq -r --argjson now "$NOW" '
  def sec: if . == null or (type != "number") then null elif . > 100000000000 then . / 1000 else . end;
  (.claudeAiOauth // {}) as $o
  | [($o.expiresAt | sec), ($o.refreshTokenExpiresAt | sec)]
  | map(if . == null then "n/a" else ((. - $now) / 3600 | tostring) end)
  | join(" ")' 2>/dev/null) || true
if [ -z "${ACC:-}" ] || [ -z "${REF:-}" ]; then
  echo "claude-auth: credentials found but not readable as Claude Code's OAuth record ($src)"
  exit 2
fi

fmt() { case "$1" in n/a) printf 'n/a' ;; *) LC_NUMERIC=C printf '%.1f h' "$1" ;; esac; }
msg="claude-auth: access token $(fmt "$ACC"), refresh token $(fmt "$REF")"
[ "$src" = file ] && [ -z "${MEGAVIBE_CLAUDE_CREDENTIALS:-}" ] && msg="$msg (from ~/.claude/.credentials.json)"
ADVICE="run /login at the laptop (not possible over Remote Control), or \`claude setup-token\` for a long-lived headless token, BEFORE an unattended window"
if [ "$REF" = n/a ]; then
  echo "$msg -> no refresh token recorded: $ADVICE"; exit 1
fi
if awk -v r="$REF" 'BEGIN { exit !(r <= 0) }'; then
  echo "$msg -> REFRESH TOKEN EXPIRED: this session fails on its next request; $ADVICE"; exit 1
fi
if awk -v r="$REF" -v h="$HOURS" 'BEGIN { exit !(r < h) }'; then
  echo "$msg -> REFRESH TOKEN EXPIRES INSIDE $HOURS h: $ADVICE"; exit 1
fi
[ "$QUIET" = 1 ] || echo "$msg (ok for the next $HOURS h)"
exit 0
