#!/bin/bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/remote-removed.XXXXXX")
trap 'rm -rf "$T"' EXIT

export HOME="$T/home" MEGAVIBE_HOME="$T/install" CALLS="$T/calls"
mkdir -p "$HOME/Library/LaunchAgents" "$MEGAVIBE_HOME" "$T/bin"
# Simulate an old install so the old launcher would reach tmux and launchctl.
bot="$MEGAVIBE_HOME/telegram-bot.py"
plist="$HOME/Library/LaunchAgents/com.megavibe.remote.plist"
touch "$bot" "$plist"
for tool in tmux launchctl; do
  cat > "$T/bin/$tool" <<'STUB'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$CALLS"
exit 1
STUB
  chmod +x "$T/bin/$tool"
done

export PATH="$T/bin:$PATH"
launcher="${1:-$REPO/megavibe}"
failed=0
check_remote() {
  local status=0 output
  output=$(perl -e 'alarm shift; exec @ARGV or die $!' 5 /bin/bash "$launcher" remote "$@" 2>&1) || status=$?
  if [ "$status" -ne 1 ] || [[ "$output" != *"Telegram remote was removed"* ]] || [ -e "$CALLS" ]; then
    printf 'FAIL: megavibe remote %s (exit %s)\n%s\n' "$*" "$status" "$output"
    if [ -e "$CALLS" ]; then cat "$CALLS"; fi
    failed=1
  fi
}

check_remote
check_remote --autostart off
[ "$failed" -eq 0 ] || exit 1
[[ -f "$bot" && -f "$plist" ]]
echo "PASS: megavibe remote exits 1 with a removal notice and calls neither fake"
