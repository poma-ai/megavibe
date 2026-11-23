#!/bin/bash
# megavibe-node.sh: `megavibe node ...`. Installs and switches the node: a LaunchAgent that keeps a
# thin node session (and, where switched on, the Personal Assistant) running on this Mac, and keeps
# the PA's memory repo in step between a writing Mac and a standby. Opt-in: nothing exists or runs
# until `megavibe node install`. Detail: README-node.md.
#
#   install [--pa] [--memory push|pull|none]   write the node folder and the LaunchAgent; print the
#                                              launchctl line(s) for the user to run
#   status                                     what is installed, loaded, switched on and running
#   on | off                                   node.off: everything off (nothing is stopped)
#   pa on | off                                pa.on: keep the PA running on this Mac
#   pa session [ID | none]                     the PA conversation the next start resumes: show, set, forget
#   session start NAME --dir DIR --task FILE [--model M] [--window W] [--prompt TEXT]
#                                              start a repo session in its own tmux window and register it
#   session add NAME --window TARGET --task FILE [--dir DIR] [--sid ID] [--model M]
#                                              register a session that already runs in a tmux window
#   session check                              registered as running, window gone: listed (exit 1)
#   session resume NAME [--fresh]              start a vanished session again (its conversation, if known)
#   session done NAME | drop NAME | list       it reported / forget it / the whole register
#   memory push | pull | none                  which way this Mac keeps the PA's memory repo
#   memory init [--origin PATH]                on the writing Mac: repo, bare origin, first commit
#   memory clone URL                           on a standby Mac: copy of the writer's repo
#   takeover                                   make this Mac the active PA (memory.pull off first)
#   handback                                   stop being the active PA (push, then standby)
#
# It never runs launchctl bootstrap/bootout itself: the guard in block-dangerous-bash.sh refuses a
# launchctl call that names ~/.megavibe from a session, and a script must not be the way around it.
# It never stops a session either; it tells the user which one to end.
set -euo pipefail

MH="${MEGAVIBE_HOME:-$HOME/.megavibe}"
N="$MH/node"
M="$MH/personal"
LABEL=com.megavibe.node
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
TPL="$(cd "$(dirname "$0")/.." && pwd)/template/node"
PA_TMUX=megavibe-personal
PA_NAME="Personal Assistant"   # the PA's fixed session name (pa-start.sh): where sessions report to
S="$N/sessions"                # the session register: one KEY=value file per started repo session
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
# Lower case only: on a case-insensitive disk Alpha and alpha would share one record but not one stamp.
SESSION_RE='^[a-z0-9][a-z0-9._-]{0,62}$'

die() { printf 'megavibe node: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
need_install() { [ -f "$N/node.sh" ] || die "not installed; run: megavibe node install"; }
pa_running() { command -v tmux >/dev/null 2>&1 && tmux has-session -t "=$PA_TMUX" 2>/dev/null; }
# fd 9 closed: a git or ssh child that outlives this command must not keep the node's lock.
g() { GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" git -C "$M" "$@" < /dev/null 9>&-; }
# The node's own lock (node.sh holds it for a whole run): a takeover or handback never runs alongside a
# node run that could pull or commit underneath it. Waits up to 120 s.
lock_node() {
  exec 9>>"$N/.lock"
  perl -e 'use Fcntl ":flock"; open(my $f, ">&=", 9) or exit 1; for (1..120) { exit 0 if flock($f, LOCK_EX | LOCK_NB); sleep 1 } exit 1' \
    || die "the node is busy (its lock is held); run the same command again in a minute (switch files changed so far stay changed)"
}
conf_get() { awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); f = 1 } END { if (f) print v }' "$N/node.conf" 2>/dev/null; }
set_memory() {   # set_memory push|pull|none: exactly one switch file, or none
  case "$1" in
    push) rm -f "$N/memory.pull"; : > "$N/memory.push" ;;
    pull) rm -f "$N/memory.push"; : > "$N/memory.pull" ;;
    none) rm -f "$N/memory.push" "$N/memory.pull" ;;
    *) die "memory: expected push, pull or none" ;;
  esac
}
start_pa() {   # the same launcher and session as node.sh and `megavibe assistant`
  command -v tmux >/dev/null 2>&1 || die "tmux is required"
  [ -d "$M" ] || die "$M does not exist; run bash setup.sh first"
  tmux new-session -d -s "$PA_TMUX" -c "$M" env MEGAVIBE_HOME="$MH" "$N/pa-start.sh" 9>&- \
    || die "could not start the PA (tmux session $PA_TMUX)"
}
plist_text() {
  local x; x() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$(x "$N/node.sh")</string></array>
  <key>EnvironmentVariables</key><dict><key>MEGAVIBE_HOME</key><string>$(x "$MH")</string></dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardOutPath</key><string>$(x "$N/launchd.log")</string>
  <key>StandardErrorPath</key><string>$(x "$N/launchd.log")</string>
</dict></plist>
EOF
}
agent_loaded() { launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; }

# Secret shapes refused before the memory repo's first commit. Prints file:line only, never the match.
secret_scan() {   # secret_scan FILE...: exit 0 clean, 1 findings
  local re='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|sk-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{20}'
  # Credential assignments in any case (ACCESS_TOKEN=, api-key:, "refresh_token": ...), matched case-blind.
  local rei='["'"'"']?(refresh|access|auth|api|secret)[_-]?(token|key)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9._~+/-]{24,}'
  local f lines hit=0
  for f in "$@"; do
    [ -f "$f" ] || continue
    # -a and LC_ALL=C: a file with a NUL or a byte that is not UTF-8 is still scanned, not skipped as binary.
    lines=$( { LC_ALL=C grep -aEn -- "$re" "$f"; LC_ALL=C grep -aEin -- "$rei" "$f"; } 2>/dev/null | LC_ALL=C cut -d: -f1 | sort -un || true)
    [ -n "$lines" ] || continue
    hit=1; printf '%s\n' "$lines" | sed "s|^|  $f:|"
  done
  return $(( hit ? 1 : 0 ))
}

cmd_install() {
  local pa=0 mem="" a prev
  while [ $# -gt 0 ]; do
    case "$1" in
      --pa) pa=1 ;;
      --memory) mem="${2:-}"; case "$mem" in push|pull|none) ;; *) die "install: --memory needs push, pull or none" ;; esac; shift ;;
      *) die "install: unknown option $1" ;;
    esac
    shift
  done
  [ "$(uname -s)" = Darwin ] || die "the node needs macOS (launchd, scutil)"
  [ -d "$TPL" ] || die "templates not found at $TPL; run bash setup.sh from the megavibe repo"
  if [ "$pa" = 1 ] && { [ -e "$N/memory.pull" ] || [ "$mem" = pull ]; }; then
    die "install: --pa on a standby (memory pull) is refused; to run the PA here use: megavibe node takeover"
  fi
  if [ "$mem" = pull ] && { [ -e "$N/pa.on" ] || pa_running; }; then
    die "install: --memory pull while this Mac runs the PA is refused; to make it a standby use: megavibe node handback"
  fi
  # The plist is built and checked before anything is written, so a refusal leaves nothing half-done.
  local new changed=0
  new=$(plist_text)
  mkdir -p "$N" "$(dirname "$PLIST")"
  if command -v plutil >/dev/null 2>&1; then
    printf '%s\n' "$new" > "$PLIST.tmp"
    plutil -lint -s "$PLIST.tmp" || { rm -f "$PLIST.tmp"; die "the generated plist does not pass plutil -lint (a path with characters a plist cannot hold?); nothing installed"; }
    rm -f "$PLIST.tmp"
  fi
  # pa-start.sh first: a node run between the two copies must not meet a new node.sh with an old launcher.
  for a in pa-start.sh node.sh CLAUDE.md; do
    if cmp -s "$TPL/$a" "$N/$a"; then say "  skip    $a (current)"
    else
      # The copy being replaced (a hand edit, an older version) is kept once as <file>.prev.
      prev=""
      if [ -f "$N/$a" ]; then cp -p "$N/$a" "$N/$a.prev"; prev=" (previous copy: $a.prev)"; fi
      # Fatal: node.sh is only installed once its launcher is, or it would call an older pa-start.sh.
      { cp "$TPL/$a" "$N/.$a.tmp" && mv -f "$N/.$a.tmp" "$N/$a"; } || die "install: could not write $N/$a; stopped (files after it were not touched)"
      say "  wrote   $a$prev"
    fi
  done
  chmod 755 "$N/node.sh" "$N/pa-start.sh"
  if [ -f "$N/node.conf" ]; then say "  skip    node.conf (yours)"
  else
    cat > "$N/node.conf" <<'EOF'
# megavibe node settings: KEY=value, one per line, no quotes. Unset keys use the default shown.
# NODE_MODEL=sonnet
# PA_MODEL=
# TMUX_SESSION=main
# NODE_PREFIX=NODE-
# COMMIT_NAME=megavibe node
# COMMIT_EMAIL=megavibe-node@localhost
# PROBE_MODEL=              model of the Codex usage probe (PA Macs only; default gpt-6-luna)
# PROBE_CODEX_HOME=          absolute path of the Codex home the probe reads and writes
EOF
    say "  wrote   node.conf"
  fi
  [ "$pa" = 1 ] && { : > "$N/pa.on"; say "  set     pa.on"; }
  [ -n "$mem" ] && { set_memory "$mem"; say "  set     memory $mem"; }
  if [ -f "$PLIST" ] && [ "$(cat "$PLIST")" = "$new" ]; then say "  skip    $PLIST (current)"
  else
    printf '%s\n' "$new" > "$PLIST.tmp" && mv -f "$PLIST.tmp" "$PLIST"; changed=1; say "  wrote   $PLIST"
  fi
  say ""
  if agent_loaded && [ "$changed" = 0 ]; then
    say "The LaunchAgent is loaded; its next run (within 5 minutes) uses the installed node.sh."
  else
    say "Load the LaunchAgent yourself, in Terminal (megavibe does not run launchctl for you):"
    agent_loaded && say "  launchctl bootout gui/$(id -u)/$LABEL"
    say "  launchctl bootstrap gui/$(id -u) $(printf '%q' "$PLIST")"
  fi
}

cmd_status() {
  local f
  if [ ! -f "$N/node.sh" ]; then say "node: not installed (megavibe node install)"; return 0; fi
  say "node folder:  $N"
  if [ -d "$TPL" ]; then
    for f in node.sh pa-start.sh CLAUDE.md; do
      cmp -s "$TPL/$f" "$N/$f" || say "  $f differs from the template (megavibe node install refreshes it)"
    done
  fi
  [ -f "$PLIST" ] && say "LaunchAgent:  $PLIST" || say "LaunchAgent:  not written"
  agent_loaded && say "  loaded" || say "  not loaded"
  say "switches:     node $( [ -e "$N/node.off" ] && echo OFF || echo on ), pa $( [ -e "$N/pa.on" ] && echo on || echo off ), memory $( if [ -e "$N/memory.push" ]; then echo push; elif [ -e "$N/memory.pull" ]; then echo pull; else echo none; fi )"
  [ -e "$N/memory.push" ] && [ -e "$N/memory.pull" ] && say "  both memory.push and memory.pull exist: push wins; run megavibe node memory push|pull"
  if command -v tmux >/dev/null 2>&1; then
    local ts; ts=$(conf_get TMUX_SESSION); ts=${ts:-main}
    say "PA session:   $( pa_running && echo "running (tmux attach -t $PA_TMUX)" || echo "not running" )"
    f=$(head -n 1 "$N/pa.session" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ $f =~ $UUID_RE ]]; then say "  conversation $f is resumed on the next start (megavibe node pa session none: start fresh)"
    else say "  no conversation recorded: the next start is fresh"; fi
    f=$(grep -lxE 'state=(running|starting)' "$S"/* 2>/dev/null | wc -l | tr -d ' ' || true)
    [ "${f:-0}" = 0 ] || say "sessions:     $f registered as running (megavibe node session check)"
    say "node windows: $(tmux list-windows -t "=$ts" -F '#{window_name}' 2>/dev/null | tr '\n' ' ' || true)"
  fi
  if [ -e "$M/.git" ]; then
    deliverables_check
    say "memory repo:  $(g rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?') -> $(g rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo 'no upstream'); $(g status --porcelain 2>/dev/null | wc -l | tr -d ' ') changed file(s) (no fetch)"
  else
    say "memory repo:  none"
  fi
  [ -f "$N/node.log" ] && { say "node.log (last 5):"; tail -n 5 "$N/node.log" | sed 's/^/  /'; }
  return 0
}

# The PA's deliverables must not be ignored in its memory repo (an older init.sh appended its
# megavibe-deliverables rule to every .gitignore, an allow-list included). Prints a warning only.
deliverables_check() {
  [ -e "$M/.git" ] || return 0
  if git -C "$M" check-ignore -q --no-index megavibe-deliverables/STATUS.md 2>/dev/null; then
    say "  WARNING: megavibe-deliverables/ is ignored by $M/.gitignore, so new deliverables do not sync; remove the megavibe-deliverables line that comes after the allow-list."
  fi
}

cmd_memory_init() {
  local origin="$MH/personal-memory.git" files
  while [ $# -gt 0 ]; do
    case "$1" in
      --origin) origin="${2:-}"; [ -n "$origin" ] || die "--origin needs a path"; shift ;;
      *) die "memory init: unknown option $1" ;;
    esac
    shift
  done
  need_install
  [ -d "$M" ] || die "$M does not exist; run bash setup.sh first"
  case "$origin" in /*) ;; *) origin="$PWD/$origin" ;; esac
  # Under the node's lock: a node run must not see the half-made repo (memory.push may already be set).
  lock_node
  if [ -e "$M/.git" ]; then
    if [ "$(g remote get-url origin 2>/dev/null || true)" = "$origin" ]; then
      # An earlier init that stopped after adding the origin (push failed) is finished here.
      g rev-parse -q --verify '@{u}' >/dev/null 2>&1 || g push -q -u origin main || die "push to $origin failed"
      set_memory push; say "memory repo already set up (origin $origin); memory push set"; deliverables_check; return 0
    fi
    die "$M is already a git repo with another or no origin; not touching it"
  fi
  if [ -e "$origin" ] && [ "$(git -C "$origin" rev-parse --is-bare-repository 2>/dev/null || true)" != true ]; then
    die "$origin exists and is not a bare git repo"
  fi
  # Only an allow-list (an exact `/*` line) is kept as it is: any other .gitignore would let the node commit
  # everything in the folder (logs, local overrides) every five minutes. Such a file becomes the allow-list
  # followed by its own rules, which come later and so still win: what it excluded stays excluded.
  if [ -e "$M/.gitignore" ] && grep -qx '/\*' "$M/.gitignore"; then
    say "  keep    .gitignore (yours, an allow-list; the template is $TPL/memory.gitignore)"
  elif [ -e "$M/.gitignore" ]; then
    cp -p "$M/.gitignore" "$M/.gitignore.prev"
    # Except megavibe's own `megavibe-deliverables` rule (init.sh adds it to every project): kept, it would
    # override the allow-list's negation and the PA's deliverables would silently never sync.
    { cat "$TPL/memory.gitignore"; printf '\n# Kept from the previous .gitignore (later rules win, so its exclusions still apply):\n'
      LC_ALL=C grep -avxE '[[:space:]]*/?megavibe-deliverables(/|/\*|/\*\*)?[[:space:]]*' "$M/.gitignore.prev" || true; } > "$M/.gitignore.tmp"
    mv -f "$M/.gitignore.tmp" "$M/.gitignore"
    say "  wrote   .gitignore (allow-list, then your previous rules; the old file is .gitignore.prev)"
  else
    cp "$TPL/memory.gitignore" "$M/.gitignore"; say "  wrote   .gitignore (allow-list)"
  fi
  git -C "$M" init -q
  # Until the first push has landed, any failure removes the repo this call just made (only .git; the
  # files are untouched), so a retry starts clean instead of finding a repo without an origin.
  INIT_DONE=0
  trap '[ "$INIT_DONE" = 1 ] || { rm -rf "$M/.git"; echo "megavibe node: memory init failed; the half-made repo in $M was removed, run it again once the cause is fixed" >&2; }' EXIT
  git -C "$M" symbolic-ref HEAD refs/heads/main
  files=()
  while IFS= read -r -d '' f; do files+=("$M/$f"); done < <(git -C "$M" ls-files -o --exclude-standard -z)
  [ ${#files[@]} -gt 0 ] || die "nothing to commit under the allow-list; check $M/.gitignore"
  if ! secret_scan "${files[@]}"; then
    die "secret-shaped text in the lines above; move it out (or ignore the file in .gitignore) and run again. Nothing was committed."
  fi
  say "  ${#files[@]} file(s) pass the secret scan"
  local cn ce; cn=$(conf_get COMMIT_NAME); ce=$(conf_get COMMIT_EMAIL)
  g add -A
  g -c user.name="${cn:-megavibe node}" -c user.email="${ce:-megavibe-node@localhost}" -c commit.gpgsign=false commit -q -m "memory: first commit"
  [ -e "$origin" ] || git init -q --bare "$origin"
  g remote add origin "$origin"
  g push -q -u origin main
  INIT_DONE=1; trap - EXIT
  set_memory push
  deliverables_check
  say "memory repo ready: $M -> $origin (memory push set; the node commits and pushes every 5 minutes)"
  say "On a standby Mac (ssh from there to here must work): megavibe node memory clone $(scutil --get LocalHostName 2>/dev/null || hostname -s).local:$origin"
}

cmd_memory_clone() {
  local url="${1:-}" b d ts
  [ -n "$url" ] || die "memory clone: give the origin URL (host:/path/to/personal-memory.git)"
  need_install
  [ -d "$M" ] || die "$M does not exist; run bash setup.sh first"
  [ -e "$N/pa.on" ] && die "pa.on is set on this Mac; a standby copy is only made with the PA off (megavibe node pa off)"
  pa_running && die "a PA is running on this Mac (tmux $PA_TMUX); end it first"
  lock_node
  if [ -e "$M/.git" ]; then
    [ "$(g remote get-url origin 2>/dev/null || true)" = "$url" ] || die "$M is already a git repo with another origin; not touching it"
    say "already a copy of $url"; set_memory pull; g status --short | sed 's/^/  /'; return 0
  fi
  git -C "$M" init -q
  # Any failure from here on removes the half-made repo (only .git; files are restored from the
  # backup folder by hand if a checkout got halfway), so a retry starts clean instead of finding a
  # repo with the right origin and taking it for a finished copy.
  CLONE_DONE=0
  trap '[ "$CLONE_DONE" = 1 ] || { rm -rf "$M/.git"; echo "megavibe node: clone failed; the half-made repo was removed (backups, if any, are in $N)" >&2; }' EXIT
  g remote add origin "$url"
  g fetch -q origin || die "fetch from $url failed (ssh to the writer?)"
  b=$(g ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')
  b=${b:-main}
  g rev-parse -q --verify "origin/$b" >/dev/null || die "origin has no branch $b"
  g symbolic-ref HEAD "refs/heads/$b"
  # Index = origin, files untouched: the status below is exactly where this Mac's files differ.
  g reset -q "origin/$b"
  d=$(g status --porcelain)
  if [ -n "$d" ]; then
    say "Differences between this Mac and origin (M: yours differs, D: missing here, ??: only here, kept):"
    printf '%s\n' "$d" | sed 's/^/  /'
  fi
  # Everything checkout would replace is copied aside first: files that differ (M, T), and for a path git
  # reports missing (D), whatever stands in its way on disk, a directory at the path or a file where one of
  # its parent directories should be.
  ts=$(date +%Y%m%d-%H%M%S)
  backup() { mkdir -p "$N/memory-backup-$ts/$(dirname "$1")" && cp -pPR "$M/$1" "$N/memory-backup-$ts/$1"; }
  while IFS= read -r -d '' f; do backup "$f"; done < <(g diff -z --name-only --diff-filter=MT)
  while IFS= read -r -d '' f; do
    if [ -e "$M/$f" ] || [ -L "$M/$f" ]; then backup "$f"; continue; fi
    p=$(dirname "$f")
    while [ "$p" != . ]; do
      if { [ -e "$M/$p" ] || [ -L "$M/$p" ]; } && { [ ! -d "$M/$p" ] || [ -L "$M/$p" ]; }; then
        [ -e "$N/memory-backup-$ts/$p" ] || backup "$p"; break
      fi
      p=$(dirname "$p")
    done
  done < <(g diff -z --name-only --diff-filter=D)
  [ -d "$N/memory-backup-$ts" ] && say "  your differing files were copied to $N/memory-backup-$ts"
  g checkout -q -- .
  g branch -q --set-upstream-to="origin/$b"
  CLONE_DONE=1; trap - EXIT
  set_memory pull
  say "standby copy ready: $M follows $url ($b); memory pull set (the node fast-forwards it while no PA runs here)"
}

cmd_takeover() {
  need_install
  # A standby has been following another Mac's PA (its node pulled the notes all along, so the merge
  # below may move nothing): a conversation recorded here from an earlier turn as the PA is older than
  # those notes, and the PA started below must begin fresh from them.
  if [ -e "$N/memory.pull" ] && [ -e "$N/pa.session" ]; then
    rm -f "$N/pa.session"; say "  this Mac was a standby: the PA starts a fresh conversation from the notes"
  fi
  # Order matters: memory.pull goes first, so no node run can pull underneath the PA started below.
  rm -f "$N/memory.pull"
  lock_node
  # pa.on is off until the takeover succeeds, so a refused takeover cannot have the node start a PA on an
  # unresolved history (on a Mac that was the active PA before, pa.on may still be set).
  rm -f "$N/pa.on"
  if pa_running; then
    # Never merge underneath a running PA. If origin holds commits this copy lacks (the other Mac's notes),
    # the PA must end first so takeover can fast-forward before it starts again.
    local sync="no memory repo here"
    if [ -e "$M/.git" ] && g rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
      if ! g fetch -q 2>/dev/null; then
        sync="origin unreachable, so whether it holds newer notes is unknown"
      elif [ -n "$(g rev-list -n 1 'HEAD..@{u}' 2>/dev/null)" ]; then
        die "origin has notes this Mac lacks and a PA runs here (tmux $PA_TMUX). End that session (/exit; pa.on is off, so it is not restarted), then run takeover again. memory.pull stays off."
      else
        sync="up to date with origin"
      fi
    fi
    set_memory push; : > "$N/pa.on"; say "a PA already runs here (tmux attach -t $PA_TMUX), $sync; pa.on and memory push set"; return 0
  fi
  if [ -e "$M/.git" ] && g rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
    if g fetch -q 2>/dev/null; then
      local before; before=$(g rev-parse HEAD 2>/dev/null || true)
      g merge -q --ff-only --no-overwrite-ignore >/dev/null 2>&1 \
        || die "the memory repo cannot fast-forward to origin (local changes or diverged history); resolve in $M, then run takeover again. memory.pull and pa.on stay off; nothing started."
      say "  memory repo up to date with origin"
      # Notes arrived from the other Mac: a conversation recorded here predates them, so start fresh.
      if [ "$before" != "$(g rev-parse HEAD 2>/dev/null || true)" ] && [ -e "$N/pa.session" ]; then
        rm -f "$N/pa.session"; say "  the notes moved on since this Mac last ran the PA: starting a fresh conversation from them"
      fi
    else
      say "  origin unreachable: starting from this Mac's copy (last update: $(g log -1 --format=%cd --date=iso 2>/dev/null || echo unknown))"
    fi
  fi
  set_memory push
  : > "$N/pa.on"
  start_pa
  say "This Mac is now the active PA: pa.on and memory push set, PA started (tmux attach -t $PA_TMUX)."
}

cmd_handback() {
  need_install
  rm -f "$N/pa.on"
  lock_node
  if pa_running; then
    die "pa.on removed, so the node will not restart the PA. End the PA session first (tmux attach -t $PA_TMUX, then /exit), then run handback again."
  fi
  if [ -e "$M/.git" ]; then
    # Publish whatever the switch was (push, or none): a standby must not keep notes origin lacks.
    g rev-parse -q --verify '@{u}' >/dev/null 2>&1 || die "the memory repo in $M has no upstream; nothing to hand back to (megavibe node memory init or clone first)"
    set_memory push
    local cn ce; cn=$(conf_get COMMIT_NAME); ce=$(conf_get COMMIT_EMAIL)
    local st
    st=$(g status --porcelain) || die "git status failed in $M (a stale .git/index.lock?); nothing pushed, memory push stays set"
    if [ -n "$st" ]; then
      g add -A
      g -c user.name="${cn:-megavibe node}" -c user.email="${ce:-megavibe-node@localhost}" -c commit.gpgsign=false commit -q -m "handback: $(date '+%F %T')"
    fi
    g push -q 2>/dev/null || die "push to origin failed; memory push stays set, so the node keeps trying. Run handback again once origin is reachable."
    g fetch -q 2>/dev/null || true
    [ "$(g rev-parse HEAD)" = "$(g rev-parse '@{u}' 2>/dev/null || true)" ] || die "origin does not hold this Mac's last commit; memory push stays set"
    say "  memory pushed to origin"
  fi
  set_memory pull
  # The PA moves on elsewhere from here: the conversation recorded on this Mac must not be resumed later.
  rm -f "$N/pa.session"
  say "Handed back: pa.on removed, memory pull set (this Mac now keeps a standby copy)."
}

# ── The session register ──────────────────────────────────────────────
# The PA starts repo sessions in tmux windows; when the tmux server dies they all die with it and
# nobody is told. `session start` records each one (name, window, folder, task file, started, state,
# conversation id) in $S/<name> and stamps its tmux window with the user option @mv_session=<name>.
# Liveness is that stamp: it goes when the window goes, it cannot survive a server restart (a window
# id or a window name can come back on a different window), and renaming the window does not lose it.
# `session check` lists every session registered as running whose stamp is gone, with its task file.
# A second signal guards the other direction: the record keeps the window's process (pid and start
# time), and a session whose stamp is gone while that very process still lives is "unseen", not
# vanished, and is never resumed (a tmux socket file cleaned out of /tmp while its server runs makes
# tmux report "no server"; resuming then would put a second copy next to every live session).
# SHORTCUT: liveness = "a stamped window exists", as in node.sh. A hung session keeps its window; a
# session started from a shell prompt inside a window (session add) leaves the window open when it
# ends. Upgrade to a heartbeat from the session if either ever bites.
bounded() { perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or exit 127' "$@"; }
tm() { bounded 15 tmux "$@" 9>&-; }
one_line() { case "$2" in *$'\n'*|*$'\r'*) die "$1 must be one line" ;; esac; }
rec_get() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$S/$1" 2>/dev/null || true; }
# rec_put NAME KEY=value...: sets those keys, keeps the others; one atomic replace. The record is
# built in memory and written with ONE write whose failure is seen (a full disk that still lets an empty
# file be created must not pass for a written record), and read back before it replaces the old one.
rec_put() {
  local name="$1" kv line keep text=""; shift
  mkdir -p "$S" || return 1
  for kv in "$@"; do text="$text$kv
"; done
  if [ -f "$S/$name" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      keep=1; for kv in "$@"; do [ "${kv%%=*}" != "${line%%=*}" ] || keep=0; done
      [ "$keep" = 0 ] || text="$text$line
"
    done < "$S/$name"
  fi
  printf '%s' "$text" > "$S/.$name.tmp" || return 1
  [ "$(cat "$S/.$name.tmp" 2>/dev/null; printf x)" = "${text}x" ] || return 1
  mv -f "$S/.$name.tmp" "$S/$name"
}
# From the moment a window is asked for until its record and stamp exist, the command is not
# interruptible: a caller that cancels in between would leave a running session nothing knows about.
hold_signals() { trap '' INT TERM HUP; }
release_signals() { trap - INT TERM HUP; }
need_name() { [[ "${1:-}" =~ $SESSION_RE ]] || die "session: a name is lower-case letters, digits, dot, dash, underscore (at most 63, starting with a letter or digit): '${1:-}'"; }
need_rec() { need_name "${1:-}"; [ -f "$S/$1" ] || die "session: $1 is not registered (megavibe node session list)"; }
# live_stamps: LIVE = the @mv_session stamps of all windows, LIVE_STATE = ok | noserver | unknown.
# Only a listing that worked, or tmux saying no server runs, proves a window is gone; anything else
# (a timeout, a refused socket) is unknown and must never read as "everything vanished".
live_stamps() {
  local rc=0 err
  LIVE=""; LIVE_STATE=ok; LIVE_WHY=""
  command -v tmux >/dev/null 2>&1 || { LIVE_STATE=unknown; LIVE_WHY="tmux not found"; return 0; }
  LIVE=$(tm list-windows -a -F '#{@mv_session}' 2>/dev/null) || rc=$?
  [ "$rc" != 0 ] || return 0
  # Asked again only for its error text (nothing is written anywhere, so a read-only register can be checked).
  err=$(tm list-windows -a -F '#{@mv_session}' 2>&1 >/dev/null | head -n 1 | tr -cd 'A-Za-z0-9 .,:()/_-' | cut -c1-160 || true)
  LIVE=""
  case "$err" in
    *"no server running"*|*"No such file or directory"*|*"Connection refused"*) LIVE_STATE=noserver ;;
    *) LIVE_STATE=unknown; LIVE_WHY="tmux list-windows failed (exit $rc)${err:+: $err}" ;;
  esac
}
alive() { printf '%s\n' "$LIVE" | grep -qxF -- "$1"; }
pid_start() { LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | tr -s ' ' || true; }
# proc_alive NAME: the process recorded for NAME still exists (same pid, same start time).
proc_alive() {
  local pid st
  pid=$(rec_get "$1" pid); st=$(rec_get "$1" pidstart)
  [[ $pid =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ -n "$st" ] && kill -0 "$pid" 2>/dev/null && [ "$(pid_start "$pid")" = "$st" ]
}
node_tmux_session() {
  local ts; ts=$(conf_get TMUX_SESSION)
  [[ $ts =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] && [ "$ts" != "$PA_TMUX" ] || ts=main
  printf '%s' "$ts"
}
# open_window NAME WINDOW DIR ARG...: a new window in the node's tmux session running `megavibe ARG...`
# in DIR, and exactly in DIR (--no-normalize): a conversation is bound to its folder, and a resume must
# land in the folder the record names, not wherever the wrapper would move to. Sets WID and WPID (the
# window's process). The arguments reach megavibe as they are, no shell in between. The caller records WPID first and stamps the window after (stamp_window), so a window
# that could not be stamped is still known by its process and shows as UNSEEN, never as absent.
open_window() {
  local win="$1" dir="$2" ts out; shift 2
  ts=$(node_tmux_session)
  tm has-session -t "=$ts" 2>/dev/null || tm new-session -d -s "$ts" -c "$HOME" -n shell || die "cannot create tmux session $ts"
  out=$(tm new-window -d -P -F '#{window_id} #{pane_pid}' -t "=$ts:" -n "$win" -c "$dir" env MEGAVIBE_HOME="$MH" megavibe --no-normalize "$@") \
    || die "could not open a tmux window in session $ts"
  WID=${out%% *}; WPID=${out##* }
  [[ $WID =~ ^@[0-9]+$ ]] && [[ $WPID =~ ^[0-9]+$ ]] || die "tmux gave no window id for the new window ($out)"
}
stamp_window() {   # stamp_window NAME: after the record holds WID and WPID
  tm set-option -w -t "$WID" @mv_session "$1" \
    || die "window $WID opened for $1 but it closed at once (megavibe not on the tmux server's PATH?) or could not be stamped. If it still runs, 'session check' shows it as UNSEEN; stamp it with: tmux set-option -w -t $WID @mv_session $1"
}
# A record is active while it is running, or starting (a start that did not get as far as its window).
active() { case "$(rec_get "$1" state)" in running|starting) return 0 ;; esac; return 1; }
report_line() { printf 'When you are done, or blocked, report to the session named "%s" with SendMessage: one line on the end state and where the result durably lives.' "$PA_NAME"; }

cmd_session_start() {
  local name="${1:-}" dir="" task="" model="" win="" prompt="" sid
  need_install; need_name "$name"; shift
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "session start: $1 needs a value"
    case "$1" in
      --dir) dir="$2" ;;
      --task) task="$2" ;;
      --model) model="$2" ;;
      --window) win="$2" ;;
      --prompt) prompt="$2" ;;
      *) die "session start: unknown option $1" ;;
    esac
    shift 2
  done
  [ -n "$dir" ] && [ -d "$dir" ] || die "session start: --dir must be an existing folder"
  [ -n "$task" ] && [ -f "$task" ] || die "session start: --task must be an existing file (the brief the session works from)"
  dir=$(cd "$dir" && pwd); task="$(cd "$(dirname "$task")" && pwd)/$(basename "$task")"
  [ -z "$model" ] || [[ $model =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "session start: unusable --model"
  win="${win:-$name}"; [[ $win =~ $SESSION_RE ]] || die "session start: unusable --window name"
  one_line --dir "$dir"; one_line --task "$task"; one_line --prompt "$prompt"
  case "$prompt" in -*) die "session start: --prompt must not start with a dash (it would be read as an option)" ;; esac
  live_stamps
  [ "$LIVE_STATE" != unknown ] || die "cannot tell which sessions run ($LIVE_WHY); nothing started"
  if alive "$name"; then die "session $name already runs in a tmux window; nothing started"; fi
  if active "$name"; then
    die "session $name is registered as $(rec_get "$name" state) but has no window: megavibe node session resume $name, or drop $name"
  fi
  sid=$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z' || true)
  [[ $sid =~ $UUID_RE ]] || die "session start: uuidgen did not give a session id"
  [ -n "$prompt" ] || prompt="Read the task file $task and carry it out fully. $(report_line)"
  # The record is made before the window, so a register that cannot be written starts nothing.
  { mkdir -p "$S" && : > "$S/.$name.new" && mv -f "$S/.$name.new" "$S/$name" && rec_put "$name" "state=starting" "dir=$dir" "task=$task" "sid=$sid" "model=$model"; } 2>/dev/null \
    || die "session start: cannot write the register in $S; nothing started"
  hold_signals
  open_window "$win" "$dir" --name "$name" ${model:+--model "$model"} --session-id "$sid" "$prompt"
  rec_put "$name" "state=running" "window=$WID" "pid=$WPID" "pidstart=$(pid_start "$WPID")" "started=$(date '+%F %T')" \
    || { tm set-option -w -t "$WID" @mv_session "$name" 2>/dev/null || true
         die "session $name runs in window $WID (stamped) but its record could not be completed; fix $S, then: megavibe node session drop $name; megavibe node session add $name --window $WID --task <file>"; }
  stamp_window "$name"
  release_signals
  say "started $name in tmux window $(node_tmux_session):$win ($WID); registered with task $task"
}

cmd_session_add() {
  local name="${1:-}" target="" task="" dir="" sid="" model="" cur
  need_install; need_name "$name"; shift
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "session add: $1 needs a value"
    case "$1" in
      --window) target="$2" ;;
      --task) task="$2" ;;
      --dir) dir="$2" ;;
      --sid) sid="$2" ;;
      --model) model="$2" ;;
      *) die "session add: unknown option $1" ;;
    esac
    shift 2
  done
  [ -n "$target" ] || die "session add: --window names the tmux window it runs in (session:window, or a window id like @7)"
  [ -n "$task" ] && [ -f "$task" ] || die "session add: --task must be an existing file"
  task="$(cd "$(dirname "$task")" && pwd)/$(basename "$task")"
  [ -z "$sid" ] || [[ $sid =~ $UUID_RE ]] || die "session add: --sid is not a session id"
  [ -z "$model" ] || [[ $model =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "session add: unusable --model"
  ! active "$name" || die "session $name is already registered as $(rec_get "$name" state) (megavibe node session drop $name first)"
  # The target is matched against the listing, whole: tmux itself resolves a target it cannot find to
  # some other window (the current one), and the stamp would then land on the wrong session.
  local all
  one_line --window "$target"
  all=$(tm list-windows -a -F '#{window_id} #{session_name}:#{window_name}' 2>/dev/null) || die "session add: tmux could not list windows"
  WID=$(printf '%s\n' "$all" | awk -v t="$target" '{ id = $1; sub(/^[^ ]* /, "") } id == t || $0 == t { print id }')
  [[ $WID =~ ^@[0-9]+$ ]] || die "session add: no tmux window $target, or several with that name (give session:window as tmux lists it, or the window id like @7)"
  # A listing that fails here must stop the command: an unread stamp is not "no stamp".
  all=$(tm list-windows -a -F '#{window_id} #{pane_pid} #{@mv_session}' 2>/dev/null) || die "session add: tmux could not list windows"
  cur=$(printf '%s\n' "$all" | awk -v id="$WID" '$1 == id { print $3 }')
  WPID=$(printf '%s\n' "$all" | awk -v id="$WID" '$1 == id { print $2 }')
  [[ $WPID =~ ^[0-9]+$ ]] || die "session add: window $WID went away"
  [ -z "$cur" ] || [ "$cur" = "$name" ] || die "session add: that window already belongs to session $cur"
  # A window from an earlier registration of this name would keep the name "alive" after this one ends.
  if [ "$cur" != "$name" ] && printf '%s\n' "$all" | awk -v n="$name" '$3 == n { f = 1 } END { exit !f }'; then
    die "session add: another tmux window is still stamped $name (an earlier registration); close it, or clear it with: tmux set-option -w -u -t <window> @mv_session"
  fi
  [ -n "$dir" ] || dir=$(tm list-windows -a -F '#{window_id} #{pane_current_path}' 2>/dev/null | awk -v id="$WID" '$1 == id { sub(/^[^ ]* /, ""); print }' || true)
  [ -n "$dir" ] && [ -d "$dir" ] || die "session add: give --dir (the folder the session runs in)"
  dir=$(cd "$dir" && pwd); one_line --dir "$dir"; one_line --task "$task"
  tm set-option -w -t "$WID" @mv_session "$name" || die "session add: could not stamp window $WID"
  mkdir -p "$S"; : > "$S/.$name.new" && mv -f "$S/.$name.new" "$S/$name"
  rec_put "$name" "state=running" "window=$WID" "pid=$WPID" "pidstart=$(pid_start "$WPID")" "dir=$dir" "task=$task" "started=$(date '+%F %T')" "sid=$sid" "model=$model"
  say "registered $name (window $WID, task $task)"
}

cmd_session_resume() {
  local name="${1:-}" fresh=0 dir task sid model prompt msg
  need_install; need_rec "$name"
  case "${2:-}" in "") ;; --fresh) fresh=1 ;; *) die "session resume: unknown option $2" ;; esac
  [ $# -le 2 ] || die "session resume: too many arguments"
  active "$name" || die "session $name is $(rec_get "$name" state), not running; start it again with: megavibe node session start $name ..."
  # A start that never reached its window has no conversation to resume.
  [ "$(rec_get "$name" state)" != starting ] || fresh=1
  live_stamps
  [ "$LIVE_STATE" != unknown ] || die "cannot tell which sessions run ($LIVE_WHY); nothing started"
  if alive "$name"; then die "session $name still has its tmux window; nothing started"; fi
  if proc_alive "$name"; then
    die "session $name has no tmux window that tmux can see, but its process (pid $(rec_get "$name" pid)) is still alive: a second copy is not started. If it really is gone: megavibe node session drop $name, then start it again"
  fi
  dir=$(rec_get "$name" dir); task=$(rec_get "$name" task); sid=$(rec_get "$name" sid); model=$(rec_get "$name" model)
  [ -d "$dir" ] || die "session $name: its folder $dir is gone"
  [[ $model =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || model=""
  # The register is written before the window is opened: if it cannot be written nothing is started
  # (a resume that launched and then failed to record would be launched again by the next try).
  rec_put "$name" "resumed=$(date '+%F %T')" 2>/dev/null || die "session resume: cannot write the register in $S; nothing started"
  hold_signals
  if [ "$fresh" = 0 ] && [[ $sid =~ $UUID_RE ]]; then
    prompt="Your session ended unexpectedly (a crash or a tmux restart) and was resumed. Check what was in flight (git status, your last steps), then continue your task from $task: do not redo finished steps and do not discard uncommitted work. $(report_line)"
    open_window "$name" "$dir" --name "$name" ${model:+--model "$model"} --resume "$sid" "$prompt"
    msg="resumed $name (conversation $sid) in window $WID; if that window closes at once the conversation is gone: megavibe node session resume $name --fresh"
  else
    sid=$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z' || true)
    [[ $sid =~ $UUID_RE ]] || die "session resume: uuidgen did not give a session id"
    prompt="A previous session working on the task in $task ended unexpectedly (a crash or a tmux restart); you continue its work. Read the task file, then reconstruct where it stood from the evidence (git status and log in this folder, open pull requests, its notes): do not redo finished steps and do not discard uncommitted work. $(report_line)"
    open_window "$name" "$dir" --name "$name" ${model:+--model "$model"} --session-id "$sid" "$prompt"
    msg="started a new conversation for $name in window $WID (the old one was not known, or --fresh was given)"
  fi
  # If the record cannot be completed now, the window is stamped all the same: it then counts as alive,
  # and a retry cannot open a second one next to it.
  rec_put "$name" "state=running" "window=$WID" "pid=$WPID" "pidstart=$(pid_start "$WPID")" "sid=$sid" "resumed=$(date '+%F %T')" \
    || { tm set-option -w -t "$WID" @mv_session "$name" 2>/dev/null || true
         die "session $name runs again in window $WID (stamped) but its record could not be updated; fix $S"; }
  stamp_window "$name"
  release_signals
  say "$msg"
}

cmd_session_mark() {   # cmd_session_mark done|dropped NAME
  need_install; need_rec "${2:-}"
  [ $# -le 2 ] || die "session: too many arguments"
  rec_put "$2" "state=$1" "ended=$(date '+%F %T')"
  say "$2: $1"
}

cmd_session_list() {
  local f n st
  need_install; live_stamps
  [ "$LIVE_STATE" != unknown ] || say "(window state unknown: $LIVE_WHY)"
  for f in "$S"/*; do
    [ -f "$f" ] || continue
    n=${f##*/}; st=$(rec_get "$n" state)
    if active "$n" && [ "$LIVE_STATE" != unknown ] && ! alive "$n"; then
      if proc_alive "$n"; then st=UNSEEN; else st=VANISHED; fi
    fi
    printf '%-9s %-28s started %s  task %s\n' "$st" "$n" "$(rec_get "$n" started)" "$(rec_get "$n" task)"
  done
}

# Exit 0: every session registered as running has its window. 1: at least one vanished (listed with
# its task file). 2: tmux could not say, or a session has no visible window while its process still
# lives; nothing is claimed either way.
cmd_session_check() {
  local f n r run=0 gone=0 out="" unseen=0 uout=""
  [ -d "$S" ] || { say "ok: no sessions registered"; return 0; }
  live_stamps
  for f in "$S"/*; do
    [ -f "$f" ] || continue
    n=${f##*/}; active "$n" || continue
    run=$((run + 1))
    [ "$LIVE_STATE" != unknown ] || continue
    ! alive "$n" || continue
    if proc_alive "$n"; then unseen=$((unseen + 1)); uout="$uout  $n  (pid $(rec_get "$n" pid))
"; continue; fi
    gone=$((gone + 1)); r=$(rec_get "$n" resumed)
    out="$out  $n  (started $(rec_get "$n" started)${r:+, resumed $r})
    task:   $(rec_get "$n" task)
    folder: $(rec_get "$n" dir)
    resume: megavibe node session resume $n      (it reported after all: megavibe node session done $n)
"
  done
  if [ "$LIVE_STATE" = unknown ] && [ "$run" -gt 0 ]; then
    say "UNKNOWN: $run session(s) registered as running, but their windows could not be checked: $LIVE_WHY"; return 2
  fi
  if [ "$gone" -gt 0 ]; then
    r=""; [ "$LIVE_STATE" != noserver ] || r=" (no tmux server is running)"
    say "VANISHED ($gone of $run): registered as running, tmux window gone, never marked done$r"
    printf '%s' "$out"
  fi
  if [ "$unseen" -gt 0 ]; then
    say "UNSEEN ($unseen of $run): no tmux window found, but the session's process is still alive (a tmux socket file removed while its server runs?). Not vanished; do not resume."
    printf '%s' "$uout"
  fi
  [ "$gone" = 0 ] || return 1
  [ "$unseen" = 0 ] || return 2
  say "ok: $run session(s) registered as running, all windows present"
}

sub="${1:-status}"; shift || true
case "$sub" in
  install) cmd_install "$@" ;;
  status) cmd_status ;;
  off) need_install; : > "$N/node.off"; say "node off (node.off): the node starts nothing; running sessions are not stopped" ;;
  on) need_install; rm -f "$N/node.off"; say "node on: the next run (within 5 minutes) starts what is missing" ;;
  pa)
    need_install
    case "${1:-}" in
      on)
        # A PA on a standby would write notes that are never pushed and block the next pull.
        [ -e "$N/memory.pull" ] && die "this Mac keeps a standby copy (memory pull); to run the PA here use: megavibe node takeover"
        : > "$N/pa.on"; say "pa on: the node starts the PA here if it is not running" ;;
      off) rm -f "$N/pa.on"; say "pa off: the node no longer restarts the PA here (a running PA is not stopped)" ;;
      session)
        # The conversation pa-start.sh resumes on the next start. Set it for a PA that was started
        # another way (or after /clear, which begins a new conversation); none: the next start is fresh.
        case "${2:-}" in
          "") cur=$(head -n 1 "$N/pa.session" 2>/dev/null | tr -d '[:space:]' || true)
              if [[ $cur =~ $UUID_RE ]]; then say "$cur"; else say "none (the next PA start is fresh)"; fi ;;
          none) rm -f "$N/pa.session" || die "pa session: could not remove $N/pa.session"; say "pa session: none (the next PA start is fresh)" ;;
          *) [[ $2 =~ $UUID_RE ]] || die "pa session: expected a session id (lower-case UUID) or none"
             { printf '%s\n' "$2" > "$N/pa.session.tmp" && mv -f "$N/pa.session.tmp" "$N/pa.session"; } 2>/dev/null \
               || die "pa session: could not write $N/pa.session; nothing changed"
             say "pa session: the next PA start resumes $2" ;;
        esac ;;
      *) die "pa: expected on, off or session" ;;
    esac ;;
  memory)
    case "${1:-}" in
      init) shift; cmd_memory_init "$@" ;;
      clone) shift; cmd_memory_clone "$@" ;;
      push|pull|none)
        need_install
        if [ "$1" = pull ] && { [ -e "$N/pa.on" ] || pa_running; }; then
          die "this Mac runs the PA (pa.on or a running session); to make it a standby use: megavibe node handback"
        fi
        set_memory "$1"; say "memory $1" ;;
      *) die "memory: expected push, pull, none, init or clone" ;;
    esac ;;
  session)
    ssub="${1:-list}"; shift || true
    case "$ssub" in
      start) cmd_session_start "$@" ;;
      add) cmd_session_add "$@" ;;
      resume) cmd_session_resume "$@" ;;
      done) cmd_session_mark done "$@" ;;
      drop) cmd_session_mark dropped "$@" ;;
      list) [ $# = 0 ] || die "session list: takes no arguments"; cmd_session_list ;;
      check) [ $# = 0 ] || die "session check: takes no arguments"; cmd_session_check ;;
      *) die "session: expected start, add, check, resume, done, drop or list" ;;
    esac ;;
  takeover) cmd_takeover ;;
  handback) cmd_handback ;;
  -h|--help|help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand '$sub' (megavibe node help)" ;;
esac
