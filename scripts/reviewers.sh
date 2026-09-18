#!/usr/bin/env bash
# reviewers.sh — which of non-negotiable 4's reviewers are switched on.
#
# One setting, `MEGAVIBE_REVIEWERS`, an ALLOW-LIST of reviewer ids:
#
#   reviewer   the Claude `reviewer` subagent (.claude/agents/reviewer.md)
#   gemini     ~/.megavibe/scripts/gemini-review.sh --as-reviewer
#   codex      ~/.megavibe/scripts/codex-review.sh --as-reviewer
#
# `reviewer` is ALWAYS in the resolved set and cannot be switched off. It is the
# floor non-negotiable 4 rests on: same subscription, no key, always available,
# and there is no script to gate it through anyway — a pin that removed it would
# be unenforceable and would contradict the protocol's "never skip it". The
# setting therefore decides which EXTERNAL reviewers join it. Naming `reviewer`
# in the list is accepted and harmless.
#
# Unset, empty, or `auto` = the default: `reviewer` plus `codex` when `codex
# exec` works on this machine, otherwise `reviewer` plus `gemini`. Gemini is
# then the FALLBACK reviewer: not in the set, but `gemini-review.sh
# --as-reviewer --fallback` may still run it when codex is installed and fails
# on the day (quota, outage). `reviewers.sh fallback gemini` answers whether
# that is allowed. Why gemini is not a peer any more: measured over one day's
# reviews (2026-09-18, 11 paired units), a single-call Gemini review produced
# four wrong headline findings and five SHIP verdicts on code with confirmed
# blockers, while codex — which runs the code — reproduced real findings in
# every unit. `all` names every reviewer explicitly. To pin the set, list only
# what you want:
#
#   MEGAVIBE_REVIEWERS="reviewer gemini"     # codex is never asked to review
#   MEGAVIBE_REVIEWERS="reviewer codex"      # gemini never, not even as fallback
#   MEGAVIBE_REVIEWERS="all"                 # all three, in parallel, as before
#
# It gates the REVIEWER ROLE, not the backend. gemini-review.sh and
# codex-review.sh are also megavibe's general Gemini/Codex transport — that is
# how /rehydrate and /prune-context reach them — so they consult this only when
# the caller passes --as-reviewer. Switching codex off must not cost you context
# recovery.
#
# Allow-list rather than ignore-list on purpose: what you read in the config is
# exactly what runs. An ignore-list only tells you the set indirectly — you have
# to know what is installed on this machine to know what you will get. The cost
# is that a reviewer added to megavibe later is OFF for anyone who has pinned a
# list; that is a protocol change that touches these docs anyway.
#
# Where to set it — the `env` block of a settings.json, which Claude Code
# applies to the session, so hooks and Bash calls both inherit it:
#
#   ~/.claude/settings.json                all projects
#   <project>/.claude/settings.local.json  one project, uncommitted (wins over it)
#   <project>/.claude/settings.json        one project, COMMITTED — may only ADD
#                                          a reviewer, never remove one, because
#                                          this file arrives with a clone
#
# This script also reads those files directly, so a review script invoked from a
# plain terminal (no Claude session, no exported var) honours the same setting.
#
# A value naming nothing known (`none`, `off`, `-codex`, a typo) is NOT an error
# and is NOT "no reviewers" — it falls back to all of them, with a warning on
# stderr. Reviewing with fewer eyes than the user expects is the bad direction
# to fail in, so every unclear path resolves to more review, never less.
#
# Usage:
#   reviewers.sh list            # resolved set, one id per line
#   reviewers.sh enabled <id>    # exit 0 if on, 1 if off, 2 on a usage error
#   reviewers.sh fallback <id>   # exit 0 if <id> may review as the FALLBACK
#                                # (default set only, and only gemini), 1 if not
#   reviewers.sh source          # where the setting came from, or "default"
#
# `megavibe reviewers` is the friendly front end for all of this.

set -euo pipefail
# Globbing OFF. The word splitting below is deliberate; pathname expansion is
# not — MEGAVIBE_REVIEWERS="*" would otherwise iterate the current directory.
set -f

KNOWN="reviewer gemini codex"
# Cannot be switched off — see the header.
ALWAYS="reviewer"
# Set by _raw_value, reported by `source`. A wrong reviewer set is confusing
# precisely because four different files can supply it.
RAW_VALUE=""
RAW_SRC="default"
# Set when a candidate file exists but cannot be trusted to answer. Resolution
# then stops and returns EVERY reviewer: an unparseable higher-precedence file
# used to fall through to whatever a lower-precedence one said, so a missing
# brace in the local override silently handed the session a restrictive pin the
# user had already replaced.
RAW_AMBIGUOUS=0
# Set when the value came from a project-scope settings.json — a file that
# arrives WITH a clone. See the "shareable" note in resolve().
RAW_SHAREABLE=0
# True when the configured value selects the DEFAULT set (unset, empty, auto,
# default) — the only mode that has a fallback reviewer. Deliberately NOT a
# flag set inside resolve(): the callers read resolve through `$(...)`, which
# is a subshell, so an assignment made in there never reaches the caller. Same
# trap _raw_value documents. This asks the question directly instead.
_is_default_set() {
  _effective_raw
  [ "$RAW_AMBIGUOUS" = 0 ] || return 1
  [ "$(_classify "$RAW_VALUE")" = "default" ]
}

# _raw_value, but with a committed project settings.json that _guard_shareable
# would REJECT already discarded — so policy questions see the same
# configuration that membership does.
#
# Without this the two disagreed: `list` correctly ignored a committed
# `"reviewer"` pin and returned the user's default set, while `fallback gemini`
# still read that rejected pin, called it an explicit list, and answered "no".
# A cloned repo could not remove a reviewer but could still switch off the
# fallback that covers one — the same hole one level down.
#
# How it tells "rejected" from "honoured" without duplicating the set builder:
# a committed file that ADDS changes the resolved set away from the baseline,
# and one that is rejected leaves the resolved set EQUAL to the baseline. So an
# equal result means the committed value is not what is in force.
_effective_raw() {
  _raw_value
  [ "$RAW_AMBIGUOUS" = 0 ] || return 0
  [ "$RAW_SHAREABLE" = 1 ] || return 0

  local full base
  full=$(resolve 2>/dev/null)
  SKIP_SHAREABLE=1; base=$(resolve 2>/dev/null); SKIP_SHAREABLE=0
  if [ "$full" = "$base" ]; then
    SKIP_SHAREABLE=1; _raw_value; SKIP_SHAREABLE=0
  fi
  return 0
}

# ONE normalization, used by everything. `list` and `fallback` each had their
# own, and they disagreed: "auto," was the default set to one and a pin to the
# other, so a trailing comma silently removed gemini's fallback. Commas and
# semicolons are separators everywhere else in this file, so they are stripped
# here too.
_normalize() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr ',;' '  '
}

# default | all | list — what the configured value asks for.
_classify() {
  case "$(_normalize "$1" | tr -d '[:space:]')" in
    ''|auto|default) printf 'default\n' ;;
    all)             printf 'all\n' ;;
    *)               printf 'list\n' ;;
  esac
}

# The default set. Codex when it works here, otherwise gemini. `codex exec
# --help` is asserted, not `command -v codex`: an installed binary whose
# subcommand was removed is not a reviewer (see codex-review.sh).
#
# BOUNDED, and on a timeout it resolves to gemini as well as codex. This probe
# sits in front of every review, ahead of the review wrapper's own timeout, so
# an installed-but-wedged codex would otherwise hang the gate with no deadline
# at all. A probe that cannot answer is uncertainty, and uncertainty resolves
# to MORE review — same direction as every other unclear path here.
#
# The fork/setpgrp/group-kill shape is deliberate (codex-review.sh has the
# long version): a bare `alarm; exec` signals only the replacement process and
# leaves its children alive.
_codex_ok() {
  command -v codex >/dev/null 2>&1 || return 1

  local _rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 codex exec --help >/dev/null 2>&1 || _rc=$?
    [ "$_rc" = 124 ] && return 2
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 5 codex exec --help >/dev/null 2>&1 || _rc=$?
    [ "$_rc" = 124 ] && return 2
  elif command -v perl >/dev/null 2>&1; then
    # Signals are forwarded as well as the alarm handled. Without the INT/TERM/
    # HUP handlers, cancelling the caller left the probe's codex child alive in
    # the process group this deliberately put it in — the exact orphan
    # process-discipline.md forbids, and the reason codex-review.sh carries the
    # same three handlers.
    perl -e '
      my $pid = fork(); exit(2) unless defined $pid;
      if ($pid == 0) { setpgrp(0,0); open(STDOUT,">","/dev/null"); open(STDERR,">","/dev/null");
                       exec(@ARGV); exit(127); }
      setpgrp($pid,$pid);
      my $reap = sub { my ($c) = @_; kill("TERM",-$pid); select(undef,undef,undef,0.5);
                       kill("KILL",-$pid); exit($c) };
      $SIG{ALRM} = sub { $reap->(2) };
      $SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { $reap->(2) };
      alarm 5; waitpid($pid,0); my $st = $?; alarm 0;
      exit($st == 0 ? 0 : 1);
    ' codex exec --help || _rc=$?
  else
    # Nothing here can bound the call. Running it unbounded would put an
    # untimed probe in front of every review — the defect this whole function
    # exists to remove — so the answer is "unknown", which costs one extra
    # reviewer and never a hang.
    return 2
  fi

  case "$_rc" in
    0) return 0 ;;   # works
    1) return 1 ;;   # answered, but not usable
    *) return 2 ;;   # timed out, or could not be run — unknown
  esac
}

_default_set() {
  _codex_ok
  case $? in
    0) printf '%s\n' reviewer codex ;;
    1) printf '%s\n' reviewer gemini ;;
    *) printf '%s\n' $KNOWN ;;   # unknown → more review, never less
  esac
}

# Assigns the globals RAW_VALUE and RAW_SRC rather than printing: a command
# substitution runs in a subshell, so a printed value comes back but the
# provenance does not.
#
# Precedence mirrors Claude Code's own: an exported var (a one-run override, or
# whatever the session already applied) beats project settings, which beat the
# user file.
# SKIP_SHAREABLE=1 makes it ignore a project's COMMITTED settings.json. That
# is how resolve() works out what the user would have had WITHOUT the file that
# arrived with the clone, which is the only baseline a "may only add" rule can
# be checked against.
SKIP_SHAREABLE=0
_raw_value() {
  RAW_VALUE=""; RAW_SRC="default"; RAW_AMBIGUOUS=0; RAW_SHAREABLE=0
  # Set-but-EMPTY is a deliberate "use the default", exactly as the header
  # says, and stops the search. Testing -n instead let MEGAVIBE_REVIEWERS=""
  # fall through to a file pin, so the documented way to clear the setting for
  # one run did the opposite of clearing it.
  if [ -n "${MEGAVIBE_REVIEWERS+x}" ]; then
    RAW_VALUE="$MEGAVIBE_REVIEWERS"; RAW_SRC="environment (MEGAVIBE_REVIEWERS)"
    return 0
  fi

  # The project root as well as the cwd. `megavibe reviewers set --project`
  # writes at the root, and a shell sitting in a subdirectory would otherwise
  # not see the file it just wrote.
  local f v root="" have_jq=1 seen_file=""
  root="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  command -v jq >/dev/null 2>&1 || have_jq=0

  # Each candidate quoted on its own: an unquoted ${root:+...} carrying two
  # paths still word-splits, so a project under "$HOME/my project" lost its
  # pin silently. With root empty these expand to "" and the -f test skips them.
  for f in ".claude/settings.local.json" ".claude/settings.json" \
           "${root:+$root/.claude/settings.local.json}" \
           "${root:+$root/.claude/settings.json}" \
           "$HOME/.claude/settings.json"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    [ -n "$seen_file" ] || seen_file="$f"
    [ "$have_jq" = 1 ] || continue
    # Parse check FIRST, and it stops the search. A file that exists but will
    # not parse cannot be distinguished from one carrying no pin, and that
    # difference decides whether a reviewer runs — so it is ambiguous, not
    # absent, and ambiguous resolves to every reviewer.
    if ! jq -e . "$f" >/dev/null 2>&1; then
      echo "reviewers.sh: $f is not valid JSON — cannot tell what it pins, using every reviewer" >&2
      RAW_AMBIGUOUS=1; RAW_SRC="$f (not valid JSON)"
      return 0
    fi
    v=$(jq -r '.env.MEGAVIBE_REVIEWERS // empty' "$f" 2>/dev/null || true)
    if [ -n "$v" ]; then
      RAW_VALUE="$v"; RAW_SRC="$f"
      # A project-scope settings.json is COMMITTED, so it can arrive with a
      # clone, written by whoever wrote the repo. settings.local.json is
      # gitignored and the $HOME file is the user's own; neither can.
      case "$f" in
        "$HOME/.claude/settings.json") ;;
        *settings.local.json) ;;
        *) RAW_SHAREABLE=1 ;;
      esac
      if [ "$RAW_SHAREABLE" = 1 ] && [ "$SKIP_SHAREABLE" = 1 ]; then
        RAW_VALUE=""; RAW_SRC="default"; RAW_SHAREABLE=0
        continue
      fi
      return 0
    fi
  done

  if [ "$have_jq" = 0 ] && [ -n "$seen_file" ]; then
    # AMBIGUOUS, not absent. A settings file exists and says something we
    # cannot read, which is exactly the "not valid JSON" case above. Leaving
    # this as an empty value used to be harmless because empty meant every
    # reviewer; now empty means the DEFAULT set, so the same path would have
    # quietly dropped a reviewer on any machine without jq.
    echo "reviewers.sh: jq is not installed — cannot read MEGAVIBE_REVIEWERS from $seen_file; using all reviewers" >&2
    RAW_AMBIGUOUS=1; RAW_SRC="$seen_file (jq unavailable)"
  fi
  return 0
}

# Resolved set on stdout, one id per line. Never fails: a config this script
# cannot make sense of falls back to "everything".
resolve() {
  local normalized id out="" warned=0 unknown=0
  _raw_value
  [ "$RAW_AMBIGUOUS" = 0 ] || { printf '%s\n' $KNOWN; return 0; }
  normalized=$(printf '%s' "$RAW_VALUE" | tr 'A-Z' 'a-z' | tr ',;' '  ')

  case "$(_classify "$RAW_VALUE")" in
    default) _guard_shareable "$(_default_set)"; return 0 ;;
    all)     _guard_shareable "$(printf '%s\n' $KNOWN)"; return 0 ;;
  esac

  out="$ALWAYS"
  for id in $normalized; do
    # `claude` is what people type for the subagent often enough to accept it.
    [ "$id" = "claude" ] && id="reviewer"
    case " $KNOWN " in
      *" $id "*) case " $out " in *" $id "*) ;; *) out="$out $id" ;; esac ;;
      *)
        # ANY unrecognised name invalidates the whole pin. Dropping just the
        # bad token and keeping the rest is the fail-CLOSED direction: a typo
        # in one name ("gemini codx") quietly removed codex from every review
        # from then on, and the surviving good token stopped the fallback
        # below from ever firing.
        unknown=1
        # Capped: a pasted 5000-word value would otherwise emit 5000 lines
        # straight into the agent transcript.
        if [ "$warned" -lt 3 ]; then
          echo "reviewers.sh: ignoring unknown reviewer '$id' (known: $KNOWN)" >&2
          warned=$((warned + 1))
        elif [ "$warned" -eq 3 ]; then
          echo "reviewers.sh: ...further unknown names suppressed" >&2
          warned=4
        fi
        ;;
    esac
  done

  if [ "$unknown" = 1 ]; then
    echo "reviewers.sh: MEGAVIBE_REVIEWERS names something I do not recognise — using every reviewer rather than guessing which one was meant" >&2
    printf '%s\n' $KNOWN
    return 0
  fi
  _guard_shareable "$out"
}

# A file that can arrive with a clone may ADD reviewers, never take them away.
# megavibe argues exactly this about the re-exec pointer — "the env block of a
# settings.json committed inside a cloned repo" is written by whoever wrote the
# repo — and then read that same file here, ahead of the user's own file, from a
# plain terminal where Claude Code trust prompts are not involved at all. A
# hostile repo could switch off the external reviewers OF ITS OWN CODE. Pin
# per-project in .claude/settings.local.json, which is gitignored and is what
# `megavibe reviewers set --project` writes.
#
# The comparison is against the BASELINE — what this machine would resolve with
# the committed file ignored — not against "all three". Comparing against all
# three was right only while the default WAS all three: the moment the default
# became two, a committed `auto` passed the check and removed the third
# reviewer from a user whose own file said `all`. Measured: it did exactly that.
_guard_shareable() {
  local candidate="$1" baseline id cand_sp
  [ "$RAW_SHAREABLE" = 1 ] || { printf '%s\n' $candidate; return 0; }

  # Recompute without the committed file. SKIP_SHAREABLE is cleared before
  # returning either way, so one guarded call cannot affect the next.
  SKIP_SHAREABLE=1
  baseline=$(resolve)
  SKIP_SHAREABLE=0

  # Space-separated, with a trailing space per word: the candidate arrives
  # newline-separated, and `printf '%s' $candidate` concatenates the words into
  # one token, so every membership test failed and the guard fired on sets that
  # removed nothing.
  cand_sp=$(printf '%s ' $candidate)
  for id in $baseline; do
    case " $cand_sp " in
      *" $id "*) ;;
      *)
        echo "reviewers.sh: $RAW_SRC is committed to the repo and would REMOVE a reviewer ($id) — ignoring it. Put a per-project pin in .claude/settings.local.json instead." >&2
        printf '%s\n' $baseline
        return 0 ;;
    esac
  done
  printf '%s\n' $candidate
}

case "${1:-list}" in
  list)
    resolve
    ;;
  enabled)
    [ $# -ge 2 ] || { echo "usage: reviewers.sh enabled <reviewer>" >&2; exit 2; }
    want=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    [ "$want" = "claude" ] && want="reviewer"
    # One known id and nothing else. grep reads a multi-line pattern as several
    # patterns, so `enabled $'gemini\ncodex'` reported success on gemini alone.
    case " $KNOWN " in
      *" $want "*) ;;
      *) echo "reviewers.sh: not a known reviewer: $2 (known: $KNOWN)" >&2; exit 2 ;;
    esac
    # Resolved into a variable rather than piped into grep: with `pipefail`, a
    # grep that exits on its first match can SIGPIPE the producer and turn an
    # "enabled" answer into status 141. -F because this is a name, not a
    # pattern: `enabled '.*'` must not match everything.
    #
    # Both guards below exit 0 — "on". Status 1 is the ONE answer that switches
    # a reviewer off, and the callers act on it, so it has to mean exactly that
    # and never "this script broke". A crashed resolve can still have printed
    # something, and `reviewer` is in every valid answer, so its absence says
    # the output is not one.
    active=$(resolve) || exit 0
    printf '%s\n' "$active" | grep -qxF -- "reviewer" || exit 0
    printf '%s\n' "$active" | grep -qxF -- "$want"
    ;;
  fallback)
    [ $# -ge 2 ] || { echo "usage: reviewers.sh fallback <reviewer>" >&2; exit 2; }
    want=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    case " $KNOWN " in
      *" $want "*) ;;
      *) echo "reviewers.sh: not a known reviewer: $2 (known: $KNOWN)" >&2; exit 2 ;;
    esac
    # Only gemini, and only when the effective configuration is the DEFAULT
    # set. A pin that names the set is exact: "reviewer codex" means gemini
    # never, not even standing in.
    #
    # Deliberately NO availability probe here. It used to re-run `_default_set`
    # and refuse when that resolution already contained gemini — which made the
    # answer depend on a second probe of codex, so a probe that succeeded for
    # `enabled` and then timed out for `fallback` turned "uncertain" into
    # "switched off" and exited 4 on the last reviewer standing. Where gemini
    # is already a peer, permitting the fallback changes nothing: it is allowed
    # to review either way. So config alone decides, and uncertainty cannot
    # subtract.
    [ "$want" = "gemini" ] || exit 1
    _is_default_set || exit 1
    exit 0
    ;;
  source)
    # resolve() is what populates RAW_SRC, so it has to run first.
    resolve >/dev/null
    printf '%s\n' "$RAW_SRC"
    ;;
  -h|--help)
    sed -n '2,55p' "$0"
    ;;
  *)
    echo "usage: reviewers.sh [list|enabled <reviewer>|fallback <reviewer>|source]" >&2
    exit 2
    ;;
esac
