#!/bin/bash
# Megavibe — stdin -> stdout secret redactor. Helper, not a registered hook.
#
# DO NOT use set -e: callers pipe log writes through this, and a failure here
# must never cost a log line.
#
# Why it exists: .agent/LOGS/tool-events.*.jsonl records every tool input and
# response verbatim, and .agent/events/ is committed to git. Any command that
# prints the environment (env, printenv, a curl echoing its headers) therefore
# writes live credentials to disk, in every project, permanently. A 2026-09-09
# sweep found 616 such occurrences across 37 files on one machine.
#
# Two passes, both best-effort:
#   1. Exact: values of environment variables whose NAME looks secret, matched
#      on token boundaries so MONKEY is not a KEY while NETWORK_KEY_WIFI is. *_URL / *_URI are included only when the value
#      actually carries an inline user:password, so a plain endpoint URL stays
#      readable in the log.
#   2. Shape: well-known token formats (sk-, ghp_, AIza, xox*-, glpat-, AKIA,
#      github_pat_, telegram bot tokens, Bearer <token>) for secrets that were
#      never environment variables — pasted keys, values read out of a file.
#
# Fail-safe by construction: perl holds the original payload and restores it if
# any substitution raises. Redaction is a hardening measure; losing a log line
# would be a worse bug than failing to redact one.
#
# Replacement text is JSON-safe (no quotes, backslashes or control characters),
# so a redacted JSONL line stays valid JSON. Length is NOT preserved — this runs
# before the write, not as an in-place patch.
#
# Known limits, accepted: values re-encoded before they hit the log (base64,
# url-encoding, JSON \u escapes) are not matched, nor is a named secret shorter
# than 8 characters or an unnamed one shorter than 20. This is defence in depth,
# not a guarantee. When a variable carries a credential under a name no
# heuristic can see, declare it in ~/.megavibe/redact-vars.

# One process, no shell buffering: $(...) strips trailing newlines and cannot
# hold NUL bytes, and temp files cost three extra spawns on a hook that fires on
# every tool call. Perl slurps the payload in binary mode, keeps the original,
# and does the substitutions inside eval — any runtime error prints the original
# bytes instead of losing them.
# A missing perl means everything below is a no-op. Say so once, rather than
# letting a disabled control look like a working one.
if ! command -v perl &>/dev/null; then
  _flag="${HOME}/.megavibe/.redaction-off"
  if [ ! -f "$_flag" ]; then
    mkdir -p "${HOME}/.megavibe" 2>/dev/null
    : > "$_flag" 2>/dev/null
    echo "$(date -u +%FT%TZ) redact-secrets.sh: perl not found — log redaction is OFF" \
      >> "${HOME}/.megavibe/hook-errors.log" 2>/dev/null
  fi
  exec cat
fi

exec perl -e '
  # Names the operator has declared secret outright, for variables no heuristic
  # can recognise (TIGER_ADMIN, GOOGLE_ADS_API_CLIENT). Comma or whitespace
  # separated in $MEGAVIBE_REDACT_VARS, one per line in ~/.megavibe/redact-vars.
  my %declared;
  for my $n (split /[,\s]+/, ($ENV{MEGAVIBE_REDACT_VARS} // "")) { $declared{uc $n} = 1 if length $n }
  if (open(my $fh, "<", ($ENV{HOME} // "") . "/.megavibe/redact-vars")) {
    while (my $l = <$fh>) { chomp $l; $l =~ s/#.*//; $l =~ s/^\s+|\s+$//g; $declared{uc $l} = 1 if length $l }
    close $fh;
  }

  my @pairs;
  for my $name (keys %ENV) {
    # Token-boundary match keeps MONKEY from looking like a KEY. The second
    # alternative has no left boundary, for established concatenated names like
    # PGPASSWORD — it lists only terms that are unambiguous on their own, so
    # MONKEY still does not match.
    my $secretish = ($name =~ /(?:^|_)(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD|PW|CREDENTIAL|AUTH|PAT|APIKEY)(?:_|$)/i
                  || $name =~ /(?:PASSWORD|PASSWD|SECRET|TOKEN|APIKEY|CREDENTIAL)/i
                  || $declared{uc $name});
    my $urlish    = ($name =~ /(_URL|_URI)$/i);
    my $v = $ENV{$name};
    next unless defined $v;
    next if $v =~ m{^[/~.]} || $v =~ /\s/;
    # A value that simply looks like a credential is treated as one whatever it
    # is called: names like TIGER_ADMIN or GOOGLE_ADS_API_CLIENT carry no token
    # a heuristic could match, and a name list is only as current as its author.
    my $tokenish = (length($v) >= 20
                 && $v =~ m{^[A-Za-z0-9_\-.:+/=]+$}
                 && $v =~ /[A-Za-z]/ && $v =~ /[0-9]/);
    next unless $secretish || $urlish || $tokenish;
    # Named secrets go down to 8 characters; a bare shape needs 20 to earn it.
    next if $secretish && length($v) < 8;
    next if !$secretish && length($v) < 20;
    # a *_URL is only a secret when it carries an inline user:password
    next if $urlish && !$secretish && !$tokenish && $v !~ m{://[^/\@\s]+:[^/\@\s]+\@};
    push @pairs, [$v, $name];
    # A secret written into JSON arrives escaped: a value containing " or \
    # never matches its raw form once jq has encoded the log line.
    (my $j = $v) =~ s/(["\\])/\\$1/g;
    push @pairs, [$j, $name] if $j ne $v;
  }
  # One alternation, one pass. A loop of per-value substitutions costs a full
  # scan of the payload per credential, which measured 107ms per tool call with
  # a realistic environment; this is a single scan regardless of how many
  # credentials are exported. Longest first, because perl alternation prefers
  # the leftmost-listed branch at a given position and a short value must not
  # partially clobber a longer one containing it.
  @pairs = sort { length($b->[0]) <=> length($a->[0]) } @pairs;
  # Exact values are matched with index(), not a regex: quotemeta + compiling a
  # 60-branch alternation on every tool call measured 70ms, against 34ms for the
  # hook without redaction. index() is a plain memory scan with no compile step.
  for my $p (@pairs) {
    (my $safe = $p->[1]) =~ s/[^A-Za-z0-9_]/_/g;   # keep the marker JSON-safe
    $p->[1] = "[REDACTED:$safe]";
  }
  my $shapes_re;

  my @shapes = (
    qr/\bsk-[A-Za-z0-9_\-]{20,}/,
    qr/\bgh[pousr]_[A-Za-z0-9]{20,}/,
    qr/\bgithub_pat_[A-Za-z0-9_]{20,}/,
    qr/\bAIza[A-Za-z0-9_\-]{30,}/,
    qr/\bxox[baprs]-[A-Za-z0-9\-]{10,}/,
    qr/\bglpat-[A-Za-z0-9_\-]{15,}/,
    qr/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
    qr/\b[0-9]{9,11}:AA[A-Za-z0-9_\-]{30,}/,
    qr/\bBearer[ \t]+[A-Za-z0-9._\-]{20,}/,   # [ \t] not \s: slurp mode would eat a newline
  );

  binmode(STDIN); binmode(STDOUT);   # byte-exact: NULs and trailing newlines survive
  local $/;                          # slurp: catches values that span lines
  my $buf = <STDIN>;
  exit 0 unless defined $buf;
  my $orig = $buf;
  eval {
    for my $p (@pairs) {
      my ($val, $rep) = @$p;
      my $vl = length $val;
      next unless $vl;
      my $pos = 0;
      while (($pos = index($buf, $val, $pos)) >= 0) {
        substr($buf, $pos, $vl) = $rep;
        $pos += length $rep;
      }
    }
    unless (defined $shapes_re) {
      my $a = join "|", map { "(?:$_)" } @shapes;
      $shapes_re = qr/$a/;
    }
    $buf =~ s{$shapes_re}{[REDACTED]}g;
    # Any surviving inline credential in a URL: drop the password only, so host,
    # port and path stay readable in the log.
    $buf =~ s{(://[^/\@\s:]+:)[^/\@\s]+\@}{$1\[REDACTED\]\@}g;
    1;
  } or do { $buf = $orig };           # any runtime error -> original bytes
  # An unchecked print can truncate on a write error while still exiting 0,
  # which would let agent-log.sh swap a complete staged entry for a partial one.
  print($buf) or exit 1;
  close(STDOUT) or exit 1;
' 
