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
# does any `rm` carrying an option rmtrash can't do (`-P`, `-W`). That skip is a
# deliberate trade-off: scratch data in /tmp can then actually free disk, and
# nothing durable should live there (macOS clears it on reboot or after days of
# disuse). Targets are RESOLVED before matching (`..`, symlinks via realpath, a
# literal leading `cd <dir>`, a well-formed `$TMPDIR`) and the skip roots must be
# strictly inside. The hook only reasons about commands that are nothing but an
# optional leading `cd` plus `rm` segments joined by `&&`/`;`; anything it cannot
# prove (relative path with no cd, `~`, `$HOME`, other variables, braces, globs
# through a symlink, pipes, redirects, substitutions, control flow, assignments)
# goes to the Trash: a wrong real `rm` is unrecoverable, a wrong trash costs disk.
#
# There is NO escape hatch: `\rm`, `/bin/rm` and `/usr/bin/rm` are rewritten too.
# Bypassing the Trash to delete something "for real" is precisely the mistake this
# hook exists to prevent (it cost a credential file on 2026-09-08). If a file must
# be unrecoverable, use `shred`/`srm` explicitly. Emptying the Trash is blocked by
# block-dangerous-bash.sh: it is the only undo, and only the user empties it.
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
# Cheap gate before spawning python: an `rm` token in any spelling — bare,
# \rm, /bin/rm, /usr/bin/rm (not terraform/confirm/xterm).
printf '%s' "$COMMAND" | grep -Eq '(^|[^[:alnum:]_])rm([^[:alnum:]_]|$)' || exit 0

TMPOUT=$(mktemp -t mv-rmtrash) || exit 0
trap 'rm -f "$TMPOUT" 2>/dev/null' EXIT
MV_CMD="$COMMAND" RMTRASH="$RMTRASH" python3 - > "$TMPOUT" 2>/dev/null <<'PY'
import os, re, sys
src = os.environ.get("MV_CMD", "")
rmtrash = os.environ["RMTRASH"]
tmp_raw = os.environ.get("TMPDIR", "") or ""   # as the shell will substitute it, trailing slash included
tmp = tmp_raw.rstrip("/")
SKIP_PREFIX = ["/tmp", "/private/tmp", "/private/var/folders", "/var/folders"]
if tmp:
    SKIP_PREFIX.append(tmp)
SKIP_COMPONENT = ("node_modules", ".Trash", ".Trashes")
# $TMPDIR is trusted (as a skip prefix AND for expansion) only in the standard
# per-user form, so a hostile value (spaces, '~', a shallow dir) cannot widen it.
TMP_OK = bool(re.fullmatch(r"/(private/)?var/folders/[A-Za-z0-9_]+/[A-Za-z0-9_]+/T|/tmp", tmp))
if tmp and not TMP_OK:
    SKIP_PREFIX = [p for p in SKIP_PREFIX if p != tmp]
SKIP_REAL = SKIP_PREFIX + [os.path.realpath(p) for p in SKIP_PREFIX]

# Words after which the next word is still command position.
CMD_LEADERS = {"sudo", "exec", "time", "nice", "nohup", "xargs", "command", "builtin",
               "env", "then", "else", "do", "if", "elif", "while", "until", "!",
               "-exec", "-execdir", "{", "}"}
BOUNDARY = " \t\n;|&("
# Every spelling of rm. There is deliberately NO escape hatch: a delete that
# bypasses the Trash is exactly the mistake this hook exists to prevent.
RM_WORDS = ("rm", "\\rm", "/bin/rm", "/usr/bin/rm")
n = len(src)

# What this hook can PROVE about the shell, and nothing more. Shell is not a regular
# language, so cwd and variables are trusted only for a command that is NOTHING BUT
# an optional leading `cd <plain dir>` plus `rm` segments, joined by `&&` or `;` —
# no pipes, redirects, substitutions, quotes in the cd, assignments, control flow or
# any other command that could create a symlink, change directory or set a variable.
# Anything else resolves absolute literal paths only; a relative path, `~`, `$VAR`
# or brace expansion there goes to the Trash. A wrong real `rm` is unrecoverable; a
# wrong trash only costs disk space. The hook's own cwd is deliberately NOT used: it
# is not guaranteed to be the Bash tool's cwd.
FORBIDDEN = re.compile(r"[|&<>`()\\\n]|\$\(")
PATHW = r"[A-Za-z0-9_./~+@:,${}][A-Za-z0-9_./~+@:,${}-]*"   # never starts with '-', no quotes
simple = False
cwd = None

def resolve_text(word):
    """The literal path the shell will hand to rm, or None if we cannot be sure."""
    if len(word) >= 2 and word[0] == "'" and word[-1] == "'" and "'" not in word[1:-1]:
        return word[1:-1]
    if len(word) >= 2 and word[0] == '"' and word[-1] == '"' and '"' not in word[1:-1]:
        word = word[1:-1]
    elif "'" in word or '"' in word:
        return None
    if "\\" in word or "`" in word:
        return None
    t = word
    if "$" in t:
        if not (simple and TMP_OK):
            return None
        t = re.sub(r"\$\{TMPDIR\}|\$TMPDIR(?![A-Za-z0-9_])", lambda m: tmp_raw, t)
        if "$" in t:
            return None
    if t.startswith("~"):
        return None                      # '~' is never expanded: HOME is not a scratch area
    return t

def cd_dir(word):
    """Physical directory `cd <word>` lands in, or None if not provable."""
    t = resolve_text(word)
    if not t or not t.startswith("/") or ".." in t.split("/") or any(ch in t for ch in "*?[{"):
        return None
    # stat the pathname AS WRITTEN: the kernel's symlink-depth limit makes `cd` fail
    # where realpath() happily resolves, and a cd that fails leaves rm in the old cwd.
    if not (os.path.isdir(t) and os.access(t, os.X_OK)):
        return None
    return os.path.realpath(t)

def analyze():
    """Set `simple` and `cwd` for the whole command (see above)."""
    global simple, cwd
    segs = [x.strip(" \t") for x in re.split(r"&&|;", src)]
    if any(FORBIDDEN.search(x) for x in segs):
        return
    if segs and segs[-1] == "":
        segs.pop()
    if not segs:
        return
    rest = segs
    m = re.match(r"^cd[ \t]+(" + PATHW + r")$", segs[0])
    if m:
        rest = segs[1:]
    for seg in rest:
        w = re.split(r"[ \t]+", seg, 1)
        if not w or w[0] not in RM_WORDS:
            return
    simple = True            # set before cd_dir: its path may use $TMPDIR / ~
    if m:
        cwd = cd_dir(m.group(1))

def inside(path):
    for root in ("/private/var/folders/", "/var/folders/"):
        if path.startswith(root):         # <user>/<id>/T/<scratch>: not the per-user dirs themselves
            c = path[len(root):].split("/")
            return len(c) >= 4 and c[2] == "T"
    return any(path.startswith(q + "/") for q in SKIP_REAL)

def skip_target(word):
    t = resolve_text(word)
    if t is None or "{" in t:
        return False
    if t.endswith("/") and any(ch in t for ch in "*?["):
        return False                                   # `l*/` matches (and follows) directory links
    t = t.rstrip("/") or "/"
    parts = t.split("/")
    if any(ch in c for c in parts[:-1] for ch in "*?["):
        return False                                   # a glob can walk through a symlink
    if ".." in parts and any(ch in t for ch in "*?["):
        return False
    if t.startswith("/"):
        # HACK: realpath is taken now, at hook time. A symlink created EARLIER IN THE SAME
        # COMMAND LINE (ln -s, tar, git checkout ...) can still redirect an absolute path
        # under /tmp. Pre-existing (the old lexical match had the same hole); closing it
        # means trashing every compound command that deletes under /tmp.
        p = t
    elif cwd is not None:
        p = cwd + "/" + t
    else:
        # relative and cwd unknown: only the component skip, and only without '..'
        return ".." not in parts and any(c in parts for c in SKIP_COMPONENT)
    # Inside the skip set LEXICALLY (what the shell is told) AND after symlink resolution
    # (what it will touch). Either alone is not enough: a link that points into /tmp must
    # not make a durable path look like scratch, and a /tmp path that points out is not.
    lex = os.path.normpath(p)
    rp = os.path.realpath(p)
    if inside(lex) and inside(rp):
        return True
    return (any(c in lex.split("/") for c in SKIP_COMPONENT)
            and any(c in rp.split("/") for c in SKIP_COMPONENT))

def read_args(j):
    args = []
    while j < n and src[j] not in "\n;|&()<>`":
        while j < n and src[j] in " \t":
            j += 1
        if j >= n or src[j] in "\n;|&()<>`":
            break
        if src[j] == "#" and src[j-1] in " \t":
            break
        ae = word_end(j); args.append(src[j:ae]); j = ae
    return args

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

analyze()
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
    if word in RM_WORDS and at_cmd:
        p = k
        while p < n and src[p] in " \t":
            p += 1
        # `rm)` (case pattern / argless rm) or `rm(` / `rm (` (function def): leave alone.
        if p < n and src[p] in ")(":
            out.append(word); i = k; at_cmd = False; continue
        args = read_args(k)
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
