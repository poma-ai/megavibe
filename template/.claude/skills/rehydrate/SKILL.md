---
name: rehydrate
description: Full AI-powered context recovery via Gemini/Codex. Use after compaction or when context feels stale.
---

# Re-hydrate Working Context

Regenerate your session-scoped WORKING_CONTEXT.md from the durable `.agent/` files using Gemini or Codex.

This is the heavy-duty recovery tool — it calls an AI backend and writes a fresh working context. For quick orientation without AI calls at **session start**, use `/catchup` instead. After compaction you do NOT need `/catchup` — the `on-compact` hook already inlined that orientation into its systemMessage, so `/rehydrate` is the only slash command to run.

## Two hard rules (a rehydrate must never stall the session)

A real session once hung for 19 minutes because rehydrate piped a 234 KB `FULL_CONTEXT.md` + 140 KB `DECISIONS.md` to Gemini with no timeout. Don't repeat it:

1. **Cap the input.** Never dump the whole `.agent/` corpus at a backend. Send a bounded slice (step 3). The full files stay the durable source.
2. **Time-bound every backend call.** Wrap it so a stall fails over instead of hanging (step 4). macOS usually lacks `timeout`/`gtimeout`, so the portable form is `perl -e 'alarm shift; exec @ARGV' <secs> <cmd...>`.

## Steps

1. **Determine your session ID and WORKING_CONTEXT path.**
   - If the on-compact hook already told you, use that path.
   - Otherwise your session ID is in the hook stdin JSON (`session_id`); WORKING_CONTEXT lives at `.agent/sessions/{session_id}/WORKING_CONTEXT.md`.

2. **Check backend availability** (standard fallback chain): `mcp__gemini-cli__ping` → `$GEMINI_API_KEY` curl → Codex MCP → Claude subagent (always works).

3. **Assemble a BOUNDED input** via Bash (caps keep it well under any backend limit and fast):

   ```bash
   SID="<your-session-id>"
   IN=".agent/LOGS/rehydrate-input.${SID}.md"
   {
     echo "# git";    git status --short --branch 2>&1 | head -40; git diff --stat 2>&1 | tail -30
     echo; echo "# TASKS.md";              cat  .agent/TASKS.md      2>/dev/null
     echo; echo "# LESSONS.md (recent)";   tail -200 .agent/LESSONS.md  2>/dev/null
     echo; echo "# DECISIONS.md (recent)"; tail -300 .agent/DECISIONS.md 2>/dev/null
     echo; echo "# FULL_CONTEXT.md (origin + recent)"
     head -30  .agent/FULL_CONTEXT.md 2>/dev/null; echo "...[older entries elided — see file]..."
     tail -500 .agent/FULL_CONTEXT.md 2>/dev/null
   } > "$IN"
   wc -c "$IN"   # sanity-check: if much over ~200 KB, tighten the tails and rebuild
   ```

4. **Call the backend, time-bounded**, writing straight to WORKING_CONTEXT:

   ```bash
   OUT=".agent/sessions/${SID}/WORKING_CONTEXT.md"; mkdir -p "$(dirname "$OUT")"
   PROMPT=$(printf '%s\n\n%s' \
     "Read the project state below and write a WORKING_CONTEXT.md (max 400 lines) with sections: Goal; Constraints (must-not-break); What's Done (files touched); Open Tasks (+acceptance criteria); Risks/Unknowns; Next Actions (3 concrete). Output ONLY the markdown." \
     "$(cat "$IN")")
   perl -e 'alarm shift; exec @ARGV' 150 gemini -p "$PROMPT" > "$OUT" 2>/dev/null
   ```

   - Non-zero exit (incl. SIGALRM timeout) **or** an empty `$OUT` = that backend FAILED. Don't retry it — move down the chain.
   - **Fallback order:** Gemini CLI → `$GEMINI_API_KEY` curl (`--max-time 150`) → Codex (`perl -e 'alarm shift; exec @ARGV' 150 codex exec "$PROMPT"`) → **Claude subagent** (Agent tool, model sonnet — internal, cannot hang, always finishes).
   - You MAY use `mcp__gemini-cli__ask-gemini` instead, but it is NOT time-boundable from here. If it doesn't return within ~3 min, abandon it and use the Bash path above — do not keep waiting.

5. **Verify + load.** Confirm `$OUT` is non-empty and contains the requested sections, then Read it into your window. If every external backend failed AND the subagent is unavailable, hand-write a minimal WORKING_CONTEXT from TASKS.md + git state rather than leaving it empty.

## Rules

- Never regenerate from an old WORKING_CONTEXT alone — always re-derive from the (bounded) log + repo state.
- Write WORKING_CONTEXT to the session-scoped path, not the project root.
- A rehydrate that stalls is worse than one that falls back to the Claude subagent — honor the two hard rules above.
- If poma-memory MCP is available, also call `poma_search` with key terms from TASKS.md to supplement the input.

## When to use

- After context compaction (the on-compact hook will tell you)
- When context feels stale or confused after many tool calls
- When `/catchup` isn't enough — you need full AI-powered recovery
