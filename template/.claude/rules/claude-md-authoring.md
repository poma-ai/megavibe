# CLAUDE.md authoring

Rules for writing or maintaining a project's `CLAUDE.md`. Apply when editing the file, when running `/init`, or when the user asks for documentation cleanup.

## Index, not encyclopedia

`CLAUDE.md` is loaded **eagerly** — every byte enters context the moment a session opens, and stays through every tool call and compaction. Detail in CLAUDE.md is detail you pay for forever.

Push detail out to `README-<topic>.md` files. Those are read **lazily** — only when Claude follows a pointer — so they don't tax the always-on prompt budget.

### Extract into a README when

- Section runs >~30 lines
- Section describes a subsystem in depth (architecture, pipeline, file map)
- Section is a long table (file responsibilities, config matrix, artifact inventory)
- Section duplicates content already covered in another doc

### What stays in CLAUDE.md

- One-paragraph rules — "do this, not that"
- 1–2 footguns per topic — gotchas a contributor would miss without reading the README
- Bold pointers: **`README-<topic>.md`** at the end of each section that has detail elsewhere
- Project-wide invariants: licensing, security boundaries, contract guarantees

### Section pattern

```
## Topic name

Short rule (1–3 lines).

Two gotchas worth keeping in mind even without reading the README:
- Gotcha 1
- Gotcha 2

Full detail: **`README-topic.md`**.
```

## Operating discipline goes ABOVE architecture

Meta-rules about HOW to work the codebase (iteration, debugging, cache use, when not to re-run, expensive-operation discipline) come BEFORE architecture descriptions. Architecture is reference; operating rules are the entry point. New contributors and AI agents both need the working rules first.

If the project has expensive operations, long-running pipelines, or non-obvious iteration patterns, lead the file with those constraints — even before "Architecture".

## Don't duplicate the protocol

Generic rules (verification, `.agent/` writes, second opinions, doc hygiene, fallback chains) live in the megavibe protocol at `~/.claude/CLAUDE.md`. Project `CLAUDE.md` exists for **project-specific** conventions only.

If a rule would apply to any project, it belongs in the protocol, not here. When you find such a rule sitting in a project CLAUDE.md, propose lifting it to the protocol and stripping the project-level copy.
