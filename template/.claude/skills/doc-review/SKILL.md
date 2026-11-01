---
name: doc-review
description: Independent multi-reviewer review of the project's MD doc set for drift, contradictions, dead pointers, and bloat. Sends CLAUDE.md + every README*.md to the allocated ship readers per delegation.md in parallel; synthesizes findings into a single report.
allowed-tools: Bash, Read, Write, Agent
---

# Doc-review (periodic doc hygiene)

Send the project's full markdown documentation surface to the readers allocated for a ship round under `.claude/rules/delegation.md`, "Two review tiers" (including its availability/failure floor), for an independent challenge. Eligibility is not allocation. Synthesize the completed reviews into a single findings report. The user decides which findings to act on.

## When to use

After significant docs or code edits that change the documentation surface — `/init` of a new project, a feature that touched multiple files, a noticeable CLAUDE.md or README growth spurt. Not every session.

## Steps

1. **Gather the MD set.** From the project root:
   ```sh
   ls CLAUDE.md README*.md 2>/dev/null
   find docs -maxdepth 2 -name '*.md' 2>/dev/null
   ```
   Most projects: just `CLAUDE.md` plus zero or more `README*.md` at the root. Adapt if the project uses a `docs/` folder. If only `CLAUDE.md` exists, the review is still useful — focus on bloat and drift-vs-code.

2. **Allocate each reader, then launch in PARALLEL** with the SAME files and the SAME prompt. Follow `.claude/rules/delegation.md` for continuous weighing, eligibility, ship composition and fallback; the session-start Reviewers row lists eligible backends, not mandatory calls. For an allocated subagent use Agent with `subagent_type: reviewer`, or `general-purpose` with `model: sonnet` and the text of `.claude/agents/reviewer.md` if it is not registered. For each allocated Codex reader use `bash ~/.megavibe/scripts/codex-review.sh --as-reviewer --timeout 600 --prompt "<prompt>" <files>`, selecting different models with `--model` for a two-Codex pair. Use Bash, not the removed Codex MCP. Launch long Codex calls with `run_in_background` and separate heartbeats. For permitted Gemini calls use `bash ~/.megavibe/scripts/gemini-review.sh --as-reviewer --pro --prompt "<prompt>" <files>`, adding `--fallback` only under the fallback rule; never use Gemini MCP or CLI for reviews. The prompt:

   > Review the attached project documentation set. For each finding, output `{category, file:line, what's wrong, suggested fix}`. Categories:
   >
   > 1. **Drift** — claims that no longer match the code or each other (verify against actual source where you can)
   > 2. **Contradictions** — places where two docs disagree
   > 3. **Dead pointers** — references to files, functions, or READMEs that don't exist
   > 4. **Bloat** — content that should be extracted into a dedicated `README-<topic>.md` per the rule-index-not-encyclopedia pattern (sections >~30 lines, file structure tables, detailed pipeline descriptions inside CLAUDE.md)
   > 5. **Underdocumented gotchas** — code patterns that look important but aren't called out
   >
   > Be specific and concise. Do not propose stylistic rewrites — only substantive issues.

3. **Missing reviewers.** Apply the availability/failure floor in `.claude/rules/delegation.md`; report which allocated readers actually answered, replacements and any shortfall. A skipped or failed call is not a completed review. Never substitute `summarizer` for `reviewer`, and never treat a switched-off backend as an outage to work around.

4. **Synthesize.** Merge the reports into a single output, grouped by category. For each finding:
   - Note how many reviewers flagged it — **all** or **two** (high-confidence) vs **one** (check it yourself before acting)
   - Preserve the file:line reference
   - Keep the suggested fix terse — one or two lines

5. **Report only.** Do NOT auto-apply fixes. Present the synthesis to the user; they choose which to act on.

## Rules

- **Parallel, not sequential.** Issue every call for the allocated set in one message — half the wall time, and it avoids one reviewer's framing biasing the next. Failure replacements follow the failed call; every replacement still reviews the same final candidate in full. When the user has pinned `all`, Gemini is a peer and goes in the parallel batch like everything else.
- The **synthesis** is the value. Don't dump raw outputs from each backend; the merged view is what the user reads.
- Avoid stylistic noise. The review targets substantive drift/contradiction/bloat, not prose taste.
- If Codex and its Gemini fallback both fail, the `reviewer` subagent's report is the review — say so. Never let the skill degrade to a self-review by the session that wrote the docs; the whole point is *independent* challenge.
