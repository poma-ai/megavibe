---
name: watch
description: Unattended watch ticks. Schedules ~/.megavibe/scripts/tick.sh as a recurring prompt (default every 30 min) that reports review requests, comments and PR pushes on the watched repos, Linear comments, the Claude login lifetime and both subscriptions' usage; the session acts on what needs an answer. `/watch off` stops it, `/watch status` shows it.
allowed-tools: Bash, Read, CronCreate, CronDelete, CronList
---

# /watch — unattended ticks

`/watch [interval] [org/repo ...]`, `/watch status`, `/watch off`.

One tick is `bash ~/.megavibe/scripts/tick.sh` (`megavibe tick` from a terminal): a deterministic report with no model calls, which you then act on. Configuration lives in `~/.megavibe/personal/tick.conf` (watched repos, people to mark, Linear on or off; see the script header), never in a project.

## Parse the input

- `off` → stop: `CronList`, delete every job whose prompt contains `tick.sh`, say so, stop.
- `status` → `CronList`; report the tick job(s) and run one tick now with `--no-mark` (a status check must not move the window). Stop.
- Otherwise: an optional leading interval token (`30m`, `45m`, `1h`) and any number of `org/repo` names. Default interval 30 minutes. Clamp to 10–50 minutes and say so when you clamped: under 10 minutes the GitHub calls are noise, and a tick inside the main thread's 1-hour prompt-cache lifetime reads the cached context instead of rewriting it. That cache effect is a side benefit of a tick that does real work (checking for review requests is time-sensitive); it is not a reason to tick on an idle session, which `delegation.md` ("Cache heartbeat") leaves an open question.

## Schedule

1. Before anything unattended: `bash ~/.megavibe/scripts/claude-auth-check.sh 12`. Exit 1 means the login will not outlast the window: tell the user now (`/login` at the laptop, or `claude setup-token` for a long-lived headless token) and still schedule.
2. If `CronList` already shows a `tick.sh` job, do not add a second; report it and run step 4.
3. `CronCreate` with `recurring: true`, the cron expression for the interval (`*/30 * * * *` for 30m; the Claude Code cron runs in this session and expires after 7 days), and this prompt, with REPOS replaced by the repo names or left empty when `tick.conf` carries them:

   > Run `bash ~/.megavibe/scripts/tick.sh REPOS` and act on the report. A review request or a comment addressed to you gets a real answer (a review ends in a recommendation; English on GitHub and trackers unless the project's rules say otherwise; never an `@`-mention without a needed action). A line starting with `! auth:` is relayed to the user at once, verbatim. The `usage:` line is context: lean optional work where it says, never drop the review floor. Then report in one or two lines; on a quiet tick say so in one line and nothing else.

4. Run one tick now (`bash ~/.megavibe/scripts/tick.sh REPOS`) and act on it as the prompt says.
5. Confirm in two lines: the cadence, the repos, the 7-day expiry, and that `/watch off` stops it.

## Rules

- The tick marks its own window (`~/.megavibe/tick/<name>.last`): never pass `--since` on a scheduled run, or items repeat.
- A failed `gh` or Linear call is reported inside the tick and is not retried by the tick; do not retry it in a loop either. Report it to the user when it persists for two ticks.
- Several projects watching the same repos get different `--name` values (`--name <project>`), or they share one window and each sees only part of the activity.
