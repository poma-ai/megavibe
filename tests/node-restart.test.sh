#!/bin/bash
# Restart records and peer watch: scratch HOME, fake clock/history/tmux/secrets/notifications.
# A stub Perl socket module supplies file handles instead of sockets: no network is possible.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/node-restart.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }
B="$T/bin"; mkdir -p "$B" "$T/lib/IO/Socket"
export FIXTURE="$T" TZ=UTC PERL5LIB="$T/lib" MEGAVIBE_NODE_TEST_BIN="$B"
cat > "$B/date" <<'STUB'
#!/bin/bash
now=$(cat "$FIXTURE/now")
[ "$1" != +%s ] || { echo "$now"; exit; }
exec /usr/bin/perl -MPOSIX=strftime -e 'print strftime(substr($ARGV[0],1),localtime($ARGV[1])), "\n"' "$1" "$now"
STUB
cat > "$B/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/tmux.calls"
case "$1" in
  list-windows)
    if [ "$2" = -a ]; then
      case "$(cat "$FIXTURE/tmux-mode")" in
        unknown) echo 'protocol version mismatch' >&2; exit 1 ;;
        absent) echo 'no server running' >&2; exit 1 ;;
        *) echo beta ;;
      esac
    else echo testmac; fi ;;
  list-sessions) printf 'main\nmegavibe-personal\n' ;;
esac
STUB
cat > "$B/mv" <<'STUB'
#!/bin/bash
case "$*" in
  *last-alive.tmp*)
    printf '%s -> %s\n' "$(cat "$MEGAVIBE_HOME/node/last-alive" 2>/dev/null)" "$(cat "$MEGAVIBE_HOME/node/last-alive.tmp")" >> "$HOME/stamp-writes"
    [ ! -f "$FIXTURE/write-fail" ] || exit 1 ;;
esac
exec /bin/mv "$@"
STUB
printf '#!/bin/bash\ncat "$FIXTURE/os"\n' > "$B/uname"
printf '#!/bin/bash\necho testmac\n' > "$B/scutil"
printf '#!/bin/bash\necho "Sat Mar 27 09:00:00 2027"\n' > "$B/ps"
printf '#!/bin/bash\necho "$*" >> "$HOME/sysctl.calls"\ncat "$FIXTURE/boot"\n' > "$B/sysctl"
printf '#!/bin/bash\necho "$*" >> "$HOME/last.calls"\ncat "$FIXTURE/shutdown"\n' > "$B/last"
printf '#!/bin/bash\necho "$*" >> "$HOME/notifications"\n' > "$B/osascript"
printf '#!/bin/bash\necho "$*" >> "$HOME/sleeps"\nn=$(cat "$FIXTURE/now"); echo $((n + $1)) > "$FIXTURE/now"\n' > "$B/sleep"
for cmd in megavibe launchctl ssh; do
  printf '#!/bin/bash\necho "%s $*" >> "$HOME/forbidden.calls"\nexit 1\n' "$cmd" > "$B/$cmd"
done
chmod +x "$B"/*
cat > "$T/lib/IO/Socket/INET.pm" <<'STUB'
package IO::Socket::INET;
use strict;
use warnings;
our $writer;
sub new {
  my ($class, %args) = @_;
  my $left = alarm 0; alarm $left;
  open my $calls, '>>', "$ENV{HOME}/connects" or die $!;
  print $calls "$args{PeerAddr} $args{PeerPort} $args{Proto} $args{Timeout} alarm=$left\n";
  close $calls;
  open my $mode, '<', "$ENV{FIXTURE}/$args{PeerAddr}" or return undef;
  chomp(my $kind = <$mode>);
  return undef if $kind eq 'refuse';
  if ($kind eq 'timeout') { select undef, undef, undef, 10; die 'alarm did not bound connect'; }
  if ($kind eq 'silent') { pipe(my $reader, $writer) or die $!; return $reader; }
  open my $banner, '<', "$ENV{FIXTURE}/banner-$kind" or die $!;
  return $banner;
}
1;
STUB
printf 'SSH-2.0-test\nThis system is locked\n' > "$T/banner-up"
printf 'This system is locked\r\n' > "$T/banner-locked"
: > "$T/banner-empty"
fresh() {
  export HOME="$T/home-$1" MEGAVIBE_HOME="$T/home-$1/.megavibe" CLAUDE_CONFIG_DIR="$T/home-$1/config" PATH="$B:/usr/bin:/bin:/usr/sbin:/sbin"
  N="$MEGAVIBE_HOME/node"
  mkdir -p "$N/sessions" "$MEGAVIBE_HOME/scripts" "$HOME/.local/bin"
  cp "$REPO/template/node/node.sh" "$N/node.sh"
  cp "$REPO/scripts/megavibe-node.sh" "$MEGAVIBE_HOME/scripts/megavibe-node.sh"
  printf '#!/bin/bash\nexit 0\n' > "$MEGAVIBE_HOME/scripts/claude-auth-check.sh"
  chmod +x "$MEGAVIBE_HOME/scripts/claude-auth-check.sh"
  : > "$N/node.conf"
  echo 1806148800 > "$T/now" # 2027-03-27 12:00 UTC
  echo Darwin > "$T/os"
  echo '{ sec = 1806145200, usec = 0 } Sat Mar 27 11:00:00 2027' > "$T/boot"
  echo 'shutdown  ~  Sat Mar 27 11:30 2027' > "$T/shutdown"
  echo normal > "$T/tmux-mode"
  rm -f "$T/write-fail"
}
node() { /bin/bash "$N/node.sh" > "$HOME/stdout" 2> "$HOME/stderr"; RC=$?; }
count() { grep -c "$1" "$2" 2>/dev/null || true; }
gap() { echo 1806141600 > "$N/last-alive"; } # 10:00, two hours ago
secret() {
  touch "$N/pa.on"
  cat > "$HOME/.local/bin/secret" <<'STUB'
#!/bin/bash
n=$(cat "$HOME/attempts" 2>/dev/null); n=$((${n:-0} + 1)); echo "$n" > "$HOME/attempts"
echo 'SECRET_OUTPUT_MUST_NOT_BE_RECORDED'
[ ! -f "$HOME/secret-cost" ] || { t=$(cat "$FIXTURE/now"); echo $((t + $(cat "$HOME/secret-cost"))) > "$FIXTURE/now"; }
[ "$n" -gt "$(cat "$HOME/fail-until")" ]
STUB
  chmod +x "$HOME/.local/bin/secret"
}
record() { printf 'state=%s\nstarted=2027-03-27 09:00\ndir=/example/repo\ntask=/example/task.md\n' "$2" > "$N/sessions/$1"; }

fresh first
node
check 'first run writes current epoch atomically, no invented outage' '[ "$RC" = 0 ] && [ "$(cat "$N/last-alive")" = 1806148800 ] && grep -qx " -> 1806148800" "$HOME/stamp-writes" && [ ! -e "$N/restart-note.txt" ]'
check 'NODE_PEERS unset: no connects, state files, notifications or peer logs' '[ ! -e "$HOME/connects" ] && [ ! -e "$HOME/notifications" ] && ! compgen -G "$N/.peer-*" >/dev/null && ! grep -q "peer " "$N/node.log" 2>/dev/null'
echo unchanged > "$N/.peer-studio"; node
check 'NODE_PEERS unset also preserves existing peer state' '[ "$(cat "$N/.peer-studio")" = unchanged ] && [ ! -e "$HOME/connects" ]'
echo 1806147900 > "$N/last-alive"; node
check 'exactly three intervals is not a gap' '[ ! -e "$N/restart-note.txt" ]'
echo 1806147899 > "$N/last-alive"; node
check 'over three intervals reports one gap' '[ "$(count "back after 15 min" "$N/node.log")" = 1 ]'

fresh restart
record alpha running; record beta running; record finished done; gap; node
check 'gap line includes duration, last alive, boot, clean shutdown' 'grep -q "back after 120 min (last alive 10:00, boot 11:00, clean shutdown: yes)" "$N/node.log"'
check 'boot/shutdown read with requested commands' 'grep -qx -- "-n kern.boottime" "$HOME/sysctl.calls" && grep -qx -- "-y -1 shutdown" "$HOME/last.calls"'
check 'note reuses session check, with vanished name and resume command only for missing active session' 'grep -q "VANISHED (1 of 2)" "$N/restart-note.txt" && grep -q "megavibe node session resume alpha" "$N/restart-note.txt" && ! grep -Eq "beta|finished" "$N/restart-note.txt"'
check 'note records disabled sync' 'grep -q "Secret sync succeeded since start: no (sync disabled" "$N/restart-note.txt"'
cp "$N/restart-note.txt" "$T/note"; node
check 'next run neither repeats gap nor loses note' '[ "$(count "back after" "$N/node.log")" = 1 ] && cmp -s "$T/note" "$N/restart-note.txt"'
echo 1806156000 > "$T/now"; echo unknown > "$T/tmux-mode"; node
check 'next gap overwrites old note, unknown sessions are not called vanished' '[ "$(count "back after" "$N/node.log")" = 2 ] && grep -q UNKNOWN "$N/restart-note.txt" && ! grep -q VANISHED "$N/restart-note.txt"'
check 'note replaced atomically, no tmp left' '[ ! -e "$N/restart-note.txt.tmp" ]'

fresh unseen
record alpha running
printf 'pid=%s\npidstart=Sat Mar 27 09:00:00 2027\n' "$$" >> "$N/sessions/alpha"
echo absent > "$T/tmux-mode"; gap; node
check 'live recorded process remains UNSEEN in restart note' 'grep -q UNSEEN "$N/restart-note.txt" && ! grep -q VANISHED "$N/restart-note.txt"'
fresh unavailable
rm "$MEGAVIBE_HOME/scripts/megavibe-node.sh"; gap; node
check 'missing session helper leaves actionable note, supervision continues' '[ "$RC" = 0 ] && grep -q "Session check unavailable" "$N/restart-note.txt"'
fresh off
gap; touch "$N/node.off"; echo 'NODE_PEERS=studio=studio.example' > "$N/node.conf"; node
check 'node off still records heartbeat/restart but checks no peers or secrets' '[ "$RC" = 0 ] && [ "$(cat "$N/last-alive")" = 1806148800 ] && grep -q "(node off)" "$N/restart-note.txt" && [ ! -e "$HOME/connects" ] && [ ! -e "$HOME/attempts" ]'
fresh absent
rm -rf "$N"; node
check 'without node directory no files or peer activity created' '[ ! -e "$N" ] && [ ! -e "$HOME/connects" ] && [ ! -e "$HOME/tmux.calls" ]'

fresh boot
echo 1806148740 > "$N/last-alive"; echo '{ sec=1806148770, usec=0 }' > "$T/boot"
echo 'shutdown  ~  Sat Mar 27 11:59:10 2027' > "$T/shutdown"; node
check 'new boot detects short gap too' 'grep -q "back after 1 min (last alive 11:59, boot 11:59, clean shutdown: unknown)" "$N/node.log"'
node; check 'boot detection fires once' '[ "$(count "back after" "$N/node.log")" = 1 ]'
gap; echo 'shutdown  ~  Sat Mar 27 09:30 2027' > "$T/shutdown"; node
check 'older shutdown reports no' 'tail -1 "$N/node.log" | grep -q "clean shutdown: no"'
gap; echo garbage > "$T/shutdown"; echo garbage > "$T/boot"; node
check 'unparseable metadata is unknown and nonfatal' '[ "$RC" = 0 ] && tail -1 "$N/node.log" | grep -q "boot unknown, clean shutdown: unknown"'
gap; mv "$B/last" "$B/last.saved"
# Hide last even on hosts where it is installed: an exec failure is the same empty result.
printf '#!/bin/bash\nexit 127\n' > "$B/last"; chmod +x "$B/last"; node
check 'unavailable shutdown command is nonfatal, unknown' '[ "$RC" = 0 ] && tail -1 "$N/node.log" | grep -q "clean shutdown: unknown"'
mv "$B/last.saved" "$B/last"
fresh year
echo 1798761900 > "$T/now" # 2027-01-01 00:05 UTC
echo 1798754400 > "$N/last-alive" # 2026-12-31 22:00 UTC
echo 'shutdown  ~  Thu Dec 31 23:00' > "$T/shutdown"; echo unknown > "$T/boot"; node
check 'yearless shutdown near New Year stays unknown' 'grep -q "clean shutdown: unknown" "$N/node.log"'
echo 1798754400 > "$N/last-alive"
echo 'shutdown  ~  Thu Dec 31 23:00 2026' > "$T/shutdown"; node
check 'explicit previous year across New Year reports yes' 'tail -1 "$N/node.log" | grep -q "clean shutdown: yes"'

# Minute precision cannot order two events within the same minute, even if seconds appear.
for scenario in equal late_stamp later_minute earlier_minute yearless_new yearless_old old_year invalid_date invalid_time invalid_seconds bad_year future; do
  fresh "shutdown-$scenario"
  gap
  case "$scenario" in
    equal) stamp='Sat Mar 27 10:00 2027'; verdict=unknown ;;
    late_stamp) echo 1806141659 > "$N/last-alive"; stamp='Sat Mar 27 10:00 2027'; verdict=unknown ;;
    later_minute) echo 1806141659 > "$N/last-alive"; stamp='Sat Mar 27 10:01 2027'; verdict=yes ;;
    earlier_minute) stamp='Sat Mar 27 09:59 2027'; verdict=no ;;
    yearless_new) stamp='Sat Mar 27 11:30'; verdict=unknown ;;
    yearless_old) stamp='Sat Mar 27 09:30'; verdict=unknown ;;
    old_year) stamp='Fri Mar 27 11:30 2026'; verdict=no ;;
    invalid_date) stamp='Wed Feb 30 11:30 2027'; verdict=unknown ;;
    invalid_time) stamp='Sat Mar 27 25:30 2027'; verdict=unknown ;;
    invalid_seconds) stamp='Sat Mar 27 11:30:99 2027'; verdict=unknown ;;
    bad_year) stamp='Sat Mar 27 11:30 2027oops'; verdict=unknown ;;
    future) stamp='Sun Mar 28 11:30 2027'; verdict=unknown ;;
  esac
  printf 'shutdown  ~  %s\n' "$stamp" > "$T/shutdown"; node
  check "shutdown $scenario reports $verdict" '[ "$RC" = 0 ] && grep -q "clean shutdown: $verdict)" "$N/node.log"'
done
fresh history_failure; gap
cp "$B/last" "$B/last.saved"
printf '#!/bin/bash\ncat "$FIXTURE/shutdown"\nexit 1\n' > "$B/last"; node
check 'failed history command cannot yield a clean verdict from partial output' 'grep -q "clean shutdown: unknown" "$N/node.log"'
mv "$B/last.saved" "$B/last"

fresh linux; echo Linux > "$T/os"; gap; node
check 'non-macOS reports unknown without querying boot/shutdown' '[ "$RC" = 0 ] && grep -q "boot unknown, clean shutdown: unknown" "$N/node.log" && [ ! -e "$HOME/sysctl.calls" ] && [ ! -e "$HOME/last.calls" ]'
fresh malformed; echo bad > "$N/last-alive"; node
check 'corrupt stamp is replaced without inventing an outage' '[ "$RC" = 0 ] && [ "$(cat "$N/last-alive")" = 1806148800 ] && [ ! -e "$N/restart-note.txt" ]'
echo 1806148500 > "$N/last-alive"; touch "$T/write-fail"; node
check 'failed atomic stamp write leaves old stamp and does not stop supervision' '[ "$RC" = 0 ] && [ "$(cat "$N/last-alive")" = 1806148500 ] && grep -q list-windows "$HOME/tmux.calls"'
fresh clock; echo unavailable > "$T/now"; node
check 'unavailable clock leaves no stamp and does not stop supervision' '[ "$RC" = 0 ] && [ ! -e "$N/last-alive" ] && grep -q list-windows "$HOME/tmux.calls"'

fresh recover; gap; secret; echo 2 > "$HOME/fail-until"; node
check 'startup retries twice with 20-second pauses, then succeeds' '[ "$(cat "$HOME/attempts")" = 3 ] && [ "$(count "^20$" "$HOME/sleeps")" = 2 ]'
check 'failure logged once and recovery counted once' '[ "$(count "secret sync failed" "$N/node.log")" = 1 ] && [ "$(count "secret sync ok after 2 failed attempts" "$N/node.log")" = 1 ]'
check 'note records success and output stays private' 'grep -q "Secret sync succeeded since start: yes" "$N/restart-note.txt" && ! grep -R -q SECRET_OUTPUT "$N" "$HOME/stdout" "$HOME/stderr"'
node; check 'continued success does not repeat recovery' '[ "$(count "secret sync ok after" "$N/node.log")" = 1 ]'
fresh failures; gap; secret; echo 99 > "$HOME/fail-until"; node
check 'startup stops after three failures; note says no' '[ "$(cat "$HOME/attempts")" = 3 ] && grep -qx "Secret sync succeeded since start: no" "$N/restart-note.txt"'
echo 1806149100 > "$T/now"; node
check 'outside startup window one attempt, no extra sleep, failure still rate-limited' '[ "$(cat "$HOME/attempts")" = 4 ] && [ "$(count "^20$" "$HOME/sleeps")" = 2 ] && [ "$(count "secret sync failed" "$N/node.log")" = 1 ]'
echo 4 > "$HOME/fail-until"; node
check 'later run reports all failed attempts and updates persistent note' '[ "$(count "secret sync ok after 4 failed attempts" "$N/node.log")" = 1 ] && grep -qx "Secret sync succeeded since start: yes" "$N/restart-note.txt"'
echo 99 > "$HOME/fail-until"; node
check 'new failure streak starts from zero, success-since-start stays yes' '[ "$(cat "$N/.secret-failures")" = 1 ] && grep -qx "Secret sync succeeded since start: yes" "$N/restart-note.txt"'
/usr/bin/touch -t 202001010000 "$N/.once-secret-sync"; node
check 'failure logs again after hourly limit expires' '[ "$(count "secret sync failed" "$N/node.log")" = 2 ]'
fresh slow; secret; echo 99 > "$HOME/fail-until"; echo 80 > "$HOME/secret-cost"; node
check 'time spent syncing counts toward startup window' '[ "$(cat "$HOME/attempts")" = 2 ] && [ "$(count "^20$" "$HOME/sleeps")" = 1 ]'
fresh disabled; secret; echo 99 > "$HOME/fail-until"; rm "$N/pa.on"; node
check 'no PA means no sync or retries' '[ ! -e "$HOME/attempts" ] && [ ! -e "$HOME/sleeps" ]'

# Both PA launch paths instruct the assistant to read the retained note.
check 'fresh and resumed PA prompts name the restart note' '[ "$(grep -c "restart-note.txt" "$REPO/template/node/pa-start.sh")" = 2 ]'

fresh peers
echo 'NODE_PEERS=studio=studio.example,192.0.2.10 spare=spare.example' > "$N/node.conf"
echo up > "$T/studio.example"; echo refuse > "$T/spare.example"; node
check 'peer initial states logged and saved' '[ "$(cat "$N/.peer-studio")" = up ] && [ "$(cat "$N/.peer-spare")" = unreachable ] && [ "$(count "peer " "$N/node.log")" = 2 ]'
check 'macOS notification per initial state' '[ "$(count "display notification" "$HOME/notifications")" = 2 ]'
check 'SSH port, timeout and DNS alarm bounded; no fallback when host is up' 'grep -qx "studio.example 22 tcp 2 alarm=2" "$HOME/connects" && ! grep -q 192.0.2.10 "$HOME/connects"'
node; check 'unchanged states are silent' '[ "$(count "peer " "$N/node.log")" = 2 ] && [ "$(count "display notification" "$HOME/notifications")" = 2 ]'
echo refuse > "$T/studio.example"; echo locked > "$T/192.0.2.10"; node
check 'fallback follows failed hostname, locked banner recognized' '[ "$(cat "$N/.peer-studio")" = locked ] && tail -3 "$HOME/connects" | head -2 | tr "\n" " " | grep -q "studio.example .*192.0.2.10" && grep -q "peer studio: locked" "$N/node.log"'
echo refuse > "$T/192.0.2.10"; node
check 'both addresses down yields unreachable' '[ "$(cat "$N/.peer-studio")" = unreachable ] && [ "$(count "peer studio: unreachable" "$N/node.log")" = 1 ]'
echo up > "$T/studio.example"; node
check 'recovery to up logged once, only first banner line examined' '[ "$(cat "$N/.peer-studio")" = up ] && [ "$(count "peer studio: up" "$N/node.log")" = 2 ]'
echo Linux > "$T/os"; echo locked > "$T/studio.example"; before=$(wc -l < "$HOME/notifications"); node
check 'non-macOS state changes log without notification' '[ "$(cat "$N/.peer-studio")" = locked ] && [ "$(wc -l < "$HOME/notifications")" = "$before" ]'
echo 'NODE_PEERS=../bad=studio.example valid=spare.example' > "$N/node.conf"; node
check 'invalid peer config never becomes a path' '[ ! -e "$MEGAVIBE_HOME/bad" ] && grep -q "unusable NODE_PEERS entry: ../bad=studio.example" "$N/node.log"'
echo 'NODE_PEERS=badentry valid=spare.example' > "$N/node.conf"; node
check 'malformed entry does not skip remaining valid peer' '[ "$(cat "$N/.peer-valid")" = unreachable ]'
check 'no ssh, megavibe launch, or launchctl invoked' '[ ! -e "$HOME/forbidden.calls" ]'
# Simulate command discovery on a Mac without osascript; all other lookups use the builtin.
command() { [ "$*" != '-v osascript' ] || return 1; builtin command "$@"; }
export -f command
echo Darwin > "$T/os"; echo 'NODE_PEERS=missing=spare.example' > "$N/node.conf"
before=$(wc -l < "$HOME/notifications"); node
check 'missing osascript silently skips notifications, still saves state' '[ "$RC" = 0 ] && [ "$(cat "$N/.peer-missing")" = unreachable ] && [ "$(wc -l < "$HOME/notifications")" = "$before" ] && [ ! -s "$HOME/stderr" ]'
unset -f command
# Invalid addresses reject the entire entry, even when its primary host would connect.
for address in 192.0.2.10:443 2001:db8::22 bad/address; do
  for field in host fallback; do
    fresh "invalid-address-$field-${address//\//-}"
    entry="bad=$address,192.0.2.10"
    [ "$field" != fallback ] || entry="bad=studio.example,$address"
    printf 'NODE_PEERS=%s valid=other.example\n' "$entry" > "$N/node.conf"
    echo up > "$T/studio.example"; echo up > "$T/192.0.2.10"; echo up > "$T/other.example"
    node; node
    check "invalid $field $address is not checked; valid peer still checked" '[ "$RC" = 0 ] && [ "$(count "^other.example 22 tcp 2 alarm=2$" "$HOME/connects")" = 2 ] && [ "$(count "^" "$HOME/connects")" = 2 ]'
    check "invalid $field $address has no state or notification" '[ ! -e "$N/.peer-bad" ] && [ "$(cat "$N/.peer-valid")" = up ] && [ "$(count "display notification" "$HOME/notifications")" = 1 ] && ! grep -q "bad:" "$HOME/notifications"'
    check "invalid $field $address logs its entry once across runs" '[ "$(grep -Fc "node.conf: unusable NODE_PEERS entry: $entry" "$N/node.log")" = 1 ]'
    find "$N" -name '.once-peer*' -exec /usr/bin/touch -t 202001010000 {} +
    node
    check "invalid $field $address logs again after hourly limit expires" '[ "$(grep -Fc "node.conf: unusable NODE_PEERS entry: $entry" "$N/node.log")" = 2 ] && [ "$(count "display notification" "$HOME/notifications")" = 1 ]'
  done
done
# Duplicate names keep the first address/state, including case-only duplicates.
for scenario in exact mixed; do
  duplicate=studio; [ "$scenario" != mixed ] || duplicate=STUDIO
  fresh "duplicate-$scenario"
  echo "NODE_PEERS=studio=first.example $duplicate=later.example,192.0.2.11 $duplicate=third.example spare=other.example" > "$N/node.conf"
  echo up > "$T/first.example"; echo locked > "$T/later.example"
  echo refuse > "$T/third.example"; echo up > "$T/other.example"
  node; node
  check "duplicate $duplicate uses only the first entry and still checks other peers" '[ "$(cat "$N/.peer-studio")" = up ] && [ "$(cat "$N/.peer-spare")" = up ] && [ "$(count "first.example " "$HOME/connects")" = 2 ] && [ "$(count "other.example " "$HOME/connects")" = 2 ] && ! grep -Eq "later.example|third.example|192.0.2.11" "$HOME/connects"'
  check "duplicate $duplicate creates one state file per name and no repeated notifications" '[ "$(find "$N" -name ".peer-*" | wc -l | tr -d " ")" = 2 ] && [ "$(count "display notification" "$HOME/notifications")" = 2 ]'
  check "duplicate $duplicate logs its name once across entries and runs" '[ "$(count "node.conf: duplicate NODE_PEERS name $duplicate; using the first entry" "$N/node.log")" = 1 ]'
  /usr/bin/touch -t 202001010000 "$N/.once-peer-duplicate-studio"; node
  check "duplicate $duplicate logs again after hourly limit expires" '[ "$(count "node.conf: duplicate NODE_PEERS name $duplicate; using the first entry" "$N/node.log")" = 2 ] && [ "$(count "display notification" "$HOME/notifications")" = 2 ]'
done

fresh timeout
echo 'NODE_PEERS=studio=studio.example,192.0.2.10' > "$N/node.conf"
echo timeout > "$T/studio.example"; echo up > "$T/192.0.2.10"; start=$SECONDS; node
check 'connect deadline catches timeout and tries fallback' '[ "$((SECONDS-start))" -lt 8 ] && [ "$(cat "$N/.peer-studio")" = up ] && grep -q 192.0.2.10 "$HOME/connects"'
echo silent > "$T/studio.example"; start=$SECONDS; node
check 'silent open port is up after bounded banner read' '[ "$((SECONDS-start))" -lt 8 ] && [ "$(cat "$N/.peer-studio")" = up ]'
echo empty > "$T/studio.example"; node
check 'connection with EOF is still up' '[ "$(cat "$N/.peer-studio")" = up ]'

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
