# CLAUDE.md — Megavibe Framework

This is the **meta-project**: the multi-agent orchestration framework itself. This CLAUDE.md governs work _on_ megavibe, not work _using_ megavibe (that's in `~/.claude/CLAUDE.md`).

## Project identity

Megavibe is a bootstrapper + protocol for AI-assisted development. It is NOT a software application — it's config, shell scripts, and markdown that get deployed _onto_ other projects. The core thesis: externalize all context to files, regenerate working context from the full log via AI subcontractors (Gemini or Codex, with automatic fallback), never rely on lossy compaction.

**There is no build step, no test suite, no package.json.** Verification is manual: run the scripts, inspect the output, confirm idempotency.

## File map

| File | Purpose | Change risk |
|------|---------|-------------|
| `megavibe` | CLI wrapper — setup + init + launch Claude | High — primary entry point |
| `install.sh` | One-command cross-platform install (`curl \| bash`) | Medium — bootstrap only |
| `setup.sh` | One-time machine bootstrapper (tools, MCP, CLI, protocol) | High — affects all users |
| `init.sh` | Per-project bootstrapper (.agent/, hooks, skills, settings) | High — affects all projects |
| `poma_memory.py` | Bundled poma-memory: markdown chunker + hybrid search + MCP server | Medium — search behavior |
| `telegram-bot.py` | Megavibe Remote v4: personal assistant + project session launcher via TG | Medium — remote access |
| `template/CLAUDE.md` | Core protocol (90 lines) — installed to `~/.claude/CLAUDE.md` | Critical — review required |
| `template/.claude/rules/spinouts.md` | Subtask spinout protocol | Medium — review recommended |
| `template/.claude/rules/delegation.md` | Tool routing + delegation protocols + selective compaction | Medium — review recommended |
| `template/.claude/skills/*/SKILL.md` | Slash command skills (rehydrate, catchup, compact-context) | Low — workflow shortcuts |
| `template/statusline.sh` | Context usage progress bar | Low |
| `template/.claude/settings.json` | Hook registrations template | Medium — when hooks change |
| `template/.claude/hooks/*.sh` | Hook scripts template (6 hooks incl. augment-search.sh) | Medium |
| `template/.claude/agents/summarizer.md` | Last-resort fallback agent (sonnet) | Low — rarely changes |
| `.claude/hooks/*.sh` | Live hooks for THIS repo (copied from template) | Should mirror template |
| `.claude/rules/*.md` | Live rules for THIS repo (copied from template) | Should mirror template |
| `.claude/agents/*.md` | Live agents for THIS repo (copied from template) | Should mirror template |
| `.agent/` | Live context for developing megavibe itself | Continuous |
| `README.md` | Full documentation | When features change |

## Critical invariants

1. **Idempotency is sacred.** Both `setup.sh` and `init.sh` must be safe to re-run. Every create/copy/install checks before writing. Test by running twice — second run must show all "skip" messages.

2. **Marker-based dedup and update.** `<!-- megavibe-v3 -->` and `<!-- /megavibe-v3 -->` bracket the protocol block in `template/CLAUDE.md`. The start marker prevents duplicate installs; the end marker enables `setup.sh` to surgically replace the block on re-run. Never remove or rename either marker. If bumping to v4, update both markers AND the grep patterns in `setup.sh`.

3. **Hook safety guards.** Every hook script must:
   - `[ -d ".agent" ] || exit 0` — no-op outside megavibe projects
   - `command -v jq &>/dev/null || exit 0` — graceful without jq
   - Never block Claude over infra issues (exit 0, not exit 2)
   - Exception: `block-dangerous-bash.sh` exits 2 intentionally

4. **Template/live parity.** `template/.claude/` and the repo's own `.claude/` should stay in sync. After editing a template hook, run `bash init.sh .` to sync the live copy.

5. **No project CLAUDE.md in template.** `init.sh` never touches a project's `CLAUDE.md`. The protocol lives user-level. Project CLAUDE.md is the user's domain.

## Verification protocol

Before committing changes to scripts or hooks:

```bash
# 1. Idempotency: run init.sh twice on a temp project
mkdir -p /tmp/mv-test && bash init.sh /tmp/mv-test
bash init.sh /tmp/mv-test  # hooks "synced", .agent/ files "skip"

# 2. Hook executability
ls -la /tmp/mv-test/.claude/hooks/*.sh  # all -rwxr-xr-x

# 3. Settings merge: pre-existing settings.json preserved
mkdir -p /tmp/mv-test2/.claude
echo '{"permissions":{"allow":["Read"]}}' > /tmp/mv-test2/.claude/settings.json
bash init.sh /tmp/mv-test2
# verify both original permissions AND megavibe hooks present

# 4. Marker detection
grep "megavibe-v3" ~/.claude/CLAUDE.md

# 5. Hook isolation: no-ops without .agent/
cd /tmp && echo '{}' | /path/to/hooks/log-tool-event.sh  # exits silently
```

For hook logic changes, test the specific scenario (counter nudge at 15 calls, rehydration flag set/clear, on-compact JSON output with special characters).

```bash
# 6. Update propagation: just re-run the scripts
bash setup.sh                 # always updates protocol + statusline
bash init.sh /path/to/project # always syncs hooks from template
```

## Shell scripting conventions

- `set -euo pipefail` at top of every script
- `$()` not backticks; `"$VAR"` not `$VAR`
- `[[ ]]` for bash conditionals
- `jq` for JSON — never grep/sed on JSON
- Hooks must be fast (they fire on EVERY tool call). No network requests, no expensive ops.

## Protocol / template changes require second opinion

Changes to `template/CLAUDE.md` affect every downstream project. Before modifying:

1. **Ask Gemini to review** the proposed change:
   - What could break for existing users?
   - Does it conflict with Claude Code built-in behavior?
   - Is the instruction clear enough that Claude will follow it?
2. **Test with a real project.** Apply the updated protocol, run a non-trivial task, confirm Claude follows the new rules.
3. **Update README.md** to reflect protocol changes.

For hook changes, ask Gemini to review for edge cases (missing files, race conditions, unexpected input, shell quoting).

## Subcontractor model routing

| Scenario | Route | Why |
|----------|-------|-----|
| Reviewing protocol text changes | Gemini | Large context, assesses clarity |
| Reviewing hook shell scripts | Gemini | Reasons about edge cases |
| Researching CLAUDE.md best practices, Claude Code features | Web search / Codex | Needs current community info |
| Comparing megavibe to alternatives | Gemini or Codex | Second opinion on architecture |
| README edits, prose polish, small script fixes | Handle directly | Not worth delegation overhead |

## Architecture decisions

| Decision | Rationale |
|----------|-----------|
| `.agent/` files, not Mem0 | Megavibe's `.agent/` + Claude Code's built-in auto-memory (`~/.claude/projects/.../memory/`) cover project + cross-session context. Mem0 would be a third layer with SaaS dependency, free-tier limits, and known bugs. |
| No swarms/antfarm | ~10 files of shell + markdown. Single-agent Claude is sufficient. Swarms add git worktree coordination for zero benefit at this scale. |
| Gemini for re-hydration (Codex as fallback) | Larger context window than Claude subagents for digesting full `.agent/FULL_CONTEXT.md`. Cheaper for read-heavy tasks via MCP. Codex falls back when Gemini is geo-blocked. |
| User-level protocol, project-level hooks | Protocol in `~/.claude/CLAUDE.md` = one source of truth everywhere. Hooks in `.claude/settings.json` = project-scoped, interact with local `.agent/`. |
| No Context7 / Sequential Thinking MCP | No external library deps (pure shell + markdown). The Explore→Plan→Implement→Verify workflow already provides structured reasoning. |
| No claude-mem plugin | Built-in auto-memory + `.agent/` files already provide durable cross-session context. claude-mem adds value for very long projects but isn't needed for this small framework. |

## Subagent usage

- **`Explore`**: Trace hook interaction flows end-to-end, deep-dive into event chains
- **`Plan`**: Before multi-file changes (e.g., adding a new hook type)
- **`general-purpose`**: Web research on Claude Code features, hook API changes, community practices
- **Gemini MCP**: Protocol text review, reviewing full README for consistency

Don't use subagents for: single-file edits, README tweaks, reading one script.

## Future development vectors

These are NOT currently implemented but are worth considering as megavibe evolves:

- ~~**Skills (`.claude/skills/`)**~~: **Done.** Three skills: `/rehydrate`, `/catchup`, `/compact-context`. Deployed by init.sh.
- ~~**Scoped rules (`.claude/rules/*.md`)**~~: **Done.** Protocol split into core (90 lines in CLAUDE.md) + rules (spinouts.md, delegation.md). Deployed by init.sh.
- ~~**`CLAUDE.local.md`**~~: **Done.** Auto-gitignored personal overrides. Created by init.sh, added to .gitignore.
- **PreToolUse input modification** (v2.0.10+): Hooks can now modify tool inputs, not just block. Could enable transparent sandboxing or convention enforcement.
- **Custom subagents** (`.claude/agents/`): A review subagent with `model: haiku` could cheaply validate hook scripts before committing.

## Known gotchas

- `init.sh` settings merge uses `jq -s` with reduce — fragile if template `settings.json` structure changes. Always test the merge path.
- `on-compact.sh` builds JSON via `jq -Rs` — escaping is delicate. Test with content containing quotes, newlines, special chars.
- `log-tool-event.sh` counter resets on ANY write to `.agent/*.md`. By design (prefers low false-negatives over precision).
- Parent directory `../CLAUDE.md` may contain Megavibe v2 rules. Claude Code walks up for CLAUDE.md files — v2 and v3 rules could conflict.
