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

A job that walks many images or large files (checking labels, describing charts, auditing documents) must not run in one long subagent. Split the items into batches and give each batch its own subagent, sized so its context stays under about 250K tokens (tens of images, not hundreds). Run them in parallel and merge the results in the parent.

Why, measured 2026-10-11 on one real job (one Sonnet subagent checking 109 image pairs, 3,744 image reads, 387 calls):
- The context grew to about 395K tokens with no re-caching at all. Past that point the earlier history kept changing (the context shrank each time, so most likely Claude Code trimming old tool results to make room; the mechanism was inferred, not confirmed), and every change made the next call re-send the whole context as fresh input. That happened 108 times, re-sending 155-866K tokens each.
- Result: 66.5M fresh input tokens and 131M cache reads. The new content the job actually needed was about 9M.
- Re-running the same calls through a simulation with a new subagent before 350K (each paying the job's 74K first call again) gave 14.4M fresh and 72M reads. That is 2.3x fewer tokens in raw count, or 3.8x cheaper weighted by API price (a cache read is about 0.1x, a write 1.25x). Either way it wins.

This applies wherever a context fills with bulky tool results: images, PDFs, long logs. The limit is context size, so a batch of 10 small text files needs no split. Brief each batch subagent with the full standard and only its own items, and have it return compact verdicts, not the raw material.

## What NOT to do

- Don't spin out tasks that need to import from each other's new code (they'd fail)
- Don't spin out tasks that both need to update a shared file (index.ts, types.d.ts, package.json)
- Don't use `isolation: "worktree"` unless you actually need merge-based conflict resolution
- Don't add file-locking infrastructure — the plan IS the lock table
- Don't spin out if you'll spend more time partitioning than just doing the work sequentially
- Don't reformat existing TASKS.md rows to match the spinout format — append a new section
