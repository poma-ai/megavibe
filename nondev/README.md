# megavibe-nondev

A megavibe profile for people who are not programmers: plain language, a single
folder they own, and an OS-enforced boundary so nothing they ask for can wander
outside it. Same harness underneath — hooks, context files, subagents, backends.

Status: the containment is proven (`spike/RESULTS.md`, `spike/RESULTS-capable.md`);
the profile installs, runs, and has been exercised end to end. Not yet piloted with
a real non-technical user.

## Install

```bash
bash nondev/init-nondev.sh                 # ~/megavibe-nondev + ~/.megavibe-nondev
bash nondev/init-nondev.sh --gdrive        # folder in Google Drive instead
nondev-doctor                              # verify, incl. a live sandbox canary
```

Then, once: sign in with `claude`, and drag the app from `/Applications` to the Dock.

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
