# megavibe-nondev

A megavibe profile for people who are not programmers: plain language, a single
folder they own, and an OS-enforced boundary so nothing they ask for can wander
outside it. Same harness underneath — hooks, context files, subagents, backends.

Status: the *fallback* contract is scripted and passes 10/10 (`spike/RESULTS.md`);
the adopted seatbelt contract is measured in `spike/RESULTS-capable.md` §D and
re-checked live by `nondev-doctor` on every run. An adversarial review closed two
sandbox escapes (see §D "Post-review hardening"). Installs, runs, and has been
exercised end to end — but not yet piloted with a real non-technical user.

## Install

**Self-serve — the person installs it themselves, one line, no admin:**

```bash
curl -fsSL https://raw.githubusercontent.com/poma-ai/megavibe/main/nondev/install-nondev.sh | bash
```

It installs Claude Code if missing, downloads via tarball (no `git`, so macOS
never pops the Xcode developer-tools dialog), asks where the folder should live,
and walks them through signing in. Prompts read from the terminal, not stdin, so
the pipe does not eat the answers.

From a checkout, or for a scripted install:

```bash
bash nondev/init-nondev.sh                          # asks where the folder goes
bash nondev/init-nondev.sh --gdrive "Client work"   # straight to Google Drive
nondev-doctor                                       # verify, incl. escape canaries
```

Run interactively, the installer lists the locations that actually exist on the
Mac — the home folder, every Google Drive account's *My Drive*, and every shared
drive — so "which folder?" is a menu choice rather than a path to type.

Then, once: sign in with `claude`, and drag the app from `/Applications` to the Dock.

Afterwards the person can move it themselves, without an admin:

```bash
nondev-folder            # where is my folder?
nondev-folder --list     # where could it be?
nondev-folder "/path"    # move it there (copies, never a bare move)
```

They can also just *ask the assistant* to do it — the protocol tells it how.
Moving re-renders the sandbox profile so containment follows the folder.

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
so in a sentence, and offers. `nondev-connect` does the rest.

```bash
nondev-connect                 # what is on, and what could be
nondev-connect gmail           # opens a browser sign-in
nondev-connect --off gmail     # reverse it
```

| Name | What it is | How it connects |
|---|---|---|
| `gmail` | Gmail — search, read threads, prepare drafts | official remote MCP, OAuth |
| `applemail` | mail already downloaded to this Mac | a sandbox read permission, not a login |
| `slack` | messages the person can already see | official remote MCP, OAuth |
| `linear` | issues, projects, status | official remote MCP, OAuth |
| `hubspot` | contacts, companies, deals | official remote MCP, OAuth |
| `analytics` | GA4 reports (read-only, runs locally) | Google's own local server + `gcloud` login |

Sign-in goes through each service's own OAuth, handled by Claude Code — no tokens
are pasted and megavibe never sees a credential. One wrinkle worth knowing: the
OAuth handshake needs a real terminal, so it cannot complete from inside a
session. `nondev-connect` registers the service, then tells the person to quit
the assistant and run the same one line in the Terminal window they started it
from; the browser opens by itself. One line, once per service.

**Google Analytics is the exception.** The Analytics Data API does not accept API
keys at all — reports are authorised per GA4 property, so it needs a real
identity. Either an admin drops a service account (granted Viewer on the
property) at `$ENGINE/policy/ga4-service-account.json`, in which case the person
signs in to nothing at all, or `nondev-connect analytics` runs
`gcloud auth application-default login` for them and the Google window opens by
itself. The service-account route is the right one for colleagues. Send, delete, archive and trash
verbs stay denied by policy on every connector; drafting is allowed, since
"write me a reply" is the point. `applemail` is the odd one out: it is not a
login but a sandbox read rule, so turning it on genuinely widens what the session
can read — verified that `.ssh`, `gh` tokens and Slack's local store stay blocked
either way, and that turning it off closes it again.

## Coexisting with classic megavibe

Both can live on one Mac. Because a nondev session is not `--restricted`, it does
read a user-level `~/.claude/CLAUDE.md`, so the plain-language protocol explicitly
overrides any developer rules it finds — verified in practice across every test
session, all of which ran with classic megavibe active.

The installer therefore **leaves an existing classic install alone by default** —
it will not silently degrade something the person chose to install. If they never
use the developer version, `nondev-mode on` parks it for a marginally cleaner
assistant, and `nondev-mode off` puts it back. Nothing is ever deleted.

## One machine, one protocol

Because the session is not `--restricted`, a user-level `~/.claude/CLAUDE.md` is read
as usual — so on a machine that also runs classic megavibe, developer rules would leak
into the plain-language assistant. `nondev-mode on|off|status` makes that an explicit
choice instead of a blend (non-destructive; the doctor reports which mode is active).

## Using the Claude app as the interface

Start the session with `--remote` (or `MEGAVIBE_NONDEV_REMOTE=1`) and attach from the
Claude app via Remote Control. The session still starts here — inside the sandbox, under
the admin policy — and the app merely drives it. Starting a session *from inside* the app
instead would bypass the sandbox and the policy entirely.

## Files

| Path | What it is |
|---|---|
| `init-nondev.sh` | provisioning: engine, folder, launcher, policy |
| `bin/megavibe-nondev` | the launcher (implements the contract above) |
| `bin/nondev-doctor` | health check, readable over a screen share |
| `bin/nondev-mode` | park/restore a conflicting user-level protocol |
| `bin/nondev-folder` | show/move the working folder (Drive-aware), re-rendering policy |
| `template/sandbox.sb.template` | the seatbelt profile (rendered with real paths) |
| `template/policy/*.template` | permissions + hook registrations |
| `template/CLAUDE-nondev.md` | the plain-language protocol |
| `template/hooks/` | session-start orientation, pre-write snapshots (undo) |
| `spike/` | the measurements the design rests on |

## Organisation-specific things stay out of this repo

**This repository is public (MIT).** Company branding, named pilot documents, customer
data, org policy and credentialed analyst verbs must not be committed here. Keep them in
a private overlay directory and point `MEGAVIBE_NONDEV_OVERLAY` at it (default
`~/.megavibe/personal/nondev`):

```
$MEGAVIBE_NONDEV_OVERLAY/
  icon.icns        ← your own Dock icon, applied at install if present
  PILOT-BRIEF.md   ← who is testing, what they report (names, emails)
```

The installer degrades gracefully when the overlay is absent: no icon, stock behaviour.
`.gitignore` blocks the overlay paths so they cannot be committed here by accident.
