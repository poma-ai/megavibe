#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/backends-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.claude" "$T/home/.codex" "$T/bin" "$T/proj/.claude"
cat > "$T/bin/codex" <<'EOS'
#!/bin/bash
if [ "${1:-}" = exec ] && [[ " $* " == *' --help '* ]]; then echo --ignore-rules; exit 0; fi
if [ "${1:-}" = login ]; then echo x >> "$CODEX_TEST_LOGINS"; [ -e "$CODEX_TEST_LOGGED_IN" ] && { echo "Logged in using ChatGPT"; exit 0; }; echo "Not logged in"; exit 1; fi
echo x >> "$CODEX_TEST_CALLS"; cat >/dev/null
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = -o ]; then j=$((i + 1)); printf 'answer\n' > "${!j}"; fi
done
EOS
chmod +x "$T/bin/codex"
export HOME="$T/home" CODEX_HOME="$T/home/.codex" PATH="$T/bin:$PATH" MEGAVIBE_HOME="$T/home/.megavibe" CLAUDE_PROJECT_DIR="$T/proj"
export CODEX_TEST_LOGINS="$T/logins" CODEX_TEST_LOGGED_IN="$T/logged-in" CODEX_TEST_CALLS="$T/calls"
unset CODEX_API_KEY CODEX_ACCESS_TOKEN OPENAI_API_KEY MEGAVIBE_CODEX_KEYED MEGAVIBE_BACKENDS MEGAVIBE_REVIEWERS MEGAVIBE_CODEX_AUTH MEGAVIBE_CODEX_OK GEMINI_API_KEY MEGAVIBE_GEMINI_DIGEST
B="$REPO/scripts/backends.sh"; RV="$REPO/scripts/reviewers.sh"
rcof() { local r=0; "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }
eq() { [ "$1" = "$2" ] || { echo "FAIL $3: got '$1' want '$2'" >&2; exit 1; }; }

eq "$("$B" list | tr '\n' ' ')" "claude codex gemini " "default lists all"
eq "$(MEGAVIBE_BACKENDS=claude "$B" list | tr '\n' ' ')" "claude " "pin"
eq "$(MEGAVIBE_BACKENDS=gemini "$B" list | tr '\n' ' ')" "claude gemini " "claude always on"
eq "$(MEGAVIBE_BACKENDS='claude codx' "$B" list 2>/dev/null | tr '\n' ' ')" "claude " "typo narrows, never widens"
eq "$(MEGAVIBE_BACKENDS='gemini codx' "$B" list 2>/dev/null | tr '\n' ' ')" "claude gemini " "typo keeps the valid names"
eq "$(rcof env MEGAVIBE_BACKENDS=claude "$B" enabled codex)" 1 "enabled codex off"
eq "$(rcof "$B" enabled bogus)" 2 "unknown id is a usage error"

echo '{"env":{"MEGAVIBE_BACKENDS":"claude"}}' > "$T/proj/.claude/settings.json"
eq "$("$B" list | tr '\n' ' ')" "claude codex gemini " "committed project settings.json ignored"
echo '{"env":{"MEGAVIBE_BACKENDS":"claude"}}' > "$T/proj/.claude/settings.local.json"
eq "$("$B" list | tr '\n' ' ')" "claude " "settings.local.json honoured"
rm "$T/proj/.claude/settings.local.json" "$T/proj/.claude/settings.json"
echo '{"env":{"MEGAVIBE_BACKENDS":"claude gemini"}}' > "$T/home/.claude/settings.json"
eq "$("$B" list | tr '\n' ' ')" "claude gemini " "user settings honoured"
echo '{broken' > "$T/home/.claude/settings.json"
eq "$("$B" list 2>/dev/null | tr '\n' ' ')" "claude " "broken json narrows to claude"
rm "$T/home/.claude/settings.json"

eq "$(rcof "$B" codex-auth)" 1 "logged out"
eq "$(rcof "$B" usable codex)" 1 "usable codex while logged out"
touch "$CODEX_TEST_LOGGED_IN"
eq "$(rcof "$B" usable codex)" 0 "login state is read live, never cached: logged in right after logged out"
rm -f "$CODEX_TEST_LOGGED_IN"
eq "$(rcof "$B" usable codex)" 1 "and logged out again right after"
touch "$CODEX_TEST_LOGGED_IN"
eq "$(rcof "$B" usable codex)" 0 "usable codex when logged in"
eq "$(rcof env MEGAVIBE_BACKENDS=claude "$B" usable codex)" 1 "usable codex when not allowed"
eq "$(rcof env MEGAVIBE_CODEX_AUTH=2 "$B" usable codex)" 2 "unknown auth is unknown, not unusable"

rm -f "$CODEX_TEST_LOGGED_IN"
eq "$("$RV" digest-chain)" "subagent" "digest-chain: logged-out codex, no gemini key"
eq "$(GEMINI_API_KEY=k "$RV" digest-chain)" "subagent" "digest-chain: a logged-out codex does not open gemini by itself"
eq "$(GEMINI_API_KEY=k MEGAVIBE_BACKENDS="claude gemini" "$RV" digest-chain)" "gemini subagent" "digest-chain: a user pin naming gemini does"
eq "$(rcof env MEGAVIBE_BACKENDS="claude gemini" "$B" pinned gemini)" 0 "pinned gemini"
eq "$(rcof "$B" pinned gemini)" 1 "not pinned by default"
eq "$(rcof env MEGAVIBE_BACKENDS=auto "$B" pinned gemini)" 1 "not pinned under auto"
eq "$(GEMINI_API_KEY=k MEGAVIBE_BACKENDS=claude "$RV" digest-chain)" "subagent" "digest-chain: gemini not allowed"
touch "$CODEX_TEST_LOGGED_IN"
eq "$("$RV" digest-chain)" "codex subagent" "digest-chain: logged in"
eq "$(MEGAVIBE_BACKENDS=claude "$RV" digest-chain)" "subagent" "digest-chain: codex not allowed"

printf 'p\n' > "$T/in"
rm -f "$CODEX_TEST_CALLS" "$CODEX_TEST_LOGGED_IN"
eq "$(rcof "$REPO/scripts/codex-review.sh" --strict --prompt hi "$T/in")" 4 "codex-review general call skips when logged out"
[ ! -e "$CODEX_TEST_CALLS" ] || { echo "FAIL: a request was sent while logged out" >&2; exit 1; }
touch "$CODEX_TEST_LOGGED_IN"
eq "$(rcof env MEGAVIBE_BACKENDS=claude "$REPO/scripts/codex-review.sh" --strict --prompt hi "$T/in")" 4 "codex-review general call skips when not allowed"
eq "$(rcof env MEGAVIBE_CODEX_AUTH=1 MEGAVIBE_AMASS_GATE=0 "$REPO/scripts/codex-review.sh" --as-reviewer --strict --prompt hi "$T/in")" 0 "reviewer role is independent of backends"
[ -e "$CODEX_TEST_CALLS" ] || { echo "FAIL: reviewer call did not reach codex" >&2; exit 1; }

eq "$(rcof env MEGAVIBE_BACKENDS=claude GEMINI_API_KEY=k "$REPO/scripts/gemini-review.sh" --prompt hi "$T/in")" 4 "gemini general call skips when not allowed"
eq "$(rcof env MEGAVIBE_BACKENDS=claude MEGAVIBE_GEMINI_DIGEST=1 GEMINI_API_KEY=k "$REPO/scripts/gemini-review.sh" --prompt hi "$T/in")" 4 "DIGEST override does not bypass the allow-list"
rm -f "$CODEX_TEST_LOGGED_IN"
eq "$(rcof env GEMINI_API_KEY=k "$REPO/scripts/gemini-review.sh" --prompt hi "$T/in")" 4 "gemini general call refused while codex is merely logged out"
touch "$CODEX_TEST_LOGGED_IN"
echo '{"env":{"MEGAVIBE_BACKENDS":"claude"}}' > "$T/proj/.claude/settings.local.json"
eq "$(rcof env GEMINI_API_KEY=k "$REPO/scripts/gemini-review.sh" --prompt hi "$T/in")" 4 "gemini gate reads the file-sourced allow-list"
rm "$T/proj/.claude/settings.local.json"

cat > "$T/order.py" <<'EOP'
import importlib.util, os, sys
sp = importlib.util.spec_from_file_location("cw", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
assert m._backend_order("auto") == ["codex"], m._backend_order("auto")
m._AUTH_BACKOFF["codex"] = 9e12
assert m._backend_order("auto") == [], "auth backoff must drop codex"
try:
    m.call_backend("x", "auto", 5, lambda *_: None); raise SystemExit("expected NoBackend")
except m.NoBackend:
    pass
os.environ["MEGAVIBE_BACKENDS"] = "claude"; m._AUTH_BACKOFF.clear()
assert m._backend_order("auto") == [], "allow-list must drop codex"
assert m._codex_auth_error("ERROR: unexpected status 401 Unauthorized: missing bearer") and not m._codex_auth_error("timeout")
assert not m._codex_auth_error("user\nsee error 401 in the parser logs, authentication fails\nERROR: model not supported on your plan")
assert not m._codex_auth_error("model not available; see login docs for plans")
echoed_prompt = "request log\nError: got 401 Unauthorized from the proxy\nend"
assert not m._codex_auth_error("user\n" + echoed_prompt + "\nERROR: model not supported on your plan", echoed_prompt), "an echoed prompt line must not count"
assert m._codex_auth_error("user\n" + echoed_prompt + "\nERROR: unexpected status 401 Unauthorized", echoed_prompt), "a real 401 still counts"
m._AUTH_BACKOFF.clear(); os.environ["MEGAVIBE_BACKENDS"] = "gemini"
open(os.path.join(os.path.dirname(sys.argv[1]), "reviewers.sh"), "w").write("exit 1\n")
assert m._backend_order("auto") == ["gemini"], m._backend_order("auto")
assert m._backend_order("codex") == ["gemini"], "a forced backend still obeys the allow-list"
open(os.path.join(os.path.dirname(sys.argv[1]), "reviewers.sh"), "w").write(open(sys.argv[2]).read())
EOP
mkdir -p "$T/scr"; cp "$REPO/scripts/context-watcher.py" "$REPO/scripts/reviewers.sh" "$REPO/scripts/backends.sh" "$T/scr/"
touch "$CODEX_TEST_LOGGED_IN"; rm -f "$T"/home/.megavibe/usage/codex-auth.*
cat >> "$T/order.py" <<'EOP'
m._AUTH_BACKOFF.clear(); os.environ.pop("MEGAVIBE_BACKENDS", None)
os.environ["GEMINI_API_KEY"] = "k"
assert m._backend_order("auto") == ["codex"], m._backend_order("auto")
assert m._backend_order("gemini") == ["gemini", "codex"], m._backend_order("gemini")
os.environ["MEGAVIBE_BACKENDS"] = "claude codex"
assert m._backend_order("gemini") == ["codex"], "a forced backend still obeys the allow-list"
d = os.path.dirname(sys.argv[1])
open(os.path.join(d, "reviewers.sh"), "w").write("exit 1\n"); open(os.path.join(d, "backends.sh"), "w").write("exit 1\n")
os.environ.pop("MEGAVIBE_BACKENDS", None)
assert m._backend_order("auto") == [], "an installed helper that cannot answer must mean no backend, not all of them"
EOP
python3 -I "$T/order.py" "$T/scr/context-watcher.py" "$REPO/scripts/reviewers.sh"

# review F5: one tokenizer, so a tab or newline in a pin cannot drop a name from `pinned`
eq "$(rcof env MEGAVIBE_BACKENDS=$'claude\tgemini' "$B" pinned gemini)" 0 "tab-separated pin names gemini"
eq "$(rcof env MEGAVIBE_BACKENDS=$'claude\ngemini' "$B" pinned gemini)" 0 "newline-separated pin names gemini"
eq "$(rcof env MEGAVIBE_BACKENDS='claude,;gemini' "$B" pinned gemini)" 0 "comma and semicolon separators"

# review F4: a named project wins over the working directory's settings file
mkdir -p "$T/other/.claude" "$T/proj/.claude"
echo '{"env":{"MEGAVIBE_BACKENDS":"claude"}}' > "$T/other/.claude/settings.local.json"
eq "$(cd "$T/other" && "$B" list | tr '\n' ' ')" "claude codex gemini " "cwd settings.local.json ignored while CLAUDE_PROJECT_DIR names another project"
eq "$(cd "$T/other" && env -u CLAUDE_PROJECT_DIR "$B" list | tr '\n' ' ')" "claude " "cwd settings.local.json used when no project is named"

# review F2: a Codex working through an API key or a custom provider reads as unknown, never as logged out
rm -f "$CODEX_TEST_LOGGED_IN"
eq "$(rcof "$B" codex-auth)" 1 "logged out and no key"
eq "$(rcof env CODEX_API_KEY=k "$B" codex-auth)" 2 "CODEX_API_KEY: unknown"
eq "$(rcof env OPENAI_API_KEY=k "$B" usable codex)" 1 "an unrelated OPENAI_API_KEY does not override a definitive 'not logged in'"
printf 'model_provider = "openai"\n' > "$T/home/.codex/config.toml"
eq "$(rcof "$B" codex-auth)" 1 "a model_provider line does not override 'not logged in'"
mkdir -p "$T/gitproj/.claude" "$T/gitproj/sub"; git -C "$T/gitproj" init -q
echo '{"env":{"MEGAVIBE_BACKENDS":"claude"}}' > "$T/gitproj/.claude/settings.local.json"
eq "$(cd "$T/gitproj/sub" && env -u CLAUDE_PROJECT_DIR "$B" list | tr '\n' ' ')" "claude " "review N1: project pin found from a subdirectory"
rm -f "$T/home/.codex/config.toml"

# review F3: MEGAVIBE_GEMINI_DIGEST=1 keeps an allowed Gemini after Codex in the watcher
touch "$CODEX_TEST_LOGGED_IN"
cat > "$T/order2.py" <<'EOP'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
os.environ["GEMINI_API_KEY"] = "k"; os.environ["MEGAVIBE_GEMINI_DIGEST"] = "1"; os.environ.pop("MEGAVIBE_BACKENDS", None)
assert m._backend_order("auto") == ["codex", "gemini"], m._backend_order("auto")
os.environ["MEGAVIBE_BACKENDS"] = "claude codex"
assert m._backend_order("auto") == ["codex"], "the allow-list still wins"
EOP
cp "$REPO/scripts/context-watcher.py" "$REPO/scripts/reviewers.sh" "$REPO/scripts/backends.sh" "$T/scr/"
python3 -I "$T/order2.py" "$T/scr/context-watcher.py"

# review F1: a pin with a usable Codex must not trip the session-start hook's ERR trap (it lost all context injection)
mkdir -p "$T/ss/home/.megavibe/scripts" "$T/ss/proj/.agent"
cp "$REPO/scripts/reviewers.sh" "$B" "$T/ss/home/.megavibe/scripts/"
for i in 1 2 3 4 5 6 7 8; do echo "lesson line $i"; done > "$T/ss/proj/.agent/LESSONS.md"
touch "$CODEX_TEST_LOGGED_IN"
ss_out=$( cd "$T/ss/proj" && echo '{"session_id":"abcdef123456","source":"startup"}' | HOME="$T/ss/home" MEGAVIBE_BACKENDS="claude codex" CLAUDE_PROJECT_DIR="$T/ss/proj" bash "$REPO/template/.claude/hooks/on-session-start.sh" 2>/dev/null )
case "$ss_out" in *"lesson line 3"*) ;; *) echo "FAIL: session-start lost its context injection with a pin set" >&2; exit 1 ;; esac
case "$ss_out" in *"Backends (non-review)"*) ;; *) echo "FAIL: Backends row missing for a pinned list" >&2; exit 1 ;; esac
echo "backends tests passed"
