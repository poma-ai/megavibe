#!/usr/bin/env bash
# Mint a per-user Google OAuth refresh token for an arbitrary scope set, via a
# localhost loopback consent flow.
#
# Why this exists: a `gcloud` login (and the Gemini CLI's stored grant) carries
# the cloud-platform scope ONLY. That does not cover the Google Ads API
# (adwords), the Workspace Admin SDK (admin.directory.*), or GA4 Admin
# (analytics.*) — each needs its own consent. This performs that consent once per
# scope family and stores the refresh token, so later automated runs are
# non-interactive.
#
# Each user runs this as THEMSELVES. The resulting token carries that person's
# own authority — no shared credential, no domain-wide delegation, and access
# dies with their account. That is the property you want for offboarding.
#
# Usage:
#   google-oauth-mint.sh ads         # https://www.googleapis.com/auth/adwords
#   google-oauth-mint.sh workspace   # admin.directory.{user,group,rolemanagement}.readonly
#   google-oauth-mint.sh groupwrite  # admin.directory.group  (member/role writes)
#   google-oauth-mint.sh analytics   # analytics.manage.users + analytics.readonly
#   google-oauth-mint.sh custom "scope1 scope2" outname
#
# Requires an OAuth client of type "Desktop app" in any Google Cloud project you
# control, as GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET. Tokens land in
# ~/.config/google-<name>-refresh-token.json, mode 0600.
#
# WARNING on `groupwrite`: admin.directory.group is a WRITE scope over Workspace
# group membership, so the refresh token it stores can change who is in which
# group — a privilege-escalation primitive sitting in a file with no expiry.
# Mint it only if you need it, and revoke at myaccount.google.com/permissions
# when you are done.
#
# Known gap, deliberate: no PKCE. Google recommends it for loopback clients, and
# it belongs here, but it is unverified in this script and an untested auth
# change is worse than a documented one. See the repo issue before relying on
# this for anything beyond an internal tool.

set -euo pipefail
# Accept the generic names first; the older GOOGLE_ADS_API_* names still work so
# an existing shell profile keeps running unchanged.
CLIENT_ID="${GOOGLE_OAUTH_CLIENT_ID:-${GOOGLE_ADS_API_CLIENT:-}}"
CLIENT_SECRET="${GOOGLE_OAUTH_CLIENT_SECRET:-${GOOGLE_ADS_API_SECRET:-}}"
[ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || {
  echo "Set GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET first." >&2
  echo "Create the client in Google Cloud console → APIs & Services → Credentials" >&2
  echo "→ Create credentials → OAuth client ID → Desktop app. Enable the APIs you" >&2
  echo "want scopes for on the same project." >&2
  exit 2
}
export CLIENT_ID CLIENT_SECRET

case "${1:-}" in
  ads)        SCOPES="https://www.googleapis.com/auth/adwords"; NAME=ads ;;
  workspace)  SCOPES="https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly https://www.googleapis.com/auth/admin.directory.user.readonly https://www.googleapis.com/auth/admin.directory.group.readonly"; NAME=workspace ;;
  groupwrite) SCOPES="https://www.googleapis.com/auth/admin.directory.group"; NAME=groups ;;
  analytics)  SCOPES="https://www.googleapis.com/auth/analytics.manage.users https://www.googleapis.com/auth/analytics.readonly"; NAME=analytics ;;
  custom)     SCOPES="${2:?scopes}"; NAME="${3:?output name}" ;;
  *) sed -n '2,26p' "$0"; exit 2 ;;
esac

PORT="${OAUTH_PORT:-8770}" SCOPES="$SCOPES" NAME="$NAME" python3 - <<'PY'
import os, sys, json, time, threading, http.server, urllib.parse, urllib.request

port = int(os.environ["PORT"]); scopes = os.environ["SCOPES"]; name = os.environ["NAME"]
cid, csec = os.environ["CLIENT_ID"], os.environ["CLIENT_SECRET"]
redirect = f"http://localhost:{port}/"
box = {}

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        box.update({k: v[0] for k, v in
                    urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).items()})
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        self.wfile.write(b"<h2>Done. Close this tab.</h2>")
    def log_message(self, *a): pass

srv = http.server.HTTPServer(("127.0.0.1", port), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()

url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
    "client_id": cid, "redirect_uri": redirect, "response_type": "code",
    "scope": scopes, "access_type": "offline", "prompt": "consent"})
print("Open this URL and approve:\n" + url + "\n", flush=True)

t0 = time.time()
while "code" not in box and "error" not in box and time.time() - t0 < 300:
    time.sleep(1)
if "code" not in box:
    sys.exit("no authorization code received: %s" % json.dumps(box))

tok = json.load(urllib.request.urlopen(urllib.request.Request(
    "https://oauth2.googleapis.com/token",
    data=urllib.parse.urlencode({"code": box["code"], "client_id": cid,
        "client_secret": csec, "redirect_uri": redirect,
        "grant_type": "authorization_code"}).encode())))
if "refresh_token" not in tok:
    sys.exit("no refresh_token returned (already-granted consent? re-run revokes nothing; "
             "remove the app at myaccount.google.com/permissions and retry)")

out = os.path.expanduser(f"~/.config/google-{name}-refresh-token.json")
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"refresh_token": tok["refresh_token"], "scopes": scopes}, f)
print("wrote " + out)
PY
