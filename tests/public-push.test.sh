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
git config --global user.email "user@corp.test"; git config --global user.name dev   # EXAMPLE: fixture
git config --global init.defaultBranch main
# stub gh: `gh repo view [owner/repo] --json ...`; visibility per file $T/vis/<owner>_<repo>; GH_FAIL=1 fails
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
[ "${GH_FAIL:-0}" = 1 ] && exit 1
repo=""; [ "$1 $2" = "repo view" ] && repo=$3
[ "${repo:0:2}" = "--" ] && repo=$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
[ -z "$repo" ] && repo="nowhere/none"
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

USERS_DIR=/Users; AKIA_PFX=AKIA   # fixture fragments, joined only when a command runs
PUB="$T/pub"; PRIV="$T/priv"; mkrepo "$PUB" https://github.com/acme/pub.git; mkrepo "$PRIV" git@github.com:acme/priv.git   # EXAMPLE: fixture

# 1. Targets: public clean passes, private/internal pass with no scan, hits ask.
commit "$PUB" a.txt "plain change"
passes "public, clean outgoing commit" "$PUB" "git push origin main"
passes "public, bare git push (upstream remote)" "$PUB" "git push"
commit "$PRIV" a.txt "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"   # EXAMPLE: fixture
passes "private target is not scanned" "$PRIV" "git push origin main"
printf INTERNAL > "$T/vis/acme_priv"
passes "internal target is not scanned" "$PRIV" "git push"
printf PRIVATE > "$T/vis/acme_priv"

# 2. Generic leaks on a public target.
L=$T/leak; mkrepo "$L" https://github.com/acme/pub.git
commit "$L" notes.md "see /Users/jsmith/work/secret.txt for the formula" "add notes"   # EXAMPLE: fixture
asks "home path in added line" "$L" "git push origin main" "PUBLIC" "notes.md:" "[home path]"
( cd "$L" && git reset -q --hard HEAD~1 )
commit "$L" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
asks "AWS key; value truncated" "$L" "git push" "[AWS key]" "AKIA…"; lacks "secret not echoed" "ABCDEFGHIJKLMNOP"
( cd "$L" && git reset -q --hard HEAD~1 )
commit "$L" k.txt "-----BEGIN OPENSSH PRIVATE KEY-----"   # EXAMPLE: fixture
asks "private key" "$L" "git push" "[private key]"
( cd "$L" && git reset -q --hard HEAD~1 )
commit "$L" m.txt "x" "mail bob@internal-corp.biz about it"   # EXAMPLE: fixture
asks "email in commit message" "$L" "git push" "[email]" "message"
( cd "$L" && git reset -q --hard HEAD~1 )
commit "$L" m.txt "contact: alice@internal-corp.biz"   # EXAMPLE: fixture
asks "email in added line" "$L" "git push" "[email]"
( cd "$L" && git reset -q --hard HEAD~1 )

# 3. False-block guards: placeholders, trailers, own authors, noreply, example domains.
commit "$L" p.md "cd /Users/you/proj; ls /home/runner/work; mail user@example.com; x@users.noreply.github.com" \
  "docs

Co-authored-by: megavibe <bot@vendor.test>   # EXAMPLE: fixture
Signed-off-by: Dev <user@corp.test>"
passes "placeholders, trailers, noreply, example.com" "$L" "git push origin main"
commit "$L" p2.md "committer is user@corp.test and that is published anyway"   # EXAMPLE: fixture
passes "the commit's own author email" "$L" "git push"
HOME_USER=$(basename "$HOME")
commit "$L" p3.md "path /Users/$HOME_USER/x"
asks "the real login name always hits" "$L" "git push" "[home path]"
( cd "$L" && git reset -q --hard HEAD~1 )
printf 'jane@corp-partner.biz\n*@partner.biz\n' > "$HOME/.megavibe/personal/public-push.allow-email"   # EXAMPLE: fixture
commit "$L" p4.md "ping jane@corp-partner.biz and bob@partner.biz"   # EXAMPLE: fixture
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
commit "$N" a.txt "token ghp_abcdefghijklmnopqrstuvwxyz0123456789" "early commit"   # EXAMPLE: fixture
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
G=$T/gitlab; mkrepo "$G" git@gitlab.example.net:grp/proj.git   # EXAMPLE: fixture
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
commit "$PUB" a.txt "token ghp_abcdefghijklmnopqrstuvwxyz0123456789" "oops"   # EXAMPLE: fixture
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
commit "$PUB" a.txt "token ghp_abcdefghijklmnopqrstuvwxyz0123456789" "oops"   # EXAMPLE: fixture
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
asks "pr create: title with a path on a public base" "$PR" "gh pr create --title 'fix ${USERS_DIR}/jsmith/x' --body '## Summary
ok'" "pull request text"
passes "pr create: clean text" "$PR" "gh pr create --title 'Fix thing' --body '## Summary
ok'"
passes "pr create to a private repo" "$PR" "gh pr create -R acme/priv --title '/Users/jsmith/x' --body y"   # EXAMPLE: fixture
asks "pr create -R public repo" "$PR" "gh pr create -R acme/pub --title 'ghp_abcdefghijklmnopqrstuvwxyz0123456789' --body y" "[GitHub token]"   # EXAMPLE: fixture
asks "pr create: attached short option -Racme/pub" "$PR" "gh pr create -Racme/pub --title 'ghp_abcdefghijklmnopqrstuvwxyz0123456789' --body y" "[GitHub token]"   # EXAMPLE: fixture
mkdir -p "$T/otherdir" && ( cd "$T/otherdir" && git init -q && git remote add origin https://github.com/cur/rent.git )
printf PUBLIC > "$T/vis/acme_pub"
printf PRIVATE > "$T/vis/cur_rent"
passes "pr create resolves the base repo from the command's cd, not the hook's cwd" /tmp "cd $T/otherdir && gh pr create --title /Users/jsmith/x --body y"   # EXAMPLE: fixture
printf PUBLIC > "$T/vis/cur_rent"
asks "pr create: gh cannot tell" "$PR" "gh pr create -R acme/mystery --title t --body b" "could not determine"
asks "pr create: a heredoc body is scanned" "$PR" $'gh pr create --title t --body-file - <<\'EOF\'\n## Summary\nsee /Users/jsmith/proj\nEOF' "pull request text" "[home path]"   # EXAMPLE: fixture
asks "pr create: $(cat <<EOF) body idiom is scanned" "$PR" $'gh pr create --title t --body "$(cat <<\'EOF\'\n## Summary\nkey AKIAABCDEFGHIJKLMNOP\nEOF\n)"' "[AWS key]"   # EXAMPLE: fixture
asks "repo create --public" "$PR" "gh repo create newthing --public" "creates a PUBLIC"
passes "repo create --private" "$PR" "gh repo create newthing --private"
asks "repo edit --visibility public" "$PR" "gh repo edit acme/priv --visibility public" "PUBLIC"
passes "repo edit --visibility private" "$PR" "gh repo edit acme/pub --visibility private"
passes "repo edit other flags" "$PR" "gh repo edit --description hi"
passes "gh pr view is untouched" "$PR" "gh pr view 3"

# 10b. Triage of the amass sweep: each was run with its exact input.
X=$T/xtra; mkrepo "$X" https://github.com/acme/pub.git
commit "$X" w.md "++ path /Users/jsmith/z is an added line that starts with three pluses"   # EXAMPLE: fixture
asks "added line '+++ ...' is content, not a file header" "$X" "git push" "[home path]" "w.md:"
( cd "$X" && git reset -q --hard HEAD~1 )
commit "$X" w.md "ok" $'subject\n\n\x01 \x02 literal delimiter bytes in a message'
passes "literal control bytes in a message do not derail the parse" "$X" "git push"
commit "$X" y.md "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
asks "unbalanced quote does not hide a push" "$X" "git commit -m 'oops && git push" "could not be parsed"
asks "push inside $( ) is still parsed as a command" "$X" 'echo $(git push origin main)' "[AWS key]"
asks "push inside eval is asked about" "$X" 'eval "git push origin main"' "eval"
passes "unbalanced quote without a push stays silent" "$X" "echo 'unclosed"
( cd "$X" && git remote set-url origin 'ext::sh -c foo' )
asks "an ext:: remote is not silently passed" "$X" "git push" "not a GitHub host"
( cd "$X" && git remote set-url origin https://github.com/acme/pub.git && git reset -q --hard HEAD~1 )
mkdir -p "$X/sub" && printf 'import sys\nprint("PWNED", file=open("/dev/stderr","w"))\nsys.exit(0)\n' > "$X/json.py"
commit "$X" y2.md "ghp_abcdefghijklmnopqrstuvwxyz0123456789"   # EXAMPLE: fixture
asks "a planted json.py in the project is not imported" "$X" "git push" "[GitHub token]"
rm -f "$X/json.py"; ( cd "$X" && git reset -q --hard HEAD~1 )
printf PUBLIC > "$T/vis/acme_a-b"; printf PRIVATE > "$T/vis/acme_a_b"
rm -rf "$HOME/.megavibe/cache"
Y=$T/coll1; mkrepo "$Y" https://github.com/acme/a-b.git; commit "$Y" l.md "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"   # EXAMPLE: fixture
Z=$T/coll2; mkrepo "$Z" https://github.com/acme/a_b.git; commit "$Z" l.md "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"   # EXAMPLE: fixture
passes "private repo a_b" "$Z" "git push"
asks "public repo a-b is not served a_b's cached PRIVATE" "$Y" "git push" "[GitHub token]"
EH=$T/edit; mkrepo "$EH" https://github.com/acme/pub.git; ( cd "$EH" && git checkout -q -b side && echo "tok ghp_abcdefghijklmnopqrstuvwxyz0123456789" > s.txt && git add s.txt && git commit -qm side && git checkout -q main )   # EXAMPLE: fixture
asks "repo edit public scans every branch" "$EH" "gh repo edit --visibility public" "every branch" "[GitHub token]"
passes "placeholder token on an EXAMPLE line" "$X" "git push"
commit "$X" ex.md "token: ghp_EXAMPLEexampleEXAMPLEexample01234567   # EXAMPLE placeholder"
passes "a line marked EXAMPLE is a placeholder, not a secret" "$X" "git push"

mkdir -p "$T/gitfail"; REALGIT=$(command -v git)
printf '#!/bin/bash\ncase " $* " in *" -p "*) exit 1;; esac\nexec %s "$@"\n' "$REALGIT" > "$T/gitfail/git"; chmod +x "$T/gitfail/git"
commit "$X" z.md "fine text"
OUT=$(jq -n --arg c "git push" --arg d "$X" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | PATH="$T/gitfail:$PATH" bash "$HOOK" 2>/dev/null)
case "$OUT" in *"scan could not run"*) ok ;; *) bad "a failing git log must ask, not pass (out=${OUT:0:120})" ;; esac

# 10c. Round-1 reader findings, each reproduced first.
R1=$T/r1; mkrepo "$R1" https://github.com/acme/priv.git
( cd "$R1" && git checkout -q -b secret && echo "ghp_abcdefghijklmnopqrstuvwxyz0123456789" > s.txt && git add s.txt && git commit -qm sec && git update-ref refs/remotes/origin/secret HEAD && git config remote.origin.pushurl https://github.com/acme/pub.git )   # EXAMPLE: fixture
asks "tracking refs of a private FETCH url do not excuse a different public push url" "$R1" "git push origin secret" "[GitHub token]"
R2=$T/r2; mkrepo "$R2" https://github.com/acme/pub.git
( cd "$R2" && git checkout -q -b secret && echo "ghp_abcdefghijklmnopqrstuvwxyz0123456789" > s.txt && git add s.txt && git commit -qm sec && git checkout -q main && git config remote.origin.push secret:secret )   # EXAMPLE: fixture
asks "remote.<name>.push is what git pushes, not HEAD" "$R2" "git push origin" "[GitHub token]"
asks "global -R before the group and verb" "$PR" "gh -R acme/pub pr create --title ghp_abcdefghijklmnopqrstuvwxyz0123456789 --body y" "[GitHub token]"   # EXAMPLE: fixture
R4=$T/r4; mkrepo "$R4" https://github.com/acme/pub.git
( cd "$R4" && echo "AKIAABCDEFGHIJKLMNOP" > ghp_abcdefghijklmnopqrstuvwxyz0123456789.txt && git add . && git commit -qm f )   # EXAMPLE: fixture
run "$R4" "git push"; lacks "a secret in a file NAME is not echoed in full" "ghp_abcdefghijklmnopqrstuvwxyz0123456789"; lacks "AWS value" "ABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
case "$WHY" in *"[AWS key]"*) ok ;; *) bad "file-name case still asks" ;; esac

# 10d. Round-1 (second reader) findings.
M=$T/m1; mkrepo "$M" https://github.com/acme/pub.git
( cd "$M" && git checkout -q -b release && echo "ghp_abcdefghijklmnopqrstuvwxyz0123456789" > r.txt && git add r.txt && git commit -qm rel && git update-ref refs/remotes/origin/release HEAD~1 && git checkout -q main )   # EXAMPLE: fixture
( cd "$M" && git config remote.origin.push release:release )
asks "--repo origin honours remote.origin.push" "$M" "git push --repo origin" "[GitHub token]"
( cd "$M" && git config --unset remote.origin.push && git config push.default matching )
asks "push.default=matching scans every branch" "$M" "git push origin" "[GitHub token]"
( cd "$M" && git config --unset push.default )
asks "the ':' matching refspec is not a delete" "$M" "git push origin :" "[GitHub token]"
passes "a real delete refspec still passes" "$M" "git push origin :old"
( cd "$M" && git checkout -q release )
asks "attached -C<path> reaches the other checkout" "$T/otherdir" "git -C$M push origin release" "[GitHub token]"
asks "attached -c<key=val> before push still parsed" "$M" "git -ccore.x=1 push origin release" "[GitHub token]"
asks "a subshell's cd does not leak into the next push" "$M" "(cd $T/otherdir && git status); git push origin release" "[GitHub token]"
asks "a child shell's cd does not leak either" "$M" "bash -c 'cd $T/otherdir'; git push origin release" "[GitHub token]"
( cd "$M" && git checkout -q main )

# 10e. Round-2 reader findings.
asks "angle brackets inside a quoted PR body are not a redirection" "$PR" "gh pr create --title t --body 'Contact <alice@internal-corp.biz> today'" "[email]"   # EXAMPLE: fixture
passes "a real redirection is still stripped from push args" "$PUB" "git push origin main > /dev/null"
RW=$T/rw; mkrepo "$RW" https://github.com/acme/priv.git
( cd "$RW" && git config "url.https://github.com/acme/pub.git.pushInsteadOf" https://github.com/acme/priv.git && echo "ghp_abcdefghijklmnopqrstuvwxyz0123456789" > t.txt && git add t.txt && git commit -qm t )   # EXAMPLE: fixture
asks "pushInsteadOf rewrites an explicit URL" "$RW" "git push https://github.com/acme/priv.git main" "[GitHub token]"
asks "inline GH_REPO selects the public repo" "$T/otherdir" "GH_REPO=acme/pub gh pr create --title ghp_abcdefghijklmnopqrstuvwxyz0123456789 --body y" "[GitHub token]"   # EXAMPLE: fixture
asks "env GH_REPO= wrapper form" "$T/otherdir" "env GH_REPO=acme/pub gh pr create --title ghp_abcdefghijklmnopqrstuvwxyz0123456789 --body y" "[GitHub token]"   # EXAMPLE: fixture

# 10f. Round-2 (second reader) findings.
asks "--body='two words' keeps its content" "$PR" "gh pr create --title=t --body='key AKIAABCDEFGHIJKLMNOP'" "[AWS key]"   # EXAMPLE: fixture
MV=$T/mv; mkrepo "$MV" https://github.com/acme/pub.git
( cd "$MV" && git checkout -q -b other && echo "ghp_abcdefghijklmnopqrstuvwxyz0123456789" > o.txt && git add o.txt && git commit -qm o && git checkout -q main )   # EXAMPLE: fixture
asks "variable refspec on a public remote" "$MV" 'BRANCH=other; git push origin "$BRANCH"' "unexpanded variable"
asks "variable remote" "$MV" 'REMOTE=origin; git push "$REMOTE" main' "unexpanded variable"
passes "variable refspec on a private remote" "$PRIV" 'B=main; git push origin "$B"'
( cd "$MV" && git config remote.origin.mirror true )
asks "remote.<name>.mirror=true scans every branch" "$MV" "git push origin" "[GitHub token]"
( cd "$MV" && git config --unset remote.origin.mirror )
printf 'AKIAABCDEFGHIJKLMNOP\n' > "$HOME/.megavibe/personal/public-push.deny"   # EXAMPLE: fixture
( cd "$MV" && git checkout -q -b k && echo "AKIAABCDEFGHIJKLMNOP" > k.txt && git add k.txt && git commit -qm k )   # EXAMPLE: fixture
run "$MV" "git push origin k"; lacks "denylist value is redacted like any secret" "ABCDEFGHIJKL"
case "$WHY" in *"denylist"*) ok ;; *) bad "denylist hit still reported" ;; esac
rm -f "$HOME/.megavibe/personal/public-push.deny"; ( cd "$MV" && git checkout -q main )

asks "an unparseable nested shell string with a push asks" "$MV" "bash -c \"git push origin 'main\"" "nested shell"

# 10g. Round-3 findings.
CM=$T/cm; mkrepo "$CM" https://github.com/acme/pub.git; commit "$CM" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
asks "a trailing shell comment does not hide the push" "$CM" "git push # publish this branch" "[AWS key]"
passes "a # inside quotes is not a comment (commit message)" "$CM" "git commit -m 'fix #12'"
asks "a quoted # argument stays an argument" "$CM" "git push origin 'main' # c" "[AWS key]"
( cd "$CM" && git reset -q --hard HEAD~1 )
( cd "$CM" && echo x > "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-AKIAABCDEFGHIJKLMNOP.txt" && git add . && git commit -qm f )   # EXAMPLE: fixture
run "$CM" "git push"; lacks "a long file name is redacted before it is cut" "AKIAABCDE"
case "$WHY" in *"AWS key"*) ok ;; *) bad "secret in a file name is reported" ;; esac
( cd "$CM" && git reset -q --hard HEAD~1 )
passes "clean PR with a home path earlier in the command" "$PR" "cd /Users/jsmith/project && gh pr create -R acme/pub --title Clean --body Done"   # EXAMPLE: fixture

# 10h. Round-3 (second reader) findings.
SR=$T/sr; mkdir -p "$SR" && ( cd "$SR" && git init -q && git remote add upstream https://github.com/acme/pub.git && echo a > a.txt && git add a.txt && git commit -qm i && echo "AKIAABCDEFGHIJKLMNOP" > k.txt && git add k.txt && git commit -qm k )   # EXAMPLE: fixture
asks "the sole remote is used when it is not called origin" "$SR" "git -c push.default=current push" "[AWS key]"
printf 'AKIAABCDEFGHIJKLMNOP\n' > "$HOME/pr.md"   # EXAMPLE: fixture
asks "--body-file ~/pr.md" "$PR" "gh pr create -R acme/pub --title Fix --body-file ~/pr.md" "[AWS key]"
asks "--body-file \$HOME/pr.md" "$PR" 'gh pr create -R acme/pub --title Fix --body-file "$HOME/pr.md"' "[AWS key]"
asks "--body-file - with no readable stdin source asks" "$PR" "cat x.md | gh pr create -R acme/pub --title Fix --body-file -" "could not be read"
asks "--body-file that does not exist asks" "$PR" "gh pr create -R acme/pub --title Fix --body-file /nonexistent/x.md" "could not be read"
rm -f "$HOME/pr.md"
printf 'Customer-X\n' > "$HOME/.megavibe/personal/public-push.deny"
DQ=$T/dq; mkrepo "$DQ" https://github.com/acme/pub.git; ( cd "$DQ" && echo ok > "Customer-X-ä.txt" && git add . && git commit -qm f )
asks "denylist hits a git-quoted (non-ASCII) file name" "$DQ" "git push" "denylist"
( cd "$DQ" && git config diff.noprefix true && git reset -q --hard HEAD~1 && echo ok > Customer-X.txt && git add . && git commit -qm g )
asks "diff.noprefix does not hide a file name" "$DQ" "git push" "denylist"
rm -f "$HOME/.megavibe/personal/public-push.deny"

# 10i. Round-4 findings.
asks "variable git -C directory asks" "$M" 'D=/nope; git -C "$D" push origin main' "not statically known"
TG=$T/tg; mkrepo "$TG" https://github.com/acme/pub.git; ( cd "$TG" && git checkout -q -b tmp && echo "AKIAABCDEFGHIJKLMNOP" > t.txt && git add t.txt && git commit -qm t && git tag v9 && git checkout -q main && git branch -qD tmp )   # EXAMPLE: fixture
asks "refs/tags/* reaches a tag-only commit" "$TG" "git push origin 'refs/tags/*:refs/tags/*'" "[AWS key]"
asks "variable PR body asks" "$PR" 'BODY=x; gh pr create -R acme/pub --title Clean --body "$BODY"' "unexpanded variable"
mkdir -p "$T/Users/jsmith"; printf 'Clean summary\n' > "$T/Users/jsmith/body.md"   # EXAMPLE: fixture
passes "a body-file path is not published text" "$PR" "gh pr create -R acme/pub --title Fix --body-file $T/Users/jsmith/body.md"   # EXAMPLE: fixture
CL=$T/cl; mkrepo "$CL" https://github.com/acme/pub.git; commit "$CL" README.md "git clone git@github.com:acme/pub.git"   # EXAMPLE: fixture
passes "an ssh clone URL is not an email" "$CL" "git push"

# 10j. Round-5 findings.
QR=$T/qr; mkrepo "$QR" https://github.com/acme/pub.git; commit "$QR" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
asks "a quoted redirection operand is not an argument" "$QR" 'git push > "push.log"' "[AWS key]"
asks "single-quoted operand and fd redirect" "$QR" "git push 2> 'err.log' 1>>out.log" "[AWS key]"
( cd "$QR" && git reset -q --hard HEAD~1 )
asks "gh repo create --public=true" "$PR" "gh repo create newthing --public=true" "PUBLIC"
passes "gh repo create --public=false" "$PR" "gh repo create newthing --public=false"
TM=$T/tm; mkrepo "$TM" https://github.com/acme/pub.git; ( cd "$TM" && git tag -a rel -m "release key AKIAABCDEFGHIJKLMNOP" )   # EXAMPLE: fixture
asks "annotated tag message, named tag" "$TM" "git push origin rel" "tag rel message" "[AWS key]"
asks "annotated tag message, --follow-tags" "$TM" "git push --follow-tags origin main" "[AWS key]"
asks "annotated tag message, --tags" "$TM" "git push --tags origin" "[AWS key]"
passes "lightweight tag has no message" "$PUB" "git push origin v-none"

asks "--recurse-submodules <value> before the remote" "$TG" "git push --recurse-submodules on-demand origin 'refs/tags/*:refs/tags/*'" "[AWS key]"
SH=$T/sh; mkrepo "$SH" https://github.com/acme/priv.git; ( cd "$SH" && git config "url.https://github.com/acme/pub.git.insteadOf" publish && echo AKIAABCDEFGHIJKLMNOP > k.txt && git add k.txt && git commit -qm k )   # EXAMPLE: fixture
asks "an insteadOf shorthand without a colon is a URL" "$SH" "git push publish main" "[AWS key]"

# 10k. Round-6 findings (tag messages).
( cd "$TM" && git config push.followTags true )
asks "push.followTags publishes the annotated tag" "$TM" "git push origin main" "[AWS key]"
( cd "$TM" && git config --unset push.followTags )
asks "a refs/tags/* refspec scans annotated tag messages" "$TM" "git push origin 'refs/tags/*:refs/tags/*'" "[AWS key]"
TS=$T/ts; mkrepo "$TS" https://github.com/acme/pub.git
( cd "$TS" && git checkout -q -b abandoned && echo x > x.txt && git add x.txt && git commit -qm x && git tag -a lost -m "key AKIAABCDEFGHIJKLMNOP" && git checkout -q main )   # EXAMPLE: fixture
passes "--follow-tags ignores a tag on an unpushed side branch" "$TS" "git push --follow-tags origin main"

asks "export GH_REPO then the PR command" "$T/otherdir" "export GH_REPO=acme/pub; gh pr create --title AKIAABCDEFGHIJKLMNOP --body y" "[AWS key]"   # EXAMPLE: fixture
asks "bare GH_REPO assignment then the PR command" "$T/otherdir" "GH_REPO=acme/pub; gh pr create --title AKIAABCDEFGHIJKLMNOP --body y" "[AWS key]"   # EXAMPLE: fixture
asks "GH_REPO inherited by bash -c" "$T/otherdir" "GH_REPO=acme/pub bash -c 'gh pr create --title AKIAABCDEFGHIJKLMNOP --body y'" "[AWS key]"   # EXAMPLE: fixture
passes "GH_REPO of a private repo stays private" "$T/otherdir" "export GH_REPO=acme/priv; gh pr create --title AKIAABCDEFGHIJKLMNOP --body y"   # EXAMPLE: fixture

( cd "$TS" && git tag -d lost >/dev/null && git checkout -q abandoned && git tag -a lost2 -m "key AKIAQRSTUVWXYZABCDEF" && git checkout -q main )   # EXAMPLE: fixture
asks "--all --follow-tags reaches a tag on a side branch" "$TS" "git push --all --follow-tags origin" "[AWS key]"
( cd "$TS" && git tag -a ghp_abcdefghijklmnopqrstuvwxyz0123456789 -m "k AKIAABCDEFGHIJKLMNOP" main )   # EXAMPLE: fixture
run "$TS" "git push --tags origin"; lacks "a token-shaped tag name is redacted before it is cut" "ghp_abcdefghijklmnopqrstuvwxyz"   # EXAMPLE: fixture

asks "a subshell's export GH_REPO does not leak out" "$PR" "(export GH_REPO=acme/priv; gh repo view); gh pr create --title AKIAABCDEFGHIJKLMNOP --body y" "[AWS key]"   # EXAMPLE: fixture
asks "unset GH_REPO clears the selection" "$PR" "export GH_REPO=acme/priv; unset GH_REPO; gh pr create --title AKIAABCDEFGHIJKLMNOP --body y" "[AWS key]"   # EXAMPLE: fixture

( cd "$M" && git checkout -q -b feature2 && echo "AKIAABCDEFGHIJKLMNOP" > f2.txt && git add f2.txt && git commit -qm f2 && git checkout -q main )   # EXAMPLE: fixture
asks "--branches is an alias for --all" "$M" "git push --branches origin" "[AWS key]"

( cd "$TM" && git config push.followTags true )
passes "--no-follow-tags overrides push.followTags" "$TM" "git push --no-follow-tags origin main"
( cd "$TM" && git config --unset push.followTags )
mkdir -p "$T/gitenv"; printf '#!/bin/bash\nprintf "%%s %%s\\n" "${GIT_NO_LAZY_FETCH:-unset}" "${GIT_TERMINAL_PROMPT:-unset}" >> "%s/gitenv.log"\nexec %s "$@"\n' "$T" "$REALGIT" > "$T/gitenv/git"; chmod +x "$T/gitenv/git"
: > "$T/gitenv.log"; commit "$CM" z2.txt "x"
jq -n --arg c "git push" --arg d "$CM" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | PATH="$T/gitenv:$PATH" bash "$HOOK" >/dev/null 2>&1
if [ -s "$T/gitenv.log" ] && ! grep -qv '^1 0$' "$T/gitenv.log"; then ok; else bad "every git call runs with GIT_NO_LAZY_FETCH=1 and no terminal prompt ($(sort -u "$T/gitenv.log" | head -3 | tr '\n' ';'))"; fi

( cd "$M" && git config push.default matching )
asks "push.default=matching with an explicit URL" "$M" "git push https://github.com/acme/pub.git" "[AWS key]"
( cd "$M" && git config --unset push.default )

SP2="$T/my project"; mkrepo "$SP2" https://github.com/acme/pub.git; commit "$SP2" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
asks "git -C with an escaped space" /tmp "git -C $T/my\\ project push origin main" "[AWS key]"
asks "cd with an escaped space" /tmp "cd $T/my\\ project && git push origin main" "[AWS key]"
asks "--body='...' is not excused by a word in --title" "$PR" "gh pr create -R acme/pub --title 'Add example' --body='key AKIAABCDEFGHIJKLMNOP'" "[AWS key]"   # EXAMPLE: fixture
# ssh aliases come from ~/.ssh/config as text; `ssh -G` would run a Match exec command
mkdir -p "$HOME/.ssh" "$T/marker"; printf 'Host work-alias\n  HostName github.com\n  Match exec "touch %s/marker/ran"\n' "$T" > "$HOME/.ssh/config"
SA=$T/sa; mkrepo "$SA" git@work-alias:acme/pub.git; commit "$SA" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
asks "an ssh alias resolved from ~/.ssh/config" "$SA" "git push" "[AWS key]"
if [ ! -e "$T/marker/ran" ]; then ok; else bad "ssh -G must not run Match exec"; fi
rm -rf "$HOME/.ssh"

passes "a clean PR chained with an unrelated command" "$PR" "gh pr create -R acme/pub --title Clean --body Done && echo /Users/jsmith/project"   # EXAMPLE: fixture
asks "quoted ; inside a PR body is still scanned" "$PR" "gh pr create -R acme/pub --title Clean --body 'a; AKIAABCDEFGHIJKLMNOP' && echo hi" "[AWS key]"   # EXAMPLE: fixture

asks "a multi-line quoted PR body keeps its '## ' heading line" "$PR" "gh pr create --title Fix --body '## Summary
## ${AKIA_PFX}ABCDEFGHIJKLMNOP
Changes ready'" "[AWS key]"
commit "$QR" k2.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
asks "a comment inside bash -c does not hide the push (leak present)" "$QR" "bash -c 'git push # publish'" "[AWS key]"
asks "bash -lc with a comment" "$QR" "bash -lc 'git push origin main # go'" "[AWS key]"

asks "two chained PR commands, the second with --body='...'" "$PR" "gh pr create -R acme/priv --title Clean --body Done; gh pr create -R acme/pub --title Clean --body='key AKIAABCDEFGHIJKLMNOP'" "[AWS key]"   # EXAMPLE: fixture
GD=$T/gd; mkrepo "$GD" https://github.com/acme/pub.git; commit "$GD" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
asks "inline GIT_DIR selects the repository" "$T/otherdir" "GIT_DIR=$GD/.git git push origin main" "[AWS key]"

CP=$T/cp; mkrepo "$CP" https://github.com/acme/pub.git
printf 'AKIAABCDEFGHIJKLMNOP\n' > "$CP/new.txt"   # EXAMPLE: fixture
rm -f "$CP/new.txt"; echo "AKIAABCDEFGHIJKLMNOP" >> "$CP/a.txt"   # EXAMPLE: fixture
( cd "$CP" && git checkout -q -- a.txt )
echo "clean addition" >> "$CP/a.txt"
( cd "$CP" && git checkout -q -- a.txt )

SW=$T/sw; mkrepo "$SW" https://github.com/acme/pub.git
( cd "$SW" && git checkout -q -b feature && echo "AKIAABCDEFGHIJKLMNOP" > f.txt && git add f.txt && git commit -qm f && git checkout -q main )   # EXAMPLE: fixture
RS=$T/rs; mkrepo "$RS" https://github.com/acme/priv.git; commit "$RS" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture

FM=$T/fm; mkrepo "$FM" https://github.com/acme/pub.git
printf '#!/bin/bash\ntouch "%s/fsmonitor-ran"\nprintf "\\0"\n' "$T" > "$T/fsmon.sh"; chmod +x "$T/fsmon.sh"; ( cd "$FM" && git config core.fsmonitor "$T/fsmon.sh" )
run "$FM" 'git commit --allow-empty -m clean && git push origin main'
if [ ! -e "$T/fsmonitor-ran" ]; then ok; else bad "a configured core.fsmonitor must not run"; fi
printf 'key AKIAABCDEFGHIJKLMNOP\n' > "$T/msg.txt"   # EXAMPLE: fixture
echo "clean2" >> "$CP/a.txt"; printf 'AKIAABCDEFGHIJKLMNOP\n' > "$CP/local-notes.txt"   # EXAMPLE: fixture
rm -f "$CP/local-notes.txt"; ( cd "$CP" && git checkout -q -- a.txt )

echo "AKIAABCDEFGHIJKLMNOP" >> "$CP/a.txt"   # EXAMPLE: fixture
( cd "$CP" && git checkout -q -- a.txt )
GP=$T/gp; mkrepo "$GP" https://github.com/acme/priv.git
( cd "$GP" && git checkout -q -b feature && echo "AKIAABCDEFGHIJKLMNOP" > f.txt && git add f.txt && git commit -qm f && git remote add publicr https://github.com/acme/pub.git && git config branch.feature.pushRemote publicr && git checkout -q main )   # EXAMPLE: fixture
printf '#!/bin/bash\ntouch "%s/gpg-ran"\nexit 0\n' "$T" > "$T/gpgstub.sh"; chmod +x "$T/gpgstub.sh"
( cd "$GP" && git config gpg.program "$T/gpgstub.sh" && git config log.showSignature true && git checkout -q feature )
run "$GP" "git push publicr feature"
if [ ! -e "$T/gpg-ran" ]; then ok; else bad "a configured gpg.program must not run during the scan"; fi
( cd "$GP" && git checkout -q main )

asks "export GIT_DIR then push" "$T/otherdir" "export GIT_DIR=$GD/.git; git push origin main" "[AWS key]"
passes "unset GIT_DIR restores the checkout" "$PUB" "export GIT_DIR=$GD/.git; unset GIT_DIR; git push origin main"

NB=$T/nb; mkrepo "$NB" https://github.com/acme/pub.git; commit "$NB" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
asks "a merge before the push cannot be seen: ask" "$SW" "git merge --ff-only feature && git push origin main" "separate call"
passes "a merge before a push to a private repo is silent" "$PRIV" "git merge --ff-only x && git push origin main"
printf 'AKIAABCDEFGHIJKLMNOP\n' > "$CP/new.txt"   # EXAMPLE: fixture
rm -f "$CP/new.txt"; echo "AKIAABCDEFGHIJKLMNOP" >> "$CP/a.txt"   # EXAMPLE: fixture
( cd "$CP" && git checkout -q -- a.txt )

( cd "$SW" && git checkout -q main )
mkdir -p "$CP/config" "$CP/sub"; printf 'AKIAABCDEFGHIJKLMNOP\n' > "$CP/config/key.txt"   # EXAMPLE: fixture
rm -rf "$CP/config"; printf 'AKIAABCDEFGHIJKLMNOP\n' > "$CP/sub/new.txt"   # EXAMPLE: fixture
rm -rf "$CP/sub"
printf 'clean\n' > "$T/body2.md"
asks "a body file written earlier in the same command" "$PR" "printf 'AKIAABCDEFGHIJKLMNOP' > $T/body2.md && gh pr create -R acme/pub --title Config --body-file $T/body2.md" "[AWS key]"   # EXAMPLE: fixture

# 10z. Predecessors are not simulated: a state-changing git command before the push, public target -> ask.
for pre in "git add a.txt" "git commit -m x" "git commit -am x" "git add . && git commit -m x" "git switch -c nb" "git checkout feature" "git branch nb2" \
           "git merge --ff-only feature" "git rebase main" "git cherry-pick HEAD" "git stash" "git reset --hard" "git tag v1.2" "git restore a.txt"; do
  asks "ask: '$pre' before a push to a public repo" "$PUB" "$pre && git push origin main" "separate call"
done
passes "no ask: a read-only git command before the push" "$PUB" "git status && git log -1 && git push origin main"
passes "no ask: the same chain to a private repo" "$PRIV" "git add a.txt && git commit -m x && git push origin main"
asks "ask even for a private repo: git remote set-url first" "$PRIV" "git remote set-url origin https://github.com/acme/pub.git && git push origin main" "changes where the push goes"
asks "ask: git config first" "$PRIV" "git config remote.origin.pushurl https://github.com/acme/pub.git && git push origin main" "changes where the push goes"
passes "no ask: git config --get first" "$PRIV" "git config --get remote.origin.url && git push origin main"
asks "a standalone push keeps the full scan" "$M" "git push origin feature2" "[AWS key]"

SM=$T/sm; mkrepo "$SM" https://github.com/acme/priv.git; printf '[submodule "s"]\n\tpath = s\n\turl = https://github.com/acme/pub.git\n' > "$SM/.gitmodules"
asks "--recurse-submodules=on-demand with a .gitmodules asks" "$SM" "git push --recurse-submodules=on-demand origin main" "submodules"
asks "--recurse-submodules on-demand (separate value)" "$SM" "git push --recurse-submodules on-demand origin main" "submodules"
( cd "$SM" && git config push.recurseSubmodules on-demand )
asks "push.recurseSubmodules=on-demand asks" "$SM" "git push origin main" "submodules"
( cd "$SM" && git config --unset push.recurseSubmodules )
passes "no recursion, private parent: silent" "$SM" "git push origin main"

# 10i. Final-round fixes: pushd/popd, stdin-like body files, FIFO body files.
asks "pushd then popd leaves the directory unknown, so the push asks" "$SR" "pushd $PRIV >/dev/null; popd >/dev/null; git -c push.default=current push"
asks "pushd alone leaves the directory unknown" "$SR" "pushd $PRIV >/dev/null && git -c push.default=current push"
asks "--body-file /dev/stdin asks" "$PR" "cat x.md | gh pr create -R acme/pub --title Fix --body-file /dev/stdin" "could not be read"
asks "--body-file /dev/fd/0 asks" "$PR" "cat x.md | gh pr create -R acme/pub --title Fix --body-file /dev/fd/0" "could not be read"
mkfifo "$T/body.fifo"
S0=$SECONDS; run "$PR" "gh pr create -R acme/pub --title Fix --body-file $T/body.fifo"
if [ "$RC" = 0 ] && [ -n "$WHY" ] && [ $((SECONDS-S0)) -lt 5 ]; then ok; else bad "a FIFO --body-file must ask without hanging (rc=$RC)"; fi

mkdir -p "$HOME/.megavibe/personal"; mkfifo "$HOME/.megavibe/personal/public-push.trusted"
S0=$SECONDS; run "$PUB" "git push origin main"; if [ $((SECONDS-S0)) -lt 8 ]; then ok; else bad "a FIFO trusted-file must not hang the hook"; fi
rm -f "$HOME/.megavibe/personal/public-push.trusted"

mkdir -p "$T/slowgit"; REALGIT=$(command -v git)
printf '#!/bin/bash\ncase "$*" in *get-url*) exec sleep 30;; esac\nexec %s "$@"\n' "$REALGIT" > "$T/slowgit/git"; chmod +x "$T/slowgit/git"
OLDPATH=$PATH; PATH="$T/slowgit:$PATH"; asks "a timed-out remote resolution asks instead of passing" "$PUB" "git push origin main" "timed out"; PATH=$OLDPATH

# 11. Fail open: no jq / python3 in PATH is a silent pass is covered by the header; check a malformed event.
OUT=$(printf 'not json' | bash "$HOOK" 2>/dev/null); RC=$?; if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "malformed input fails open"; fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
