# Deliverables and open decisions

Where a session puts what the user will read, and how it asks for decisions. The user reads a visible folder; they do not dig through `.agent/` or hunt for pages hosted elsewhere.

## The folder

`megavibe-deliverables/` in the project root (created and gitignored by `init.sh`). Clean Markdown or HTML only: a report, a review synthesis, a plan, an analysis the user will rely on. Name files `YYYY-MM-DD-topic.md`. `.agent/` stays the machine-facing log (events, working context, research notes); a deliverable that matters is written to the folder, and `.agent/` may point at it. A hosted page (a claude.ai artifact, a doc) is for sharing with someone else on request, not the default; if you publish one, the folder still carries the source.

## `STATUS.md`: one live file, kept current

Update it whenever the state or a decision changes, in the same turn, not at the end. Shape (the template `init.sh` installs):

- `## Now`: 2–4 lines on what is being worked on, what is done, what is waiting.
- `## Decisions needed`: one `### D<n> · title` block per open decision with `Context:`, `Options:` (lettered), `My default if unanswered:` and an empty `Answer:` line. Numbers are never reused.
- `## Decided`: answered blocks move here with the answer, so nothing is asked twice.

**No open ends inline.** "Your call", "later", "let me know if you want" and "say go" in a reply leave a question nobody tracks. If the user must decide something, it becomes a D-block in `STATUS.md` with options and a default, and the reply says only that it is there. If work can continue, continue on the stated default and say which default you took. If it cannot (destructive, irreversible, or the answer changes what you build), say that it is blocked on D<n>.

## Answers typed into the file

`status-sync.sh` (SessionStart and every prompt) compares the `Answer:` lines under `## Decisions needed` with what the session last saw and injects any new one. Treat it as the user's decision: act on it, record it with `agent-log.sh append`, move the block to `## Decided`. The user may answer several at once, in any order, while you work.
