#!/usr/bin/env bash
# PreToolUse (mcp__codex__codex): pin sandbox + approval policy on every Codex call.
#
# DO NOT use set -e / set -euo pipefail here (architecture decision 13): hooks fire
# on every tool call and must degrade to a no-op, never to an error.
#
# Why: codex mcp-server defaults to approval_policy="on-request". When the model
# wants a command the sandbox blocks, it sends an MCP `elicitation/create` to
# Claude Code, which answers elicitations by asking the human. An elicitation is a
# server-initiated question, not a permission check, so
# --dangerously-skip-permissions does NOT suppress it: the user gets a permission
# prompt in the middle of a review they never asked to approve.
#
# With approval-policy=never Codex never elicits; a command the sandbox blocks
# simply fails. `sandbox` is forced to read-only in the same breath — dropping the
# human veto without pinning the confinement would be the wrong half of the rule
# to enforce, and a caller-supplied `workspace-write` would then run unsupervised.
# Megavibe uses Codex as a read-only reviewer only; a call that genuinely needs to
# write must disable this hook with MEGAVIBE_CODEX_APPROVALS=1 and take the
# approval prompts that come with it.
#
# `codex mcp-server` ignores `-c approval_policy=...` and [projects."..."] entries
# carry no approval policy, so the tool-call argument is the only lever megavibe
# can pull. (A top-level approval_policy in ~/.codex/config.toml also works, but
# that is machine-local and megavibe does not install it.)
#
# Escape hatch: MEGAVIBE_CODEX_APPROVALS=1 leaves the call untouched.

if [ -d "${CLAUDE_PROJECT_DIR:-.}/.agent" ]; then :; else exit 0; fi
command -v jq &>/dev/null || exit 0
if [ "${MEGAVIBE_CODEX_APPROVALS:-0}" = "1" ]; then exit 0; fi

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
if [ "$TOOL" = "mcp__codex__codex" ]; then :; else exit 0; fi

printf '%s' "$INPUT" | jq -c '
  if (.tool_input | type) != "object" then empty
  else .tool_input as $in
    | ($in + {"approval-policy": "never", "sandbox": "read-only"}) as $out
    | if $out == $in then empty
      else {hookSpecificOutput: {
              hookEventName: "PreToolUse",
              updatedInput: $out
            }}
      end
  end' 2>/dev/null || true
exit 0
