#!/usr/bin/env bash
# backends.sh — which EXTERNAL backends megavibe may use for NON-REVIEW work.
#
# One setting, `MEGAVIBE_BACKENDS`, an ALLOW-LIST of backend ids:
#
#   claude   the Claude subagents and headless workers (cannot be switched off)
#   codex    codex exec (codex-review.sh without --as-reviewer, the context
#            watcher, amass --provider auto, the usage probe, second-opinion.sh)
#   gemini   gemini-review.sh without --as-reviewer (still rationed and still
#            refused while codex is usable, see delegation.md)
#
# Unset, empty or `auto` = every backend is allowed and availability decides, as
# before this setting existed. A list names exactly what may run:
#
#   MEGAVIBE_BACKENDS="claude"          # background work stays on the Claude plan
#   MEGAVIBE_BACKENDS="claude gemini"   # never codex (the watcher, digests, probe)
#
# INDEPENDENT of MEGAVIBE_REVIEWERS (reviewers.sh), which gates the reviewer role
# only. Switching codex off here does not remove it as a reviewer, and the other
# way round. A logged-out codex is not "allowed or not": `usable` also asks
# `"$CODEX_BIN" login status` (bounded, cached) so a daemon does not send a request
# every five minutes that is answered with 401.
#
# Where it is read: the exported variable, then <project>/.claude/settings.local.json,
# then ~/.claude/settings.json. This script itself never reads a COMMITTED
# <project>/.claude/settings.json (it arrives with a clone). Inside a Claude Code
# session that file's `env` block is still applied by Claude Code and then arrives
# here as the exported variable, so the guarantee is only that this script does
# not go looking for it.
#
# An unreadable settings file or a missing jq resolves to `claude` only, and an
# unknown name in a pin is dropped, each with a warning on stderr: unclear input
# narrows the set, it never widens it.
#
# Usage:
#   backends.sh list            resolved allow-list, one id per line
#   backends.sh enabled <id>    exit 0 allowed, 1 not allowed, 2 usage error
#   backends.sh usable <id>     exit 0 usable, 1 not (reason on stdout),
#                               2 could not tell (callers treat it as usable)
#   backends.sh codex-auth      exit 0 logged in, 1 not logged in, 2 unknown (bounded 10 s)
#   backends.sh pinned <id>     exit 0 when the setting is an explicit list that names <id>
#                               (not auto/unset), 1 otherwise
#   backends.sh source          where the setting came from, or "default"

set -euo pipefail
set -f

KNOWN="claude codex gemini"
CODEX_BIN="${MEGAVIBE_CODEX_BIN:-codex}"   # test seam, as in the usage probe
RAW_VALUE=""
RAW_SRC="default"
RAW_BAD=0

_raw_value() {
  RAW_VALUE=""; RAW_SRC="default"; RAW_BAD=0
  if [ -n "${MEGAVIBE_BACKENDS+x}" ]; then
    RAW_VALUE="$MEGAVIBE_BACKENDS"; RAW_SRC="environment (MEGAVIBE_BACKENDS)"
    return 0
  fi
  local f v root="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  for f in ".claude/settings.local.json" "${root:+$root/.claude/settings.local.json}" "$HOME/.claude/settings.json"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if ! command -v jq >/dev/null 2>&1; then
      echo "backends.sh: jq is not installed — cannot read MEGAVIBE_BACKENDS from $f; allowing claude only" >&2
      RAW_BAD=1; RAW_SRC="$f (jq unavailable)"; return 0
    fi
    if ! jq -e . "$f" >/dev/null 2>&1; then
      echo "backends.sh: $f is not valid JSON — cannot tell what it pins; allowing claude only" >&2
      RAW_BAD=1; RAW_SRC="$f (not valid JSON)"; return 0
    fi
    v=$(jq -r '.env.MEGAVIBE_BACKENDS // empty' "$f" 2>/dev/null || true)
    if [ -n "$v" ]; then RAW_VALUE="$v"; RAW_SRC="$f"; return 0; fi
  done
  return 0
}

resolve() {
  local n id out="claude" unknown=0
  _raw_value
  # A settings file that exists but cannot be read is ambiguous, and this setting decides where
  # subscriptions and keys are spent, so ambiguity allows claude only (with the warning above).
  [ "$RAW_BAD" = 0 ] || { printf '%s\n' claude; return 0; }
  n=$(printf '%s' "$RAW_VALUE" | tr 'A-Z' 'a-z' | tr ',;' '  ')
  case "$(printf '%s' "$n" | tr -d '[:space:]')" in
    ''|auto|default|all) printf '%s\n' $KNOWN; return 0 ;;
  esac
  for id in $n; do
    case " $KNOWN " in
      *" $id "*) case " $out " in *" $id "*) ;; *) out="$out $id" ;; esac ;;
      *) unknown=1; echo "backends.sh: unknown backend '${id:0:40}' (known: $KNOWN)" >&2 ;;
    esac
  done
  # An unknown name is dropped, never promoted to "everything": this setting
  # decides where subscriptions and keys are spent, so a typo ("codx") must
  # narrow the set (here to what was spelled right, at least claude), not widen it.
  if [ "$unknown" = 1 ]; then echo "backends.sh: ignoring the unknown name(s) above; using: $out" >&2; fi
  printf '%s\n' $out
}

_enabled() {
  local r; r=$(resolve 2>/dev/null) || true
  case " $(printf '%s' "$r" | tr '\n' ' ') " in *" $1 "*) return 0 ;; esac
  return 1
}

# Runs "$@" with stdin closed, output dropped, and a deadline. 124 = gave up.
_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@" </dev/null >/dev/null 2>&1; return $?
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@" </dev/null >/dev/null 2>&1; return $?
  elif command -v perl >/dev/null 2>&1; then
    perl -e '
      my $s = shift; my $pid = fork(); exit(125) unless defined $pid;
      if ($pid == 0) { setpgrp(0,0); open(STDIN,"<","/dev/null"); open(STDOUT,">","/dev/null"); open(STDERR,">","/dev/null"); exec(@ARGV); exit(127); }
      setpgrp($pid,$pid);
      my $reap = sub { kill("TERM",-$pid); select(undef,undef,undef,0.5); kill("KILL",-$pid); exit(124) };
      $SIG{ALRM} = $reap; $SIG{INT} = $SIG{TERM} = $SIG{HUP} = $reap;
      alarm $s; waitpid($pid,0); my $st = $?; alarm 0;
      my $c = $st >> 8; exit($st == 0 ? 0 : ($c == 1 ? 1 : 2));
    ' "$secs" "$@"; return $?
  fi
  return 124
}

_codex_auth() {
  case "${MEGAVIBE_CODEX_AUTH:-}" in 0|1|2) return "$MEGAVIBE_CODEX_AUTH" ;; esac
  command -v "$CODEX_BIN" >/dev/null 2>&1 || return 1
  # Not cached on purpose: a cached "logged in" outlived a logout (and a test run with a stub
  # codex wrote one into the real home), while the probe itself takes about 0.1 s.
  local rc=0
  _bounded 10 "$CODEX_BIN" login status || rc=$?
  case "$rc" in 0|1) return "$rc" ;; *) return 2 ;; esac
}

case "${1:-list}" in
  list) resolve ;;
  source) resolve >/dev/null; printf '%s\n' "$RAW_SRC" ;;
  enabled)
    [ $# -ge 2 ] || { echo "usage: backends.sh enabled <backend>" >&2; exit 2; }
    id=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    case " $KNOWN " in *" $id "*) ;; *) echo "backends.sh: not a known backend: $2 (known: $KNOWN)" >&2; exit 2 ;; esac
    _enabled "$id" || exit 1
    ;;
  codex-auth) rc=0; _codex_auth || rc=$?; exit "$rc" ;;
  pinned)
    [ $# -ge 2 ] || { echo "usage: backends.sh pinned <backend>" >&2; exit 2; }
    id=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    case " $KNOWN " in *" $id "*) ;; *) echo "backends.sh: not a known backend: $2 (known: $KNOWN)" >&2; exit 2 ;; esac
    resolve >/dev/null 2>&1 || true
    [ "$RAW_BAD" = 0 ] || exit 1
    case "$(printf '%s' "$RAW_VALUE" | tr 'A-Z' 'a-z' | tr ',;' '  ' | tr -d '[:space:]')" in ''|auto|default|all) exit 1 ;; esac
    _enabled "$id" || exit 1
    printf '%s' "$RAW_VALUE" | tr 'A-Z' 'a-z' | tr ',;' '  ' | tr -s ' ' '\n' | grep -qxF -- "$id" || exit 1
    ;;
  usable)
    [ $# -ge 2 ] || { echo "usage: backends.sh usable <backend>" >&2; exit 2; }
    id=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    case " $KNOWN " in *" $id "*) ;; *) echo "backends.sh: not a known backend: $2 (known: $KNOWN)" >&2; exit 2 ;; esac
    [ "$id" = claude ] && exit 0
    _enabled "$id" || { echo "$id is not in MEGAVIBE_BACKENDS"; exit 1; }
    case "$id" in
      gemini)
        k="${GEMINI_API_KEY:-}"; [ -n "${k// /}" ] || { echo "no GEMINI_API_KEY"; exit 1; }
        ;;
      codex)
        here=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
        cx=0; [ ! -f "$here/reviewers.sh" ] || bash "$here/reviewers.sh" codex-ok >/dev/null 2>&1 || cx=$?
        [ "$cx" != 1 ] || { echo "codex is not usable here (codex exec missing or broken)"; exit 1; }
        au=0; _codex_auth || au=$?
        [ "$au" != 1 ] || { echo "codex is not logged in (run: codex login)"; exit 1; }
        [ "$cx" = 0 ] && [ "$au" = 0 ] || exit 2
        ;;
    esac
    ;;
  -h|--help) sed -n '2,45p' "$0" ;;
  *) echo "usage: backends.sh [list|enabled <id>|usable <id>|pinned <id>|codex-auth|source]" >&2; exit 2 ;;
esac
