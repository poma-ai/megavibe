#!/bin/bash
# pa-start.sh: the one launcher of the Personal Assistant (PA). Run inside the tmux session
# megavibe-personal, by `megavibe assistant` and by the node (node.sh) alike, through the megavibe wrapper.
#
# Where the node folder exists it keeps the PA's conversation: a fresh start chooses the session id and
# records it in node/pa.session; every later start resumes that conversation, so its context and its
# session-scoped schedules come back after a crash, a tmux restart or an exit. Fresh or resumed, the
# session always carries the same name (PA_NAME), which is the name other sessions message it by.
# `megavibe node pa session none` forgets the recorded conversation (the next start is fresh),
# `megavibe node pa session <id>` records one that was started another way. Without a node folder the
# start is fresh every time, as before, rebuilding from the PA's notes.
#   pa-start.sh --running   exit 0 when a PA already runs from the personal folder, else 1; starts nothing
# Model: PA_MODEL in the node folder's node.conf (unset: Claude's own default once a session id is
# chosen here, because the wrapper's usage router leaves a start with a chosen id alone); switch with
# /model inside the session.
# SHORTCUT: a resume that ends within 30 s counts as "could not be resumed" (the conversation is gone
# from this Mac) and a fresh PA is started in its place; a PA the user ends within 30 s of a resume is
# replaced by a fresh one too. Upgrade to the launcher's exit status if the wrapper ever reports one.
# SHORTCUT: /clear inside the PA starts a new conversation the file does not know; record it with
# `megavibe node pa session <id>` or the next restart resumes the conversation from before the /clear.
# MEGAVIBE_NODE_TEST_BIN: tests put stub binaries first on PATH. MEGAVIBE_NODE_TEST_RESUME_SECS: tests
# shorten the 30 s. Nothing else reads them.
# The inherited PATH comes first (a claude under an npm prefix or nvm must stay reachable for
# `megavibe assistant`); the standard directories are only appended, for the LaunchAgent's sparse PATH.
export PATH="${MEGAVIBE_NODE_TEST_BIN:+$MEGAVIBE_NODE_TEST_BIN:}${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
MH="${MEGAVIBE_HOME:-$HOME/.megavibe}"
N="$MH/node"
PA_NAME="Personal Assistant"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
nlog() { [ -d "$N" ] && printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$N/node.log"; }
# pa_live: is a PA already running from the personal folder? The wrapper keeps a session lock there
# with the pid of its claude process. Live means: that pid exists, its command line names claude or
# megavibe, and (where lsof can tell) its working directory is the personal folder, so a pid reused by
# another process, or by a Claude session elsewhere, is not taken for the PA. Without jq, or without a
# lock, the answer is no, and the start goes ahead as it always did.
pa_live() {
  local meta="$MH/personal/.agent/.session-lock.d/metadata.json" pid cmd cwd
  [ -f "$meta" ] && command -v jq >/dev/null 2>&1 || return 1
  pid=$(jq -r '.pid // empty' "$meta" 2>/dev/null)
  [[ $pid =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null || return 1
  cmd=$(ps -p "$pid" -o command= 2>/dev/null)
  case "$cmd" in *claude*|*megavibe*) ;; *) return 1 ;; esac
  cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
  [ -z "$cwd" ] || [ "$cwd" -ef "$MH/personal" ]
}
if [ "${1:-}" = --running ]; then pa_live; exit; fi
cd "$MH/personal" || exit 1
if pa_live; then
  nlog "pa-start: a PA already runs from $MH/personal (its session lock names a live process); not starting a second one"
  if [ -t 1 ]; then
    echo "A Personal Assistant already runs from $MH/personal (see .agent/.session-lock.d there); not starting a second one. This window closes in 20 s."
    sleep 20
  fi
  exit 0
fi
PA_MODEL=$(awk 'index($0, "PA_MODEL=") == 1 { v = substr($0, 10) } END { print v }' "$N/node.conf" 2>/dev/null)
if ! [[ $PA_MODEL =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]; then
  PA_MODEL=""
  nlog "node.conf: PA_MODEL has an unusable value; using the default"
fi
# A detached session cannot answer the workspace-trust dialog, so accept it once, the first time only
# (without jq it cannot tell, and runs the preflight every start, as `megavibe assistant` always did).
if ! command -v jq >/dev/null 2>&1 || [ "$(jq -r --arg d "$PWD" '.projects[$d].hasTrustDialogAccepted // false' "$HOME/.claude.json" 2>/dev/null)" != true ]; then
  # Bounded: a preflight that hangs would leave the PA's tmux session alive and never restarted.
  perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or exit 127' 60 claude -p --dangerously-skip-permissions "echo ok" >/dev/null 2>&1 < /dev/null || true
fi
# --no-normalize: the PA runs in its own folder even when $HOME is a git repo (dotfiles); the wrapper
# would otherwise move to that repo root and refuse to run in the home directory.
SF="$N/pa.session"
SID=""
[ -f "$SF" ] && SID=$(head -n 1 "$SF" 2>/dev/null | tr -d '[:space:]')
# Only a session id is ever passed on: a file holding anything else is ignored.
[[ $SID =~ $UUID_RE ]] || SID=""
if [ -n "$SID" ]; then
  MIN="${MEGAVIBE_NODE_TEST_RESUME_SECS:-30}"
  T0=$SECONDS
  megavibe --no-normalize ${PA_MODEL:+--model "$PA_MODEL"} --name "$PA_NAME" --resume "$SID" "Your session ended (a crash, a tmux restart or an exit) and was restarted: this is your previous conversation, resumed under the same session name. Check that your scheduled ticks and watches are back and set them up again if not, run 'megavibe node session check' to find repo sessions that vanished meanwhile, then tell the user in one line that you are back and what was interrupted."
  [ $((SECONDS - T0)) -ge "$MIN" ] && exit 0
  mv -f "$SF" "$SF.failed" 2>/dev/null
  nlog "pa-start: conversation $SID could not be resumed (it ended within $MIN s); starting a fresh PA, the id is kept in pa.session.failed"
fi
NEW=""
if [ -d "$N" ]; then
  NEW=$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')
  if [[ $NEW =~ $UUID_RE ]] && printf '%s\n' "$NEW" > "$SF.tmp" 2>/dev/null && mv -f "$SF.tmp" "$SF" 2>/dev/null; then :
  else NEW=""; nlog "pa-start: could not record a session id (uuidgen, or $SF not writable); this PA will not be resumed after a restart"; fi
fi
exec megavibe --no-normalize ${PA_MODEL:+--model "$PA_MODEL"} --name "$PA_NAME" ${NEW:+--session-id "$NEW"} "You were just started fresh (a restart or a first start). Run /rehydrate now, then read megavibe-deliverables/STATUS.md and the newest files in megavibe-deliverables/ if they exist, then tell the user in one line that you are back and what is open."
