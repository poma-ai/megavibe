#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/megavibe-worktree-name.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
cat > "$T/bin/git" <<'EOF'
#!/bin/bash
printf 'git-called\n' >> "$GIT_CALLS"
exit 1
EOF
chmod +x "$T/bin/git"
export GIT_CALLS="$T/git.calls" MEGAVIBE_HOME="$T/home" PATH="$T/bin:$PATH"

set +e
out=$(bash "$REPO/megavibe" worktree --help 2>&1)
rc=$?
set -e
[ "$rc" = 2 ]
grep -q 'usage: megavibe worktree <name>' <<< "$out"
[ ! -s "$GIT_CALLS" ]

set +e
out=$(bash "$REPO/megavibe" worktree '' 2>&1)
rc=$?
set -e
[ "$rc" = 2 ]
grep -q 'usage: megavibe worktree <name>' <<< "$out"
[ ! -s "$GIT_CALLS" ]

# A valid name passes the check and reaches git (the stub fails, so the command fails after it).
set +e
out=$(bash "$REPO/megavibe" worktree valid-name 2>&1)
rc=$?
set -e
[ "$rc" != 2 ]
[ -s "$GIT_CALLS" ]
# `! cmd` never trips set -e, so test it explicitly.
if grep -q 'usage: megavibe worktree <name>' <<< "$out"; then echo 'valid name got the usage error' >&2; exit 1; fi
echo 'ok'
