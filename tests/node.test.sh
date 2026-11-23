#!/bin/bash
# /bin/bash tests/node.test.sh
# The opt-in node: template/node/node.sh (the LaunchAgent's watchdog), template/node/pa-start.sh (the one
# PA launcher) and scripts/megavibe-node.sh (`megavibe node ...`). Everything runs against a scratch
# HOME and MEGAVIBE_HOME with stubbed tmux, scutil, launchctl, uname, megavibe, claude and the login
# check; git runs for real on scratch repos (a local bare origin, no network).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/node-test.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }

B="$T/bin"; mkdir -p "$B"
# Stateful tmux: sessions are files in $TMUXSTATE/s, a session's windows are lines in $TMUXSTATE/w.<s>.
# TMUX_FAIL=<verb> makes that verb fail; every call is logged.
cat > "$B/tmux" <<'EOF'
#!/bin/bash
S="$TMUXSTATE"; mkdir -p "$S/s"; printf '%s\n' "$*" >> "$S/calls"
# The locale a real tmux server (and every pane in it) would inherit from this call.
case "$1" in new-session|new-window) printf '%s LC_ALL=%s LANG=%s\n' "$1" "${LC_ALL-unset}" "${LANG-unset}" >> "$S/locale" ;; esac
v="$1"; shift
[ "${TMUX_FAIL:-}" = "$v" ] && exit 1
tgt() { local t="$1"; t="${t#=}"; printf '%s' "${t%%:*}"; }
case "$v" in
  has-session) while [ $# -gt 0 ]; do [ "$1" = -t ] && { [ -e "$S/s/$(tgt "$2")" ]; exit; }; shift; done; exit 1 ;;
  new-session) n=""; w=""; while [ $# -gt 0 ]; do case "$1" in -s) n="$2"; shift ;; -n) w="$2"; shift ;; -c) shift ;; -d) ;; *) break ;; esac; shift; done
    [ -e "$S/s/$n" ] && exit 1; : > "$S/s/$n"; printf '%s\n' "${w:-0}" > "$S/w.$n"; printf '%s\n' "$*" > "$S/cmd.$n" ;;
  new-window) t=""; w=""; while [ $# -gt 0 ]; do case "$1" in -t) t=$(tgt "$2"); shift ;; -n) w="$2"; shift ;; -c) shift ;; -d) ;; *) break ;; esac; shift; done
    printf '%s\n' "$w" >> "$S/w.$t"; printf '%s\n' "$*" > "$S/wcmd.$w" ;;
  list-windows) while [ $# -gt 0 ]; do [ "$1" = -t ] && { cat "$S/w.$(tgt "$2")" 2>/dev/null; exit 0; }; shift; done ;;
  list-sessions) ls "$S/s" ;;
  send-keys) [ "${TMUX_SENDFAIL:-}" = 1 ] && exit 1; printf '%s\n' "$*" >> "$S/keys" ;;
esac
exit 0
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "${HOSTNAME_STUB-testmac}"\n' > "$B/scutil"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/launchctl.calls"\n[ "$1" = print ] && [ -e "%s/loaded" ] && exit 0\n[ "$1" = print ] && exit 113\nexit 0\n' "$T" "$T" > "$B/launchctl"
printf '#!/bin/bash\necho Darwin\n' > "$B/uname"
# megavibe stub: the last call's arguments one per line in megavibe.args, every call as one line in
# megavibe.calls; it stays alive for the seconds in megavibe.sleep when that file exists.
printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s/megavibe.args"\nprintf "%%s\\n" "$*" >> "%s/megavibe.calls"\n[ -e "%s/megavibe.sleep" ] && sleep "$(cat "%s/megavibe.sleep")"\nexit 0\n' "$T" "$T" "$T" "$T" > "$B/megavibe"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/claude.calls"\n' "$T" > "$B/claude"
chmod +x "$B"/*
export PATH="$B:$PATH"

# fresh: a new HOME, MEGAVIBE_HOME and tmux state; the node folder installed from the template.
fresh() {
  H="$T/h$1"; mkdir -p "$H/.megavibe/personal" "$H/.megavibe/scripts"
  export HOME="$H" MEGAVIBE_HOME="$H/.megavibe" TMUXSTATE="$H/tmux" MEGAVIBE_NODE_TEST_BIN="$B"
  N="$MEGAVIBE_HOME/node"; M="$MEGAVIBE_HOME/personal"
  AUTH_RC=0; AUTH_MSG="ok"
  printf '#!/bin/bash\necho "$AUTH_MSG"\nexit "$AUTH_RC"\n' > "$MEGAVIBE_HOME/scripts/claude-auth-check.sh"
  chmod +x "$MEGAVIBE_HOME/scripts/claude-auth-check.sh"
  rm -f "$T/launchctl.calls" "$T/loaded" "$T/megavibe.args" "$T/megavibe.calls" "$T/megavibe.sleep" "$T/claude.calls"
}
ctl() { o=$(bash "$REPO/scripts/megavibe-node.sh" "$@" 2>&1); RC=$?; }
node() { AUTH_RC=$AUTH_RC AUTH_MSG=$AUTH_MSG bash "$N/node.sh"; RC=$?; }
log() { cat "$N/node.log" 2>/dev/null; }
export AUTH_RC AUTH_MSG

# ── install ───────────────────────────────────────────────────────────
fresh 1
ctl install
check "install: exit 0 ($o)" '[ "$RC" = 0 ]'
check "install: node.sh, pa-start.sh, CLAUDE.md, node.conf written" '[ -x "$N/node.sh" ] && [ -x "$N/pa-start.sh" ] && [ -f "$N/CLAUDE.md" ] && [ -f "$N/node.conf" ]'
check "install: plist names the node.sh and MEGAVIBE_HOME" 'grep -q "<string>$N/node.sh</string>" "$H/Library/LaunchAgents/com.megavibe.node.plist" && grep -q "<string>$MEGAVIBE_HOME</string>" "$H/Library/LaunchAgents/com.megavibe.node.plist"'
check "install: plist is valid" '! command -v plutil >/dev/null || plutil -lint -s "$H/Library/LaunchAgents/com.megavibe.node.plist"'
check "install: prints the bootstrap line" '[[ "$o" == *"launchctl bootstrap gui/$(id -u) $H/Library/LaunchAgents/com.megavibe.node.plist"* ]]'
check "install: never runs launchctl bootstrap itself" '! grep -qv "^print " "$T/launchctl.calls"'
check "install: no switch files by default" '[ ! -e "$N/pa.on" ] && [ ! -e "$N/memory.push" ] && [ ! -e "$N/memory.pull" ]'
echo "PA_MODEL=opus" >> "$N/node.conf"
ctl install
check "install twice: all skip, node.conf kept ($o)" '[ "$RC" = 0 ] && [[ "$o" != *wrote* ]] && grep -q "^PA_MODEL=opus" "$N/node.conf"'
touch "$T/loaded"; ctl install
check "install, loaded and unchanged: no launchctl line" '[[ "$o" == *"is loaded"* ]] && [[ "$o" != *"launchctl bootstrap"* ]]'
ctl install --memory bogus
check "install --memory bogus: refused before writing switches" '[ "$RC" = 1 ] && [ ! -e "$N/memory.push" ] && [ ! -e "$N/memory.pull" ]'
ctl install --memory
check "install --memory without a value: refused" '[ "$RC" = 1 ]'
ctl install --pa --memory pull
check "install --pa --memory pull: refused (standby), nothing switched" '[ "$RC" = 1 ] && [ ! -e "$N/pa.on" ] && [ ! -e "$N/memory.pull" ]'
ctl install --pa --memory push
check "install --pa --memory push: switches set" '[ -e "$N/pa.on" ] && [ -e "$N/memory.push" ] && [ ! -e "$N/memory.pull" ]'
ctl install --memory pull
check "install --memory pull with pa.on: refused, nothing switched" '[ "$RC" = 1 ] && [ -e "$N/memory.push" ] && [ ! -e "$N/memory.pull" ]'
ctl memory pull
check "memory pull with pa.on: refused, points to handback" '[ "$RC" = 1 ] && [ -e "$N/memory.push" ] && [[ "$o" == *handback* ]]'
ctl pa off
echo "hand edit" > "$N/CLAUDE.md"; ctl install
check "install over a hand-edited file: previous copy kept as .prev" '[ "$(cat "$N/CLAUDE.md.prev")" = "hand edit" ] && cmp -s "$N/CLAUDE.md" "$REPO/template/node/CLAUDE.md" && [[ "$o" == *"CLAUDE.md.prev"* ]]'
printf '#!/bin/bash\necho Linux\n' > "$T/uname-linux"; chmod +x "$T/uname-linux"
o=$(PATH="$T/lx:$PATH"; mkdir -p "$T/lx"; cp "$T/uname-linux" "$T/lx/uname"; bash "$REPO/scripts/megavibe-node.sh" install 2>&1); RC=$?
check "install off macOS: refused" '[ "$RC" = 1 ] && [[ "$o" == *macOS* ]]'
rm -f "$T/loaded"

# ── switches and status ───────────────────────────────────────────────
ctl memory pull; ctl memory push
check "memory push: pull removed" '[ -e "$N/memory.push" ] && [ ! -e "$N/memory.pull" ]'
ctl memory none
check "memory none: both gone" '[ ! -e "$N/memory.push" ] && [ ! -e "$N/memory.pull" ]'
ctl off; check "off: node.off" '[ -e "$N/node.off" ]'
ctl status; check "status shows OFF" '[[ "$o" == *"node OFF"* ]]'
ctl on; check "on: node.off removed" '[ ! -e "$N/node.off" ]'
ctl pa off; check "pa off" '[ ! -e "$N/pa.on" ]'
ctl memory pull; ctl pa on
check "pa on on a standby: refused, points to takeover" '[ "$RC" = 1 ] && [ ! -e "$N/pa.on" ] && [[ "$o" == *takeover* ]]'
ctl memory none
ctl bogus; check "unknown subcommand: exit 1" '[ "$RC" = 1 ]'
fresh 1b; ctl status
check "status before install: says not installed, exit 0" '[ "$RC" = 0 ] && [[ "$o" == *"not installed"* ]]'
ctl pa on; check "pa on before install: refused" '[ "$RC" = 1 ]'

# ── node.sh ───────────────────────────────────────────────────────────
fresh 2; ctl install
node
check "node: starts the node window with sonnet and NODE-<host>" '[ "$RC" = 0 ] && grep -qx testmac "$TMUXSTATE/w.main" && grep -q -- "megavibe --no-normalize --model sonnet --name NODE-testmac" "$TMUXSTATE/wcmd.testmac"'
check "node: passes MEGAVIBE_HOME to the session" 'grep -q "env MEGAVIBE_HOME=$MEGAVIBE_HOME" "$TMUXSTATE/wcmd.testmac"'
check "node: no PA without pa.on" '[ ! -e "$TMUXSTATE/s/megavibe-personal" ]'
n1=$(grep -c "^new-window" "$TMUXSTATE/calls"); node
check "node: second run starts nothing new" '[ "$(grep -c "^new-window" "$TMUXSTATE/calls")" = "$n1" ]'
printf 'NODE_MODEL=haiku\nTMUX_SESSION=work\nNODE_PREFIX=N_\n' >> "$N/node.conf"; node
check "node.conf: model, session and prefix honoured" 'grep -q -- "--model haiku --name N_testmac" "$TMUXSTATE/wcmd.testmac" && grep -qx testmac "$TMUXSTATE/w.work"'
printf 'TMUX_SESSION=megavibe-personal\n' >> "$N/node.conf"; rm -f "$TMUXSTATE/w.work"; node
check "node.conf: TMUX_SESSION may not be the PA session" 'grep -qx testmac "$TMUXSTATE/w.main" && ! grep -qx testmac "$TMUXSTATE/w.megavibe-personal" 2>/dev/null && log | grep -q "may not be the PA"'
printf 'TMUX_SESSION=work\n' >> "$N/node.conf"
printf 'NODE_MODEL=--dangerously-x\n' >> "$N/node.conf"; rm -f "$TMUXSTATE/w.work"; touch "$TMUXSTATE/s/work"; node
check "node.conf: a value starting with - is refused" 'grep -q -- "--model sonnet" "$TMUXSTATE/wcmd.testmac"'
printf 'NODE_MODEL=x;rm -rf ~\n' >> "$N/node.conf"; rm -f "$TMUXSTATE/w.work"; touch "$TMUXSTATE/s/work"; node
check "node.conf: unusable value falls back and is logged" 'grep -q -- "--model sonnet" "$TMUXSTATE/wcmd.testmac" && log | grep -q "NODE_MODEL has an unusable value"'

fresh 3; ctl install
TMUX_FAIL=list-windows node
check "failed window listing: nothing started, logged" '! grep -q "^new-window" "$TMUXSTATE/calls" && log | grep -q "could not list windows"'
fresh 3b; ctl install; HOSTNAME_STUB='bad name' node
check "unusable host name: exit 1, nothing started" '[ "$RC" = 1 ] && ! grep -q "^new-window" "$TMUXSTATE/calls" 2>/dev/null'
fresh 3c; ctl install; touch "$N/node.off"; node
check "node.off: nothing at all" '[ "$RC" = 0 ] && [ ! -e "$TMUXSTATE/calls" ]'

# the Codex usage probe: run by the node on a PA Mac only, at most every 30 minutes
fresh 4p; ctl install
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/probe.calls"\n' "$T" > "$MEGAVIBE_HOME/scripts/usage-probe.sh"; chmod +x "$MEGAVIBE_HOME/scripts/usage-probe.sh"
node
check "node without pa.on: the usage probe is not run" '[ ! -e "$T/probe.calls" ]'
touch "$N/pa.on"; node
check "node with pa.on: the usage probe runs with --every 30" '[ "$(cat "$T/probe.calls" 2>/dev/null)" = "run --every 30" ]'
printf '#!/bin/bash\nprintf "%%s|%%s|%%s\\n" "$*" "${MEGAVIBE_PROBE_MODEL:-}" "${CODEX_HOME:-}" >> "%s/probe.calls"\n' "$T" > "$MEGAVIBE_HOME/scripts/usage-probe.sh"
rm -f "$T/probe.calls"; printf 'PROBE_MODEL=my-model\nPROBE_CODEX_HOME=/tmp/some codex\n' >> "$N/node.conf"; node
check "node with pa.on: probe model and Codex home from node.conf reach the probe" '[ "$(cat "$T/probe.calls" 2>/dev/null)" = "run --every 30|my-model|/tmp/some codex" ]'

# PA secrets sync: run by the node on a PA Mac that has the secrets tool; failure logged without its text
fresh 4s; ctl install
mkdir -p "$HOME/.local/bin"; printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/secret.calls"\n' "$T" > "$HOME/.local/bin/secret"; chmod +x "$HOME/.local/bin/secret"
node
check "node without pa.on: secret sync is not run" '[ ! -e "$T/secret.calls" ]'
touch "$N/pa.on"; node
check "node with pa.on: secret sync runs on every run" '[ "$(cat "$T/secret.calls" 2>/dev/null)" = "sync" ]'
printf '#!/bin/bash\necho SECRETVALUE; exit 3\n' > "$HOME/.local/bin/secret"
node
check "failed secret sync: logged without its output" 'log | grep -q "secret sync failed" && ! log | grep -q SECRETVALUE && [ ! -e "$N/secret-sync.log" ]'
mv "$HOME/.local/bin/secret" "$HOME/.local/bin/secret.off"; node
check "no secrets tool: nothing happens, exit 0" '[ "$RC" = 0 ] && [ "$(cat "$T/secret.calls")" = "sync" ]'

fresh 4; ctl install
for i in 1 2 3 4; do rm -f "$TMUXSTATE/w.main"; mkdir -p "$TMUXSTATE/s"; touch "$TMUXSTATE/s/main"; node; done
check "start cap: 3 node starts per hour" '[ "$(grep -c "^new-window" "$TMUXSTATE/calls")" = 3 ] && log | grep -q "3 starts in the last hour"'

fresh 5; ctl install --pa
node
check "node: what it starts in tmux gets a UTF-8 locale, never LC_ALL=C ($(tr '\n' ';' < "$TMUXSTATE/locale"))" '[ "$(grep -c "LC_ALL=unset LANG=en_US.UTF-8$" "$TMUXSTATE/locale")" = 3 ] && [ "$(wc -l < "$TMUXSTATE/locale" | tr -d " ")" = 3 ]'
( export LC_ALL=C; node ); rm -f "$TMUXSTATE/w.main" "$TMUXSTATE/s/megavibe-personal"; : > "$TMUXSTATE/locale"; ( export LC_ALL=C; AUTH_RC=$AUTH_RC AUTH_MSG=$AUTH_MSG bash "$N/node.sh" )
check "node: an inherited LC_ALL=C is not passed on either ($(tr '\n' ';' < "$TMUXSTATE/locale"))" '[ -s "$TMUXSTATE/locale" ] && ! grep -q "LC_ALL=C" "$TMUXSTATE/locale"'
check "pa.on: PA started in megavibe-personal through pa-start.sh" '[ -e "$TMUXSTATE/s/megavibe-personal" ] && grep -q "$N/pa-start.sh" "$TMUXSTATE/cmd.megavibe-personal"'
fresh 5b; ctl install --pa; chmod -x "$N/pa-start.sh"; node
check "pa.on, launcher not executable: logged, not started" '[ ! -e "$TMUXSTATE/s/megavibe-personal" ] && log | grep -q "pa-start.sh is missing or not executable"'
fresh 5c; ctl install --pa; TMUX_FAIL=list-sessions node
check "session listing failed: PA not started, logged" '[ ! -e "$TMUXSTATE/s/megavibe-personal" ] && log | grep -q "could not list sessions"'

fresh 6; ctl install; node
AUTH_RC=1 AUTH_MSG='REFRESH TOKEN EXPIRES INSIDE 168 h; $(evil)' node
check "login warning: typed once, sanitised, generic wording" 'grep -q "Claude login warning on testmac: REFRESH TOKEN EXPIRES INSIDE 168 h" "$TMUXSTATE/keys" && ! grep -q "\\$" "$TMUXSTATE/keys" && grep -q "so the user can renew" "$TMUXSTATE/keys"'
k=$(wc -l < "$TMUXSTATE/keys"); AUTH_RC=1 node
check "login warning: not repeated within a day" '[ "$(wc -l < "$TMUXSTATE/keys")" = "$k" ]'
fresh 6b; ctl install; node; AUTH_RC=1 TMUX_SENDFAIL=1 node
check "login warning not delivered: retried next run" '[ ! -e "$N/.login-warned" ] && log | grep -q "could not be typed"'
AUTH_RC=1 node; check "login warning: delivered on the retry" '[ -e "$N/.login-warned" ]'
fresh 6c; ctl install; AUTH_RC=7 node
check "login lifetime unknown: logged once" 'log | grep -q "could not tell the login lifetime (exit 7)"'

# ── memory: init, push, clone, pull, takeover, handback (real git) ───
fresh 7; ctl install
mkdir -p "$M/.agent/events" "$M/megavibe-deliverables" "$M/.agent/LOGS"
echo note > "$M/.agent/events/e1.md"; echo x > "$M/.agent/LOGS/scratch.log"; echo secret-ish > "$M/random.txt"
printf 'token: "%s"\n' "ghp_EXAMPLEexampleEXAMPLEexample01234567" > "$M/megavibe-deliverables/leak.md"   # EXAMPLE: leak-scan placeholder
ctl memory init
check "memory init: secret refused, nothing committed, file:line only ($o)" '[ "$RC" = 1 ] && [[ "$o" == *"leak.md:1"* ]] && [[ "$o" != *ghp_* ]] && [ ! -d "$M/.git" ]'
rm "$M/megavibe-deliverables/leak.md"
printf 'caf\351 %s\n' "AKIAEXAMPLEEXAMPLE12" > "$M/megavibe-deliverables/latin1.md"   # EXAMPLE: leak-scan placeholder
ctl memory init
check "memory init: a non-UTF-8 file is scanned, not skipped ($o)" '[ "$RC" = 1 ] && [[ "$o" == *"latin1.md:1"* ]] && [ ! -d "$M/.git" ]'
rm "$M/megavibe-deliverables/latin1.md"
printf 'ACCESS_TOKEN=%s\n' "EXAMPLEexampleEXAMPLEexample0123" > "$M/megavibe-deliverables/env.md"   # EXAMPLE: leak-scan placeholder
ctl memory init
check "memory init: an upper-case token assignment is refused" '[ "$RC" = 1 ] && [[ "$o" == *"env.md:1"* ]] && [ ! -d "$M/.git" ]'
rm "$M/megavibe-deliverables/env.md"
printf '# caf\351\n.DS_Store\ntools/.env\nmegavibe-deliverables\n/megavibe-deliverables/*\nmegavibe-deliverables/drafts/\n' > "$M/.gitignore"; echo handoff > "$M/megavibe-deliverables/handoff.md"; mkdir -p "$M/megavibe-deliverables/drafts"; echo private > "$M/megavibe-deliverables/drafts/d.md"; mkdir -p "$M/tools"; echo "DATABASE_PASSWORD=fixture" > "$M/tools/.env"; echo ok > "$M/tools/run.sh"
ctl memory init
check "memory init: a .gitignore that is not an allow-list becomes the allow-list plus its own rules" 'LC_ALL=C grep -aqx .DS_Store "$M/.gitignore.prev" && grep -qx "/\*" "$M/.gitignore" && LC_ALL=C grep -aqx "tools/.env" "$M/.gitignore"'
check "memory init: what the old .gitignore excluded is not committed" '! git -C "$M" ls-files | grep -q "tools/.env" && git -C "$M" ls-files | grep -q tools/run.sh'
check "memory init: megavibe's own deliverables rule is not carried over (deliverables committed)" 'git -C "$M" ls-files | grep -q megavibe-deliverables/handoff.md && ! grep -aq "^Binary" "$M/.gitignore" && ! git -C "$M" ls-files | grep -q drafts/d.md'
cp "$M/.gitignore" "$T/gi.keep"; echo megavibe-deliverables >> "$M/.gitignore"; ctl status
check "status warns when an allow-list ignores the deliverables" '[[ "$o" == *"WARNING: megavibe-deliverables/ is ignored"* ]]'
cp "$T/gi.keep" "$M/.gitignore"
O="$MEGAVIBE_HOME/personal-memory.git"
check "memory init: bare origin, first commit pushed, memory.push ($o)" '[ "$RC" = 0 ] && [ "$(git -C "$O" rev-parse --is-bare-repository)" = true ] && [ "$(git -C "$M" rev-parse HEAD)" = "$(git -C "$O" rev-parse main)" ] && [ -e "$N/memory.push" ]'
check "memory init: allow-list keeps LOGS and stray files out" '! git -C "$M" ls-files | grep -q -e LOGS -e random.txt && git -C "$M" ls-files | grep -q events/e1.md'
ctl memory init; check "memory init again: idempotent" '[ "$RC" = 0 ] && [[ "$o" == *"already set up"* ]]'
echo note2 > "$M/.agent/events/e2.md"; node
check "node memory.push: commits and pushes" '[ "$(git -C "$O" rev-parse main)" = "$(git -C "$M" rev-parse HEAD)" ] && git -C "$O" ls-tree -r main --name-only | grep -q e2.md'
mv "$M/.git/index" "$M/.git/index.bak"; echo garbage > "$M/.git/index"; echo n3 > "$M/.agent/events/e3.md"; node
check "git status fails: nothing committed, logged" 'log | grep -q "git status failed"'
mv -f "$M/.git/index.bak" "$M/.git/index"
STUDIO_HOME=$H; STUDIO_M=$M; STUDIO_N=$N
# An init that stopped after adding the origin (push failed) is finished by running init again.
fresh 7b; ctl install; mkdir -p "$M/.agent/events"; echo a > "$M/.agent/events/a.md"
git -C "$M" init -q; git -C "$M" symbolic-ref HEAD refs/heads/main; cp "$REPO/template/node/memory.gitignore" "$M/.gitignore"
git -C "$M" add -A; git -C "$M" -c user.name=t -c user.email=t@t commit -qm first; git init -q --bare "$MEGAVIBE_HOME/personal-memory.git"; git -C "$M" remote add origin "$MEGAVIBE_HOME/personal-memory.git"
ctl memory init
check "memory init after a stopped push: finishes the push ($o)" '[ "$RC" = 0 ] && git -C "$M" rev-parse "@{u}" >/dev/null 2>&1 && [ -e "$N/memory.push" ]'
# A first commit that fails (here a pre-commit hook in the user's global hooks path) leaves no half-made
# repo, so the retry works; and commit.gpgsign=true from the user's config does not break the commits.
fresh 7c; ctl install; mkdir -p "$M/.agent/events"; echo a > "$M/.agent/events/a.md"
mkdir -p "$T/failhooks"; printf '#!/bin/sh\nexit 1\n' > "$T/failhooks/pre-commit"; chmod +x "$T/failhooks/pre-commit"
git config --file "$H/.gitconfig" core.hooksPath "$T/failhooks"; ctl memory init
check "memory init: a failed first commit leaves no half-made repo ($o)" '[ "$RC" != 0 ] && [ ! -e "$M/.git" ]'
git config --file "$H/.gitconfig" --unset core.hooksPath; git config --file "$H/.gitconfig" commit.gpgsign true; git config --file "$H/.gitconfig" gpg.program /usr/bin/false
ctl memory init
check "memory init: retry works, and commit.gpgsign=true does not break it ($o)" '[ "$RC" = 0 ] && git -C "$M" rev-parse "@{u}" >/dev/null 2>&1'
echo b > "$M/.agent/events/b.md"; node
check "node: automatic commit works with commit.gpgsign=true" 'git -C "$MEGAVIBE_HOME/personal-memory.git" ls-tree -r main --name-only | grep -q events/b.md'
H="$STUDIO_HOME"; export HOME="$H" MEGAVIBE_HOME="$H/.megavibe" TMUXSTATE="$H/tmux"; N="$STUDIO_N"; M="$STUDIO_M"

fresh 8; ctl install
mkdir -p "$M/.agent/events"; echo mine > "$M/.agent/events/e1.md"; echo only-here > "$M/local.txt"
ctl memory clone "$O"
check "clone: exit 0, differing file reported and backed up ($o)" '[ "$RC" = 0 ] && [[ "$o" == *".agent/events/e1.md"* ]] && [ "$(cat "$N"/memory-backup-*/.agent/events/e1.md)" = mine ]'
check "clone: files now match origin, untracked kept, upstream set, memory.pull" '[ "$(cat "$M/.agent/events/e1.md")" = note ] && [ -f "$M/local.txt" ] && git -C "$M" rev-parse "@{u}" >/dev/null && [ -e "$N/memory.pull" ]'
fresh 8d; ctl install; ctl memory clone "$T/no-such-origin.git"
check "clone that fails after init: half-made repo removed, retry possible" '[ "$RC" = 1 ] && [ ! -d "$M/.git" ] && [ ! -e "$N/memory.pull" ]'
ctl memory clone "$O"; check "clone retried after a failure: works" '[ "$RC" = 0 ] && [ -e "$N/memory.pull" ]'
H8="$T/h8"; export HOME="$H8" MEGAVIBE_HOME="$H8/.megavibe" TMUXSTATE="$H8/tmux"; N="$MEGAVIBE_HOME/node"; M="$MEGAVIBE_HOME/personal"
# A local directory (or file) standing where origin tracks a file (or a directory): backed up, not deleted.
fresh 8e; ctl install
mkdir -p "$M/.agent/events/e1.md" "$M/.agent"; echo irreplaceable > "$M/.agent/events/e1.md/local.md"
ctl memory clone "$O"
check "clone: a local directory in the way of a tracked file is backed up ($o)" '[ "$RC" = 0 ] && [ "$(cat "$N"/memory-backup-*/.agent/events/e1.md/local.md)" = irreplaceable ] && [ "$(cat "$M/.agent/events/e1.md")" = note ]'
fresh 8f; ctl install
mkdir -p "$M/.agent"; echo blocker > "$M/.agent/events"
ctl memory clone "$O"
check "clone: a local file where origin has a directory is backed up ($o)" '[ "$(cat "$N"/memory-backup-*/.agent/events 2>/dev/null)" = blocker ]'
H8="$T/h8"; export HOME="$H8" MEGAVIBE_HOME="$H8/.megavibe" TMUXSTATE="$H8/tmux"; N="$MEGAVIBE_HOME/node"; M="$MEGAVIBE_HOME/personal"
ctl memory clone /elsewhere.git; check "clone onto another origin: refused" '[ "$RC" = 1 ]'
fresh 8b; ctl install --pa; ctl memory clone "$O"
check "clone with pa.on: refused, nothing written" '[ "$RC" = 1 ] && [ ! -d "$M/.git" ]'
fresh 8c; ctl install; touch "$TMUXSTATE/s/megavibe-personal" 2>/dev/null || { mkdir -p "$TMUXSTATE/s"; touch "$TMUXSTATE/s/megavibe-personal"; }
ctl memory clone "$O"; check "clone while a PA runs: refused" '[ "$RC" = 1 ] && [ ! -d "$M/.git" ]'

# standby pulls: from fresh 8's copy
H8="$T/h8"; export HOME="$H8" MEGAVIBE_HOME="$H8/.megavibe" TMUXSTATE="$H8/tmux"; N="$MEGAVIBE_HOME/node"; M="$MEGAVIBE_HOME/personal"
( cd "$STUDIO_M" && echo n4 > .agent/events/e4.md && git add -A && git -c user.name=t -c user.email=t@t commit -qm e4 && git push -q )
mkdir -p "$TMUXSTATE/s"; touch "$TMUXSTATE/s/megavibe-personal"; node
check "pull skipped while a PA runs" '[ ! -f "$M/.agent/events/e4.md" ] && log | grep -q "not pulling while a PA runs"'
rm -f "$TMUXSTATE/s/megavibe-personal"; touch "$N/pa.on"; rm -f "$N"/.once-*; node
check "pull skipped while pa.on is set" '[ ! -f "$M/.agent/events/e4.md" ]'
rm -f "$N/pa.on" "$TMUXSTATE/s/megavibe-personal"; node
check "pull: fast-forwards on a pure standby" '[ -f "$M/.agent/events/e4.md" ]'
# An ignored local file that an incoming commit tracks: the update stops, the file stays.
mkdir -p "$M/.agent/LOGS"; echo local-only > "$M/.agent/LOGS/keep.log"
( cd "$STUDIO_M" && mkdir -p .agent/LOGS && echo theirs > .agent/LOGS/keep.log && git add -f .agent/LOGS/keep.log && git -c user.name=t -c user.email=t@t commit -qm forced && git push -q )
rm -f "$N"/.once-*; node
check "pull: ignored local file is not overwritten" '[ "$(cat "$M/.agent/LOGS/keep.log")" = local-only ] && log | grep -q "memory: update failed"'
rm -f "$M/.agent/LOGS/keep.log"; rm -f "$N"/.once-*; node   # catch up for the takeover below

# takeover / handback on the standby
touch "$N/memory.pull"
( cd "$STUDIO_M" && echo n5 > .agent/events/e5.md && git add -A && git -c user.name=t -c user.email=t@t commit -qm e5 && git push -q )
ctl takeover
check "takeover: memory.pull gone, memory.push and pa.on set, PA started ($o)" '[ "$RC" = 0 ] && [ ! -e "$N/memory.pull" ] && [ -e "$N/memory.push" ] && [ -e "$N/pa.on" ] && [ -e "$TMUXSTATE/s/megavibe-personal" ]'
check "takeover: fast-forwarded to origin before starting" '[ -f "$M/.agent/events/e5.md" ]'
( cd "$STUDIO_M" && git pull -q --ff-only && echo n5b > .agent/events/e5b.md && git add -A && git -c user.name=t -c user.email=t@t commit -qm e5b && git push -q )
ctl takeover
check "takeover with a running PA behind origin: refused, asks to end it" '[ "$RC" = 1 ] && [[ "$o" == *"/exit"* ]] && [ ! -f "$M/.agent/events/e5b.md" ]'
rm -f "$TMUXSTATE/s/megavibe-personal"; ctl takeover
check "takeover after the PA ended: fast-forwards and starts it" '[ "$RC" = 0 ] && [ -f "$M/.agent/events/e5b.md" ] && [ -e "$TMUXSTATE/s/megavibe-personal" ]'
ctl handback
check "handback while the PA runs: refused, pa.on removed, still push" '[ "$RC" = 1 ] && [ ! -e "$N/pa.on" ] && [ -e "$N/memory.push" ] && [[ "$o" == *"/exit"* ]]'
rm -f "$TMUXSTATE/s/megavibe-personal"; echo standby-note > "$M/.agent/events/s1.md"
mv "$M/.git/index" "$M/.git/index.good"; echo garbage > "$M/.git/index"; ctl handback
check "handback with a failing git status: refused, nothing switched ($o)" '[ "$RC" = 1 ] && [ -e "$N/memory.push" ] && [ ! -e "$N/memory.pull" ]'
mv -f "$M/.git/index.good" "$M/.git/index"
ctl handback
check "handback: pushed, then memory.pull ($o)" '[ "$RC" = 0 ] && git -C "$O" ls-tree -r main --name-only | grep -q s1.md && [ -e "$N/memory.pull" ] && [ ! -e "$N/memory.push" ]'
# handback publishes even when the switch was none
ctl memory none; echo unpublished > "$M/.agent/events/u1.md"; ctl handback
check "handback with memory none: still commits and pushes" '[ "$RC" = 0 ] && git -C "$O" ls-tree -r main --name-only | grep -q u1.md && [ -e "$N/memory.pull" ]'
# diverged: origin moves while this copy has its own commit
( cd "$STUDIO_M" && git pull -q --ff-only && echo n6 > .agent/events/e6.md && git add -A && git -c user.name=t -c user.email=t@t commit -qm e6 && git push -q )
( cd "$M" && echo l > .agent/events/l1.md && git add -A && git -c user.name=t -c user.email=t@t commit -qm l1 )
ctl takeover
check "takeover on diverged history: refused, nothing started, memory.pull stays off" '[ "$RC" = 1 ] && [ ! -e "$TMUXSTATE/s/megavibe-personal" ] && [ ! -e "$N/memory.pull" ] && [ ! -e "$N/pa.on" ]'
touch "$N/pa.on"; ctl takeover
check "takeover refused on a Mac that still had pa.on: pa.on disarmed" '[ "$RC" = 1 ] && [ ! -e "$N/pa.on" ]'
node; check "  and the node does not start a PA afterwards" '[ ! -e "$TMUXSTATE/s/megavibe-personal" ]'
git -C "$M" remote set-url origin "$T/nowhere.git"; git -C "$M" reset -q --hard HEAD~1
ctl takeover
check "takeover with origin unreachable: starts from the local copy" '[ "$RC" = 0 ] && [[ "$o" == *"origin unreachable"* ]] && [ -e "$TMUXSTATE/s/megavibe-personal" ]'
ctl takeover
check "takeover, PA running, origin unreachable: says it could not check, not up to date" '[ "$RC" = 0 ] && [[ "$o" == *"is unknown"* ]] && [[ "$o" != *"up to date"* ]]'

# ── pa-start.sh: the one launcher ────────────────────────────────────
fresh 9; ctl install
bash "$N/pa-start.sh"
check "pa-start: no PA_MODEL -> no --model, named, rebuild prompt" '! grep -qx -- --model "$T/megavibe.args" && grep -qx "Personal Assistant" "$T/megavibe.args" && grep -q "/rehydrate" "$T/megavibe.args" && grep -qx -- --no-normalize "$T/megavibe.args"'
check "pa-start: the prompt addresses the user generically" 'grep -q "tell the user" "$T/megavibe.args"'
check "pa-start: trust preflight once when not yet trusted" 'grep -q "echo ok" "$T/claude.calls"'
echo "PA_MODEL=opus" >> "$N/node.conf"; printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}' "$(cd "$M" && pwd)" > "$H/.claude.json"; rm -f "$T/claude.calls"
bash "$N/pa-start.sh"
check "pa-start: PA_MODEL=opus -> --model opus; trusted -> no preflight" 'grep -qx opus "$T/megavibe.args" && [ ! -e "$T/claude.calls" ]'
echo 'PA_MODEL=$(x)' >> "$N/node.conf"; bash "$N/pa-start.sh"
check "pa-start: unusable PA_MODEL ignored and logged" '! grep -qx -- --model "$T/megavibe.args" && log | grep -q "PA_MODEL has an unusable value"'

# ── pa-start.sh: recorded session, resume, fixed name, no second PA ──
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
export MEGAVIBE_NODE_TEST_RESUME_SECS=1
fresh 9b; ctl install
bash "$N/pa-start.sh"
SID1=$(cat "$N/pa.session" 2>/dev/null)
check "pa-start fresh: a session id is chosen, recorded in pa.session and passed as --session-id ($SID1)" '[[ "$SID1" =~ ^$UUID_RE$ ]] && grep -qx -- --session-id "$T/megavibe.args" && grep -qx -- "$SID1" "$T/megavibe.args" && ! grep -qx -- --resume "$T/megavibe.args"'
echo 2 > "$T/megavibe.sleep"; : > "$T/megavibe.calls"
bash "$N/pa-start.sh"
check "pa-start with pa.session: resumes that id under the fixed name, once, no fresh start" '[ "$(wc -l < "$T/megavibe.calls" | tr -d " ")" = 1 ] && grep -qx -- --resume "$T/megavibe.args" && grep -qx -- "$SID1" "$T/megavibe.args" && grep -qx "Personal Assistant" "$T/megavibe.args" && ! grep -qx -- --session-id "$T/megavibe.args" && grep -qx -- --no-normalize "$T/megavibe.args"'
check "pa-start resume: the prompt says it was resumed and points at the session check" 'grep -q "resumed" "$T/megavibe.args" && grep -q "megavibe node session check" "$T/megavibe.args" && ! grep -q "/rehydrate" "$T/megavibe.args"'
check "pa-start resume: pa.session unchanged" '[ "$(cat "$N/pa.session")" = "$SID1" ]'
echo "PA_MODEL=opus" >> "$N/node.conf"; bash "$N/pa-start.sh"
check "pa-start resume: PA_MODEL still passed" 'grep -qx opus "$T/megavibe.args" && grep -qx -- --resume "$T/megavibe.args"'
: > "$T/megavibe.calls"; echo 0 > "$T/megavibe.sleep"
bash "$N/pa-start.sh"
SID2=$(cat "$N/pa.session" 2>/dev/null)
check "pa-start: a resume that ends at once falls back to a fresh start with a new id" '[ "$(wc -l < "$T/megavibe.calls" | tr -d " ")" = 2 ] && sed -n 1p "$T/megavibe.calls" | grep -q -- "--resume $SID1" && sed -n 2p "$T/megavibe.calls" | grep -q -- "--session-id $SID2" && [[ "$SID2" =~ ^$UUID_RE$ ]] && [ "$SID2" != "$SID1" ]'
bash "$N/pa-start.sh"
check "pa-start: a second failed resume keeps both ids" '[ "$(sed -n 1p "$N/pa.session.failed")" = "$SID1" ] && [ "$(sed -n 2p "$N/pa.session.failed")" = "$SID2" ] && [ "$(wc -l < "$N/pa.session.failed" | tr -d " ")" = 2 ]'
SID2=$(cat "$N/pa.session")
check "pa-start: the id that could not be resumed is kept aside and logged" '[ "$(sed -n 1p "$N/pa.session.failed" 2>/dev/null)" = "$SID1" ] && log | grep -q "could not be resumed"'
printf 'not-a-uuid; touch %s/pwned\n' "$T" > "$N/pa.session"; : > "$T/megavibe.calls"; bash "$N/pa-start.sh"
check "pa-start: an unusable pa.session is never passed on; fresh start" '[ "$(wc -l < "$T/megavibe.calls" | tr -d " ")" = 1 ] && ! grep -q "pwned" "$T/megavibe.calls" && [ ! -e "$T/pwned" ] && grep -qx -- --session-id "$T/megavibe.args"'
# Without a node folder (plain `megavibe assistant`, no node installed) nothing changes: no id, no file.
fresh 9c
bash "$REPO/template/node/pa-start.sh"
check "pa-start without a node folder: fresh start as before, no --session-id, nothing written" 'grep -qx "Personal Assistant" "$T/megavibe.args" && grep -q "/rehydrate" "$T/megavibe.args" && ! grep -qx -- --session-id "$T/megavibe.args" && [ ! -e "$MEGAVIBE_HOME/node" ]'
# A PA that already runs from the personal folder (the wrapper's session lock names a live claude
# process whose working directory is that folder): no second one, by either route.
fresh 9d; ctl install --pa
mkdir -p "$M/.agent/.session-lock.d"
( cd "$M" && exec -a claude-live sleep 300 ) & LIVE=$!
printf '{"pid": %s, "session_id": "x"}\n' "$LIVE" > "$M/.agent/.session-lock.d/metadata.json"
sleep 1
bash "$N/pa-start.sh" --running; check "pa-start --running: exit 0 while the lock names a live PA process" '[ "$?" = 0 ]'
bash "$N/pa-start.sh"
check "pa-start: does not start a second PA while one runs" '[ ! -e "$T/megavibe.calls" ] && log | grep -q "already runs"'
node
check "node: pa.on, PA running outside its tmux session: not started, logged, not counted as a start" '[ ! -e "$TMUXSTATE/s/megavibe-personal" ] && log | grep -q "already runs outside" && [ ! -e "$N/.starts-pa" ]'
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
bash "$N/pa-start.sh" --running; check "pa-start --running: exit 1 once that process is gone (stale lock)" '[ "$?" = 1 ]'
( cd "$T" && exec -a claude-live sleep 300 ) & LIVE=$!
printf '{"pid": %s}\n' "$LIVE" > "$M/.agent/.session-lock.d/metadata.json"; sleep 1
bash "$N/pa-start.sh" --running; check "pa-start --running: a live process in another folder (pid reuse) is not a PA" '[ "$?" = 1 ]'
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
printf '{"pid": %s}\n' "$$" > "$M/.agent/.session-lock.d/metadata.json"
bash "$N/pa-start.sh" --running; check "pa-start --running: a live process that is not claude is not a PA" '[ "$?" = 1 ]'
node
check "node: stale lock: the PA is started" '[ -e "$TMUXSTATE/s/megavibe-personal" ] && [ -s "$N/.starts-pa" ]'
# Without a node folder the launcher does not judge the lock: the wrapper's own handling applies, as before.
fresh 9f; mkdir -p "$M/.agent/.session-lock.d"
( cd "$M" && exec -a claude-live sleep 300 ) & LIVE=$!
printf '{"pid": %s}\n' "$LIVE" > "$M/.agent/.session-lock.d/metadata.json"; sleep 1
bash "$REPO/template/node/pa-start.sh"
check "pa-start without a node folder, live lock: megavibe is still called (unchanged behaviour)" '[ "$(wc -l < "$T/megavibe.calls" | tr -d " ")" = 1 ]'
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
# megavibe node pa session: show, set, clear
fresh 9e; ctl install
ctl pa session; check "pa session: none recorded ($o)" '[ "$RC" = 0 ] && [[ "$o" == *none* ]]'
ctl pa session 11111111-2222-4333-8444-555555555555
check "pa session <id>: recorded" '[ "$RC" = 0 ] && [ "$(cat "$N/pa.session")" = 11111111-2222-4333-8444-555555555555 ]'
ctl pa session 'x; y'; check "pa session <junk>: refused, file unchanged" '[ "$RC" = 1 ] && [ "$(cat "$N/pa.session")" = 11111111-2222-4333-8444-555555555555 ]'
ctl status; check "status shows the recorded PA conversation" '[[ "$o" == *11111111-2222-4333-8444-555555555555* ]]'
chmod 500 "$N"; ctl pa session 99999999-2222-4333-8444-555555555555; chmod 700 "$N"
check "pa session <id> with an unwritable node folder: fails, says so, old id kept ($o)" '[ "$RC" = 1 ] && [ "$(cat "$N/pa.session")" = 11111111-2222-4333-8444-555555555555 ]'
ctl pa session none; check "pa session none: cleared" '[ "$RC" = 0 ] && [ ! -e "$N/pa.session" ]'
unset MEGAVIBE_NODE_TEST_RESUME_SECS

# pa-start.sh keeps the inherited PATH (a claude under nvm or an npm prefix), standard dirs only appended.
mkdir -p "$T/custom-bin"; printf '#!/bin/bash\necho custom\n' > "$T/custom-bin/only-here"; chmod +x "$T/custom-bin/only-here"
o=$(PATH="$T/custom-bin:$PATH" bash -c 'source <(sed -n "/^export PATH=/p" "$0"); command -v only-here' "$REPO/template/node/pa-start.sh" 2>&1)
check "pa-start: inherited PATH entries stay reachable ($o)" '[[ "$o" == "$T/custom-bin/only-here" ]]'
# ── the wrapper: megavibe assistant and megavibe node use the same launcher ──
# init.sh (run by the wrapper on every PA start) leaves the memory repo's allow-list .gitignore alone.
fresh 10; mkdir -p "$M/megavibe-deliverables"; cp "$REPO/template/node/memory.gitignore" "$M/.gitignore"; git -C "$M" init -q
bash "$REPO/init.sh" "$M" > "$T/init.log" 2>&1
check "init.sh: memory allow-list keeps deliverables tracked, private files still ignored" '! git -C "$M" check-ignore -q megavibe-deliverables/new.md && git -C "$M" check-ignore -q CLAUDE.local.md'
bash "$REPO/init.sh" "$M" > "$T/init2.log" 2>&1
check "init.sh: allow-list exception is idempotent" '! git -C "$M" check-ignore -q megavibe-deliverables/new.md && [ "$(grep -cx megavibe-deliverables "$M/.gitignore")" = 0 ]'
# An ordinary project with an allow-list but no deliverables negation keeps every protection.
P="$T/plainproj"; mkdir -p "$P/src"; git -C "$P" init -q; printf '/*\n!/src/\n' > "$P/.gitignore"
bash "$REPO/init.sh" "$P" > "$T/init3.log" 2>&1
check "init.sh: ordinary /* project still ignores CLAUDE.local.md in an allowed dir" 'touch "$P/src/CLAUDE.local.md" && git -C "$P" check-ignore -q src/CLAUDE.local.md'
check "wrapper: update path syncs megavibe-node.sh like setup.sh" 'grep -q "REPO_DIR/scripts/megavibe-node.sh" "$REPO/megavibe" && grep -q "SCRIPT_DIR/scripts/megavibe-node.sh" "$REPO/setup.sh"'
check "wrapper: assistant starts pa-start.sh, not claude directly" 'sed -n "/Assistant subcommand/,/exec tmux attach/p" "$REPO/megavibe" | grep -q "bash \"\$PA_START\"" && ! sed -n "/Assistant subcommand/,/exec tmux attach/p" "$REPO/megavibe" | grep -q "claude --dangerously"'
o=$(bash "$REPO/scripts/megavibe-node.sh" help 2>&1)
check "help: whole header, ends with the never-stops line" '[[ "$o" == *"tells the user which one to end."* ]]'
check "templates: no absolute home paths" '! grep -rqE "/Users/|/home/" "$REPO/template/node" "$REPO/scripts/megavibe-node.sh"'

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
