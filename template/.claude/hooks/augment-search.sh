#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="augment-search.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  jq -n --arg msg "$msg" '{systemMessage: $msg}' 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — augment Grep/Glob + Bash search with poma-memory vector search
# Triggered by: PreToolUse (Grep, Glob, Bash)
#
# Bash branch covers shell search (grep/rg/ag/fd/ack/find) — including piped
# forms the native-tools nudge deliberately ignores — so memory recall fires no
# matter how Claude searches, not only via the native Grep/Glob tools.
#
# When Claude searches for something, this hook silently runs a poma-memory
# search with the same query and injects any relevant .agent/ context as a
# systemMessage. Claude sees both native results + semantic matches.
#
# systemMessage is more authoritative than additionalContext — Claude treats
# it as system-level instruction rather than advisory annotation.
#
# Performance: model2vec semantic search on <10K vectors takes <10ms.
# No timeout needed (macOS lacks `timeout` command — was silently breaking this hook).

# Only run if this is a Megavibe-initialized project
[ -d ".agent" ] || exit 0

# Require poma-memory (pip-installed)
command -v poma-memory &>/dev/null || exit 0
POMA_CMD="poma-memory"

# Check index exists (no point searching an empty index)
[ -f ".agent/.poma-memory.db" ] || exit 0

# Require jq
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")

# Extract search term based on tool type
PATTERN=""
if [[ "$TOOL_NAME" == "Grep" ]]; then
  PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // ""' 2>/dev/null || echo "")
elif [[ "$TOOL_NAME" == "Glob" ]]; then
  # Extract meaningful terms from glob pattern (e.g., "**/*.test.ts" → "test")
  RAW=$(echo "$INPUT" | jq -r '.tool_input.pattern // ""' 2>/dev/null || echo "")
  # Strip glob syntax to get searchable keywords
  PATTERN=$(echo "$RAW" | sed 's/\*\*\///g; s/\*//g; s/\.//g; s/\///g' | tr -- '-_' ' ')
elif [[ "$TOOL_NAME" == "Bash" ]]; then
  # Shell search: pull the pattern out of grep/rg/ag/fd/ack/find invocations.
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
  # Cheap gate: only parse when a search tool appears as a command word.
  if command -v python3 &>/dev/null && \
     printf '%s' "$CMD" | grep -qE '(^|[|;&(]|[[:space:]])(grep|egrep|fgrep|rg|ag|ack|fd|find)([[:space:]]|$)' 2>/dev/null; then
    # shlex handles quotes; per-tool flag logic avoids grabbing paths/flag values.
    PATTERN=$(python3 - "$CMD" 2>/dev/null <<'PYEOF' || true
import sys, re, shlex
PATTERN_FLAGS = {'-e', '--regexp'}
SKIP_VAL = {'-f','--file','-g','--glob','-t','--type','--include','--exclude',
            '-m','--max-count','-A','-B','-C','--context','-d','--max-depth','--threads','-j'}
SEARCH = {'grep','egrep','fgrep','rg','ag','fd','ack'}
def clean(p):
    return ' '.join(re.sub(r'[^A-Za-z0-9 ]+', ' ', p).split())
def extract(cmd):
    try:
        toks = shlex.split(cmd)
    except Exception:
        return ''
    n = len(toks); i = 0
    while i < n:
        base = toks[i].split('/')[-1]
        if base in SEARCH:
            j = i + 1
            while j < n:
                a = toks[j]
                if a in PATTERN_FLAGS and j + 1 < n:
                    return clean(toks[j + 1])
                if a.startswith('-'):
                    if '=' in a: j += 1; continue
                    if a in SKIP_VAL: j += 2; continue
                    j += 1; continue
                return clean(a)
            return ''
        if base == 'find':
            for k in range(i + 1, n):
                if toks[k] in ('-name','-iname','-path','-ipath','-regex','-iregex') and k + 1 < n:
                    return clean(toks[k + 1])
            return ''
        i += 1
    return ''
print(extract(sys.argv[1]))
PYEOF
)
  fi
fi

# Skip trivial patterns (too short to be meaningful)
[ "${#PATTERN}" -gt 3 ] || exit 0

# Skip if Claude is already searching inside .agent/ (avoid redundancy)
SEARCH_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // ""' 2>/dev/null || echo "")
if [[ "$SEARCH_PATH" == *".agent"* ]]; then
  exit 0
fi

# Run poma-memory search (no timeout — <10ms on typical indexes).
# Request extra results so the .agent/LOGS/ filter below can drop noise
# (stale rehydration-instructions, session state dumps) without starving
# the useful matches.
# --min-score is a relevance floor: RRF scores cluster ~0.027+ when BOTH BM25 and
# semantic corroborate a hit vs ~0.016 for single-signal noise, so 0.02 keeps only
# corroborated context and injects NOTHING when nothing is genuinely relevant —
# no more random off-topic cheatsheets. Tune via MEGAVIBE_POMA_MIN_SCORE.
MIN_SCORE="${MEGAVIBE_POMA_MIN_SCORE:-0.02}"
RAW_RESULTS=$($POMA_CMD search "$PATTERN" --path .agent/ --top-k 6 --min-score "$MIN_SCORE" 2>/dev/null || echo "")

# Drop result blocks whose File: path is under .agent/LOGS/ — that dir is an
# audit trail (rehydration-instructions, per-session flags, counters), not
# semantic context. Without this filter, old "⚠️ CONTEXT WAS JUST COMPACTED"
# instruction files leak back in and look like live re-hydration nags.
RESULTS=$(echo "$RAW_RESULTS" | awk '
/^--- Result/ {
  if (buf != "" && !skip) printf "%s", buf
  buf = $0 "\n"
  skip = 0
  next
}
/^File:.*\.agent\/LOGS\// { skip = 1 }
{ buf = buf $0 "\n" }
END { if (buf != "" && !skip) printf "%s", buf }
')

# Only inject if we got meaningful results (not "No results found.")
if [ -z "$RESULTS" ] || [[ "$RESULTS" == *"No results found"* ]]; then
  exit 0
fi

# Inject as systemMessage — Claude treats this as authoritative system-level context
jq -n --arg msg "Related project context from poma-memory (semantic search on .agent/):
$RESULTS" '{
  systemMessage: $msg
}'
