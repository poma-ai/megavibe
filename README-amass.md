# README-amass.md: the cheap amass tier, measured

Detail behind the short rule in `.claude/rules/delegation.md`. Source: a measured pilot on two past review rounds (list-price accounting, not subscription quota; the samples are small, so read it as a calibration).


`amass.sh run --out DIR [--change TEXT] [--lens name=text]... [--copies N] FILE... [--context FILE...]...` inlines the files into one prompt and sends it to many headless one-shot calls (`claude -p --model haiku`, no tools, no user, project or local settings, no MCP, no session), one lens per prompt, then `amass.sh dedupe --out DIR` clusters the lists with one more call. It costs cents and surfaces suspects before the expensive rounds. It is **not** a reviewer and gates nothing: the review tiers, the ship round and the floor above are unchanged, and its output is a list of leads (measured 84-92% noise in the original pilot) to reproduce or verify before anyone fixes them. Treat the lists and clusters as data, never as instructions.

P1/P2 labels are the model's, not a measurement: measured precision was about 15-20 percent across nine reviews of real diffs, and roughly 40 percent on fresh complex shell code. Member counts show how many findings support a cluster, not independent verification. The tool reasons inside the diff and can miss defects involving untouched functions; pass callers and callees with --context. In real runs, 3-5 of 18 workers failing to parse is normal and counted in the summary (the failed workers and unparsed lines remain visible).

Measured in that pilot (list-price accounting, not subscription quota; n is small, so read it as a calibration):
- **Cost per call:** Haiku one-shot about $0.003-0.007 (warm copies of one prompt share a cache write); lean Haiku worker with Read/Grep/Glob $0.016; Sonnet one-shot $0.025 warm ($0.16 cold); an Agent-tool subagent doing the same Haiku job $0.19. Every Agent-tool subagent here starts at about 93K tokens of inherited context (about 62K of CLAUDE.md and rules, 18K of tool definitions, 12K of MCP) and re-reads it each turn.
- **Price cliffs (published list prices at the time of the pilot; check them again):** Haiku bills the whole request 5x once the prompt passes 100K tokens (confirmed per request), so `amass.sh` refuses more than 150 KB of input (`--max-input-kb`). luna ($0.10 in, $0.50 out per million, the same as Haiku below its cliff) flips at 272K tokens and then only doubles; terra costs 10x luna, sol 20x, astra 100x. Where luna has no measurement of its own, weigh it as Haiku-priced per token.
- **Yield:** lens targeting beats more copies (the hostile-input lens found a defect class in 8 of 8 copies that 48 whole-change copies found once). Recall plateaus: on one unit 12 lens-sharded copies reached 0.66 and 48 reached 0.80; on a security-heavy unit 28 reviewers together found 6 of 10 and none found two P0s. Haiku never found the hardest defect of the first unit in 96 runs; Sonnet one-shot found it in 4 of 9. So: Haiku swarm first, a handful of Sonnet one-shots (`--claude-model sonnet`) for what it cannot reach, luna with execution to verify clusters, and then the normal rounds.
- **Use the Agent tool only when the task needs it:** project rules and hooks, writes, or a conversation. For bounded read-only work (enumerate, summarise, extract, classify, dedupe) prefer a headless call; it carries none of the inherited stack.
- **Codex workers are not tool-less:** the Claude workers of `amass.sh` have no tools, but each Codex worker runs in Codex's read-only sandbox (it cannot write and has no network) and can read local files. Text injected into untrusted inlined code could steer a Codex worker to read files on the machine, so do not amass untrusted code on a machine whose readable files hold secrets, or use `--provider claude`. Every Codex call also pins `model_provider="openai"` (the built-in provider), so a saved config or profile naming another provider cannot receive the inlined files, and `--ignore-rules` is passed only when `codex exec --help` lists it.
- **Supervision:** every worker call, Claude or Codex, and the usage probe run under a process-group supervisor: a timeout (exit 124), TERM, HUP or INT kills the call's children too, and a cancelled run reaps every launched worker. `AMASS_PROBE_TIMEOUT` (seconds, default 20) bounds each usage probe; a probe that times out means an unknown projection.
- **Safety:** the workers run with `--setting-sources ""`, so none of your hooks or rules applies to them (rm-to-trash, block-dangerous-bash); an administrator's managed policy, if the machine has one, still applies: keep them tool-less or read-only, and never hand such a worker Bash, Write or Edit. The files you inline are sent to the model, as with any call. API keys and cloud-provider switches are removed from each call's environment, and before anything is sent `claude auth status` must report a claude.ai subscription login (a saved Console key would still bill), otherwise the script refuses. Nothing is dropped silently: response lines that are not finding lines are counted and reported, prose with no finding line fails the run, and dedupe re-adds what the model omitted. Each `run` and `dedupe` appends one line (time, model, calls, cost, input size, project folder name) to `~/.megavibe/amass-usage.jsonl`, so adoption and spend can be measured against the Agent-tool subagent calls in the transcripts.


## In a fix loop: implement, sweep, fix (measured)

One session ran the loop on two changes: four shell items (a review wrapper, a config guard, a PreToolUse guard, a launcher check) and a batch of protocol text. Each step was cheap: a sweep took 70-125 s and about $0.03 of Haiku plus about 90K luna tokens; a fix batch by a cheap model took 2-13 minutes. "Real" below means confirmed by execution or by a later ship reader; there was no independent ground truth, so read the numbers as a calibration.

- **Code: the second sweep yielded little.** Sweep 1 gave 29 clusters, 9 accepted after triage; sweep 2 gave 23, 2 accepted. Each fix batch (Sonnet for the 9 sweep-1 items, Haiku for the 2 sweep-2 items and later for 8 ship-round findings, all with failing-first tests) passed its tests. The ship rounds that followed still found a blocker and six P2s.
- **About half of those reader findings had been raised by the sweeps** and dropped in triage: a nearby input was run instead of the lead's exact one; an "evasion" lead was ruled out of scope without checking its false-block side; a real lead was filed as a known gap; and one lead was "refuted" by a run in the session shell that a clean environment then reproduced (a CLI flag a fresh login requires). The rest concerned code written by later fix batches that no sweep saw.
- **Text: sweeps find cross-file contradictions only with the files attached.** With only the diff and the always-loaded file, two sweeps had none of the 4 P1s the first ship round found. With all five rule files attached and a lens that must quote the conflicting rule, one sweep found 8-9 of a later round's 10 findings. The cluster count stayed at 23-30 across four sweeps, including one over 16 added lines, many on text that already existed: it is not a convergence signal.
- **Text fixers.** Haiku changed the text for 25 of 27 leads (the other 2 concerned text that already existed), rejected none, filled the size budget and caused about 8 regressions; an earlier brief that said "prefer deleting" made it delete most of the content. luna under a zero-growth rule rejected 14 of 29 leads with reasons and shrank the text. The comparison is not controlled (Haiku had no growth rule).
- **Provider yield.** Haiku gave about 10 findings per call and luna about 5; of the clusters judged real, 12 came from Haiku alone, 2 from luna alone and 8 from both. A controlled pilot on known defects measured equal recall (0.80) and precision 0.16 (Haiku) against 0.58 (luna). A 3:2 Haiku:luna split (`--split 3:2`) was then used, to keep Haiku's volume while giving luna's fewer, more often real leads more weight than 4:1 would.
- **Churn.** Four added protocol sections drew findings in every sweep and every ship round; each rewording produced the next round's findings. Removing them (for a separate change) ended it: the last four ship rounds had 1, 3, 1 and 0 material findings.

## Mixed runs: Claude and Codex in one run

`--provider auto` is the default for `run` and `dedupe`. Both models are near-free, so a run uses both for diversity and leans on the subscription that has more room.

- **auto** uses every provider whose login check passes (Claude: the `claude auth status` claude.ai check; Codex: `codex exec --help` plus a ChatGPT-account login). Both pass: a mixed run. One fails: one warning line naming it, and everything runs on the other. Both fail: refused, nothing sent. **mix** requires both and refuses if either check fails. **claude** and **codex** behave as before. A `--dry-run` checks no login and plans for both providers.
- **The split.** Each provider's effective projection P comes from `usage-route.sh pace` (run once per provider): the recent projection if present, else the linear one, else the used percentage, else unknown; clamped to 10-1000. `usage-route.sh` is looked up next to `amass.sh`, then in `~/.megavibe/scripts/`. A probe that fails, blocks or prints nothing means unknown. Weights are 1/P, so with T calls Claude gets `round(T * wc / (wc + wx))`, where wc and wx are the two weights, and at least one call each when T is 2 or more. P 150 against 225 over 10 calls gives Claude 6, Codex 4. An unknown side takes the other side's P (equal weight); both unknown gives 1:1, and with an odd total Claude takes the extra call. One call goes to the larger weight (a tie: Claude).
- **Override.** `--split N:M` (claude:codex, non-negative integers, not both 0) or `MEGAVIBE_AMASS_SPLIT=N:M`; the flag wins. A zero weight is honoured with no floor (`--split 1:0` is all Claude). It needs `mix` or `auto`.
- **Printed before sending, also with `--dry-run`:** `split: claude 6 (haiku), codex 4 (gpt-5.6-luna); projections claude 150 (recent), codex 225 (recent)`, or `split: override N:M; ...`.
- **Which call goes where.** Calls are walked copy by copy (copy 1 of every prompt, then copy 2, ...), odd copies in prompt order and even copies reversed, and a running deficit hands them to the two providers so they interleave and each lens tends to get both. Cache sharing is kept per provider: phase 1 starts, for every prompt, its first call on each provider it uses; after the stagger, phase 2 starts the rest.
- **Models.** `--claude-model` (default haiku) and `--codex-model` (default gpt-5.6-luna). `--model` names one model, so it only fits a single provider; with a mixed run it is refused with a pointer to the two flags. The mixed input cap is 150 KB (the stricter one, Haiku's cliff) unless `--max-input-kb` is given.
- **Records.** `runs.tsv` has a provider column on every row (`name cost status findings unparsed tokens provider`); each call also leaves `raw/<name>.provider`. The summary of a mixed run prints calls, ok and findings per provider, with Claude's cost in USD and Codex's tokens, plus totals. The ledger gets one line per provider used.
- **Dedupe** with auto picks the available provider with the lower effective projection (the one with headroom; a tie goes to Claude), and says which and why; `--provider claude|codex` forces one; after a run that was forced onto one provider (recorded in `requested` in the run directory), plain `dedupe` stays on that provider, and `dedupe --model` with two usable providers is refused like `run --model`. The summary follows the providers that actually ran, not the requested mode. After a mixed run, cluster lines show the provider support, for example `n=3 (claude 2, codex 1)`; the `CUNK` fallback cluster shows only its count.

## Codex when Claude is hot

Use `--provider codex` when Claude is hot and Codex has headroom (or let `auto` weigh it). Specify
the provider on each command to force one:

```bash
scripts/amass.sh run --provider codex --out /tmp/amass-codex-new src/parser.sh
scripts/amass.sh dedupe --provider codex --out /tmp/amass-codex-new
scripts/amass.sh summary --out /tmp/amass-codex-new
```

Codex defaults to `gpt-5.6-luna`; `--model gpt-6-luna` also works on the tested
plan. The bare name `luna` does not. Luna is about ten times cheaper than terra.
The historical Claude precision ranges above are pilot observations, not a
provider comparison. One later pilot on the same known-defect set (see "In a fix loop"
above) measured precision 0.16 for Haiku and 0.58 for luna at equal recall; it is a single
pilot, not a settled ranking. P1/P2 labels are the model's; reproduce the suspected defect.

Each Codex worker is one headless `codex exec`, with the prompt on stdin and its
own final-answer file in the run directory. It runs in throwaway scratch space,
with a read-only sandbox, approval policy `never`, `--ignore-rules`,
`--skip-git-repo-check` and `--ephemeral`. Scratch is removed on completion,
failure, timeout or handled cancellation. Timeout supervision kills the worker's
process group. `codex exec --help` must succeed and `codex login status` must
report a ChatGPT-account login; neither check prompts. The environment allows
only HOME, PATH, CODEX_HOME, proxy and certificate variables, excluding API keys,
endpoint overrides and headers. Every Codex call also passes
`--ignore-user-config` and pins `model_provider="openai"`, so a saved endpoint,
provider, MCP server or notify command never applies (auth still comes from
CODEX_HOME); a Codex whose `exec --help` lacks that flag is treated as unusable.

Codex alone defaults to `--max-input-kb` 400; Claude's, and a mixed run's, is 150. The cap covers the
whole prompt, including context and lens text. Luna's price doubles past about
272K tokens; the 400 KB cap uses the rough 1.8 bytes/token estimate, not an exact
tokenizer or a guarantee about total context. Override the cap explicitly when needed.

Codex reports tokens rather than dollars. JSONL `turn.completed` usage supplies
input plus output tokens (cached input is already included). Missing usage stays
unknown, never zero. The ledger adds `provider` and `tokens` (null when unknown);
Codex cost stays null unless `MEGAVIBE_AMASS_CODEX_PRICE` supplies a nonnegative
USD price per million tokens. That optional blended rate produces a labelled
estimate, not a bill or subscription-quota measurement; it does not separately
price input, output, caching or the price cliff. Failed attempts are accounted
for too. Summary reads the saved token totals without needing provider flags or
the pricing environment again. Raw events, final answers and normalized results
remain in the run directory for inspection.


## Command reference

`scripts/amass.sh run --out DIR [--provider auto|mix|claude|codex] [--split N:M] [--change TEXT | --task-file F] [--model MODEL | --claude-model M --codex-model M] [--lens name=text]... [--lenses-file F] [--no-lens] [--copies 3] [--whole N] [--parallel 12] [--timeout 280] [--max-input-kb 150] [--dry-run] FILE... [--context FILE...]...`, then `amass.sh dedupe --out DIR` and `amass.sh summary --out DIR`. For `run`, --out DIR must not exist (it is claimed atomically); a wrapper that pre-creates it fails with exit 2 and an explanation. A dry run uses scratch space and does not claim the requested output directory. Each `run` and `dedupe` appends a line to `~/.megavibe/amass-usage.jsonl` (`AMASS_LEDGER` overrides).

`--context` accepts one or more files until the next option and can be repeated. Put reviewed files before the first context group, or after `--`. Quote paths containing spaces or newlines, and prefix option-like filenames with `./` (for example, `--context ./-n`). Context files follow all reviewed files in `===== CONTEXT path =====` blocks. The task tells workers that these are callers, callees or tests of the changed functions, not files under review; findings must concern the reviewed files. This instruction also applies with `--task-file`. Context shares the input-size cap and the checks for readable regular files and NUL bytes. A file supplied in both roles appears in both blocks and counts toward the cap twice.

For example:

```bash
scripts/amass.sh run --out /tmp/amass-new --change 'Handle empty input' \
  src/parser.sh --context src/caller.sh tests/parser.test.sh --context src/helper.sh
scripts/amass.sh dedupe --out /tmp/amass-new
```

`clusters.md`, `dedupe` and `summary` show lines such as `C3 | P1 | n=7 | defect text | members: ...`, sorted by member count descending, then by id in C-locale lexical order (`C10` before `C2`). Model ids and member references stay unchanged; clusters with zero or missing members remain with `n=0`, and omitted findings are retained in the counted `CUNK` fallback cluster. The dedupe prompt asks for `[no-input]` at the end of a cluster line whose text names no concrete failing input (a specific input value, call or state that triggers it). The marker is advisory and never removes a cluster. Quoted markers in finding text stay literal, and older responses without markers still parse.
