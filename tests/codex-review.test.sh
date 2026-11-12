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
# A8: the recorded argv carries the provider pin as its own -c argument on a normal run.
grep -qx -- 'model_provider="openai"' "$CODEX_TEST_ARGV"
[ "$(grep -x -B1 -- 'model_provider="openai"' "$CODEX_TEST_ARGV" | head -1)" = "-c" ]
# The user's own model and effort settings stay in effect: no config bypass, no forced model.
! grep -qx -- '--ignore-user-config' "$CODEX_TEST_ARGV"
! grep -qx -- '--model' "$CODEX_TEST_ARGV"

# R3: a single-quoted (TOML literal string) profile name selects the same profile.
printf '%s\n' "profile = 'lit'" '[profiles.lit]' 'openai_base_url = "https://x.invalid"' > "$CODEX_HOME/config.toml"
if run_review; then echo 'FAIL: single-quoted active profile endpoint was not refused' >&2; exit 1; fi
: > "$CODEX_HOME/config.toml"

# A9: the key under the ACTIVE profile is refused; under an inactive profile it is not.
cat > "$CODEX_HOME/config.toml" <<'EOF'
profile = "work"
[profiles.work]
openai_base_url = "https://elsewhere.invalid"
EOF
set +e
run_review 2>"$T/active.err"
rc=$?
set -e
[ "$rc" = 2 ]
grep -q 'openai_base_url' "$T/active.err"

cat > "$CODEX_HOME/config.toml" <<'EOF'
profile = "work"
[profiles.work]
model = "x"
[profiles.other]
openai_base_url = "https://elsewhere.invalid"
EOF
rm -f "$CODEX_TEST_PROMPT"
run_review
[ -e "$CODEX_TEST_PROMPT" ]
# F2: a trailing comment, a commented table header and a non-profile table must not confuse the guard.
cat > "$CODEX_HOME/config.toml" <<'EOF2'
profile = "work"  # mine
[profiles.work]
openai_base_url = "https://elsewhere.invalid"
EOF2
set +e
run_review 2>"$T/comment.err"
rc=$?
set -e
[ "$rc" = 2 ]
grep -q 'openai_base_url' "$T/comment.err"

cat > "$CODEX_HOME/config.toml" <<'EOF2'
profile = "work"
[profiles.work] # w
openai_base_url = "https://elsewhere.invalid"
EOF2
set +e
run_review 2>"$T/header.err"
rc=$?
set -e
[ "$rc" = 2 ]
grep -q 'openai_base_url' "$T/header.err"

cat > "$CODEX_HOME/config.toml" <<'EOF2'
[tui]
profile = "x"
[profiles.x]
openai_base_url = "https://elsewhere.invalid"
EOF2
rm -f "$CODEX_TEST_PROMPT"
run_review
[ -e "$CODEX_TEST_PROMPT" ]
echo 'ok'
