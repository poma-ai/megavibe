#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="on-pre-compact.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — pre-compaction status report + grace-period and flag stamper
# Triggered by: PreCompact (fires on BOTH auto-compact AND manual /compact)
#
# IMPORTANT: Claude does NOT get a turn between this hook and compaction, and
# Claude Code DISCARDS a PreCompact hook's systemMessage (hooks reference). This
# hook therefore reaches nobody directly: what it learns goes to stderr, to a
# timestamped alert file, and, for the register-currency warning, to a file
# on-compact.sh folds into the short message the post-compact model does see.
# (Measured 2026-10-11 over 20 compactions: the old "stamp the summary" text
# appeared in 0 of 20 summaries.)
#
# Strategy:
# - Read the tool-call counter to assess staleness
# - Stamp .compact-ts.$SID and .needs-rehydration.$SID so post-compact
#   log-tool-event.sh honors the grace period even on manual /compact
#   (SessionStart:compact is documented for both, but has not always fired
#   for a manual /compact, so on-compact.sh
#   cannot be relied on to stamp these files — PreCompact is the only
#   hook that reliably fires for both manual and automatic compactions)
# - Drop this session's read-delta cache, whose rows would otherwise claim
#   that file content survived the compaction that is about to drop it
#   (see the SID note at that block: the two hooks must agree on the name)
# - Report what may be lost and the single required
#   post-compact action (/rehydrate); the /catchup-equivalent orientation is
#   written to a file by on-compact.sh

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

# --- A SUBAGENT's compaction is not this session's ---
# Subagents share the parent's session_id, so without this guard a subagent
# compacting set the PARENT's rehydration flag, and the main thread was then
# told to "Run /rehydrate NOW" for a compaction it never had (found twice in one
# session, 2026-10-04/05, each matching a subagents/agent-*.jsonl compaction to
# the second). The hooks reference documents agent_id for hooks that fire inside
# a subagent, but not for PreCompact specifically, so both signals are checked,
# and the payload's KEYS (never its values) are logged so the next real case
# shows which one Claude Code actually sends.
_PC_KEYS=$(printf '%s' "$INPUT" | jq -c 'keys' 2>/dev/null || echo "?")
_PC_AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null || echo "")
_PC_TP=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
# Anchored on THIS session's own subagent directory (<id>/subagents/), never a
# bare "subagents" component: a config or home path can contain one, and a false
# match here silently disables the whole recovery for a real compaction.
_PC_SIDF=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
_PC_SUBPATH=no
[ -n "$_PC_SIDF" ] && case "$_PC_TP" in */"$_PC_SIDF"/subagents/agent-*.jsonl) _PC_SUBPATH=yes ;; esac
echo "$(date -u +%FT%TZ) sid=${SID} agent_id=${_PC_AGENT:+set} subagent_path=${_PC_SUBPATH} keys=${_PC_KEYS}" \
  >> "${LOGDIR}/pre-compact-inputs.log" 2>/dev/null || true
[ "$_PC_SUBPATH" = yes ] && _PC_AGENT="${_PC_AGENT:-subagent-path}"
IS_SUBAGENT=0; [ -n "$_PC_AGENT" ] && IS_SUBAGENT=1

# --- Stamp the grace-period cooldown and rehydration flag ---
# log-tool-event.sh reads .compact-ts.$SID to suppress both the 8-call
# stale-context nudge and the rehydrate-pending nag for TOKEN_COOLDOWN_SECS
# (default 300s). on-compact.sh ALSO stamps this on auto-compaction, but
# stamping here guarantees manual /compact also gets the grace window.
[ "$IS_SUBAGENT" -eq 0 ] && { date +%s > "${LOGDIR}/.compact-ts.${SID}" 2>/dev/null || true; }
# Mark that rehydration is needed. on-compact.sh normally sets this too, but
# it may not run for a manual /compact, so this is the floor.
# The nag count (log-tool-event.sh) restarts with each compaction.
# The autopilot's once-per-fill-cycle flags (rehydrate AND close-out) are re-armed here too,
# because on-compact.sh (which also does it) may not run for a manual /compact.
# Not when a non-empty WORKING_CONTEXT (full-id or legacy 12-char directory) was
# written within the hour: on-compact.sh applies the same rule, but it may not
# run for a manual /compact, and then nothing would take the flag back down.
_PC_FRESH=0
# session_id becomes a path component below: same safe-charset gate as on-compact.sh.
case "$_PC_SIDF" in ''|.|..|*[!A-Za-z0-9._-]*) _PC_SIDF="none" ;; esac
for _wc in ".agent/sessions/${_PC_SIDF:-none}/WORKING_CONTEXT.md" ".agent/sessions/${SID}/WORKING_CONTEXT.md"; do
  if [ -f "$_wc" ] && [ -s "$_wc" ]; then
    _m=$(stat -c %Y "$_wc" 2>/dev/null || stat -f %m "$_wc" 2>/dev/null || echo 0)
    case "$_m" in ''|*[!0-9]*) _m=0 ;; esac
    [ $(( $(date +%s) - _m )) -lt 3600 ] && _PC_FRESH=1
  fi
done
if [ "$IS_SUBAGENT" -eq 0 ]; then
  if [ "$_PC_FRESH" -eq 1 ]; then rm -f "${LOGDIR}/.needs-rehydration.${SID}" 2>/dev/null || true
  else echo 0 > "${LOGDIR}/.needs-rehydration.${SID}" 2>/dev/null || true; fi
  rm -f "${LOGDIR}/.rehydrate-nudge.${SID}" "${LOGDIR}/.rehydrate-blocked.${SID}" "${LOGDIR}/.rehydrate-nagcount.${SID}" \
        "${LOGDIR}/.closeout-done.${SID}" "${LOGDIR}/.closeout-blocked.${SID}" "${LOGDIR}/.closeout-count.${SID}" 2>/dev/null || true
fi

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

# A subagent's compaction still drops ITS reads (the cache invalidation above
# applies), but everything below is about the main session's recovery.
[ "$IS_SUBAGENT" -eq 1 ] && exit 0

# How stale is the context?
COUNT=$(head -c 12 "$COUNTER_FILE" 2>/dev/null | head -n 1 || true)
case "$COUNT" in ""|*[!0-9]*) COUNT=0 ;; esac   # a cache file is data: only an integer reaches the report
# The counter resets on every .agent/ write, and the context watcher writes every
# few minutes, so with the watcher alive it reads 0 every time. The age of the
# newest write is the number that still says something.
_newest=$(ls -t .agent/events/ 2>/dev/null | head -1)
LAST_WRITE_MIN="?"
if [ -n "$_newest" ]; then
  _m=$(stat -c %Y ".agent/events/$_newest" 2>/dev/null || stat -f %m ".agent/events/$_newest" 2>/dev/null || echo "")
  [ -n "$_m" ] && LAST_WRITE_MIN=$(( ($(date +%s) - _m) / 60 ))
fi

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
# state the repo is actually in? Staleness of WRITES is not staleness of TRUTH;
# this checks the latter, by age alone.
#
# It USED to also compare the releases §0 names against the tags HEAD carries.
# That was dropped after five review rounds found twelve distinct false-positive
# modes in it, the last of which are undecidable by construction: "a version
# string occurs in this text" and "this register claims that release" are the
# same bytes, so a dependency pin, a language version, another project's release
# — or the same release spelled `1.1.0` where the tag says `v1.1.0` — all read
# as the register naming the wrong thing. The output lands in the post-compact
# message, where the next session takes it on trust, so a check that
# occasionally asserts unfalsifiable staleness is worse there than no check.
# The sound version is a different design: have the register record the release
# as a machine-readable marker per non-negotiable 7 and compare THAT against
# `git tag --points-at HEAD`. Exact by construction, nothing parsed out of prose.
#
# Every branch is built to stay SILENT unless it can make a true statement. A
# warning that fires unconditionally is trained away within two compactions, and
# it lands in the post-compact message, which the next session takes on trust. An unverified claim delivered there is the exact
# failure non-negotiable 7 exists to prevent, so this must not be the thing that
# commits it. Four review rounds each found a new false positive here; the
# design rule that finally held is: when in doubt, say nothing.
_epoch_of_date() {  # YYYY-MM-DD -> epoch. GNU first, then BSD/macOS. Empty on failure.
  date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || echo ""
}
# Heading styles seen in real registers: "## 0 ", "## 0. ", "## 0: ", "## 0b. ",
# and the occasional "###". Anchored so "## 10. " can never match.
_S0_PAT='^#+[[:space:]]+0[a-z]?[.):]?[[:space:]]'
REG_WARN=""
S0_LINE=""
# GATED on the section existing. "§0 = where we stand" is one project's
# convention and the TASKS.md init.sh seeds is a bare table with no §0 at all,
# so an ungated check warned on every compaction in every stock project.
[ -f .agent/TASKS.md ] && S0_LINE=$(grep -m1 -E "$_S0_PAT" .agent/TASKS.md 2>/dev/null || echo "")
if [ -n "$S0_LINE" ]; then
  # The section, heading included, read ONCE. `|| echo ""` because this is not
  # inside a conditional and the file can vanish between the -f test and here:
  # an unguarded non-zero hits this hook's ERR trap, which exits 0 having
  # emitted no compaction message at all.
  S0_OK=1
  S0_BODY=$(awk -v pat="$_S0_PAT" '
    f && /^#+[[:space:]]/ { exit }
    $0 ~ pat && !f { f=1 }
    f { print }
  ' .agent/TASKS.md 2>/dev/null) || S0_OK=0
  # A read that FAILED is not a section that said nothing. Asserting "carries no
  # date" because awk could not open the file is the same class of unverified
  # claim this whole feature is about.
  [ -n "$S0_BODY" ] || S0_OK=0
  if [ "$S0_OK" = 1 ]; then
    # Only a date the register OFFERS as its stamp: bracketed in the heading,
    # or line-initial "As of <date>" in the body. Any other date is something
    # the register talks ABOUT — "freeze was 2026-08-01", "see INC-2026-08-01",
    # "fixed as of 2026-08-01" — and reading those as the write time reported
    # registers written today as fifty-one days old.
    S0_DATE=$(printf '%s' "$S0_LINE" \
              | grep -oE '[([][0-9]{4}-[0-9]{2}-[0-9]{2}[])]' \
              | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
    if [ -z "$S0_DATE" ]; then
      S0_DATE=$(printf '%s' "$S0_BODY" \
                | grep -iEo '^[[:space:]]*as of[[:space:]:]+[0-9]{4}-[0-9]{2}-[0-9]{2}' \
                | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
    fi
    if [ -n "$S0_DATE" ]; then
      T0=$(_epoch_of_date "$S0_DATE"); NOW_S=$(date +%s)
      if [ -n "$T0" ] && [ "$T0" -gt 0 ] 2>/dev/null; then
        AGE_D=$(( (NOW_S - T0) / 86400 ))
        # A §0 written on Friday should not nag on Tuesday for being written on
        # Friday. Seven days, overridable.
        MAX_AGE=${MEGAVIBE_REGISTER_MAX_AGE_DAYS:-7}
        case "$MAX_AGE" in ''|*[!0-9]*) MAX_AGE=7 ;; esac
        if [ "$AGE_D" -gt "$MAX_AGE" ] 2>/dev/null; then
          REG_WARN="${REG_WARN}
- TASKS.md §0 carries the date ${S0_DATE} — ${AGE_D} days ago. Confirm it still describes the repo before repeating it."
        fi
      fi
    fi
  fi
fi


# --- Deliverables register: asks that never became a file ---
# What a compaction summary keeps is decisions and paths, not "the user asked
# for X and no file exists yet" (found 2026-10-15: 8 asks in one project that
# ended only in .agent/RESEARCH or in chat). This block only COUNTS, and prints
# fixed text plus numbers: nothing from STATUS.md or from a file name ever
# reaches the message, which a model reads as instructions and which a cloned
# repo's own STATUS.md could otherwise write (a tracked file, a tracked symlink,
# a case variant on a case-insensitive filesystem all slip past a "tracked?"
# test). The model reads the table itself, as it reads any file of the repo.
# Only where the project has megavibe-deliverables/STATUS.md; the result reaches
# the post-compact message through .ask-counts.<sid> (four integers; the text is rendered there).
ASK_WARN=""
_ST="megavibe-deliverables/STATUS.md"
if [ -f "$_ST" ]; then
  _STTXT=$(head -c 524288 "$_ST" 2>/dev/null | LC_ALL=C tr -d '\r\0' || true)
  # "Now" is a status line, not the report (bytes: wc -m depends on the locale).
  _NOWB=$(printf '%s\n' "$_STTXT" | LC_ALL=C awk '/^## /{ p = (tolower($0) ~ /^## now([^a-z]|$)/); next } p' | wc -c | tr -d ' ')
  # Rows of the register table under "## Asked for": the table that starts at a
  # header line whose first cell is "Ask" and ends at the first blank or pipe-less
  # line (another table, an example in a code fence, prose do not count). Outer
  # pipes are optional, up to 3 leading blanks are allowed. Columns Ask | Date |
  # File | Mirror | State; markup (* _ backticks, [text](link)) is removed from the
  # state, a file keeps its own characters (wrapping markup only is also tried);
  # a row with fewer than 5 columns counts as open. One row per line, delimited
  # by the unit separator: class, file, file without wrapping markup.
  _ROWS=$(printf '%s\n' "$_STTXT" | LC_ALL=C awk '
    # BSD awk is quadratic on /[ \t]+$/ over a long run of blanks: collapse runs first (linear), then drop one blank at each end
    function trim(x) { gsub(/[ \t]+/, " ", x); sub(/^ /, "", x); sub(/ $/, "", x); return x }
    function plain(x) { x = trim(x); gsub(/[*_`]/, "", x); if (x ~ /^\[[^]]*\]\([^)]*\)$/) { sub(/^\[/, "", x); sub(/\].*$/, "", x) } return trim(x) }
    function fenceinfo(x,   t, c, n) { t = x; sub(/^[ \t]*/, "", t); c = substr(t, 1, 1); if (c != "`" && c != "~") return 0; n = 0; while (substr(t, n + 1, 1) == c) n++; if (n < 3) return 0; fch = c; fln = n; frest = substr(t, n + 1); return 1 }
    length($0) > 2000 { if (t && intab && !fence && !inc) nopen++; next }   # no real line is this long; BSD awk is quadratic on long runs, so no other rule may see it
    fence { if (fenceinfo($0) && fch == ofch && fln >= oln && frest ~ /^[ \t]*$/) fence = 0; next }
    inc { if ($0 ~ /-->/) inc = 0; next }
    /^[ \t]*<!--/ { if ($0 !~ /-->/) inc = 1; next }
    fenceinfo($0) { fence = 1; ofch = fch; oln = fln; intab = 0; next }   # a fence ends the table
    /^## / { t = (tolower($0) ~ /^## asked for[ \t]*$/); intab = 0; next }
    !t { next }
    {
      line = $0
      if (line ~ /^(    |\t)/) { intab = 0; next }   # four blanks or a tab: an indented code block, not a table
      if (line ~ /^[ \t]*$/ || line !~ /\|/) { intab = 0; next }
      gsub(/\\\|/, "\001", line)      # an escaped pipe belongs to its cell
      sub(/^[ \t]+/, "", line); base = (line ~ /^\|/) ? 1 : 0   # leading blanks only: cells keep their inner blanks
      n = split(line, c, "|")
      if (!intab) { if (tolower(plain(c[1 + base])) == "ask") intab = 1; next }   # the register starts at its header line
      a = trim(c[1 + base])
      if (a ~ /^:?-+:?$/ || (tolower(plain(a)) == "ask" && tolower(plain(c[2 + base])) == "date" && tolower(plain(c[3 + base])) == "file")) next   # the separator row, or a repeated header (all three cells: a row for an ask titled "Ask" counts)
      s = tolower(plain(c[5 + base])); sub(/^[^a-z]+/, "", s)   # a leading emoji or bullet is not the state
      k = (s ~ /^done([^a-z]|$)/) ? "done" : ((s ~ /^(dropped|moved)([^a-z]|$)/) ? "dropped" : "open")
      raw = c[3 + base]
      if (length(raw) > 600) f = ""   # padding beyond this is junk; it also bounds the quadratic trim below (600 blanks: well under a millisecond a row)
      else { f = raw; sub(/^[ \t]+/, "", f); sub(/[ \t]+$/, "", f); if (length(f) > 255) f = "" }   # edges only: a name keeps its own inner blanks; no file name is over 255 (NAME_MAX), which also bounds the shell loop
      gsub(/\001/, "|", f); gsub(/[\001-\037]/, "", f)
      g0 = f; sub(/^[*~]+/, "", g0); sub(/[*~]+$/, "", g0)   # bold/strike wrappers
      g = g0; sub(/^`+/, "", g); sub(/`+$/, "", g)   # g: wrapping markup only, file names keep their underscores
      h = g0   # h: also MATCHED pairs of wrapping underscores (italics, bold) around plain text or a code span; the inside of a code span stays literal
      for (w = 0; w < 2; w++) if (h ~ /^_.+_$/) { sub(/^_/, "", h); sub(/_$/, "", h); sub(/^[*~]+/, "", h); sub(/[*~]+$/, "", h) }
      sub(/^`+/, "", h); sub(/`+$/, "", h)
      tgt = ""; lk = (h ~ /^!?\[[^]]*\]\(.*\)$/) ? h : ((g ~ /^!?\[[^]]*\]\(.*\)$/) ? g : "")
      if (lk != "") { tgt = lk; sub(/^.*\]\(/, "", tgt); sub(/\)$/, "", tgt); if (tgt ~ /^</) { sub(/^</, "", tgt); sub(/>.*$/, "", tgt) } else { sub(/[ \t].*$/, "", tgt) }; sub(/#.*$/, "", tgt); gsub(/%20/, " ", tgt) }
      if (k == "open") nopen++
      else if (k == "done") {   # open rows are only counted here; of the done rows the FIRST 250 and the LAST 250 are kept (rows are added at either end), so the shell loop stays short
        nd++; r = k "\037" f "\037" g "\037" h "\037" "" "\037" tgt
        if (nd <= 250) head[nd] = r; else ring[nd % 250] = r
      }
    }
    END { for (i = 1; i <= (nd < 250 ? nd : 250); i++) print head[i]; for (i = (nd > 499 ? nd - 249 : 251); i <= nd; i++) print ring[i % 250]; print "count\037" (nopen + 0) }' 2>/dev/null || true)
  _NOPEN=0; _NNOFILE=0
  if [ -n "$_ROWS" ]; then
    _US=$(printf '\037')
    while IFS="$_US" read -r _c _f _g _h _l _t; do
      case "$_c" in
        count) case "$_f" in ""|*[!0-9]*) ;; *) _NOPEN=$_f ;; esac ;;
        done)
          # "done" counts only when the file is really in the folder (no path tricks).
          _have=0
          for _cand in "$_f" "$_g" "$_h" "$_t"; do   # literal names first; a link resolves by its target, never by its label
            case "$_cand" in */megavibe-deliverables/*) _cand="${_cand##*/megavibe-deliverables/}" ;; esac   # an absolute path into the folder
            _cand="${_cand#megavibe-deliverables/}"; _cand="${_cand#./}"; _cand="${_cand%/}"
            case "$_cand" in
              ""|.|/*|..|../*|*/../*|*/..|./*) ;;
              *) [ -e "megavibe-deliverables/$_cand" ] && _have=1 ;;
            esac
          done
          [ "$_have" -eq 1 ] || _NNOFILE=$((_NNOFILE + 1)) ;;
      esac
    done <<ROWS_EOF
$_ROWS
ROWS_EOF
  fi
  # While something is open: research notes newer than the newest deliverable
  # (last 14 days) may be the memo that was asked for. Heuristic, counted only.
  _NNEWR=0
  if [ "$_NOPEN" -gt 0 ] && [ -d .agent/RESEARCH ]; then
    _NEWEST=$(ls -t megavibe-deliverables 2>/dev/null | grep -v -E '^(STATUS|README)\.md$' | head -1 || true)
    if [ -n "$_NEWEST" ]; then
      _NNEWR=$(find .agent/RESEARCH -type f ! -name '.gitkeep' -mtime -14 -newer "megavibe-deliverables/$_NEWEST" -print0 2>/dev/null | LC_ALL=C tr -cd '\0' | wc -c | tr -d ' ' || echo 0)
    else
      _NNEWR=$(find .agent/RESEARCH -type f ! -name '.gitkeep' -mtime -14 -print0 2>/dev/null | LC_ALL=C tr -cd '\0' | wc -c | tr -d ' ' || echo 0)
    fi
  fi
  _PARTS=""
  [ "$_NOPEN" -eq 0 ] || _PARTS="${_PARTS}
- ${_NOPEN} ask(s) still open"
  [ "$_NNOFILE" -eq 0 ] || _PARTS="${_PARTS}
- ${_NNOFILE} ask(s) marked done whose file is not in megavibe-deliverables/"
  [ "${_NNEWR:-0}" -eq 0 ] 2>/dev/null || _PARTS="${_PARTS}
- ${_NNEWR} research note(s) in .agent/RESEARCH newer than the newest deliverable (heuristic: the memo asked for may be one of them; promote it to the folder)"
  if [ "${_NOWB:-0}" -gt 4000 ] 2>/dev/null; then
    _PARTS="${_PARTS}
- the STATUS.md \"Now\" section is ${_NOWB} bytes (cap about 4000): move the account into a dated file in the folder and link it"
  fi
  if [ -n "$_PARTS" ]; then
    ASK_WARN="Counts only, taken from megavibe-deliverables/STATUS.md (an ask is done only when its file is in the folder; a chat answer is not a file). Read its \"Asked for\" table and finish or update the rows:${_PARTS}"
  fi
fi

MSG="📋 COMPACTION IS ABOUT TO HAPPEN — CONTEXT FILE STATUS:
- FULL_CONTEXT.md: ${FC_LINES} lines
- TASKS.md: ${TASKS_LINES} lines
- DECISIONS.md: ${DECISIONS_LINES} lines
- LESSONS.md: ${LESSONS_LINES} lines
- Tool calls since last .agent/ write: ${COUNT}
- Newest .agent/events entry: ${LAST_WRITE_MIN} min ago

⚠️ If ${COUNT} is high, context accumulated in this conversation may NOT be in the .agent/ files yet. The post-compaction recovery will only have what's on disk.

After compaction, the only required action is: run /rehydrate (it regenerates WORKING_CONTEXT.md via the chain reviewers.sh digest-chain prints: Codex then the Claude subagent, or capped Gemini then the subagent where there is no Codex). The post-compact hook writes the full orientation (git state, DECISIONS/TASKS/LESSONS) to .agent/LOGS/rehydration-instructions.<session>.md."


# Add the register-currency warning to the report. This is the one part of it
# that can contradict the reassuring line counts above, which is why it is also
# written to .reg-warn.<sid> below for the post-compact message.
if [ -n "$REG_WARN" ]; then
  MSG="$MSG

🕗 REGISTER CURRENCY — the records may describe a state the repo has left:${REG_WARN}

These files are what post-compaction recovery reads FIRST, and the line counts above say nothing about whether they are still TRUE. Before repeating anything from TASKS §0 or BUGS as current, re-read them against git (tags, recent commits). Treat a stale §0 as the first thing to fix after /rehydrate."
fi

if [ -n "$ASK_WARN" ]; then
  MSG="$MSG

📎 DELIVERABLES REGISTER:${ASK_WARN}"
fi

# --- Optional fold hint (appended only if FULL_CONTEXT.md is large) ---
# FULL_CONTEXT.md is RENDERED from the write-once event log, so its size is not a
# problem in itself (/rehydrate reads a bounded slice). What accumulates is the number of
# event files; agent-log.sh fold moves old ones into snapshot.md and the rendered view
# stays identical. The old /prune-context skill, which asked an AI which lines to delete
# from the rendered file, is superseded. Distinct from /compact (the live conversation).
PRUNE_THRESHOLD=500
if [ "$FC_LINES" -gt "$PRUNE_THRESHOLD" ] 2>/dev/null; then
  MSG="$MSG

🧹 FULL_CONTEXT.md is ${FC_LINES} lines (above the ${PRUNE_THRESHOLD}-line threshold). It is rendered from write-once events and /rehydrate reads a bounded slice, so the size alone is not a problem. If .agent/events/ has accumulated a lot of old entries, run .claude/hooks/agent-log.sh fold after /rehydrate: it moves events older than 30 days into .agent/snapshot.md, loses nothing, and FULL_CONTEXT.md renders identically before and after. This is distinct from /compact, which summarizes the live conversation."
fi

# --- Where the report goes ---
#   1. A timestamped alert file per compaction (one fixed name was overwritten
#      every time, so 16 of 20 compactions could not be audited afterwards),
#      plus the fixed name as a copy of the latest; the last 30 per session kept.
#   2. stderr (Claude Code surfaces hook stderr to the user).
#   3. The register-currency warning, the one part the next model must see, to a
#      file on-compact.sh puts into its post-compact message.
ALERT_FILE="${LOGDIR}/pre-compact-alert.${SID}.md"
ALERT_TS_FILE="${LOGDIR}/pre-compact-alert.${SID}.$(date -u +%Y%m%dT%H%M%SZ).md"
{
  echo "# Pre-compact alert — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "$MSG"
} > "$ALERT_TS_FILE" 2>/dev/null || true
cp "$ALERT_TS_FILE" "$ALERT_FILE" 2>/dev/null || true
ls -t "${LOGDIR}"/pre-compact-alert."${SID}".2*.md 2>/dev/null | tail -n +31 | while IFS= read -r _old; do rm -f "$_old" 2>/dev/null || true; done
if [ -n "$REG_WARN" ]; then
  printf '%s\n' "$REG_WARN" > "${LOGDIR}/.reg-warn.${SID}" 2>/dev/null || true
else
  rm -f "${LOGDIR}/.reg-warn.${SID}" 2>/dev/null || true
fi
if [ -n "$ASK_WARN" ]; then
  printf '%s\n' "$ASK_WARN" > "${LOGDIR}/.ask-warn.${SID}" 2>/dev/null || true
  # What on-compact.sh reads is numbers only, validated there; it renders the text itself.
  printf '%s %s %s %s\n' "${_NOPEN:-0}" "${_NNOFILE:-0}" "${_NNEWR:-0}" "${_NOWB:-0}" > "${LOGDIR}/.ask-counts.${SID}" 2>/dev/null || true
else
  rm -f "${LOGDIR}/.ask-warn.${SID}" "${LOGDIR}/.ask-counts.${SID}" 2>/dev/null || true
fi

# Echo to stderr — visible to the user in the Claude Code UI
echo "" >&2
echo "═══════════════════════════════════════════════════════════════" >&2
echo "$MSG" >&2
echo "" >&2
echo "(saved to $ALERT_FILE)" >&2
echo "═══════════════════════════════════════════════════════════════" >&2
echo "" >&2

# Kept for older Claude Code versions that may still show it; current ones discard it.
jq -n --arg msg "$MSG" '{systemMessage: $msg}' 2>/dev/null || true
