#!/usr/bin/env bash
# provision-megawork.sh — an admin creates the credentials Megawork colleagues
# need, one capability at a time, all with the same shape:
#   create a narrow service identity → grant a read-only role → write the
#   credential into the private overlay → print how to revoke it.
#
# Everything lands in ONE Google Cloud project (default: the one that owns the
# key in $GEMINI_API_KEY, else --project), so the audit is one IAM page and one
# budget. Identities are named megawork-<capability>-<team> (the Gemini one
# keeps mint-gemini-key.sh's megavibe-gemini-<name> prefix).
#
# Usage:
#   scripts/provision-megawork.sh gemini  [--team T] [--project P]   # Gemini API key (via mint-gemini-key.sh)
#   scripts/provision-megawork.sh ga4     [--team T] [--project P]   # GA4 read-only service account + key JSON
#   scripts/provision-megawork.sh github  --token <fine-grained read-only PAT>   # validates + stores  (--token - to paste)
#   scripts/provision-megawork.sh org     --admin-name "…" [--grafana-url URL]   # policy/org.json (local org values)
#   scripts/provision-megawork.sh db      --name <x> --password -   # policy/<x>-password for the reports helper
#   scripts/provision-megawork.sh grafana --token -                 # Viewer service-account token (create it in Grafana)
#   scripts/provision-megawork.sh toolbox --file <tools.yaml>       # the report definitions (from your services repo)
#   scripts/provision-megawork.sh list    [--project P]              # what exists
#
# Output: files in $MEGAWORK_OVERLAY (default ~/.megavibe/personal/megawork/),
# which every install YOU run picks up silently. For a colleague's own install
# send them the single value they paste (Gemini key, GitHub token); files such
# as the GA4 JSON travel via the overlay or `megawork-connect --import`.
#
# What this deliberately does not do: cluster access, broad roles, one identity
# for everything. See .agent/RESEARCH/2026-09-07_access-model-*.md.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OVERLAY="${MEGAWORK_OVERLAY:-$HOME/.megavibe/personal/megawork}"
TEAM="team"; PROJECT=""; TOKEN=""; NAME=""; PASSWORD=""; FILE=""; ADMIN_NAME=""; GRAFANA_URL=""
case "${1:-}" in -h|--help|"") sed -n '2,30p' "$0"; exit 0 ;; esac
CAP="$1"; shift
die(){ echo "error: $*" >&2; exit 1; }
note(){ echo "  $*"; }
need(){ [ $# -ge 2 ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --team)    need "$@"; TEAM="$2"; shift 2 ;;
    --project) need "$@"; PROJECT="$2"; shift 2 ;;
    --token)   need "$@"; TOKEN="$2"; shift 2 ;;
    --name)    need "$@"; NAME="$2"; shift 2 ;;
    --password) need "$@"; PASSWORD="$2"; shift 2 ;;
    --file)    need "$@"; FILE="$2"; shift 2 ;;
    --admin-name) need "$@"; ADMIN_NAME="$2"; shift 2 ;;
    --grafana-url) need "$@"; GRAFANA_URL="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
TEAM=$(printf '%s' "$TEAM" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-*//; s/-*$//' | cut -c1-12)
[ -n "$TEAM" ] || die "--team must contain letters or digits"
mkdir -p "$OVERLAY"; chmod 700 "$OVERLAY"

project(){ # billed project: explicit, else the one owning $GEMINI_API_KEY
  [ -n "$PROJECT" ] && { printf '%s' "$PROJECT"; return; }
  command -v gcloud >/dev/null || die "gcloud not found"
  gcloud projects list --limit=1 >/dev/null 2>&1 || die "gcloud is not signed in — run: gcloud auth login"
  if [ -n "${GEMINI_API_KEY:-}" ]; then
    local parent; parent=$(gcloud services api-keys lookup "$GEMINI_API_KEY" --format='value(parent)' 2>/dev/null | sed -n 's|projects/\([^/]*\)/.*|\1|p')
    [ -n "$parent" ] && gcloud projects describe "$parent" --format='value(projectId)' 2>/dev/null && return
  fi
  die "no --project given and none derivable from GEMINI_API_KEY"
}

case "$CAP" in
  gemini)
    P=$(project); note "project: $P"
    OUTM=$(bash "$HERE/mint-gemini-key.sh" --billed --project "$P" --name "megawork-$TEAM" 2>&1) || { printf '%s\n' "$OUTM"; exit 1; }
    printf '%s\n' "$OUTM" | grep -v 'key written to\|to export it'
    KF=$(printf '%s\n' "$OUTM" | sed -n 's/.*key written to: \([^ ]*\).*/\1/p' | head -1)
    [ -n "$KF" ] && [ -s "$KF" ] || die "minted, but the key file was not found"
    cp "$KF" "$OVERLAY/gemini-key" && chmod 600 "$OVERLAY/gemini-key" && rm -f "$KF"
    note "key stored at $OVERLAY/gemini-key (0600) — every install you run picks it up; colleagues paste it" ;;

  ga4)
    P=$(project); note "project: $P"
    SA="megawork-ga4-$TEAM"; EMAIL="$SA@$P.iam.gserviceaccount.com"; OUT="$OVERLAY/ga4-service-account.json"
    gcloud services enable analyticsdata.googleapis.com analyticsadmin.googleapis.com --project "$P" >/dev/null 2>&1 || true
    if gcloud iam service-accounts describe "$EMAIL" --project "$P" >/dev/null 2>&1; then note "service account exists: $EMAIL"
    else gcloud iam service-accounts create "$SA" --project "$P" --display-name="Megawork GA4 read-only ($TEAM)" >/dev/null; note "created $EMAIL"; fi
    if [ -s "$OUT" ]; then note "key already at $OUT — delete it first to rotate"
    else gcloud iam service-accounts keys create "$OUT" --iam-account="$EMAIL" --project "$P" >/dev/null; chmod 600 "$OUT"; note "key written: $OUT (0600)"; fi
    echo ""
    echo "  One step only you can do: Google Analytics → Admin → Property access management →"
    echo "  add  $EMAIL  with the role VIEWER. Nothing else is granted anywhere."
    echo "  Revoke: gcloud iam service-accounts delete $EMAIL --project $P" ;;

  github)
    if [ "$TOKEN" = "-" ]; then printf '  Paste the fine-grained token: '; IFS= read -r -s TOKEN < /dev/tty; echo ""; fi
    [ -n "$TOKEN" ] || die "github needs --token <fine-grained PAT> (or --token - to paste it without it landing in shell history). Create it at
  https://github.com/settings/personal-access-tokens/new  (resource owner: the org;
  repository access: All repositories; permissions READ-ONLY: Contents, Issues,
  Pull requests, Metadata; no account permissions). Expiry: 1 year, calendar it."
    # Fine-grained tokens are the only kind whose permissions can be read-only per
    # category; they are recognisable by prefix. Classic tokens (ghp_) are refused
    # outright. GitHub offers no API to introspect a fine-grained token's
    # permissions, so read-only rests on how the admin created it — the connector
    # additionally sends X-MCP-Readonly so the MCP server exposes no write tools.
    case "$TOKEN" in github_pat_*) ;; ghp_*|gho_*|ghu_*|ghs_*) die "this is a classic token — create a FINE-GRAINED token (github_pat_…) with read-only permissions instead" ;; *) die "that does not look like a GitHub token" ;; esac
    WHO=$(curl -s --max-time 20 -H "Authorization: Bearer $TOKEN" -H 'Accept: application/vnd.github+json' https://api.github.com/user 2>/dev/null | jq -r '.login // empty' 2>/dev/null || true)
    [ -n "$WHO" ] || die "GitHub did not accept that token (or could not be reached)"
    printf '%s\n' "$TOKEN" > "$OVERLAY/github-token"; chmod 600 "$OVERLAY/github-token"
    note "token for $WHO stored at $OVERLAY/github-token (0600)"
    note "colleagues paste it via: megawork-connect github   (or it rides your overlay)"
    note "revoke: https://github.com/settings/personal-access-tokens" ;;

  org)
    # One local file for organisation values; every connector reads it with a
    # neutral default, so this repo never carries a company name or address.
    O="$OVERLAY/org.json"; command -v jq >/dev/null || die "jq is required"
    [ -s "$O" ] || echo '{}' > "$O"
    [ -n "$ADMIN_NAME$GRAFANA_URL" ] || die "org needs at least one of --admin-name, --grafana-url"
    jq --arg a "$ADMIN_NAME" --arg g "$GRAFANA_URL" \
       '(if $a != "" then .admin_name=$a else . end) | (if $g != "" then .grafana_url=$g else . end)' "$O" > "$O.tmp" && mv "$O.tmp" "$O"
    chmod 600 "$O"; note "org.json:"; jq . "$O" | sed 's/^/    /' ;;

  db)
    # Names are canonical lowercase-with-hyphens; the env var is the same name in
    # UPPER_CASE with underscores (reporting-ro ↔ MEGAWORK_PASSWORD_REPORTING_RO). Both
    # spellings are accepted here and normalised.
    [ -n "$NAME" ] || die "db needs --name <source> (the name the report definitions use, e.g. reporting-ro)"
    N=$(printf '%s' "$NAME" | tr 'A-Z_' 'a-z-' | tr -c 'a-z0-9-\n' '-' | sed 's/--*/-/g; s/^-*//; s/-*$//'); [ -n "$N" ] || die "--name must contain letters or digits"
    if [ "$PASSWORD" = "-" ] || [ -z "$PASSWORD" ]; then printf '  Paste the password for %s: ' "$N"; IFS= read -r -s PASSWORD < /dev/tty; echo ""; fi
    [ -n "$PASSWORD" ] || die "empty password"
    printf '%s\n' "$PASSWORD" > "$OVERLAY/$N-password"; chmod 600 "$OVERLAY/$N-password"
    note "stored $OVERLAY/$N-password (0600) — tools.yaml references it as \${MEGAWORK_PASSWORD_$(printf '%s' "$N" | tr 'a-z-' 'A-Z_')}" ;;

  grafana)
    GURL=$(jq -r '.grafana_url // empty' "$OVERLAY/org.json" 2>/dev/null || true); [ -n "$GURL" ] || die "set the address first: provision-megawork.sh org --grafana-url https://…"
    if [ "$TOKEN" = "-" ] || [ -z "$TOKEN" ]; then printf '  Paste the Grafana service-account token (role: Viewer): '; IFS= read -r -s TOKEN < /dev/tty; echo ""; fi
    [ -n "$TOKEN" ] || die "empty token. Create one in Grafana → Administration → Users and access → Service accounts → New (role Viewer) → Add token"
    WHO=$(curl -s --max-time 20 -H "Authorization: Bearer $TOKEN" "${GURL%/}/api/user" 2>/dev/null | jq -r '.login // empty' 2>/dev/null || true)
    [ -n "$WHO" ] || die "Grafana did not accept that token (or $GURL could not be reached)"
    ROLE=$(curl -s --max-time 20 -H "Authorization: Bearer $TOKEN" "${GURL%/}/api/org" 2>/dev/null | jq -r '.name // empty' 2>/dev/null || true)
    printf '%s\n' "$TOKEN" > "$OVERLAY/grafana-token"; chmod 600 "$OVERLAY/grafana-token"
    note "token for $WHO${ROLE:+ (org: $ROLE)} stored at $OVERLAY/grafana-token (0600); make sure the service account's role is Viewer" ;;

  toolbox)
    [ -n "$FILE" ] && [ -s "$FILE" ] || die "toolbox needs --file <tools.yaml> (the named-SQL definitions your developers maintain in the services repo)"
    grep -qE '^\s*sources:' "$FILE" && grep -qE '^\s*tools:' "$FILE" || die "$FILE does not look like an MCP Toolbox tools.yaml (needs sources: and tools:)"
    # A literal password is one that is neither a ${…} placeholder nor a comment.
    if grep -vE '^[[:space:]]*#' "$FILE" | grep -qE 'password:[[:space:]]*["'"'"']?[^$"'"'"'[:space:]]'; then die "$FILE contains a literal password — reference \${MEGAWORK_PASSWORD_<NAME>} instead and store it with: provision-megawork.sh db --name <name> --password -"; fi
    cp "$FILE" "$OVERLAY/tools.yaml"; chmod 600 "$OVERLAY/tools.yaml"
    note "stored $OVERLAY/tools.yaml — tools: $(awk '/^tools:/{f=1;next} /^[a-z]/{f=0} f && /^  [a-z0-9_]+:$/{gsub(/[ :]/,""); printf "%s ", $0}' "$FILE")"
    for v in $(grep -oE '\$\{MEGAWORK_PASSWORD_[A-Z0-9_]+\}' "$FILE" | tr -d '${}' | sort -u); do
      f="$OVERLAY/$(printf '%s' "${v#MEGAWORK_PASSWORD_}" | tr 'A-Z_' 'a-z-')-password"; [ -s "$f" ] && note "password present: $(basename "$f")" || note "still needed: provision-megawork.sh db --name $(basename "$f" -password) --password -"; done ;;

  list)
    P=$(project); echo "Megawork identities in $P:"
    gcloud iam service-accounts list --project "$P" --filter='email:megawork- OR email:megavibe-gemini-' --format='table(email,displayName,disabled)' 2>/dev/null || true
    echo ""; echo "API keys:"; gcloud services api-keys list --project "$P" --format='table(displayName,createTime.date(),restrictions.apiTargets[0].service)' 2>/dev/null || true
    echo ""; echo "overlay:"; ls -l "$OVERLAY" 2>/dev/null | awk 'NR>1{print "  "$NF"  ("$5" bytes)"}' ;;

  *) sed -n '2,30p' "$0"; exit 2 ;;
esac
