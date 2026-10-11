# Subtask Spinouts

When a plan has 3+ tasks, consider spinning independent tasks out to parallel subagents. The primary benefit is **context freshness** — each agent gets a clean window with only the context it needs, avoiding quality degradation from accumulated exploration history.

## When to spin out

Spin out when ALL of these hold:
- 3+ tasks in the plan
- Tasks have **non-overlapping file sets** (no two tasks edit the same file)
- Each task is **self-contained** — doesn't need to import from, or share types/interfaces with, other tasks in the same wave
- Each task is substantial enough to benefit from fresh context (not a one-liner)
- Tasks don't depend on each other's output

Do NOT spin out when:
- Tasks are tightly coupled (A's output feeds B's input)
- Tasks need to modify shared files (index exports, shared type definitions, config files)
- Session context is still fresh (early in session, small codebase)
- A single-file refactor or small change
- You need to see results of task A before planning task B

## Structured task format

When planning for spinouts, add a spinout plan section below the existing tasks in `.agent/TASKS.md`. Do not reformat existing task rows — append the spinout plan separately:

```markdown
## Spinout plan

| # | Task | Files | Verify | Depends | Status |
|---|------|-------|--------|---------|--------|
| 1 | Add auth middleware | src/middleware/auth.ts, src/types/auth.ts | curl -I /protected → 401 | — | pending |
| 2 | Add login route | src/app/api/login/route.ts | curl -X POST → 200 + cookie | 1 | pending |
| 3 | Add signup route | src/app/api/signup/route.ts | curl -X POST → 201 | 1 | pending |
| 4 | Add protected dashboard | src/app/dashboard/page.tsx | browser shows dashboard | 1 | pending |

Waves: [1] → [2, 3, 4]
```

The **Files** column is the coordination mechanism. Before spawning, verify: **no file appears in two tasks within the same wave.**

## Dispatch protocol

1. **Group into waves.** Tasks with no unresolved dependencies AND non-overlapping files go in the same wave. Tasks that share files or depend on an incomplete task go in a later wave. Tasks that modify shared resources (index files, type exports, configs) go in their own wave.

   ```
   Wave 1: [Task 1]            — no deps, runs alone (others depend on it)
   Wave 2: [Task 2] [Task 3] [Task 4]  — all depend on 1, files don't overlap → parallel
   ```

2. **Pre-spawn overlap check.** For each wave, confirm no file appears in two tasks. If overlap exists, move one task to the next wave.

3. **Spawn subagents, pinned to Sonnet by default.** `Explore`, `Plan` and `general-purpose` carry no `model` field of their own — the Agent tool inherits whatever model the parent session is running (measured over September 2026: 76% of all subagent API calls that month ran on Opus/Fable because the calling sessions did, at 2-5x Sonnet's per-token price, for work — file search, mechanical research — that doesn't need it). Pass `model: "sonnet"` explicitly on every spin-out unless the task itself needs top-tier judgment (architecture tradeoffs, ambiguous debugging, anything you'd hesitate to delegate to a human junior) — in that case say so and let it inherit. For a pure read-and-summarize or mechanical-extraction task with no judgment call in it (digest this context, extract these facts, not decide anything), try `model: "haiku"` instead — measured once (2026-10-04, see `delegation.md`'s backend comparison) at comparable quality to the sonnet subagent, fewer tokens, half the per-token price; escalate to sonnet if the output comes back thin. This is a default to override, not a hard rule: when in doubt, Sonnet first, re-run on the parent's model only if the result is visibly thin. For each task in the current wave, launch a `Task` subagent with this prompt structure. Keep the project context brief — summarize `WORKING_CONTEXT.md` to only what's relevant for this specific task, don't paste the whole file:

   ```
   You are implementing a single task in a larger plan. Edit ONLY the files listed.

   ## Project context
   [focused summary of WORKING_CONTEXT.md — only what this task needs to know]

   ## Your task
   Task: [name]
   Files to create/edit: [list — be explicit about create vs edit]
   Action: [what to do]
   Verification: [command + expected output]
   Done when: [acceptance criteria]

   ## Constraints
   - Edit ONLY the files listed above
   - If you discover you need to edit another file, STOP and report it instead
   - Run the verification command before finishing
   - Report: what you changed, verification result, any issues found
   ```

4. **Collect results.** After all tasks in a wave complete:
   - Review each subagent's report
   - If a task failed: decide whether to retry it alone, fix it inline, or abort remaining waves
   - If a task reported needing files outside its scope: handle those edits inline before the next wave
   - Run integration-level verification (build, lint, tests) before proceeding to the next wave

5. **Update `.agent/TASKS.md`** — mark completed tasks, note any issues, proceed.

## Batch jobs: split by context size, not by task count

When one job walks many items that are each judged on their own (checking labels, describing charts, auditing documents) and their tool results are bulky (images, PDFs, long logs), do not let one subagent's context grow far past about 400K tokens. Give each batch of items a fresh subagent instead.
- **Single jobs count too.** This applies even when the job is a single task: the 3+ task gate above is about planning, not context.
- **Dependent items stay together.** Items that must be compared with each other go in the same subagent, with the evidence the comparison needs. A summary handed to the next batch can drop exactly that evidence.
- **Shared output files.** Independent items that write one shared file go to batches in sequence, not in parallel, per the overlap check above.
- **Fan-out and merge.** Fan out in waves of a few at a time, and merge compact verdicts in the parent, never the raw material.
- **When it does not pay.** If the briefing plus first call per subagent would exceed about a third of the cap (about 80K), or the whole job fits under 250K anyway, splitting saves little or nothing: do not split.

**Sizing.** Aim to keep each subagent's context under about 250K tokens. That is a margin below the first observed reset, not a measured safe threshold. A parent cannot see a subagent's context, so estimate it:
- **Count reads and calls, not items.** In the job below, each item took about 34 image reads (author-counted from the transcript), and each call added a median of 22K and a mean of 32K tokens.
- **Run one pilot batch first.** Its context size is the sum of `input_tokens`, `cache_creation_input_tokens` and `cache_read_input_tokens` on its last request, not a sum over the transcript. Size the rest from the pilot's growth per item, with headroom.

**Why, measured 2026-10-11 on one real job** (one Sonnet subagent, 109 image pairs, 3,744 image reads, 387 requests; input tokens only):
- **No re-caching at first.** The context grew to 394K tokens without one.
- **Then repeated resets.** From there, 107 requests read only the 17.6K-token system prefix from cache and re-sent the rest as fresh input. 104 of those came with a shrinking context, most likely Claude Code trimming old tool results; that mechanism is inferred, not confirmed. Later resets came at 375-918K, so the trigger is not one fixed size.
- **Result: 66.5M fresh input tokens and 131M cache reads.** Ordinary calls added 8.8M tokens of new content; about 11M is the estimate counting the reset calls.
- **Projection.** A simulation over the same requests, with a new subagent before 250K (74 subagents, each paying the job's 74K first call again), gives 16.7M fresh and 54M reads. That is 2.8x fewer raw tokens, or 3.7x cheaper weighted by API price (cache read about 0.1x, 5-minute write 1.25x). How either maps onto subscription limits is not documented.
- **Checks, one assumption changed at a time.** Weighted savings: 3.3x keeping the observed cache expiries; 2.2x keeping every observed reset; 2.7x sizing by mean rather than median growth; 2.0x with per-call growth doubled; 2.1x with the briefing doubled.
- **Stacked worst case.** Doubled growth plus doubled briefing gives 1.1x, and adding the expiries and resets gives 0.9x. That case is where the "do not split" condition above comes from.

This is a projection from one job, not a measured re-run. On the realistic reading of the data the saving is about 3x; it holds only while each batch's fixed cost stays small next to the context it saves.

## What NOT to do

- Don't spin out tasks that need to import from each other's new code (they'd fail)
- Don't spin out tasks that both need to update a shared file (index.ts, types.d.ts, package.json)
- Don't use `isolation: "worktree"` unless you actually need merge-based conflict resolution
- Don't add file-locking infrastructure — the plan IS the lock table
- Don't spin out if you'll spend more time partitioning than just doing the work sequentially
- Don't reformat existing TASKS.md rows to match the spinout format — append a new section
