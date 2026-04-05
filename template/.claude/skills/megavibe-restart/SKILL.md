---
name: megavibe-restart
description: Update megavibe and restart this session with new hooks/rules/skills
user_invocable: true
---

# Megavibe Restart

Update megavibe and seamlessly resume this conversation with new hooks, rules, and skills applied.

## Instructions

1. Write the restart marker file:
```bash
touch ~/.megavibe/.restart-session
```

2. Tell the user:
> Restart marker set. Type `/exit` to complete the restart.
> The megavibe wrapper will automatically update, sync hooks/rules/skills to this project, and resume this conversation.

Do NOT attempt to exit Claude programmatically. The user must type `/exit` themselves.
