# Tool Routing and Delegation Protocols

## Tool routing

| Need | Primary | Fallback | Output format |
|------|---------|----------|---------------|
| Large context (long logs, many files, PDFs) | Gemini | Codex | Key claims, evidence anchors, risks, unknowns |
| Re-hydrate working context | Gemini | Codex | `.agent/sessions/{sid}/WORKING_CONTEXT.md` (max ~400 lines) |
| Accessibility-grade image description | Gemini | Codex | Literal, high-recall, structured markdown |
| Research memo (multi-source, citations) | Codex | Gemini | `.agent/RESEARCH/YYYY-MM-DD_topic.md` |
| Fast second opinion / alternative plan | Codex | Gemini | Patch plan + test plan |
| Quick fact check / web search | Codex | Gemini | Claims with sources |
| JS-heavy site, auth flow, DOM extraction | Playwright | — | Screenshots/HTML → `.agent/ASSETS/` |
| Interpret screenshots or UI captures | Gemini (after Playwright) | Codex | Structured description |
| Automatic .agent/ context augmentation | poma-memory (via Grep hook) | poma-memory MCP | Injected as additionalContext on every Grep |
| Selective context compaction | Gemini | — | See below |

## Gemini / Codex delegation protocols

These protocols apply to whichever backend is available. When Gemini is the primary, use Gemini MCP tools. When falling back to Codex, use Codex MCP tools with the same inputs and output requirements.

### Re-hydration (regenerate working context)

Inputs to provide the backend:
- `.agent/FULL_CONTEXT.md`
- `.agent/DECISIONS.md`
- `.agent/TASKS.md`
- `git status` + `git diff --stat` output

Output requirements (max ~400 lines):
- **Goal** — current objective
- **Constraints** — must-not-break list
- **What's Done** — files touched, changes landed
- **Open Tasks** — with acceptance criteria
- **Risks / Unknowns**
- **Next Actions** — 3 concrete next steps

Rules:
- Never regenerate from an old WORKING_CONTEXT alone. Always re-derive from the full log + repo state.
- Write WORKING_CONTEXT to the session-scoped path (`.agent/sessions/{sid}/WORKING_CONTEXT.md`), not the project root.

### Selective context compaction

FULL_CONTEXT.md is append-only and has **no length limit** — let it grow. Do NOT preemptively truncate, archive, or summarize it.

When FULL_CONTEXT.md becomes too large for the re-hydration backend to process in a single call (~750K words for Gemini), use Gemini for **selective line-level compaction**:

1. Send FULL_CONTEXT.md to Gemini with this prompt: "Read this entire context log. Identify lines that are redundant, superseded by later entries, or no longer relevant. Output ONLY the line numbers to remove, grouped by reason. Preserve: all decisions, all open task references, all lessons learned, all architectural context. Remove: duplicate status updates, resolved issue descriptions, stale progress notes."
2. Archive the original to `.agent/LOGS/FULL_CONTEXT.pre-compact.md`
3. Remove only the lines Gemini identified
4. Append a compaction note: `--- Compacted on YYYY-MM-DD: removed N lines (Gemini-selected) ---`

This is a rare operation — most projects will never hit the limit.

### Image description (accessibility-grade)

Rules:
- Assume reader cannot see the image.
- Literal and high recall: layout, text, icons, charts.
- Transcribe all visible text faithfully.
- Charts: describe axes, legends, main trend.
- UI: describe hierarchy (header, nav, main, CTAs, errors, states).

Output: Overview → Text present → Layout/elements → Notable details → Inferred intent (labeled).

### Large-corpus digestion

Output: Index (outline with anchors) → Relevant extracts only → Brief (claims + evidence) → Risks/edge cases.

### Second opinion review

Output: What could fail → Missing tests → Security/perf concerns → Alternative approach.

## Codex delegation protocols

### Research memo

**Task:** produce a research memo with citations and implementable recommendations.

**Command:** use `codex exec` via Bash with a research prompt. Write output to `.agent/RESEARCH/YYYY-MM-DD_topic.md`.

**Output format** (markdown):
- Findings
- Tradeoffs
- Recommendation
- Implementation checklist
- Sources (URLs, with citations for nontrivial claims)

Codex uses cached web search by default. Add `--search` for live results when freshness matters.
