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
# strictly inside. RELATIVE paths, `$TMPDIR` and `cd` are trusted only in a command that
# is nothing but an optional leading `cd` plus `rm` segments joined by `&&`/`;`. Anything
# the hook cannot prove (relative path without that shape, `~`, `$HOME`, other variables,
# braces, a glob through a symlink, a command substitution among the arguments, an rm
# run by xargs) goes to the Trash: a wrong real `rm` is unrecoverable, a wrong trash costs
# disk. An absolute scratch target stays real even with redirects after it (`rm -rf
# /tmp/x 2>/dev/null`) and in compound lines; redirect operands are never mistaken for
# rm operands. See README for the known gaps.
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
PY_RC=0   # a failing analysis must reach the fallback below, not the ERR trap (which exits 0 = rm stays real)
mkdir -p "${HOME:-/tmp}/.megavibe" 2>/dev/null || true
MV_CMD="$COMMAND" RMTRASH="$RMTRASH" python3 - > "$TMPOUT" 2>>"${HOME:-/tmp}/.megavibe/hook-errors.log" <<'PY' || PY_RC=$?
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

def is_arith(body):
    """True when `(( body ))` / `$(( body ))` can only be arithmetic. A body with a command
    separator (; & | newline, a backtick) may instead be nested subshells that RUN commands, so it
    is parsed as commands: trashing a variable named rm costs nothing, a plain rm does. (So a variable
    literally named rm used in arithmetic next to a bitwise operator, or with an operator hidden in an
    expansion (`$((rm $op 1))`), may be rewritten: bash then reports a syntax error and nothing is
    deleted. A static check cannot tell those from a nested command list, and that is the side to
    err on.)"""
    flat = []; k = 0
    while k < len(body):
        if body.startswith("$(", k):             # a nested substitution is parsed on its own
            e = find_close(body, k + 2)
            if e >= len(body):                   # unterminated: not something arithmetic can contain
                return False
            k = e + 1
        else:
            flat.append(body[k]); k += 1
    text = re.sub(r"\b\d{1,2}#[0-9A-Za-z@_]+", "0", "".join(flat))     # 16#ff is a number, not a comment
    if re.search(r"[;&|\n`#]", text):
        return False
    # two words side by side (`rm victim`, `rm -rf x`) are a command; arithmetic never has them
    return not re.search(r"[\w$]\s+[\w\"'/~.$]", text)

def find_close(text, k):
    """k is just past an opening $( : index of the matching ), or len(text). Quotes, escapes,
    nested $( ) and comments are shell syntax here, so a ) inside them does not count."""
    m_ = len(text); d = 1
    while k < m_:
        ch = text[k]
        if ch == "\\":
            k += 2; continue
        if ch == "'":
            if k > 0 and text[k-1] == "$":          # $'...' : backslash escapes inside
                k += 1
                while k < m_ and text[k] != "'":
                    k += 2 if text[k] == "\\" else 1
                k += 1; continue
            k = text.find("'", k + 1); k = m_ if k == -1 else k + 1; continue
        if ch == '"':
            k += 1
            while k < m_ and text[k] != '"':
                if text[k] == "\\":
                    k += 2
                elif text.startswith("$(", k):
                    k = find_close(text, k + 2) + 1
                else:
                    k += 1
            k += 1; continue
        if text.startswith("$(", k):
            d += 1; k += 2; continue
        if ch == "(":
            d += 1
        elif ch == ")":
            d -= 1
            if d == 0:
                return k
        elif ch == "#" and (k == 0 or text[k-1] in " \t\n;|&("):
            k = text.find("\n", k); k = m_ if k == -1 else k
            continue
        k += 1
    return m_

def subst_rewrite(text, heredoc=False):
    """bash runs the commands inside $( ) and ` ` even in text the main parser treats as opaque
    (a double-quoted string or a word containing one, an unquoted heredoc body). Rewrite them with
    the real parser, every rm there forced to the Trash (the target cannot be proven from here).
    Single-quoted text is literal and is copied as is; in a heredoc body quotes are plain characters."""
    r = []; k = 0; m_ = len(text); dq = False
    while k < m_:
        ch = text[k]
        if ch == "\\" and k + 1 < m_:
            r.append(text[k:k+2]); k += 2
        elif ch == "'" and not dq and not heredoc:
            if k > 0 and text[k-1] == "$":          # $'...' : backslash escapes inside
                e2 = k + 1
                while e2 < m_ and text[e2] != "'":
                    e2 += 2 if text[e2] == "\\" else 1
                e2 += 1
            else:
                e2 = text.find("'", k + 1); e2 = m_ if e2 == -1 else e2 + 1
            r.append(text[k:e2]); k = e2
        elif ch == '"' and not heredoc:
            dq = not dq; r.append(ch); k += 1
        elif text.startswith("$((", k) and find_close(text, k + 2) < m_ and text[find_close(text, k + 2) - 1] == ")" \
                and is_arith(text[k+3:find_close(text, k + 2) - 1]):
            e2 = find_close(text, k + 2)
            r.append("$((" + subst_rewrite(text[k+3:e2-1]) + "))"); k = e2 + 1
        elif text.startswith("$(", k):
            e2 = find_close(text, k + 2)
            r.append("$(" + parse(text[k+2:e2], True) + (")" if e2 < m_ else "")); k = e2 + 1
        elif ch == "`":
            e2 = k + 1
            while e2 < m_ and text[e2] != "`":
                e2 += 2 if text[e2] == "\\" else 1
            if e2 >= m_:
                r.append(text[k:]); break
            r.append("`" + parse(text[k+1:e2], True) + "`"); k = e2 + 1
        else:
            r.append(ch); k += 1
    return "".join(r)

REDIR = re.compile(r"(?:\d+|\{[A-Za-z_]\w*\})?(?:<<<|<<-?|<>|>>|>\||<&|>&|[<>])")
NO_TARGET = "\n;|&()<>`"
# Wrappers that run another command, and may take their own options before it
# (`nice -n 5 rm`, `sudo -u bob rm`, `timeout 5 rm`). The tables below say which options take a
# separate argument word, so the FIRST word that is not an option (or its argument, VAR=val, a
# timeout DURATION) is the wrapped command: `sudo -u bob rm` rewrites the rm, `sudo git rm`
# does not. A substitution among the options makes the wrapped command unknowable, and then
# any later rm counts.
# Options of each wrapper that take a separate argument word. An option missing from a table
# is assumed to take none; that is the one way the wrapped command can be misidentified, so
# the tables list what each tool documents.
_S = {"-a":1,"-u":1,"-g":1,"-h":1,"-p":1,"-C":1,"-D":1,"-r":1,"-t":1,"-T":1,"-U":1,"-R":1,
      "--user":1,"--group":1,"--host":1,"--prompt":1,"--close-from":1,"--chdir":1,"--role":1,"--type":1,
      "--chroot":1,"--command-timeout":1,"--other-user":1}
WRAPPERS = {
    "sudo": _S, "doas": {"-u":1,"-C":1}, "nice": {"-n":1,"--adjustment":1},
    "ionice": {"-c":1,"-n":1,"-p":1,"-P":1,"-u":1}, "nohup": {},
    "time": {"-f":1,"-o":1,"--format":1,"--output":1},
    "env": {"-u":1,"-C":1,"-P":1,"--unset":1,"--chdir":1},      # -S/--split-string: its argument IS the command
    "timeout": {"-s":1,"-k":1,"--signal":1,"--kill-after":1},
    "stdbuf": {"-i":1,"-o":1,"-e":1}, "setsid": {}, "caffeinate": {"-t":1,"-w":1},
    "exec": {"-a":1}, "builtin": {}, "command": {},
    "xargs": {"-a":1,"-d":1,"-E":1,"-I":1,"-J":1,"-L":1,"-n":1,"-P":1,"-R":1,"-S":1,"-s":1,
              "--arg-file":1,"--delimiter":1,"--max-args":1,"--max-procs":1,"--max-chars":1},
}

def skip_quote(k):
    """k is at an opening quote: index just past the closing one. $'...' honours backslashes."""
    q = src[k]
    bs = 0; j = k - 2
    while j >= 0 and src[j] == "\\":
        bs += 1; j -= 1
    esc = (q == '"') or (k > 0 and src[k-1] == "$" and bs % 2 == 0)
    k += 1
    while k < n and src[k] != q:
        if esc and src[k] == "\\" and k + 1 < n:
            k += 1
        k += 1
    return k + 1

def word_end(j):
    k = j
    while k < n and (src[k] == "`" or src[k] not in " \t\n;|&()<>`"):
        if src[k] == "\\" and k + 1 < n:
            k += 2; continue
        if src[k] in "'\"":
            k = skip_quote(k); continue
        if src[k] == "$" and src[k+1:k+2] == "(":      # $( ), $(( )): one span, however many spaces/;/| it holds
            k = min(find_close(src, k + 2) + 1, n); continue
        if src[k] == "`":
            k += 1
            while k < n and src[k] != "`":
                k += 2 if src[k] == "\\" else 1
            k += 1; continue
        k += 1
    return min(k, n)

def unquote_marker(w):
    """A heredoc marker the way bash removes quotes: '...' is literal, "..." keeps a backslash
    unless it escapes $ ` " \\, outside quotes a backslash just quotes the next character."""
    r = []; i2 = 0; m = len(w)
    while i2 < m:
        ch = w[i2]
        if ch == "'":
            e2 = w.find("'", i2 + 1); e2 = m if e2 == -1 else e2
            r.append(w[i2+1:e2]); i2 = e2 + 1
        elif ch == '"':
            i2 += 1
            while i2 < m and w[i2] != '"':
                if w[i2] == "\\" and i2 + 1 < m and w[i2+1] in '$`"\\':
                    i2 += 1
                r.append(w[i2]); i2 += 1
            i2 += 1
        elif ch == "\\" and i2 + 1 < m:
            r.append(w[i2+1]); i2 += 2
        else:
            r.append(ch); i2 += 1
    return "".join(r)

def redir_end(j):
    """j is at a redirect operator: index just past it and its target word."""
    m = REDIR.match(src, j)
    j += len(m.group(0))
    while j < n and src[j] in " \t":
        j += 1
    if j < n and src[j] not in NO_TARGET:
        j = max(word_end(j), j + 1)
    return j

def read_args(j):
    """The words of a simple command, redirects skipped. Second value: True when the
    command line carries something that makes the argument list unprovable (a command
    substitution), so the caller must not skip."""
    args = []; unsafe = False
    while j < n:
        while j < n and src[j] in " \t":
            j += 1
        if j >= n:
            break
        ch = src[j]
        if ch in "\n;|)":
            break
        if ch == "`" or ch == "(" or (ch == "$" and src[j+1:j+2] == "("):
            unsafe = True; break
        if ch == "&":
            if src[j+1:j+2] == ">":
                j += 2 + (src[j+2:j+3] == ">")
                while j < n and src[j] in " \t":
                    j += 1
                if j < n and src[j] not in NO_TARGET:
                    j = max(word_end(j), j + 1)
                continue
            break
        if ch == "#" and src[j-1] in " \t":
            break
        if REDIR.match(src, j) and (ch in "<>" or re.match(r"(?:\d+|\{[A-Za-z_]\w*\})[<>]", src[j:])):
            j = redir_end(j); continue
        ae = word_end(j)
        if ae == j:
            break
        w = src[j:ae]
        if "`" in w or "$(" in w:
            unsafe = True
        args.append(w); j = ae
        if j < n and src[j] == "(" and src[j-1] == "$":
            unsafe = True; break
    return args, unsafe

def parse(text, trash_all=False):
    """Rewrite the rm words in command position of `text`. trash_all: text taken from inside
    $( ), backticks, a double-quoted string or a heredoc body, where the cwd and variables of the
    real command line are not known, so every rm there goes to the Trash."""
    global src, n
    saved = (src, n)
    src = text; n = len(text)
    try:
        out = []
        i = 0
        at_cmd = True          # next word is in command position
        pending_heredoc = []   # (marker, dash, expands) declared on this line; their bodies start after the newline
        stack = []             # at_cmd to restore when $( ) / ` ` closes; None for ( ) / case )
        scan_stack = []        # parallel to the substitutions: was a wrapper's command being identified?
        wrap = None            # inside a wrapper's own options (sudo -u bob ..., nice -n 5 ...): which wrapper
        wrap_argn = 0          # words still to swallow as an option's argument
        wrap_dur = False       # timeout: the DURATION word is still to come
        scan_all = False       # reserved: never set (a substitution is part of the word it sits in, so it is just that option's argument)
        via_xargs = False      # this command is run by xargs: it will get operands we cannot see
        redir_target = False   # the next word is a redirect target; command position is unchanged by it
        redir_saved = True

        while i < n:
            c = src[i]
            if c == "\\" and src[i+1:i+2] == "\n":        # line continuation: not a word, not a separator
                out.append("\\\n"); i += 2; continue
            if c == "(":
                if at_cmd and src[i+1:i+2] == "(":
                    # a (( ... )) command is arithmetic, not a command list: `rm` there is a variable name
                    # (only $( ) substitutions INSIDE it run)
                    end = find_close(src, i + 1)
                    if end < n and end - 1 > i + 1 and src[end-1] == ")" and is_arith(src[i+2:end-1]):
                        out.append("((" + subst_rewrite(src[i+2:end-1]) + "))"); i = end + 1
                        at_cmd = False; continue
                stack.append(None)
                scan_stack.append((None, via_xargs, redir_target, redir_saved))
                redir_target = False
                out.append(c); i += 1; at_cmd = True; wrap = None; scan_all = via_xargs = False; continue
            if c == "&" and src[i+1:i+2] == ">":          # &> / &>> redirect, not a separator
                m = re.match(r"&>>?", src[i:]); out.append(m.group(0)); i += len(m.group(0))
                redir_target = True; redir_saved = at_cmd; continue
            if c in ";|&\n":
                out.append(c); i += 1; at_cmd = True; wrap = None; scan_all = via_xargs = False; redir_target = False
                if c == "\n" and pending_heredoc:
                    for marker, dash, expands in pending_heredoc:
                        # the body runs to the first line that IS the marker (exactly; <<- also ignores leading tabs)
                        b = i
                        while b < n:
                            e3 = src.find("\n", b); e3 = n if e3 == -1 else e3
                            ln = src[b:e3]
                            if (ln.lstrip("\t") if dash else ln) == marker:
                                break
                            b = e3 + 1
                        body = src[i:min(b, n)]
                        out.append(subst_rewrite(body, True) if expands else body)     # an unquoted body still RUNS $( ) and backticks
                        e3 = src.find("\n", b) if b < n else -1
                        t_end = n if e3 == -1 else e3 + 1
                        out.append(src[min(b, n):t_end]); i = t_end
                    pending_heredoc.clear()
                continue
            if c in " \t":
                out.append(c); i += 1; continue
            if c == ")":
                sv = stack.pop() if stack else None
                at_cmd = True if sv is None else sv
                was_ws, was_xargs, was_redir, was_saved = scan_stack.pop() if scan_stack else (None, False, False, True)
                if was_redir:                          # `> >(cmd)`: the substitution WAS the redirect target
                    at_cmd = was_saved
                out.append(c); i += 1
                wrap = None; scan_all = False
                via_xargs = was_xargs; continue
            if c in "<>":
                m = re.match(r"<<-?[ \t]*", src[i:])
                if m and not src.startswith("<<<", i):
                    j = i + len(m.group(0))
                    e = word_end(j)
                    if e > j:                       # the marker, with quotes and backslashes stripped as bash does
                        marker = unquote_marker(src[j:e]); dash = src[i:j].startswith("<<-")
                        # Only a real heredoc if a LATER line is exactly the marker; otherwise this is `1 << 2`
                        # (arithmetic) or an unterminated marker, and swallowing the rest would hide real commands.
                        nl = src.find("\n", e)
                        found = False
                        while nl != -1 and nl < n:
                            e3 = src.find("\n", nl + 1); e3 = n if e3 == -1 else e3
                            ln = src[nl + 1:e3]
                            if (ln.lstrip("\t") if dash else ln) == marker:
                                found = True; break
                            nl = e3 if e3 < n else -1
                        if found:
                            out.append(src[i:e]); i = e
                            pending_heredoc.append((marker, dash, not re.search(r"['\"\\]", src[j:e])))   # the rest of the line is parsed normally
                            continue
                m = REDIR.match(src, i)
                out.append(m.group(0)); i += len(m.group(0))
                redir_target = True; redir_saved = at_cmd; continue
            if c == "#" and (i == 0 or src[i-1] in BOUNDARY):
                e = src.find("\n", i); e = n if e == -1 else e
                out.append(src[i:e]); i = e; continue
            if c in "'\"":
                k = min(skip_quote(i), n)
                tok = src[i:k]
                out.append(subst_rewrite(tok) if c == '"' else tok); i = k
                if redir_target:
                    redir_target = False; at_cmd = redir_saved
                elif wrap is not None:
                    # a quoted word between a wrapper and its command is an option argument or the DURATION
                    if wrap_argn:
                        wrap_argn -= 1
                    elif wrap == "timeout" and wrap_dur:
                        wrap_dur = False
                    else:
                        wrap = None; at_cmd = False        # a quoted command word: not an rm we recognise
                else:
                    at_cmd = False
                continue
            k = word_end(i); word = src[i:k]
            if "$(" in word or "`" in word:
                word = subst_rewrite(word)     # a substitution among the characters of a word still runs
            if redir_target:                               # `> file`, `2>&1`, `<<< text`: not the command
                out.append(word); i = k; redir_target = False; at_cmd = redir_saved; continue
            if (word.isdigit() or re.fullmatch(r"\{[A-Za-z_]\w*\}", word)) and k < n and src[k] in "<>":    # the `2` of `2>file`, the `{fd}` of `{fd}>file`
                out.append(word); i = k; continue
            if wrap is not None:
                # between a wrapper and the command it runs: options, their arguments, VAR=val for env,
                # the DURATION for timeout. The first word that is none of those IS the wrapped command.
                if wrap_argn:
                    wrap_argn -= 1; out.append(word); i = k; continue
                if word == "--" or (word.startswith("-") and len(word) > 1):
                    out.append(word); i = k
                    tbl = WRAPPERS[wrap]
                    wrap_argn = tbl.get(word, 0)
                    if not wrap_argn and re.fullmatch(r"-[A-Za-z]\S*", word):
                        # a short-option cluster, read left to right: the first letter that takes an
                        # argument ends it; the argument is the rest of the word (-uroot, -n5, -IUSER)
                        # or, when nothing follows, the next word (-Eu bob, -rn 1)
                        for idx in range(1, len(word)):
                            if tbl.get("-" + word[idx], 0):
                                wrap_argn = 0 if idx + 1 < len(word) else 1
                                break
                    if wrap == "command" and word in ("-v", "-V"):    # a lookup: nothing is executed
                        wrap = None; at_cmd = False
                    continue
                if wrap == "env" and re.match(r"^[A-Za-z_]\w*=", word):
                    out.append(word); i = k; continue
                if wrap == "timeout" and wrap_dur:
                    wrap_dur = False; out.append(word); i = k; continue
                wrap = None; at_cmd = True                  # fall through: this word is the command
            if word in RM_WORDS and (at_cmd or scan_all):
                p = k
                while p < n and src[p] in " \t":
                    p += 1
                # `rm)` (case pattern / argless rm) or `rm(` / `rm (` (function def): leave alone.
                if p < n and src[p] in ")(":
                    out.append(word); i = k; at_cmd = False; continue
                args, unsafe = read_args(k)
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
                elif trash_all or via_xargs or unsafe:
                    out.append(rmtrash)      # operands we cannot see (xargs), command substitutions, or no known cwd
                elif targets and all(skip_target(t) for t in targets):
                    out.append(word)
                else:
                    out.append(rmtrash)
                i = k; at_cmd = False; scan_all = False; continue
            out.append(word); i = k
            if at_cmd and word in WRAPPERS:
                wrap = word; wrap_argn = 0; wrap_dur = (word == "timeout")
                if word == "xargs":
                    via_xargs = True
                continue
            if at_cmd and (word.startswith("-") or word == "{}"):
                pass   # option of sudo/xargs/env/find -exec: the command is still to come
            else:
                at_cmd = word in CMD_LEADERS or bool(re.match(r'^[A-Za-z_]\w*=', word))
        return "".join(out)
    finally:
        src, n = saved

analyze()
sys.stdout.write(parse(src))
PY
NEW_CMD=$(cat "$TMPOUT" 2>/dev/null)
if [ -z "$NEW_CMD" ]; then
  # The analysis produced nothing (it crashed, or was killed). Leaving the command alone
  # would leave EVERY rm real, which is exactly what this hook exists to prevent, so fall
  # back to a crude rewrite: any rm in command position (after a separator, keyword, assignment,
  # find -exec, or a wrapper and its options) becomes rmtrash,
  # quoted or not. Over-eager on purpose — a wrong trash costs disk space, a wrong rm
  # is unrecoverable. (-P / -W are left real, as in the main path.)
  echo "rm-to-trash.sh: analysis produced no output for a command containing rm — using the crude fallback" >> "${HOME:-/tmp}/.megavibe/hook-errors.log" 2>/dev/null || true
  # Command position only (after a separator or a wrapper and its options), so `git rm`,
  # `docker rm`, `echo rm` are left alone; a deletion carrying -P/-W stays real, per command.
  NEW_CMD=$(printf '%s' "$COMMAND" | RT="$RMTRASH" perl -0pe '
    my @q;   # quoted strings (without substitutions) are masked, so their contents are never mistaken for commands or options
    s{(\x27[^\x27]*\x27|"(?:[^"\\]|\\.)*")}{
        my $m = $1;
        if ($m =~ /^"/ && $m =~ /\$\(|`/) {
            $m =~ s{(\$\((?:[^()]|\([^()]*\))*\)|`[^`]*`)|([^\$`]+|[\$`])}{ defined $1 ? $1 : do { push @q, $2; "\x01" . $#q . "\x02" } }ge;
            $m
        } else { push @q, $m; "\x01" . $#q . "\x02" }
    }gex;
    my %o = (sudo=>"ugCDhprtTUR", doas=>"uC", nice=>"n", ionice=>"cnpPu", nohup=>"", time=>"fo", env=>"uCP",
             timeout=>"sk", stdbuf=>"ioe", setsid=>"", caffeinate=>"tw", exec=>"a", builtin=>"", command=>"",
             xargs=>"adEIJLnPRSs");
    my $alts = join("|", map { my $l = $o{$_}; my $arg = $l ne "" ? "-[A-Za-z]*[$l][ \\t]+\\S+|" : "";
                               "$_(?:[ \\t]+(?>$arg-\\S+|[\\d.]+[smhd]?|[A-Za-z_]\\w*=\\S+))*[ \\t]+" }
                          sort { length($b) <=> length($a) } keys %o);
    my $chain = qr/(?>$alts)/;
    s{((?:\A|[;&|(`\n]|\$\(|[ \t]-exec(?:dir)?(?=[ \t]))[ \t]*(?>(?:[A-Za-z_]\w*=\S*|then|do|else|elif|if|while|until|!|\{|(?:\d+|\{\w+\})?(?:[<>]+&?|&>>?)[ \t]*[^\s;|&()<>`]+)[ \t]+)*(?:$chain)*)(\\rm|/usr/bin/rm|/bin/rm|rm)(?=[\s;|&)]|\z)([^;|&\n\$`)]*)}
     { my ($pre,$cmd,$rest)=($1,$2,$3); my ($op)=split /(?:^|\s)--(?:\s|$)/, $rest, 2; ($op =~ /(?:^|\s)-[A-Za-z]*[PW]/) ? "$pre$cmd$rest" : "$pre$ENV{RT}$rest" }gex;
    s{\x01(\d+)\x02}{$q[$1]}g;' 2>/dev/null) || exit 0
  [ -n "$NEW_CMD" ] || exit 0
fi
[ "$NEW_CMD" != "$COMMAND" ] || exit 0

# Merge into the existing tool_input — replacing it would drop timeout,
# run_in_background and description from the call.
printf '%s' "$INPUT" | jq -c --arg cmd "$NEW_CMD" \
  --arg ctx "[megavibe rm-to-trash] rm ran as rmtrash — deleted paths are in the Trash (~/.Trash on the boot disk, the volume's .Trashes elsewhere)." \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {command: $cmd}), additionalContext: $ctx}}'
exit 0
