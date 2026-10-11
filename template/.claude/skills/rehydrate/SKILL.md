---
name: rehydrate
description: Full AI-powered context recovery via Codex or (without Codex) capped Gemini, with the Claude subagent behind. Run `reviewers.sh digest-chain` for the order. Use after compaction or when context feels stale.
---

# Re-hydrate Working Context

Regenerate your session-scoped WORKING_CONTEXT.md from the durable `.agent/` files using the backends `reviewers.sh digest-chain` lists, in that order (Codex → Claude subagent; or, without Codex, capped Gemini → Claude subagent).

This is the heavy-duty recovery tool — it calls an AI backend and writes a fresh working context. For quick orientation without AI calls at **session start**, use `/catchup` instead. After compaction you do NOT need `/catchup`: the `on-compact` hook writes that orientation to `.agent/LOGS/rehydration-instructions.<session>.md` and points you at it, so `/rehydrate` is the only slash command to run.

## Two hard rules (a rehydrate must never stall the session)

A real session once hung for 19 minutes because rehydrate piped a 234 KB `FULL_CONTEXT.md` + 140 KB `DECISIONS.md` to Gemini with no timeout. Don't repeat it:

1. **Cap the input.** Never dump the whole `.agent/` corpus at a backend. Send a bounded slice (step 3). The full files stay the durable source.
2. **Time-bound every backend call.** Wrap it so a stall fails over instead of hanging (step 4). macOS usually lacks `timeout`/`gtimeout`, so the portable form is `perl -e 'alarm shift; exec @ARGV' <secs> <cmd...>`.

## Steps

1. **Determine your session ID and WORKING_CONTEXT path.**
   - If the on-compact hook already told you, use that path.
   - Otherwise your session ID is in the hook stdin JSON (`session_id`); WORKING_CONTEXT lives at `.agent/sessions/{session_id}/WORKING_CONTEXT.md`.

2. **Pick the backend order**: `bash ~/.megavibe/scripts/reviewers.sh digest-chain` prints it — `codex subagent` when `codex exec` works (or the probe cannot tell), `gemini subagent` on a machine without Codex that has `$GEMINI_API_KEY` (and a non-zero Gemini cap), else `subagent`. Try them left to right; the Claude subagent is always last and always works. If `digest-chain` itself errors (an installed script older than this skill), run `codex exec --help >/dev/null 2>&1` and treat success as `codex subagent`.

3. **Assemble a BOUNDED input** via Bash. The caps are in BYTES: line caps do not bound a file whose lines are long, and a whole `TASKS.md` was 4,459 lines in one project, so real inputs reached 451 KB (Gemini's general path refuses above 300 KB):

   ```bash
   SID="<your-session-id>"
   IN=".agent/LOGS/rehydrate-input.${SID}.md"
   {
     echo "# git";    git status --short --branch 2>&1 | head -40 | head -c 8000; echo; git diff --stat 2>&1 | tail -30 | tail -c 4000
     echo; echo "# TASKS.md (whole up to 60 KB, else first and last 30 KB: the top is the where-we-stand section)"
     if [ "$(wc -c < .agent/TASKS.md 2>/dev/null || echo 0)" -le 60000 ]; then cat .agent/TASKS.md 2>/dev/null
     else head -c 30000 .agent/TASKS.md; echo; echo "...[middle elided — see file]..."; tail -c 30000 .agent/TASKS.md; fi
     echo; echo "# LESSONS.md (most recent 20 KB)";     tail -c 20000 .agent/LESSONS.md   2>/dev/null
     echo; echo "# DECISIONS.md (most recent 40 KB)";   tail -c 40000 .agent/DECISIONS.md 2>/dev/null
     echo; echo "# FULL_CONTEXT.md (origin + most recent 70 KB)"
     head -c 3000 .agent/FULL_CONTEXT.md 2>/dev/null; echo; echo "...[older entries elided — see file]..."
     tail -c 70000 .agent/FULL_CONTEXT.md 2>/dev/null
   } > "$IN"
   wc -c "$IN"   # about 200 KB at most; a cut at the start of a section can split one line, which is harmless
   ```

4. **Call the backend, time-bounded**, into a staging file that is promoted to WORKING_CONTEXT only once it is a real answer. A failed or cut-off backend must never touch the canonical file: a hook treats a fresh non-empty WORKING_CONTEXT as "rehydration done" and stops reminding you.

   ```bash
   OUT=".agent/sessions/${SID}/WORKING_CONTEXT.md"; mkdir -p "$(dirname "$OUT")"
   INSTR="Read the project state below and write a WORKING_CONTEXT.md (max 400 lines) with these six sections, each as a '## ' heading: Goal; Constraints (must-not-break); What's Done (files touched); Open Tasks (+acceptance criteria); Risks/Unknowns; Next Actions (3 concrete). Output ONLY the markdown."
   # Codex at low effort. Measured 2026-09-18 on a 196 KB input: 23s and 76
   # lines on a small model. Effort is the wrong knob here (94 reasoning tokens
   # even at `high` — digesting a log does not reason), so `low` is free. The
   # wrapper owns its own timeout and kills the whole process group, so there is
   # no orphan and no argv limit.
   NEW="$OUT.new"
   # promote <exit code of the backend that wrote $NEW>: moves $NEW over $OUT only
   # if the backend succeeded and all six sections are present, each with text
   # under it (deeper ### subheadings stay inside their section).
   promote() {
     local ok=0
     [ "$1" -eq 0 ] && [ -f "$NEW" ] && [ -s "$NEW" ] && [ ! -d "$OUT" ] && ok=1
     awk 'BEGIN{n=split("goal constraint done open risk next",k," ")}
          /^#+ /{lv=index($0," ")-1; l=tolower($0); hit=""
                 for(i=1;i<=n;i++) if(index(l,k[i])){hit=k[i]; break}
                 if(hit!=""){cur=hit; clv=lv} else if(cur!="" && lv<=clv){cur=""}
                 next}
          NF && cur!=""{body[cur]=1}
          END{for(i=1;i<=n;i++) if(!(k[i] in body)) exit 1}' "$NEW" 2>/dev/null || ok=0
     if [ "$ok" -eq 1 ] && mv -f "$NEW" "$OUT"; then rm -f "$OUT.err"; echo promoted; return 0; fi
     echo "backend failed (rc $1, or sections missing)"; return 1
   }
   : > "$NEW"
   bash ~/.megavibe/scripts/codex-review.sh --effort low \
     --timeout 150 --out "$NEW" --prompt "$INSTR" "$IN" >/dev/null 2>"$OUT.err"
   promote $?
   ```

   No `--model`: the user's own `~/.codex/config.toml` picks it, and a name
   pinned here would fail every rehydration on any plan that does not expose it,
   pushing this to the Claude subagent and ~125K tokens of the session's own
   quota. If a small model is available and you want the speed, `--model` it —
   `gpt-5.6-terra` measured fastest here — but re-run without the flag if that
   call fails rather than falling down the chain on a model name.

   - `backend failed` (non-zero exit, incl. the wrapper's 124 timeout, an empty answer, or one missing any of the six required sections or the text under one) = that backend FAILED. Don't retry it — move down the chain, again writing to `$NEW` and promoting only a valid answer.
   - **Fallback order** is whatever `digest-chain` printed in step 2. With Codex: Codex (above) → **Claude subagent** (Agent tool, `subagent_type: summarizer` — internal, cannot hang, always finishes, and the best output of the three; it spends this subscription's own quota, ~125K tokens on an input this size, which is why it is second and not first). **Without Codex** (`gemini subagent`): Gemini first — `: > "$NEW"; perl -e 'alarm shift; exec @ARGV' 150 bash ~/.megavibe/scripts/gemini-review.sh --max 12000 --out "$NEW" --prompt "$INSTR" "$IN"; promote $?`, then `rm -f "$NEW.raw.json"` — then the subagent (give it the same instruction; empty `$NEW` first, it writes its answer there with Bash or returns it for you to write there, then `promote 0`). Gemini here is the metered alternative: flash-lite only, never Pro, and `gemini-review.sh` itself refuses (exit 5) once today's call, dollar or input-size cap is reached, or (exit 4) while Codex is usable; treat both as "that backend failed" and move on to the subagent. Exit 3 (cut off) leaves a partial `$NEW`: do not promote it; move on to the subagent. Check `finishReason` in the `.err` before trusting a short answer. `gemini-review.sh --budget` shows today's spend. Never the Gemini CLI or `mcp__gemini-cli__ask-gemini` here: both run full thinking on a large input and stall.

5. **Verify + load.** Confirm `$OUT` was promoted (non-empty, the requested sections), then Read it into your window **in full**: one Read call with no `offset`/`limit` (it is at most ~400 lines). Reading only its head was the common failure in practice (8 of 17 real runs), and leaves you working from the compaction summary after all. If every external backend failed AND the subagent is unavailable, hand-write a minimal WORKING_CONTEXT from TASKS.md + git state rather than leaving it empty.

## Rules

- Never regenerate from an old WORKING_CONTEXT alone — always re-derive from the (bounded) log + repo state.
- Write WORKING_CONTEXT to the session-scoped path, not the project root.
- A rehydrate that stalls is worse than one that falls back down the chain — honor the two hard rules above.
- If poma-memory MCP is available, also call `poma_search` with key terms from TASKS.md to supplement the input.

## When to use

- After context compaction (the on-compact hook will tell you)
- When context feels stale or confused after many tool calls
- When `/catchup` isn't enough — you need full AI-powered recovery
