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
# Bash branch covers shell CONTENT search (grep/rg/ag/ack) so memory recall fires
# however Claude searches, not only via the native Grep/Glob tools. It is gated to
# AVOID operational misfires: skips greps that filter piped output (`… | grep x`),
# counting/quiet/only-matching flags (-c/-q/-o), and log/config targets (*.log,
# .claude/, .megavibe/, /tmp). find/fd are excluded (file-name location, not a
# concept search). A search reading repo files (`rg x`, `grep -rn x src/`) fires.
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
# Session scope for the per-session injection ledgers (dedup + self-write suppression).
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12 || echo "default")
SID="${SID:-default}"

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
  # Shell CONTENT search: pull the pattern out of grep/rg/ag/ack invocations,
  # but only when it's a genuine codebase search — not operational plumbing.
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
  # Cheap gate: only parse when a content-search tool appears as a command word.
  if command -v python3 &>/dev/null && \
     printf '%s' "$CMD" | grep -qE '(^|[|;&(]|[[:space:]])(grep|egrep|fgrep|rg|ag|ack)([[:space:]]|$)' 2>/dev/null; then
    # shlex handles quotes; per-tool flag logic avoids grabbing paths/flag values.
    PATTERN=$(python3 - "$CMD" 2>/dev/null <<'PYEOF' || true
import sys, re, shlex
PATTERN_FLAGS = {'-e', '--regexp'}
SKIP_VAL = {'-f','--file','-g','--glob','-t','--type','--include','--exclude',
            '-m','--max-count','-A','-B','-C','--context','-d','--max-depth','--threads','-j'}
OPS_FLAGS = {'--count','--quiet','--silent','--only-matching'}
SEARCH = {'grep','egrep','fgrep','rg','ag','ack'}
# Operational targets — filtering/counting/log-poking, not codebase exploration.
OPS_PATH = re.compile(r'\.log\b|\.jsonl\b|/\.claude/|/\.megavibe/|/tmp/|/var/log|hook-errors')
def clean(p):
    return ' '.join(re.sub(r'[^A-Za-z0-9 ]+', ' ', p).split())
def extract(cmd):
    # Skip operational commands that merely contain a search tool.
    if OPS_PATH.search(cmd):
        return ''
    m = re.search(r'(?<!\w)(egrep|fgrep|grep|rg|ag|ack)(?!\w)', cmd)
    if not m:
        return ''
    # A search tool downstream of a pipe is FILTERING output, not searching files.
    if '|' in cmd[:m.start()]:
        return ''
    try:
        toks = shlex.split(cmd)
    except Exception:
        return ''
    n = len(toks)
    for i in range(n):
        if toks[i].split('/')[-1] not in SEARCH:
            continue
        j = i + 1
        while j < n:
            a = toks[j]
            # count/quiet/only-matching = scripting, not exploration
            if a in OPS_FLAGS:
                return ''
            if re.fullmatch(r'-[A-Za-z]+', a) and (set(a[1:]) & set('cqo')):
                return ''
            if a in PATTERN_FLAGS and j + 1 < n:
                return clean(toks[j + 1])
            if a.startswith('-'):
                if '=' in a: j += 1; continue
                if a in SKIP_VAL: j += 2; continue
                j += 1; continue
            return clean(a)
        return ''
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
# --min-score is a relevance floor on the RRF-fused score. Anatomy: a hit at
# rank r in a list contributes 1/(61+r), so the scale runs ~0.016 (top of ONE
# list = single-signal noise) to ~0.033 (top of BOTH lists). 0.028 requires
# both BM25 and semantic to rank the hit ~top-8 — tight corroboration. Note
# the ceiling: RRF is rank-based and saturates at 0.033, so no floor can drop
# an irrelevant hit that happens to top both lists; that's what poma-memory's
# cosine empty gate (v0.4+) is for — it suppresses ALL results when even the
# best semantic match is weak. Tune via MEGAVIBE_POMA_MIN_SCORE.
MIN_SCORE="${MEGAVIBE_POMA_MIN_SCORE:-0.028}"
# Over-request candidates so the filters below (ephemeral paths, self-written
# files, already-injected blocks) have room to drop noise without starving the
# final set. MAX_RESULTS caps what actually gets injected — the top few are the
# highest-scored survivors, which trims the low-signal 0.028-0.030 floor band
# that read as "unrelated". Tune via MEGAVIBE_POMA_{TOPK,MAX_RESULTS}.
TOPK="${MEGAVIBE_POMA_TOPK:-8}"
MAX_RESULTS="${MEGAVIBE_POMA_MAX_RESULTS:-3}"
# Numeric-guard the knobs: a non-numeric TOPK would make poma error (empty recall);
# a non-numeric MAX_RESULTS would crash the python int() and force the awk fallback.
case "$TOPK" in ''|*[!0-9]*) TOPK=8 ;; esac; [ "$TOPK" -ge 1 ] 2>/dev/null || TOPK=1
case "$MAX_RESULTS" in ''|*[!0-9]*) MAX_RESULTS=3 ;; esac   # 0 is valid = inject nothing
RAW_RESULTS=$($POMA_CMD search "$PATTERN" --path .agent/ --top-k "$TOPK" --min-score "$MIN_SCORE" 2>/dev/null || echo "")

# Per-session ledgers (see the python filter for full rationale):
#   injected.<sid>.log       — content-keys of blocks already injected this session
#   session-writes.<sid>.log — abspaths this session wrote under .agent/ (fed by
#                              reindex-agent.sh); their content is already in the
#                              live context, so re-injecting it is pure waste.
# Both are cleared on compaction (on-compact.sh) — after a summary the content has
# left the window, so recall becomes useful again.
mkdir -p .agent/LOGS 2>/dev/null || true
INJ_LEDGER=".agent/LOGS/injected.${SID}.log"
WRITES_LEDGER=".agent/LOGS/session-writes.${SID}.log"

# Fallback filter (no python3): drop result blocks whose File: path points at
# ephemeral, per-session, or audit state rather than durable semantic context.
# Without this, old "⚠️ CONTEXT WAS JUST COMPACTED" instructions and prior-session
# working-context dumps leak back in — they score the same as live docs (RRF
# saturates ~0.033 for any corroborated hit) so a score floor cannot exclude them;
# only a path filter can. Observed: stale session WORKING_CONTEXT outranking
# DECISIONS.md as a #1 hit for a code-symbol search.
# Honours MAX_RESULTS so the no-python3 path can't inject the full top-k (no dedup
# is available without hashing, but at least the volume matches the primary path).
_ephemeral_awk() {
  awk -v max="${MAX_RESULTS:-3}" '
  function flush() { if (buf ~ /^--- Result/ && !skip && printed < max) { printf "%s", buf; printed++ } }
  /^--- Result/ { flush(); buf = $0 "\n"; skip = 0; next }
  /^File:.*\.agent\/(LOGS|sessions)\// { skip = 1 }
  /^File:.*\.agent\/WORKING_CONTEXT\.md/ { skip = 1 }
  { buf = buf $0 "\n" }
  END { flush() }
  '
}

# Primary path (python3): ephemeral filter + self-written suppression + per-session
# dedup + cap. Dedup keys on the chunk BODY (File: path + text, minus the volatile
# "--- Result N (score) ---" header and "Updated:" line) so the same chunk is
# suppressed across DIFFERENT queries whose RRF scores differ — "one appearance is
# enough". Degrades to the awk ephemeral filter (no dedup) if python3 is absent or
# errors, so behaviour never regresses below today's.
if command -v python3 &>/dev/null; then
  # Pass data via env, not stdin: `python3 - <<HEREDOC` already consumes stdin as
  # the PROGRAM source, so a piped payload would never reach sys.stdin.read().
  RESULTS=$(RAW_RESULTS="$RAW_RESULTS" INJ_LEDGER="$INJ_LEDGER" WRITES_LEDGER="$WRITES_LEDGER" MAXN="$MAX_RESULTS" python3 - 2>/dev/null <<'PYEOF'
import sys, re, os, hashlib
inj_path = os.environ["INJ_LEDGER"]; writes_path = os.environ["WRITES_LEDGER"]
maxn = int(os.environ["MAXN"]); raw = os.environ.get("RAW_RESULTS", "")
blocks = [b for b in re.split(r'(?m)(?=^--- Result )', raw) if b.strip().startswith('--- Result')]
def load(p):
    try:
        return set(l.strip() for l in open(p) if l.strip())
    except Exception:
        return set()
injected = load(inj_path)
written = set(os.path.abspath(w) for w in load(writes_path))
EPHEMERAL = re.compile(r'\.agent/(LOGS|sessions)/|\.agent/WORKING_CONTEXT\.md')
kept, new = [], []
for b in blocks:
    if len(kept) >= maxn:                           # cap-at-top: maxn=0 -> inject nothing
        break
    m = re.search(r'(?m)^File: (\S+)', b)
    fp = m.group(1) if m else ''
    if fp and EPHEMERAL.search(fp):
        continue
    if fp and os.path.abspath(fp) in written:      # self-written (full Write) this session
        continue
    body = '\n'.join(l for l in b.splitlines()
                     if not l.startswith('--- Result') and not l.startswith('Updated:'))
    key = hashlib.md5(body.encode('utf-8', 'replace')).hexdigest()
    if key in injected:                             # already injected this session
        continue
    kept.append(b.rstrip('\n'))
    new.append(key)
if new:
    try:
        with open(inj_path, 'a') as f:
            f.write('\n'.join(new) + '\n')
    except Exception:
        pass
sys.stdout.write('\n'.join(kept))
PYEOF
) || RESULTS=$(printf '%s' "$RAW_RESULTS" | _ephemeral_awk)
else
  RESULTS=$(printf '%s' "$RAW_RESULTS" | _ephemeral_awk)
fi

# Only inject if we got meaningful results (not "No results found.")
if [ -z "$RESULTS" ] || [[ "$RESULTS" == *"No results found"* ]]; then
  exit 0
fi

# Inject as systemMessage — Claude treats this as authoritative system-level context
jq -n --arg msg "Related project context from poma-memory (semantic search on .agent/):
$RESULTS" '{
  systemMessage: $msg
}'
