#!/bin/bash
# amass.sh — a cheap first pass: many headless one-shot model calls over the SAME inlined
# input, one lens per prompt, then ONE dedupe call. It is a source of LEADS, never a review
# and never a gate (the review tiers in .claude/rules/delegation.md are unchanged).
#
#   amass.sh run    --out DIR [--change TEXT | --task-file F] [--provider auto|mix|claude|codex] [--split N:M]
#                   [--model MODEL | --claude-model M --codex-model M] [--codex-effort E] [--lens name=text]...
#                   [--lenses-file F] [--no-lens] [--copies 3] [--whole 0] [--parallel 12]
#                   [--timeout 280] [--max-input-kb KB] [--dry-run] FILE... [--context FILE...]...
#   amass.sh dedupe --out DIR [--provider auto|claude|codex] [--model MODEL] [--timeout 280]
#   amass.sh summary --out DIR
#
# Why it is built this way (measured in a pilot; the numbers are in README-amass.md):
#  - The Claude path uses `claude -p` with NO tools, no user, project or local settings (so no CLAUDE.md,
#    rules or hooks of yours; an administrator's managed policy, if the machine has one, still
#    applies), no MCP and no session: about 5K tokens of fixed overhead where an Agent-tool
#    subagent carries about 93K. The files are inlined into the prompt, so the model cannot
#    touch anything: the worst a hostile file can do is mislead its own list.
#  - Haiku bills the WHOLE request at 5x once the prompt passes 100K tokens, so the input is
#    capped (--max-input-kb) and the run refuses above it.
#  - Identical prompts share one cache write: the first copy of each prompt is started first,
#    the rest follow after AMASS_STAGGER seconds. Prompts that differ only in the lens line do
#    not share the bulk, so spend copies on a lens, not on many different lens texts.
#  - Subscription login only: every call runs in an allow-listed minimal environment (no API key, token,
#    custom header or cloud-provider variable can reach it), and before anything is sent `claude auth status` must report
#    a claude.ai (subscription) login, because a saved Console key would still bill. If the
#    check cannot be made the script refuses (it needs a claude that has `auth status`).
#  - Nothing is dropped silently: every response line that is not a finding line is counted
#    and reported, a response with text but no finding lines fails, and dedupe re-adds the
#    findings the model omitted. Every call's cost is kept, failed ones included.
#  - The default --provider auto mixes both: every provider whose login check passes gets calls, split
#    inversely to its projected end-of-window usage (usage-route.sh pace), at least one call each.
#  - Codex uses read-only exec in throwaway scratch space, a ChatGPT login, a 400 KB
#    input cap and token accounting; dollar estimates require an explicit price.
set -euo pipefail

PROG=${0##*/}
CLAUDE_BIN=${AMASS_CLAUDE:-claude}
STAGGER=${AMASS_STAGGER:-6}

# The environment of every claude call is an ALLOW-LIST (env -i plus what claude legitimately needs), so no
# credential, endpoint or header variable (ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_CUSTOM_HEADERS,
# cloud-provider switches and tokens, ...) can reach it, whatever it is called: a deny-list of names would miss
# the next one. A saved claude.ai login is found through HOME or CLAUDE_CONFIG_DIR.
CLEAN=(env -i)
for _v in PATH HOME USER LOGNAME SHELL TERM LANG LC_ALL LC_CTYPE TMPDIR TZ CLAUDE_CONFIG_DIR HTTPS_PROXY HTTP_PROXY NO_PROXY ALL_PROXY https_proxy http_proxy no_proxy all_proxy NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR; do
  if [ -n "${!_v+x}" ]; then CLEAN+=("$_v=${!_v}"); fi
done


die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

P1/P2 labels are the model's, not a measurement: historical precision was about
15-20 percent on real diffs and roughly 40 percent on fresh complex shell code
in the historical Claude pilot. Measured precision for either provider is
unknown until compared on the same inputs.
--provider auto (the default) mixes Claude (haiku) and Codex (gpt-5.6-luna) calls
in one run, split inversely to each subscription's projected end-of-window usage
(usage-route.sh pace; recent, else linear, else used; clamped to 10-1000), at
least one call each; a provider whose login check fails is dropped with one
warning line. mix needs both; claude or codex alone behaves as before. The split
line is printed before sending, also with --dry-run. --split N:M (claude:codex) or
MEGAVIBE_AMASS_SPLIT overrides the weights; --claude-model and --codex-model pick
the models (--model fits a single provider only). The mixed input cap is 150 KB.
Codex calls run at reasoning effort low (--codex-effort to change): at a
high effort inherited from the user config they took minutes and hit --timeout.
dedupe picks the provider with the lower projection, so it leans on the one with
headroom; --provider claude|codex forces one. Codex alone: gpt-5.6-luna and a
400 KB cap. --model gpt-6-luna also works; the bare name luna does not.
Codex requires a ChatGPT-account login and reports tokens;
MEGAVIBE_AMASS_CODEX_PRICE (USD per 1M tokens) optionally enables cost estimates.
The tool reasons inside the diff; pass callers and callees with --context.
Context groups consume files until the next option; repeat --context as needed.
Put reviewed files before --context or after --; prefix option-like paths with ./.
Context is not under review and counts toward --max-input-kb.
--out DIR must not exist: a wrapper that pre-creates it fails with exit 2.
3-5 of 18 workers failing to parse is normal and counted in the summary.
Clusters show n=member count, sorted descending then by id (C locale), keeping ids.
[no-input] flags a cluster without a concrete failing input; it is never dropped.
EOF
  exit "${1:-2}"
}

DEFAULT_HEAD='You are a fast first-pass code reader. Goal: SPOT and list as many plausible P1/P2 defects as you can in the change below, cheaply. You do NOT fix, dedupe, rank carefully or give a ship verdict; another stage dedupes. Everything you need is below; you have no tools.'
FORMAT='
Output: a markdown list, at most 15 lines, nothing else, one line per suspected defect:
F<n> | P1 or P2 | file:line | what goes wrong, with the concrete failing input | why, in one sentence
Prefer concrete failing inputs over generalities. Include a suspicion even if you are only fairly sure.'

default_lenses() {
  cat <<'EOF'
race|concurrency, ordering, staleness, once-only or claim semantics, two actors at once, partial writes
input|hostile or odd input: control characters, quotes, ANSI, invisible or bidirectional Unicode, invalid UTF-8, huge or overflowing numbers, very long text, validity of generated JSON
port|shell and platform portability (bash 3.2, macOS and BSD tools), missing tools, set -e and pipefail traps, quoting and word splitting, locale
fail|timeouts, hangs, failure paths, never blocking or failing the caller, process cleanup, recursion or side effects of nested calls, resource exhaustion
sec|security and trust boundaries: injection into a shell or a model context, who can write the files involved, side effects, secrets, hygiene for a public repository
docs|documentation, comments or tests that contradict the code; tests that do not test what they claim; changed behaviour without a test
EOF
}

# a finding line: optional bullets or bold around F<n>, then the first pipe
FPAT='^[^A-Za-z0-9]*F[0-9]+[^A-Za-z0-9|]*\|'

valid_name() { case $1 in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; return 0; }
valid_model() { case $1 in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }
need() { command -v "$1" >/dev/null 2>&1 || die "needs $1"; }
isnum() { case $1 in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# one bounded, tool-less, settings-less call: prompt file in, raw json out. It runs under the same
# process-group supervisor as every other call, so a timeout or a cancelled run kills its children too.
call_claude() { # model timeout prompt_file out_json out_err ; returns the exit status
  supervise "$WORK" "$2" claude "$CLAUDE_BIN" -p --model "$1" --output-format json \
    --tools "" --no-session-persistence --disable-slash-commands --strict-mcp-config \
    --setting-sources "" < "$3" > "$4" 2> "$5"
}

# Codex keeps its own environment: in particular no OPENAI/CODEX credential,
# endpoint or header override can select API billing. Saved account auth remains
# available through HOME/CODEX_HOME. The Claude invocation above is unchanged.
CODEX_BIN=${AMASS_CODEX:-codex}
REQ=auto          # what was asked: auto|mix|claude|codex
PROVS=''          # the providers that will get calls, space separated, once resolved
RESOLVED=0
CLAUDE_MODEL=haiku; CODEX_MODEL=gpt-5.6-luna
# Lens enumeration does not need deliberation: at the user config's high effort luna took
# minutes per call and often hit the timeout; low answers in seconds. --codex-effort overrides.
CODEX_EFFORT=low
CX_WORK=''; SUP_PID=''; WORKERS=(); CX_DRY=''; DD_LOCK=''; SCR=''; CX_IGNORE=0; CX_IUC=0
CX_CLEAN=(env -i)
for _v in HOME PATH CODEX_HOME HTTPS_PROXY HTTP_PROXY NO_PROXY ALL_PROXY https_proxy http_proxy no_proxy all_proxy NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR; do
  if [ -n "${!_v+x}" ]; then CX_CLEAN+=("$_v=${!_v}"); fi
done

sup_stop() {
  if [ -n "$SUP_PID" ]; then
    kill -TERM "$SUP_PID" 2>/dev/null || true
    wait "$SUP_PID" 2>/dev/null || true
    SUP_PID=''
  fi
}
# Every launched worker is tracked, whatever its provider; each one's own EXIT trap stops its supervisor.
cleanup() {
  local pid
  for pid in ${WORKERS[@]+"${WORKERS[@]}"}; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in ${WORKERS[@]+"${WORKERS[@]}"}; do wait "$pid" 2>/dev/null || true; done
  sup_stop
  if [ -n "$CX_WORK" ]; then rm -rf "$CX_WORK" || true; fi
  if [ -n "$CX_DRY" ]; then rm -rf "$CX_DRY" || true; fi
  if [ -n "$SCR" ]; then rm -rf "$SCR" || true; fi
  if [ -n "$DD_LOCK" ]; then rmdir "$DD_LOCK" 2>/dev/null || true; fi
}
mk_sc() { # scratch directory for probe output, kept out of pipes and out of the run directory
  if [ -z "$SCR" ]; then
    SCR=$(mktemp -d "${TMPDIR:-/tmp}/amass-sc.XXXXXX") || { SCR=''; die "cannot create a scratch directory"; }
    SCR=$(cd "$SCR" && pwd -P)
  fi
}
model_of() { if [ "$1" = codex ]; then printf '%s' "$CODEX_MODEL"; else printf '%s' "$CLAUDE_MODEL"; fi; }

# Every provider mode cleans up after itself and forwards cancellation.
setup_provider() {
  case $REQ in claude|codex|mix|auto) ;; *) die '--provider must be auto, mix, claude or codex' ;; esac
  trap cleanup EXIT
  trap 'exit 143' TERM HUP
  trap 'exit 130' INT
  if [ -n "${MEGAVIBE_AMASS_CODEX_PRICE+x}" ]; then
    printf '%s\n' "$MEGAVIBE_AMASS_CODEX_PRICE" | LC_ALL=C grep -Eq '^[0-9]+([.][0-9]+)?$' \
      || die 'MEGAVIBE_AMASS_CODEX_PRICE must be a nonnegative USD price per 1M tokens'
  fi
}
# The input cap follows the strictest provider in play (Haiku's cliff when Claude is involved).
apply_caps() {
  local hc=0 hx=0 p
  for p in $PROVS; do if [ "$p" = codex ]; then hx=1; else hc=1; fi; done
  CAP_SUFFIX=''
  if [ "$hx" = 1 ] && [ "$hc" = 0 ]; then
    CAP_REASON='Codex luna doubles in price past 272K tokens'; CAP_SUFFIX=" ($CAP_REASON)"
    [ "$MAXKB_SET" = 1 ] || MAXKB=400
  else
    CAP_REASON='Haiku bills the whole request 5x past 100K tokens'
    [ "$hx" = 0 ] || CAP_SUFFIX=" ($CAP_REASON)"
    [ "$MAXKB_SET" = 1 ] || MAXKB=150
  fi
}
finalize_models() { # --model names one model, so it only fits a single provider
  [ "$MODEL_SET" = 1 ] || return 0
  case $PROVS in
    *' '*) die "--model cannot name both models of a mixed run: use --claude-model and --codex-model" ;;
    codex)
      # auto may have dropped the provider the model was meant for: never hand a Claude model to Codex
      case $MODEL in haiku|sonnet|opus|fable|claude-*) [ "${REQ:-}" != auto ] || die "--model $MODEL is a Claude model, but only Codex is usable; pass --codex-model or --provider" ;; esac
      CODEX_MODEL=$MODEL ;;
    *)
      case $MODEL in gpt-*|o[0-9]*) [ "${REQ:-}" != auto ] || die "--model $MODEL is a Codex model, but only Claude is usable; pass --claude-model or --provider" ;; esac
      CLAUDE_MODEL=$MODEL ;;
  esac
}

# A supervisor owns the process group, forwards cancellation, and reaps it on timeout, on
# cancellation and after a normal exit (leftover ordinary children die with it). Unlike
# alarm+exec this also kills subprocesses (macOS has no timeout). kind picks the environment:
# claude and codex use their allow-lists, anything else runs in the caller's environment.
# stdin, stdout and stderr come from the caller's redirections; exit code 124 means timeout.
supervise() { # cwd timeout kind argv...
  local cwd=$1 t=$2 kind=$3 rc=0 pre
  shift 3
  case $kind in claude) pre=("${CLEAN[@]}") ;; codex) pre=("${CX_CLEAN[@]}") ;; *) pre=(env) ;; esac
  ( cd "$cwd" && exec "${pre[@]}" perl -e '
    my $t = shift;
    my $pid = fork(); die "fork: $!" unless defined $pid;
    if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127; }
    setpgrp($pid, $pid);
    my $stop = sub {
      my ($code) = @_;
      $SIG{ALRM} = $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "IGNORE";
      kill "TERM", -$pid;
      select undef, undef, undef, 1;
      kill "KILL", -$pid;
      waitpid($pid, 0);
      exit $code;
    };
    $SIG{ALRM} = sub { $stop->(124) };
    $SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { $stop->(143) };
    alarm $t;
    waitpid($pid, 0); my $st = $?; alarm 0;
    $SIG{ALRM} = $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "IGNORE";
    kill "KILL", -$pid;
    exit(($st & 127) ? 128 + ($st & 127) : $st >> 8);
  ' "$t" "$@" ) <&0 &   # explicit stdin: background commands otherwise receive /dev/null
  SUP_PID=$!
  wait "$SUP_PID" || rc=$?
  SUP_PID=''
  return "$rc"
}

call_model() { # provider model timeout prompt_file out_json out_err
  local pv=$1; shift
  if [ "$pv" = claude ]; then call_claude "$@"; return $?; fi
  local rc=0 tokens answer="$4.answer" events="$4.events"
  # Dedupe can be repeated: never accept a previous attempt's final answer.
  rm -f "$answer" "$4"
  # model_provider is pinned to the built-in id on every call: a saved config or profile naming a custom
  # provider (its own base_url or token) must not receive the inlined files; -c beats config and profiles.
  local cxa=(exec --model "$1" -c "model_reasoning_effort=\"$CODEX_EFFORT\"" -c 'model_provider="openai"' --sandbox read-only -c 'approval_policy="never"')
  [ "$CX_IGNORE" != 1 ] || cxa+=(--ignore-rules)   # older builds without the flag run as before
  # Saved config can redirect the endpoint (openai_base_url, chatgpt_base_url) and with it the
  # login token and the inlined files; auth still comes from CODEX_HOME without it.
  [ "$CX_IUC" != 1 ] || cxa+=(--ignore-user-config)
  cxa+=(--skip-git-repo-check --ephemeral --json --output-last-message "$answer" -)
  supervise "$CX_WORK" "$2" codex "$CODEX_BIN" "${cxa[@]}" < "$3" > "$events" 2> "$5" || rc=$?
  # JSONL turn.completed usage is machine-readable. Cached input is already in
  # input_tokens. No complete usage event means unknown, including failed calls.
  tokens=$(jq -Rn '[inputs | fromjson? | select(.type == "turn.completed") | .usage] |
    if length > 0 and all(.[]; (.input_tokens | type) == "number" and
      (.output_tokens | type) == "number" and .input_tokens >= 0 and .output_tokens >= 0)
    then map(.input_tokens + .output_tokens) | add else null end' "$events") || tokens=null
  if [ -s "$answer" ]; then
    jq -n --rawfile result "$answer" --argjson tokens "$tokens" --argjson rc "$rc" \
      '{is_error:($rc != 0),result:$result,tokens:$tokens}' > "$4"
  else
    jq -n --argjson tokens "$tokens" '{is_error:true,result:"",tokens:$tokens}' > "$4"
  fi
  return "$rc"
}

call_tokens() {
  local t
  t=$(jq -r '.tokens // empty' "$1" 2>/dev/null) || t=''
  printf '%s' "${t:-?}"
}
# A total with any unknown member is itself unknown, not the known subtotal.
total_tokens() { # tsv column provider (rows of that provider only)
  LC_ALL=C awk -F'\t' -v col="$2" -v p="$3" '$7 == p {if ($col ~ /^[0-9]+$/) s+=$col; else u++}
    END {if (u) print "?"; else printf "%.0f\n", s+0}' "$1"
}

# the cost of one call, whether or not it succeeded ("?" when the output has none)
call_cost() { # provider raw_json
  local c
  if [ "$1" = codex ]; then
    c=$(call_tokens "$2")
    if [ "$c" != '?' ] && [ -n "${MEGAVIBE_AMASS_CODEX_PRICE+x}" ]; then
      jq -n --argjson t "$c" --arg p "$MEGAVIBE_AMASS_CODEX_PRICE" '$t * ($p|tonumber) / 1000000'
    else printf '?'; fi
    return
  fi
  c=$(jq -s -r 'if length != 1 then empty else .[0] | (if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end) | select(type == "object") | (.total_cost_usd | select(type == "number")) end' "$2" 2>/dev/null) || c=''
  [ -n "$c" ] && printf '%s' "$c" || printf '?'
}

# result text out of one raw json file; fails unless the call succeeded
extract() { # raw_json text_out
  # NUL bytes would be truncated by bash variables further down, so they are removed here
  jq -e -s -r 'if length != 1 then empty else .[0] | (if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end) | select(type == "object" and .is_error == false and (.result | type) == "string") | .result end' "$1" 2>/dev/null | tr -d '\000' > "$2"
}

# Availability: refuse anything but a claude.ai subscription login (a saved Console key would bill)
# and a ChatGPT-account Codex login. Each check sets AV_ERR and returns 1 instead of dying, so that
# auto can fall back to the other provider.
AV_ERR=''
avail_claude() {
  local j m
  mk_sc
  supervise . 30 claude "$CLAUDE_BIN" auth status </dev/null > "$SCR/auth.json" 2>/dev/null \
    || { AV_ERR="cannot verify the login ('$CLAUDE_BIN auth status' failed); refusing to send anything"; return 1; }
  j=$(cat "$SCR/auth.json" 2>/dev/null) || j=''
  m=$(printf '%s' "$j" | jq -r '.authMethod // empty' 2>/dev/null) || m=''
  [ "$m" = "claude.ai" ] \
    || { AV_ERR="the login is not a claude.ai subscription login (authMethod='${m:-unknown}'); refusing, because such calls could bill an API key"; return 1; }
  return 0
}
avail_codex() {
  command -v "$CODEX_BIN" >/dev/null 2>&1 || { AV_ERR='needs codex'; return 1; }
  if [ -z "$CX_WORK" ]; then
    local resolved
    CX_WORK=$(mktemp -d "${TMPDIR:-/tmp}/amass-codex.XXXXXX") || { CX_WORK=''; AV_ERR='cannot create Codex scratch directory'; return 1; }
    resolved=$(cd "$CX_WORK" && pwd -P) || { AV_ERR='cannot resolve Codex scratch directory'; return 1; }
    CX_WORK=$resolved
  fi
  supervise "$CX_WORK" 30 codex "$CODEX_BIN" exec --help </dev/null > "$CX_WORK/help" 2>&1 \
    || { AV_ERR='codex exec --help failed; refusing to send anything'; return 1; }
  if grep -q -e '--ignore-rules' "$CX_WORK/help"; then CX_IGNORE=1; else CX_IGNORE=0; fi
  if grep -q -e '--ignore-user-config' "$CX_WORK/help"; then CX_IUC=1; else CX_IUC=0; fi
  supervise "$CX_WORK" 30 codex "$CODEX_BIN" login status </dev/null > "$CX_WORK/login" 2>&1 \
    || { AV_ERR='cannot verify the Codex login; a ChatGPT-account login is required'; return 1; }
  grep -qx 'Logged in using ChatGPT' "$CX_WORK/login" \
    || { AV_ERR='Codex login is not a ChatGPT-account login; refusing to send anything'; return 1; }
  return 0
}
# Decide which providers get calls. Explicit claude/codex: that one, checked. mix: both, checked.
# auto: every provider whose check passes; one warning line if one fails. A dry run checks nothing.
resolve_providers() {
  [ "$RESOLVED" = 0 ] || return 0
  RESOLVED=1
  local ec='' ex='' okc=0 okx=0 dry=${DRY:-0}
  case $REQ in
    claude|codex)
      PROVS=$REQ
      if [ "$dry" != 1 ]; then
        if [ "$REQ" = codex ]; then avail_codex || die "$AV_ERR"; else avail_claude || die "$AV_ERR"; fi
      fi ;;
    mix)
      PROVS='claude codex'
      if [ "$dry" != 1 ]; then
        avail_claude || die "mix needs both providers; claude: $AV_ERR"
        avail_codex || die "mix needs both providers; codex: $AV_ERR"
      fi ;;
    auto)
      # a dry run checks no login (it must not touch the provider tools): it plans for both
      if [ "$dry" = 1 ]; then PROVS='claude codex'; return 0; fi
      if avail_claude; then okc=1; else ec=$AV_ERR; fi
      if avail_codex; then okx=1; else ex=$AV_ERR; fi
      if [ "$okc$okx" = 11 ]; then PROVS='claude codex'
      elif [ "$okc" = 1 ]; then PROVS=claude; printf '%s: warning: codex is not usable (%s); running everything on claude\n' "$PROG" "$ex" >&2
      elif [ "$okx" = 1 ]; then PROVS=codex; printf '%s: warning: claude is not usable (%s); running everything on codex\n' "$PROG" "$ec" >&2
      else die "no usable provider: claude: $ec; codex: $ex"; fi ;;
  esac
}

# Effective projected end-of-window usage of one provider, from usage-route.sh pace:
# provider|used|elapsed_pct|linear_proj|recent_pts_per_day|recent_proj|remaining_days.
# recent_proj, else linear_proj, else used, else unknown; clamped to [10, 1000]. A probe that fails,
# blocks or prints nothing means unknown, never an error. Sets PV (number or empty) and PS (source).
isdec() { printf '%s' "$1" | LC_ALL=C grep -Eq '^[0-9]+([.][0-9]+)?$'; }
pace_proj() { # provider
  PV=''; PS=unknown
  local ur out line used lin rec v=''
  ur=${MEGAVIBE_AMASS_USAGE_ROUTE:-}
  if [ -z "$ur" ]; then
    ur="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/usage-route.sh"
    [ -f "$ur" ] || ur="$HOME/.megavibe/scripts/usage-route.sh"
  fi
  [ -f "$ur" ] || return 0
  # supervised, output to a file: a child that outlives the probe cannot hold a pipe open, and the
  # whole process group dies at the deadline. A timeout or failure means unknown.
  local pt=${AMASS_PROBE_TIMEOUT:-20}
  isnum "$pt" && [ "$pt" -ge 1 ] || pt=20
  mk_sc
  : > "$SCR/pace.out"
  if supervise . "$pt" bare env "MEGAVIBE_ROUTER_PROVIDER=$1" bash "$ur" pace </dev/null > "$SCR/pace.out" 2>/dev/null; then
    out=$(cat "$SCR/pace.out" 2>/dev/null) || out=''
  else out=''; fi
  line=${out%%$'\n'*}
  used=''; lin=''; rec=''
  IFS='|' read -r _ used _ lin _ rec _ <<< "$line" || true
  if isdec "$rec"; then v=$rec; PS=recent
  elif isdec "$lin"; then v=$lin; PS=linear
  elif isdec "$used"; then v=$used; PS=used; fi
  [ -n "$v" ] || return 0
  PV=$(LC_ALL=C awk -v p="$v" 'BEGIN{if (p < 10) p = 10; if (p > 1000) p = 1000; print p}')
}
# both providers' projections; an unknown side takes the other's value (equal weight), both unknown -> ''
# sets PC PX (numbers or empty), SC SX (sources), EC EX (effective values used for weighting)
both_proj() {
  pace_proj claude; PC=$PV; SC=$PS
  pace_proj codex; PX=$PV; SX=$PS
  EC=$PC; EX=$PX
  [ -n "$EC" ] || EC=$PX
  [ -n "$EX" ] || EX=$PC
}
proj_text() { if [ -n "$1" ]; then printf '%s (%s)' "$(LC_ALL=C awk -v p="$1" 'BEGIN{printf "%.0f", p}')" "$2"; else printf '? (unknown)'; fi; }

# n_claude of total calls: weights 1/P (or the --split N:M weights); rounded half up, so with equal
# weights Claude gets the extra call of an odd total; at least one call per provider when total >= 2
# (a zero weight from --split is honoured); a single call goes to the larger weight (tie: Claude).
split_calls() { # total split_or_empty ; sets NC and SPLIT_DESC
  local total=$1 wa wb
  if [ -n "$2" ]; then
    wa=${2%%:*}; wb=${2#*:}
    SPLIT_DESC=''
  else
    both_proj
    if [ -z "$EC" ]; then wa=1; wb=1
    else read -r wa wb < <(LC_ALL=C awk -v pc="$EC" -v px="$EX" 'BEGIN{printf "%.12g %.12g\n", 1/pc, 1/px}'); fi
    SPLIT_DESC="projections claude $(proj_text "$PC" "$SC"), codex $(proj_text "$PX" "$SX")"
  fi
  NC=$(LC_ALL=C awk -v T="$total" -v a="$wa" -v b="$wb" 'BEGIN{
    if (T == 1) { print (a >= b) ? 1 : 0; exit }
    n = int(T * a / (a + b) + 0.5)
    if (a > 0 && b > 0 && T >= 2) { if (n < 1) n = 1; if (n > T - 1) n = T - 1 }
    print n }')
}

alive() { kill -0 "$1" 2>/dev/null; }

# one line per run/dedupe in a local ledger, so adoption and spend can be measured later.
# Best effort: a ledger that cannot be written never fails or slows a run.
ledger() { # cmd model calls ok cost input_kb unknown_costs tokens provider   (cost is null whenever any call's cost is unknown; cost_known is the known subtotal)
  local f=${AMASS_LEDGER:-$HOME/.megavibe/amass-usage.jsonl}
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cmd "$1" --arg model "$2" --arg proj "$(basename "$PWD")" \
    --arg provider "$9" --arg tokens "${8:-?}" --argjson calls "$3" --argjson ok "$4" --arg cost "$5" --argjson kb "$6" --argjson unk "${7:-0}" \
    '{ts:$ts,cmd:$cmd,model:$model,provider:$provider,tokens:($tokens|tonumber? // null),project:$proj,calls:$calls,ok:$ok,cost:(if $unk > 0 then null else ($cost|tonumber? // null) end),cost_known:(if $provider == "codex" and $unk == $calls then null else ($cost|tonumber? // null) end),cost_unknown_calls:$unk,input_kb:$kb} + (if $provider == "codex" then {cost_estimated:($unk < $calls)} else {} end)' >> "$f" 2>/dev/null || true
}

codex_summary() { # worker provider of the run's calls: claude or codex
  local worker=$1
  LC_ALL=C awk -F'\t' -v worker="$worker" '
    function usage(label, n, tok, unknown, cost, cu, estimated) {
      printf "%s %d, ", label, n
      if (estimated) {
        if (unknown && !tok) printf "tokens unknown (%d unknown calls), ", unknown
        else if (unknown) printf "tokens unknown (known %.0f; %d unknown calls), ", tok, unknown
        else printf "tokens %.0f, ", tok
      }
      if (cu == n) printf "cost unknown\n"
      else printf "%scost $%.6f%s\n", (estimated ? "estimated " : ""), cost, (cu ? " (PARTIAL: some costs unknown)" : "")
    }
    FILENAME == ARGV[1] {
      n++; if ($3 == "ok") {ok++; f+=$4} else bad=bad" "$1
      u+=$5
      if ($2 == "?") cu++; else c+=$2
      if (worker == "codex") {if ($6 ~ /^[0-9]+$/) t+=$6; else tu++}
      next
    }
    {dn++; if ($2 == "?") dcu++; else dc+=$2
     if ($3 == "codex") {cx++; if ($4 ~ /^[0-9]+$/) dt+=$4; else dtu++}}
    END {
      printf "runs %d, ok %d, failed %d, findings %d, unparsed lines %d (kept in lists/, not clustered)\n", n, ok, n-ok, f, u
      usage("worker calls", n, t, tu, c, cu, worker == "codex")
      if (dn) {
        usage("dedupe calls", dn, dt, dtu, dc, dcu, cx > 0)
        printf "Codex total tokens %s\n", ((tu+dtu) ? "unknown" : sprintf("%.0f", t+dt))
      }
      if (bad != "") printf "FAILED:%s\n", bad
    }' "$OUT/runs.tsv" ${SUMMARY_DEDUPE:+"$SUMMARY_DEDUPE"}
  if [ -f "$OUT/clusters.md" ]; then cat "$OUT/clusters.md"; fi
}

# a run that used both providers: per provider calls, ok, findings and cost (claude, USD) or tokens (codex)
mix_summary() {
  LC_ALL=C awk -F'\t' '
    function money(x) { return sprintf("$%.6f", x) }
    FILENAME == ARGV[1] {
      p = (NF >= 7) ? $7 : "claude"; n[p]++; tn++
      if ($3 == "ok") {ok[p]++; tok++; f[p] += $4; tf += $4} else bad = bad " " $1
      u += $5
      if ($2 ~ /^[0-9.eE+-]+$/) c[p] += $2; else cu[p]++
      if (p == "codex") {if ($6 ~ /^[0-9]+$/) t += $6; else tu++}
      next
    }
    { p = ($3 == "codex") ? "codex" : "claude"; dn[p]++
      if ($2 ~ /^[0-9.eE+-]+$/) dc[p] += $2; else dcu[p]++
      if (p == "codex") {if ($4 ~ /^[0-9]+$/) dt += $4; else dtu++} }
    END {
      printf "runs %d, ok %d, failed %d, findings %d, unparsed lines %d (kept in lists/, not clustered)\n", tn, tok, tn - tok, tf, u
      split("claude codex", ps, " ")
      for (k = 1; k <= 2; k++) {
        p = ps[k]
        if (!n[p]) continue
        printf "%s: worker calls %d, ok %d, findings %d, ", p, n[p], ok[p], f[p]
        if (p == "codex") {
          if (tu && !t) printf "tokens unknown (%d unknown calls), ", tu
          else if (tu) printf "tokens unknown (known %.0f; %d unknown calls), ", t, tu
          else printf "tokens %.0f, ", t
          if (cu[p] == n[p]) printf "cost unknown\n"; else printf "estimated cost %s%s\n", money(c[p]), (cu[p] ? " (PARTIAL: some costs unknown)" : "")
        } else {
          if (cu[p] == n[p]) printf "cost unknown\n"; else printf "cost %s%s\n", money(c[p]), (cu[p] ? " (PARTIAL: some costs unknown)" : "")
        }
      }
      for (k = 1; k <= 2; k++) {
        p = ps[k]
        if (!dn[p]) continue
        printf "dedupe %s: calls %d, ", p, dn[p]
        if (p == "codex") printf "tokens %s, ", (dtu ? "unknown" : sprintf("%.0f", dt))
        if (dcu[p] == dn[p]) printf "cost unknown\n"; else printf "%scost %s%s\n", (p == "codex" ? "estimated " : ""), money(dc[p]), (dcu[p] ? " (PARTIAL: some costs unknown)" : "")
      }
      cc = c["claude"] + dc["claude"]
      printf "total: claude cost %s%s; codex tokens %s\n", money(cc), ((cu["claude"] + dcu["claude"]) ? " (PARTIAL: some costs unknown)" : ""), ((tu + dtu) ? "unknown" : sprintf("%.0f", t + dt))
      if (bad != "") printf "FAILED:%s\n", bad
    }' "$OUT/runs.tsv" ${SUMMARY_DEDUPE:+"$SUMMARY_DEDUPE"}
  if [ -f "$OUT/clusters.md" ]; then cat "$OUT/clusters.md"; fi
}

cmd_summary() {
  # every awk here runs under LC_ALL=C: in a decimal-comma locale (de_DE, fr_FR, ...) awk would read the
  # JSON costs wrongly and print $0,0000, which looks like a real zero
  [ -s "$OUT/runs.tsv" ] || die "no runs.tsv in $OUT"
  local SUMMARY_DEDUPE='' provs
  [ ! -s "$OUT/dedupe_cost.tsv" ] || SUMMARY_DEDUPE="$OUT/dedupe_cost.tsv"
  provs=$(LC_ALL=C awk -F'\t' 'NF >= 7 {print $7}' "$OUT/runs.tsv" | sort -u | tr '\n' ' ')
  # the summary follows the providers that actually ran (runs.tsv), not the requested mode
  case $provs in *claude*codex*) mix_summary; return ;; esac
  case $provs in *codex*) codex_summary codex; return ;; esac
  case $provs in *claude*) ;; *) if [ -f "$OUT/provider" ]; then codex_summary codex; return; fi ;; esac   # runs.tsv from before the provider column
  if [ -n "$SUMMARY_DEDUPE" ] && grep -q "$(printf '\tcodex\t')" "$SUMMARY_DEDUPE"; then
    codex_summary claude; return
  fi
  local dc=0 dn=0 du=0
  if [ -s "$OUT/dedupe_cost.tsv" ]; then
    dc=$(LC_ALL=C awk -F'\t' '$2 ~ /^[0-9.eE+-]+$/ {s+=$2} END{printf "%.6f", s+0}' "$OUT/dedupe_cost.tsv"); dn=$(wc -l < "$OUT/dedupe_cost.tsv" | tr -d ' ')
    du=$(LC_ALL=C awk -F'\t' '$2 !~ /^[0-9.eE+-]+$/ {n++} END{print n+0}' "$OUT/dedupe_cost.tsv")
  fi
  LC_ALL=C awk -F'\t' -v dc="$dc" -v dn="$dn" -v du="$du" 'BEGIN{n=0;ok=0;c=0;f=0;u=0;unk=0}
    {n++; if($2 ~ /^[0-9.eE+-]+$/){c+=$2} else unk++; u+=$5; if($3=="ok"){ok++; f+=$4} else bad=bad" "$1}
    END{printf "runs %d, ok %d, failed %d, findings %d, unparsed lines %d (kept in lists/, not clustered), worker cost $%.4f (mean $%.4f per ok run)%s\n", n, ok, n-ok, f, u, c, (ok?c/ok:0), (unk?" plus "unk" call(s) with unknown cost":"");
      if(dn>0) printf "dedupe calls %d, cost $%.4f%s; total cost $%.4f%s\n", dn, dc, (du?" (+"du" with unknown cost)":""), c+dc, ((unk+du)?" (PARTIAL: some costs unknown)":"");
      if(bad!="") printf "FAILED:%s\n", bad}' "$OUT/runs.tsv"
  if [ -f "$OUT/clusters.md" ]; then cat "$OUT/clusters.md"; fi
}

cmd_run() {
  local TASK_FILE='' CHANGE='' MODEL='' MODEL_SET=0 MAXKB_SET=0 COPIES=3 WHOLE='' PARALLEL=12 TIMEOUT=280 MAXKB=150 DRY=0 NOLENS=0 LENSFILE='' SPLIT='' SPLIT_FLAG=0
  local LNAME=() LTEXT=() FILES=() CONTEXT=() i name text line
  while [ $# -gt 0 ]; do
    case $1 in
      --out) OUT=${2:-}; shift 2 ;;
      --task-file) TASK_FILE=${2:-}; shift 2 ;;
      --change) CHANGE=${2:-}; shift 2 ;;
      --context)
        case ${2:-} in ''|--*|-h) die "--context needs FILE (prefix option-like paths with ./)" ;; esac
        CONTEXT+=("$2"); shift 2
        while [ $# -gt 0 ]; do
          case $1 in -*) break ;; esac
          CONTEXT+=("$1"); shift
        done ;;
      --provider) [ $# -ge 2 ] || die "--provider needs auto, mix, claude or codex"; REQ=$2; shift 2 ;;
      --model) MODEL=${2:-}; MODEL_SET=1; shift 2 ;;
      --claude-model) CLAUDE_MODEL=${2:-}; shift 2 ;;
      --codex-model) CODEX_MODEL=${2:-}; shift 2 ;;
      --codex-effort) CODEX_EFFORT=${2:-}; shift 2 ;;
      --split) SPLIT=${2:-}; SPLIT_FLAG=1; shift 2 ;;
      --lens) [ -n "${2:-}" ] || die "--lens needs name=text"; case $2 in *=*) ;; *) die "--lens needs name=text" ;; esac
              name=${2%%=*}; text=${2#*=}; valid_name "$name" || die "bad lens name '$name'"
              LNAME+=("$name"); LTEXT+=("$text"); shift 2 ;;
      --lenses-file) LENSFILE=${2:-}; shift 2 ;;
      --no-lens) NOLENS=1; shift ;;
      --copies) COPIES=${2:-}; shift 2 ;;
      --whole) WHOLE=${2:-}; shift 2 ;;
      --parallel) PARALLEL=${2:-}; shift 2 ;;
      --timeout) TIMEOUT=${2:-}; shift 2 ;;
      --max-input-kb) MAXKB=${2:-}; MAXKB_SET=1; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      -h|--help) usage 0 ;;
      --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
      -*) die "unknown option $1" ;;
      *) FILES+=("$1"); shift ;;
    esac
  done
  setup_provider
  [ -n "${OUT:-}" ] || die "--out DIR is required"
  [ "$MODEL_SET" = 0 ] || valid_model "$MODEL" || die "bad --model"
  valid_model "$CLAUDE_MODEL" || die "bad --claude-model"
  valid_model "$CODEX_MODEL" || die "bad --codex-model"
  case $CODEX_EFFORT in minimal|low|medium|high|xhigh) ;; *) die "--codex-effort must be minimal, low, medium, high or xhigh" ;; esac
  [ "$REQ" != mix ] || [ "$MODEL_SET" = 0 ] || die "--model cannot name both models of a mixed run: use --claude-model and --codex-model"
  if [ "$SPLIT_FLAG" = 0 ] && [ -n "${MEGAVIBE_AMASS_SPLIT:-}" ]; then
    case $REQ in claude|codex) ;; *) SPLIT=$MEGAVIBE_AMASS_SPLIT ;; esac
  fi
  if [ -n "$SPLIT" ] || [ "$SPLIT_FLAG" = 1 ]; then
    printf '%s' "$SPLIT" | LC_ALL=C grep -Eq '^[0-9]+:[0-9]+$' || die "the split must be N:M (claude:codex), non-negative integers"
    case $SPLIT in *[1-9]*) ;; *) die "the split must not be 0:0" ;; esac
    case $REQ in claude|codex) die "--split needs --provider mix or auto" ;; esac
  fi
  case $REQ in claude|codex) PROVS=$REQ ;; *) PROVS='claude codex' ;; esac
  apply_caps
  for i in "$COPIES" "$PARALLEL" "$TIMEOUT" "$MAXKB"; do isnum "$i" || die "numeric option expected, got '$i'"; done
  [ "$COPIES" -ge 1 ] && [ "$PARALLEL" -ge 1 ] && [ "$TIMEOUT" -ge 1 ] || die "--copies, --parallel and --timeout must be at least 1"
  [ -z "$WHOLE" ] || isnum "$WHOLE" || die "--whole must be a number"
  if [ -z "${FILES[*]+x}" ]; then
    [ -n "${CONTEXT[*]+x}" ] && die "no FILE to inline (files after --context are context: put the reviewed files before --context, or after --)"
    die "no FILE to inline"
  fi
  # a path that starts with - must not become an option of cat, cmp or tr: make every operand explicit,
  # and read files by redirection
  for i in "${!FILES[@]}"; do case ${FILES[$i]} in /*|./*) ;; *) FILES[$i]=./${FILES[$i]} ;; esac; done
  if [ ${#CONTEXT[@]} -gt 0 ]; then
    for i in "${!CONTEXT[@]}"; do case ${CONTEXT[$i]} in /*|./*) ;; *) CONTEXT[$i]=./${CONTEXT[$i]} ;; esac; done
  fi
  case $TASK_FILE in ""|/*|./*) ;; *) TASK_FILE=./$TASK_FILE ;; esac
  case $LENSFILE in ""|/*|./*) ;; *) LENSFILE=./$LENSFILE ;; esac
  need jq; need perl
  if [ -n "$TASK_FILE" ]; then [ -f "$TASK_FILE" ] || die "no such task file $TASK_FILE"; fi
  # The guarded expansion also works for an empty context array under bash 3.2 set -u.
  for i in "${FILES[@]}" ${CONTEXT[@]+"${CONTEXT[@]}"}; do
    [ -f "$i" ] && [ -r "$i" ] || die "cannot read $i"
    if ! LC_ALL=C tr -d '\000' < "$i" | cmp -s - "$i"; then die "$i looks binary (contains NUL bytes)"; fi
  done
  if [ "$NOLENS" = 0 ] && [ ${#LNAME[@]} -eq 0 ]; then
    if [ -n "$LENSFILE" ]; then [ -f "$LENSFILE" ] || die "no such lenses file"; else LENSFILE=''; fi
    # `|| [ -n "$line" ]`: a last line without a newline is still a lens
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in ''|'#'*) continue ;; esac
      name=${line%%|*}; text=${line#*|}; valid_name "$name" || die "bad lens name '$name' in lens list"
      LNAME+=("$name"); LTEXT+=("$text")
    done < <(if [ -n "$LENSFILE" ]; then cat < "$LENSFILE"; else default_lenses; fi)
    # a lenses file that yields nothing must not silently become twelve whole-change calls
    if [ -n "$LENSFILE" ] && [ ${#LNAME[@]} -eq 0 ]; then die "no lens found in $LENSFILE (one 'name|text' per line)"; fi
  fi
  [ -n "$WHOLE" ] || { if [ ${#LNAME[@]} -eq 0 ]; then WHOLE=12; else WHOLE=0; fi; }
  if [ ${#LNAME[@]} -eq 0 ] && [ "$WHOLE" -eq 0 ]; then die "nothing to run (no lens and --whole 0)"; fi
  # names must be unique, and must not collide with the whole runs
  if [ ${#LNAME[@]} -gt 0 ]; then
    # compared without regard to case: x and X are one file on a case-insensitive file system
    local lo
    for i in "${!LNAME[@]}"; do
      lo=$(printf '%s' "${LNAME[$i]}" | tr 'A-Z' 'a-z')
      [ "$lo" != whole ] || die "lens name 'whole' is reserved"
      for name in "${LNAME[@]:$((i+1))}"; do
        [ "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" != "$lo" ] || die "duplicate lens name '${LNAME[$i]}' (names are compared without regard to case)"
      done
    done
  fi

  # the output directory is claimed exclusively and atomically: mkdir without -p fails when
  # anything (a directory, a file, a symlink) already has that name, so two runs cannot share one
  local DRYDIR=''
  if [ "$DRY" = 1 ]; then
    OUT=$(mktemp -d "${TMPDIR:-/tmp}/amass-dry.XXXXXX") || die "cannot create a scratch directory"; DRYDIR=$OUT; CX_DRY=$OUT   # a refusal after this point must not leave the scratch directory
  else
    case $OUT in */) OUT=${OUT%/} ;; esac
    [ -n "$OUT" ] || die "bad --out"
    case $OUT in */*) mkdir -p "${OUT%/*}" ;; esac
    mkdir "$OUT" 2>/dev/null || die "$OUT already exists (or cannot be created); every run needs a new --out"
  fi
  mkdir "$OUT/raw" "$OUT/lists" "$OUT/prompts" "$OUT/work"
  OUT=$(cd "$OUT" && pwd -P); WORK="$OUT/work"
  {
    if [ -n "$TASK_FILE" ]; then cat < "$TASK_FILE"; else
      printf '%s\n' "$DEFAULT_HEAD"
      [ -z "$CHANGE" ] || printf '\nChange under review: %s\n' "$CHANGE"
      printf '%s\n' "$FORMAT"
    fi
    if [ ${#CONTEXT[@]} -gt 0 ]; then
      printf '\n%s\n' 'CONTEXT blocks are context (callers, callees, tests of the changed functions), not under review; findings must be about the reviewed files in FILE blocks.'
    fi
    for i in "${FILES[@]}"; do printf '\n===== FILE %s =====\n' "$i"; cat < "$i"; done
    for i in ${CONTEXT[@]+"${CONTEXT[@]}"}; do printf '\n===== CONTEXT %s =====\n' "$i"; cat < "$i"; done
  } > "$OUT/base.txt"
  local bytes kb
  bytes=$(wc -c < "$OUT/base.txt" | tr -d ' '); kb=$(( (bytes + 1023) / 1024 ))
  printf 'input %d KB (about %d tokens at 1.8 bytes per token)\n' "$kb" $(( bytes * 10 / 18 ))
  # auto without an explicit cap needs to know who is usable before it knows the cap
  if [ "$REQ" = auto ] && [ "$MAXKB_SET" = 0 ]; then resolve_providers; apply_caps; fi
  if [ "$kb" -gt "$MAXKB" ]; then die "input is $kb KB, above --max-input-kb $MAXKB ($CAP_REASON); inline less or raise the limit on purpose"; fi

  # prompts: the shared base first, the lens last
  local PN=() PK=()
  if [ ${#LNAME[@]} -gt 0 ]; then
    for i in "${!LNAME[@]}"; do
      { cat "$OUT/base.txt"; printf '\n===== LENS =====\nReport only defects that fit this lens: %s\n' "${LTEXT[$i]}"; } > "$OUT/prompts/${LNAME[$i]}.txt"
      PN+=("${LNAME[$i]}"); PK+=("$COPIES")
    done
  fi
  if [ "$WHOLE" -gt 0 ]; then
    { cat "$OUT/base.txt"; printf '\n===== LENS =====\nnone, cover the whole change.\n'; } > "$OUT/prompts/whole.txt"
    PN+=(whole); PK+=("$WHOLE")
  fi
  # the cap is on the LARGEST prompt (base plus lens text), not on the base alone
  local pk
  for i in "${!PN[@]}"; do
    pk=$(( ($(wc -c < "$OUT/prompts/${PN[$i]}.txt") + 1023) / 1024 ))
    if [ "$pk" -gt "$MAXKB" ]; then die "prompt '${PN[$i]}' is $pk KB, above --max-input-kb $MAXKB$CAP_SUFFIX"; fi
  done
  local total=0
  for i in "${!PN[@]}"; do total=$((total + PK[i])); done
  printf '%d prompts, %d calls, up to %d at once\n' "${#PN[@]}" "$total" "$PARALLEL"
  resolve_providers
  finalize_models
  local NCL
  case $PROVS in
    'claude codex')
      split_calls "$total" "$SPLIT"; NCL=$NC
      if [ -n "$SPLIT" ]; then
        printf 'split: override %s; claude %d (%s), codex %d (%s)\n' "$SPLIT" "$NCL" "$CLAUDE_MODEL" "$((total - NCL))" "$CODEX_MODEL"
      else
        printf 'split: claude %d (%s), codex %d (%s); %s\n' "$NCL" "$CLAUDE_MODEL" "$((total - NCL))" "$CODEX_MODEL" "$SPLIT_DESC"
      fi ;;
    codex) NCL=0; printf 'provider codex, model %s\n' "$CODEX_MODEL" ;;
    *) NCL=$total; printf 'provider claude, model %s\n' "$CLAUDE_MODEL" ;;
  esac
  if [ "$DRY" = 1 ]; then
    rm -rf "$DRYDIR"; echo "dry run: nothing was sent"
    case $REQ in auto|mix) echo "dry run: no login was checked, so auto plans for both providers" ;; esac
    return 0
  fi
  if [ "$PROVS" = codex ]; then printf 'codex\n' > "$OUT/provider"; fi
  printf '%s\n' "$REQ" > "$OUT/requested"

  # Assign a provider to every call. The walk is copy-major (copy 1 of every prompt, then copy 2, ...) and
  # snakes: odd copies in prompt order, even copies reversed, so an even number of prompts cannot lock one
  # provider onto the same lenses. A running deficit (Bresenham) interleaves the two providers.
  local AP=() AW maxk=0 j=0 cc=0 order idx
  for i in "${!PN[@]}"; do [ "${PK[$i]}" -le "$maxk" ] || maxk=${PK[$i]}; done
  AW=$((maxk + 1))
  k=1
  while [ "$k" -le "$maxk" ]; do
    order=''
    for i in "${!PN[@]}"; do
      if [ "${PK[$i]}" -ge "$k" ]; then
        if [ $((k % 2)) -eq 0 ]; then order="$i $order"; else order="$order $i"; fi
      fi
    done
    for i in $order; do
      j=$((j + 1))
      if [ $(( (2 * j * NCL + total) / (2 * total) )) -gt "$cc" ]; then AP[$((i * AW + k))]=claude; cc=$((cc + 1))
      else AP[$((i * AW + k))]=codex; fi
    done
    k=$((k + 1))
  done

  local PIDS=() live n k
  throttle() {
    while :; do
      live=0
      for n in ${PIDS[@]+"${PIDS[@]}"}; do alive "$n" && live=$((live + 1)); done
      [ "$live" -lt "$PARALLEL" ] && break
      sleep 1
    done
  }
  launch() { # prompt name, copy number, provider
    local nm=$1 kk=$2 pv=$3 mdl pid
    mdl=$(model_of "$pv")
    throttle
    printf '%s\n' "$pv" > "$OUT/raw/${nm}_${kk}.provider"
    ( trap sup_stop EXIT
      trap 'exit 143' TERM HUP
      trap 'exit 130' INT
      rc=0; call_model "$pv" "$mdl" "$TIMEOUT" "$OUT/prompts/$nm.txt" "$OUT/raw/${nm}_${kk}.json" "$OUT/raw/${nm}_${kk}.err" || rc=$?
      echo "$rc" > "$OUT/raw/${nm}_${kk}.rc" ) &
    pid=$!
    PIDS+=("$pid")
    WORKERS+=("$pid")
  }
  # phase 1: the first call of every prompt on each provider it uses writes that provider's cache;
  # phase 2: the rest read it
  local P1=() n1=0 seenc seenx pv
  for i in "${!PN[@]}"; do
    seenc=0; seenx=0; k=1
    while [ "$k" -le "${PK[$i]}" ]; do
      idx=$((i * AW + k)); pv=${AP[$idx]}
      if [ "$pv" = claude ] && [ "$seenc" = 0 ]; then seenc=1; P1[$idx]=1; n1=$((n1 + 1)); launch "${PN[$i]}" "$k" claude
      elif [ "$pv" = codex ] && [ "$seenx" = 0 ]; then seenx=1; P1[$idx]=1; n1=$((n1 + 1)); launch "${PN[$i]}" "$k" codex; fi
      k=$((k + 1))
    done
  done
  if [ "$total" -gt "$n1" ]; then
    sleep "$STAGGER"
    for i in "${!PN[@]}"; do
      k=1; while [ "$k" -le "${PK[$i]}" ]; do
        idx=$((i * AW + k))
        [ -n "${P1[$idx]:-}" ] || launch "${PN[$i]}" "$k" "${AP[$idx]}"
        k=$((k + 1))
      done
    done
  fi
  wait
  WORKERS=()

  : > "$OUT/runs.tsv"
  local cost nf st rc nl nu tk
  for i in "${!PN[@]}"; do
    k=1; while [ "$k" -le "${PK[$i]}" ]; do
      n="${PN[$i]}_$k"; pv=${AP[$((i * AW + k))]}; rc=$(cat "$OUT/raw/$n.rc" 2>/dev/null || echo 99); nf=0; nu=0; st=ok
      cost=$(call_cost "$pv" "$OUT/raw/$n.json")
      if [ "$rc" != 0 ]; then st="fail(rc=$rc)"
      elif extract "$OUT/raw/$n.json" "$OUT/lists/$n.md"; then
        nf=$(grep -cE "$FPAT" "$OUT/lists/$n.md" || true)
        nl=$(grep -c '[^[:space:]]' "$OUT/lists/$n.md" || true)
        nu=$((nl - nf))
        # text with no finding line at all is not a clean "no findings": it did not follow the format
        if [ "$nf" -eq 0 ] && [ "$nl" -gt 0 ]; then st="fail(unformatted)"; fi
      else st="fail(bad-output)"; fi
      if [ "$pv" = codex ]; then tk=$(call_tokens "$OUT/raw/$n.json"); else tk=-; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$cost" "$st" "$nf" "$nu" "$tk" "$pv" >> "$OUT/runs.tsv"
      k=$((k + 1))
    done
  done
  # the run is final now: lists/ and runs.tsv are complete, so dedupe may read them
  printf 'done\n' > "$OUT/.complete.tmp" && mv "$OUT/.complete.tmp" "$OUT/.complete"
  cmd_summary
  local tn tok tc tu used=''
  [ "$NCL" -eq 0 ] || used=claude
  [ "$NCL" -eq "$total" ] || used="$used codex"
  for pv in $used; do
    read -r tn tok tc tu < <(LC_ALL=C awk -F'\t' -v p="$pv" '$7 == p {n++; if($3=="ok")o++; if($2 ~ /^[0-9.eE+-]+$/)c+=$2; else k++} END{printf "%d %d %.6f %d\n", n, o+0, c+0, k+0}' "$OUT/runs.tsv")
    if [ "$pv" = codex ]; then
      # Preserve small estimates instead of rounding them to the legacy six decimals.
      tc=$(jq -Rn '[inputs | split("\t") | select(.[6] == "codex") | .[1] | tonumber?] | add // 0' "$OUT/runs.tsv")
    fi
    ledger run "$(model_of "$pv")" "$tn" "$tok" "$tc" "$kb" "$tu" "$(total_tokens "$OUT/runs.tsv" 6 "$pv")" "$pv"
  done
  if ! grep -q "$(printf '\tok\t')" "$OUT/runs.tsv"; then
    echo "$PROG: no call succeeded; first error:" >&2; head -c 300 "$OUT"/raw/*.err 2>/dev/null | head -3 >&2; exit 3
  fi
}

cmd_dedupe() {
  local MODEL='' MODEL_SET=0 MAXKB_SET=0 TIMEOUT=280 MAXKB=150 DRY=0 DP REQ_SET=0 rq
  while [ $# -gt 0 ]; do
    case $1 in
      --out) OUT=${2:-}; shift 2 ;;
      --provider) [ $# -ge 2 ] || die "--provider needs auto, claude or codex"; REQ=$2; REQ_SET=1; shift 2 ;;
      --model) MODEL=${2:-}; MODEL_SET=1; shift 2 ;;
      --claude-model) CLAUDE_MODEL=${2:-}; shift 2 ;;
      --codex-model) CODEX_MODEL=${2:-}; shift 2 ;;
      --codex-effort) CODEX_EFFORT=${2:-}; shift 2 ;;
      --timeout) TIMEOUT=${2:-}; shift 2 ;;
      --max-input-kb) MAXKB=${2:-}; MAXKB_SET=1; shift 2 ;;
      -h|--help) usage 0 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ "$REQ" != mix ] || REQ=auto
  [ -n "${OUT:-}" ] && [ -d "$OUT/lists" ] || die "--out must be a finished run directory"
  [ -e "$OUT/.complete" ] || die "$OUT is not a finished run (no .complete marker): wait for amass.sh run to return before dedupe"
  # a run that the user forced onto one provider is deduped on that provider unless --provider says otherwise
  if [ "$REQ_SET" = 0 ] && [ -s "$OUT/requested" ]; then
    rq=$(head -n1 "$OUT/requested")
    case $rq in claude|codex) REQ=$rq ;; esac
  fi
  setup_provider
  case $REQ in claude|codex) PROVS=$REQ ;; *) PROVS='claude codex' ;; esac
  apply_caps
  [ "$MODEL_SET" = 0 ] || valid_model "$MODEL" || die "bad --model"
  valid_model "$CLAUDE_MODEL" || die "bad --claude-model"
  valid_model "$CODEX_MODEL" || die "bad --codex-model"
  case $CODEX_EFFORT in minimal|low|medium|high|xhigh) ;; *) die "--codex-effort must be minimal, low, medium, high or xhigh" ;; esac
  isnum "$TIMEOUT" && isnum "$MAXKB" || die "numeric option expected"
  [ "$TIMEOUT" -ge 1 ] || die "--timeout must be at least 1 (0 would disable the deadline)"
  need jq; need perl
  OUT=$(cd "$OUT" && pwd -P); WORK="$OUT/work"; mkdir -p "$WORK"
  resolve_providers
  case $PROVS in
    *' '*) [ "$MODEL_SET" = 0 ] || die "--model cannot name both models of a mixed run: use --claude-model and --codex-model" ;;
  esac
  if [ "$PROVS" = 'claude codex' ]; then
    # the provider with the LOWER projected usage has the headroom; ties go to claude
    both_proj
    DP=$(LC_ALL=C awk -v a="$EC" -v b="$EX" 'BEGIN{if (a == "" || b == "") {print "claude"; exit} print (b + 0 < a + 0) ? "codex" : "claude"}')
    printf 'dedupe: provider %s (projections claude %s, codex %s; the lower one has the headroom, a tie goes to claude)\n' "$DP" "$(proj_text "$PC" "$SC")" "$(proj_text "$PX" "$SX")"
  else DP=$PROVS; fi
  PROVS=$DP; finalize_models; apply_caps
  MODEL=$(model_of "$DP")
  # two dedupes on one run directory would overwrite each other's files and costs
  mkdir "$OUT/.dedupe.lock" 2>/dev/null || die "another dedupe seems to be running on $OUT (remove $OUT/.dedupe.lock if it is stale)"
  DD_LOCK="$OUT/.dedupe.lock"
  local f n line num
  : > "$OUT/dedupe_in.txt"; : > "$OUT/dedupe_unparsed.txt"
  for f in "$OUT"/lists/*.md; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .md); num=0
    while IFS= read -r line; do
      printf '%s' "$line" | grep -q '[^[:space:]]' || continue
      if printf '%s' "$line" | grep -qE "$FPAT"; then
        num=$((num + 1))
        printf '%s.F%d | %s\n' "$n" "$num" "$(printf '%s' "$line" | sed -E 's/^[^A-Za-z0-9]*F[0-9]+[^A-Za-z0-9|]*\|[[:space:]]*//')" >> "$OUT/dedupe_in.txt"
      else
        printf '%s: %s\n' "$n" "$line" >> "$OUT/dedupe_unparsed.txt"
      fi
    done < "$f"
  done
  local lines kb
  lines=$(wc -l < "$OUT/dedupe_in.txt" | tr -d ' '); kb=$(( ($(wc -c < "$OUT/dedupe_in.txt") + 1023) / 1024 ))
  [ "$lines" -gt 0 ] || die "no findings to dedupe in $OUT/lists"
  [ "$kb" -le "$MAXKB" ] || die "dedupe input is $kb KB, above --max-input-kb $MAXKB$CAP_SUFFIX; dedupe per lens in separate run directories"
  {
    printf '%s\n' 'You are the dedupe stage of a code-review pipeline. Below, each line is: ID | severity | location | what goes wrong | why. Many lines from different reviewers describe the SAME underlying defect. Group them: one cluster = one distinct underlying defect (same root cause and same kind of location). Do NOT merge different defects just because they touch the same file. Do not judge whether a defect is real, do not fix, do not drop anything: every ID must appear in exactly one cluster. Output one line per cluster, nothing else, in exactly this format:'
    printf '%s\n' 'C<n> | severity (highest in the cluster) | one-sentence defect | members: ID,ID,ID'
    printf '%s\n' 'If the cluster text names no concrete failing input (a specific input value, call or state that triggers it), append [no-input] at the end of the line, after the members list. This marker is advisory: never drop a cluster because of it. A marker inside quoted finding text is literal text, not this flag.'
    printf '\n===== FINDINGS =====\n'; cat "$OUT/dedupe_in.txt"
  } > "$OUT/dedupe_prompt.txt"
  # the cap is on the whole prompt, instructions included
  local pk
  pk=$(( ($(wc -c < "$OUT/dedupe_prompt.txt") + 1023) / 1024 ))
  [ "$pk" -le "$MAXKB" ] || die "the dedupe prompt is $pk KB, above --max-input-kb $MAXKB$CAP_SUFFIX; dedupe per lens in separate run directories"
  printf 'dedupe: %d findings, %d KB, provider %s, model %s\n' "$lines" "$pk" "$DP" "$MODEL"
  local rc=0 cost dok=0
  call_model "$DP" "$MODEL" "$TIMEOUT" "$OUT/dedupe_prompt.txt" "$OUT/dedupe_raw.json" "$OUT/dedupe_raw.err" || rc=$?
  cost=$(call_cost "$DP" "$OUT/dedupe_raw.json")
  if [ "$DP" = codex ]; then
    printf 'dedupe\t%s\tcodex\t%s\n' "$cost" "$(call_tokens "$OUT/dedupe_raw.json")" >> "$OUT/dedupe_cost.tsv"
  else printf 'dedupe\t%s\n' "$cost" >> "$OUT/dedupe_cost.tsv"; fi   # every attempt is accounted for, failed ones too
  if [ "$rc" = 0 ] && extract "$OUT/dedupe_raw.json" "$OUT/clusters_raw.md"; then dok=1; fi
  ledger dedupe "$MODEL" 1 "$dok" "$cost" "$pk" "$([ "$cost" = '?' ] && echo 1 || echo 0)" "$(call_tokens "$OUT/dedupe_raw.json")" "$DP"   # before any failure exit
  [ "$rc" = 0 ] || { echo "$PROG: dedupe call failed (rc=$rc)" >&2; head -c 300 "$OUT/dedupe_raw.err" >&2; exit 3; }
  [ "$dok" = 1 ] || { echo "$PROG: dedupe output unusable" >&2; exit 3; }
  # Parse the final members field, not arbitrary pipes or n= in the defect text.
  # Only a terminal, unquoted marker is metadata; quoted occurrences stay literal.
  # Keep clusters with missing/empty member lists too, with a count of zero.
  : > "$OUT/id_provider.txt"
  if ls "$OUT"/raw/*.provider >/dev/null 2>&1 && [ "$(cat "$OUT"/raw/*.provider | sort -u | wc -l | tr -d ' ')" -ge 2 ]; then
    for f in "$OUT"/raw/*.provider; do printf '%s %s\n' "$(basename "$f" .provider)" "$(cat "$f")"; done > "$OUT/id_provider.txt"
  fi
  perl -e '
    use strict; use warnings;
    open my $seen, ">", shift @ARGV or die "members_seen: $!";
    # n counts DISTINCT, known finding ids only: a repeated or invented id is not support
    my %valid;
    open my $vin, "<", shift @ARGV or die "dedupe_in: $!";
    while (my $vl = <$vin>) { chomp $vl; my ($vid) = split / /, $vl, 2; $valid{$vid} = 1 if defined $vid && length $vid; }
    close $vin;
    # run name -> provider; empty unless the run used both providers (then clusters show the support split)
    my %prov;
    open my $pin, "<", shift @ARGV or die "id_provider: $!";
    while (my $pl = <$pin>) { chomp $pl; my ($r, $pv) = split / /, $pl, 2; $prov{$r} = $pv if defined $pv && length $r; }
    close $pin;
    while (<>) {
      chomp; s/\r$//;
      next unless /^[^A-Za-z0-9]*(C[0-9]+)\s*\|\s*([^|]+?)\s*\|\s*(.*?)\s*$/;
      my ($id, $severity, $body) = ($1, $2, $3);
      my $flag = $body =~ s/\s+\[no-input\]$// ? " [no-input]" : "";
      my $members = $body =~ s/\s*\|\s*members:\s*([^|]*)$// ? $1 : "";
      my @ids = grep { length } map { s/^\s+|\s+$//g; $_ } split /,/, $members;
      print $seen "$_\n" for @ids;
      my (%once, %pc); my $count = 0;
      for my $mid (@ids) {
        next unless $valid{$mid} && !$once{$mid}++;
        $count++;
        if (%prov) { my ($run) = $mid =~ /^(.*)\.F[0-9]+$/; $pc{$prov{$run} // "?"}++ if defined $run; }
      }
      my $sup = (%prov && %pc) ? " (" . join(", ", map { "$_ $pc{$_}" } sort keys %pc) . ")" : "";
      print "$count\t$id\t$id | $severity | n=$count$sup | $body | members: ", join(",", @ids), "$flag\n";
    }
    close $seen or die "members_seen: $!";
  ' "$OUT/members_seen.txt" "$OUT/dedupe_in.txt" "$OUT/id_provider.txt" "$OUT/clusters_raw.md" > "$OUT/clusters.tsv"
  # nothing may be lost: every id exactly once; the omitted ones are appended as one cluster
  sort -o "$OUT/members_seen.txt" "$OUT/members_seen.txt"
  cut -d' ' -f1 "$OUT/dedupe_in.txt" | sort > "$OUT/members_all.txt"
  comm -13 "$OUT/members_seen.txt" "$OUT/members_all.txt" > "$OUT/members_missing.txt"
  uniq -d "$OUT/members_seen.txt" > "$OUT/members_dup.txt"
  comm -23 <(sort -u "$OUT/members_seen.txt") "$OUT/members_all.txt" > "$OUT/members_unknown.txt"
  if [ -s "$OUT/members_missing.txt" ]; then
    local missing
    missing=$(wc -l < "$OUT/members_missing.txt" | tr -d ' ')
    printf '%s\tCUNK\tCUNK | ? | n=%s | not clustered by the dedupe call (kept so nothing is lost) | members: %s\n' "$missing" "$missing" "$(paste -sd, "$OUT/members_missing.txt")" >> "$OUT/clusters.tsv"
  fi
  # Explicit keys keep text (including pipes, n= and tabs) out of the ordering.
  # -s preserves model order even if both keys tie; model ids are never renumbered.
  LC_ALL=C sort -s -t "$(printf '\t')" -k1,1nr -k2,2 "$OUT/clusters.tsv" | cut -f3- > "$OUT/clusters.md"
  local spend="cost \$$cost"
  if [ "$DP" = codex ]; then
    spend=$(call_tokens "$OUT/dedupe_raw.json")
    [ "$spend" != '?' ] || spend=unknown
    spend="tokens $spend"
    if [ "$cost" != '?' ]; then spend="$spend, estimated cost \$$cost"; else spend="$spend, cost unknown"; fi
  fi
  printf 'dedupe: %d clusters, %d findings omitted by the model and re-added, %d duplicated ids, %d unknown ids, %s\n' \
    "$(grep -c 'members:' "$OUT/clusters.md" || true)" "$(wc -l < "$OUT/members_missing.txt" | tr -d ' ')" "$(wc -l < "$OUT/members_dup.txt" | tr -d ' ')" "$(wc -l < "$OUT/members_unknown.txt" | tr -d ' ')" "$spend"
  if [ -s "$OUT/dedupe_unparsed.txt" ]; then
    printf 'dedupe: %d response lines were not in the finding format and are NOT clustered; read them in %s\n' "$(wc -l < "$OUT/dedupe_unparsed.txt" | tr -d ' ')" "$OUT/dedupe_unparsed.txt"
  fi
  cat "$OUT/clusters.md"
}

[ $# -ge 1 ] || usage 2
sub=$1; shift
OUT=''; WORK=''
case $sub in
  run) cmd_run "$@" ;;
  dedupe) cmd_dedupe "$@" ;;
  summary) while [ $# -gt 0 ]; do case $1 in --out) OUT=${2:-}; shift 2 ;; *) die "unknown option $1" ;; esac; done
           [ -n "$OUT" ] || die "--out DIR is required"; cmd_summary ;;
  -h|--help) usage 0 ;;
  *) usage 2 ;;
esac
