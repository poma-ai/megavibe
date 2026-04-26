---
name: doc-review
description: Independent dual-backend review of the project's MD doc set for drift, contradictions, dead pointers, and bloat. Sends CLAUDE.md + every README*.md to Gemini AND Codex in parallel; synthesizes findings into a single report.
allowed-tools: Bash, Read, Write
---

# Doc-review (periodic doc hygiene)

Send the project's full markdown documentation surface to Gemini AND Codex in parallel for an independent challenge. Synthesize the two reviews into a single findings report. The user decides which findings to act on.

## When to use

After significant docs or code edits that change the documentation surface — `/init` of a new project, a feature that touched multiple files, a noticeable CLAUDE.md or README growth spurt. Not every session.

## Steps

1. **Gather the MD set.** From the project root:
   ```sh
   ls CLAUDE.md README*.md 2>/dev/null
   find docs -maxdepth 2 -name '*.md' 2>/dev/null
   ```
   Most projects: just `CLAUDE.md` plus zero or more `README*.md` at the root. Adapt if the project uses a `docs/` folder. If only `CLAUDE.md` exists, the review is still useful — focus on bloat and drift-vs-code.

2. **Send to BOTH backends in PARALLEL** in a single tool-call batch — `mcp__gemini-cli__ask-gemini` and `mcp__codex__codex` with the SAME files and the SAME prompt:

   > Review the attached project documentation set. For each finding, output `{category, file:line, what's wrong, suggested fix}`. Categories:
   >
   > 1. **Drift** — claims that no longer match the code or each other (verify against actual source where you can)
   > 2. **Contradictions** — places where two docs disagree
   > 3. **Dead pointers** — references to files, functions, or READMEs that don't exist
   > 4. **Bloat** — content that should be extracted into a dedicated `README-<topic>.md` per the rule-index-not-encyclopedia pattern (sections >~30 lines, file structure tables, detailed pipeline descriptions inside CLAUDE.md)
   > 5. **Underdocumented gotchas** — code patterns that look important but aren't called out
   >
   > Be specific and concise. Do not propose stylistic rewrites — only substantive issues.

3. **Backend fallback.** If a backend is unavailable per `.claude/rules/delegation.md`, run with whichever is available and note the missing one in the synthesis. If both Gemini and Codex are down, fall back to the Claude subagent (`summarizer`) — but flag clearly that this is a single-backend review, not the intended independent challenge.

4. **Synthesize.** Merge both reports into a single output, grouped by category. For each finding:
   - Note whether **both** backends flagged it (high-confidence) or **one** (consider the other's framing)
   - Preserve the file:line reference
   - Keep the suggested fix terse — one or two lines

5. **Report only.** Do NOT auto-apply fixes. Present the synthesis to the user; they choose which to act on.

## Rules

- **Parallel, not sequential.** Issue both backend calls in one message — half the wall time and avoids one backend's framing biasing the other.
- The **synthesis** is the value. Don't dump raw outputs from each backend; the merged view is what the user reads.
- Avoid stylistic noise. The review targets substantive drift/contradiction/bloat, not prose taste.
- If both backends fail, say so and stop. Don't let the skill silently degrade to a self-review — the whole point is *independent* challenge.
