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

# Assigns the globals RAW_VALUE and RAW_SRC rather than printing: a command
# substitution runs in a subshell, so a printed value comes back but the
# provenance does not.
#
# Precedence mirrors Claude Code's own: an exported var (a one-run override, or
# whatever the session already applied) beats project settings, which beat the
# user file.
_raw_value() {
  RAW_VALUE=""; RAW_SRC="default"
  if [ -n "${MEGAVIBE_REVIEWERS:-}" ]; then
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
  # paths still word-splits, so a project under "/Users/me/my project" lost its
  # pin silently. With root empty these expand to "" and the -f test skips them.
  for f in ".claude/settings.local.json" ".claude/settings.json" \
           "${root:+$root/.claude/settings.local.json}" \
           "${root:+$root/.claude/settings.json}" \
           "$HOME/.claude/settings.json"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    [ -n "$seen_file" ] || seen_file="$f"
    [ "$have_jq" = 1 ] || continue
    v=$(jq -r '.env.MEGAVIBE_REVIEWERS // empty' "$f" 2>/dev/null || true)
    if [ -n "$v" ]; then
      RAW_VALUE="$v"; RAW_SRC="$f"
      return 0
    fi
    # A file that exists but will not parse cannot be distinguished from one
    # carrying no pin — and that difference decides whether a reviewer runs.
    # Say so rather than quietly resolving to "all".
    jq -e . "$f" >/dev/null 2>&1 || \
      echo "reviewers.sh: $f is not valid JSON — any MEGAVIBE_REVIEWERS pin in it is being ignored" >&2
  done

  if [ "$have_jq" = 0 ] && [ -n "$seen_file" ]; then
    echo "reviewers.sh: jq is not installed — cannot read MEGAVIBE_REVIEWERS from $seen_file; using all reviewers" >&2
  fi
  return 0
}

# Resolved set on stdout, one id per line. Never fails: a config this script
# cannot make sense of falls back to "everything".
resolve() {
  local normalized id out="" warned=0
  _raw_value
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

  # Only $ALWAYS survived: the value named nothing else we recognise, which is a
  # typo far more often than a deliberate "Claude only". Fail open.
  if [ "$(printf '%s' "$out" | tr -d '[:space:]')" = "$(printf '%s' "$ALWAYS" | tr -d '[:space:]')" ] \
     && ! printf '%s' " $normalized " | grep -q " reviewer \| claude "; then
    echo "reviewers.sh: MEGAVIBE_REVIEWERS named no known reviewer — falling back to all" >&2
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
    # Resolved into a variable rather than piped into grep: with `pipefail`, a
    # grep that exits on its first match can SIGPIPE the producer and turn an
    # "enabled" answer into status 141. -F because this is a name, not a
    # pattern: `enabled '.*'` must not match everything.
    active=$(resolve)
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
