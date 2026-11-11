#!/bin/bash
# claude-review.sh — the Claude-side counterpart of codex-review.sh: one lean headless worker
# call, with or without execution, on the Claude subscription. Same interface on purpose, so
# the allocation rule in .claude/rules/delegation.md can give a unit of work to either
# provider by weighing both weekly windows, not by which side is easier to spawn.
#
#   claude-review.sh [--as-reviewer] [--prompt TEXT | --prompt-file F] [--out FILE]
#                    [--model sonnet] [--timeout 900] [--tools exec|read|none]
#                    [--effort LEVEL] [--max-input-kb N] [--keep-scratch] FILE...
#
# The files are appended to the prompt as `===== path =====` blocks (and, for exec and read, also
# copied into the worker's scratch directory). The answer goes to stdout and to --out.
# Exit: 0 ok, 2 usage or refusal, 3 the call failed, 124 timed out.
#
# Why not the Agent tool: every Agent-tool subagent starts at about 93K tokens of inherited
# context in a project with heavy instructions and re-reads it each turn; this worker starts at
# about 5-8K. It keeps what the Agent-tool reviewer has (reading, running things) and adds what
# the sandboxed Codex reviewer has (a throwaway scratch directory, writes confined to it):
#  - cwd is a fresh scratch directory, TMPDIR inside it, deleted on exit (as codex-review.sh).
#  - --tools exec (the default under --as-reviewer): Read, Grep, Glob, Bash, Write. On macOS the
#    process runs under a seatbelt profile that DENIES every file write except the scratch
#    directory and claude's own state (so a stray `find -delete` or `git checkout` against the
#    project fails with "Operation not permitted"); the repository's block-dangerous-bash.sh
#    and block-permission-hooks.sh are registered through --settings, WITHOUT loading the
#    project's CLAUDE.md, rules or other hooks. Without a seatbelt (not macOS) exec is refused.
#    Not confined, unlike codex: the network (claude itself needs it) and reads.
#  - --tools read (the default otherwise): Read, Grep, Glob only. --tools none: nothing, the files
#    are only in the prompt (the cheapest; no scratch needed).
#  - Subscription login only: the call runs in an allow-listed minimal environment (no API key, token,
#    custom header or cloud-provider variable can reach it), and `claude auth status` must report a
#    claude.ai login (a saved Console key would bill); if that cannot be checked the script refuses.
# The `reviewer` role cannot be switched off, so --as-reviewer has no MEGAVIBE_REVIEWERS gate;
# it selects exec as the default and adds the process rules to the brief.
set -euo pipefail

PROG=${0##*/}
CLAUDE_BIN=${CLAUDE_REVIEW_CLAUDE:-claude}
MV_HOME=${MEGAVIBE_HOME:-$HOME/.megavibe}
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

# The environment of every claude call is an ALLOW-LIST (env -i plus what claude legitimately needs), so no
# credential, endpoint or header variable (ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_CUSTOM_HEADERS,
# cloud-provider switches and tokens, ...) can reach it, whatever it is called: a deny-list of names would miss
# the next one. A saved claude.ai login is found through HOME or CLAUDE_CONFIG_DIR.
CLEAN=(env -i)
for _v in PATH HOME USER LOGNAME SHELL TERM LANG LC_ALL LC_CTYPE TMPDIR TZ CLAUDE_CONFIG_DIR HTTPS_PROXY HTTP_PROXY NO_PROXY ALL_PROXY https_proxy http_proxy no_proxy all_proxy NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR; do
  if [ -n "${!_v+x}" ]; then CLEAN+=("$_v=${!_v}"); fi
done


die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
valid_model() { case $1 in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }
isnum() { case $1 in ''|*[!0-9]*) return 1 ;; esac; return 0; }

AS_REVIEWER=0 PROMPT='' PROMPT_FILE='' OUT='' MODEL=sonnet TIMEOUT=900 TOOLS='' EFFORT='' MAXKB='' KEEP=0
FILES=()
while [ $# -gt 0 ]; do
  case $1 in
    --as-reviewer) AS_REVIEWER=1; shift ;;
    --prompt) PROMPT=${2:-}; shift 2 ;;
    --prompt-file) PROMPT_FILE=${2:-}; shift 2 ;;
    --out) OUT=${2:-}; shift 2 ;;
    --model) MODEL=${2:-}; shift 2 ;;
    --timeout) TIMEOUT=${2:-}; shift 2 ;;
    --tools) TOOLS=${2:-}; shift 2 ;;
    --effort) EFFORT=${2:-}; shift 2 ;;
    --max-input-kb) MAXKB=${2:-}; shift 2 ;;
    --keep-scratch) KEEP=1; shift ;;
    --sandbox|--approve-for-me|--full-auto|--dangerously-skip-permissions|--permission-mode)
      die "$1 is not available here: the sandbox and the tool set are fixed by --tools" ;;
    -h|--help) usage 0 ;;
    --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
    -*) die "unknown option $1" ;;
    *) FILES+=("$1"); shift ;;
  esac
done
# a path that starts with - must not become an option of cat, cp, cmp or tr: every operand is made
# explicit (./ or absolute), and files are read by redirection
if [ ${#FILES[@]} -gt 0 ]; then
  for i in "${!FILES[@]}"; do case ${FILES[$i]} in /*|./*) ;; *) FILES[$i]=./${FILES[$i]} ;; esac; done
fi
case $PROMPT_FILE in ""|/*|./*) ;; *) PROMPT_FILE=./$PROMPT_FILE ;; esac
case $OUT in ""|/*|./*) ;; *) OUT=./$OUT ;; esac
valid_model "$MODEL" || die "bad --model"
isnum "$TIMEOUT" && [ "$TIMEOUT" -ge 1 ] || die "--timeout must be a number of seconds, at least 1"
[ -z "$EFFORT" ] || case $EFFORT in *[!A-Za-z0-9_-]*) die "bad --effort" ;; esac
if [ -z "$TOOLS" ]; then if [ "$AS_REVIEWER" = 1 ]; then TOOLS=exec; else TOOLS=read; fi; fi
case $TOOLS in exec|read|none) ;; *) die "--tools must be exec, read or none" ;; esac
if [ -z "$MAXKB" ]; then case $MODEL in haiku*) MAXKB=150 ;; *) MAXKB=600 ;; esac; fi
isnum "$MAXKB" || die "--max-input-kb must be a number"
if [ -n "$PROMPT_FILE" ]; then [ -r "$PROMPT_FILE" ] || die "cannot read $PROMPT_FILE"; PROMPT=$(cat < "$PROMPT_FILE"); fi
[ -n "$PROMPT" ] || die "give --prompt or --prompt-file"
command -v jq >/dev/null 2>&1 || die "needs jq"
command -v perl >/dev/null 2>&1 || die "needs perl"
if [ ${#FILES[@]} -gt 0 ]; then
  for f in "${FILES[@]}"; do
    [ -f "$f" ] && [ -r "$f" ] || die "cannot read $f"
    if ! LC_ALL=C tr -d '\000' < "$f" | cmp -s - "$f"; then die "$f looks binary (contains NUL bytes)"; fi
  done
fi

# exec needs a way to confine writes and the guard hooks; without both it is refused, never degraded
HOOKS=''
SEATBELT=0
if [ "$TOOLS" = exec ]; then
  if [ "$(uname -s)" = Darwin ] && command -v sandbox-exec >/dev/null 2>&1; then SEATBELT=1
  else die "--tools exec needs a write sandbox (macOS sandbox-exec); use --tools read, or codex-review.sh --as-reviewer, which has its own"; fi
  for d in "$MV_HOME/template/.claude/hooks" "$SELF_DIR/../template/.claude/hooks"; do
    if [ -x "$d/block-dangerous-bash.sh" ]; then HOOKS=$(CDPATH= cd -- "$d" && pwd -P); break; fi
  done
  [ -n "$HOOKS" ] || die "--tools exec needs block-dangerous-bash.sh (looked in $MV_HOME/template and next to this script); refusing to run Bash unguarded"
fi

SC=''; TOOLDIR=''
cleanup() {
  if [ -n "$SC" ] && [ "$KEEP" = 0 ]; then
    chmod -R u+rwX "$SC" 2>/dev/null || true; rm -rf "$SC" 2>/dev/null || true
    # the worker's own tool folder (named after its unique scratch dir), never anything else
    case $TOOLDIR in /private/tmp/claude-*/-*claude-review-scratch*) rm -rf "$TOOLDIR" 2>/dev/null || true ;; esac
  fi
}
trap cleanup EXIT

# subscription login only, checked under the same cleaned environment the call will use
J=$("${CLEAN[@]}" \
      perl -e 'alarm shift; exec @ARGV' 30 "$CLAUDE_BIN" auth status 2>/dev/null) \
  || die "cannot verify the login ('$CLAUDE_BIN auth status' failed); refusing to send anything"
M=$(printf '%s' "$J" | jq -r '.authMethod // empty' 2>/dev/null) || M=''
[ "$M" = "claude.ai" ] || die "the login is not a claude.ai subscription login (authMethod='${M:-unknown}'); refusing, because such calls could bill an API key"

SC=$(mktemp -d "${TMPDIR:-/tmp}/claude-review-scratch.XXXXXX") || die "cannot create the scratch dir"
SC=$(CDPATH= cd -- "$SC" && pwd -P)
mkdir "$SC/tmp" "$SC/in"

# the request: harness note, the caller's prompt, then the files
{
  printf 'NOTE FROM THE HARNESS: your working directory is a throwaway scratch directory (%s); TMPDIR is %s/tmp.' "$SC" "$SC"
  if [ "$TOOLS" = exec ]; then
    printf ' Every file write outside it is denied by the operating system, so work and run harnesses only there, by absolute path, and never run anything against the real HOME or the real repository. Never kill processes by pattern (pkill, killall, tmux, launchctl): kill only a PID you started yourself.'
  fi
  [ "$TOOLS" = none ] || printf ' Copies of the attached files are under %s/in/ (the same content is also in this prompt).' "$SC"
  printf ' The caller ran this from %s, which is the project: treat it as READ-ONLY.\n\n' "$PWD"
  printf '%s\n' "$PROMPT"
  if [ ${#FILES[@]} -gt 0 ]; then
    n=0
    for f in "${FILES[@]}"; do
      n=$((n + 1)); printf '\n===== %s =====\n' "$f"; cat < "$f"
      [ "$TOOLS" = none ] || cp -- "$f" "$SC/in/${n}_$(basename -- "$f")"
    done
  fi
} > "$SC/request.txt"
KB=$(( ($(wc -c < "$SC/request.txt") + 1023) / 1024 ))
[ "$KB" -le "$MAXKB" ] || die "the request is $KB KB, above --max-input-kb $MAXKB"

case $TOOLS in
  exec) TL="Read,Grep,Glob,Bash,Write"; SANDBOX_NOTE="seatbelt: writes only in the scratch dir" ;;
  read) TL="Read,Grep,Glob"; SANDBOX_NOTE="read-only tools" ;;
  none) TL=""; SANDBOX_NOTE="no tools" ;;
esac
ARGS=(-p --model "$MODEL" --output-format json --no-session-persistence --disable-slash-commands --strict-mcp-config --setting-sources "" --tools "$TL")
[ -z "$TL" ] || ARGS+=(--allowedTools "$TL")
[ -z "$EFFORT" ] || ARGS+=(--effort "$EFFORT")
PRE=()
if [ "$TOOLS" = exec ]; then
  # guard hooks only, registered here: no CLAUDE.md, rules or other hooks are loaded
  jq -n --arg d "$HOOKS" '{hooks:{PreToolUse:([{matcher:"Bash",hooks:[{type:"command",command:($d+"/block-dangerous-bash.sh")}]}]
      + (if ($d|length) > 0 then [{matcher:"Write|Edit",hooks:[{type:"command",command:($d+"/block-permission-hooks.sh")}]}] else [] end))}}' > "$SC/settings.json"
  ARGS+=(--settings "$SC/settings.json")
  # claude's Bash tool keeps a per-working-directory folder under /private/tmp/claude-<uid>/ (named
  # after the cwd) and a /tmp/claude-<id>-cwd file; only THIS worker's own folder is allowed, not the
  # whole tree, which also holds other sessions' scratch
  SLUG=$(printf '%s' "$SC" | sed 's/[^A-Za-z0-9]/-/g')
  TOOLDIR="/private/tmp/claude-$(id -u)/$SLUG"
  cat > "$SC/profile.sb" <<EOF
(version 1)
(allow default)
(deny file-write*)
(allow file-write*
  (subpath "$SC")
  (subpath "$TOOLDIR")
  (subpath "$HOME/.claude")
  (regex #"^$HOME/\\.claude\\.json")
  (regex #"^/private/tmp/claude-[0-9A-Za-z]+-cwd")
  (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper") (regex #"^/dev/fd/"))
EOF
  PRE=(sandbox-exec -f "$SC/profile.sb")
fi

printf '[claude-review: tools=%s (%s) model=%s timeout=%ss request=%sKB]\n' "$TOOLS" "$SANDBOX_NOTE" "$MODEL" "$TIMEOUT" "$KB" >&2
START=$(date +%s)
RC=0
( cd "$SC" && "${CLEAN[@]}" TMPDIR="$SC/tmp" \
    perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" ${PRE[@]+"${PRE[@]}"} "$CLAUDE_BIN" "${ARGS[@]}" < "$SC/request.txt" > "$SC/raw.json" 2> "$SC/raw.err" ) || RC=$?
DUR=$(( $(date +%s) - START ))

COST=$(jq -s -r 'if length != 1 then empty else .[0] | (if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end) | select(type == "object") | (.total_cost_usd | select(type == "number")) end' "$SC/raw.json" 2>/dev/null) || COST=''
[ -n "$COST" ] || COST='?'
TURNS=$(jq -s -r '.[0] | (if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end) | .num_turns // empty' "$SC/raw.json" 2>/dev/null) || TURNS=''
LED=${AMASS_LEDGER:-$HOME/.megavibe/amass-usage.jsonl}
if mkdir -p "$(dirname "$LED")" 2>/dev/null; then
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cmd review --arg model "$MODEL" --arg proj "$(basename "$PWD")" --arg tools "$TOOLS" \
    --argjson ok "$([ "$RC" = 0 ] && echo 1 || echo 0)" --arg cost "$COST" --argjson kb "$KB" --argjson dur "$DUR" \
    '{ts:$ts,cmd:$cmd,model:$model,project:$proj,tools:$tools,calls:1,ok:$ok,cost:($cost|tonumber? // null),input_kb:$kb,seconds:$dur}' >> "$LED" 2>/dev/null || true
fi
if [ "$RC" = 142 ]; then echo "$PROG: timed out after ${TIMEOUT}s (cost $COST)" >&2; exit 124; fi
if [ "$RC" != 0 ]; then echo "$PROG: the call failed (rc=$RC, cost $COST)" >&2; head -c 400 "$SC/raw.err" >&2; exit 3; fi
jq -e -s -r 'if length != 1 then empty else .[0] | (if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end) | select(type == "object" and .is_error == false and (.result | type) == "string") | .result end' "$SC/raw.json" > "$SC/answer.txt" 2>/dev/null \
  || { echo "$PROG: the call returned no usable result (cost $COST)" >&2; head -c 400 "$SC/raw.err" >&2; exit 3; }
printf '[claude-review: done in %ss, %s turn(s), cost $%s]\n' "$DUR" "${TURNS:-?}" "$COST" >&2
if [ -n "$OUT" ]; then ( umask 077; cp -- "$SC/answer.txt" "$OUT" ) || die "cannot write $OUT"; fi
cat "$SC/answer.txt"
