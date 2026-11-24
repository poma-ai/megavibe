# Delegation: measurements and history

Evidence behind the rules in `template/CLAUDE.md` and `template/.claude/rules/` (mostly `delegation.md`, also `spinouts.md`). Moved out of those files on 2026-11-23 because they are loaded eagerly into every session and the instruction-file total passed the 150k-char limit; the rules there stay authoritative. This file is evidence and history: imperatives in the quoted text below are the original wording of rules that live in those files. Text is as moved, apart from bracketed notes and small edits that repair references.

## Reasoning-effort/timeout asymmetry (2026-10-04)

**Reasoning-effort/timeout asymmetry, found and fixed 2026-10-04.** `~/.codex/config.toml` had `model_reasoning_effort = "low"` while the Claude `reviewer` subagent ran `medium` (now `high`) — Codex, the *primary* reviewer by call volume, was configured to think less than its own fallback. Measured over September: of 1,015 `codex-review.sh`/`gemini-review.sh` calls, ~21.3% actually failed (10.5% timeout at the 300s default, 10.8% error — separate from the 1.9% that exited 4 as a deliberate `MEGAVIBE_REVIEWERS` skip, which is a setting, not a failure, and does not trigger a reviewer-fallback report). Each real failure on a review call falls through to the costlier Sonnet `reviewer` per the protocol's own fallback rule, which both inflates Claude spend and quietly erases the intended Codex-first ordering; non-review Codex calls (re-hydration) fall through to the `summarizer` subagent instead, per the chain above [the standard chain, in delegation.md under "Universal fallback principle"] — research is the documented exception (Gemini stays ahead of the subagent there; see the "Research memo" section of delegation.md [not in this file]). Bumped `model_reasoning_effort` to `high` directly in `~/.codex/config.toml` (a personal file, not this repo) and smoke-tested at the new setting: a small single-file review ran in 21s, well inside even the old 300s cap — but that was a trivial task, and real multi-file reviews that run tests will run longer at higher effort, which is why the timeout above doubled too [the `--timeout 600` advice in delegation.md, "Universal fallback principle"]. `~/.codex/sessions/` shows real, growing Codex usage (not idle) but at roughly 7% of Claude's measured call volume over the same window — directional evidence of headroom, not a measured quota ceiling, since one `codex exec` call can cover what several Claude turns do. A/B'd once since (2026-10-05): `gpt-6.1-sol` vs. `gpt-6-astra`, both at `high` effort, same real review task. Same ship verdict, comparable depth, astra marginally faster this run. No clear win on n=1 — kept `sol` as the default rather than switch on a tie. The backend comparison [below, under "Summarisation backend comparison"] measured summarisation, not review quality, and explicitly found astra's longer summary wasn't a more accurate one, so that comparison doesn't carry over; revisit the model choice if more review trials show a consistent gap either way.

## Summarisation backend comparison (2026-09-18)

**Why this order, measured 2026-09-18.** Same 196 KB re-hydration input, four backends in parallel:



| Backend | Time | Output | What it costs |
|---|---|---|---|
| Codex `gpt-5.6-terra`, effort low | 23 s | 76 lines | plan tokens |
| Claude `summarizer` (sonnet) | 87 s | 64 lines | 125K tokens of this session's own subscription |
| Codex `gpt-6-astra`, effort low / high | 93 / 105 s | 156 / 168 lines | plan tokens |
| Gemini `3.1-flash-lite`, level low | 9 s | 40 lines | billed per token |
| Claude `general-purpose` + `model: haiku`, measured 2026-10-04 on a different 200KB input | 65 s | 108 lines, specific (named commits, PR #s, task IDs, acceptance criteria — plus a self-added Rationale section not in the template) | 113K tokens of this session's own subscription — *less* than the sonnet subagent, at half Sonnet's per-token price |



Nothing was invented by any of them — every claim traced back to the input. Line count doesn't rank them: the subagent's 64 lines carried the most specifics per line (named commits, task IDs, open blockers), the judgement behind ranking it above Gemini. Two conclusions: **effort is the wrong knob for summarising** (even at `high`, Codex spent only 94 reasoning tokens — digesting a log doesn't reason, the model sets time and length), and **a bigger model isn't a better summary** (astra took 4x the wall-clock for a longer document, not a more accurate one).



**A third conclusion, from the Haiku row above: a smaller model isn't a worse summary either, at least once.** Haiku's output matched the sonnet subagent's named-specifics density (commits, PR numbers, task IDs, acceptance criteria) at half Sonnet's per-token price and fewer total tokens, with one self-corrected hiccup (1 of 4 Read calls errored, presumably a chunk-boundary miss, and it recovered without being told to). This is **n=1 on a single real input, not a repeat of the controlled 4-way test above** — the original input file no longer exists to re-run it on. `summarizer.md` stays pinned to `sonnet` until a second run confirms this isn't a fluke; `general-purpose` + `model: haiku` is worth reaching for directly on read-and-summarize tasks with no judgment call in them (a context digest, not a decision) in the meantime.

## Codex quota day, Gemini as lone reviewer

**A Codex quota day is the weakest configuration megavibe has.** Reviews, re-hydration and the watcher's five-minute flush all draw on the same subscription; on the day these numbers were measured, Codex was exhausted for ~3 hours, leaving reviews to the `reviewer` subagent plus `gemini-review.sh --as-reviewer --fallback --pro` — the same audit recorded Gemini alone approving five changes with real blockers. On a quota day: **treat every Gemini finding as a lead to reproduce and every Gemini verdict as unverified**, say so in the synthesis, and prefer holding a risky merge over shipping on one unreproduced review. `megavibe reviewers set all` pays for the third opinion every day instead of relying on it only when the primary is down.

## Why the reviewer subagent runs at effort high (2026-10-04)

**`effort: high`, not `medium` (changed 2026-10-04).** Measured across all projects for the month of September: the whole Sonnet-pinned reviewer+summarizer track was ~4% of total Claude spend ($326 of ~$8,400, list-price estimate) — the dominant costs were main-thread model choice and *unpinned* generic subagents (Explore/Plan/general-purpose riding the parent session's model — see `template/.claude/rules/spinouts.md` [bracketed path added]), not this track. Raising the reviewer's effort increases its token spend per invocation, but against a base that small the absolute cost stays trivial, and review is the one place in the protocol where under-thinking directly costs a missed blocker. No controlled A/B exists comparing medium vs. high review quality here — if one gets built later (same diff, both effort levels, findings diffed against a known-blocker set), record it and revisit. Until then this is a deliberate quality-over-cost call given the measured cost floor, not a measured win.

## The honest cost of two review tiers

The honest cost of this trade: an intermediate reviewer's mistake can shape the implementation and the framing of the next review, and the ship round may miss it again — especially if it is shown only the latest fixes rather than the whole candidate. That is why the ship round reviews the **final candidate in full**, not the delta since the last round. "Round one's defect gets caught later" is the expectation, not a guarantee.

## Paired-review yield, 2026-10-09

**Measured 2026-10-09, and the decision it led to.** Across 31 paired rounds in six sessions (Codex and the `reviewer` subagent each reviewed the candidate of that round, which evolved between rounds) there were 201 distinct blocker/P1/P2 findings, counted by the analysing agents' judgement of "the same defect", so every percentage below is an observational estimate: about 28% found by both, about 42% by Codex only, about 30% by the subagent only. So Codex alone would have covered about 70% and the subagent alone about 58%: the two are NOT redundant, and a "second only if the first is clean" gate would almost never run it (Codex said "do not ship" in 28 of 31 rounds). The ship round therefore normally keeps two independent readers, with composition chosen by the allocation rule [in delegation.md, "Allocate every ship reader"]. The cost side: one 9-round PR spent about 950K Claude tokens on the subagent (about 100K per round measured there; ~180-200K on larger inputs), and from the sixth round on most findings were bugs introduced by the previous round's fixes. The repo owner decided: both readers only on the ship round. Read it as a COST decision, not a yield one: on any intermediate round the second reader's findings (about 30% of the serious ones) are not found then, they surface at the ship round, and a ship round that returns blockers is followed by normal rounds and then a NEW full-set ship round on the final state, so the saving is on the rounds in between. Caveats: the subagent often ran after Codex's fixes had landed (inflating its unique count); the two samples disagree (on one narrow shell change, 7 paired rounds, the subagent alone found 1 of 16 serious findings; on five wider protocol, security and multi-file sessions, 24 paired rounds, it alone found 56 of 185); no transcript contains a higher-effort single reviewer.

## Cache heartbeat: measured, verdict unresolved (2026-10-04/05)

Proposed once: ping an idle session every ~50 min (under the 1h ephemeral cache TTL) for up to 12-24h to avoid a cold-cache rebuild. Mechanism is confirmed accurate: every request that touches a cached prefix bills `cache_read_input_tokens` for the FULL prefix length, every time; there is no cheaper standalone way to extend a cache entry's TTL. Of 207 cold-restart events since Sep 1, 177 fall inside a 24h window, totaling 75.9M tokens to rebuild from scratch at resume (raw `cache_creation_input_tokens`). Pinging all 177 every 50 min for the length of each gap, then resuming warm, costs 498.7M raw tokens moved — **6.57x more tokens than doing nothing.**

**What that 6.57x does NOT settle: whether raw token count is the metric that matters.** Anthropic's own published API pricing weights a cache read at roughly 0.1x base input price and a 1-hour cache write at roughly 2x — a 20x asymmetry in the OPPOSITE direction from the raw-token count, because reads are cheap to serve on the backend and writes aren't. If Claude Code's subscription usage/rate limits are cost-weighted the way the dollar pricing is rather than a flat sum of tokens-moved, heartbeating could be net CHEAPER against the real limit, not 6.57x more expensive — a complete reversal. Anthropic's actual plan-metering formula isn't publicly documented, and nothing here verifies which model applies. **Verdict: don't build persistent heartbeat infrastructure on either conclusion yet.** Before deciding either way: run matched trials — several heartbeat-then-resume cycles AND several cold-resume cycles on comparable work, controlling for other activity in the window — and compare what each does to Claude Code's own usage/rate-limit display specifically (not the API response's token counts, and re-fetch it fresh rather than trusting a cached reading — `/usage` can show a stale one). A couple of pings alone only measures the ping's own cost, not whether it actually beat the cold-resume alternative; this section should be rewritten once a real matched comparison exists.

## Codex MCP server removal (codex-cli 0.154.0, 2026-09-10)

**There is no Codex MCP server, since codex-cli 0.154.0 (2026-09-10).** That release deleted the `mcp-server` subcommand — `strings` on the native binary returns zero occurrences, so it is gone from compiled code, not just from help; `codex mcp` now manages Codex as a *client* (list/get/add/remove/login/logout). Do not try to register it, and do not read `CONNECTION_CLOSED` from a `codex` MCP entry as a network fault: codex forwards an unrecognised subcommand to the interactive CLI as a prompt, the TUI starts, dies with "stdin is not a terminal", and the pipe closes mid-handshake. The error never names the real cause, which is why this read as an outage for hours. `setup.sh` removes the dead registration; `on-session-start.sh` asserts `codex exec` exists rather than assuming it.

## Model steering table: rows moved whole

| Role | Model | Effort | Why | Confidence |
|---|---|---|---|---|
| Main/captain (your own session) | Opus for most work; Fable for one deep, continuous, hard thread; Sonnet for routine work | session default | Fable is 2.5x Opus per token — reserve it for sustained hard reasoning in a SINGLE context. Avoid using it to fan out across many project contexts at once: each pays its own fresh floor regardless of model, so that step should run the cheapest model ADEQUATE for the judgment that step actually needs — not automatically the cheapest available, and not the priciest by default either (reported from a 2026-10-04 transcript audit on one machine, not yet written to a durable record: 5 projects' first calls within 50s on 2026-09-28, ~1.83M fresh tokens, ~97% of that day's Fable cost) | reported, not independently re-checked — see caveat |
| Codex, reviews | `gpt-6.1-sol` | **high** | was `low` (a real misconfiguration — Codex, the primary reviewer by volume, was thinking less than its own Sonnet fallback; fixed). A/B'd once against `gpt-6-astra` on a real review task: same verdict, comparable depth, astra actually faster this run — no clear win, kept `sol` as the default rather than switch on an n=1 tie | fixed; model choice inconclusive, revisit if evidence accumulates |

What this table is *not*: a result of finding one mega-pattern in aggregate error rates (there wasn't one — tool-call error rates sit flat at 1-4% across every model/effort combo, most likely task-difficulty confound rather than model quality signal). It's task-shape-based reasoning plus the handful of things that WERE directly measurable (the Haiku test, the Codex misconfiguration, the Codex A/B) — formalized so the next session doesn't have to re-derive it. Two reported findings — the Main/captain row's incident citation above, and the "## Cache heartbeat" section [above in this file] — come from one machine's transcript audit and haven't been written to a durable record or independently reproduced. Treat those two as leads, not settled fact, until they are.

## Text removed from delegation.md on 2026-11-23 (verbatim fragments)

- [sandbox note, codex-review.sh paragraph] until 2026-10-15 the sandbox was strictly read-only and 22 of 23 reviews in one session said they could not create a scratch file and reviewed by reading, which is the "reviewer that only reads the diff" failure this protocol names.

-  `exec` has no interactive approver, and the wrapper pins `approval_policy="never"` so a user's on-request or auto-review setting cannot approve an escalation; the elicitation problem that `codex-approval-never.sh` existed for cannot arise. That hook is therefore gone from the template and from new projects; existing projects keep an inert copy, since pruning it would mean a settings.json migration for zero behavioural gain — re-running `init.sh` drops the registration anyway. One caveat if you never re-init: that copy matches the tool NAME `mcp__codex__codex`, so a third-party MCP server registered under the name `codex` (which the cleanup deliberately does not delete) would have its input rewritten by a hook written for a different server.

-  *(Found 2026-10-05: this line previously scoped "sanctioned" too narrowly, contradicting the Tool routing table and non-negotiable 4, both of which already required `--pro` on every reviewer-role Gemini call, review-tier or not — pre-existing, not introduced by the change in this diff.)*

- it moves events older than 30 days into the snapshot (`--before YYYY-MM-DD` to choose the cutoff), no content is lost, and `FULL_CONTEXT.md` renders the same apart from one `registers-fold-cutoff` comment line; it refuses while events are uncovered, so review the registers and run `compact-readiness.sh --mark` first. Re-hydration reads a bounded slice of it (`/rehydrate`), so the size of the rendered file is not a problem in itself. The old procedure (send the file to a backend, delete the lines it names, append a compaction note) is retired for exactly that reason; `/prune-context` is kept only for old projects that still hand-append to `FULL_CONTEXT.md`.

## Second extraction, 2026-11-23 (review round on PR #120; verbatim originals)

### Gemini as the no-Codex alternative: full text

**Without Codex, Gemini is the (metered) alternative for non-review work — and only then.** Added 2026-10-08 after finding teammates with no Codex at all, for whom every re-hydration otherwise cost ~125K tokens of their own Claude quota. `reviewers.sh digest-chain` prints `codex subagent` where `codex exec` works (or the probe cannot tell), `gemini subagent` where it answered "unusable" and a `$GEMINI_API_KEY` is set, and `subagent` otherwise; the Claude subagent is printed last; allocation below chooses the first backend among those available. On a machine WITH Codex, `gemini-review.sh` refuses general (non-`--as-reviewer`) calls outright (exit 4; `MEGAVIBE_GEMINI_DIGEST=1` overrides), so Gemini cannot quietly become a third paid path. Where it is allowed, every call is rationed by the script itself, not by this text: flash-lite at thinkingLevel low only (a `--pro` or `--auto` outside a review is downgraded), output capped at 12000 tokens and input at 300 KB, at most 40 general calls and an estimated $1.00 per local day (`MEGAVIBE_GEMINI_DAILY_CALLS`, `MEGAVIBE_GEMINI_DAILY_USD`, `MEGAVIBE_GEMINI_MAX_INPUT_KB`, `MEGAVIBE_GEMINI_MAX_OUT`; a daily cap of 0 or an unreadable value switches general use off). Each call is reserved in the ledger under a lock BEFORE it is sent (a call that fails after sending still counts) and an unreadable or unwritable ledger refuses; the context watcher may use at most 60% of the day so `/rehydrate` keeps a share; the lock needs `perl`, without it general calls refuse and `digest-chain` does not advertise Gemini, exit 5 when a cap is hit so the caller falls through to the subagent, and every call logged to `~/.megavibe/gemini-usage.jsonl` (`gemini-review.sh --budget` shows today's). The context watcher — the heaviest recurring caller — goes through the same script and flushes at half rate while Gemini is its backend. Reviews are never refused by these caps (a skipped review is worse than a spent cent) but are logged and count toward the day's spend. The dollar figure is an estimate priced on the high side (`MEGAVIBE_GEMINI_PRICES` tunes it), not a bill; the API key's own project budget is the real ceiling.

### codex-review.sh paragraph: full text

**Use `~/.megavibe/scripts/codex-review.sh`**, which mirrors `gemini-review.sh`'s interface: `--prompt`/`--prompt-file` plus `FILE...`, files appended as `===== path =====` blocks, `--out`, `--model`, `--timeout` (default 300s, exit 124 on timeout so the chain falls through instead of hanging). The project under review is never writable and there is **no `--sandbox` flag** — passing one is refused (exit 2), as are `--approve-for-me`, `--full-auto` and `--dangerously-bypass-approvals-and-sandbox`. Under `--as-reviewer` Codex runs with a throwaway **scratch directory** as its working directory (writable, `TMPDIR` inside it, deleted on exit; network off; `/tmp` and the project read-only, measured with a canary file), so it can write and run the harnesses a review needs. Both modes also pass `--ignore-rules`: a user's codex exec-policy rules (`$CODEX_HOME/rules`, which codex writes when someone answers "always allow") run an allowed command outside any sandbox and re-opened the project, `$HOME`, `/tmp` and the network (found 2026-10-15 with the real codex, in strict mode too). Not covered: a `notify` command or MCP server in the user's own codex config runs as part of codex itself. `--strict` or `MEGAVIBE_CODEX_SCRATCH=0` restores a fully read-only run; the non-review uses (`/rehydrate`, summaries, memos) stay strict, `--scratch` opts them in. `exec` has no interactive approver and the wrapper pins `approval_policy="never"`, so a user's on-request or auto-review setting cannot approve an escalation; `codex-approval-never.sh` is gone from the template and from new projects; existing projects keep an inert copy, and re-running `init.sh` drops its registration. If you never re-init, that copy matches the tool name `mcp__codex__codex`, so a third-party MCP server named `codex` would have its input rewritten by it (history: **`README-delegation-measurements.md`**).

### The sweep gate: full text with the 2026-11-19 audit

**The sweep is enforced, not remembered (added 2026-11-16, tightened 2026-11-19).** The step below was skipped almost every time it relied on memory, so `codex-review.sh` and `claude-review.sh` refuse an `--as-reviewer` call (exit 6) unless the amass ledger holds an `amass.sh run` for the directory you run in (full path; rows from before the path was recorded match on the basename) from the last 120 minutes (`MEGAVIBE_AMASS_GATE_MINS`) in which at least one call succeeded and, in a git checkout, of the same content: the run records a tree hash of the tracked files, taken when it froze its input (every `.agent/` and `megavibe-deliverables/` left out), so a fix edit or fix commit after the sweep needs a new sweep, while committing exactly the swept content does not. The only waivers are `--no-amass "oversize: ..."` (the files handed to the reviewer, data files left out, exceed 140 KB: amass caps its whole prompt at 150 KB) and `--no-amass "prose: ..."` (every file, and every path in a passed `.patch`/`.diff`, is prose or data), both checked by the script, and `--no-amass "hotfix: ..."`, accepted unchecked but shown as an owed sweep at session start and in `tick.sh` until a sweep runs in that directory. Any other reason is refused (exit 2): "the sweep ran earlier on the branch", "a small diff" and "another author's PR" are not waivers (an audit of 71 free-text waivers on 2026-11-19 found about 52 outside the exemptions, and readers found defects in most of the waived re-review rounds). A `--dry-run` does not count. `MEGAVIBE_AMASS_GATE=0` switches the gate off. Outside git, and for untracked files, only the window applies. The `reviewer` subagent is not a script and is not gated: run the sweep before it by the same rule, and say in the round if you waived it. Detail: `scripts/amass-gate.sh`.

### Cut rounds: motivating measurement

In one session, four PRs cost about 22 Codex review calls and 8 implementation runs: the rounds were the expense, not the price of a call. 

### Cut rounds: stale-base example

 (a stale base returned findings already fixed on main)

### Cut rounds: untested-claim example

 (an untested claim cost a whole two-reader round)

### Cut rounds: dismissed-cluster example

 (measured 2026-11-16: a dismissed cluster was exactly the P1 both readers then reported, a whole two-reader round spent on what the sweep had already found)

### reviewers: auto/all history

`auto` and `all` used to be the same word for the same thing, because the default WAS all three. They are different now, so `set all` writes the literal value instead of clearing the setting. A pin written by the OLD command cannot be recovered — it cleared the setting, which is indistinguishable from never having chosen — so the session-start hook says once, per machine, that the default changed and how to get all three back.

### reviewers: first-cut bug

 Getting this backwards is the bug the first cut shipped — `MEGAVIBE_REVIEWERS="reviewer"` silently stripped `/rehydrate` of both external backends.

### reviewers: committed-file rationale

 It arrives with a clone, written by whoever wrote the repo, and a repo that can switch off the reviewers reading its own code is a hole, not a feature; a reducing pin there is ignored with a warning.

### reviewers: allow-list rationale

Allow-list rather than ignore-list on purpose: the config states exactly which backends may review, where an ignore-list only says it relative to whatever happens to be installed on the machine. The cost is that a reviewer added to megavibe later is off for anyone who has pinned a list.

### Model steering table, full (second extraction)

| Role | Model | Effort | Why | Confidence |
|---|---|---|---|---|
| Main/captain (your own session) | Opus for most work; Fable for one deep, continuous, hard thread; Sonnet for routine work | session default | Fable is 2.5x Opus per token: reserve it for sustained hard reasoning in a SINGLE context, avoid using it to fan out across many project contexts at once (each pays its own fresh floor): each fan-out step runs the cheapest model adequate for the judgment that step needs, not automatically the cheapest and not the priciest. The cost audit behind this is a lead, not settled fact: **`README-delegation-measurements.md`** | reported, not independently re-checked |
| `reviewer` subagent | Sonnet | **high** | ~4% of measured Claude spend; under-thinking here costs missed blockers; base cost too small to justify going cheaper | deliberate, cost floor measured, review *quality* not A/B'd |
| `summarizer` subagent | Sonnet | session default | proven since the 2026-09-18 four-backend test (table in the README). Haiku matched it once on a real task — comparable density, fewer tokens, half the price — not yet switched; needs a second confirming run | n=1, promising |
| Explore / Plan / general-purpose — judgment-heavy | inherit parent | — | architecture tradeoffs, ambiguous debugging — state why when letting it inherit | deliberate default-to-override |
| Explore / Plan / general-purpose — moderate research/search | **Sonnet** | — | the main fix: 76% of all subagent calls were silently riding an Opus/Fable parent for work that didn't need it | measured, fixed 2026-10-04 |
| Explore / Plan / general-purpose — pure digest/extraction, no judgment | **Haiku** | — | matched the sonnet subagent's output density once, fewer tokens, half the price | n=1, promising |
| `fork` | n/a — shares parent's cache; **default to inheriting, don't override** | n/a | a fork can reuse the parent's warm, MATCHING prefix, avoiding another cache write for that shared portion — it does NOT make new reasoning, new output, or the cache reads on top of that prefix free, and the reuse only holds while the prefix still matches (changing the model invalidates it, trading the cache saving for whatever that model swap was meant to buy). Override the model only when the task's judgment need is high enough to justify losing the cache — that's the exception, not the default | by design, scope corrected 2026-10-05 |
| Codex, reviews | `gpt-6.1-sol` | **high** | was `low` (a misconfiguration, fixed); one A/B against `gpt-6-astra` was a tie, so `sol` stays | fixed; model choice inconclusive |
| Codex, summarize/rehydrate | `gpt-6.1-sol` | `low` | effort doesn't help digesting a log — the model sets time and length, not the effort knob (2026-09-18 measurement) | established, for this task shape only |
| Codex, research memos | `gpt-6.1-sol` | judge per task | the 2026-09-18 measurement only tested log-digesting; a research memo makes tradeoff judgments and recommendations, a different task shape — not covered by that result | unmeasured, don't extend the low-effort finding here |
| Gemini | eligible by default, off as a peer by default, never as a reviewer on **this machine** | — | the template still ships Gemini as Codex's configurable fallback (`megavibe reviewers set all` restores it everywhere) — this row records a personal `MEGAVIBE_REVIEWERS=reviewer codex` pin on this one machine, not a protocol change. Every other section of this file and of `CLAUDE.md` describing Gemini as Codex's fallback is still the shipped default for every other user | personal setting, scope-corrected 2026-10-05 — do not read as "removed from megavibe" |

### Spinouts: batch-job measurement (second extraction, verbatim)

**Why, measured 2026-10-11 on one real job** (one Sonnet subagent, 109 image pairs and 3,744 image reads as counted by the author from the transcript, 387 requests; input tokens only, parent orchestration not counted):
- **No re-caching at first.** The context grew to 394K tokens without one.
- **Then repeated resets.** From there, 107 requests read only the 17.6K-token system prefix from cache and re-sent the rest as fresh input. 104 of those came with a shrinking context, most likely Claude Code trimming old tool results; that mechanism is inferred, not confirmed. 19 of them followed a pause of over 5 minutes, so cache expiry explains some too. Later resets came at 375-918K, so the trigger is not one fixed size.
- **Result: 66.5M fresh input tokens and 131M cache reads.** Ordinary calls added 8.8M tokens of new content; about 11M is the estimate counting the reset calls.
- **Projection.** A simulation over the same requests, with a new subagent before 250K (74 subagents, each paying the job's 74K first call again), gives 16.7M fresh and 54M reads. That is 2.8x fewer raw tokens, or 3.7x cheaper weighted by API price (cache read about 0.1x, 5-minute write 1.25x; at the 1-hour write's 2x it is 3.8x). How either maps onto subscription limits is not documented.
- **Checks, one assumption changed at a time.** Weighted savings: 3.3x keeping the observed cache expiries; 2.2x keeping every observed reset; 2.8x with all per-call growth scaled 1.4x (mean over median); 2.0x with per-call growth doubled; 2.1x with the briefing doubled.
- **Stacked worst case.** Doubled growth plus doubled briefing gives 1.1x, and adding the expiries and resets gives 0.9x.

This is a projection from one job on one Claude Code build, not a measured re-run; re-measure if a later build behaves differently. Across the single-assumption checks the saving is about 2-4x; it holds only while each batch's fixed cost stays small next to the context it saves. At this job's 74K first call, a 350K cap instead of 250K changes the simulated saving by only about 0.1x; with a large briefing the higher cap recovers much more (2.1x against 1.1x at 200K), so a bulky briefing is a reason to batch closer to 350K, at the cost of less margin below the first reset.

### Spinouts: cache-warm measurement (second extraction, verbatim)

Measured
2026-10-14 in one project: three long subagents (contexts of 790-970K) each sat
in 34-38 foreground waits of 5-9 minutes and re-wrote about 500K tokens every
time: 51M cache-written tokens (about 64M weighted at 1.25x) plus 548M cache
reads (about 55M at 0.1x) made about 119M of that session's 190M price-weighted
tokens that day (63%). The weights are API list-price ratios, an assumption: how
plan limits meter cache reads and writes is not documented, and `delegation.md`
("Cache heartbeat") shows the raw-token count can point the other way. Not
reproduced on another project.

## CLAUDE.md moves, second extraction (verbatim originals)

### CLAUDE.md: Deliverables paragraph (full)

**Deliverables and open decisions: where the project has a `megavibe-deliverables/` folder (visible, gitignored; `init.sh` creates it).** Reports, review syntheses and plans the user will read go there as clean Markdown or HTML, not only in `.agent/` or on a hosted page (working notes stay in `.agent/RESEARCH/`, but a memo, report, analysis or retrospective the user asked for is a deliverable even when it is research, and a chat answer alone does not satisfy such an ask; a deliverable that must outlive the working copy is also recorded where it durably lives). Log every such ask (not every question: one that only wants a chat answer needs no row) in STATUS.md's `## Asked for` table when it is made (ask, date, file, mirror, state): it is `done` only when its file is in the folder, and the pre-compact hook carries counts of open rows past a compaction. Keep `megavibe-deliverables/STATUS.md` current in the same turn things change: the state plus every decision the user owes as a numbered `D<n>` block with options, a default and an `Answer:` line the user can fill in at any time (`status-sync.sh` relays it). Do not leave a routine open end inline ("your call", "later", "say go"): put it in STATUS.md and continue on the stated default, or say you are blocked on D<n>; destructive or irreversible questions, and anything this protocol says to stop and ask about, are still asked in chat. **Phone copy:** the user reads on a phone / Remote Control and cannot open laptop folders, so when the user is remote or says "sync", send every file `~/.megavibe/scripts/deliverables-index.sh unsent` lists with `SendUserFile` (one call each, date order; a directory entry is described in chat and only its `NOTE.md` is sent), record each with `deliverables-index.sh mark <file> sent <date>` and send the rebuilt `INDEX.md`; a file with customer, personal or billing data, or confidential material, is never sent without asking in chat (`mark <file> skipped: <reason>`, name and reason kept generic because `INDEX.md` reaches the phone; a confidential folder is marked skipped when it is created). Format and rules: **`.claude/rules/deliverables.md`**.

### CLAUDE.md: kubectl exec paragraph (full)

**`kubectl exec` is a write, not a read.** `kubectl exec`, `attach`, `cp`, `debug`, `port-forward` (and `oc` equivalents) are **writes** — they start a process inside a live production container, and in a zero-headroom pod (`request.mem == limit.mem`) the OOM killer then takes the *server*, not your shell. Wanting to print an env var feels like reading; the mechanism decides the category, not the intent. Get it from the manifest instead — `get`/`describe`, image tag, env block, sealed secret, repo — and never spend production risk to *confirm* something you already have evidence for. `block-dangerous-bash.sh` blocks this class fail-closed unless the namespace/context visibly names non-prod (`MEGAVIBE_ALLOW_PROD_EXEC=1` to override). Note too that editing a Deployment's pod template — **including one env var** — rolls every pod, so a GitOps sync of a manifest PR *is* a production restart. Full rules: **`.claude/rules/prod-access-discipline.md`**.

### CLAUDE.md: auth-failure paragraph (full)

**Never answer an auth failure with "run `gcloud auth login`".** `cloud-token.sh` exports a freshly minted token file (`CLOUDSDK_AUTH_ACCESS_TOKEN_FILE`) in front of any command that mentions `kubectl`, `gcloud`, `kubeseal` or `helm` (GKE kubectl gets it through gcloud), so a reauth wall is the hook's job, not the user's — it is inert until `~/.megavibe/personal/cloud-token.conf` names a token file and a keeper. A command mentioning gcloud with `auth`, `config`, `components` or `init`, or one that picks its own identity (`--account`, `--configuration`, impersonation, `CLOUDSDK_*` overrides) deliberately gets no token, and the hook says so; run the cluster command as its own call then. If a command still fails on auth, report that plainly instead of sending the user to an interactive login.

### CLAUDE.md: long-running processes paragraph (full)

**Long-running processes.** Don't disown servers, watchers, or polling loops to launchd — no `nohup`, no bare `&` from a shell that's about to exit, no `disown`. Use Bash `run_in_background`, foreground in a terminal the user is watching, or a named tmux session. Anything else and the user finds the process parented to PID 1 a week later. Bind dev servers to `127.0.0.1` by default — uvicorn, `python -m http.server`, vite, next dev all default to `0.0.0.0`, exposing internal services on the LAN; change it explicitly. Polling loops against authenticated APIs (kubectl, gcloud, GitHub, k8s) **must exit on auth failure** rather than retry — one watchdog with no fail-fast generated 1.2M gcloud log files in 14 days. When you start a long-running process, report PID/session, port, how to find it, and how to kill it. **A background task nobody is watching is a task that can crashloop forever.** The harness notifies on completion only; a hung or restarting task never completes, so silence looks exactly like progress. Never end a turn "waiting" on a `run_in_background` Bash or an async Agent: arm a `Monitor` heartbeat on its output file (every ≤5 min: byte or entry delta plus tail) the moment you start it, read the output on every beat, and judge `+0` against what the task is — a build at `+0` is hung, an idle server at `+0` is fine, repeating lines are a crashloop — then act. `watch-background.sh` tells you to arm it at start and blocks a turn from ending on an unchecked task older than the interval (default 5 min, `MEGAVIBE_BG_CHECK_SECS`) — the net, not the mechanism. Full rules: **`.claude/rules/process-discipline.md`**.

### Trash paragraph: 2026-09-08 incident

 — the hook rewrites those too, and reaching for one is the exact move that destroyed a credential file on 2026-09-08.

### Trash paragraph: 2026-10-26 incident

(a glob plus `rmtree` destroyed finished work on 2026-10-26; a worktree removal deletes

### Trash paragraph: 2026-09-30 incident

 (an agent "freeing space" wiped one on 2026-09-30)

### Disk paragraph: 2026-11-03 incident

 (14.8 GB in one session on 2026-11-03, found by the user at 8 GB free)

## Third extraction, 2026-11-23 (small history/anecdote cuts; verbatim originals)

### prod-access: 2026-11-15 mail incident narrative

On 2026-11-15 a "read-only" comparison of admin pages, run before and after a
routing change, requested one page that queues a mail to every active customer
on each plain GET. Six requests queued about 70,000 mails; about 9,300 were
delivered before anyone looked. The page had been classified by its name and
the size of its output. Its code was 71 lines.


### process-discipline: silence anecdote

Sessions have waited an
hour on that silence. A completion event is not monitoring.

### process-discipline: main-thread cache note

The main thread's cache usually lives 1 hour (subscription default; 5 minutes
on API billing or when forced), so the default four-minute beat is cheap there
and not a reason to beat faster. 

### spinouts: September measurement detail

(measured over September 2026: 76% of all subagent API calls that month ran on Opus/Fable because the calling sessions did, at 2-5x Sonnet's per-token price, for work — file search, mechanical research — that doesn't need it)

### spinouts: haiku measurement pointer

 — measured once (2026-10-04, see the backend comparison in `README-delegation-measurements.md` (https://github.com/poma-ai/megavibe/blob/main/README-delegation-measurements.md)) at comparable quality to the sonnet subagent, fewer tokens, half the per-token price;

### delegation: two-tiers cost aside

 — in one session here, two invocations cost 386K tokens (measured at `effort: medium`; `effort: high` costs more per invocation, deliberately — see below)

### delegation: steering table disclaimer

What this table is *not*: a result of an aggregate error-rate pattern (there was none). It is task-shape reasoning plus the few things directly measured (the Haiku test, the Codex misconfiguration, the Codex A/B). The Main/captain row's audit and the cache-heartbeat numbers come from one machine's transcript audit, not independently reproduced: treat both as leads. Detail: **`README-delegation-measurements.md`**.

### delegation: Codex idle-gap measurement

 (measured gaps of 86 s and 264 s)

### delegation: Codex .output remark

 (false Stop-hook alarms, and a user asking what the job is doing)

## Fourth extraction, 2026-11-23 (verbatim originals)

### CLAUDE.md: Skills list (full)

- `/rehydrate` — regenerate WORKING_CONTEXT.md from .agent/ files via Codex, or capped Gemini where there is no Codex (Claude subagent behind either)
- `/catchup` — orient yourself in a project at session start (reads .agent/ + git state)
- `/init-feature <description|issue link>` — scope a feature before building, from prose or a GitHub ticket: a summary and estimate you confirm or send back, then a fork (write a spec, or vibe it)
- `/finish-feature [base]` — measure what the finished feature actually cost (turns, tool calls, tokens, diff size), score it against that estimate, comment it on the PR and offer to merge
- `/prune-context` — **superseded.** Compaction is now `.claude/hooks/agent-log.sh fold`, which moves old entries into `.agent/snapshot.md` instead of asking an AI which lines to delete from a log nobody can reconstruct. **Not the same as `/compact`** — see the decision table below.
- `/megavibe-restart` — update megavibe and restart this session with new hooks/rules/skills applied
- `/watch [interval] [org/repo ...]` — unattended ticks: every 30 min (default) a deterministic `tick.sh` report of review requests, comments and pushes from others on the watched repos, Linear comments, the login lifetime and both subscriptions' usage; act on it, one line when quiet. Before any unattended window run `~/.megavibe/scripts/claude-auth-check.sh` (`megavibe auth`): a refresh token that lapses kills the session and `/login` does not work over Remote Control. `/watch off` stops it.

### CLAUDE.md: codex probe rationale

 Assert the subcommand rather than assuming it: an auto-updating npm-global CLI will keep removing things, and the resulting error never names the real cause.

### CLAUDE.md: Gemini caps restatement

there `gemini-review.sh` meters every call (flash-lite only, never Pro; daily caps of 40 calls, $1 and 300 KB input; `--budget` shows today's spend), so a missing key costs nothing while Codex is up.

### delegation: xhigh removal history

 (the automatic `xhigh` was removed on 2026-10-11 after it timed out on real large reviews and a blind benchmark found it no better)

## Fifth extraction, 2026-11-23 (verbatim originals)

### CLAUDE.md: Disk space paragraph (full)

**Disk space is finite.** `disk-check.sh` tells the session when free space is under 15 GB (`MEGAVIBE_DISK_WARN_GB`; opt out with `MEGAVIBE_DISK_WATCH=0`): at session start, after every compaction, and from `log-tool-event.sh` once per 5 minutes of tool activity (`MEGAVIBE_DISK_CHECK_MINS`, 0 switches the mid-session check off; needs perl, for the lock and the deadline), speaking once per level change. The space a long session eats is mostly its own: reviewer repo copies, venvs and model downloads in the scratchpad. When disk is low, first run `~/.megavibe/scripts/worktrees-audit.sh audit` to report what is big; `remove-safe` only touches clean, fully pushed, merged worktrees (or detached duplicates reachable from a remote ref), excluding locked, main and current worktrees. Review `remove-safe --dry-run` before removal. Before a job that writes gigabytes — datasets, model weights, virtualenvs, builds, worktrees — run `~/.megavibe/scripts/disk-watch.sh check`; for a long one arm a `Monitor` on `~/.megavibe/scripts/disk-watch.sh watch`, which prints only on a 1 GB move or a threshold crossing. `rm`-style deletes routed through rm-to-trash go to the Trash: they are recoverable and free no space until the user empties it (a Trash review only marks items droppable). `git worktree remove`, `git clean` and similar operations delete for real and free space at once; they do not go through the Trash (the forced forms are refused; plain `git worktree remove` still deletes ignored files). Report first and let the user decide about emptying the Trash (in Finder, or offer `~/.megavibe/scripts/trash-empty.sh` as described above for them to approve the prompt); never empty the Trash yourself any other way.

### CLAUDE.md: Pre-compact paragraph (full)

**Pre-compact** (PreCompact hook): A hook records the current `.agent/` file status and how long ago the newest event was written, plus, where the project has `megavibe-deliverables/STATUS.md`, counts of asks without a file, of newer research notes and of an over-long `Now` (see Deliverables), plus a register-currency warning when `TASKS.md` section 0 carries a date stamp older than seven days (silent unless the project uses that section and stamps it; `MEGAVIBE_REGISTER_MAX_AGE_DAYS` tunes the age). Claude Code discards a PreCompact hook's message, so the report goes to stderr for the user and to a timestamped `.agent/LOGS/pre-compact-alert.*.md`; the register warning is carried into the post-compact message. It ignores a subagent's compaction, which is not this session's.

### CLAUDE.md: Proactive nudge paragraph (full)

**Proactive nudge** (safety net, only when context-watcher is OFF): A hook measures transcript token usage and nudges at three escalating tiers — 🟡 50% / 🟠 75% / 🔴 90% of the model's effective auto-compact threshold (Claude Code's native default, typically ~80% of model context). When the context-watcher daemon is alive for the session (the default), these nudges suppress entirely — the watcher keeps `.agent/` fresh between turns and the in-session nudges become noise. Set `autoCompactWindow` in `.claude/settings.json` or `$CLAUDE_CODE_AUTO_COMPACT_WINDOW` to impose a project- or user-level cap. Each tier fires at most once; the counter resets after an actual compaction.

### prod-access: shlex history

Parsing uses Python's `shlex`, not a regex. A regex first cut was defeated by
`bash -c "kubectl exec …"`, by `kube'ctl' exec`, by a backslash-newline
continuation between `kubectl` and `exec`, and by `COLOR=#ff00aa kubectl exec …`
(a `#` inside a word is not a comment) — and it wrongly blocked
`kubectl get pod exec` by scanning every word for the verb instead of parsing
the subcommand. Shell is not a regular language. Without `python3` the guard
skips rather than blocks, the same posture `rm-to-trash.sh` takes.
