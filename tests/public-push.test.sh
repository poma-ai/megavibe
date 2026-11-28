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
if [ "$1" = api ]; then   # gh api repos/<nwo>/git/commits/<sha>: found, unless the sha is listed in $STUB_DIR/absent; not counted as a lookup
  [ "${GH_FAIL:-0}" = 1 ] && { echo "gh: connection failed" >&2; exit 1; }
  grep -qx "${2##*/}" "$STUB_DIR/absent" 2>/dev/null && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
  echo "${2##*/}"; exit 0
fi
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
KNOWN="$HOME/.megavibe/personal/public-push.known-public"; printf '# the fixture expects every github.com repository to be public\ngithub.com/*\n' > "$KNOWN"

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
denies() {  # denies <name> <cwd> <cmd> [text the reason must contain]...: the guard refuses and tells the agent how to issue the command again
  local name=$1 cwd=$2 cmd=$3; run "$cwd" "$cmd"; shift 3
  WHY=$(printf '%s' "$OUT" | jq -r 'select(.hookSpecificOutput.permissionDecision == "deny") | .hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
  if [ "$RC" != 0 ] || [ -z "$WHY" ]; then bad "$name (rc=$RC, no deny: ${OUT:0:160})"; return; fi
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
denies "cd into a variable cannot be resolved" /tmp 'cd "$X" && git push' "not statically known"
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
passes "pr create: clean text" "$PR" "gh pr create --title 'Fix thing' --body '## Summary
ok'"
passes "pr create to a private repo" "$PR" "gh pr create -R acme/priv --title '/Users/jsmith/x' --body y"   # EXAMPLE: fixture
mkdir -p "$T/otherdir" && ( cd "$T/otherdir" && git init -q && git remote add origin https://github.com/cur/rent.git )
printf PUBLIC > "$T/vis/acme_pub"
printf PRIVATE > "$T/vis/cur_rent"
passes "pr create resolves the base repo from the command's cd, not the hook's cwd" /tmp "cd $T/otherdir && gh pr create --title /Users/jsmith/x --body y"   # EXAMPLE: fixture
printf PUBLIC > "$T/vis/cur_rent"
asks "pr create: gh cannot tell" "$PR" "gh pr create -R acme/mystery --title t --body b" "could not determine"
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
passes "a real redirection is still stripped from push args" "$PUB" "git push origin main > /dev/null"
RW=$T/rw; mkrepo "$RW" https://github.com/acme/priv.git
( cd "$RW" && git config "url.https://github.com/acme/pub.git.pushInsteadOf" https://github.com/acme/priv.git && echo "ghp_abcdefghijklmnopqrstuvwxyz0123456789" > t.txt && git add t.txt && git commit -qm t )   # EXAMPLE: fixture
asks "pushInsteadOf rewrites an explicit URL" "$RW" "git push https://github.com/acme/priv.git main" "[GitHub token]"

# 10f. Round-2 (second reader) findings.
MV=$T/mv; mkrepo "$MV" https://github.com/acme/pub.git
( cd "$MV" && git checkout -q -b other && echo "ghp_abcdefghijklmnopqrstuvwxyz0123456789" > o.txt && git add o.txt && git commit -qm o && git checkout -q main )   # EXAMPLE: fixture
denies "variable refspec on a public remote" "$MV" 'BRANCH=other; git push origin "$BRANCH"' "unexpanded variable"
denies "variable remote" "$MV" 'REMOTE=origin; git push "$REMOTE" main' "unexpanded variable"
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
HP="$T$USERS_DIR/jsmith/project"; mkrepo "$HP" https://github.com/acme/pub.git   # a real repository whose path holds a home-path-looking part
passes "clean PR with a home path earlier in the command" "$PR" "cd $HP && gh pr create -R acme/pub --title Clean --body Done"   # EXAMPLE: fixture

# 10g. gh pr create can push the current branch itself: unpushed commits are scanned; --template is read.
PU=$T/pu; mkrepo "$PU" https://github.com/acme/pub.git
commit "$PU" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
passes "pr create to a private base does not scan commits" "$PU" "gh pr create -R acme/priv --title Fix --body Done"
( cd "$PU" && git update-ref refs/remotes/origin/feature HEAD )
passes "pr create: the branch is already on a remote" "$PU" "gh pr create -R acme/pub --title Fix --body Done"
PC=$T/pc; mkrepo "$PC" https://github.com/acme/pub.git; commit "$PC" a.txt "plain change"
passes "pr create: an unpushed clean commit passes" "$PC" "gh pr create -R acme/pub --title Fix --body Done"
printf 'AKIAABCDEFGHIJKLMNOP\n' > "$T/tpl.md"   # EXAMPLE: fixture
PD=$T/pd; mkrepo "$PD" https://github.com/acme/pub.git; commit "$PD" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
passes "pr create after a commit in the same call to a private base passes" "$PC" "git add a.txt && git commit -qm x && gh pr create -R acme/priv --title Fix --body Done"
denies "pr create after a remote change in the same call" "$PC" "git remote set-url origin https://github.com/acme/pub.git && gh pr create -R acme/pub --title Fix --body Done" "separate call"
PV=$T/pv; mkrepo "$PV" git@github.com:acme/priv.git; commit "$PV" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
denies "pr create after a remote retarget from a private origin asks" "$PV" "git remote set-url origin https://github.com/acme/pub.git && gh pr create --title Fix --body Done" "separate call"
PRL=$T/prl; mkrepo "$PRL" https://github.com/acme/pub.git; mkdir -p "$PRL/sub"; commit "$PRL" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
( cd "$PRL" && git config diff.relative true )
asks "push from a subdirectory with diff.relative=true still sees the whole commit" "$PRL" "cd sub && git push" "[AWS key]"
RR=$T/rr; mkdir -p "$RR" && ( cd "$RR" && git init -q && git remote add origin https://github.com/acme/pub.git && printf 'AKIAABCDEFGHIJKLMNOP\n' > key.txt && git add key.txt && git commit -qm root )   # EXAMPLE: fixture
asks "a root commit with a secret is seen with default git config" "$RR" "git push origin main" "[AWS key]"
( cd "$RR" && git config log.showRoot false && git config diff.renames copies && git config diff.ignoreSubmodules all && git config core.quotepath false )
asks "log.showRoot=false does not hide a root commit from a push scan" "$RR" "git push origin main" "[AWS key]"
printf 'clean\n' > "$PC/template.md"; printf 'AKIAABCDEFGHIJKLMNOP\n' > "$PC/secret.md"   # EXAMPLE: fixture
mkdir -p "$T$USERS_DIR/jsmith"; printf 'clean template\n' > "$T$USERS_DIR/jsmith/tpl-ok.md"
passes "the local path of a clean template is not published text" "$PC" "gh pr create -R acme/pub --title Clean --template $T$USERS_DIR/jsmith/tpl-ok.md"
head -c 1100000 /dev/zero | tr '\0' 'a' > "$T/big.md"
printf 'clean template\n' > "$T/tpl-ok.md"
passes "pr create --template with clean text passes" "$PC" "gh pr create -R acme/pub --title Fix --template $T/tpl-ok.md"

# 10h. Round-3 (second reader) findings.
SR=$T/sr; mkdir -p "$SR" && ( cd "$SR" && git init -q && git remote add upstream https://github.com/acme/pub.git && echo a > a.txt && git add a.txt && git commit -qm i && echo "AKIAABCDEFGHIJKLMNOP" > k.txt && git add k.txt && git commit -qm k )   # EXAMPLE: fixture
asks "the sole remote is used when it is not called origin" "$SR" "git -c push.default=current push" "[AWS key]"
printf 'AKIAABCDEFGHIJKLMNOP\n' > "$HOME/pr.md"   # EXAMPLE: fixture
rm -f "$HOME/pr.md"
printf 'Customer-X\n' > "$HOME/.megavibe/personal/public-push.deny"
DQ=$T/dq; mkrepo "$DQ" https://github.com/acme/pub.git; ( cd "$DQ" && echo ok > "Customer-X-ä.txt" && git add . && git commit -qm f )
asks "denylist hits a git-quoted (non-ASCII) file name" "$DQ" "git push" "denylist"
( cd "$DQ" && git config diff.noprefix true && git reset -q --hard HEAD~1 && echo ok > Customer-X.txt && git add . && git commit -qm g )
asks "diff.noprefix does not hide a file name" "$DQ" "git push" "denylist"
rm -f "$HOME/.megavibe/personal/public-push.deny"

# 10i. Round-4 findings.
denies "variable git -C directory asks" "$M" 'D=/nope; git -C "$D" push origin main' "not statically known"
TG=$T/tg; mkrepo "$TG" https://github.com/acme/pub.git; ( cd "$TG" && git checkout -q -b tmp && echo "AKIAABCDEFGHIJKLMNOP" > t.txt && git add t.txt && git commit -qm t && git tag v9 && git checkout -q main && git branch -qD tmp )   # EXAMPLE: fixture
asks "refs/tags/* reaches a tag-only commit" "$TG" "git push origin 'refs/tags/*:refs/tags/*'" "[AWS key]"
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

passes "GH_REPO of a private repo stays private" "$T/otherdir" "export GH_REPO=acme/priv; gh pr create --title AKIAABCDEFGHIJKLMNOP --body y"   # EXAMPLE: fixture

( cd "$TS" && git tag -d lost >/dev/null && git checkout -q abandoned && git tag -a lost2 -m "key AKIAQRSTUVWXYZABCDEF" && git checkout -q main )   # EXAMPLE: fixture
asks "--all --follow-tags reaches a tag on a side branch" "$TS" "git push --all --follow-tags origin" "[AWS key]"
( cd "$TS" && git tag -a ghp_abcdefghijklmnopqrstuvwxyz0123456789 -m "k AKIAABCDEFGHIJKLMNOP" main )   # EXAMPLE: fixture
run "$TS" "git push --tags origin"; lacks "a token-shaped tag name is redacted before it is cut" "ghp_abcdefghijklmnopqrstuvwxyz"   # EXAMPLE: fixture


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
# ssh aliases come from ~/.ssh/config as text; `ssh -G` would run a Match exec command
mkdir -p "$HOME/.ssh" "$T/marker"; printf 'Host work-alias\n  HostName github.com\n  Match exec "touch %s/marker/ran"\n' "$T" > "$HOME/.ssh/config"
SA=$T/sa; mkrepo "$SA" git@work-alias:acme/pub.git; commit "$SA" k.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
asks "an ssh alias resolved from ~/.ssh/config" "$SA" "git push" "[AWS key]"
if [ ! -e "$T/marker/ran" ]; then ok; else bad "ssh -G must not run Match exec"; fi
rm -rf "$HOME/.ssh"

passes "a clean PR chained with an unrelated command" "$PR" "gh pr create -R acme/pub --title Clean --body Done && echo /Users/jsmith/project"   # EXAMPLE: fixture

commit "$QR" k2.txt "AKIAABCDEFGHIJKLMNOP"   # EXAMPLE: fixture
asks "a comment inside bash -c does not hide the push (leak present)" "$QR" "bash -c 'git push # publish'" "[AWS key]"
asks "bash -lc with a comment" "$QR" "bash -lc 'git push origin main # go'" "[AWS key]"

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
denies "a merge before the push cannot be seen: ask" "$SW" "git merge --ff-only feature && git push origin main" "separate call"
passes "a merge before a push to a private repo is silent" "$PRIV" "git merge --ff-only x && git push origin main"
printf 'AKIAABCDEFGHIJKLMNOP\n' > "$CP/new.txt"   # EXAMPLE: fixture
rm -f "$CP/new.txt"; echo "AKIAABCDEFGHIJKLMNOP" >> "$CP/a.txt"   # EXAMPLE: fixture
( cd "$CP" && git checkout -q -- a.txt )

( cd "$SW" && git checkout -q main )
mkdir -p "$CP/config" "$CP/sub"; printf 'AKIAABCDEFGHIJKLMNOP\n' > "$CP/config/key.txt"   # EXAMPLE: fixture
rm -rf "$CP/config"; printf 'AKIAABCDEFGHIJKLMNOP\n' > "$CP/sub/new.txt"   # EXAMPLE: fixture
rm -rf "$CP/sub"
printf 'clean\n' > "$T/body2.md"

# 10z. Predecessors are not simulated: a state-changing git command before the push, public target -> ask.
for pre in "git add a.txt" "git commit -m x" "git commit -am x" "git add . && git commit -m x" "git switch -c nb" "git checkout feature" "git branch nb2" \
           "git merge --ff-only feature" "git rebase main" "git cherry-pick HEAD" "git stash" "git reset --hard" "git tag v1.2" "git restore a.txt"; do
  denies "deny: '$pre' before a push to a public repo" "$PUB" "$pre && git push origin main" "separate call"
done
passes "no ask: a read-only git command before the push" "$PUB" "git status && git log -1 && git push origin main"
passes "no ask: the same chain to a private repo" "$PRIV" "git add a.txt && git commit -m x && git push origin main"
denies "ask even for a private repo: git remote set-url first" "$PRIV" "git remote set-url origin https://github.com/acme/pub.git && git push origin main" "changes where the push goes"
denies "ask: git config first" "$PRIV" "git config remote.origin.pushurl https://github.com/acme/pub.git && git push origin main" "changes where the push goes"
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
denies "pushd then popd leaves the directory unknown, so the push asks" "$SR" "pushd $PRIV >/dev/null; popd >/dev/null; git -c push.default=current push"
denies "pushd alone leaves the directory unknown" "$SR" "pushd $PRIV >/dev/null && git -c push.default=current push"

mkdir -p "$HOME/.megavibe/personal"; mkfifo "$HOME/.megavibe/personal/public-push.trusted"
S0=$SECONDS; run "$PUB" "git push origin main"; if [ $((SECONDS-S0)) -lt 8 ]; then ok; else bad "a FIFO trusted-file must not hang the hook"; fi
rm -f "$HOME/.megavibe/personal/public-push.trusted"

mkdir -p "$T/slowgit"; REALGIT=$(command -v git)
printf '#!/bin/bash\ncase "$*" in *get-url*) exec sleep 30;; esac\nexec %s "$@"\n' "$REALGIT" > "$T/slowgit/git"; chmod +x "$T/slowgit/git"
OLDPATH=$PATH; PATH="$T/slowgit:$PATH"; asks "a timed-out remote resolution asks instead of passing" "$PUB" "git push origin main" "timed out"; PATH=$OLDPATH

# 10b. Changes after two independent opinions: the known-public list, deny-and-retry, the trusted file never
#      overriding a PUBLIC answer, stale tracking refs, the timeout on a hung gh, heredoc detection outside quotes.
NP="$T/np"; mkrepo "$NP" https://github.com/other/surprise.git; printf PUBLIC > "$T/vis/other_surprise"; commit "$NP" a.txt "plain change"   # EXAMPLE: fixture
printf 'github.com/acme/*\ngithub.com/cur/*\n' > "$KNOWN"
asks "a PUBLIC repository that is not on the known-public list asks even when the scan is clean" "$NP" "git push origin main" "not on your list" "github.com/other/surprise"
asks "pr create to a PUBLIC repository that is not on the list asks" "$NP" "gh pr create -R other/surprise --title T --body B" "not on your list"
passes "a listed public repository with a clean push stays silent" "$PUB" "git push origin main"
printf 'GitHub.com/Other/Surprise\n' >> "$KNOWN"
passes "the known-public list matches case-insensitively" "$NP" "git push origin main"
/bin/rm -f "$KNOWN"
asks "no known-public file: every public target asks" "$PUB" "git push origin main" "not on your list"
printf 'github.com/*\n' > "$KNOWN"
# the trusted file answers only where the lookup cannot; it never overrides a PUBLIC answer
printf 'github.com/acme/*\n' > "$HOME/.megavibe/personal/public-push.trusted"
commit "$PUB" t.txt "key ${AKIA_PFX}ABCDEFGHIJKLMNOP"
asks "a trusted glob does not switch the scan off for a PUBLIC repository" "$PUB" "git push origin main" "[AWS key]"
( cd "$PUB" && git reset -q --hard HEAD~1 )
/bin/rm -f "$HOME/.megavibe/personal/public-push.trusted"
# deny-and-retry: not a permission prompt, and no override hint
denies "a deny tells the agent to issue the command again" "$PUB" "git commit --allow-empty -m x && git push origin main" "separate call" "no human decision"
lacks "a deny does not advertise the override" "MEGAVIBE_ALLOW_PUBLIC_PUSH"
passes "the same chain to a private repository still passes" "$PRIV" "git commit --allow-empty -m x && git push origin main"
# a branch switch before a push that names no remote, in a repository with several remotes
MR="$T/multi"; mkrepo "$MR" git@github.com:acme/priv.git   # EXAMPLE: fixture
( cd "$MR" && git remote add pub https://github.com/acme/pub.git && git branch -q rel && git config branch.rel.pushRemote pub )
denies "switch then a bare push with several remotes: run separately" "$MR" "git switch rel && git push" "several remotes"
passes "switch then a push that names the (private) remote" "$MR" "git switch rel && git push origin rel"
passes "switch then a bare push with one remote, private" "$PRIV" "git switch -c topic9 && git push"
# stale tracking refs: the remote's URL now names a public repository, the refs still describe the old one
ST="$T/stale"; mkrepo "$ST" git@github.com:acme/priv.git   # EXAMPLE: fixture
commit "$ST" a.txt "internal path $USERS_DIR/realperson/x" "old private work"; ( cd "$ST" && git update-ref refs/remotes/origin/main HEAD )
commit "$ST" a.txt "plain change"
( cd "$ST" && git remote set-url origin https://github.com/acme/pub.git && git rev-parse HEAD~1 > "$T/vis/absent" )
asks "tracking refs the destination does not hold are not trusted: the private commit is scanned" "$ST" "git push origin main" "tracking refs" "[home path]"
: > "$T/vis/absent"
passes "tracking refs the destination holds are used as before" "$ST" "git push origin main"
( cd "$ST" && git rev-parse HEAD~1 > "$T/vis/absent" );
GH_FAIL=1 passes "a gh that cannot answer the boundary lookup is not read as stale refs (visibility from the cache)" "$ST" "git push origin main"
printf '#!/bin/bash\n[ "$1" = api ] && sleep 30\nexec %s "$@"\n' "$T/bin/gh" > "$T/slowapi"; mkdir -p "$T/slowgh"; mv "$T/slowapi" "$T/slowgh/gh"; chmod +x "$T/slowgh/gh"
( cd "$ST" && git merge -q --no-ff -m m1 HEAD~1 2>/dev/null; true )
OLDPATH=$PATH; PATH="$T/slowgh:$PATH"; S0=$SECONDS; run "$ST" "git push origin main"; PATH=$OLDPATH
if [ $((SECONDS-S0)) -lt 20 ]; then ok; else bad "the boundary lookups share one time budget ($((SECONDS-S0)) s)"; fi
: > "$T/vis/absent"
# a "<<" inside quotes is not a heredoc: the push on the next line is still seen
denies "a quoted << does not swallow the following push" "$PUB" "python3 -c \"print(1 << n)\"
git commit --allow-empty -m x && git push origin main" "separate call"
# a gh that hangs with a child holding the pipe is cut off at the limit
mkdir -p "$T/hanggh"; printf '#!/bin/bash\n( sleep 60 ) &\nsleep 60\n' > "$T/hanggh/gh"; chmod +x "$T/hanggh/gh"
/bin/rm -rf "$HOME/.megavibe/cache"; OLDPATH=$PATH; PATH="$T/hanggh:$PATH"; S0=$SECONDS
asks "a hung gh (with a child holding the pipe) ends at the timeout and asks" "$PUB" "git push origin main" "could not determine"
if [ $((SECONDS-S0)) -lt 20 ]; then ok; else bad "the gh timeout was not enforced ($((SECONDS-S0)) s)"; fi; PATH=$OLDPATH

# 10c. Findings of the ship round.
# tracking refs that hide the WHOLE push (the tracking ref is the tip itself) leave no boundary: the tip is checked
SE="$T/stale-empty"; mkrepo "$SE" git@github.com:acme/priv.git   # EXAMPLE: fixture
commit "$SE" a.txt "internal path $USERS_DIR/realperson/y" "private work"; ( cd "$SE" && git update-ref refs/remotes/origin/main HEAD )
( cd "$SE" && git remote set-url origin https://github.com/acme/pub.git && git rev-parse HEAD > "$T/vis/absent" )
asks "tracking refs that hide the whole push are checked against the destination" "$SE" "git push -u origin main" "tracking refs" "[home path]"
: > "$T/vis/absent"
passes "an up-to-date push to a listed public repository stays silent" "$SE" "git push -u origin main"
# a << that is not a heredoc (in a comment, in a quoted multi-line text) hides nothing
commit "$PUB" t2.txt "key ${AKIA_PFX}ABCDEFGHIJKLMNOP"
asks "a << in a comment does not swallow the push on the next line" "$PUB" "# Write the PR body with <<EOF
git push -u origin main" "[AWS key]"
denies "a << in a multi-line commit message does not swallow the chained push" "$PUB" "git commit --allow-empty -m \"docs: explain <<EOF usage
more\" && git push origin main" "separate call"
( cd "$PUB" && git reset -q --hard HEAD~1 )
passes "a clean private PR whose quoted body mentions <<EOF passes" "$PRIV" "gh pr create -R acme/priv --title Fix --body '## Summary
Document shell heredocs with <<EOF.
The docs are ready.
'"
# a body file created earlier in the same call: deny-and-retry, not a prompt about an unreadable file
# the retry instruction for a variable directory does not point at -R as a way out
lacks "the instruction does not offer -R as sufficient" "or pass -R"
# a dry run publishes nothing, whatever ran before it
passes "a dry run after a remote change is not checked" "$PUB" "git remote set-url origin https://github.com/acme/pub.git && git push --dry-run origin main"
denies "a real push after a remote change is still denied" "$PUB" "git remote set-url origin https://github.com/acme/pub.git && git push origin main" "separate call"

# a literal $WORD in single quotes (or escaped) is text: no dead-end deny
passes "a single-quoted literal \$WORD in a PR title is text" "$PUB" "gh pr create -R acme/pub --title 'Fix \$CLAUDE_PROJECT_DIR handling' --body Clean"
passes "an escaped \$WORD in a PR title is text" "$PUB" "gh pr create -R acme/pub --title \"Fix \\\$CLAUDE_PROJECT_DIR handling\" --body Clean"


# findings of the second ship round
commit "$PUB" t3.txt "key ${AKIA_PFX}ABCDEFGHIJKLMNOP"
asks "a << in a comment is not a heredoc even when a later heredoc ends with the same word" "$PUB" "# Write the PR body with <<EOF
git push -u origin main
cat >$T/local.md <<'EOF'
Clean
EOF" "[AWS key]"
denies "a variable in an inline GIT_DIR cannot be resolved" "$PRIV" "REPO=$PUB; GIT_DIR=\"\$REPO/.git\" git push origin main" "literal path"
( cd "$PUB" && git reset -q --hard HEAD~1 )
passes "a multi-line single-quoted PR body with a literal \$WORD is text" "$PUB" "gh pr create -R acme/pub --title Fix --body '## Summary
Document \$GH_HOST.
'"

# an apostrophe inside a comment does not pair with a later quote and hide the commands between them
denies "an apostrophe in a comment does not hide the commit before the push" "$PUB" "# don't amend, just add and push
git add k.txt && git commit -q -m 'add key'
git push -u origin main" "separate call"
passes "an apostrophe in a comment before a clean private push" "$PRIV" "# don't forget the upstream
git push -u origin main"
# text that only mentions a push publishes nothing
passes "a commit message with a backticked git push in single quotes" "$PUB" "git commit --allow-empty -m 'Fix \`git push\` guard for chains'"
passes "a PR comment that mentions git push" "$PUB" "gh pr comment 12 --body 'now denies \`git push\` after a commit'"
passes "a commit message with escaped backticks in double quotes" "$PUB" "git commit --allow-empty -m \"Fix \\\`git push\\\` guard\""
passes "the word eval in a message is not an eval" "$PUB" "git commit --allow-empty -m 'handle eval of git push in hook'"
passes "grep for eval and git push" "$PUB" "grep -rn 'eval' hooks/ | grep 'git push'"
asks "a real eval of a push still asks" "$PUB" "eval \"git push origin main\"" "substitution or eval"
asks "a push inside backticks still asks" "$PUB" "echo \`git push origin main\`" "substitution or eval"
passes "a clean push inside \$( ) is parsed as a push and scanned" "$PUB" "echo \$(git push origin main)"

# findings of the third ship round
printf 'clean\n' > "$T/body10.md"
passes "a body file named once is read and scanned" "$PUB" "gh pr create -R acme/pub --title Fix --body-file $T/body10.md"
passes "an escaped \$( in a commit message is text" "$PUB" "git commit --allow-empty -m \"Document \\\$(git push)\""
denies "the variable-directory instruction says to drop the cd" "$PUB" "cd \"\$PWD\" && git push" "without that cd"

passes "a title that mentions the body file's name is not a second use of the file" "$PUB" "gh pr create -R acme/pub --title 'Explain body10.md' --body-file $T/body10.md"

# findings of the fourth ship round
# a worktree created and pushed from in the same call: its directory does not exist when the hook runs
commit "$PUB" w.txt "key ${AKIA_PFX}ABCDEFGHIJKLMNOP"
denies "worktree add then a push from the new directory: run separately" "$PUB" "git worktree add -b wtfeat ../fresh-wt && git -C ../fresh-wt push -u origin wtfeat" "does not exist yet"
denies "worktree add then cd and push: run separately" "$PUB" "git worktree add -b wtfeat ../fresh-wt && cd ../fresh-wt && git push -u origin wtfeat" "separate call"
denies "worktree add is a state change before a push to a public repository" "$PUB" "git worktree add -b wtfeat2 ../fresh-wt2 && git push origin main" "separate call"
( cd "$PUB" && git reset -q --hard HEAD~1 )
passes "worktree list before a clean push is read-only" "$PUB" "git worktree list && git push origin main"
# a body file whose name is also part of a flag or of the command words
printf '## Summary\nClean\n' > "$PUB/body"; printf '## Summary\nClean\n' > "$PUB/pr"
passes "a body file named body is not counted inside --body-file" "$PUB" "gh pr create -R acme/pub --title Fix --body-file body"
passes "a body file named ./body" "$PUB" "gh pr create -R acme/pub --title Fix --body-file ./body"
passes "a body file named pr is not counted inside gh pr create" "$PUB" "gh pr create -R acme/pub --title Fix --body-file pr"
/bin/rm -f "$PUB/body" "$PUB/pr"
denies "the deny says that nothing in the call ran" "$PUB" "git commit --allow-empty -m x && git push origin main" "NOTHING in this call ran"

# 10z. Pull requests: the visibility of the destination, and on a public one the text (section 12 has the text cases).
printf 'github.com/acme/pub\n' > "$KNOWN"
passes "pr create to a known-public repository passes" "$PUB" "gh pr create -R acme/pub --title Fix --body Done"
asks "pr create: a token-shaped title to a known-public repository is a hit" "$PUB" "gh pr create -R acme/pub --title ghp_abcdefghijklmnopqrstuvwxyz0123456789 --body y" "[GitHub token]" "title"   # EXAMPLE: fixture
denies "pr create: a body file that does not exist cannot be checked" "$PUB" "gh pr create -R acme/pub --title Fix --body-file /nonexistent/x.md" "does not exist" "--body-file FILE"
denies "pr create: a variable in the body cannot be checked" "$PUB" 'BODY=x; gh pr create -R acme/pub --title Fix --body "$BODY"' "variable" "--body-file FILE"
passes "pr create after a commit in the same call to a known-public repository passes" "$PUB" "git commit --allow-empty -qm x && gh pr create -R acme/pub --title Fix --body Done"
passes "pr create to a private repository passes" "$PUB" "gh pr create -R acme/priv --title Fix --body Done"
passes "pr create to an internal repository passes" "$PUB" "gh pr create -R acme/int --title Fix --body Done"
passes "pr create without -R in a checkout whose remote is private passes" "$PRIV" "gh pr create --title Fix --body Done"
passes "pr create without -R in a checkout whose remote is known-public passes" "$PUB" "gh pr create --title Fix --body Done"
asks "pr edit: an unlisted public checkout" "$NP" "gh pr edit 3 --title T" "not on your list"
passes "pr edit by URL of a private repository" "$NP" "gh pr edit https://github.com/acme/priv/pull/3 --body Done"
asks "pr edit: -R to an unlisted public repository" "$PRIV" "gh pr edit 3 -R other/surprise --title T" "not on your list"
passes "pr view is untouched" "$PUB" "gh pr view 3 -R other/surprise"
asks "pr comment to an unlisted public repository" "$PUB" "gh pr comment 3 -R other/surprise --body hi" "not on your list"
asks "pr create to a public repository that is not on the list asks" "$NP" "gh pr create -R other/surprise --title T --body B" "not on your list" "github.com/other/surprise"
asks "pr create without -R: the checkout's remote is public and not on the list" "$NP" "gh pr create --title T --body B" "not on your list" "github.com/other/surprise"
asks "pr create: gh cannot tell" "$PUB" "gh pr create -R acme/mystery --title t --body b" "could not determine"
denies "pr create after a remote change in the same call is a retry" "$PUB" "git remote set-url origin https://github.com/acme/priv.git && gh pr create --title Fix --body Done" "separate call"
passes "pr create to a private repository named with -R does not depend on an unresolvable directory" "$PUB" 'cd "$WHERE" && gh pr create -R acme/priv --title Fix --body Done'
asks "pr create to an unlisted public repository named with -R from an unresolvable directory asks" "$PRIV" 'cd "$WHERE" && gh pr create -R other/surprise --title Fix --body Done' "not on your list"
asks "a PR body that looks like -R does not replace the destination" "$PRIV" "gh pr create -R other/surprise --title Fix --body '-Racme/priv'" "not on your list" "other/surprise"
passes "a PR title that looks like -R does not cause a false ask" "$PUB" 'gh pr create -R acme/pub --title "-R flag support" --body "Document this flag"'
asks "an option-shaped title before -R is a title, not the repository" "$PRIV" "gh pr create --title '-Racme/priv' -R other/surprise" "not on your list" "other/surprise"
denies "pr create from an unresolvable directory is a retry" "$PUB" 'cd "$WHERE" && gh pr create --title Fix --body Done' "not statically known"
passes "the same pr create with an explicit literal directory and -R passes" "$PUB" "cd $PUB && gh pr create -R acme/pub --title Fix --body Done"
asks "pr create: inline GH_REPO selects a public repository that is not on the list" "$PRIV" "GH_REPO=other/surprise gh pr create --title T --body B" "not on your list"
asks "pr create: exported GH_REPO selects a public repository that is not on the list" "$PRIV" "export GH_REPO=other/surprise; gh pr create --title T --body B" "not on your list"
passes "pr create: GH_REPO selecting a private repository passes from a public checkout" "$PUB" "GH_REPO=acme/priv gh pr create --title T --body B"
asks "pr create: host-qualified -R names a public repository that is not on the list" "$PRIV" "gh pr create -R github.com/other/surprise --title T --body B" "not on your list"
asks "pr create: -R= form" "$PRIV" "gh pr create -R=other/surprise --title T --body B" "not on your list"
asks "pr create inside bash -c" "$PRIV" "bash -c 'gh pr create -R other/surprise --title T --body B'" "not on your list"
printf 'github.com/*\n' > "$KNOWN"

# 10y. An unresolvable --git-dir / --work-tree / -C is never a silent pass.
GDX="$T/gitdirx"; mkrepo "$GDX" https://github.com/acme/pub.git; commit "$GDX" a.txt "plain change"
denies "--git-dir with a variable" "$T" 'git --git-dir "$GDX/.git" push origin main' "not statically known"
denies "--git-dir=\$VAR" "$T" 'git --git-dir=$GDX/.git push origin main' "not statically known"
denies "--work-tree with a variable" "$T" 'git --work-tree "$GDX" push origin main' "not statically known"
denies "--work-tree=\$VAR" "$T" 'git --work-tree=$GDX push origin main' "not statically known"
denies "--git-dir with a command substitution" "$T" 'git --git-dir "$(pwd)/.git" push origin main' "not statically known"
denies "-C with a variable" "$T" 'git -C "$GDX" push origin main' "not statically known"
passes "--git-dir given literally to a known-public repository passes" "$T" "git --git-dir=$GDX/.git --work-tree=$GDX push origin main"
passes "--git-dir given literally to a private repository passes" "$T" "git --git-dir=$PRIV/.git --work-tree=$PRIV push origin main"
passes "-C given literally to a private repository passes" "$T" "git -C $PRIV push origin main"
passes "a variable in a non-push git command is untouched" "$T" 'git --git-dir "$GDX/.git" status'

# 12. The text a gh command publishes is scanned on a public repository: built-in rules deny, other hits ask with the
#     text shown, a text the guard cannot see is denied with the instruction to pass a file.
SLH=claude.ai; SLINK="https://$SLH/code/session_01AbCdEfGhIjKl"; TRK=Claude; TRL="$TRK-Session: $SLINK"   # fixture fragments: the literal forms never appear in this file
TX=$T/tx; mkrepo "$TX" https://github.com/acme/pub.git
printf '## Summary\nClean text.\n' > "$TX/clean.md"
printf '## Summary\nSee %s\n' "$SLINK" > "$TX/link.md"
printf '## Summary\nDone.\n\nCo-authored-by: megavibe <bot@vendor.test>\n%s\n' "$TRL" > "$TX/trailer.md"   # EXAMPLE: fixture
printf '## Summary\nFor ACME Corp only.\n' > "$TX/deny.md"
printf 'ACME Corp\n' > "$HOME/.megavibe/personal/public-push.deny"
printf '{"body":"Done.\\n\\n%s"}' "$TRL" > "$TX/trailer.json"
printf '{"query":"mutation { addComment(input: {subjectId: \\"x\\", body: \\"hi\\"}) { clientMutationId } }"}' > "$TX/mut.json"
printf '{"query":"query { viewer { login } }","variables":{"note":"mutation"}}' > "$TX/query.json"
for v in "pr create --title T" "pr edit 3" "pr comment 3" "pr review 3 --comment" "pr merge 3 --squash" "issue create --title T" "issue edit 3" "issue comment 3"; do
  passes "$v: clean --body" "$TX" "gh $v --body 'Clean text.'"
  passes "$v: clean --body-file" "$TX" "gh $v --body-file clean.md"
  passes "$v: clean -F" "$TX" "gh $v -F clean.md"
  denies "$v: session link in --body" "$TX" "gh $v --body 'see $SLINK'" "session link" "Co-authored-by alone is fine"
  denies "$v: session link in --body-file" "$TX" "gh $v --body-file link.md" "session link"
  denies "$v: session trailer in a body file (-F)" "$TX" "gh $v -F trailer.md" "Claude-Session trailer"
  asks "$v: a denylist hit asks and shows the text" "$TX" "gh $v --body-file deny.md" "[denylist #1]" "characters" "| For ACME Corp only."
  denies "$v: a body from a variable" "$TX" "gh $v --body \"\$B\"" "variable" "--body-file FILE"
  denies "$v: a body from a pipe" "$TX" "printf x | gh $v --body-file -" "standard input"
  passes "$v: a session link to a private repository" "$TX" "gh $v -R acme/priv --body 'see $SLINK'"
done
for v in "pr close 3" "pr reopen 3" "issue close 3" "issue reopen 3"; do
  passes "$v: clean --comment" "$TX" "gh $v --comment 'Done.'"
  denies "$v: session link in --comment" "$TX" "gh $v -c 'see $SLINK'" "session link"
  passes "$v: no comment publishes no text" "$TX" "gh $v"
done
denies "pr merge: session trailer in --subject" "$TX" "gh pr merge 3 --squash --subject '$TRL'" "Claude-Session trailer"
passes "pr review --approve without a body publishes no text" "$TX" "gh pr review 3 --approve"
passes "release create: clean notes" "$TX" "gh release create v1 --title v1 --notes 'Clean.'"
denies "release create: session link in a notes file" "$TX" "gh release create v1 -F link.md" "session link"
denies "release edit: notes from a variable" "$TX" "gh release edit v1 --notes \"\$N\"" "--notes-file FILE"
asks "release create: a denylist hit in -n" "$TX" "gh release create v1 -n 'for acme corp'" "[denylist #1]"
passes "release create to a private repository" "$TX" "gh release create v1 -R acme/priv -n 'see $SLINK'"
# gh api
passes "api: a read is not checked" "$TX" "gh api repos/acme/pub/pulls/3"
passes "api: -X GET with fields is a read" "$TX" "gh api -X GET repos/acme/pub/issues -f state=open"
passes "api: a clean comment" "$TX" "gh api repos/acme/pub/issues/3/comments -f body='Clean.'"
denies "api: session link in -f body" "$TX" "gh api repos/acme/pub/issues/3/comments -f body='see $SLINK'" "session link"
denies "api: session link in -F body=@file" "$TX" "gh api repos/acme/pub/issues/3/comments -F body=@link.md" "session link"
denies "api: trailer inside a JSON --input" "$TX" "gh api -X PATCH repos/acme/pub/pulls/3 --input trailer.json" "Claude-Session trailer"
denies "api: --input from a pipe" "$TX" "cat trailer.json | gh api repos/acme/pub/issues/3/comments --input -" "standard input" "-F body=@FILE"
denies "api: a field from a substitution" "$TX" "gh api repos/acme/pub/issues/3/comments -f body=\"\$(cat link.md)\"" "substitution"
passes "api: a session link to a private repository" "$TX" "gh api -X POST repos/acme/priv/issues/3/comments -f body='$SLINK'"
denies "api: {owner}/{repo} resolves from the checkout" "$TX" "gh api repos/{owner}/{repo}/issues/3/comments -f body='$SLINK'" "session link"
passes "api: {owner}/{repo} in a private checkout" "$PRIV" "gh api repos/{owner}/{repo}/issues/3/comments -f body='$SLINK'"
denies "api: a full URL endpoint" "$TX" "gh api https://api.github.com/repos/acme/pub/issues/3/comments -f body='$SLINK'" "session link"
B64=$(printf 'see %s' "$SLINK" | base64 | tr -d '\n')
denies "api: the contents API's base64 is decoded" "$TX" "gh api -X PUT repos/acme/pub/contents/x.md -f message=add -f content=$B64" "session link"
asks "api: a GraphQL mutation cannot be placed and asks" "$TX" 'gh api graphql -f query='"'"'mutation { addComment(input: {subjectId: "x", body: "hi"}) { clientMutationId } }'"'" "GraphQL mutation" "| mutation"
passes "api: a GraphQL query is a read" "$TX" "gh api graphql -f query='query { viewer { login } }'"
passes "api: an endpoint that is not a repository is not checked" "$TX" "gh api -X POST user/keys -f title=k"
# heredocs and standard input
passes "a quoted heredoc as --body-file -, clean" "$TX" $'gh pr create --title T --body-file - <<\'EOF\'\nClean $NOT_EXPANDED text\nEOF'
denies "a quoted heredoc with a session link" "$TX" $'gh pr comment 3 --body-file - <<\'EOF\'\nsee '"$SLINK"$'\nEOF' "session link"
denies "an unquoted heredoc that expands" "$TX" $'gh pr comment 3 --body-file - <<EOF\nsee $X\nEOF' "unquoted heredoc"
passes "an unquoted heredoc without expansions" "$TX" $'gh pr comment 3 -F - <<EOF\nplain text\nEOF'
passes "a \$(cat <<'EOF') body, clean" "$TX" $'gh pr create --title T --body "$(cat <<\'EOF\'\n## Summary\nClean.\nEOF\n)"'
denies "a \$(cat <<'EOF') body with the session trailer" "$TX" $'gh pr create --title T --body "$(cat <<\'EOF\'\n## Summary\nDone.\n\n'"$TRL"$'\nEOF\n)"' "Claude-Session trailer"
denies "a heredoc of another command is not gh's standard input" "$TX" $'cat <<\'EOF\' > /dev/null\nx\nEOF\ngh pr comment 3 --body-file -' "standard input"
denies "a here-string is not seen" "$TX" "gh pr comment 3 --body-file - <<< 'x'" "standard input"
denies "a < redirection is not seen" "$TX" "gh pr comment 3 --body-file - < clean.md" "standard input"
denies "a multi-line quoted body keeps its lines: the trailer is at a line start" "$TX" "gh pr comment 3 --body 'Done.

$TRL'" "Claude-Session trailer"
passes "a trailer named mid-line is not a trailer" "$TX" "gh pr comment 3 --body 'Explain the $TRK-Session: trailer rule'"
passes "a placeholder session link is not a session link" "$TX" "gh pr comment 3 --body 'links look like https://$SLH/code/session_... and session_<id>'"
denies "a quote that starts mid-word runs past parentheses" "$TX" "gh api repos/acme/pub/issues/3/comments -f body='x (y) $SLINK'" "session link"
denies "a mid-word quoted body keeps its lines" "$TX" "gh pr comment 3 --body='Done.

$TRL'" "Claude-Session trailer"
# a body file another command in the same call may write
denies "a body file written earlier in the same call" "$TX" "printf x > clean.md && gh pr create --title T --body-file clean.md" "same call"
passes "a body file named once in a two-command call" /tmp "cd $TX && gh pr create --title T --body-file clean.md"
denies "a relative body file after a cd the guard cannot follow" "$TX" 'cd "$D" && gh pr comment 3 -R acme/pub --body-file clean.md' "relative file"
denies "a body file named by a glob" "$TX" "gh pr comment 3 --body-file *.md" "glob"
# parsing hazards
denies "bash -c" "$TX" "bash -c 'gh pr comment 3 --body \"see $SLINK\"'" "session link"
denies "a line continuation" "$TX" $'gh pr comment 3 \\\n  --body-file link.md' "session link"
denies "a cd chain" /tmp "cd $TX && gh pr comment 3 --body-file link.md" "session link"
denies "inside an unquoted \$( )" "$TX" "x=\$(gh pr comment 3 --body-file link.md)" "session link"
denies "inside a double-quoted \$( ): parsed as the command bash runs" "$TX" "echo \"\$(gh pr comment 3 --body-file link.md)\"" "session link"
passes "a double-quoted \$(gh pr create ...) to a private repository does not ask" "$PRIV" "URL=\"\$(gh pr create --title T --body 'see $SLINK')\""
asks "a backtick inside double quotes after another command still asks" "$TX" "gh pr comment 1 -R acme/priv -b ok && echo \"\`gh issue comment 2 -b x\`\"" "substitution"
passes "a read inside a double-quoted \$( ) does not ask" "$TX" "T=\"\$(gh api repos/acme/pub/pulls/3 --jq .title)\""
denies "--repo" "$PRIV" "gh pr comment 3 --repo acme/pub --body-file $TX/link.md" "session link"
denies "-R=owner/repo" "$PRIV" "gh pr comment 3 -R=acme/pub --body-file $TX/link.md" "session link"
denies "a URL argument names the repository" "$PRIV" "gh pr comment https://github.com/acme/pub/pull/3 --body-file $TX/link.md" "session link"
passes "a URL argument of a private repository" "$TX" "gh issue comment https://github.com/acme/priv/issues/3 --body-file link.md"
denies "the last -R counts, as in gh" "$PRIV" "gh pr comment 3 -R acme/priv -R acme/pub --body-file $TX/link.md" "session link"
denies "-R in a variable" "$TX" 'gh pr comment 3 -R "$REPO" --body x' "variable"
asks "an enterprise host through GH_HOST" "$PRIV" "GH_HOST=ghe.corp.test gh pr comment 3 -R acme/pub --body Clean" "ghe.corp.test/acme/pub" "not on your list"
asks "an enterprise host in -R" "$PRIV" "gh pr comment 3 -R ghe.corp.test/acme/pub --body Clean" "ghe.corp.test/acme/pub"
asks "unknown visibility asks and shows the text" "$TX" "gh pr comment 3 -R acme/mystery --body 'Hello there'" "could not determine" "| Hello there"
asks "unknown visibility names a session link without denying" "$TX" "gh pr comment 3 -R acme/mystery --body '$SLINK'" "could not determine" "[session link]"
run "$TX" "gh pr comment 3 --body 'tok ghp_abcdefghijklmnopqrstuvwxyz0123456789'"; lacks "the text shown in the question is redacted" "ghp_abcdefghijklmn"   # EXAMPLE: fixture
passes "a dry run publishes nothing" "$TX" "gh pr create --dry-run --title T --body '$SLINK'"
denies "--fill on a public repository" "$TX" "gh pr create --fill" "--fill"
denies "--editor on a public repository" "$TX" "gh issue comment 3 --editor" "editor"
passes "--web with a clean title" "$TX" "gh issue create --web --title T"
passes "--fill on a private repository" "$PRIV" "gh pr create --fill"
for c in "gh pr view 3" "gh issue list" "gh release list" "gh api user" "gh pr checks 3" "gh pr diff 3"; do passes "untouched: $c" "$TX" "$c"; done
printf 'github.com/other/*\n' > "$KNOWN"
asks "a clean text to an unlisted public repository asks and shows the text" "$TX" "gh issue comment 3 --body 'Thanks, merged.'" "not on your list" "| Thanks, merged."
printf 'github.com/*\n' > "$KNOWN"
# commit and tag messages: the built-in rules on the push side
TP=$T/tp; mkrepo "$TP" https://github.com/acme/pub.git
commit "$TP" a.txt "x" "$(printf 'Fix it\n\nCo-authored-by: megavibe <bot@vendor.test>\n%s' "$TRL")"   # EXAMPLE: fixture
denies "push: the session trailer to a public repository" "$TP" "git push origin main" "Claude-Session trailer" "git commit --amend"
TV=$T/tv; mkrepo "$TV" https://github.com/acme/priv.git
commit "$TV" a.txt "x" "$(printf 'Fix it\n\nCo-authored-by: megavibe <bot@vendor.test>\n%s' "$TRL")"   # EXAMPLE: fixture
passes "push: the same commit to a private repository" "$TV" "git push origin main"
( cd "$TP" && git reset -q --hard HEAD~1 )
commit "$TP" a.txt "x" "Fix it, see $SLINK"
denies "push: a session link in a commit message" "$TP" "git push origin main" "session link"
( cd "$TP" && git reset -q --hard HEAD~1 )
commit "$TP" a.txt "x" "$(printf 'Fix it\n\nCo-authored-by: megavibe <bot@vendor.test>')"   # EXAMPLE: fixture
passes "push: Co-authored-by alone is fine" "$TP" "git push origin main"
commit "$TP" a.txt "y" "Explain the $TRK-Session: trailer and https://$SLH/code/session_... links"
passes "push: a message that names the rule is not a trailer" "$TP" "git push origin main"
( cd "$TP" && git tag -a rel1 -m "$(printf 'Release\n\n%s' "$TRL")" )
denies "push: the session trailer in an annotated tag message" "$TP" "git push origin rel1" "Claude-Session trailer"
( cd "$TP" && git tag -d rel1 >/dev/null )
rm -f "$HOME/.megavibe/personal/public-push.deny"
# missing jq or python3: the hook fails open (documented), as before
mkdir -p "$T/nojq" "$T/nopy"
for b in python3 git cat; do ln -sf "$(command -v $b)" "$T/nojq/$b"; done
for b in jq git cat; do ln -sf "$(command -v $b)" "$T/nopy/$b"; done
IN=$(jq -n --arg c "gh pr comment 3 --body '$SLINK'" --arg d "$TX" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')
OUT=$(printf '%s' "$IN" | PATH="$T/nojq" /bin/bash "$HOOK" 2>/dev/null); if [ -z "$OUT" ]; then ok; else bad "no jq: fails open"; fi
OUT=$(printf '%s' "$IN" | PATH="$T/nopy" /bin/bash "$HOOK" 2>/dev/null); if [ -z "$OUT" ]; then ok; else bad "no python3: fails open"; fi

# 12b. Leads of the amass sweep, each run with its exact input before the fix.
printf 'ACME Corp\n' > "$HOME/.megavibe/personal/public-push.deny"
denies "an indented EOF does not end the heredoc" "$TX" $'gh pr comment 3 --body-file - <<\'EOF\'\nok\n  EOF\nsee '"$SLINK"$'\nEOF' "session link"
passes "<<- strips leading tabs from the terminator" "$TX" $'gh pr comment 3 --body-file - <<-\'EOF\'\n\tok\n\tEOF'
denies "-f is --fill for pr create" "$TX" "gh pr create -f" "--fill"
denies "-e is --editor for issue comment" "$TX" "gh issue comment 3 -e" "editor"
denies "xargs supplies arguments the guard cannot see" "$TX" "printf x | xargs -I{} gh pr comment 7 -b {}" "xargs"
denies "a body file named in quotes elsewhere in the call" "$TX" "printf x > 'clean'.md; gh pr comment 7 -F clean.md" "same call"
passes "a GraphQL query with a variable field is a read" "$PRIV" "gh api graphql -f query='query{viewer{login}}' -F n=\"\$N\""
passes "the word mutation inside a GraphQL query string is a read" "$PRIV" "gh api graphql -f query='query { search(query: \"mutation\", type: ISSUE, first: 1) { issueCount } }'"
asks "a GraphQL mutation in --input asks" "$TX" "gh api graphql --input $TX/mut.json" "GraphQL mutation"
denies "exec gh is unwrapped" "$TX" "exec gh pr comment 7 -b 'see $SLINK'" "session link"
denies "an option built by a variable" "$TX" "B=--body; gh pr comment 7 \$B 'see $SLINK'" "built by a variable"
denies "an api endpoint built by a variable" "$TX" "gh api \"\$BASE/repos/acme/pub/issues/7/comments\" -f body=x" "variable"
denies "a double-quoted substitution after another gh command is parsed" "$TX" "gh pr comment 1 -R acme/priv -b ok && echo \"\$(gh issue comment 2 -b 'see $SLINK')\"" "session link"
denies "repos/{owner}/name takes the owner from the checkout" "$PRIV" "gh api -X POST 'repos/{owner}/pub/issues' -f body='$SLINK'" "session link"
denies "gh repo set-default earlier in the call" "$PRIV" "gh repo set-default acme/pub && gh pr comment 7 -b 'see $SLINK'" "set-default"
passes "a lone dollar sign is not an expansion" "$TX" "gh issue comment 7 --body \"cost is 5 \$ per seat\""
passes "a backslash an unquoted heredoc keeps is literal" "$TX" $'gh issue comment 3 -F - <<EOF\nRegex \\d+ fixed\nEOF'
denies "a typed placeholder is not a heredoc" "$TX" "printf x | gh issue comment 5 --body-file - __MVHD0__" "standard input"
denies "a URL argument wins over -R" "$TX" "gh pr comment https://github.com/acme/pub/pull/1 -R acme/priv -b 'see $SLINK'" "session link"
denies "JSON on standard input is decoded: a trailer at a line start" "$TX" $'gh api repos/acme/pub/issues/3/comments --input - <<\'EOF\'\n{"body":"Done.\\n\\n'"$TRK"$'-Session: x"}\nEOF' "Claude-Session trailer"
denies "a bundle of switches ending in a value-taking option (-wb TEXT)" "$TX" "gh pr comment 3 -wb 'see $SLINK'" "session link"
denies "a bundle with the value attached (-wbTEXT)" "$TX" "gh pr comment 3 -wbsee_$SLINK" "session link"
passes "a heredoc delimiter with a hyphen" "$TX" $'gh pr comment 3 -F - <<\'END-BODY\'\nclean\nEND-BODY'
passes "a GraphQL query in --input is a read" "$TX" "gh api graphql --input $TX/query.json"
B64F=$(printf 'see %s' "$SLINK" | base64 | tr -d '\n'); printf '%s\n' "$B64F" > "$TX/b64.txt"
denies "-F content=@file is decoded as base64" "$TX" "gh api -X PUT repos/acme/pub/contents/x.md -f message=add -F content=@b64.txt" "session link"
# 12c. Findings of the ship round.
denies "a heredoc example inside a multi-line single-quoted body is text, and is scanned" "$TX" "gh pr create --title T --body 'Repro:
cat <<EOF
see $SLINK
EOF
end'" "session link"
asks "a heredoc example inside a multi-line double-quoted body is scanned" "$TX" "gh pr comment 3 --body \"Setup:
cat <<EOF > cfg
path=$USERS_DIR/jsmith/work
EOF
\"" "[home path]"
denies "a <<- example inside a quoted body" "$TX" "gh issue create --title a --body 'x
cat <<-EOF
	see $SLINK
	EOF
y'" "session link"
passes "the \$(cat <<'EOF') form is still a heredoc" "$TX" $'gh pr create --title T --body "$(cat <<\'EOF\'\n## Summary\nClean.\nEOF\n)"'
passes "a quoted ) inside a double-quoted \$( ) to a private repository" "$PRIV" "URL=\"\$(gh pr comment 3 --body \\\"a ) b\\\")\""
passes "a here-string's quoted text is not a heredoc opener" "$PRIV" $'gh pr comment 3 -F - <<< \'x <<EOF\'\ngit status\nEOF'
asks "an unquoted backtick substitution after another command asks" "$TX" "gh pr comment 1 -R acme/priv -b ok; echo \`gh issue comment 2 -b x\`" "substitution"
denies "a title from a variable gets a literal-title hint" "$TX" 'gh pr create --title "$T" --body x' "title, subject or comment literally"
PF=$T/pf; mkrepo "$PF" https://github.com/acme/pub.git
commit "$PF" a.txt "x" "$(printf 'Old work\n\n%s' "$TRL")"
( cd "$PF" && git update-ref refs/remotes/origin/main HEAD && git remote add fork https://github.com/acme/fork.git && git checkout -q -b feat )
printf PUBLIC > "$T/vis/acme_fork"
commit "$PF" b.txt "clean" "clean work"
asks "a trailer commit another remote already holds asks, it does not tell the agent to rewrite history" "$PF" "git push fork feat" "already hold" "git fetch" "origin"
run "$PF" "git push fork feat"; lacks "no rewrite instruction for published commits" "git commit --amend"
commit "$PF" c.txt "new" "$(printf 'New work\n\n%s' "$TRL")"
denies "a new trailer commit on top is still denied" "$PF" "git push fork feat" "no remote holds yet" "git rebase"
# 12d. Findings of the second ship round: an unquoted substitution is part of its word, and its commands are checked.
for c in "gh pr comment \$(gh pr view --json number -q .number) --body 'see $SLINK'" "gh pr comment \$(echo 3) --body 'see $SLINK'" \
         "gh pr edit \$(echo 3) --body 'see $SLINK'" "gh pr merge \$(echo 3) --subject 'see $SLINK'" "gh issue comment \$(echo 3) -b 'see $SLINK'" \
         "gh release create \$(echo v1) --notes 'see $SLINK'" "gh api repos/acme/pub/issues/\$(echo 3)/comments -f body='see $SLINK'" \
         "gh pr comment \$((1+2)) --body 'see $SLINK'" "gh pr comment 3 >(cat) --body 'see $SLINK'" "gh pr comment 3 <(echo) --body 'see $SLINK'" \
         "gh pr comment 3 --title=\$(echo y) --body 'see $SLINK'" "gh pr comment 3 -R acme/pub\$(echo) --body 'see $SLINK'"; do
  run "$TX" "$c"; d=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  case "$d" in deny|ask) ok ;; *) bad "an unquoted substitution before the text does not hide it: $c (decision: ${d:-none})" ;; esac
done
denies "a substituted pull request number asks for a literal one" "$TX" "gh pr comment \$(gh pr view --json number -q .number) --body 'Clean.'" "pass it literally"
passes "the same idiom on a private repository passes" "$PRIV" "gh pr comment \$(gh pr view --json number -q .number) --body 'see $SLINK'"
printf "github.com/acme/*\n" > "$KNOWN"; asks "a push inside a substitution inside bash -c is checked" "$T/np" "bash -c 'echo \$(git push origin main)'" "not on your list"
printf 'github.com/*\n' > "$KNOWN"
passes "a double-quoted \$( ) with quotes inside it keeps the outer word" "$PRIV" "gh pr comment 3 --body \"\$(gh pr view 3 --json title -q \".title\")\""
P5=pu; P5=${P5}sh
commit "$PUB" k9.txt "key ${AKIA_PFX}ABCDEFGHIJKLMNOP"
asks "a substitution in an unquoted heredoc body is checked" "$PUB" $'cat <<EOF\ndon\'t $(git '"$P5"$' origin main)\nEOF' "[AWS key]"
passes "a quoted heredoc body is text" "$PUB" $'cat <<\'EOF\'\n$(git '"$P5"$' origin main)\nEOF'
asks "a push nested deeper than the guard follows asks" "$PUB" "echo \$(echo \$(echo \$(echo \$(git $P5 origin main))))" "could not parse"
( cd "$PUB" && git reset -q --hard HEAD~1 )
# 12e. Findings of the third ship round.
asks "a # inside a quote within \"\$( )\" does not cut the rest of the line" "$TX" "echo \"\$(echo \"a #b\")\"; gh pr comment 3 --body 'k $USERS_DIR/jsmith/x'" "[home path]"
asks "an escaped backslash at a line end does not join the next line" "$TX" 'echo C:\\dir\\
gh pr comment 3 --body '"'k $USERS_DIR/jsmith/x'" "[home path]"
asks "a real line continuation still joins" "$TX" $'gh pr comment 3 \\\n --body \'k '"$USERS_DIR"$'/jsmith/x\'' "[home path]"
printf 'github.com/other/*\n' > "$KNOWN"
asks "gh pr create --web to an unlisted public repository still asks" "$TX" "gh pr create --web" "not on your list"
asks "gh pr create --draft without text still asks" "$TX" "gh pr create -R acme/pub --draft" "not on your list"
printf 'github.com/*\n' > "$KNOWN"
passes "gh pr create --web to a private repository" "$PRIV" "gh pr create --web"
passes "gh api with :owner/:repo in a private checkout" "$PRIV" "gh api repos/:owner/:repo/issues/3/comments -f body=hi"
denies "gh api with :owner/:repo in a public checkout" "$TX" "gh api repos/:owner/:repo/issues/3/comments -f body='see $SLINK'" "session link"
rm -f "$HOME/.megavibe/personal/public-push.deny"

# 11. Fail open: no jq / python3 in PATH is a silent pass is covered by the header; check a malformed event.
OUT=$(printf 'not json' | bash "$HOOK" 2>/dev/null); RC=$?; if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "malformed input fails open"; fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
