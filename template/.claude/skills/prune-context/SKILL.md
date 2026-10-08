---
name: prune-context
description: "SUPERSEDED - do not use on a project that has .agent/snapshot.md or event files; run .claude/hooks/agent-log.sh fold instead (moves old events into the snapshot, loses nothing). Legacy only: selectively prune redundant lines from a hand-maintained .agent/FULL_CONTEXT.md via AI, in the reviewers.sh digest-chain order. Distinct from /compact (Claude Code built-in, which summarizes the live conversation)."
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Glob
---

# Prune FULL_CONTEXT.md (selective line removal)

> **Superseded; legacy projects only.** (`init.sh` creates `.agent/events/` on every run, so that directory alone proves nothing.) If `.agent/snapshot.md` exists or `.agent/events/` holds any `.md` file, this project uses the event log: `FULL_CONTEXT.md` is *rendered* and must never be edited in place (a protocol rule). STOP and tell the user to run `.claude/hooks/agent-log.sh fold` instead. The procedure below applies only to an old project whose `FULL_CONTEXT.md` is still a hand-appended file and which has neither a snapshot nor any event file.

> **Not to be confused with `/compact`.** `/compact` is Claude Code's built-in conversation summarizer. `/prune-context` removes redundant lines from the durable `.agent/FULL_CONTEXT.md` log. See the "Which compaction do I need?" table in `CLAUDE.md`.

Use Codex (or the standard fallback chain) to surgically remove redundant lines from `.agent/FULL_CONTEXT.md` while preserving all important context.

## Prerequisites

- At least one backend must be available. Try in the order `bash ~/.megavibe/scripts/reviewers.sh digest-chain` prints: Codex (`codex-review.sh --effort low`) → Claude subagent, or without Codex capped Gemini (`gemini-review.sh`) → Claude subagent
- FULL_CONTEXT.md is a legacy hand-appended file (no snapshot, no event files) and large enough to warrant compaction (500+ lines)
- The Claude subagent has a 200K token window — for very large logs, it may need to process in chunks

## Steps

1. **Check size.** Read `.agent/FULL_CONTEXT.md` and count lines. If under 500 lines, tell the user it's not worth compacting yet and stop.

2. **Archive the original.** Copy the current file:
   ```
   cp .agent/FULL_CONTEXT.md .agent/LOGS/FULL_CONTEXT.pre-compact.md
   ```

3. **Send to the backend** (using the standard fallback chain) with this prompt:

   > Read this entire context log. Identify lines that are redundant, superseded by later entries, or no longer relevant.
   >
   > Output ONLY the line numbers to remove, grouped by reason.
   >
   > **Preserve:** all decisions, all open task references, all lessons learned, all architectural context.
   > **Remove:** duplicate status updates, resolved issue descriptions, stale progress notes.

4. **Remove only the identified lines.** Use the Edit tool to remove each group of lines the backend identified. Work in reverse order (highest line numbers first) to avoid offset drift.

5. **Append a compaction note** at the end of FULL_CONTEXT.md:
   ```
   --- Compacted on YYYY-MM-DD: removed N lines (AI-selected) ---
   ```

6. **Report results** to the user: how many lines before, how many removed, how many remain.

## Rules

- This is a **rare operation**. Most projects will never need it.
- NEVER compact without an AI backend — human judgment is too lossy. Use the standard fallback chain.
- NEVER delete the archive until the user confirms the compaction looks good.
- If in doubt about whether to remove a line, keep it.
