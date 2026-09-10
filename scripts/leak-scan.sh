#!/usr/bin/env bash
# Check that nothing org-specific or secret is published in this PUBLIC repo.
#
# megavibe ships credential-touching scripts (provision-megawork.sh,
# mint-gemini-key.sh, google-oauth-mint.sh) and is developed inside a company
# that has real keys, hostnames and colleagues. Two things have already landed
# here and cost a history rewrite each — see .gitignore. The cost asymmetry is
# the whole argument: catching it before a push is a `git reset`, catching it
# after is a force-push plus a rotation.
#
# Scans TRACKED CONTENT and, unless --fast, ALL HISTORY — a secret deleted in a
# later commit is still published. Exits 1 on any finding.
#
# Matches are printed as file:line plus a truncated fingerprint, never the
# value: a scanner that echoes secrets into a terminal, a CI log or an agent
# transcript has moved the leak rather than found it.
#
# Usage: scripts/leak-scan.sh [--fast]

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

FAST=0
[ "${1:-}" = "--fast" ] && FAST=1
FOUND=0

# Redact before printing: keep file:line, show only enough of the match to
# recognise which rule fired.
show() {
  sed -E 's/^([^:]*:[0-9]*:).*/\1/' | while read -r loc; do
    printf '    %s\n' "$loc"
  done
}

report() {
  local name="$1" hits="$2"
  [ -z "$hits" ] && return 0
  FOUND=1
  printf '  FAIL  %s\n' "$name"
  printf '%s\n' "$hits" | head -20 | show
  local n; n=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
  [ "$n" -gt 20 ] && printf '    ... and %d more\n' "$((n - 20))"
}

# Placeholders that legitimately look like the thing they stand in for.
PLACEHOLDER='your-|YOUR_|example|EXAMPLE|placeholder|<[a-z]|\$\{|\$[A-Z]|\.\.\.|xxx|XXX|changeme|redacted|REDACTED'

# This file is excluded from its own scan: every pattern it searches for is
# spelled out in its source, so including it guarantees a permanent self-match
# in four of the six checks — and a scanner that always reports something is a
# scanner nobody reads.
scan_tracked() {
  git ls-files -z | xargs -0 grep -nIE "$1" 2>/dev/null \
    | grep -vE "$PLACEHOLDER" | grep -v '^scripts/leak-scan\.sh:'
}

echo "leak-scan: $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"

# --- 1. Credential shapes ---------------------------------------------------
# Provider-specific prefixes. High precision: these have no innocent spelling.
SECRETS='(AIza[0-9A-Za-z_-]{30,}|sk-[A-Za-z0-9]{32,}|ghp_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9-]{20,}|glpat-[A-Za-z0-9_-]{15,}|lin_api_[A-Za-z0-9]{20,}|[0-9]{9,10}:AA[A-Za-z0-9_-]{30,}|ya29\.[A-Za-z0-9_-]{40,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
report "credential shapes (tracked)" "$(scan_tracked "$SECRETS")"

# --- 2. Assigned literals ---------------------------------------------------
# A secret with no recognisable prefix, caught by its NAME plus a value long
# enough not to be a flag or a path fragment. Values starting with / or ~ are
# dropped: `KUBE_TOKEN_FILE=/path/the/keeper/writes` names where a secret lives
# rather than being one, and that spelling is common in this repo's docs.
report "secret-named assignments" \
  "$(scan_tracked '(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|APIKEY)[A-Z_]*=["'"'"']?[A-Za-z0-9_+.-][A-Za-z0-9_/+.-]{19,}')"

# --- 3. Internal infrastructure ---------------------------------------------
# Loopback and RFC1918 are fine — they are in every dev-server example here.
report "internal infra (IPs, hosts, DSNs, GCP projects)" \
  "$(scan_tracked '([0-9]{1,3}\.){3}[0-9]{1,3}|[a-z0-9-]+\.(poma-ai|tigon)\.(com|cc)|[a-z0-9-]+\.(internal|svc\.cluster\.local)|(postgres|postgresql|mysql|mongodb|mongodb\+srv|redis|amqp)://|gs://|projects/[a-z0-9-]{6,}' \
    | grep -vE '127\.0\.0\.1|0\.0\.0\.0|localhost|192\.168\.|10\.0\.0|255\.255|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-|v?[0-9]+\.[0-9]+\.[0-9]+')"

# --- 4. People and machines -------------------------------------------------
# Commit authorship is excluded by construction: this reads file CONTENT only.
# Contributors' own names in their own commit metadata are their choice, not a
# leak, and cannot be scrubbed without rewriting their history.
report "personal identifiers in file content" \
  "$(scan_tracked '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|/Users/[a-z]+/|/home/[a-z]+/' \
    | grep -vE 'megavibe@poma-ai\.com|user@|you@|name@|noreply|@example|\$HOME|~/')"

# --- 5. Binaries ------------------------------------------------------------
# An icon has leaked here before. Images and archives are also where metadata
# and whole documents hide from every grep above.
BIN=$(git ls-files | grep -iE '\.(png|jpg|jpeg|gif|icns|ico|pdf|zip|tar|gz|sqlite|db|xlsx|docx)$')
report "binary/asset files tracked" "$(printf '%s' "$BIN" | sed 's/$/:0:/')"

# --- 6. History -------------------------------------------------------------
# The expensive one, and the one that matters: a secret removed in a later
# commit is still served by GitHub at its blob URL forever.
if [ "$FAST" -eq 0 ]; then
  H=$(git log -p --all --no-color 2>/dev/null | grep -aE '^\+' | grep -aE "$SECRETS" | grep -vE "$PLACEHOLDER")
  if [ -n "$H" ]; then
    FOUND=1
    printf '  FAIL  credential shapes (history)\n'
    printf '    %d added line(s) across history match a credential prefix.\n' \
      "$(printf '%s\n' "$H" | wc -l | tr -d ' ')"
    printf '    Find them with: git log -p --all -S<fragment>\n'
    printf '    A history rewrite AND rotation are both required — the blob\n'
    printf '    stays reachable by SHA even after a force-push.\n'
  fi
else
  echo "  SKIP  history (--fast)"
fi

# --- 7. Org coupling (review, not verdict) ----------------------------------
# The second axis, and the one a regex cannot decide. This repo is published for
# strangers, so the question is not only "is anything secret here" but "does any
# of it only make sense inside the company that wrote it". Hardcoded org
# defaults, internal tool names, and workflows that assume our cluster are not
# leaks — they are what makes a public tool useless to everyone else.
#
# Legitimate hits exist (repo URL, licence, the poma-memory dependency), so this
# never fails the run. It prints a count and asks for eyes.
ORG_ALLOW='github\.com/poma-ai/megavibe|raw\.githubusercontent\.com/poma-ai|api\.github\.com/repos/poma-ai|poma-ai/megavibe|megavibe@poma-ai\.com|POMA AI GmbH|poma-memory|poma_memory|poma-serve|POMA_STATE|POMA_TAIL|\.poma-heal'
ORG=$(scan_tracked 'poma|tigon' | grep -viE "$ORG_ALLOW")
if [ -n "$ORG" ]; then
  printf '  REVIEW  org-specific references outside the known-good set (%d)\n' \
    "$(printf '%s\n' "$ORG" | wc -l | tr -d ' ')"
  printf '%s\n' "$ORG" | head -15 | show
  printf '    Each must be a real dependency, not an assumption a stranger\n'
  printf '    cannot satisfy. Parameterise it or move it to the private overlay.\n'
fi

if [ "$FOUND" -eq 0 ]; then
  echo "leak-scan: clean"
  exit 0
fi
echo "leak-scan: findings above — do not push"
exit 1
