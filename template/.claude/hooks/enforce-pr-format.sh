#!/bin/bash
# Megavibe — enforce the PR description format on GitHub PR create/edit via gh.
# Triggered by: PreToolUse (Bash)
# Exit 2 = block the command; Exit 0 = allow; Exit 1 = "hook error" (never do this).
# NOTE: no 'trap exit 0' here — this hook INTENTIONALLY exits 2, like
# block-dangerous-bash.sh. It is a sanctioned exception to invariant #3's
# "never block Claude" clause. That exception covers a body that fails the
# format, and nothing else: an infrastructure failure must still exit 0, so
# every tool this script depends on either has a guard or fails open.
#
# Required body format:
#   features/changes -> ## Summary
#   bug fixes        -> ## Bug  AND  ## Fix
#
# gh ignores a repo's PULL_REQUEST_TEMPLATE.md whenever --body/--body-file is
# passed, so the web-UI template cannot enforce anything here. This can.
#
# THE ESCAPE HATCH: a segment with leading whitespace is never treated as an
# invocation. Indent an example and it is documentation. This is the remedy
# block_format() prints, so it has to keep working — see the guard below the
# per-segment filters. The cost is that a genuinely indented invocation (inside
# an if/for body, say) is skipped; that is a fail-open, the safe direction here.
#
# Deliberate fail-OPEN cases (allow rather than block, because blocking would be
# unsatisfiable and the hook is a self-correction aid, not a security boundary):
#   - an indented invocation, per the escape hatch above
#   - a --body-file path the hook cannot read and that the command does not write
#   - a RELATIVE --body-file path in a command that also runs cd/pushd: the hook
#     does not share the command's cwd, so the file it can see is not the file gh
#     will send, in either direction
#   - a body passed indirectly, `--body "$(cat f.md)"` or `--body "$B"`, where the
#     text is not in the command string and no readable file can be resolved
#   - any failure of the heading search itself (grep erroring, a fork failing
#     under load): HEADING_ERR turns the block into an allow
#
#   - the inline-body text is taken from the whole command (from the first body
#     flag onward), not from the individual invocation, so with two PR commands
#     in one Bash call a good body on EITHER satisfies BOTH — in both directions
#     (`create -b good && edit -b bad` and `create -b bad && create -b good`).
#     Per-invocation scoping would mean reading the body out of the segment, and
#     a segment is one line, so every multi-line body would break. Not worth it.
#
#   - the writes_path branch (`printf ... > b.md && gh pr create -F b.md`)
#     validates the whole command rather than just the text being written, so a
#     heading anywhere in the call satisfies it.
#
#   - a "## Summary" inside a fenced code block in the body counts as the
#     heading. Stripping fences would let one unclosed fence swallow a real
#     heading and block a valid PR, which is the worse failure.
#
#   - text AFTER the body value can still satisfy the heading search
#     (`--body "nothing" --assignee "## Summary"`). Everything BEFORE the first
#     body flag is cut, which covers the realistic shape (a `git commit -m` with
#     a "## Summary" heading chained ahead of the PR); a full extraction of the
#     quoted value cannot be done safely, because a body containing an escaped
#     quote would truncate early and block a valid PR.
#
# Deliberate fail-CLOSED case:
#   - an UNINDENTED heredoc/doc line that itself begins with a gh PR invocation
#     reads as an invocation. Indent it, per the escape hatch.
#
# DO NOT use set -e — a transient jq/grep failure must not surface as a hook error.
set -u
set -f  # no globbing: $_seg is word-split deliberately below

[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" = "Bash" ] || exit 0
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$COMMAND" ] || exit 0

# --- cheap pre-filter --------------------------------------------------------
# This hook is registered on matcher Bash, so it runs on every Bash call in the
# project. The per-segment loop below is comparatively expensive (it spawns sed
# and grep per candidate segment), so reject the overwhelming majority of
# commands with three whole-string greps first.
printf '%s' "$COMMAND" | grep -Eq '(^|[[:space:]])pr([[:space:]]|$)' || exit 0
printf '%s' "$COMMAND" | grep -Eq '(^|[[:space:]])(create|edit)([[:space:]]|$)' || exit 0
printf '%s' "$COMMAND" | grep -q 'gh' || exit 0

# Join line continuations so a flag on a wrapped line still belongs to the
# invocation's segment.
CMD=${COMMAND//\\$'\n'/ }

# --- helpers -----------------------------------------------------------------
# Set when the heading search could not be performed (as opposed to finding
# nothing). grep exits >1 on error, and the quote folding is pure bash, so this
# is the only failure path left. A set flag converts a block into an allow.
HEADING_ERR=0

# Heading boundary allows punctuation ("## Summary:") and bold markers
# ("## **Summary**"), which are ordinary ways to write these headings.
#
# A heading counts at the start of a line OR straight after a quote/backtick/
# paren, so that `--body "## Summary` is found even though it is mid-line in the
# command text. That boundary is part of the regex on purpose.
#
# Two earlier versions got this wrong. The first folded those characters to
# newlines with `tr`; a `tr` that failed yielded empty input, which read as "no
# heading" and BLOCKED a valid body. The second used four `${t//x/y}` bash
# substitutions, which are super-quadratic in bash 3.2 — the /bin/bash this
# shebang selects on macOS — and cost 55s on a valid 14KB body and ~9min at
# 30KB, on a hook that runs on every Bash call. The regex form forks once and
# is flat.
has_heading() {
  local rc
  printf '%s' "$2" \
    | grep -Eqi "(^|[\"'\`(])[[:space:]]*##[[:space:]]+[*_]{0,2}$1([[:punct:][:space:]]|$)"
  rc=$?
  [ "$rc" -gt 1 ] && HEADING_ERR=1
  return "$rc"
}

# When the body is a heredoc or an inline string, the heading search runs over
# the command text, so a "## Summary" sitting in --title would satisfy it and
# let a body with no headings through. Drop title values first. Titles are
# single-line, so a line-based sed is sufficient.
strip_titles() {
  sed -E 's/(--title|-t)[[:space:]=]+"[^"]*"//g
          s/(--title|-t)[[:space:]=]+'"'"'[^'"'"']*'"'"'//g' 2>/dev/null
}

# Offset of the first occurrence of $1 in $2, or the empty string if absent.
# Pure bash: this runs per body-flag candidate and must not fork.
offset_of() {
  local pre
  case "$2" in
    *"$1"*) pre=${2%%"$1"*}; printf '%s' "${#pre}" ;;
    *) printf '%s' "" ;;
  esac
}

# Offset of the earliest body flag in $1, and which kind it is, as "OFFSET KIND"
# where KIND is `file` (--body-file/-F) or `inline` (--body/-b), or "" if none.
# --body is a prefix of --body-file, so on a tie the file form wins.
first_body_flag() {
  local s=$1 best="" kind="" p o
  for p in '--body-file' ' -F'; do
    o=$(offset_of "$p" "$s")
    [ -n "$o" ] && { [ -z "$best" ] || [ "$o" -lt "$best" ]; } && { best=$o; kind=file; }
  done
  for p in '--body' ' -b'; do
    o=$(offset_of "$p" "$s")
    [ -n "$o" ] && { [ -z "$best" ] || [ "$o" -lt "$best" ]; } && { best=$o; kind=inline; }
  done
  [ -n "$best" ] && printf '%s %s' "$best" "$kind"
}

# Does the command itself write to this path? If so the file's current content
# (missing, or stale from an earlier run) is not what gh will send.
# Searched against CMD_CODE, the command with quoted contents blanked, so that
# a redirection mentioned inside a string (`echo "save to > b.md"`) is not read
# as the command actually writing that file.
writes_path() {
  local p="$1" v
  for v in "> $p" ">$p" ">> $p" ">>$p" "tee $p" "tee -a $p" \
           "> \"$p\"" ">\"$p\"" ">> \"$p\"" "tee \"$p\"" \
           "> '$p'" ">'$p'" ">> '$p'" "tee '$p'"; do
    printf '%s' "$CMD_CODE" | grep -qF -- "$v" && return 0
  done
  return 1
}

# Split on the shell separators that end a command — but only where they are not
# inside quotes. A blind `tr ';|&'` truncated
# `gh pr create --title "foo & bar" --body "## Summary"` at the ampersand,
# leaving a first segment with no --body that was then blocked for having no
# body at all. Quote state carries across lines, which is what a multi-line
# command needs. An unbalanced quote inside a heredoc desyncs the tracker and
# under-splits; that only widens an invocation's segment, which is the same
# first-invocation scoping limit already documented above.
# Blank out the CONTENTS of quoted spans, keeping length and everything outside
# them. Used where a test must see shell syntax rather than prose: a `--web` in
# a body must not read as the flag, and a `> file` inside an echo must not read
# as a redirection. Same quote tracker as split_segments.
blank_quoted() {
  awk '
    BEGIN { sq = 0; dq = 0 }
    {
      out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\" && sq == 0) { out = out "  "; i++; continue }
        if (c == "\047" && dq == 0) { sq = 1 - sq; out = out c; continue }
        if (c == "\042" && sq == 0) { dq = 1 - dq; out = out c; continue }
        if (sq == 1 || dq == 1) { out = out " "; continue }
        out = out c
      }
      print out
    }
  ' 2>/dev/null
}

split_segments() {
  awk '
    BEGIN { sq = 0; dq = 0 }
    {
      out = ""
      eat = 0          # swallow blanks right after a separator, so that the
                       # indent escape hatch cannot be tripped by `cmd;  gh ...`
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\" && sq == 0) { eat = 0; out = out c substr($0, i + 1, 1); i++; continue }
        if (c == "\047" && dq == 0) { eat = 0; sq = 1 - sq; out = out c; continue }
        if (c == "\042" && sq == 0) { eat = 0; dq = 1 - dq; out = out c; continue }
        if (sq == 0 && dq == 0 && (c == ";" || c == "|" || c == "&")) { eat = 1; out = out "\n"; continue }
        if (eat == 1 && (c == " " || c == "\t")) { continue }
        eat = 0
        out = out c
      }
      print out
    }
  ' 2>/dev/null
}

block_format() {
  cat >&2 <<'MSG'
Blocked: PR body does not match the required description format.

  features/changes -> a "## Summary" section (what and why, 2-3 sentences)
  bug fixes        -> a "## Bug" section (what broke, observed behaviour, repro)
                      AND a "## Fix" section (what changed, why it is correct)
  both             -> ## Summary, then ## Bug, then ## Fix

The heading must be exactly level 2 -- "## Summary", not "### Summary" and not
an underlined (setext) heading.

A "## Fix" without a "## Bug" (or the reverse) is rejected even when a
"## Summary" is present, because that is a bug fix missing half its description.

If this command is writing DOCUMENTATION that merely contains an example
invocation, indent the example by one space. An indented line is never read as
a command.
MSG
  exit 2
}

# The body text to search when the body is inline or a heredoc, i.e. not
# separable from the command string. Title values are dropped, then everything
# before the first body flag is cut, so a "## Summary" in a `git commit -m`
# chained ahead of the PR cannot satisfy the check.
CMD_BODY=$(printf '%s' "$CMD" | strip_titles)
[ -n "$CMD_BODY" ] || CMD_BODY="$CMD"   # a sed failure must not empty the body
# The untruncated form. Needed only where the body text legitimately sits BEFORE
# the flag: `printf '## Summary\n' > b.md && gh pr create -F b.md` writes the
# file the same command then passes, so the content to validate is the printf.
CMD_WRITTEN="$CMD_BODY"
# The command with quoted contents blanked: shell syntax without the prose.
CMD_CODE=$(printf '%s' "$CMD" | blank_quoted)
[ -n "$CMD_CODE" ] || CMD_CODE="$CMD"
_fb=$(first_body_flag "$CMD_BODY")
[ -n "$_fb" ] && CMD_BODY=${CMD_BODY:${_fb%% *}}

SEGMENTS=$(printf '%s' "$CMD" | split_segments)
[ -n "$SEGMENTS" ] || SEGMENTS=$(printf '%s' "$CMD" | tr ';|&' '\n\n\n')

# --- walk the command's segments ---------------------------------------------
# Match an INVOCATION, not a mention: a command that merely contains the text
# (docs, tests, an echo) must not be blocked, so the match has to begin a command
# segment. Flag detection is scoped to the invocation's own segment so that a
# `curl -F`/`curl -w` in an adjacent command cannot hijack it.
while IFS= read -r _seg; do
  # Pure-bash rejects before any subprocess: the sed/grep pipeline below costs
  # milliseconds per segment, and a long heredoc has one segment per line.
  case "$_seg" in *gh*) ;; *) continue ;; esac
  case "$_seg" in *pr*) ;; *) continue ;; esac
  case "$_seg" in *create*|*edit*) ;; *) continue ;; esac

  # THE ESCAPE HATCH. Must come before any whitespace trimming, or the remedy
  # printed by block_format is a lie. split_segments already swallowed the
  # blanks that follow a separator, so any leading whitespace left here is the
  # author's own indentation.
  case "$_seg" in [[:space:]]*) continue ;; esac
  # Per-segment, so a failed heading search in one invocation cannot silently
  # wave through the next one in the same call.
  HEADING_ERR=0

  # The sed below strips exactly one set of prefixes before the binary. If the
  # segment's first word is not `gh`, not a path ending in /gh, and not one of
  # those prefixes, no amount of stripping will make it start with gh — so
  # reject it here rather than paying for a sed. This guard is deliberately no
  # stricter than the sed it guards: every form the sed strips is listed.
  # Without it, a 400-line document whose every line mentions gh, pr and create
  # spawned 400 seds and took ~3s.
  case "${_seg%%[[:space:]]*}" in
    gh|*/gh) ;;
    command|exec|env|time|nice|sudo|builtin|then|do|else|xargs|stdbuf|nohup|timeout) ;;
    *=*) ;;                            # leading env assignment
    '$('*|'('*|'{'*|'`'*|'!'*) ;;      # subshell, group, backtick, negation
    *) continue ;;
  esac

  _stripped=$(printf '%s' "$_seg" | sed -E '
    :top
    s/^(\$\(|\(|\{|`|!)[[:space:]]*//
    s/^timeout([[:space:]]+-[^[:space:]]+)*[[:space:]]+[0-9]+[smhd]?[[:space:]]+//
    s/^(command|exec|env|time|nice|sudo|builtin|then|do|else|xargs|stdbuf|nohup)([[:space:]]+-[^[:space:]]+)*[[:space:]]+//
    s/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//
    t top
  ' 2>/dev/null)
  # A sed failure must degrade to the unstripped segment, never to an empty one:
  # empty would skip the segment and fail open.
  [ -n "$_stripped" ] && _seg="$_stripped"

  # the binary, optionally path-qualified
  printf '%s ' "$_seg" | grep -Eq '^([^[:space:]]*/)?gh[[:space:]]' || continue

  # Identify command and subcommand POSITIONALLY. Searching for a " pr "
  # substring read `gh issue create --body "the pr will create noise"` as a PR
  # invocation and blocked it. gh's grammar is `gh [global flags] <command>
  # <subcommand> ...`, so walk the tokens, skip flags (and -R/--repo, the one
  # global flag that takes a separate value), and take the first three bare
  # words: binary, command, subcommand.
  #
  # A quoted value word-splits into several tokens, which is harmless: the
  # command and subcommand both precede any flag, so a body's contents are never
  # reached. `set -f` keeps a glob in the body from expanding here.
  _cmd=""; _sub=""; _n=0; _skip=0
  for _t in $_seg; do
    if [ "$_skip" = 1 ]; then _skip=0; continue; fi
    _t=${_t//\"/}; _t=${_t//\'/}; _t=${_t//\`/}
    [ -n "$_t" ] || continue
    case "$_t" in
      -R|--repo) _skip=1; continue ;;
      -*) continue ;;
    esac
    _n=$((_n + 1))
    case "$_n" in
      2) _cmd="$_t" ;;
      3) _sub="$_t"; break ;;
    esac
  done
  [ "$_cmd" = "pr" ] || continue
  case "$_sub" in create|edit) ;; *) continue ;; esac

  # Title values are prose and must not be read as syntax. Without this, a PR
  # titled `fix -F handling` made first_body_flag report a --body-file, and the
  # user was blocked with a message about a flag they never passed and no way to
  # comply short of renaming the PR. strip_titles runs on $CMD for the body
  # text; the segment needs its own pass.
  _st=$(printf '%s' "$_seg" | strip_titles)
  [ -n "$_st" ] && _seg="$_st"

  # `--web`/`--help` are looked for in the segment with quoted CONTENTS blanked,
  # so prose inside a body ("we could use --web instead", "pass -h for help")
  # is not mistaken for the flag, while a real flag is still found wherever it
  # sits — including after the body, which a pre-body-only test missed.
  _segcode=$(printf '%s' "$_seg" | blank_quoted)
  [ -n "$_segcode" ] || _segcode="$_seg"

  # `--help` prints usage and creates nothing.
  printf '%s ' "$_segcode" | grep -Eq '(^|[[:space:]])(--help|-h)([[:space:]]|=|$)' && continue
  # `--web` hands the body to the browser form, where the repo template applies.
  printf '%s ' "$_segcode" | grep -Eq '(^|[[:space:]])(--web|-w)([[:space:]]|=|$)' && continue

  _fbseg=$(first_body_flag "$_seg")
  if [ -n "$_fbseg" ]; then
    _bodykind=${_fbseg##* }
  else
    _bodykind=""
  fi

  # --- locate this invocation's body ----------------------------------------
  BODY=""
  INDIRECT=0
  if [ "$_bodykind" = file ]; then
    BODY_FILE=$(printf '%s' "$_seg" \
      | grep -Eo '(--body-file|-F)[[:space:]=]*("[^"]*"|'"'"'[^'"'"']*'"'"'|([^[:space:]]|\\ )+)' \
      | head -1 \
      | sed -E 's/^(--body-file|-F)[[:space:]=]*//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/; s/\\ / /g')
    case "$BODY_FILE" in "~"|"~/"*) BODY_FILE="$HOME${BODY_FILE#\~}" ;; esac

    if [ "$BODY_FILE" = "-" ] || [ "$BODY_FILE" = "/dev/stdin" ]; then
      BODY="$CMD_BODY"     # heredoc on stdin: the text is in this command
    elif writes_path "$BODY_FILE"; then
      BODY="$CMD_WRITTEN"  # command writes the file first: validate what it writes
    else
      # A relative path resolves against the COMMAND's cwd, which this hook does
      # not share. Same-named file at the project root => wrong verdict in either
      # direction, so only trust a relative path when nothing moves the cwd.
      case "$BODY_FILE" in
        /*) ;;
        *) printf '%s' "$CMD" | grep -Eq '(^|[[:space:]])(cd|pushd|popd)([[:space:]]|$)' && continue ;;
      esac
      if [ -d "$BODY_FILE" ]; then
        echo "Blocked: --body-file '$BODY_FILE' is a directory, not a file." >&2
        exit 2
      elif [ -f "$BODY_FILE" ] && [ -r "$BODY_FILE" ]; then
        BODY=$(cat "$BODY_FILE" 2>/dev/null || echo "")
        if [ -z "$BODY" ]; then
          echo "Blocked: PR body file '$BODY_FILE' is empty." >&2
          exit 2
        fi
      else
        continue           # unreadable and unwritten: documented fail-open
      fi
    fi

  elif [ "$_bodykind" = inline ]; then
    BODY="$CMD_BODY"
    # An indirect body ($(cat f), $VAR) is not present in the command string, so
    # a missing heading there proves nothing. A heredoc IS present, so it is not
    # indirect and must still be validated.
    if ! printf '%s' "$CMD" | grep -q '<<'; then
      if printf '%s ' "$_seg" | grep -Eq '(--body|-b)[[:space:]=]*"?(\$\(|`|\$[A-Za-z_{])'; then
        INDIRECT=1
        # Resolve the common `--body "$(cat FILE)"` shape when FILE is readable.
        _bf=$(printf '%s' "$_seg" \
          | grep -Eo '(--body|-b)[[:space:]=]*"?\$\([[:space:]]*cat[[:space:]]+[^)"]+' \
          | head -1 | sed -E 's/.*cat[[:space:]]+//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//')
        if [ -n "$_bf" ] && [ -f "$_bf" ] && [ -r "$_bf" ]; then
          BODY=$(cat "$_bf" 2>/dev/null || echo "")
          INDIRECT=0
        fi
      fi
    fi

  else
    # No body flag in THIS segment.
    #
    # The edit bail comes first: `gh pr edit 7 --add-label x` does not touch the
    # body, and it must not inherit a --body belonging to some other command in
    # the same call. Checking the whole command first blocked
    # `gh pr comment 5 --body "lgtm" && gh pr edit 5 --add-label ready`.
    if [ "$_sub" = "edit" ]; then
      continue
    elif printf '%s ' "$_seg" | grep -Eq '(^|[[:space:]])--fill(-first|-verbose)?([[:space:]]|=|$)'; then
      cat >&2 <<'MSG'
Blocked: --fill builds the PR body from commit messages, which cannot satisfy the
required description format.

Pass an explicit --body instead:
  features/changes -> a "## Summary" section
  bug fixes        -> a "## Bug" section and a "## Fix" section
MSG
      exit 2
    elif printf '%s' "$CMD" | grep -Eq '(--body|--body-file)([[:space:]]|=)|(^|[[:space:]])(-b|-F)'; then
      # The whole call has a body flag but this segment does not: the split was
      # imperfect (a desynced quote tracker inside a heredoc, say) rather than
      # the body being genuinely absent. Validate rather than block.
      BODY="$CMD_BODY"
    else
      cat >&2 <<'MSG'
Blocked: creating a PR with no --body opens an editor, which will not work in a
non-interactive session.

Pass --body (or --body-file) with:
  features/changes -> a "## Summary" section
  bug fixes        -> a "## Bug" section and a "## Fix" section
MSG
      exit 2
    fi
  fi

  # --- validate this invocation ---------------------------------------------
  HAS_SUMMARY=0; has_heading 'Summary' "$BODY" && HAS_SUMMARY=1
  HAS_BUG=0;     has_heading 'Bug'     "$BODY" && HAS_BUG=1
  HAS_FIX=0;     has_heading 'Fix'     "$BODY" && HAS_FIX=1

  # The heading search itself failed. Never block over infrastructure.
  [ "$HEADING_ERR" = 1 ] && continue

  if [ "$HAS_BUG" -ne "$HAS_FIX" ]; then
    if [ "$HAS_BUG" -eq 1 ]; then
      echo "Blocked: PR body has a '## Bug' section but no '## Fix' section. A bug fix needs both." >&2
    else
      echo "Blocked: PR body has a '## Fix' section but no '## Bug' section. A bug fix needs both." >&2
    fi
    exit 2
  fi

  [ "$HAS_SUMMARY" -eq 1 ] && continue
  [ "$HAS_BUG" -eq 1 ] && continue
  [ "$INDIRECT" -eq 1 ] && continue   # body not inspectable: documented fail-open

  block_format
done <<EOF
$SEGMENTS
EOF

exit 0
