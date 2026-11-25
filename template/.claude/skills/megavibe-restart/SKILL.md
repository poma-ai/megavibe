---
name: megavibe-restart
description: Save background work, update megavibe and resume this exact conversation
user_invocable: true
---

# Megavibe Restart

Update megavibe and resume this conversation with new hooks, rules, and skills.

1. Prepare this session's handover and scoped restart marker:

```bash
bash "${MEGAVIBE_HOME:-$HOME/.megavibe}/scripts/restart.sh" request
```

The helper prints the handover path under `.agent/sessions/<session id>/`.
Read it. It records the last harness registry (commands, start times, output
files) and observed child processes, distinguishing session-bound work that
ends from named tmux or reparented work that survives. Observations can be
incomplete; they do not prove an unlisted job stopped.

2. **Append your own notes to that file before exiting.** Include non-megavibe
background work the registry cannot explain: scheduled prompts you created
(including `/watch`), Monitor heartbeats, servers started for tests, long jobs
in named tmux sessions, and anything detached. For each, write its purpose,
task ID/PID/tmux name, output location, how to check it, and how to restart or
re-arm it if still needed. Do not blindly relaunch a job that may survive.

3. Tell the user:

> Handover saved. Type `/exit` to complete the restart. The wrapper updates,
> syncs hooks/rules/skills, and resumes this conversation by session ID.

Do not exit Claude programmatically from this skill. The user types `/exit`.
If the helper cannot establish the ID, it says so in one line and the launcher
falls back to `--continue`. An older launcher also warns about that fallback.

On the first startup/resume after the restart, the hook shows the handover
once and marks it shown, retaining the file. Check each job's survival,
re-arm its heartbeat or restart it only if needed, and say which you dropped.

For several sessions, `megavibe restart-all --dry-run` previews the eligible
ones; `megavibe restart-all` prepares handovers and submits `/exit` in idle
matched tmux panes. `--others` excludes the caller; otherwise it is considered
last and still skipped when busy. Busy, unknown, unmatched and non-tmux
sessions are listed and left alone. Launchers predating scoped restart need
one manual restart. The batch cannot add your unwritten knowledge: save those
notes through this skill first when they matter.
