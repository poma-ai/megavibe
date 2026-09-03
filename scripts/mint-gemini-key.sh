#!/usr/bin/env bash
# Mint a Gemini API "auth key" programmatically — no AI Studio clicking.
#
# Why this exists:
#   - Google retired Gemini CLI OAuth (2026-06-18) → megavibe needs an API key.
#   - AI Studio's UI attaches keys to whatever project you pick; you cannot
#     detach billing from a project that has it (e.g. a prod project), so an
#     ambient key on a billing-enabled project silently BILLS every call.
#   - Fix: a dedicated project with NO billing account → free tier only, which
#     hard-429s instead of billing. megavibe's fallback chain absorbs the 429.
#   - "Standard" API keys are rejected by the Gemini API from September 2026;
#     keys bound to a service account ("auth keys") are the supported kind.
#     `gcloud services api-keys create --service-account=...` mints exactly that.
#
# Data treatment: run this while authed as a Google Workspace enterprise
# account and the key inherits Paid-Service treatment per Google's Gemini API
# terms (prompts NOT used for training) even on free quota.
#
# Usage:
#   gcloud auth login                       # once, interactively
#   bash scripts/mint-gemini-key.sh [--project ID] [--write-rc] [--quiet-key]
#
# Prints only a key prefix + length, never the whole key. --write-rc appends
# the key to your shell profile; otherwise the key lands in a 0600 temp file
# whose path is printed.

set -euo pipefail

PROJECT=""
WRITE_RC=0
SA_NAME="megavibe-gemini"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)   PROJECT="$2"; shift 2 ;;
    --write-rc)  WRITE_RC=1; shift ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *)           echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

die()  { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }

command -v gcloud &>/dev/null || die "gcloud not found (brew install --cask google-cloud-sdk)"

# Credentials: requires a live gcloud login. Never loop retrying auth — a stale
# credential is not going to fix itself while we hammer the API.
if ! gcloud projects list --limit=1 &>/dev/null; then
  die "gcloud credentials are stale or absent. Run:  gcloud auth login"
fi

ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "")
[ -n "$ACCOUNT" ] && note "account: $ACCOUNT"

# ─── Project: dedicated, billing-less ───────────────────────────────
if [ -z "$PROJECT" ]; then
  PROJECT="mv-gemini-$(date +%Y%m%d%H%M%S)"
fi

if gcloud projects describe "$PROJECT" &>/dev/null; then
  note "project $PROJECT exists — reusing"
else
  note "creating project $PROJECT (no billing account will be attached)"
  gcloud projects create "$PROJECT" --name="megavibe gemini" >/dev/null \
    || die "project creation failed (org policy may require a folder/billing — pass --project with an existing billing-LESS project)"
fi

# Refuse to mint an ambient key on a billing-enabled project: that is the exact
# silent-spend footgun this script exists to avoid.
BILLING=$(gcloud billing projects describe "$PROJECT" --format='value(billingEnabled)' 2>/dev/null || echo "unknown")
case "$BILLING" in
  True|true)
    die "project $PROJECT HAS billing enabled — refusing (every call would bill). Use a billing-less project." ;;
  unknown)
    note "billing status unverifiable (no billing API access) — continuing; verify manually" ;;
  *)
    note "billing: not enabled (free tier only — calls 429 instead of billing)" ;;
esac

# ─── APIs ───────────────────────────────────────────────────────────
for api in apikeys.googleapis.com generativelanguage.googleapis.com; do
  if gcloud services list --enabled --project "$PROJECT" --format='value(config.name)' 2>/dev/null | grep -qx "$api"; then
    note "api enabled already: $api"
  else
    note "enabling $api"
    gcloud services enable "$api" --project "$PROJECT" >/dev/null \
      || die "could not enable $api (some APIs require billing; check org policy)"
  fi
done

# ─── Service account (auth keys bind to one) ────────────────────────
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
if gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT" &>/dev/null; then
  note "service account exists: $SA_EMAIL"
else
  note "creating service account $SA_NAME"
  gcloud iam service-accounts create "$SA_NAME" \
    --project "$PROJECT" --display-name="megavibe Gemini backend" >/dev/null
fi

# ─── The auth key, restricted to the Gemini API only ────────────────
note "minting auth key (restricted to generativelanguage.googleapis.com)"
# --billing-project is REQUIRED: without it the API Keys call is attributed to
# the credential's own quota project (e.g. the Gemini CLI's), which fails with a
# confusing SERVICE_DISABLED naming a project you never touched.
gcloud services api-keys create \
  --project "$PROJECT" --billing-project "$PROJECT" \
  --display-name="megavibe gemini auth key" \
  --service-account="$SA_EMAIL" \
  --api-target=service=generativelanguage.googleapis.com >/dev/null 2>&1 \
  || die "key creation failed on $PROJECT (needs roles/serviceusage.apiKeysAdmin; re-run with the API Keys API enabled)"

KEY_RESOURCE=$(gcloud services api-keys list --project "$PROJECT" --billing-project "$PROJECT" \
  --format='value(name)' 2>/dev/null | head -1)
[ -n "$KEY_RESOURCE" ] || die "key created but not listable on $PROJECT"

KEY_STRING=$(gcloud services api-keys get-key-string "$KEY_RESOURCE" --billing-project "$PROJECT" --format='value(keyString)')
[ -n "$KEY_STRING" ] || die "key created but key string could not be read: $KEY_RESOURCE"

# Never echo the whole key.
note "key minted: ${KEY_STRING:0:6}…(${#KEY_STRING} chars), sa=$SA_EMAIL"

if [ "$WRITE_RC" -eq 1 ]; then
  RC="$HOME/.bashrc"
  case "$(basename "${SHELL:-bash}")" in
    zsh) RC="$HOME/.zshrc" ;;
    *)   [ -f "$HOME/.bash_profile" ] && RC="$HOME/.bash_profile" ;;
  esac
  if grep -q '^[[:space:]]*export GEMINI_API_KEY=' "$RC" 2>/dev/null; then
    echo ""
    echo "  NOTE: $RC already exports GEMINI_API_KEY — left untouched."
    echo "  Existing keys are often billing-enabled (e.g. a prod project); to swap,"
    echo "  rename the old line (e.g. GEMINI_API_KEY_LEGACY) and add the new key."
    KEYFILE=$(mktemp); chmod 600 "$KEYFILE"; printf '%s\n' "$KEY_STRING" > "$KEYFILE"
    echo "  New key written to: $KEYFILE  (delete it after copying)"
  else
    printf '\nexport GEMINI_API_KEY=%q\n' "$KEY_STRING" >> "$RC"
    note "exported GEMINI_API_KEY in $(basename "$RC") (new terminals pick it up)"
  fi
else
  KEYFILE=$(mktemp); chmod 600 "$KEYFILE"; printf '%s\n' "$KEY_STRING" > "$KEYFILE"
  note "key written to: $KEYFILE  (chmod 600 — delete after copying)"
  note "to export it:  export GEMINI_API_KEY=\$(cat $KEYFILE)"
fi

echo ""
echo "  Done. Project $PROJECT has no billing → free tier (Flash ~1,500 req/day)."
echo "  Revoke anytime:  gcloud services api-keys delete $KEY_RESOURCE"
