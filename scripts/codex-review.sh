#!/usr/bin/env bash
# codex-review.sh — a Codex review/second-opinion call, over `codex exec`.
#
# Why this exists: codex-cli 0.154.0 (2026-09-10) DELETED the `mcp-server`
# subcommand. `strings` on the native binary returns zero occurrences of it, so
# it is gone from compiled code, not just from help. The failure is disguised:
# codex forwards an unrecognised subcommand to the interactive CLI as a prompt,
# the TUI launches, dies with "stdin is not a terminal", and Claude Code reports
# CONNECTION_CLOSED — which reads like a network fault, not a removed feature.
# `codex exec` is unaffected and non-interactive, so that is the transport now.
#
# Deliberately mirrors gemini-review.sh's interface so both reviewers of
# non-negotiable 4 are called the same way and neither is the awkward one.
#
# Usage:
#   scripts/codex-review.sh [--model M] [--timeout N]
#                           [--out FILE] --prompt "text" FILE...
#   scripts/codex-review.sh ... --prompt-file PROMPT.md FILE...
#
# Files are appended to the prompt as "===== path =====" blocks, same as
# gemini-review.sh. The model's answer goes to stdout; --out also writes it to
# FILE. Exit 0 on an answer, 124 on timeout, 2 on a usage error, 1 on error.
#
# SANDBOX: always read-only, and the escape hatches
# (--dangerously-bypass-approvals-and-sandbox, --approve-for-me) are refused
# outright rather than passed through. This is where that enforcement now lives:
# codex-approval-never.sh used to force read-only on every mcp__codex__codex
# call, and it can no longer fire because the tool it guarded does not exist.
# A reviewer does not need write access to review.
#
# `exec` has no approval prompt at all, so the old approval-policy=never is
# implicit — there is no interactive approver to say yes.

set -euo pipefail

MODEL=""; TIMEOUT=300; OUT=""; PROMPT=""; PROMPT_FILE=""
# read-only is not a default, it is the contract. There is deliberately no
# flag to raise it: a caller-supplied sandbox is how the previous version of
# this guarantee was lost.
readonly SANDBOX="read-only"
FILES=()
need(){ [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --model)       need "$@"; MODEL="$2"; shift 2 ;;
    --timeout)     need "$@"; TIMEOUT="$2"; shift 2 ;;
    --out)         need "$@"; OUT="$2"; shift 2 ;;
    --prompt)      need "$@"; PROMPT="$2"; shift 2 ;;
    --prompt-file) need "$@"; PROMPT_FILE="$2"; shift 2 ;;
    # Refused, not forwarded: a review that can write is not a review.
    --sandbox|--dangerously-bypass-approvals-and-sandbox|--approve-for-me|--full-auto)
      echo "error: $1 is not available here — this reviewer is read-only by contract" >&2; exit 2 ;;
    -h|--help)     sed -n '2,32p' "$0"; exit 0 ;;
    --)            shift; FILES+=("$@"); break ;;
    -*)            echo "unknown arg: $1" >&2; exit 2 ;;
    *)             FILES+=("$1"); shift ;;
  esac
done

# Zero would CANCEL perl's alarm, silently turning the timeout contract off.
case "$TIMEOUT" in ''|*[!0-9]*) echo "error: --timeout must be a number" >&2; exit 2 ;; esac
[ "$TIMEOUT" -gt 0 ] || { echo "error: --timeout must be greater than 0 (0 disables the alarm)" >&2; exit 2; }

command -v codex &>/dev/null || { echo "error: codex is not on PATH" >&2; exit 1; }
[ -n "$PROMPT" ] || [ -n "$PROMPT_FILE" ] || { echo "error: --prompt or --prompt-file is required" >&2; exit 2; }
[ -n "$PROMPT_FILE" ] && PROMPT=$(cat -- "$PROMPT_FILE")
[ -n "$(printf '%s' "$PROMPT" | tr -d '[:space:]')" ] || { echo "error: the prompt is empty" >&2; exit 2; }
[ "${#FILES[@]}" -gt 0 ] || echo "note: no files given — sending the prompt alone" >&2

# The prompt goes in via STDIN, not argv: a review of several files is far past
# any safe argv length, and `codex exec -` reads instructions from stdin.
REQ=$(mktemp -t codex-req)
ANS=$(mktemp -t codex-ans)
trap 'rm -f "$REQ" "$REQ.err" "$ANS"' EXIT
{
  printf '%s\n' "$PROMPT"
  for f in ${FILES[@]+"${FILES[@]}"}; do
    [ -f "$f" ] && [ -r "$f" ] || { echo "error: not a readable file: $f" >&2; exit 1; }
    printf '\n\n===== %s =====\n' "$f"; cat -- "$f"
  done
} > "$REQ"

# --skip-git-repo-check: reviews run against arbitrary paths, including temp
# dirs that are not repos. -o writes ONLY the final message, so the answer never
# has to be scraped out of the run's progress chrome.
ARGS=(exec --sandbox "$SANDBOX" --skip-git-repo-check --color never -o "$ANS")
[ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
ARGS+=(-)

# macOS has no timeout(1) and no gtimeout without coreutils, so this is perl.
# A reviewer that hangs is worse than one that fails: the caller is blocked on
# it, and the megavibe rule is to fall through the chain rather than wait.
#
# NOT the one-line `alarm shift; exec @ARGV` form. SIGALRM does survive the
# exec, but it then reaches only the process that replaced perl — measured: a
# 3s timeout returned 124 and left a live `codex exec` behind, which is exactly
# the orphan process-discipline.md forbids. So: fork, put the child in its own
# process GROUP, and on timeout signal the whole group (TERM, then KILL) so
# codex's own children die with it.
set +e
perl -e '
  my $t = shift;
  my $pid = fork();
  die "fork: $!" unless defined $pid;
  if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 127; }
  setpgrp($pid, $pid);   # race-free: whichever call lands first wins
  $SIG{ALRM} = sub {
    kill("TERM", -$pid);
    select(undef, undef, undef, 2);
    kill("KILL", -$pid);
    exit 124;
  };
  alarm $t;
  waitpid($pid, 0);
  my $st = $?;
  alarm 0;               # close the reaped-child / PID-reuse window
  exit(128 + ($st & 127)) if ($st & 127);
  exit($st >> 8);
' "$TIMEOUT" codex "${ARGS[@]}" < "$REQ" >/dev/null 2>"$REQ.err"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  # 142 = SIGALRM (128+14); perl's alarm kills the exec'd process that way.
  if [ "$RC" -eq 142 ] || [ "$RC" -eq 124 ]; then
    echo "error: codex timed out after ${TIMEOUT}s — fall through to the next backend, do not retry" >&2
    exit 124
  fi
  echo "error: codex exec failed (rc=$RC): $(tail -3 "$REQ.err" 2>/dev/null | tr '\n' ' ' | cut -c1-300)" >&2
  rm -f "$REQ.err"
  exit 1
fi
rm -f "$REQ.err"

[ -s "$ANS" ] || { echo "error: codex returned no answer" >&2; exit 1; }
[ -n "$OUT" ] && cp "$ANS" "$OUT"
cat "$ANS"
echo "" >&2
echo "[codex-review: sandbox=$SANDBOX${MODEL:+ model=$MODEL} timeout=${TIMEOUT}s]" >&2
