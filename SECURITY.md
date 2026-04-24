# Security Policy

## Reporting a vulnerability

Please **do not** report security issues via public GitHub issues.

Use GitHub's [Private Vulnerability Reporting](https://github.com/poma-ai/megavibe/security/advisories/new) to send a confidential report directly to the maintainers.

We aim to acknowledge reports within 72 hours and issue fixes or mitigations within 14 days for confirmed high-severity issues.

## Scope

megavibe is a local-first framework — it installs shell scripts and configures Claude Code on the user's machine. Security-relevant areas include:

- Shell scripts that run during install/setup (`install.sh`, `setup.sh`, `init.sh`, `megavibe`)
- Hooks that execute on every tool call (`.claude/hooks/*.sh`)
- MCP server configurations
- Anything that handles external input (Telegram bot, remote-control)

Bugs in protocol text, documentation, or unused features are not security issues — report those as regular issues.

## Supported versions

Only the latest `main` branch receives security fixes. There are no long-term-support releases.
