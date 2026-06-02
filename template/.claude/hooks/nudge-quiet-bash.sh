#!/bin/bash
# DO NOT use set -e — this hook must be resilient to transient failures.
_hook_error() {
  local msg="nudge-quiet-bash.sh failed at line $1: $2"
  echo "$msg" >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — nudge Claude away from self-narrating shell.
#
# Triggered by: PreToolUse (Bash) and PreToolUse (Write of *.sh / *.bash).
# Exit 0 ALWAYS — advisory only, never blocks (invariant #3; the only
# intentional-block hook is block-dangerous-bash.sh).
#
# Rationale: on bypass/yolo the only consumer of a script's stdout is the
# model on its next turn — and the model authored the script, so echoing
# "Starting…/Step 1 complete/banners" narrates its own plan back to itself.
# That costs tokens twice (authored INTO the script + re-ingested as output)
# and tells the next turn nothing it can't read from the source.
#
# Design (mirrors nudge-native-tools.sh):
#   * High precision over recall — a false nudge erodes trust. Trigger only
#     on a banner OR >=2 narration echoes. A lone status echo never fires.
#   * Honors the rule's escape hatch: lines routing output to stderr (>&2),
#     a log (>>), or gated behind VERBOSE/DEBUG are NOT counted — those are
#     sanctioned breadcrumbs, not violations.
#   * Dedupes once per session (no nag-spam). The CLAUDE.md rule carries the
#     standing norm; this hook is just a spot reminder.
#   * Emits systemMessage via JSON stdout (the advisory channel, per the
#     nudge-native-tools convention).

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")

# Resolve the text to inspect depending on the tool.
TEXT=""
case "$TOOL" in
  Bash)
    TEXT=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
    ;;
  Write)
    FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
    case "$FP" in
      *.sh|*.bash) TEXT=$(echo "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null || echo "") ;;
      *) exit 0 ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
[ -n "$TEXT" ] || exit 0

# Normalize: split statement separators (; and newlines) so each echo counts
# independently, then drop fragments that route output to stderr / a log, or
# sit behind a VERBOSE|DEBUG gate — those are the rule's allowed breadcrumbs.
# NB: split on ; only, NOT && — a guard like `[ -n "$VERBOSE" ] && echo ...`
# must stay on one fragment so the VERBOSE filter below can see it.
NORM=$(printf '%s\n' "$TEXT" | sed 's/;/\
/g' | grep -vEi '>&2|>>|> |VERBOSE|DEBUG' 2>/dev/null || true)

# Banner echoes: an echo of a separator rule (4+ of = - # *).
BANNER=$(printf '%s\n' "$NORM" | grep -cE 'echo[[:space:]]+.{0,3}[-=#*]{4,}' 2>/dev/null || true)

# Narration echoes: an echo of a progress / status phrase on stdout.
NARR=$(printf '%s\n' "$NORM" | grep -ciE 'echo.*(starting|step [0-9]|done|completed|complete|checking|running|finished|processing|initializing|beginning|verifying|preparing|installing|building|✓|✅|🚀|==>)' 2>/dev/null || true)

BANNER=${BANNER:-0}
NARR=${NARR:-0}
# High-precision gate: one banner, or two-plus narration echoes.
if [ "$BANNER" -eq 0 ] && [ "$NARR" -lt 2 ]; then
  exit 0
fi

# Per-session dedup — nudge at most once per session.
SID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null | cut -c1-12)
SID="${SID:-default}"
NUDGE_DIR=".agent/LOGS"
mkdir -p "$NUDGE_DIR" 2>/dev/null || true
SEEN_FLAG="${NUDGE_DIR}/.nudge-quiet-bash.${SID}"
if [ -f "$SEEN_FLAG" ]; then
  exit 0
fi
touch "$SEEN_FLAG" 2>/dev/null || true

MSG="[megavibe] This shell narrates its own steps to stdout (banners / progress / 'step complete' chatter). On bypass the only reader is you next turn — and you wrote the script, so this costs tokens twice (authored in + re-ingested) and tells you nothing the source didn't. Quiet by default: emit only errors, computed values, and an explicit verification verdict (quiet != correct — print the check, don't infer success from silence). Gate real breadcrumbs behind VERBOSE=1 or send them to stderr/a log. (One-time nudge per session — call still runs.)"

jq -n --arg msg "$MSG" '{systemMessage: $msg}' 2>/dev/null || true

exit 0
