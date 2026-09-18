# Tool Routing and Delegation Protocols

## Universal fallback principle

**Megavibe works with ONLY a Claude Code subscription.** External backends (Codex, Gemini) improve quality for specific tasks but are never required. Every task has a last-resort path through Claude itself (via the `summarizer` subagent at `.claude/agents/summarizer.md`).

**The standard chain, for every task:**
1. **Codex** — `~/.megavibe/scripts/codex-review.sh --prompt "..." FILE...` (NOT an MCP server — see below). For a summarising job add `--effort low`; for a review leave it off and let the user's own `~/.codex/config.toml` choose. Add `--model` only if you are prepared to re-run without it when that model is not on this plan: a pinned name that a plan does not expose fails every call and pushes the work to the Claude subagent's 125K tokens.
2. **Claude subagent** — `.claude/agents/summarizer.md`, no key, always available, and the best output of the three on a context digest. It spends the same subscription quota the session runs on, which is the only reason it is not first.
3. **Gemini** — `~/.megavibe/scripts/gemini-review.sh --prompt "..." FILE...` (requires `$GEMINI_API_KEY` from a **billed** project — Google-account OAuth was retired 2026-06-18, and the free tier is 20 req/day and trains on prompts). Every token is billed and on reviews it is the weakest of the three, so it is last.
4. Gemini MCP (`mcp__gemini-cli__ask-gemini`) — short interactive questions only; the CLI it wraps hardcodes 3.x thinking, so long answers truncate or take minutes.

**Why this order, measured 2026-09-18.** Same 196 KB re-hydration input, four backends in parallel:

| Backend | Time | Output | What it costs |
|---|---|---|---|
| Codex `gpt-5.6-terra`, effort low | 23 s | 76 lines | plan tokens |
| Claude `summarizer` (sonnet) | 87 s | 64 lines | 125K tokens of this session's own subscription |
| Codex `gpt-6-astra`, effort low / high | 93 / 105 s | 156 / 168 lines | plan tokens |
| Gemini `3.1-flash-lite`, level low | 9 s | 40 lines | billed per token |

Nothing was invented by any of them; every specific claim in all four traced back to the input. Line count is the only measured column, and it does not rank them — the subagent's 64 lines carried the most specifics per line (named commits, task IDs, the open blockers and who they were waiting on), which is the judgement behind putting it above Gemini and is a judgement, not a measurement. Two things follow. **Effort is the wrong knob for summarising** — even at `high`, Codex spent 94 reasoning tokens, because digesting a log does not reason; the MODEL sets the time and the length. And **a bigger model is not a better summary**: astra spent four times the wall clock to produce a longer document, not a more accurate one.

**What a Codex quota day looks like, because this order concentrates load on one plan.** Reviews, re-hydration and the watcher's five-minute flush now all draw on the same subscription, and on the day these numbers were measured Codex was quota-exhausted for about three hours. When that happens the review round is the `reviewer` subagent plus `gemini-review.sh --as-reviewer --fallback --pro`, and that is the weakest configuration megavibe has: the same audit recorded Gemini alone approving five changes that carried real blockers. So on a quota day, **treat every Gemini finding as a lead to reproduce and every Gemini verdict as unverified**, say in the synthesis that Codex did not run, and prefer holding a risky merge to shipping on a single unreproduced review. `megavibe reviewers set all` is the standing answer for anyone who would rather pay for the third opinion every day than rely on it only when the primary is down.

**Reviews rank differently** — see the review row below. There depth is the whole point: Codex reads the repo, runs the tests and reproduces the failing input, and over 11 paired reviews in one day it found real defects in every unit. Gemini, one stateless API call over inlined files, produced four wrong headline findings and five SHIP verdicts on code with confirmed blockers, including "a masterclass" on a patch with a P1 in it. That is why it is the fallback reviewer rather than a third opinion, and why it always gets `--pro` when it does review.

**There is no Codex MCP server, since codex-cli 0.154.0 (2026-09-10).** That release deleted the `mcp-server` subcommand — `strings` on the native binary returns zero occurrences, so it is gone from compiled code, not just from help; `codex mcp` now manages Codex as a *client* (list/get/add/remove/login/logout). Do not try to register it, and do not read `CONNECTION_CLOSED` from a `codex` MCP entry as a network fault: codex forwards an unrecognised subcommand to the interactive CLI as a prompt, the TUI starts, dies with "stdin is not a terminal", and the pipe closes mid-handshake. The error never names the real cause, which is why this read as an outage for hours. `setup.sh` removes the dead registration; `on-session-start.sh` asserts `codex exec` exists rather than assuming it.

**Use `~/.megavibe/scripts/codex-review.sh`**, which mirrors `gemini-review.sh`'s interface: `--prompt`/`--prompt-file` plus `FILE...`, files appended as `===== path =====` blocks, `--out`, `--model`, `--timeout` (default 300s, exit 124 on timeout so the chain falls through instead of hanging). Read-only is pinned and there is **no `--sandbox` flag** — passing one is refused (exit 2), as are `--approve-for-me`, `--full-auto` and `--dangerously-bypass-approvals-and-sandbox` — a reviewer does not need write access. `exec` has no interactive approver, so the old `approval-policy: "never"` is implicit and the elicitation problem that `codex-approval-never.sh` existed for cannot arise. That hook is therefore gone from the template and from new projects; existing projects keep an inert copy, since pruning it would mean a settings.json migration for zero behavioural gain — re-running `init.sh` drops the registration anyway. One caveat if you never re-init: that copy matches the tool NAME `mcp__codex__codex`, so a third-party MCP server registered under the name `codex` (which the cleanup deliberately does not delete) would have its input rewritten by a hook written for a different server.

**Gemini thinking, measured 2026-09-06:** `gemini-3.8-flash` spends 15–40K thought tokens on a review prompt by default and returns almost no text under any output cap; `thinkingLevel: low` returns the complete answer in seconds. `gemini-review.sh` sets it. Keep `-m`/model overrides to flash except through `gemini-review.sh --pro` for reviews; the Pro line has no free tier and bills 3-16x flash.

**Never retry a failed MCP call more than once.** Move to the next fallback immediately.

**Do not fan a job out to several cheap models instead of one good one.** The measured failure mode is shallow work, not too few opinions: models that cannot run the code agree with each other and still miss the P1. Depth first, then a second independent reader.

## Two review tiers, and why

Every round gets **one** reviewer — Codex, or the `reviewer` subagent where Codex is unavailable. The round that gates the ship, and anything critical, gets **both in parallel**. Critical means credentials or security, data loss or destructive paths, anything public or user-facing, the protocol and templates themselves, and anything the user names.

The reason is cost asymmetry, measured. Codex draws on a separate plan; the `reviewer` subagent draws ~180-200K tokens of the SAME subscription the session is spending — in one session here, two invocations cost 386K tokens. Running both on every intermediate round spends the user's Claude subscription quota (a different resource from the session's context window, and the one that runs out) to re-check work that is still moving. Running only Codex on the last round ships on a single unreproduced opinion.

The honest cost of this trade: an intermediate reviewer's mistake can shape the implementation and the framing of the next review, and the ship round may miss it again — especially if it is shown only the latest fixes rather than the whole candidate. That is why the ship round reviews the **final candidate in full**, not the delta since the last round. "Round one's defect gets caught later" is the expectation, not a guarantee.

Iterating toward a fix is a normal round. The last one before merge is not. A change that goes through exactly one review round is having its ship round, so it gets the full set.

**Decide the tier before the round, not after.** Nothing ships on an intermediate review: before merging, deploying, publishing or calling an important result done, the final candidate must have had a full-set review. If a round you started as "normal" turns out to be the last, run the missing reviewers on the final state first. Otherwise a change can be reviewed cheaply forever and then merged on the strength of a round that was never the gate.

**The floor is one independent reviewer, never zero.** On a machine with only a Claude subscription, that is the subagent on every round, because there is nothing else — the tiering removes the *second* reader on intermediate rounds, never the only one.

## Switching reviewers off

`MEGAVIBE_REVIEWERS` is an allow-list of reviewer ids — `gemini`, `codex`, and `reviewer` (the Claude subagent, which is **always** in the resolved set and cannot be switched off: it is the floor non-negotiable 4 rests on, costs no key, and has no script to gate it through). Being in the set is about eligibility, not cadence: the two tiers above decide which rounds actually call it. Unset, empty or `auto` is the DEFAULT: `reviewer` + `codex` where `codex exec` works, `reviewer` + `gemini` where it does not, and all three if the probe cannot answer at all. `all` names every reviewer explicitly and makes Gemini eligible as a peer — eligibility, not cadence: an ordinary intermediate round still runs one reviewer, and ship rounds run the eligible set in parallel. To pin the set:

```
megavibe reviewers                          # what is on, where it was set, what is available
megavibe reviewers set all                  # all three eligible; ship rounds run them in parallel
megavibe reviewers set reviewer codex       # never gemini, not even as codex's fallback
megavibe reviewers set --project reviewer   # this project only (uncommitted)
megavibe reviewers set auto                 # back to the default
```

`auto` and `all` used to be the same word for the same thing, because the default WAS all three. They are different now, so `set all` writes the literal value instead of clearing the setting. A pin written by the OLD command cannot be recovered — it cleared the setting, which is indistinguishable from never having chosen — so the session-start hook says once, per machine, that the default changed and how to get all three back.

It writes `MEGAVIBE_REVIEWERS` into the `env` block of `~/.claude/settings.json`, or with `--project` into the project's uncommitted `.claude/settings.local.json`, which Claude Code applies to the session so hooks and Bash calls inherit it. `reviewers.sh` also reads those files directly, so a review script run from a plain terminal honours the same setting. Precedence: the exported variable, then `settings.local.json`, then the project's committed `settings.json`, then the user file — except that the committed project file may only **add** reviewers. It arrives with a clone, written by whoever wrote the repo, and a repo that can switch off the reviewers reading its own code is a hole, not a feature; a reducing pin there is ignored with a warning. `~/.megavibe/scripts/reviewers.sh list` prints the resolved set, `source` says which of them supplied it.

**It gates the reviewer ROLE, not the backend.** `gemini-review.sh` and `codex-review.sh` are also the general Codex/Gemini transport — steps 1 and 3 of the fallback chain above, and what `/rehydrate` and `/prune-context` call — so they consult the allow-list **only when the caller passes `--as-reviewer`**. Pass that flag for the reviews of non-negotiable 4 and for nothing else: switching a reviewer off must not cost anyone context recovery. Getting this backwards is the bug the first cut shipped — `MEGAVIBE_REVIEWERS="reviewer"` silently stripped `/rehydrate` of both external backends.

Allow-list rather than ignore-list on purpose: the config states exactly what runs, where an ignore-list only says it relative to whatever happens to be installed on the machine. The cost is that a reviewer added to megavibe later is off for anyone who has pinned a list.

**Every unclear path resolves to MORE review.** A settings file that exists but cannot be parsed — bad JSON, no `jq` — is ambiguous rather than absent, and returns all three. An unrecognised name invalidates the whole pin rather than being dropped from it, because `"gemini codx"` would otherwise switch codex off forever on a typo. A committed project `settings.json` is compared against what the machine would resolve WITHOUT it and ignored if it removes anything, which is why `auto` in a cloned repo cannot quietly take Gemini away from a user whose own file says `all`. The availability probe is bounded and, on a timeout, counts as unknown and returns all three. In the review scripts, exit status **1** from `reviewers.sh` is the only answer that switches a reviewer off; every other status is the helper failing to answer, and the review runs.

Enforcement is in the scripts, not only here — under `--as-reviewer` they exit **4** with a `skip:` line when their reviewer is not in the set, before spending a token. Exit 4 means *switched off*, not *failed*: do not fall through the chain looking for a substitute, and do not report the review as degraded by a backend outage. Every unclear path fails OPEN to all reviewers — unreadable config, missing `jq`, an unrecognised value, a helper that crashes — because reviewing with fewer eyes than the user expects is the bad direction to fail in. A round that ends up with only the `reviewer` subagent is still a review; say so plainly in the synthesis.

**Never override the Gemini model to a Pro variant** (`-m gemini-*-pro*`, `model: gemini-*-pro*`) in the MCP tool, the CLI, or the watcher. Pro has no free tier and bills at 3-16x flash on a paid key. The one sanctioned use is `gemini-review.sh --pro` for reviews of protocol/template changes and user-facing work (≈$0.15 a review); everything else stays on `gemini-flash-latest`, and if flash is not enough, fall through the chain to Codex.

## Tool routing

| Need | Primary | Fallback 1 | Fallback 2 | Output format |
|------|---------|-----------|-----------|---------------|
| Large context (long logs, many files, PDFs) | Codex | Claude subagent | Gemini | Key claims, evidence anchors, risks, unknowns |
| Re-hydrate working context | Codex `--effort low` | Claude subagent | Gemini | `.agent/sessions/{sid}/WORKING_CONTEXT.md` (max ~400 lines) |
| Summarize text (any length/target) | Codex `--effort low` | Claude subagent | Gemini | Structured summary at specified target length |
| Accessibility-grade image description | Gemini | Codex | Claude subagent | Literal, high-recall, structured markdown |
| Research memo (multi-source, citations) | Codex (`--search` when freshness matters) | Gemini | Claude subagent | `.agent/RESEARCH/YYYY-MM-DD_topic.md` |
| **Review, normal round** (non-negotiable 4) | Codex `codex-review.sh --as-reviewer`, when switched on AND available | `reviewer` subagent — whenever Codex is switched off, absent, OR its call failed | `gemini-review.sh --as-reviewer --fallback --pro` may JOIN the subagent when Codex failed today; it never takes the round alone | Ranked findings with file:line, failing input, outcome, fix |
| **Review, ship round or anything critical** | EVERY reviewer both switched on and available, in parallel — `reviewer` subagent (Opus; `general-purpose`+opus with the agent's text if not yet registered), Codex, and Gemini when pinned as a peer | whichever of them are available | Gemini `--fallback --pro` stands in for a Codex that FAILED (a Codex switched off is not a failure) | Same, plus a ship / do-not-ship verdict |
| Fast second opinion / alternative plan | Codex | Claude subagent | Gemini | Patch plan + test plan |
| Quick fact check / web search | Codex | Gemini | Claude subagent | Claims with sources |
| JS-heavy site, auth flow, DOM extraction | Playwright | — | — | Screenshots/HTML → `.agent/ASSETS/` |
| Interpret screenshots or UI captures | Gemini | Codex | Claude subagent | Structured description |
| Automatic .agent/ context augmentation | poma-memory (via Grep/Glob hook) | poma-memory MCP | — | Injected as systemMessage on every Grep/Glob |
| Selective context compaction | Codex | Claude subagent | Gemini | See below |

## Gemini / Codex / Claude subagent delegation protocols

These protocols apply to whichever backend is available. Codex is the primary — `~/.megavibe/scripts/codex-review.sh` — then the Claude subagent via the Agent tool with `.claude/agents/summarizer.md`, then Gemini via `~/.megavibe/scripts/gemini-review.sh` (its MCP tool only for short questions). The inputs and output requirements are the same whichever one answers.

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

If Codex is unavailable, fall back to Gemini (`gemini-review.sh`) → Claude subagent. Research is the one job where Gemini stays ahead of the subagent: neither can search the live web, and Gemini brings the larger window. Neither replaces Codex's `--search`, so say in the memo that the sources are recalled rather than fetched.

## Claude subagent protocols

The `summarizer` subagent (`.claude/agents/summarizer.md`, model: sonnet) is the SECOND link in the chain, between Codex and Gemini. It runs on the same Claude subscription — no API key needed, always available.

**When to use:** When Codex is unavailable or has failed. It sits ABOVE Gemini in the chain — its output is the best of the three on a context digest — but below Codex, because it draws on the same subscription quota the session itself is spending. Never for a review: `summarizer` is not `reviewer`, and non-negotiable 4 wants a fresh adversarial context, not a summary.

**Limitations:**
- 200K token context window (vs Gemini's ~1M) — may not fit very large FULL_CONTEXT.md files
- No web search capability (unlike Codex)
- Shares the parent session's rate limits — measured 125K tokens and 87 s on a 196 KB input, so a rehydrate here is not free even though no money changes hands

**How to invoke:** Use the Agent tool:
```
Agent(prompt="Read .agent/FULL_CONTEXT.md and produce a WORKING_CONTEXT summary (max 400 lines)...",
      subagent_type="general-purpose")
```
Or reference the custom agent if deployed: `.claude/agents/summarizer.md`
