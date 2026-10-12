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
# Then, on a Bash command that mentions kubectl, gcloud, kubeseal or helm:
#   1. runs KUBE_TOKEN_KEEPER when KUBE_TOKEN_FILE is missing or older than MAX_AGE
#   2. puts `export CLOUDSDK_AUTH_ACCESS_TOKEN_FILE='<token file>'` on a line in
#      front of the command. gcloud reads it; kubectl reaches it through the GKE
#      credential plugin. The command itself is not changed.
#
# gcloud was the gap that made this look broken. The keeper mints a `ya29.`
# Google OAuth access token, which is exactly what `gcloud --access-token-file`
# consumes — but the hook only ever rewrote kubectl, so every `gcloud` call
# still hit the reauth wall. Measured in ~/dev/poma-on-prem's own logs: 74
# occurrences of the model telling the user to run `gcloud auth login`, and 32
# of "cannot prompt during non-interactive execution", while a usable token sat
# in the keeper's file.
#
# A command that mentions gcloud, `auth` and a login verb (login,
# activate-service-account, application-default) gets no token: a login is the
# one command that fixes a genuine expiry, and it must not be shadowed by the
# token it replaces.
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

printf '%s' "$COMMAND" | grep -Eq '(^|[^[:alnum:]_-])(kubectl|gcloud|kubeseal|helm)([^[:alnum:]_-]|$)' || exit 0
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

# --- 2. hand the token over through gcloud's own configuration -------------
# Nothing inside the command is rewritten. One line in front of it exports
# CLOUDSDK_AUTH_ACCESS_TOKEN_FILE (the auth/access_token_file property). gcloud
# reads it directly, and kubectl gets it too: the GKE credential plugin
# (gke-gcloud-auth-plugin) asks `gcloud config config-helper` for a token,
# which honours the property. Verified 2026-10-12 against a GKE cluster:
# kubectl, kubectl auth whoami, kubeseal --fetch-cert and gcloud all work with
# only this variable, and all fail at the reauth wall without it. A kubectl
# started by a script or `bash -c` inherits it; one run over ssh does not.
#
# Why not rewrite the command: putting --token=... next to each `kubectl` needs a
# shell parser. It rewrote heredoc bodies written to files, and two parser
# attempts failed review on new edge cases; a generated kubeconfig layered in
# front of the user's absorbed `kubectl config use-context` and `get-credentials`
# writes. An exported path touches neither the command nor any config file.
#
# An explicit --token or --access-token-file in the command still wins over the
# property, so they need no special case.
printf '%s' "$COMMAND" | grep -Eq '(^|[^[:alnum:]_-])(kubectl|gcloud|kubeseal|helm)([^[:alnum:]_-]|$)' || exit 0
# A login must not run with the token it is meant to replace: with the property
# set, gcloud would pick the token file over the account being logged in. Word
# level and deliberately broad (any flags, `beta`, quoting, continuations): a
# command that mentions gcloud, `auth` and a login verb gets no token at all.
w() { printf '%s' "$COMMAND" | grep -Eq "(^|[^[:alnum:]_-])$1([^[:alnum:]_-]|\$)"; }
if w gcloud && w auth && { w login || w activate-service-account || w application-default; }; then
  exit 0
fi
# A relative path is resolved the way step 1 checked it: from this directory.
case "$KUBE_TOKEN_FILE" in /*) TOKEN_PATH="$KUBE_TOKEN_FILE" ;; *) TOKEN_PATH="$PWD/$KUBE_TOKEN_FILE" ;; esac
case "$TOKEN_PATH" in *"'"*) exit 0 ;; esac   # cannot be single-quoted safely
# Only the token FILE's path is exported, never the token. The command stays
# byte for byte as written, below the prefix line.
NEW_CMD="export CLOUDSDK_AUTH_ACCESS_TOKEN_FILE='$TOKEN_PATH'
$COMMAND"

printf '%s' "$INPUT" | jq -c --arg cmd "$NEW_CMD" \
  --arg ctx "[megavibe cloud-token] kubectl/gcloud are carrying a freshly minted token. Do NOT tell the user to run gcloud auth login or any interactive cloud login for this — the keeper handles it. If a command still fails on auth, say so plainly rather than falling back to asking for a login." \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {command: $cmd}), additionalContext: $ctx}}'
exit 0
