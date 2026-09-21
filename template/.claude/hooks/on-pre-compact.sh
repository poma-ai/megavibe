#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="on-pre-compact.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — pre-compaction context flush reminder + grace-period stamper
# Triggered by: PreCompact (fires on BOTH auto-compact AND manual /compact)
#
# IMPORTANT: Claude does NOT get a turn between this hook and compaction.
# The systemMessage here becomes part of the compaction summary — it tells
# the post-compaction Claude whether context files were stale and what to
# run next.
#
# Strategy:
# - Read the tool-call counter to assess staleness
# - Stamp .compact-ts.$SID and .needs-rehydration.$SID so post-compact
#   log-tool-event.sh honors the grace period even on manual /compact
#   (SessionStart:compact only fires on AUTO-compaction, so on-compact.sh
#   cannot be relied on to stamp these files — PreCompact is the only
#   hook that reliably fires for both manual and automatic compactions)
# - Drop this session's read-delta cache, whose rows would otherwise claim
#   that file content survived the compaction that is about to drop it
#   (see the SID note at that block: the two hooks must agree on the name)
# - Emit a systemMessage noting what may be lost and the single required
#   post-compact action (/rehydrate) — per D79, /catchup is folded inline

# Only run if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
SID="${SID:-default}"

LOGDIR=".agent/LOGS"
COUNTER_FILE="${LOGDIR}/.tool-call-counter.${SID}"

mkdir -p "$LOGDIR" 2>/dev/null || true

# --- Stamp the grace-period cooldown and rehydration flag ---
# log-tool-event.sh reads .compact-ts.$SID to suppress both the 8-call
# stale-context nudge and the rehydrate-pending nag for TOKEN_COOLDOWN_SECS
# (default 300s). on-compact.sh ALSO stamps this on auto-compaction, but
# stamping here guarantees manual /compact also gets the grace window.
date +%s > "${LOGDIR}/.compact-ts.${SID}" 2>/dev/null || true
# Mark that rehydration is needed. on-compact.sh normally sets this too,
# but it won't fire for manual /compact — so we set it here as the floor.
touch "${LOGDIR}/.needs-rehydration.${SID}" 2>/dev/null || true

# --- Invalidate the read-delta re-Read cache ---
# read-delta.sh answers a re-Read of an unchanged file with a stub saying the
# content is "already in your context above". Compaction is exactly the event
# that makes that false: the earlier Read leaves the context window while the
# cache row survives, so the next Read of that file would hand back a stub
# pointing at content nobody has. Dropping this session's rows costs one full
# re-read and nothing else. PreCompact is the only hook that fires for both
# manual and automatic compaction, which is why it lives here.
#
# read-delta.sh sanitises the id before it reaches a filename; $SID above is
# NOT sanitised, because other per-session files written here are read back
# by log-tool-event.sh under the unsanitised name. So derive read-delta's
# form separately, and delete both spellings: the two hooks agreeing is what
# makes the invalidation work, and deleting a cache that is not there costs
# nothing while missing one costs a false stub.
RD_SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | tr -cd 'A-Za-z0-9-' | cut -c1-12)
RD_SID="${RD_SID:-default}"
for _rd_sid in "$RD_SID" "$SID"; do
  rm -f "${LOGDIR}/read-cache.${_rd_sid}.jsonl" 2>/dev/null || true
  rm -f "${LOGDIR}"/read-stub."${_rd_sid}".*.txt 2>/dev/null || true
  # ...and the pre-fix stub name, which has no agent segment for that glob
  # to match. One file per project, but it is never cleaned up otherwise.
  rm -f "${LOGDIR}/read-stub.${_rd_sid}.txt" 2>/dev/null || true
  # The once-per-session "payload shape moved" flag belongs to that cache.
  rm -f "${LOGDIR}/.read-delta-shape.${_rd_sid}" 2>/dev/null || true
done

# How stale is the context?
COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")

# Check which .agent/ files have content
FC_LINES=$(wc -l < .agent/FULL_CONTEXT.md 2>/dev/null || echo "0")
FC_LINES=$(echo "$FC_LINES" | tr -d ' ')
TASKS_LINES=$(wc -l < .agent/TASKS.md 2>/dev/null || echo "0")
TASKS_LINES=$(echo "$TASKS_LINES" | tr -d ' ')
DECISIONS_LINES=$(wc -l < .agent/DECISIONS.md 2>/dev/null || echo "0")
DECISIONS_LINES=$(echo "$DECISIONS_LINES" | tr -d ' ')
LESSONS_LINES=$(wc -l < .agent/LESSONS.md 2>/dev/null || echo "0")
LESSONS_LINES=$(echo "$LESSONS_LINES" | tr -d ' ')

# --- Register-currency check ---
# Answers a question the line counts above cannot: is TASKS §0 still ABOUT the
# state the repo is actually in? A register can be 700 lines, freshly written,
# and still describe a release that shipped two tags ago. Staleness of WRITES is
# not staleness of TRUTH; this checks the latter.
#
# Every branch here is built to stay SILENT unless it can make a true statement.
# A warning that fires unconditionally is trained away within two compactions,
# and it would land in the compaction summary — the one place post-compaction
# Claude cannot check anything against. An unverified claim delivered there is
# the exact failure non-negotiable 7 exists to prevent, so this must not be the
# thing that commits it.
_epoch_of_date() {  # YYYY-MM-DD -> epoch. GNU first, then BSD/macOS. Empty on failure.
  date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || echo ""
}
# Heading styles seen in real registers: "## 0 ", "## 0. ", "## 0: ", "## 0b. ",
# and the occasional "###". Anchored so "## 10. " can never match.
_S0_PAT='^#+[[:space:]]+0[a-z]?[.):]?[[:space:]]'
REG_WARN=""
S0_LINE=""
[ -f .agent/TASKS.md ] && S0_LINE=$(grep -m1 -E "$_S0_PAT" .agent/TASKS.md 2>/dev/null || echo "")
# GATED on the section existing. "§0 = where we stand" is one project's
# convention, documented in no other file here, and the TASKS.md init.sh seeds
# is a bare table with no §0 at all — so an ungated check warned on every
# compaction in every stock project, this repo included, with no way to silence
# it short of inventing the section.
if [ -n "$S0_LINE" ]; then
  S0_DATE=$(printf '%s' "$S0_LINE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
  if [ -n "$S0_DATE" ]; then
    T0=$(_epoch_of_date "$S0_DATE"); NOW_S=$(date +%s)
    if [ -n "$T0" ] && [ "$T0" -gt 0 ] 2>/dev/null; then
      AGE_D=$(( (NOW_S - T0) / 86400 ))
      # A §0 written on Friday should not nag on Tuesday for having been written
      # on Friday. Seven days, and overridable.
      MAX_AGE=${MEGAVIBE_REGISTER_MAX_AGE_DAYS:-7}
      case "$MAX_AGE" in ''|*[!0-9]*) MAX_AGE=7 ;; esac
      if [ "$AGE_D" -gt "$MAX_AGE" ] 2>/dev/null; then
        REG_WARN="${REG_WARN}
- TASKS.md §0 (\"where we stand\") is dated ${S0_DATE} — ${AGE_D} days old."
      fi
    fi
  else
    REG_WARN="${REG_WARN}
- TASKS.md §0 carries no date — cannot tell whether it is current."
  fi
  # Only this project's OWN repo. `git rev-parse --git-dir` succeeds from any
  # subdirectory of any repo, so a project nested in a monorepo — or under a
  # repo'd home directory — was being compared against the PARENT's tags.
  # `pwd -P`, not $PWD: git reports the PHYSICAL toplevel, and on macOS a
  # project reached through /tmp (a symlink to /private/tmp) compared a logical
  # path against a physical one, never matched, and silently disabled the tag
  # check for everyone working under a symlinked path.
  if [ "$(git rev-parse --show-toplevel 2>/dev/null || echo "")" = "$(pwd -P)" ]; then
    # --points-at, not --abbrev=0. The latter returns the nearest REACHABLE tag,
    # which on a HEAD forty commits past a release is not a tag HEAD is on at
    # all — and the message said it was. Between releases this now says nothing,
    # which is correct: an untagged HEAD is not evidence the register is stale.
    # ALL tags at HEAD, not just the first. A release commit routinely carries
    # an alias (`v1.1.0` plus `release-20260921`), and picking one at random
    # warned that a register naming the other had missed it.
    HEAD_TAGS=$(git tag --points-at HEAD 2>/dev/null || echo "")
    if [ -n "$HEAD_TAGS" ]; then
      # Bounded at the next heading of ANY level. `^## [1-9]` let an unnumbered
      # "## Backlog" fall through, so §0 ran to EOF and a current tag mentioned
      # anywhere below it hid a real mismatch. `|| echo ""` because this
      # assignment is NOT inside a conditional and the file can vanish between
      # the -f test and here: an unguarded non-zero hits this hook's ERR trap,
      # which exits 0 having emitted no compaction message at all.
      # The heading is PART of the section: "## 0. Running v1.1.0 — 2026-09-21"
      # names the current tag in the heading itself, and skipping that line
      # reported the register as never mentioning it.
      S0_BODY=$(awk -v pat="$_S0_PAT" '
        f && /^#+[[:space:]]/ { exit }
        $0 ~ pat && !f { f=1 }
        f { print }
      ' .agent/TASKS.md 2>/dev/null || echo "")
      # Whole tokens, not substrings: `grep -qF v1.1.0` also matches v1.1.01.
      # Dots and dashes stay in the token because tags contain them, so the
      # trailing sentence period has to come off afterwards — otherwise
      # "Running v1.0.0." yields the token `v1.0.0.` and never matches the tag.
      # `/` and `+` are legal in tag names (release/v1.1.0, v1.0.0+build.3) and
      # splitting on them reported an explicitly named tag as absent.
      S0_TOKENS=$(printf '%s' "$S0_BODY" | tr -cs 'A-Za-z0-9._/+-' '\n' \
                  | sed 's/^[._-]*//; s/[._-]*$//' || echo "")
      # Which of THIS repo's tags §0 actually names. A semver regex reported
      # "(no version at all)" for a register that plainly named bake-18.
      NAMED=$(git tag 2>/dev/null | grep -xF -f <(printf '%s\n' "$S0_TOKENS") 2>/dev/null | sort -u | tr '\n' ' ' || echo "")
      # Naming ANY tag HEAD carries is enough. Tag names cannot contain spaces,
      # so word-splitting HEAD_TAGS here is safe.
      HEAD_NAMED=0
      for _t in $HEAD_TAGS; do
        if printf '%s\n' "$S0_TOKENS" | grep -qxF -- "$_t"; then HEAD_NAMED=1; break; fi
      done
      # Silent when §0 names no tag at all: a register that does not track
      # releases is not thereby stale, and this check cannot tell the difference.
      if [ -n "$NAMED" ] && [ "$HEAD_NAMED" = 0 ]; then
        REG_WARN="${REG_WARN}
- TASKS.md §0 names no tag that HEAD carries. HEAD: $(printf '%s' "$HEAD_TAGS" | tr '\n' ' ' | sed 's/ *$//'). §0 names: ${NAMED}"
      fi
    fi
  fi
fi


MSG="📋 COMPACTION IS ABOUT TO HAPPEN — CONTEXT FILE STATUS:
- FULL_CONTEXT.md: ${FC_LINES} lines
- TASKS.md: ${TASKS_LINES} lines
- DECISIONS.md: ${DECISIONS_LINES} lines
- LESSONS.md: ${LESSONS_LINES} lines
- Tool calls since last .agent/ write: ${COUNT}

⚠️ If ${COUNT} is high, context accumulated in this conversation may NOT be in the .agent/ files yet. The post-compaction recovery will only have what's on disk.

After compaction, your only required action is: run /rehydrate (single command — it regenerates WORKING_CONTEXT.md via Codex, the Claude subagent, then Gemini). A 5-minute post-compact grace period suppresses stale-context nags while /rehydrate runs, so you won't get double-yelled-at during recovery. On auto-compactions the on-compact hook will additionally inline git state + DECISIONS/TASKS/LESSONS in its systemMessage — on manual /compact that orientation lives in this compaction summary instead."


# Fold the register-currency warning into the compaction summary. This is the
# one part of the message that can contradict the reassuring line counts above,
# so it goes in the summary itself, not only to stderr.
if [ -n "$REG_WARN" ]; then
  MSG="$MSG

🕗 REGISTER CURRENCY — the records may describe a state the repo has left:${REG_WARN}

These files are what post-compaction recovery reads FIRST, and the line counts above say nothing about whether they are still TRUE. Before repeating anything from TASKS §0 or BUGS as current, re-read them against git (tags, recent commits). Treat a stale §0 as the first thing to fix after /rehydrate."
fi

# --- Optional /prune-context hint (appended only if FULL_CONTEXT.md is large) ---
# Distinct from /compact: /prune-context trims redundant lines from the
# durable .agent/FULL_CONTEXT.md log. Keeps future rehydrations focused.
PRUNE_THRESHOLD=500
if [ "$FC_LINES" -gt "$PRUNE_THRESHOLD" ] 2>/dev/null; then
  MSG="$MSG

🧹 FULL_CONTEXT.md is ${FC_LINES} lines (above the ${PRUNE_THRESHOLD}-line pruning threshold). After /rehydrate, consider running /prune-context to let Codex (or the chain behind it) selectively remove redundant or superseded entries. This is distinct from /compact: /compact summarizes the live conversation, /prune-context cleans the durable .agent/FULL_CONTEXT.md log."
fi

# --- User-visible alert ---
# The systemMessage below is folded into the compaction summary, so the user
# never sees it as a standalone turn. To prove the hook ran, we ALSO:
#   1. Write a durable alert file the user can tail/grep
#   2. Echo the report to stderr (Claude Code surfaces hook stderr to the user)
ALERT_FILE="${LOGDIR}/pre-compact-alert.${SID}.md"
{
  echo "# Pre-compact alert — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "$MSG"
} > "$ALERT_FILE" 2>/dev/null || true

# Echo to stderr — visible to the user in the Claude Code UI
echo "" >&2
echo "═══════════════════════════════════════════════════════════════" >&2
echo "$MSG" >&2
echo "" >&2
echo "(saved to $ALERT_FILE)" >&2
echo "═══════════════════════════════════════════════════════════════" >&2
echo "" >&2

jq -n --arg msg "$MSG" '{systemMessage: $msg}' 2>/dev/null || true
