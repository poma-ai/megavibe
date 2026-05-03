# Long-running processes

When you start something that outlives the current command — a server, watcher, port-forward, or polling loop — these rules apply. Getting them wrong leaves orphan processes running for days or weeks under launchd, exposing services on the LAN, or hammering external APIs in failure loops.

## Don't disown to launchd

If a process ends up parented to PID 1 (launchd on macOS, init/systemd on Linux), nothing will catch it. The shell that launched it is gone. The user has no terminal to come back to. It runs forever.

Avoid:
- `nohup ... &`
- Bare `&` in a shell that's about to exit — this is the common case, because shells spawned by tool calls return immediately
- `disown` after backgrounding
- `setsid`, `screen -dm`, anything that detaches by design

Use one of these instead:
- **Bash `run_in_background`** (Claude Code's own backgrounding) — bound to the session, cleaned up when the session ends. Right for short-lived work the parent will check on.
- **Foreground in a terminal the user is watching** — for things you want them to see in real time.
- **Named tmux session** — for things genuinely meant to outlive the current Claude session: `tmux new -d -s <project>-<purpose> '<command>'`. The session name is how the user finds and kills it later.

## Bind dev servers to localhost by default

For uvicorn, fastapi, `python -m http.server`, vite, next dev, webpack-dev-server, json-server, and similar: pass `--host 127.0.0.1` (or the framework equivalent) unless the user explicitly asked for LAN access.

`--host 0.0.0.0` is uvicorn's default. It is also `python -m http.server`'s default. That puts the service on every interface, IPv4 + IPv6. On a coworking, hotel, or conference WiFi that's an unauthenticated read of your project directory or local API. The user usually didn't ask for this — it just happened because the framework defaults that way.

When LAN access is genuinely needed (testing from a phone on the same network, demoing to someone in the room): say so explicitly in your launch summary so the user knows the exposure exists.

## Polling loops need fail-fast and backoff

A `while true; do <cmd>; sleep N; done` against an external API (kubectl, gcloud, GitHub, k8s, cloud SDKs, anything that needs auth) must:

- **Exit on auth failure.** If the command fails with `Unauthorized`, `ReauthRequired`, `401`, `Token expired`, or similar — stop the loop. Don't retry. The credentials are not going to fix themselves while you're hammering the API. Hammering produces failure-log spam, sometimes millions of files.
- **`sleep ≥ 30s`** for cloud API polls. Per-second polls are how a forgotten watchdog generates 1.2M log files in 14 days.
- **Run in a named tmux session**, not disowned. So when auth eventually does break, the user can find and kill it.

## Tell the user where it lives

When you start a long-running process, your final report must include:
- **PID** (or tmux session name)
- **Bind address + port** — and explicitly note if LAN-exposed
- **How to find it later** — exact `ps` filter, `lsof -nP -iTCP:<port>`, or `tmux attach -t <name>`
- **How to kill it** — `kill <pid>` or `tmux kill-session -t <name>`

Without this, the user cannot clean up after the session ends. Process hygiene is a deliverable, not an afterthought.

## Audit periodically

To find user processes orphaned to launchd (likely candidates for cleanup):

```bash
ps -axo pid,ppid,etime,command | awk '$2==1 && /\/(bash|zsh|sh|python|node|ruby|deno|bun|uvicorn|http\.server|kubectl)\b/ && !/\/System\/|\/usr\/lib|\/Applications\/|com\.apple|\.appex/'
```

Match against the expected set (ssh-agent, gpg-agent / keyboxd, colima/lima/orbstack, intentional tmux sessions, named dev servers). Anything left over is a candidate for `kill`. Walk parent chains with `ps -p <pid> -o ppid=` if you need to know what spawned a polling kubectl or gcloud process — the polling parent is usually a forgotten `/tmp/*.sh` watchdog.
