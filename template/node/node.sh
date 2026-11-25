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
# One run at a time: an flock on fd 9, held until this script exits (no lock file to clean up).
exec 9>>"$N/.lock" || exit 1
perl -e 'use Fcntl ":flock"; open(my $f, ">&=", 9) or exit 1; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' || exit 0
# Nothing this script starts may inherit fd 9: a tmux server holding it would keep the lock for good.
tmux() { bounded 15 tmux "$@" 9>&-; }
log_once() { [ -n "$(find "$N/.once-$1" -mmin -60 2>/dev/null)" ] || { log "$2"; touch "$N/.once-$1"; }; }
# These records are advisory: an unavailable clock/history or a failed write never stops supervision.
put() { printf '%s\n' "$2" > "$N/$1.tmp" && mv -f "$N/$1.tmp" "$N/$1"; }
epoch() { local v; v=$(cat "$N/$1" 2>/dev/null); [[ $v =~ ^[1-9][0-9]{0,10}$ ]] && printf '%s' "$v"; }
hhmm() { perl -MPOSIX=strftime -e 'print strftime("%H:%M", localtime($ARGV[0]))' "$1" 2>/dev/null; }
NOW=$(date +%s); LAST=$(epoch last-alive); BOOT=""; RESTART=""
OS=$(uname -s)
if [ "$OS" = Darwin ]; then
  BOOT=$(bounded 2 sysctl -n kern.boottime 2>/dev/null 9>&- | sed -nE 's/.*[ {]sec[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p')
  [[ $BOOT =~ ^[1-9][0-9]{0,10}$ ]] || BOOT=""
fi
if [[ $NOW =~ ^[1-9][0-9]{0,10}$ ]]; then
  if [ -n "$LAST" ] && { [ $((NOW - LAST)) -gt 900 ] || [ "${BOOT:-0}" -gt "$LAST" ]; }; then
    CLEAN=unknown
    if [ "$OS" = Darwin ] && HISTORY=$(LC_ALL=C bounded 2 last -y -1 shutdown 2>/dev/null 9>&-); then
      # Request the year; missing/unparseable history cannot establish a shutdown date.
      SHUTDOWN=$(printf '%s\n' "$HISTORY" | perl -MTime::Local=timelocal -e '
        my $now = shift; my %mon; @mon{qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)} = (0..11);
        while (<STDIN>) {
          next unless /^shutdown\s/;
          last unless /^shutdown\s+.*?\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+(\w{3})\s+(\d{1,2})\s+(\d\d):(\d\d)(?::(\d\d))?\s+(\d{4})(?=\s|$)/;
          my ($m,$d,$h,$min,$sec,$year) = ($1,$2,$3,$4,$5 || 0,$6);
          last unless exists $mon{$m};
          my $t = eval { timelocal($sec,$min,$h,$d,$mon{$m},$year) };
          last unless defined $t && $t <= $now;
          my @date = localtime($t);
          last unless $date[0] == $sec && $date[1] == $min && $date[2] == $h
            && $date[3] == $d && $date[4] == $mon{$m} && $date[5] + 1900 == $year;
          print $t; last;
        }' "$NOW" 2>/dev/null)
      if [[ $SHUTDOWN =~ ^[1-9][0-9]{0,10}$ ]]; then
        # last reports minutes: events in the same minute cannot be ordered.
        # Its newest shutdown being earlier rules out any shutdown at/after LAST.
        if [ $((SHUTDOWN / 60)) -gt $((LAST / 60)) ]; then CLEAN=yes
        elif [ $((SHUTDOWN / 60)) -lt $((LAST / 60)) ]; then CLEAN=no; fi
      fi
    fi
    RESTART="back after $(( (NOW - LAST) / 60 )) min (last alive $(hhmm "$LAST"), boot $(if [ -n "$BOOT" ]; then hhmm "$BOOT"; else printf unknown; fi), clean shutdown: $CLEAN)"
    log "$RESTART"
  fi
  put last-alive "$NOW"
  if [ -n "$RESTART" ] || [ -z "$(epoch .started-at)" ]; then
    put .started-at "$NOW"; put .secret-ok no
  fi
fi 2>/dev/null

# Preserve the existing check's names, resume commands, and UNKNOWN/UNSEEN distinctions.
if [ -n "$RESTART" ]; then
  CHECK=$(bounded 45 bash "$MH/scripts/megavibe-node.sh" session check 2>/dev/null 9>&-)
  [ -n "$CHECK" ] || CHECK="Session check unavailable; run: megavibe node session check"
  put restart-note.txt "$RESTART
$CHECK
Secret sync succeeded since start: no (not yet checked)" 2>/dev/null
fi
secret_note() {
  [ -f "$N/restart-note.txt" ] || return 0
  { sed '/^Secret sync succeeded since start:/d' "$N/restart-note.txt"; printf 'Secret sync succeeded since start: %s\n' "$1"; } > "$N/restart-note.txt.tmp" && mv -f "$N/restart-note.txt.tmp" "$N/restart-note.txt"
}
if [ -e "$N/node.off" ]; then
  secret_note "$(cat "$N/.secret-ok" 2>/dev/null || echo no) (node off)" 2>/dev/null
  exit 0
fi
# PA only. Count every failed attempt across runs, but retain the hourly failure-log limit.
# Retry only during the first three minutes of this node's recorded start, never every tick.
if [ -e "$N/pa.on" ] && [ -x "$HOME/.local/bin/secret" ]; then
  FAILURES=$(epoch .secret-failures); FAILURES=${FAILURES:-0}; ATTEMPT=0
  START=$(epoch .started-at); START=${START:-0}
  while :; do
    ATTEMPT=$((ATTEMPT + 1))
    if bounded 60 "$HOME/.local/bin/secret" sync >/dev/null 2>&1 9>&- </dev/null; then
      [ "$FAILURES" = 0 ] || log "secret sync ok after $FAILURES failed attempts"
      put .secret-failures 0; put .secret-ok yes
      break
    fi
    FAILURES=$((FAILURES + 1)); put .secret-failures "$FAILURES"
    log_once secret-sync "secret sync failed or timed out (run: secret sync)"
    RETRY_NOW=$(date +%s)
    [[ $RETRY_NOW =~ ^[1-9][0-9]{0,10}$ ]] && [ "$RETRY_NOW" -ge "$START" ] || break
    [ "$ATTEMPT" -lt 3 ] && [ $((RETRY_NOW - START + 20)) -lt 180 ] || break
    sleep 20
  done
  secret_note "$(cat "$N/.secret-ok" 2>/dev/null || echo no)"
else
  secret_note "$(cat "$N/.secret-ok" 2>/dev/null || echo no) (sync disabled or tool unavailable)"
fi 2>/dev/null

# No authentication or client data: connect to port 22, then read only the first server line.
# Perl is already required by the node; its core socket module also bounds DNS with the alarm.
peer_state() {
  perl -MIO::Socket::INET -e '
    $SIG{ALRM} = sub { die "timeout\n" };
    my $s = eval { alarm 2; IO::Socket::INET->new(PeerAddr=>$ARGV[0], PeerPort=>22, Proto=>"tcp", Timeout=>2) };
    alarm 0; exit 1 unless $s;
    my $line = "";
    eval { alarm 2; while (length($line) < 4096 && sysread($s, my $c, 1)) { $line .= $c; last if $c eq "\n"; } };
    alarm 0; print index($line, "This system is locked") >= 0 ? "locked" : "up";
  ' "$1" 2>/dev/null 9>&- </dev/null
}
PEERS=$(conf NODE_PEERS "" '[^[:cntrl:]]*')
IFS=' ' read -r -a PEER_ENTRIES <<< "$PEERS"
SEEN_PEERS='|'
for PEER in "${PEER_ENTRIES[@]}"; do
  # Safe filenames and arguments; a bad entry cannot prevent checking the other peers.
  [[ $PEER =~ ^([A-Za-z0-9][A-Za-z0-9_-]*)=([A-Za-z0-9][A-Za-z0-9.-]*)(,([A-Za-z0-9][A-Za-z0-9.-]*))?$ ]] || {
    PEER_KEY=$(printf '%s' "$PEER" | cksum)
    log_once "peer-invalid-${PEER_KEY%% *}" "node.conf: unusable NODE_PEERS entry: $PEER"
    continue
  }
  PN=${BASH_REMATCH[1]}; HOST=${BASH_REMATCH[2]}; FALLBACK=${BASH_REMATCH[4]}
  PN_KEY=$(printf '%s' "$PN" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  if [[ $SEEN_PEERS == *"|$PN_KEY|"* ]]; then
    log_once "peer-duplicate-$PN_KEY" "node.conf: duplicate NODE_PEERS name $PN; using the first entry"
    continue
  fi
  SEEN_PEERS="$SEEN_PEERS$PN_KEY|"
  STATE=$(peer_state "$HOST") || STATE=""
  if [ -z "$STATE" ] && [ -n "$FALLBACK" ]; then STATE=$(peer_state "$FALLBACK") || STATE=""; fi
  STATE=${STATE:-unreachable}
  [ "$(cat "$N/.peer-$PN" 2>/dev/null)" != "$STATE" ] || continue
  put ".peer-$PN" "$STATE" || continue
  log "peer $PN: $STATE"
  if [ "$OS" = Darwin ] && command -v osascript >/dev/null 2>&1; then
    bounded 3 osascript -e "display notification \"$PN: $STATE\" with title \"Megavibe node\"" >/dev/null 2>&1 9>&- </dev/null || true
  fi
done

NAME=$(bounded 10 scutil --get LocalHostName 2>/dev/null 9>&-) || NAME=""
case "$NAME" in ""|-*|*[!A-Za-z0-9-]*) log "unusable host name '$NAME'"; exit 1 ;; esac
[ "${#NAME}" -le 63 ] || { log "host name too long"; exit 1; }
command -v tmux >/dev/null 2>&1 && command -v megavibe >/dev/null 2>&1 || { log "tmux or megavibe not found"; exit 1; }

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
