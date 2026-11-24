#!/bin/bash
# /bin/bash tests/kill-guard.test.sh
# The process-kill guard in block-dangerous-bash.sh: pkill, killall, tmux kill verbs and the
# launchctl stop verbs are blocked wherever they run, including when the command text cannot
# be tokenized (2026-11-23: nested quotes inside $( ) inside double quotes made the tokenizer
# fail and the guard passed a `tmux kill-server` that took down the live tmux server).
# An explicit `tmux -L <name>` with a literal name (not "default", not the live socket) targets
# a server the caller started and is allowed; any -S keeps the block. Nothing here runs tmux:
# the hook only reads the command text.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$REPO/template/.claude/hooks/block-dangerous-bash.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/kill-guard-test.XXXXXX") || exit 2
trap '/bin/rm -rf "$T"' EXIT
mkdir -p "$T/home"; export HOME="$T/home"; cd "$T" || exit 2
unset MEGAVIBE_ALLOW_KILL MEGAVIBE_ALLOW_PROD_EXEC
PASS=0; FAIL=0
run() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | env -u TMUX ${2:+TMUX="$2"} bash "$HOOK" >/dev/null 2>&1; RC=$?; }
blocks() { run "$2" "${3:-}"; if [ "$RC" = 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL (not blocked, rc=%s): %s\n' "$RC" "$1"; fi; }
passes() { run "$2" "${3:-}"; if [ "$RC" = 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL (blocked, rc=%s): %s\n' "$RC" "$1"; fi; }

# 1. The 2026-11-23 command, verbatim shape, and the nested-quote variants that broke the tokenizer.
blocks "incident command" 'cd /tmp; export TMUX_TMPDIR=$(mktemp -d); tmux new-session -d -s abc; for t in =abc abc =abc: abc:; do echo "$t: $(tmux show-options -t "$t" status 2>&1)"; done; tmux kill-server'
blocks "incident command inside tmux" 'cd /tmp; export TMUX_TMPDIR=$(mktemp -d); tmux new-session -d -s abc; for t in =abc abc =abc: abc:; do echo "$t: $(tmux show-options -t "$t" status 2>&1)"; done; tmux kill-server' "/tmp/tmux-1/default,1,0"
blocks "nested quotes, then pkill" 'echo "$(printf "%s" "$x")"; pkill -f worker'
blocks "nested quotes, then killall" 'echo "a $(echo "b")"; killall node'
blocks "nested quotes, then launchctl bootout" 'echo "$(id -u "$u")"; launchctl bootout gui/501/com.example.agent'
blocks "nested quotes, then tmux kill-session" 'x="$(tmux display -p "#S")"; tmux kill-session -t "$x"'
blocks "unbalanced quote with a kill verb" 'echo "oops; tmux kill-server'
blocks "TMUX_TMPDIR does not isolate" 'TMUX_TMPDIR=$(mktemp -d) tmux kill-server'

# 2. Substitutions run, even inside double quotes; so do backticks, eval and find -exec.
blocks "\$( ) inside double quotes" 'echo "$(tmux kill-server)"'
blocks "backticks" 'echo `tmux kill-server`'
blocks "backticks inside double quotes" 'echo "`pkill x`"'
blocks "process substitution" 'cat <(tmux kill-server)'
blocks "nested substitution" 'echo "$(echo "$(killall node)")"'
blocks "eval quoted" 'eval "tmux kill-server"'
blocks "eval bare" 'eval tmux kill-server'
blocks "find -exec" 'find . -name x -exec tmux kill-server \;'
blocks "find -exec sh -c" "find . -exec sh -c 'pkill x' \\;"

# 3. bash -c, including a body the tokenizer cannot read.
blocks "bash -c" 'bash -c "tmux kill-server"'
blocks "bash -c with nested quotes" "bash -c 'echo \"\$(tmux show -t \"\$t\")\"; tmux kill-server'"
blocks "sh -c unbalanced body" "sh -c 'echo \"x; tmux kill-server'"
blocks "sudo pkill" 'sudo pkill -9 node'

# 4. -L / -S: a server the caller named. "default" and the live socket stay blocked.
passes "tmux -L name kill-server" 'tmux -L mvtest kill-server'
passes "tmux -Lname kill-server" 'tmux -Lmvtest kill-server'
passes "env -u TMUX tmux -L name kill-server" 'env -u TMUX tmux -L mvtest kill-server'
passes "tmux -L name kill-session" 'tmux -L mvtest kill-session -t a'
blocks "tmux -S path kill-server (only -L is allowed)" 'tmux -S /tmp/mvtest.sock kill-server'
passes "tmux -L inside tmux" 'tmux -L mvtest kill-server' "/tmp/tmux-1/default,1,0"
passes "recipe with nested quotes" 'env -u TMUX tmux -L mvt new -d -s a; for t in a; do echo "$(env -u TMUX tmux -L mvt show -t "$t" status)"; done; env -u TMUX tmux -L mvt kill-server'
blocks "tmux -L default" 'tmux -L default kill-server'
blocks "tmux -L variable" 'tmux -L "$name" kill-server'
blocks "tmux -S default socket" 'tmux -S /tmp/tmux-501/default kill-server'
blocks "tmux -S the live socket" 'tmux -S /tmp/live.sock kill-server' "/tmp/live.sock,1,0"
blocks "tmux -S variable" 'tmux -S "$sock" kill-server'
blocks "one -L, one bare" 'tmux -L mvtest kill-server; tmux kill-server'
blocks "nested quotes, -L then bare" 'echo "$(tmux -L a show -t "$t")"; tmux kill-server'

# 4b. From the sweep: tmux prefers -S over -L, paths are case-insensitive on macOS, tmux takes
# unique prefixes, aliases and ";"-separated command sequences, and some verbs run shell text.
blocks "-S default before -L name" 'tmux -S /tmp/tmux-501/default -L mvtest kill-server'
blocks "-L default before -L name" 'tmux -L default -L mvtest kill-server'
blocks "-S DEFAULT (case)" 'tmux -S /tmp/tmux-501/DEFAULT kill-server'
blocks "-L Default (case)" 'tmux -L Default kill-server'
blocks "-L naming the live socket" 'tmux -L pa kill-server' "/tmp/tmux-501/pa,1,0"
blocks "eval chain" 'eval eval eval eval eval eval eval eval tmux kill-server'
blocks "line continuation in the name" "$(printf 'tm\\\nux kill-server')"
blocks "quotes inside the name" "pk''ill -f worker"
passes "-vL name" 'tmux -vL mvtest kill-server'
passes "quoted heredoc keeps \$( ) inert" "$(printf 'cat <<\"EOF\"\n$(tmux kill-server)\nEOF')"
passes "tmux new with a harmless command" "tmux new -d -s work 'npm run dev'"
passes "launchctl print" 'launchctl print gui/501 | grep -c stop'
passes "ps grep tmux" "ps aux | grep '[t]mux'"

# 4c. From the second sweep.
passes "heredoc to python" "$(printf 'python3 - <<'"'"'EOF'"'"'\nprint(1)\nEOF')"

blocks "escaped quote, then pkill" 'echo "a \" b"; pkill x'
blocks "mid-word quote, then pkill" "x=a'b c'd; pkill y"
passes "escaped quote text only" 'echo "a \" pkill \" b"'

# 4d. From the ship round: a selector built by a substitution, a symlinked socket, a relative -S,
# tmux option values that are names, not commands.
blocks "-L from a substitution" 'tmux -L "$(printf %s mvtest)" kill-server'
blocks "-S from a substitution" 'tmux -S "$(printf %s /tmp/mvtest.sock)" kill-server'
blocks "-L from backticks" 'tmux -L `cat name` kill-server'
blocks "relative -S" 'tmux -S ./mvtest.sock kill-server'
mkdir -p "$T/sock/tmux-$(id -u)" && : > "$T/sock/tmux-$(id -u)/default" && ln -s default "$T/sock/tmux-$(id -u)/review"
if TMUX_TMPDIR="$T/sock" run 'tmux -L review kill-server' && [ "$RC" = 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL (not blocked, rc=$RC): -L name symlinked to default"; fi
ln -s "$T/sock/tmux-$(id -u)/default" "$T/abs.sock"
blocks "-S symlink to default" "tmux -S $T/abs.sock kill-server"
passes "new-session named pkill" 'tmux new-session -d -s pkill'
passes "new-window named killall" 'tmux new-window -n killall -t a'

# 4e. From the ship round (Claude): comments with apostrophes, tmux-command arguments, delimiters.
blocks "comment with apostrophes around a kill" "$(printf '# Clean up the old session (it'"'"'s stale)\ntmux kill-session -t old\n# Don'"'"'t touch the others\ntmux ls')"
blocks "comment in a loop" "$(printf '# we'"'"'ll retry\nfor i in 1 2; do\n  pkill -f worker\ndone\n# that'"'"'s all')"
passes "comment with an apostrophe and a kill word" "# don't do x pkill"
passes "hash inside a word is no comment" 'echo a#b; tmux ls'
blocks "hash inside a word, then a kill" 'echo a#b; pkill x'
passes "if-shell with -L name" "tmux -L mvtest if-shell true 'kill-server'"
passes "delimiter with a dash" "$(printf 'cat <<'"'"'END-MSG'"'"'\ntmux kill-server\nEND-MSG')"
passes "remote shell-fed heredoc" "$(printf 'ssh host bash -s <<'"'"'EOF'"'"'\npkill java\nEOF')"
blocks "kubectl port-forward" 'kubectl port-forward -n prod svc/x 8080'
passes "port-forward example in a PR heredoc" "$(printf 'gh pr create --body "$(cat <<'"'"'EOF'"'"'\nUsage:\nkubectl port-forward svc/x 8080\nEOF\n)"')"


# 4f. From ship round 2 (Codex).
passes "shell name in a heredoc line comment" "$(printf 'git commit -F - <<'"'"'EOF'"'"' # bash hook regression\ntmux kill-server\nEOF')"
passes "indented delimiter lookalike (exec guard)" "$(printf 'git commit -F - <<'"'"'EOF'"'"'\n  EOF\nLiteral example: $(kubectl exec -n prod pod -- env)\nEOF')"
blocks "<<- closes at a tab-indented delimiter" "$(printf 'cat <<-EOF\n\tdone\n\tEOF\npkill x')"
passes "bash -n here-string" "bash -n <<< 'tmux kill-server'"
passes "bash -n heredoc" "$(printf 'bash -n <<'"'"'EOF'"'"'\ntmux kill-server\nEOF')"
passes "tmux new with an argv payload" "tmux new-session -d printf %s 'pkill is blocked'"

# 4g. From ship round 2 (Claude): # inside nested quotes is no comment; trap, function, wrappers.
blocks "# in nested quotes, then a kill" 'echo "$(echo "a #b")"; tmux kill-server'
blocks "tmux format string, then a kill" 'echo "$(tmux list-windows -F "#{window_index} #{window_name}")" && tmux kill-server'
blocks "tmux format in an assignment, then a kill" 'x="$(tmux list-panes -F "#{pane_id} #{pane_pid}")"; echo "$x"; tmux kill-server'
blocks "date format, then killall" 'echo "$(date +"%Y #1")"; killall node'
passes "heredoc into a path containing bash" "$(printf 'cat > tests/bash/foo.sh <<'"'"'EOF'"'"'\npkill foo\nEOF')"
passes "send-keys argument ending in ;" "tmux send-keys -t x 'cd /tmp;' 'kill 1234' Enter"
passes "trap with a harmless handler" "trap 'echo done' EXIT"

# 4h. -L through a TMUX_TMPDIR set in the command; commit texts that once tripped a rewrite.
if run "TMUX_TMPDIR=$T/sock tmux -L review kill-server" && [ "$RC" = 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL (not blocked, rc=$RC): inline TMUX_TMPDIR, -L symlinked to default"; fi
blocks "non-literal TMUX_TMPDIR with -L" 'export TMUX_TMPDIR=$(mktemp -d); tmux -L mvtest kill-server'
passes "env -u TMUX recipe without TMUX_TMPDIR" 'env -u TMUX tmux -L mvtest new -d -s a; env -u TMUX tmux -L mvtest kill-server'
blocks "bash -c with comment apostrophes" "$(printf 'bash -c "# It'"'"'s stale\ntmux kill-server\n# Don'"'"'t leave it running"')"
passes "commit message quoting <<EOF" "$(printf 'git commit -m '"'"'Document the bash <<EOF example\nExplain why tmux kill-server is blocked.'"'"'')"
passes "commit heredoc with a quoted heading and kubectl" "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\n# The \"kubectl exec example\nUse kubectl exec -n prod pod -- env\" only when approved.\nEOF\n)"')"
passes "indented delimiter lookalike (exec guard)" "$(printf 'git commit -F - <<'"'"'EOF'"'"'\n  EOF\nLiteral example: $(kubectl exec -n prod pod -- env)\nEOF')"

blocks "clustered -vL with a separate default" 'tmux -vL default kill-server'
blocks "clustered -2S with the default socket" 'tmux -2S /tmp/tmux-501/default kill-server'
passes "clustered -vL with a separate name" 'tmux -vL mvtest kill-server'

# 4i. From the v2 ship round (Codex): comments, quoted TMUX_TMPDIR.
passes "search with a comment apostrophe" "rg -n 'pkill' template/.claude/hooks # don't edit yet"
passes "commented kubectl example" "$(printf '# Sample: $(kubectl exec -n prod pod -- env)\nkubectl get pods -n prod')"
blocks "comment apostrophes around a dq substitution kill" "$(printf '# it'"'"'s\necho "$(pkill x)"\n# don'"'"'t')"
blocks "unclosed quote then a substitution kill" "echo 'abc \$(pkill x)"
blocks "quoted TMUX_TMPDIR with -L" "env \"TMUX_TMPDIR=$T/so ck\" tmux -L review kill-server"
blocks "export TMUX_TMPDIR from a variable with -L" 'export TMUX_TMPDIR="$d"; tmux -L mvtest kill-server'
passes "hash inside a word" 'echo a#b; tmux ls'
blocks "hash inside a word, then a kill" 'echo a#b; pkill x'

# 4j. From the v2 ship round (Claude): grouped separators, escaped quotes, comments.
blocks "kill after a subshell" '(cd /tmp && ls); tmux kill-server'
blocks "pkill after a subshell, no space" '(echo a);pkill -f x'
blocks "kill in a subshell after a command" 'echo a;(tmux kill-server)'
blocks "kill after a backgrounded subshell" '(sleep 1 &); tmux kill-server'
passes "subshells without a kill" 'tmux ls; (cd /tmp && ls); echo ok'
blocks "escaped quote, then a kill" 'echo "a\"" ; tmux kill-server ; echo "x"'
blocks "escaped quote in a second word, then a kill" 'echo "a" "b\"" ; tmux kill-server ; echo "c"'
blocks "nested bash -c with escaped quotes" 'bash -c "bash -c \"tmux kill-server\""'
passes "echo with a kill word and a comment apostrophe" "echo \"pkill\" # it's fine"

# 4k. From v2 ship round 2 (Codex).
blocks "escaped space before #, then a kill" 'cd My\ #project && tmux kill-server'
blocks "escaped char before #, then pkill" 'echo a\;#b; pkill x'
passes "case arm inside \$( ) in commit text" 'git commit -m "$(case "$OSTYPE" in darwin*) echo "Document tmux kill-server";; *) echo "Document cleanup";; esac)"'
blocks "case arm inside \$( ) that kills" 'x="$(case a in a) tmux kill-server;; esac)"'
mkdir -p "$T/lv" && : > "$T/lv/live.sock" && ln -s live.sock "$T/lv/alias.sock"
blocks "-S naming the live socket through an alias" "tmux -S $T/lv/live.sock kill-server" "$T/lv/alias.sock,1,0"
blocks "-S alias of the live socket" "tmux -S $T/lv/alias.sock kill-server" "$T/lv/live.sock,1,0"

blocks "single-quoted trailing backslashes around a kill" "grep -c 'x\\' f; tmux kill-server; grep 'y\\' g"
blocks "single-quoted trailing backslash, killall" "echo \"a\" 'b\\'; killall node; echo 'c\\'"
blocks "three single-quoted backslash strings" "echo 'a\\' ; tmux kill-server ; echo 'b\\' ; echo 'c'"

# 4l. From v2 ship round 3 (Codex): word boundaries around substitutions, comments in $( ), case.
blocks "# right after a substitution, then a kill" 'echo $(date +%s)#cleanup; tmux kill-server'
blocks "# right after backticks, then pkill" 'echo `date`#x; pkill y'
blocks ") in a comment inside \$( ), then a kill" "$(printf 'echo "$(tmux list-sessions # 1) Inspect sessions\n  tmux kill-server\n)"')"
passes "case.sh path inside \$( ) in a commit" 'git commit -m "$(git log -1 --format=%s -- tests/case.sh)" -m "Cover tmux kill-server cleanup"'
passes ") in a comment, kubectl example in the comment" "$(printf 'echo "$(printf '"'"'%%s'"'"' ok # 1) Example: $(kubectl exec -n prod pod -- env)\n)"')"

blocks "# inside \${ }, then a kill" 'x=${l%% #*}; tmux kill-server'
blocks "# inside \${ } in a loop, then pkill" 'for l in a b; do x=${l%% #*}; echo $x; done; pkill -f foo'
blocks "# in \${//}, then pkill" 'echo ${x// #/}; pkill foo'
blocks "# in \${:-}, then a kill" 'echo a ${x:- #} ; tmux kill-server'
passes "a real comment after \${x}" 'echo a ${x} #c; tmux ls'

# 4m. From v2 ship round 4 (Codex).
blocks "TMUX_TMPDIR spelled in pieces with -L" "env TMUX_\"\"TMPDIR=$T/sock tmux -L review kill-server"
blocks "case argument, then kickstart -p -k" "printf '%s\n' \"\$(git log -1 --format=%s -- case README.md)\"; launchctl kickstart -p -k gui/501/com.example.worker"
blocks "case argument, then a quoted verb" "printf '%s\n' \"\$(git log -1 --format=%s -- case README.md)\"; tmux kill-\"server\""
passes "case argument in a commit" "git commit -m \"\$(git log -1 --format=%s -- case README.md)\" -m 'Document tmux kill-server behavior'"
passes "quoted pipe inside a substitution (exec guard)" "echo \"\$(echo kubectl describe pod foo '|' kubectl exec -it foo -- sh)\""
blocks "a real pipe inside a substitution (exec guard)" "echo \"\$(echo x | kubectl exec -i -n prod foo -- sh)\""
blocks "case keyword in a substitution, then a kill" 'x="$(case a in a) echo;; esac)"; tmux kill-server'

# 4n. From v2 ship round 4 (Claude).
passes "case argument in \$( ) with a kill word in prose" 'git commit -m "$(echo use case statements)" -m "mention pkill in docs"'
passes "env -u TMUX_TMPDIR with -L" 'env -u TMUX -u TMUX_TMPDIR tmux -L mvtest kill-server'
passes "TMUX_TMPDIR only mentioned in a comment" 'tmux -L mvtest kill-server # TMUX_TMPDIR is not set'

# 4o. From v2 ship round 5 (Codex): per-frame quote state, esac as an argument, +=, escapes.
blocks "nested quoted ) hides a kill" 'echo "$(echo "$(printf "%s" "ready)")"; tmux kill-server)"'
blocks "esac argument hides a later arm" 'echo "$(case cleanup in dry-run) echo esac;; production) echo yes;; *) tmux kill-server;; esac)"'
blocks "TMUX_TMPDIR+= with -L" 'export TMUX_TMPDIR+=/extra; tmux -L review kill-server'
passes "escaped quotes in bash -c inside \$( ) (exec guard)" 'echo "$(bash -c "kubectl get pods -o jsonpath=\"{.items[*].metadata.name}\"")"'
passes "escaped pipe inside \$( ) (exec guard)" 'echo "$(echo kubectl get pods \| kubectl exec -it foo -- sh)"'
blocks "nested \$( ) inside a quoted string in a body" 'x="$(echo "a $(tmux kill-server) b")"'
passes "arithmetic \$(( )) with a kill word in prose" 'echo $((1+2)) "pkill is blocked" | wc -c'

# 4p. From v2 ship round 6 (Codex).
passes "indented delimiter lookalike in a quoted commit heredoc" "$(printf 'git commit -F - <<'"'"'EOF'"'"'\n  EOF\nLiteral example: "$(tmux kill-server)"\nEOF')"
passes "comment with ); and a kill verb" 'tmux list-panes -F "#{pane_id}" # (run manually); tmux kill-pane -t %3'
blocks "<<- closes at a tab-indented delimiter, then a kill" "$(printf 'cat <<-EOF\n\tbody\n\tEOF\ntmux kill-server')"

blocks "<< in a string does not hide a later exec substitution" "$(printf 'echo "a << b"\necho "$(kubectl exec -n prod p -- ls)"')"
blocks "arithmetic << does not hide a later exec substitution" "$(printf 'x=$((1 << 3))\necho "$(kubectl exec -n prod p -- ls)"')"

# 4q. From v2 ship round 7 (Codex).
blocks "-L under sudo -u root" 'sudo -u root tmux -L review kill-server'
blocks "-L under sudo with env TMUX_TMPDIR" 'sudo -u root env TMUX_TMPDIR=/tmp/x tmux -L review kill-server'
passes "escaped parentheses inside \$( ) in a commit" 'git commit -m "$(echo Document cleanup \( tmux kill-server \))"'
passes "escaped semicolon inside \$( )" 'echo "$(echo a \; tmux kill-server)"'
blocks "real parentheses inside \$( ) still split" 'echo "$(echo a; (tmux kill-server))"'

# 4r. From v2 ship round 7 (Claude): unclosed << swallows later lines; exec guard keywords.
blocks "prose <<EOF in a commit, kill on the next line" "$(printf 'git commit -m "docs: mention <<EOF heredocs"\ntmux kill-server')"
blocks "arithmetic << then a kill on the next line" "$(printf 'echo "$((1 << SHIFT))"\ntmux kill-server')"
passes "dashed delimiter heredoc body mentions a kill" "$(printf 'cat <<'"'"'END-MSG'"'"'\ntmux kill-server\nEND-MSG')"
blocks "dashed delimiter heredoc, then a kill" "$(printf 'cat <<'"'"'END-MSG'"'"'\nnotes\nEND-MSG\ntmux kill-server')"
blocks "kubectl exec in a for loop" 'for p in a b; do kubectl exec -n prod $p -- ls; done'
blocks "kubectl exec in an if" 'if true; then kubectl exec -n prod p -- ls; fi'
blocks "kubectl exec in braces" 'true && { kubectl exec -n prod p -- ls; }'

# 4s. From v2 ship round 8 (Codex).
blocks "arithmetic << with a later numeric line, kill between" "$(printf 'width=$((1 << 8))\ntmux kill-server\ncat <<'"'"'EOF'"'"'\n8\nEOF')"
passes "quoted delimiter with a space (kill guard)" "$(printf 'git commit -m "$(cat <<'"'"'END NOTES'"'"'\nExample: `tmux kill-server`\nEND NOTES\n)"')"
passes "quoted delimiter with a space (exec guard)" "$(printf 'git commit -m "$(cat <<'"'"'END NOTES'"'"'\nExample: $(kubectl exec -n prod pod -- env)\nEND NOTES\n)"')"
passes "printenv TMUX" 'printenv TMUX'

# 4t. From v2 ship round 9 (Codex).
if TMUX_TMPDIR=run run 'cd fixture && tmux -L review kill-server' && [ "$RC" = 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL (not blocked, rc=$RC): relative inherited TMUX_TMPDIR with -L"; fi
passes "case pattern named pkill inside \$( ) in a commit" "git commit -m \"\$(case \"\${mode:-tmux}\" in tmux) echo 'Document tmux cleanup';; pkill) echo 'Document worker cleanup';; esac)\""
blocks "case arm body that kills" 'x="$(case a in a) tmux kill-server;; esac)"'
blocks "case arm body that kills, top level" 'case $m in stop) pkill -f worker;; esac'

# 4u. From v2 ship round 9 (Claude): the common multi-pod exec shapes.
blocks "for loop over \$(kubectl get) then exec" 'for p in $(kubectl get pods -n prod -o name); do kubectl exec -n prod "$p" -- ls; done'
blocks "POD=\$(...); kubectl exec" 'POD=$(kubectl get pod -n prod -l app=x -o name); kubectl exec -n prod "$POD" -- env'
blocks "subshell then kubectl exec" '(echo a); kubectl exec -n prod p -- ls'
passes "the same against staging" 'POD=$(kubectl get pod -n staging -o name); kubectl exec -n staging "$POD" -- env'
passes "commented exec example before a read" "$(printf '# Sample: $(kubectl exec -n prod pod -- env)\nkubectl get pods -n prod')"

# 4v. From v2 ship round 10 (Codex).
passes "bash array holding an exec command, printed" 'cmd=(kubectl exec -n prod deploy/api -- printenv); declare -p cmd'
blocks "bash array then a real exec" 'cmd=(echo hi); kubectl exec -n prod p -- ls'
_big=$(python3 -c 'print("python3 -c \x27match \"tmux kill-server\":\n" + "".join("    case x if x in (\"case-%d\",): pass\n" % i for i in range(300)) + "\x27")')
_t0=$(python3 -c 'import time; print(time.time())'); run "$_big"; _t1=$(python3 -c 'import time; print(time.time())')
if [ "$RC" = 0 ] && python3 -c "import sys; sys.exit(0 if $_t1 - $_t0 < 2.0 else 1)"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL (rc=$RC or slow): 300 case words without esac under 2 s"; fi

# 4w. From v2 ship round 11 (Codex): -S dropped from the exception, links, commas, quoted ;, heredoc in bash -c.
blocks "-S with a comma in the live socket path" 'tmux -S /tmp/project,review/live.sock kill-server' "/tmp/project,review/live.sock,123,0"
blocks "-L naming the live socket whose path holds a comma" 'tmux -L live.sock kill-server' "/tmp/project,review/live.sock,123,0"
blocks "symlink made in the same command, then -L" 'ln -s /tmp/tmux-501/default /tmp/tmux-501/review && tmux -L review kill-server'
passes "-L after other work" 'env -u TMUX tmux -L mvtest new -d -s a; sleep 1; env -u TMUX tmux -L mvtest kill-server'
passes "quoted ; in an attached --message (exec guard)" 'git commit --message="Document debugging; kubectl exec -n prod pod -- env is guarded"'
passes "quoted heredoc inside bash -c mentions a kill" "$(printf 'bash -c '"'"'cat > notes.md <<"EOF"\nHere is an example: $(tmux kill-server)\nEOF'"'"'')"
blocks "unquoted heredoc inside bash -c runs a kill" "$(printf 'bash -c '"'"'cat <<EOF\n$(tmux kill-server)\nEOF'"'"'')"

# 4x. From v2 ship round 12 (Codex): quoted flag values in the exec guard.
passes "quoted non-prod namespace" 'kubectl exec -n "staging" deploy/api -- env'
passes "quoted attached namespace" 'kubectl exec --namespace="staging" deploy/api -- env'
passes "quoted non-prod context" "kubectl exec --context='dev-cluster' deploy/api -- env"
passes "quoted --help" 'kubectl exec "--help"'
blocks "quoted prod namespace" 'kubectl exec -n "prod" deploy/api -- env'

# 4y. Top-level unquoted heredoc bodies: their substitutions run.
blocks "unquoted heredoc body runs \$(tmux kill-server)" "$(printf 'cat <<EOF\nstatus: $(tmux kill-server)\nEOF')"
blocks "unquoted heredoc body runs backticks" "$(printf 'cat > f <<EOF\n`pkill -f worker`\nEOF')"
passes "quoted heredoc body keeps \$( ) inert (top level)" "$(printf 'cat <<'"'"'EOF'"'"'\nstatus: $(tmux kill-server)\nEOF')"
passes "unquoted heredoc body with a harmless substitution" "$(printf 'cat <<EOF\ndate: $(date)\nnote: never run tmux kill-server\nEOF')"

# 4z. From v2 ship round 13 (Codex).
passes "quoted ; mid-word inside \$( ) (exec guard)" "git commit -m \"\$(git log -1 --pretty=format:'Debugging; kubectl exec -n prod pod -- env')\""
blocks "a real ; then exec inside \$( )" 'echo "$(echo a; kubectl exec -n prod pod -- env)"'
passes "escaped \$( in an unquoted heredoc body" "$(printf 'git commit -F - <<EOF\nUse \\$(tmux kill-server) only for cleanup.\nEOF')"
passes "escaped backticks in an unquoted heredoc body" "$(printf 'cat <<EOF\nrun \\`pkill -f worker\\` by hand\nEOF')"
blocks "escaped backslash, then a live \$( in a heredoc body" "$(printf 'cat <<EOF\nUse \\\\\\\\$(tmux kill-server) now.\nEOF')"
blocks "unescaped \$( in the same heredoc shape" "$(printf 'git commit -F - <<EOF\nUse $(tmux kill-server) only for cleanup.\nEOF')"

# 4aa. From v2 ship round 14 (Codex).
mkdir -p "$T/kube" && printf 'apiVersion: v1\nkind: Config\ncurrent-context: docker-desktop\n' > "$T/kube/config"
if KUBECONFIG="$T/kube/config" run "$(printf '# Don'"'"'t forget the context\nkubectl --context prod-cluster exec -n prod deploy/api -- env')" && [ "$RC" = 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL (not blocked, rc=$RC): unbalanced-quote fallback under a local kube context"; fi
passes "bash -c with a quoted ; and kubectl exec --help" "bash -c 'kubectl exec --help; printf \"\\n\"'"
passes "command -v pkill inside \$( )" "printf '%s\n' \"\$(command -v pkill)\""
passes "command -v tmux" 'command -v tmux && tmux ls'
blocks "command pkill (runs it)" 'command pkill -f worker'

blocks "-L . (a directory)" 'tmux -L . kill-server'
blocks "-L .." 'tmux -L .. kill-server'

# 4bb. From v2 ship round 15 (Codex).
mkdir -p "$T/sock2/tmux-$(id -u)" && : > "$T/sock2/tmux-$(id -u)/smoke" && ln -s smoke "$T/sock2/tmux-$(id -u)/default"
if TMUX_TMPDIR="$T/sock2" run 'tmux -L smoke kill-server' && [ "$RC" = 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL (not blocked, rc=$RC): -L name that default points to"; fi
passes "heredoc example inside a single-quoted commit message" "$(printf 'git commit -m '"'"'Document the heredoc example:\ncat <<EOF\n$(tmux kill-server)\nEOF\n'"'"'')"
passes "array literal printed inside \$( )" 'echo "$(cmd=(pkill -f worker); declare -p cmd)"'
blocks "array literal then a real kill inside \$( )" 'echo "$(cmd=(x); pkill -f worker)"'

# 4cc. From v2 ship round 16 (Codex).
blocks "bash -c smoke test: comment, arithmetic <<, kill, heredoc" "$(printf 'bash -c '"'"'# Run the smoke test\nwidth=$((1 << 8))\ntmux kill-server\ncat <<EOF\n8\nEOF\n'"'"'')"
blocks "same shape with pkill" "$(printf 'bash -c '"'"'# Run the smoke test\nwidth=$((1 << 8))\npkill -f worker\ncat <<EOF\n8\nEOF\n'"'"'')"
passes "quoted ) in a case pattern, kill word printed" "case \"\$line\" in \"cleanup)\"*) echo 'tmux kill-server test';; esac"
blocks "quoted ) in a case pattern, kill in the arm" "case \"\$line\" in \"cleanup)\"*) tmux kill-server;; esac"

# 4dd. From v2 ship round 17 (Codex).
passes "quoted commit heredoc quoting a kubectl loop" "$(printf 'git commit -F - <<'"'"'EOF'"'"'\nDocument the approved debugging loop:\nfor pod in pod-a pod-b; do kubectl exec -n prod "$pod" -- printenv; done\nEOF')"
blocks "the same loop as a live command" 'for pod in pod-a pod-b; do kubectl exec -n prod "$pod" -- printenv; done'
passes "quoted staging context with a space, attached" 'kubectl exec --context="Team A/staging" deploy/api -- printenv'
passes "multi-line case with a pattern named pkill in \$( )" "$(printf 'git commit -m "$(case "$cmd" in\n  pkill) echo '"'"'Document worker cleanup'"'"';;\n  *) echo '"'"'Document cleanup'"'"';;\nesac)"')"
blocks "multi-line case with pkill in the arm body" "$(printf 'x="$(case "$cmd" in\n  stop) pkill -f worker;;\nesac)"')"

# 5. Text that only mentions kill verbs stays allowed.
passes "heredoc body mentions kill-server" "$(printf 'cat > notes.md <<EOF\nnever run tmux kill-server or pkill here\nEOF')"
passes "quoted heredoc body with nested quotes" "$(printf 'cat <<'"'"'EOF'"'"'\necho "\$(tmux show -t "\$t")"; tmux kill-server\nEOF')"
passes "commit message from a heredoc" "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nguard: block `tmux kill-server` and "$(pkill x)"\nEOF\n)"')"
passes "capture-pane with nested substitution" 'tmux capture-pane -p -t "$(tmux display -p "#S")"'
passes "commit message" "git commit -m 'guard: block tmux kill-server and pkill'"
passes "echo in double quotes" 'echo "do not tmux kill-server"'
passes "grep pattern" "grep -n 'kill-server\\|pkill' file.sh"
passes "tmux ls" 'tmux ls'
passes "tmux with nested quotes, no kill" 'for t in a b; do echo "$t: $(tmux show-options -t "$t" status 2>&1)"; done'
passes "kill a pid" 'kill $!'
passes "escape hatch inline" 'MEGAVIBE_ALLOW_KILL=1 tmux kill-server'

# 6. The exec guard: a substitution inside double quotes runs too.
blocks "kubectl exec inside \"\$( )\"" 'echo "$(kubectl exec -n prod pod -- env)"'
blocks "kubectl exec in backticks" 'echo `kubectl exec -n prod pod -- env`'
passes "kubectl exec example in a commit heredoc" "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nDocument the literal example: $(kubectl exec -n prod pod -- env)\nEOF\n)"')"
passes "kubectl exec named only in text" "git commit -m 'never kubectl exec -n prod'"

PYX=$(sed -n '/_VERDICT=$(printf/,/|| echo died)/p' "$HOOK" | sed '1d;$d')
if [ -n "$PYX" ] && [ "$(printf 'kubectl get pods' | python3 -W error -c "$PYX" 2>&1)" = ok ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: exec guard python does not compile cleanly"; fi
# 6b. A python that fails blocks (both guards), it does not pass.
mkdir -p "$T/badpy" && printf '#!/bin/sh\nexit 1\n' > "$T/badpy/python3" && chmod +x "$T/badpy/python3"
for c in 'tmux kill-server' 'kubectl exec -n prod pod -- env' 'sudo pkill -f worker' 'x; killall node' 'launchctl bootout gui/501/x' 'kubectl -n prod exec p -- ls' 'kubectl --context=prod exec p -- ls'; do
  jq -n --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}' | env -u TMUX PATH="$T/badpy:$PATH" bash "$HOOK" >/dev/null 2>&1; RC=$?
  if [ "$RC" = 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL (python failure passed, rc=$RC): $c"; fi
done
# ... but only for the verbs the guards exist for: a broken python3 shim must not block everyday work
for c in 'tmux ls' 'cargo check --all' 'kubectl get pods -n prod' 'git log --oneline | grep k ' 'kubectl logs deploy/executor -n prod' 'kubectl logs deploy/proxy -n prod' 'git commit -m "remove pkill usage"' 'grep -rn pkill src/' 'echo "debug: ok" && kubectl version' 'git commit -m "undo pkill change"' 'kubectl logs deploy/api -c proxy -n prod' 'kubectl get cm debug -n prod'; do
  jq -n --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}' | env -u TMUX PATH="$T/badpy:$PATH" bash "$HOOK" >/dev/null 2>&1; RC=$?
  if [ "$RC" = 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL (python failure blocked an everyday command, rc=$RC): $c"; fi
done

# 6c. The python of both guards sits inside a single-quoted bash string: one apostrophe in it
# (even in a comment) ends the string early, and the kill guard then blocks every tmux call.
for sect in kill exec; do
  case $sect in kill) a='_KV=$(printf'; b='|| echo died)' ;; exec) a='_VERDICT=$(printf'; b='|| echo died)' ;; esac
  body=$(awk -v a="$a" -v b="$b" 'index($0, a) {f=1; next} f && index($0, b) {exit} f' "$HOOK")
  if [ -n "$body" ] && ! printf '%s' "$body" | grep -q "'"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: a single quote in the $sect guard python"; fi
done

# 6d. A python3 that exits 0 and prints nothing is treated as one that died.
mkdir -p "$T/silentpy" && printf '#!/bin/sh\nexit 0\n' > "$T/silentpy/python3" && chmod +x "$T/silentpy/python3"
for c in 'tmux kill-server' 'kubectl exec -n prod pod -- env'; do
  jq -n --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}' | env -u TMUX PATH="$T/silentpy:$PATH" bash "$HOOK" >/dev/null 2>&1; RC=$?
  if [ "$RC" = 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL (silent python passed, rc=$RC): $c"; fi
done

# 7. The embedded python must compile cleanly: a SyntaxError would send every call to the died fallback.
PY=$(sed -n '/_KV=$(printf/,/|| echo died)/p' "$HOOK" | sed '1d;$d')
if [ -n "$PY" ] && [ "$(printf 'tmux ls' | python3 -I -W error -c "$PY" 2>&1)" = ok ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: kill guard python does not compile cleanly"; fi

printf 'kill-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
