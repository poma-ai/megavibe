#!/bin/bash
# DO NOT use set -e — hook must be resilient.
_hook_error() {
  echo "kube-token.sh failed at line $1: $2" >> "${HOME:-/tmp}/.megavibe/hook-errors.log" 2>/dev/null || true
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — kubectl carries a freshly minted token, so a non-interactive session
# never has to ask a human to log in.
#
# The problem this solves: many orgs enforce a re-auth policy (Google Cloud RAPT,
# AWS SSO, Okta-fronted OIDC) that refuses to refresh credentials outside an
# interactive terminal. `kubectl` then dies with something like
# "Reauthentication failed. cannot prompt during non-interactive execution",
# roughly hourly. The usual workaround is a small keeper script that mints a
# short-lived bearer token to a file. That works — but only if the agent
# REMEMBERS it exists. Measured in one real setup: 19 occurrences of the model
# telling its user to run an interactive login, across 18 transcripts in 9
# projects, while the keeper sat one command away. A hook cannot forget.
#
# Configure it (nothing here is org-specific; the hook is inert until you do):
#   ~/.megavibe/personal/kube-token.conf   — sourced if present
#     KUBE_TOKEN_FILE=/path/the/keeper/writes
#     KUBE_TOKEN_KEEPER='cd ~/path && python3 mint_token.py --no-check'
#     KUBE_TOKEN_MAX_AGE=3000        # optional, seconds; default 3000 (50 min)
#   or export the same three as environment variables.
#
# Then, on a Bash command with `kubectl` in command position and no --token of
# its own, this hook:
#   1. runs KUBE_TOKEN_KEEPER when KUBE_TOKEN_FILE is missing or older than MAX_AGE
#   2. rewrites `kubectl` -> `kubectl --token="$(cat $KUBE_TOKEN_FILE)"`
#
# The token is injected as a command substitution — never as a shell variable
# (zsh does not word-split, and a token held in a variable leaked once), and
# never into the model's context. Only `kubectl` in command position is touched:
# a quoted mention, a `grep kubectl`, and a command that already passes --token
# are all left alone.
#
# Triggered by: PreToolUse (Bash). Exit 0 always.

CONF="$HOME/.megavibe/personal/kube-token.conf"
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
KUBE_TOKEN_FILE="${KUBE_TOKEN_FILE:-}"
KUBE_TOKEN_KEEPER="${KUBE_TOKEN_KEEPER:-}"
KUBE_TOKEN_MAX_AGE="${KUBE_TOKEN_MAX_AGE:-3000}"
[ -n "$KUBE_TOKEN_FILE" ] || exit 0
[ -n "$KUBE_TOKEN_KEEPER" ] || exit 0

command -v jq &>/dev/null || exit 0
command -v python3 &>/dev/null || exit 0

INPUT=$(cat 2>/dev/null || echo "")
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL" = "Bash" ] || exit 0
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$COMMAND" ] || exit 0

printf '%s' "$COMMAND" | grep -Eq '(^|[^[:alnum:]_-])kubectl([^[:alnum:]_-]|$)' || exit 0
printf '%s' "$COMMAND" | grep -q -- '--token' && exit 0
# Never recurse into the keeper's own invocation.
case "$COMMAND" in *"$KUBE_TOKEN_KEEPER"*) exit 0 ;; esac

# --- 1. keep the token fresh -------------------------------------------------
NEED=1
if [ -f "$KUBE_TOKEN_FILE" ]; then
  MTIME=$(stat -f %m "$KUBE_TOKEN_FILE" 2>/dev/null || stat -c %Y "$KUBE_TOKEN_FILE" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - MTIME )) -lt "$KUBE_TOKEN_MAX_AGE" ] && NEED=0
fi
if [ "$NEED" = "1" ]; then
  ( eval "$KUBE_TOKEN_KEEPER" ) >/dev/null 2>&1 &
  KPID=$!
  for _ in $(seq 1 60); do kill -0 "$KPID" 2>/dev/null || break; sleep 1; done
  kill -9 "$KPID" 2>/dev/null || true
  wait "$KPID" 2>/dev/null || true
fi
[ -s "$KUBE_TOKEN_FILE" ] || exit 0

# --- 2. rewrite kubectl in command position ----------------------------------
TMPOUT=$(mktemp -t mv-kubetoken) || exit 0
trap 'rm -f "$TMPOUT" 2>/dev/null' EXIT
MV_CMD="$COMMAND" TOKEN_FILE="$KUBE_TOKEN_FILE" python3 - > "$TMPOUT" 2>/dev/null <<'PY'
import os, re, sys
src = os.environ.get("MV_CMD", "")
inject = 'kubectl --token="$(cat %s)"' % os.environ["TOKEN_FILE"]
pat = re.compile(r'(^|[|;&(]\s*|\$\(\s*|(?<=\n))(\s*)(kubectl)(?=\s|$)')
spans = []
for m in pat.finditer(src):
    before = src[:m.start(3)]
    # skip anything sitting inside an open quote
    if before.count("'") % 2 == 1 or (before.count('"') - before.count('\\"')) % 2 == 1:
        continue
    spans.append((m.start(3), m.end(3)))
if not spans:
    sys.stdout.write(src); raise SystemExit
out, last = [], 0
for s, e in spans:
    out.append(src[last:s]); out.append(inject); last = e
out.append(src[last:])
sys.stdout.write("".join(out))
PY
NEW_CMD=$(cat "$TMPOUT" 2>/dev/null)
[ -n "$NEW_CMD" ] || exit 0
[ "$NEW_CMD" != "$COMMAND" ] || exit 0

printf '%s' "$INPUT" | jq -c --arg cmd "$NEW_CMD" \
  --arg ctx "[megavibe kube-token] kubectl is carrying a freshly minted token. Do NOT tell the user to run an interactive cloud login for this — the keeper handles it." \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {command: $cmd}), additionalContext: $ctx}}'
exit 0
