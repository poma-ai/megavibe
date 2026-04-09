---
name: catchup
description: Quick orientation on project state. Reads .agent/ files and git history — no AI calls, finishes in seconds.
allowed-tools: Read, Glob, Grep, Bash
---

# Catch Up on Project State

Fast, read-only orientation. No Gemini/Codex calls — this should finish in seconds.

## Steps

1. **Read TASKS.md first** to determine mode:
   - If ALL tasks are `done` (or TASKS.md has ≤5 lines): **quick mode**
   - If any task is `pending` or `in progress`: **open-tasks mode**

2. **Read project knowledge** (both modes):
   - `.agent/DECISIONS.md` — key decisions with rationale
   - `.agent/LESSONS.md` — patterns from past corrections

3. **Check git state** (both modes):
   - `git log --oneline -10`
   - `git diff --stat` (uncommitted changes)
   - `git branch --show-current`

4. **Open-tasks mode only** — also read:
   - `.agent/FULL_CONTEXT.md` (last 100 lines — recent context around open work)
   - Any session-scoped WORKING_CONTEXT that exists in `.agent/sessions/`

5. **Report to the user:**

   **Quick mode** (all done):
   - Branch, recent commits, any uncommitted changes
   - Key decisions (brief)
   - "All N tasks complete. Ready for a new task."

   **Open-tasks mode:**
   - Branch, uncommitted changes
   - Open tasks with their acceptance criteria (from TASKS.md)
   - Recent context relevant to open tasks (from FULL_CONTEXT.md)
   - Key decisions and lessons
   - Suggest: "Use `/rehydrate` for full AI-powered context recovery if needed."

## When to use

- Starting a new session on a project you've worked on before
- Picking up after a break — especially when there are open tasks
- Joining a project another session was working on

## When NOT to use

- **Right after compaction — the `on-compact` hook already inlined `/catchup`'s output (git state + DECISIONS + TASKS + LESSONS + pre-compact WORKING_CONTEXT) into its systemMessage. Just run `/rehydrate` — that's the only slash command needed post-compact.**
- If you just need to continue exactly where you left off — use `megavibe --resume`
