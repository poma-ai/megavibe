<!-- megavibe-v3 -->

# Megavibe v3 Operating Rules

Claude Code is the executor and orchestrator. Gemini and Codex are subcontractors via MCP. Playwright handles UI automation. **Megavibe works with only a Claude Code subscription** — external backends improve quality but are never required.

**Context management rules (items 2–3 below) apply only when an `.agent/` directory exists in the project root.** The workflow, tool routing, and verification rules apply everywhere. Personal overrides go in `CLAUDE.local.md` (auto-gitignored).

## Non-negotiables

1. **Verification is mandatory.** Every task must specify verification commands and expected outcomes. Run verification before declaring done.

2. **Continuous context writes.** Write to `.agent/` files **as you go**, not just at milestones. After every significant decision, completed subtask, or important discovery:
   - Append a 2–3 line summary to `.agent/FULL_CONTEXT.md`
   - Update `.agent/DECISIONS.md` if a decision was made
   - Update `.agent/TASKS.md` if task status changed
   A hook counts tool calls since your last `.agent/` write and nudges you after 8 calls. Don't ignore it — stale context files mean broken re-hydration. But don't rely on the hook: follow this rule independently.

3. **Full context log is durable.** `.agent/FULL_CONTEXT.md` is append-only with no length limit — let it grow. Store research in `.agent/RESEARCH/`. Store screenshots/HTML/PDFs in `.agent/ASSETS/`.

4. **Second opinions for risky changes.** If ambiguous, risky, or repeatedly corrected: request a second opinion from Codex and/or Gemini before shipping. When requesting second opinions, ask the reviewer to consider the neutral case, the devil's advocate case, and the optimistic case — then synthesize.

5. **Never drop uncommitted changes.** Before any git operation that could lose work (checkout, reset, pull, rebase, clean, restore, switch branches): run `git status`. If there are uncommitted changes, `git stash push -m "megavibe-auto: <reason>"` first, inform the user what was stashed, and ask before popping or discarding. Never silently overwrite dirty state.

## Session isolation

Multiple Claude Code sessions can run in the same project simultaneously. To prevent races:
- **Shared files** (append-only, project-level truth): `FULL_CONTEXT.md`, `DECISIONS.md`, `TASKS.md`, `LESSONS.md`, `RESEARCH/`
- **Session-scoped files**: `WORKING_CONTEXT.md` lives at `.agent/sessions/{session_id}/WORKING_CONTEXT.md`. Hook counters and flags are also per-session.

The on-compact hook tells you your session ID and WORKING_CONTEXT path. Use the path it gives you.

## Compaction lifecycle (automatic)

Compaction has three phases, all hook-driven:

**Pre-compact** (PreCompact hook): A hook stamps the compaction summary with the current `.agent/` file status and staleness (tool calls since last write), echoes the same report to stderr so the user sees it, and writes `.agent/LOGS/pre-compact-alert.${SID}.md` as a durable audit trail. This tells post-compaction Claude whether files might be stale.

**Proactive nudge** (before compaction triggers): A hook measures transcript token usage and nudges at three escalating tiers — 🟡 100K (advisory), 🟠 250K (urgent), 🔴 500K (critical; Claude Code's built-in auto-compact fires at ~835K on a 1M window). Each tier fires at most once; the counter resets after an actual compaction. At every tier: **flush all pending context to `.agent/` files first**, then run `/compact`. Post-compaction recovery only has what's on disk.

**Post-compact** (on-compact hook): After compaction, a hook injects `.agent/DECISIONS.md`, `.agent/TASKS.md`, `.agent/LESSONS.md`, the current git state, and the pre-compact `WORKING_CONTEXT.md` (as a stale hint) — i.e. everything `/catchup` would produce, inlined directly into the systemMessage. **Your only required action is:**
1. Run `/rehydrate` — full AI-powered recovery via Gemini/Codex fallback chain, writes a fresh `WORKING_CONTEXT.md`

You do NOT need to run `/catchup` separately after compaction — the orientation is already in the hook's injected message. `/catchup` remains useful for session-start orientation (fresh launch, no compaction event). A 5-minute post-compact grace period suppresses stale-context nags while `/rehydrate` runs, so you won't get double-yelled-at during recovery.

## Workflow: Explore → Plan → Implement → Verify → Commit → Learn → Reflect

**Explore** (read-only)
- Read tools, grep/glob, targeted reads.
- When you Grep or Glob, a hook automatically searches `.agent/` context via poma-memory and injects relevant matches as a system message. No action needed — just search normally and you'll see project context alongside results.
- Large explorations: delegate to Explore subagent or Gemini.

**Plan**
- Files to change, step sequence, verification commands, acceptance criteria.
- When the plan has 3+ tasks, use structured task format (see `.claude/rules/spinouts.md`).
- Check `.agent/LESSONS.md` before planning — don't repeat past mistakes.
- **Search project memory before planning:** if poma-memory MCP is available, call `poma_search` with key terms from the task to surface relevant decisions, context, and patterns. The Grep hook does this automatically during code search, but planning benefits from a deliberate memory check.
- **Think critically.** Question the user's assumptions, identify overlooked risks, and flag when the approach seems wrong — even if the user sounds certain. Substance over agreement.

**Implement**
- Follow the plan. Small diffs. No unrelated refactors.
- When the plan has parallel tasks: spin them out (see `.claude/rules/spinouts.md`).
- **If implementation diverges significantly from the plan, STOP.** Re-assess, update the plan in TASKS.md, and get alignment before continuing. Pushing through a broken plan wastes more than pausing to fix it.

**Verify**
- Run verification commands. For UI: Playwright screenshots + Gemini description.

**Commit**
- Descriptive message. Include what was verified.
- After committing: append a summary to `.agent/FULL_CONTEXT.md`.

**Learn**
- After ANY correction from the user, append a 1–2 line pattern to `.agent/LESSONS.md`: what went wrong, what to do instead.

**Reflect** (periodic)
- After completing a major feature or multi-task plan, take one turn to zoom out: Is the overall approach still sound? Are we solving the right problem? Is complexity growing faster than value? Write a 3–5 line assessment to `FULL_CONTEXT.md`. This catches strategic drift that task-level verification misses.

## Skills

Megavibe provides slash commands for common workflows. Type `/` to see them:
- `/rehydrate` — regenerate WORKING_CONTEXT.md from .agent/ files via Gemini/Codex
- `/catchup` — orient yourself in a project at session start (reads .agent/ + git state)
- `/compact-context` — selectively compact FULL_CONTEXT.md via standard fallback chain (rare, for very large logs)
- `/megavibe-restart` — update megavibe and restart this session with new hooks/rules/skills applied

**Proactive compaction.** A hook measures exact token usage from the conversation transcript and nudges at three escalating tiers: 🟡 100K (advisory), 🟠 250K (urgent), 🔴 500K (critical — auto-compact approaches at ~835K on 1M windows). Each tier fires at most once per session; the counter resets after an actual compaction. At every tier, **flush all pending context to `.agent/` files first, then run `/compact`**. Post-compact recovery (`/rehydrate`) only has what's on disk. For manual FULL_CONTEXT.md cleanup (rare), use `/compact-context` (Gemini-driven selective removal). If context feels stale mid-session, use `/rehydrate`.

## Backend availability check

On every fresh session start, call `mcp__gemini-cli__ping` to test Gemini connectivity. If it fails or Gemini MCP tools are not listed, mark Gemini as **unavailable** for this session and use the Fallback column in the routing table in `.claude/rules/delegation.md`.

Do the same for Codex: attempt a simple Codex tool call. If it fails, mark Codex as unavailable.

If both are unavailable, use the Claude subagent (`.claude/agents/summarizer.md`) as last resort — it always works on the same subscription. Never retry a failed MCP call more than once — switch to the next fallback immediately.

## Output discipline

Prefer: checklists, tables, JSON schemas.
Avoid: long narrative.

Standard schemas:
- `{assumptions, facts[], decisions[], risks[], next_steps[]}`
- `claim | evidence | confidence | action`

**Clipboard on request only.** Never auto-copy to clipboard — it overwrites whatever the user has there. Only copy when the user explicitly asks ("clip", "copy that", "clipboard"). Use the platform's clipboard tool: `pbcopy` (macOS), `xclip -selection clipboard` or `xsel --clipboard` (Linux), `clip.exe` (Windows/WSL). When they do: clean markdown, no hard wraps, no gutter artifacts.

**Respect execution mode.** When the user says "do NOT switch to plan mode" or asks you to execute autonomously/unattended, do NOT use TaskCreate, TaskUpdate, or EnterPlanMode. These tools trigger interactive permission prompts that break autonomous execution — even re-entering bypass mode doesn't suppress them. Just execute directly, reporting progress via text output.

<!-- /megavibe-v3 -->
