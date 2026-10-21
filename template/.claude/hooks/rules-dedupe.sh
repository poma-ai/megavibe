#!/bin/bash
# Usage: rules-dedupe.sh [--init] <project> [template-rules-dir]
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

INIT=0
[ "${1:-}" = "--init" ] && { INIT=1; shift; }
PROJECT="${1:-.}"
TEMPLATE_RULES="${2:-${MEGAVIBE_HOME:-$HOME/.megavibe}/template/.claude/rules}"

[ -d "$PROJECT/.agent" ] && [ -d "$PROJECT/.claude" ] || exit 0
[ -d "$TEMPLATE_RULES" ] || exit 0
OWN_DIR="$PROJECT/.claude/rules"
# Never act through a linked .claude or rules directory: it belongs to another
# project (a worktree's .claude is the main checkout's), whose own run decides
# by where that project lives.
[ -L "$PROJECT/.claude" ] || [ -L "$OWN_DIR" ] && exit 0
LOGICAL="$(cd "$PROJECT" 2>/dev/null && pwd -L)" || exit 0
PHYSICAL="$(cd "$PROJECT" 2>/dev/null && pwd -P)" || exit 0
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

# covering_copy <chain-root> <name>: the nearest parent copy usable as the
# single copy, printed; non-zero if there is none.
covering_copy() {
  local a c
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    [ -d "$a/.agent/events" ] || continue
    c="$a/.claude/rules/$2"
    [ -f "$c" ] && [ ! -L "$c" ] && [ -r "$c" ] || continue
    printf '%s\n' "$c"; return 0
  done < <(parents "$1")
  return 1
}

tracked() {  # tracked <dir> <file>: true if git tracks it (unknown = tracked)
  command -v git >/dev/null 2>&1 || return 0
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$1" ls-files --error-unmatch -- "$2" >/dev/null 2>&1
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

  cov_l="$(covering_copy "$LOGICAL" "$n")"; cov_p="$(covering_copy "$PHYSICAL" "$n")"
  if [ "$INIT" = 1 ]; then
    for c in "$cov_l" "$cov_p"; do
      [ -n "$c" ] && ! cmp -s "$c" "$tpl" || continue
      cdir="$(dirname "$(dirname "$(dirname "$c")")")"
      tracked "$cdir" ".claude/rules/$n" && continue
      install "$tpl" "$c" && refreshed=$((refreshed + 1))
    done
  fi

  # Covered only if both spellings of the path find a parent copy, and both
  # copies are the template's bytes (a stale or custom parent copy is not a
  # substitute for this project's own).
  covered=0
  if [ -n "$cov_l" ] && [ -n "$cov_p" ] && cmp -s "$cov_l" "$tpl" && cmp -s "$cov_p" "$tpl"; then
    covered=1
  fi

  if [ "$covered" = 1 ]; then
    [ -e "$own" ] || [ -L "$own" ] || continue
    # init.sh has always overwritten these files (infrastructure), so under
    # --init a stale copy goes too; at session start only identical ones do.
    if [ -f "$own" ] && [ ! -L "$own" ] && { [ "$INIT" = 1 ] || cmp -s "$own" "$tpl" || cmp -s "$own" "$cov_l"; } \
       && ! tracked "$PROJECT" ".claude/rules/$n" && [ ! "$own" -ef "$cov_l" ] && [ ! "$own" -ef "$cov_p" ]; then
      rm -f "$own" && removed=$((removed + 1))
    else
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
[ "$kept" -gt 0 ] && [ "$INIT" = 1 ] && msg="${msg}${kept} kept although a parent carries them (edited or tracked here); "
[ -n "$msg" ] && echo "rules: ${msg%; }; applies from the next session"
exit 0
