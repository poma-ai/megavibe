# Remote access

Use megavibe from your phone: Claude's own Remote Control, or an optional
Telegram bot that doubles as a personal assistant and project launcher.

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
| "**myapp** status" | Bot reads `.agent/TASKS.md` → instant status, no Claude call |
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

# 4. Start the bot — ONCE. It stays up (supervised, auto-restart) and you
#    rarely touch it again; re-running is a harmless no-op.
megavibe remote

#    Occasional controls (you won't need these often):
megavibe remote --status        # is it running?
megavibe remote --stop          # stop it
megavibe remote --autostart on  # also start it at login, macOS (off | status too)
megavibe remote --fg            # run in foreground to watch logs (debugging)

# 5. Register your projects (in Telegram DM with the bot):
#    /register megavibe ~/Documents/megavibe
#    /register myapp ~/code/myapp
```

#### Day to day — what to type, when

After the one-time setup above, **the bot stays up on its own.** You don't keep starting it. In normal use you only ever do one of these:

| You want to… | Do this |
|---|---|
| Ask your assistant something from your **phone/Watch** | Just message the bot in Telegram (text or voice note) — nothing to type on your computer |
| Sit at that **same** assistant from your **keyboard** | `megavibe assistant` — attaches your terminal to the live session; press `Ctrl-b` then `d` to leave it running |
| Work on a specific **project** from your phone | Message the bot, e.g. `fix the auth bug in megavibe` → it sends a link to tap |
| Make the bot **survive reboots** | `megavibe remote --autostart on` (once, macOS) |
| Check it's alive / stop it | `megavibe remote --status` · `megavibe remote --stop` |

You normally **never re-type `megavibe remote`** — it's idempotent and supervised, so it's only for the very first start (or after a `--stop`). `megavibe remote` (phone) and `megavibe assistant` (keyboard) are two doors into the **same** live Claude.

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

**One brain, reachable two ways.** The personal assistant is a *single* persistent Claude running in the `megavibe-personal` tmux session, working out of `~/.megavibe/personal/` (its own `.agent/` memory and poma-memory index). You reach the **same live session** two ways: `megavibe remote` drives it from your phone or Watch over Telegram, and `megavibe assistant` attaches your terminal straight to it. Start a thought at your desk, continue it on your phone — one conversation, not just shared files. (`megavibe assistant` spins the brain up if it isn't running yet; detach with `Ctrl-b d` and it keeps going.) Run either from **any directory**: everything uses absolute `~/.megavibe/` paths, so there's no folder you need to `cd` into first.

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

