#!/bin/bash
# DO NOT use set -e — hook must be resilient.
_hook_error() {
  echo "rm-to-trash.sh failed at line $1: $2" >> "${HOME:-/tmp}/.megavibe/hook-errors.log" 2>/dev/null || true
  exit 0
}
trap '_hook_error ${LINENO:-?} "${BASH_COMMAND:-unknown}"' ERR
set -u

# Megavibe — deletions go to the Trash, not into the void.
#
# Rewrites `rm` in command position of a Bash tool command to `rmtrash` (same
# flags, moves files to the Trash) BEFORE the command runs, via PreToolUse
# updatedInput. A wrong delete is then a drag out of the Trash. This rewrites
# the command LINE Claude runs — not the inside of a script it invokes, and not
# a quoted `bash -c "rm …"` body. A shell alias only covers interactive shells;
# this covers the command Claude runs directly.
#
# Only when rmtrash is installed (setup.sh installs it where Homebrew exists).
# Only `rm` in command position — never inside quotes, heredoc bodies, comments,
# case patterns, `=`/`==` comparisons, or a `rm()` function definition. Targets
# all under the temp dirs / node_modules / a volume's Trash keep real `rm`, as
# does any `rm` carrying an option rmtrash can't do (`-P`, `-W`). To force a real
# unlink, write `\rm` or `/bin/rm` (both are left untouched).
#
# Runs in every project, not only megavibe ones — same reasoning as
# block-dangerous-bash.sh (a recoverable delete is always good); documented as
# an exception in CLAUDE.md invariant 3.
#
# Triggered by: PreToolUse (Bash). Exit 0 always.

command -v jq &>/dev/null || exit 0
command -v python3 &>/dev/null || exit 0
RMTRASH=$(command -v rmtrash 2>/dev/null || true)
[ -n "$RMTRASH" ] || exit 0

INPUT=$(cat 2>/dev/null || echo "")
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL" = "Bash" ] || exit 0
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$COMMAND" ] || exit 0
# Cheap gate before spawning python: a bare `rm` token (not terraform/confirm/
# xterm, and not /bin/rm — the leading / excludes it, keeping the escape hatch).
printf '%s' "$COMMAND" | grep -Eq '(^|[^[:alnum:]_/])rm([^[:alnum:]_]|$)' || exit 0

TMPOUT=$(mktemp -t mv-rmtrash) || exit 0
trap 'rm -f "$TMPOUT" 2>/dev/null' EXIT
MV_CMD="$COMMAND" RMTRASH="$RMTRASH" python3 - > "$TMPOUT" 2>/dev/null <<'PY'
import os, re, sys
src = os.environ.get("MV_CMD", "")
rmtrash = os.environ["RMTRASH"]
tmp = (os.environ.get("TMPDIR", "") or "").rstrip("/")
SKIP_PREFIX = ["/tmp", "/private/tmp", "/private/var/folders", "/var/folders"]
if tmp:
    SKIP_PREFIX.append(tmp)
SKIP_COMPONENT = ("node_modules", ".Trash", ".Trashes")

# Words after which the next word is still command position.
CMD_LEADERS = {"sudo", "exec", "time", "nice", "nohup", "xargs", "command", "builtin",
               "env", "then", "else", "do", "if", "elif", "while", "until", "!",
               "-exec", "-execdir", "{", "}"}
BOUNDARY = " \t\n;|&("
n = len(src)

def skip_target(word):
    w = word.strip("'\"").rstrip("/")
    if any(w == p or w.startswith(p + "/") for p in SKIP_PREFIX):
        return True
    return any(p in w.split("/") for p in SKIP_COMPONENT)

def word_end(j):
    k = j
    while k < n and src[k] not in " \t\n;|&()<>`":
        if src[k] == "\\" and k + 1 < n:
            k += 2; continue
        if src[k] in "'\"":
            q = src[k]; k += 1
            while k < n and src[k] != q:
                if q == '"' and src[k] == "\\" and k + 1 < n:
                    k += 1
                k += 1
            k += 1; continue
        k += 1
    return k

out = []
i = 0
at_cmd = True          # next word is in command position
heredoc = None         # terminator we are inside
stack = []             # at_cmd to restore when $( ) / ` ` closes; None for ( ) / case )

while i < n:
    c = src[i]
    if heredoc is not None:
        e = src.find("\n", i); e = n if e == -1 else e
        out.append(src[i:e+1] if e < n else src[i:e])
        if src[i:e].strip() == heredoc:
            heredoc = None
        i = e + 1; continue
    if c == "(":
        stack.append(at_cmd if (i > 0 and src[i-1] == "$") else None)
        out.append(c); i += 1; at_cmd = True; continue
    if c == "`":
        if stack and stack[-1] == "bt":
            stack.pop()
            sv = stack.pop() if stack else False
            at_cmd = False if sv is None else sv
        else:
            stack.append(at_cmd); stack.append("bt"); at_cmd = True
        out.append(c); i += 1; continue
    if c in ";|&\n":
        out.append(c); i += 1; at_cmd = True; continue
    if c in " \t":
        out.append(c); i += 1; continue
    if c == ")":
        sv = stack.pop() if stack else None
        at_cmd = True if sv is None else sv
        out.append(c); i += 1; continue
    if c in "<>":
        m = re.match(r"<<-?\s*(['\"]?)([^\s'\"<>|&;()]+)\1", src[i:])
        if m:
            out.append(m.group(0)); i += len(m.group(0))
            e = src.find("\n", i); e = n if e == -1 else e
            out.append(src[i:e+1] if e < n else src[i:e]); i = e + 1
            heredoc = m.group(2); at_cmd = True; continue
        out.append(c); i += 1; at_cmd = False; continue
    if c == "#" and (i == 0 or src[i-1] in BOUNDARY):
        e = src.find("\n", i); e = n if e == -1 else e
        out.append(src[i:e]); i = e; continue
    if c in "'\"":
        q = c; k = i + 1
        while k < n and src[k] != q:
            if q == '"' and src[k] == "\\" and k + 1 < n:
                k += 1
            k += 1
        out.append(src[i:min(k+1, n)]); i = k + 1; at_cmd = False; continue
    k = word_end(i); word = src[i:k]
    if word == "rm" and at_cmd:
        p = k
        while p < n and src[p] in " \t":
            p += 1
        # `rm)` (case pattern / argless rm) or `rm(` / `rm (` (function def): leave alone.
        if p < n and src[p] in ")(":
            out.append(word); i = k; at_cmd = False; continue
        j = k; args = []
        while j < n and src[j] not in "\n;|&()<>`":
            while j < n and src[j] in " \t":
                j += 1
            if j >= n or src[j] in "\n;|&()<>`":
                break
            if src[j] == "#" and src[j-1] in " \t":
                break
            ae = word_end(j); args.append(src[j:ae]); j = ae
        targets = []; opts_done = False; unsupported = False
        for a in args:
            if opts_done or a == "-" or not a.startswith("-"):
                targets.append(a)
            elif a == "--":
                opts_done = True
            elif not a.startswith("--") and ("P" in a or "W" in a):
                unsupported = True   # rmtrash cannot -P (overwrite) / -W (undelete)
        if unsupported:
            out.append(word)
        elif targets and all(skip_target(t) for t in targets):
            out.append(word)
        else:
            out.append(rmtrash)
        i = k; at_cmd = False; continue
    out.append(word); i = k
    if at_cmd and (word.startswith("-") or word == "{}"):
        pass   # option of sudo/xargs/env/find -exec: the command is still to come
    else:
        at_cmd = word in CMD_LEADERS or bool(re.match(r'^[A-Za-z_]\w*=', word))
sys.stdout.write("".join(out))
PY
NEW_CMD=$(cat "$TMPOUT" 2>/dev/null)
[ -n "$NEW_CMD" ] || exit 0
[ "$NEW_CMD" != "$COMMAND" ] || exit 0

# Merge into the existing tool_input — replacing it would drop timeout,
# run_in_background and description from the call.
printf '%s' "$INPUT" | jq -c --arg cmd "$NEW_CMD" \
  --arg ctx "[megavibe rm-to-trash] rm ran as rmtrash — deleted paths are in the Trash (~/.Trash on the boot disk, the volume's .Trashes elsewhere)." \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {command: $cmd}), additionalContext: $ctx}}'
exit 0
