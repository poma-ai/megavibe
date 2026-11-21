#!/bin/bash
# /bin/bash tests/public-push.test.sh
# block-public-push.sh: visibility lookup (stub gh), scan of outgoing commits, denylist,
# unknown-visibility posture, command parsing, override. Nothing touches the network: the
# remotes are never contacted, gh is a stub, HOME is a scratch directory.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$REPO/template/.claude/hooks/block-public-push.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/public-push-test.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap '/bin/rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

export HOME="$T/home"; mkdir -p "$HOME/.megavibe/personal" "$T/bin" "$T/vis"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email "dev@corp.test"; git config --global user.name dev
git config --global init.defaultBranch main
# stub gh: `gh repo view [owner/repo] --json ...`; visibility per file $T/vis/<owner>_<repo>; GH_FAIL=1 fails
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
[ "${GH_FAIL:-0}" = 1 ] && exit 1
repo=""; [ "$1 $2" = "repo view" ] && repo=$3
[ "${repo:0:2}" = "--" ] && repo="cur/rent"
f="$STUB_DIR/$(printf '%s' "$repo" | tr / _)"
[ -f "$f" ] || exit 1
printf '{"visibility":"%s","nameWithOwner":"%s"}\n' "$(cat "$f")" "$repo"
EOF
chmod +x "$T/bin/gh"
export STUB_DIR="$T/vis" STUB_LOG="$T/gh.log" PATH="$T/bin:$PATH"
printf PUBLIC > "$T/vis/acme_pub"; printf PRIVATE > "$T/vis/acme_priv"; printf INTERNAL > "$T/vis/acme_int"
printf PUBLIC > "$T/vis/cur_rent"

mkrepo() {   # mkrepo <dir> <remote url>: a repo with one clean commit that the "remote" already has
  mkdir -p "$1" && ( cd "$1" && git init -q && git remote add origin "$2" && echo "hello" > a.txt && git add a.txt \
    && git commit -qm "init" && git update-ref refs/remotes/origin/main HEAD && git branch -q --set-upstream-to=origin/main main 2>/dev/null; true )
}
commit() {   # commit <dir> <file> <content> [message]
  ( cd "$1" && printf '%s\n' "$3" >> "$2" && git add "$2" && git commit -qm "${4:-change}" )
}
run() {   # run <cwd> <command>: sets RC OUT WHY
  OUT=$(jq -n --arg c "$2" --arg d "$1" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | bash "$HOOK" 2>/dev/null); RC=$?
  WHY=$(printf '%s' "$OUT" | jq -r 'select(.hookSpecificOutput.permissionDecision == "ask") | .hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
}
passes() { run "$2" "$3"; if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "$1 (rc=$RC out=${OUT:0:200})"; fi; }
asks() {  # asks <name> <cwd> <cmd> [text the reason must contain]...
  local name=$1 cwd=$2 cmd=$3; run "$cwd" "$cmd"; shift 3
  if [ "$RC" != 0 ] || [ -z "$WHY" ]; then bad "$name (rc=$RC, no ask)"; return; fi
  local s; for s in "$@"; do case "$WHY" in *"$s"*) ;; *) bad "$name (reason lacks: $s) :: ${WHY:0:300}"; return ;; esac; done
  ok
}
lacks() { case "$WHY" in *"$2"*) bad "$1 (reason has: $2)" ;; *) ok ;; esac; }

PUB="$T/pub"; PRIV="$T/priv"; mkrepo "$PUB" https://github.com/acme/pub.git; mkrepo "$PRIV" git@github.com:acme/priv.git

# 1. Targets: public clean passes, private/internal pass with no scan, hits ask.
commit "$PUB" a.txt "plain change"
passes "public, clean outgoing commit" "$PUB" "git push origin main"
passes "public, bare git push (upstream remote)" "$PUB" "git push"
commit "$PRIV" a.txt "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"
passes "private target is not scanned" "$PRIV" "git push origin main"
printf INTERNAL > "$T/vis/acme_priv"
passes "internal target is not scanned" "$PRIV" "git push"
printf PRIVATE > "$T/vis/acme_priv"

# 2. Generic leaks on a public target.
L=$T/leak; mkrepo "$L" https://github.com/acme/pub.git
commit "$L" notes.md "see /Users/jsmith/work/secret.txt for the formula" "add notes"
asks "home path in added line" "$L" "git push origin main" "PUBLIC" "notes.md:" "[home path]"
( cd "$L" && git reset -q --hard HEAD~1 )
commit "$L" k.txt "AKIAABCDEFGHIJKLMNOP"
asks "AWS key; value truncated" "$L" "git push" "[AWS key]" "AKIA…"; lacks "secret not echoed" "ABCDEFGHIJKLMNOP"
( cd "$L" && git reset -q --hard HEAD~1 )
commit "$L" k.txt "-----BEGIN OPENSSH PRIVATE KEY-----"
asks "private key" "$L" "git push" "[private key]"
( cd "$L" && git reset -q --hard HEAD~1 )
commit "$L" m.txt "x" "mail bob@internal-corp.biz about it"
asks "email in commit message" "$L" "git push" "[email]" "message"
( cd "$L" && git reset -q --hard HEAD~1 )
commit "$L" m.txt "contact: alice@internal-corp.biz"
asks "email in added line" "$L" "git push" "[email]"
( cd "$L" && git reset -q --hard HEAD~1 )

# 3. False-block guards: placeholders, trailers, own authors, noreply, example domains.
commit "$L" p.md "cd /Users/you/proj; ls /home/runner/work; mail user@example.com; x@users.noreply.github.com" \
  "docs

Co-authored-by: megavibe <bot@vendor.test>
Signed-off-by: Dev <dev@corp.test>"
passes "placeholders, trailers, noreply, example.com" "$L" "git push origin main"
commit "$L" p2.md "committer is dev@corp.test and that is published anyway"
passes "the commit's own author email" "$L" "git push"
HOME_USER=$(basename "$HOME")
commit "$L" p3.md "path /Users/$HOME_USER/x"
asks "the real login name always hits" "$L" "git push" "[home path]"
( cd "$L" && git reset -q --hard HEAD~1 )
printf 'jane@corp-partner.biz\n*@partner.biz\n' > "$HOME/.megavibe/personal/public-push.allow-email"
commit "$L" p4.md "ping jane@corp-partner.biz and bob@partner.biz"
passes "allow-email file" "$L" "git push"
/bin/rm -f "$HOME/.megavibe/personal/public-push.allow-email"

# 4. Denylist: literal (case-insensitive), /regex/, invalid regex, path names, comments.
D=$T/deny; mkrepo "$D" https://github.com/acme/pub.git
printf '# customers\nACME Corp\n/prod-db-[0-9]+/\n/(unclosed/\n\n' > "$HOME/.megavibe/personal/public-push.deny"
commit "$D" c.md "pricing for acme corp is 4 euro"
asks "denylist literal, case-insensitive" "$D" "git push" "[denylist #2]" "c.md:"
( cd "$D" && git reset -q --hard HEAD~1 )
commit "$D" c.md "connect to prod-db-17 now"
asks "denylist regex" "$D" "git push" "[denylist #3]" "invalid regex" "4"
( cd "$D" && git reset -q --hard HEAD~1 )
( cd "$D" && echo x > "ACME Corp-notes.txt" && git add . && git commit -qm "file named after a customer" )
asks "denylist hits a file path" "$D" "git push" "path"
( cd "$D" && git reset -q --hard HEAD~1 )
commit "$D" c.md "nothing to see"
passes "denylist present, clean change" "$D" "git push"
/bin/rm -f "$HOME/.megavibe/personal/public-push.deny"

# 5. New branch versus existing branch.
N=$T/newbr; mkrepo "$N" https://github.com/acme/pub.git
commit "$N" a.txt "token ghp_abcdefghijklmnopqrstuvwxyz0123456789" "early commit"
( cd "$N" && git update-ref refs/remotes/origin/main HEAD )   # the remote already holds it
( cd "$N" && git checkout -q -b feat )
commit "$N" b.txt "fine"
passes "new branch: only commits the remote lacks are scanned" "$N" "git push -u origin feat"
( cd "$N" && git checkout -q main && git checkout -q -b feat2 && git reset -q --hard HEAD~0 )
( cd "$N" && git update-ref -d refs/remotes/origin/main )
asks "new branch, nothing on the remote: every reachable commit is scanned" "$N" "git push origin feat2" "ghp_"

# 6. Unknown visibility: asks, never silent.
U=$T/unk; mkrepo "$U" https://github.com/acme/mystery.git
asks "gh does not know the repo" "$U" "git push" "could not determine"
rm -rf "$HOME/.megavibe/cache"; GH_FAIL=1 asks "gh failing (offline / not logged in)" "$PUB" "git push" "could not determine" 2>/dev/null
G=$T/gitlab; mkrepo "$G" git@gitlab.example.net:grp/proj.git
asks "a host that is not GitHub" "$G" "git push" "not a GitHub host" "gitlab.example.net"
printf 'gitlab.example.net/grp/*\n' > "$HOME/.megavibe/personal/public-push.trusted"
passes "trusted file silences a known-private host" "$G" "git push"
printf 'github.com/acme/mystery\n' > "$HOME/.megavibe/personal/public-push.trusted"
passes "trusted file silences an unknown repo" "$U" "git push"
/bin/rm -f "$HOME/.megavibe/personal/public-push.trusted"
LP=$T/localpath; mkrepo "$LP" "$T/bare.git"
passes "a local-path remote is not public" "$LP" "git push"
S=$T/sshalias; mkrepo "$S" git@work-alias:acme/priv.git
asks "ssh alias that does not resolve" "$S" "git push" "not a GitHub host"

# 7. Command parsing: all spellings the other guards parse.
commit "$PUB" a.txt "token ghp_abcdefghijklmnopqrstuvwxyz0123456789" "oops"
( cd "$PUB" && git tag v1 )
for c in "git push origin main" "git push" "bash -c 'git push origin main'" "sudo git push" "env X=1 git push" \
         "git -C $PUB push" "cd $PUB && git push" "echo hi; git push --force-with-lease origin main" "time git push -u origin HEAD" \
         "git push origin HEAD:refs/heads/other" "sh -c \"cd $PUB && git push\"" "git push origin main 2>&1 | tail -3" "git push --tags origin"; do
  cwd=$PUB; case "$c" in "git -C"*|"cd "*|"sh -c \"cd"*) cwd=/tmp ;; esac
  asks "parse: $c" "$cwd" "$c" "ghp_"
done
passes "echo of a push is text" "$PUB" "echo 'git push origin main'"
passes "commit message naming a push" "$PUB" "git commit -m 'git push later'"
passes "heredoc body naming a push" "$PUB" $'cat <<EOF\ngit push\nEOF'
passes "dry run sends nothing" "$PUB" "git push --dry-run"
passes "short dry run" "$PUB" "git push -n origin main"
passes "delete refspec" "$PUB" "git push origin :old-branch"
passes "delete flag" "$PUB" "git push origin --delete old-branch"
passes "not a push" "$PUB" "git status"
passes "grep for push" "$PUB" "grep -rn push ."
asks "cd into a variable cannot be resolved" /tmp 'cd "$X" && git push' "not statically known"
( cd "$PUB" && git tag -d v1 >/dev/null; git reset -q --hard HEAD~1 )

# 8. Override: the launch environment counts, an inline prefix does not.
commit "$PUB" a.txt "token ghp_abcdefghijklmnopqrstuvwxyz0123456789" "oops"
OUT=$(jq -n --arg c "git push" --arg d "$PUB" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | MEGAVIBE_ALLOW_PUBLIC_PUSH=1 bash "$HOOK" 2>/dev/null); RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "override env var passes (rc=$RC)"; fi
asks "inline prefix is NOT an override, and is reported" "$PUB" "MEGAVIBE_ALLOW_PUBLIC_PUSH=1 git push" "ghp_" "inline MEGAVIBE_ALLOW_PUBLIC_PUSH"
( cd "$PUB" && git reset -q --hard HEAD~1 )

# 9. Cache: one gh call per repo inside the TTL; unknown is never cached.
/bin/rm -rf "$HOME/.megavibe/cache"; : > "$STUB_LOG"
passes "cache warm-up" "$PUB" "git push"; passes "cache hit" "$PUB" "git push"
n=$(grep -c . "$STUB_LOG"); if [ "$n" = 1 ]; then ok; else bad "cache: expected 1 gh call, saw $n"; fi
: > "$STUB_LOG"; GH_FAIL=1 run "$U" "git push"; GH_FAIL=1 run "$U" "git push"
n=$(grep -c . "$STUB_LOG"); if [ "$n" = 2 ]; then ok; else bad "unknown result must not be cached: saw $n calls"; fi

# 10. gh pr create / repo create / repo edit.
PR=$T/pr; mkrepo "$PR" https://github.com/acme/pub.git
asks "pr create: title with a path on a public base" "$PR" "gh pr create --title 'fix /Users/jsmith/x' --body '## Summary
ok'" "pull request text"
passes "pr create: clean text" "$PR" "gh pr create --title 'Fix thing' --body '## Summary
ok'"
passes "pr create to a private repo" "$PR" "gh pr create -R acme/priv --title '/Users/jsmith/x' --body y"
asks "pr create -R public repo" "$PR" "gh pr create -R acme/pub --title 'ghp_abcdefghijklmnopqrstuvwxyz0123456789' --body y" "[GitHub token]"
asks "pr create: gh cannot tell" "$PR" "gh pr create -R acme/mystery --title t --body b" "could not determine"
asks "repo create --public" "$PR" "gh repo create newthing --public" "creates a PUBLIC"
passes "repo create --private" "$PR" "gh repo create newthing --private"
asks "repo edit --visibility public" "$PR" "gh repo edit acme/priv --visibility public" "PUBLIC"
passes "repo edit --visibility private" "$PR" "gh repo edit acme/pub --visibility private"
passes "repo edit other flags" "$PR" "gh repo edit --description hi"
passes "gh pr view is untouched" "$PR" "gh pr view 3"

# 10b. Triage of the amass sweep: each was run with its exact input.
X=$T/xtra; mkrepo "$X" https://github.com/acme/pub.git
commit "$X" w.md "++ path /Users/jsmith/z is an added line that starts with three pluses"
asks "added line '+++ ...' is content, not a file header" "$X" "git push" "[home path]" "w.md:"
( cd "$X" && git reset -q --hard HEAD~1 )
commit "$X" w.md "ok" $'subject\n\n\x01 \x02 literal delimiter bytes in a message'
passes "literal control bytes in a message do not derail the parse" "$X" "git push"
commit "$X" y.md "AKIAABCDEFGHIJKLMNOP"
asks "unbalanced quote does not hide a push" "$X" "git commit -m 'oops && git push" "could not be parsed"
asks "push inside $( ) is still parsed as a command" "$X" 'echo $(git push origin main)' "[AWS key]"
asks "push inside eval is asked about" "$X" 'eval "git push origin main"' "eval"
passes "unbalanced quote without a push stays silent" "$X" "echo 'unclosed"
( cd "$X" && git remote set-url origin 'ext::sh -c foo' )
asks "an ext:: remote is not silently passed" "$X" "git push" "not a GitHub host"
( cd "$X" && git remote set-url origin https://github.com/acme/pub.git && git reset -q --hard HEAD~1 )
mkdir -p "$X/sub" && printf 'import sys\nprint("PWNED", file=open("/dev/stderr","w"))\nsys.exit(0)\n' > "$X/json.py"
commit "$X" y2.md "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
asks "a planted json.py in the project is not imported" "$X" "git push" "[GitHub token]"
rm -f "$X/json.py"; ( cd "$X" && git reset -q --hard HEAD~1 )
printf PUBLIC > "$T/vis/acme_a-b"; printf PRIVATE > "$T/vis/acme_a_b"
rm -rf "$HOME/.megavibe/cache"
Y=$T/coll1; mkrepo "$Y" https://github.com/acme/a-b.git; commit "$Y" l.md "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"
Z=$T/coll2; mkrepo "$Z" https://github.com/acme/a_b.git; commit "$Z" l.md "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"
passes "private repo a_b" "$Z" "git push"
asks "public repo a-b is not served a_b's cached PRIVATE" "$Y" "git push" "[GitHub token]"
EH=$T/edit; mkrepo "$EH" https://github.com/acme/pub.git; ( cd "$EH" && git checkout -q -b side && echo "tok ghp_abcdefghijklmnopqrstuvwxyz0123456789" > s.txt && git add s.txt && git commit -qm side && git checkout -q main )
asks "repo edit public scans every branch" "$EH" "gh repo edit --visibility public" "every branch" "[GitHub token]"
passes "placeholder token on an EXAMPLE line" "$X" "git push"
commit "$X" ex.md "token: ghp_EXAMPLEexampleEXAMPLEexample01234567   # EXAMPLE placeholder"
passes "a line marked EXAMPLE is a placeholder, not a secret" "$X" "git push"

# 11. Fail open: no jq / python3 in PATH is a silent pass is covered by the header; check a malformed event.
OUT=$(printf 'not json' | bash "$HOOK" 2>/dev/null); RC=$?; if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "malformed input fails open"; fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
