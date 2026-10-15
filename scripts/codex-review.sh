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
#   scripts/codex-review.sh [--as-reviewer] [--model M] [--effort minimal|low|medium|high|xhigh]
#                           [--timeout N] [--out FILE] --prompt "text" FILE...
#   scripts/codex-review.sh ... --prompt-file PROMPT.md FILE...
#
# Files are appended to the prompt as "===== path =====" blocks, same as
# gemini-review.sh. The model's answer goes to stdout; --out also writes it to
# FILE. --model and --effort override ~/.codex/config.toml for this one call
# (effort maps to `-c model_reasoning_effort=`); unset, the config's defaults
# apply. Measured 2026-09-18 on a 60K-token rehydration: effort changes nothing
# (0-94 reasoning tokens at every level — summarising does not reason) while the
# model sets the time and the length, gpt-5.6-terra 23 s / gpt-6-astra 100 s.
# So a summary call names a small model and low effort; a review leaves both to
# the config, where the user has chosen the effort they pay for. (Until 2026-10-11 an under-used Codex week raised
# an unspecified review to xhigh. Removed: a blind benchmark found xhigh no better at twice the time, and in real use
# both auto-xhigh reviews of large PRs timed out at 900s where the config's effort answered in about 8 minutes.)
# --as-reviewer marks this call as one of non-negotiable 4's reviews, and
# is the ONLY mode MEGAVIBE_REVIEWERS gates: without it this is just megavibe's
# general Codex path (/rehydrate, research memos, second opinions), which no
# reviewer setting should be able to switch off.
#
# Exit 0 on an answer, 124 on timeout, 4 if asked to review while codex is off
# in MEGAVIBE_REVIEWERS, 2 on a usage error, 1 on error.
#
# SANDBOX. The project under review is never writable. There is no --sandbox flag
# at all: passing one is refused (exit 2), as are --approve-for-me, --full-auto and
# --dangerously-bypass-approvals-and-sandbox. This is where that enforcement lives:
# codex-approval-never.sh used to force read-only on every mcp__codex__codex
# call, and it can no longer fire because the tool it guarded does not exist.
#
# Two modes, same guarantee for the project:
#   scratch (the default under --as-reviewer; --scratch elsewhere): codex runs with
#     workspace-write in a throwaway directory it is started IN (and TMPDIR points
#     there), network off, /tmp and $TMPDIR NOT writable. The project, $HOME and
#     everything else stay read-only, even a project that happens to live under
#     /tmp. A reviewer must run the code it reviews (a reviewer that only read the
#     diff missed a P1 in every measured case), and that needs a place to write
#     harnesses; with a strictly read-only sandbox 22 of 23 reviews in one
#     2026-10-15 session reported they could not create a scratch file and
#     reviewed by reading. The prompt tells it where the project is (absolute
#     path, read-only) and where the scratch dir is; the dir is deleted on exit.
#   strict read-only (--strict, MEGAVIBE_CODEX_SCRATCH=0, and the default for the
#     non-review uses: /rehydrate, summaries, memos): nothing is writable at all.
#
# `exec` has no approval prompt at all, so the old approval-policy=never is
# implicit — there is no interactive approver to say yes.

set -euo pipefail

MODEL=""; EFFORT=""; TIMEOUT=300; OUT=""; PROMPT=""; PROMPT_FILE=""
# The project is never writable: that is the contract. There is deliberately no
# flag to raise it beyond the scratch dir: a caller-supplied sandbox is how the
# previous version of this guarantee was lost.
SCRATCH_MODE=""   # "" = decide below (reviewer: scratch, otherwise strict); 1 / 0 = forced
AS_REVIEWER=""
FILES=()
need(){ [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --as-reviewer) AS_REVIEWER=1; shift ;;
    --scratch)     SCRATCH_MODE=1; shift ;;
    --strict)      SCRATCH_MODE=0; shift ;;
    --model)       need "$@"; MODEL="$2"; shift 2 ;;
    --effort)      need "$@"; EFFORT=$(printf '%s' "$2" | tr 'A-Z' 'a-z'); shift 2 ;;
    --timeout)     need "$@"; TIMEOUT="$2"; shift 2 ;;
    --out)         need "$@"; OUT="$2"; shift 2 ;;
    --prompt)      need "$@"; PROMPT="$2"; shift 2 ;;
    --prompt-file) need "$@"; PROMPT_FILE="$2"; shift 2 ;;
    # Refused, not forwarded: a review that can write is not a review.
    --sandbox|--dangerously-bypass-approvals-and-sandbox|--approve-for-me|--full-auto)
      echo "error: $1 is not available here — the project under review is read-only by contract (use --scratch for a writable scratch dir)" >&2; exit 2 ;;
    -h|--help)     awk 'NR >= 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    --)            shift; FILES+=("$@"); break ;;
    -*)            echo "unknown arg: $1" >&2; exit 2 ;;
    *)             FILES+=("$1"); shift ;;
  esac
done

# Scratch or strict: an explicit flag wins, then MEGAVIBE_CODEX_SCRATCH, then
# the default (reviews get a scratch dir, everything else is strict).
if [ -z "$SCRATCH_MODE" ]; then
  case "${MEGAVIBE_CODEX_SCRATCH:-}" in 1) SCRATCH_MODE=1 ;; 0) SCRATCH_MODE=0 ;; *) if [ -n "$AS_REVIEWER" ]; then SCRATCH_MODE=1; else SCRATCH_MODE=0; fi ;; esac
fi
if [ "$SCRATCH_MODE" = 1 ]; then SANDBOX="workspace-write"; else SANDBOX="read-only"; fi

# Case-insensitive, and `minimal` accepted because codex accepts it. Validated
# rather than passed through: the value lands in a `-c model_reasoning_effort=`
# TOML literal.
case "$EFFORT" in ''|minimal|low|medium|high|xhigh) ;; *) echo "error: --effort must be minimal, low, medium, high or xhigh" >&2; exit 2 ;; esac

# Zero would CANCEL perl's alarm, silently turning the timeout contract off.
case "$TIMEOUT" in ''|*[!0-9]*) echo "error: --timeout must be a number" >&2; exit 2 ;; esac
[ "$TIMEOUT" -gt 0 ] || { echo "error: --timeout must be greater than 0 (0 disables the alarm)" >&2; exit 2; }
TIMEOUT=$((10#$TIMEOUT))   # "0600" is decimal 600 here, not octal

# Asked to REVIEW, and this reviewer is switched off? Refuse before spending
# anything. The gate lives here, not only in the protocol text, so an agent that
# calls a disabled reviewer out of habit gets a free no-op instead of a paid
# review the user did not want.
#
# Only under --as-reviewer. This script is also megavibe's general codex path —
# /rehydrate and /prune-context and every large-context task come through here —
# and MEGAVIBE_REVIEWERS is a statement about reviewing, not about the backend.
# Gating unconditionally would have stripped context recovery of its backend for
# anyone who switched one reviewer off.
_RVDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ -n "$AS_REVIEWER" ] && [ -f "$_RVDIR/reviewers.sh" ]; then
  _rv_rc=0; bash "$_RVDIR/reviewers.sh" enabled codex >/dev/null 2>&1 || _rv_rc=$?
  # ONLY 1 means "switched off". A helper that crashed, or one from a future
  # version with different exit codes, must not be able to silence a reviewer —
  # non-negotiable 4 fails open.
  if [ "$_rv_rc" -eq 1 ]; then
    echo "skip: codex is not in MEGAVIBE_REVIEWERS ($(bash "$_RVDIR/reviewers.sh" list 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'))" >&2
    exit 4
  fi
fi

command -v codex &>/dev/null || { echo "error: codex is not on PATH" >&2; exit 1; }
[ -n "$PROMPT" ] || [ -n "$PROMPT_FILE" ] || { echo "error: --prompt or --prompt-file is required" >&2; exit 2; }
[ -n "$PROMPT_FILE" ] && PROMPT=$(cat -- "$PROMPT_FILE")
[ -n "$(printf '%s' "$PROMPT" | tr -d '[:space:]')" ] || { echo "error: the prompt is empty" >&2; exit 2; }
[ "${#FILES[@]}" -gt 0 ] || echo "note: no files given — sending the prompt alone" >&2

# The prompt goes in via STDIN, not argv: a review of several files is far past
# any safe argv length, and `codex exec -` reads instructions from stdin.
REQ=$(mktemp -t codex-req)
ANS=$(mktemp -t codex-ans)
SCRATCH=""
if [ "$SCRATCH_MODE" = 1 ]; then
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/codex-review-scratch.XXXXXX") || { echo "error: cannot create the scratch dir" >&2; exit 1; }
  mkdir -p "$SCRATCH/tmp"
fi
trap 'rm -f "$REQ" "$REQ.err" "$ANS"; [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"' EXIT
{
  if [ -n "$SCRATCH" ]; then
    printf 'SANDBOX NOTE FROM THE HARNESS: the project under review is at %s (your own working directory is NOT the project). It is READ-ONLY for you: read it by absolute path and never try to modify it. Your writable scratch directory is %s (it is your working directory; TMPDIR is %s/tmp): copy what you need there and write and run harnesses there. There is no network, and /tmp is not writable.\n\n' "$PWD" "$SCRATCH" "$SCRATCH"
  fi
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
if [ -n "$SCRATCH" ]; then
  # workspace-write is the cwd (the scratch dir) only: /tmp and $TMPDIR excluded, network off.
  ARGS+=(-C "$SCRATCH" -c sandbox_workspace_write.network_access=false -c sandbox_workspace_write.exclude_slash_tmp=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true)
  export TMPDIR="$SCRATCH/tmp"
fi
[ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
[ -n "$EFFORT" ] && ARGS+=(-c "model_reasoning_effort=$EFFORT")
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
run_codex() {
perl -e '
  my $t = shift;
  my $pid = fork();
  die "fork: $!" unless defined $pid;
  if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 127; }
  setpgrp($pid, $pid);   # race-free: whichever call lands first wins
  my $reap = sub {
    my ($code) = @_;
    kill("TERM", -$pid);
    select(undef, undef, undef, 2);
    kill("KILL", -$pid);
    exit $code;
  };
  $SIG{ALRM} = sub { $reap->(124) };
  # The child is in its OWN process group so the alarm can signal it as a group.
  # That also means signals sent to the CALLER process group no longer reach it, so
  # they must be forwarded by hand or cancelling the caller orphans codex.
  $SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { $reap->(143) };
  alarm $t;
  waitpid($pid, 0);
  my $st = $?;
  alarm 0;               # close the reaped-child / PID-reuse window
  exit(128 + ($st & 127)) if ($st & 127);
  exit($st >> 8);
' "$1" codex "${@:2}" < "$REQ" >/dev/null 2>"$REQ.err"
}
run_codex "$TIMEOUT" "${ARGS[@]}"
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
echo "[codex-review: sandbox=$SANDBOX${SCRATCH:+ (scratch dir only; project read-only)}${MODEL:+ model=$MODEL}${EFFORT:+ effort=$EFFORT} timeout=${TIMEOUT}s]" >&2
