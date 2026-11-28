---
name: compaction-lifecycle
description: Compaction mechanics. Load before running compact-readiness.sh or agent-log.sh fold, when a pre-compact, post-compact or context-size hook message needs interpreting, and when choosing between /compact, /rehydrate and fold. Holds the readiness check with its --mark step, the compaction hooks, the proactive nudges, the context watcher and the which-compaction table. The close-out and post-compact recovery rules themselves stay in the protocol.
---

# Compaction lifecycle: mechanics

The rules (save and continue at context pressure, recover after a compaction) are in the protocol, `~/.claude/CLAUDE.md`, "Compaction lifecycle". This skill holds the mechanics behind them.

Hooks support this lifecycle:

**Pre-compact** (PreCompact hook): records the `.agent/` file status and the age of the newest event; where the project has `megavibe-deliverables/STATUS.md`, counts of asks without a file, newer research notes and an over-long `Now` (see Deliverables); and a register-currency warning when `TASKS.md` section 0 carries a date stamp older than seven days (silent unless the project uses that section and stamps it; `MEGAVIBE_REGISTER_MAX_AGE_DAYS`). Its plain stdout, which Claude Code hands the compaction as instructions, is a short fixed list of what to keep (counts and this session's paths, never project-file text); the full report goes to stderr and `.agent/LOGS/pre-compact-alert.*.md`, and the register warning is carried into the post-compact message. It ignores a subagent's compaction.

**Proactive nudge** (only when the context-watcher is OFF): a hook nudges at 🟡 50% / 🟠 75% / 🔴 90% of the model's effective auto-compact threshold (typically ~80% of model context); each tier fires once and the counter resets after a compaction. When the watcher daemon is alive (the default) the nudges suppress entirely. `autoCompactWindow` in `.claude/settings.json` or `$CLAUDE_CODE_AUTO_COMPACT_WINDOW` caps the window.

**Ready to compact?** Advisory: run `.claude/hooks/compact-readiness.sh --session <session-id>` while refreshing the close-out (pass `--session` whenever sessions share the project; without it the script takes `$CLAUDE_CODE_SESSION_ID`, else the one tool-call counter touched in the last 24 hours, and two is ambiguous, exit 2). Exit 0 means no findings in the observed state, 1 means `NOT READY` findings, 2 means unable to check. It never blocks a tool, Stop or compaction. A body line starting with `DECISION:`, `D<number> `, `D<number>:` or `Decided:` asks for reconciliation of both `DECISIONS.md` and `TASKS.md` (backtick-fenced examples are ignored; other decision-like prose is advisory, shown up to `MEGAVIBE_READY_ADVISORY_LIMIT`, default 20); three uncovered events also prompt task reconciliation (`MEGAVIBE_READY_TASKS_MIN_EVENTS`, default 3). After reviewing the events and reconciling both registers, run the same command with `--mark`: it records the reviewed event filenames in `.agent/.registers-checkpoint` (only membership in that list establishes coverage), as your assertion of review: it never certifies readiness or acknowledges pending rows (exit 1 can accompany a successful write). `agent-log.sh fold` refuses uncovered events, so synchronize, review and mark before folding. Pending watcher rows are reported as counts with queue paths only; an ambiguous session alias reports uncertainty (exit 2) and is never assigned. Live running tasks without a heartbeat count as `NOT READY` only when supplied through `--hook-input <JSON_FILE>` (or `-` for stdin); otherwise their coverage is unknown. Full semantics, caps and edge cases: https://github.com/poma-ai/megavibe/blob/main/README-compaction-readiness.md

**Context watcher** (default ON; opt out with `MEGAVIBE_WATCHER=0`): an out-of-band daemon that flushes `.agent/` files on a trickle (every 5 min) directly from the transcript, replacing in-session nudges. Decisions are staged for human review; narrative/lessons/tasks auto-apply under flock. When the watcher is alive, in-session tier nudges suppress. Full detail: **`README-watcher.md`**.

# Which compaction do I need?

| Situation | Command | What it does |
|-----------|---------|--------------|
| User wants to compact the live conversation manually | `/compact` (built-in, optional) | A user MAY run it; otherwise Claude Code compacts automatically |
| After a compaction whose hook reports the working context missing or stale | `/rehydrate` | Rebuilds `WORKING_CONTEXT.md` from `.agent/` + git |
| Session feels stale mid-work | `/rehydrate` | Same |
| `.agent/events/` has accumulated a lot of old entries | `agent-log.sh fold` | Moves entries older than 30 days into `.agent/snapshot.md`. No content is lost (the old event files are removed once copied into the snapshot), and `FULL_CONTEXT.md` renders the same apart from one `registers-fold-cutoff` comment line. It refuses while events are uncovered: review the registers and run `compact-readiness.sh --mark` first. |

Size hints still fire from `on-pre-compact.sh` and from the tier nudges in `log-tool-event.sh` when `FULL_CONTEXT.md` exceeds 500 lines. Treat them as a prompt to `fold`, not to prune.
