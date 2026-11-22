# The node (opt-in, macOS)

A node keeps a Mac reachable for other Claude sessions and keeps the Personal Assistant (PA) alive there. Nothing of this exists until you run `megavibe node install`; a megavibe user with one Mac and no PA never sees it.

## What runs

| Piece | Where | What it does |
|---|---|---|
| LaunchAgent `com.megavibe.node` | `~/Library/LaunchAgents/com.megavibe.node.plist` | Runs `node.sh` at login and every 300 s, only in a logged-in GUI session (`Aqua`). |
| `node.sh` | `~/.megavibe/node/` | Keeps a node session in tmux session `main` (`TMUX_SESSION`), in a window named after the Mac's `LocalHostName`; the Claude session inside it is named `NODE-<host>` (model `sonnet`). Where `pa.on` exists, starts the PA in tmux session `megavibe-personal`. Syncs the PA's memory repo. Types a warning into the node window once a day when the Claude login expires within 168 h, has expired, or is logged out. It starts things; it never stops or kills anything. |
| `pa-start.sh` | `~/.megavibe/node/` | The one PA launcher: `megavibe --name "Personal Assistant"` in `~/.megavibe/personal`, with a first prompt that makes the PA run `/rehydrate` and read its `megavibe-deliverables/`. `megavibe assistant` uses the same launcher (the installed copy, else the template). |
| `CLAUDE.md` | `~/.megavibe/node/` | The node session's role: takes no work, relays to the PA, never runs setup for another session. |
| `node.conf` | `~/.megavibe/node/` | Settings, `KEY=value`, read by the scripts and never sourced; a value that fails its pattern is logged to `node.log` and replaced by the default. |

Settings and defaults: `NODE_MODEL=sonnet`, `PA_MODEL=` (empty: megavibe's own choice; set `opus` to pin the PA), `TMUX_SESSION=main`, `NODE_PREFIX=NODE-`, `COMMIT_NAME=megavibe node`, `COMMIT_EMAIL=megavibe-node@localhost` (the memory repo's automatic commits).

Switch files in `~/.megavibe/node/` (set them with the commands, not by hand):

| File | Command | Meaning |
|---|---|---|
| `node.off` | `megavibe node off` / `on` | The node starts nothing. Running sessions are not stopped. |
| `pa.on` | `megavibe node pa on` / `off` | Keep the PA running on this Mac. |
| `memory.push` | `megavibe node memory push` | This Mac writes the memory repo: commit what changed, push. |
| `memory.pull` | `megavibe node memory pull` | This Mac keeps a standby copy: fetch and fast-forward only, never while a PA runs or is set to run here. |

`megavibe node status` shows all of it, plus whether the installed scripts differ from the template (re-run `install` after an update to refresh them; `node.conf` and the switches are kept).

## Install

```
megavibe node install [--pa] [--memory push|pull|none]
```

It writes the node folder and the plist and prints the line(s) that load the agent. **megavibe does not run `launchctl` for you.** `block-dangerous-bash.sh` refuses, from a Claude session, a `launchctl` (or `osascript`, `crontab`) command that names `~/.megavibe`, because such a command starts a process outside Claude Code's process tree, and a megavibe script that ran it would be a way around that guard. So you type it, in Terminal:

```
launchctl bootstrap gui/<uid> ~/Library/LaunchAgents/com.megavibe.node.plist
```

When the agent is already loaded and the plist did not change, nothing needs loading: the next run uses the refreshed `node.sh`. When the plist changed, `install` prints a `bootout` line first. To remove the node: `launchctl bootout gui/<uid>/com.megavibe.node`, then delete the plist and the folder.

Requires tmux, perl, and the `megavibe` and `claude` commands on the PATH that `node.sh` sets (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, system paths): a LaunchAgent does not see a shell profile, so a `claude` that lives only under nvm or a custom npm prefix needs a symlink in `~/.local/bin`. `megavibe assistant` keeps the PATH of the shell it runs in.

## Two Macs: the PA's memory

The PA's notes (`~/.megavibe/personal`, its `.agent/` events and registers, `megavibe-deliverables/`) can live in a git repo whose origin is a bare repo on the writing Mac. A standby Mac holds a copy its node keeps current, so the PA can be started there when the writer is down.

On the writing Mac:

```
megavibe node memory init [--origin PATH]
```

Creates the repo with an allow-list `.gitignore` (template `template/node/memory.gitignore`: `.agent/`, `megavibe-deliverables/`, `CLAUDE.md`, `tools/`, `tick.conf`; logs, per-session state, rendered views and indexes stay out; an existing `.gitignore` without an exact `/*` line is kept as `.gitignore.prev` and its rules are appended after the allow-list, so what it excluded stays excluded, except megavibe's own `megavibe-deliverables` rule), scans every file the first commit would hold for secret-shaped text (private keys, cloud, GitHub and Slack tokens, `sk-` keys, `ACCESS_TOKEN=`/`api_key:`/`"refresh_token":`-style assignments in any case; prints `file:line` only, commits nothing on a hit), commits, creates the bare origin (default `~/.megavibe/personal-memory.git`), pushes, and sets `memory push`. It prints the URL for the standby.

On the standby Mac (ssh from it to the writer must work without a password prompt; the node uses `BatchMode`):

```
megavibe node memory clone <host>:<path to the bare repo>
```

Refused while `pa.on` is set or a PA runs here. Steps: `git init`, add the origin, fetch, `reset` the index to the origin's default branch (files untouched), report where this Mac's files differ, copy every differing file to `~/.megavibe/node/memory-backup-<time>/`, check out, set the upstream, set `memory pull`. Files only this Mac has stay where they are.

### Takeover and handback

Run these yourself on the Mac concerned. A node session asked by another session to do them names the command and does not run it.

`megavibe node takeover` makes this Mac the active PA: it removes `memory.pull` **first** (so no node run can pull underneath the PA), takes the node's lock, fast-forwards the repo from origin (an unreachable origin, the usual case when the writer is down, starts from the local copy and says so; a diverged history stops with nothing started), sets `memory push` and `pa.on`, and starts the PA.

`megavibe node handback` stops being the active PA. It never stops the PA itself: it removes `pa.on` (so the node will not restart it); while the PA still runs it exits and asks you to end that session (`tmux attach -t megavibe-personal`, then `/exit`); then it commits, pushes, checks origin holds the last commit, and sets `memory pull`. A failed push keeps `memory push`, so the node keeps trying.

Moving the PA while both Macs are up: run `megavibe node handback` on the Mac that has it first (it pushes and turns that Mac into a standby), then `megavibe node takeover` on the other. A takeover cannot tell whether the other Mac's PA is still running.

Returning to the writer: when the writer boots, its node restarts its PA (`pa.on`). For a clean return, first `megavibe node handback` on the standby, then on the writer `megavibe node takeover` (it fast-forwards to the standby's commits). If the writer's PA already committed before the handback, the histories have diverged and takeover stops; merge by hand in `~/.megavibe/personal` (events are write-once files, so conflicts are rare; the registers can conflict).

## Known limits (SHORTCUTs in the code)

- Liveness is "the tmux window exists": a hung session keeps its window and is not restarted.
- The login warning is typed into the node window; if the session is not at its prompt, that day's line is lost or mangled.
- The pull checks for a running PA at the start of the run; a PA started by another route in the seconds before the merge is not seen (`takeover` avoids this for its own start).
- Each helper runs under a deadline that ends the helper, not its children.
- At most 3 starts per window per hour; after that it logs once and waits.
- The secret scan runs once, before the first commit; the node's later automatic commits are not scanned, so keep secrets out of the PA's folder (the allow-list `.gitignore` is the main guard).
- Two Macs that both hold `memory.push` at the same time diverge; nothing merges automatically.

Tests: `tests/node.test.sh` (stubbed tmux, scutil, launchctl and login check; real git on scratch repos).

**Codex usage probe.** While `pa.on` is set, each run also calls `usage-probe.sh run --every 30` (one tiny Codex call at most every 30 minutes, skipped when a Codex reading under 15 minutes old exists) so the usage forecast has fresh Codex readings (README "Recent-pace forecast"). Without `pa.on` the node makes no such call.
