#!/bin/bash
# /bin/bash tests/compaction-channels.test.sh
# PreCompact stdout as preservation instructions, the Compact Instructions
# section, and rehydration that is required only when the session's working
# context is missing or older than the durable state it summarises.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOKS="$REPO/template/.claude/hooks"
T=$(mktemp -d "${TMPDIR:-/tmp}/compaction-channels.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/.megavibe"
export MEGAVIBE_WATCHER=0 CLAUDE_CODE_SESSION_ID=""
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

SID="0123abcd-4567-89ef-0123-456789abcdef"
S12=${SID:0:12}
MARK="PLANTED-PROJECT-TEXT-7f3e"

stamp() { # stamp FILE SECONDS_AGO
  local t=$(( $(date +%s) - $2 )) s
  s=$(date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$t" +%Y%m%d%H%M.%S)
  touch -t "$s" "$1"
}

newproj() { # newproj NAME -> prints dir; a populated .agent/ with planted text
  local p="$T/$1"
  mkdir -p "$p/.agent/events" "$p/.agent/LOGS" "$p/.agent/sessions/$SID" "$p/megavibe-deliverables"
  for i in $(seq 1 15); do echo "line $i $MARK" >> "$p/.agent/FULL_CONTEXT.md"; done
  printf '# Decisions\nDECISION: %s\n' "$MARK" > "$p/.agent/DECISIONS.md"
  printf '## 0. Where we stand (2020-01-01)\n%s\n' "$MARK" > "$p/.agent/TASKS.md"
  printf 'lesson %s\n' "$MARK" > "$p/.agent/LESSONS.md"
  printf 'DECISION: %s\n' "$MARK" > "$p/.agent/events/20200101T000000Z-x-000001.md"
  printf '## Now\n%s\n\n## Asked for\nAsk | Date | File | Mirror | State\n|---|---|---|---|---|\n%s | 2020-01-01 | x.md | | open\n' "$MARK" "$MARK" > "$p/megavibe-deliverables/STATUS.md"
  for f in "$p/.agent/FULL_CONTEXT.md" "$p/.agent/DECISIONS.md" "$p/.agent/TASKS.md" \
           "$p/.agent/LESSONS.md" "$p/.agent/events/"*.md "$p/megavibe-deliverables/STATUS.md"; do
    stamp "$f" 7200
  done
  echo "$p"
}
wc_file() { echo "$1/.agent/sessions/$SID/WORKING_CONTEXT.md"; }

precompact() { # precompact DIR [extra-json] -> stdout
  (cd "$1" && printf '{"session_id":"%s","transcript_path":"/x/%s.jsonl","hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null%s}' \
    "$SID" "$SID" "${2:-}" | /bin/bash "$HOOKS/on-pre-compact.sh" 2>/dev/null)
}
oncompact() { # oncompact DIR -> additionalContext
  (cd "$1" && printf '{"session_id":"%s","transcript_path":"/x/%s.jsonl","source":"compact"}' "$SID" "$SID" \
    | /bin/bash "$HOOKS/on-compact.sh" 2>/dev/null) | jq -r '.hookSpecificOutput.additionalContext // empty'
}
flag() { [ -f "$1/.agent/LOGS/.needs-rehydration.$S12" ]; }

# --- 1. PreCompact stdout: plain-text preservation instructions -------------
P=$(newproj pc1); echo "wc" > "$(wc_file "$P")"
OUT=$(precompact "$P")
check "precompact: stdout is not empty" '[ -n "$OUT" ]'
check "precompact: stdout is plain text, not JSON" '! printf "%s" "$OUT" | jq -e . >/dev/null 2>&1'
check "precompact: under the 10,000-character cap" '[ "${#OUT}" -lt 10000 ]'
check "precompact: names the working context path" 'printf "%s" "$OUT" | grep -qF ".agent/sessions/$SID/WORKING_CONTEXT.md"'
check "precompact: names the event log" 'printf "%s" "$OUT" | grep -qF ".agent/events/"'
check "precompact: asks to keep running background work with ids" 'printf "%s" "$OUT" | grep -qi "background"'
check "precompact: asks to keep open decisions" 'printf "%s" "$OUT" | grep -qi "decision"'
check "precompact: asks to keep the next step" 'printf "%s" "$OUT" | grep -qi "next step"'
check "precompact: carries no project-file text" '! printf "%s" "$OUT" | grep -qF "$MARK"'
check "precompact: alert file still written" 'ls "$P"/.agent/LOGS/pre-compact-alert.*.md >/dev/null 2>&1'

OUTSUB=$(precompact "$P" ',"agent_id":"a1"')
check "precompact: a subagent's compaction gets no session instructions" '[ -z "$OUTSUB" ]'

Q="$T/plain"; mkdir -p "$Q"
OUTQ=$(cd "$Q" && echo '{"session_id":"x"}' | /bin/bash "$HOOKS/on-pre-compact.sh" 2>/dev/null)
check "precompact: no output without .agent/" '[ -z "$OUTQ" ]'
check "precompact: no files without .agent/" '[ -z "$(ls -A "$Q")" ]'
OUTQ=$(cd "$Q" && echo '{"session_id":"x","source":"compact"}' | /bin/bash "$HOOKS/on-compact.sh" 2>/dev/null)
check "oncompact: no output without .agent/" '[ -z "$OUTQ" ]'
check "oncompact: no files without .agent/" '[ -z "$(ls -A "$Q")" ]'

BADSID='../../x'
OUTB=$(cd "$P" && printf '{"session_id":"%s","trigger":"auto"}' "$BADSID" | /bin/bash "$HOOKS/on-pre-compact.sh" 2>/dev/null)
check "precompact: unsafe session id never reaches the path" '! printf "%s" "$OUTB" | grep -qF "../"'

# --- 2. Freshness: stale = missing, empty, or older than the durable state ---
# Fresh: written after every event and register, even if hours old.
P=$(newproj fresh); W=$(wc_file "$P"); echo "wc" > "$W"; stamp "$W" 5400
precompact "$P" >/dev/null
check "fresh(pre): no rehydration flag for an old WC newer than all events" '! flag "$P"'
MSG=$(oncompact "$P")
check "fresh(post): no rehydration flag" '! flag "$P"'
check "fresh(post): message says rehydrate is optional" 'printf "%s" "$MSG" | grep -qi "optional"'
check "fresh(post): message says why (no newer events)" 'printf "%s" "$MSG" | grep -qi "newer than every event"'

# Stale: one event newer than a WC written ten minutes ago.
P=$(newproj stale); W=$(wc_file "$P"); echo "wc" > "$W"; stamp "$W" 600
echo "later" > "$P/.agent/events/20200101T000100Z-x-000002.md"; stamp "$P/.agent/events/20200101T000100Z-x-000002.md" 60
precompact "$P" >/dev/null
check "stale(pre): flag set when an event is newer than the WC" 'flag "$P"'
MSG=$(oncompact "$P")
check "stale(post): flag set" 'flag "$P"'
check "stale(post): message requires /rehydrate" 'printf "%s" "$MSG" | grep -q "Run /rehydrate"'
check "stale(post): message counts the newer events" 'printf "%s" "$MSG" | grep -q "1 event"'
check "stale(post): no project-file text" '! printf "%s" "$MSG" | grep -qF "$MARK"'

# Stale: a register (TASKS.md) changed after the WC.
P=$(newproj reg); W=$(wc_file "$P"); echo "wc" > "$W"; stamp "$W" 600; stamp "$P/.agent/TASKS.md" 30
precompact "$P" >/dev/null
check "register(pre): flag set when TASKS.md is newer than the WC" 'flag "$P"'
oncompact "$P" >/dev/null
check "register(post): flag set" 'flag "$P"'

# Missing and empty WC.
P=$(newproj missing)
precompact "$P" >/dev/null
check "missing(pre): flag set" 'flag "$P"'
MSG=$(oncompact "$P")
check "missing(post): flag set" 'flag "$P"'
check "missing(post): message says no working context" 'printf "%s" "$MSG" | grep -qi "no working context"'
P=$(newproj empty); : > "$(wc_file "$P")"
oncompact "$P" >/dev/null
check "empty(post): flag set" 'flag "$P"'

# Legacy project without an event log: FULL_CONTEXT.md written after the WC.
P=$(newproj legacy); rm -r "$P/.agent/events"
W=$(wc_file "$P"); echo "wc" > "$W"; stamp "$W" 600; stamp "$P/.agent/FULL_CONTEXT.md" 30
precompact "$P" >/dev/null
check "legacy(pre): FULL_CONTEXT.md newer than the WC is stale without an event log" 'flag "$P"'
oncompact "$P" >/dev/null
check "legacy(post): flag set" 'flag "$P"'
P=$(newproj legacy2); rm -r "$P/.agent/events"
W=$(wc_file "$P"); echo "wc" > "$W"; stamp "$W" 600
oncompact "$P" >/dev/null
check "legacy(post): fresh when nothing is newer" '! flag "$P"'

# Canonical WC stale, legacy 12-char WC fresh: both hooks judge the canonical one.
P=$(newproj split); W=$(wc_file "$P"); echo "wc" > "$W"; stamp "$W" 600
mkdir -p "$P/.agent/sessions/$S12"; echo "old" > "$P/.agent/sessions/$S12/WORKING_CONTEXT.md"
echo "later" > "$P/.agent/events/20200101T000100Z-x-000002.md"; stamp "$P/.agent/events/20200101T000100Z-x-000002.md" 60
precompact "$P" >/dev/null
check "split(pre): canonical WC decides, not the legacy one" 'flag "$P"'

# A failure before the list still hands the compaction a fixed list.
H="$T/brokenhooks"; mkdir -p "$H"; cp "$HOOKS"/*.sh "$H"/
awk '{print} /^INPUT=\$\(cat\)$/{print "false"}' "$HOOKS/on-pre-compact.sh" > "$H/on-pre-compact.sh"
check "fault injection applied" 'grep -qx false "$H/on-pre-compact.sh"'
P=$(newproj broken)
OUT=$(cd "$P" && printf '{"session_id":"%s","trigger":"auto"}' "$SID" | /bin/bash "$H/on-pre-compact.sh" 2>/dev/null); RC=$?
check "error path: exits 0" '[ "$RC" -eq 0 ]'
check "error path: still prints the preservation list" 'printf "%s" "$OUT" | grep -q "Megavibe preservation instructions"'
check "error path: list printed once" '[ "$(printf "%s\n" "$OUT" | grep -c "Megavibe preservation instructions")" -eq 1 ]'
check "error path: no project text" '! printf "%s" "$OUT" | grep -qF "$MARK"'

# The two copies of wc_state must stay identical.
fn() { sed -n '/^wc_state() {/,/^}/p' "$1"; }
check "wc_state identical in both hooks" '[ -n "$(fn "$HOOKS/on-compact.sh")" ] && [ "$(fn "$HOOKS/on-compact.sh")" = "$(fn "$HOOKS/on-pre-compact.sh")" ]'

# --- 3. Compact Instructions section in the protocol -------------------------
BLOCK=$(sed -n '/<!-- megavibe-v3 -->/,/<!-- \/megavibe-v3 -->/p' "$REPO/template/CLAUDE.md")
check "protocol: has a Compact Instructions heading inside the markers" 'printf "%s\n" "$BLOCK" | grep -qE "^#+ Compact Instructions$"'
SECTION=$(printf '%s\n' "$BLOCK" | awk '/^#+ Compact Instructions$/{f=1;next} f&&/^#+ /{exit} f')
check "protocol: Compact Instructions is short (index rule)" '[ "$(printf "%s\n" "$SECTION" | grep -c .)" -le 8 ]'

printf 'compaction-channels: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
