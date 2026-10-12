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
# still hit the reauth wall. Measured in one real project's logs: 74
# occurrences of the model telling the user to run `gcloud auth login`, and 32
# of "cannot prompt during non-interactive execution", while a usable token sat
# in the keeper's file.
#
# A command running `gcloud auth|config|components|init` gets no token: a login
# is the one command that fixes a genuine expiry and must not be shadowed by the
# token it replaces, and the other credential commands need the stored accounts.
#
# Only the token FILE's path is exported, never the token: it does not enter
# the command text, a shell variable or the model's context (a token held in a
# variable leaked once).
#
# Triggered by: PreToolUse (Bash). Exit 0 always.

for CONF in "${HOME:-}/.megavibe/personal/cloud-token.conf" \
            "${HOME:-}/.megavibe/personal/kube-token.conf"; do
  [ -f "$CONF" ] && { . "$CONF" 2>/dev/null; break; }
done
KUBE_TOKEN_FILE="${KUBE_TOKEN_FILE:-}"
KUBE_TOKEN_KEEPER="${KUBE_TOKEN_KEEPER:-}"
KUBE_TOKEN_MAX_AGE="${KUBE_TOKEN_MAX_AGE:-3000}"
case "$KUBE_TOKEN_MAX_AGE" in ''|*[!0-9]*) KUBE_TOKEN_MAX_AGE=3000 ;; esac
KUBE_TOKEN_MAX_AGE=$((10#$KUBE_TOKEN_MAX_AGE))   # decimal: "08" is not octal
[ -n "$KUBE_TOKEN_FILE" ] || exit 0
[ -n "$KUBE_TOKEN_KEEPER" ] || exit 0

command -v jq &>/dev/null || exit 0

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
# The keeper may have failed: a token that is still stale would only turn the
# reauth wall into a 401 that shadows whatever credentials the user has. Ten
# minutes of grace over MAX_AGE, then hand nothing over.
MTIME=$(stat -f %m "$KUBE_TOKEN_FILE" 2>/dev/null || stat -c %Y "$KUBE_TOKEN_FILE" 2>/dev/null || echo 0)
if [ $(( $(date +%s) - MTIME )) -ge $(( KUBE_TOKEN_MAX_AGE + 600 )) ]; then
  printf '%s' "$INPUT" | jq -c '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: "[megavibe cloud-token] The token keeper could not refresh the token, so none was handed over. If this command fails on auth, say plainly that the keeper failed; do not send the user to an interactive login."}}' 2>/dev/null || true
  exit 0
fi

# --- 2. hand the token over through gcloud's own configuration -------------
# Nothing inside the command is rewritten. One line in front of it exports
# CLOUDSDK_AUTH_ACCESS_TOKEN_FILE (the auth/access_token_file property). gcloud
# reads it directly, and kubectl gets it too: the GKE credential plugin
# (gke-gcloud-auth-plugin) asks `gcloud config config-helper` for a token,
# which honours the property. Verified 2026-10-12 against a GKE cluster:
# kubectl, kubectl auth whoami, kubeseal --fetch-cert and gcloud all work with
# only this variable, and all fail at the reauth wall without it. A kubectl
# started by a script or `bash -c` from a command that mentions one of the
# tools inherits it; a script whose command line names none of them, `sudo`,
# `env -i` and ssh do not. Only GKE credentials go through gcloud: EKS/OIDC
# kube contexts and other tools' application-default credentials are untouched.
#
# Why not rewrite the command: putting --token=... next to each `kubectl` needs a
# shell parser. It rewrote heredoc bodies written to files, and two parser
# attempts failed review on new edge cases; a generated kubeconfig layered in
# front of the user's absorbed `kubectl config use-context` and `get-credentials`
# writes. An exported path touches neither the command nor any config file.
#
# An explicit --token or --access-token-file in the command still wins over the
# property, so they need no special case.
#
# gcloud's own credential and configuration commands get no token: with the
# property set gcloud uses the token file instead of the stored accounts, so a
# login would be shadowed by the token it replaces, `auth revoke` would not
# revoke, and `print-identity-token`/`print-access-token <account>` would answer
# for the wrong identity. The same goes for a command that picks its own
# identity (--account, --configuration, --credential-file-override,
# CLOUDSDK_CORE_ACCOUNT, CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE,
# CLOUDSDK_ACTIVE_CONFIG_NAME, CLOUDSDK_CONFIG=).
#
# FAIL-CLOSED, by word co-occurrence, not by gcloud's grammar. Here a missed
# credential command runs with the keeper's identity, while a false skip only
# means no token (the behaviour before this hook). Matching gcloud's command
# structure missed some spelling in every review round (quoted words, `a\uth`,
# redirections glued to gcloud, flags with values), so the check does not look
# at structure at all: after joining line continuations and deleting every
# quote and backslash, a command that contains the word `gcloud` AND any of the
# words auth, config, components, init, or an identity selector, gets no token.
# Over-skips by design (e.g. `gcloud ... ; kubectl logs deploy/auth`); then the
# agent is told to run the cluster command separately. Not recognisable
# statically: a group held in a variable (`gcloud $G`), which still gets it.
NORM=$(printf '%s' "$COMMAND" | python3 -c '
import sys
sys.stdout.write(sys.stdin.read().replace("\\\n", "").replace("\x27", "").replace("\"", "").replace("\\", ""))
' 2>/dev/null) || NORM=""
# Without python (or if it fails): the same in sed + tr.
# ($!{N;ba} keeps a single line: BSD sed's bare N discards it at end of input.)
[ -n "$NORM" ] || NORM=$(printf '%s' "$COMMAND" | sed -e ':a' -e '$!{N;ba' -e '}' -e 's/\\\n//g' 2>/dev/null | tr -d "\"'\\\\") || NORM=""
has() { printf '%s' "$NORM" | grep -Eq "(^|[^[:alnum:]_])($1)([^[:alnum:]_]|\$)"; }
# The CLOUDSDK_* identity variables count even without the word gcloud: they
# also steer the GKE plugin's call to gcloud (`env CLOUDSDK_CORE_ACCOUNT=x kubectl`).
# With gcloud in the command, ANSI-C or locale quoting ($'...', $"...) also
# skips (it can spell any word), and so does --flags-file, which can carry an
# --account the command line does not show.
#
# Scope: this guards against honest mistakes (a login, a revoke or an explicit
# account running under the keeper's token), not against a command built to get
# past it. Any command the agent runs can read the token file directly, so a
# deliberately obfuscated spelling (a group or the gcloud name assembled from
# variables, globs, brace or command expansion) crosses no boundary; recognising
# every one would need a shell, and the attempts to approximate one cost the
# ordinary commands their token.
SKIP=0
[ -n "$NORM" ] || SKIP=1      # could not normalise: fail closed
printf '%s' "$NORM" | grep -Eq 'CLOUDSDK_(CORE_ACCOUNT|AUTH_CREDENTIAL_FILE_OVERRIDE|ACTIVE_CONFIG_NAME|CONFIG|AUTH_ACCESS_TOKEN|AUTH_IMPERSONATE_SERVICE_ACCOUNT)([^_[:alnum:]]|$)' && SKIP=1
if has gcloud; then
  has 'auth|config|components|init' && SKIP=1
  printf '%s' "$NORM" | grep -Eq -- '--account|--configuration|--credential-file-override|--impersonate-service-account|--flags-file' && SKIP=1
  printf '%s' "$COMMAND" | grep -Eq '\$['"'"'"]' && SKIP=1
fi
if [ "$SKIP" = "1" ]; then
  printf '%s' "$INPUT" | jq -c '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: "[megavibe cloud-token] No token was handed over for this command: it contains gcloud together with a credential/configuration word (auth, config, components, init, also inside names or paths), an account/configuration/impersonation choice or $'...' quoting, or a CLOUDSDK_* identity variable. If it fails on auth, run the cluster or gcloud command as its own Bash call without those words (a kubectl call without gcloud in it always gets the token); otherwise report the failure plainly."}}' 2>/dev/null || true
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
  --arg ctx "[megavibe cloud-token] gcloud and GKE kubectl in this command get a freshly minted token (CLOUDSDK_AUTH_ACCESS_TOKEN_FILE). Do NOT tell the user to run gcloud auth login or any interactive cloud login for this — the keeper handles it. If a command still fails on auth, say so plainly rather than falling back to asking for a login." \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {command: $cmd}), additionalContext: $ctx}}'
exit 0
