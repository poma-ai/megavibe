#!/bin/bash
# amass.sh — a cheap first pass: many headless one-shot model calls over the SAME inlined
# input, one lens per prompt, then ONE dedupe call. It is a source of LEADS, never a review
# and never a gate (the review tiers in .claude/rules/delegation.md are unchanged).
#
#   amass.sh run    --out DIR [--change TEXT | --task-file F] [--model haiku] [--lens name=text]...
#                   [--lenses-file F] [--no-lens] [--copies 3] [--whole 0] [--parallel 12]
#                   [--timeout 280] [--max-input-kb 150] [--dry-run] FILE... [--context FILE...]...
#   amass.sh dedupe --out DIR [--model haiku] [--timeout 280]
#   amass.sh summary --out DIR
#
# Why it is built this way (measured in a pilot; the numbers are in README-amass.md):
#  - Each call is `claude -p` with NO tools, no user, project or local settings (so no CLAUDE.md,
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
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

P1/P2 labels are the model's, not a measurement: measured precision is about
15-20 percent on real diffs and roughly 40 percent on fresh complex shell code.
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

# one bounded, tool-less, settings-less call: prompt file in, raw json out
call_claude() { # model timeout prompt_file out_json out_err ; returns the exit status
  ( cd "$WORK" && "${CLEAN[@]}" \
      perl -e 'alarm shift; exec @ARGV' "$2" "$CLAUDE_BIN" -p --model "$1" --output-format json \
      --tools "" --no-session-persistence --disable-slash-commands --strict-mcp-config \
      --setting-sources "" < "$3" > "$4" 2> "$5" )
}

# the cost of one call, whether or not it succeeded ("?" when the output has none)
call_cost() { # raw_json
  local c
  c=$(jq -s -r 'if length != 1 then empty else .[0] | (if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end) | select(type == "object") | (.total_cost_usd | select(type == "number")) end' "$1" 2>/dev/null) || c=''
  [ -n "$c" ] && printf '%s' "$c" || printf '?'
}

# result text out of one raw json file; fails unless the call succeeded
extract() { # raw_json text_out
  # NUL bytes would be truncated by bash variables further down, so they are removed here
  jq -e -s -r 'if length != 1 then empty else .[0] | (if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end) | select(type == "object" and .is_error == false and (.result | type) == "string") | .result end' "$1" 2>/dev/null | tr -d '\000' > "$2"
}

# refuse anything but a claude.ai subscription login (a saved Console key would bill)
check_login() {
  local j m
  j=$("${CLEAN[@]}" \
        perl -e 'alarm shift; exec @ARGV' 30 "$CLAUDE_BIN" auth status 2>/dev/null) \
    || die "cannot verify the login ('$CLAUDE_BIN auth status' failed); refusing to send anything"
  m=$(printf '%s' "$j" | jq -r '.authMethod // empty' 2>/dev/null) || m=''
  [ "$m" = "claude.ai" ] || die "the login is not a claude.ai subscription login (authMethod='${m:-unknown}'); refusing, because such calls could bill an API key"
}

alive() { kill -0 "$1" 2>/dev/null; }

# one line per run/dedupe in a local ledger, so adoption and spend can be measured later.
# Best effort: a ledger that cannot be written never fails or slows a run.
ledger() { # cmd model calls ok cost input_kb unknown_costs   (cost is null whenever any call's cost is unknown; cost_known is the known subtotal)
  local f=${AMASS_LEDGER:-$HOME/.megavibe/amass-usage.jsonl}
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cmd "$1" --arg model "$2" --arg proj "$(basename "$PWD")" \
    --argjson calls "$3" --argjson ok "$4" --arg cost "$5" --argjson kb "$6" --argjson unk "${7:-0}" \
    '{ts:$ts,cmd:$cmd,model:$model,project:$proj,calls:$calls,ok:$ok,cost:(if $unk > 0 then null else ($cost|tonumber? // null) end),cost_known:($cost|tonumber? // null),cost_unknown_calls:$unk,input_kb:$kb}' >> "$f" 2>/dev/null || true
}

cmd_summary() {
  # every awk here runs under LC_ALL=C: in a decimal-comma locale (de_DE, fr_FR, ...) awk would read the
  # JSON costs wrongly and print $0,0000, which looks like a real zero
  [ -s "$OUT/runs.tsv" ] || die "no runs.tsv in $OUT"
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
  local TASK_FILE='' CHANGE='' MODEL=haiku COPIES=3 WHOLE='' PARALLEL=12 TIMEOUT=280 MAXKB=150 DRY=0 NOLENS=0 LENSFILE=''
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
      --model) MODEL=${2:-}; shift 2 ;;
      --lens) [ -n "${2:-}" ] || die "--lens needs name=text"; case $2 in *=*) ;; *) die "--lens needs name=text" ;; esac
              name=${2%%=*}; text=${2#*=}; valid_name "$name" || die "bad lens name '$name'"
              LNAME+=("$name"); LTEXT+=("$text"); shift 2 ;;
      --lenses-file) LENSFILE=${2:-}; shift 2 ;;
      --no-lens) NOLENS=1; shift ;;
      --copies) COPIES=${2:-}; shift 2 ;;
      --whole) WHOLE=${2:-}; shift 2 ;;
      --parallel) PARALLEL=${2:-}; shift 2 ;;
      --timeout) TIMEOUT=${2:-}; shift 2 ;;
      --max-input-kb) MAXKB=${2:-}; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      -h|--help) usage 0 ;;
      --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
      -*) die "unknown option $1" ;;
      *) FILES+=("$1"); shift ;;
    esac
  done
  [ -n "${OUT:-}" ] || die "--out DIR is required"
  valid_model "$MODEL" || die "bad --model"
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
    OUT=$(mktemp -d "${TMPDIR:-/tmp}/amass-dry.XXXXXX") || die "cannot create a scratch directory"; DRYDIR=$OUT
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
  printf 'input %d KB (about %d tokens at 1.8 bytes per token), model %s\n' "$kb" $(( bytes * 10 / 18 )) "$MODEL"
  if [ "$kb" -gt "$MAXKB" ]; then die "input is $kb KB, above --max-input-kb $MAXKB (Haiku bills the whole request 5x past 100K tokens); inline less or raise the limit on purpose"; fi

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
    if [ "$pk" -gt "$MAXKB" ]; then die "prompt '${PN[$i]}' is $pk KB, above --max-input-kb $MAXKB"; fi
  done
  local total=0
  for i in "${!PN[@]}"; do total=$((total + PK[i])); done
  printf '%d prompts, %d calls, up to %d at once\n' "${#PN[@]}" "$total" "$PARALLEL"
  if [ "$DRY" = 1 ]; then rm -rf "$DRYDIR"; echo "dry run: nothing was sent"; return 0; fi
  check_login

  local PIDS=() live n k
  throttle() {
    while :; do
      live=0
      for n in ${PIDS[@]+"${PIDS[@]}"}; do alive "$n" && live=$((live + 1)); done
      [ "$live" -lt "$PARALLEL" ] && break
      sleep 1
    done
  }
  launch() { # prompt name, copy number
    throttle
    ( rc=0; call_claude "$MODEL" "$TIMEOUT" "$OUT/prompts/$1.txt" "$OUT/raw/$1_$2.json" "$OUT/raw/$1_$2.err" || rc=$?
      echo "$rc" > "$OUT/raw/$1_$2.rc" ) &
    PIDS+=("$!")
  }
  # phase 1: the first copy of every prompt writes the cache; phase 2: the copies read it
  for i in "${!PN[@]}"; do launch "${PN[$i]}" 1; done
  if [ "$total" -gt "${#PN[@]}" ]; then
    sleep "$STAGGER"
    for i in "${!PN[@]}"; do
      k=2; while [ "$k" -le "${PK[$i]}" ]; do launch "${PN[$i]}" "$k"; k=$((k + 1)); done
    done
  fi
  wait

  : > "$OUT/runs.tsv"
  local cost nf st rc nl nu
  for i in "${!PN[@]}"; do
    k=1; while [ "$k" -le "${PK[$i]}" ]; do
      n="${PN[$i]}_$k"; rc=$(cat "$OUT/raw/$n.rc" 2>/dev/null || echo 99); nf=0; nu=0; st=ok
      cost=$(call_cost "$OUT/raw/$n.json")
      if [ "$rc" != 0 ]; then st="fail(rc=$rc)"
      elif extract "$OUT/raw/$n.json" "$OUT/lists/$n.md"; then
        nf=$(grep -cE "$FPAT" "$OUT/lists/$n.md" || true)
        nl=$(grep -c '[^[:space:]]' "$OUT/lists/$n.md" || true)
        nu=$((nl - nf))
        # text with no finding line at all is not a clean "no findings": it did not follow the format
        if [ "$nf" -eq 0 ] && [ "$nl" -gt 0 ]; then st="fail(unformatted)"; fi
      else st="fail(bad-output)"; fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$cost" "$st" "$nf" "$nu" >> "$OUT/runs.tsv"
      k=$((k + 1))
    done
  done
  # the run is final now: lists/ and runs.tsv are complete, so dedupe may read them
  printf 'done\n' > "$OUT/.complete.tmp" && mv "$OUT/.complete.tmp" "$OUT/.complete"
  cmd_summary
  local tn tok tc tu
  read -r tn tok tc tu < <(LC_ALL=C awk -F'\t' '{n++; if($3=="ok")o++; if($2 ~ /^[0-9.eE+-]+$/)c+=$2; else k++} END{printf "%d %d %.6f %d\n", n, o+0, c+0, k+0}' "$OUT/runs.tsv")
  ledger run "$MODEL" "$tn" "$tok" "$tc" "$kb" "$tu"
  if ! grep -q "$(printf '\tok\t')" "$OUT/runs.tsv"; then
    echo "$PROG: no call succeeded; first error:" >&2; head -c 300 "$OUT"/raw/*.err 2>/dev/null | head -3 >&2; exit 3
  fi
}

cmd_dedupe() {
  local MODEL=haiku TIMEOUT=280 MAXKB=150
  while [ $# -gt 0 ]; do
    case $1 in
      --out) OUT=${2:-}; shift 2 ;;
      --model) MODEL=${2:-}; shift 2 ;;
      --timeout) TIMEOUT=${2:-}; shift 2 ;;
      --max-input-kb) MAXKB=${2:-}; shift 2 ;;
      -h|--help) usage 0 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ -n "${OUT:-}" ] && [ -d "$OUT/lists" ] || die "--out must be a finished run directory"
  [ -e "$OUT/.complete" ] || die "$OUT is not a finished run (no .complete marker): wait for amass.sh run to return before dedupe"
  valid_model "$MODEL" || die "bad --model"; isnum "$TIMEOUT" && isnum "$MAXKB" || die "numeric option expected"
  [ "$TIMEOUT" -ge 1 ] || die "--timeout must be at least 1 (0 would disable the deadline)"
  need jq; need perl
  OUT=$(cd "$OUT" && pwd -P); WORK="$OUT/work"; mkdir -p "$WORK"
  # two dedupes on one run directory would overwrite each other's files and costs
  mkdir "$OUT/.dedupe.lock" 2>/dev/null || die "another dedupe seems to be running on $OUT (remove $OUT/.dedupe.lock if it is stale)"
  trap 'rmdir "$OUT/.dedupe.lock" 2>/dev/null || true' EXIT
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
  [ "$kb" -le "$MAXKB" ] || die "dedupe input is $kb KB, above --max-input-kb $MAXKB; dedupe per lens in separate run directories"
  {
    printf '%s\n' 'You are the dedupe stage of a code-review pipeline. Below, each line is: ID | severity | location | what goes wrong | why. Many lines from different reviewers describe the SAME underlying defect. Group them: one cluster = one distinct underlying defect (same root cause and same kind of location). Do NOT merge different defects just because they touch the same file. Do not judge whether a defect is real, do not fix, do not drop anything: every ID must appear in exactly one cluster. Output one line per cluster, nothing else, in exactly this format:'
    printf '%s\n' 'C<n> | severity (highest in the cluster) | one-sentence defect | members: ID,ID,ID'
    printf '%s\n' 'If the cluster text names no concrete failing input (a specific input value, call or state that triggers it), append [no-input] at the end of the line, after the members list. This marker is advisory: never drop a cluster because of it. A marker inside quoted finding text is literal text, not this flag.'
    printf '\n===== FINDINGS =====\n'; cat "$OUT/dedupe_in.txt"
  } > "$OUT/dedupe_prompt.txt"
  # the cap is on the whole prompt, instructions included
  local pk
  pk=$(( ($(wc -c < "$OUT/dedupe_prompt.txt") + 1023) / 1024 ))
  [ "$pk" -le "$MAXKB" ] || die "the dedupe prompt is $pk KB, above --max-input-kb $MAXKB; dedupe per lens in separate run directories"
  printf 'dedupe: %d findings, %d KB, model %s\n' "$lines" "$pk" "$MODEL"
  check_login
  local rc=0 cost dok=0
  call_claude "$MODEL" "$TIMEOUT" "$OUT/dedupe_prompt.txt" "$OUT/dedupe_raw.json" "$OUT/dedupe_raw.err" || rc=$?
  cost=$(call_cost "$OUT/dedupe_raw.json")
  printf 'dedupe\t%s\n' "$cost" >> "$OUT/dedupe_cost.tsv"   # every attempt is accounted for, failed ones too
  if [ "$rc" = 0 ] && extract "$OUT/dedupe_raw.json" "$OUT/clusters_raw.md"; then dok=1; fi
  ledger dedupe "$MODEL" 1 "$dok" "$cost" "$pk" "$([ "$cost" = '?' ] && echo 1 || echo 0)"   # before any failure exit
  [ "$rc" = 0 ] || { echo "$PROG: dedupe call failed (rc=$rc)" >&2; head -c 300 "$OUT/dedupe_raw.err" >&2; exit 3; }
  [ "$dok" = 1 ] || { echo "$PROG: dedupe output unusable" >&2; exit 3; }
  # Parse the final members field, not arbitrary pipes or n= in the defect text.
  # Only a terminal, unquoted marker is metadata; quoted occurrences stay literal.
  # Keep clusters with missing/empty member lists too, with a count of zero.
  perl -e '
    use strict; use warnings;
    open my $seen, ">", shift @ARGV or die "members_seen: $!";
    # n counts DISTINCT, known finding ids only: a repeated or invented id is not support
    my %valid;
    open my $vin, "<", shift @ARGV or die "dedupe_in: $!";
    while (my $vl = <$vin>) { chomp $vl; my ($vid) = split / /, $vl, 2; $valid{$vid} = 1 if defined $vid && length $vid; }
    close $vin;
    while (<>) {
      chomp; s/\r$//;
      next unless /^[^A-Za-z0-9]*(C[0-9]+)\s*\|\s*([^|]+?)\s*\|\s*(.*?)\s*$/;
      my ($id, $severity, $body) = ($1, $2, $3);
      my $flag = $body =~ s/\s+\[no-input\]$// ? " [no-input]" : "";
      my $members = $body =~ s/\s*\|\s*members:\s*([^|]*)$// ? $1 : "";
      my @ids = grep { length } map { s/^\s+|\s+$//g; $_ } split /,/, $members;
      print $seen "$_\n" for @ids;
      my %once; my $count = grep { $valid{$_} && !$once{$_}++ } @ids;
      print "$count\t$id\t$id | $severity | n=$count | $body | members: ", join(",", @ids), "$flag\n";
    }
    close $seen or die "members_seen: $!";
  ' "$OUT/members_seen.txt" "$OUT/dedupe_in.txt" "$OUT/clusters_raw.md" > "$OUT/clusters.tsv"
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
  printf 'dedupe: %d clusters, %d findings omitted by the model and re-added, %d duplicated ids, %d unknown ids, cost $%s\n' \
    "$(grep -c 'members:' "$OUT/clusters.md" || true)" "$(wc -l < "$OUT/members_missing.txt" | tr -d ' ')" "$(wc -l < "$OUT/members_dup.txt" | tr -d ' ')" "$(wc -l < "$OUT/members_unknown.txt" | tr -d ' ')" "$cost"
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
