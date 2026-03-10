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

3. **Spawn subagents.** For each task in the current wave, launch a `Task` subagent with this prompt structure. Keep the project context brief — summarize `WORKING_CONTEXT.md` to only what's relevant for this specific task, don't paste the whole file:

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

## What NOT to do

- Don't spin out tasks that need to import from each other's new code (they'd fail)
- Don't spin out tasks that both need to update a shared file (index.ts, types.d.ts, package.json)
- Don't use `isolation: "worktree"` unless you actually need merge-based conflict resolution
- Don't add file-locking infrastructure — the plan IS the lock table
- Don't spin out if you'll spend more time partitioning than just doing the work sequentially
- Don't reformat existing TASKS.md rows to match the spinout format — append a new section
