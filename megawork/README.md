# megawork

A megavibe profile for people who are not programmers: plain language, a single
folder they own, and an OS-enforced boundary so nothing they ask for can wander
outside it. Same harness underneath — hooks, context files, subagents, backends.

Status: the *fallback* contract is scripted and passes 10/10 (`spike/RESULTS.md`);
the adopted seatbelt contract is measured in `spike/RESULTS-capable.md` §D and
re-checked live by `megawork-doctor` on every run. An adversarial review closed two
sandbox escapes (see §D "Post-review hardening"). Installs, runs, and has been
exercised end to end — but not yet piloted with a real non-technical user.

## Install

**Self-serve — the person installs it themselves, one line, no admin:**

```bash
curl -fsSL https://raw.githubusercontent.com/poma-ai/megavibe/main/megawork/install.sh | bash
```

It installs Claude Code if missing, downloads via tarball (no `git`, so macOS
never pops the Xcode developer-tools dialog), asks where the folder should live,
and walks them through signing in. Prompts read from the terminal, not stdin, so
the pipe does not eat the answers.

From a checkout, or for a scripted install:

```bash
bash megawork/init.sh                          # asks where the folder goes
bash megawork/init.sh --gdrive "Client work"   # straight to Google Drive
megawork-doctor                                       # verify, incl. escape canaries
```

Run interactively, the installer lists the locations that actually exist on the
Mac — the home folder, every Google Drive account's *My Drive*, and every shared
drive — so "which folder?" is a menu choice rather than a path to type.

Then drag the app from `/Applications` to the Dock — the installer has already walked them through signing in.

Afterwards the person can move it themselves, without an admin:

```bash
megawork-folder            # where is my folder?
megawork-folder --list     # where could it be?
megawork-folder "/path"    # move it there (copies, never a bare move)
```

The assistant can show them the options and hand them the exact command, but
the move itself runs in Terminal: inside a session the engine is read-only, on
purpose. Moving re-renders the sandbox profile so containment follows the
folder, keeps Apple Mail and connected services switched on, and pre-approves
the new folder so Claude does not ask "do you trust this folder?".

## How containment works

The boundary is a macOS **seatbelt profile**, not Claude's own flags:

```
sandbox-exec -f <profile> claude --settings <policy> --add-dir <folder> --append-system-prompt <protocol>
```

Writes are confined by the kernel to the colleague's folder; reads stay broad
(that is the point — the assistant can consult their material) minus a secrets
denylist. Bash, MCP servers and connectors all remain available.

**Why not `--restricted`:** it confines Claude's own file tools but *not* Bash, and it
cannot admit MCP servers at all — measured, see `spike/RESULTS-capable.md`. Capability
and `--restricted` are mutually exclusive, so the boundary has to live in the OS.
`--restricted` remains the automatic fallback where no sandbox exists: reduced
capability, never reduced containment.

## Connecting other services

Nothing is connected by default — not mail, not chat, not the CRM. Wiring all of
that up at install time reads as creepy even when it is convenient, so consent is
just-in-time instead: the assistant notices a task would be better with one, says
so in a sentence, and offers. `megawork-connect` does the rest.

```bash
megawork-connect                 # what is on, and what could be
megawork-connect gmail           # opens a browser sign-in
megawork-connect --off gmail     # reverse it
```

| Name | What it is | How it connects |
|---|---|---|
| `gmail` | Gmail — search, read threads, prepare drafts | official remote MCP, OAuth |
| `applemail` | mail already downloaded to this Mac | a sandbox read permission, not a login |
| `slack` | messages the person can already see | official remote MCP, OAuth |
| `linear` | issues, projects, status | official remote MCP, OAuth |
| `hubspot` | contacts, companies, deals | official remote MCP, OAuth |
| `github` | code, issues and pull requests in the company repositories | GitHub's remote MCP at its `/readonly` endpoint with `X-MCP-Readonly`, using an admin-issued fine-grained token (`policy/github-token`) created with read-only permissions |
| `analytics` | GA4 reports (read-only) | Google's local MCP with an admin-provisioned service account (Viewer on the property) |
| `reports` | usage and billing figures, as named questions | MCP Toolbox for Databases with the organisation's `policy/tools.yaml` (named SQL over read-only views); passwords via `policy/<name>-password`, never in the file |
| `grafana` | dashboards, metrics and service logs | `mcp-grafana --disable-write` with a Viewer service-account token; address from `policy/org.json` |

Online services sign in through their own OAuth, handled by Claude Code — nothing
is pasted and megavibe never sees a credential. The OAuth handshake needs a real
terminal, which a session is not — so the launcher does it: the assistant queues
the sign-in, the person closes the session with Ctrl-D, the browser opens by
itself, and the session reopens with the service connected. Two kinds are
admin-issued instead of signed in: the Gemini key and access tokens such as
GitHub's. Those are pasted once (or arrive via the admin's overlay), kept at
`~/.megawork/policy/` (0600, unreadable from inside a session) and handed to the
session as environment variables — the MCP registration holds a `${…}`
placeholder, never the value. That applies to every pasted secret (Gemini key,
tokens, database passwords): the file is protected, the value is in the
session's environment and therefore visible to the assistant, which is why each
is a narrow, revocable credential. Read-only for GitHub rests on how the admin created
the token (GitHub has no API to verify a fine-grained token's permissions) plus
the server's own read-only mode; `scripts/provision-megawork.sh github` refuses
classic tokens. **Nobody types a command** for the online services; the pasted
kinds need exactly one paste.

**Google Analytics is the exception.** The Analytics Data API does not accept API
keys at all — reports are authorised per GA4 property, so it needs a real
identity. Either an admin drops a service account (granted Viewer on the
property) at `$ENGINE/policy/ga4-service-account.json`, in which case the person
signs in to nothing at all, or `megawork-connect analytics` runs
`gcloud auth application-default login` for them and the Google window opens by
itself. The service-account route is the right one for colleagues. Work tools are theirs
to edit — Linear, HubSpot, Notion, Drive: that is how they already use them and
the blast radius is small. What policy denies is outward-facing messaging:
sending mail, posting or replying in Slack, trashing or archiving mail. Drafting
is allowed, since "write me a reply" is the point. Where read-only matters it is
enforced at the source — the GitHub token is issued read-only and the server runs
in read-only mode, the GA4 identity is a Viewer — not by guessing tool names. `applemail` is the odd one out: it is not a
login but a sandbox read rule, so turning it on genuinely widens what the session
can read — verified that `.ssh`, `gh` tokens and Slack's local store stay blocked
either way, and that turning it off closes it again.

## The harness it keeps

Containment was the hard part, but it is not the valuable part. The profile also
carries the things that make megavibe worth using:

- **Memory across days.** The assistant appends what it did to
  `$ENGINE/agent/HISTORY.md`, and gets the recent entries back at the start of
  every session — so "what did we work on last time?" is answered from its own
  notes. Kept in the engine, not the person's folder, so cloud sync never sees
  it and their folders stay exactly as tidy as they left them.
- **Undo**, via pre-write snapshots (also engine-side).
- **Updates.** `megawork-update` fetches the current release and re-runs the
  installer, keeping folder, history and connections. It backs the engine up
  first and rolls back automatically if the health check fails afterwards — a
  colleague must never be left with a broken assistant and no way back. The
  launcher mentions an available update at most once a week, as one quiet line,
  and never installs anything on its own.
- **A health check**, `megawork-doctor`, readable over a screen share.

## Coexisting with classic megavibe

Both can live on one Mac. Because a Megawork session is not `--restricted`, it does
read a user-level `~/.claude/CLAUDE.md`, so the plain-language protocol explicitly
overrides any developer rules it finds — verified in practice across every test
session, all of which ran with classic megavibe active.

The installer therefore **leaves an existing classic install alone by default** —
it will not silently degrade something the person chose to install. If they never
use the developer version, `megawork-mode on` parks it for a marginally cleaner
assistant, and `megawork-mode off` puts it back. Nothing is ever deleted.

## One machine, one protocol

Because the session is not `--restricted`, a user-level `~/.claude/CLAUDE.md` is read
as usual — so on a machine that also runs classic megavibe, developer rules would leak
into the plain-language assistant. `megawork-mode on|off|status` makes that an explicit
choice instead of a blend (non-destructive; the doctor reports which mode is active).

## Using the Claude app as the interface

Start the session with `--remote` (or `MEGAWORK_REMOTE=1`) and attach from the
Claude app via Remote Control. The session still starts here — inside the sandbox, under
the admin policy — and the app merely drives it. Starting a session *from inside* the app
instead would bypass the sandbox and the policy entirely.

## Files

| Path | What it is |
|---|---|
| `install.sh` | the `curl \| bash` one-liner: Claude, tarball, harness, then `init.sh` |
| `init.sh` | provisioning: engine, folder, launcher, policy, Gemini key |
| `bin/megawork` | the launcher (implements the contract above) |
| `bin/megawork-doctor` | health check, readable over a screen share |
| `bin/megawork-connect` | switch services on/off, one at a time; also the Gemini key paste/repair path |
| `bin/megawork-update` | fetch the current release, back up, re-run `init.sh`, verify, roll back if needed |
| `bin/megawork-mode` | park/restore a conflicting user-level protocol |
| `bin/megawork-folder` | show/move the working folder (Drive-aware), re-rendering policy |
| `template/sandbox.sb.template` | the seatbelt profile (rendered with real paths) |
| `template/policy/*.template`, `template/policy/mcp.json` | permissions + hook registrations; MCP config for the no-sandbox fallback |
| `template/CLAUDE-megawork.md` | the plain-language protocol |
| `template/hooks/` | session-start orientation, pre-write snapshots (undo) |
| `spike/` | the measurements the design rests on |

## Organisation-specific things stay out of this repo

**This repository is public (MIT).** Company branding, named pilot documents, customer
data, org policy and credentialed analyst verbs must not be committed here. Keep them in
a private overlay directory and point `MEGAWORK_OVERLAY` at it (default
`~/.megavibe/personal/megawork`):

```
$MEGAWORK_OVERLAY/
  icon.icns                   ← your own Dock icon, applied at install if present
  PILOT-BRIEF.md              ← who is testing, what they report (names, emails)
  gemini-key                  ← admin-issued credentials: picked up by every install
  github-token                   the admin runs, copied to ~/.megawork/policy/ (0600,
  ga4-service-account.json       newer-only, so a token pasted later is not clobbered)
  grafana-token, <db>-password   ← more of the same
  org.json, tools.yaml           ← organisation values and report definitions (not secrets)
```

**Local configuration, not repository configuration.** Everything that names the
organisation lives in the overlay and is copied into `~/.megawork/policy/`:
`org.json` (admin name, Grafana address — every connector reads it with a
neutral default, so the file is optional), `tools.yaml` (the named SQL
the reports connector may run — written by the organisation's developers next
to their schema), and the credentials. This public repo ships only the
mechanism plus `template/examples/org.example.json` and `tools.example.yaml`.

The overlay is also the credential store. `scripts/provision-megawork.sh <gemini|ga4|github|grafana|db|toolbox|org>`
creates each credential as its own narrow identity in one Google Cloud project
(`megawork-<capability>-<team>`, Viewer/read-only roles, one budget) and writes it
here; `provision-megawork.sh list` shows what exists. Colleagues who install on
their own paste the single-string kinds (Gemini key, GitHub token) when asked.

The installer degrades gracefully when the overlay is absent: no icon, stock behaviour.
`.gitignore` blocks the overlay paths so they cannot be committed here by accident.

## Backends

Gemini and Codex are part of the profile, not optional extras — the assistant
uses them for long documents and second opinions, invisibly. Neither is ever
presented to the person as a decision to make.

The Gemini key is the organisation's, not the person's. It comes from a project **with
billing attached**: that is the only way the Gemini API treats prompts as a
"Paid Service" and keeps them out of Google's training data (a Workspace login
does not change this for the API — only for AI Studio), and the free tier is
20 requests a day on the one model a new project can still call, which is not
a backend. The installer takes the key from `MEGAWORK_OVERLAY/gemini-key` or
`GEMINI_API_KEY` if an admin left one; otherwise it asks the person to paste
it once, checks it with a single call, and keeps it at `~/.megawork/policy/
gemini-key` (0600; the file is unreadable from inside a session, but the
launcher hands the key to the session as `GEMINI_API_KEY`, so treat it as
visible to the assistant — it is a per-person key precisely so it can be
revoked). Enter skips, and the closing message then says plainly that second
opinions are not set up. Add or repair later: `megawork-connect gemini` (a dead
key is replaced in one go; a working one is kept — `--off gemini` first to
swap it). `megawork-doctor` reports whether the key answers.

Cost: at a measured developer load (about 50 calls a month, ~2M input tokens) a
flash-class model is roughly $2 per active Mac per month. Never pin or override
to a Pro model — it bills at 3-16x. The Gemini CLI default is pinned to
`gemini-flash-latest` when the key is stored. Admins mint per-person keys on the
billed project with `scripts/mint-gemini-key.sh --project <id> --billed`, so
each colleague's key can be revoked on its own.

Codex is installed and used if the person has a ChatGPT account; if not, it
stays quiet.

Both helpers are npm packages. A stock Mac has no Node, so the installer fetches
Node's official LTS tarball (~240 MB; ~600 MB once the helpers are installed under it) into `~/.megawork/tools/node` (no Homebrew,
no sudo, no Xcode dialog). The launcher puts that directory first on `PATH` for
every session whenever it exists, so the helpers installed under it resolve; a
Mac that already had npm at install time gets no download. Without this step the harness silently
installed nothing on a bare Mac and the assistant had no Gemini tool even with
a valid key.
