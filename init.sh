#!/bin/bash
set -euo pipefail

# Megavibe v3 — Project bootstrapper
# Usage: bash megavibe/init.sh /path/to/project
# Idempotent: always updates hooks (infrastructure), never overwrites .agent/ (user data).
#
# Prerequisite: run setup.sh first (installs tools + user-level CLAUDE.md).

if [ $# -lt 1 ]; then
  echo "Usage: bash $0 <project-path>"
  echo "Example: bash $0 /path/to/my-project"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/template"

PROJECT="${1%/}"

if [ ! -d "$PROJECT" ]; then
  echo "Error: $PROJECT is not a directory"
  exit 1
fi

# --- Check prerequisites ---
if ! command -v jq &>/dev/null; then
  echo "Warning: jq is not installed. Hooks require jq to function."
  echo "  Run 'bash megavibe/setup.sh' first, or install jq manually."
  echo "  Continuing anyway (hooks will be inert until jq is available)."
  echo ""
fi

if [ ! -f "$HOME/.claude/CLAUDE.md" ] || ! grep -q "megavibe-v3" "$HOME/.claude/CLAUDE.md" 2>/dev/null; then
  echo "Note: Megavibe protocol not found in ~/.claude/CLAUDE.md."
  echo "  Run 'bash megavibe/setup.sh' to install it."
  echo ""
fi

echo "Bootstrapping Megavibe in: $PROJECT"

# --- Create directories ---
mkdir -p "$PROJECT/.agent/RESEARCH"
mkdir -p "$PROJECT/.agent/ASSETS"
mkdir -p "$PROJECT/.agent/PLANS"
mkdir -p "$PROJECT/.agent/LOGS/transcripts"
mkdir -p "$PROJECT/.agent/sessions"
mkdir -p "$PROJECT/.claude/hooks"
mkdir -p "$PROJECT/.claude/rules"

# ─── Atomic file install ─────────────────────────────────────────────
#
# Never `cp` onto a path a live process may be executing or reading. `cp` opens
# the destination O_TRUNC on the same inode, so a running bash — which reads
# scripts lazily by byte offset — can resume mid-token, and a hook caught
# mid-read sees a truncated file. Write to a temp beside the destination and
# rename(): the swap is atomic and every open fd keeps the intact old inode.
#
# Symlinked destinations are resolved first, so the target is replaced and the
# link survives — matching what plain `cp` did.

# Mode of a file, portably: BSD stat and GNU stat disagree on the flag.
stat_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

# Resolve a path through its symlink chain. POSIX only: BSD readlink has no -f.
# Fails past 40 hops rather than returning a still-symlinked path, which the
# caller would then replace instead of following.
resolve_link() {
  local p="$1" link n=0
  while [ -L "$p" ]; do
    if [ "$n" -ge 40 ]; then return 1; fi
    link="$(readlink "$p")"
    case "$link" in
      /*) p="$link" ;;
      *)  p="$(dirname "$p")/$link" ;;
    esac
    n=$((n + 1))
  done
  printf '%s\n' "$p"
}

# atomic_install SRC DST [MODE]
#
# MODE, when given, is forced. Pass it for anything that must be executable to
# work — `cp` onto an existing file kept the *destination's* mode, so a
# repo-side mode slip stayed invisible on upgrades and only broke fresh
# installs. When MODE is omitted the destination's current mode is preserved
# (falling back to the source's when creating), which is exactly what plain
# `cp` did: user files never get silently widened.
atomic_install() {
  local src="$1" dst="$2" mode="${3:-}" tmp dstdir
  if [ ! -f "$src" ]; then return 1; fi
  dst="$(resolve_link "$dst")" || return 1
  # `cp SRC DIR` copies into the directory; renaming would hide the temp inside
  # it and leave the intended name untouched. Refuse rather than half-work.
  if [ -d "$dst" ]; then return 1; fi
  dstdir="$(dirname "$dst")"
  if [ ! -d "$dstdir" ]; then return 1; fi
  tmp="$(mktemp "$dstdir/.$(basename "$dst").XXXXXX")" || return 1
  if ! cp "$src" "$tmp"; then rm -f "$tmp"; return 1; fi
  if [ -z "$mode" ]; then
    if [ -e "$dst" ]; then mode="$(stat_mode "$dst" || true)"; else mode="$(stat_mode "$src" || true)"; fi
  fi
  # A forced mode that cannot be applied is a failed install, not a warning:
  # a 0644 hook is silently dead.
  if [ -n "$mode" ] && ! chmod "$mode" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv -f "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
  return 0
}

# atomic_install_dir SRC DST
#
# Replaces a whole tree with two renames instead of `rm -rf` plus a
# multi-second `cp -R`, which leaves the tree missing or half-populated for
# anything reading it concurrently. NOT atomic — POSIX rename() cannot swap two
# non-empty directories — so a reader can still catch a sub-millisecond window
# where DST does not exist. That is strictly better than the old window, not a
# guarantee of absence.
atomic_install_dir() {
  local src="$1" dst="$2" tmp old dstdir
  if [ ! -d "$src" ]; then return 1; fi
  dst="$(resolve_link "$dst")" || return 1
  dstdir="$(dirname "$dst")"
  if [ ! -d "$dstdir" ]; then return 1; fi
  tmp="$(mktemp -d "$dstdir/.$(basename "$dst").XXXXXX")" || return 1
  old="$tmp.old"
  if ! cp -R "$src/." "$tmp/"; then rm -rf "$tmp"; return 1; fi
  if [ -e "$dst" ] && ! mv "$dst" "$old"; then rm -rf "$tmp"; return 1; fi
  if ! mv "$tmp" "$dst"; then
    # Restoring is the last line of defence; if it fails the tree is gone and
    # the user needs the path, not a silent return.
    if [ -e "$old" ] && ! mv "$old" "$dst"; then
      echo "ERROR: could not restore $dst — the previous tree is at $old" >&2
    fi
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$old"
  return 0
}

# --- Helper: copy only if file doesn't exist (for user data) ---
copy_if_missing() {
  local src="$1"
  local dst="$2"
  if [ -f "$dst" ]; then
    echo "  skip: $dst (already exists)"
  else
    cp "$src" "$dst"
    echo "  created: $dst"
  fi
}

# --- Merge hooks into .claude/settings.json (first time only) ---
SETTINGS="$PROJECT/.claude/settings.json"
TEMPLATE_SETTINGS="$TEMPLATE_DIR/.claude/settings.json"

if [ -f "$SETTINGS" ]; then
  if command -v jq &>/dev/null; then
    # Always sync hooks from template (infrastructure — matches hook script overwrite policy)
    # Preserves any non-hooks keys (permissions, etc.) from existing settings
    # plansDirectory: default it fleet-wide (set-if-absent) so plans persist into
    # .agent/PLANS instead of the user-global ~/.claude/plans/, but never clobber a
    # value the project set deliberately. Relative path resolves to project root.
    # Rewrite relative hook paths to absolute (prevents breakage when session cd's to subdirectory)
    # `pwd -P` resolves symlinks. Bare `pwd` would record the logical (symlink)
    # path — if the symlink is later removed or its target moves, the hardcoded
    # hook paths in settings.json break with "No such file or directory" and the
    # session cannot run any tool. Always anchor to the canonical filesystem path.
    ABS_PROJECT=$(cd "$PROJECT" && pwd -P)
    # Quote hook command paths to handle spaces in directory names (e.g., "POMA AI")
    # Shell receives: "/path/with spaces/.claude/hooks/script.sh" (quoted = single arg)
    jq -s '.[0] as $p | .[1] as $t | ($p * {hooks: $t.hooks}) | .plansDirectory = ($p.plansDirectory // $t.plansDirectory)' "$SETTINGS" "$TEMPLATE_SETTINGS" \
      | jq --arg root "$ABS_PROJECT/" 'walk(if type == "object" and .command? and (.command | startswith(".claude/hooks/")) then .command = "\"" + $root + .command + "\"" else . end)' \
      > "${SETTINGS}.tmp"
    atomic_install "${SETTINGS}.tmp" "$SETTINGS"
    rm -f "${SETTINGS}.tmp"
    echo "  synced: .claude/settings.json (hooks)"
  else
    echo "  warning: .claude/settings.json exists but jq is not available to sync hooks"
    echo "           Megavibe hooks saved to .claude/settings.megavibe.json for manual merge"
    atomic_install "$TEMPLATE_SETTINGS" "$PROJECT/.claude/settings.megavibe.json"
  fi
else
  # `pwd -P` for the same reason as the sync branch above: a logical path
  # bakes a symlink into settings.json and breaks every hook if it moves.
  ABS_PROJECT=$(cd "$PROJECT" && pwd -P)
  jq --arg root "$ABS_PROJECT/" 'walk(if type == "object" and .command? and (.command | startswith(".claude/hooks/")) then .command = "\"" + $root + .command + "\"" else . end)' \
    "$TEMPLATE_SETTINGS" > "$SETTINGS"
  echo "  created: $SETTINGS"
fi

# --- Hook scripts (infrastructure — always overwrite) ---
HOOKS_MISSING=0
for hook in log-tool-event.sh block-dangerous-bash.sh block-stray-working-context.sh nudge-native-tools.sh nudge-quiet-bash.sh after-edit.sh reindex-agent.sh on-compact.sh on-pre-compact.sh on-session-start.sh on-session-end.sh start-context-watcher.sh revive-watcher.sh augment-search.sh resize-image.sh read-delta.sh truncate-verbose-bash.sh; do
  if [ -f "$TEMPLATE_DIR/.claude/hooks/$hook" ]; then
    atomic_install "$TEMPLATE_DIR/.claude/hooks/$hook" "$PROJECT/.claude/hooks/$hook" 755
    echo "  synced: .claude/hooks/$hook"
  else
    echo "  skip: .claude/hooks/$hook (missing from template)"
    HOOKS_MISSING=$((HOOKS_MISSING + 1))
  fi
done
if [ "$HOOKS_MISSING" -gt 0 ]; then
  echo "" >&2
  echo "  ⚠  WARNING: $HOOKS_MISSING hook(s) missing from $TEMPLATE_DIR/.claude/hooks/" >&2
  echo "     Your ~/.megavibe/template/ is likely stale — the wrapper's template" >&2
  echo "     sync only runs when CLAUDE.md changes, not hooks/settings.json." >&2
  echo "     Immediate fix: rm -rf ~/.megavibe/template && \\" >&2
  echo "                    cp -R <megavibe-repo>/template ~/.megavibe/template" >&2
  echo "     Durable fix: update megavibe wrapper (post-Apr-9 uses diff -rq)." >&2
  echo "" >&2
fi

# --- Rule files (infrastructure — always overwrite) ---
for rule in "$TEMPLATE_DIR/.claude/rules/"*.md; do
  [ -f "$rule" ] || continue
  atomic_install "$rule" "$PROJECT/.claude/rules/$(basename "$rule")"
  echo "  synced: .claude/rules/$(basename "$rule")"
done

# --- verify.sh example (opt-in — inert until the user copies it into place) ---
if [ -f "$TEMPLATE_DIR/.claude/verify.sh.example" ]; then
  atomic_install "$TEMPLATE_DIR/.claude/verify.sh.example" "$PROJECT/.claude/verify.sh.example" 755
  echo "  synced: .claude/verify.sh.example (opt-in; cp to verify.sh to enable)"
fi

# --- Skills (infrastructure — always overwrite) ---
if [ -d "$TEMPLATE_DIR/.claude/skills" ]; then
  for skill_dir in "$TEMPLATE_DIR/.claude/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    mkdir -p "$PROJECT/.claude/skills/$skill_name"
    skill_failed=0
    for skill_file in "$skill_dir"*; do
      [ -f "$skill_file" ] || continue
      atomic_install "$skill_file" "$PROJECT/.claude/skills/$skill_name/$(basename "$skill_file")" \
        || skill_failed=$((skill_failed + 1))
    done
    if [ "$skill_failed" -gt 0 ]; then
      echo "  warning: .claude/skills/$skill_name/ — $skill_failed file(s) failed to install" >&2
    else
      echo "  synced: .claude/skills/$skill_name/"
    fi
  done
fi

# --- Agents (infrastructure — always overwrite) ---
if [ -d "$TEMPLATE_DIR/.claude/agents" ]; then
  mkdir -p "$PROJECT/.claude/agents"
  for agent in "$TEMPLATE_DIR/.claude/agents/"*.md; do
    [ -f "$agent" ] || continue
    atomic_install "$agent" "$PROJECT/.claude/agents/$(basename "$agent")"
    echo "  synced: .claude/agents/$(basename "$agent")"
  done
fi

# --- .agent starter files (user data — never overwrite) ---
# .gitignore is infrastructure (like hooks) — always sync from template
atomic_install "$TEMPLATE_DIR/.agent/.gitignore" "$PROJECT/.agent/.gitignore"
echo "  synced: .agent/.gitignore"
copy_if_missing "$TEMPLATE_DIR/.agent/FULL_CONTEXT.md" "$PROJECT/.agent/FULL_CONTEXT.md"
copy_if_missing "$TEMPLATE_DIR/.agent/DECISIONS.md" "$PROJECT/.agent/DECISIONS.md"
copy_if_missing "$TEMPLATE_DIR/.agent/TASKS.md" "$PROJECT/.agent/TASKS.md"
copy_if_missing "$TEMPLATE_DIR/.agent/LESSONS.md" "$PROJECT/.agent/LESSONS.md"
# WORKING_CONTEXT.md is now session-scoped (created at .agent/sessions/{sid}/ by hooks)

# --- CLAUDE.local.md — personal overrides (gitignored) ---
if [ ! -f "$PROJECT/CLAUDE.local.md" ]; then
  touch "$PROJECT/CLAUDE.local.md"
  echo "  created: CLAUDE.local.md (personal overrides, gitignored)"
else
  echo "  skip: CLAUDE.local.md (already exists)"
fi

# Add megavibe entries to .gitignore (idempotent)
GITIGNORE_ENTRIES=("CLAUDE.local.md" "events.jsonl")
# Only add .claude/ subpaths if .claude/ isn't already gitignored as a whole
CLAUDE_SUBPATH_ENTRIES=(".claude/hooks/" ".claude/rules/" ".claude/skills/" ".claude/agents/" ".claude/settings.json")
if [ -f "$PROJECT/.gitignore" ] || [ -d "$PROJECT/.git" ] || [ -f "$PROJECT/.git" ]; then
  [ -f "$PROJECT/.gitignore" ] || touch "$PROJECT/.gitignore"
  # If .claude/ is already ignored, skip all subpath entries
  if ! grep -qxF '.claude/' "$PROJECT/.gitignore" && ! grep -qxF '.claude' "$PROJECT/.gitignore"; then
    GITIGNORE_ENTRIES+=("${CLAUDE_SUBPATH_ENTRIES[@]}")
  fi
  for entry in "${GITIGNORE_ENTRIES[@]}"; do
    if ! grep -qF "$entry" "$PROJECT/.gitignore"; then
      echo "$entry" >> "$PROJECT/.gitignore"
      echo "  added $entry to .gitignore"
    fi
  done
fi

# .gitkeep files for empty dirs
touch "$PROJECT/.agent/RESEARCH/.gitkeep"
touch "$PROJECT/.agent/ASSETS/.gitkeep"
touch "$PROJECT/.agent/PLANS/.gitkeep"
touch "$PROJECT/.agent/LOGS/.gitkeep"
touch "$PROJECT/.agent/sessions/.gitkeep"

# --- Make hooks executable + clear macOS quarantine (handles git clone / curl|bash) ---
chmod +x "$PROJECT/.claude/hooks/"*.sh 2>/dev/null || true
# macOS quarantine xattr blocks execution of downloaded scripts
xattr -rd com.apple.quarantine "$PROJECT/.claude/hooks/" 2>/dev/null || true

# --- One-time poma-memory index heal (purge stale / cross-project-contaminated db) ---
# Older installs could leave .agent/.poma-memory.db indexed against a prior checkout,
# or polluted by a parent-dir `poma-memory index` that swept sibling sub-projects into
# one db. `poma-memory index` is additive (mtime-gated) with no --rebuild flag, so that
# bad data never clears itself. Run ONCE per project (marker-gated) to delete the db and
# rebuild it scoped to THIS .agent/ only — never a parent dir (that caused the pollution).
# Safe: marker-gated (idempotent), no-op without poma-memory, never aborts init.
HEAL_MARKER="$PROJECT/.agent/LOGS/.poma-heal-v1"
if command -v poma-memory &>/dev/null && [ ! -f "$HEAL_MARKER" ]; then
  echo "  healing poma-memory index (one-time clean rebuild)..."
  mkdir -p "$PROJECT/.agent/LOGS"
  DB="$PROJECT/.agent/.poma-memory.db"
  BAK="${DB}.heal-bak"
  # Move the (possibly contaminated) db aside rather than deleting outright, so a
  # failed reindex leaves a stale-but-functional index instead of an empty one.
  rm -f "$BAK"
  if [ -f "$DB" ]; then mv "$DB" "$BAK"; fi
  rm -f "${DB}-shm" "${DB}-wal"
  if ( cd "$PROJECT" && poma-memory index .agent/ >/dev/null 2>&1 ); then
    rm -f "$BAK"
    echo "v1 healed $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$HEAL_MARKER" 2>/dev/null || true
    echo "  healed: .agent/.poma-memory.db (clean per-project rebuild)"
  else
    # Reindex failed (missing deps, transient SQLite lock, OOM). Restore the prior
    # index so search keeps working; leave the marker absent so init retries later.
    rm -f "$DB" "${DB}-shm" "${DB}-wal"
    if [ -f "$BAK" ]; then mv "$BAK" "$DB"; fi
    echo "  note: poma-memory reindex failed — kept prior index. Retry: (cd $PROJECT && poma-memory index .agent/)" >&2
  fi
fi

# --- Trust this directory in Gemini CLI (if installed) ---
# Gemini CLI's trust gate refuses @file references in untrusted dirs, which
# silently degrades Gemini MCP quality. Trust is per-folder (TRUST_FOLDER),
# matching Claude Code's per-dir trust model. Skip silently if Gemini isn't
# installed (no ~/.gemini directory) — don't presume installation.
if [ -d "$HOME/.gemini" ] && command -v jq &>/dev/null; then
  GEMINI_TRUST="$HOME/.gemini/trustedFolders.json"
  ABS_TARGET="$(cd "$PROJECT" && pwd -P)"
  [ -f "$GEMINI_TRUST" ] || echo '{}' > "$GEMINI_TRUST"
  if jq -e --arg p "$ABS_TARGET" 'has($p)' "$GEMINI_TRUST" >/dev/null; then
    echo "  skip: Gemini CLI already trusts $ABS_TARGET"
  else
    tmp="$(mktemp)"
    jq --arg p "$ABS_TARGET" '. + {($p): "TRUST_FOLDER"}' "$GEMINI_TRUST" > "$tmp"
    mv "$tmp" "$GEMINI_TRUST"
    echo "  trusted: $ABS_TARGET in ~/.gemini/trustedFolders.json"
  fi
fi

echo ""
echo "Done. Megavibe is ready in: $PROJECT"
echo ""
echo "Next steps:"
echo "  cd $PROJECT && claude"
echo ""
