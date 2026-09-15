---
name: init-feature
description: Scope a feature before any code is written — a what-to-do summary, a complexity and token estimate from countable evidence, then a fork the user chooses: write a spec, or vibe it. Use when the user types /init-feature, or explicitly asks to scope, size, estimate, or "init" a feature before building it. Do NOT use for a plain request to build, add, fix or start something — that is ordinary work, not a scoping run.
allowed-tools: Read, Glob, Grep, Bash, Write, Agent, Skill, AskUserQuestion
argument-hint: "<feature description>"
---

# Init feature

Turn a feature description into a scoped brief, a cost estimate, and a routing decision the user makes. Nothing is built here.

The feature description is whatever came with the invocation — `$ARGUMENTS` when it is interpolated, otherwise the user's own message. If there is none, ask for one or two sentences and stop until they answer; everything below depends on it.

**If this session cannot take interactive input** — `claude -p`, a scheduled or unattended run, or `AskUserQuestion` is unavailable or errors when Step 4 calls it — do Steps 1–3, print the brief with the recommended route, and stop there. Step 4's question has no one to answer it, and picking the route yourself is the one thing this skill must not do.

## Step 1 — Bounded exploration (read-only)

Budget: **~15 tool calls, hard cap**. You are estimating a cost; do not spend it up front. Grep for touch points and read only the hit regions — never whole files. If the feature crosses several subsystems or the repo is unfamiliar, delegate one `Explore` agent with breadth "medium" instead of fanning out yourself, so the file dumps stay out of this context.

Where `.agent/` exists, also skim `DECISIONS.md` and `LESSONS.md` for prior art on the same area.

Record these, because Step 3 is arithmetic on them:

- `N_files` — files to edit or create
- `L_touched` — lines you will actually have to read in them (hit regions plus surrounding context, not `wc -l` of the whole file)
- `L_docs` — lines of standard docs the work requires reading: `CLAUDE.md`, the rules, any README the change touches. This term usually dominates and is the one that gets forgotten.
- `L_changed` — lines added or modified, as a number you commit to
- `NEW` — new modules or subsystems introduced
- `CROSS` — yes/no: does it change an interface something else depends on (schema, wire protocol, hook contract, public API, installed template)
- `TESTS` — does a verification path already exist, or must one be built

## Step 2 — Summary of what to do

Ten lines or fewer:

- **Goal** — one sentence, the outcome not the mechanism
- **Approach** — 3–6 ordered bullets
- **Touch points** — table: `file | change | risk`
- **Unknowns** — at most 3, each with the one command or question that resolves it

No code, no edits, no branch. If the description is ambiguous in a way that changes the shape of the work, name the ambiguity as an unknown rather than picking silently.

## Step 3 — Complexity and token estimate

Size from the Step 1 counts. Read the table **top down and stop at the first row where any criterion matches** — the rows are thresholds, not a partition, so order is what makes the answer unique. S is the fallback, so every input lands somewhere.

| Size | Any one of | Route it suggests |
|------|------------|-------------------|
| **XL** | >25 files · >2000 changed lines · unknowns outnumber knowns | spec, split into phases |
| **L** | >10 files · >600 changed lines · `CROSS` yes · 2+ new modules | spec |
| **M** | >3 files · >150 changed lines · 1 new module · 2+ unknowns | vibe |
| **S** | everything else | vibe |

Token estimate — show the arithmetic, not just the answer:

```
session = (L_touched + L_docs) × 20  +  L_changed × 25  +  25000
review  = R × ((L_touched + L_docs) × 20  +  L_changed × 12  +  8000)
```

- **20 tokens/line** is a midpoint, not a constant. Source and shell measure 9–12 tokens per line; prose markdown 15–38. Skew it toward the material the feature actually sits in and say which you used.
- **25 tokens per changed line** covers draft, re-read and fix churn — writing a line costs several times reading one.
- **25000** is orchestration: tool results, conversation, the parts of the session that exist regardless of feature size.
- **A reviewer re-reads the standard before the diff** — non-negotiable 4 requires it — so `review` carries the same `L_docs` term `session` does. In a repo with a real protocol that preload alone is 20–30k per reviewer, and leaving it out understates the review by about half. The trailing **8000** is the reviewer's prompt and report, not its reading.
- **Report three lines, not one number.** `session` is this conversation's context. The `reviewer` subagent's share of `review` is a separate window on the same subscription quota. Gemini's and Codex's share is API spend outside the subscription entirely. An all-in figure is fine if you label it as spanning all three — never present it as context you are about to consume.
- **`R` counts reviewers that are both switched on and available**, which are different questions. Switched on: `bash ~/.megavibe/scripts/reviewers.sh list 2>/dev/null`. Available: `reviewer` always; `gemini` only if `$GEMINI_API_KEY` is set; `codex` only if `codex exec --help` succeeds. If the script is missing, megavibe is not installed here — `R = 1`. A Claude-only user carries `R = 1`, and assuming 3 inflates the headline by tens of thousands of tokens.

Report each line as a **range, `÷2` to `×3`**, with the assumptions under it. The dominant variance is how many exploration rounds the implementation needs, and that is not knowable now — say so. Give effort in turns or sessions, never days or weeks.

## Step 4 — Ask the user how to proceed

`AskUserQuestion`, one question, two options. Put the one the Step 3 size suggests first, marked `(Recommended)`:

- **Create a spec** — write the design down and review it before any code
- **Vibe it** — go straight to Explore → Plan → Implement → Verify

Do not choose for the user and do not start work until they answer. This fork is the point of the skill.

## Step 5a — Spec path

**i. Find the spec skills that already exist.** Do not assume; look. Use `find`, not a glob — under zsh an unmatched glob aborts the whole command and `2>/dev/null` does not save it, so the `ls` form silently reports "no spec skills found" in any project missing one of these directories:

```sh
find ~/.claude/skills .claude/skills -maxdepth 2 -name 'SKILL.md' 2>/dev/null || true
find ~/.claude/commands .claude/commands -maxdepth 1 -name '*.md' 2>/dev/null || true
```

Match `SKILL.md` exactly under the skills roots — a bare `*.md` also returns things like `SKILL_old.md`, which is not invocable and fails if offered and chosen.

Add any skill from this session's available-skills list whose description mentions spec, plan, design, architecture or PRD — plugin skills never appear on disk. Keep the candidates that genuinely cover speccing; read the frontmatter `description` rather than guessing from the filename. **Exclude `init-feature` itself** — its own description says "write a spec", so it matches its own filter and would recurse.

**ii. Ask which to use.** `AskUserQuestion` with up to three candidates plus **"Let the agent design the orchestration"**. Only skip this question if the search genuinely returned nothing — say so in one line and go to iii.

Chosen skill → invoke it with the `Skill` tool, passing the feature description **and** the Step 2 summary. Do not make it re-derive scope you already paid for.

**iii. Agent-designed orchestration.** Print the plan as one table, then run it — no second approval gate:

| agent | role | input | output |
|-------|------|-------|--------|

Constraints on the design:

- Drafters follow scope. Use only agents that exist — check `.claude/agents/`, `~/.claude/agents/`, and this session's available agent types before naming one.
- Reviewers follow non-negotiable 4 and the `MEGAVIBE_REVIEWERS` allow-list. A reviewer that is switched off is absent, not failed; one that is unavailable is named as missing.
- **Parallel drafters never share a file.** A spec is one document, so per `.claude/rules/spinouts.md` they cannot draft it concurrently: give each drafter its own section file under `.agent/PLANS/<slug>/` — or a `<slug>/` directory beside the spec where there is no `.agent/` — then merge serially in a final step. One drafter needs no wave at all.
- Terminate at **2 review rounds**. Unresolved concerns go to the spec's Open Questions, not into another round.
- Spec lands at `.agent/PLANS/YYYY-MM-DD-<slug>-spec.md`, or the project root if there is no `.agent/` — do not create one.

## Step 5b — Vibe path

Straight into the protocol workflow: Explore → Plan → Implement → Verify → Commit. No spec document. The Step 2 summary is the plan. Verification commands and independent review still apply — vibing skips the design document, not the evidence.

## Artifact

The brief is the Step 2 summary, the Step 3 estimate with the counts it was computed from, and the route the user chose.

If an `.agent/` directory already exists in the project root, write it to `.agent/PLANS/YYYY-MM-DD-<slug>-brief.md` and log one line:

```sh
printf 'init-feature: <slug> — sized <S|M|L|XL>, est <range> tokens, route <spec|vibe>' | .claude/hooks/agent-log.sh append
```

Never create `.agent/` to hold it — a project without one has opted out of context management, and there the brief just stays in the conversation.

When the feature actually lands, write a **new** log entry quoting the original estimate beside the observed cost. Never edit the first entry — non-negotiable 3 makes the event log append-only. An estimate nobody scores against reality never gets better.

## Rules

- Read-only until the user answers Step 4.
- Cap the exploration. Burning 80k tokens to estimate an 80k-token feature is a failure of the skill.
- Every estimate is a range with its assumptions stated. Never present a single number as a measurement.
- Do not enter plan mode *inside this skill* — it already has its own approval gate, and `ExitPlanMode` would stall on top of it. The implementation that follows is unaffected.
