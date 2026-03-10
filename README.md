# Megavibe

**Give Claude Code a memory that never dies.**

Megavibe makes Claude Code remember everything — decisions, mistakes, progress, and context — across sessions, compactions, and crashes. One command to install, one command to use.

**macOS only** (for now). Requires a [Claude Code](https://docs.anthropic.com/en/docs/claude-code) subscription.

---

## Get Started

### 1. Open Terminal

Press **Cmd + Space**, type **Terminal**, press **Enter**.

### 2. Install Megavibe

Copy-paste this into Terminal and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/poma-ai/megavibe/main/install.sh | bash
```

The installer handles everything — Homebrew, Node.js, Python, AI tools — and walks you through each step. Takes about 5 minutes.

### 3. Use it

Navigate to any project and run:

```bash
cd ~/Desktop/my-project
megavibe
```

That's it. Claude now remembers everything you work on together. Run `megavibe` every time you start working — it's always safe to re-run.

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
3. Claude calls Gemini (or ChatGPT) to read the full log and produce a focused summary
4. Claude reads the summary and continues — zero information loss, no human intervention

---

## Features

### Automatic context recovery

When Claude runs out of memory and compacts, megavibe detects it and triggers recovery. Three tiers:

- **Small projects** (< 10KB context): injects the full log directly — no AI needed
- **Normal projects**: Claude calls Gemini to produce a focused ~400-line summary
- **Empty context** (first compaction): instructs Claude to save the compaction summary before it's lost

Recovery uses a fallback chain: Gemini (subscription) → Gemini (API key, for geo-blocked regions) → ChatGPT/Codex. At least one needs to work.

### Semantic search augmentation

Every time Claude searches your code (Grep), a hook automatically searches your project memory too and injects relevant context. Claude sees both code results AND related decisions/history — without you asking.

Powered by poma-memory (bundled): hybrid BM25 + vector search over your `.agent/` files. Works locally, no API calls.

### Self-improvement

When you correct Claude, it records the pattern in `LESSONS.md`. Before every plan, it checks its lessons to avoid repeating mistakes. Your Claude gets better at YOUR project over time.

### Safety hooks

Automatically blocks dangerous commands before they execute:
- `rm -rf /` or `rm -rf ~`
- `git push --force main`
- `git reset --hard`
- `DROP TABLE`

### Multi-agent orchestration

Claude is the orchestrator. Supporting agents connect via MCP and are used automatically:

| Agent | What it does | Required? |
|-------|-------------|-----------|
| **Claude Code** | Edits files, runs commands, delegates | Yes |
| **Gemini** | Context recovery, large file analysis, image description | No (installed by setup) |
| **ChatGPT/Codex** | Research, second opinions, web search | No (installed by setup) |
| **Playwright** | Browser automation, screenshots | No (installed by setup) |
| **poma-memory** | Semantic search over project memory | No (bundled) |

All agents use browser login — no API keys needed. If one isn't available, Claude falls back automatically.

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
| `/catchup` | Starting a new session — reviews open tasks, git state, decisions |
| `/rehydrate` | After compaction or stale context — full AI-powered recovery |
| `/compact-context` | When FULL_CONTEXT.md gets very large (rare) |

---

## Optional: Better Search with OpenAI Embeddings

poma-memory uses a local model (model2vec, 30MB) by default — no API key needed. If you set `OPENAI_API_KEY`, it switches to OpenAI's `text-embedding-3-large` for higher-quality search. Cost is negligible (~$0.01/month).

```bash
export OPENAI_API_KEY="your-key-here"  # add to ~/.zshrc for persistence
```

---

## What Gets Installed

### Machine-wide (by setup)

| What | Where |
|------|-------|
| `megavibe` CLI | `~/.local/bin/megavibe` |
| Framework files | `~/.megavibe/` |
| Core protocol | `~/.claude/CLAUDE.md` |
| Status bar | `~/.claude/statusline.sh` |
| MCP servers | Codex, Gemini, Playwright, poma-memory |

### Per-project (automatic on first `megavibe` run)

| What | Where |
|------|-------|
| Hooks (6 scripts) | `.claude/hooks/` |
| Rules (2 files) | `.claude/rules/` |
| Skills (3 commands) | `.claude/skills/` |
| Hook config | `.claude/settings.json` |
| Context structure | `.agent/` |
| Personal overrides | `CLAUDE.local.md` |

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
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

**Hooks aren't firing** — Install jq: `brew install jq`

**Gemini/Codex not connecting** — Run the CLI directly (`gemini` or `codex`) to re-authenticate. Megavibe works without them.

**Context recovery not working** — Check that `.agent/FULL_CONTEXT.md` has content. If empty, Claude hasn't started writing context yet. The hook nudges it after the first few tool calls.

**poma-memory search not working** — Check Python deps: `python3 -c "import numpy, model2vec"`. If missing: `pip3 install numpy model2vec`

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
Megavibe still works. Context files are durable regardless. AI-powered recovery needs at least one backend, but you can also review `.agent/` files manually.

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

---

## License

[MIT](LICENSE)
