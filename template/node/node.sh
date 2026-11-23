#!/bin/bash
# node.sh: keep this Mac's node session running; where pa.on exists, also the Personal Assistant;
# and keep the PA's memory repo in step and, on a PA Mac, the secrets in step (memory.push on the Mac that writes it, memory.pull on a
# Mac that holds a standby copy). Installed by `megavibe node install`; opt-in, see README-node.md.
# Run by the LaunchAgent com.megavibe.node at login and every 5 minutes. It starts things; it never
# stops or kills anything. A session that exits is started again on the next run (at most 3 starts
# per window per hour): to keep everything
# off, create the file node.off in this folder (`megavibe node off`); to keep only the PA off, remove
# pa.on (`megavibe node pa off`).
# The PA lives where `megavibe assistant` looks for it: tmux session megavibe-personal. Both start it
# through the same launcher, pa-start.sh, which resumes the PA's recorded conversation under its fixed
# session name (node/pa.session; a first start, or one whose conversation is gone, is fresh and rebuilds
# from its notes). A PA that already runs somewhere else from the personal folder is never doubled.
# The node runs in tmux session TMUX_SESSION (main by default), in a window named after the host; its
# Claude session is named <NODE_PREFIX><host> (NODE- by default), so nobody mistakes it for a session
# to give work to.
# Settings: node.conf in this folder (KEY=value lines, read here, never sourced). Log: node.log.
# SHORTCUT: liveness = "the tmux window exists". A hung session keeps its window and is not restarted;
# upgrade to a heartbeat if that ever happens.
# SHORTCUT: the login warning is typed into the node window whatever it shows; if the session is not at
# its prompt the line is lost or mangled for that day. Upgrade to SendMessage-from-outside if one exists.
# MEGAVIBE_NODE_TEST_BIN: tests put stub binaries first on PATH. Nothing else reads it.
export PATH="${MEGAVIBE_NODE_TEST_BIN:+$MEGAVIBE_NODE_TEST_BIN:}/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=en_US.UTF-8
# Locale: this script matches byte-wise (LC_ALL=C for bash's own patterns, and on each text tool below),
# but LC_ALL is NOT exported: a tmux server this script starts, and every session in it, would
# otherwise run in the C locale and draw replacement characters for anything that is not ASCII.
LC_ALL=C; export -n LC_ALL
MH="${MEGAVIBE_HOME:-$HOME/.megavibe}"
N="$MH/node"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$N/node.log"; }
[ -d "$N" ] || exit 1
[ -e "$N/node.off" ] && exit 0
# conf KEY DEFAULT REGEX: the last KEY=value line of node.conf; a value that does not match REGEX
# (whole value) is logged and replaced by DEFAULT, so a typo cannot reach a command line.
conf() {
  local v
  v=$(LC_ALL=C awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); f = 1 } END { if (f) print v }' "$N/node.conf" 2>/dev/null)
  if [ -z "$v" ]; then printf '%s' "$2"
  elif [[ $v =~ ^$3$ ]]; then printf '%s' "$v"
  else log "node.conf: $1 has an unusable value; using the default"; printf '%s' "$2"; fi
}
# Values start with a letter or digit, so none can reach a command line as an option.
NODE_MODEL=$(conf NODE_MODEL sonnet '[A-Za-z0-9][A-Za-z0-9._-]*')
TS=$(conf TMUX_SESSION main '[A-Za-z0-9][A-Za-z0-9_-]*')
[ "$TS" = megavibe-personal ] && { log "node.conf: TMUX_SESSION may not be the PA's session; using main"; TS=main; }
PREFIX=$(conf NODE_PREFIX NODE- '[A-Za-z0-9_-]*')
CNAME=$(conf COMMIT_NAME 'megavibe node' '[A-Za-z0-9][A-Za-z0-9 ._-]*')
CMAIL=$(conf COMMIT_EMAIL 'megavibe-node@localhost' '[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+')
# Every helper runs under a deadline (perl alarm ends only the helper this script started).
# SHORTCUT: the alarm ends the helper itself, not its children, and a helper that ignored SIGALRM
# would hold this script and its lock. None of the helpers does (tmux, scutil, git, and
# claude-auth-check.sh, which bounds its own child; an ssh that git started can outlive git, but it
# does not hold fd 9; the secrets tool's sync is the one external helper added since, and it is bounded by 60 s); upgrade to a supervising process that ends the helper's process group if a
# helper is ever added that might.
# A helper that cannot be started exits 127 here, not 0.
bounded() { perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or exit 127' "$@"; }
NAME=$(bounded 10 scutil --get LocalHostName 2>/dev/null) || NAME=""
case "$NAME" in ""|-*|*[!A-Za-z0-9-]*) log "unusable host name '$NAME'"; exit 1 ;; esac
[ "${#NAME}" -le 63 ] || { log "host name too long"; exit 1; }
command -v tmux >/dev/null 2>&1 && command -v megavibe >/dev/null 2>&1 || { log "tmux or megavibe not found"; exit 1; }

# One run at a time: an flock on fd 9, held until this script exits (no lock file to clean up).
exec 9>>"$N/.lock" || exit 1
perl -e 'use Fcntl ":flock"; open(my $f, ">&=", 9) or exit 1; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' || exit 0
# Nothing this script starts may inherit fd 9: a tmux server holding it would keep the lock for good.
tmux() { bounded 15 tmux "$@" 9>&-; }

tmux has-session -t "=$TS" 2>/dev/null || tmux new-session -d -s "$TS" -c "$HOME" -n shell || { log "cannot create tmux session $TS"; exit 1; }
# One successful listing decides what exists. If tmux cannot list, nothing is started: a failed
# listing is not proof that a window is gone, and starting on it would duplicate a paid session.
WINDOWS=$(tmux list-windows -t "=$TS" -F '#{window_name}' 2>/dev/null) || { log "tmux could not list windows; nothing started"; exit 0; }
have() { printf '%s\n' "$WINDOWS" | LC_ALL=C grep -qxF -- "$1"; }
# At most 3 successful starts per window per hour, so a session that dies at start-up cannot crashloop.
may_start() {
  local n
  n=$(LC_ALL=C awk -v t=$(( $(date +%s) - 3600 )) '$1 ~ /^[0-9]+$/ && $1 > t' "$N/.starts-$1" 2>/dev/null | wc -l)
  [ "$n" -lt 3 ] && return 0
  [ -n "$(find "$N/.capped-$1" -mmin -60 2>/dev/null)" ] || { log "$1: 3 starts in the last hour, not starting again"; touch "$N/.capped-$1"; }
  return 1
}
log_once() { [ -n "$(find "$N/.once-$1" -mmin -60 2>/dev/null)" ] || { log "$2"; touch "$N/.once-$1"; }; }
started() {
  date +%s >> "$N/.starts-$1"
  tail -n 20 "$N/.starts-$1" > "$N/.starts-$1.tmp" && mv -f "$N/.starts-$1.tmp" "$N/.starts-$1"
  log "started $1"
}

if ! have "$NAME" && may_start node; then
  # Several arguments: tmux runs them as they are, no shell in between.
  tmux new-window -d -t "=$TS:" -n "$NAME" -c "$N" env MEGAVIBE_HOME="$MH" megavibe --no-normalize --model "$NODE_MODEL" --name "$PREFIX$NAME" && started node
fi
# Is a PA running here? As with the windows, only a successful listing proves its session is absent.
# PA_UP: yes, no, or unknown (listing failed).
if SESSIONS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null); then
  if printf '%s\n' "$SESSIONS" | LC_ALL=C grep -qxF megavibe-personal; then PA_UP=yes; else PA_UP=no; fi
else
  PA_UP=unknown; log_once pa-list "tmux could not list sessions; PA not checked, memory not pulled"
fi
if [ -e "$N/pa.on" ] && [ "$PA_UP" = no ]; then
  if [ ! -x "$N/pa-start.sh" ]; then
    log_once pa-launcher "pa.on is set but pa-start.sh is missing or not executable; the PA is NOT being restarted"
  elif [ ! -d "$MH/personal" ]; then
    log_once pa-folder "pa.on is set but $MH/personal does not exist; the PA is NOT being started"
  elif ! grep -q -- '--running' "$N/pa-start.sh" 2>/dev/null; then
    # An older launcher would take --running for a start. Never ask it; say what to do instead.
    log_once pa-old-launcher "pa-start.sh is older than node.sh and cannot be asked whether a PA runs; the PA is NOT being started. Run: megavibe node install"
  elif bounded 15 "$N/pa-start.sh" --running 9>&- < /dev/null; then
    # The tmux session is gone but a PA process still runs from the personal folder (resumed by hand in
    # another terminal, say): a second one would resume the same conversation underneath it.
    log_once pa-elsewhere "pa.on is set and a PA already runs outside tmux session megavibe-personal (its session lock names a live process); not starting a second one"
  elif may_start pa; then
    tmux new-session -d -s megavibe-personal -c "$MH/personal" env MEGAVIBE_HOME="$MH" "$N/pa-start.sh" && { started pa; PA_UP=yes; }
  fi
fi

# Claude login about to lapse: tell the node session once a day; it tells the PA, who tells the user.
# The helper decides (its own contract): exit 0 = more than 168 h left, exit 1 = expires inside 168 h,
# expired or logged out (its message says which), anything else = lifetime unknown.
bounded 20 "$MH/scripts/claude-auth-check.sh" 168 > "$N/.auth-check" 2>/dev/null 9>&- < /dev/null
arc=$?
if [ "$arc" -ne 0 ] && [ "$arc" -ne 1 ] && [ -z "$(find "$N/.auth-unknown" -mtime -1 2>/dev/null)" ]; then
  log "login check could not tell the login lifetime (exit $arc); no expiry warning possible"; touch "$N/.auth-unknown"
fi
# Under 7 days: renewing needs the user at a Mac, so they get a week of daily reminders.
if [ "$arc" -eq 1 ] && [ -z "$(find "$N/.login-warned" -mtime -1 2>/dev/null)" ] && have "$NAME"; then
  msg=$(head -1 "$N/.auth-check" 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9 .,:()>-' | LC_ALL=C cut -c1-200)
  if tmux send-keys -t "=$TS:=$NAME" -l "Claude login warning on $NAME: ${msg:-login check failed}. Tell the Personal Assistant session now, so the user can renew the login." \
    && tmux send-keys -t "=$TS:=$NAME" Enter; then
    touch "$N/.login-warned"; log "login warning sent: $msg"
  else
    log "login warning could not be typed into the node window; trying again next run"
  fi
fi

# Keep the Codex usage reading fresh for the forecast (usage-route.sh forecast): one tiny Codex call at most every
# 30 minutes. PA only: a Mac without pa.on, and plain megavibe use, never run it. The helper skips itself when
# a reading under 15 minutes old exists or codex is unavailable, and never raises: a failed probe is only logged by it.
if [ -e "$N/pa.on" ] && [ -x "$MH/scripts/usage-probe.sh" ]; then
  PROBE_MODEL=$(conf PROBE_MODEL "" '[A-Za-z0-9][A-Za-z0-9._-]*')
  PROBE_CODEX_HOME=$(conf PROBE_CODEX_HOME "" '/[^[:cntrl:]]*')
  (
    [ -z "$PROBE_MODEL" ] || export MEGAVIBE_PROBE_MODEL="$PROBE_MODEL"
    [ -z "$PROBE_CODEX_HOME" ] || export CODEX_HOME="$PROBE_CODEX_HOME"
    bounded 300 "$MH/scripts/usage-probe.sh" run --every 30 >/dev/null 2>&1 9>&- </dev/null
  ) || true
fi

# PA secrets: where the PA runs and the personal secrets tool is installed (~/.local/bin/secret), carry secret
# changes from the other Mac (iCloud store) into this Mac's Keychain on every run, so no separate job is needed.
# PA only, like the probe above: a Mac without pa.on, and plain megavibe use, never run it. Its output is
# discarded (it could carry secret names, and a log would grow without bound); a failure is logged by exit
# status only, once an hour.
if [ -e "$N/pa.on" ] && [ -x "$HOME/.local/bin/secret" ]; then
  bounded 60 "$HOME/.local/bin/secret" sync >/dev/null 2>&1 9>&- </dev/null \
    || log_once secret-sync "secret sync failed or timed out (run: secret sync)"
fi

# PA memory: a git repo in the personal folder whose origin is a bare repo on the writing Mac.
# memory.push: this Mac writes it (commit what changed, push). memory.pull: standby copy, fast-forward
# only, and only while no PA runs here. Neither file: nothing happens.
M="$MH/personal"
g() { GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" bounded 60 git -C "$M" "$@" 9>&- < /dev/null; }
if [ -d "$M/.git" ] && [ -e "$N/memory.push" ]; then
  # A failing status (damaged index, lock held, timeout) must not read as "nothing changed".
  # Signing is off for these automatic commits: a signing agent is not reachable from a LaunchAgent, and a
  # user-wide commit.gpgsign=true would otherwise make every commit fail.
  if ! CHANGED=$(g status --porcelain 2>/dev/null); then
    log_once memory-status "memory: git status failed; nothing committed"
  elif [ -n "$CHANGED" ]; then
    { g add -A && g -c user.name="$CNAME" -c user.email="$CMAIL" -c commit.gpgsign=false commit -q -m "auto: $(date '+%F %T') $NAME"; } >/dev/null 2>&1 \
      || log_once memory-commit "memory: commit failed"
  fi
  if LOCAL=$(g rev-parse HEAD 2>/dev/null) && REMOTE=$(g rev-parse '@{u}' 2>/dev/null); then
    [ "$LOCAL" = "$REMOTE" ] || g push -q >/dev/null 2>&1 || log_once memory-push "memory: push failed"
  else
    log_once memory-rev "memory: cannot read HEAD or its upstream; nothing pushed"
  fi
elif [ -d "$M/.git" ] && [ -e "$N/memory.pull" ]; then
  # A pull rewrites files in the folder, and a PA writing there at the same moment could lose a note.
  # So this Mac pulls only as a pure standby: no PA session here, and none set to be started here.
  # SHORTCUT: PA_UP is the listing from the start of this run. A PA started by hand in the seconds
  # between that listing and the merge is not seen. `megavibe node takeover` removes memory.pull
  # before it starts the PA, which closes that window for its own start; a PA started by another
  # route is not covered. Upgrade to one lock shared with every PA start route if that ever bites.
  if [ -e "$N/pa.on" ] || [ "$PA_UP" != no ]; then
    log_once memory-pull-skip "memory: not pulling while a PA runs (or is set to run) on this Mac"
  else
    # --no-overwrite-ignore: a file that is ignored here but tracked in an incoming commit stops the
    # update instead of being replaced.
    { g fetch -q && g merge -q --ff-only --no-overwrite-ignore; } >/dev/null 2>&1 \
      || log_once memory-pull "memory: update failed (origin unreachable, or local files in the way)"
  fi
fi
exit 0
