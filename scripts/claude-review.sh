#!/bin/bash
# claude-review.sh — the Claude-side counterpart of codex-review.sh: one lean headless worker
# call, with or without execution, on the Claude subscription. Same interface on purpose, so
# the allocation rule in .claude/rules/delegation.md can give a unit of work to either
# provider by weighing both weekly windows, not by which side is easier to spawn.
#
#   claude-review.sh [--as-reviewer] [--prompt TEXT | --prompt-file F] [--out FILE]
#                    [--model sonnet] [--timeout 900] [--tools exec|read|none]
#                    [--effort LEVEL] [--max-input-kb N] [--keep-scratch] FILE...
#
# The files are appended to the prompt as `===== path =====` blocks (and, for exec and read, also
# copied into the worker's scratch directory). The answer goes to stdout and to --out.
# Exit: 0 ok, 2 usage or refusal, 3 the call failed, 124 timed out.
#
# Why not the Agent tool: every Agent-tool subagent starts at about 93K tokens of inherited
# context in a project with heavy instructions and re-reads it each turn; this worker starts at
# about 5-8K. It keeps what the Agent-tool reviewer has (reading, running things) and adds what
# the sandboxed Codex reviewer has (a throwaway scratch directory, writes confined to it):
#  - cwd is a fresh scratch directory, TMPDIR inside it, deleted on exit (as codex-review.sh).
#  - --tools exec (the default under --as-reviewer): Read, Grep, Glob, Bash, Write. On macOS the
#    process runs under a seatbelt profile that DENIES every file write except the scratch
#    directory and claude's own state (so a stray `find -delete` or `git checkout` against the
#    project fails with "Operation not permitted"); the repository's block-dangerous-bash.sh
#    and block-permission-hooks.sh are registered through --settings, WITHOUT loading the
#    project's CLAUDE.md, rules or other hooks. Without a seatbelt (not macOS) exec is refused.
#    Not confined, unlike codex: the network (claude itself needs it) and reads.
#  - --tools read (the default otherwise): Read, Grep, Glob only. --tools none: nothing, the files
#    are only in the prompt (the cheapest; no scratch needed).
#  - Subscription login only: the call runs in an allow-listed minimal environment (no API key, token,
#    custom header or cloud-provider variable can reach it; proxy and certificate settings are kept), and `claude auth status` must report a
#    claude.ai login (a saved Console key would bill); if that cannot be checked the script refuses.
# The `reviewer` role cannot be switched off, so --as-reviewer has no MEGAVIBE_REVIEWERS gate;
# it selects exec as the default and adds the process rules to the brief.
set -euo pipefail

PROG=${0##*/}
CLAUDE_BIN=${CLAUDE_REVIEW_CLAUDE:-claude}
MV_HOME=${MEGAVIBE_HOME:-$HOME/.megavibe}
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

# The environment of every claude call is an ALLOW-LIST (env -i plus what claude legitimately needs), so no
# credential, endpoint or header variable (ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_CUSTOM_HEADERS,
# cloud-provider switches and tokens, ...) can reach it, whatever it is called: a deny-list of names would miss
# the next one. A saved claude.ai login is found through HOME or CLAUDE_CONFIG_DIR.
CLEAN=(env -i)
for _v in PATH HOME USER LOGNAME SHELL TERM LANG LC_ALL LC_CTYPE TMPDIR TZ CLAUDE_CONFIG_DIR HTTPS_PROXY HTTP_PROXY NO_PROXY ALL_PROXY https_proxy http_proxy no_proxy all_proxy NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR; do
  if [ -n "${!_v+x}" ]; then CLEAN+=("$_v=${!_v}"); fi
done


die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

# Production always uses /bin/ps; the fixture override requires explicit test mode
# and is passed only to the supervisor, never into the worker environment.
PS_BIN=/bin/ps
if [ "${CLAUDE_REVIEW_TESTING:-0}" = 1 ]; then PS_BIN=${CLAUDE_REVIEW_TEST_PS:-/bin/ps}; fi

# Group signals catch unobserved/reparented children in the original group.
# Polling additionally tracks observed descendants that call setsid. A child that
# calls setsid AND is reparented before it was ever observed cannot be caught by
# polling. Shorter polling does not remove this residual risk.
SUP='
use strict;
use POSIX qw(WNOHANG);
use IO::Select;
use Time::HiRes qw(time sleep);
my ($t, $ps_command, $state) = (shift, shift, shift);
my ($cancel, $pid, $status, $inspection_failed, $cleaning) = (0, undef, undef, 0, 0);
my ($guard, $pulse, $inspector);
$SIG{INT} = sub { $cancel ||= 130 };
$SIG{TERM} = sub { $cancel ||= 143 };
$SIG{HUP} = sub { $cancel ||= 129 };
$SIG{PIPE} = "IGNORE";
my (%seen, %live);
sub heartbeat { print {$pulse} "tick\n" if $pulse; }
sub stop_inspector {
    return unless $inspector;
    kill "KILL", -$inspector;
    kill "KILL", $inspector; # Also covers failure to establish its group.
    waitpid($inspector, 0);
    $inspector = undef;
    print {$pulse} "ps 0\n" if $pulse;
}
sub snapshot {
    return if $inspection_failed;
    pipe(my $read, my $write) or die "ps pipe: $!";
    $inspector = fork();
    die "ps fork: $!" unless defined $inspector;
    if (!$inspector) {
        $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "DEFAULT";
        close $pulse if $pulse;
        close $read;
        setpgrp(0, 0) or POSIX::_exit(127);
        open STDOUT, ">&", $write or POSIX::_exit(127);
        close $write;
        exec $ps_command, "-axo", "pid=,ppid=,lstart=";
        POSIX::_exit(127);
    }
    setpgrp($inspector, $inspector);
    print {$pulse} "ps $inspector\n" if $pulse;
    close $write;
    my $select = IO::Select->new($read);
    my ($text, $done, $rc) = ("", 0, undef);
    my $until = time() + 0.25;
    while (time() < $until && (!$cancel || $cleaning)) {
        heartbeat();
        if (!$done && $select->can_read(0.01)) {
            my $n = sysread($read, my $buf, 65536);
            if (defined $n) { $text .= $buf; $done = 1 if !$n; }
        } else { sleep 0.01; }
        if (!defined $rc && waitpid($inspector, WNOHANG) == $inspector) { $rc = $?; }
        last if $done && defined $rc;
    }
    close $read;
    if (!defined $rc) { stop_inspector(); }
    else {
        # A shim can exit while a child keeps stdout open. Its group still
        # belongs to this inspection even though the direct child was reaped.
        kill "KILL", -$inspector unless $done;
        $inspector = undef;
        print {$pulse} "ps 0\n" if $pulse;
    }
    if (!$done || !defined($rc) || $rc != 0) {
        $inspection_failed = 1;
        warn "inspection unavailable: cannot inspect worker descendants with ps\n";
        return;
    }
    my %rows;
    for (split /\n/, $text) {
        $rows{$1} = [$2, $3] if /^\s*(\d+)\s+(\d+)\s+(.+?)\s*$/;
    }
    return \%rows;
}
# Only the parent side can write this file: the control directory is outside
# every worker-writable root. Atomic replacement leaves a complete snapshot if
# the supervisor is stopped or killed midway through publishing the next one.
sub save_observed {
    open my $f, ">", "$state.tmp.$$" or die "descendant state: $!";
    for my $p (keys %live) { print $f "$p $seen{$p}\n" or die "descendant state: $!"; }
    close $f or die "descendant state: $!";
    rename "$state.tmp.$$", $state or die "descendant state rename: $!";
}
sub read_observed {
    my %observed;
    if (open my $f, "<", $state) {
        while (<$f>) { $observed{$1} = $2 if /^\s*(\d+)\s+(.+?)\s*$/; }
    }
    return \%observed;
}
sub signal_observed {
    my ($signal, $observed) = @_;
    my $sent = 0;
    for my $p (keys %$observed) {
        next unless kill 0, $p;
        # Each inspection is bounded, including when ps hangs. Never signal a
        # saved PID on inspection loss or after its start time has changed.
        my $rows = eval { snapshot() };
        if ($@) { warn $@; $inspection_failed = 1; stop_inspector(); }
        next unless $rows && exists $rows->{$p} && $rows->{$p}[1] eq $observed->{$p};
        $sent += kill $signal, $p;
    }
    return $sent;
}
# The wrapper uses the same identity checks before removing either directory,
# even when its wait returned before the independent watchdog finished.
if ($t eq "cleanup") {
    $cleaning = 1;
    my $observed = read_observed();
    sleep 2 if signal_observed("TERM", $observed);
    signal_observed("KILL", $observed);
    exit 0;
}
snapshot(); # Bounded pre-start check: refuse if process inspection is unavailable.
exit $cancel if $cancel;
exit 3 if $inspection_failed;

# The gate prevents exec until the parent has established the worker group and
# started an independent watchdog. This group is distinct from the wrapper group.
pipe(my $gate_r, my $gate_w) or die "gate pipe: $!";
$pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "DEFAULT";
    close $gate_w;
    setpgrp(0, 0) or POSIX::_exit(127);
    my $go = "";
    sysread($gate_r, $go, 1);
    close $gate_r;
    POSIX::_exit(127) unless $go eq "G";
    exec @ARGV;
    POSIX::_exit(127);
}
my $deadline = time() + $t;
sub members {
    my $rows = snapshot();
    # On inspection loss retain the last observed descendants for best-effort
    # cleanup; no new detached children can be discovered or identities refreshed.
    return keys %live unless $rows;
    %live = ();
    for my $p (keys %seen) {
        $live{$p} = 1 if exists $rows->{$p} && $rows->{$p}[1] eq $seen{$p};
    }
    $live{$pid} = 1 if !defined($status) && exists $rows->{$pid};
    my $changed = 1;
    while ($changed) {
        $changed = 0;
        for my $p (keys %$rows) {
            next if $live{$p};
            if ($live{$rows->{$p}[0]}) { $live{$p} = 1; $changed = 1; }
        }
    }
    $seen{$_} = $rows->{$_}[1] for keys %live;
    save_observed();
    return keys %live;
}
sub reap {
    return if defined $status;
    my $r = waitpid($pid, WNOHANG);
    $status = $? if $r == $pid;
}
my $error;
eval {
    close $gate_r;
    setpgrp($pid, $pid) or die "worker setpgrp: $!";
    pipe(my $watch, $pulse) or die "watchdog pipe: $!";
    $pulse->autoflush(1);
    my $supervisor = $$;
    $guard = fork();
    die "watchdog fork: $!" unless defined $guard;
    if (!$guard) {
        close $pulse;
        undef $pulse;
        close $gate_w;
        $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "DEFAULT";
        my $select = IO::Select->new($watch);
        my ($last, $pending, $ps) = (time(), "", 0);
        while (time() < $deadline + 4 && time() < $last + 3) {
            next unless $select->can_read(0.05);
            my $n = sysread($watch, my $buf, 65536);
            last unless $n; # Supervisor died without finishing cleanup.
            $last = time();
            $pending .= $buf;
            while ($pending =~ s/^(.*?)\n//) {
                my $line = $1;
                POSIX::_exit(0) if $line eq "done";
                $ps = $1 if $line =~ /^ps (\d+)$/;
            }
        }
        # Group cleanup still works without ps. Detached descendants require
        # fresh identity checks against the last atomically published snapshot.
        $cleaning = 1;
        my $observed = read_observed();
        kill "TERM", -$pid;
        kill "KILL", -$ps if $ps;
        signal_observed("TERM", $observed);
        sleep 2;
        kill "KILL", -$pid;
        signal_observed("KILL", $observed);
        # EOF can mean the supervisor already died; do not signal a reused PID.
        kill "KILL", $supervisor if getppid() == $supervisor;
        POSIX::_exit(0);
    }
    close $watch;
    print {$gate_w} "G";
    close $gate_w;
    while (1) {
        heartbeat();
        members();
        reap();
        last if $cancel || defined $status;
        if (time() >= $deadline) { $cancel = 124; last; }
        sleep 0.05;
    }
    1;
} or $error = $@ || "supervisor failed\n";

# Every post-fork error, normal exit, deadline and signal reaches this cleanup.
# Group KILL after the grace also catches children spawned by TERM handlers.
$cleaning = 1;
close $gate_w;
stop_inspector();
kill "TERM", -$pid;
my $until = time() + 2;
my %termed;
while (1) {
    heartbeat();
    my @live = eval { members() };
    if ($@) { $error ||= $@; $inspection_failed = 1; @live = keys %live; stop_inspector(); }
    for my $p (@live) {
        next if defined($status) && $p == $pid;
        kill "TERM", $p unless ($termed{$p} // "") eq $seen{$p};
        $termed{$p} = $seen{$p};
    }
    reap();
    last if time() >= $until;
    last unless kill(0, -$pid) || grep { $_ != $pid && kill(0, $_) } @live;
    sleep 0.05;
}
kill "KILL", -$pid;
kill "KILL", $_ for grep { !defined($status) || $_ != $pid } keys %live;
if (!defined $status) { waitpid($pid, 0); $status = $?; }
if ($pulse) { print {$pulse} "done\n"; close $pulse; }
waitpid($guard, 0) if $guard;
warn $error if $error;
exit($cancel || ($error || $inspection_failed ? 3 : ($status & 127 ? 128 + ($status & 127) : $status >> 8)));
'
usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
valid_model() { case $1 in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }
isnum() { case $1 in ''|*[!0-9]*) return 1 ;; esac; return 0; }

AS_REVIEWER=0 PROMPT='' PROMPT_FILE='' OUT='' MODEL=sonnet TIMEOUT=900 TOOLS='' EFFORT='' MAXKB='' KEEP=0
FILES=()
while [ $# -gt 0 ]; do
  case $1 in
    --as-reviewer) AS_REVIEWER=1; shift ;;
    --prompt) PROMPT=${2:-}; shift 2 ;;
    --prompt-file) PROMPT_FILE=${2:-}; shift 2 ;;
    --out) OUT=${2:-}; shift 2 ;;
    --model) MODEL=${2:-}; shift 2 ;;
    --timeout) TIMEOUT=${2:-}; shift 2 ;;
    --tools) TOOLS=${2:-}; shift 2 ;;
    --effort) EFFORT=${2:-}; shift 2 ;;
    --max-input-kb) MAXKB=${2:-}; shift 2 ;;
    --keep-scratch) KEEP=1; shift ;;
    --sandbox|--approve-for-me|--full-auto|--dangerously-skip-permissions|--permission-mode)
      die "$1 is not available here: the sandbox and the tool set are fixed by --tools" ;;
    -h|--help) usage 0 ;;
    --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
    -*) die "unknown option $1" ;;
    *) FILES+=("$1"); shift ;;
  esac
done
# a path that starts with - must not become an option of cat, cp, cmp or tr: every operand is made
# explicit (./ or absolute), and files are read by redirection
if [ ${#FILES[@]} -gt 0 ]; then
  for i in "${!FILES[@]}"; do case ${FILES[$i]} in /*|./*) ;; *) FILES[$i]=./${FILES[$i]} ;; esac; done
fi
case $PROMPT_FILE in ""|/*|./*) ;; *) PROMPT_FILE=./$PROMPT_FILE ;; esac
case $OUT in ""|/*|./*) ;; *) OUT=./$OUT ;; esac
valid_model "$MODEL" || die "bad --model"
isnum "$TIMEOUT" && [ "$TIMEOUT" -ge 1 ] || die "--timeout must be a number of seconds, at least 1"
[ -z "$EFFORT" ] || case $EFFORT in *[!A-Za-z0-9_-]*) die "bad --effort" ;; esac
if [ -z "$TOOLS" ]; then if [ "$AS_REVIEWER" = 1 ]; then TOOLS=exec; else TOOLS=read; fi; fi
case $TOOLS in exec|read|none) ;; *) die "--tools must be exec, read or none" ;; esac
if [ -z "$MAXKB" ]; then case $MODEL in haiku*) MAXKB=150 ;; *) MAXKB=600 ;; esac; fi
isnum "$MAXKB" || die "--max-input-kb must be a number"
if [ -n "$PROMPT_FILE" ]; then [ -r "$PROMPT_FILE" ] || die "cannot read $PROMPT_FILE"; PROMPT=$(cat < "$PROMPT_FILE"); fi
[ -n "$PROMPT" ] || die "give --prompt or --prompt-file"
command -v jq >/dev/null 2>&1 || die "needs jq"
command -v perl >/dev/null 2>&1 || die "needs perl"
if [ ${#FILES[@]} -gt 0 ]; then
  for f in "${FILES[@]}"; do
    [ -f "$f" ] && [ -r "$f" ] || die "cannot read $f"
    if ! LC_ALL=C tr -d '\000' < "$f" | cmp -s - "$f"; then die "$f looks binary (contains NUL bytes)"; fi
  done
fi

# exec needs a way to confine writes and the guard hooks; without both it is refused, never degraded
HOOKS=''
SEATBELT=0
if [ "$TOOLS" = exec ]; then
  if [ "$(uname -s)" = Darwin ] && command -v sandbox-exec >/dev/null 2>&1; then SEATBELT=1
  else die "--tools exec needs a write sandbox (macOS sandbox-exec); use --tools read, or codex-review.sh --as-reviewer, which has its own"; fi
  for d in "$MV_HOME/template/.claude/hooks" "$SELF_DIR/../template/.claude/hooks"; do
    if [ -x "$d/block-dangerous-bash.sh" ] && [ -x "$d/block-permission-hooks.sh" ]; then HOOKS=$(CDPATH= cd -- "$d" && pwd -P); break; fi
  done
  [ -n "$HOOKS" ] || die "--tools exec needs both block-dangerous-bash.sh and block-permission-hooks.sh, executable, in one directory (looked in $MV_HOME/template and next to this script); refusing to run Bash unguarded"
fi

SC=''; CTL=''; TOOLDIR=''; SUP_PID=''
cleanup() {
  if [ -n "$CTL" ] && [ -f "$CTL/descendants" ]; then
    "${CLEAN[@]}" perl -e "$SUP" cleanup "$PS_BIN" "$CTL/descendants" || true
  fi
  if [ "$KEEP" = 0 ]; then
    if [ -n "$SC" ]; then chmod -R u+rwX "$SC" 2>/dev/null || true; rm -rf "$SC" 2>/dev/null || true; fi
    if [ -n "$CTL" ]; then rm -rf "$CTL" 2>/dev/null || true; fi
    # the worker's own tool folder (named after its unique scratch dir), never anything else
    case $TOOLDIR in /private/tmp/claude-*/-*claude-review-scratch*) rm -rf "$TOOLDIR" 2>/dev/null || true ;; esac
  fi
}
# A background exec keeps $! equal to the supervisor PID (including during auth).
# wait is interruptible in bash 3.2; foreground commands defer these traps.
terminate() {
  local code=$1 signal=$2
  trap '' INT TERM HUP
  if [ -n "$SUP_PID" ]; then
    # The independent supervisor watchdog owns the known worker group and also
    # bounds this wait if the supervisor stops responding during inspection.
    kill -"$signal" "$SUP_PID" 2>/dev/null || true
    wait "$SUP_PID" 2>/dev/null || true
    SUP_PID=''
  fi
  exit "$code"
}
trap cleanup EXIT
trap 'terminate 130 INT' INT
trap 'terminate 143 TERM' TERM
trap 'terminate 129 HUP' HUP

SC=$(mktemp -d "${TMPDIR:-/tmp}/claude-review-scratch.XXXXXX") || die "cannot create the scratch dir"
SC=$(CDPATH= cd -- "$SC" && pwd -P)
mkdir "$SC/tmp" "$SC/in"
SLUG=$(printf '%s' "$SC" | sed 's/[^A-Za-z0-9]/-/g')
TOOLDIR="/private/tmp/claude-$(id -u)/$SLUG"
# One canonical list drives both the profile and control-directory exclusion.
# Resolve existing symlink ancestors even when a granted leaf does not yet exist.
POLICY='
use strict;
use Cwd qw(realpath);
use File::Basename qw(dirname basename);
use File::Temp qw(tempdir);
sub canonical {
    my ($p) = @_;
    $p = "$ENV{PWD}/$p" unless $p =~ m{^/};
    my @tail;
    while (!-e $p) {
        die "cannot resolve writable path $p\n" if -l $p;
        unshift @tail, basename($p);
        my $parent = dirname($p);
        die "cannot resolve writable path $p\n" if $parent eq $p;
        $p = $parent;
    }
    $p = realpath($p) // die "realpath: $!";
    for (@tail) {
        next if $_ eq ".";
        if ($_ eq "..") { $p = dirname($p); }
        else { $p .= ($p eq "/" ? "" : "/") . $_; }
    }
    return $p;
}
sub quote_sb { my $s = shift; $s =~ s/(["\\])/\\$1/g; return qq{"$s"}; }
sub inside { return $_[1] eq "/" || $_[0] eq $_[1] || index($_[0], "$_[1]/") == 0; }
my ($scratch, $tool, $mode) = @ARGV;
my $home = canonical($ENV{HOME});
my @roots = map { canonical($_) } ($scratch, $tool, "$home/.claude");
push @roots, canonical($ENV{CLAUDE_CONFIG_DIR}) if length($ENV{CLAUDE_CONFIG_DIR} // "");
my @devices = map { canonical($_) } qw(/dev/null /dev/tty /dev/dtracehelper /dev/fd);
# Future .claude.json siblings and cwd markers need prefix grants; also resolve
# existing matching symlinks so their targets participate in the exclusion.
my @prefixes = ("$home/.claude.json", canonical("/private/tmp") . "/claude-");
for my $prefix (@prefixes) {
    my $dir = dirname($prefix);
    next unless -d $dir;
    opendir my $dh, $dir or die "opendir $dir: $!";
    for my $name (readdir $dh) {
        next unless index("$dir/$name", $prefix) == 0;
        next if $prefix eq $prefixes[1] && $name !~ /^claude-[0-9A-Za-z]+-cwd/;
        push @roots, canonical("$dir/$name") if -l "$dir/$name";
    }
    closedir $dh;
}
my $ctl;
for my $base ($ENV{TMPDIR} // "/tmp", "$home/Library/Caches", "$home/.cache", "/private/var/tmp", "/tmp") {
    next unless -d $base && -w $base;
    my $try = eval { canonical(tempdir("claude-review-ctl.XXXXXX", DIR => $base)) };
    next unless defined $try;
    my $overlap = grep { inside($try, $_) || inside($_, $try) } (@roots, @devices);
    $overlap ||= grep { index($try, $_) == 0 || inside($_, $try) } @prefixes;
    if ($overlap) { rmdir $try or die "rmdir $try: $!"; next; }
    $ctl = $try; last;
}
die "no control directory disjoint from all worker-writable roots; refusing exec\n" unless defined $ctl;
if ($mode eq "exec") {
    open my $fh, ">", "$ctl/profile.sb" or die "profile: $!";
    print $fh "(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*\n";
    print $fh "  (subpath ", quote_sb($_), ")\n" for @roots;
    print $fh "  (literal ", quote_sb($_), ")\n" for @devices[0..2];
    print $fh "  (subpath ", quote_sb($devices[3]), ")\n";
    print $fh "  (regex ", quote_sb("^" . quotemeta($prefixes[0])), ")\n";
    print $fh "  (regex ", quote_sb("^" . quotemeta($prefixes[1]) . "[0-9A-Za-z]+-cwd"), "))\n";
    close $fh or die "profile: $!";
}
print "$ctl\n";
'
CTL=$(perl -e "$POLICY" "$SC" "$TOOLDIR" "$TOOLS") || die "cannot isolate the control directory from worker-writable roots"

# Subscription login only, supervised and interruptible just like the worker.
"${CLEAN[@]}" perl -e "$SUP" 30 "$PS_BIN" "$CTL/descendants" "$CLAUDE_BIN" auth status > "$CTL/auth.json" 2>/dev/null &
SUP_PID=$!
AUTH_RC=0
wait "$SUP_PID" || AUTH_RC=$?
SUP_PID=''
[ "$AUTH_RC" = 0 ] || die "cannot verify the login ('$CLAUDE_BIN auth status' failed); refusing to send anything"
M=$(jq -r 'select(.loggedIn == true) | .authMethod // empty' "$CTL/auth.json" 2>/dev/null) || M=''
[ "$M" = "claude.ai" ] || die "the login is not a claude.ai subscription login (authMethod='${M:-unknown}'); refusing, because such calls could bill an API key"

# the request: harness note, the caller's prompt, then the files
{
  printf 'NOTE FROM THE HARNESS: your working directory is a throwaway scratch directory (%s); TMPDIR is %s/tmp.' "$SC" "$SC"
  if [ "$TOOLS" = exec ]; then
    printf ' Every file write outside it is denied by the operating system, so work and run harnesses only there, by absolute path, and never run anything against the real HOME or the real repository. Never kill processes by pattern (pkill, killall, tmux, launchctl): kill only a PID you started yourself.'
  fi
  [ "$TOOLS" = none ] || printf ' Copies of the attached files are under %s/in/ (the same content is also in this prompt).' "$SC"
  printf ' The caller ran this from %s, which is the project: treat it as READ-ONLY.\n\n' "$PWD"
  printf '%s\n' "$PROMPT"
  if [ ${#FILES[@]} -gt 0 ]; then
    n=0
    for f in "${FILES[@]}"; do
      n=$((n + 1)); printf '\n===== %s =====\n' "$f"; cat < "$f"
      [ "$TOOLS" = none ] || cp -- "$f" "$SC/in/${n}_$(basename -- "$f")"
    done
  fi
} > "$CTL/request.txt"
KB=$(( ($(wc -c < "$CTL/request.txt") + 1023) / 1024 ))
[ "$KB" -le "$MAXKB" ] || die "the request is $KB KB, above --max-input-kb $MAXKB"

case $TOOLS in
  exec) TL="Read,Grep,Glob,Bash,Write"; SANDBOX_NOTE="seatbelt: writes only in the scratch dir" ;;
  read) TL="Read,Grep,Glob"; SANDBOX_NOTE="read-only tools" ;;
  none) TL=""; SANDBOX_NOTE="no tools" ;;
esac
if [ -z "$EFFORT" ] && [ "$AS_REVIEWER" = 1 ]; then EFFORT=high; fi
ARGS=(-p --model "$MODEL" --output-format json --no-session-persistence --disable-slash-commands --strict-mcp-config --setting-sources "" --tools "$TL")
[ -z "$TL" ] || ARGS+=(--allowedTools "$TL")
[ -z "$EFFORT" ] || ARGS+=(--effort "$EFFORT")
PRE=()
if [ "$TOOLS" = exec ]; then
  # guard hooks only, registered here: no CLAUDE.md, rules or other hooks are loaded
  # the command string is run by a shell: each path is quoted (@sh), so a directory with spaces still works
  jq -n --arg d "$HOOKS" '{hooks:{PreToolUse:[
      {matcher:"Bash",hooks:[{type:"command",command:(($d+"/block-dangerous-bash.sh")|@sh)}]},
      {matcher:"Write|Edit",hooks:[{type:"command",command:(($d+"/block-permission-hooks.sh")|@sh)}]}]}}' > "$CTL/settings.json"
  ARGS+=(--settings "$CTL/settings.json")
  PRE=(sandbox-exec -f "$CTL/profile.sb")
fi

printf '[claude-review: tools=%s (%s) model=%s timeout=%ss request=%sKB]\n' "$TOOLS" "$SANDBOX_NOTE" "$MODEL" "$TIMEOUT" "$KB" >&2
START=$(date +%s)
RC=0
( cd "$SC" && exec "${CLEAN[@]}" TMPDIR="$SC/tmp" \
    perl -e "$SUP" "$TIMEOUT" "$PS_BIN" "$CTL/descendants" ${PRE[@]+"${PRE[@]}"} "$CLAUDE_BIN" "${ARGS[@]}" < "$CTL/request.txt" > "$CTL/raw.json" 2> "$CTL/raw.err" ) &
SUP_PID=$!
wait "$SUP_PID" || RC=$?
SUP_PID=''
DUR=$(( $(date +%s) - START ))

COST=$(jq -s -r 'if length != 1 then empty else .[0] | (if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end) | select(type == "object") | (.total_cost_usd | select(type == "number")) end' "$CTL/raw.json" 2>/dev/null) || COST=''
[ -n "$COST" ] || COST='?'
TURNS=$(jq -s -r '.[0] | (if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end) | .num_turns // empty' "$CTL/raw.json" 2>/dev/null) || TURNS=''
LED=${AMASS_LEDGER:-$HOME/.megavibe/amass-usage.jsonl}
if mkdir -p "$(dirname "$LED")" 2>/dev/null; then
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cmd review --arg model "$MODEL" --arg proj "$(basename "$PWD")" --arg tools "$TOOLS" \
    --argjson ok "$([ "$RC" = 0 ] && echo 1 || echo 0)" --arg cost "$COST" --argjson kb "$KB" --argjson dur "$DUR" \
    '{ts:$ts,cmd:$cmd,model:$model,project:$proj,tools:$tools,calls:1,ok:$ok,cost:($cost|tonumber? // null),input_kb:$kb,seconds:$dur}' >> "$LED" 2>/dev/null || true
fi
if [ "$RC" = 124 ]; then echo "$PROG: timed out after ${TIMEOUT}s (cost $COST)" >&2; exit 124; fi
if [ "$RC" != 0 ]; then echo "$PROG: the call failed (rc=$RC, cost $COST)" >&2; head -c 400 "$CTL/raw.err" >&2; exit 3; fi
jq -e -s -r 'if length != 1 then empty else .[0] | (if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end) | select(type == "object" and .is_error == false and (.result | type) == "string") | .result end' "$CTL/raw.json" > "$CTL/answer.txt" 2>/dev/null \
  || { echo "$PROG: the call returned no usable result (cost $COST)" >&2; head -c 400 "$CTL/raw.err" >&2; exit 3; }
printf '[claude-review: done in %ss, %s turn(s), cost $%s]\n' "$DUR" "${TURNS:-?}" "$COST" >&2
if [ -n "$OUT" ]; then ( umask 077; cp -- "$CTL/answer.txt" "$OUT" ) || die "cannot write $OUT"; fi
cat "$CTL/answer.txt"
