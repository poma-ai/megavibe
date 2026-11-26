#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/watcher-gate-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.megavibe/scripts" "$T/home/.codex" "$T/bin" "$T/proj/.agent"
cp "$REPO/scripts/reviewers.sh" "$REPO/scripts/backends.sh" "$T/home/.megavibe/scripts/"
printf '#!/bin/sh\nexit 0\n' > "$T/home/.megavibe/scripts/context-watcher.py"; chmod +x "$T/home/.megavibe/scripts/context-watcher.py"
printf '{}\n' > "$T/transcript.jsonl"
cat > "$T/bin/codex" <<'EOS'
#!/bin/bash
if [ "${1:-}" = exec ] && [[ " $* " == *' --help '* ]]; then exit 0; fi
if [ "${1:-}" = login ]; then [ -e "$CODEX_TEST_LOGGED_IN" ] && { echo "Logged in using ChatGPT"; exit 0; }; echo "Not logged in"; exit 1; fi
exit 0
EOS
cat > "$T/bin/tmux" <<'EOS'
#!/bin/bash
case "${1:-}" in has-session) exit 1 ;; new) shift; printf '%s\n' "$*" >> "$TMUX_TEST_LOG"; exit 0 ;; *) exit 0 ;; esac
EOS
chmod +x "$T/bin/codex" "$T/bin/tmux"
export HOME="$T/home" CODEX_HOME="$T/home/.codex" PATH="$T/bin:$PATH"
export CODEX_TEST_LOGGED_IN="$T/logged-in" TMUX_TEST_LOG="$T/tmux.log"
unset CODEX_API_KEY CODEX_ACCESS_TOKEN OPENAI_API_KEY MEGAVIBE_CODEX_KEYED MEGAVIBE_BACKENDS MEGAVIBE_REVIEWERS MEGAVIBE_CODEX_AUTH MEGAVIBE_CODEX_OK GEMINI_API_KEY MEGAVIBE_WATCHER
HOOK="$REPO/template/.claude/hooks/start-context-watcher.sh"
INPUT=$(printf '{"session_id":"aaaaaaaaaaaabbbb","transcript_path":"%s"}' "$T/transcript.jsonl")
eq() { [ "$1" = "$2" ] || { echo "FAIL $3: got '$1' want '$2'" >&2; exit 1; }; }
run_hook() { rm -f "$TMUX_TEST_LOG" "$T/proj/.agent/LOGS/"watcher-spawn.* 2>/dev/null || true; ( cd "$T/proj" && printf '%s' "$INPUT" | bash "$HOOK" ) >/dev/null 2>&1; }
spawned() { [ -s "$TMUX_TEST_LOG" ] && echo yes || echo no; }

rm -f "$CODEX_TEST_LOGGED_IN"
run_hook; eq "$(spawned)" no "logged-out Codex, default pin: no idle watcher"
grep -q "not started" "$T/proj/.agent/LOGS/watcher-spawn.aaaaaaaaaaaa.log" || { echo "FAIL: skip not logged" >&2; exit 1; }

touch "$CODEX_TEST_LOGGED_IN"
run_hook; eq "$(spawned)" yes "logged-in Codex: watcher starts"
grep -q -- "-u MEGAVIBE_BACKENDS CLAUDE_PROJECT_DIR=" "$TMUX_TEST_LOG" || { echo "FAIL: unset pin not passed explicitly" >&2; cat "$TMUX_TEST_LOG" >&2; exit 1; }
grep -q -- "-u MEGAVIBE_CODEX_AUTH" "$TMUX_TEST_LOG" || { echo "FAIL: unset codex-auth override not passed explicitly" >&2; exit 1; }
MEGAVIBE_CODEX_AUTH=2 run_hook
grep -q "MEGAVIBE_CODEX_AUTH=2" "$TMUX_TEST_LOG" || { echo "FAIL: MEGAVIBE_CODEX_AUTH override not forwarded to the watcher" >&2; cat "$TMUX_TEST_LOG" >&2; exit 1; }
rm -f "$CODEX_TEST_LOGGED_IN"
CODEX_API_KEY=secret-value run_hook; eq "$(spawned)" no "keyed-only Codex: the watcher would not have the key, so it is not started"
MEGAVIBE_CODEX_AUTH=2 CODEX_API_KEY=secret-value run_hook; eq "$(spawned)" yes "explicit MEGAVIBE_CODEX_AUTH=2: watcher starts"
if grep -q "secret-value" "$TMUX_TEST_LOG"; then echo "FAIL: the key itself reached the tmux command line" >&2; exit 1; fi
touch "$CODEX_TEST_LOGGED_IN"

export MEGAVIBE_BACKENDS="claude"
run_hook; eq "$(spawned)" no "pin claude: no watcher"

export MEGAVIBE_BACKENDS="claude gemini" GEMINI_API_KEY=k
rm -f "$CODEX_TEST_LOGGED_IN"
run_hook; eq "$(spawned)" yes "pin naming gemini, Codex logged out: watcher starts for Gemini"
grep -q 'MEGAVIBE_BACKENDS=claude\\ gemini' "$TMUX_TEST_LOG" || { echo "FAIL: pin not quoted into the tmux command" >&2; cat "$TMUX_TEST_LOG" >&2; exit 1; }

unset MEGAVIBE_BACKENDS
rm -f "$CODEX_TEST_LOGGED_IN"
MEGAVIBE_GEMINI_DIGEST=1 GEMINI_API_KEY=k run_hook; eq "$(spawned)" yes "review N5: logged-out Codex, Gemini opted in: watcher starts"

export MEGAVIBE_BACKENDS='claude; touch '"$T"'/pwned'
run_hook; [ ! -e "$T/pwned" ] || { echo "FAIL: pin text was executed" >&2; exit 1; }
echo "watcher gate tests passed"
