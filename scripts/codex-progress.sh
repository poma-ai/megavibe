#!/usr/bin/env bash
# codex-progress.sh — what is a running (or finished) Codex job actually doing?
#
# Codex writes every event of a `codex exec` run (codex-review.sh, second-opinion.sh,
# a hand-started job) to
#   ${CODEX_HOME:-~/.codex}/sessions/YYYY/MM/DD/rollout-<local time>-<uuid>.jsonl
# and the file grows with each event while the job lives. That is the real progress
# log: the Bash task's .output file is EMPTY when stdout is redirected, and `-o FILE`
# holds only the final message. (amass's Codex workers run --ephemeral and write no
# rollout; a stdout log and an rc file stay the right evidence of a job's start-up
# failure and exit status.)
#
# Usage: codex-progress.sh [--latest | --cwd DIR | --file F | --path] [--since EPOCH]
#                          [--last N] [--brief] [--days D]
#   --latest   newest rollout (default)
#   --cwd DIR  rollouts whose first line records a working directory EQUAL to DIR
#              (a pattern with * is matched as a glob, e.g. '*/codex-review-scratch.*');
#              the newest unless --path
#   --file F   that rollout
#   --path     print only the path of THE matching rollout, so a caller can pin it;
#              exit 3 and say so when several match (never picks one silently),
#              exit 1 when none does yet
#   --since E  only rollouts whose session started at or after epoch E (a job's start)
#   --last N   how many recent assistant messages and commands to print (default 6)
#   --brief    one line: size, idle seconds, events, last assistant message
#   --days D   how many day directories back to search (default 2)
# An unchanged size is a reason to look, not proof of a hang: a model can reason for
# minutes without writing an event (measured gaps of 86 s and 264 s). Check the idle
# time and that the process is alive before stopping a job.
# Read-only. Reads the head line and a bounded tail of the file. Exit 0 found, 1 no
# rollout, 2 usage/dependency, 3 ambiguous.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "codex-progress: jq is required" >&2; exit 2; }

mode=latest; cwd=; file=; last=6; brief=0; days=2; want_path=0; since=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest) mode=latest ;;
    --cwd) mode=cwd; cwd="${2:?--cwd needs a directory}"; shift ;;
    --file) mode=file; file="${2:?--file needs a path}"; shift ;;
    --path) want_path=1 ;;
    --since) since="${2:?--since needs an epoch}"; shift ;;
    --last) last="${2:?--last needs a number}"; shift ;;
    --days) days="${2:?--days needs a number}"; shift ;;
    --brief) brief=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "codex-progress: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$last" =~ ^[0-9]+$ && "$days" =~ ^[0-9]+$ && "$since" =~ ^[0-9]+$ ]] || { echo "codex-progress: --last, --days and --since take a number" >&2; exit 2; }
[[ $days -ge 1 ]] || { echo "codex-progress: --days must be at least 1" >&2; exit 2; }

home="${CODEX_HOME:-$HOME/.codex}/sessions"

# stat flavours differ (BSD -f, GNU -c, and GNU -f prints filesystem info): probe each
# separately and keep only a plain number.
mtime() {
  local v
  v=$(stat -f %m "$1" 2>/dev/null) && [[ "$v" =~ ^[0-9]+$ ]] && { echo "$v"; return; }
  v=$(stat -c %Y "$1" 2>/dev/null) && [[ "$v" =~ ^[0-9]+$ ]] && { echo "$v"; return; }
  echo 0
}
size() { wc -c <"$1" | tr -d ' '; }

first_line() { head -n 1 "$1" 2>/dev/null | head -c 400000; }
head_cwd() { first_line "$1" | jq -r '(.payload // .) | .cwd // ""' 2>/dev/null || true; }
head_start() { first_line "$1" | jq -r '(.payload // .) | .timestamp // empty | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null || echo 0; }
head_model() { head -n 30 "$1" 2>/dev/null | head -c 400000 | jq -r 'select(.type == "turn_context") | .payload.model // empty' 2>/dev/null | head -n 1 || true; }

cwd_ok() { # rollout cwd matches the selector
  local c; c=$(head_cwd "$1")
  if [[ "$cwd" == *'*'* ]]; then [[ "$c" == $cwd ]]; else [[ "$c" == "$cwd" ]]; fi
}

if [[ $mode == file ]]; then
  [[ -f "$file" ]] || { echo "codex-progress: no such file: $file" >&2; exit 1; }
else
  matches=()
  for ((i = 0; i < days; i++)); do
    d=$(date -v-"${i}"d +%Y/%m/%d 2>/dev/null || date -d "-${i} day" +%Y/%m/%d)
    [[ -d "$home/$d" ]] || continue
    # every rollout of the day, newest first: the cwd/since filter runs BEFORE any limit
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      if [[ $since -gt 0 ]]; then
        # an already-finished older job cannot match: skip files last written before the start
        [[ $(mtime "$f") -ge $since ]] || continue
        s=$(head_start "$f"); [[ "$s" =~ ^[0-9]+$ && $s -ge $((since - 2)) ]] || continue
      fi
      [[ $mode != cwd ]] || cwd_ok "$f" || continue
      matches+=("$f")
    done < <(ls -t "$home/$d"/rollout-*.jsonl 2>/dev/null)
  done
  [[ ${#matches[@]} -gt 0 ]] || { echo "codex-progress: no matching rollout yet under $home (last $days day(s))" >&2; exit 1; }
  if [[ $want_path -eq 1 && ${#matches[@]} -gt 1 ]]; then
    echo "codex-progress: ambiguous, ${#matches[@]} rollouts match; pin one with --file (newest first):" >&2
    printf '  %s\n' "${matches[@]}" >&2
    exit 3
  fi
  file=${matches[0]}
  for f in "${matches[@]}"; do [[ $(mtime "$f") -gt $(mtime "$file") ]] && file=$f; done
fi

if [[ $want_path -eq 1 ]]; then printf '%s\n' "$file"; exit 0; fi

bytes=$(size "$file")
age=$(( $(date +%s) - $(mtime "$file") ))
events=$(wc -l <"$file" | tr -d ' ')

# Bounded tail: the last 6 MB, minus the first (possibly partial) line. fromjson? skips junk.
tail_events() {
  tail -c 6000000 "$file" | sed '1d' | jq -R 'fromjson? | select(.type == "response_item") | .payload' 2>/dev/null || true
}

msgs=$(tail_events | jq -r 'select(.type == "message" and .role == "assistant")
  | [.content[]? | select(.type == "output_text") | .text] | join(" ") | gsub("\\s+"; " ")
  | select(length > 0)' 2>/dev/null | tail -n "$last" || true)
cmds=$(tail_events | jq -r 'select(.type == "function_call" or .type == "local_shell_call" or .type == "custom_tool_call")
  | (.name // "shell") + ": " + ((.arguments // .input // (.action.command // "" | tostring)) | tostring | gsub("\\s+"; " "))' 2>/dev/null \
  | tail -n "$last" || true)

if [[ $brief -eq 1 ]]; then
  lastmsg=$(printf '%s\n' "$msgs" | tail -n 1 | cut -c1-200)
  printf 'idle %ss, %s bytes, %s events | last: %s\n' "$age" "$bytes" "$events" "${lastmsg:-(no assistant message in the tail)}"
  exit 0
fi

echo "rollout: $file"
echo "cwd:     $(head_cwd "$file")"
echo "model:   $(head_model "$file")"
echo "size:    $bytes bytes, $events events, last write ${age}s ago"
echo "--- last $last assistant messages (what Codex says) ---"
printf '%s\n' "$msgs" | cut -c1-600
echo "--- last $last commands (what Codex runs) ---"
printf '%s\n' "$cmds" | cut -c1-300
