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

## Session isolation

Multiple Claude Code sessions can run in the same project simultaneously. To prevent races:
- **Shared files** (append-only, project-level truth): `FULL_CONTEXT.md`, `DECISIONS.md`, `TASKS.md`, `LESSONS.md`, `RESEARCH/`
- **Session-scoped files**: `WORKING_CONTEXT.md` lives at `.agent/sessions/{session_id}/WORKING_CONTEXT.md`. Hook counters and flags are also per-session.

The on-compact hook tells you your session ID and WORKING_CONTEXT path. Use the path it gives you.

## Auto-triggered re-hydration

When Claude Code compacts the context, a hook injects `.agent/DECISIONS.md`, `.agent/TASKS.md`, and your session-scoped `WORKING_CONTEXT.md` as context, plus an instruction to call Gemini (or Codex) for full re-hydration. The hook triggers automatically; you execute the call.

**When you see the re-hydration instruction, follow it immediately** using the standard fallback chain:
1. Try Gemini MCP → `$GEMINI_API_KEY` curl → Codex MCP → Claude subagent (last resort, always works).
2. Ask it to read `.agent/FULL_CONTEXT.md` + `.agent/DECISIONS.md` + `.agent/TASKS.md` + `git status` output.
3. Ask it to write a fresh `WORKING_CONTEXT.md` at the session-scoped path provided by the hook (max ~400 lines).
4. Read the regenerated file and continue working.

This is auto-triggered — no human intervention needed, but you must follow through. A hook nags via stderr on every tool call until `WORKING_CONTEXT.md` is updated.

## Workflow: Explore → Plan → Implement → Verify → Commit → Learn → Reflect

**Explore** (read-only)
- Read tools, grep/glob, targeted reads.
- When you Grep, a hook automatically searches `.agent/` context and injects relevant matches. No action needed — just use Grep normally and you'll see project context alongside code results.
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

**Proactive compaction.** A hook measures exact token usage from the conversation transcript. When context exceeds ~120K tokens, it nudges you to run `/compact`. **Follow the nudge** — your `.agent/` files and poma-memory already have everything; compaction just clears the conversation buffer so you get a fresh, focused working context via the on-compact recovery hook. For manual FULL_CONTEXT.md cleanup (rare), use `/compact-context` (Gemini-driven selective removal). If context feels stale mid-session, use `/rehydrate`.

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
