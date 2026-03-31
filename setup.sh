#!/bin/bash
set -euo pipefail

# Megavibe v3 — Machine setup
# Usage: bash megavibe/setup.sh
# Idempotent: skips tools/MCP already installed, always updates protocol + statusline.
# Supports: macOS, Linux, Windows (Git Bash / WSL). Requires Node.js (npm/npx).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

info()  { echo -e "${BOLD}$1${RESET}"; }
ok()    { echo -e "  ${GREEN}✓${RESET} $1"; }
skip()  { echo -e "  ${YELLOW}skip${RESET} $1 (already installed)"; }
warn()  { echo -e "  ${YELLOW}!${RESET} $1"; }
fail()  { echo -e "  ${RED}✗${RESET} $1"; }

NEEDS_LOGIN=()

# ─── npm global prefix (Linux/WSL: avoid EACCES on /usr/local) ─────

if [[ "$(uname -s)" != "Darwin" ]] && [[ "$(id -u 2>/dev/null || echo 1000)" != "0" ]]; then
  NPM_PREFIX="${HOME}/.local"
  if [[ "$(npm config get prefix 2>/dev/null)" == /usr* ]]; then
    npm config set prefix "$NPM_PREFIX"
    mkdir -p "$NPM_PREFIX/bin"
    # Ensure ~/.local/bin is on PATH for this session
    case ":$PATH:" in
      *":$NPM_PREFIX/bin:"*) ;;
      *) export PATH="$NPM_PREFIX/bin:$PATH" ;;
    esac
  fi
fi

# ─── Python detection (Windows Git Bash has 'python' not 'python3') ──

PYTHON=""
for cmd in python3 python; do
  if command -v "$cmd" &>/dev/null && "$cmd" -c "import sys; assert sys.version_info >= (3, 8)" &>/dev/null; then
    PYTHON="$cmd"
    break
  fi
done

if [ -z "$PYTHON" ]; then
  warn "Python 3.8+ not found — poma-memory and Telegram bot will be unavailable"
fi

# ─── 0. Define installation mode ────────────────────────────────────

NONINTERACTIVE_AUTO=0
if [ "$#" -gt 0 ]; then
  case "$1" in
    --auto-install)
      NONINTERACTIVE_AUTO=1
      ;;
  esac
fi

if [ "$NONINTERACTIVE_AUTO" -eq 0 ]; then
  echo "  How do you want to install Megavibe?"
  echo "  1. Automatic (default) - all supported tools will be installed"
  echo "  2. Custom"
  read -p "  Enter your choice: " NONINTERACTIVE_AUTO
  case "$NONINTERACTIVE_AUTO" in
    1) NONINTERACTIVE_AUTO=1 ;;
    2) NONINTERACTIVE_AUTO=0 ;;
    *) echo "  Invalid choice. Please enter 1 or 2." && exit 1 ;;
  esac
fi

# ─── 1. Install tools ───────────────────────────────────────────────

info "1) Installing tools"

# Claude Code
claude_install() {
  if command -v claude &>/dev/null; then
    skip "Claude Code ($(claude --version 2>/dev/null || echo 'installed'))"
  else
    echo "  Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    ok "Claude Code"
    NEEDS_LOGIN+=("claude")
  fi
}

# Codex CLI
CODEX_INSTALLED=0
codex_install() {
  CODEX_INSTALLED=1
  if command -v codex &>/dev/null; then
    skip "Codex CLI"
  else
    echo "  Installing Codex CLI..."
    npm i -g @openai/codex
    ok "Codex CLI"
    NEEDS_LOGIN+=("codex")
  fi
}

# Gemini CLI
GEMINI_INSTALLED=0
gemini_install() {
  GEMINI_INSTALLED=1
  if command -v gemini &>/dev/null; then
    skip "Gemini CLI"
  else
    echo "  Installing Gemini CLI..."
    npm i -g @google/gemini-cli
    ok "Gemini CLI"
    NEEDS_LOGIN+=("gemini")
  fi
}

# jq (required by hooks)
jq_install() {
  if command -v jq &>/dev/null; then
    skip "jq"
  else
    echo "  Installing jq..."
    if command -v brew &>/dev/null; then
      brew install jq
    elif command -v apt-get &>/dev/null; then
      sudo apt-get update -qq && sudo apt-get install -y -qq jq
    elif command -v dnf &>/dev/null; then
      sudo dnf install -y -q jq
    elif command -v pacman &>/dev/null; then
      sudo pacman -S --noconfirm jq
    elif command -v apk &>/dev/null; then
      sudo apk add jq
    elif command -v winget &>/dev/null; then
      winget install --accept-source-agreements jqlang.jq 2>/dev/null || true
    elif command -v choco &>/dev/null; then
      choco install -y jq
    else
      fail "jq not found. Install it manually: https://jqlang.github.io/jq/download/"
      exit 1
    fi
    ok "jq"
  fi
}

# Ask before installing CLIs when missing (unless non-interactive --auto-install or no TTY)
should_install_codex() {
  if [ "$NONINTERACTIVE_AUTO" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    return 0
  fi
  read -r -p "  Install Codex CLI? [Y/n] " _codex_ans
  case "${_codex_ans:-y}" in
    [nN]|[nN][oO]) return 1 ;;
    *) return 0 ;;
  esac
}

should_install_gemini() {
  if [ "$NONINTERACTIVE_AUTO" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    return 0
  fi
  read -r -p "  Install Gemini CLI? [Y/n] " _gemini_ans
  case "${_gemini_ans:-y}" in
    [nN]|[nN][oO]) return 1 ;;
    *) return 0 ;;
  esac
}

claude_install
jq_install

# Install Codex CLI when it is missing (unless non-interactive --auto-install or no TTY)
if command -v codex &>/dev/null || should_install_codex; then
  codex_install
else
  skip "Codex CLI (user skipped)"
fi
if command -v gemini &>/dev/null || should_install_gemini; then
  gemini_install
else
  skip "Gemini CLI (user skipped)"
fi


# ─── 2. First-time logins ───────────────────────────────────────────

if [ ${#NEEDS_LOGIN[@]} -gt 0 ]; then
  echo ""
  info "2) First-time logins"
  echo ""
  echo "  These tools were just installed. To activate them, open a NEW"
  echo "  terminal window and run each command — it will open your browser"
  echo "  to sign in:"
  echo ""
  for tool in "${NEEDS_LOGIN[@]}"; do
    case "$tool" in
      claude) echo "    claude          (requires Claude subscription)" ;;
      codex)  echo "    codex           (optional — uses your ChatGPT account)" ;;
      gemini) echo "    gemini          (optional — uses your Google account)" ;;
      *)      echo "    $tool" ;;
    esac
  done
  echo ""
  echo "  You can do this now or later — megavibe works with just Claude."
  echo ""
  read -p "  Press Enter to continue... "
else
  echo ""
  info "2) Logins — all tools already installed, skipping"
fi

# ─── 3. Deploy megavibe to ~/.megavibe/ + install CLI ─────────────

echo ""
info "3) Deploying megavibe"

MEGAVIBE_HOME="$HOME/.megavibe"
mkdir -p "$MEGAVIBE_HOME"

# Copy core files to ~/.megavibe/ (always overwrite — infrastructure)
cp "$SCRIPT_DIR/setup.sh" "$MEGAVIBE_HOME/setup.sh"
cp "$SCRIPT_DIR/init.sh" "$MEGAVIBE_HOME/init.sh"
# Save detected Python command so hooks and MCP can use it
if [ -n "$PYTHON" ]; then
  echo "$PYTHON" > "$MEGAVIBE_HOME/python-cmd"
fi

# Install poma-memory from PyPI (preferred) or fall back to bundled poma_memory.py
if [ -n "$PYTHON" ]; then
  if $PYTHON -c "import poma_memory" &>/dev/null; then
    skip "poma-memory (pip, already installed)"
  else
    echo "  Installing poma-memory from PyPI..."
    $PYTHON -m pip install --user --quiet "poma-memory[semantic]" 2>/dev/null \
      || $PYTHON -m pip install --quiet "poma-memory[semantic]" 2>/dev/null
    if $PYTHON -c "import poma_memory" &>/dev/null; then
      ok "poma-memory (pip)"
    else
      # Fallback: bundled single-file poma_memory.py (works without pip)
      if [ -f "$SCRIPT_DIR/poma_memory.py" ]; then
        cp "$SCRIPT_DIR/poma_memory.py" "$MEGAVIBE_HOME/poma_memory.py"
        # Install minimal deps for bundled version
        $PYTHON -m pip install --user --quiet numpy model2vec 2>/dev/null \
          || $PYTHON -m pip install --quiet numpy model2vec 2>/dev/null \
          || warn "Could not install poma-memory deps — search will be unavailable"
        ok "poma-memory (bundled fallback)"
      else
        warn "poma-memory unavailable — search will be disabled"
      fi
    fi
  fi
elif [ -f "$SCRIPT_DIR/poma_memory.py" ]; then
  cp "$SCRIPT_DIR/poma_memory.py" "$MEGAVIBE_HOME/poma_memory.py"
fi

# Deploy Telegram bot (optional — only used if MEGAVIBE_TELEGRAM_TOKEN is set)
telegram_bot_install() {
  if [ -f "$SCRIPT_DIR/telegram-bot.py" ]; then
    cp "$SCRIPT_DIR/telegram-bot.py" "$MEGAVIBE_HOME/telegram-bot.py"
    ok "telegram-bot.py deployed"

    # Install python-telegram-bot if not already present (+ httpx for voice I/O)
    if [ -n "$PYTHON" ]; then
      if $PYTHON -c "import telegram" &>/dev/null; then
        skip "python-telegram-bot"
      else
        echo "  Installing python-telegram-bot (for Megavibe Remote)..."
        $PYTHON -m pip install --user --quiet "python-telegram-bot>=21" httpx 2>/dev/null \
          || $PYTHON -m pip install --quiet "python-telegram-bot>=21" httpx 2>/dev/null \
          || warn "Could not install python-telegram-bot — remote will be unavailable"
        if $PYTHON -c "import telegram" &>/dev/null; then
          ok "python-telegram-bot + httpx"
        fi
      fi
    fi
  fi
}

should_install_telegram() {
  if [ "$NONINTERACTIVE_AUTO" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    return 0
  fi
  read -r -p "  Install Telegram bot? [Y/n] " _telegram_ans
  case "${_telegram_ans:-y}" in
    [nN]|[nN][oO]) return 1 ;;
    *) return 0 ;;
  esac
}

TELEGRAM_INSTALLED=0
if should_install_telegram; then
  telegram_bot_install
  TELEGRAM_INSTALLED=1
else
  skip "Telegram bot (user skipped)"
fi

# 
rm -rf "$MEGAVIBE_HOME/template"
cp -R "$SCRIPT_DIR/template" "$MEGAVIBE_HOME/template"
ok "~/.megavibe/ synced"


# Initialize personal assistant project (standard megavibe dir)
PERSONAL_DIR="$MEGAVIBE_HOME/personal"
if [ ! -d "$PERSONAL_DIR/.agent" ]; then
  mkdir -p "$PERSONAL_DIR/.agent"
  cat > "$PERSONAL_DIR/CLAUDE.md" << 'PERSONAL_EOF'
# Personal Assistant

You are the user's personal assistant, responding via Telegram (often from Apple Watch).

## Rules
- Answer the question directly. No preamble, no status reports, no tool availability announcements.
- NEVER say things like "Gemini is available" or report which tools/MCP servers are connected. Just answer.
- Keep responses concise but complete. The user reads on a small screen (Watch/phone).
- Plain text preferred. No code blocks, no markdown tables unless specifically asked.
- Use the user's language (German if they write in German, English if English).

## What you do
- Answer general questions (weather, facts, calculations, advice)
- Remember personal preferences, goals, and context from .agent/ files
- Help with life admin (scheduling, reminders, planning)
- When asked about a specific coding project, mention that the user should ask about it by name to route to that project

## Context files
- .agent/FULL_CONTEXT.md — ongoing personal context log
- .agent/LESSONS.md — personal preferences and patterns
- .agent/DECISIONS.md — life decisions and rationale
PERSONAL_EOF
  echo "# Personal Context Log" > "$PERSONAL_DIR/.agent/FULL_CONTEXT.md"
  echo "# Personal Decisions" > "$PERSONAL_DIR/.agent/DECISIONS.md"
  echo "# Personal Preferences" > "$PERSONAL_DIR/.agent/LESSONS.md"
  ok "~/.megavibe/personal/ (personal assistant project)"
else
  skip "~/.megavibe/personal/ (already exists)"
fi

# Initialize projects registry
if [ ! -f "$MEGAVIBE_HOME/projects.json" ]; then
  echo '{}' > "$MEGAVIBE_HOME/projects.json"
  ok "~/.megavibe/projects.json (project registry)"
else
  skip "~/.megavibe/projects.json (already exists)"
fi

# Remember source repo so the deployed CLI can sync from it later
echo "$SCRIPT_DIR" > "$MEGAVIBE_HOME/source-repo"

# Install CLI wrapper to ~/.local/bin/ (symlink to ~/.megavibe/ copy)
CLI_DIR="$HOME/.local/bin"
mkdir -p "$CLI_DIR"
# Copy to ~/.megavibe/ first (already done above via setup.sh copy)
cp "$SCRIPT_DIR/megavibe" "$MEGAVIBE_HOME/megavibe"
chmod +x "$MEGAVIBE_HOME/megavibe"
# Symlink from ~/.local/bin/ → ~/.megavibe/ so updates propagate automatically
ln -sf "$MEGAVIBE_HOME/megavibe" "$CLI_DIR/megavibe"
ok "megavibe CLI installed to $CLI_DIR/megavibe → ~/.megavibe/megavibe"

# Warn if ~/.local/bin is not in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$CLI_DIR"; then
  warn "$CLI_DIR is not in your PATH"
  SHELL_NAME=$(basename "${SHELL:-/bin/bash}")
  case "$SHELL_NAME" in
    zsh)  PROFILE_FILE="~/.zshrc" ;;
    bash) PROFILE_FILE="~/.bashrc" ;;
    fish) PROFILE_FILE="~/.config/fish/config.fish" ;;
    *)    PROFILE_FILE="~/.bashrc or ~/.profile" ;;
  esac
  echo "    Add this to your shell profile ($PROFILE_FILE):"
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

# ─── 4. Install/update Megavibe protocol in user-level CLAUDE.md ────

echo ""
info "4) Installing Megavibe protocol"

CLAUDE_MD="$HOME/.claude/CLAUDE.md"
MARKER="<!-- megavibe-v3 -->"
END_MARKER="<!-- /megavibe-v3 -->"
V2_HEADING="Operating rules (Megavibe v2)"

mkdir -p "$HOME/.claude"

if [ -f "$CLAUDE_MD" ] && grep -q "$MARKER" "$CLAUDE_MD"; then
  # ── v3 already installed — surgical replace ──
  if grep -q "$END_MARKER" "$CLAUDE_MD"; then
    sed '\|'"$MARKER"'|,\|'"$END_MARKER"'|d' "$CLAUDE_MD" > "${CLAUDE_MD}.tmp"
    if [ ! -s "${CLAUDE_MD}.tmp" ] || ! grep -q '[^[:space:]]' "${CLAUDE_MD}.tmp"; then
      cp "$SCRIPT_DIR/template/CLAUDE.md" "$CLAUDE_MD"
    else
      echo "" >> "${CLAUDE_MD}.tmp"
      cat "$SCRIPT_DIR/template/CLAUDE.md" >> "${CLAUDE_MD}.tmp"
      mv "${CLAUDE_MD}.tmp" "$CLAUDE_MD"
    fi
    ok "~/.claude/CLAUDE.md updated (v3 refreshed)"
  else
    warn "~/.claude/CLAUDE.md has start marker but no end marker (legacy install)."
    echo "    Add '<!-- /megavibe-v3 -->' at the end of the megavibe block, then re-run."
  fi

elif [ -f "$CLAUDE_MD" ] && grep -q "$V2_HEADING" "$CLAUDE_MD"; then
  # ── v2 detected — strip and replace ──
  warn "Megavibe v2 protocol detected in ~/.claude/CLAUDE.md"

  # Back up before modifying
  cp "$CLAUDE_MD" "${CLAUDE_MD}.pre-v3-backup"
  ok "backup saved to ${CLAUDE_MD}.pre-v3-backup"

  # v2 was always appended at the end — strip from v2 heading to EOF
  sed "/$V2_HEADING/,\$d" "$CLAUDE_MD" > "${CLAUDE_MD}.tmp"

  # Remove trailing blank lines from remaining content
  if [ -s "${CLAUDE_MD}.tmp" ] && grep -q '[^[:space:]]' "${CLAUDE_MD}.tmp"; then
    # User had content before v2 block — preserve it, append v3
    sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "${CLAUDE_MD}.tmp" > "${CLAUDE_MD}.tmp2"
    mv "${CLAUDE_MD}.tmp2" "${CLAUDE_MD}.tmp"
    echo "" >> "${CLAUDE_MD}.tmp"
    cat "$SCRIPT_DIR/template/CLAUDE.md" >> "${CLAUDE_MD}.tmp"
    mv "${CLAUDE_MD}.tmp" "$CLAUDE_MD"
    ok "v2 replaced with v3 (user content preserved)"
  else
    # File was entirely v2 content
    cp "$SCRIPT_DIR/template/CLAUDE.md" "$CLAUDE_MD"
    ok "v2 replaced with v3"
  fi

elif [ -f "$CLAUDE_MD" ]; then
  # ── User has a CLAUDE.md but no megavibe — append ──
  echo "" >> "$CLAUDE_MD"
  cat "$SCRIPT_DIR/template/CLAUDE.md" >> "$CLAUDE_MD"
  ok "Megavibe protocol appended to existing ~/.claude/CLAUDE.md"
else
  # ── No CLAUDE.md at all — create ──
  cp "$SCRIPT_DIR/template/CLAUDE.md" "$CLAUDE_MD"
  ok "~/.claude/CLAUDE.md created"
fi

# Warn about v2 in parent-directory CLAUDE.md files (Claude Code walks up)
for check_file in "$HOME/CLAUDE.md" "$HOME/Documents/CLAUDE.md"; do
  if [ -f "$check_file" ] && grep -q "$V2_HEADING" "$check_file"; then
    warn "Megavibe v2 content found in $check_file"
    echo "    Claude Code walks up directories for CLAUDE.md files."
    echo "    v2 rules there may conflict with v3. Consider removing them."
  fi
done

# Clean up stale tmp files
rm -f "${CLAUDE_MD}.tmp" "${CLAUDE_MD}.tmp2"

# Record installed version (for future upgrade detection)
echo "3" > "$MEGAVIBE_HOME/version"

# ─── 5. Install/update statusline ───────────────────────────────────

echo ""
info "5) Installing statusline"

STATUSLINE_SCRIPT="$HOME/.claude/statusline.sh"

cp "$SCRIPT_DIR/template/statusline.sh" "$STATUSLINE_SCRIPT"
chmod +x "$STATUSLINE_SCRIPT"
ok "~/.claude/statusline.sh"

# Add statusLine + attribution config to user-level settings.json
USER_SETTINGS="$HOME/.claude/settings.json"
MEGAVIBE_SETTINGS='{"statusLine":{"type":"command","command":"~/.claude/statusline.sh","padding":2},"attribution":{"commit":"","pr":""}}'

if [ -f "$USER_SETTINGS" ]; then
  if command -v jq &>/dev/null; then
    # Merge megavibe defaults (statusLine + attribution) into existing settings
    # jq * does recursive merge — user overrides are preserved if set after setup
    jq --argjson mv "$MEGAVIBE_SETTINGS" '. * $mv' \
      "$USER_SETTINGS" > "${USER_SETTINGS}.tmp"
    mv "${USER_SETTINGS}.tmp" "$USER_SETTINGS"
    ok "settings.json updated (statusLine + attribution)"
  else
    warn "Could not merge settings (jq not available)"
  fi
else
  echo "$MEGAVIBE_SETTINGS" | jq . > "$USER_SETTINGS"
  ok "~/.claude/settings.json created (statusLine + attribution)"
fi

# ─── 6. Register MCP servers ────────────────────────────────────────

echo ""
info "6) Registering MCP servers"

# Check which MCP servers are already registered
EXISTING_MCP=$(claude mcp list 2>/dev/null || echo "")

# Codex MCP
register_codex_mcp() {
  if echo "$EXISTING_MCP" | grep -qi "codex"; then
    skip "Codex MCP server"
  else
    claude mcp add --transport stdio --scope user codex -- codex mcp-server
    ok "Codex MCP server"
  fi
}

if [ "$CODEX_INSTALLED" -eq 1 ]; then
  register_codex_mcp
fi

# Gemini MCP
register_gemini_mcp() {
  if echo "$EXISTING_MCP" | grep -qi "gemini"; then
    skip "Gemini MCP server"
  else
    claude mcp add --transport stdio --scope user gemini-cli -- npx -y gemini-mcp-tool
    ok "Gemini MCP server"
  fi

  # Gemini CLI auth: use API key when GEMINI_API_KEY is set
  # (OAuth hits Cloud AI Companion API which requires GCP IAM permissions;
  #  API key mode hits the public generativelanguage.googleapis.com endpoint)
  GEMINI_SETTINGS="$HOME/.gemini/settings.json"
  if [ -n "${GEMINI_API_KEY:-}" ]; then
    mkdir -p "$HOME/.gemini"
    if [ -f "$GEMINI_SETTINGS" ]; then
      if command -v jq &>/dev/null && jq -e '.security.auth.selectedType' "$GEMINI_SETTINGS" &>/dev/null; then
        CURRENT_AUTH=$(jq -r '.security.auth.selectedType' "$GEMINI_SETTINGS")
        if [ "$CURRENT_AUTH" != "gemini-api-key" ]; then
          jq '.security.auth.selectedType = "gemini-api-key"' "$GEMINI_SETTINGS" > "${GEMINI_SETTINGS}.tmp"
          mv "${GEMINI_SETTINGS}.tmp" "$GEMINI_SETTINGS"
          ok "Gemini CLI switched to API key auth (was: $CURRENT_AUTH)"
        fi
      fi
    else
      echo '{"security":{"auth":{"selectedType":"gemini-api-key"}}}' | jq . > "$GEMINI_SETTINGS"
      ok "Gemini CLI configured for API key auth"
    fi
  fi
}

if [ "$GEMINI_INSTALLED" -eq 1 ]; then
  register_gemini_mcp
fi

# Playwright MCP
register_playwright_mcp() {
  if echo "$EXISTING_MCP" | grep -qi "playwright"; then
    skip "Playwright MCP server"
  else
    claude mcp add --transport stdio --scope user playwright -- npx -y @playwright/mcp@latest
    ok "Playwright MCP server"
  fi

  # Ensure Playwright browsers are installed (required for @playwright/mcp to work)
  if npx -y @playwright/mcp@latest --help &>/dev/null 2>&1; then
    if npx playwright install chromium &>/dev/null 2>&1; then
      ok "Playwright chromium browser"
    else
      warn "Could not install Playwright browsers — run: npx playwright install chromium"
    fi
  else
    warn "Playwright MCP not available — browser install skipped"
  fi
}

should_install_playwright() {
  if [ "$NONINTERACTIVE_AUTO" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    return 0
  fi
  read -r -p "  Install Playwright MCP server? [Y/n] " _playwright_ans
  case "${_playwright_ans:-y}" in
    [nN]|[nN][oO]) return 1 ;;
    *) return 0 ;;
  esac
}

if should_install_playwright; then
  register_playwright_mcp
else
  skip "Playwright MCP server (user skipped)"
fi

# poma-memory MCP (bundled poma_memory.py or pip-installed)
if echo "$EXISTING_MCP" | grep -qi "poma-memory"; then
  skip "poma-memory MCP server"
elif [ -f "$MEGAVIBE_HOME/poma_memory.py" ] && [ -n "$PYTHON" ]; then
  claude mcp add --transport stdio --scope user poma-memory -- "$PYTHON" "$MEGAVIBE_HOME/poma_memory.py" mcp
  ok "poma-memory MCP server (bundled)"
elif command -v poma-memory-mcp &>/dev/null; then
  claude mcp add --transport stdio --scope user poma-memory -- poma-memory-mcp
  ok "poma-memory MCP server (pip)"
else
  skip "poma-memory MCP server (poma_memory.py not found in ~/.megavibe/)"
fi

# ─── 7. Verify ──────────────────────────────────────────────────────

echo ""
info "7) Verification"

claude mcp list 2>/dev/null && ok "MCP servers listed" || warn "Could not list MCP servers (claude may need login first)"

# ─── Done ────────────────────────────────────────────────────────────

echo ""
info "Machine setup complete."
echo ""
echo "  Next: cd into any project and run:"
echo "    megavibe"
echo ""
