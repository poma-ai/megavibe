#!/bin/bash
set -euo pipefail

# Megavibe — one-command install
# Usage: curl -fsSL https://raw.githubusercontent.com/poma-ai/megavibe/main/install.sh | bash
#
# Supports macOS, Linux, and Windows (Git Bash / WSL).
# Auto-installs prerequisites using the platform's package manager.
# Guides through each login step interactively.

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

ok()   { echo -e "  ${GREEN}done${RESET} $1"; }
info() { echo -e "${BOLD}$1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }

echo ""
echo -e "${BOLD}Welcome to Megavibe${RESET}"
echo -e "${DIM}Give Claude Code a memory that never dies.${RESET}"
echo ""

# ─── OS detection ─────────────────────────────────────────────────────

detect_os() {
  case "$(uname -s)" in
    Darwin)  echo "macos" ;;
    Linux)
      # WSL detection
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "windows"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

OS=$(detect_os)

if [ "$OS" = "unknown" ]; then
  echo -e "${RED}Unsupported platform: $(uname -s)${RESET}"
  echo "  Megavibe supports macOS, Linux, and Windows (Git Bash or WSL)."
  exit 1
fi

echo -e "  ${DIM}Detected platform: ${OS}${RESET}"

# ─── Package manager detection ────────────────────────────────────────

# Returns the best available package manager for install commands
detect_pkg_manager() {
  if command -v brew &>/dev/null; then echo "brew"
  elif command -v apt-get &>/dev/null; then echo "apt"
  elif command -v dnf &>/dev/null; then echo "dnf"
  elif command -v pacman &>/dev/null; then echo "pacman"
  elif command -v apk &>/dev/null; then echo "apk"
  elif command -v winget &>/dev/null; then echo "winget"
  elif command -v choco &>/dev/null; then echo "choco"
  else echo "none"
  fi
}

# Install a package using the detected package manager
# Usage: pkg_install <brew-name> <apt-name> [dnf-name] [pacman-name]
pkg_install() {
  local brew_name="${1:-}" apt_name="${2:-}" dnf_name="${3:-$2}" pacman_name="${4:-$2}"
  local mgr
  mgr=$(detect_pkg_manager)

  case "$mgr" in
    brew)   brew install "$brew_name" ;;
    apt)    sudo apt-get update -qq && sudo apt-get install -y -qq "$apt_name" ;;
    dnf)    sudo dnf install -y -q "$dnf_name" ;;
    pacman) sudo pacman -S --noconfirm "$pacman_name" ;;
    apk)    sudo apk add "$apt_name" ;;
    winget) winget install --accept-source-agreements --accept-package-agreements "$brew_name" 2>/dev/null || true ;;
    choco)  choco install -y "$brew_name" ;;
    none)
      echo -e "  ${RED}No package manager found.${RESET}"
      echo "    Install '$apt_name' manually and re-run this script."
      return 1
      ;;
  esac
}

# ─── Prerequisites (auto-install everything) ─────────────────────────

info "Step 1 of 4: Checking prerequisites"
echo ""

# macOS: Xcode Command Line Tools (provides git)
if [ "$OS" = "macos" ]; then
  if ! xcode-select -p &>/dev/null; then
    echo "  Installing Xcode Command Line Tools (this may take a few minutes)..."
    echo -e "  ${DIM}A popup may appear — click 'Install' if it does.${RESET}"
    xcode-select --install 2>/dev/null || true
    until xcode-select -p &>/dev/null; do
      sleep 5
    done
    ok "Xcode Command Line Tools"
  else
    ok "Xcode Command Line Tools (already installed)"
  fi
fi

# macOS: Homebrew (offer to install if missing — it's the best macOS package manager)
if [ "$OS" = "macos" ] && ! command -v brew &>/dev/null; then
  echo "  Installing Homebrew (the macOS package manager)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for this session (Apple Silicon vs Intel)
  if [ -f "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -f "/usr/local/bin/brew" ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  ok "Homebrew"
fi

# Git
if ! command -v git &>/dev/null; then
  echo "  Installing git..."
  pkg_install git git
  ok "git"
else
  ok "git (already installed)"
fi

# Node.js (for npm/npx, needed by MCP servers)
if ! command -v node &>/dev/null; then
  echo "  Installing Node.js..."
  pkg_install node nodejs nodejs nodejs
  ok "Node.js $(node --version 2>/dev/null || echo '')"
else
  ok "Node.js $(node --version) (already installed)"
fi

# npm (sometimes separate on Linux)
if ! command -v npm &>/dev/null; then
  echo "  Installing npm..."
  pkg_install npm npm npm npm
  ok "npm"
fi

# jq (needed by hooks)
if ! command -v jq &>/dev/null; then
  echo "  Installing jq..."
  pkg_install jq jq jq jq
  ok "jq"
else
  ok "jq (already installed)"
fi

# Python 3.10+ (required by poma-memory) — Windows Git Bash may have 'python' not 'python3'
PYTHON_FOUND=""
for pycmd in /opt/homebrew/bin/python3 /usr/local/bin/python3 python3 python; do
  if command -v "$pycmd" &>/dev/null && "$pycmd" -c "import sys; assert sys.version_info >= (3, 10)" &>/dev/null; then
    PYTHON_FOUND="$pycmd"
    break
  fi
done

if [ -z "$PYTHON_FOUND" ]; then
  echo "  Installing Python 3 (3.10+ required for poma-memory)..."
  pkg_install python3 python3 python3 python
  # Check if the newly installed version is 3.10+
  for pycmd in /opt/homebrew/bin/python3 /usr/local/bin/python3 python3 python; do
    if command -v "$pycmd" &>/dev/null && "$pycmd" -c "import sys; assert sys.version_info >= (3, 10)" &>/dev/null; then
      PYTHON_FOUND="$pycmd"
      break
    fi
  done
  if [ -n "$PYTHON_FOUND" ]; then
    ok "Python $($PYTHON_FOUND --version 2>&1 | cut -d' ' -f2)"
  else
    warn "Installed Python is older than 3.10 — poma-memory may not install"
    ok "Python $(python3 --version 2>&1 | cut -d' ' -f2)"
  fi
else
  ok "Python $($PYTHON_FOUND --version 2>&1 | cut -d' ' -f2) (already installed)"
fi

# curl (usually pre-installed, but not always on minimal Linux)
if ! command -v curl &>/dev/null; then
  echo "  Installing curl..."
  pkg_install curl curl curl curl
  ok "curl"
fi

echo ""

# ─── Clone and run setup ─────────────────────────────────────────────

# Reuse an existing clone of github.com/poma-ai/megavibe when cwd (or this script's dir) is inside it.
find_megavibe_repo() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 1
  git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null || return 1
  local root url
  root=$(git -C "$dir" rev-parse --show-toplevel)
  url=$(git -C "$root" config --get remote.origin.url 2>/dev/null || true)
  case "$url" in
    *poma-ai/megavibe*) printf '%s' "$root"; return 0 ;;
    *) return 1 ;;
  esac
}

info "Step 2 of 4: Installing Megavibe"
echo ""

MEGAVIBE_SRC=""
_root=$(find_megavibe_repo "$PWD") && MEGAVIBE_SRC="$_root"
if [ -z "$MEGAVIBE_SRC" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
  _dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || _dir=""
  if [ -n "$_dir" ]; then
    _root=$(find_megavibe_repo "$_dir") && MEGAVIBE_SRC="$_root"
  fi
fi

if [ -n "$MEGAVIBE_SRC" ]; then
  echo "  Using existing Megavibe repository at $MEGAVIBE_SRC"
  echo ""
else
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT
  echo "  Downloading..."
  git clone --depth 1 https://github.com/poma-ai/megavibe.git "$TMPDIR/megavibe" 2>/dev/null
  MEGAVIBE_SRC="$TMPDIR/megavibe"
  echo ""
fi

if [ ! -f "$MEGAVIBE_SRC/setup.sh" ]; then
  echo -e "  ${RED}✗${RESET} Megavibe setup script missing: $MEGAVIBE_SRC/setup.sh"
  echo "    (incomplete clone, damaged checkout, or wrong directory). Clone or fix the repo, then re-run."
  exit 1
fi

# Run setup (installs CLIs, MCP servers, protocol, statusline)
bash "$MEGAVIBE_SRC/setup.sh"

# Store version hash so megavibe can check for updates later
MEGAVIBE_HOME="$HOME/.megavibe"
VERSION_HASH=$(git -C "$MEGAVIBE_SRC" rev-parse HEAD 2>/dev/null || \
  curl -sfL -H "Accept: application/vnd.github.sha" "https://api.github.com/repos/poma-ai/megavibe/commits/main" 2>/dev/null || \
  echo "")
if [ -n "$VERSION_HASH" ]; then
  echo "$VERSION_HASH" > "$MEGAVIBE_HOME/version"
fi

# Ensure ~/.local/bin is on PATH permanently (Linux/WSL — npm globals go here)
if [[ "$OS" != "macos" ]] && [[ "$(id -u)" != "0" ]]; then
  LOCAL_BIN="$HOME/.local/bin"
  case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *)
      export PATH="$LOCAL_BIN:$PATH"
      # Persist to shell profile
      SHELL_RC="$HOME/.bashrc"
      [[ -n "${ZSH_VERSION:-}" ]] && SHELL_RC="$HOME/.zshrc"
      [[ "$(basename "${SHELL:-bash}")" == "zsh" ]] && SHELL_RC="$HOME/.zshrc"
      if ! grep -q '.local/bin' "$SHELL_RC" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
        warn "Added ~/.local/bin to PATH in $(basename "$SHELL_RC")"
      fi
      ;;
  esac
fi

echo ""

# ─── Login guidance ──────────────────────────────────────────────────

info "Step 3 of 4: Sign in to AI services"
echo ""
echo "  Megavibe uses Claude as the main brain, with Gemini and ChatGPT"
echo "  as helpers. You need at least a Claude subscription."
echo ""
echo -e "  ${BOLD}Required:${RESET}"
echo "    Claude Code  — you should already be logged in"
echo "                   (if not, run: claude)"
echo ""
echo -e "  ${BOLD}Optional but recommended:${RESET}"
echo "    Gemini       — run: gemini"
echo "    ChatGPT      — run: codex"
echo ""
echo -e "  ${DIM}Each command opens your browser to sign in. Free tiers work.${RESET}"
echo -e "  ${DIM}You can add these later — megavibe works without them.${RESET}"
echo ""
read -p "  Press Enter when ready to continue... " || true
echo ""

# ─── Done ────────────────────────────────────────────────────────────

info "Step 4 of 4: Ready!"
echo ""
echo -e "  ${GREEN}${BOLD}Megavibe is installed.${RESET}"
echo ""
echo "  To start using it, open your project folder and run megavibe:"
echo ""
echo -e "    ${BOLD}cd ~/my-project${RESET}    ${DIM}(or wherever your code is)${RESET}"
echo -e "    ${BOLD}megavibe${RESET}"
echo ""
echo "  That's it. Claude will remember everything from now on."
echo ""
echo -e "  ${DIM}Tip: Run 'megavibe' every time you start working. It's always safe to re-run.${RESET}"
echo ""
