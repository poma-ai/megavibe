---
name: prune-context
description: Selectively prune redundant lines from .agent/FULL_CONTEXT.md via AI (Gemini/Codex). Use when FULL_CONTEXT.md has grown large (500+ lines). Distinct from /compact (Claude Code built-in, which summarizes the live conversation).
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Glob
---

# Prune FULL_CONTEXT.md (selective line removal)

> **Not to be confused with `/compact`.** `/compact` is Claude Code's built-in conversation summarizer. `/prune-context` removes redundant lines from the durable `.agent/FULL_CONTEXT.md` log. See the "Which compaction do I need?" table in `CLAUDE.md`.

Use Gemini (or the standard fallback chain) to surgically remove redundant lines from `.agent/FULL_CONTEXT.md` while preserving all important context.

## Prerequisites

- At least one backend must be available. Try in order: Gemini MCP → `$GEMINI_API_KEY` curl → Codex MCP → Claude subagent (last resort)
- FULL_CONTEXT.md should be large enough to warrant compaction (500+ lines)
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
   --- Compacted on YYYY-MM-DD: removed N lines (Gemini-selected) ---
   ```

6. **Report results** to the user: how many lines before, how many removed, how many remain.

## Rules

- This is a **rare operation**. Most projects will never need it.
- NEVER compact without an AI backend — human judgment is too lossy. Use the standard fallback chain.
- NEVER delete the archive until the user confirms the compaction looks good.
- If in doubt about whether to remove a line, keep it.
