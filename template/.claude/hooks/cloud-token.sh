#!/bin/bash
# DO NOT use set -e — hook must be resilient.
_hook_error() {
  echo "cloud-token.sh failed at line $1: $2" >> "${HOME:-/tmp}/.megavibe/hook-errors.log" 2>/dev/null || true
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — kubectl AND gcloud carry a freshly minted token, so a
# non-interactive session never has to ask a human to log in.
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
#   ~/.megavibe/personal/cloud-token.conf  — sourced if present
#   (~/.megavibe/personal/kube-token.conf is still read, for installs that
#    predate the rename)
#     KUBE_TOKEN_FILE=/path/the/keeper/writes
#     KUBE_TOKEN_KEEPER='cd ~/path && python3 mint_token.py --no-check'
#     KUBE_TOKEN_MAX_AGE=3000        # optional, seconds; default 3000 (50 min)
#   or export the same three as environment variables.
#
# Then, on a Bash command that mentions `kubectl` or `gcloud` and passes no
# token flag of its own, this hook:
#   1. runs KUBE_TOKEN_KEEPER when KUBE_TOKEN_FILE is missing or older than MAX_AGE
#   2. puts one line in front of the command that tells kubectl and gcloud where
#      the token is (KUBECONFIG with a tokenFile user, and
#      CLOUDSDK_AUTH_ACCESS_TOKEN_FILE). The command itself is not changed.
#
# gcloud was the gap that made this look broken. The keeper mints a `ya29.`
# Google OAuth access token, which is exactly what `gcloud --access-token-file`
# consumes — but the hook only ever rewrote kubectl, so every `gcloud` call
# still hit the reauth wall. Measured in ~/dev/poma-on-prem's own logs: 74
# occurrences of the model telling the user to run `gcloud auth login`, and 32
# of "cannot prompt during non-interactive execution", while a usable token sat
# in the keeper's file.
#
# A command that mentions `gcloud auth`, `components`, `config` or `init`
# gets no gcloud token: `gcloud auth login` is the one command that fixes a
# genuine expiry, and it must not be shadowed by the token it replaces.
#
# Only the token FILE's path is exported, never the token: it does not enter
# the command text, a shell variable or the model's context (a token held in a
# variable leaked once).
#
# Triggered by: PreToolUse (Bash). Exit 0 always.

for CONF in "$HOME/.megavibe/personal/cloud-token.conf" \
            "$HOME/.megavibe/personal/kube-token.conf"; do
  [ -f "$CONF" ] && { . "$CONF" 2>/dev/null; break; }
done
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

printf '%s' "$COMMAND" | grep -Eq '(^|[^[:alnum:]_-])(kubectl|gcloud)([^[:alnum:]_-]|$)' || exit 0
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

# --- 2. hand the token over through each tool's own configuration -----------
# Nothing inside the command is rewritten. A one-line prefix exports where the
# token is, and kubectl and gcloud read it themselves:
#   gcloud  — CLOUDSDK_AUTH_ACCESS_TOKEN_FILE (the auth/access_token_file
#             property; verified with Cloud SDK, 2026-10-12)
#   kubectl — KUBECONFIG = <generated file>:<your kubeconfig>. The generated file
#             only redefines the GKE users (gke-gcloud-auth-plugin or the old
#             gcp auth-provider) with tokenFile: <token file>; kubeconfig merging
#             takes the first definition of a user, so those users authenticate
#             with the token and everything else comes from your own file.
# The previous design rewrote `kubectl`/`gcloud` words in the command text,
# which needs a shell parser: it rewrote heredoc bodies written to files, and
# two attempts at a parser each failed review on new edge cases. A prefix
# cannot touch a heredoc, a quote or a comment, and it also reaches kubectl run
# by a script or a `bash -c`.

# A caller who passes a token explicitly means it; do not second-guess them.
case "$COMMAND" in *--token*|*--access-token-file*) exit 0 ;; esac
case "$KUBE_TOKEN_FILE" in *"'"*) exit 0 ;; esac   # cannot be quoted safely below

PREFIX=""
if printf '%s' "$COMMAND" | grep -Eq '(^|[^[:alnum:]_-])kubectl([^[:alnum:]_-]|$)'; then
  BASE="${KUBECONFIG:-$HOME/.kube/config}"
  # One generated file per base config: a session with a different KUBECONFIG
  # must not inherit users generated from another one.
  GEN="$HOME/.megavibe/personal/cloud-token.$(printf '%s' "$BASE" | cksum | cut -d' ' -f1).kubeconfig"
  REGEN=0
  [ -s "$GEN" ] || REGEN=1
  grep -qF "$KUBE_TOKEN_FILE" "$GEN" 2>/dev/null || REGEN=1
  OLDIFS=$IFS; IFS=:
  for f in $BASE; do [ -n "$f" ] && [ "$f" -nt "$GEN" ] && REGEN=1; done
  IFS=$OLDIFS
  if [ "$REGEN" = "1" ]; then
    TMPGEN=$(mktemp "$GEN.XXXXXX" 2>/dev/null) || TMPGEN=""
    if [ -n "$TMPGEN" ]; then
      # `command` and an explicit KUBECONFIG: read the user's own config, never
      # one that already includes the generated file.
      KUBECONFIG="$BASE" command kubectl config view --raw -o json 2>/dev/null \
        | TOKEN_FILE="$KUBE_TOKEN_FILE" python3 -c '
import json, os, sys
try:
    cfg = json.load(sys.stdin)
except Exception:
    sys.exit(1)
users = []
for u in cfg.get("users") or []:
    user = u.get("user") or {}
    cmd = os.path.basename(str((user.get("exec") or {}).get("command") or ""))
    prov = (user.get("auth-provider") or {}).get("name")
    if cmd == "gke-gcloud-auth-plugin" or prov == "gcp":
        users.append({"name": u["name"], "user": {"tokenFile": os.environ["TOKEN_FILE"]}})
json.dump({"apiVersion": "v1", "kind": "Config", "users": users}, sys.stdout)
' > "$TMPGEN" 2>/dev/null && chmod 600 "$TMPGEN" && mv -f "$TMPGEN" "$GEN"
      rm -f "$TMPGEN" 2>/dev/null
    fi
  fi
  if grep -q '"tokenFile"' "$GEN" 2>/dev/null; then
    case "$GEN:$BASE" in *"'"*) ;; *) PREFIX="export KUBECONFIG='$GEN:$BASE'; " ;; esac
  fi
fi
# gcloud: not for the commands that manage credentials or config themselves
# (auth, config, components, init), anywhere in the command — a login must not
# be shadowed by the token it is meant to replace.
if printf '%s' "$COMMAND" | grep -Eq '(^|[^[:alnum:]_-])gcloud([^[:alnum:]_-]|$)' \
   && ! printf '%s' "$COMMAND" | grep -Eq 'gcloud[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(auth|config|components|init)([^[:alnum:]_-]|$)'; then
  PREFIX="${PREFIX}export CLOUDSDK_AUTH_ACCESS_TOKEN_FILE='$KUBE_TOKEN_FILE'; "
fi
[ -n "$PREFIX" ] || exit 0
# The prefix on its own line: the command below it stays byte for byte as written.
NEW_CMD="$PREFIX
$COMMAND"

printf '%s' "$INPUT" | jq -c --arg cmd "$NEW_CMD" \
  --arg ctx "[megavibe cloud-token] kubectl/gcloud are carrying a freshly minted token. Do NOT tell the user to run gcloud auth login or any interactive cloud login for this — the keeper handles it. If a command still fails on auth, say so plainly rather than falling back to asking for a login." \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {command: $cmd}), additionalContext: $ctx}}'
exit 0
