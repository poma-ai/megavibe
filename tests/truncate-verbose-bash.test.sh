#!/bin/bash
# /bin/bash tests/truncate-verbose-bash.test.sh
# The rewritten command must return the original command's exit status, in
# bash 3.2 and zsh, with the trimmed output and the teed log unchanged.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
H="$REPO/template/.claude/hooks/truncate-verbose-bash.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/trunc-verbose.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

mkdir -p "$T/p/.agent" "$T/bin"
# Fake npm: FAKE_LINES lines, odd ones on stderr, then exit FAKE_RC.
cat > "$T/bin/npm" <<'EOF'
#!/bin/bash
i=1; while [ "$i" -le "${FAKE_LINES:-120}" ]; do
  if [ $((i % 2)) -eq 1 ]; then echo "line $i" >&2; else echo "line $i"; fi; i=$((i + 1)); done
exit "${FAKE_RC:-0}"
EOF
# Fake git: FAKE_LINES lines then exit FAKE_RC; FAKE_RC=pipe streams until
# head closes the pipe, so the process dies of SIGPIPE as real git does.
cat > "$T/bin/git" <<'EOF'
#!/bin/bash
[ "${FAKE_RC:-0}" = pipe ] && exec seq 1 1000000
seq 1 "${FAKE_LINES:-10}"; exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/bin/npm" "$T/bin/git"
# A real repository whose git log -p runs far past 500 lines.
if git init -q "$T/g" 2>/dev/null; then
  (cd "$T/g" && seq 1 5000 > f && git add f && git -c user.name=t -c user.email=t@example.invalid commit -qm init) >/dev/null 2>&1
fi

hook() { # hook <command> -> prints the hook's JSON (empty when not rewritten)
  jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c,timeout:5000}}' | (cd "$T/p" && bash "$H")
}
rewritten() { hook "$1" | jq -r '.hookSpecificOutput.updatedInput.command // empty'; }

# run <shell> <command> -> stdout+stderr of the rewritten command in $OUT, status in $RC
run() {
  local cmd; cmd=$(rewritten "$2")
  [ -n "$cmd" ] || { OUT="(not rewritten)"; RC=x; return; }
  OUT=$(cd "$T/p" && PATH="$T/bin:$PATH" "$1" -c "$cmd" 2>&1); RC=$?
}

for sh in /bin/bash zsh; do
  sh_n=$(basename "$sh")
  command -v "$sh" >/dev/null || { bad "$sh not found"; continue; }
  for c in "npm install" "npm ci --silent"; do
    for rc in 0 3; do
      rm -f "$T/p/.agent/LOGS/"*.log
      FAKE_LINES=120 FAKE_RC=$rc run "$sh" "$c"
      [ "$RC" = "$rc" ] && ok || bad "$sh: '$c' exiting $rc returned $RC"
      [ "$OUT" = "$(seq 71 120 | sed 's/^/line /')" ] && ok || bad "$sh: '$c' rc=$rc trimmed output changed"
      log=$(ls "$T/p/.agent/LOGS/"*.log 2>/dev/null | head -1)
      [ -n "$log" ] && [ "$(sort -t' ' -k2 -n "$log")" = "$(seq 1 120 | sed 's/^/line /')" ] && ok \
        || bad "$sh: '$c' rc=$rc log missing lines"
    done
  done
  FAKE_LINES=10 FAKE_RC=0 run "$sh" "git log -p"
  [ "$RC" = 0 ] && [ "$OUT" = "$(seq 1 10)" ] && ok || bad "$sh: git log -p success returned $RC"
  FAKE_LINES=10 FAKE_RC=128 run "$sh" "git log -p nosuchrev"
  [ "$RC" = 128 ] && [ "$OUT" = "$(seq 1 10)" ] && ok || bad "$sh: git log -p failing 128 returned $RC"
  FAKE_RC=pipe run "$sh" "git log --all -p"
  [ "$RC" = 0 ] && [ "$OUT" = "$(seq 1 500)" ] && ok || bad "$sh: git log -p cut by head returned $RC (want 0, 500 lines)"
  # A command after the rewritten one sees its status.
  cmd=$(rewritten "npm install")
  out=$(cd "$T/p" && FAKE_RC=4 PATH="$T/bin:$PATH" "$sh" -c "$cmd && echo NEXT; echo rc=\$?" 2>&1 | tail -1)
  [ "$out" = "rc=4" ] && ok || bad "$sh: '&& next; echo \$?' after failing npm saw [$out]"
  # A log tee cannot write does not turn npm's success into a failure.
  cmd=$(rewritten "npm install"); mv "$T/p/.agent/LOGS" "$T/p/.agent/L0"; : > "$T/p/.agent/LOGS"
  out=$(cd "$T/p" && FAKE_LINES=60 FAKE_RC=0 PATH="$T/bin:$PATH" "$sh" -c "$cmd" 2>/dev/null); trc=$?
  mv "$T/p/.agent/LOGS" "$T/p/.agent/Lfile.$sh_n"; mv "$T/p/.agent/L0" "$T/p/.agent/LOGS"
  [ "$trc" = 0 ] && [ "$out" = "$(seq 11 60 | sed 's/^/line /')" ] && ok || bad "$sh: unwritable log turned success into $trc"
  # SIGPIPE ignored by the caller: git still reports the cut as success.
  if [ -d "$T/g/.git" ]; then
    (cd "$T/g" && "$sh" -c "trap '' PIPE; $(rewritten "git log -p")" >/dev/null 2>&1); grc=$?
    [ "$grc" = 0 ] && ok || bad "$sh: git log -p with SIGPIPE ignored returned $grc"
  fi
  # A trailing comment must not swallow the wrapper (it comments out the trim).
  FAKE_LINES=3 FAKE_RC=5 run "$sh" "npm install # note"
  [ "$RC" = 5 ] && ok || bad "$sh: 'npm install # note' exiting 5 returned $RC"
  # Real git, cut by head: success stays success.
  if [ -d "$T/g/.git" ]; then
    out=$(cd "$T/g" && "$sh" -c "$(rewritten "git log -p")" 2>/dev/null); grc=$?
    [ "$grc" = 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 500 ] && ok || bad "$sh: real git log -p | head returned $grc"
  fi
done

# Compound commands and multi-line commands are left alone.
for c in "npm install && echo x" "npm install; echo \$?" "npm install | cat" "npm install &" "npm install x) & (echo y" "$(printf 'npm install x\necho done')"; do
  [ -z "$(hook "$c")" ] && ok || bad "rewrote compound command: $c"
done
# Other tool_input fields survive the rewrite.
[ "$(hook "npm ci" | jq -r '.hookSpecificOutput.updatedInput.timeout')" = 5000 ] && ok || bad "timeout dropped"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
