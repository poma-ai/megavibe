---
name: doc-review
description: Independent three-reviewer review of the project's MD doc set for drift, contradictions, dead pointers, and bloat. Sends CLAUDE.md + every README*.md to the switched-on reviewers (Claude `reviewer` subagent, Gemini, Codex) in parallel; synthesizes findings into a single report.
allowed-tools: Bash, Read, Write, Agent
---

# Doc-review (periodic doc hygiene)

Send the project's full markdown documentation surface to every switched-on reviewer in parallel — the Claude `reviewer` subagent always, plus Gemini and Codex unless the user has left one out of the `MEGAVIBE_REVIEWERS` allow-list or it is unavailable — for an independent challenge. Synthesize the reviews into a single findings report. The user decides which findings to act on.

## When to use

After significant docs or code edits that change the documentation surface — `/init` of a new project, a feature that touched multiple files, a noticeable CLAUDE.md or README growth spurt. Not every session.

## Steps

1. **Gather the MD set.** From the project root:
   ```sh
   ls CLAUDE.md README*.md 2>/dev/null
   find docs -maxdepth 2 -name '*.md' 2>/dev/null
   ```
   Most projects: just `CLAUDE.md` plus zero or more `README*.md` at the root. Adapt if the project uses a `docs/` folder. If only `CLAUDE.md` exists, the review is still useful — focus on bloat and drift-vs-code.

2. **Send to the reviewers in PARALLEL**, in a single tool-call batch, with the SAME files and the SAME prompt. Call only the reviewers in the `MEGAVIBE_REVIEWERS` allow-list — the session-start table has a Reviewers row naming the active set, and a reviewer left out of it exits 4 under `--as-reviewer` instead of reviewing. The `reviewer` subagent always runs (Agent tool, `subagent_type: reviewer`, or `general-purpose` with `model: opus` and the text of `.claude/agents/reviewer.md` if the project has not synced agents yet). Add Gemini via Bash — `bash ~/.megavibe/scripts/gemini-review.sh --as-reviewer --prompt "<prompt>" <files>` (add `--pro` only when CLAUDE.md or the protocol itself is in the set) — only if `$GEMINI_API_KEY` is set (it exits 1 otherwise; that is a skipped reviewer, not a failed review). Add Codex via Bash — `bash ~/.megavibe/scripts/codex-review.sh --as-reviewer --prompt "<prompt>" <files>` — only if `codex` is on PATH. There is no Codex MCP: codex-cli 0.154.0 removed it, and `setup.sh` deletes the dead registration, so a gate on "is the Codex MCP listed" is permanently false and would report Codex unavailable when it works. Never use `mcp__gemini-cli__ask-gemini` here: the CLI it wraps truncates or stalls on 3.x thinking. The prompt:

   > Review the attached project documentation set. For each finding, output `{category, file:line, what's wrong, suggested fix}`. Categories:
   >
   > 1. **Drift** — claims that no longer match the code or each other (verify against actual source where you can)
   > 2. **Contradictions** — places where two docs disagree
   > 3. **Dead pointers** — references to files, functions, or READMEs that don't exist
   > 4. **Bloat** — content that should be extracted into a dedicated `README-<topic>.md` per the rule-index-not-encyclopedia pattern (sections >~30 lines, file structure tables, detailed pipeline descriptions inside CLAUDE.md)
   > 5. **Underdocumented gotchas** — code patterns that look important but aren't called out
   >
   > Be specific and concise. Do not propose stylistic rewrites — only substantive issues.

3. **Missing reviewers.** A backend that is unavailable (no key, not installed) and one that is switched off in `MEGAVIBE_REVIEWERS` are both simply absent from the round — name which, and do not treat a switched-off reviewer as an outage to work around. The `reviewer` subagent is never skipped: `MEGAVIBE_REVIEWERS` governs the external reviewers only and cannot remove it. If Gemini or Codex is unavailable per `.claude/rules/delegation.md`, run with the rest and name the missing reviewer in the synthesis. Never substitute `summarizer` for `reviewer`. A single-reviewer round (reviewer only) is still a review — say so plainly.

4. **Synthesize.** Merge the reports into a single output, grouped by category. For each finding:
   - Note how many reviewers flagged it — **all** or **two** (high-confidence) vs **one** (check it yourself before acting)
   - Preserve the file:line reference
   - Keep the suggested fix terse — one or two lines

5. **Report only.** Do NOT auto-apply fixes. Present the synthesis to the user; they choose which to act on.

## Rules

- **Parallel, not sequential.** Issue both backend calls in one message — half the wall time and avoids one backend's framing biasing the other.
- The **synthesis** is the value. Don't dump raw outputs from each backend; the merged view is what the user reads.
- Avoid stylistic noise. The review targets substantive drift/contradiction/bloat, not prose taste.
- If Gemini and Codex both fail, the `reviewer` subagent's report is the review — say so. Never let the skill degrade to a self-review by the session that wrote the docs; the whole point is *independent* challenge.
