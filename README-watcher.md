# Context Watcher

A long-running daemon that keeps `.agent/` files fresh from the live Claude Code transcript — with **no in-session token tax**.

The intent: replace the proactive tier-nudge architecture ("flush context NOW") with an out-of-band watcher that does the flush itself, on a trickle, while you work. Claude never has to be reminded; the files are already current when compaction or session end arrives.

**Status: default ON.** Opt out per session with `MEGAVIBE_WATCHER=0`.

---

## How it runs

One `python3 ~/.megavibe/scripts/context-watcher.py` process per Claude session, hosted in a named tmux session `mvw-<sid12>`.

- **Spawned** by `on-session-start.sh` (matcher `startup`) — automatically, unless `MEGAVIBE_WATCHER=0` is set in the shell that launched Claude.
- **Killed** by `on-session-end.sh` (matcher `.*`) which `tmux kill-session`s the daemon. The daemon catches the resulting SIGHUP, does one final flush, then exits.
- **Self-contained**: lives entirely in tmux, never disowned to launchd, no LAN ports, no PID files needed.

## What it does each cycle (default every 300s)

1. Reads new turns from the transcript JSONL past the cursor at `.agent/LOGS/.flush-cursor.<sid>`.
2. If fewer than `--min-new-turns` (default 10), skips.
3. Sends slice + existing `.agent/` files to **Gemini → Codex** (fallback). All-backends-fail = cycle skipped, log entry written, no user impact.
4. Parses the JSON envelope. Drops any item whose `verbatim_evidence` (>=20 chars) isn't a substring of the slice. Lessons additionally require evidence from a **user-role** turn — so the assistant's self-reflection can't masquerade as a user-confirmed pattern.
5. **Auto-applies** (low-stakes, easy to revert, under `flock`):
   - `narrative` → append to `FULL_CONTEXT.md` with the slice's actual date
   - `lessons` → append to `LESSONS.md`
   - `tasks_patch` → append rows to `TASKS.md`; status changes / comments land as `<!-- watcher notes -->`
6. **Stages** (high-stakes, durable rationale):
   - `decisions` → `.agent/LOGS/pending-decisions.<sid>.jsonl` — gated by human review

## Reviewing staged decisions

```bash
python3 ~/.megavibe/scripts/review-decisions.py            # walk current project, interactive
python3 ~/.megavibe/scripts/review-decisions.py --list     # just counts
python3 ~/.megavibe/scripts/review-decisions.py --yes-all  # accept everything (use sparingly)
```

Accepted decisions get appended to `.agent/DECISIONS.md` continuing the existing sequence number; rejected ones stay in the staging JSONL with `status: rejected` for audit.

## Enabling / disabling

The watcher is **on by default** — `claude` (or `megavibe`) launches and the spawn hook will start it automatically, provided tmux is on PATH and `~/.megavibe/scripts/context-watcher.py` exists.

```bash
# Disable for one session
MEGAVIBE_WATCHER=0 claude

# Disable persistently
echo 'export MEGAVIBE_WATCHER=0' >> ~/.zshrc   # or ~/.bashrc
```

When the watcher is alive (its `mvw-<sid12>` tmux session exists), the in-session tier nudges and the 8-call stale-context nudge in `log-tool-event.sh` both suppress automatically — the daemon is keeping `.agent/` fresh, so Claude doesn't need a "flush now" reminder. When the watcher is off, those nudges remain the safety net.

## The ratio nudge (user-facing)

With the watcher running and the launcher's 500K cap removed, context can grow much larger before the harness auto-compacts. Most of the time that's fine — the watcher is flushing knowledge as you work. But occasionally context grows faster than the watcher can keep up with: a long exploration burst, a wall of tool output, etc.

For that case `log-tool-event.sh` fires a **once-per-session** stderr nudge (visible to you, not folded into Claude's context) when:

- `tokens > 400K`, **AND**
- `tokens_grown_per_hour / agent_writes_per_hour > 100K` (the watcher is genuinely outrun)

Sample output:

```
📊 Context at 580K — grew 230K in the last hour with 1 .agent/ writes.
   The watcher is being outrun. If this thread of work is winding down,
   consider /compact (durable state is in .agent/ — recovery is cheap).
```

If you want to suppress it for a session, `touch .agent/LOGS/.user-nudge-fired.<sid>` (or just ignore it — it only fires once anyway).

## Inspecting / killing

```bash
# Is it running?
tmux ls | grep '^mvw-'

# What is it doing?
tail -f .agent/LOGS/watcher.<sid12>.log

# Manual kill (also happens automatically on session end)
tmux kill-session -t mvw-<sid12>

# What's pending review?
python3 ~/.megavibe/scripts/review-decisions.py --list
```

## When it skips

- `MEGAVIBE_WATCHER` not set → never spawns
- No `.agent/` directory in cwd → not a megavibe project
- `tmux` not on PATH → silent skip
- Transcript file not yet on disk at SessionStart → spawn skipped, but **self-heals**: see below
- All backends failed → cycle skipped, log entry written, next cycle retries

The watcher never blocks the user, never throws errors into the Claude context. Worst-case it does nothing useful that cycle.

## Self-heal + visibility

The spawn hook (`start-context-watcher.sh`) fires once at `SessionStart` and globs for the transcript JSONL. Claude Code sometimes hasn't written that file yet — the hook would then give up *permanently*, leaving the watcher dead all session and `.agent/` silently stale (the failure mode that motivated this section).

Two guards close that gap:

- **`revive-watcher.sh`** (PostToolUse, all tools) — if no `mvw-<sid12>` session is alive, it re-runs the spawn logic, throttled to once per 60s per session. By the first tool call the transcript exists, so a lost startup race heals on the next action. It passes the `transcript_path` from the hook input straight through, so the spawn skips the racey glob entirely.
- **Statusline warning** — when the watcher *should* be running (not opted out, prereqs present) but its tmux session is gone, `statusline.sh` appends a red **`⚠ autosave off`** to the bar. A bare context-% means nothing to someone who doesn't know the daemon exists; this names the problem in plain language. A brief flicker at startup is normal (revive heals it within one tool call); a persistent warning means autosave is genuinely down.

## Known quirks

**Commit-message mining.** Bash tool output that contains a git commit message ends up in the transcript slice the watcher reads. Gemini's evidence-quote check passes against commit messages perfectly — they're verbatim, >=20 chars, on disk. So a decision you captured in a commit message can re-stage as a "new" pending decision next cycle, even though it's already on a row in `DECISIONS.md`.

A pre-stage dedup filter (`dedup_decisions` in `context-watcher.py`) catches the obvious cases by checking whether the candidate title (normalized, lowercased, first 60 chars) already appears anywhere in `DECISIONS.md`. Titles shorter than 30 chars normalized can't be safely deduped this way and pass through — you'll see them in review and reject by hand if redundant.

This is acceptable noise; the cost of a false-positive rejection (silent data loss of a real decision) is higher than a false-negative pass-through (one extra reject click in the review CLI).

## Architecture notes

- **Cursor is line-indexed, atomic** (tmp + rename). Advanced only after successful application — a crash mid-cycle re-processes the same slice next time, no data loss.
- **flock on shared file appends.** Two concurrent watchers (same project, two sessions) serialize on `<file>.lock` next to each shared file.
- **Multi-session safety.** Pending-decisions queue is session-scoped; auto-applied files are project-scoped under lock.
- **Side-effect**: writes to `.agent/*.md` bump file mtimes, which `log-tool-event.sh` notices and uses to reset the in-session stale-context counter. Free benefit — Claude stops getting nagged when the watcher is doing the work.

## Phase-out plan for tier nudges

Tier nudges in `log-tool-event.sh` stay live until the watcher has empirical evidence (a few real-session runs) that it keeps files current without intervention. Once that bar is cleared, the tier-nudge code in `log-tool-event.sh` (~80 lines) can be removed.

Until then: both run side-by-side. Tier nudges fire if context grows past 50/75/90% of the auto-compact window; the watcher writes files between turns. No interaction between them.
