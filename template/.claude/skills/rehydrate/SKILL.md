---
name: rehydrate
description: Full AI-powered context recovery via Codex, the Claude subagent, or Gemini. Use after compaction or when context feels stale.
---

# Re-hydrate Working Context

Regenerate your session-scoped WORKING_CONTEXT.md from the durable `.agent/` files using Codex, the Claude subagent, or Gemini — in that order.

This is the heavy-duty recovery tool — it calls an AI backend and writes a fresh working context. For quick orientation without AI calls at **session start**, use `/catchup` instead. After compaction you do NOT need `/catchup` — the `on-compact` hook already inlined that orientation into its systemMessage, so `/rehydrate` is the only slash command to run.

## Two hard rules (a rehydrate must never stall the session)

A real session once hung for 19 minutes because rehydrate piped a 234 KB `FULL_CONTEXT.md` + 140 KB `DECISIONS.md` to Gemini with no timeout. Don't repeat it:

1. **Cap the input.** Never dump the whole `.agent/` corpus at a backend. Send a bounded slice (step 3). The full files stay the durable source.
2. **Time-bound every backend call.** Wrap it so a stall fails over instead of hanging (step 4). macOS usually lacks `timeout`/`gtimeout`, so the portable form is `perl -e 'alarm shift; exec @ARGV' <secs> <cmd...>`.

## Steps

1. **Determine your session ID and WORKING_CONTEXT path.**
   - If the on-compact hook already told you, use that path.
   - Otherwise your session ID is in the hook stdin JSON (`session_id`); WORKING_CONTEXT lives at `.agent/sessions/{session_id}/WORKING_CONTEXT.md`.

2. **Check backend availability** (standard chain): `codex exec --help` succeeds (→ `codex-review.sh`) → Claude subagent (always works) → `$GEMINI_API_KEY` set (→ `gemini-review.sh`).

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
   INSTR="Read the project state below and write a WORKING_CONTEXT.md (max 400 lines) with sections: Goal; Constraints (must-not-break); What's Done (files touched); Open Tasks (+acceptance criteria); Risks/Unknowns; Next Actions (3 concrete). Output ONLY the markdown."
   # Codex at low effort. Measured 2026-09-18 on a 196 KB input: 23s and 76
   # lines on a small model. Effort is the wrong knob here (94 reasoning tokens
   # even at `high` — digesting a log does not reason), so `low` is free. The
   # wrapper owns its own timeout and kills the whole process group, so there is
   # no orphan and no argv limit.
   bash ~/.megavibe/scripts/codex-review.sh --effort low \
     --timeout 150 --out "$OUT" --prompt "$INSTR" "$IN" >/dev/null 2>"$OUT.err" || : > "$OUT"
   [ -s "$OUT" ] && rm -f "$OUT.err"   # keep the .err only when it failed
   ```

   No `--model`: the user's own `~/.codex/config.toml` picks it, and a name
   pinned here would fail every rehydration on any plan that does not expose it,
   pushing this to the Claude subagent and ~125K tokens of the session's own
   quota. If a small model is available and you want the speed, `--model` it —
   `gpt-5.6-terra` measured fastest here — but re-run without the flag if that
   call fails rather than falling down the chain on a model name.

   - Non-zero exit (incl. the wrapper's 124 timeout) **or** an empty `$OUT` = that backend FAILED. Don't retry it — move down the chain.
   - **Fallback order:** Codex (above) → **Claude subagent** (Agent tool, `subagent_type: summarizer` — internal, cannot hang, always finishes, and the best output of the three; it spends this subscription's own quota, ~125K tokens on an input this size, which is why it is second and not first) → **Gemini** (`perl -e 'alarm shift; exec @ARGV' 150 bash ~/.megavibe/scripts/gemini-review.sh --max 12000 --out "$OUT" --prompt "$INSTR" "$IN"`, then `rm -f "$OUT.raw.json"`) — every Gemini token is billed, and on a job this size `--max 12000` counts thinking too, so check `finishReason` in the `.err` before trusting a short answer. Never the Gemini CLI or `mcp__gemini-cli__ask-gemini` here: both run full thinking on a large input and stall.

5. **Verify + load.** Confirm `$OUT` is non-empty and contains the requested sections, then Read it into your window. If every external backend failed AND the subagent is unavailable, hand-write a minimal WORKING_CONTEXT from TASKS.md + git state rather than leaving it empty.

## Rules

- Never regenerate from an old WORKING_CONTEXT alone — always re-derive from the (bounded) log + repo state.
- Write WORKING_CONTEXT to the session-scoped path, not the project root.
- A rehydrate that stalls is worse than one that falls back down the chain — honor the two hard rules above.
- If poma-memory MCP is available, also call `poma_search` with key terms from TASKS.md to supplement the input.

## When to use

- After context compaction (the on-compact hook will tell you)
- When context feels stale or confused after many tool calls
- When `/catchup` isn't enough — you need full AI-powered recovery
