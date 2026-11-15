#!/bin/bash
# /bin/bash tests/remote-delete.test.sh
# The remote-delete guard in block-dangerous-bash.sh: a delete inside an ssh payload, a
# script sent to a remote shell on stdin, sftp batch text and rsync --delete towards a
# remote side go to the permission prompt (permissionDecision "ask") with the host and the
# paths named. Nothing here connects anywhere: the hook only reads the command text.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$REPO/template/.claude/hooks/block-dangerous-bash.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/remote-delete-test.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap '/bin/rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# a stand-in rmtrash, so the local real-delete guard is active as on a set-up Mac
mkdir -p "$T/bin" "$T/cwd" "$T/home"; printf '#!/bin/bash\nexit 0\n' > "$T/bin/rmtrash"; chmod +x "$T/bin/rmtrash"
export HOME="$T/home"
cd "$T/cwd" || exit 2
export PATH="$T/bin:$PATH"
printf 'cd /srv/app\nrm -rf releases/old\n' > "$T/cwd/del.sh"
printf 'cd /srv/app\ngit pull\nls releases\n' > "$T/cwd/plain.sh"
printf 'rm /upload/old.zip\nbye\n' > "$T/cwd/batch.txt"

run() {   # run <command text>: sets RC, OUT (stdout), WHY (the ask reason, empty if none)
  OUT=$(jq -n --arg c "$1" --arg d "$T/cwd" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | bash "$HOOK" 2>/dev/null); RC=$?
  WHY=$(printf '%s' "$OUT" | jq -r 'select(.hookSpecificOutput.permissionDecision == "ask") | .hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
}
asks() {  # asks <name> <command> [text the reason must contain]...
  local name=$1; run "$2"; shift 2
  if [ "$RC" != 0 ] || [ -z "$WHY" ]; then bad "$name (rc=$RC, no ask)"; return; fi
  local s; for s in "$@"; do case "$WHY" in *"$s"*) ;; *) bad "$name (reason lacks: $s)"; return ;; esac; done
  ok
}
passes() { run "$2"; if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "$1 (rc=$RC out=${OUT:0:80})"; fi; }
blocks() { run "$2"; if [ "$RC" = 2 ]; then ok; else bad "$1 (rc=$RC)"; fi; }
# stops: asked about, or blocked by the local guard (a shell word outside the quotes): never a silent pass
stops() { run "$2"; if [ "$RC" = 2 ] || [ -n "$WHY" ]; then ok; else bad "$1 (rc=$RC, passed silently)"; fi; }

# 1. The 2026-11-15 shapes: an approved purge with an appended path, a staging copy, one file.
asks "purge plus an appended rm names both" \
  "ssh -o BatchMode=yes -o ConnectTimeout=15 user@host.example 'cd /srv/app && before=\$(ls errors | wc -l) && find errors -maxdepth 1 -type f -name \"sql-*.log\" -mtime +90 -print0 | xargs -0 -r rm -f && echo \"errors: \$before -> \$(ls errors | wc -l)\"; ls -la errors/.htaccess | cut -c1-60; rm -f /archive-today.tar.gz 2>/dev/null; ls /Downloads | wc -l'" \
  "user@host.example" "find errors" "/archive-today.tar.gz"
asks "rm -r of a directory" "ssh user@host.example 'rm -r /staging-copy && cd /srv/app && git worktree prune'" "/staging-copy"
asks "a single rm -f" "ssh user@host.example 'rm -f /archive-today.tar.gz'" "/archive-today.tar.gz"

# 2. Other spellings of a remote delete.
asks "unquoted remote command" "ssh host.example rm -f /tmp/x" "/tmp/x"
asks "options with values before the host" "ssh -p 2222 -i ~/.ssh/id -l deploy host.example 'rmdir /srv/empty'" "host.example" "/srv/empty"
asks "find -delete in a quoted remote command" "ssh host.example 'find logs -mtime +90 -delete'" "find -delete"
asks "find -exec rm" "ssh host.example 'find /var/tmp -name \"*.old\" -exec rm {} +'" "find -exec rm"
asks "sudo sh -c" "ssh host.example \"sudo sh -c 'rm -rf /var/cache/app'\"" "/var/cache/app"
asks "inside a command substitution" "ssh host.example 'echo \"left: \$(rm -f /tmp/a; ls | wc -l)\"'" "/tmp/a"
asks "git clean on the remote side" "ssh host.example 'cd /srv/app && git clean -fdx'" "git clean"
asks "interpreter code that deletes" "ssh host.example 'python3 -c \"import shutil; shutil.rmtree(\\\"/srv/x\\\")\"'" "rmtree"
asks "behind timeout" "timeout 30 ssh host.example 'unlink /srv/link'" "/srv/link"
asks "behind sshpass" "sshpass -p secret ssh host.example 'rm /srv/a'" "/srv/a"
asks "in a loop over hosts" 'for h in a.example b.example; do ssh "$h" "rm -f /tmp/lock"; done' "/tmp/lock"
stops "through bash -c" "bash -c \"ssh host.example 'rm /srv/a'\"" "/srv/a"
asks "an ssh inside the remote command" "ssh jump.example \"ssh inner.example 'rm /srv/a'\"" "inner.example"
asks "multi-line payload" "ssh host.example '
cd /srv/app
rm -rf releases/old
'" "releases/old"

# 3. A script sent to a remote shell on stdin.
stops "heredoc into bash -s" "ssh host.example bash -s <<'EOF'
cd /srv/app
rm -rf releases/old
EOF" "releases/old" "heredoc"
asks "heredoc with no remote command" "ssh host.example <<EOF
rm /srv/a
EOF" "/srv/a"
asks "a script file redirected into a remote shell" "ssh host.example 'bash -s' < del.sh" "releases/old" "del.sh"
asks "the same through cat and a pipe" "cat del.sh | ssh host.example bash" "releases/old"
stops "echo piped into a remote shell" "echo 'rm /srv/a' | ssh host.example sh" "/srv/a"
stops "a here-string" "ssh host.example bash <<< 'rm /srv/a'" "/srv/a"
asks "a script file the guard cannot read" "ssh host.example 'bash -s' < missing.sh" "cannot read"
asks "a script path in a variable" 'ssh host.example bash -s < "$SCRIPT"' "cannot read"
asks "another command's output as the script" "sed 's/a/b/' plain.sh | ssh host.example bash" "cannot read"
passes "a script file without a delete" "ssh host.example 'bash -s' < plain.sh"
passes "data on stdin to a remote command that is not a shell" "gzip -dc dump.gz | ssh host.example 'cat > /tmp/dump'"
passes "a heredoc without a delete" "ssh host.example bash -s <<'EOF'
cd /srv/app && git pull
EOF"

# 4. sftp and rsync.
asks "sftp heredoc" "sftp user@host.example <<EOF
cd /upload
rm old.zip
EOF" "old.zip"
asks "sftp batch file" "sftp -b batch.txt user@host.example" "/upload/old.zip"
passes "sftp download" "sftp user@host.example <<EOF
get report.csv
EOF"
asks "rsync --delete towards a remote side" "rsync -a --delete build/ user@host.example:/srv/app/" "/srv/app/"
asks "rsync --delete-after with -e" "rsync -az -e 'ssh -p 2222' --delete-after build/ host.example:/srv/app/" "/srv/app/"
asks "rsync --remove-source-files from a remote side" "rsync -a --remove-source-files host.example:/srv/out/ ./in/" "/srv/out/"
passes "rsync --delete as a dry run" "rsync -an --delete build/ user@host.example:/srv/app/"
passes "rsync without a deleting option" "rsync -a build/ user@host.example:/srv/app/"
passes "rsync --delete pulling to a local directory" "rsync -a --delete user@host.example:/srv/app/ ./mirror/"

# 5. No delete: untouched (exit 0, no output).
passes "ls and git status" "ssh host.example 'ls; git status'"
passes "moving into a quarantine folder" "ssh host.example 'mkdir -p ~/.megavibe-quarantine/2026-11-15 && mv -n -- /srv/a ~/.megavibe-quarantine/2026-11-15/'"
passes "rm as a grep pattern" "ssh host.example 'grep -c rm /var/log/app.log'"
passes "rm inside echoed text" "ssh host.example 'echo \"rm is only a word here\"'"
passes "a file name containing rm" "ssh host.example 'cat /etc/rm.conf; systemctl status rm-cleanup.service'"
passes "docker rm is not a file delete" "ssh host.example 'docker ps -a'"
passes "a commit message that mentions ssh and rm" "git commit -m 'guard: ssh host rm -f /x is now asked about'"
passes "scp" "scp report.csv user@host.example:/srv/in/"
passes "an interactive-style ssh with no command" "ssh host.example"
passes "ssh-keygen and friends" "ssh-keygen -R host.example; ssh-add -l"
passes "a command with none of the three words" "ls -la"

# 6. Together with the local real-delete guard.
blocks "a local interpreter delete next to a remote delete stays blocked" "ssh host.example 'rm /srv/a'; python3 -c 'import shutil; shutil.rmtree(\"build\")'"
blocks "a local find -delete with a harmless ssh" "ssh host.example ls; find . -name '*.tmp' -delete"
# the human's switch for the local guard does not open the remote rule
OUT=$(jq -n --arg c "ssh host.example 'rm /srv/a'" '{tool_input:{command:$c}}' | MEGAVIBE_ALLOW_REAL_DELETE=1 bash "$HOOK" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then ok; else bad "MEGAVIBE_ALLOW_REAL_DELETE=1 must not open remote deletes"; fi
mkdir -p "$T/jqonly"; ln -sf "$(command -v jq)" "$T/jqonly/jq"      # a PATH without rmtrash
OUT=$(jq -n --arg c "ssh host.example 'rm /srv/a'" '{tool_input:{command:$c}}' | PATH="$T/jqonly:/usr/bin:/bin" /bin/bash "$HOOK" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then ok; else bad "asked without rmtrash too (a remote rule needs no local Trash)"; fi

# 6b. Round-1 review findings (2026-11-15), each failing before its fix.
blocks "a local find -delete stays blocked next to the same text run remotely" "ssh host.example 'find build -delete'; find build -delete"
asks "a comment line in a multi-line remote script hides nothing" "ssh host.example '
# Clean expired release
rm -rf /srv/releases/old
'" "/srv/releases/old"
asks "interpreter code is shown, so both targets are visible" "ssh host.example 'python3 -c \"import os; os.remove(\\\"/srv/approved\\\"); os.remove(\\\"/srv/unapproved\\\")\"'" "/srv/approved" "/srv/unapproved"
asks "git clean shows its operands" "ssh host.example 'git clean -fd -- /srv/app/cache /srv/important'" "/srv/important"
LONG=$(i=0; while [ $i -lt 400 ]; do printf '/srv/logs/file-%04d.log ' $i; i=$((i + 1)); done)
asks "an over-long path list says it is incomplete" "ssh host.example 'rm ${LONG}/srv/secret'" "INCOMPLETE"
asks "printf piped into a remote login shell" "printf '%s\\n' 'rm /srv/old' | ssh host.example" "/srv/old"
asks "echo -n piped into a remote login shell" "echo -n 'rm /srv/old' | ssh host.example" "/srv/old"
asks "lftp -e on an ftp host" "lftp -e 'rm /upload/old.zip; bye' ftp.example" "ftp.example" "/upload/old.zip"
passes "rsync --delay-updates is not a deleting option" "rsync -a --delay-updates build/ host.example:/srv/app/"
passes "a remote rsync dry run" "ssh host.example 'rsync -an --delete /srv/a/ /srv/b/'"
asks "a remote rsync --delete" "ssh host.example 'rsync -a --delete /srv/a/ /srv/b/'" "/srv/b/"
passes "sftp -b - reads its batch from stdin: a download" "sftp -b - host.example <<'EOF'
get report.csv
bye
EOF"
asks "sftp -b - with a delete in the stdin batch" "sftp -b - host.example <<'EOF'
rm /upload/old.zip
EOF" "/upload/old.zip"
asks "ssh -M is a flag, the next word is the host" "ssh -M host.example 'rm /srv/old'" "host.example" "/srv/old"
asks "autossh -M takes a port" "autossh -M 0 host.example 'rm /srv/old'" "host.example" "/srv/old"
passes "a literal command substitution in a single-quoted commit message" "git commit -m 'Document \$(ssh host.example rm /srv/old)'"
asks "a command substitution that does run" "echo \"\$(ssh host.example rm /srv/old)\"" "/srv/old"
asks "git worktree remove without --force on the remote side" "ssh host.example 'git worktree remove /srv/app-old'" "/srv/app-old"
asks "a deleting trap" "ssh host.example 'trap \"rm /srv/lock\" EXIT; echo ok'" "/srv/lock"
asks "find -exec with git rm -f" "ssh host.example 'find /srv/old -type f -exec git rm -f {} +'" "find -exec"
asks "an rsync daemon URL names its host" "rsync -a --delete build/ rsync://backup.example/module/" "on backup.example"
asks "a -- between host and command" "ssh host.example -- rm -f /srv/x" "/srv/x"
asks "tar --remove-files" "ssh host.example 'tar czf logs.tgz logs --remove-files'" "remove-files"
passes "a plain remote git rm of a tracked file" "ssh host.example 'git rm old.txt && git commit -m cleanup'"
passes "a FIFO as stdin is not read" "ssh host.example 'cat > /tmp/f' < /dev/zero"
asks "a device as a script for a remote shell is asked about, not read" "ssh host.example bash -s < /dev/zero" "cannot read"

# 6c. From the second lead sweep.
asks "lftp reverse mirror with --delete" "lftp -e 'mirror -R --delete build/ /srv/app; bye' ftp.example" "mirror"
asks "lftp glob rm" "lftp -e 'glob rm /upload/*.zip; bye' ftp.example" "/upload/"
passes "lftp download mirror" "lftp -e 'mirror /srv/app local/; bye' ftp.example"
asks "busybox rm" "ssh host.example 'busybox rm -rf /srv/a'" "/srv/a"
asks "ionice rm" "ssh host.example 'ionice -c3 rm -rf /srv/a'" "/srv/a"
asks "rsync --delete to a bracketed IPv6 host" "rsync -a --delete build/ deploy@[2001:db8::1]:/srv/app/" "/srv/app/"
passes "stdin from /dev/null" "ssh host.example 'bash -s' < /dev/null"
passes "a login shell with stdin from /dev/null" "ssh host.example < /dev/null"

# 6d. Ship-round findings (2026-11-15, two readers), each failing before its fix.
mkdir -p "$T/cwd/deploy"; printf 'rm /srv/approved\nrm /srv/unapproved\n' > "$T/cwd/deploy/script.sh"; printf 'ls /srv\n' > "$T/cwd/script.sh"
printf 'put report.csv\nbye\n' > "$T/cwd/batch-safe.txt"
asks "an escaped find terminator does not cut -delete off" "ssh host.example 'find /srv/logs -type f -exec grep -q expired {} \\; -delete'" "find -delete"
asks "two -exec actions, the second deletes" "ssh host.example 'find /srv/logs -type f -exec grep -q expired {} \\; -exec rm {} \\;'" "find -exec rm"
asks "a numeric file name before a redirection is an operand" "ssh host.example 'rm /srv/approved 20261115 > /dev/null'" "20261115"
asks "a reused heredoc delimiter: each redirection has its own body" "cat <<'EOF' > note.txt
Deployment note
EOF
ssh host.example 'bash -s' <<'EOF'
rm /srv/approved
rm /srv/unapproved
EOF" "/srv/approved" "/srv/unapproved"
passes "a reused heredoc delimiter, harmless remote script" "cat <<'EOF' > cleanup-notes.txt
to do: rm /srv/old
EOF
ssh host.example 'bash -s' <<'EOF'
ls /srv
EOF"
asks "a relative script after cd is read from the new directory" "cd deploy && ssh host.example 'bash -s' < script.sh" "/srv/unapproved"
asks "the same through cat" "cd deploy && cat script.sh | ssh host.example 'bash -s'" "/srv/unapproved"
passes "without the cd the harmless script of that name passes" "ssh host.example 'bash -s' < script.sh"
asks "a relative script after cd into a variable is not read" 'cd "$DIR" && ssh host.example bash -s < script.sh' "cannot read"
asks "printf with a format shows the real paths" "printf 'rm -f %s\\n' /srv/approved /srv/unapproved | ssh host.example" "/srv/approved" "/srv/unapproved"
asks "echo with several words shows the real paths" "echo rm -f /srv/approved /srv/unapproved | ssh host.example" "/srv/approved" "/srv/unapproved"
passes "printf of a line that only prints the word" "printf 'echo %s\\n' 'rm /srv/a' | ssh host.example"
asks "lftp commands chained with &&" "lftp -e 'cd /upload && rm old.zip; bye' ftp.example" "old.zip"
asks "lftp stdin with ; on one line" "lftp ftp.example <<'EOF'
cd /upload; rm old.zip
bye
EOF" "old.zip"
asks "lftp open names the host the delete runs on" "lftp -e 'open other.example; rm /upload/old.zip; bye' ftp.example" "on other.example"
passes "a remote git rm dry run" "ssh host.example 'git rm -n -f old.txt'"
passes "a remote git rm --dry-run" "ssh host.example 'git rm -f --dry-run old.txt'"
passes "an lftp mirror dry run" "lftp -e 'mirror -R --delete --dry-run build/ /srv/app; bye' ftp.example"
passes "sftp -f is a flag, not a batch file" "sftp -f host.example <<< 'put report.csv'"
passes "sftp -f before -b with a harmless batch" "sftp -f -b batch-safe.txt host.example"
asks "a bracketed IPv6 host is named in full" "rsync -a --delete build/ deploy@[2001:db8::1]:/srv/app/" "on deploy@[2001:db8::1]:"
asks "ssh options after the host" "ssh host.example -p 2222 'rm /srv/a'" "on host.example" "/srv/a"
asks "ssh -t after the host" "ssh host.example -t 'sudo rm /srv/a'" "/srv/a"
asks "operands after a command substitution stay visible" "ssh host.example 'rm /srv/approved \$(cat /srv/list.txt) /srv/unapproved'" "/srv/unapproved" "cat /srv/list.txt"
passes "a remote shell syntax check runs nothing" "ssh host.example 'bash -n' < del.sh"
asks "the whole remote command is shown next to the parsed paths" "ssh host.example 'cd /srv && rm -f a b'" "the whole remote command" "cd /srv && rm -f a b"

# 6e. From the third lead sweep.
TAB=$(printf '\t')
stops "a <<- heredoc into a remote shell" "ssh host.example bash -s <<-EOF
${TAB}rm /srv/a
${TAB}EOF"
OUT=$(jq -n --arg c "ssh host.example bash -s <<-EOF
${TAB}rm /srv/a
${TAB}EOF" '{tool_input:{command:$c}}' | PATH="$T/jqonly:/usr/bin:/bin" /bin/bash "$HOOK" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("/srv/a")' >/dev/null 2>&1; then ok; else bad "a <<- heredoc is read (no rmtrash, so the local guard is not what stops it)"; fi
asks "a process substitution as the script of a remote shell cannot be read" "ssh host.example bash < <(cat del.sh)" "cannot read"
mkdir -p "$T/badpy"; printf '#!/bin/bash\nexit 3\n' > "$T/badpy/python3"; chmod +x "$T/badpy/python3"
OUT=$(jq -n --arg c "ssh host.example 'rm /srv/a'" '{tool_input:{command:$c}}' | PATH="$T/badpy:$PATH" /bin/bash "$HOOK" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then ok; else bad "a python3 that fails: remote rm is still asked about"; fi
OUT=$(jq -n --arg c "ssh host.example 'ls'" '{tool_input:{command:$c}}' | PATH="$T/badpy:$PATH" /bin/bash "$HOOK" 2>/dev/null)
if [ -z "$OUT" ]; then ok; else bad "a python3 that fails: a plain ssh passes"; fi

# 6f. Second ship round (2026-11-15, two readers), each failing before its fix.
mkdir -p "$T/cwd/web" "$T/cwd/frontend"; printf 'ls /srv\n' > "$T/cwd/web/del.sh"
asks "lftp: a quoted ; in a file name cannot hide the next operand" "lftp -e 'rm \"/upload/report;2026.zip\" /upload/unapproved.zip; bye' ftp.example" "/upload/unapproved.zip" "the whole lftp command text"
asks "sftp: the batch text as written is in the reason" "sftp user@host.example <<EOF
rm old.zip
bye
EOF" "the whole sftp command text"
asks "a cd inside a subshell does not move the script path" "(cd web && npm run build) && ssh host.example 'bash -s' < del.sh" "releases/old"
passes "a cd inside a subshell, harmless script in the start directory" "(cd frontend && npm run build); ssh host.example 'bash -s' < plain.sh"
passes "an escaped command substitution in a double-quoted commit message" "git commit -m \"Document \\\$(ssh host.example rm /srv/a)\""
passes "the same in echo" "echo \"Example: \\\$(ssh host.example rm /srv/old)\""
OUT=$(jq -n --arg c "bash -n <<'EOF'
ssh host.example 'rm /srv/old'
EOF" '{tool_input:{command:$c}}' | PATH="$T/jqonly:/usr/bin:/bin" /bin/bash "$HOOK" 2>/dev/null)
if [ -z "$OUT" ]; then ok; else bad "a local bash -n syntax check runs nothing (no rmtrash)"; fi
asks "a heredoc piped across a line break into a remote shell" "cat <<'EOF' |
rm /srv/a
EOF
ssh host.example 'bash -s'" "/srv/a"
asks "a subshell piped into a remote shell" "(cat del.sh) | ssh host.example bash" "releases/old"
passes "an or-list is not a pipe" "test -f plain.sh || ssh host.example 'bash -s'"
asks "clustered ssh options ending in one that takes a value" "ssh -tp 2222 host.example 'rm /srv/a'" "on host.example" "/srv/a"
asks "an attached option value" "ssh -lalice -p2222 host.example 'rm /srv/a'" "on host.example"
OUT=$(jq -n --arg c "ssh host.example 'rm /srv/approved /srv/unapproved'" '{tool_input:{command:$c}}' | PATH="$T/badpy:$PATH" /bin/bash "$HOOK" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("/srv/unapproved")' >/dev/null 2>&1; then ok; else bad "a failing python3: the fallback reason carries the command text"; fi

# 6g. Third ship round (2026-11-15, two readers) and the backstop under the parser.
printf 'rm /srv/approved\n' > "$T/cwd/script.sh"      # outer script.sh now deletes one path; deploy/script.sh deletes two
asks "a file read by the producer inside a subshell is read from the subshell's directory" "(cd deploy && cat script.sh) | ssh host.example 'bash -s'" "/srv/unapproved"
printf 'ls /srv\n' > "$T/cwd/script.sh"
asks "find with escaped parentheses and -delete" "ssh host.example 'find /srv/logs -type f \\( -name \"*.log\" -o -name \"*.tmp\" \\) -delete'" "find -delete"
asks "find with escaped parentheses and -exec rm" "ssh host.example 'find /srv/logs -type f \\( -name \"*.log\" -o -name \"*.tmp\" \\) -exec rm {} +'" "find -exec rm"
printf "ssh host.example 'rm /srv/old'\n" > "$T/cwd/ssh-commands.txt"
OUT=$(jq -n --arg c "sh -c 'cat > copied.txt' < ssh-commands.txt" --arg d "$T/cwd" '{cwd:$d,tool_input:{command:$c}}' | PATH="$T/jqonly:/usr/bin:/bin" /bin/bash "$HOOK" 2>/dev/null)
if [ -z "$OUT" ]; then ok; else bad "a shell given its program with -c does not run its stdin file (no rmtrash)"; fi
passes "sftp: a local !command is not a remote delete" "sftp host.example <<'EOF'
!ls ./download.tmp
get report.csv
EOF"
OUT=$(jq -n --arg c "sftp host.example <<'EOF'
!rm ./download.tmp
get report.csv
EOF" '{tool_input:{command:$c}}' | PATH="$T/jqonly:/usr/bin:/bin" /bin/bash "$HOOK" 2>/dev/null)
if [ -z "$OUT" ]; then ok; else bad "sftp !rm runs locally: no remote-delete prompt (no rmtrash)"; fi
asks "sudo -iu user in front of the delete" "ssh host.example 'sudo -iu deploy rm -f /srv/unapproved'" "/srv/unapproved"
asks "repeated spaces in a file name survive in the reason" "ssh host.example 'rm -f /srv/approved \"/srv/Report  final.csv\"'" "Report  final.csv"
i=0; : > "$T/cwd/dense.sh"; while [ $i -lt 9 ]; do printf ':\n%.0s' $(seq 1 50000) >> "$T/cwd/dense.sh"; i=$((i + 1)); done; printf 'rm /srv/unapproved\n' >> "$T/cwd/dense.sh"
run "ssh host.example 'bash -s' < dense.sh"
if [ "$RC" = 2 ] || { [ -n "$WHY" ] && case "$WHY" in *"/srv/unapproved"*|*INCOMPLETE*) true ;; *) false ;; esac; }; then ok; else bad "a script too big to parse in time: blocked, or asked with the path or the word INCOMPLETE (rc=$RC)"; fi
asks "sftp -bFILE attached" "sftp -bbatch.txt user@host.example" "/upload/old.zip"
asks "bash -euo pipefail reads its stdin script" "ssh host.example 'bash -euo pipefail' < del.sh" "releases/old"
asks "zip -m deletes what it archived" "ssh host.example 'zip -m logs.zip /srv/logs/old.log'" "zip -m"
asks "backstop: a delete behind a wrapper the parser does not know" "ssh host.example 'runuser -u deploy -- true; flock /tmp/l sudo -H -u deploy rm -rf /srv/x'" "/srv/x"
asks "backstop: a delete after a construct the parser cannot split" "ssh host.example 'case \$1 in a) ;; esac; rm -rf /srv/y'" "/srv/y"
passes "backstop: rm as an argument, not a command" "ssh host.example 'ls | grep -v rm; man rm; which rm; type rm'"
passes "backstop: docker and package managers" "ssh host.example 'docker rm old; docker image rm x; npm rm left-pad; apt-get remove -y pkg'"
passes "backstop: a word in echoed text" "ssh host.example 'echo \"please rm nothing\"; printf \"%s\\n\" rm'"

# 6h. Cheap sweep cycles after the backstop (each lead fed to the hook before its fix).
asks "rsync --remove-sent-files, the old name" "rsync -a --remove-sent-files host.example:/srv/out/ ./in/" "/srv/out/"
asks "an rsync option with a value after the destination" "rsync -az --delete build/ host.example:/srv/app/ --contimeout 10" "/srv/app/"
asks "su -c on the remote side" "ssh host.example \"su -c 'rm -rf /srv/old' deploy\"" "/srv/old"
asks "flock in front of the delete" "ssh host.example 'flock /var/lock/clean.lock rm -rf /srv/old'" "/srv/old"
asks "a local find that runs ssh for each match" "find /srv/old -name '*.log' -exec ssh host.example rm -f {} \\;" "on host.example"
asks "a dollar-quoted remote command" "ssh host.example \$'rm -rf /srv/old'" "/srv/old"
passes "git clean dry run on the remote side" "ssh host.example 'cd /srv/app && git clean -nd'"
passes "flock around a harmless command" "ssh host.example 'flock /var/lock/x.lock ./deploy.sh'"

asks "lftp glob with an option" "lftp -e 'glob -a rm /upload/old.zip; bye' ftp.example" "/upload/old.zip"
asks "an rsync option value that starts with a dash" "rsync -a --delete --exclude -notes build/ host.example:/srv/app/" "/srv/app/"
passes "rsync --list-only deletes nothing" "rsync --list-only --delete user@host.example:/srv/app/ ./listing/"
asks "taskset in front of the delete" "ssh host.example 'taskset -c 0 rm -rf /srv/x'" "/srv/x"
passes "git rm --cached on the remote side" "ssh host.example 'cd /srv/app && git rm --cached .env'"

LOPTS=$(i=0; while [ $i -lt 40 ]; do printf -- '-x%s ' $i; i=$((i + 1)); done)
passes "an lftp open with a long option list is parsed at once, not timed out into a block" "lftp -e 'open ${LOPTS}h1 h2 h3; bye' ftp.example"
asks "lftp -e written as one word with its commands" "lftp -e'rm /upload/old.zip; bye' ftp.example" "/upload/old.zip"
asks "rsync --log-file-format with its value after the destination" "rsync -a --delete build/ host.example:/srv/app/ --log-file-format %n" "/srv/app/"

asks "backstop: chroot in front of the delete" "ssh host.example \"chroot /srv/jail rm -rf /tmp/old\"" "/tmp/old"
asks "backstop: setpriv in front of the delete" "ssh host.example 'setpriv --reuid=0 -- rm -rf /srv/x'" "/srv/x"
asks "backstop: an object-store delete" "ssh host.example 'aws s3 rm s3://bucket/key; s3cmd del x; mc rm /data/old'" "/data/old"
passes "backstop: a deleting word as data for grep, sed, journalctl and docker" "ssh host.example 'grep -c rm /var/log/app.log; sed -n /rm/p /etc/x; journalctl -u rm /dev/null; docker rm -f /web'"
passes "backstop: a path that only contains the word" "ssh host.example 'ls /srv/rm /tmp/unlink; cat ./rm/readme; stat /usr/bin/rm'"

# 6i. Fourth ship round (2026-11-15, two readers), each failing before its fix.
passes "backstop: a search behind sudo" "ssh host.example 'sudo grep -n rm /var/log/cloud-init-output.log'"
passes "backstop: a search behind env and timeout" "ssh host.example 'env LC_ALL=C grep rm /var/log/app.log; timeout 10 grep rm /var/log/app.log'"
passes "backstop: a search fed by xargs" "ssh host.example 'find /srv -type f -print0 | xargs -0 grep rm'"
passes "backstop: searching for a deleting command as a quoted string" "ssh host.example 'grep -F \"sudo rm -rf\" /var/log/auth.log; grep -c \"find . -delete\" /root/.bash_history'"
passes "backstop: wrapped docker and git rm --cached" "ssh host.example 'sudo docker rm -f web; sudo -u deploy git rm --cached .env'"
passes "backstop: a script written through a heredoc is not run" "ssh host.example \"cat > /srv/app/cleanup.sh <<'EOF'
rm /srv/old
EOF\""
passes "backstop: a commented delete in a deploy script" "ssh host.example 'bash -s' <<'EOF'
cd /srv/app
# rm /srv/old after approval
git pull
EOF"
asks "backstop still catches an unlisted wrapper behind sudo" "ssh host.example 'sudo chroot /srv/jail rm -rf /tmp/old'" "/tmp/old"
i=0; : > "$T/cwd/purge.sh"; while [ $i -lt 8000 ]; do printf 'rm -f /srv/app/cache/%s-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' $i; i=$((i + 1)); done >> "$T/cwd/purge.sh"
run "ssh host.example 'bash -s' < purge.sh"
if [ "$RC" = 2 ] || { [ -n "$WHY" ] && case "$WHY" in *INCOMPLETE*) true ;; *) false ;; esac; }; then ok; else bad "a script with thousands of deletes: valid ask JSON that says INCOMPLETE, or a block (rc=$RC, ${#OUT} bytes out)"; fi
asks "sftp options in a cluster: the host is the host" "sftp -qP 2222 -b - user@host.example <<'EOF'
rm /upload/old.zip
bye
EOF" "on user@host.example"

# 6j. Sweep cycle after the fourth ship round.
asks "a local wrapper in front of rsync --delete" "ionice -c3 rsync -a --delete build/ host.example:/srv/app/" "/srv/app/"
asks "taskset in front of rsync --delete" "taskset -c 0 rsync -a --delete build/ deploy@host.example:/srv/app/" "/srv/app/"
asks "rsync --copy-as with a value after the destination" "rsync -a --delete build/ host.example:/srv/app/ --copy-as deploy" "/srv/app/"
passes "rsync --delete pulling, with an exclude value before the source" "rsync -a --delete --exclude cache user@host.example:/srv/app/ ./mirror/"
asks "lftp queue rm" "lftp -e 'queue rm /upload/old.zip; bye' ftp.example" "/upload/old.zip"
asks "lftp commands separated by a single &" "lftp -e 'cd /upload & rm old.zip; bye' ftp.example" "old.zip"
asks "backstop: a relative operand behind an unlisted wrapper" "ssh host.example 'chroot /srv/jail rm -rf releases/old'" "releases/old"
passes "backstop: a subcommand named rm with a bare word" "ssh host.example 'mytool rm item42; conda env list'"

# 6k. False prompts reproduced by three independent readers.
passes "backstop: xargs runs grep with options, not its rm pattern" "ssh host 'find /srv -type f -print0 | xargs -0 grep -n rm'"
passes "backstop: command -v only looks up rm" "ssh host 'command -v rm'"
passes "backstop: wrapper names inside grep patterns are data" "ssh host 'grep -e sudo -e rm /var/log/auth.log'"
passes "clustered sudo options before git rm --cached" "ssh host 'sudo -iu deploy git rm --cached .env'"
passes "clustered sudo options before grep" "ssh host 'sudo -iu deploy grep rm /srv/app/deploy.log'"
passes "taskset before grep" "ssh host 'taskset -c 0 grep rm /var/log/app.log'"
passes "rsync pull with a filter in a short option cluster" "rsync -avf ': .rsync-filter' --delete host:/srv/app/ mirror"
passes "rsync pull with a clustered filter and --copy-as" "rsync -avf ': .rsync-filter' --copy-as deploy --delete host:/srv/app/ mirror"
passes "rsync pull with two remote sources and a bare local destination" "rsync -az --delete host:/srv/app/ host:/srv/config/ mirror"
passes "flock before git rm --cached" "ssh host 'flock /tmp/deploy.lock git rm --cached .env'"
asks "rsync push with a relative source path" "rsync -a --delete ./dir/ host:/srv/x/" "/srv/x/"
asks "rsync push with bare source and remote destination" "rsync -a --delete dir host:/srv/x" "/srv/x"
asks "rsync push with multiple bare sources" "rsync --delete-after a b host:dest" "host:dest"

# The same wrapper must exempt search arguments and still resolve a real deleting command.
for OPT in '-iu deploy' '-iudeploy' '-ig staff' '-igstaff' '-ih host' '-ip prompt' '-iC 3' '-iD /srv' '-iR /srv' '-iT 10'; do
  passes "sudo $OPT keeps search arguments as data" "ssh host 'sudo $OPT grep -n rm /srv/log'"
  asks "sudo $OPT resolves a delete in the parser" "ssh host 'sudo $OPT rm -f /srv/old'" "/srv/old" "the whole remote command"
done
for WRAPPER in 'ionice -c 2 -n4' 'taskset -c 0' 'taskset 0x1' 'chrt -f 10' 'setsid -f' 'chronic' 'unbuffer -p' \
               'caffeinate -t 1' 'flock -w 2 /tmp/deploy.lock' 'flock -w2 9' 'env -u OLD LC_ALL=C' \
               'nice -n5' 'nohup' 'time -f elapsed -o /tmp/timing' 'timeout -k1 10' 'flock /tmp/lock sudo -iu deploy'; do
  passes "$WRAPPER keeps search arguments as data" "ssh host '$WRAPPER grep -n rm /srv/log'"
  asks "$WRAPPER resolves a delete in the parser" "ssh host '$WRAPPER rm -f /srv/old'" "/srv/old" "the whole remote command"
done
passes "wrapped command lookups stay exempt" "ssh host 'sudo -iu deploy command -pv rm; flock /tmp/lock type rm; taskset -c 0 which rm'"

# Option values before the source or after the destination are never positional operands.
for OPT in "-avf ': .rsync-filter'" "-avf': .rsync-filter'" "-ave 'ssh -p 2222'" '-avessh' \
           '-avT destination' '-avTdestination' '-avB 1024' '-avB1024' \
           '--copy-as deploy' "--filter ': .rsync-filter'" '--rsh ssh' '--exclude cache' '--exclude-from excludes' \
           '--include src' '--include-from includes' '--files-from files' '--bwlimit 100' '--chmod D755' \
           '--chown deploy:staff' '--usermap root:deploy' '--groupmap root:staff'; do
  passes "rsync pull consumes $OPT" "rsync $OPT --delete host:/srv/app/ mirror"
  asks "rsync push consumes trailing $OPT" "rsync -a --delete dir host:dest $OPT" "host:dest"
done
passes "rsync filter equals-value on a pull" "rsync -a --filter=': .rsync-filter' --delete host:/srv/app/ mirror"
passes "rsync dry run before a value-taking clustered option" "rsync -anTdestination --delete dir host:dest"
asks "rsync daemon push with an option terminator" "rsync -a --delete -- dir rsync://host/module/" "on host" "rsync://host/module/"

# 6l. Sixth ship round: one failing-first regression per finding.
printf 'rm /srv/approved /srv/unapproved\n' > "$T/cwd/delete-script.sh"
asks "clustered sudo before a shell reading a script" "ssh host 'sudo -iu deploy bash -s' < delete-script.sh" "/srv/approved" "/srv/unapproved"
asks "lftp open carries its host from -e into stdin" "lftp -e 'open other.example' ftp.example <<'EOF'
rm /upload/old.zip
bye
EOF" "on other.example" "open other.example" "/upload/old.zip"
passes "compressed search arguments are data" "ssh host 'zgrep -n rm /var/log/auth.log.*.gz'"
passes "Python module arguments are data" "ssh host 'python3 -m pytest --collect-only -k unlink'"

# Wrapped stdin shells must resolve exactly like wrapped commands.
for WRAPPER in 'flock /srv/deploy.lock' 'taskset -c 0'; do
  asks "$WRAPPER before a shell reading a script" "ssh host '$WRAPPER bash -s' < delete-script.sh" "/srv/approved" "/srv/unapproved"
done
passes "clustered sudo reads a harmless deploy script" "ssh host 'sudo -iu deploy bash -s' < plain.sh"
asks "flock -c executes shell text" "ssh host 'flock /tmp/lock -c \"rm -f /srv/old\"'" "/srv/old" "the whole remote command"
asks "flock --command before the lock" "ssh host 'flock --command \"rm -f /srv/old\" /tmp/lock'" "/srv/old"
passes "flock -c harmless shell text" "ssh host 'flock /tmp/lock -c \"grep rm /srv/log\"'"

# Each lftp source continues the connection established by the previous source.
printf 'open file.example\n' > "$T/cwd/open.lftp"
asks "lftp -c carries its host into stdin" "lftp -c 'open command.example' ftp.example <<'EOF'
rm /upload/old.zip
bye
EOF" "on command.example" "open command.example" "/upload/old.zip"
asks "lftp -e carries its host into a script file" "lftp -e 'open  other.example' -f batch.txt ftp.example" "on other.example" "open  other.example" "/upload/old.zip"
asks "lftp script file carries its host into stdin" "lftp -f open.lftp ftp.example <<'EOF'
rm /upload/old.zip
bye
EOF" "on file.example" "open file.example" "/upload/old.zip"
asks "lftp carries its host between command options" "lftp -c 'open command.example' -e 'rm /upload/old.zip' ftp.example" "on command.example" "open command.example" "/upload/old.zip"
asks "lftp later open replaces the earlier connection" "lftp -e 'open other.example' -f open.lftp ftp.example <<'EOF'
rm /upload/old.zip
bye
EOF" "on file.example" "open other.example" "open file.example"
passes "lftp open followed by harmless stdin" "lftp -e 'open other.example' ftp.example <<'EOF'
get report.csv
bye
EOF"

# Search patterns remain data through the same wrapper resolver.
for SEARCH in 'zgrep -n rm /var/log/auth.log.*.gz' 'bzgrep -n rm /var/log/x.bz2' \
              'xzgrep rm /var/log/x.xz' 'zegrep rm /var/log/x.gz' \
              'fd rm /srv/app' 'rg rm /srv/app' 'ag rm /srv/app' 'ack rm /srv/app'; do
  for WRAPPER in '' 'sudo -iu deploy' 'env LC_ALL=C' 'xargs -0'; do
    passes "$WRAPPER $SEARCH is a search" "ssh host '$WRAPPER $SEARCH'"
  done
done
asks "fd --exec still executes rm" "ssh host 'fd --exec rm'" "fd --exec rm"
asks "fd -x executes rm" "ssh host 'fd -x rm {}'" "fd -x rm"
asks "wrapped fd --exec still executes rm" "ssh host 'sudo -iu deploy fd --exec rm'" "fd --exec rm"

# Python only executes -c text or stdin, never module/script arguments.
passes "Python module filter remove is data" "ssh host 'python3 -m pytest -k remove tests/'"
passes "Python script subcommand is data" "ssh host 'python3 manage.py unlink_accounts'"
passes "Python module path arguments bypass the shell backstop" "ssh host 'python3 -m pytest -k unlink /srv/tests'"
passes "Python script API arguments are data" "ssh host 'python3 manage.py os.remove unlink /srv/tests'"
passes "Python -c trailing arguments are data" "ssh host 'python3 -c \"print(1)\" unlink /srv/tests'"
passes "wrapped Python module arguments are data" "ssh host 'sudo -iu deploy python3 -m pytest -k unlink'"
passes "Python attached module option arguments are data" "ssh host 'python3 -Impytest -k unlink'"
passes "Python module stdin is data" "ssh host \"python3 -m pytest <<'EOF'
import os; os.remove('/srv/x')
EOF\""
passes "Python script stdin is data" "ssh host \"python3 manage.py <<'EOF'
import os; os.remove('/srv/x')
EOF\""
passes "Python -c stdin is data" "ssh host \"python3 -c 'print(1)' <<'EOF'
import os; os.remove('/srv/x')
EOF\""
asks "Python -c deleting API still asks" "ssh host \"python3 -c \\\"import os; os.remove('/srv/x')\\\"\"" "/srv/x"
asks "Python attached -c after option values" "ssh host \"python3 -W ignore -X dev -Ic\\\"import os; os.remove('/srv/x')\\\"\"" "/srv/x"
asks "Python remote heredoc code still asks" "ssh host \"python3 - <<'EOF'
import os; os.remove('/srv/x')
EOF\"" "/srv/x"
asks "Python remote here-string code still asks" "ssh host \"python3 - <<< \\\"import os; os.remove('/srv/x')\\\"\"" "/srv/x"
asks "Python remote piped code still asks" "ssh host \"printf '%s' \\\"import os; os.remove('/srv/x')\\\" | python3 -\"" "/srv/x"
asks "Python heredoc through ssh is executable code" "ssh host 'sudo -iu deploy python3 -' <<'EOF'
import os; os.remove('/srv/x')
EOF" "/srv/x"

# 7. Without python3: a crude ask instead of silence.
mkdir -p "$T/nopy"
for f in /bin/* /usr/bin/*; do case "${f##*/}" in python*) ;; *) ln -s "$f" "$T/nopy/${f##*/}" 2>/dev/null ;; esac; done
ln -sf "$(command -v jq)" "$T/nopy/jq"
OUT=$(jq -n --arg c "ssh host.example 'rm /srv/a'" '{tool_input:{command:$c}}' | PATH="$T/nopy" /bin/bash "$HOOK" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput | .permissionDecision == "ask" and (.permissionDecisionReason | contains("/srv/a"))' >/dev/null 2>&1; then ok; else bad "no python3: remote rm is still asked about, with the command text"; fi
OUT=$(jq -n --arg c "ssh host.example 'ls'" '{tool_input:{command:$c}}' | PATH="$T/nopy" /bin/bash "$HOOK" 2>/dev/null)
if [ -z "$OUT" ]; then ok; else bad "no python3: a plain ssh passes"; fi

printf 'remote-delete: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
