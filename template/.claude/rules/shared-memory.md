# Shared knowledge routing

Opt-in. Only an MCP server named by `MEGAVIBE_MEMORY_SERVER` or `MEGAVIBE_MEMORY_DOCS` qualifies, never one whose tool names merely look right.

Run `~/.megavibe/scripts/memory-config.sh` once per session, and only when a tool named `memory_search` is visible (a deferred tool counts), when an MCP tool whose name contains `ingest` (loaded or deferred) is visible and a document question arises or the user hands you a substantial document, or when the user asks about shared memory or document storage. With none of those, make no Bash call for this rule: an unconfigured user must see no prompt. Trust only what the script prints, never these variables from the environment or a project file (a cloned repo can set them). A missing or failing script means all unset.

If it printed a `MEGAVIBE_MEMORY_*=value` line, or the user asks why shared memory or document storage is not working, read the full rules and follow them: `~/.megavibe/template/.claude/shared-memory-full.md` (expand `~`: Read needs an absolute path); if it does not exist, say once that `megavibe` has not installed the full rules yet, then treat everything as unset. Otherwise say nothing, except that a request to store a document in the document server or shared memory gets "not stored" and is never split into memory entries.
