#!/usr/bin/env bash
# codex-progress.sh — what is a running (or finished) Codex job actually doing?
#
# Codex writes every event of a `codex exec` run (codex-review.sh, second-opinion.sh,
# amass codex workers, hand-started jobs) to
#   ${CODEX_HOME:-~/.codex}/sessions/YYYY/MM/DD/rollout-<local time>-<uuid>.jsonl
# and the file grows with each event while the job lives. That is the real
# heartbeat: the Bash task's .output file is EMPTY when stdout is redirected, and
# `-o FILE` holds only the final message, so a long job looks silent otherwise.
#
# Usage: codex-progress.sh [--latest | --cwd DIR | --file F] [--last N] [--brief] [--days D]
#   --latest   newest rollout (default)
#   --cwd DIR  newest rollout whose first line records a working directory containing DIR
#              (the -C directory; a codex-review-scratch.* directory for --as-reviewer runs)
#   --file F   that rollout
#   --last N   how many recent assistant messages and commands to print (default 6)
#   --brief    one line: bytes, age, events, last assistant message (for a Monitor loop;
#              compute the byte delta in the loop: +0 for two beats means hung)
#   --days D   how many day directories back to search (default 2)
# Read-only. Reads the head line and a bounded tail of the file, so it is safe on large
# rollouts. Exit 0 found, 1 no rollout, 2 usage/dependency.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "codex-progress: jq is required" >&2; exit 2; }

mode=latest; cwd=; file=; last=6; brief=0; days=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest) mode=latest ;;
    --cwd) mode=cwd; cwd="${2:?--cwd needs a directory}"; shift ;;
    --file) mode=file; file="${2:?--file needs a path}"; shift ;;
    --last) last="${2:?--last needs a number}"; shift ;;
    --days) days="${2:?--days needs a number}"; shift ;;
    --brief) brief=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "codex-progress: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$last" =~ ^[0-9]+$ && "$days" =~ ^[0-9]+$ ]] || { echo "codex-progress: --last and --days take a number" >&2; exit 2; }

home="${CODEX_HOME:-$HOME/.codex}/sessions"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
size()  { wc -c <"$1" | tr -d ' '; }

head_cwd() { head -n 1 "$1" 2>/dev/null | head -c 200000 | jq -r '(.payload // .) | .cwd // ""' 2>/dev/null || true; }
head_model() { head -n 30 "$1" 2>/dev/null | head -c 400000 | jq -r 'select(.type == "turn_context") | .payload.model // empty' 2>/dev/null | head -n 1 || true; }

if [[ $mode == file ]]; then
  [[ -f "$file" ]] || { echo "codex-progress: no such file: $file" >&2; exit 1; }
else
  cands=()
  for ((i = 0; i < days; i++)); do
    d=$(date -v-"${i}"d +%Y/%m/%d 2>/dev/null || date -d "-${i} day" +%Y/%m/%d)
    [[ -d "$home/$d" ]] || continue
    while IFS= read -r f; do cands+=("$f"); done < <(ls -t "$home/$d"/rollout-*.jsonl 2>/dev/null | head -40)
  done
  file=
  for f in ${cands[@]+"${cands[@]}"}; do
    if [[ $mode == cwd ]]; then
      [[ "$(head_cwd "$f")" == *"$cwd"* ]] || continue
    fi
    if [[ -z $file || $(mtime "$f") -gt $(mtime "$file") ]]; then file=$f; fi
  done
  [[ -n $file ]] || { echo "codex-progress: no matching rollout under $home (last $days day(s))" >&2; exit 1; }
fi

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
  printf 'rollout %s: %s bytes, idle %ss, %s events | last: %s\n' "$(basename "$file")" "$bytes" "$age" "$events" "${lastmsg:-(no assistant message in the tail)}"
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
