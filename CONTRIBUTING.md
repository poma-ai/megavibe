# Contributing to megavibe

Thanks for your interest! megavibe is a small project maintained by POMA AI GmbH. Contributions are welcome.

## Bug reports

Open a [GitHub Issue](https://github.com/poma-ai/megavibe/issues/new) with:

- What you expected to happen
- What actually happened (include any error output)
- Minimal steps to reproduce
- Your OS, Python version, Node version, and `claude --version`

## Pull requests

1. Fork the repo and create a branch off `main` (e.g. `fix/typo-readme`, `feat/new-hook`).
2. Keep changes focused — one concern per PR. Small diffs get reviewed faster.
3. Match existing shell conventions: `set -euo pipefail`, `[[ ]]` for bash, `jq` for JSON, fast hooks.
4. Test locally. For shell scripts: `bash -n <script>` at minimum. For hook changes: verify idempotency by running twice and confirming skip-messages on the second run (see `CLAUDE.md` → "Verification protocol").
5. Write a clear commit message — brief imperative is great ("fix X", "add Y").
6. Open the PR against `main`.

Expect a review within a few days. If a PR sits longer than a week, feel free to ping in a comment.

## Questions and discussions

Prefer the [Discussions](https://github.com/poma-ai/megavibe/discussions) tab for "how do I...", "would it make sense if...", and general usage questions. Issues are for bugs and concrete feature requests.

## Security

Please **do not** file security vulnerabilities as public issues. See [SECURITY.md](./SECURITY.md).

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](./LICENSE).
