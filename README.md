# Megavibe

**Give Claude Code a memory that never dies.**

Megavibe makes Claude Code remember everything — decisions, mistakes, progress, and context — across sessions, compactions, and crashes. One command to install, one command to use. Optionally, control it from your phone or Apple Watch.

**macOS, Linux, and Windows** (Git Bash or WSL). Requires a [Claude Code](https://docs.anthropic.com/en/docs/claude-code) subscription. Everything else is optional.

---

## Get Started

### 1. Open a terminal

- **macOS**: Press **Cmd + Space**, type **Terminal**, press **Enter**
- **Linux**: Open your terminal emulator
- **Windows**: Open **Git Bash** (from [git-scm.com](https://git-scm.com)) or **WSL**

### 2. Install Megavibe

Copy-paste this into Terminal and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/poma-ai/megavibe/main/install.sh | bash
```

The installer detects your OS and package manager (Homebrew, apt, dnf, pacman, winget, choco) and installs everything needed — Node.js, Python, jq, AI tools — then walks you through each step. Takes about 5 minutes.

### 3. Use it

Navigate to any project and run:

```bash
cd ~/my-project
megavibe
```

That's it. Claude now remembers everything you work on together. Run `megavibe` every time you start working — it's always safe to re-run.

Every session automatically has **Remote Control** enabled — you can connect from your phone via the Claude app at any time (see [Remote Access](#remote-access-optional) below).

---

## What Does It Actually Do?

### The problem

Claude Code forgets things. Every time it "compacts" (runs out of memory), it loses detail. After a few compactions, it forgets constraints, repeats mistakes, and loses track of decisions.

### The solution

Megavibe creates a **durable memory layer** that Claude writes to continuously and recovers from automatically:

```
your-project/
├── .agent/                          <- Claude's memory (survives everything)
│   ├── FULL_CONTEXT.md              <- everything that happened (append-only)
│   ├── DECISIONS.md                 <- why things were done a certain way
│   ├── TASKS.md                     <- what's done, what's pending
│   ├── LESSONS.md                   <- patterns from your corrections
│   └── sessions/{id}/
│       └── WORKING_CONTEXT.md       <- focused summary (~400 lines)
│
├── .claude/                         <- automation (hooks, rules, skills)
│   ├── hooks/                       <- auto-logging, safety, search
│   ├── rules/                       <- extended protocols
│   ├── skills/                      <- slash commands (/catchup, /rehydrate)
│   └── settings.json                <- hook configuration
│
└── CLAUDE.local.md                  <- your personal overrides (gitignored)
```

**How recovery works:**

1. Claude writes to `.agent/` files as it works (a hook nudges it every ~8 tool calls)
2. When Claude's context gets compacted, a hook fires automatically
3. Claude calls Gemini (or ChatGPT, or a built-in subagent) to read the full log and produce a focused summary
4. Claude reads the summary and continues — zero information loss, no human intervention

---

## Features

### Automatic context recovery

When Claude runs out of memory and compacts, megavibe detects it and triggers recovery. Three tiers:

- **Small projects** (< 10KB context): injects the full log directly — no AI needed
- **Normal projects**: Claude calls Gemini to produce a focused ~400-line summary
- **Empty context** (first compaction): instructs Claude to save the compaction summary before it's lost

Recovery uses a fallback chain: Gemini (subscription) → Gemini (API key) → ChatGPT/Codex → Claude subagent (always works, same subscription).

### Semantic search augmentation

Every time Claude searches your code (Grep), a hook automatically searches your project memory too and injects relevant context. Claude sees both code results AND related decisions/history — without you asking.

Powered by [poma-memory](https://github.com/poma-ai/poma-memory) (pip-installed): hybrid BM25 + vector search over your `.agent/` files. Works locally, no API calls.

### Self-improvement

When you correct Claude, it records the pattern in `LESSONS.md`. Before every plan, it checks its lessons to avoid repeating mistakes. Your Claude gets better at YOUR project over time.

### Safety hooks

Automatically blocks dangerous commands before they execute:
- `rm -rf /` or `rm -rf ~`
- `git push --force main`
- `git reset --hard`
- `DROP TABLE`

### Phone access (built-in)

Every megavibe session has [Remote Control](https://code.claude.com/docs/en/remote-control) enabled by default. Type `/rc` in your terminal session to get a QR code — scan it with your phone and continue the same session in the Claude app. Walk away from your desk, keep working from the couch.

### Multi-agent orchestration

**Megavibe works with only a Claude Code subscription.** Everything else adds capabilities but is never required.

| What you add | How | What it unlocks |
|-------------|-----|-----------------|
| **Claude Code** (required) | Subscription | Core: editing, commands, memory, context recovery via built-in subagent |
| **Gemini CLI** | Run `gemini` to log in | Better context recovery (1M token window), large file analysis |
| **ChatGPT/Codex CLI** | Run `codex` to log in | Research with web search, second opinions |
| **Playwright** | Installed by setup | Browser automation, screenshots, UI testing |
| **poma-memory** | Bundled (automatic) | Semantic search over project memory |
| **Telegram bot** | Optional, see below | Personal assistant + project launcher from phone/Watch |

Setup installs Gemini/Codex/Playwright CLIs and walks you through login. You can skip any — megavibe adapts.

### Structured workflow

```
Explore → Plan → Implement → Verify → Commit → Learn → Reflect
```

| Step | What Claude does |
|------|-----------------|
| **Explore** | Read-only investigation |
| **Plan** | Define files, steps, verification commands |
| **Implement** | Follow the plan. Stop and re-plan if it diverges |
| **Verify** | Run tests/commands |
| **Commit** | Descriptive message, log to FULL_CONTEXT.md |
| **Learn** | After corrections, record the pattern |
| **Reflect** | After major features, assess if approach is still sound |

### Parallel tasks (spinouts)

When a plan has 3+ independent tasks, Claude can spin them to parallel subagents. Each gets a fresh context window. The primary benefit is **context freshness**, not just speed.

### Slash commands

Inside a megavibe session:

| Command | When to use |
|---------|------------|
| `/catchup` | **Starting a new session** — reviews open tasks, git state, decisions (no AI calls). **Not needed after compaction** — the `on-compact` hook already inlines its output. |
| `/rehydrate` | **After compaction or stale context** — full AI-powered recovery. Post-compact this is the ONLY slash command you need to type; a 5-minute grace period suppresses stale-context nags while it runs. |
| `/prune-context` | When `.agent/FULL_CONTEXT.md` gets very large (rare); **distinct from `/compact`** (built-in conversation summarizer) |
| `/rc` | Get a QR code to connect from your phone (Claude app) |

---

## Remote Access (optional)

Control Claude Code from your iPhone, Apple Watch, or any device — with or without Telegram.

### Without Telegram (built-in)

Every megavibe session has Remote Control enabled. In your terminal:

```
/rc
```

Scan the QR code with your phone → Claude app opens → same session. Type on either device. Works immediately, no setup needed.

### With Telegram (personal assistant + project launcher)

Add a Telegram bot for a richer experience: a personal assistant that answers questions, checks project status, and launches Claude sessions — all from a chat message or voice note on your Watch.

#### What it does

| You send | What happens |
|----------|-------------|
| "fix the auth bug in **megavibe**" | Bot launches a Claude session in the project dir → sends you a link → tap → Claude app → full interactive session |
| "what's the weather in Tokyo?" | Personal assistant answers directly in Telegram (readable on Watch) |
| "**officeqa** status" | Bot reads `.agent/TASKS.md` → instant status, no Claude call |
| Voice note from Watch | Transcribed via OpenAI Whisper → routed like text |

The personal assistant runs as a **full Claude session** (not a limited headless mode) — it has access to all tools including web search, and maintains conversation history across messages.

#### Setup

```bash
# 1. Install tmux (needed for persistent personal session)
#    macOS:  brew install tmux
#    Ubuntu: sudo apt install tmux
#    Fedora: sudo dnf install tmux
#    Arch:   sudo pacman -S tmux

# 2. Create a Telegram bot
#    Message @BotFather on Telegram → /newbot → copy the token
#    Message @userinfobot → copy your numeric user ID

# 3. Add to your shell profile (~/.zshrc, ~/.bashrc, etc.):
export MEGAVIBE_TELEGRAM_TOKEN="your-bot-token"
export MEGAVIBE_TELEGRAM_USER_ID="your-user-id"

# Optional: for voice transcription (Watch voice notes)
export OPENAI_API_KEY="your-key"

# 4. Start the bot
megavibe remote          # foreground (Ctrl+C to stop)
megavibe remote --bg     # background
megavibe remote --stop   # stop background bot
megavibe remote --status # check if running

# 5. Register your projects (in Telegram DM with the bot):
#    /register megavibe ~/Documents/megavibe
#    /register officeqa ~/Documents/_1_WORK/poma/poma-officeqa
```

#### How it works

```
megavibe remote
  │
  ├─ Personal assistant (full Claude in tmux)
  │   └─ ~/.megavibe/personal/ — standard megavibe project
  │   └─ Messages injected via tmux, responses read from session JSONL
  │   └─ Visible in Claude app via Remote Control
  │
  ├─ Project launcher
  │   └─ Mention a project name → spawns claude remote-control
  │   └─ Sends session URL to Telegram → tap to open in Claude app
  │
  └─ Status reader
      └─ Reads .agent/TASKS.md directly (instant, no Claude call)
```

The personal assistant is a standard megavibe project at `~/.megavibe/personal/` — same `.agent/` files, same poma-memory indexing. Your personal context persists across sessions just like project context.

#### Apple Watch

Install [Pigeon for Telegram](https://apps.apple.com/app/pigeon-for-telegram/id1576307230) (~$2/month). Record voice notes on your wrist → OpenAI Whisper transcribes them → the bot routes to the right project or answers personally. Responses are concise and Watch-readable.

#### Bot commands

| Command | Action |
|---------|--------|
| `/register name ~/path` | Register a project |
| `/projects` | List all projects with status |
| `/status [name]` | Project status (tasks, activity) |
| `/cancel [name\|personal]` | Stop a session |
| `/help` | Show all commands |

---

## Optional API Keys

Megavibe works without any API keys. Adding them unlocks extra capabilities:

| Key | What it does | Cost | How to get it |
|-----|-------------|------|---------------|
| `GEMINI_API_KEY` | Fallback for Gemini CLI when OAuth is geo-blocked | Free tier available | [aistudio.google.com](https://aistudio.google.com/apikey) |
| `OPENAI_API_KEY` | Better poma-memory search + voice transcription for Remote | ~$0.01/month search; ~$0.006/voice note | [platform.openai.com](https://platform.openai.com/api-keys) |

```bash
# Add to your shell profile (~/.zshrc, ~/.bashrc, etc.) for persistence
export GEMINI_API_KEY="your-key-here"
export OPENAI_API_KEY="your-key-here"
```

---

## What Gets Installed

### Machine-wide (by setup)

| What | Where |
|------|-------|
| `megavibe` CLI | `~/.local/bin/megavibe` |
| Framework files | `~/.megavibe/` |
| Personal assistant project | `~/.megavibe/personal/` |
| Core protocol | `~/.claude/CLAUDE.md` |
| Status bar | `~/.claude/statusline.sh` |
| MCP servers | Codex, Gemini, Playwright, poma-memory |

### Per-project (automatic on first `megavibe` run)

| What | Where |
|------|-------|
| Hooks (7 scripts) | `.claude/hooks/` |
| Rules (2 files) | `.claude/rules/` |
| Skills (3 commands) | `.claude/skills/` |
| Agents (1 fallback) | `.claude/agents/` |
| Hook config | `.claude/settings.json` |
| Context structure | `.agent/` |
| Personal overrides | `CLAUDE.local.md` |

---

## Performance

Megavibe adds minimal overhead. The main cost is the poma-memory vector search database, which stores embeddings of your `.agent/` files locally.

**Real measurements** from an active project (megavibe itself — 1,500-line context log, 50+ sessions, 3,000 chunks indexed):

| Metric | Value | Notes |
|--------|-------|-------|
| **Disk (DB)** | ~10 MB | Scales linearly with indexed content (~3 KB/chunk) |
| **Disk (.agent/)** | ~25 MB | Includes FULL_CONTEXT.md, logs, sessions. Grows over weeks/months |
| **RAM (model)** | ~25 MB | model2vec embedding model, loaded on first search |
| **Search (cold)** | ~500 ms | First search loads the model |
| **Search (warm)** | ~300 ms | Subsequent searches in the same session |
| **Hook overhead** | < 10 ms | Hooks are shell scripts, no network calls |

For a typical project (shorter context, ~500 chunks), expect ~1 MB disk and sub-100ms warm search.

poma-memory uses brute-force cosine similarity on numpy arrays — no external vector DB needed. This scales comfortably to ~10K chunks (~30 MB DB) before you'd notice any slowdown. Most projects will never reach that.

---

## Updating

Re-run the installer. It's idempotent:

```bash
curl -fsSL https://raw.githubusercontent.com/poma-ai/megavibe/main/install.sh | bash
```

Or if you have a local clone: `bash megavibe/setup.sh`

---

## Troubleshooting

**`megavibe: command not found`**
```bash
# Add ~/.local/bin to your PATH (add to ~/.zshrc, ~/.bashrc, or ~/.profile)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

**Hooks aren't firing** — Install jq: `brew install jq` (macOS), `sudo apt install jq` (Ubuntu), `sudo dnf install jq` (Fedora)

**Gemini/Codex not connecting** — Run the CLI directly (`gemini` or `codex`) to re-authenticate. Megavibe works without them.

**Context recovery not working** — Check that `.agent/FULL_CONTEXT.md` has content. If empty, Claude hasn't started writing context yet. The hook nudges it after the first few tool calls.

**poma-memory search not working** — Check Python deps: `python3 -c "import numpy, model2vec"`. If missing: `pip3 install numpy model2vec`

**Remote bot: "No response received"** — Check the tmux session: `tmux attach -t megavibe-personal`. Claude may be waiting for input or stuck on a prompt.

**Remote bot: voice not working** — Requires `OPENAI_API_KEY` and `httpx`: `pip3 install httpx`

**Debug hooks** — `claude --debug` shows hook execution details.

---

## FAQ

**Does this work with any language/framework?**
Yes. Megavibe is language-agnostic — it's just files and shell hooks.

**Can my team use it on the same project?**
Yes. `.agent/` files are designed for concurrent access. Commit `.agent/` to git so the team shares decisions and lessons.

**Does this replace Claude Code's built-in memory?**
No, it complements it. Claude's auto-memory handles cross-session preferences. Megavibe handles detailed project context, decisions, and task state.

**What if I don't have Gemini or ChatGPT?**
Megavibe still works. Context recovery falls back to a built-in Claude subagent (same subscription). External backends improve quality but are never required.

**Do I need Telegram for remote access?**
No. Every session has `/rc` (Remote Control) built in — connect from the Claude app on your phone with no extra setup. Telegram adds a personal assistant and project launcher on top.

**Does the Telegram bot need to run all the time?**
No. It's optional. Start it when you want remote access, stop it when you don't. Your terminal sessions work exactly the same either way.

**How do I uninstall?**
```bash
rm -rf ~/.megavibe ~/.local/bin/megavibe
# Remove the megavibe block from ~/.claude/CLAUDE.md (between <!-- megavibe-v3 --> markers)
# In each project: rm -rf .agent .claude/hooks .claude/rules .claude/skills CLAUDE.local.md
```

---

## Architecture (for contributors)

See [CLAUDE.md](CLAUDE.md) for full contributor documentation.

- **Idempotency is sacred.** Both `setup.sh` and `init.sh` are safe to re-run.
- **Marker-based protocol updates.** `<!-- megavibe-v3 -->` markers enable surgical replacement.
- **Infrastructure vs. user data.** Hooks/rules/skills are always overwritten. Context files are never overwritten.
- **Session isolation.** Multiple Claude sessions can run on the same project safely.
- **Remote Control by default.** Every session launches with `--remote-control`.

---

## License

[MIT](LICENSE)
