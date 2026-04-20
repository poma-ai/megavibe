# Tool Routing and Delegation Protocols

## Universal fallback principle

**Megavibe works with ONLY a Claude Code subscription.** External backends (Gemini, Codex) improve quality for specific tasks but are never required. Every task has a last-resort path through Claude itself (via the `summarizer` subagent at `.claude/agents/summarizer.md`).

**Standard fallback chain** (Gemini-primary tasks):
1. Gemini MCP (subscription/OAuth)
2. `$GEMINI_API_KEY` via curl (for geo-blocked regions)
3. Codex MCP
4. Claude subagent (always available — same subscription)

**Reverse chain** (Codex-primary tasks):
1. Codex MCP
2. Gemini MCP
3. `$GEMINI_API_KEY` via curl
4. Claude subagent

**Never retry a failed MCP call more than once.** Move to the next fallback immediately.

## Tool routing

| Need | Primary | Fallback 1 | Fallback 2 | Last resort | Output format |
|------|---------|-----------|-----------|-------------|---------------|
| Large context (long logs, many files, PDFs) | Gemini | Codex | — | Claude subagent | Key claims, evidence anchors, risks, unknowns |
| Re-hydrate working context | Gemini | Codex | — | Claude subagent | `.agent/sessions/{sid}/WORKING_CONTEXT.md` (max ~400 lines) |
| Summarize text (any length/target) | Gemini | Codex | — | Claude subagent | Structured summary at specified target length |
| Accessibility-grade image description | Gemini | Codex | — | Claude subagent | Literal, high-recall, structured markdown |
| Research memo (multi-source, citations) | Codex | Gemini | — | Claude subagent | `.agent/RESEARCH/YYYY-MM-DD_topic.md` |
| Fast second opinion / alternative plan | Codex | Gemini | — | Claude subagent | Patch plan + test plan |
| Quick fact check / web search | Codex | Gemini | — | Claude subagent | Claims with sources |
| JS-heavy site, auth flow, DOM extraction | Playwright | — | — | — | Screenshots/HTML → `.agent/ASSETS/` |
| Interpret screenshots or UI captures | Gemini | Codex | — | Claude subagent | Structured description |
| Automatic .agent/ context augmentation | poma-memory (via Grep/Glob hook) | poma-memory MCP | — | — | Injected as systemMessage on every Grep/Glob |
| Selective context compaction | Gemini | Codex | — | Claude subagent | See below |

## Gemini / Codex / Claude subagent delegation protocols

These protocols apply to whichever backend is available. When Gemini is the primary, use Gemini MCP tools. When falling back to Codex, use Codex MCP tools with the same inputs and output requirements. When falling back to Claude subagent, use the Agent tool with `.claude/agents/summarizer.md`.

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

When FULL_CONTEXT.md becomes too large for the re-hydration backend to process in a single call (~750K words for Gemini), use the standard fallback chain for **selective line-level compaction**:

1. Send FULL_CONTEXT.md to the backend with this prompt: "Read this entire context log. Identify lines that are redundant, superseded by later entries, or no longer relevant. Output ONLY the line numbers to remove, grouped by reason. Preserve: all decisions, all open task references, all lessons learned, all architectural context. Remove: duplicate status updates, resolved issue descriptions, stale progress notes."
2. Archive the original to `.agent/LOGS/FULL_CONTEXT.pre-compact.md`
3. Remove only the lines the backend identified
4. Append a compaction note: `--- Compacted on YYYY-MM-DD: removed N lines (AI-selected) ---`

This is a rare operation — most projects will never hit the limit. The Claude subagent fallback has a smaller context window (200K tokens vs Gemini's ~1M), so for very large logs it may need to process in chunks.

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

If Codex is unavailable, fall back to Gemini MCP → `$GEMINI_API_KEY` curl → Claude subagent (reverse chain). The Claude subagent cannot do live web search but can analyze local files and produce structured research from available context.

## Claude subagent protocols

The `summarizer` subagent (`.claude/agents/summarizer.md`, model: sonnet) is the universal last-resort fallback. It runs on the same Claude subscription — no API key needed, always available.

**When to use:** Only after Gemini AND Codex have both failed. Never as a first choice — external backends have larger context windows and (for Codex) web search.

**Limitations:**
- 200K token context window (vs Gemini's ~1M) — may not fit very large FULL_CONTEXT.md files
- No web search capability (unlike Codex)
- Shares the parent session's rate limits

**How to invoke:** Use the Agent tool:
```
Agent(prompt="Read .agent/FULL_CONTEXT.md and produce a WORKING_CONTEXT summary (max 400 lines)...",
      subagent_type="general-purpose")
```
Or reference the custom agent if deployed: `.claude/agents/summarizer.md`
