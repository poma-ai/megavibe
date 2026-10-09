# Tool Routing and Delegation Protocols

## Universal fallback principle

**Megavibe works with ONLY a Claude Code subscription.** External backends (Codex, Gemini) improve quality for specific tasks but are never required. Every task has a last-resort path through Claude itself (via the `summarizer` subagent at `.claude/agents/summarizer.md`).

**The standard chain, for every task** (`~/.megavibe/scripts/reviewers.sh digest-chain` prints the order for non-review work on this machine; the list below is the full set, Gemini applies only as the next paragraph says):
1. **Codex** — `~/.megavibe/scripts/codex-review.sh --prompt "..." FILE...` (NOT an MCP server — see below). For a summarising job add `--effort low`; for a review leave `--effort` off and let the user's own `~/.codex/config.toml` choose, but **pass `--timeout 600`** (double the script's 300s default; a review you run in the BACKGROUND, as you should any long job, can pass `--timeout 900` or more, and then, when Codex's week is under-used, the script runs an unspecified review at `xhigh`; a foreground Bash call cannot outlast 600s, so it never gets the bump). Add `--model` only if you are prepared to re-run without it when that model is not on this plan: a pinned name that a plan does not expose fails every call and pushes the work to the Claude subagent's 125K tokens.
2. **Claude subagent** — `.claude/agents/summarizer.md`, no key, always available, and the best output of the three on a context digest. It spends the same subscription quota the session runs on, which is the only reason it is not first.
3. **Gemini** — `~/.megavibe/scripts/gemini-review.sh --prompt "..." FILE...` (requires `$GEMINI_API_KEY` from a **billed** project — Google-account OAuth was retired 2026-06-18, and the free tier is 20 req/day and trains on prompts). Every token is billed and on reviews it is the weakest of the three, so it is last.
4. Gemini MCP (`mcp__gemini-cli__ask-gemini`) — short interactive questions only; the CLI it wraps hardcodes 3.x thinking, so long answers truncate or take minutes.

**Without Codex, Gemini is the (metered) alternative for non-review work — and only then.** Added 2026-10-08 after finding teammates with no Codex at all, for whom every re-hydration otherwise cost ~125K tokens of their own Claude quota. `reviewers.sh digest-chain` prints `codex subagent` where `codex exec` works (or the probe cannot tell), `gemini subagent` where it answered "unusable" and a `$GEMINI_API_KEY` is set, and `subagent` otherwise; the Claude subagent is always last. On a machine WITH Codex, `gemini-review.sh` refuses general (non-`--as-reviewer`) calls outright (exit 4; `MEGAVIBE_GEMINI_DIGEST=1` overrides), so Gemini cannot quietly become a third paid path. Where it is allowed, every call is rationed by the script itself, not by this text: flash-lite at thinkingLevel low only (a `--pro` or `--auto` outside a review is downgraded), output capped at 12000 tokens and input at 300 KB, at most 40 general calls and an estimated $1.00 per local day (`MEGAVIBE_GEMINI_DAILY_CALLS`, `MEGAVIBE_GEMINI_DAILY_USD`, `MEGAVIBE_GEMINI_MAX_INPUT_KB`, `MEGAVIBE_GEMINI_MAX_OUT`; a daily cap of 0 or an unreadable value switches general use off). Each call is reserved in the ledger under a lock BEFORE it is sent (a call that fails after sending still counts) and an unreadable or unwritable ledger refuses; the context watcher may use at most 60% of the day so `/rehydrate` keeps a share; the lock needs `perl`, without it general calls refuse and `digest-chain` does not advertise Gemini, exit 5 when a cap is hit so the caller falls through to the subagent, and every call logged to `~/.megavibe/gemini-usage.jsonl` (`gemini-review.sh --budget` shows today's). The context watcher — the heaviest recurring caller — goes through the same script and flushes at half rate while Gemini is its backend. Reviews are never refused by these caps (a skipped review is worse than a spent cent) but are logged and count toward the day's spend. The dollar figure is an estimate priced on the high side (`MEGAVIBE_GEMINI_PRICES` tunes it), not a bill; the API key's own project budget is the real ceiling.

**Subscription usage steers the main thread and subagent pinning, never the review floor.** `megavibe` reads the Claude usage history the statusline keeps (`scripts/usage-route.sh`) and, on a fresh launch with no explicit `--model`/`--effort` and no model or effort pinned by the environment or project settings (each half separately), starts an over-used account on `sonnet`/`medium` and an under-used one (capacity that will reset unspent) on `opus`; a `usage router:` line from `usage-advisory.sh` says once per band how to pin subagents (`haiku`/`sonnet` when hot, inherit when capacity would be wasted). It does not touch the reviewer tiers above: the `reviewer` subagent stays pinned and a normal round still goes to Codex first. API billing is barred at launch (`MEGAVIBE_ALLOW_API_BILLING=1` to accept). Codex gets the same bands from its own weekly rate-limit records (`usage-route.sh codex`): in `under`, a review that named no `--effort` or `--model` and was given `--timeout 900` or more (a review run in the background) runs at `xhigh`; in `over`, nothing changes. `usage-route.sh balance` tells the session which subscription optional work should lean on when the two projections differ by 20 points or more, or one runs hot. It is advice; `digest-chain` and the review tiers are not touched.

**Reasoning-effort/timeout asymmetry, found and fixed 2026-10-04.** `~/.codex/config.toml` had `model_reasoning_effort = "low"` while the Claude `reviewer` subagent ran `medium` (now `high`) — Codex, the *primary* reviewer by call volume, was configured to think less than its own fallback. Measured over September: of 1,015 `codex-review.sh`/`gemini-review.sh` calls, ~21.3% actually failed (10.5% timeout at the 300s default, 10.8% error — separate from the 1.9% that exited 4 as a deliberate `MEGAVIBE_REVIEWERS` skip, which is a setting, not a failure, and does not trigger a reviewer-fallback report). Each real failure on a review call falls through to the costlier Sonnet `reviewer` per the protocol's own fallback rule, which both inflates Claude spend and quietly erases the intended Codex-first ordering; non-review Codex calls (re-hydration) fall through to the `summarizer` subagent instead, per the chain above — research is the documented exception (Gemini stays ahead of the subagent there; see the Research memo section below). Bumped `model_reasoning_effort` to `high` directly in `~/.codex/config.toml` (a personal file, not this repo) and smoke-tested at the new setting: a small single-file review ran in 21s, well inside even the old 300s cap — but that was a trivial task, and real multi-file reviews that run tests will run longer at higher effort, which is why the timeout above doubled too. `~/.codex/sessions/` shows real, growing Codex usage (not idle) but at roughly 7% of Claude's measured call volume over the same window — directional evidence of headroom, not a measured quota ceiling, since one `codex exec` call can cover what several Claude turns do. A/B'd once since (2026-10-05): `gpt-6.1-sol` vs. `gpt-6-astra`, both at `high` effort, same real review task. Same ship verdict, comparable depth, astra marginally faster this run. No clear win on n=1 — kept `sol` as the default rather than switch on a tie. The backend comparison above measured summarisation, not review quality, and explicitly found astra's longer summary wasn't a more accurate one, so that comparison doesn't carry over; revisit the model choice if more review trials show a consistent gap either way.

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

**A Codex quota day is the weakest configuration megavibe has.** Reviews, re-hydration and the watcher's five-minute flush all draw on the same subscription; on the day these numbers were measured, Codex was exhausted for ~3 hours, leaving reviews to the `reviewer` subagent plus `gemini-review.sh --as-reviewer --fallback --pro` — the same audit recorded Gemini alone approving five changes with real blockers. On a quota day: **treat every Gemini finding as a lead to reproduce and every Gemini verdict as unverified**, say so in the synthesis, and prefer holding a risky merge over shipping on one unreproduced review. `megavibe reviewers set all` pays for the third opinion every day instead of relying on it only when the primary is down.

**Reviews rank differently — depth is the point.** Codex reads the repo, runs tests, reproduces failures; over 11 paired reviews in one day it found real defects in every unit. Gemini — one stateless call over inlined files — produced four wrong headline findings and five SHIP verdicts on code with confirmed blockers (one "a masterclass" on a patch with a P1 in it). That's why it's the fallback, not a third opinion, and why it always gets `--pro` when it reviews.

**There is no Codex MCP server, since codex-cli 0.154.0 (2026-09-10).** That release deleted the `mcp-server` subcommand — `strings` on the native binary returns zero occurrences, so it is gone from compiled code, not just from help; `codex mcp` now manages Codex as a *client* (list/get/add/remove/login/logout). Do not try to register it, and do not read `CONNECTION_CLOSED` from a `codex` MCP entry as a network fault: codex forwards an unrecognised subcommand to the interactive CLI as a prompt, the TUI starts, dies with "stdin is not a terminal", and the pipe closes mid-handshake. The error never names the real cause, which is why this read as an outage for hours. `setup.sh` removes the dead registration; `on-session-start.sh` asserts `codex exec` exists rather than assuming it.

**Use `~/.megavibe/scripts/codex-review.sh`**, which mirrors `gemini-review.sh`'s interface: `--prompt`/`--prompt-file` plus `FILE...`, files appended as `===== path =====` blocks, `--out`, `--model`, `--timeout` (default 300s, exit 124 on timeout so the chain falls through instead of hanging). Read-only is pinned and there is **no `--sandbox` flag** — passing one is refused (exit 2), as are `--approve-for-me`, `--full-auto` and `--dangerously-bypass-approvals-and-sandbox` — a reviewer does not need write access. `exec` has no interactive approver, so the old `approval-policy: "never"` is implicit and the elicitation problem that `codex-approval-never.sh` existed for cannot arise. That hook is therefore gone from the template and from new projects; existing projects keep an inert copy, since pruning it would mean a settings.json migration for zero behavioural gain — re-running `init.sh` drops the registration anyway. One caveat if you never re-init: that copy matches the tool NAME `mcp__codex__codex`, so a third-party MCP server registered under the name `codex` (which the cleanup deliberately does not delete) would have its input rewritten by a hook written for a different server.

**Gemini thinking, measured 2026-09-06:** `gemini-3.8-flash` spends 15–40K thought tokens on a review prompt by default and returns almost no text under any output cap; `thinkingLevel: low` returns the complete answer in seconds. `gemini-review.sh` sets it. Keep `-m`/model overrides to flash except through `gemini-review.sh --pro` for reviews; the Pro line has no free tier and bills 3-16x flash.

**Never retry a failed MCP call more than once.** Move to the next fallback immediately.

**Do not fan a job out to several cheap models instead of one good one.** The measured failure mode is shallow work, not too few opinions: models that cannot run the code agree with each other and still miss the P1. Depth first, then a second independent reader.

## Two review tiers, and why

Every round gets **one** reviewer — Codex where it is switched on and its call succeeds, otherwise the `reviewer` subagent (Gemini may join that round, never take it alone). The round that gates the ship gets every eligible reviewer **in parallel**; intermediate rounds do not, critical work included. Critical means credentials or security, data loss or destructive paths, anything public or user-facing, the protocol and templates themselves, and anything the user names: such work is held to the same ship round and is the work for which a missing or failed review is least acceptable, but it does not get a second reader on rounds that are still moving.

The reason is cost asymmetry, measured. Codex draws on a separate plan; the `reviewer` subagent draws ~180-200K tokens of the SAME subscription the session is spending — in one session here, two invocations cost 386K tokens (measured at `effort: medium`; `effort: high` costs more per invocation, deliberately — see below). Running both on every intermediate round spends the user's Claude subscription quota (a different resource from the session's context window, and the one that runs out) to re-check work that is still moving. Running only Codex on the last round ships on a single unreproduced opinion.

**`effort: high`, not `medium` (changed 2026-10-04).** Measured across all projects for the month of September: the whole Sonnet-pinned reviewer+summarizer track was ~4% of total Claude spend ($326 of ~$8,400, list-price estimate) — the dominant costs were main-thread model choice and *unpinned* generic subagents (Explore/Plan/general-purpose riding the parent session's model — see `spinouts.md`), not this track. Raising the reviewer's effort increases its token spend per invocation, but against a base that small the absolute cost stays trivial, and review is the one place in the protocol where under-thinking directly costs a missed blocker. No controlled A/B exists comparing medium vs. high review quality here — if one gets built later (same diff, both effort levels, findings diffed against a known-blocker set), record it and revisit. Until then this is a deliberate quality-over-cost call given the measured cost floor, not a measured win.

The honest cost of this trade: an intermediate reviewer's mistake can shape the implementation and the framing of the next review, and the ship round may miss it again — especially if it is shown only the latest fixes rather than the whole candidate. That is why the ship round reviews the **final candidate in full**, not the delta since the last round. "Round one's defect gets caught later" is the expectation, not a guarantee.

Iterating toward a fix is a normal round. The last one before merge is not. A change that goes through exactly one review round is having its ship round, so it gets the full set.

**Decide the tier before the round, not after.** Nothing ships on an intermediate review: before merging, deploying, publishing or calling an important result done, the final candidate must have had a full-set review. For a follow-up after a completed full-set review, apply the verification-only test of non-negotiable 4; its conditions live there only, so the two copies cannot drift, and its other stated exceptions apply as written there. Any substantive, uncertain or critical change requires independent review before shipping. If a round you started as "normal" turns out to be the last, run the missing reviewers on the final state first. Otherwise a change can be reviewed cheaply forever and then merged on the strength of a round that was never the gate.

**Measured 2026-10-09, and the decision it led to.** Across 31 paired rounds in six sessions (Codex and the `reviewer` subagent each reviewed the candidate of that round, which evolved between rounds) there were 201 distinct blocker/P1/P2 findings, counted by the analysing agents' judgement of "the same defect", so every percentage below is an observational estimate: about 28% found by both, about 42% by Codex only, about 30% by the subagent only. So Codex alone would have covered about 70% and the subagent alone about 58%: the two are NOT redundant, and a "second only if the first is clean" gate would almost never run it (Codex said "do not ship" in 28 of 31 rounds). The ship round therefore keeps both. The cost side: one 9-round PR spent about 950K Claude tokens on the subagent (about 100K per round measured there; ~180-200K on larger inputs), and from the sixth round on most findings were bugs introduced by the previous round's fixes. The repo owner decided: both readers only on the ship round. Read it as a COST decision, not a yield one: on any intermediate round the second reader's findings (about 30% of the serious ones) are not found then, they surface at the ship round, and a ship round that returns blockers is followed by normal rounds and then a NEW full-set ship round on the final state, so the saving is on the rounds in between. Caveats: the subagent often ran after Codex's fixes had landed (inflating its unique count); the two samples disagree (on one narrow shell change, 7 paired rounds, the subagent alone found 1 of 16 serious findings; on five wider protocol, security and multi-file sessions, 24 paired rounds, it alone found 56 of 185); no transcript contains a higher-effort single reviewer.

**The floor is one independent reviewer, never zero.** On a machine with only a Claude subscription, that is the subagent on every round, because there is nothing else — the tiering removes the *second* reader on intermediate rounds, never the only one.

## Model & effort steering — current state (2026-10-04/05)

Formalizing what the measurements above actually settled, so it doesn't stay scattered across commits:

| Role | Model | Effort | Why | Confidence |
|---|---|---|---|---|
| Main/captain (your own session) | Opus for most work; Fable for one deep, continuous, hard thread; Sonnet for routine work | session default | Fable is 2.5x Opus per token — reserve it for sustained hard reasoning in a SINGLE context. Avoid using it to fan out across many project contexts at once: each pays its own fresh floor regardless of model, so that step should run the cheapest model ADEQUATE for the judgment that step actually needs — not automatically the cheapest available, and not the priciest by default either (reported from a 2026-10-04 transcript audit on one machine, not yet written to a durable record: 5 projects' first calls within 50s on 2026-09-28, ~1.83M fresh tokens, ~97% of that day's Fable cost) | reported, not independently re-checked — see caveat |
| `reviewer` subagent | Sonnet | **high** | ~4% of measured Claude spend; under-thinking here costs missed blockers; base cost too small to justify going cheaper | deliberate, cost floor measured, review *quality* not A/B'd |
| `summarizer` subagent | Sonnet | session default | proven since the original 4-way test (2026-09-18). Haiku matched it once on a real task — comparable density, fewer tokens, half the price — not yet switched; needs a second confirming run | n=1, promising |
| Explore / Plan / general-purpose — judgment-heavy | inherit parent | — | architecture tradeoffs, ambiguous debugging — state why when letting it inherit | deliberate default-to-override |
| Explore / Plan / general-purpose — moderate research/search | **Sonnet** | — | the main fix: 76% of all subagent calls were silently riding an Opus/Fable parent for work that didn't need it | measured, fixed 2026-10-04 |
| Explore / Plan / general-purpose — pure digest/extraction, no judgment | **Haiku** | — | matched the sonnet subagent's output density once, fewer tokens, half the price | n=1, promising |
| `fork` | n/a — shares parent's cache; **default to inheriting, don't override** | n/a | a fork can reuse the parent's warm, MATCHING prefix, avoiding another cache write for that shared portion — it does NOT make new reasoning, new output, or the cache reads on top of that prefix free, and the reuse only holds while the prefix still matches (changing the model invalidates it, trading the cache saving for whatever that model swap was meant to buy). Override the model only when the task's judgment need is high enough to justify losing the cache — that's the exception, not the default | by design, scope corrected 2026-10-05 |
| Codex, reviews | `gpt-6.1-sol` | **high** | was `low` (a real misconfiguration — Codex, the primary reviewer by volume, was thinking less than its own Sonnet fallback; fixed). A/B'd once against `gpt-6-astra` on a real review task: same verdict, comparable depth, astra actually faster this run — no clear win, kept `sol` as the default rather than switch on an n=1 tie | fixed; model choice inconclusive, revisit if evidence accumulates |
| Codex, summarize/rehydrate | `gpt-6.1-sol` | `low` | effort doesn't help digesting a log — the model sets time and length, not the effort knob (2026-09-18 measurement) | established, for this task shape only |
| Codex, research memos | `gpt-6.1-sol` | judge per task | the 2026-09-18 measurement only tested log-digesting; a research memo makes tradeoff judgments and recommendations, a different task shape — not covered by that result | unmeasured, don't extend the low-effort finding here |
| Gemini | eligible by default, off as a peer by default, never as a reviewer on **this machine** | — | the template still ships Gemini as Codex's configurable fallback (`megavibe reviewers set all` restores it everywhere) — this row records a personal `MEGAVIBE_REVIEWERS=reviewer codex` pin on this one machine, not a protocol change. Every other section of this file and of `CLAUDE.md` describing Gemini as Codex's fallback is still the shipped default for every other user | personal setting, scope-corrected 2026-10-05 — do not read as "removed from megavibe" |

What this table is *not*: a result of finding one mega-pattern in aggregate error rates (there wasn't one — tool-call error rates sit flat at 1-4% across every model/effort combo, most likely task-difficulty confound rather than model quality signal). It's task-shape-based reasoning plus the handful of things that WERE directly measurable (the Haiku test, the Codex misconfiguration, the Codex A/B) — formalized so the next session doesn't have to re-derive it. Two reported findings — the Main/captain row's incident citation above, and the "## Cache heartbeat" section further down — come from one machine's transcript audit and haven't been written to a durable record or independently reproduced. Treat those two as leads, not settled fact, until they are.

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

**It gates the reviewer ROLE, not the backend.** `gemini-review.sh` and `codex-review.sh` are also the general Codex/Gemini transport — steps 1 and 3 of the fallback chain above, and what `/rehydrate` and `/prune-context` call — so they consult the allow-list **only when the caller passes `--as-reviewer`**. Pass that flag for the reviews of non-negotiable 4 and for nothing else: switching a reviewer off must not cost anyone context recovery. (Separately, and not through `MEGAVIBE_REVIEWERS`: `gemini-review.sh` without `--as-reviewer` is the rationed no-Codex alternative described at the top, and refuses on a machine where Codex is usable.) Getting this backwards is the bug the first cut shipped — `MEGAVIBE_REVIEWERS="reviewer"` silently stripped `/rehydrate` of both external backends.

Allow-list rather than ignore-list on purpose: the config states exactly what runs, where an ignore-list only says it relative to whatever happens to be installed on the machine. The cost is that a reviewer added to megavibe later is off for anyone who has pinned a list.

**Every unclear path resolves to MORE review.** A settings file that exists but cannot be parsed — bad JSON, no `jq` — is ambiguous rather than absent, and returns all three. An unrecognised name invalidates the whole pin rather than being dropped from it, because `"gemini codx"` would otherwise switch codex off forever on a typo. A committed project `settings.json` is compared against what the machine would resolve WITHOUT it and ignored if it removes anything, which is why `auto` in a cloned repo cannot quietly take Gemini away from a user whose own file says `all`. The availability probe is bounded and, on a timeout, counts as unknown and returns all three. In the review scripts, exit status **1** from `reviewers.sh` is the only answer that switches a reviewer off; every other status is the helper failing to answer, and the review runs.

Enforcement is in the scripts, not only here — under `--as-reviewer` they exit **4** with a `skip:` line when their reviewer is not in the set, before spending a token. Exit 4 means *switched off*, not *failed*: do not fall through the chain looking for a substitute, and do not report the review as degraded by a backend outage. Every unclear path fails OPEN to all reviewers — unreadable config, missing `jq`, an unrecognised value, a helper that crashes — because reviewing with fewer eyes than the user expects is the bad direction to fail in. A round that ends up with only the `reviewer` subagent is still a review; say so plainly in the synthesis.

**Never override the Gemini model to a Pro variant** (`-m gemini-*-pro*`, `model: gemini-*-pro*`) in the MCP tool, the CLI, or the watcher. Pro has no free tier and bills at 3-16x flash on a paid key. The sanctioned use is `gemini-review.sh --pro` for **any reviewer-role call** — flash truncates or stalls on 3.x thinking specifically for reviews, not just the protocol/template/user-facing subset, matching CLAUDE.md non-negotiable 4's "always `--pro`" for reviews (≈$0.15 a review); everything else — non-review Gemini usage — is pinned by the script to a flash-lite model (`MEGAVIBE_GEMINI_DIGEST_MODEL`, a caller's `--model` is ignored), and if that is not enough there, fall through the chain to the Claude subagent. The `ask-gemini` MCP tool bypasses the cost rails entirely: short interactive questions only. *(Found 2026-10-05: this line previously scoped "sanctioned" too narrowly, contradicting the Tool routing table and non-negotiable 4, both of which already required `--pro` on every reviewer-role Gemini call, review-tier or not — pre-existing, not introduced by the change in this diff.)*

## Cache heartbeat: measured, verdict genuinely unresolved (2026-10-04/05)

Proposed once: ping an idle session every ~50 min (under the 1h ephemeral cache TTL) for up to 12-24h to avoid a cold-cache rebuild. Mechanism is confirmed accurate: every request that touches a cached prefix bills `cache_read_input_tokens` for the FULL prefix length, every time; there is no cheaper standalone way to extend a cache entry's TTL. Of 207 cold-restart events since Sep 1, 177 fall inside a 24h window, totaling 75.9M tokens to rebuild from scratch at resume (raw `cache_creation_input_tokens`). Pinging all 177 every 50 min for the length of each gap, then resuming warm, costs 498.7M raw tokens moved — **6.57x more tokens than doing nothing.**

**What that 6.57x does NOT settle: whether raw token count is the metric that matters.** Anthropic's own published API pricing weights a cache read at roughly 0.1x base input price and a 1-hour cache write at roughly 2x — a 20x asymmetry in the OPPOSITE direction from the raw-token count, because reads are cheap to serve on the backend and writes aren't. If Claude Code's subscription usage/rate limits are cost-weighted the way the dollar pricing is rather than a flat sum of tokens-moved, heartbeating could be net CHEAPER against the real limit, not 6.57x more expensive — a complete reversal. Anthropic's actual plan-metering formula isn't publicly documented, and nothing here verifies which model applies. **Verdict: don't build persistent heartbeat infrastructure on either conclusion yet.** Before deciding either way: run matched trials — several heartbeat-then-resume cycles AND several cold-resume cycles on comparable work, controlling for other activity in the window — and compare what each does to Claude Code's own usage/rate-limit display specifically (not the API response's token counts, and re-fetch it fresh rather than trusting a cached reading — `/usage` can show a stale one). A couple of pings alone only measures the ping's own cost, not whether it actually beat the cold-resume alternative; this section should be rewritten once a real matched comparison exists.

## Tool routing

**Gemini in the Fallback columns below applies only on a machine without Codex** (`reviewers.sh digest-chain`), within the daily caps; on a Codex machine skip to the next column. The one exception is the Gemini-primary image rows, which use the multimodal path rather than `gemini-review.sh`.

| Need | Primary | Fallback 1 | Fallback 2 | Output format |
|------|---------|-----------|-----------|---------------|
| Large context (long logs, many files, PDFs) | Codex | Claude subagent | Gemini | Key claims, evidence anchors, risks, unknowns |
| Re-hydrate working context | Codex `--effort low` | Claude subagent | Gemini | `.agent/sessions/{sid}/WORKING_CONTEXT.md` (max ~400 lines) |
| Summarize text (any length/target) | Codex `--effort low` | Claude subagent | Gemini | Structured summary at specified target length |
| Accessibility-grade image description | Gemini | Codex | Claude subagent | Literal, high-recall, structured markdown |
| Research memo (multi-source, citations) | Codex (`--search` when freshness matters) | Gemini | Claude subagent | `.agent/RESEARCH/YYYY-MM-DD_topic.md` |
| **Review, normal round** (non-negotiable 4) | Codex `codex-review.sh --as-reviewer`, when switched on AND available | `reviewer` subagent — whenever Codex is switched off, absent, OR its call failed | `gemini-review.sh --as-reviewer --fallback --pro` may JOIN the subagent when Codex failed today; it never takes the round alone | Ranked findings with file:line, failing input, outcome, fix |
| **Review, ship round** (critical work included; its intermediate rounds are normal rounds) | EVERY reviewer both switched on and available, in parallel — `reviewer` subagent (Sonnet, high effort; `general-purpose`+sonnet with the agent's text if not yet registered), Codex, and Gemini when pinned as a peer | whichever of them are available | Gemini `--fallback --pro` stands in for a Codex that FAILED (a Codex switched off is not a failure) | Same, plus a ship / do-not-ship verdict |
| Fast second opinion / alternative plan | Codex | Claude subagent | Gemini | Patch plan + test plan |
| Quick fact check / web search | Codex | Gemini | Claude subagent | Claims with sources |
| JS-heavy site, auth flow, DOM extraction | Playwright | — | — | Screenshots/HTML → `.agent/ASSETS/` |
| Interpret screenshots or UI captures | Gemini | Codex | Claude subagent | Structured description |
| Automatic .agent/ context augmentation | poma-memory (via Grep/Glob hook) | poma-memory MCP | — | Injected as systemMessage on every Grep/Glob |
| Tidy a long event log | `agent-log.sh fold` (no backend) | — | — | See "Context compaction" below |

## Gemini / Codex / Claude subagent delegation protocols

These protocols apply to whichever backend is available. Codex is the primary — `~/.megavibe/scripts/codex-review.sh` — then the Claude subagent via the Agent tool with `.claude/agents/summarizer.md`, then Gemini via `~/.megavibe/scripts/gemini-review.sh` (on a machine WITHOUT Codex, Gemini comes before the subagent) (its MCP tool only for short questions). The inputs and output requirements are the same whichever one answers.

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

### Context compaction (superseded: fold, not AI line removal)

`.agent/FULL_CONTEXT.md` is RENDERED from `.agent/snapshot.md` plus the write-once events in `.agent/events/`; it is never edited in place and needs no AI pruning. When `.agent/events/` has accumulated a lot of old entries, run `.claude/hooks/agent-log.sh fold`: it moves events older than 30 days into the snapshot (`--before YYYY-MM-DD` to choose the cutoff), no content is lost, and `FULL_CONTEXT.md` renders identically before and after. Re-hydration reads a bounded slice of it (`/rehydrate`), so the size of the rendered file is not a problem in itself. The old procedure (send the file to a backend, delete the lines it names, append a compaction note) is retired for exactly that reason; `/prune-context` is kept only for old projects that still hand-append to `FULL_CONTEXT.md`.

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

If Codex is unavailable, fall back to Gemini (`gemini-review.sh`) → Claude subagent — but only on a machine WITHOUT Codex: where Codex is installed and merely failed that day, Gemini's general path refuses (exit 4), so go straight to the subagent. Research is the one job where Gemini stays ahead of the subagent: neither can search the live web, and Gemini brings the larger window. Neither replaces Codex's `--search`, so say in the memo that the sources are recalled rather than fetched.

## Claude subagent protocols

The `summarizer` subagent (`.claude/agents/summarizer.md`, model: sonnet) is the SECOND link in the chain on a machine with Codex (between Codex and Gemini), and the LAST on a machine without it (after capped Gemini) — `reviewers.sh digest-chain` says which. It runs on the same Claude subscription — no API key needed, always available.

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
