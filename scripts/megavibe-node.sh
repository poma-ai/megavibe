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
  for a in node.sh pa-start.sh CLAUDE.md; do
    if cmp -s "$TPL/$a" "$N/$a"; then say "  skip    $a (current)"
    else
      # The copy being replaced (a hand edit, an older version) is kept once as <file>.prev.
      prev=""
      if [ -f "$N/$a" ]; then cp -p "$N/$a" "$N/$a.prev"; prev=" (previous copy: $a.prev)"; fi
      cp "$TPL/$a" "$N/.$a.tmp" && mv -f "$N/.$a.tmp" "$N/$a"; say "  wrote   $a$prev"
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
      g merge -q --ff-only --no-overwrite-ignore >/dev/null 2>&1 \
        || die "the memory repo cannot fast-forward to origin (local changes or diverged history); resolve in $M, then run takeover again. memory.pull and pa.on stay off; nothing started."
      say "  memory repo up to date with origin"
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
  say "Handed back: pa.on removed, memory pull set (this Mac now keeps a standby copy)."
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
      *) die "pa: expected on or off" ;;
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
  takeover) cmd_takeover ;;
  handback) cmd_handback ;;
  -h|--help|help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand '$sub' (megavibe node help)" ;;
esac
