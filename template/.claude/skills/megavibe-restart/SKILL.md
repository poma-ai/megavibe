---
name: megavibe-restart
disable-model-invocation: true
user-invocable: true
description: Save background work, update megavibe and resume this exact conversation
---

# Megavibe Restart

Start this skill only when the user types `/megavibe-restart`. The model may offer the command, but must not invoke the skill itself.

Update megavibe and resume this conversation with new hooks, rules, and skills.

1. Prepare this session's handover and scoped restart marker:

```bash
bash "${MEGAVIBE_HOME:-$HOME/.megavibe}/scripts/restart.sh" request
```

The helper prints the handover path under `.agent/sessions/<session id>/`.
Read it. It records task IDs, start times, safe local output paths and
observed executable names, with command arguments and environment omitted.
Survival labels are expectations only; verify each PID and start time.
Observations can be incomplete and do not prove an unlisted job stopped.

2. **Append your own notes to that file before exiting.** Include non-megavibe
background work the registry cannot explain: scheduled prompts you created
(including `/watch`), Monitor heartbeats, servers started for tests, long jobs
in named tmux sessions, and anything detached. For each, write its purpose,
task ID/PID/tmux name, output location, how to check it, and how to restart or
re-arm it if still needed. Do not include credentials or environment values.
Do not blindly relaunch a job that may survive.

3. Tell the user:

> Handover saved. Type `/exit` to complete the restart. The wrapper updates,
> syncs hooks/rules/skills, and resumes this conversation by session ID.

Do not exit Claude programmatically from this skill. The user types `/exit`.
If the helper cannot establish the exact ID or the launcher is too old,
it reports a skipped restart in one line. Do not tell the user a restart is
armed after a failure: restart that conversation manually once instead.
To cancel an armed request, run the helper with `cancel <session id>`.

At SessionEnd the helper refreshes machine evidence while preserving your
notes. A matching successful capture and confirmed process exit permit the
replacement launch. Only that replacement’s SessionStart activates the reminder;
a failed launch stays `not-restarted`. The matching startup/resume shows it once (or a bounded summary pointing to the retained
file). Check each job's PID/start time and actual survival, re-arm its heartbeat
or restart it only if needed, and say which you dropped.

For several sessions, `megavibe restart-all` reports sessions requiring this
manual flow; `--others` excludes the caller. Automatic pane input is removed
because tmux cannot atomically verify Claude's editor and submit `/exit`.
