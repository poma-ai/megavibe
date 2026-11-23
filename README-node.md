# The node (opt-in, macOS)

A node keeps a Mac reachable for other Claude sessions and keeps the Personal Assistant (PA) alive there. Nothing of this exists until you run `megavibe node install`; a megavibe user with one Mac and no PA never sees it.

## What runs

| Piece | Where | What it does |
|---|---|---|
| LaunchAgent `com.megavibe.node` | `~/Library/LaunchAgents/com.megavibe.node.plist` | Runs `node.sh` at login and every 300 s, only in a logged-in GUI session (`Aqua`). |
| `node.sh` | `~/.megavibe/node/` | Keeps a node session in tmux session `main` (`TMUX_SESSION`), in a window named after the Mac's `LocalHostName`; the Claude session inside it is named `NODE-<host>` (model `sonnet`). Where `pa.on` exists, starts the PA in tmux session `megavibe-personal`. Syncs the PA's memory repo. Types a warning into the node window once a day when the Claude login expires within 168 h, has expired, or is logged out. It starts things; it never stops or kills anything. |
| `pa-start.sh` | `~/.megavibe/node/` | The one PA launcher: `megavibe --name "Personal Assistant"` in `~/.megavibe/personal`. A first start chooses the session id, records it in `pa.session`, and makes the PA run `/rehydrate` and read its `megavibe-deliverables/`; every later start resumes that conversation under the same name (see "When the PA or a session dies"). `megavibe assistant` uses the same launcher (the installed copy, else the template; without a node folder every start is fresh). |
| `CLAUDE.md` | `~/.megavibe/node/` | The node session's role: takes no work, relays to the PA, never runs setup for another session. |
| `node.conf` | `~/.megavibe/node/` | Settings, `KEY=value`, read by the scripts and never sourced; a value that fails its pattern is logged to `node.log` and replaced by the default. |

Settings and defaults: `NODE_MODEL=sonnet`, `PA_MODEL=` (empty: Claude's own default; set `opus` to pin the PA), `TMUX_SESSION=main`, `NODE_PREFIX=NODE-`, `COMMIT_NAME=megavibe node`, `COMMIT_EMAIL=megavibe-node@localhost` (the memory repo's automatic commits).

Switch files in `~/.megavibe/node/` (set them with the commands, not by hand):

| File | Command | Meaning |
|---|---|---|
| `node.off` | `megavibe node off` / `on` | The node starts nothing. Running sessions are not stopped. |
| `pa.on` | `megavibe node pa on` / `off` | Keep the PA running on this Mac. |
| `memory.push` | `megavibe node memory push` | This Mac writes the memory repo: commit what changed, push. |
| `memory.pull` | `megavibe node memory pull` | This Mac keeps a standby copy: fetch and fast-forward only, never while a PA runs or is set to run here. |

`megavibe node status` shows all of it, plus whether the installed scripts differ from the template (re-run `install` after an update to refresh them; `node.conf` and the switches are kept).

## When the PA or a session dies

Everything here lives in tmux, so one dead tmux server takes the PA, the node and every repo session with it. The node's LaunchAgent brings the node back within five minutes; the rest is this section.

**The PA comes back as itself.** With `pa.on` set, the node starts the PA when tmux session `megavibe-personal` is gone, through `pa-start.sh`, which resumes the conversation recorded in `~/.megavibe/node/pa.session` (`megavibe --resume <id>`): context and session-scoped schedules return, and the first prompt tells the PA to check its schedules and run `megavibe node session check`. The session name is always `Personal Assistant`, fresh or resumed, so sessions that report to it by name keep reaching it. `megavibe node pa session` shows the recorded conversation, `megavibe node pa session <id>` records one (for a PA that was started another way, or after `/clear`, which begins a conversation the file does not know), `megavibe node pa session none` makes the next start fresh. The file is per Mac and not part of the memory repo: a standby that takes over starts fresh from the notes, `handback` forgets the conversation recorded on the Mac that hands back, and so does a `takeover` on a Mac that was a standby or that pulls in newer notes.

Two gotchas:
- A resume that ends within 30 s counts as "that conversation is gone": the id is added to `pa.session.failed` and a fresh PA starts in its place. A PA you end within 30 s of a resume is replaced by a fresh one too.
- No second PA: where the wrapper's session lock in the personal folder names a live Claude process (a PA resumed by hand in another terminal), neither the node nor `megavibe assistant` starts another; `node.log` says so. That check needs `jq`, and applies only where the node folder exists (without a node, `megavibe assistant` handles a live lock as it always did).

**Repo sessions are registered, and a vanished one is reported.** Start them through the register instead of a bare `tmux new-window`:

```
megavibe node session start NAME --dir DIR --task FILE [--model M] [--window W] [--prompt TEXT]
megavibe node session check        # exit 0 all present, 1 some vanished (listed), 2 could not say
megavibe node session resume NAME  # a vanished one: its conversation again; --fresh: a new one from the task file
megavibe node session done NAME    # it reported; drop NAME forgets it; list shows all
megavibe node session add NAME --window TARGET --task FILE [--dir DIR] [--sid ID]   # one that already runs
```

`start` (and `resume`) passes `MEGAVIBE_PARENT_SESSION` set to the `CLAUDE_CODE_SESSION_ID` of the session that runs the command (empty when there is none), so `megavibe sessions` links the registered session to its starter and reports it as an orphan if that session ends (README "Launch records"). It opens a window in the node's tmux session running `megavibe --no-normalize --name NAME --session-id <new id> "<prompt>"` in `DIR` (exactly there: a conversation is bound to its folder, so give the repo or worktree root; names are lower case) (default prompt: read the task file, carry it out, report to the session named `Personal Assistant`), and writes `~/.megavibe/node/sessions/NAME` (state, window, folder, task file, started, conversation id). Liveness is a tmux user option on the window (`@mv_session`): it goes when the window goes, cannot survive a server restart, and survives a rename. `check` lists every session still registered as running whose window is gone, with its task file and the resume command, on every run until it is resumed, marked `done` or dropped; run it from the PA's recurring tick. A failed tmux listing is "unknown" (exit 2), never "all vanished"; tmux saying that no server runs (or that its socket is missing or refuses) is the one failure that counts as gone, and even then a session whose recorded process (pid and start time) is still alive is listed as `UNSEEN` (exit 2 when nothing vanished) and is not resumed: a tmux socket file cleaned out of `/tmp` under a live server looks exactly like a dead server. `resume` uses `megavibe --resume <id>`; if that window closes at once the conversation no longer exists, and `--fresh` starts a new one with a brief to reconstruct the state from the task file and the repo.

Give each session its own folder (a worktree): the wrapper asks an interactive question when another session holds the folder's lock, and a detached window cannot answer it. A session started with a chosen id gets no model from the usage router; pass `--model`.

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

- Liveness is "the tmux window exists", for the node, the PA and registered sessions alike: a hung session keeps its window and is neither restarted nor reported. A session registered with `session add` that runs from a shell prompt leaves its window open when it ends.
- `/clear` inside the PA begins a conversation `pa.session` does not know; until it is recorded (`megavibe node pa session <id>`) a restart resumes the conversation from before the `/clear`.
- With a session id chosen by `pa-start.sh`, an unset `PA_MODEL` means Claude's own default model, not the usage router's choice.
- The login warning is typed into the node window; if the session is not at its prompt, that day's line is lost or mangled.
- The pull checks for a running PA at the start of the run; a PA started by another route in the seconds before the merge is not seen (`takeover` avoids this for its own start).
- Each helper runs under a deadline that ends the helper, not its children.
- At most 3 starts per window per hour; after that it logs once and waits.
- The secret scan runs once, before the first commit; the node's later automatic commits are not scanned, so keep secrets out of the PA's folder (the allow-list `.gitignore` is the main guard).
- Two Macs that both hold `memory.push` at the same time diverge; nothing merges automatically.

Tests: `tests/node.test.sh` (stubbed tmux, scutil, launchctl and login check; real git on scratch repos) and `tests/node-sessions.test.sh` (the session register against a real tmux on a private `-L` server, never the live one).

**Codex usage probe.** While `pa.on` is set, each run also calls `usage-probe.sh run --every 30` (one tiny Codex call at most every 30 minutes, skipped when a Codex reading under 15 minutes old exists) so the usage forecast has fresh Codex readings (README "Recent-pace forecast"). Without `pa.on` the node makes no such call.
