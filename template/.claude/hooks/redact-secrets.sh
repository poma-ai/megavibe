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
# url-encoding, JSON \u escapes) are not matched, nor are secrets shorter than
# 20 characters. This is defence in depth, not a guarantee.

# One process, no shell buffering: $(...) strips trailing newlines and cannot
# hold NUL bytes, and temp files cost three extra spawns on a hook that fires on
# every tool call. Perl slurps the payload in binary mode, keeps the original,
# and does the substitutions inside eval — any runtime error prints the original
# bytes instead of losing them.
command -v perl &>/dev/null || exec cat

exec perl -e '
  my @pairs;
  for my $name (keys %ENV) {
    # Token-boundary match keeps MONKEY from looking like a KEY. The second
    # alternative has no left boundary, for established concatenated names like
    # PGPASSWORD — it lists only terms that are unambiguous on their own, so
    # MONKEY still does not match.
    my $secretish = ($name =~ /(?:^|_)(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH|PAT|APIKEY)(?:_|$)/i
                  || $name =~ /(?:PASSWORD|PASSWD|SECRET|TOKEN|APIKEY|CREDENTIAL)/i);
    my $urlish    = ($name =~ /(_URL|_URI)$/i);
    next unless $secretish || $urlish;
    my $v = $ENV{$name};
    next unless defined $v && length($v) >= 20;
    next if $v =~ m{^[/~.]};
    # a *_URL is only a secret when it carries an inline user:password
    next if $urlish && !$secretish && $v !~ m{://[^/\@\s]+:[^/\@\s]+\@};
    push @pairs, [$v, $name];
  }
  # longest first: a short value that is a substring of a longer one must not
  # partially clobber it
  @pairs = sort { length($b->[0]) <=> length($a->[0]) } @pairs;

  my @shapes = (
    qr/\bsk-[A-Za-z0-9_\-]{20,}/,
    qr/\bgh[pousr]_[A-Za-z0-9]{20,}/,
    qr/\bgithub_pat_[A-Za-z0-9_]{20,}/,
    qr/\bAIza[A-Za-z0-9_\-]{30,}/,
    qr/\bxox[baprs]-[A-Za-z0-9\-]{10,}/,
    qr/\bglpat-[A-Za-z0-9_\-]{15,}/,
    qr/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
    qr/\b[0-9]{9,11}:AA[A-Za-z0-9_\-]{30,}/,
    qr/\bBearer\s+[A-Za-z0-9._\-]{20,}/,
  );

  binmode(STDIN); binmode(STDOUT);   # byte-exact: NULs and trailing newlines survive
  local $/;                          # slurp: catches values that span lines
  my $buf = <STDIN>;
  exit 0 unless defined $buf;
  my $orig = $buf;
  eval {
    for my $p (@pairs) {
      my ($val, $name) = @$p;
      (my $safe = $name) =~ s/[^A-Za-z0-9_]/_/g;   # keep the marker JSON-safe
      $buf =~ s/\Q$val\E/[REDACTED:$safe]/g;
    }
    $buf =~ s/$_/[REDACTED]/g for @shapes;
    1;
  } or do { $buf = $orig };           # any runtime error -> original bytes
  # An unchecked print can truncate on a write error while still exiting 0,
  # which would let agent-log.sh swap a complete staged entry for a partial one.
  print($buf) or exit 1;
  close(STDOUT) or exit 1;
' 
