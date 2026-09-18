---
name: finish-feature
description: Close out a finished feature by measuring what it actually cost — turns, tool calls, tokens, and the real size of the diff — scoring that against what /init-feature predicted, posting it as a comment on the branch's PR, and asking whether to merge that PR. Use when the user types /finish-feature, or explicitly asks how much a finished piece of work cost, how many turns or tokens it took, or how the estimate held up. Do NOT use to summarize work that is still in progress.
allowed-tools: Read, Glob, Grep, Bash, Write, Edit, AskUserQuestion
argument-hint: "[base-ref, e.g. main]"
---

# Finish feature

The other half of `/init-feature`. That skill predicts; this one measures, and puts the two side by side. An estimate nobody scores never improves.

**Measure, never recall.** Every number below is in the transcript or in git. Do not report a token count, a turn count, or a diff size from memory or from a task notification — read it. A remembered number is the failure mode this skill exists to fix.

**If this session cannot take interactive input** — `claude -p`, a scheduled or unattended run, or `AskUserQuestion` is unavailable or errors — do Steps 1–4 and 6, and in Step 5 post nothing, open nothing and merge nothing. Say which actions were skipped and why. A prohibition with no stated alternative is where an agent improvises, and the thing it would improvise here is a merge.

## Step 1 — Measure the session

```sh
bash .claude/skills/finish-feature/session-cost.sh --base <ref>
```

`<ref>` is whatever came with the invocation, or `main` when nothing did — read it from the user's message rather than assuming `$ARGUMENTS` interpolates here.

`--base` is the ref the feature branched from; the diff is measured `base...HEAD`. Add `--json` to get the same figures as data, `--session <id>` for a session other than the newest, `--dir` for another project.

**Run this after the work is committed.** `base...HEAD` compares commits, so anything still in the working tree is absent from the diff and the feature reads as smaller than it was. The script counts uncommitted paths and says so; if it does, commit first and re-run rather than reporting the low number.

It reports **token numbers that are not interchangeable**, and quoting the wrong one is the usual way this analysis goes wrong:

| Number | What it is | Use it for |
|--------|-----------|-----------|
| **context total** | the per-window peaks summed | how much context the work really occupied. Only appears when the session compacted; compaction discards the window and starts over, so the pre-compact window is invisible to a single peak |
| **peak context** | the fullest single window | context pressure. A task notification's `subagent_tokens` is this figure, within about 4%. The statusline shows *current* usage, not this. |
| **generated** | output tokens | how much the model actually produced |
| **new material** | input + output + the cache creation that actually grew the window (a prefix-cache rebuild re-reports the whole window and is excluded) | **the figure to compare against an `/init-feature` estimate** |
| **processed** | + cache reads | total the API saw; it grows with turn count, not with work done, so it is the wrong yardstick for effort |

Subagents are counted separately because they run in their own windows. Their cost is real and belongs in the total; it is not this conversation's context.

**After a compaction, quote `context total`, not `peak context`.** Compaction discards the window, so the fullest-single-window figure silently omits everything before the last reset — a session that compacted twice reads as roughly a third of what it occupied. The script splits windows at the compaction marker Claude Code writes into the transcript (`isCompactSummary`); only in a transcript with no marker at all does it fall back to detecting where context collapses below 60% of the previous response. It first drops the zero-usage `<synthetic>` entries Claude Code writes for interrupts, API errors and an expired login, which otherwise read as a reset and invent a window that never existed.

**Counts are per API response, not per transcript line.** A reply with a thinking block and two tool calls is three JSONL lines carrying three identical copies of `message.usage`, so a naive sum inflates every token figure by 2–3x, and by a different factor in each session. The script deduplicates on `message.id` first. If you ever hand-check these numbers with your own `jq`, do the same or you will "find" an inflation that is not there.

## Step 2 — Bound what you are attributing

The transcript covers the **whole session**, not just this feature — and it may not even cover all of it. `/clear`, `--resume` and `/megavibe-restart` each start a new transcript file while compaction does not, so a feature that spanned a restart is measured from the last file only. The script counts the project's other transcripts and says so; when it does, say it in the report rather than presenting a half-measurement as the total. If the session also did unrelated work, say so and bound it — the `started`/`ended` timestamps and the human-turn count are the handles. An unqualified session total attributed to one feature is a wrong number with a right provenance.

## Step 3 — Find the prediction

Look for the brief `/init-feature` left:

```sh
ls .agent/PLANS/*-brief.md 2>/dev/null || true
grep -rl 'init-feature:' .agent/events/ 2>/dev/null | tail -5 || true
```

**Also look on GitHub.** `/init-feature` can post its summary and estimate as a comment on the ticket the work came from, and in a project without `.agent/` that comment is the *only* copy. Check the ticket named in the brief, or the one this branch's PR references:

```sh
gh issue view "<ref>" --comments 2>/dev/null | grep -A20 'init-feature' || true
```

No brief and no such comment means the feature was never scoped. Report the actuals, note that there is nothing to score against, and stop — do not reconstruct a prediction after the fact and then grade it. That is a number invented to be beaten.

## Step 4 — Score it

Two comparisons, both concrete:

- **Size.** Recompute the `/init-feature` ladder from what actually happened — real file count, real changed lines from the diff, whether the interface change materialised, how many unknowns turned out to exist. Report predicted size vs actual size.
- **Tokens.** Predicted range against measured **new material**, session and subagents shown separately. State the ratio plainly: inside the band, or over by how much.

Then, the part that carries the value: **name why**, with evidence. A ratio without a cause teaches nothing next time. The usual causes, in the order they actually bite:

1. Review rounds — each reviewer round is a full re-read of the standard plus the diff, and a second round doubles it
2. Rework — findings that required rewriting work already done
3. Exploration — more rounds than the bounded-explore budget assumed
4. Scope movement — the work delivered was not the work scoped
5. Unknowns that resolved badly

Point at the evidence for the cause you name: the tool-call count, the number of review rounds, the commits, the log entries.

## Step 5 — The pull request

The analysis is worth more on the PR than in a terminal nobody scrolls back to.

Gate the whole step on a real check, and skip it silently when the check fails — there is nothing to post to:

```sh
gh auth status >/dev/null 2>&1 && gh repo view --json nameWithOwner >/dev/null 2>&1 \
  && git symbolic-ref -q HEAD >/dev/null || echo "skip step 5"
```

This has to be its own command. `gh pr view` exits 1 when the branch has no PR, when the remote is not GitHub at all, **and** on a detached HEAD, so treating that one exit status as "no PR yet" makes the skill offer to open a PR it cannot create — `gh pr create` then fails with "you must be on a branch". `gh auth status` does not cover either case: auth is per-host, not per-repo. Then find what exists:

```sh
gh pr view --json number,state,isDraft,url,mergeable,mergeStateStatus,reviewDecision 2>/dev/null || echo "none"
```

Treat `none` as "no PR" only because the gate above already proved this is a GitHub repo — on its own that exit status also means a GitLab remote or a detached HEAD, and `gh auth status` passes in both since auth is per-host, not per-repo.

**No PR yet** → ask whether to open one. On yes, the body must carry the headings `enforce-pr-format.sh` requires, or the call is blocked: `## Summary` for a feature or change, `## Bug` **and** `## Fix` for a bug fix, both for something that is both. Level-2 headings exactly, and `--fill` is refused because a body built from commit messages cannot satisfy the shape.

```sh
 gh pr create --base <ref> --title "<what changed>" --body-file <path>
```

Pass the same `<ref>` Step 1 measured against. Without `--base` the PR opens against the repo's default branch — on a fork, the *upstream's* default — and the comment would then describe a different range of commits than the PR contains. Run it unindented: the leading space here is the `enforce-pr-format.sh` escape hatch that makes this documentation, and copying it skips the format check.

**A PR exists** → post the analysis as a comment on it, whatever its state. This is the post-hook: the cost measurement lands where the change is reviewed.

```sh
 gh pr comment <number> --body-file <path>
```

Write the comment from Step 4 — predicted versus actual size, predicted versus measured tokens, and the cause of the gap. Keep it to what a reviewer would want: the numbers and the one-line reason, not the full session narrative.

**If that PR is still open** → ask whether to merge it. Never merge without an explicit yes; it is outward-facing and it is other people's branch protection you would be spending. Check first, and **report instead of asking** in every one of these — the failure mode is offering a merge that should not have been offered, not declining one that was fine:

- **No review.** Merging is shipping, and non-negotiable 4 requires review before shipping. `reviewDecision` must be `APPROVED`, or this session must have actually run a review round on this change. Branch protection catches this only in repos that have it, which is not most repos, so check it here rather than trusting `BLOCKED` to appear.
- `isDraft` is true → say so. `state` is `OPEN` for a draft, and `gh pr merge` fails on one.
- `mergeable` is `CONFLICTING` → say so
- `mergeable` is `UNKNOWN` → GitHub computes mergeability asynchronously, so this is the normal answer right after a push. Re-poll once, then report if it is still unknown. Never offer a merge on an unknown.
- `mergeStateStatus` is `BLOCKED`, `BEHIND` or `UNSTABLE` → say which
- Pick the method the repo actually allows, preferring squash:
  ```sh
  gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed
  ```
  Name the method in the question so the user is agreeing to a specific action, then run it with **the method you found**, not the one in this example:
  ```sh
   gh pr merge <number> --<method>
  ```
  A repo with squash disabled and rebase enabled will reject a pasted `--squash`.

A closed or already-merged PR gets the comment and no question.

## Step 6 — Record it

Append a **new** event — never edit the estimate's entry, the log is append-only per non-negotiable 3:

```sh
printf 'finish-feature: <slug> — predicted <size>/<range>, actual <size>/<measured> new material (<n> turns, <n> tool calls, <n> subagent runs). Miss driven by <cause>. PR <url or none>, merged <yes|no|not asked>.' | .claude/hooks/agent-log.sh append
```

If the miss teaches something reusable — a coefficient that is wrong in this repo, a cost this project always incurs and the estimate never includes — add a line to `.agent/LESSONS.md`. If it was a one-off, do not: a lessons file full of noise stops being read.

Where there is no `.agent/`, report in the conversation and skip both writes. Never create `.agent/` to hold this.

## Rules

- Measured numbers only. If the script cannot produce one, say the number is unavailable rather than estimating it.
- Report the ratio and the cause together. Either alone is useless.
- This is an analysis, not a verdict on the work. An estimate that missed by 3x is information about the estimator, not a failure of the feature.
- Do not re-run reviews, re-verify the code, or reopen the work. The feature is finished; this measures it.
- Every `gh` action in Step 5 is outward-facing: other people see the issue comment, and a merge is theirs to live with. Ask, act on the answer, and never infer a yes from silence or from the work looking done.
