#!/usr/bin/env bash
# Mint a Gemini API "auth key" programmatically — no AI Studio clicking.
#
# What this is for (2026-09): an ADMIN minting keys for megavibe / Megawork
# users on the organisation's BILLED Gemini project — one key per person (or one
# shared key for a small team), so each can be
# revoked on its own. Run it on your own Mac; never on a colleague's.
#
# Why billed, and why not the free tier any more:
#   - The Gemini API is a "Paid Service" (prompts NOT used to improve Google's
#     products) ONLY through a project with an active billing account. A
#     Workspace enterprise login does not change that for the API — that clause
#     in Google's terms covers AI Studio. A free key trains on our prompts.
#   - The free tier is 20 requests/day (measured 2026-09-06, gemini-3.8-flash,
#     project-wide), Pro has no free tier at all, and older Flash models return
#     "not available to new users". Not a backend.
#   - Google retired Gemini CLI OAuth (2026-06-18) → an API key is required.
#   - "Standard" API keys are rejected from September 2026; keys bound to a
#     service account ("auth keys") are the supported kind, which is what
#     `gcloud services api-keys create --service-account=...` mints.
#
# Cost control: pin flash (`gemini-flash-latest`), never Pro; put a Cloud
# Billing budget alert on the project. Measured load is ~$2/month per active Mac.
#
# Usage:
#   gcloud auth login                       # once, interactively
#   bash scripts/mint-gemini-key.sh --project <billed-project-id> --billed \
#        [--name <person>] [--write-rc]
#
# Without --billed the script REFUSES a billing-enabled project (the old
# free-tier mode, kept for experiments). Prints only a key prefix + length,
# never the whole key. --write-rc appends the key to your shell profile;
# otherwise the key lands in a 0600 temp file whose path is printed.

set -euo pipefail

PROJECT=""
WRITE_RC=0
BILLED=0
SA_NAME="megavibe-gemini"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)   PROJECT="$2"; shift 2 ;;
    --write-rc)  WRITE_RC=1; shift ;;
    --billed)    BILLED=1; shift ;;
    # Service-account ids: 6-30 chars, lowercase, no leading/trailing hyphen.
    --name)      SA_NAME="megavibe-gemini-$(printf '%s' "$2" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-*//' | cut -c1-14 | sed 's/-*$//')"; shift 2 ;;
    -h|--help)   sed -n '2,32p' "$0"; exit 0 ;;
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

# ─── Project ────────────────────────────────────────────────────────
if [ -z "$PROJECT" ]; then
  [ "$BILLED" -eq 1 ] && die "--billed needs --project <existing billed project id>; this script never creates billed projects"
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
    if [ "$BILLED" -eq 1 ]; then
      note "billing: enabled — Paid Service treatment (no training on prompts); keep the model pinned to flash"
    else
      die "project $PROJECT HAS billing enabled — pass --billed if that is intended (it is, for admin-issued keys)"
    fi ;;
  unknown)
    [ "$BILLED" -eq 1 ] && die "--billed given but billing status of $PROJECT cannot be verified — refusing to hand out a key that may train on prompts"
    note "billing status unverifiable (no billing API access) — continuing; verify manually" ;;
  *)
    [ "$BILLED" -eq 1 ] && die "--billed given but $PROJECT has NO billing account — that key would be free-tier (20 req/day, trains on prompts)"
    note "billing: not enabled (free tier only — 20 req/day, prompts used for training)" ;;
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
# Capture THIS key's resource name from the create call. Listing and taking the
# first entry handed out whichever key already existed — the same credential to
# several people, so revoking one person's key revoked another's.
KEY_RESOURCE=$(gcloud services api-keys create \
  --project "$PROJECT" --billing-project "$PROJECT" \
  --display-name="megavibe gemini auth key (${SA_NAME#megavibe-gemini-})" \
  --service-account="$SA_EMAIL" \
  --api-target=service=generativelanguage.googleapis.com \
  --format='value(response.name)' 2>/dev/null) \
  || die "key creation failed on $PROJECT (needs roles/serviceusage.apiKeysAdmin; re-run with the API Keys API enabled)"
[ -n "$KEY_RESOURCE" ] || KEY_RESOURCE=$(gcloud services api-keys list --project "$PROJECT" --billing-project "$PROJECT" \
  --filter="serviceAccount.email=$SA_EMAIL" --sort-by=~createTime --format='value(name)' 2>/dev/null | head -1)
[ -n "$KEY_RESOURCE" ] || die "key created but its resource name could not be read on $PROJECT"

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
if [ "$BILLED" -eq 1 ]; then echo "  Done. Billed project → no training on prompts; cost ~\$2/month per active Mac on flash."
else echo "  Done. Project $PROJECT has no billing → free tier: ~20 req/day and prompts ARE used for training."; fi
echo "  Revoke anytime:  gcloud services api-keys delete $KEY_RESOURCE"
