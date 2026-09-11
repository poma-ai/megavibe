# Tool Routing and Delegation Protocols

## Universal fallback principle

**Megavibe works with ONLY a Claude Code subscription.** External backends (Gemini, Codex) improve quality for specific tasks but are never required. Every task has a last-resort path through Claude itself (via the `summarizer` subagent at `.claude/agents/summarizer.md`).

**Standard fallback chain** (Gemini-primary tasks):
1. Gemini direct API: `~/.megavibe/scripts/gemini-review.sh --prompt "..." FILE...` (requires `$GEMINI_API_KEY` from a **billed** project — Google-account OAuth was retired 2026-06-18, and the free tier is 20 req/day and trains on prompts; without a key, skip straight to Codex)
2. Gemini MCP (`mcp__gemini-cli__ask-gemini`) — for short interactive questions only; the CLI it wraps hardcodes 3.x thinking, so long answers truncate or take minutes
3. Codex: `~/.megavibe/scripts/codex-review.sh --prompt "..." FILE...` (NOT an MCP server — see below)
4. Claude subagent (always available — same subscription)

**Reverse chain** (Codex-primary tasks):
1. Codex: `~/.megavibe/scripts/codex-review.sh` (or `codex exec` directly for research memos)
2. Gemini direct API (`gemini-review.sh`)
3. Gemini MCP
4. Claude subagent

**There is no Codex MCP server, since codex-cli 0.154.0 (2026-09-10).** That release deleted the `mcp-server` subcommand — `strings` on the native binary returns zero occurrences, so it is gone from compiled code, not just from help; `codex mcp` now manages Codex as a *client* (list/get/add/remove/login/logout). Do not try to register it, and do not read `CONNECTION_CLOSED` from a `codex` MCP entry as a network fault: codex forwards an unrecognised subcommand to the interactive CLI as a prompt, the TUI starts, dies with "stdin is not a terminal", and the pipe closes mid-handshake. The error never names the real cause, which is why this read as an outage for hours. `setup.sh` removes the dead registration; `on-session-start.sh` asserts `codex exec` exists rather than assuming it.

**Use `~/.megavibe/scripts/codex-review.sh`**, which mirrors `gemini-review.sh`'s interface: `--prompt`/`--prompt-file` plus `FILE...`, files appended as `===== path =====` blocks, `--out`, `--model`, `--timeout` (default 300s, exit 124 on timeout so the chain falls through instead of hanging). Read-only is pinned and there is **no `--sandbox` flag** — passing one is refused (exit 2), as are `--approve-for-me`, `--full-auto` and `--dangerously-bypass-approvals-and-sandbox` — a reviewer does not need write access. `exec` has no interactive approver, so the old `approval-policy: "never"` is implicit and the elicitation problem that `codex-approval-never.sh` existed for cannot arise. That hook is therefore gone from the template and from new projects; existing projects keep an inert copy, since pruning it would mean a settings.json migration for zero behavioural gain — re-running `init.sh` drops the registration anyway. One caveat if you never re-init: that copy matches the tool NAME `mcp__codex__codex`, so a third-party MCP server registered under the name `codex` (which the cleanup deliberately does not delete) would have its input rewritten by a hook written for a different server.

**Gemini thinking, measured 2026-09-06:** `gemini-3.8-flash` spends 15–40K thought tokens on a review prompt by default and returns almost no text under any output cap; `thinkingLevel: low` returns the complete answer in seconds. `gemini-review.sh` sets it. Keep `-m`/model overrides to flash except through `gemini-review.sh --pro` for reviews; the Pro line has no free tier and bills 3-16x flash.

**Never retry a failed MCP call more than once.** Move to the next fallback immediately.

## Switching reviewers off

`MEGAVIBE_REVIEWERS` is an allow-list of reviewer ids — `gemini`, `codex`, and `reviewer` (the Claude subagent, which is **always** in the resolved set and cannot be switched off: it is the floor non-negotiable 4 rests on, costs no key, and has no script to gate it through). Unset, empty or `auto` means every reviewer that is available, which is the default and needs no configuration. To pin the set:

```
megavibe reviewers                          # what is on, where it was set, what is available
megavibe reviewers set reviewer gemini      # this user, all projects
megavibe reviewers set --project reviewer   # this project only (uncommitted)
megavibe reviewers set auto                 # back to the default
```

It writes `MEGAVIBE_REVIEWERS` into the `env` block of `~/.claude/settings.json`, or with `--project` into the project's uncommitted `.claude/settings.local.json`, which Claude Code applies to the session so hooks and Bash calls inherit it. `reviewers.sh` also reads those files directly, so a review script run from a plain terminal honours the same setting. Precedence: the exported variable, then `settings.local.json`, then the project's committed `settings.json`, then the user file — except that the committed project file may only **add** reviewers. It arrives with a clone, written by whoever wrote the repo, and a repo that can switch off the reviewers reading its own code is a hole, not a feature; a reducing pin there is ignored with a warning. `~/.megavibe/scripts/reviewers.sh list` prints the resolved set, `source` says which of them supplied it.

**It gates the reviewer ROLE, not the backend.** `gemini-review.sh` and `codex-review.sh` are also the general Gemini/Codex transport — steps 1 and 3 of the fallback chain above, and what `/rehydrate` and `/prune-context` call — so they consult the allow-list **only when the caller passes `--as-reviewer`**. Pass that flag for the reviews of non-negotiable 4 and for nothing else: switching a reviewer off must not cost anyone context recovery. Getting this backwards is the bug the first cut shipped — `MEGAVIBE_REVIEWERS="reviewer"` silently stripped `/rehydrate` of both external backends.

Allow-list rather than ignore-list on purpose: the config states exactly what runs, where an ignore-list only says it relative to whatever happens to be installed on the machine. The cost is that a reviewer added to megavibe later is off for anyone who has pinned a list.

Enforcement is in the scripts, not only here — under `--as-reviewer` they exit **4** with a `skip:` line when their reviewer is not in the set, before spending a token. Exit 4 means *switched off*, not *failed*: do not fall through the chain looking for a substitute, and do not report the review as degraded by a backend outage. Every unclear path fails OPEN to all reviewers — unreadable config, missing `jq`, an unrecognised value, a helper that crashes — because reviewing with fewer eyes than the user expects is the bad direction to fail in. A round that ends up with only the `reviewer` subagent is still a review; say so plainly in the synthesis.

**Never override the Gemini model to a Pro variant** (`-m gemini-*-pro*`, `model: gemini-*-pro*`) in the MCP tool, the CLI, or the watcher. Pro has no free tier and bills at 3-16x flash on a paid key. The one sanctioned use is `gemini-review.sh --pro` for reviews of protocol/template changes and user-facing work (≈$0.15 a review); everything else stays on `gemini-flash-latest`, and if flash is not enough, fall through the chain to Codex.

## Tool routing

| Need | Primary | Fallback 1 | Fallback 2 | Last resort | Output format |
|------|---------|-----------|-----------|-------------|---------------|
| Large context (long logs, many files, PDFs) | Gemini | Codex | — | Claude subagent | Key claims, evidence anchors, risks, unknowns |
| Re-hydrate working context | Gemini | Codex | — | Claude subagent | `.agent/sessions/{sid}/WORKING_CONTEXT.md` (max ~400 lines) |
| Summarize text (any length/target) | Gemini | Codex | — | Claude subagent | Structured summary at specified target length |
| Accessibility-grade image description | Gemini | Codex | — | Claude subagent | Literal, high-recall, structured markdown |
| Research memo (multi-source, citations) | Codex | Gemini | — | Claude subagent | `.agent/RESEARCH/YYYY-MM-DD_topic.md` |
| **Independent review before shipping** (non-negotiable 4) | every reviewer in `MEGAVIBE_REVIEWERS` (default: all) — `reviewer` subagent (Opus; `general-purpose`+opus with the agent's text if not yet registered) **+** Gemini `gemini-review.sh --as-reviewer` **+** Codex `codex-review.sh --as-reviewer`, in parallel | reviewer + whichever backend is up | — | `reviewer` subagent alone | Ranked findings with file:line, failing input, outcome, fix; ship / do-not-ship verdict |
| Fast second opinion / alternative plan | Codex | Gemini | — | Claude subagent | Patch plan + test plan |
| Quick fact check / web search | Codex | Gemini | — | Claude subagent | Claims with sources |
| JS-heavy site, auth flow, DOM extraction | Playwright | — | — | — | Screenshots/HTML → `.agent/ASSETS/` |
| Interpret screenshots or UI captures | Gemini | Codex | — | Claude subagent | Structured description |
| Automatic .agent/ context augmentation | poma-memory (via Grep/Glob hook) | poma-memory MCP | — | — | Injected as systemMessage on every Grep/Glob |
| Selective context compaction | Gemini | Codex | — | Claude subagent | See below |

## Gemini / Codex / Claude subagent delegation protocols

These protocols apply to whichever backend is available. When Gemini is the primary, use `~/.megavibe/scripts/gemini-review.sh` (the MCP tool only for short questions). When falling back to Codex, use `~/.megavibe/scripts/codex-review.sh` with the same inputs and output requirements. When falling back to Claude subagent, use the Agent tool with `.claude/agents/summarizer.md`.

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

If Codex is unavailable, fall back to Gemini (`gemini-review.sh`) → Claude subagent (reverse chain). The Claude subagent cannot do live web search but can analyze local files and produce structured research from available context.

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
