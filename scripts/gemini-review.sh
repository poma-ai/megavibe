#!/usr/bin/env bash
# gemini-review.sh — a Gemini review/summary call that actually comes back.
#
# Why not the MCP tool or `gemini -p`:
#   Gemini 3.x Flash thinks by default, and the Gemini CLI (which gemini-mcp
#   wraps) hardcodes the thinking mode with no setting to lower it. Measured
#   2026-09-06 on gemini-3.8-flash with a 9K-token review prompt: default
#   thinking spent 15,362 thought tokens and returned 318 tokens of text before
#   hitting an 8,000 cap (39,493 thoughts at a 32,000 cap — still truncated);
#   `thinkingLevel: low` returned the complete review in 6 seconds. The CLI's
#   multi-minute "hangs" in the watcher and /rehydrate are the same effect.
#   This script calls the API directly, so it can set the level.
#
# Usage:
#   scripts/gemini-review.sh [--as-reviewer] [--fallback] [--pro]
#                            [--level low|medium|high]
#                            [--max N] [--out FILE] --prompt "text" FILE...
#   scripts/gemini-review.sh ... --prompt-file PROMPT.md FILE...
#
# Files are appended to the prompt as "===== path =====" blocks. Output: the
# model's text on stdout; with --out, the text goes there and the raw JSON to
# FILE.raw.json for audit (without --out nothing is left behind).
# --as-reviewer marks this call as one of non-negotiable 4's reviews, and is the
# ONLY mode MEGAVIBE_REVIEWERS gates: without it this is just megavibe's general
# Gemini path (/rehydrate, summaries, large context), which no reviewer setting
# should be able to switch off.
#
# --fallback says this review is standing in for codex, which is in the set and
# failed today (quota, outage, timeout). It is accepted only when reviewers.sh
# says gemini is the fallback — the default set, with codex in it and gemini
# not. It is NOT a way past a pin: `MEGAVIBE_REVIEWERS="reviewer codex"` means
# gemini never reviews, and --fallback still exits 4 there. Use it only after
# codex actually failed; a fallback review run alongside a successful codex
# review is just the reviewer the measurements moved out of the set.
#
# Exit 0 on a complete answer, 3 if the answer was cut off (MAX_TOKENS), 4 if
# asked to review while gemini is off in MEGAVIBE_REVIEWERS (or asked for general
# work while codex is usable — see below), 5 if a cost rail refused the call,
# 1 on API/network error. Never retries more than once (megavibe rule).
#
# GENERAL (non-review) calls are the ALTERNATIVE for machines without Codex, and
# they are metered. Every call is recorded in ~/.megavibe/gemini-usage.jsonl
# (tokens and an estimated dollar cost; the estimate is deliberately on the high
# side). Without --as-reviewer:
#   - codex usable (`reviewers.sh codex-ok`), unknown, or unaskable -> exit 4, no
#     spend. Only MEGAVIBE_GEMINI_DIGEST=1 overrides (any other value does not).
#   - never Pro, never --auto: the model is MEGAVIBE_GEMINI_DIGEST_MODEL (default
#     gemini-3.1-flash-lite, must be a flash-lite) at thinkingLevel low; a caller's
#     --model/--level is ignored.
#   - output capped at MEGAVIBE_GEMINI_MAX_OUT tokens (default 12000, thinking
#     counts), input at MEGAVIBE_GEMINI_MAX_INPUT_KB (default 300), calls per
#     local day at MEGAVIBE_GEMINI_DAILY_CALLS (default 40), total spend per local
#     day at MEGAVIBE_GEMINI_DAILY_USD (default 1.00; 0 switches general use off;
#     an unreadable value counts as 0). The context watcher (MEGAVIBE_GEMINI_CALLER
#     =watcher) may use 60% of the day's calls and dollars, so /rehydrate keeps a
#     share. Over a cap: exit 5, so the caller falls through to the Claude subagent.
#   - each call is RESERVED in the ledger, under a lock, at its worst-case cost
#     before it is sent, then settled to the real cost from the response. An
#     unreadable or unwritable ledger refuses (exit 5): it cannot enforce a cap.
# Reviews (--as-reviewer) are never refused by these rails — a skipped review is
# worse than a spent cent — but they are recorded and count toward the day's
# spend. MEGAVIBE_GEMINI_PRICES="flash_in flash_out pro_in pro_out" ($ per 1M
# tokens, default "0.30 2.50 2.00 12.00") tunes the estimate.
#   scripts/gemini-review.sh --budget     # today's usage against the caps
#
# Model: gemini-flash-latest by default (≈$0.04 per 50K-token review on the
# paid key). --pro = gemini-3.1-pro-preview at thinkingLevel medium (≈$0.15);
# use it for any reviewer-role call (--as-reviewer); non-review usage stays on flash.
# Needs a key from a BILLED project in $GEMINI_API_KEY — the free tier is
# 20 requests/day and trains on prompts.

set -euo pipefail
# The assembled request holds the caller's files or transcript slice: private from the start.
umask 077

# Measured 2026-09-10: default is now the pinned gemini-3.1-flash-lite (cheapest
# non-deprecated tier). NOT the `gemini-flash-lite-latest` alias — it answered with
# no text part at all in testing, so it is unreliable for scripted use; pinned
# lite versions (3.1, 3.5) both answer correctly with thinkingLevel.
# gemini-flash-latest still resolves to gemini-3.8-flash if you want the bigger model.
# (the current Pro line; answered live that day). Both accept thinkingConfig.thinkingLevel.
# If Google moves the alias to a model that rejects the field, the API returns 400 and
# this script exits 1 with the message — re-check `models?key=` and adjust MODEL/--pro.
MODEL="gemini-3.1-flash-lite"; LEVEL="low"; MAX=16000; OUT=""; PROMPT=""; PROMPT_FILE=""
# --auto: review on the cheap model, escalate to Pro only when warranted.
#
# Self-reported confidence is deliberately NOT the only gate. A model that misses
# a blocker does not know it missed it — confidence tracks fluency, not accuracy,
# so "no findings, confidence 0.95" is exactly the failure this is meant to catch.
# Escalation therefore fires on ANY of four signals, three of which do not depend
# on the model's own introspection:
#   1. it reported a blocker/major finding      (its findings, not its confidence)
#   2. self-reported confidence below threshold (weakest signal; a tiebreak only)
#   3. it reported partial coverage, or emitted no parseable verdict at all
#   4. the INPUT is high-stakes by deterministic file match — fires even when the
#      cheap model says everything is fine
AS_REVIEWER=""; FALLBACK=""; SHOW_BUDGET=""
AUTO=""; MIN_CONF="0.75"; PRO_MODEL="gemini-3.1-pro-preview"; PRO_LEVEL="medium"
FILES=()
need(){ [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --as-reviewer) AS_REVIEWER=1; shift ;;
    --fallback)    FALLBACK=1; shift ;;
    --pro)         MODEL="$PRO_MODEL"; LEVEL="$PRO_LEVEL"; shift ;;
    --auto)        AUTO=1; shift ;;
    --min-conf)    need "$@"; MIN_CONF="$2"; shift 2 ;;
    --model)       need "$@"; MODEL="$2"; shift 2 ;;
    --level)       need "$@"; LEVEL="$2"; shift 2 ;;
    --max)         need "$@"; MAX="$2"; shift 2 ;;
    --out)         need "$@"; OUT="$2"; shift 2 ;;
    --prompt)      need "$@"; PROMPT="$2"; shift 2 ;;
    --prompt-file) need "$@"; PROMPT_FILE="$2"; shift 2 ;;
    --budget)      SHOW_BUDGET=1; shift ;;
    -h|--help)     awk '/^set -euo/{exit} NR>1{print}' "$0"; exit 0 ;;
    --)            shift; FILES+=("$@"); break ;;
    -*)            echo "unknown arg: $1" >&2; exit 2 ;;
    *)             FILES+=("$1"); shift ;;
  esac
done

# ---- cost rails -----------------------------------------------------------
_trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }
_isnum() { case "$1" in ''|.|*.|*[!0-9.]*|*.*.*) return 1 ;; esac; }
_pos() { _isnum "$1" && awk -v v="$1" 'BEGIN{exit !(v+0 > 0)}'; }
# Caps on SPENDING (calls, dollars) fail CLOSED: a value that cannot be read means 0
# (general use off), never the default — a typo must not buy more than was asked.
_cap_spend() { local v; v=$(_trim "${1:-}")
  if [ -z "$v" ]; then printf '%s' "$2"
  elif _isnum "$v"; then printf '%s' "$v"
  else echo "warning: unusable cap value '$v' — treating it as 0 (general gemini use off)" >&2; printf '0'; fi; }
# Size limits fall back to the default (they only ever bound a call).
_cap_size() { local v; v=$(_trim "${1:-}"); if _pos "$v"; then printf '%s' "$v"; else printf '%s' "$2"; fi; }
CAP_CALLS=$(_cap_spend "${MEGAVIBE_GEMINI_DAILY_CALLS:-}" 40)
CAP_USD=$(_cap_spend "${MEGAVIBE_GEMINI_DAILY_USD:-}" 1.00)
CAP_KB=$(_cap_size "${MEGAVIBE_GEMINI_MAX_INPUT_KB:-}" 300)
CAP_OUT=$(_cap_size "${MEGAVIBE_GEMINI_MAX_OUT:-}" 12000); CAP_OUT=${CAP_OUT%%.*}; [ "${CAP_OUT:-0}" -ge 1 ] 2>/dev/null || CAP_OUT=12000
PRICES="${MEGAVIBE_GEMINI_PRICES:-0.30 2.50 2.00 12.00}"
read -r _p1 _p2 _p3 _p4 _px <<< "$PRICES"
if [ -n "$_px" ] || ! { _isnum "${_p1:-}" && _isnum "${_p2:-}" && _isnum "${_p3:-}" && _isnum "${_p4:-}"; }; then
  echo "warning: unusable MEGAVIBE_GEMINI_PRICES — using the defaults" >&2; PRICES="0.30 2.50 2.00 12.00"
fi
CALLER=$(printf '%s' "${MEGAVIBE_GEMINI_CALLER:-interactive}" | tr -cd 'a-z-' | cut -c1-20); CALLER=${CALLER:-interactive}
WATCHER_SHARE=0.6          # the watcher may use at most this share of the day's caps; /rehydrate keeps the rest
LEDGER="${MEGAVIBE_GEMINI_LEDGER:-${HOME:-/tmp}/.megavibe/gemini-usage.jsonl}"
HAVE_LOCK=""
TODAY=$(date +%Y-%m-%d)

# A kernel lock, not a lock file: bash opens the file on fd 9 and a short perl process
# flock()s THAT open file description, which stays locked after perl exits for as long
# as fd 9 is open — so it is released when this process ends, however it ends (kill -9
# included). A lock file or directory needs stale-lock recovery, and that recovery was
# itself racy. No perl, or no lock within 10s, means the caller refuses (exit 5).
_lock() {
  mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || return 1
  command -v perl >/dev/null 2>&1 || return 1
  exec 9>>"$LEDGER.lock" || return 1
  perl -MFcntl=:flock -e 'open(my $f, "+<&=", 9) or exit 2; $SIG{ALRM} = sub { exit 3 }; alarm 10; flock($f, LOCK_EX) or exit 1; exit 0' \
    || { exec 9>&-; return 1; }
  HAVE_LOCK=1
}
_unlock() { [ -z "$HAVE_LOCK" ] || { exec 9>&-; HAVE_LOCK=""; }; }

# "digest-calls usd reviews watcher-calls watcher-usd" for today, or ERR. Rows that are
# not JSON objects are skipped one by one; an unreadable ledger is ERR (callers
# that spend must refuse on it — a ledger nobody can read cannot enforce a cap).
_today() {
  [ -e "$LEDGER" ] || { echo "0 0 0 0 0"; return; }
  [ -f "$LEDGER" ] && [ -r "$LEDGER" ] || { echo ERR; return; }
  jq -Rnr --arg d "$TODAY" '[inputs | fromjson? | select(type == "object" and .day == $d)]
    | def usd: ((.usd | tonumber? // 0) | if (. == . and . < 1e9 and . > -1e9) then . else 0 end);
      [ (map(select(.kind == "digest")) | length),
        (map(usd) | add // 0 | if . < 0 then 0 else . end),
        (map(select(.kind == "review")) | length),
        (map(select(.kind == "digest" and .caller == "watcher")) | length),
        (map(select(.caller == "watcher") | usd) | add // 0 | if . < 0 then 0 else . end) ]
    | map(tostring) | join(" ")' < "$LEDGER" 2>/dev/null || echo ERR
}

if [ -n "$SHOW_BUDGET" ]; then
  _st=$(_today)
  if [ "$_st" = ERR ]; then echo "gemini ledger unreadable: $LEDGER"; exit 1; fi
  read -r _c _u _r _wc _wu <<< "$_st"
  _u=$(awk -v v="$_u" 'BEGIN{printf "%.4f", v}'); _wu=$(awk -v v="$_wu" 'BEGIN{printf "%.4f", v}')
  printf 'gemini today (%s): %s general calls (cap %s), %s reviews, ~$%s of $%s (watcher: %s calls, ~$%s, share %s)\nledger: %s\n' \
    "$TODAY" "$_c" "$CAP_CALLS" "$_r" "$_u" "$CAP_USD" "$_wc" "$_wu" "$WATCHER_SHARE" "$LEDGER"
  exit 0
fi

# One ledger row, written with a single write so concurrent writers cannot interleave.
# kind: digest (a reserved general call) | adjust (settles a reservation) | review.
_row() {  # kind model in out usd
  local row
  row=$(jq -nc --arg day "$TODAY" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg kind "$1" --arg model "$2" \
    --arg caller "$CALLER" --argjson in "$3" --argjson out "$4" --argjson usd "$5" \
    '{day:$day, ts:$ts, kind:$kind, model:$model, caller:$caller, in:$in, out:$out, usd:$usd}') || return 1
  { printf '\n%s\n' "$row" >> "$LEDGER"; } 2>/dev/null
}

# A GENERAL call is reserved BEFORE it is sent: under the lock, check the day's caps and
# append a row at the worst-case cost, so concurrent calls cannot all pass the same
# check and a call that fails after sending still counts. settle() later replaces the
# estimate with the real cost when the response carries usage.
RESV=0
reserve() {  # $1 = 1 to enforce the caps (every outbound attempt, the transient retry included)
  local in_tok est st c u r wc wu cc cu pi po
  in_tok=$(( ($(wc -c < "$REQ.txt") + 2) / 3 ))
  read -r pi po _ _ <<< "$PRICES"
  est=$(awk -v i="$in_tok" -v o="$MAX" -v pi="$pi" -v po="$po" 'BEGIN{x=(i*pi + o*po)/1000000; x=int(x*10000 + 0.9999)/10000; if (x < 0.0001) x=0.0001; printf "%.4f", x}')
  if [ "$1" = 1 ]; then
    awk -v c="$CAP_CALLS" -v d="$CAP_USD" 'BEGIN{exit !(c+0 <= 0 || d+0 <= 0)}' \
      && { echo "skip: general gemini use is switched off (a daily cap is 0 or unreadable)" >&2; exit 5; }
  fi
  _lock || { echo "skip: could not lock the gemini ledger ($LEDGER) — falling through" >&2; exit 5; }
  TODAY=$(date +%Y-%m-%d)      # read AFTER the lock (it may have waited past midnight); settle() reuses it
  if [ "$1" = 1 ]; then
    st=$(_today)
    [ "$st" != ERR ] || { _unlock; echo "skip: the gemini ledger is unreadable ($LEDGER) — cannot enforce the caps, falling through" >&2; exit 5; }
    read -r c u r wc wu <<< "$st"
    # The day's caps always apply; the watcher is held to a SHARE of them on top of that.
    if awk -v n="$c" -v c="$CAP_CALLS" 'BEGIN{exit !(n+0 >= c+0)}'; then
      _unlock; echo "skip: $c general gemini calls today reached the cap of $CAP_CALLS (MEGAVIBE_GEMINI_DAILY_CALLS) — falling through" >&2; exit 5
    fi
    if awk -v u="$u" -v e="$est" -v c="$CAP_USD" 'BEGIN{exit !(u+e > c+0)}'; then
      _unlock; echo "skip: gemini spend today ~\$$u plus this call's ~\$$est would pass the \$$CAP_USD cap (MEGAVIBE_GEMINI_DAILY_USD) — falling through" >&2; exit 5
    fi
    if [ "$CALLER" = watcher ]; then
      cc=$(awk -v v="$CAP_CALLS" -v s="$WATCHER_SHARE" 'BEGIN{printf "%d", v*s}')
      cu=$(awk -v v="$CAP_USD" -v s="$WATCHER_SHARE" 'BEGIN{printf "%.4f", v*s}')
      if awk -v n="$wc" -v c="$cc" 'BEGIN{exit !(n+0 >= c+0)}' || awk -v u="$wu" -v e="$est" -v c="$cu" 'BEGIN{exit !(u+e > c+0)}'; then
        _unlock; echo "skip: the context watcher has used its share of today's gemini caps ($wc calls / ~\$$wu of $cc / \$$cu) — falling through" >&2; exit 5
      fi
    fi
  fi
  _row digest "$MODEL" "$in_tok" "$MAX" "$est" \
    || { _unlock; echo "skip: the gemini ledger is not writable ($LEDGER) — falling through" >&2; exit 5; }
  _unlock; RESV="$est"
}

# Record what a response really cost. Called on EVERY response, before it is
# validated: a blocked or empty answer is still billed.
settle() {  # $1 = response body
  local in out actual pi po rpi rpo
  in=$(printf '%s' "$1" | jq -r '.usageMetadata.promptTokenCount // empty' 2>/dev/null) || in=""   # not JSON: same as no usage
  if [ -z "$in" ]; then
    # No usage in the response. Only a JSON API ERROR is a confirmed unbilled failure
    # (Google does not charge for those): refund the dollar estimate, keep the CALL
    # counted, so a throttle or a bad key cannot burn the day's dollars. Anything
    # else — an empty or unparseable body, or an answer that simply carries no
    # metadata — might have been generated and billed, so the reservation stands.
    if [ "$KIND" = digest ] && printf '%s' "$1" | jq -e 'type == "object" and (.error | type == "object")' >/dev/null 2>&1 \
       && awk -v e="$RESV" 'BEGIN{exit !(e+0 > 0)}'; then
      _row adjust "$MODEL" 0 0 "-$RESV" || true; RESV=0
    fi
    return 0
  fi
  out=$(printf '%s' "$1" | jq -r '(.usageMetadata.candidatesTokenCount // 0) + (.usageMetadata.thoughtsTokenCount // 0)' 2>/dev/null) || return 0
  read -r pi po rpi rpo <<< "$PRICES"
  case "$MODEL" in *pro*) pi="$rpi"; po="$rpo" ;; esac
  actual=$(awk -v i="$in" -v o="$out" -v pi="$pi" -v po="$po" 'BEGIN{printf "%.4f", (i*pi + o*po)/1000000}')
  if [ "$KIND" = digest ]; then
    _row adjust "$MODEL" "$in" "$out" "$(awk -v a="$actual" -v e="$RESV" 'BEGIN{printf "%.4f", a - e}')" || true
    RESV="$actual"
  else
    _row review "$MODEL" "$in" "$out" "$actual" || true
  fi
}

# Asked to REVIEW, and this reviewer is switched off? Refuse before spending
# anything. The gate lives here, not only in the protocol text, so an agent that
# calls a disabled reviewer out of habit gets a free no-op instead of a paid
# review the user did not want.
#
# Only under --as-reviewer. This script is also megavibe's general gemini path —
# /rehydrate and /prune-context and every large-context task come through here —
# and MEGAVIBE_REVIEWERS is a statement about reviewing, not about the backend.
# Gating unconditionally would have stripped context recovery of its backend for
# anyone who switched one reviewer off.
_SRC="${BASH_SOURCE[0]}"
while [ -h "$_SRC" ]; do   # resolve symlinks: the helper scripts live next to the REAL file
  _D=$(cd -- "$(dirname -- "$_SRC")" && pwd); _SRC=$(readlink "$_SRC")
  case "$_SRC" in /*) ;; *) _SRC="$_D/$_SRC" ;; esac
done
_RVDIR=$(cd -- "$(dirname -- "$_SRC")" && pwd)
if [ -n "$AS_REVIEWER" ] && [ -f "$_RVDIR/reviewers.sh" ]; then
  _rv_rc=0; bash "$_RVDIR/reviewers.sh" enabled gemini >/dev/null 2>&1 || _rv_rc=$?
  # Off in the set, but standing in for a codex that failed? Ask whether gemini
  # is the fallback here.
  #
  # Only status 1 means "no". Anything else — a crash, a missing file, a future
  # version with different codes — is the helper failing to answer, and an
  # unanswered question resolves to MORE review, exactly as the `enabled` gate
  # below does. Written as `if bash ...; then` this read every non-zero status
  # as a refusal, so one broken helper silenced the last reviewer standing.
  if [ "$_rv_rc" -eq 1 ] && [ -n "$FALLBACK" ]; then
    _fb_rc=0; bash "$_RVDIR/reviewers.sh" fallback gemini >/dev/null 2>&1 || _fb_rc=$?
    if [ "$_fb_rc" -ne 1 ]; then
      _rv_rc=0
      [ "$_fb_rc" -eq 0 ] \
        && echo "note: gemini is reviewing as the FALLBACK for codex" >&2 \
        || echo "note: could not confirm the fallback policy (reviewers.sh exit $_fb_rc) — reviewing anyway" >&2
    fi
  fi
  # ONLY 1 means "switched off". A helper that crashed, or one from a future
  # version with different exit codes, must not be able to silence a reviewer —
  # non-negotiable 4 fails open.
  if [ "$_rv_rc" -eq 1 ]; then
    echo "skip: gemini is not in MEGAVIBE_REVIEWERS ($(bash "$_RVDIR/reviewers.sh" list 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'))${FALLBACK:+ — and not the fallback here}" >&2
    exit 4
  fi
fi

KEY="${GEMINI_API_KEY:-}"
[ -n "$KEY" ] || { echo "error: GEMINI_API_KEY is not set (needs a key from a billed project)" >&2; exit 1; }
[ -n "$PROMPT" ] || [ -n "$PROMPT_FILE" ] || { echo "error: --prompt or --prompt-file is required" >&2; exit 2; }
command -v jq &>/dev/null || { echo "error: jq is required" >&2; exit 1; }
[ -n "$PROMPT_FILE" ] && PROMPT=$(cat -- "$PROMPT_FILE")
[ -n "$(printf '%s' "$PROMPT" | tr -d '[:space:]')" ] || { echo "error: the prompt is empty" >&2; exit 2; }
[ "${#FILES[@]}" -gt 0 ] || echo "note: no files given — sending the prompt alone" >&2

KIND="review"
if [ -z "$AS_REVIEWER" ]; then
  KIND="digest"
  # Alternative for machines WITHOUT codex. Only an answer of "unusable" (1) opens it;
  # usable (0), unknown (2, a wedged probe) and no helper at all all refuse — spending
  # is the wrong direction to fail open in. The override is exactly MEGAVIBE_GEMINI_DIGEST=1.
  if [ "${MEGAVIBE_GEMINI_DIGEST:-}" != 1 ]; then
    _cx=2; [ ! -f "$_RVDIR/reviewers.sh" ] || { _cx=0; bash "$_RVDIR/reviewers.sh" codex-ok >/dev/null 2>&1 || _cx=$?; }
    if [ "$_cx" -ne 1 ]; then
      echo "skip: codex is usable (or its state is unknown) here — gemini is the alternative only on machines without it (MEGAVIBE_GEMINI_DIGEST=1 overrides)" >&2
      exit 4
    fi
  fi
  # Flash-lite at low thinking and nothing else: the model comes from the owner's
  # config, never from a caller's --model (Pro, an ultra tier, a thinking-heavy flash).
  DM="${MEGAVIBE_GEMINI_DIGEST_MODEL:-gemini-3.1-flash-lite}"
  [[ "$DM" =~ ^gemini-[A-Za-z0-9._-]*flash-lite[A-Za-z0-9._-]*$ ]] || DM="gemini-3.1-flash-lite"
  [ "$MODEL" = "gemini-3.1-flash-lite" ] || echo "note: general calls use $DM only — ignoring the requested model" >&2
  MODEL="$DM"; LEVEL="low"
  [ -z "$AUTO" ] || { echo "note: --auto escalation is for reviews only — ignored" >&2; AUTO=""; }
  case "$MAX" in ''|*[!0-9]*) MAX="$CAP_OUT" ;; esac
  [ "$MAX" -ge 1 ] 2>/dev/null || MAX="$CAP_OUT"
  [ "$MAX" -le "$CAP_OUT" ] || MAX="$CAP_OUT"
fi

# Assemble the request in a temp file — a 1M-character body must not pass
# through argv. jq -Rs escapes the text exactly.
REQ=$(mktemp -t gemini-req)
if [ -n "$OUT" ]; then RAW="$OUT.raw.json"; KEEP_RAW=1; else RAW=$(mktemp -t gemini-raw); KEEP_RAW=""; fi
trap '_unlock; [ -n "$KEEP_RAW" ] || rm -f "$RAW"; rm -f "$REQ" "$REQ.txt"' EXIT
AUTO_SUFFIX=''
if [ -n "$AUTO" ]; then
  AUTO_SUFFIX=$(cat <<'SUF'

---
After your review, emit EXACTLY this line last, on its own, nothing after it:

<<<VERDICT severity=SEV confidence=CONF coverage=COV>>>

  SEV   = blocker | major | minor | none   (the most severe issue you actually found)
  CONF  = 0.00-1.00, how confident you are that you found everything that matters
  COV   = full | partial   ("partial" if anything stopped you reviewing properly:
          missing files, truncated input, code you could not follow, or a change
          whose consequences you cannot see from what was provided)

Be honest about partial coverage and about low confidence. A cheap model saying
"none / 1.00" on work it did not fully understand is worse than useless — an
honest "partial" costs one extra call, a false "full" ships a defect.
SUF
)
fi

{
  printf '%s\n' "$PROMPT"
  [ -n "$AUTO_SUFFIX" ] && printf '%s\n' "$AUTO_SUFFIX"
  for f in "${FILES[@]:-}"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] && [ -r "$f" ] || { echo "error: not a readable file: $f" >&2; exit 1; }
    printf '\n\n===== %s =====\n' "$f"; cat -- "$f"
  done
} > "$REQ.txt"
if [ "$KIND" = "digest" ]; then
  _kb=$(( ($(wc -c < "$REQ.txt") + 1023) / 1024 ))
  if awk -v k="$_kb" -v c="$CAP_KB" 'BEGIN{exit !(k+0 > c+0)}'; then
    echo "skip: input is ${_kb} KB, over the ${CAP_KB} KB cap for general gemini calls (MEGAVIBE_GEMINI_MAX_INPUT_KB) — falling through" >&2; exit 5
  fi
fi
build_req(){ jq -Rs --arg level "$1" --argjson max "$MAX" \
  '{contents:[{parts:[{text:.}]}], generationConfig:{maxOutputTokens:$max, temperature:0.2, thinkingConfig:{thinkingLevel:$level}}}' \
  < "$REQ.txt" > "$REQ"; }
build_req "$LEVEL"

call(){ curl -s --max-time 280 -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent" \
  -H "x-goog-api-key: $KEY" -H 'Content-Type: application/json' --data-binary @"$REQ"; }

[ "$KIND" != digest ] || reserve 1
BODY=$(call || true)
settle "$BODY"
# One retry only, and only for the transient shapes (empty body, 429, 5xx).
if [ -z "$BODY" ] || printf '%s' "$BODY" | jq -e '.error.code as $c | $c==429 or $c>=500' >/dev/null 2>&1; then
  sleep 5
  [ "$KIND" != digest ] || reserve 1     # the retry is a second outbound call: full checks, full count
  BODY=$(call || true)
  settle "$BODY"
fi
[ -n "$BODY" ] || { echo "error: no response from Gemini (network/throttle)" >&2; exit 1; }
printf '%s' "$BODY" > "$RAW"
printf '%s' "$BODY" | jq -e . >/dev/null 2>&1 || { echo "error: invalid response from Gemini (proxy page or truncated JSON) — raw kept at $RAW" >&2; KEEP_RAW=1; exit 1; }

if printf '%s' "$BODY" | jq -e '.error' >/dev/null 2>&1; then
  echo "error: $(printf '%s' "$BODY" | jq -r '.error.message' | cut -c1-300)" >&2; exit 1
fi
printf '%s' "$BODY" | jq -e '.candidates[0].content.parts' >/dev/null 2>&1 \
  || { echo "error: no answer in the response (blocked or empty) — $(printf '%s' "$BODY" | jq -c '.promptFeedback // .candidates[0].finishReason // empty' | cut -c1-200)" >&2; KEEP_RAW=1; exit 1; }
TEXT=$(printf '%s' "$BODY" | jq -r '[.candidates[0].content.parts[]? | select(.thought != true) | .text // empty] | join("")')
FINISH=$(printf '%s' "$BODY" | jq -r '.candidates[0].finishReason // "?"')
USAGE=$(printf '%s' "$BODY" | jq -r '.usageMetadata | "in=\(.promptTokenCount // "?") out=\(.candidatesTokenCount // "?") thoughts=\(.thoughtsTokenCount // 0)"')
MV=$(printf '%s' "$BODY" | jq -r '.modelVersion // "?"')

if [ -n "$AUTO" ]; then
  V=$(printf '%s' "$TEXT" | grep -oE '<<<VERDICT[^>]*>>>' | tail -1)
  SEV=$(printf '%s' "$V" | grep -oE 'severity=[a-z]+' | cut -d= -f2)
  CONF=$(printf '%s' "$V" | grep -oE 'confidence=[0-9.]+' | cut -d= -f2)
  COV=$(printf '%s' "$V" | grep -oE 'coverage=[a-z]+' | cut -d= -f2)

  # (4) Deterministic high-stakes match on the INPUT — independent of the model.
  # These are the paths where a missed defect is expensive, so they always get
  # the stronger reviewer regardless of how confident the cheap one sounded.
  STAKES=""
  for f in "${FILES[@]:-}"; do
    case "$f" in
      *auth*|*Auth*|*credential*|*secret*|*token*|*passwd*|*password*|*crypto*|*key*.py|\
      *payment*|*billing*|*invoice*|*charge*|*refund*|\
      *migration*|*migrate*|*schema*|*delete*|*destroy*|*drop*|*purge*|\
      *CLAUDE.md|*README*.md|*SKILL.md|*.github/workflows/*)
        STAKES="$f"; break ;;
    esac
  done

  WHY=""
  case "$SEV" in blocker|major) WHY="found a $SEV finding" ;; esac
  [ -z "$WHY" ] && [ -z "$V" ] && WHY="emitted no parseable verdict"
  [ -z "$WHY" ] && [ "$COV" != "full" ] && WHY="reported coverage=$COV"
  [ -z "$WHY" ] && [ -n "$CONF" ] && awk -v c="$CONF" -v m="$MIN_CONF" 'BEGIN{exit !(c<m)}' \
    && WHY="confidence $CONF < $MIN_CONF"
  [ -z "$WHY" ] && [ -n "$STAKES" ] && WHY="high-stakes input ($STAKES)"

  if [ -n "$WHY" ]; then
    echo "[gemini-review: escalating to $PRO_MODEL — $WHY]" >&2
    CHEAP_TEXT="$TEXT"; CHEAP_MV="$MV"; CHEAP_USAGE="$USAGE"
    MODEL="$PRO_MODEL"; LEVEL="$PRO_LEVEL"; build_req "$PRO_LEVEL"
    BODY=$(call || true)
    settle "$BODY"
    if printf '%s' "$BODY" | jq -e '.candidates[0].content.parts' >/dev/null 2>&1; then
      TEXT=$(printf '%s' "$BODY" | jq -r '[.candidates[0].content.parts[]? | select(.thought != true) | .text // empty] | join("")')
      FINISH=$(printf '%s' "$BODY" | jq -r '.candidates[0].finishReason // "?"')
      USAGE=$(printf '%s' "$BODY" | jq -r '.usageMetadata | "in=\(.promptTokenCount // "?") out=\(.candidatesTokenCount // "?") thoughts=\(.thoughtsTokenCount // 0)"')
      MV=$(printf '%s' "$BODY" | jq -r '.modelVersion // "?"')
      USAGE="$USAGE (escalated from $CHEAP_MV: $CHEAP_USAGE)"
    else
      # Pro failed: keep the cheap review rather than returning nothing, and say so.
      echo "warning: escalation call failed — returning the $CHEAP_MV review" >&2
      TEXT="$CHEAP_TEXT"
    fi
  else
    echo "[gemini-review: no escalation — severity=$SEV confidence=$CONF coverage=$COV]" >&2
  fi
fi

if [ -n "$OUT" ]; then printf '%s\n' "$TEXT" > "$OUT"; fi
printf '%s\n' "$TEXT"
echo "" >&2; echo "[gemini-review: model=$MV level=$LEVEL finish=$FINISH $USAGE${KEEP_RAW:+ raw=$RAW}]" >&2
[ "$FINISH" = "STOP" ] || { echo "warning: answer was cut off ($FINISH) — raise --max or lower --level" >&2; exit 3; }
