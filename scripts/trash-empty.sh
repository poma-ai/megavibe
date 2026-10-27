#!/bin/bash
# Empty what the Trash review marked droppable (or, with --all, the whole Trash),
# but only behind a permission prompt the human answers.
#
#   ~/.megavibe/scripts/trash-empty.sh          delete the items marked "droppable" in the review
#   ~/.megavibe/scripts/trash-empty.sh --all    delete everything in ~/.Trash
#
# This is the one place megavibe really deletes. Megavibe sessions run with
# permissions bypassed, and every consent check an agent can run itself was shown
# forgeable (environment overrides, transcript appends, pseudo-terminals). What an
# agent cannot answer for the user is Claude Code's own permission prompt: an ASK
# rule is honoured under bypassPermissions, and the prompt is forwarded to the phone
# under Remote Control. So the gate is a pair of `permissions.ask` rules that
# setup.sh installs (see README, "Trash greenlight"), and this script is the thing
# they gate:
#
#   Bash(~/.megavibe/scripts/trash-empty.sh *)    the one spelling the hook lets through
#   Bash(*trash-empty*)                           catch-all: any command text naming it prompts
#
# Hardening, each against a way of getting the delete WITHOUT that prompt:
#   - it refuses unless it is the file at $HOME/.megavibe/scripts/trash-empty.sh (not a
#     copy, a symlink, `source`d, or run under another HOME), so renaming it dodges nothing;
#   - it refuses unless those ask rules are present in the user's settings (or in the
#     managed settings file). Presence is the mechanism check, NOT the user's consent: the
#     consent is the prompt. Removing the rules to dodge the prompt makes this refuse;
#   - everything derives from $HOME. MEGAVIBE_TRASH_DIR and MEGAVIBE_TRASH_LEDGER_DIR
#     (the test knobs trash-review.py honours) are ignored here, and the script takes no
#     --yes, --dry-run or environment switch: a prefix assignment must not aim it elsewhere;
#   - each droppable item is deleted only if its recorded Trash entry is still there, in
#     ~/.Trash, and is the same object (device and inode) the ledger recorded.
#
# The deletion uses /bin/rm on purpose: the rm-to-trash.sh hook rewrites the command
# text Claude runs, never the inside of a script, so this really deletes, and that is
# the point of the prompt. rm does not follow symlinks: a symlink in the Trash is
# unlinked and its target is untouched.
#
# No lock: a concurrent `trash-review.py apply` renames an item into its claim
# directory first, so this script's identity check or its rm then reports "gone" and
# the item is skipped, never deleted twice or half-moved.
#
# Exit: 0 done (or nothing to do); 1 some item failed or was skipped; 2 usage;
#       3 precondition (environment, install path, Trash); 4 the permission rules are not installed.
#
# Known limits, same as the Trash guard's (README): the identity check and the rm are
# two steps, so an entry swapped in between by something running as the user is deleted;
# the rule-presence check reads a file the user's own account can edit, so the managed
# settings file (setup.sh --trash-greenlight-managed) is what makes it hold against an agent.

[ -n "${BASH_VERSION:-}" ] || { echo "trash-empty.sh: must run under bash" >&2; exit 3; }
[[ ${BASH_SOURCE[0]} == "$0" ]] || { echo "trash-empty.sh: refusing to be sourced" >&2; return 3 2>/dev/null || exit 3; }
# Functions a caller exported (export -f jq) are imported by this shell and would stand in for
# jq, cd, printf, date ...: drop them all before anything else runs.
# shellcheck disable=SC2046  # word splitting is the point: one function name per word
builtin unset -f $(builtin compgen -A function) 2>/dev/null
# No -e: a failing item must not stop the others. Every failure below is handled by hand.
set -uo pipefail

usage() { echo "usage: ~/.megavibe/scripts/trash-empty.sh [--all]" >&2; exit 2; }
die() { echo "trash-empty.sh: $2" >&2; exit "$1"; }

MODE=droppable
case $# in
  0) ;;
  1) [ "$1" = "--all" ] && MODE=all || usage ;;
  *) usage ;;
esac

# --- preconditions: any failure touches nothing -------------------------------------
[ "$(uname -s)" = Darwin ] || die 3 "macOS only (the Trash and its ledger are macOS-specific)"
[ -n "${HOME:-}" ] && [[ $HOME == /* ]] || die 3 "HOME is not set to an absolute path"
command -v jq >/dev/null 2>&1 || die 3 "jq is required (brew install jq)"
command -v python3 >/dev/null 2>&1 || die 3 "python3 is required"

# Physical path of an existing entry's directory plus its name (a final symlink is not resolved).
phys() { local d; d=$(cd "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1; printf '%s/%s\n' "$d" "$(basename -- "$1")"; }
INSTALL_DIR=$(cd "$HOME/.megavibe/scripts" 2>/dev/null && pwd -P) || die 3 "$HOME/.megavibe/scripts does not exist; run it from its install path"
SELF=$(phys "$0") || die 3 "cannot resolve $0"
[ ! -L "$0" ] && [ -f "$0" ] && [ "$SELF" = "$INSTALL_DIR/trash-empty.sh" ] \
  || die 3 "run it from its install path: ~/.megavibe/scripts/trash-empty.sh (not a copy, a symlink, or another HOME)"

TRASH="$HOME/.Trash"
[ -d "$TRASH" ] && [ ! -L "$TRASH" ] || die 3 "$TRASH is not a directory (or is a symlink); nothing touched"
TRASH_PHYS=$(cd "$TRASH" && pwd -P) || die 3 "cannot enter $TRASH"
REVIEW="$INSTALL_DIR/trash-review.py"
[ -f "$REVIEW" ] && [ ! -L "$REVIEW" ] || die 3 "$REVIEW is missing; run setup.sh"
LEDGER_DIR="$HOME/.megavibe/trash"

# The mechanism check: the ask rules that gate this script must be installed.
# Either the managed settings file carries them, or every user settings file Claude
# Code could be reading does: ~/.claude/settings.json always, and the directory named
# by CLAUDE_CONFIG_DIR when that is set (an agent prefixing CLAUDE_CONFIG_DIR= must
# not be able to point this check at a settings file of its own making).
MANAGED="/Library/Application Support/ClaudeCode/managed-settings.json"
RULE_PATH='Bash(~/.megavibe/scripts/trash-empty.sh *)'
RULE_ANY='Bash(*trash-empty*)'
has_rules() {
  [ -f "$1" ] && jq -e --arg a "$RULE_PATH" --arg b "$RULE_ANY" \
    '(.permissions.ask // []) | (any(.[]; . == $a) and any(.[]; . == $b))' "$1" >/dev/null 2>&1
}
GREEN=0
has_rules "$MANAGED" && GREEN=1
if [ "$GREEN" = 0 ] && has_rules "$HOME/.claude/settings.json"; then
  GREEN=1
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]; then
    has_rules "$CLAUDE_CONFIG_DIR/settings.json" || GREEN=0
  fi
fi
[ "$GREEN" = 1 ] || die 4 "the permission prompt that gates this script is not installed; run setup.sh (it adds the permissions.ask rules)"

# --- helpers --------------------------------------------------------------------------
NOW() { date +%Y-%m-%dT%H:%M:%S%z; }
mkdir -p "$LEDGER_DIR" || die 3 "cannot create $LEDGER_DIR"
LOG="$LEDGER_DIR/empty.log"
REVIEWED="$LEDGER_DIR/reviewed.jsonl"

# One reviewed.jsonl line, shaped like trash-review.py's own: the id leaves the pending and
# droppable lists (a later "emptied" is not "droppable", and the entry is gone anyway).
record() {   # record <id> <ok:true|false> <kb> <path> <detail>
  [ -n "$1" ] || return 0
  jq -nc --arg id "$1" --arg ts "$(NOW)" --argjson ok "$2" --argjson kb "$3" --arg path "$4" --arg detail "$5" \
    '{id:$id, ts:$ts, action:"emptied", ok:$ok, kb:$kb, path:$path, detail:$detail}' >> "$REVIEWED" 2>/dev/null \
    || echo "trash-empty.sh: could not record $1 in $REVIEWED" >&2
}
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

EMPTIED=0; FAILED=0; SKIPPED=0; KB=0

# /bin/rm -rf -- on one Trash entry; counts it and records the ids it frees.
remove_entry() {   # remove_entry <entry> <id> <kb> <path>
  local e=$1 id=$2 kb opath=$4 err
  kb=$(num "$3")
  err=$(/bin/rm -rf -- "$e" 2>&1)
  if [ ! -e "$e" ] && [ ! -L "$e" ]; then
    EMPTIED=$((EMPTIED + 1)); KB=$((KB + kb))
    echo "emptied: $(basename -- "$e")"
    record "$id" true "$kb" "$opath" "emptied from the Trash"
  else
    FAILED=$((FAILED + 1))
    echo "failed:  $(basename -- "$e")${err:+ ($(printf '%s' "$err" | head -n 1))}" >&2
    record "$id" false "$kb" "$opath" "emptying failed: $(printf '%s' "$err" | head -n 1)"
  fi
}

# --- droppable mode -------------------------------------------------------------------
if [ "$MODE" = droppable ]; then
  # PYTHON*: -I ignores the environment; the two paths are set from $HOME, never inherited.
  LISTING=$(MEGAVIBE_TRASH_DIR="$TRASH" MEGAVIBE_TRASH_LEDGER_DIR="$LEDGER_DIR" python3 -I "$REVIEW" droppable --json 2>/dev/null) \
    || die 1 "could not read the list of droppable items (try: python3 $REVIEW droppable)"
  if [ -z "$LISTING" ]; then
    echo "nothing marked droppable; run the Trash review first"
    exit 0
  fi
  FS=$'\x1f'
  FIELDS=$(printf '%s\n' "$LISTING" | jq -r '[(.id // ""), ((.dev // "")|tostring), ((.ino // "")|tostring), ((.kb // 0)|tostring), (.path // ""), (.trash_path // "")] | join("\u001f")') \
    || die 1 "could not parse the list of droppable items"
  while IFS="$FS" read -r id dev ino kb opath tp; do
    [ -n "$id" ] || continue
    base=$(basename -- "$tp")
    case "$base" in ''|.|..) SKIPPED=$((SKIPPED + 1)); echo "skipped: $id (bad Trash name)" >&2; continue ;; esac
    if [ "$(cd "$(dirname -- "$tp")" 2>/dev/null && pwd -P)" != "$TRASH_PHYS" ]; then
      SKIPPED=$((SKIPPED + 1)); echo "skipped: $id (recorded outside $TRASH)" >&2; continue
    fi
    got=$(/usr/bin/stat -f '%d %i' "$tp" 2>/dev/null) || got=""     # lstat: a symlink is the entry itself
    if [ -z "$got" ]; then
      SKIPPED=$((SKIPPED + 1)); echo "skipped: $base (already gone)" >&2; continue
    fi
    if [ "$got" != "$dev $ino" ]; then
      SKIPPED=$((SKIPPED + 1)); echo "skipped: $base (replaced since it was marked droppable)" >&2; continue
    fi
    remove_entry "$tp" "$id" "$kb" "$opath"
  done <<EOF
$FIELDS
EOF
# --- --all ----------------------------------------------------------------------------
else
  # trash_path -> id for the ledger lines: the last record per id wins (a relocation line
  # updates the Trash name), and only entries that are in the Trash are looked up.
  MAP=""
  if [ -s "$LEDGER_DIR/ledger.jsonl" ]; then
    MAP=$(jq -rs 'reduce .[] as $r ({}; if ($r.id // null) != null then .[$r.id] = ((.[$r.id] // {}) + $r) else . end)
                  | to_entries[] | select(.value.trash_path != null)
                  | [.key, (.value.kb // 0 | tostring), (.value.path // ""), .value.trash_path] | join("\u001f")' \
                "$LEDGER_DIR/ledger.jsonl" 2>/dev/null) || MAP=""
  fi
  FS=$'\x1f'
  while IFS= read -r -d '' e; do
    id=""; kb=0; opath=""
    if [ -n "$MAP" ]; then
      # awk, not a bash loop: the ledger holds every item ever trashed. ENVIRON, not -v (which would eat backslashes).
      rec=$(printf '%s\n' "$MAP" | K="$e" awk -F '\037' '$4 == ENVIRON["K"] { print $1 FS $2 FS $3; exit }')
      IFS="$FS" read -r id kb opath <<EOF
$rec
EOF
    fi
    remove_entry "$e" "$id" "${kb:-0}" "$opath"
  done < <(/usr/bin/find "$TRASH" -mindepth 1 -maxdepth 1 -print0)
fi

# --- summary --------------------------------------------------------------------------
SUMMARY="mode=$MODE emptied=$EMPTIED failed=$FAILED skipped=$SKIPPED kb=$KB"
echo "$SUMMARY"
printf '%s user=%s %s\n' "$(NOW)" "$(id -un)" "$SUMMARY" >> "$LOG" 2>/dev/null || true
[ "$FAILED" = 0 ] && [ "$SKIPPED" = 0 ]
