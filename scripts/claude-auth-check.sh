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
# Exit 0: the login outlasts HOURS (default 12). Exit 1: it expires inside HOURS, has
# expired, or nobody is logged in. Exit 2: no credentials found, or the lifetime is
# unknown (logged in, but no usable expiry anywhere). --quiet prints
# nothing on exit 0 (for hooks and ticks that only want the warning).
#
# Source: `claude auth status` first (its loginExpiresAt is the login's own lifetime, and
# it is what Claude Code itself uses); only when that is unavailable, the macOS keychain
# entry "Claude Code-credentials", else ~/.claude/.credentials.json (Linux; on a Mac that
# file can be an old copy). A stored record can be stale: an expiry of 0 or before 2001
# is "unknown", never "expired". Nothing is printed but hours from now.
# Test seams: MEGAVIBE_CLAUDE_AUTH_STATUS=<json file> stands in for `claude auth status`
# (MEGAVIBE_CLAUDE_STATUS_TIMEOUT, default 10 s, bounds the real call);
# MEGAVIBE_CLAUDE_CREDENTIALS=<json file> reads that file instead of either stored source
# (and, without the status seam, skips `claude auth status`); MEGAVIBE_NOW pins the clock.
set -uo pipefail

HOURS=12; QUIET=0
for a in "$@"; do
  case "$a" in
    --quiet|-q) QUIET=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    ''|*[!0-9.]*|*.*.*|.) echo "claude-auth: unknown argument: $a (HOURS is a number)" >&2; exit 2 ;;
    *) HOURS="$a" ;;
  esac
done
NOW="${MEGAVIBE_NOW:-$(date +%s 2>/dev/null)}"
case "$NOW" in ''|*[!0-9]*) echo "claude-auth: cannot read the clock" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "claude-auth: jq is required" >&2; exit 2; }

json=""; src=""
ADVICE="run /login at the laptop (not possible over Remote Control), or \`claude setup-token\` for a long-lived headless token, BEFORE an unattended window"
# A long-lived token from `claude setup-token` lives in the environment and Claude Code uses
# it when set, whatever an older keychain entry or file says: not an alarm, not "unknown".
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  [ "$QUIET" = 1 ] || echo "claude-auth: long-lived token from the environment (CLAUDE_CODE_OAUTH_TOKEN); its expiry is not recorded here"; exit 0
fi
# `claude auth status`: the login's own expiry. Only hours are printed from it (it also
# carries the account's email and organisation). Bounded like the keychain call.
status=""; STATUS_TRIED=0
if [ -n "${MEGAVIBE_CLAUDE_AUTH_STATUS:-}" ]; then
  STATUS_TRIED=1
  [ -f "$MEGAVIBE_CLAUDE_AUTH_STATUS" ] && status=$(cat "$MEGAVIBE_CLAUDE_AUTH_STATUS" 2>/dev/null)
elif [ -z "${MEGAVIBE_CLAUDE_CREDENTIALS:-}" ] && command -v perl >/dev/null 2>&1; then
  CLAUDE_BIN=$(command -v claude 2>/dev/null) || CLAUDE_BIN=""
  [ -n "$CLAUDE_BIN" ] || { [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"; }
  if [ -n "$CLAUDE_BIN" ]; then
    STATUS_TRIED=1
    # Bounded: the call runs in its own process group, which is killed at the deadline, and its
    # output goes to a file, so a child that outlives it cannot hold a pipe open. Logged out,
    # the CLI prints valid JSON and exits 1: keep the output, let jq judge it.
    st_file=""
    # Killed between here and the rm below (HUP, INT, TERM), the file still goes.
    trap 'rm -f "$st_file"' EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
    st_file=$(mktemp "${TMPDIR:-/tmp}/claude-auth-status.XXXXXX" 2>/dev/null) || st_file=""
    if [ -n "$st_file" ]; then
      perl -e '
        my $t = shift; my $pid = fork; die unless defined $pid;
        if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127 }
        local $SIG{ALRM} = sub { kill "KILL", -$pid; exit 142 };
        alarm $t; waitpid($pid, 0); exit($? >> 8)' "${MEGAVIBE_CLAUDE_STATUS_TIMEOUT:-10}" \
        "$CLAUDE_BIN" auth status >"$st_file" 2>/dev/null </dev/null || true
      status=$(cat "$st_file" 2>/dev/null); rm -f "$st_file"
    fi
  fi
fi
if [ -n "$status" ]; then
  # "in <hours>" when the expiry parses, "out" when not logged in, "other" (an API key or
  # another method: the login lifetime does not apply), "" when unusable.
  read -r STATE LOGIN < <(printf '%s' "$status" | jq -r --argjson now "$NOW" '
    if type != "object" then ""
    elif .loggedIn == false then "out -"
    elif .loggedIn == true and has("authMethod") and .authMethod != "claude.ai" then "other -"
    elif .loggedIn == true then
      ((.loginExpiresAt // null)
        | if type == "number" then (if . > 100000000000 then . / 1000 else . end)
          elif type == "string" then
            ([try (sub("\\.[0-9]+"; "") | capture("^(?<t>.*?)(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))$")) catch empty] | .[0]) as $p
            | (if $p == null then null else (($p.t + "Z") | try fromdateiso8601 catch null) end) as $b
            | if $b == null then null elif $p.z == "Z" then $b
              else $b - (if $p.s == "+" then 1 else -1 end) * (($p.h | tonumber) * 3600 + ($p.m | tonumber) * 60) end
          else null end) as $e
      | if $e == null or $e < 1000000000 then "unknown -" else "in \((($e - $now) / 3600))" end
    else "" end' 2>/dev/null) || true
  case "${STATE:-}" in
    out) echo "claude-auth: not logged in (claude auth status): $ADVICE"; exit 1 ;;
    other) [ "$QUIET" = 1 ] || echo "claude-auth: not a claude.ai login (claude auth status); no login lifetime to check"; exit 0 ;;
    # Logged in, but no usable expiry: unknown. The stored record is not consulted here, because
    # a stale record is exactly what reports a working login as expired.
    unknown) echo "claude-auth: logged in (claude auth status), login lifetime unknown"; exit 2 ;;
    in)
      lmsg="claude-auth: login $(LC_NUMERIC=C printf '%.1f h' "$LOGIN") left (claude auth status)"
      if awk -v r="$LOGIN" 'BEGIN { exit !(r <= 0) }'; then echo "$lmsg -> LOGIN EXPIRED: this session fails on its next request; $ADVICE"; exit 1; fi
      if awk -v r="$LOGIN" -v h="$HOURS" 'BEGIN { exit !(r < h) }'; then echo "$lmsg -> LOGIN EXPIRES INSIDE $HOURS h: $ADVICE"; exit 1; fi
      [ "$QUIET" = 1 ] || echo "$lmsg (ok for the next $HOURS h)"
      exit 0 ;;
  esac
fi
if [ -n "${MEGAVIBE_CLAUDE_CREDENTIALS:-}" ]; then
  [ -f "$MEGAVIBE_CLAUDE_CREDENTIALS" ] && json=$(cat "$MEGAVIBE_CLAUDE_CREDENTIALS" 2>/dev/null); src="file"
else
  if [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v security >/dev/null 2>&1; then
    # Bounded: a hung keychain must not stall the SessionStart hook that calls this. perl's
    # alarm kills the child (exit 142); without perl the call runs unbounded.
    if command -v perl >/dev/null 2>&1; then
      json=$(perl -e 'alarm 5; exec @ARGV' security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null); rc=$?
      if [ "$rc" = 142 ]; then echo "claude-auth: the keychain did not answer within 5 s; login lifetime unknown"; exit 2; fi
      [ "$rc" = 0 ] && [ -n "$json" ] && src="keychain" || json=""
    else
      json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) && src="keychain"
    fi
  fi
  if [ -z "$json" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
    json=$(cat "$HOME/.claude/.credentials.json" 2>/dev/null); src="file"
  fi
fi
if [ -z "$json" ]; then
  echo "claude-auth: no Claude Code credentials found (keychain entry or ~/.claude/.credentials.json); not logged in?"
  exit 2
fi

# Hours left on each token (printed to one decimal); "n/a" when the field is missing, zero or
# implausible (before 2001: a stale record, not an expired login). A value over 1e11 is
# milliseconds (what Claude Code writes); seconds are accepted too.
read -r ACC REF HASREF < <(printf '%s' "$json" | jq -r --argjson now "$NOW" '
  def sec: if . == null or (type != "number") then null elif . > 100000000000 then . / 1000 else . end
    | if . == null or . < 1000000000 then null else . end;
  (.claudeAiOauth // {}) as $o
  | [($o.expiresAt | sec), ($o.refreshTokenExpiresAt | sec)]
  | map(if . == null then "n/a" else ((. - $now) / 3600 | tostring) end)
  | . + [if (($o.refreshToken // "") | type) == "string" and ($o.refreshToken // "") != "" then "yes" else "no" end]
  | join(" ")' 2>/dev/null) || true
if [ -z "${ACC:-}" ] || [ -z "${REF:-}" ]; then
  echo "claude-auth: credentials found but not readable as Claude Code's OAuth record ($src)"
  exit 2
fi

fmt() { case "$1" in n/a) printf 'n/a' ;; *) LC_NUMERIC=C printf '%.1f h' "$1" ;; esac; }
msg="claude-auth: access token $(fmt "$ACC"), refresh token $(fmt "$REF")"
[ "$src" = file ] && [ -z "${MEGAVIBE_CLAUDE_CREDENTIALS:-}" ] && msg="$msg (from ~/.claude/.credentials.json)"
[ "$STATUS_TRIED" = 1 ] && msg="$msg (stored record; \`claude auth status\` unavailable)"
if [ "$REF" = n/a ] && [ "${HASREF:-no}" = yes ]; then
  echo "$msg -> a refresh token is stored but its expiry is unknown; login lifetime unknown"; exit 2
fi
if [ "$REF" = n/a ] && [ "$ACC" = n/a ]; then
  echo "$msg -> login lifetime unknown: the stored record has no usable expiry and \`claude auth status\` gave none"; exit 2
fi
if [ "$REF" = n/a ]; then
  # No refresh token: a long-lived token (`claude setup-token`) or an older record. Then the
  # access token's own expiry is the lifetime: fine while it outlasts the horizon.
  if [ "$ACC" != n/a ] && awk -v a="$ACC" -v h="$HOURS" 'BEGIN { exit !(a >= h) }'; then
    [ "$QUIET" = 1 ] || echo "$msg (no refresh token recorded: a long-lived token? its own expiry is the lifetime; ok for the next $HOURS h)"; exit 0
  fi
  echo "$msg -> no refresh token recorded and the access token does not outlast $HOURS h: $ADVICE"; exit 1
fi
if awk -v r="$REF" 'BEGIN { exit !(r <= 0) }'; then
  # A record with no usable access expiry and a past refresh expiry was seen on a working login:
  # stale, not proof of expiry. A genuinely expired login also carries a real access expiry.
  if [ "$ACC" = n/a ]; then
    echo "$msg -> login lifetime unknown (the stored record looks stale)"; exit 2
  fi
  echo "$msg -> REFRESH TOKEN EXPIRED: this session fails on its next request; $ADVICE"; exit 1
fi
if awk -v r="$REF" -v h="$HOURS" 'BEGIN { exit !(r < h) }'; then
  echo "$msg -> REFRESH TOKEN EXPIRES INSIDE $HOURS h: $ADVICE"; exit 1
fi
[ "$QUIET" = 1 ] || echo "$msg (ok for the next $HOURS h)"
exit 0
