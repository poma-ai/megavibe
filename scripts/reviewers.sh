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
# Unset, empty, or `auto` = every reviewer that is actually available. That is
# the default and nobody has to configure anything. To pin the set, list only
# what you want:
#
#   MEGAVIBE_REVIEWERS="reviewer gemini"     # codex is never asked to review
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
#   <project>/.claude/settings.json        one project (wins over the user file)
#   <project>/.claude/settings.local.json  one project, uncommitted (wins over both)
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

# Assigns the globals RAW_VALUE and RAW_SRC rather than printing: a command
# substitution runs in a subshell, so a printed value comes back but the
# provenance does not.
#
# Precedence mirrors Claude Code's own: an exported var (a one-run override, or
# whatever the session already applied) beats project settings, which beat the
# user file.
_raw_value() {
  RAW_VALUE=""; RAW_SRC="default"; RAW_AMBIGUOUS=0
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
      return 0
    fi
  done

  if [ "$have_jq" = 0 ] && [ -n "$seen_file" ]; then
    echo "reviewers.sh: jq is not installed — cannot read MEGAVIBE_REVIEWERS from $seen_file; using all reviewers" >&2
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

  case "$(printf '%s' "$normalized" | tr -d '[:space:]')" in
    ''|auto|all|default) printf '%s\n' $KNOWN; return 0 ;;
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
  printf '%s\n' $out
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
  source)
    # resolve() is what populates RAW_SRC, so it has to run first.
    resolve >/dev/null
    printf '%s\n' "$RAW_SRC"
    ;;
  -h|--help)
    sed -n '2,55p' "$0"
    ;;
  *)
    echo "usage: reviewers.sh [list|enabled <reviewer>|source]" >&2
    exit 2
    ;;
esac
