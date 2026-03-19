---
name: rehydrate
description: Full AI-powered context recovery via Gemini/Codex. Use after compaction or when context feels stale.
---

# Re-hydrate Working Context

Regenerate your session-scoped WORKING_CONTEXT.md from the durable `.agent/` files using Gemini or Codex.

This is the heavy-duty recovery tool — it calls an AI backend and writes a fresh working context. For quick orientation without AI calls, use `/catchup` instead.

## Steps

1. **Determine your session ID and WORKING_CONTEXT path.**
   - If the on-compact hook already told you, use that path.
   - Otherwise: your session ID is in the hook stdin JSON (`session_id` field). Your WORKING_CONTEXT lives at `.agent/sessions/{session_id}/WORKING_CONTEXT.md`.
   - Create the session directory if it doesn't exist: `mkdir -p .agent/sessions/{session_id}/`

2. **Check backend availability** (standard fallback chain):
   - Call `mcp__gemini-cli__ping`. If it responds, use Gemini.
   - If Gemini MCP fails and `$GEMINI_API_KEY` is set, use it via curl.
   - If both Gemini paths fail, try Codex MCP.
   - If ALL external backends fail, use the Claude subagent as last resort: launch an Agent (model: sonnet) with the summarization prompt. This always works — same subscription.

3. **Gather inputs.** Read these files:
   - `.agent/FULL_CONTEXT.md`
   - `.agent/DECISIONS.md`
   - `.agent/TASKS.md`
   - `.agent/LESSONS.md`
   - Run `git status` and `git diff --stat` via Bash.

4. **Send to the backend** with this prompt:

   > Read these project files and regenerate a WORKING_CONTEXT.md (max 400 lines) with these sections:
   > - **Goal** — current objective
   > - **Constraints** — must-not-break list
   > - **What's Done** — files touched, changes landed
   > - **Open Tasks** — with acceptance criteria
   > - **Risks / Unknowns**
   > - **Next Actions** — 3 concrete next steps

5. **Write the result** to `.agent/sessions/{session_id}/WORKING_CONTEXT.md`.

6. **Read the file** to load the fresh context into your window.

## Rules

- Never regenerate from an old WORKING_CONTEXT alone. Always re-derive from the full log + repo state.
- Write WORKING_CONTEXT to the session-scoped path, not the project root.
- If poma-memory MCP is available, also call `poma_search` with key terms from TASKS.md to supplement the backend's input.

## When to use

- After context compaction (the on-compact hook will tell you)
- When context feels stale or confused after many tool calls
- When `/catchup` isn't enough — you need full AI-powered recovery
