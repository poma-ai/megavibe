---
name: disk-and-trash
description: Disk space and Trash mechanics. Load when disk space is low or a disk warning appears, when session scratch is over budget, before cleaning up worktrees or temp directories, and when a Trash review is due or the user asks about the Trash. Holds the disk thresholds, session temp and scratch registration, the worktree audit, the startup scratch sweep, the footprint line and the Trash review flow. The deletion rules themselves (Trash, never empty it, remote hosts) stay in the protocol.
---

# Disk space and the Trash: mechanics

The rules (deletions go to the Trash and never bypass it, never empty the Trash, a remote host has no Trash, a round is not done while its copies exist, the scratch budget) are in the protocol, `~/.claude/CLAUDE.md`, "Deletions go to the Trash" and "Disk space is finite". This skill holds the mechanics.

## Disk warnings

`disk-check.sh` warns when free space is below the larger of 40 GB and 15 percent of the volume (`MEGAVIBE_DISK_WARN_GB` fixes the line; opt out with `MEGAVIBE_DISK_WATCH=0`): at session start, after every compaction, and about every 5 minutes of tool activity (`MEGAVIBE_DISK_CHECK_MINS`, 0 switches the mid-session check off; it needs perl), speaking once per level change.

Pytest and other tools that honor the default `TMPDIR` use the session’s short, budgeted temp directory when the SessionStart export succeeds. Use the session scratchpad for large items you place explicitly and register large items created directly under the shared temp base with `~/.megavibe/scripts/scratch-own.sh register PATH` (the SID comes from `CLAUDE_CODE_SESSION_ID`). When disk is low, first run `~/.megavibe/scripts/worktrees-audit.sh audit` to report what is big; `remove-safe` only touches clean, fully pushed, merged worktrees (or detached duplicates reachable from a remote ref), excluding locked, main and current ones, so review `remove-safe --dry-run` first.

## Startup scratch sweep and footprint

SessionStart also runs a bounded sweep of scratch from ended sessions. It keeps sessions it identifies as live, recent changes, and trees containing `.keep`. SessionStart registers custom Claude config directories for sweeps from other sessions. A custom directory outside normal discovery needs a SessionStart with the updated hook before another session can find it. A running `claude` process without a matching live record suspends session scratch cleanup, including for sessions started before their custom directory was registered. Damaged records, missing or unreadable registered config or sessions directories, and inconclusive process scans also suspend session scratch cleanup. The cutoff is 24 hours by default (`MEGAVIBE_SCRATCH_ORPHAN_HOURS=0` disables the sweep). Old, unopened numbered pytest run directories under the system temp's `pytest-of-<user>` directory are removed as a class because they are test fixtures by construction.

When a low-space warning appears at session start or after compaction, its footprint line shows how much used space on the boot volume is attributable to Megavibe. Run `~/.megavibe/scripts/disk-watch.sh footprint` to get the same estimate on demand. If a project is on another volume, the Megavibe launcher can place its session scratch on that volume.

## Trash review

**Trash review:** every trashed item is recorded. The hook speaks at 1024 MB unreviewed, or at 100 MB when an unreviewed item is older than seven days. Explicit attendance overrides payload and entrypoint inference. Unattended runs leave the stamp alone, and notices appear at most once per due state on this machine. If the user is present when `trash-watch.sh` says a review is due, follow its steps the same turn — a Haiku agent groups the items, AskUserQuestion asks per group (restore / keep / back up / mark droppable), `trash-review.py group` + `apply` carry it out. Nothing in it deletes: droppable items stay in the Trash for the user to empty. The review steps are printed by `trash-watch.sh` itself when a review is due; freeing what the review marked droppable follows the protocol's rule on the emptying script.
