#!/bin/bash
# /bin/bash tests/claude-review.test.sh
# scripts/claude-review.sh against a FAKE claude on CLAUDE_REVIEW_CLAUDE: nothing here calls the real
# claude. On macOS the fake runs inside the REAL seatbelt the script builds, so write containment
# is asserted for real: the fake tries to write outside and inside its scratch directory and logs
# what the operating system said. The fake logs into its own scratch dir (the only place it may
# write), which the tests read through --keep-scratch.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
CR="$REPO/scripts/claude-review.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/claude-review-test.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap '/bin/rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null 2>&1 && command -v perl >/dev/null 2>&1 || { echo "SKIP: needs jq and perl"; exit 0; }
MAC=0; [ "$(uname -s)" = Darwin ] && command -v sandbox-exec >/dev/null 2>&1 && MAC=1

# All state/path tests use a fake HOME, never the real Claude configuration.
export HOME="$T/home"
unset CLAUDE_CONFIG_DIR
mkdir -p "$T/tmp" "$T/outside" "$HOME/.claude" "$HOME/Library/Caches"
if [ "${CLAUDE_REVIEW_TEST_SKIP_EXEC:-0}" = 1 ]; then MAC=0; fi
cat > "$T/fake-claude" <<'EOF'
#!/bin/bash
. "$(dirname "$0")/conf.sh" 2>/dev/null || true
if [ "${1:-}" = auth ]; then
  env | cut -d= -f1 | sort >> "$FAKE_OUTSIDE/auth.envnames"
  case "${FAKE_AUTH:-sub}" in
    apikey) echo '{"loggedIn":true,"authMethod":"apiKey"}' ;;
    broken) exit 1 ;;
    loggedout) echo '{"loggedIn":false,"authMethod":"claude.ai"}' ;;
    *) echo '{"loggedIn":true,"authMethod":"claude.ai"}' ;;
  esac
  exit 0
fi
# the worker call: log into the cwd (the scratch dir), the only place a sandboxed worker may write
printf '%s\n' "$@" > fake.argv
printf '%s' "${ANTHROPIC_API_KEY:-<unset>}" > fake.apikey
printf '%s' "${TMPDIR:-<unset>}" > fake.tmpdir
pwd > fake.cwd
echo $$ > "$FAKE_OUTSIDE/worker.pid"
echo "$PPID" > "$FAKE_OUTSIDE/supervisor.pid"
printf '%s %s fixture-%s\n' "$$" "$PPID" "$$" >> "$FAKE_OUTSIDE/ps.rows"
env | cut -d= -f1 | sort > fake.envnames
cat > fake.prompt
ls in > fake.in 2>/dev/null
( touch "$FAKE_OUTSIDE/should-not-exist" 2> fake.outside.err; echo "$?" > fake.outside.rc )
( touch ./inside-ok 2> /dev/null; echo "$?" > fake.inside.rc )
if [ -n "${FAKE_PLANT:-}" ]; then
  # a hostile worker: plant links where the parent would write, and rewrite its own settings
  ln -sf "$FAKE_OUTSIDE/victim" answer.txt 2>/dev/null; ln -sf "$FAKE_OUTSIDE/victim" raw.json 2>/dev/null
  ln -sf "$FAKE_OUTSIDE/victim" settings.json 2>/dev/null; ln -sf "$FAKE_OUTSIDE/victim" request.txt 2>/dev/null
fi
case "${FAKE_MODE:-ok}" in
  detached_timeout|detached_normal|detached_watchdog)
    # This child leaves the worker process group/session, as Claude Bash does.
    perl -MPOSIX=setsid -e '
      open my $rows, ">>", "$ARGV[1]/ps.rows" or die $!;
      print $rows "$$ ", getppid(), " fixture-$$\n"; close $rows;
      my $pid = fork(); die "fork: $!" unless defined $pid;
      if (!$pid) {
        setsid() >= 0 or die "setsid: $!";
        $SIG{TERM} = "IGNORE";
        open my $rows, ">>", "$ARGV[1]/ps.rows" or die $!;
        print $rows "$$ ", getppid(), " fixture-$$\n"; close $rows;
        sleep 30; exit 0;
      }
      open my $f, ">", $ARGV[0] or die $!; print $f "$pid\n"; close $f;
      sleep 2; # keep ancestry observable across several supervisor polls
    ' "$FAKE_OUTSIDE/child.pid" "$FAKE_OUTSIDE"
    [ "$FAKE_MODE" = detached_normal ] || sleep 30 ;;
  orphan_timeout|orphan_normal|term_child)
    # The helper never appears under the worker in the fixture: its short-lived
    # intermediate exits before a snapshot. It remains in the worker group.
    exec perl -MTime::HiRes=sleep -e '
      my ($mode, $dir) = @ARGV;
      sub helper {
        my $p = fork(); die $! unless defined $p;
        if (!$p) {
          $SIG{TERM} = "IGNORE";
          open my $f, ">", "$dir/child.pid" or die $!;
          print $f "$$\n"; close $f;
          open my $r, ">>", "$dir/ps.rows" or die $!;
          print $r "$$ 1 fixture-$$\n"; close $r;
          sleep 30; exit 0;
        }
      }
      if ($mode eq "term_child") { $SIG{TERM} = sub { helper(); exit 0 }; sleep 30; }
      else {
        my $p = fork(); die $! unless defined $p;
        if (!$p) { helper(); exit 0; }
        waitpid($p, 0);
        sleep 0.1 until -s "$dir/child.pid";
        if ($mode eq "orphan_timeout") { sleep 30; }
        print qq({"result":"ok","is_error":false}\n);
      }
    ' "$FAKE_MODE" "$FAKE_OUTSIDE" ;;
  inspect_fail) sleep 1 ;;
  child) sleep 30 & echo $! > "$FAKE_OUTSIDE/child.pid"; sleep 30 ;;
  stubborn) trap '' TERM HUP INT; sleep 30 ;;
  fail) echo boom >&2; exit 1 ;;
  slow) sleep 6 ;;
  garbled) echo "not json"; exit 0 ;;
  iserror) printf '[{"type":"result","is_error":true,"result":"x","total_cost_usd":0.1}]'; exit 0 ;;
esac
jq -n '[{"type":"system"},{"type":"result","is_error":false,"result":"F1 | P2 | a.sh:1 | something | because","total_cost_usd":0.005,"num_turns":3}]'
EOF
chmod +x "$T/fake-claude"
export CLAUDE_REVIEW_CLAUDE="$T/fake-claude" AMASS_LEDGER="$T/ledger.jsonl" TMPDIR="$T/tmp" FAKE_OUTSIDE="$T/outside"
export ANTHROPIC_API_KEY=example-placeholder-not-a-key
export ANTHROPIC_CUSTOM_HEADERS=$'Authorization:\nx-api-key: example-placeholder' ANTHROPIC_FOUNDRY_API_KEY=example AWS_BEARER_TOKEN_BEDROCK=example ANTHROPIC_FUTURE_SWITCH=1 CLAUDE_CODE_USE_ANYTHING=1
printf 'alpha\nbeta\n' > "$T/a.txt"; printf 'gamma\n' > "$T/b.txt"

# The worker runs in an allow-listed environment, so the fake cannot be steered through environment
# variables. It reads its settings from conf.sh next to it; fk writes them for one command, then resets.
defconf() { { printf 'export FAKE_LOG=%q\n' "${FAKE_LOG:-}"; printf 'export FAKE_OUTSIDE=%q\n' "${FAKE_OUTSIDE:-}"; } > "$T/conf.sh"; }
fk() {
  defconf
  while [ "$1" != -- ]; do printf 'export %s=%q\n' "${1%%=*}" "${1#*=}" >> "$T/conf.sh"; shift; done
  shift
  "$@"; local rc=$?
  defconf
  return $rc
}
defconf
kept() { ls -d "$T"/tmp/claude-review-scratch.* 2>/dev/null | head -1; }
clean_kept() { /bin/rm -rf "$T"/tmp/claude-review-scratch.* "$T"/tmp/claude-review-ctl.* 2>/dev/null; }
ctl() { ls -d "$T"/tmp/claude-review-ctl.* 2>/dev/null | head -1; }

check "bash -n" '/bin/bash -n "$CR"'
SUP=$(sed -n "/^SUP='$/,/^'$/p" "$CR" | sed '1d;$d')
check "supervisor compiles" 'perl -c -e "$SUP" >/dev/null 2>&1'
check "no bashisms past 3.2" '! grep -nE "mapfile|readarray|declare -A|wait -n|\$\{[A-Za-z_]+,,\}" "$CR"'

# Exercise exactly the policy used by the wrapper without needing sandbox-exec
# or process inspection. This also permits useful checks inside nested seatbelt.
POLICY=$(sed -n "/^POLICY='$/,/^'$/p" "$CR" | sed '1d;$d')
profile_disjoint() {
  perl - "$1" <<'CHECK'
use strict;
my $ctl = shift;
open my $f, "<", "$ctl/profile.sb" or exit 1;
sub inside { $_[1] eq "/" || $_[0] eq $_[1] || index($_[0], "$_[1]/") == 0 }
my $grants = 0;
while (<$f>) {
    if (/\((subpath|literal|regex) #?"((?:\\.|[^"\\])*)"\)/) {
        my ($kind, $path) = ($1, $2);
        $path =~ s/\\(["\\])/$1/g;
        if ($kind eq "regex") { exit 1 if $ctl =~ /$path/; }
        else { exit 1 if inside($ctl, $path) || inside($path, $ctl); }
        $grants++;
    }
}
exit($grants >= 8 ? 0 : 1);
CHECK
}
policy_case() {
  local name=$1 base=$2 cfg=$3 c rc
  mkdir -p "$base" "$base/claude-review-scratch.policy"
  c=$(TMPDIR="$base" CLAUDE_CONFIG_DIR="$cfg" perl -e "$POLICY" \
      "$base/claude-review-scratch.policy" "$T/tool-folder" exec 2>"$T/policy.err")
  rc=$?
  if [ "$rc" = 0 ]; then
    check "$name: control is disjoint from every profile grant" 'profile_disjoint "$c"'
    case $c in "$HOME/Library/Caches/"*) ok ;; *) bad "$name: expected safe cache fallback" ;; esac
    /bin/rm -rf "$c"
  else
    bad "$name: policy generation failed"
    cat "$T/policy.err"
  fi
}
policy_case "config equals TMPDIR" "$T/tmp" "$T/tmp"
policy_case "TMPDIR below .claude" "$HOME/.claude/tmp" ""
# Symlink spelling must resolve to the same grant/exclusion path.
ln -s "$HOME/.claude" "$T/state-link"
policy_case "symlinked TMPDIR and config" "$T/state-link/tmp" "$T/state-link"
c=$(TMPDIR="$T/tmp" CLAUDE_CONFIG_DIR=/ perl -e "$POLICY" "$T/tmp" "$T/tool-folder" exec 2>"$T/policy.err"); rc=$?
check "overlap with every candidate refuses control creation clearly" '[ $rc -ne 0 ] && grep -q "no control directory disjoint" "$T/policy.err"'
/bin/rm -rf "$T/tmp/claude-review-scratch.policy"

# usage and refusals
"$CR" --tools none a.txt >/dev/null 2>&1; rc=$?
check "no prompt is refused" '[ $rc -eq 2 ]'
"$CR" --prompt p --tools bogus "$T/a.txt" >/dev/null 2>&1; rc=$?
check "bad --tools refused" '[ $rc -eq 2 ]'
"$CR" --prompt p --model "--evil" "$T/a.txt" >/dev/null 2>&1; rc=$?
check "option-looking model refused" '[ $rc -eq 2 ]'
"$CR" --prompt p --timeout 0 "$T/a.txt" >/dev/null 2>&1; rc=$?
check "timeout 0 refused (it would disable the deadline)" '[ $rc -eq 2 ]'
"$CR" --prompt p --sandbox danger-full-access "$T/a.txt" >/dev/null 2>&1; rc=$?
check "a caller-supplied sandbox or permission mode is refused" '[ $rc -eq 2 ]'
"$CR" --prompt p --permission-mode bypassPermissions "$T/a.txt" >/dev/null 2>&1; rc=$?
check "--permission-mode refused" '[ $rc -eq 2 ]'
head -c 2000 /dev/zero > "$T/bin.dat"
"$CR" --prompt p --tools none "$T/bin.dat" >/dev/null 2>&1; rc=$?
check "a binary file is refused" '[ $rc -eq 2 ]'
# A deterministic process table lets all non-seatbelt checks run when /bin/ps
# is denied. Only our fake processes register rows; unobserved orphans report
# PPID 1. Real ps remains the default outside this restricted environment.
REAL_PS=1
/bin/ps -axo pid=,ppid=,lstart= >/dev/null 2>&1 || REAL_PS=0
cat > "$T/ps-fixture" <<'EOF'
#!/usr/bin/perl
use strict;
use FindBin;
my $dir = "$FindBin::Bin/outside";
my $mode = "";
if (open my $f, "<", "$dir/ps.mode") { chomp($mode = <$f> // ""); }
if ($mode eq "pre_fail") { exit 1; }
my ($sentinel, $worker);
if ($mode =~ /^sentinel_/) {
    if (open my $f, "<", "$dir/sentinel.pid") { chomp($sentinel = <$f>); }
    if (open my $f, "<", "$dir/worker.pid") { chomp($worker = <$f>); }
    if (-e "$dir/sentinel.observed") {
        # The first table reported this test-owned process as a descendant.
        # Later tables either fail or show a reused PID with a different start.
        exit 1 if $mode eq "sentinel_fail";
        my $start = $mode eq "sentinel_match" ? "fixture-$sentinel" : "changed-$sentinel";
        print "$sentinel 1 $start\n";
    }
}
if ($mode eq "observed" && -s "$dir/child.pid") {
    open my $f, ">>", "$dir/snapshots" or die $!;
    print $f "snapshot\n"; close $f;
}
if (-s "$dir/worker.pid") {
    if ($mode eq "slow") { select(undef, undef, undef, 1.2); }
    if ($mode eq "fail") { exit 1; }
    if ($mode eq "block") {
        open my $f, ">", "$dir/inspection.pid" or die $!;
        print $f "$$\n"; close $f;
        my $child = fork(); die $! unless defined $child;
        if (!$child) { exec "/bin/sleep", "30"; exit 127; }
        open my $c, ">", "$dir/inspection-child.pid" or die $!;
        print $c "$child\n"; close $c;
        sleep 30;
        waitpid($child, 0);
        exit 0;
    }
}
if (-e "$dir/use-real-ps" && $mode !~ /^(identity_|sentinel_)/) { exec "/bin/ps", @ARGV; exit 127; }
if (open my $f, "<", "$dir/ps.rows") {
    while (<$f>) {
        my ($pid, $parent, $start) = split;
        next unless $pid && kill(0, $pid);
        $parent = 1 unless kill(0, $parent);
        $start = "changed-$start" if $mode eq "identity_change" && -e "$dir/term.received";
        print "$pid $parent $start\n";
        if ($worker && $pid == $worker && !-e "$dir/sentinel.observed") {
            print "$sentinel $worker fixture-$sentinel\n";
            open my $seen, ">", "$dir/sentinel.observed" or die $!;
            print $seen "observed\n"; close $seen;
        }
    }
}
EOF
chmod +x "$T/ps-fixture"
if [ "$REAL_PS" = 0 ]; then
  echo "note: using controlled ps fixture; real process-table inspection is denied"
  export CLAUDE_REVIEW_TESTING=1 CLAUDE_REVIEW_TEST_PS="$T/ps-fixture"
else
  touch "$T/outside/use-real-ps"
fi
fk FAKE_AUTH=apikey -- "$CR" --prompt p --tools none "$T/a.txt" >/dev/null 2>&1; rc=$?
check "an API-key login is refused" '[ $rc -eq 2 ] && [ -z "$(kept)" ]'
fk FAKE_AUTH=broken -- "$CR" --prompt p --tools none "$T/a.txt" >/dev/null 2>&1; rc=$?
check "an unverifiable login is refused" '[ $rc -eq 2 ]'
out=$("$CR" --prompt p --tools none --max-input-kb 1 "$T/a.txt" 2>&1 < /dev/null); [ -f "$T/big.txt" ] || head -c 5000 /dev/zero | tr '\0' 'x' > "$T/big.txt"
"$CR" --prompt p --tools none --max-input-kb 1 "$T/big.txt" >/dev/null 2>&1; rc=$?
check "an oversized request is refused" '[ $rc -eq 2 ]'

# tools none: nothing but the prompt
clean_kept
out=$("$CR" --prompt "review this" --tools none --keep-scratch --out "$T/ans.txt" "$T/a.txt" "$T/b.txt" 2>"$T/err.txt"); rc=$?
S0=$(kept)
check "tools none exits 0 and prints the answer" '[ $rc -eq 0 ] && echo "$out" | grep -q "F1 | P2"'
check "--out got the answer, mode 600" 'grep -q "F1 | P2" "$T/ans.txt" && [ "$(stat -f %Lp "$T/ans.txt" 2>/dev/null || stat -c %a "$T/ans.txt")" = 600 ]'
check "tools none: empty tool list, no allowedTools, no settings" 'sed -n "/^--tools\$/{n;p;}" "$S0/fake.argv" | grep -qx "" && ! grep -qx -- "--allowedTools" "$S0/fake.argv" && ! grep -qx -- "--settings" "$S0/fake.argv"'
check "the flags that isolate the call are all present" 'grep -qx -- "--no-session-persistence" "$S0/fake.argv" && grep -qx -- "--strict-mcp-config" "$S0/fake.argv" && grep -qx -- "--disable-slash-commands" "$S0/fake.argv" && sed -n "/^--setting-sources\$/{n;p;}" "$S0/fake.argv" | grep -qx ""'
check "model defaults to sonnet" 'sed -n "/^--model\$/{n;p;}" "$S0/fake.argv" | grep -qx sonnet'
check "files are appended as ===== path ===== blocks, harness note first" 'grep -q "===== $T/a.txt =====" "$S0/fake.prompt" && grep -q "alpha" "$S0/fake.prompt" && grep -q "gamma" "$S0/fake.prompt" && head -c 40 "$S0/fake.prompt" | grep -q "NOTE FROM THE HARNESS"'
check "the caller dir is named as read-only project" 'grep -q "which is the project: treat it as READ-ONLY" "$S0/fake.prompt"'
check "the worker sees an allow-listed environment: nothing ANTHROPIC, AWS or cloud-switch, PATH and HOME present" '! grep -qE "ANTHROPIC|AWS_|CLAUDE_CODE_USE" "$S0/fake.envnames" && grep -qx PATH "$S0/fake.envnames" && grep -qx HOME "$S0/fake.envnames"'
check "the login check runs in the same allow-listed environment" '[ -s "$T/outside/auth.envnames" ] && ! grep -qE "ANTHROPIC|AWS_|CLAUDE_CODE_USE" "$T/outside/auth.envnames"'
check "the API key is removed from the worker environment" '[ "$(cat "$S0/fake.apikey")" = "<unset>" ]'
check "the worker runs in its scratch dir with TMPDIR inside it" '[ "$(cat "$S0/fake.cwd")" = "$S0" ] && [ "$(cat "$S0/fake.tmpdir")" = "$S0/tmp" ]'
check "no copies of the files for tools none" '[ -z "$(cat "$S0/fake.in")" ]'
check "the cost and turns are reported" 'grep -q "cost \$0.005" "$T/err.txt" && grep -q "3 turn" "$T/err.txt"'
check "one ledger line for the call" 'jq -e "select(.cmd == \"review\") | .ok == 1 and .tools == \"none\" and .cost == 0.005 and .model == \"sonnet\"" "$AMASS_LEDGER" >/dev/null'
check "no key material in the ledger" '! grep -q "example-placeholder" "$AMASS_LEDGER"'
clean_kept

# tools read
out=$("$CR" --prompt "p" --tools read --keep-scratch "$T/a.txt" 2>/dev/null); S1=$(kept)
check "tools read: Read, Grep, Glob only, and copies of the files in in/" 'sed -n "/^--tools\$/{n;p;}" "$S1/fake.argv" | grep -qx "Read,Grep,Glob" && grep -q "a.txt" "$S1/fake.in"'
clean_kept

# tools exec (needs the macOS seatbelt)
if [ "$MAC" = 1 ]; then
  # the runs above had no sandbox, so the fake could create this file; start clean
  rm -f "$T/outside/should-not-exist"
  out=$("$CR" --prompt "p" --as-reviewer --keep-scratch "$T/a.txt" 2>"$T/err2.txt"); rc=$?; S2=$(kept)
  check "exec is the default under --as-reviewer and runs" '[ $rc -eq 0 ] && grep -q "tools=exec" "$T/err2.txt"'
  check "exec tool set and allowedTools" 'sed -n "/^--tools\$/{n;p;}" "$S2/fake.argv" | grep -qx "Read,Grep,Glob,Bash,Write" && sed -n "/^--allowedTools\$/{n;p;}" "$S2/fake.argv" | grep -qx "Read,Grep,Glob,Bash,Write"'
  check "the guard hooks are registered through --settings, without loading other settings" 'jq -e ".hooks.PreToolUse[0].hooks[0].command | contains(\"block-dangerous-bash.sh\")" "$(ctl)/settings.json" >/dev/null && sed -n "/^--setting-sources\$/{n;p;}" "$S2/fake.argv" | grep -qx ""'
  check "a write OUTSIDE the scratch dir is denied by the operating system" '[ "$(cat "$S2/fake.outside.rc")" != 0 ] && [ ! -e "$T/outside/should-not-exist" ] && grep -qi "not permitted" "$S2/fake.outside.err"'
  check "a write INSIDE the scratch dir works" '[ "$(cat "$S2/fake.inside.rc")" = 0 ] && [ -e "$S2/inside-ok" ]'
  check "the profile allows only the scratch dir, the worker tool folder and claude state" 'grep -q "(deny file-write\*)" "$(ctl)/profile.sb" && grep -q "subpath \"$S2\"" "$(ctl)/profile.sb" && ! grep -q "subpath \"/private/tmp\")" "$(ctl)/profile.sb" && ! grep -q "subpath \"/Users\")" "$(ctl)/profile.sb"'
  clean_kept
  # without --keep-scratch the scratch dir is gone, also when the call fails
  fk FAKE_MODE=fail -- "$CR" --prompt p --as-reviewer "$T/a.txt" >/dev/null 2>&1; rc=$?
  check "a failed exec call exits 3 and leaves no scratch dir" '[ $rc -eq 3 ] && [ -z "$(kept)" ]'
elif [ "${CLAUDE_REVIEW_TEST_SKIP_EXEC:-0}" = 1 ]; then
  echo "SKIP: real exec containment requested off (nested seatbelt)"
else
  echo "note: exec tests skipped (no macOS sandbox-exec here)"
  "$CR" --prompt p --tools exec "$T/a.txt" >/dev/null 2>&1; rc=$?
  check "exec is refused where writes cannot be confined" '[ $rc -eq 2 ]'
fi

# failures, timeouts
fk FAKE_MODE=fail -- "$CR" --prompt p --tools none "$T/a.txt" >/dev/null 2>&1; rc=$?
check "a failing call exits 3" '[ $rc -eq 3 ]'
fk FAKE_MODE=garbled -- "$CR" --prompt p --tools none "$T/a.txt" >/dev/null 2>&1; rc=$?
check "garbled output exits 3" '[ $rc -eq 3 ]'
fk FAKE_MODE=iserror -- "$CR" --prompt p --tools none "$T/a.txt" >/dev/null 2>&1; rc=$?
check "an is_error result exits 3" '[ $rc -eq 3 ]'
start=$(date +%s)
fk FAKE_MODE=slow -- "$CR" --prompt p --tools none --timeout 1 "$T/a.txt" >/dev/null 2>&1; rc=$?
dur=$(( $(date +%s) - start ))
check "a hanging call is killed: exit 124 within the bound" '[ $rc -eq 124 ] && [ $dur -lt 5 ]'
check "a failed or timed-out call is in the ledger with ok=0" 'jq -s -e "map(select(.ok == 0)) | length >= 2" "$AMASS_LEDGER" >/dev/null'
check "no scratch dir is left behind by any of the runs" '[ -z "$(kept)" ]'

# a file whose name starts with - is a file, not an option, and is read from the file
mkdir -p "$T/dash" && printf 'dash-file-content\n' > "$T/dash/-n"
clean_kept
out=$( cd "$T/dash" && "$CR" --prompt p --tools read --keep-scratch -- -n < /dev/null 2>/dev/null ); rc=$?
S9=$(kept)
check "a file named -n is inlined and copied by its content" '[ $rc -eq 0 ] && grep -q "dash-file-content" "$S9/fake.prompt" && grep -q "===== ./-n =====" "$S9/fake.prompt"'
clean_kept

# regressions for the ship round
# a logged-out status is not a subscription login, whatever authMethod says
fk FAKE_AUTH=loggedout -- "$CR" --prompt p --tools none "$T/a.txt" >/dev/null 2>&1; rc=$?
check "loggedIn must be true, not only authMethod" '[ $rc -eq 2 ]'
# the timeout supervises the whole process group
rm -f "$T/outside/child.pid"
start=$(date +%s)
fk FAKE_MODE=child -- "$CR" --prompt p --tools none --timeout 1 "$T/a.txt" >/dev/null 2>&1; rc=$?
dur=$(( $(date +%s) - start ))
sleep 1
check "a timed-out worker's children die with it" '[ $rc -eq 124 ] && [ -s "$T/outside/child.pid" ] && ! kill -0 "$(cat "$T/outside/child.pid")" 2>/dev/null'
start=$(date +%s)
fk FAKE_MODE=stubborn -- "$CR" --prompt p --tools none --timeout 1 "$T/a.txt" >/dev/null 2>&1; rc=$?
dur=$(( $(date +%s) - start ))
check "a worker that ignores TERM is killed after the grace period (exit 124, bounded)" '[ $rc -eq 124 ] && [ $dur -lt 8 ]'
# Detached descendants must die on both deadline and successful completion.
for mode in detached_timeout detached_normal; do
  rm -f "$T/outside/child.pid"
  limit=1; expected=124
  if [ "$mode" = detached_normal ]; then limit=10; expected=0; fi
  start=$(date +%s)
  fk FAKE_MODE="$mode" -- "$CR" --prompt p --tools none --timeout "$limit" "$T/a.txt" >/dev/null 2>&1; rc=$?
  dur=$(( $(date +%s) - start ))
  sleep 1
  check "$mode: detached child is dead, with expected status and bounded cleanup" '[ $rc -eq $expected ] && [ $dur -lt 8 ] && [ -s "$T/outside/child.pid" ] && ! kill -0 "$(cat "$T/outside/child.pid")" 2>/dev/null'
  # Only this test child, if a regression left it alive.
  if [ -s "$T/outside/child.pid" ]; then kill -KILL "$(cat "$T/outside/child.pid")" 2>/dev/null || true; fi
done

# TERM goes only to the wrapper PID; no process-group signal from the test.
clean_kept
rm -f "$T/outside/worker.pid"
defconf
printf 'export FAKE_MODE=stubborn\n' >> "$T/conf.sh"
"$CR" --prompt p --tools none --timeout 30 "$T/a.txt" >"$T/signal.out" 2>"$T/signal.err" &
wrapper=$!
n=0
while [ ! -s "$T/outside/worker.pid" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
signal_sc=$(kept); signal_ctl=$(ctl)
start=$(date +%s)
kill -TERM "$wrapper" 2>/dev/null || true
wait "$wrapper"; rc=$?
dur=$(( $(date +%s) - start ))
defconf
check "TERM to wrapper stops the worker and returns promptly" '[ $rc -eq 143 ] && [ $dur -lt 8 ] && [ -s "$T/outside/worker.pid" ] && ! kill -0 "$(cat "$T/outside/worker.pid")" 2>/dev/null'
check "TERM cleans scratch and control only after stopping the worker" '[ -n "$signal_sc" ] && [ -n "$signal_ctl" ] && [ ! -e "$signal_sc" ] && [ ! -e "$signal_ctl" ]'
if [ -s "$T/outside/worker.pid" ]; then kill -KILL "$(cat "$T/outside/worker.pid")" 2>/dev/null || true; fi

# Round-3 regressions: group coverage must not depend on ancestry observation.
for mode in orphan_timeout orphan_normal term_child; do
  rm -f "$T/outside/child.pid"
  limit=1; expected=124
  if [ "$mode" = orphan_normal ]; then limit=10; expected=0; fi
  start=$(date +%s)
  fk FAKE_MODE="$mode" -- "$CR" --prompt p --tools none --timeout "$limit" "$T/a.txt" >/dev/null 2>&1; rc=$?
  dur=$(( $(date +%s) - start ))
  sleep 0.2
  check "$mode: group cleanup kills even an unobserved helper" '[ $rc -eq $expected ] && [ $dur -lt 8 ] && [ -s "$T/outside/child.pid" ] && ! kill -0 "$(cat "$T/outside/child.pid")" 2>/dev/null'
  if [ -s "$T/outside/child.pid" ]; then kill -KILL "$(cat "$T/outside/child.pid")" 2>/dev/null || true; fi
done

# These fault injections always use the guarded override, including on hosts
# where real ps works. It is not an ordinary-user ps configuration option.
export CLAUDE_REVIEW_TESTING=1 CLAUDE_REVIEW_TEST_PS="$T/ps-fixture"
rm -f "$T/outside/worker.pid"
echo pre_fail > "$T/outside/ps.mode"
"$CR" --prompt p --tools none "$T/a.txt" >/dev/null 2>&1; rc=$?
check "pre-start ps failure refuses to launch and cleans directories" '[ $rc -ne 0 ] && [ ! -e "$T/outside/worker.pid" ] && [ -z "$(kept)" ] && [ -z "$(ctl)" ]'

# a ps that is slow but works (1.2 s per table, a loaded machine) is not an inspection loss
rm -f "$T/outside/worker.pid"
echo slow > "$T/outside/ps.mode"
fk FAKE_MODE=inspect_fail -- "$CR" --prompt p --tools none --timeout 20 "$T/a.txt" >"$T/slow.out" 2>"$T/slow.err"; rc=$?
check "a slow but working ps is not an inspection loss: exit 0, answer kept, no warning" '[ $rc -eq 0 ] && grep -q "F1 | P2" "$T/slow.out" && ! grep -q "inspection unavailable" "$T/slow.err"'
if [ -s "$T/outside/worker.pid" ]; then kill -KILL "$(cat "$T/outside/worker.pid")" 2>/dev/null || true; fi

for fault in fail block; do
  rm -f "$T/outside/worker.pid" "$T/outside/inspection.pid" "$T/outside/inspection-child.pid"
  echo "$fault" > "$T/outside/ps.mode"
  mode=inspect_fail; limit=5; expected=0   # a lost ps only narrows cleanup; the finished worker's answer is kept
  if [ "$fault" = block ]; then mode=stubborn; limit=1; expected=124; fi
  start=$(date +%s)
  fk FAKE_MODE="$mode" -- "$CR" --prompt p --tools none --timeout "$limit" "$T/a.txt" >"$T/fault.out" 2>"$T/fault.err"; rc=$?
  dur=$(( $(date +%s) - start ))
  check "ps $fault after start: bounded exit with the worker's own status and a dead worker" '[ $rc -eq $expected ] && [ $dur -lt 8 ] && [ -s "$T/outside/worker.pid" ] && ! kill -0 "$(cat "$T/outside/worker.pid")" 2>/dev/null'
  if [ "$fault" = fail ]; then
    check "ps fail after start: the finished worker's answer is delivered and the loss is warned" 'grep -q "F1 | P2" "$T/fault.out" && grep -q "process inspection was unavailable" "$T/fault.err"'
  fi
  check "ps $fault after start: scratch and control directories cleaned" '[ -z "$(kept)" ] && [ -z "$(ctl)" ]'
  if [ "$fault" = block ]; then
    check "blocked inspection subprocess and its child are killed" '[ -s "$T/outside/inspection.pid" ] && ! kill -0 "$(cat "$T/outside/inspection.pid")" 2>/dev/null && [ -s "$T/outside/inspection-child.pid" ] && ! kill -0 "$(cat "$T/outside/inspection-child.pid")" 2>/dev/null'
    for f in inspection inspection-child; do
      if [ -s "$T/outside/$f.pid" ]; then kill -KILL "$(cat "$T/outside/$f.pid")" 2>/dev/null || true; fi
    done
  fi
  if [ -s "$T/outside/worker.pid" ]; then kill -KILL "$(cat "$T/outside/worker.pid")" 2>/dev/null || true; fi
done

# TERM during a blocked snapshot, and a stopped supervisor that needs its
# independent watchdog. Signal only PIDs launched by this test invocation.
for fault in block stopped stopped_block; do
  rm -f "$T/outside/worker.pid" "$T/outside/inspection.pid" "$T/outside/inspection-child.pid" "$T/outside/supervisor.pid"
  case $fault in *block) echo block ;; *) echo "$fault" ;; esac > "$T/outside/ps.mode"
  defconf
  printf 'export FAKE_MODE=stubborn\n' >> "$T/conf.sh"
  "$CR" --prompt p --tools none --timeout 30 "$T/a.txt" >"$T/signal.out" 2>"$T/signal.err" &
  wrapper=$!
  marker="$T/outside/worker.pid"
  case $fault in *block) marker="$T/outside/inspection-child.pid" ;; esac
  n=0
  while [ ! -s "$marker" ] && [ "$n" -lt 100 ]; do sleep 0.02; n=$((n + 1)); done
  if [ "$fault" != block ] && [ -s "$T/outside/supervisor.pid" ]; then
    kill -STOP "$(cat "$T/outside/supervisor.pid")" 2>/dev/null || true
  fi
  start=$(date +%s)
  kill -TERM "$wrapper" 2>/dev/null || true
  wait "$wrapper"; rc=$?
  dur=$(( $(date +%s) - start ))
  defconf
  sleep 0.2
  check "TERM with $fault inspection/supervisor kills workload within bound" '[ $rc -eq 143 ] && [ $dur -lt 8 ] && [ -s "$T/outside/worker.pid" ] && ! kill -0 "$(cat "$T/outside/worker.pid")" 2>/dev/null'
  check "TERM with $fault inspection/supervisor cleans directories" '[ -z "$(kept)" ] && [ -z "$(ctl)" ]'
  if [ "$fault" != stopped ]; then
    check "TERM with $fault also kills the inspection group" '[ -s "$T/outside/inspection.pid" ] && ! kill -0 "$(cat "$T/outside/inspection.pid")" 2>/dev/null && [ -s "$T/outside/inspection-child.pid" ] && ! kill -0 "$(cat "$T/outside/inspection-child.pid")" 2>/dev/null'
  fi
  for f in worker inspection inspection-child supervisor; do
    if [ -s "$T/outside/$f.pid" ]; then kill -KILL "$(cat "$T/outside/$f.pid")" 2>/dev/null || true; fi
  done
done

# A detached child already observed by the supervisor must remain covered when
# that supervisor can no longer clean up. Wait for several fixture snapshots AND
# the published identity, so these cases do not test the unobserved-child risk.
for fault in killed stopped_term; do
  clean_kept
  rm -f "$T/outside/worker.pid" "$T/outside/child.pid" "$T/outside/supervisor.pid" "$T/outside/snapshots"
  echo observed > "$T/outside/ps.mode"
  defconf
  printf 'export FAKE_MODE=detached_watchdog\n' >> "$T/conf.sh"
  "$CR" --prompt p --tools none --timeout 30 "$T/a.txt" >"$T/signal.out" 2>"$T/signal.err" &
  wrapper=$!
  n=0; observed=0
  while [ "$n" -lt 100 ]; do
    signal_sc=$(kept); signal_ctl=$(ctl)
    if [ -s "$T/outside/child.pid" ] && [ -s "$T/outside/snapshots" ] &&
       [ "$(wc -l < "$T/outside/snapshots")" -ge 5 ] &&
       grep -q "^$(cat "$T/outside/child.pid") " "$signal_ctl/descendants" 2>/dev/null; then
      observed=1; break
    fi
    sleep 0.05; n=$((n + 1))
  done
  check "$fault: detached child identity published after several snapshots" '[ "$observed" = 1 ]'
  start=$(date +%s)
  expected=3
  if [ -s "$T/outside/supervisor.pid" ]; then
    supervisor=$(cat "$T/outside/supervisor.pid")
    if [ "$fault" = killed ]; then
      kill -KILL "$supervisor" 2>/dev/null || true
    else
      kill -STOP "$supervisor" 2>/dev/null || true
      kill -TERM "$wrapper" 2>/dev/null || true
      expected=143
    fi
  else
    kill -TERM "$wrapper" 2>/dev/null || true
  fi
  wait "$wrapper"; rc=$?
  dur=$(( $(date +%s) - start ))
  defconf
  sleep 0.2
  check "$fault: observed setsid child ignoring TERM is killed within bound" '[ $rc -eq $expected ] && [ $dur -lt 8 ] && [ -s "$T/outside/child.pid" ] && ! kill -0 "$(cat "$T/outside/child.pid")" 2>/dev/null'
  check "$fault: scratch and control directories are both cleaned" '[ -n "$signal_sc" ] && [ -n "$signal_ctl" ] && [ ! -e "$signal_sc" ] && [ ! -e "$signal_ctl" ] && [ -z "$(kept)" ] && [ -z "$(ctl)" ]'
  for f in worker child supervisor; do
    if [ -s "$T/outside/$f.pid" ]; then kill -KILL "$(cat "$T/outside/$f.pid")" 2>/dev/null || true; fi
  done
done
rm -f "$T/outside/ps.mode"

# A test-owned sentinel is deliberately misreported as a descendant once, then
# inspection fails or its identity changes; a matching identity is the positive
# control. It is detached from the worker group, so only an individual signal
# could touch it. Exercise main cleanup and the watchdog with a stopped parent.
for route in main watchdog; do
  for fault in fail mismatch match; do
    clean_kept
    rm -f "$T/outside/worker.pid" "$T/outside/supervisor.pid" "$T/outside/sentinel.observed" "$T/outside/sentinel.ready" "$T/outside/sentinel.term"
    echo "sentinel_$fault" > "$T/outside/ps.mode"
    perl -MPOSIX=setsid -e '
      my $dir = shift;
      setsid() >= 0 or die "setsid: $!";
      $SIG{TERM} = sub {
        open my $f, ">", "$dir/sentinel.term" or die $!;
        print $f "TERM\n"; close $f;
      };
      open my $f, ">", "$dir/sentinel.ready" or die $!;
      print $f "ready\n"; close $f;
      sleep 30 while 1;
    ' "$T/outside" &
    sentinel=$!
    echo "$sentinel" > "$T/outside/sentinel.pid"
    n=0
    while [ ! -s "$T/outside/sentinel.ready" ] && [ "$n" -lt 100 ]; do sleep 0.02; n=$((n + 1)); done
    defconf
    printf 'export FAKE_MODE=stubborn\n' >> "$T/conf.sh"
    limit=1; expected=124
    if [ "$route" = watchdog ]; then limit=30; expected=3; fi
    "$CR" --prompt p --tools none --timeout "$limit" "$T/a.txt" >"$T/sentinel.out" 2>"$T/sentinel.err" &
    wrapper=$!
    if [ "$route" = watchdog ]; then
      n=0; observed=0
      while [ "$n" -lt 100 ]; do
        signal_ctl=$(ctl)
        if grep -q "^$sentinel fixture-$sentinel$" "$signal_ctl/descendants" 2>/dev/null; then
          observed=1; break
        fi
        sleep 0.02; n=$((n + 1))
      done
      check "$route/$fault: sentinel identity published for watchdog" '[ "$observed" = 1 ]'
      if [ "$observed" = 1 ] && [ -s "$T/outside/supervisor.pid" ]; then
        # Keep the wrapper waiting until the watchdog finishes both signal
        # phases, so it cannot remove the state file before the watchdog reads.
        kill -STOP "$(cat "$T/outside/supervisor.pid")" 2>/dev/null || true
      else
        kill -TERM "$wrapper" 2>/dev/null || true
      fi
    fi
    wait "$wrapper"; rc=$?
    defconf
    if [ "$fault" = match ]; then
      check "$route/$fault: matching detached child receives TERM and KILL" '[ -s "$T/outside/sentinel.observed" ] && [ -s "$T/outside/sentinel.term" ] && ! kill -0 "$sentinel" 2>/dev/null'
    else
      check "$route/$fault: observed sentinel receives no TERM or KILL and survives" '[ -s "$T/outside/sentinel.observed" ] && [ ! -e "$T/outside/sentinel.term" ] && kill -0 "$sentinel" 2>/dev/null'
    fi
    check "$route/$fault: expected exit and worker group dead" '[ $rc -eq $expected ] && [ -s "$T/outside/worker.pid" ] && ! kill -0 -- "-$(cat "$T/outside/worker.pid")" 2>/dev/null'
    kill -KILL "$sentinel" 2>/dev/null || true
    wait "$sentinel" 2>/dev/null || true
  done
done
rm -f "$T/outside/ps.mode"

# Exercise the wrapper fallback directly with a process owned by this test.
# The shim simulates PID reuse without ever targeting an unrelated process,
# including an identity change between the TERM and KILL phases.
for mode in identity_stale identity_change identity_match; do
  rm -f "$T/outside/identity.ready" "$T/outside/term.received"
  echo "$mode" > "$T/outside/ps.mode"
  perl -e '
    my $dir = shift;
    $SIG{TERM} = sub {
      open my $f, ">", "$dir/term.received" or die $!;
      print $f "TERM\n"; close $f;
    };
    open my $r, ">>", "$dir/ps.rows" or die $!;
    print $r "$$ ", getppid(), " fixture-$$\n"; close $r;
    open my $f, ">", "$dir/identity.ready" or die $!;
    print $f "ready\n"; close $f;
    sleep 30 while 1;
  ' "$T/outside" &
  target=$!
  n=0
  while [ ! -s "$T/outside/identity.ready" ] && [ "$n" -lt 100 ]; do sleep 0.02; n=$((n + 1)); done
  identity="fixture-$target"
  [ "$mode" != identity_stale ] || identity="old-$identity"
  printf '%s %s\n' "$target" "$identity" > "$T/observed"
  perl -e "$SUP" cleanup "$T/ps-fixture" "$T/observed" >"$T/identity.out" 2>"$T/identity.err"; rc=$?
  case $mode in
    identity_stale) check "fallback skips TERM and KILL for a stale identity" '[ $rc -eq 0 ] && kill -0 "$target" 2>/dev/null && [ ! -e "$T/outside/term.received" ]' ;;
    identity_change) check "fallback rechecks identity before KILL after sending TERM" '[ $rc -eq 0 ] && kill -0 "$target" 2>/dev/null && [ -s "$T/outside/term.received" ]' ;;
    identity_match) check "fallback sends TERM then KILL for a matching identity" '[ $rc -eq 0 ] && ! kill -0 "$target" 2>/dev/null && [ -s "$T/outside/term.received" ]' ;;
  esac
  kill -KILL "$target" 2>/dev/null || true
  wait "$target" 2>/dev/null || true
done
rm -f "$T/outside/ps.mode"
if [ "$REAL_PS" = 1 ]; then unset CLAUDE_REVIEW_TESTING CLAUDE_REVIEW_TEST_PS; fi

if [ "$MAC" = 1 ]; then
  # Run the wrapper too: the two overlapping configurations must select a
  # disjoint control directory (or refuse before the fake worker can start).
  for layout in config_tmp home_tmp; do
    clean_kept
    case $layout in
      config_tmp) base="$T/tmp"; cfg="$T/tmp" ;;
      home_tmp) base="$HOME/.claude/tmp"; cfg="" ;;
    esac
    rm -f "$T/outside/worker.pid"
    out=$(TMPDIR="$base" CLAUDE_CONFIG_DIR="$cfg" "$CR" --prompt p --as-reviewer --keep-scratch "$T/a.txt" 2>"$T/layout.err"); rc=$?
    c=$(ls -d "$HOME"/Library/Caches/claude-review-ctl.* 2>/dev/null | head -1)
    check "$layout: exec control is disjoint, or exec is refused" '{ [ $rc -eq 0 ] && profile_disjoint "$c"; } || { [ $rc -eq 2 ] && [ ! -e "$T/outside/worker.pid" ] && grep -q "control directory" "$T/layout.err"; }'
    /bin/rm -rf "$HOME"/Library/Caches/claude-review-ctl.* "$HOME"/.claude/tmp/claude-review-scratch.*
    clean_kept
  done
  # a hostile worker plants links where the parent writes: nothing outside may change
  printf 'ORIGINAL\n' > "$T/outside/victim"
  clean_kept
  out=$(fk FAKE_PLANT=1 -- "$CR" --prompt p --as-reviewer --keep-scratch "$T/a.txt" 2>/dev/null); rc=$?
  check "links planted in the scratch dir cannot make the parent overwrite anything outside" '[ "$(cat "$T/outside/victim")" = ORIGINAL ] && echo "$out" | grep -q "F1 | P2"'
  S6=$(kept)
  check "the control files live outside the worker-writable scratch dir" '[ -f "$(ctl)/request.txt" ] && [ ! -L "$(ctl)/request.txt" ] && [ -f "$(ctl)/settings.json" ] && [ ! -L "$(ctl)/settings.json" ] && [ -f "$(ctl)/profile.sb" ] && [ "$(cat "$T/outside/victim")" = ORIGINAL ]'
  check "the profile does not allow writing the control dir" '! grep -q "$(ctl)" "$(ctl)/profile.sb"'
  check "--as-reviewer defaults to effort high" 'sed -n "/^--effort\$/{n;p;}" "$S6/fake.argv" | grep -qx high'
  clean_kept
  # hook paths with spaces still work, and an incomplete hook bundle is not used
  mkdir -p "$T/mv home/template/.claude/hooks"
  cp "$REPO/template/.claude/hooks/block-dangerous-bash.sh" "$REPO/template/.claude/hooks/block-permission-hooks.sh" "$T/mv home/template/.claude/hooks/"
  out=$(MEGAVIBE_HOME="$T/mv home" "$CR" --prompt p --as-reviewer --keep-scratch "$T/a.txt" 2>/dev/null); S7=$(kept)
  cmd=$(jq -r ".hooks.PreToolUse[0].hooks[0].command" "$(ctl)/settings.json")
  rc2=0; printf '%s' '{"tool_name":"Bash","tool_input":{"command":"killall zzz"}}' | sh -c "$cmd" >/dev/null 2>&1 || rc2=$?
  check "the registered hook command works from a path containing spaces (the guard runs and refuses)" '[ "$rc2" = 2 ]'
  clean_kept
  rm -f "$T/mv home/template/.claude/hooks/block-permission-hooks.sh"
  out=$(MEGAVIBE_HOME="$T/mv home" "$CR" --prompt p --as-reviewer --keep-scratch "$T/a.txt" 2>/dev/null); S8=$(kept)
  check "a bundle missing the permission guard is not used (the complete one next to the script is)" 'jq -e ".hooks.PreToolUse[1].hooks[0].command | contains(\"block-permission-hooks.sh\")" "$(ctl)/settings.json" >/dev/null && ! jq -r ".hooks.PreToolUse[0].hooks[0].command" "$(ctl)/settings.json" | grep -q "mv home"'
  clean_kept
  # a custom CLAUDE_CONFIG_DIR is claude's own state: the profile allows it
  mkdir -p "$T/cfg"
  out=$(CLAUDE_CONFIG_DIR="$T/cfg" "$CR" --prompt p --as-reviewer --keep-scratch "$T/a.txt" 2>/dev/null)
  check "a custom CLAUDE_CONFIG_DIR is allowed in the profile" 'grep -q "subpath \"$T/cfg\"" "$(ctl)/profile.sb"'
  clean_kept
fi

printf 'claude-review.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
