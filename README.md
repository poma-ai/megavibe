# Megavibe

**Give Claude Code a memory that survives compaction, crashes and new sessions.**

Megavibe keeps decisions, mistakes, progress and context in files on disk, so a
fresh session can pick up where the last one stopped instead of re-deriving
everything from a lossy summary.

**Before you paste the install command**, know what it does to your machine — it
installs CLIs and MCP servers, and it launches Claude with permission prompts
disabled by default. See [Security and what gets installed](#security-and-what-gets-installed).

Requires a [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
subscription. macOS and Linux (Windows via Git Bash/WSL, less tested); the
context watcher needs `tmux`.

## Security and what gets installed

Megavibe is installed with `curl | bash` and then changes how Claude Code runs.
Stated plainly, because you should decide before pasting:

- **Permission prompts are disabled by default.** The `megavibe` wrapper launches
  Claude with `--dangerously-skip-permissions`, so the agent acts without asking.
  That is the point (unattended runs), and it is a real trade — run plain `claude`
  in a project if you want prompts back.
- **Commits get a co-author trailer** (`megavibe <megavibe@poma-ai.com>`) so
  agent-assisted commits are identifiable. Change it in
  `~/.claude/settings.json` under `attribution`, or clear it.
- **MCP servers are registered** user-wide: Gemini and Playwright if their CLIs
  are present, plus the bundled poma-memory semantic search. Codex is NOT an MCP
  server — codex-cli 0.154.0 removed its `mcp-server` subcommand, so megavibe
  calls it through `~/.megavibe/scripts/codex-review.sh` over `codex exec` and
  removes any dead registration left by an earlier setup.
  A Codex review runs with the project read-only and a throwaway scratch directory
  writable (no network), so it can run the harnesses a review needs; `--strict` or
  `MEGAVIBE_CODEX_SCRATCH=0` makes it fully read-only.
- **Hooks run on every tool call** in projects you initialise — they write context
  files under `.agent/` and never send anything off your machine on their own.
- **Backends see your content.** Delegating to Gemini or Codex sends the material
  to those providers. Whether they train on it depends on your account with
  them — for the Gemini API, only a key from a project **with billing attached**
  is a "Paid Service" (prompts not used for training); a Workspace login does
  not change that for the API, and the free tier trains on your prompts.

## Get Started

### 1. Open a terminal

- **macOS**: Press **Cmd + Space**, type **Terminal**, press **Enter**
- **Linux**: Open your terminal emulator
- **Windows**: Open **Git Bash** (from [git-scm.com](https://git-scm.com)) or **WSL**

### 2. Install Megavibe

Copy-paste this into Terminal and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/poma-ai/megavibe/main/install.sh | bash
```

The installer detects your OS and package manager (Homebrew, apt, dnf, pacman, winget, choco) and installs everything needed — Node.js, Python, jq, AI tools — then walks you through each step. Takes about 5 minutes.

Run unattended (stdin not a terminal, as in an agent's shell or a script), `install.sh` and `setup.sh` never wait for an answer: setup takes the automatic install and skips the Gemini key prompt, and both run `sudo` with `-n`, so a package install that would need a password fails at once with a hint instead of hanging (re-run from a terminal, or install that package yourself). The `curl | bash` installer sets `MEGAVIBE_TTY_PROMPT=1`, which lets setup's key and `sudo` prompts reach your terminal when its output is visible there.

### 3. Use it

Navigate to any project and run:

```bash
cd ~/my-project
megavibe
```

That's it. Claude now remembers everything you work on together. Run `megavibe` every time you start working — it's always safe to re-run.

Every session automatically has **Remote Control** enabled — you can connect from your phone via the Claude app at any time (see [Remote Access](#remote-access-optional) below).

---

## What Does It Actually Do?

### The problem

Claude Code forgets things. Every time it "compacts" (runs out of memory), it loses detail. After a few compactions, it forgets constraints, repeats mistakes, and loses track of decisions.

### The solution

Megavibe creates a **durable memory layer** that Claude writes to continuously and recovers from automatically:

```
your-project/
├── .agent/                          <- Claude's memory (survives everything)
│   ├── FULL_CONTEXT.md              <- everything that happened (append-only)
│   ├── DECISIONS.md                 <- why things were done a certain way
│   ├── TASKS.md                     <- what's done, what's pending
│   ├── LESSONS.md                   <- patterns from your corrections
│   └── sessions/{id}/
│       └── WORKING_CONTEXT.md       <- focused summary (~400 lines)
│
├── .claude/                         <- automation (hooks, rules, skills)
│   ├── hooks/                       <- auto-logging, safety, search
│   ├── rules/                       <- extended protocols
│   ├── skills/                      <- slash commands (/catchup, /rehydrate)
│   └── settings.json                <- hook configuration
│
└── CLAUDE.local.md                  <- your personal overrides (gitignored)
```

**How recovery works:**

1. An **out-of-band watcher daemon** reads the live transcript and writes summaries to `.agent/` files between turns — no in-session token tax, on by default. (Hook-based nudges are still there as a safety net when the watcher is off.)
2. When Claude's context gets compacted, a hook fires automatically
3. Claude calls Codex (or a built-in subagent, or Gemini) to read the full log and produce a focused summary
4. Claude reads the summary and continues — zero information loss, no human intervention

---

## Features

### Continuous out-of-band context flush (the watcher)

A background Python daemon (`~/.megavibe/scripts/context-watcher.py`) tails the live transcript JSONL and, on a 5-minute trickle, asks Codex (Gemini as fallback) to extract decisions, lessons, task changes, and a narrative recap — then writes them straight to `.agent/` files under `flock`. No in-session token cost, no prompts for Claude. Decisions are **staged** to a per-session queue for human review (low-stakes items auto-apply); review with `python3 ~/.megavibe/scripts/review-decisions.py`.

The watcher is on by default — set `MEGAVIBE_WATCHER=0` to opt out. When it's running, in-session tier nudges suppress automatically (no double-up). Full design and operations notes: **[README-watcher.md](README-watcher.md)**.

### Automatic context recovery

When Claude runs out of memory and compacts, megavibe detects it and triggers recovery. The hook writes the full orientation (git state, decisions, tasks, lessons, and the whole log when it is small) to `.agent/LOGS/rehydration-instructions.<session>.md` and gives Claude a short message pointing at it, because hook output over 10,000 characters reaches the model only as a 2,000-character preview. Then:

- **Normal case**: Claude runs `/rehydrate`, which calls Codex (or the subagent) to produce a focused ~400-line `WORKING_CONTEXT.md`
- **Working context written within the last hour**: Claude reads it and carries on; `/rehydrate` is optional
- **Empty context** (first compaction): instructs Claude to save the compaction summary before it's lost

**Ready to compact?** This check is advisory: run `.claude/hooks/compact-readiness.sh --session <session-id>` before `/compact`. Without `--session` it takes `$CLAUDE_CODE_SESSION_ID`, else the one tool-call counter touched in the last 24 hours (two is ambiguous and exits 2), so pass it whenever sessions share the project. Exit 0 means no findings in the observed state, 1 means `NOT READY` findings in the report, and 2 means unable to check (including missing `python3`). It never blocks a tool, Stop, or compaction. A body line starting with `DECISION:`, `D<number> `, `D<number>:` or `Decided:` asks for reconciliation of both `DECISIONS.md` and `TASKS.md`; backtick-fenced examples are ignored. Other decision-like prose is advisory. Three uncovered events also prompt task reconciliation (`MEGAVIBE_READY_TASKS_MIN_EVENTS`, default 3). Register mtimes and tool counters do not prove coverage.

After reviewing the events and reconciling both registers, run the same command with `--mark`. This records the observed event filenames in `.agent/.registers-checkpoint`: `covered-through <newest filename>` followed by covered filenames, one per line. Only membership establishes coverage; the header is descriptive. Same-second suffixes and late arrivals remain uncovered until marked. Marking records your assertion of review, then reports remaining findings: exit 1 can accompany a successful coverage write. It never certifies readiness or acknowledges pending rows. Legacy single-filename records are rejected, never migrated automatically. Reports create no files or locks; marking serializes coverage writes locally, while cloud replacement can still lose coverage. The existing coverage-aware `agent-log.sh fold` is retained: it refuses uncovered events, publishes the snapshot before removing events, and prunes identities at the snapshot's fold cutoff. Synchronize and review before folding; the report covers retained events, not history already in the snapshot.

Pending watcher rows are reported only as counts with their queue paths, regardless of timestamps or coverage records. No row IDs, receipts, handling markers, queue locks, or ownership migration are involved. Explicit full session IDs never select a sibling; exact short session directories remain exact. Unambiguous short aliases may resolve through session directories, background-state keys, or full queue/counter names. Ambiguous aliases or shared legacy queues report uncertainty (exit 2); the check never assigns their ownership or changes them.

Historical heartbeat nudges are advisory. Live running tasks without a heartbeat produce `NOT READY` findings only when supplied through `--hook-input <JSON_FILE>` (or `-` for stdin); otherwise coverage is unknown. The report uses the same task references and age interval as `watch-background.sh`. Working-context age and uncommitted work are informational. Finding and information previews are capped at 20 lines each; prose advisories default to 20 (`MEGAVIBE_READY_ADVISORY_LIMIT`, 0–1000), with 200 characters per detail line and omitted counts. Pre-compact alerts and tier 2/3 nudges carry advisory text (the alert capped at 6000 characters of text; a tier nudge at 2000 characters of its JSON-escaped form, so control characters count at their escaped length; each plus a truncation notice) and surface dependency failures.

**Register currency (optional).** If your `.agent/TASKS.md` opens with a "where we stand" section numbered 0, the pre-compact hook warns when that section's own date stamp is more than seven days old, and carries the warning into the message the session gets after the compaction. `MEGAVIBE_REGISTER_MAX_AGE_DAYS` changes the threshold.

It only reads a date the section *offers* as its stamp: bracketed in the heading — `## 0. Where we stand (2026-09-21)` — or a line beginning `As of 2026-09-21:`. Any other date is something the register talks about rather than when it was written, and reading "freeze was 2026-08-01" as a write time would report a register written today as fifty-one days old. A section with no stamp produces nothing; unknown is not the same as stale.

Everything else stays silent, including projects with no section 0. The staleness counter above tells you when a register was last *written*; this tells you how long ago it claims to have been *true*, which is the question that survives compaction badly.

Recovery uses a fallback chain, and `~/.megavibe/scripts/reviewers.sh digest-chain` prints the order for this machine: ChatGPT/Codex → Claude subagent (always works, same subscription); on a machine without Codex, capped Gemini (API key) → Claude subagent. Measured on a 196 KB context log, Codex answers in 23 s on a small model at low effort, the subagent produces the richest summary but spends the session's own quota, and Gemini is the thinnest and the only one billed per token.

### Semantic search augmentation

Every time Claude searches your code (Grep), a hook automatically searches your project memory too and injects relevant context. Claude sees both code results AND related decisions/history — without you asking.

Powered by [poma-memory](https://github.com/poma-ai/poma-memory) (pip-installed): hybrid BM25 + local vector search (model2vec) over your `.agent/` files. Works locally, no API calls. A `reindex-agent.sh` hook keeps the index fresh — it re-indexes changed `.agent/*.md` after edits and Bash appends (debounced, mtime-gated), so semantic recall stays close to the current state.

**Umbrella sessions (several repos under one parent dir):** set
`MEGAVIBE_EXTRA_AGENT_DIRS` to a colon-separated list of other projects' `.agent/`
directories (e.g. in the parent's `.claude/settings.json` under `"env"`). The search
hook then recalls from those indexes too, and the reindex hook keeps each of them
fresh — every root keeps its own `.poma-memory.db`, so nothing is mixed. Empty
(the default) = single-root behaviour.

### Self-improvement

When you correct Claude, it records the pattern in `LESSONS.md`. Before every plan, it checks its lessons to avoid repeating mistakes. Your Claude gets better at YOUR project over time.

### Safety hooks

Automatically blocks dangerous commands before they execute:
- `rm -rf /` or `rm -rf ~`
- `git push --force main`
- `git reset --hard`
- `DROP TABLE`

**Memory search runs against a warm daemon.** Every `poma-memory search` reloads the embedding model and re-reads every stored embedding — 0.52s, of which the search itself is under 10ms — and the recall hook fires on every Grep, Glob and shell content-search. A `SessionStart` hook keeps one resident daemon per machine (`poma-memory serve`, unix socket, 0600) in a named tmux session, which takes the hook end-to-end from ~690ms to ~330ms; with `MEGAVIBE_EXTRA_AGENT_DIRS` the saving multiplies, because one warm process serves every root. Find it with `tmux attach -t poma-serve`, kill it with `tmux kill-session -t poma-serve`, and it reaps itself after 30 idle minutes. Spawn outcomes land in `.agent/LOGS/poma-serve-spawn.log`. Set `MEGAVIBE_POMA_SERVE=0` to opt out. Nothing depends on it: `poma-memory search` talks to the socket when one is there and runs in-process when it is not, so a dead daemon costs speed and never correctness — the hook is byte-identical either way.

**One session per branch, without splitting the project's memory.** Several sessions in one checkout fight over the branch: one switches, another commits onto it without noticing. `megavibe worktree review` creates `../<repo>-review` on its own branch, sharing one `.git`. The part that matters is what it does *not* isolate — `.agent/` and `.claude/` are symlinked back to the main checkout, so the event log, TASKS, DECISIONS and the memory index stay one thing across every session, and every worktree runs identical hooks. A per-worktree copy would quietly split the project's memory in half. `megavibe worktree` lists them, `megavibe worktree remove <name>` takes one away and keeps the branch.

**Credentials never reach the logs.** `.agent/LOGS/tool-events.*.jsonl` records every tool input and response verbatim, and `.agent/events/` is committed to git — so one `env` in a Bash call used to write every exported API key to disk permanently. The `redact-secrets.sh` helper now filters all three write paths (the tool-event log, `agent-log.sh` entries, and the context watcher's own event writes): it replaces the values of environment variables that look like credentials, plus well-known token shapes (`sk-`, `ghp_`, `AIza`, `xox*-`, `glpat-`, `AKIA`, `Bearer …`), and strips the password out of any inline `user:pass@host` URL while leaving the host readable. A variable carrying a secret under a name no heuristic can recognise goes in `~/.megavibe/redact-vars`, one per line. It fails open by design — if perl is missing or the helper is not found, the log is still written unfiltered and a line lands in `~/.megavibe/hook-errors.log`, because losing a log entry is worse than failing to redact one. It is defence in depth, not a guarantee: base64, url-encoded and `\u`-escaped copies are not matched.

**Disk space.** `disk-check.sh` runs at session start and speaks up only when free space on the home volume is below 15 GB (`MEGAVIBE_DISK_WARN_GB`, critical below `MEGAVIBE_DISK_CRIT_GB`, default 8), listing the biggest places to look — the Trash, agent temp directories, caches and logs, `.agent/ASSETS`, `.venv`, `.worktrees`, `node_modules` — as sizes only. `scripts/disk-watch.sh watch` is a quiet Monitor loop for long jobs: it prints only when free space moves by 1 GB or crosses a threshold. Nothing here deletes. `MEGAVIBE_DISK_WATCH=0` switches the hook off.

**`kubectl` and `gcloud` never ask a human to log in.** Many orgs enforce a re-auth policy — Google Cloud RAPT, AWS SSO, an Okta-fronted OIDC provider — that refuses to refresh credentials outside an interactive terminal, so an agent session dies hourly with something like `Reauthentication failed. cannot prompt during non-interactive execution`. The usual answer is a small keeper script that mints a short-lived token to a file, and it works right up until the agent forgets the keeper exists and tells you to go log in instead. (Measured across two real setups: 19 such asks in 9 projects before this hook, and — because the hook originally covered only `kubectl` — another 74 `gcloud auth login` suggestions in a single project afterwards, with a usable token sitting in the keeper's file the whole time.) Point `cloud-token.sh` at your keeper and it stops being something anyone has to remember: on any Bash command that mentions `kubectl`, `gcloud`, `kubeseal` or `helm`, it runs the keeper when the token file is missing or stale, then puts one line in front of the command, `export CLOUDSDK_AUTH_ACCESS_TOKEN_FILE='<token file>'`. gcloud reads that property directly, and kubectl on GKE reaches it through `gke-gcloud-auth-plugin`, which asks gcloud for its token; a Google `ya29.` access token serves both. The command itself is never changed, so heredocs, quotes and comments are safe. A kubectl started by a script or `bash -c` is covered when the command line names one of the tools; a script whose command line names none of them, `sudo`, `env -i` and `ssh` are not, and only GKE credentials go through gcloud (EKS/OIDC contexts and other tools' application-default credentials are untouched). Configure it in `~/.megavibe/personal/cloud-token.conf` (or the same three environment variables) with `KUBE_TOKEN_FILE`, `KUBE_TOKEN_KEEPER` and optionally `KUBE_TOKEN_MAX_AGE` (default 50 min); with none of them set the hook is inert, so it costs nothing if you use neither tool. Only the token file's path is exported, never the token, so it does not enter a shell variable, the transcript or the model's context. A command that contains the word `gcloud` together with `auth`, `config`, `components` or `init` anywhere, or that selects its own identity (`--account`, `--configuration`, `--credential-file-override` with gcloud, or any of `CLOUDSDK_CORE_ACCOUNT`, `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE`, `CLOUDSDK_ACTIVE_CONFIG_NAME`, `CLOUDSDK_CONFIG`, `CLOUDSDK_AUTH_ACCESS_TOKEN`), gets no token: with the property set gcloud uses the token file instead of the stored accounts, so a login would be shadowed by the token it replaces and `auth revoke` or `print-identity-token` would answer for the wrong identity. The check is word co-occurrence after deleting quotes and backslashes, not gcloud's grammar, so it errs towards skipping (no token, the behaviour before this hook); when a skipped command also runs kubectl, helm or kubeseal, the agent is told to run the cluster command as its own call. With gcloud in the command, `$'…'`/`$"…"` quoting, `--flags-file` and impersonation (`--impersonate-service-account`, `CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT`) also skip; every skip, and a keeper that failed to refresh the token, tells the agent why. The guard is against honest mistakes, not a command built to get past it: any command the agent runs can read the token file directly, so a group or the gcloud name assembled from variables, globs or expansions crosses no boundary and is not recognised. Commands that need a stored service-account key, such as `gcloud storage sign-url`, still see the token instead. An explicit `--token` or `--access-token-file` wins over the property. If the keeper fails and the token is still stale, nothing is handed over. (An earlier version rewrote each `kubectl`/`gcloud` word to carry a token flag. That needs a shell parser, and it rewrote heredoc bodies being written to files.)

**Kill guard.** `block-dangerous-bash.sh` also refuses `pkill`, `killall`, `tmux kill-server|kill-session|kill-window|kill-pane` and `launchctl bootout|unload|remove|stop|kill|bootstrap|disable|kickstart -k` (a reviewer's `pkill` took down every tmux-hosted session on 2026-10-15). It parses the command with `shlex` (wrappers like `sudo -u x`, `env`, `bash -c` are followed; quoted text and heredoc bodies are not commands). It does not catch `kill $(pgrep …)`; kill only a PID you started (`$!`). Escape hatch for a human decision: `MEGAVIBE_ALLOW_KILL=1`.

**Phone copy and second opinion.** `scripts/deliverables-index.sh` keeps a ledger and `INDEX.md` for `megavibe-deliverables/` so a remote user can be sent every file exactly once (`unsent`, `mark`, `index`). `scripts/second-opinion.sh --problem "…" FILE…` asks Codex (gpt-6-astra at high effort, scratch sandbox) for ranked causes plus what to check, for a bug that resists two attempts.

**Deletions go to the Trash.** On a Mac with `rmtrash` installed (`setup.sh` installs it where Homebrew exists), the `rm-to-trash.sh` hook rewrites every `rm …` Claude runs into `rmtrash …` before it executes — same flags, but the files land in `~/.Trash` instead of disappearing. A wrong delete becomes a drag out of the Trash. Only `rm` in command position is touched — including inside `$( )`, `find -exec`, `xargs {}` and after a plain `sudo`; never text inside quotes, heredoc bodies, comments, `case` patterns or a `rm()` definition; a quoted `bash -c "rm …"` body is therefore refused by `block-dangerous-bash.sh` (below) rather than run as a real `rm`. (A wrapper with its own options — `sudo -u bob rm`, `nice -n 5 rm`, `timeout 5 rm`, `env -u X rm` — is followed too: per-wrapper option tables find the command it actually runs, so `sudo -u bob rm` is rewritten and `sudo git rm` is not. Redirects, including before the command, and here-strings do not change which word is the command; an `rm` run by `xargs`, or with a command substitution in its arguments, always goes to the Trash because its operands cannot be seen. Commands inside `$( )`/backticks are rewritten even in a double-quoted string or an unquoted heredoc body, where bash runs them.) It rewrites the command line Claude runs, not the inside of a script it invokes. Every target goes to the Trash, temp directories and `node_modules` included: Claude scratchpads live under `/private/tmp` and hold days of work, and a glob there destroyed finished work for good on 2026-10-26. `rm -W` (undelete) stays real; `rm -P` (overwrite), `shred` and `srm` are refused by `block-dangerous-bash.sh`. `MEGAVIBE_RM_SCRATCH_REAL=1` in Claude Code's environment restores the old behaviour, where targets all under the temp dirs (`/tmp`, `/private/tmp`, the per-user `/var/folders/…/T`, a well-formed `$TMPDIR`) or `node_modules` keep real `rm` so scratch data frees disk at once; the rest of this paragraph describes that mode. Targets are resolved first — `..`, symlinks and a leading `cd <dir>` are followed, the path must be inside the temp dir both as written and after symlink resolution — and the hook only reasons about a command that is nothing but an optional leading `cd` plus `rm` segments joined by `&&`/`;`. Anything it cannot prove (a relative path without that shape, `~`, `$HOME`, other variables, braces, a glob through a symlink, a command substitution among the arguments, an `rm` run by `xargs`) goes to the Trash; an absolute scratch target stays real even with redirects after it (`rm -rf /tmp/x 2>/dev/null`) or in a compound line. Known trade-off: arithmetic that uses a variable literally named `rm` with a bitwise operator or an operator hidden in an expansion (`$((rm $op 1))`) may be rewritten, which makes bash report a syntax error (never a deleted file), because a static check cannot tell it from a nested command list. Known gap, same as before this resolution existed: a symlink created earlier in the same command line can redirect an absolute `/tmp` path. If the analysis itself crashes, a crude fallback rewrites every `rm` in command position (separators, keywords, assignments, `find -exec`, wrapper chains; `git rm`/`docker rm`/`echo rm` are left alone, and a deletion carrying `-P`/`-W` stays real per command) to `rmtrash` — over-eager on purpose, logged in `~/.megavibe/hook-errors.log` — rather than leaving `rm` real. A shell alias only covers interactive shells; the hook covers the command line Claude runs directly. There is no escape hatch for `rm`: `\rm`, `/bin/rm` and `/usr/bin/rm` are rewritten too, deliberately. Making something unrecoverable is the user's call: `shred`, `srm` and `rm -P` are refused unless they set `MEGAVIBE_ALLOW_REAL_DELETE=1`. Note the tradeoff: a large `rm -rf dist` now fills `~/.Trash` rather than freeing the space — reclaiming it is the user's call, in Finder or through the Trash greenlight below, informed by the Trash review. `block-dangerous-bash.sh` refuses any attempt by Claude to empty the Trash or delete from it, except the one script that sits behind a permission prompt (see "Trash greenlight") (Finder `empty` via `osascript`, `rm`/`find -delete`/`rsync --delete` on `~/.Trash`, `trash --empty`), because the Trash is the only undo an agent's deletes have; an agent "freeing space" emptied one on 2026-09-30. It parses the command text (`shlex`, so quoted prose such as a commit message is not a command), which means it allows what it does not recognise: a script file, an interpreter one-liner that builds the delete call from pieces (`python3 -c 'getattr(os, "un" + "link")(…)'`), a runtime-assembled or obfuscated path (`T=~/.Tr; T=${T}ash`, `~/.Tras*`, `~/.Tr$'a'sh`), `tar`/`zip` deleters and other exotic forms still get through, and prose inside a heredoc that feeds a shell or interpreter is blocked. The gate in front of the greenlight script adds one deliberate over-block: any Bash text containing `trash-e` is refused (`git add scripts/trash-empty.sh`, `bash -n`, `grep`, a commit message naming it); use the Read and Grep tools, `git add scripts/`, and `git commit -F` (see "Trash greenlight" below). Three independent review rounds each found new bypasses in the earlier versions, so treat it as a net with holes, not a wall. Case variants (`.TRASH`) are covered because APFS is case-insensitive. Without `python3` a cruder regex applies. Any miss is a permanent delete when `MEGAVIBE_RM_SCRATCH_REAL=1` is set, since that mode leaves `rm` on a `.Trash` target real. Deleted files land in the boot disk's `~/.Trash`, or the volume's own `.Trashes` off other disks.

**Deleting from code is blocked, too.** `rm-to-trash.sh` only sees `rm`, so `block-dangerous-bash.sh` refuses the other ways an agent reaches for a real delete: an interpreter (`python`, `node`, `perl`, `ruby`, …) whose inline code or feeding heredoc calls `shutil.rmtree`, `os.remove`/`unlink`, `fs.rmSync`, `FileUtils.rm`, `unlink` or runs `rm` as a subprocess (where it is not rewritten), and `find -delete`, `unlink` and `git clean -f` as commands. The fix is always the same: collect the paths and `rm` them, or call `~/.megavibe/scripts/trash.sh` from the code (a bare `rmtrash` skips the ledger). It reads the command TEXT coarsely and blocks on co-occurrence: an interpreter (`python`, `node`, `perl`, `ruby`, `awk`, …) that runs, plus a deletion API anywhere in the text or a subprocess string that runs `rm`, `find -delete`, `unlink`, `shred` or `git clean -f`; a shell, `eval`, `trap`, `env -S`, `parallel` or `awk` that runs, plus `rm` inside quoted text or a heredoc it consumes, or `rm` text piped into a shell; `rm` spelled so `rm-to-trash.sh` cannot see it (`"rm"`, `\rm`, `RM=rm; $RM`, `$(which rm)`); `unlink`, `shred` or `srm` fed by `xargs`/`parallel`, and `rm` run by `fd -x`; `rm` split by a line continuation; and `find -delete`, `unlink`, `shred`, `srm`, `rm -P`, `rimraf`, `git rm -f` and any `git clean` but a dry run (`-n`) in command position (after keywords, wrappers with options, `VAR=` and redirections, inside `$( )` even in double quotes). Over-blocking it accepts: an interpreter name that is only an argument (`brew unlink node@18`) counts as running it, and a deletion phrase quoted in the same call as a shell or interpreter (`python3 -m pytest -q && git commit -m "use os.remove less"`, `docker run -e MODE="rm" img`) is refused; run the commit, `gh` call or `grep` as its own Bash call, or pass the text with `-F`/`--body-file`. Comments are ignored for shell commands (text after a `#` on a line that runs an interpreter still counts), and quoted options (`'-delete'`) still count. A heredoc counts only when a shell or interpreter consumes it (or its line ends in a pipe), and only when a later line closes it, so a commit message or note written through `cat <<'EOF'` passes; a command that runs a shell or interpreter and merely mentions these calls in quoted text is refused (write such text to a file with the Write tool, since a heredoc that runs would trip it too, and pass the file, e.g. `git commit -F`). It is active only where `rmtrash` is on PATH, the same condition `rm-to-trash.sh` uses: without it `rm` deletes for real anyway, and blocking the other forms would only push agents towards that. A pattern that runs longer than two seconds blocks the command rather than letting it through. `\rm` with one leading backslash is rewritten like `rm`; `trash.sh` falls back to plain `rmtrash` when `python3` itself is broken. Review rounds kept finding spellings a shell parser here missed, which is why it is coarse; it is still a net, not a wall. Not covered: a script FILE an interpreter or shell runs; code assembled at runtime; `docker run … rm` inside a container; `script`, `flock`, `watch` or `source <(…)` running `rm`; `rsync --delete`/`--remove-source-files`, `tar --remove-files`, `zip -m`, `git worktree remove --force`; build-tool cleans (`make clean`, `npm run clean`, `cargo clean`, `mvn clean`); options quoted in pieces (`-de"lete"`) and `$'...'` quoting; a deleter in quotes after `find -exec` or `fd -x`; a `#` that bash does not treat as a comment (after an escaped space or a `)`, at the start of a continuation line) is read as one and hides the rest of its line; dozens of `xargs` options in one command trip the two-second limit and are blocked; a quoted `rm` behind a wrapper option that takes a value (`sudo -u bob "rm"`, `nice -n 5 "rm"`); a nested quote inside a double-quoted `$( )` (`"$(printf '%s' '$(which rm)')"` is refused although it only prints); a backtick after an even run of backslashes (`"\\`cmd`"`); interpreters outside the list (`ipython`, `ts-node`/`tsx`, `Rscript`, `julia`, `uv run -`) and the wrappers `unbuffer`, `chronic`, `busybox`, `ssh host`, `su -c`; `rmdir`; overwriting a file with `mv`/`cp`/`>`, and truncation; anything run outside the Bash tool.

**Trash review.** `rm` runs as `~/.megavibe/scripts/trash.sh`, which renames each item into `~/.Trash` as `<name> mv-<id>` and records it in `~/.megavibe/trash/ledger.jsonl`: original path, that exact Trash entry and its inode, size, session, working directory. Every later action first checks the entry is still the same object, so a name clash or a replaced entry can never redirect it. Finder's "Put Back" does not know these items; restore them through the review. Options it does not handle (`-i`, `-I`, `-x`), an item on another volume, or a rename the OS refuses go to `rmtrash` instead (recorded where possible, not restorable from here). The `trash-watch.sh` hook (PostToolUse on Bash) stays silent until the unreviewed items in the Trash pass `MEGAVIBE_TRASH_REVIEW_COUNT` (default 30) or `MEGAVIBE_TRASH_REVIEW_MB` (default 2048), once per crossing. A single large delete crosses it in the same turn. Then it tells the main session to dump the pending items, have a Haiku agent group them with a recommendation each, ask the user per group with AskUserQuestion, and apply the answers with `trash-review.py apply`:

| Action | Effect |
|---|---|
| Restore | moved back to its original path, never replacing anything there (an atomic no-replace rename) |
| Keep in Trash | marked reviewed, not raised by the hook again; a later group can still restore or back it up |
| Back up | moved to `MEGAVIBE_TRASH_BACKUP_DIR`, by default `megavibe-trash-backup/` in iCloud Drive (or in `~` without iCloud), under the date and the original path |
| Mark droppable | left in the Trash and reported by `status`, so the user can empty the Trash knowing what is in it; the review itself never deletes it; only the user, or the Trash greenlight script behind a permission prompt (below), empties it |

Nothing in the review deletes. Megavibe sessions run with permissions bypassed, and three review rounds found every agent-run consent check for a real delete forgeable (environment overrides, appends to the session transcript, a pseudo-terminal), so no consent check lives in the review: "droppable" items stay in the Trash, and `status` reports how many and how big they are so emptying the Trash is an informed choice. The emptying is a separate script behind a permission prompt the human answers (next paragraph), or Finder. Keep and Mark droppable leave an item reviewable: a later group can still restore or back it up (`pending --all` lists them). Every action first moves the recorded entry atomically into a private claim directory and checks its inode there, so nothing can swap it between the check and the action; checks that can fail (creating the parent, the backup directory) run before the claim, a failure after it puts the item back, and the next `apply` puts back anything an interrupted run left behind. A move to another volume copies (with `ditto`: resource forks, extended attributes, ACLs; a symlink as a symlink) to an exclusively created staging name, publishes with a no-replace rename, and leaves the original in the Trash: removing it would be a real delete. `status` also lists anything an interrupted review stranded in the claim directory. Groups are registered with `trash-review.py group`, which prints a summary line per group to quote in the question. `python3 ~/.megavibe/scripts/trash-review.py status` (counts) and `pending` (the items) work from any terminal. The ledger is best effort: without `python3`, or for an item on another volume (whose Trash location is not recorded, so it cannot be restored from here), the delete still goes to the Trash. `MEGAVIBE_TRASH_REVIEW=0` switches the hook off. Tests: `/bin/bash tests/trash.test.sh`.

**Trash greenlight.** `~/.megavibe/scripts/trash-empty.sh` deletes the items the review marked droppable; `trash-empty.sh --all` empties the whole Trash, including what the ledger never saw. It is the one place megavibe really deletes. What gates it is not a check the agent could run itself from a Bash command but Claude Code's own permission prompt. `setup.sh` (macOS) adds three `permissions.ask` rules to `~/.claude/settings.json` (and to `$CLAUDE_CONFIG_DIR/settings.json` when that is set), as a union with the ones you already have, never replacing a list: `Bash(~/.megavibe/scripts/trash-empty.sh *)`, the same path with `$HOME` expanded, and the catch-all `Bash(*trash-empty*)`. Per Claude Code's documentation an ask rule still prompts under `bypassPermissions` (the mode `megavibe` launches with), the `Monitor` tool follows the same Bash rules, and under Remote Control the prompt is forwarded to the phone: your Yes or No there is the decision. In a plain `claude` session in `dontAsk` mode the call is denied instead of prompting. Check it once on your machine: ask Claude to run the script while nothing is droppable; a prompt must appear in the terminal and on the phone, and No must leave `empty.log` unchanged.

What this guarantees, stated precisely: **the script runs only when Claude Code's own shell was given exactly the approved command, which Claude Code prompts for, unless the agent has rewritten Claude Code's own configuration (permission hooks, settings, plugins) or writes deleting code of its own.** It does not prove that a human answered the prompt. Those two cases are a documented boundary, not something this feature chases to the end; the cheap guards are below, and managed settings close the settings-file route for the ask rules but not for hooks (`allowManagedHooksOnly` would, and would also switch off megavibe's own hooks).

- **The script checks what Claude Code's shell was given.** Ask rules match the command text as written, so a spelling that reaches the file without the text matching (a glob, `cd` first, a variable, a symlinked directory, `env -C`) would skip the prompt, and a list of such spellings can never be complete. So the script does not trust the text it was started with. Claude Code runs a Bash call as a child of its own `claude` process, through a shell whose command line is `<shell> -c source <home>/.claude/shell-snapshots/snapshot-<shell>-<n>-<id>.sh 2>/dev/null || true && … && eval '<the command as typed>' < /dev/null && pwd -P >| /tmp/claude-<hex>-cwd` (measured on Claude Code 2.1.30x with zsh; a quote inside the command is rendered `'"'"'`). That command line is what the permission rules matched. The script walks its ancestors and runs only if (1) the topmost process called `claude` is a running process that satisfies Anthropic's Developer ID requirement (`codesign -v -R=…` against the live pid with team `Q6L2SF6YDW`, so a renamed look-alike, a copy or a tampered binary does not count), and (2) the shell directly below it has exactly that command-line shape with the payload `~/.megavibe/scripts/trash-empty.sh` or `~/.megavibe/scripts/trash-empty.sh --all`, matching the argument the script itself got, nothing else in the call. A bare `bash -c … && eval '…' < /dev/null` from a hook, an MCP server or a helper command does not have that shape. Anything else exits 5, including a plain terminal (even with a tty: an agent can start a Terminal window or a launchd job), a process started outside Claude Code (`osascript`, `launchctl`, `tmux`, a daemonised job), every spelling above, and a `claude` started inside another `claude`'s Bash call (run it from the outermost session). It relies on Claude Code's current way of running commands, on a native, signed install (an npm install shows up as `node`) and on `~/.claude` as the config directory (a custom `CLAUDE_CONFIG_DIR` keeps its shell snapshots elsewhere); if any of that changes, or a sandbox forbids reading the process table, it fails closed (exit 5) until the script is updated; Finder always works.
- **A PermissionRequest hook can answer the prompt for you, so two cheap guards.** Claude Code runs a `PermissionRequest` hook instead of asking you, and the hook can say Yes. The script therefore exits 6 while a non-empty `hooks.PermissionRequest` is visible in the managed settings file, `~/.claude/settings.json`, `~/.claude/settings.local.json`, or the `.claude/settings.json` and `.claude/settings.local.json` of the session's working directory and every directory above it (the working directories of Claude Code's shell and of `claude` itself, read with `lsof`; if neither can be read the script refuses with exit 5, because the project files cannot be checked). A settings file that does not parse is judged by its text and fails closed: any mention of `hooks` counts. The message tells the agent to ask you to remove the hook, not to remove it. `template/.claude/hooks/block-permission-hooks.sh` (a PreToolUse hook on Write, Edit and MultiEdit, run by `init.sh`) covers any `*settings*.json`, a plugin `hooks.json`, and the frontmatter of `.claude/agents`, `skills` and `commands` files: a Write that mentions `PermissionRequest` is refused; an Edit or MultiEdit is applied to the file as it is and refused if the result mentions it at least as often as before (adding one, splitting the word across two edits, and editing around a hook that is already there are refused; deleting one is allowed); a JSON `\u00` escape in a settings write is refused, and JSON that parses is checked with its escapes decoded. `block-dangerous-bash.sh` has a text rule for the Bash route (any command that mentions PermissionRequest next to a settings or hooks file, even to read it: use the Read or Grep tool). Both are text checks and a determined agent can write the same configuration another way (see "Not covered"). **A user with a harmless PermissionRequest hook of their own (one that only notifies) is locked out of this script while it exists**, and so would everyone be if megavibe shipped one, which it does not; to use the greenlight they remove that hook themselves, otherwise they empty the Trash in Finder.
- **The hook is only the first net.** `block-dangerous-bash.sh` lets exactly `~/.megavibe/scripts/trash-empty.sh [--all]`, alone in the call, through to the prompt and refuses other commands that name the script (`trash-empty`, `trash-em*`, `trash-e*`; quotes, backslashes, brackets, braces and newlines ignored, case ignored), a home-anchored path whose first part is a glob that can complete to `.megavibe` and that goes on below it (`~/.m*/scripts/x`, `~/.meg?vibe/x`; `ls -d ~/.m*` passes), and `osascript`, `launchctl`, `crontab` or `open -a Terminal` that mention `~/.megavibe` or the script (`launchctl list | grep com.megavibe` does not). Spellings that name nothing it can see (`cd -P ~/.megavibe/scripts && ./tr*h-e*`, `env -C …`, `$D/tr*h-e*`, `find … -exec {} \;`, a symlinked directory) pass it on purpose: the script refuses them (exit 5). The catch-all ask rule still prompts for any command whose text names the script, in projects without the hook too.
- **Over-blocks.** Any Bash text that names the script is refused, not only runs of it: `git add scripts/trash-empty.sh`, `bash -n scripts/trash-empty.sh`, `shellcheck`, `grep`, `cat` and a commit message that mentions it, and a path with a directory called `…trash-empty…` in it. Use the Read and Grep tools, `git add scripts/` (the directory), a loop over the directory for lint (`for f in scripts/*.sh; do bash -n "$f"; done`), `git commit -F file`. In your own sessions the catch-all rule also makes any such command ask first. Ordinary commands (`ls ~/.m2/*`, `cat ~/.mcp*.json`, `echo trash-export`, `ls ~/.megavibe/scripts/*.sh`) pass.
- **The environment is not trusted.** The shebang is `#!/bin/bash -p` (privileged mode: no `BASH_ENV`, no functions imported from the environment such as `export -f jq`), and the script refuses to run unless `-p` is in effect, so `bash trash-empty.sh` and `source` both exit 3. The path is fixed, the environment is wiped (`env -i`), python3 is looked up only in `/opt/homebrew/bin`, `/usr/local/bin` and `/usr/bin`, never through `PATH`, and the home directory is the user database's: a different `$HOME` is refused. `CLAUDE_CONFIG_DIR` is ignored: the rules must be, as a real array of strings under `permissions.ask`, in `<home>/.claude/settings.json` or in the managed settings file (`setup.sh` writes both locations when the variable is set, so the prompt exists wherever Claude Code reads it). That is the mechanism check, not consent: the consent is the prompt. Not a copy, a symlink or another install path (exit 3); rules missing or malformed (exit 4).
- **How it deletes.** One embedded python program (`python3 -I`), not a subcommand of `trash-review.py` (`python3 …/trash-review.py` is allowed and typable). It opens `~/.Trash` once with `O_NOFOLLOW` and works relative to that descriptor, so swapping `~/.Trash` for a symlink mid-run changes nothing. It reads the ledger as JSON (a newline or separator in a recorded path cannot become a record), accepts only a direct-child name (no `/`, `.`, `..`, trailing slash), and claims each entry with an atomic rename into a private quarantine directory inside the Trash, then checks it is the object the ledger recorded (device and inode) **after** the claim; if another object was swapped in, it is put back and nothing is deleted. The delete is directory-relative and never follows a symlink: a symlink in the Trash is unlinked, its target untouched. Two ledger records for one object that disagree (one kept, one droppable) skip it. A droppable item that is no longer in the Trash (restored, or emptied in Finder) gets an `emptied` row marked "already gone" and does not keep the run at exit 1. It holds the review's `apply.lock`, so it never runs in the middle of a review. An entry it cannot fully delete gets its name back, so a later run finishes it. The delete is plain `unlink`/`rmdir` on purpose: the `rm-to-trash.sh` hook rewrites the command text Claude runs, never the inside of a script. It raises its open-file limit so a deep tree can be walked, and if macOS refuses it access to `~/.Trash` it prints the system error with a Full Disk Access hint. There is no `--yes`, `--dry-run` or environment switch. Exit 1 means something was skipped or failed.
- **What a Yes consents to.** Yes means: delete what the Trash review marked droppable (for `--all`: everything in the Trash). The marks come from the review, where you answer per group, but `trash-review.py group` and `apply` can also be typed by an agent, so **a mark is not consent by itself and the prompt shows only the command**. If you did not just answer a review, look first: `python3 ~/.megavibe/scripts/trash-review.py droppable`. `--all` is for when you asked for it; the review procedure (`trash-watch.sh`) offers only the plain form, never retries a denied prompt, and a denied prompt is the answer. The installed script is a file your account can edit, so an edited copy would run after a Yes; the managed settings file protects the rules, not the script.
- **Interrupted runs.** TERM, HUP and INT end the python program cleanly (the entry it is on goes back under its name; the shell stub passes those signals on to the python child, which runs as its child so that the script's own shell stays in the process chain). KILL, or a power cut, can leave a claimed entry in a hidden `.megavibe-empty-<hex>` directory inside the Trash. The next droppable run, under the lock and before anything else, finishes the entries the ledger still marks droppable and puts every other back under its Trash name (or `recovered-<hex>-<slot>` when that name is taken or unknown), and says so; it never writes "already gone" for an object that is still there. Killing only the shell stub with KILL leaves the python child running to the end of the item it is on; it finishes and logs by itself. A `--all` run sweeps such leftovers like any other entry.
- **Record.** `~/.megavibe/trash/empty.log` gets one line per removed item (name and size) and one total line per run, including a run with nothing to do; every emptied item gets an `emptied` row in `reviewed.jsonl`, so it leaves `pending` and `status`. A droppable record with no device and inode (taken by the `rmtrash` fallback, or on another volume) cannot be emptied here: the run says so once, closes it with an `unemptiable` row so it does not fail every later run, and the item stays in the Trash for Finder. A ledger line that is not UTF-8 or a record that cannot be used is skipped, with a message, and the rest of the run goes on.
- **Stronger, opt-in.** `megavibe trash-greenlight` (or `bash ~/.megavibe/setup.sh --trash-greenlight-managed`) writes the same rules to `/Library/Application Support/ClaudeCode/managed-settings.json`, which an agent running as you cannot edit: it asks for your sudo password at a terminal, backs up an existing file once (to `managed-settings.json.megavibe-backup`, never overwritten, so the first backup is the original), refuses one that is not valid JSON, and unions with your other settings. Run `/status` in Claude Code to confirm it lists Managed settings. If your organisation delivers managed settings by MDM or remote policy, Claude Code reads that source and ignores this file.
- **Not covered.** (1) Deleting code the agent writes itself, as above. (2) Claude Code's own configuration, rewritten by the agent in ways the two guards above do not see: hooks in plugins or in agent and skill frontmatter, a hook or MCP server whose command line is written to imitate the shell's shape, and a second `claude` started detached with other settings (`--setting-sources`, another `CLAUDE_CONFIG_DIR`, `-p`) whose own shell is then given the approved text without your ask rules; anything that can answer or avoid the prompt without a human is outside what the script can see. (3) The rule-presence check reads a file your account can edit: an agent that removes the rules, runs the plain form (no prompt, because the rules are gone), and restores them from a background process timed to the script's check could pass it; the managed settings file closes that. (4) The script proves the call was the approved text, not that the prompt was shown, which is why the rules must be installed. (5) The launcher syncs the script, but only `setup.sh` adds the rules, so until it has run the script refuses (exit 4). (6) Whether `~` in a rule is matched literally is not documented, which is why the expanded path and the catch-all are installed too.

Tests: `/bin/bash tests/trash.test.sh` (sections 7-11: the hook's first net, the script in a scratch `HOME` with a rewritten copy for its test points, the settings merge, the provenance decision on fixture process chains, the PermissionRequest checks).

### Phone access (built-in)

Every megavibe session has [Remote Control](https://code.claude.com/docs/en/remote-control) enabled by default. Type `/rc` in your terminal session to get a QR code — scan it with your phone and continue the same session in the Claude app. Walk away from your desk, keep working from the couch.

### Multi-agent orchestration

**Megavibe works with only a Claude Code subscription.** Everything else adds capabilities but is never required.

| What you add | How | What it unlocks |
|-------------|-----|-----------------|
| **Claude Code** (required) | Subscription | Core: editing, commands, memory, context recovery via built-in subagent |
| **ChatGPT/Codex CLI** | Run `codex` to log in | The primary backend: reviews, context recovery, research with web search, second opinions |
| **Gemini CLI** | Set `GEMINI_API_KEY` (a key from a **billed** project — the free tier is 20 req/day and trains on prompts) | Codex's fallback reviewer; and, only on a machine without Codex, the metered backend for summaries and re-hydration (see below, inputs up to 300 KB) |
| **Playwright** | Installed by setup | Browser automation, screenshots, UI testing |
| **poma-memory** | Bundled (automatic) | Semantic search over project memory |
| **Telegram bot** | Optional, see below | Personal assistant + project launcher from phone/Watch |

Setup installs Gemini/Codex/Playwright CLIs and walks you through activation. You can skip any — megavibe adapts.

> **Note (June 2026):** Google retired "Login with Google" for Gemini CLI on June 18, 2026, steering individual accounts to its Antigravity CLI successor. The Gemini CLI itself still works with an API key, which is the only supported auth for megavibe's Gemini backend. Setup prompts for the key.
>
> **Which key:** one from a Google Cloud project **with billing attached** — an admin mints it with `scripts/mint-gemini-key.sh --project <id> --name <person>` (billed is the default; `--free-tier` opts into the dropped mode). Per [Google's Gemini API terms](https://ai.google.dev/gemini-api/terms) that is the only way API prompts are excluded from training; the Workspace-account clause in those terms covers AI Studio, not the API. The free tier (measured 2026-09: 20 requests/day on the one model a new project can still call) is neither a backend nor private. Cost at a measured developer load is $2–6/month per Mac on flash; never pin a Pro model.
>
> **Gemini reviews, and summaries on a machine without Codex, go through `~/.megavibe/scripts/gemini-review.sh`** (direct API, `thinkingLevel: low`): Gemini 3.x Flash thinks by default and the Gemini CLI — which the MCP tool wraps — cannot lower it, so long answers truncate or take minutes there.
>
> **Gemini without Codex is rationed.** Outside a review the script refuses while Codex is usable, and otherwise runs flash-lite only (never Pro), with output capped at 12000 tokens, input at 300 KB, and at most 40 calls and an estimated $1.00 per local day; over any cap it exits 5 and the caller falls through to the Claude subagent. Every call is logged in `~/.megavibe/gemini-usage.jsonl` (`gemini-review.sh --budget` shows today's). Each call is reserved in the ledger under a lock before it is sent, an unreadable ledger refuses, the context watcher may use at most 60% of the day, and an unreadable cap value counts as 0. Tune with `MEGAVIBE_GEMINI_DAILY_CALLS`, `MEGAVIBE_GEMINI_DAILY_USD` (0 switches general use off), `MEGAVIBE_GEMINI_DIGEST_MODEL` (must be a flash-lite), `MEGAVIBE_GEMINI_MAX_INPUT_KB`, `MEGAVIBE_GEMINI_MAX_OUT`, `MEGAVIBE_GEMINI_PRICES`. The dollar figure is an estimate priced on the high side; your key's own project budget is the real ceiling. Reviews are never refused by the caps, only logged.
>
> **Antigravity CLI (Google's successor) is deliberately not the backend:** it works headlessly on a Workspace login, but it is an agent harness — ~13K tokens of system prompt per call, 2–4 minutes and 3–5x the tokens for the same review the API answers in 7 s, a weekly per-account compute quota with lockouts, and Workspace access is a Gemini Enterprise add-on. Measured 2026-09-06; revisit if Google ships a harness-free headless mode.

**Choosing which reviewers run.** Megavibe reviews in two tiers. Every round gets one independent reader — Codex where it is switched on and available, otherwise the Claude `reviewer` subagent (which also takes the round when a Codex call fails). The round that gates the ship gets both in parallel (critical work such as credentials, destructive paths, public-facing work or the protocol itself gets the same ship round; its intermediate rounds are normal rounds). The reason is cost: Codex draws on its own plan, while the subagent spends ~180-200K tokens of the same Claude subscription your session is using, so running both on every intermediate round buys a second opinion on work that is still moving. Gemini is their fallback, not a third peer — it reviews only when Codex fails on the day, and always on `--pro`. If you want something else:

```bash
megavibe reviewers                          # what is on, where it was set, what is available
megavibe reviewers set all                  # all three eligible; ship rounds run them in parallel
megavibe reviewers set reviewer codex       # never Gemini, not even as a fallback
megavibe reviewers set --project reviewer   # this project only (uncommitted)
megavibe reviewers set auto                 # back to the default
```

**Why Gemini is the fallback reviewer.** Measured across one day of paired reviews (11 units where both read the same diff with the same prompt): Codex — which reads the repo, runs the tests, and reproduces the failing input — found real defects in every unit. Gemini, a single stateless API call over inlined files, produced four wrong headline findings and five SHIP verdicts on code with confirmed blockers. It also produced one unique real catch that nothing else found — an argument for `set all`, not for the default: under the default it does not review at all on a day when Codex works, so that class of catch goes to zero. It stays in the chain because it is the only EXTERNAL review capability on a machine without Codex, where it takes Codex's place in the default set alongside the subagent, and because it covers the days Codex is out of quota. To keep the third opinion at roughly $0.15 a review, run `megavibe reviewers set all` and treat its findings as leads to reproduce rather than as verdicts.

The Claude `reviewer` subagent can never be switched off — it needs no key and is the floor the rule rests on — so this setting really chooses which external readers join it. Switched on is not the same as called every round: under the tiering above the subagent joins on the ship round (critical work included), and carries the normal round alone whenever Codex is switched off, absent, or has failed. It writes `MEGAVIBE_REVIEWERS` into the `env` block of `~/.claude/settings.json`, or — with `--project` — the project's uncommitted `.claude/settings.local.json`; the environment variable overrides both. A **committed** project `.claude/settings.json` is read too, but it may only *add* reviewers: a file that arrives with a clone must not be able to switch off the reviewers looking at that clone's code. The session-start status table gains a Reviewers row, and a reviewer you switched off exits without spending anything when asked to review.

It limits **reviews only**. Gemini and Codex stay available for context recovery, summaries and large-context work whatever you set here — switching a reviewer off should not cost you `/rehydrate`.

### Structured workflow

```
Explore → Plan → Implement → Verify → Commit → Learn → Reflect
```

| Step | What Claude does |
|------|-----------------|
| **Explore** | Read-only investigation |
| **Plan** | Define files, steps, verification commands |
| **Implement** | Follow the plan. Stop and re-plan if it diverges |
| **Verify** | Run tests/commands; important results get an independent subagent/backend review by default |
| **Commit** | Descriptive message, log to FULL_CONTEXT.md |
| **Learn** | After corrections, record the pattern |
| **Reflect** | After major features, assess if approach is still sound |

### Parallel tasks (spinouts)

When a plan has 3+ independent tasks, Claude can spin them to parallel subagents. Each gets a fresh context window. The primary benefit is **context freshness**, not just speed.

A job over many bulky items (images, PDFs, long logs) is split the same way by context size: on one measured image-labelling job, one long subagent cost an estimated 2-4x more than batches kept under about 250K tokens would have (it pays only while each batch's fixed briefing stays small). Rule and numbers: `.claude/rules/spinouts.md`, "Batch jobs".

A subagent's prompt cache lives 5 minutes by default (the main thread's usually 1 hour), so a foreground wait past that re-writes its whole context. Spin-out briefs therefore carry a wait limit of 170 s per call and a sentinel-file recipe for waiting on long jobs; waits over about 35 minutes belong to the parent. Measurement and recipe: `.claude/rules/spinouts.md`, "Subagents: keep the cache warm while waiting".

### Slash commands

Inside a megavibe session:

| Command | When to use |
|---------|------------|
| `/catchup` | **Starting a new session** — reviews open tasks, git state, decisions (no AI calls). **Not needed after compaction** — the `on-compact` hook writes the same orientation to `.agent/LOGS/rehydration-instructions.<session>.md`. |
| `/rehydrate` | **After compaction or stale context** — full AI-powered recovery. Post-compact this is the ONLY slash command you need to type; until it has run, the hooks remind the session on the 1st, 10th and 30th tool call after a 5-minute grace window, and block one Stop at the first turn end after a reminder. |
| `/prune-context` | **Superseded** by `.claude/hooks/agent-log.sh fold` (moves old events into `.agent/snapshot.md`; no content is lost); kept for old projects. **Distinct from `/compact`** (built-in conversation summarizer) |
| `/doc-review` | After material doc/code changes — multi-reviewer (Claude `reviewer` subagent + Codex) review of `CLAUDE.md` + every `README*.md` for drift, contradictions, dead pointers, bloat |
| `/megavibe-restart` | Update megavibe and restart the session so new hooks/rules/skills apply. When an update landed, the resumed session's start-up message carries a short note of what it changed (see [Updating](#updating)) |
| `/init-feature <description \| issue link>` | **Before starting a feature** — takes prose or a GitHub issue link; produces a scoped summary and a complexity/token estimate you confirm or send back, then you pick: write a spec or vibe it, and whether to post the result to that ticket or open a new one |
| `/finish-feature [base]` | **After finishing one** — measures turns, tool calls and tokens actually spent from the transcript, scores them against what `/init-feature` predicted, comments the result on the PR and offers to merge it |
| `/copy` | Copy content to the clipboard, formatted for the target (Slack, Markdown, plain text) |
| `/rc` | Get a QR code to connect from your phone (Claude app) |

---

## Remote access (optional)

Every session has `/rc` — connect from the Claude app on your phone, no setup.
An optional Telegram bot adds a personal assistant and project launcher.

Full detail: **`README-remote.md`**.

## Optional API Keys

Megavibe works without any API keys. Adding them unlocks extra capabilities:

| Key | What it does | Cost | How to get it |
|-----|-------------|------|---------------|
| `GEMINI_API_KEY` | **Required for the Gemini backend** — Google-account OAuth was retired June 18, 2026 | Needs billing on the key's project (free tier: 20 req/day, prompts used for training) | [aistudio.google.com](https://aistudio.google.com/apikey) |
| `OPENAI_API_KEY` | Better poma-memory search + voice transcription for Remote | ~$0.01/month search; ~$0.006/voice note | [platform.openai.com](https://platform.openai.com/api-keys) |

```bash
# Add to your shell profile (~/.zshrc, ~/.bashrc, etc.) for persistence
export GEMINI_API_KEY="your-key-here"
export OPENAI_API_KEY="your-key-here"
```

## Subscription-first routing

Megavibe prefers the subscriptions you already pay for over anything billed per token, and uses what they report about themselves to spend them sensibly.

- **API billing is barred.** A launch that would bill per token (`claude auth status` reporting `api_key` or `api_key_helper`; a subscription OAuth token is fine; a Bedrock/Vertex/Foundry or other third-party provider only gets a notice, since that is a cloud bill, not a Claude one) stops with one line on the main `megavibe` launch; `MEGAVIBE_ALLOW_API_BILLING=1` accepts it. An exported `ANTHROPIC_API_KEY` is masked for that session, as before. `megavibe assistant` and `remote` start Claude by other routes (tmux, the Telegram bot) and are not covered yet, and neither is a key you pass yourself through `--settings`.
- **Usage history.** Claude Code has no usage API, but the statusline receives your account-wide five-hour and seven-day usage (`rate_limits`, subscribers only, after the first reply). `statusline.sh` appends a row to `~/.megavibe/usage/claude.jsonl` on a change or every five minutes. Nothing leaves the machine and nothing reads credentials.
- **Launch.** `scripts/usage-route.sh` classifies the account as `over` (7-day use at 90% or projected past 100% of the week; in the first quarter of the week, before there is a projection, 30 points ahead of a straight-line pace, held until the projection takes over; or 5-hour use at 85%), `under` (week on pace to use less than 70%, or capacity about to reset unspent) or `normal`. `over` launches with `--model sonnet --effort medium` where your defaults are higher; `under` launches with `${MEGAVIBE_ROUTER_UP:-opus}` where your default is lower, but an upgrade to Opus (or Fable) only on a Max plan (`claude auth status` reports `subscriptionType`; a lower `MEGAVIBE_ROUTER_UP` target is not plan-gated): a lower or unknown plan keeps the model it chose, Sonnet unless it picked otherwise, because Opus spends a Pro limit several times faster. Hysteresis releases `over` 30 minutes after its leave thresholds first hold (the highest reading of a window is remembered, so a reading of 85% or more holds `over` until the window resets or the projection falls with elapsed time; delete `~/.megavibe/usage/route-state.json` or set `MEGAVIBE_ROUTER=0` to override), and requires two qualifying evaluations 30 minutes apart for `under`; `under` lasts only while its qualifying reading holds (the five-hour window that justified it resetting ends it), and with no live window both bands are `normal`. Which window is live is decided by its reset time, not by the order rows were logged. Concurrent sessions are merged by taking the highest reading of the current window, which the router also remembers in `route-state.json` so a flood of late, lower rows cannot hide it. No data or a reset window is `normal`, which changes nothing; a reading older than 6 hours inside a live window still counts toward `over` (usage only grows inside a window) but never toward `under`. `under` upgrades from the model in `~/.claude/settings.json`, so it needs one there. The history keeps its newest 5000 rows past 2 MB and does not tell accounts apart (one account per `~/.megavibe`).
- **Your choice wins, per half.** `--model`/`--effort`/`--settings` on the command line, a resumed conversation (`--continue`, `--resume`, `--from-pr`) and `MEGAVIBE_ROUTER=0` switch the router off. A model set by `ANTHROPIC_MODEL`/`ANTHROPIC_DEFAULT_MODEL` or a project `model` is left alone, and so is an effort set by `CLAUDE_CODE_EFFORT_LEVEL` or a project `effortLevel`; the other half can still be routed. `megavibe route` prints what a launch would do.
- **Mid-session.** `usage-advisory.sh` tells the session when the band changes, and again after `/clear` or a compaction, how to spend subagents (pin `haiku`/`sonnet` when hot; let judgment-heavy ones inherit when capacity would be lost), and says when usage is back to normal. It also relays the balance advice below, and withdraws it when it stops applying.

- **Codex, same engine.** `usage-route.sh codex` runs the same bands on the weekly figure Codex records in `~/.codex/sessions/**/rollout-*.jsonl` (ChatGPT login only; only this machine's calls appear, so a Codex also used elsewhere under-reads, and a reading counts as stale after 24 hours). The Codex band is advice (`megavibe route`, and `usage-route.sh balance` below); it changes no review. Until 2026-10-11 the `under` band raised an unspecified review to `xhigh`. That was removed: a blind benchmark found `xhigh` no better than `high` at about twice the time, and in real use both reviews of large PRs it raised timed out at 900 s, where the config's own effort answered in about 8 minutes. `over` changes nothing either: the review floor does not drop, and a Codex that runs dry already falls to the `reviewer` subagent.
- **Balance.** `usage-route.sh balance` compares the two weekly projections. When one subscription is running hot and the other is not, or they differ by 20 points or more, the advisory hook tells the session which one optional work (digests, exploration, second opinions) should lean on. It is advice for the model's own routing, not a gate: `reviewers.sh digest-chain` is unchanged. `megavibe route` prints both bands and the balance.

A running session's model cannot be changed from outside, so the launch is the only place the router acts on the main thread. Spare Anthropic capacity at reset is lost, so is spare Codex capacity; the point of the balance is that neither runs dry while the other idles.

---

## Deliverables and open decisions

A session hands you work in one visible place instead of burying it in the hidden `.agent/` directory or leaving it on a hosted page.

- **`megavibe-deliverables/`** in each project root (created and gitignored by `init.sh`): reports, review syntheses and plans as clean Markdown or HTML. Nothing in it is committed; move a file out when it graduates.
- **`megavibe-deliverables/STATUS.md`** is the live file: what is going on, and every decision you owe as a numbered `D<n>` block with options, a default the session proceeds on, and an `Answer:` line. Type an answer into the file at any time; `status-sync.sh` (session start, every prompt you send, and every tool result while a session works) hands new answers to the session, which acts on them and moves the block to "Decided". The text is capped, is treated as a choice or short instruction (never as authorisation for a destructive action), and a `STATUS.md` that git tracks is ignored. `megavibe worktree remove` refuses to delete a worktree whose own `megavibe-deliverables/` holds anything beyond the two untouched template files.
- **`## Asked for`** in `STATUS.md` is the register of what you asked a session to write (ask, date, file, mirror, state). A request is `done` only when its file is in the folder: a chat answer or a note in `.agent/RESEARCH/` does not count. At each compaction `on-pre-compact.sh` hands the next model counts only (open asks, rows marked `done` whose file is missing, while something is open the number of `.agent/RESEARCH/` files from the last 14 days newer than everything in the folder except STATUS.md and README.md, a heuristic, and a `Now` section over about 4000 bytes): never text from the file, since a cloned repo can ship its own `STATUS.md`. Added after an audit found eight asks in one project that never became a file.
- The protocol bans open ends inline ("your call", "later", "say go"): an owed decision goes into STATUS.md, and the session continues on its stated default or says it is blocked on that D-number. Format: `.claude/rules/deliverables.md`.

---

## Installed files and hooks

### Machine-wide (by setup)

| What | Where |
|------|-------|
| `megavibe` CLI | `~/.local/bin/megavibe` |
| Framework files | `~/.megavibe/` |
| Personal assistant project | `~/.megavibe/personal/` (once set up with `bash ~/.megavibe/init.sh ~/.megavibe/personal`, its hooks, rules, skills and agents sync on the next project `megavibe` launch after an update, not on `megavibe assistant`; log in `~/.megavibe/personal-init.log`) |
| Core protocol | `~/.claude/CLAUDE.md` |
| Status bar | `~/.claude/statusline.sh` |
| MCP servers | Gemini, Playwright, poma-memory (Codex is a CLI, not MCP) |

### Per-project (automatic on first `megavibe` run)

Not in your home directory: there `.claude/` is your user-level config, so hooks installed into it would fire in every project, and a session there would run with bypassed permissions but no guard hooks. `megavibe` refuses to start in `~` (cd into a project, or run plain `claude`), and `init.sh ~` installs nothing. In a folder that is not a repo but holds several (an umbrella like `~/dev`), the launcher names the repos whose own `.agent/` log is newest: there, memory and `.agent/` are one bucket for all of them and, by default, no repo's own decisions, lessons or tasks are read (`MEGAVIBE_EXTRA_AGENT_DIRS` adds other repos' `.agent/` to search only), so launch inside the repo you change and reach a second one with `--add-dir`. If an older launch from `~` already installed hooks, `setup.sh` says which registrations in `~/.claude/settings.json` to delete; it then archives `~/.claude/hooks` on the next run.

| What | Where |
|------|-------|
| Hooks (33 scripts) | `.claude/hooks/` |
| Rules (6 files) | `.claude/rules/`. Claude Code also loads the rules of every parent directory, so a megavibe project nested in another (`~/dev/proj` under `~/dev`) keeps no copy of the rules the parent carries: `rules-dedupe.sh` (run by `init.sh` and on session start and resume) removes the project's untracked copies (identical ones at session start, any under `init.sh`, which always overwrote them) and reinstalls one, from the next session, if no copy exists anywhere up the tree. Copies tracked by git, linked, or edited (outside `init.sh`) are kept |
| Plan storage | `.agent/PLANS/` (native `plansDirectory`) |
| Skills (8 commands) | `.claude/skills/` |
| Agents (1 fallback) | `.claude/agents/` |
| Hook config | `.claude/settings.json` |
| Context structure | `.agent/` |
| Personal overrides | `CLAUDE.local.md` |
| Deliverables and live decisions | `megavibe-deliverables/` (gitignored) |

---

## Performance

Megavibe adds minimal overhead. The main cost is the poma-memory vector search database, which stores embeddings of your `.agent/` files locally.

**Real measurements** from an active project (megavibe itself — 1,500-line context log, 50+ sessions, 3,000 chunks indexed):

| Metric | Value | Notes |
|--------|-------|-------|
| **Disk (DB)** | ~10 MB | Scales linearly with indexed content (~3 KB/chunk) |
| **Disk (.agent/)** | ~25 MB | Includes FULL_CONTEXT.md, logs, sessions. Grows over weeks/months |
| **RAM (model)** | ~25 MB | model2vec embedding model, loaded on first search |
| **Search (cold)** | ~500 ms | First search loads the model |
| **Search (warm)** | ~300 ms | Subsequent searches in the same session |
| **Hook overhead** | < 10 ms | Hooks are shell scripts, no network calls |

For a typical project (shorter context, ~500 chunks), expect ~1 MB disk and sub-100ms warm search.

poma-memory uses brute-force cosine similarity on numpy arrays — no external vector DB needed. This scales comfortably to ~10K chunks (~30 MB DB) before you'd notice any slowdown. Most projects will never reach that.

---

## Updating

Re-run the installer. It's idempotent:

```bash
curl -fsSL https://raw.githubusercontent.com/poma-ai/megavibe/main/install.sh | bash
```

Or if you have a local clone: `bash megavibe/setup.sh`

**What changed?** `megavibe update` (which `/megavibe-restart` also runs) writes a short plain-language note of what the update changed, so the next session can show it. At update time it makes one call, `claude -p --model haiku --output-format json`, over the commit messages of the range: no tools, no settings or hooks (so no `apiKeyHelper` is loaded either), no MCP servers, a scratch working directory, and the variables that would point it at an API key or another provider (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, the Bedrock, Vertex and Foundry switches) removed, so it uses your subscription. If your Claude login itself is a console API key, the call is billed to it: a few thousand Haiku tokens per update. `MEGAVIBE_UPDATE_SUMMARY=0` turns the call off. The wait is at most 25 seconds by default; `MEGAVIBE_UPDATE_SUMMARY_TIMEOUT=<seconds>` takes one to three digits and is clamped to 1-120, anything else means 25. An answer that is not one complete, successful JSON document (an error, a login message, a truncated or doubled output) is never used as a note.

Records are kept as one file per update, `~/.megavibe/update-notes/<old8>-<new8>`, written whole and never touched again by the launcher, so updates that finish out of order, or that follow one another before you open a session, are separate files and none overwrites another. A range is published at most once, even if two `megavibe update` runs race on it: before publishing, the launcher takes an empty marker directory for the range (`update-notes/.published/<old8>-<new8>`, removed by the hook after 30 days), so a record that was already shown cannot come back. At session start in a megavibe project, `announce-update.sh` (a SessionStart hook, which never waits for an update in progress) takes each pending file with its own atomic move and shows what it got as one start-up message, oldest first by when the update started, capped at about 40 lines and 3000 bytes; what does not fit (and everything beyond the 50 oldest pending records) waits for the next session and is counted in a closing "... and N more updates" line. Each record is shown once, by exactly one session. Nothing is typed into the session for you and the model is not handed the update log. A record shows its note or, when no note could be made (no `claude`, `perl` or `jq` on the machine, a timeout, any error, or a switched-off call), its first few commit subjects. The hook needs `jq` to build the message: without it nothing is shown and the records wait. A record no session has shown for a week is deleted lazily, at the next session start after that, not on a timer. The single `~/.megavibe/.update-changelog` file of older launchers is still read, once.

---

## Troubleshooting

**`megavibe: command not found`**
```bash
# Add ~/.local/bin to your PATH (add to ~/.zshrc, ~/.bashrc, or ~/.profile)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

**Hooks aren't firing** — Install jq: `brew install jq` (macOS), `sudo apt install jq` (Ubuntu), `sudo dnf install jq` (Fedora)

**Codex not connecting** — Run `codex` directly to re-authenticate. **Gemini not connecting** — check that `GEMINI_API_KEY` is exported and `~/.gemini/settings.json` has `security.auth.selectedType = "gemini-api-key"` (Google-account login was retired June 18, 2026). Megavibe works without either.

**Context recovery not working** — Check that `.agent/FULL_CONTEXT.md` has content. If empty, the watcher hasn't flushed yet (cycles every 5 min by default) or it isn't running. Verify with `tmux ls | grep '^mvw-'`; tail its log at `.agent/LOGS/watcher.<sid12>.log`. If the watcher is off (`MEGAVIBE_WATCHER=0`), the safety-net hook nudges Claude to flush manually after the first few tool calls.

**poma-memory search not working** — Check Python deps: `python3 -c "import numpy, model2vec"`. If missing: `pip3 install numpy model2vec`

**Memory recall returns stale or off-topic hits** — An older index can be stale (built against a prior checkout) or cross-project-contaminated (an early `poma-memory index` run from a parent dir swept sibling `.agent/` dirs into one db). `poma-memory index` is additive and won't clear that. **Self-heal:** re-run `bash ~/.megavibe/setup.sh` (upgrades poma-memory to ≥0.3.7) and `bash ~/.megavibe/init.sh <project>` (or `/megavibe-restart`) — init does a one-time clean rebuild of that project's index, gated on `.agent/LOGS/.poma-heal-v1`. Force a re-heal anytime by deleting that marker and re-running init, or manually: `rm -f .agent/.poma-memory.db*; poma-memory index .agent/` from inside the project. **Never** run `poma-memory index` from a parent dir containing sub-project `.agent/` dirs — that is what causes the contamination.

**Remote bot: "No response received"** — Check the tmux session: `tmux attach -t megavibe-personal`. Claude may be waiting for input or stuck on a prompt.

**Remote bot: voice not working** — Requires `OPENAI_API_KEY` and `httpx`: `pip3 install httpx`

**Debug hooks** — `claude --debug` shows hook execution details.

---

## FAQ

**Does this work with any language/framework?**
Yes. Megavibe is language-agnostic — it's just files and shell hooks.

**Can my team use it on the same project?**
Yes. `.agent/` files are designed for concurrent access. Commit `.agent/` to git so the team shares decisions and lessons.

**Does this replace Claude Code's built-in memory?**
No, it complements it. Claude's auto-memory handles cross-session preferences. Megavibe handles detailed project context, decisions, and task state.

**What if I don't have Gemini or ChatGPT?**
Megavibe still works. Context recovery and reviews fall back to built-in Claude subagents on the same subscription. External backends improve quality but are never required.

**Do I need Telegram for remote access?**
No. Every session has `/rc` (Remote Control) built in — connect from the Claude app on your phone with no extra setup. Telegram adds a personal assistant and project launcher on top.

**Does the Telegram bot need to run all the time?**
No. It's optional. Run `megavibe remote` to spin it up in the background (it will persist across terminal closes). To make it automatically start when your computer boots up, run `megavibe remote --autostart on`. Your normal terminal sessions work exactly the same either way.

**How do I uninstall?**
```bash
rm -rf ~/.megavibe ~/.local/bin/megavibe
# Remove the megavibe block from ~/.claude/CLAUDE.md (between <!-- megavibe-v3 --> markers)
# In each project: rm -rf .agent .claude/hooks .claude/rules .claude/skills CLAUDE.local.md
```

---

## Architecture (for contributors)

See [CLAUDE.md](CLAUDE.md) for full contributor documentation.

- **Idempotency is sacred.** Both `setup.sh` and `init.sh` are safe to re-run.
- **Marker-based protocol updates.** `<!-- megavibe-v3 -->` markers enable surgical replacement.
- **Infrastructure vs. user data.** Hooks/rules/skills are always overwritten. Context files are never overwritten.
- **Session isolation.** Multiple Claude sessions can run on the same project safely.
- **Remote Control by default.** Every session launches with `--remote-control`.

---

## License

[MIT](LICENSE)
