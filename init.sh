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
mkdir -p "$PROJECT/.agent/LOGS/transcripts"
mkdir -p "$PROJECT/.agent/sessions"
mkdir -p "$PROJECT/.claude/hooks"
mkdir -p "$PROJECT/.claude/rules"

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
    # Rewrite relative hook paths to absolute (prevents breakage when session cd's to subdirectory)
    ABS_PROJECT=$(cd "$PROJECT" && pwd)
    # Quote hook command paths to handle spaces in directory names (e.g., "POMA AI")
    # Shell receives: "/path/with spaces/.claude/hooks/script.sh" (quoted = single arg)
    jq -s '.[0] * {hooks: .[1].hooks}' "$SETTINGS" "$TEMPLATE_SETTINGS" \
      | jq --arg root "$ABS_PROJECT/" 'walk(if type == "object" and .command? and (.command | startswith(".claude/hooks/")) then .command = "\"" + $root + .command + "\"" else . end)' \
      > "${SETTINGS}.tmp"
    mv "${SETTINGS}.tmp" "$SETTINGS"
    echo "  synced: .claude/settings.json (hooks)"
  else
    echo "  warning: .claude/settings.json exists but jq is not available to sync hooks"
    echo "           Megavibe hooks saved to .claude/settings.megavibe.json for manual merge"
    cp "$TEMPLATE_SETTINGS" "$PROJECT/.claude/settings.megavibe.json"
  fi
else
  ABS_PROJECT=$(cd "$PROJECT" && pwd)
  jq --arg root "$ABS_PROJECT/" 'walk(if type == "object" and .command? and (.command | startswith(".claude/hooks/")) then .command = "\"" + $root + .command + "\"" else . end)' \
    "$TEMPLATE_SETTINGS" > "$SETTINGS"
  echo "  created: $SETTINGS"
fi

# --- Hook scripts (infrastructure — always overwrite) ---
for hook in log-tool-event.sh block-dangerous-bash.sh after-edit.sh on-compact.sh on-pre-compact.sh on-session-start.sh augment-search.sh resize-image.sh; do
  cp "$TEMPLATE_DIR/.claude/hooks/$hook" "$PROJECT/.claude/hooks/$hook"
  echo "  synced: .claude/hooks/$hook"
done

# --- Rule files (infrastructure — always overwrite) ---
for rule in "$TEMPLATE_DIR/.claude/rules/"*.md; do
  [ -f "$rule" ] || continue
  cp "$rule" "$PROJECT/.claude/rules/$(basename "$rule")"
  echo "  synced: .claude/rules/$(basename "$rule")"
done

# --- Skills (infrastructure — always overwrite) ---
if [ -d "$TEMPLATE_DIR/.claude/skills" ]; then
  for skill_dir in "$TEMPLATE_DIR/.claude/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    mkdir -p "$PROJECT/.claude/skills/$skill_name"
    cp "$skill_dir"* "$PROJECT/.claude/skills/$skill_name/" 2>/dev/null || true
    echo "  synced: .claude/skills/$skill_name/"
  done
fi

# --- Agents (infrastructure — always overwrite) ---
if [ -d "$TEMPLATE_DIR/.claude/agents" ]; then
  mkdir -p "$PROJECT/.claude/agents"
  for agent in "$TEMPLATE_DIR/.claude/agents/"*.md; do
    [ -f "$agent" ] || continue
    cp "$agent" "$PROJECT/.claude/agents/$(basename "$agent")"
    echo "  synced: .claude/agents/$(basename "$agent")"
  done
fi

# --- .agent starter files (user data — never overwrite) ---
# .gitignore is infrastructure (like hooks) — always sync from template
cp "$TEMPLATE_DIR/.agent/.gitignore" "$PROJECT/.agent/.gitignore"
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
touch "$PROJECT/.agent/LOGS/.gitkeep"
touch "$PROJECT/.agent/sessions/.gitkeep"

# --- Make hooks executable + clear macOS quarantine (handles git clone / curl|bash) ---
chmod +x "$PROJECT/.claude/hooks/"*.sh 2>/dev/null || true
# macOS quarantine xattr blocks execution of downloaded scripts
xattr -rd com.apple.quarantine "$PROJECT/.claude/hooks/" 2>/dev/null || true

echo ""
echo "Done. Megavibe is ready in: $PROJECT"
echo ""
echo "Next steps:"
echo "  cd $PROJECT && claude"
echo ""
