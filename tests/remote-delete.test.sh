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
mkdir -p "$T/bin" "$T/cwd"; printf '#!/bin/bash\nexit 0\n' > "$T/bin/rmtrash"; chmod +x "$T/bin/rmtrash"
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

# 1. The 2026-11-15 shapes: an approved purge with an appended path, a staging copy, one file.
asks "purge plus an appended rm names both" \
  "ssh -o BatchMode=yes -o ConnectTimeout=15 user@host.example 'cd /srv/app && before=\$(ls errors | wc -l) && find errors -maxdepth 1 -type f -name \"sql-*.log\" -mtime +90 -print0 | xargs -0 -r rm -f && echo \"errors: \$before -> \$(ls errors | wc -l)\"; ls -la errors/.htaccess | cut -c1-60; rm -f /archive-today.tar.gz 2>/dev/null; ls /Downloads | wc -l'" \
  "user@host.example" "find errors" "/archive-today.tar.gz"
asks "rm -r of a directory" "ssh user@host.example 'rm -r /staging-copy && cd /srv/app && git worktree prune'" "/staging-copy"
asks "a single rm -f" "ssh user@host.example 'rm -f /archive-today.tar.gz'" "/archive-today.tar.gz"

# 2. Other spellings of a remote delete.
asks "unquoted remote command" "ssh host.example rm -f /tmp/x" "/tmp/x"
asks "options with values before the host" "ssh -p 2222 -i ~/.ssh/id -l deploy host.example 'rmdir /srv/empty'" "host.example" "/srv/empty"
asks "find -delete is asked, not hard-blocked as a local delete" "ssh host.example 'find logs -mtime +90 -delete'" "find -delete"
asks "find -exec rm" "ssh host.example 'find /var/tmp -name \"*.old\" -exec rm {} +'" "find -exec rm"
asks "sudo sh -c" "ssh host.example \"sudo sh -c 'rm -rf /var/cache/app'\"" "/var/cache/app"
asks "inside a command substitution" "ssh host.example 'echo \"left: \$(rm -f /tmp/a; ls | wc -l)\"'" "/tmp/a"
asks "git clean on the remote side" "ssh host.example 'cd /srv/app && git clean -fdx'" "git clean"
asks "interpreter code that deletes" "ssh host.example 'python3 -c \"import shutil; shutil.rmtree(\\\"/srv/x\\\")\"'" "rmtree"
asks "behind timeout" "timeout 30 ssh host.example 'unlink /srv/link'" "/srv/link"
asks "behind sshpass" "sshpass -p secret ssh host.example 'rm /srv/a'" "/srv/a"
asks "in a loop over hosts" 'for h in a.example b.example; do ssh "$h" "rm -f /tmp/lock"; done' "/tmp/lock"
asks "through bash -c" "bash -c \"ssh host.example 'rm /srv/a'\"" "/srv/a"
asks "an ssh inside the remote command" "ssh jump.example \"ssh inner.example 'rm /srv/a'\"" "inner.example"
asks "multi-line payload" "ssh host.example '
cd /srv/app
rm -rf releases/old
'" "releases/old"

# 3. A script sent to a remote shell on stdin.
asks "heredoc into bash -s" "ssh host.example bash -s <<'EOF'
cd /srv/app
rm -rf releases/old
EOF" "releases/old" "heredoc"
asks "heredoc with no remote command" "ssh host.example <<EOF
rm /srv/a
EOF" "/srv/a"
asks "a script file redirected into a remote shell" "ssh host.example 'bash -s' < del.sh" "releases/old" "del.sh"
asks "the same through cat and a pipe" "cat del.sh | ssh host.example bash" "releases/old"
asks "echo piped into a remote shell" "echo 'rm /srv/a' | ssh host.example sh" "/srv/a"
asks "a here-string" "ssh host.example bash <<< 'rm /srv/a'" "/srv/a"
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
asks "the local guard switched off by the human does not switch this one off" "ssh host.example 'rm /srv/a'" "/srv/a"
OUT=$(jq -n --arg c "ssh host.example 'rm /srv/a'" '{tool_input:{command:$c}}' | MEGAVIBE_ALLOW_REAL_DELETE=1 bash "$HOOK" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then ok; else bad "MEGAVIBE_ALLOW_REAL_DELETE=1 must not open remote deletes"; fi
mkdir -p "$T/jqonly"; ln -sf "$(command -v jq)" "$T/jqonly/jq"      # a PATH without rmtrash
OUT=$(jq -n --arg c "ssh host.example 'rm /srv/a'" '{tool_input:{command:$c}}' | PATH="$T/jqonly:/usr/bin:/bin" /bin/bash "$HOOK" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then ok; else bad "asked without rmtrash too (a remote rule needs no local Trash)"; fi

# 7. Without python3: a crude ask instead of silence.
mkdir -p "$T/nopy"
for f in /bin/* /usr/bin/*; do case "${f##*/}" in python*) ;; *) ln -s "$f" "$T/nopy/${f##*/}" 2>/dev/null ;; esac; done
ln -sf "$(command -v jq)" "$T/nopy/jq"
OUT=$(jq -n --arg c "ssh host.example 'rm /srv/a'" '{tool_input:{command:$c}}' | PATH="$T/nopy" /bin/bash "$HOOK" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then ok; else bad "no python3: remote rm is still asked about"; fi
OUT=$(jq -n --arg c "ssh host.example 'ls'" '{tool_input:{command:$c}}' | PATH="$T/nopy" /bin/bash "$HOOK" 2>/dev/null)
if [ -z "$OUT" ]; then ok; else bad "no python3: a plain ssh passes"; fi

printf 'remote-delete: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
