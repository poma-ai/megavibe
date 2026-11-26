#!/bin/bash
# Container entrypoint: clone the repository, set it up for megavibe, start the dispatcher in tmux, queue the issues from the
# environment, then tick every MEGAVIBE_TICK_SECS so finished sessions free their slot and the next issue starts.
# Chat with the dispatcher:   docker compose exec -it megavibe tmux attach -t mvd-<repo-name>
set -euo pipefail

say() { printf 'megavibe-container: %s\n' "$*"; }
die() { printf 'megavibe-container: %s\n' "$*" >&2; exit 1; }

# ── what must be there ────────────────────────────────────────────────
[ -n "${GH_TOKEN:-}" ] || [ -n "${GH_ENTERPRISE_TOKEN:-}" ] || die "GH_TOKEN is not set: a token that can read and comment on issues, push branches and open pull requests of the repository"
[ -n "${MEGAVIBE_REPO:-}" ] || die "MEGAVIBE_REPO is not set (OWNER/NAME, or a clone URL)"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && ! claude auth status >/dev/null 2>&1; then
  die "Claude Code has no login: set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token), or log in once into the claude volume: docker compose run --rm megavibe claude auth login"
fi
[[ ${MEGAVIBE_MAX:-3} =~ ^[1-9][0-9]*$ ]] || die "MEGAVIBE_MAX must be a positive number"
[ -z "${MEGAVIBE_TOTAL:-}" ] || [[ $MEGAVIBE_TOTAL =~ ^[1-9][0-9]*$ ]] || die "MEGAVIBE_TOTAL must be a positive number (or empty: no limit)"
[[ ${MEGAVIBE_TICK_SECS:-120} =~ ^[1-9][0-9]*$ ]] || die "MEGAVIBE_TICK_SECS must be a positive number"

# ── megavibe itself (the volume over ~/.megavibe can start empty or old) ──
if [ ! -x "$HOME/.megavibe/scripts/megavibe-dispatch.sh" ] || ! cmp -s /opt/megavibe/scripts/megavibe-dispatch.sh "$HOME/.megavibe/scripts/megavibe-dispatch.sh"; then
  say "installing megavibe into $HOME/.megavibe"
  bash /opt/megavibe/setup.sh --auto-install </dev/null >/tmp/setup.log 2>&1 || { tail -40 /tmp/setup.log >&2; die "megavibe setup failed"; }
fi

# ── git and gh credentials ────────────────────────────────────────────
git config --global user.name "${GIT_USER_NAME:-megavibe}"
git config --global user.email "${GIT_USER_EMAIL:-megavibe-dispatch@localhost.invalid}"
git config --global init.defaultBranch main
gh auth setup-git >/dev/null 2>&1 || die "gh could not be set up as the git credential helper (is GH_TOKEN valid?)"
gh api user --jq .login >/dev/null 2>&1 || die "GH_TOKEN does not work (gh api user failed)"

# Claude Code's first-run dialogs have nobody to answer them: mark onboarding done and accept the permission-bypass notice
# (the issue sessions run with --dangerously-skip-permissions, which is why this container is the boundary). Best effort.
mkdir -p "$HOME/.claude"
[ -f "$HOME/.claude.json" ] || printf '{"hasCompletedOnboarding":true}\n' > "$HOME/.claude.json"
[ -f "$HOME/.claude/settings.json" ] || printf '{"skipDangerousModePermissionPrompt":true}\n' > "$HOME/.claude/settings.json"

# ── the repository ────────────────────────────────────────────────────
case "$MEGAVIBE_REPO" in
  *://*|git@*) url="$MEGAVIBE_REPO" ;;
  *) url="https://${GH_HOST:-github.com}/${MEGAVIBE_REPO%.git}.git" ;;
esac
name=$(basename "${MEGAVIBE_REPO%.git}")
[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "cannot derive a folder name from MEGAVIBE_REPO"
repo="/work/$name"
if [ -d "$repo/.git" ]; then git -C "$repo" fetch -q origin || die "git fetch failed in $repo"
else git clone -q "$url" "$repo" || die "git clone $url failed (token scope? repository name?)"; fi
cd "$repo"
[ -d .agent ] || bash /opt/megavibe/init.sh "$repo" >/dev/null 2>&1 || die "init.sh failed in $repo"

# ── the dispatcher ────────────────────────────────────────────────────
queue=$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n-' '-')
export MEGAVIBE_DISPATCH_QUEUE="$queue"
args=(start --no-attach --max "${MEGAVIBE_MAX:-3}")
[ -z "${MEGAVIBE_TOTAL:-}" ] || args+=(--total "$MEGAVIBE_TOTAL")
[ -z "${MEGAVIBE_BASE:-}" ] || args+=(--base "$MEGAVIBE_BASE")
[ -z "${MEGAVIBE_MODEL:-}" ] || args+=(--model "$MEGAVIBE_MODEL")
[ -z "${MEGAVIBE_TICKET_SKILL:-}" ] || args+=(--skill "$MEGAVIBE_TICKET_SKILL")
[ "${MEGAVIBE_PRECHECK:-on}" != off ] || args+=(--no-precheck)
[ "${MEGAVIBE_ALLOW_PUBLIC:-0}" != 1 ] || args+=(--allow-public)
megavibe dispatch "${args[@]}"

# ── the issues from the environment ───────────────────────────────────
nums=()
for tok in ${MEGAVIBE_ISSUES:-}; do
  case "$tok" in
    [0-9]*..[0-9]*) a=${tok%%..*}; b=${tok##*..}; [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $a -le $b && $((b - a)) -lt 200 ]] || die "bad range '$tok'"; nums+=($(seq "$a" "$b")) ;;
    [0-9]*) [[ $tok =~ ^[0-9]+$ ]] || die "bad issue '$tok'"; nums+=("$tok") ;;
    *) die "MEGAVIBE_ISSUES: '$tok' is neither a number nor a range like 12..15" ;;
  esac
done
[ "${#nums[@]}" = 0 ] || megavibe dispatch add "${nums[@]}" || say "some issues were not queued (see above)"
if [ -n "${MEGAVIBE_LABELS:-}" ]; then
  largs=(); IFS=',' read -r -a ls <<< "$MEGAVIBE_LABELS"
  for l in "${ls[@]}"; do largs+=(--label "$l"); done
  megavibe dispatch add "${largs[@]}" ${MEGAVIBE_LABEL_LIMIT:+--limit "$MEGAVIBE_LABEL_LIMIT"} || say "the label sweep failed (see above)"
fi

# ── tick forever; a stop signal ends the loop (the sessions end with the container) ──
trap 'say "stopping"; exit 0' TERM INT
say "dispatching $name: attach with  docker compose exec -it megavibe tmux attach -t mvd-$queue"
while true; do
  megavibe dispatch tick || say "tick failed; trying again in ${MEGAVIBE_TICK_SECS:-120}s"
  [ -z "${MEGAVIBE_LABELS:-}" ] || { megavibe dispatch add "${largs[@]}" ${MEGAVIBE_LABEL_LIMIT:+--limit "$MEGAVIBE_LABEL_LIMIT"} >/dev/null 2>&1 || true; }
  sleep "${MEGAVIBE_TICK_SECS:-120}" & wait $!
done
