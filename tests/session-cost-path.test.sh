#!/bin/bash
# session-cost.sh finds a session's transcript where Claude Code stores it: under
# $CLAUDE_CONFIG_DIR (else ~/.claude)/projects/<project>/<session-id>.jsonl, where <project>
# is the working directory with every non-alphanumeric character replaced by "-", and a
# name over 200 characters is cut to 200 with a hash appended
# (https://code.claude.com/docs/en/sessions.md, "Where transcripts are stored").
set -euo pipefail
REPO=${SESSION_COST_TEST_REPO:-$(cd "$(dirname "$0")/.." && pwd -P)}
S="$REPO/template/.claude/skills/finish-feature/session-cost.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-session-cost.XXXXXX")
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)

PASS=0 FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
transcript() { # transcript DIR SID [CWD]
  mkdir -p "$1"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m1","model":"x","usage":{"input_tokens":5,"output_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' > "$1/$2.jsonl"
  if [ -n "${3:-}" ]; then
    jq -c --arg cwd "$3" '. + {cwd:$cwd}' "$1/$2.jsonl" > "$T/with-cwd"
    mv "$T/with-cwd" "$1/$2.jsonl"
  fi
}
sid_of() { jq -r .session 2>/dev/null; }

P="$T/my proj+v2@x"
mkdir -p "$P" "$T/home"
transcript "$T/home/.claude/projects/$(slug "$P")" aaaa-1
out=$(cd "$P" && env -u CLAUDE_CONFIG_DIR HOME="$T/home" bash "$S" --json 2>&1 | sid_of) || out=""
check 'default config dir, path with space, + and @' '[ "$out" = aaaa-1 ]'

transcript "$T/cfg/projects/$(slug "$P")" bbbb-2
out=$(cd "$P" && HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" bash "$S" --json 2>&1 | sid_of) || out=""
check 'CLAUDE_CONFIG_DIR is honoured' '[ "$out" = bbbb-2 ]'
out=$(cd "$P" && HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" bash "$S" --json --session bbbb-2 2>&1 | sid_of) || out=""
check '--session under CLAUDE_CONFIG_DIR' '[ "$out" = bbbb-2 ]'

L="$T/$(printf 'long-directory-name-%.0s' 1 2 3 4 5 6 7 8 9 10 11)"
mkdir -p "$L"
ls_=$(slug "$L")
transcript "$T/home/.claude/projects/${ls_:0:200}-1a2b3c" cccc-3 "$L"
out=$(cd "$L" && env -u CLAUDE_CONFIG_DIR HOME="$T/home" bash "$S" --json 2>&1 | sid_of) || out=""
check 'project name over 200 characters (truncated + hash)' '[ "$out" = cccc-3 ]'

# Hash suffixes are deliberately opaque fixtures: identity comes from cwd, never prefix.
A="$L/project-a"; B="$L/project-b"
mkdir -p "$A" "$B"
a_slug=$(slug "$A"); b_slug=$(slug "$B")
ROOT="$T/collisions/projects"
ADIR="$ROOT/${a_slug:0:200}-aaaaaa"
BDIR="$ROOT/${b_slug:0:200}-bbbbbb"
transcript "$BDIR" project-b "$B"
cost_a() { CLAUDE_CONFIG_DIR="$T/collisions" bash "$S" --dir "$A" --json "$@"; }
not_found() {
  local rc=0 out
  out=$(cost_a "$@" 2>&1) || rc=$?
  [ "$rc" != 0 ] && [[ "$out" == *"no transcript"* ]]
}
check 'review 3: only B exists, A must not report B costs' 'not_found'
check 'review 3: explicit B session does not belong to A' 'not_found --session project-b'
transcript "$ADIR" project-a "$A"
out=$(cost_a 2>/dev/null | sid_of) || out=""
check 'review 3: both directories exist, A selects its own transcript' '[ "$out" = project-a ]'
out=$(cost_a --session project-a 2>/dev/null | sid_of) || out=""
check 'review 3: both directories exist, explicit A session works' '[ "$out" = project-a ]'
check 'review 3: both directories exist, explicit B session is rejected' 'not_found --session project-b'
# A correct sibling is not evidence for another transcript in the same directory.
transcript "$ADIR" wrong-project "$B"
transcript "$ADIR" unknown-project
check 'review 3: candidate without recorded cwd is rejected' 'not_found --session unknown-project'
check 'review 3: candidate with mismatching cwd beside A is rejected' 'not_found --session wrong-project'
out=$(cost_a 2>/dev/null | sid_of) || out=""
check 'review 3: newest unverified candidates are skipped' '[ "$out" = project-a ]'
printf 'not json\n' > "$ADIR/malformed.jsonl"
check 'review 3: malformed candidate is rejected' 'not_found --session malformed'
transcript "$ADIR" later-a "$A"
touch -t 202601010000 "$ADIR/project-a.jsonl"
out=$(cost_a 2>/dev/null | sid_of) || out=""
check 'review 3: newest verified transcript is selected' '[ "$out" = later-a ]'

echo "session-cost-path: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
