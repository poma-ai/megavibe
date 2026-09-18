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

## Backgrounded work gets a heartbeat

`run_in_background` and an async `Agent` return at once and promise a
notification when the task completes. A task that hangs, or restarts itself in
a loop, never completes — so the notification never comes, and from the main
thread a crashloop is indistinguishable from progress. Sessions have waited an
hour on that silence. A completion event is not monitoring.

The moment you start one, arm a `Monitor` heartbeat on its output file and do
not end the turn "waiting":

```bash
f=<output file>; last=0; while sleep 240; do s=$(wc -c <"$f" 2>/dev/null | tr -d ' ' || echo 0); printf 'bg <id>: %s bytes (+%s) | %s\n' "$s" "$((s-last))" "$(tail -c 200 "$f" 2>/dev/null | tr '\n' ' ')"; last=$s; done
```

Every beat wakes you with fresh evidence, whether or not the task finished.
Read it against what the task *is*, not as a verdict: a build or test run at
`+0` for two beats is hung, while a server idling at `+0` is healthy; a file
that keeps growing with the same lines repeating is a crashloop; a subagent
transcript whose last tool names repeat for many beats is a loop. Read the
output before acting, then act — kill it, fix it, `SendMessage` or `TaskStop`
the agent — instead of waiting one more interval. When the completion
notification arrives, `TaskStop` the heartbeat. There is no exemption for
"short" tasks: a thirty-second task that hangs is the same silence, and the
heartbeat costs one notification if the task finishes first. If `Monitor` is
not in your tool set, `ToolSearch "select:Monitor"`; if it is unavailable
altogether, run the same loop with a fixed beat count through
`run_in_background` and let its completion be the wake-up.

`watch-background.sh` enforces both halves. On start it injects the exact loop
to arm. On a turn boundary it reads the harness's live task registry and
refuses to let the turn end while a running task older than the interval has
no other running task whose command names it — which is what an armed
heartbeat looks like, and which stops being true the moment the heartbeat
exits or is stopped. Once per interval, all overdue tasks in one reason, never
in a loop. A Stop hook cannot wake you later; the heartbeat is the only thing
that can. `MEGAVIBE_BG_CHECK_SECS` sets the interval (clamped to 60–600 s; the
heartbeat beats 60 s under it); `MEGAVIBE_BG_WATCH=0` switches the hook off.
The default four-minute beat also happens to keep the API's five-minute prompt
cache warm — a side benefit, not a reason to beat faster. Do not read a
subagent's `.output` symlink whole: it is the full JSONL transcript.

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

## Reap by orphan-status, never by age

A long-lived process is **not** the same as a stale one. The kill signal is a
**dead owner** — parent reparented to PID 1, or the session/tmux/script that
spawned it is gone — not how long it has been running. An 8-day-old process can
be a live daemon doing exactly its job; a 2-minute-old one can already be an
orphan. Before killing anything:

- Confirm the parent: `ps -p <pid> -o ppid=`. PPID 1 (launchd/init) = orphaned.
- If PPID is alive, trace it (`ps -p <ppid> -o command=`) — a live parent means the process is still owned. Leave it.
- Never batch-kill by `etime` or a name match alone. Match each candidate against the expected set first.

This is a real footgun: "kill the oldest `node`/`gemini-mcp`/`python` process"
will happily take down a multi-day session that is still in active use.

## Audit periodically

To find user processes orphaned to launchd (likely candidates for cleanup):

```bash
ps -axo pid,ppid,etime,command | awk '$2==1 && /\/(bash|zsh|sh|python|node|ruby|deno|bun|uvicorn|http\.server|kubectl)\b/ && !/\/System\/|\/usr\/lib|\/Applications\/|com\.apple|\.appex/'
```

Match against the expected set (ssh-agent, gpg-agent / keyboxd, colima/lima/orbstack, intentional tmux sessions, named dev servers). Anything left over is a candidate for `kill`. Walk parent chains with `ps -p <pid> -o ppid=` if you need to know what spawned a polling kubectl or gcloud process — the polling parent is usually a forgotten `/tmp/*.sh` watchdog.
