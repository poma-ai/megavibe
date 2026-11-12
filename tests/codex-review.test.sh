#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/codex-review-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.codex" "$T/bin"
cat > "$T/bin/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = exec ] && [[ " $* " == *' --help '* ]]; then echo --ignore-rules; exit 0; fi
printf '%s\n' "$@" > "$CODEX_TEST_ARGV"
cat > "$CODEX_TEST_PROMPT"
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = -o ]; then j=$((i + 1)); printf 'normal answer\n' > "${!j}"; fi
done
EOF
chmod +x "$T/bin/codex"
export HOME="$T/home" CODEX_HOME="$T/home/.codex" PATH="$T/bin:$PATH"
export CODEX_TEST_ARGV="$T/argv" CODEX_TEST_PROMPT="$T/prompt"
run_review() { "$REPO/scripts/codex-review.sh" --strict --timeout 2 --prompt review "$T/input" >/dev/null; }
printf 'input\n' > "$T/input"

printf 'openai_base_url = "https://elsewhere.invalid"\n' > "$CODEX_HOME/config.toml"
set +e
run_review 2>"$T/err"
rc=$?
set -e
[ "$rc" = 2 ]
grep -q 'openai_base_url' "$T/err"
[ ! -e "$CODEX_TEST_PROMPT" ]

cat > "$CODEX_HOME/config.toml" <<'EOF'
profile = "remote"
[profiles.remote]
chatgpt_base_url = "https://elsewhere.invalid"
EOF
set +e
run_review 2>"$T/profile.err"
rc=$?
set -e
[ "$rc" = 2 ]
grep -q 'chatgpt_base_url' "$T/profile.err"

printf 'chatgpt_base_url = "https://elsewhere.invalid"\n' > "$CODEX_HOME/config.toml"
if MEGAVIBE_CODEX_ALLOW_ENDPOINT=1 run_review; then :; else echo 'FAIL: endpoint override did not run' >&2; exit 1; fi

: > "$CODEX_HOME/config.toml"
run_review
grep -q -- '-c' "$CODEX_TEST_ARGV"
grep -q 'model_provider="openai"' "$CODEX_TEST_ARGV"
echo 'ok'
