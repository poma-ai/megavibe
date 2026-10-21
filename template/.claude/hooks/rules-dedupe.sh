#!/bin/bash
# Usage: rules-dedupe.sh [--init] <project> [template-rules-dir]
#        rules-dedupe.sh          (no arguments: a SessionStart hook on startup and
#                                  resume; project = cwd, stdin drained, note
#                                  printed as a systemMessage)
#
# Claude Code loads .claude/rules/*.md from the project AND from every parent
# directory (measured 2026-10-21 with `claude -p` in a scratch tree; it walks
# past the git root). A megavibe project inside another one (~/dev/proj under
# ~/dev) therefore loaded every megavibe rule twice: 19 projects did, 223k
# characters against the 150k instruction limit.
#
# One copy, at the top: a template rule that a megavibe parent already
# carries (same bytes) is not kept in the project. Per template rule:
#   - covered: some parent directory that is a megavibe project (.agent/events)
#     holds a readable, regular, identical copy, on the logical and on the
#     physical path of the project alike. Then the project's own copy is
#     removed, but only if it is a regular file, not tracked by git, and
#     byte-identical to the template or to that parent copy (with --init: any
#     content, since init.sh always overwrote these files); otherwise it is
#     kept (a duplicate is the safe failure).
#   - not covered: the project gets its own copy (installed if missing; with
#     --init also refreshed to the template, as init.sh always did).
# With --init, a covering parent's copy that is older than the template is
# refreshed first (init.sh would do that in the parent too), so a template
# update does not leave the parent stale and the child duplicated.
#
# Writes only <project>/.claude/rules/<template rule>, and with --init a
# megavibe parent's .claude/rules/<template rule>. No settings files, no
# scans: one stat/cmp per rule and parent. Never fails the caller (exit 0).
# A project whose parent loses its copy has none for the session in which
# this script (at session start) reinstalls it; the next session has it.
set -u

HOME="${HOME:-/nonexistent}"
INIT=0; HOOK=0
# No arguments = called as a hook: the hook command carries none, because
# init.sh quotes each registered command as one path.
if [ "$#" = 0 ]; then HOOK=1; [ -t 0 ] || cat >/dev/null 2>&1 || true; fi
[ "${1:-}" = "--init" ] && { INIT=1; shift; }
PROJECT="${1:-.}"
TEMPLATE_RULES="${2:-${MEGAVIBE_HOME:-$HOME/.megavibe}/template/.claude/rules}"

[ -d "$PROJECT/.agent" ] && [ -d "$PROJECT/.claude" ] || exit 0
[ -d "$TEMPLATE_RULES" ] || exit 0
# Never act through a linked .claude or rules directory: it belongs to another
# project (a worktree's .claude is the main checkout's), whose own run decides
# by where that project lives.
# A sentinel keeps a trailing newline that $(...) would strip (a directory
# named "child<newline>" would otherwise resolve to its sibling "child").
LOGICAL="$(cd "$PROJECT" 2>/dev/null && pwd -L && echo x)" || exit 0; LOGICAL="${LOGICAL%$'\n'x}"
PHYSICAL="$(cd "$PROJECT" 2>/dev/null && pwd -P && echo x)" || exit 0; PHYSICAL="${PHYSICAL%$'\n'x}"
# Parents are walked line by line: a path containing a newline is refused.
case "$LOGICAL$PHYSICAL" in *$'\n'*) exit 0 ;; esac
# The logical spelling must name the directory the files are in (A/link/..
# resolves differently for cd and for open()); all file work uses PHYSICAL.
[ "$LOGICAL" -ef "$PHYSICAL" ] || exit 0
OWN_DIR="$PHYSICAL/.claude/rules"
[ -L "$PHYSICAL/.claude" ] || [ -L "$OWN_DIR" ] && exit 0
HOME_P="$(cd "$HOME" 2>/dev/null && pwd -P)"

# Parents of one spelling of the path, nearest first, excluding $HOME and /:
# ~/.claude/rules is user-level and setup.sh's to clean up.
parents() {
  local d="$1"
  while :; do
    d="$(dirname "$d")"
    [ "$d" = "/" ] && return
    [ "$d" = "$HOME" ] || [ "$d" = "$HOME_P" ] && continue
    printf '%s\n' "$d"
  done
}

# A parent's rules count only through real directories: a linked .claude or
# .claude/rules belongs to some other checkout, which is never written here
# and whose loading through the link is not relied on.
parent_copy() {  # parent_copy <parent> <name>: usable copy path, or non-zero
  local c="$1/.claude/rules/$2"
  [ -d "$1/.agent/events" ] || return 1
  [ -L "$1/.claude" ] || [ -L "$1/.claude/rules" ] && return 1
  [ -f "$c" ] && [ ! -L "$c" ] && [ -r "$c" ] || return 1
  printf '%s\n' "$c"
}

# covering_copy <chain-root> <name> <template>: the nearest parent copy with
# the template's bytes, printed; non-zero if there is none.
covering_copy() {
  local a c
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    c="$(parent_copy "$a" "$2")" || continue
    cmp -s "$c" "$3" && { printf '%s\n' "$c"; return 0; }
  done < <(parents "$1")
  return 1
}

# nearest_copy <chain-root> <name>: the nearest usable parent copy, any bytes.
nearest_copy() {
  local a c
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    c="$(parent_copy "$a" "$2")" && { printf '%s\n' "$c"; return 0; }
  done < <(parents "$1")
  return 1
}

tracked() {  # tracked <file>: true unless git positively says untracked
  local d n w out found=0
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 0
  n="$d/$(basename "$1")"
  # Every repository up the tree is asked (one nested in .claude/rules does
  # not hide an outer one that tracks the file), with no inherited GIT_DIR
  # and friends pointing git somewhere else. Untracked only when there is no
  # repository at all, or every one of them answers and lists nothing; any
  # failure (a broken index, dubious ownership, a stub git) counts as tracked.
  w="$d"
  while :; do
    if [ -e "$w/.git" ]; then
      found=1
      command -v git >/dev/null 2>&1 || return 0
      out="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY \
             git -C "$w" ls-files -- "$n" 2>/dev/null)" || return 0
      [ -n "$out" ] && return 0
    fi
    [ "$w" = "/" ] && break
    w="$(dirname "$w")"
  done
  return 1
}

install() {  # install <src> <dest>: atomic copy
  local tmp
  mkdir -p "$(dirname "$2")" 2>/dev/null
  tmp="$(mktemp "$(dirname "$2")/.$(basename "$2").XXXXXX" 2>/dev/null)" || return 1
  if cp "$1" "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$2"; then return 0; fi
  rm -f "$tmp"; return 1
}

removed=0; installed=0; refreshed=0; kept=0
for tpl in "$TEMPLATE_RULES"/*.md; do
  [ -f "$tpl" ] || continue
  n="$(basename "$tpl")"
  own="$OWN_DIR/$n"

  if [ "$INIT" = 1 ]; then
    for c in "$(nearest_copy "$LOGICAL" "$n")" "$(nearest_copy "$PHYSICAL" "$n")"; do
      [ -n "$c" ] && ! cmp -s "$c" "$tpl" || continue
      tracked "$c" && continue
      install "$tpl" "$c" && refreshed=$((refreshed + 1))
    done
  fi

  # Covered only if both spellings of the path find a parent copy with the
  # template's bytes (a stale or custom parent copy is no substitute).
  cov_l="$(covering_copy "$LOGICAL" "$n" "$tpl")"; cov_p="$(covering_copy "$PHYSICAL" "$n" "$tpl")"
  covered=0
  [ -n "$cov_l" ] && [ -n "$cov_p" ] && covered=1

  if [ "$covered" = 1 ]; then
    [ -e "$own" ] || [ -L "$own" ] || continue
    # init.sh has always overwritten these files (infrastructure), so under
    # --init a stale copy goes too; at session start only identical ones do.
    if [ -f "$own" ] && [ ! -L "$own" ] && { [ "$INIT" = 1 ] || cmp -s "$own" "$tpl" || cmp -s "$own" "$cov_l"; } \
       && ! tracked "$own" && [ ! "$own" -ef "$cov_l" ] && [ ! "$own" -ef "$cov_p" ]; then
      rm -f "$own" && removed=$((removed + 1))
    else
      # Kept (tracked, linked or not a regular file). Under --init a tracked,
      # regular copy is still synced to the template, as init.sh always did.
      if [ "$INIT" = 1 ] && [ -f "$own" ] && [ ! -L "$own" ] && ! cmp -s "$own" "$tpl"; then
        install "$tpl" "$own" && installed=$((installed + 1))
      fi
      kept=$((kept + 1))
    fi
  else
    if [ ! -e "$own" ] && [ ! -L "$own" ]; then
      install "$tpl" "$own" && installed=$((installed + 1))
    elif [ "$INIT" = 1 ] && [ -f "$own" ] && [ ! -L "$own" ] && ! cmp -s "$own" "$tpl"; then
      install "$tpl" "$own" && installed=$((installed + 1))
    fi
  fi
done

msg=""
[ "$removed" -gt 0 ] && msg="${msg}${removed} removed (a megavibe parent directory carries them); "
[ "$installed" -gt 0 ] && msg="${msg}${installed} installed or updated; "
[ "$refreshed" -gt 0 ] && msg="${msg}${refreshed} parent copies refreshed to the template; "
[ "$kept" -gt 0 ] && [ "$INIT" = 1 ] && [ -n "$msg" ] && msg="${msg}${kept} kept although a parent carries them (tracked by git, linked, or not a regular file); "
[ -n "$msg" ] || exit 0
msg="rules: ${msg%; }; applies from the next session"
if [ "$HOOK" = 1 ]; then
  command -v jq >/dev/null 2>&1 && jq -n --arg m "$msg" '{systemMessage: $m}'
else
  echo "$msg"
fi
exit 0
