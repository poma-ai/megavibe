#!/bin/bash
# Megavibe — ask before internal work reaches a PUBLIC repository.
# Triggered by: PreToolUse (Bash). Runs in ALL projects (a push is a push).
# DO NOT use set -e. This hook never exits 2. It stays silent (exit 0), or answers with a
# permission prompt (permissionDecision "ask", honoured under bypassPermissions and
# forwarded to the phone, like the remote-delete guard), or, where it could not see the
# push and the agent can simply issue it again in a form it can see (a chain, a variable,
# an unknown directory), with permissionDecision "deny" and a reason that says how: the
# agent corrects itself and no human is asked. Infra failures (no jq, no python3, a check
# that crashes before the target is known to be public) fail OPEN: silent exit 0. Once a
# target is known to be PUBLIC, a failure of this guard asks.
set -u
#
# Why: on 2026-11-21 a session pushed a branch with internal material to a
# repository that turned out to be public; it was reachable for about 50 minutes.
# "Check the repository's visibility before every push" lived only in memory and was
# skipped. This is the check, in code.
#
# What fires it (parsed by a quote-aware tokenizer, so quoted text, echo and commit messages are not
# commands; `bash -c`, `sudo`, `env X=1`, `git -C dir`, and `cd dir && git push` are):
#   git push                      the target is resolved (remote name, URL, pushurl,
#                                 insteadOf, branch/pushDefault remote) and its
#                                 visibility looked up with `gh repo view`
#   gh pr create|edit|comment|review|merge|close|reopen, gh issue create|edit|comment|close|reopen,
#   gh release create|edit, gh api writes (POST/PATCH/PUT, or fields without -X, to repos/<owner>/<repo>/...)
#                                 the repository the text goes to (the last -R/--repo, a pull request or
#                                 issue URL, the api endpoint, GH_REPO, else the one gh resolves from the
#                                 checkout; host from -R HOST/o/r, the URL, --hostname, GH_HOST) is looked
#                                 up. PUBLIC: the text is scanned like a commit (--title, --subject, --body,
#                                 --notes, --comment, --body-file/--notes-file/-F FILE, --template, -f/-F
#                                 fields, -F k=@FILE, --input FILE with its JSON strings, the contents API's
#                                 base64; "-" for standard input only when it is a heredoc the hook can see,
#                                 and "$(cat <<'EOF' ... EOF)"). Text the hook cannot see (a variable, a
#                                 substitution, a pipe or redirection, an unquoted heredoc that expands,
#                                 --fill, --editor, a missing file, a file another command in the same call
#                                 names) is DENIED with the instruction to pass a file. A question about a
#                                 text shows its length and first lines. `gh api graphql` with a mutation asks
#                                 (its repository cannot be placed); a query is a read.
#   built-in rules                for commit and tag messages and every published text, on a PUBLIC target,
#                                 with no configuration: a Claude Code session link (claude.ai/code/session_…)
#                                 and a `Claude-Session:` trailer are DENIED, not asked: approving them is never
#                                 the intent. Co-authored-by alone is fine; private repositories keep both.
#   gh repo create --public       asks (publishes a new repo); scans local history
#                                 when --push/--source is given
#   gh repo edit --visibility public   asks: it turns the WHOLE history public;
#                                 scans local history when no other repo is named
# Not fired: --dry-run, --delete, a delete refspec (":branch"), a local-path remote.
#
# Chains are NOT simulated. A state-changing git command earlier in the same call (add, commit, switch,
# checkout, branch, merge, rebase, pull, cherry-pick, reset, stash, tag, ...) makes the push's content
# unknowable beforehand, and every simulated predecessor opened the next gap (fifteen review rounds). So a push
# to a PUBLIC repository after one is DENIED with the instruction to run it in a separate call, where the full
# scan applies: `git commit ... && git push` chains to public repos are therefore always refused once, BY DESIGN,
# and the agent repeats the push alone (a standalone push keeps the full scan; the same chain to a private repo
# passes). `git remote add|set-url|rename|remove` and `git config` (writes) before a push are denied the same way
# whatever the visibility, since they change where it goes; so is `git switch`/`checkout` before a push that names
# no remote in a repository with several remotes (the branch decides the remote). Also denied, with the fix named:
# a variable in the remote, a refspec (public target) or the directory (`-C`, `--git-dir`, `--work-tree`, a `cd`).
#
# Postures (each reason names what was found, one line per hit, values truncated):
#   PRIVATE / INTERNAL target     silent pass, no scan, no cost
#   PUBLIC target, not expected   ask, whatever the scan says: the repository is not on the list of repositories
#                                 you expect to be public, ~/.megavibe/personal/public-push.known-public (one
#                                 host/owner/repo glob per line, `#` comments, case-insensitive). The human adds a
#                                 repository there once. This is what stops content no pattern recognises from
#                                 reaching a repository nobody knew was public.
#   PUBLIC target, scan clean     silent pass when the repository is on that list
#   PUBLIC target, hits           ask, each hit named by file:line (secrets show 4
#                                 characters at most)
#   visibility UNKNOWN            ask: gh missing or failing, offline, a host that is
#                                 not GitHub, an ssh alias that does not resolve. A
#                                 push to a host that might be public never passes
#                                 silently. Silence a host or repo you know is private
#                                 in ~/.megavibe/personal/public-push.trusted (it answers
#                                 only where the lookup cannot: a PUBLIC answer from gh is
#                                 never overridden by it)
#   scan truncated               ask: more than 500 outgoing commits or 8 MB of diff
#                                 is a scan that did not see everything
#
# What is scanned (outgoing = `git rev-list <src> --not --remotes=<remote>`: commits
# the remote's last-fetched refs do not hold; a new branch yields every commit it
# does not share with the remote): added lines, commit messages, changed file paths.
# The tracking refs are used only when the destination really holds them: the boundary
# commits of the outgoing range (five at most) are looked up with `gh api`, and when one
# is definitely absent (the remote's URL was changed since the last fetch) every commit
# that would go out is scanned and the prompt says so.
#   generic     home paths (/Users/<name>/, /home/<name>/; placeholders such as
#               /Users/<you>/ pass, the real login name never does), private keys and
#               token shapes (AWS, GitHub, Slack, Anthropic/OpenAI sk-, Google AIza,
#               Stripe live, GitLab; a line containing example/placeholder/xxx/redacted/
#               dummy is skipped for these, as scripts/leak-scan.sh does; a line carrying the uppercase
#               marker EXAMPLE declares itself a fixture and is exempt from the home-path and email
#               patterns too: only the denylist still applies to it), email addresses other than: the authors and
#               committers of the outgoing commits and your user.email (they are
#               published anyway), trailer lines (Co-authored-by:, Signed-off-by:),
#               noreply addresses, example.com/.org/.net and the reserved .example/.invalid/.test
#               domains, and your allow file
#   denylist    ~/.megavibe/personal/public-push.deny, outside any repo. One entry
#               per line; `#` starts a comment; case-insensitive literal text, or a
#               regex when written /like this/. Customer names, host names, internal
#               terms. Example (generic): `ACME Corp`, `/prod-db-[0-9]+/`.
#   allow       ~/.megavibe/personal/public-push.allow-email: one glob per line.
#
# Resolution detail: GitHub is github.com plus every host in GH_HOST or
# MEGAVIBE_GITHUB_HOSTS (space separated); an ssh alias is resolved from the HostName lines of ~/.ssh/config, read as text (`ssh -G` would run Match exec commands; Include and wildcard hosts are not followed).
# Results of `gh repo view` are cached per repository for MEGAVIBE_PUBLIC_PUSH_CACHE_SECS
# (default 300) under ~/.megavibe/cache/public-push/; an unknown result is never cached.
#
# Override, for a human only: export MEGAVIBE_ALLOW_PUBLIC_PUSH=1 in the environment
# the session LAUNCHES with (shell or settings env). An inline prefix in the command
# is deliberately NOT honoured, and is reported if present: a peer message or a
# prompt-injected instruction can only edit the command text, not the hook's
# environment. The prompt itself is the per-push human decision.
#
# Known gaps (not enforced here): gh texts outside the list above (gh gist create, gh label create/edit, repository
# descriptions, gh workflow run inputs, gh api to endpoints that are not repos/<owner>/<repo>, release ASSETS) are
# not read; a session link inside a committed FILE is not a built-in rule (only messages and published texts are);
# a body file is read as it is when the hook runs (a file another command in the same call names is denied, one
# changed by a process outside the call is not seen, nor one a script in the call writes without naming it); --web
# texts typed in the browser are the human's; shell forms the parser does not model (ANSI-C $'…' quoting, brace
# expansion, a case-pattern `)` or a `)` inside ${…} within $( ), a quoted command word such as git "push" or gh
# "pr", gh aliases, eval of single-quoted text, a script fed to a shell on stdin, a ` #` inside a quote nested in
# backticks or ${…} within double quotes, which cuts the rest of that line);
# a GraphQL mutation always asks, private repositories included;
# the commits `gh pr create` may push itself are not scanned either: the pull request part only asks when its
# destination is public and not on your known-public list; a `cd` that only runs conditionally
# (`test -d x && cd y; git push`) is followed as if it ran; with tracking refs that hide the whole push, a selector
# (--all, --branches) is not expanded into tips; configuration that changes what git itself does or shows
# (GIT_CONFIG_COUNT/KEY/VALUE in the command, replace refs, i18n.logOutputEncoding, a `-diff` attribute: none occurs
# without a deliberate setup); a placeholder word (example, xxx, ...) anywhere on a line exempts the whole line from
# the secret patterns; denylist literals match as substrings; a push through a git alias, a script or
# $(...)/backtick substitution; `git push` inside a command run by another tool; binary content; the
# conflict-resolution lines of a merge commit (git log -p shows no diff for merges); a denylist written in a file the hook cannot read is
# silently empty (the reason says so only for an invalid regex).

command -v jq &>/dev/null || exit 0
command -v python3 &>/dev/null || exit 0

[ "${MEGAVIBE_ALLOW_PUBLIC_PUSH:-0}" = "1" ] && exit 0

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$COMMAND" ] || exit 0

case "$COMMAND" in
  *push*|*gh*pr*|*gh*repo*|*gh*issue*|*gh*release*|*gh*api*) ;;
  *) exit 0 ;;
esac

read -r -d '' _PROG <<'PYEOF'
import fnmatch, hashlib, json, os, re, shlex, stat, subprocess, sys, time

try:
    DATA = json.load(sys.stdin)
except Exception:
    sys.exit(0)
CMD = (DATA.get("tool_input") or {}).get("command") or ""
CWD0 = DATA.get("cwd") or os.getcwd()
HOME = os.path.expanduser("~")
PERSONAL = os.path.join(HOME, ".megavibe", "personal")
CACHE_DIR = os.path.join(HOME, ".megavibe", "cache", "public-push")
try:
    TTL = int(os.environ.get("MEGAVIBE_PUBLIC_PUSH_CACHE_SECS", "300"))
except ValueError:
    TTL = 300
MAX_COMMITS, MAX_BYTES, MAX_HITS = 500, 8 * 1024 * 1024, 20
NONCE = hashlib.sha1(os.urandom(16)).hexdigest()[:12]
M1, M2 = "\x01MV" + NONCE + "\x01", "\x02MV" + NONCE + "\x02"   # commit delimiters no content can predict

def ask(lines):
    why = "Public-push guard: " + lines[0] + "\n" + "\n".join(lines[1:])
    why += ("\nApprove only if you have read the outgoing change and every line above is expected. "
            "A standing human decision: export MEGAVIBE_ALLOW_PUBLIC_PUSH=1 before launching the session "
            "(an inline prefix is ignored).")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                      "permissionDecision": "ask", "permissionDecisionReason": why}}))
    sys.exit(0)

RETRY = []   # the guard could not see this push, and the agent can simply issue it again in a form it can see
def retry(msg):
    RETRY.append(msg); return None

def deny(lines):
    why = "Public-push guard: NOTHING in this call ran (earlier commands such as git add or git commit included), nothing was pushed or published. " + lines[0] + "\n" + "\n".join(lines[1:])
    why += "\nIssue the command again as described; no human decision is needed for that."
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                      "permissionDecision": "deny", "permissionDecisionReason": why}}))
    sys.exit(0)

# ---- command parsing (same family as the kill guard in block-dangerous-bash.sh) ----
_QUOTED = re.compile(r"""('[^']*'|"(?:\\.|[^"\\])*")""")
def match_close(s, k):
    """index of the ) that closes a ( opened just before s[k], honouring quotes, escapes and nesting; -1 if none"""
    d, q, n = 0, None, len(s)
    while k < n:
        c = s[k]
        if q == "'":
            if c == "'": q = None
        elif c == "\\": k += 1
        elif q == '"':
            if c == '"': q = None
            elif c == "$" and s[k + 1:k + 2] == "(":
                j = match_close(s, k + 2)
                if j < 0: return -1
                k = j
        elif c in "'\"": q = c
        elif c == "(": d += 1
        elif c == ")":
            if d == 0: return k
            d -= 1
        k += 1
    return -1
def _scan(text, comments=False, blank_single=False):
    """one pass over shell text with the quote state carried along (quotes may span lines). comments: drop an unquoted
    # at a word start up to the newline, so an apostrophe inside a comment cannot pair with a later quote.
    blank_single: replace what single quotes hold, and an escaped backtick or $, with spaces (text, never a substitution)."""
    out, q, i, n = [], None, 0, len(text)
    while i < n:
        c = text[i]
        if q == "'":
            if c == "'": q = None; out.append(c)
            else: out.append(" " if (blank_single and c != "\n") else c)
        elif q == '"':
            if c == "\\" and i + 1 < n:
                out.append("  " if (blank_single and text[i + 1] in "`$") else c + text[i + 1]); i += 1
            elif c == "$" and text[i + 1:i + 2] == "(" and match_close(text, i + 2) >= 0:   # "$( "a #b" )": not a comment, not the end
                j = match_close(text, i + 2)
                out.append("$(" + _scan(text[i + 2:j], comments, blank_single) + ")"); i = j + 1; continue
            else:
                if c == '"': q = None
                out.append(c)
        elif c == "\\" and i + 1 < n:
            out.append("  " if (blank_single and text[i + 1] in "`$") else c + text[i + 1]); i += 1
        elif c in "'\"":
            q = c; out.append(c)
        elif comments and c == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
            while i < n and text[i] != "\n": i += 1
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)

def strip_comments(text):
    return _scan(text, comments=True)
# Heredocs: each operator is replaced in the command text by a word __MVHD<n>__ that names its body in BODIES, so a gh
# command that reads its text from standard input can be given the body it will really read (and nothing else can).
out, pending, BODIES, _open, _openers = [], [], [], [], []   # _open: lines taken as heredoc body since the last complete heredoc
HDNONCE = hashlib.sha1(os.urandom(16)).hexdigest()[:10]   # a placeholder nobody can type into a command
HD_RE = re.compile(r"(?<!<)<<(?!<)(-?)\s*(\\?)([\x27\"]?)([A-Za-z0-9_][A-Za-z0-9_.-]*)[\x27\"]?")
def bare_line(line, st):
    """line with quoted text blanked (same length) and comments blanked, given the quote stack st open at its start
    ("'", '"', or [depth] for a $( ) inside double quotes, where the shell reads commands again). A quoted heredoc
    delimiter right after << is kept. -> (bare, stack at the end of the line)"""
    out, i, n, keep = [], 0, len(line), False
    while i < n:
        c, top = line[i], (st[-1] if st else None)
        if top == "'":
            if c == "'": st.pop(); out.append(c); keep = False
            else: out.append(c if keep else " ")
            i += 1; continue
        if top == '"':
            if c == "\\" and i + 1 < n: out.append(line[i:i + 2] if keep else "  "); i += 2; continue
            if c == '"': st.pop(); out.append(c); keep = False; i += 1; continue
            if c == "$" and line[i + 1:i + 2] == "(": st.append([0]); out.append("$("); i += 2; continue
            out.append(c if keep else " "); i += 1; continue
        if c == "\\" and i + 1 < n: out.append(line[i:i + 2]); i += 2; continue
        if c in "'\"":
            keep = bool(re.search(r"(?<!<)<<-?\s*\\?$", "".join(out))); st.append(c); out.append(c); i += 1; continue
        if isinstance(top, list):
            if c == "(": top[0] += 1
            elif c == ")":
                if top[0] == 0: st.pop()
                else: top[0] -= 1
        if c == "#" and not st and (i == 0 or line[i - 1] in " \t;&|("): out.append(" " * (n - i)); break
        out.append(c); i += 1
    return "".join(out), st
_QST = []
for line in CMD.split("\n"):
    if pending:
        d, idx = pending[0]
        if line == d or (BODIES[idx]["dash"] and line.lstrip("\t") == d):   # bash: the exact line, <<- strips tabs only
            pending.pop(0)
            if not pending: _open = []; _openers = []
        else:
            BODIES[idx]["lines"].append(line.lstrip("\t") if BODIES[idx]["dash"] else line); _open.append(line)
        continue
    _bare, _QST = bare_line(line, _QST)   # "1 << n" inside quotes is not a heredoc, nor one in a comment, nor in a multi-line quoted body
    _ms = list(HD_RE.finditer(_bare))   # _bare keeps every position of line, so a match locates the operator in line
    if _ms:
        _openers.append((len(out), line))
        base0 = len(BODIES)
        for k, m in enumerate(_ms):
            BODIES.append({"lines": [], "literal": bool(m.group(2) or m.group(3)), "dash": bool(m.group(1))})
            pending.append((m.group(4), base0 + k))
        for k, m in reversed(list(enumerate(_ms))):
            line = line[:m.start()] + " __MVHD%s_%d__ " % (HDNONCE, base0 + k) + line[m.end():]
    out.append(line)
if pending:   # a heredoc that never ends was not one (a << in a comment or in a multi-line quoted text): what it took is command text
    for _i, _orig in _openers: out[_i] = _orig
    out += _open
HDTOK = re.compile(r"__MVHD" + HDNONCE + r"_(\d+)__")
def body_of(idx):
    """-> (text, literal) of heredoc idx; literal False when the body may expand ($, backtick, backslash in an unquoted heredoc)"""
    b = BODIES[idx]; t = "\n".join(b["lines"])
    return t, b["literal"] or not re.search(r"\$[A-Za-z_{(0-9@*#?$!-]|`|\\[$`\\]", t)   # what an unquoted heredoc expands
def nl_sep(text):
    """a newline outside quotes separates commands; one inside quotes is part of the word (a multi-line body keeps its lines)"""
    out, q, i = [], None, 0
    while i < len(text):
        c = text[i]
        if q is None and c == "\\" and i + 1 < len(text): out.append(text[i:i + 2]); i += 2; continue
        if q == '"' and c == "\\" and i + 1 < len(text): out.append(text[i:i + 2]); i += 2; continue
        if c in "'\"" and (q is None or q == c): q = None if q else c
        out.append(" ; " if (c == "\n" and q is None) else c); i += 1
    return "".join(out)
TEXT = nl_sep(re.sub(r"(?<!\\)((?:\\\\)*)\\\n", r"\1", strip_comments("\n".join(out))))   # C:\\dir\\ at a line end does not join
# redirections are not arguments: `2>&1`, `> file`, `< file`
_REDIR = re.compile(r"(?:(?<=\s)|^)\d*(?:>>?|<)(?:&\d+-?|[ \t]*[^\s;&|()\"'<>]+)")   # an unquoted operand; a quoted one is dropped with its operator at token level
TEXT = "".join(part if i % 2 else _REDIR.sub(" ", part).replace("\\ ", "\x1f") for i, part in enumerate(_QUOTED.split(TEXT)))   # "\\ " (an escaped space) stays inside its word   # quoted text is never a redirection

WRAP = {"sudo": {"-u","-g","-h","-p","-C","-T","-r","-t","-U","-D","-R"}, "doas": {"-u","-C"},
        "env": {"-u","-C","-S","-P"}, "nice": {"-n"}, "stdbuf": {"-i","-o","-e"},
        "timeout": {"-s","-k"}, "nohup": set(), "command": set(), "time": set(), "builtin": set(),
        "xargs": {"-I","-n","-P","-L","-s","-E","-d","-a"}, "exec": {"-a"}, "setsid": set(), "caffeinate": {"-t","-w"},
        "gtimeout": {"-s","-k"}}
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "fi", "done"}
SHELLS = {"sh", "bash", "zsh", "ksh", "dash"}
OPS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&", ";;"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

PUNCT = "();<>|&"
def split_tokens(s):
    """shell words with their quotes kept (unq removes them), and operator runs. A quote may start inside a word
    (body='a (b)'): it runs to its closing quote across spaces, parentheses and newlines, as in the shell. None: an
    unclosed quote."""
    toks, cur, q, i, n = [], [], None, 0, len(s)
    def flush():
        if cur: toks.append("".join(cur)); cur.clear()
    while i < n:
        c = s[i]
        if q:
            if q == '"' and c == "\\" and i + 1 < n: cur.append(s[i:i + 2]); i += 2; continue
            if q == '"' and c == "$" and s[i + 1:i + 2] == "(":   # "$( ... )": quotes inside it do not end the double quote
                j = match_close(s, i + 2)
                if j < 0: return None
                cur.append(s[i:j + 1]); i = j + 1; continue
            cur.append(c); i += 1
            if c == q: q = None
            continue
        if c == "\\" and i + 1 < n: cur.append(s[i:i + 2]); i += 2; continue
        if s[i + 1:i + 2] == "(" and (c == "$" or (c in "<>" and not cur)):   # $( ), $(( )), <( ), >( ): part of the word
            j = match_close(s, i + 2)
            if j < 0: return None
            cur.append(s[i:j + 1]); i = j + 1; continue
        if c in "'\"": q = c; cur.append(c); i += 1; continue
        if c in " \t\n\r\f\v": flush(); i += 1; continue   # not isspace(): \x1f marks an escaped space inside a word
        if c in PUNCT:
            flush(); j = i
            while j < n and s[j] in PUNCT: j += 1
            toks.append(s[i:j]); i = j; continue
        cur.append(c); i += 1
    if q: return None
    flush()
    out = []
    for t in toks:   # shlex glues operator runs such as ");" into one token: split them
        if t not in OPS and t and all(ch in "();&|" for ch in t):
            i = 0
            while i < len(t):
                for op in ("&&", "||", "|&", ";;", ";", "&", "|", "(", ")"):
                    if t.startswith(op, i): out.append(op); i += len(op); break
        else:
            out.append(t)
    # --flag='two words': non-posix shlex ends the token at the opening quote; glue the pieces back into one word
    merged, i = [], 0
    while i < len(out):
        t = out[i]
        def _bad(x):
            try: shlex.split(x); return False
            except ValueError: return True
        if t not in OPS and _bad(t):
            j, acc = i + 1, t
            while j < len(out) and out[j] not in OPS and _bad(acc): acc += " " + out[j]; j += 1
            if not _bad(acc): merged.append(acc); i = j; continue
        merged.append(t); i += 1
    return merged

class W(str):
    """a shell word without its quotes; dyn: the shell expands something in it ($, backtick outside single quotes)"""
    dyn = False
def word(s, dyn):
    w = W(s); w.dyn = dyn; return w
def unq(tok):
    dyn = bool(re.search(r"\$[A-Za-z_{(0-9@*#?$!-]|`|^[<>]\(", _scan(tok, blank_single=True)))   # a lone "$ " is not expanded
    try:
        w = shlex.split(tok)
        return word(("".join(w) if w else "").replace("\x1f", " "), dyn)
    except ValueError:
        return word(tok, dyn)

REDIROP = re.compile(r"^\d*(?:>>?|<<?<?|>&|<&|&>>?)$")
def commands(tokens):
    cur, skip = [], False
    for ti, t in enumerate(tokens):
        if skip: skip = False; continue          # the operand of a redirection (quoted or not) is not an argument
        if REDIROP.match(t): skip = True; continue
        if t.isdigit() and ti + 1 < len(tokens) and REDIROP.match(tokens[ti + 1]): continue   # the fd of `2> file`
        if t in OPS:
            if cur: yield [unq(x) for x in cur]
            cur = []
            if t == "(": yield ["__PUSH__"]
            elif t == ")": yield ["__POP__"]
        else:
            cur.append(t)
    if cur: yield [unq(x) for x in cur]

NOTES, ACTIONS = [], []   # ACTIONS: dicts {kind, argv, cwd, gitopts}
state = {"cwd": CWD0, "cwd_known": True}

def expand(p):
    if p.startswith("~"): p = HOME + p[1:]
    return p

def do_cd(argv):
    args = [a for a in argv[1:] if not a.startswith("-") or a == "-"]
    if not args: state["cwd"] = HOME; return
    p = args[0]
    if "$" in p or "`" in p or p == "-":
        state["cwd_known"] = False; return
    state["cwd"] = os.path.normpath(os.path.join(state["cwd"], expand(p)))

SCOPES = []
UNPARSED = []
# State-changing git commands earlier in the same command are NOT simulated (every simulated predecessor opens
# the next gap): a push to a PUBLIC repository after one of them asks to be run in a separate call, where the
# full scan applies. `commit && push` chains to public repos therefore always prompt, by design.
STATE_VERBS = {"add", "commit", "stash", "checkout", "switch", "restore", "reset", "merge", "rebase", "pull", "cherry-pick", "am", "revert", "mv", "r" + "m", "tag", "apply", "clean", "fast-import", "commit-tree", "filter-branch", "replace", "update-ref", "symbolic-ref"}
PRE = {"mutators": [], "retarget": [], "ghdefault": []}
PERSIST, INHERIT = {}, [{}]   # exported / bare GH_REPO= selections persist in the shell; a child shell inherits the command's
ENVSEL = {}   # inline GH_REPO= / GH_HOST= selections, which gh honours (the override variable is NOT honoured inline)
def note_assign(a):
    if a.startswith("MEGAVIBE_ALLOW_PUBLIC_PUSH="):
        NOTES.append("an inline MEGAVIBE_ALLOW_PUBLIC_PUSH assignment in the command is ignored: only the session's launch environment counts")
    elif a.startswith(("GH_REPO=", "GH_HOST=", "GIT_DIR=", "GIT_WORK_TREE=")):
        ENVSEL[a.split("=", 1)[0]] = a.split("=", 1)[1]
NCMD = [0]   # commands seen in this call: a file read before a call that has several may be written by one of them
def scan_argv(argv, depth=0):
    if depth > 3 or not argv: return
    ENVSEL.clear(); ENVSEL.update(PERSIST); ENVSEL.update(INHERIT[-1])
    if argv == ["__PUSH__"]: SCOPES.append((state["cwd"], state["cwd_known"], dict(PERSIST))); return   # a subshell's cd must not leak out
    if argv == ["__POP__"]:
        if SCOPES:
            state["cwd"], state["cwd_known"], _p = SCOPES.pop()
            PERSIST.clear(); PERSIST.update(_p)
        return
    hd = [int(HDTOK.fullmatch(a).group(1)) for a in argv if HDTOK.fullmatch(a)]   # heredocs this command reads
    argv = [a for a in argv if not HDTOK.fullmatch(a)]
    if not argv: return
    NCMD[0] += 1
    i, via_xargs = 0, False
    while i < len(argv):
        a = argv[i]; b = os.path.basename(a)
        if ASSIGN.match(a):
            note_assign(a)
            i += 1; continue
        if a in KEYWORDS: i += 1; continue
        if b in WRAP:
            if b == "xargs": via_xargs = True
            i += 1
            while i < len(argv) and argv[i].startswith("-") and argv[i] != "-":
                opt = argv[i]; i += 1
                if opt == "--": break
                if opt in WRAP[b] and i < len(argv): i += 1
            while i < len(argv) and ASSIGN.match(argv[i]):
                note_assign(argv[i])
                i += 1
            if b in ("timeout", "gtimeout") and i < len(argv) and re.match(r"^[0-9.]+[smhd]?$", argv[i]): i += 1
            continue
        break
    if i >= len(argv):   # a bare assignment statement: GH_REPO=x; then the command
        for a in argv:
            if ASSIGN.match(a) and a.startswith(("GH_REPO=", "GH_HOST=", "GIT_DIR=", "GIT_WORK_TREE=")): PERSIST[a.split("=", 1)[0]] = a.split("=", 1)[1]
        return
    argv = argv[i:]
    base = os.path.basename(argv[0])
    if base == "unset":
        for a in argv[1:]: PERSIST.pop(a, None)
        return
    if base in ("export", "declare", "typeset", "set") and len(argv) > 1:
        for a in argv[1:]:
            if a.startswith(("GH_REPO=", "GH_HOST=", "GIT_DIR=", "GIT_WORK_TREE=")): PERSIST[a.split("=", 1)[0]] = a.split("=", 1)[1]
        return
    if base in SHELLS:
        for j, a in enumerate(argv[1:], 1):
            if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) and j + 1 < len(argv):
                t = split_tokens(nl_sep(strip_comments(argv[j + 1])))
                if t is None:
                    if GITPUSH.search(argv[j + 1]): UNPARSED.append(argv[j + 1])
                    return
                saved = (state["cwd"], state["cwd_known"], len(SCOPES), dict(PERSIST))
                INHERIT.append(dict(ENVSEL))
                try:
                    for c in commands(t): scan_argv(c, depth + 1)
                    scan_substs(argv[j + 1], depth + 1)
                finally: INHERIT.pop()
                state["cwd"], state["cwd_known"] = saved[0], saved[1]; del SCOPES[saved[2]:]; PERSIST.clear(); PERSIST.update(saved[3])   # a child shell's cd does not persist
                return
        return
    if base in ("pushd", "popd"):
        state["cwd_known"] = False; return   # the directory stack is not modelled: unknown directory + public-capable push asks
    if base == "cd":
        do_cd(argv); return
    if base == "git":
        gitopts, k = [], 1
        cwd = state["cwd"]
        dir_known = state["cwd_known"]
        while k < len(argv) and argv[k].startswith("-"):
            o = argv[k]
            if len(o) > 2 and o[:2] == "-C" and not o.startswith("--"):
                if "$" in o or "`" in o: dir_known = False
                cwd = os.path.normpath(os.path.join(cwd, expand(o[2:]))); k += 1; continue
            if len(o) > 2 and o[:2] == "-c" and not o.startswith("--"):
                gitopts += ["-c", o[2:]]; k += 1; continue
            if o in ("-C",) and k + 1 < len(argv):
                if "$" in argv[k + 1] or "`" in argv[k + 1]: dir_known = False
                cwd = os.path.normpath(os.path.join(cwd, expand(argv[k + 1]))); k += 2; continue
            if o in ("-c", "--git-dir", "--work-tree", "--namespace", "--exec-path") and k + 1 < len(argv):
                if o in ("--git-dir", "--work-tree") and ("$" in argv[k + 1] or "`" in argv[k + 1]): dir_known = False   # cannot be resolved statically
                gitopts += [o, argv[k + 1]]; k += 2; continue
            if o.startswith("--git-dir=") or o.startswith("--work-tree="):
                if "$" in o or "`" in o: dir_known = False
                gitopts.append(o)
            k += 1
        _verb = argv[k] if k < len(argv) else ""
        if _verb == "remote" and len(argv) > k + 1 and argv[k + 1] in ("add", "set-url", "rename", "remove", "r" + "m", "set-head"):
            PRE["retarget"].append("remote " + argv[k + 1])   # changes where the push goes
        elif _verb == "config" and len(argv) > k + 1 and not any(a in ("--get", "--get-all", "--get-regexp", "--list", "-l") for a in argv[k + 1:]):
            PRE["retarget"].append("config")
        elif _verb == "branch" and any(not a.startswith("-") for a in argv[k + 1:]):
            PRE["mutators"].append("branch")
        elif _verb == "worktree" and len(argv) > k + 1 and argv[k + 1] == "add":
            PRE["mutators"].append("worktree add")   # creates a directory and a branch a later push in this call may use
        elif _verb in STATE_VERBS:
            PRE["mutators"].append(_verb)   # changes what would be pushed: not simulated, see below
        if k < len(argv) and argv[k] == "push":
            for _v in ("GIT_DIR", "GIT_WORK_TREE"):   # inline repository selectors, which git honours
                if ENVSEL.get(_v) and ("$" in ENVSEL[_v] or "`" in ENVSEL[_v]): dir_known = False   # ... but not one this hook can resolve
                if ENVSEL.get(_v): gitopts.append("--%s=%s" % (_v.lower().replace("_", "-"), os.path.join(cwd, expand(ENVSEL[_v]))))
            ACTIONS.append({"kind": "push", "argv": argv[k + 1:], "cwd": cwd, "gitopts": gitopts, "known": dir_known, "pre": {"mutators": list(PRE["mutators"]), "retarget": list(PRE["retarget"])}})
        return
    if base == "gh":
        rest = [x for x in argv[1:]]
        g = gh_parse(rest)
        if g is None: return
        key, vals, pos = g
        if key == "repo set-default":
            PRE["ghdefault"].append(key); return
        if key in ("repo create", "repo edit"):
            ACTIONS.append({"kind": "repo-" + key.split()[1], "argv": rest, "cwd": state["cwd"], "gitopts": [], "known": state["cwd_known"]})
        elif key in GH_SPEC:
            ACTIONS.append({"kind": "text", "key": key, "vals": vals, "pos": pos, "hd": hd, "xargs": via_xargs, "cwd": state["cwd"], "gitopts": [], "known": state["cwd_known"], "env": dict(ENVSEL), "pre": {"mutators": list(PRE["mutators"]), "retarget": list(PRE["retarget"]), "ghdefault": list(PRE["ghdefault"])}})

# ---- gh commands that publish text: value-taking options per command ("short/long"; every other option is a switch) ----
_GH_COMMON = "R/repo"
GH_SWITCH = {"pr create": {"-f": "--fill", "-e": "--editor", "-w": "--web", "-d": "--draft"},
             "issue create": {"-e": "--editor", "-w": "--web"}, "pr comment": {"-e": "--editor", "-w": "--web"},
             "issue comment": {"-e": "--editor", "-w": "--web"}}
GH_SPEC = {
    "pr create": "t/title b/body F/body-file B/base H/head a/assignee l/label m/milestone p/project r/reviewer T/template /recover",
    "pr edit": "t/title b/body F/body-file B/base /add-assignee /remove-assignee /add-label /remove-label /add-project /remove-project /add-reviewer /remove-reviewer m/milestone",
    "pr comment": "b/body F/body-file", "pr review": "b/body F/body-file",
    "pr merge": "t/subject b/body F/body-file A/author-email /match-head-commit",
    "pr close": "c/comment", "pr reopen": "c/comment",
    "issue create": "t/title b/body F/body-file a/assignee l/label m/milestone p/project T/template /recover",
    "issue edit": "t/title b/body F/body-file /add-assignee /remove-assignee /add-label /remove-label /add-project /remove-project m/milestone",
    "issue comment": "b/body F/body-file", "issue close": "c/comment r/reason", "issue reopen": "c/comment",
    "release create": "t/title n/notes F/notes-file /target /discussion-category /notes-start-tag",
    "release edit": "t/title n/notes F/notes-file /tag /target /discussion-category",
    "api": "X/method f/raw-field F/field H/header /input q/jq t/template /hostname /cache p/preview",
}
# what each published option carries: a literal text, or a file (or - for standard input)
GH_TEXT = {"--title": "title", "--subject": "title", "--body": "body", "--notes": "notes", "--comment": "comment"}
GH_FILE = {"--body-file": "body file", "--notes-file": "notes file", "--template": "template"}
def _spec(key):
    short, longs = {}, set()
    for pair in (GH_SPEC[key] + " " + _GH_COMMON).split():
        s, l = pair.split("/")
        longs.add("--" + l)
        if s: short["-" + s] = "--" + l
    return short, longs
def gh_parse(rest):
    """-> (key, {long option: [values]}, positional) for gh <group> <verb> ..., or None. A value keeps its W (dyn) flag."""
    words, skip = [], False
    for k, x in enumerate(rest):   # the command words: the first non-option words, an -R/--repo value skipped
        if skip: skip = False; continue
        if x in ("-R", "--repo"): skip = True; continue
        if not x.startswith("-"):
            words.append(k)
            if len(words) == 2 or (len(words) == 1 and x == "api"): break
    if not words: return None
    key = " ".join(rest[k] for k in words)
    if key == "repo set-default": return key, {}, []
    if key not in GH_SPEC and key not in ("repo create", "repo edit"): return None
    if key not in GH_SPEC: return key, {}, []
    short, longs = _spec(key)
    args = [x for k, x in enumerate(rest) if k not in words]
    vals, pos, i = {}, [], 0
    def put(k, v): vals.setdefault(k, []).append(v)
    while i < len(args):
        a = args[i]
        if a == "--": pos += args[i + 1:]; break
        if a.startswith("--"):
            if "=" in a:
                k, v = a.split("=", 1); put(k, word(v, getattr(a, "dyn", False))); i += 1; continue
            if a in longs and i + 1 < len(args): put(a, args[i + 1]); i += 2; continue
            if getattr(a, "dyn", False): put("__dyn__", a)
            put(a, True); i += 1; continue
        if a.startswith("-") and len(a) > 1:
            f = a[:2]
            if f in short:
                if len(a) > 2: put(short[f], word(a[2:][1:] if a[2] == "=" else a[2:], getattr(a, "dyn", False))); i += 1
                elif i + 1 < len(args): put(short[f], args[i + 1]); i += 2
                else: i += 1
                continue
            i += 1
            for j, ch in enumerate(a[1:], 1):   # a bundle (-wb TEXT): switches until a value-taking option, which takes the rest or the next word
                if "-" + ch in short:
                    rest_ = a[j + 1:]
                    if rest_: put(short["-" + ch], word(rest_[1:] if rest_[0] == "=" else rest_, getattr(a, "dyn", False)))
                    elif i < len(args): put(short["-" + ch], args[i]); i += 1
                    break
                put(GH_SWITCH.get(key, {}).get("-" + ch, "-" + ch), True)
            continue
        if getattr(a, "dyn", False): put("__dyn__", a)   # $B may expand to an option: which text it carries is unknown
        pos.append(a); i += 1
    return key, vals, pos

_GHPUB = (r"\bgh\s+(?:pr\s+(?:create|edit|comment|review|merge|close|reopen)|issue\s+(?:create|edit|comment|close|reopen)|release\s+(?:create|edit)|repo\s+(?:create|edit))\b"
          r"|\bgh\s+api\s+(?!graphql\b)[^)`]*?(?:\s-[fF]\s|\s-[fF]\S|--(?:raw-)?field\b|--input\b)|\bgh\s+api\b[^)`]*?(?:-X\s*|--method[\s=])(?:POST|PATCH|PUT)\b|\bgh\s+api\s+graphql\b[^)`]*?mutation")
GITPUSH = re.compile(r"\bgit\b(?:\s+-\S+(?:\s+\S+)?)*\s+push\b|" + _GHPUB)
SUBSTS_LEFT = []
def subst_spans(text, quotes=True):
    """inner text of each outermost $( ), <( ), >( ) outside single quotes; None when one is unbalanced.
    quotes=False: a heredoc body, where quote characters are plain text"""
    out, i, n, q = [], 0, len(text), None
    while i < n:
        c = text[i]
        if q == "'":
            if c == "'": q = None
            i += 1; continue
        if c == "\\": i += 2; continue
        if quotes and c == '"': q = None if q == '"' else '"'; i += 1; continue
        if quotes and c == "'" and q is None: q = "'"; i += 1; continue
        if text[i + 1:i + 2] == "(" and (c == "$" or (quotes and c in "<>" and q is None)):
            j = match_close(text, i + 2)
            if j < 0: return None
            out.append(text[i + 2:j]); i = j + 1; continue
        i += 1
    return out
def scan_substs(text, depth=1, quotes=True):
    if depth > 3:
        if GITPUSH.search(text): SUBSTS_LEFT.append(1)   # nested deeper than this guard follows: ask, never pass
        return
    spans = subst_spans(text, quotes)
    if spans is None:
        if GITPUSH.search(text): SUBSTS_LEFT.append(1)
        return
    for inner in spans:
        if not GITPUSH.search(inner): continue
        t = split_tokens(nl_sep(strip_comments(inner)))
        if t is None: SUBSTS_LEFT.append(1); continue
        saved = (state["cwd"], state["cwd_known"], len(SCOPES), dict(PERSIST))   # a substitution runs in a subshell
        for c in commands(t): scan_argv(c, depth)
        state["cwd"], state["cwd_known"] = saved[0], saved[1]; del SCOPES[saved[2]:]; PERSIST.clear(); PERSIST.update(saved[3])
        scan_substs(inner, depth + 1)
toks = split_tokens(TEXT)
if toks is None:
    # the text cannot be tokenised (an unclosed quote, say): do not let that hide a push
    if GITPUSH.search(TEXT) or GITPUSH.search(CMD): ask(["this command mentions a push or a public-repository operation but could not be parsed (unbalanced quotes?), so its target was not checked."])
    sys.exit(0)
for c in commands(toks):
    scan_argv(c)
scan_substs(TEXT)
for _b in BODIES:   # an unquoted heredoc body runs its substitutions too
    if not _b["literal"]: scan_substs("\n".join(_b["lines"]), 1, quotes=False)
if SUBSTS_LEFT:
    ask(["a push or public-repository operation sits inside a command substitution this guard could not parse, so its target was not checked."])
if UNPARSED:
    ask(["a nested shell command mentions a push or a public-repository operation but could not be parsed, so its target was not checked."])
# a substitution or an eval that holds a push; `eval` only where a command starts, and never text in single quotes
# (a commit message or a comment body that mentions `git push` publishes nothing)
SUBST = re.compile(r"(?:\$\(|`|(?:^|[;&|(])\s*eval\b)[^)`]*(?:" + GITPUSH.pattern + ")")
_BL = _scan(TEXT, blank_single=True)
def dq_substs(bl):
    """(start, end) of each $( ... ) inside double quotes in bl (single-quoted text blanked); None when unbalanced"""
    spans, i, n, inq = [], 0, len(bl), False
    while i < n:
        c = bl[i]
        if c == "\\": i += 2; continue
        if c == '"': inq = not inq; i += 1; continue
        if inq and bl.startswith("$(", i):
            d, j = 0, i + 2
            while j < n and not (bl[j] == ")" and d == 0):
                if bl[j] == "\\": j += 2; continue
                if bl[j] == '"':   # a quoted string inside the substitution: its parentheses do not count
                    j += 1
                    while j < n and bl[j] != '"': j += 2 if bl[j] == "\\" else 1
                    j += 1; continue
                d += (bl[j] == "(") - (bl[j] == ")"); j += 1
            if j >= n: return None
            spans.append((i + 2, j)); i = j + 1; continue
        i += 1
    return spans
_DQ_LEFT = False
if dq_substs(_BL) is None and GITPUSH.search(_BL): _DQ_LEFT = True
if any(q.startswith('"') and "`" in q and SUBST.search(q) for q in _QUOTED.findall(_BL)): _DQ_LEFT = True   # a backtick inside double quotes is not parsed
if (not ACTIONS and SUBST.search(_BL)) or _DQ_LEFT or any(not m.group(0).startswith("$(") for m in SUBST.finditer(_BL)):
    ask(["a push or public-repository operation sits inside a command substitution or eval, which this guard does not parse: its target was not checked."])
if not ACTIONS:
    sys.exit(0)

# ---- helpers: git / gh ----
# no git call of ours may reach the network or write objects: a partial clone would otherwise lazy-fetch a missing blob
SAFE_ENV = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
def run(cmd, cwd=None, timeout=10, env=None, err=False):
    """-> (rc, stdout) or with err=True (rc, stdout, stderr). The child gets its own process group, which is killed
    on a timeout: a grandchild (a credential helper) holding the pipe would otherwise make the limit unbounded."""
    def _r(rc, o=b"", e=b""):
        o = o.decode("utf-8", "replace")
        return (rc, o, e.decode("utf-8", "replace")) if err else (rc, o)
    try:
        p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env or SAFE_ENV, start_new_session=True)
    except Exception:
        return _r(127)
    try:
        o, e = p.communicate(timeout=timeout)
        return _r(p.returncode, o, e)
    except subprocess.TimeoutExpired:
        try: os.killpg(p.pid, 9)
        except OSError: pass
        try: p.communicate(timeout=2)
        except Exception: pass
        return _r(124)
    except Exception:
        return _r(127)

def is_regular(path):   # a FIFO or device at a config/cache path would block the hook on open
    try: return stat.S_ISREG(os.stat(path).st_mode)
    except OSError: return False

NOEXEC = ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "log.showSignature=false", "-c", "diff.external=", "-c", "core.pager=cat", "-c", "diff.relative=false", "-c", "log.showRoot=true"]   # a configured fsmonitor program would run on status/diff
def git(act, *a, timeout=10):
    return run(["git"] + act["gitopts"] + NOEXEC + list(a), cwd=act["cwd"] if os.path.isdir(act["cwd"]) else None, timeout=timeout)

def read_lines(path):
    if not is_regular(path): return []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return [l.rstrip("\n") for l in f]
    except OSError:
        return []

def is_trusted(slug):   # slug: host/owner/repo
    for l in read_lines(os.path.join(PERSONAL, "public-push.trusted")):
        l = l.strip()
        if l and not l.startswith("#") and fnmatch.fnmatch(slug.lower(), l.lower()):
            return True
    return False

def known_public(slug):   # slug: host/owner/repo. The repositories the user EXPECTS to be public.
    for l in read_lines(os.path.join(PERSONAL, "public-push.known-public")):
        l = l.strip()
        if l and not l.startswith("#") and fnmatch.fnmatch(slug.lower(), l.lower()):
            return True
    return False

def not_expected(slug):
    return ("%s is PUBLIC and is not on your list of repositories you expect to be public. Approve only if publishing there is "
            "intended. To stop this question for that repository, the human adds the line `%s` to ~/.megavibe/personal/public-push.known-public." % (slug, slug.lower()))

def stale_tracking(act, host, nwo, revargs, remote):
    """True when a commit the scan would treat as already published (a boundary of the outgoing range, taken from the
    local tracking refs of <remote>) is definitely not in the destination: the refs describe another repository, as
    after a `git remote set-url`. Anything but a definite "not found" (offline, rate limit) keeps the old behaviour."""
    rc, o = git(act, "rev-list", "--boundary", "--max-count=%d" % (MAX_COMMITS + 1), *(revargs + ["--not", "--remotes=" + remote]))
    if rc != 0: return False
    bounds = [l[1:] for l in o.split() if l.startswith("-")][:5]   # SHORTCUT: the first five boundaries; a range with more (many merged bases) is checked in part
    if not [l for l in o.split() if not l.startswith("-")]:
        # nothing outgoing: the tracking refs hide the whole push, so there is no boundary. Check the pushed tips themselves
        # (named revisions only; SHORTCUT: a selector such as --branches is not expanded here).
        for r in [r for r in revargs if not r.startswith("--")][:5]:
            rc, t = git(act, "rev-parse", "--verify", "-q", r + "^{commit}")
            if rc == 0 and t.strip(): bounds.append(t.strip())
    env = dict(os.environ); env["GH_HOST"] = host; env["GH_PROMPT_DISABLED"] = "1"
    deadline = time.time() + 12   # one budget for all lookups: a slow GitHub must not add a minute to a push
    for b in bounds:
        left = deadline - time.time()
        if left < 1: break
        rc, _o, e = run(["gh", "api", "repos/%s/git/commits/%s" % (nwo, b), "--jq", ".sha"], timeout=left, env=env, err=True)
        if rc != 0 and re.search(r"HTTP (404|422)", e): return True
    return False

URL_RES = [
    re.compile(r"^(?:ssh|git\+ssh|git|https?)://(?:[^@/]+@)?(?P<host>[^/:]+)(?::\d+)?/(?P<path>.+)$"),
    re.compile(r"^(?:[^@/:]+@)?(?P<host>[^/:@]+):(?P<path>[^/].*)$"),
]
def parse_url(u):
    if u.startswith("file://") or u.startswith("/") or u.startswith(".") or u.startswith("~"):
        return None
    for r in URL_RES:
        m = r.match(u)
        if m:
            path = m.group("path").strip("/")
            if path.endswith(".git"): path = path[:-4]
            parts = path.split("/")
            return m.group("host").lower(), parts
    return None

GH_HOSTS = {"github.com"} | {h.lower() for h in os.environ.get("MEGAVIBE_GITHUB_HOSTS", "").split()}
if os.environ.get("GH_HOST"): GH_HOSTS.add(os.environ["GH_HOST"].lower())

def resolve_alias(host):
    """an ssh alias -> its HostName, read from ~/.ssh/config as text: `ssh -G` would run Match exec commands"""
    if host in GH_HOSTS: return host
    cur, ok = False, False
    for l in read_lines(os.path.join(HOME, ".ssh", "config")):
        w = l.split("#", 1)[0].split()
        if not w: continue
        key = w[0].lower().rstrip("=")
        if key == "host": cur = host in w[1:]; continue
        if key == "match": cur = False; continue
        if cur and key in ("hostname",) and len(w) > 1:
            h = w[1].lstrip("=").lower()
            if h in GH_HOSTS: return h
    return host

def gh_visibility(host, nwo, cwd=None):
    """returns (VIS|None, nameWithOwner|None)"""
    cache = None
    if nwo:
        key = host + "/" + nwo.lower()
        cache = os.path.join(CACHE_DIR, hashlib.sha1(key.encode()).hexdigest())
        try:
            if is_regular(cache) and time.time() - os.path.getmtime(cache) < TTL:
                v = open(cache).read().strip()
                if v in ("PUBLIC", "PRIVATE", "INTERNAL"): return v, nwo
        except OSError:
            pass
    env = dict(os.environ); env["GH_HOST"] = host; env["GH_PROMPT_DISABLED"] = "1"
    cmd = ["gh", "repo", "view"] + ([nwo] if nwo else []) + ["--json", "visibility,nameWithOwner"]
    rc, o = run(cmd, cwd=cwd if cwd and os.path.isdir(cwd) else None, timeout=12, env=env)
    if rc != 0: return None, None
    try:
        j = json.loads(o); v = str(j.get("visibility", "")).upper()
    except Exception:
        return None, None
    if v not in ("PUBLIC", "PRIVATE", "INTERNAL"): return None, None
    if cache:
        try:
            os.makedirs(CACHE_DIR, exist_ok=True)
            if not os.path.lexists(cache) or is_regular(cache):
                with open(cache, "w") as f: f.write(v)
        except OSError:
            pass
    return v, j.get("nameWithOwner")

# ---- scanning ----
SECRET_RES = [
    ("private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY")),
    ("AWS key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})")),
    ("Slack token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}")),
    ("API key (sk-)", re.compile(r"\bsk-(?:ant-)?[A-Za-z0-9_-]{32,}")),
    ("Google key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
    ("Stripe live key", re.compile(r"\b[sr]k_live_[A-Za-z0-9]{16,}")),
    ("GitLab token", re.compile(r"\bglpat-[A-Za-z0-9_-]{15,}")),
]
# the same placeholder convention scripts/leak-scan.sh uses: a line that says it is an example is not a secret
PLACEHOLDER = re.compile(r"example|placeholder|your-|YOUR_|xxx|changeme|redacted|dummy", re.I)
HOMEPATH = re.compile(r"(?<![A-Za-z0-9_])/(?:Users|home)/([A-Za-z0-9][A-Za-z0-9._-]*)/")
PLACEHOLDER_USERS = {"user","username","you","your","yourname","your-name","name","me","example","alice","bob","jane",
    "john","foo","bar","runner","ubuntu","vscode","node","shared","guest","someone","test","dev","admin","jdoe","x","u",
    "yourusername","your_name","your-username","myuser","myname","owner","agent","claude","app","nobody","git","ci","build"}
REAL_USER = os.path.basename(HOME.rstrip("/")).lower()
EMAIL = re.compile(r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
TRAILER = re.compile(r"^\s*[A-Za-z][A-Za-z-]*-by:", re.I)
DEFAULT_EMAIL_ALLOW = ["git@*", "*@users.noreply.github.com", "noreply@*", "no-reply@*", "*@example.com", "*@example.org",
                       "*@example.net", "*@localhost", "*@*.example", "*@*.invalid", "*@*.test"]

# built-in, no configuration: a link back to a Claude Code session and the session trailer of a commit message
BUILTIN_RES = [
    ("session link", re.compile(r"claude\.ai/code/session_[A-Za-z0-9_-]{4,}", re.I)),
    ("Claude-Session trailer", re.compile(r"^\s*Claude-Session\s*:", re.I)),
]
BUILTIN_FIX = ("On a public repository the session link and the Claude-Session trailer are left out (Co-authored-by alone is fine; "
               "private repositories keep them).")

def load_deny():
    items, bad = [], []
    for n, l in enumerate(read_lines(os.path.join(PERSONAL, "public-push.deny")), 1):
        s = l.strip()
        if not s or s.startswith("#"): continue
        if len(s) >= 3 and s.startswith("/") and s.endswith("/"):
            try: items.append((n, re.compile(s[1:-1], re.I)))
            except re.error: bad.append(n)
        else:
            items.append((n, re.compile(re.escape(s), re.I)))
    return items, bad

def redact(t):
    for _k, rx in SECRET_RES: t = rx.sub(lambda m: m.group(0)[:4] + "…", t)
    return t

def trunc(s, n=16):
    s = s.replace("\n", " ")
    return s if len(s) <= n else s[:n] + "…"

class ScanFailed(Exception): pass

def run_capped(cmd, cwd, cap, timeout=60):
    """stdout up to cap+1 bytes, then the process is killed; raises ScanFailed on error/timeout"""
    try:
        p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=SAFE_ENV)
    except Exception:
        raise ScanFailed()
    import threading
    t = threading.Timer(timeout, p.kill); t.start()
    try:
        data = p.stdout.read(cap + 1)
        if len(data) > cap: p.kill()
        p.wait()
    finally:
        t.cancel()
    if len(data) <= cap and p.returncode != 0: raise ScanFailed()
    return data

class Scanner:
    def __init__(self, extra_emails):
        self.hits = []
        self.total = 0
        self.deny, self.bad_deny = load_deny()
        self.email_allow = DEFAULT_EMAIL_ALLOW + [l.strip() for l in read_lines(os.path.join(PERSONAL, "public-push.allow-email"))
                                                  if l.strip() and not l.strip().startswith("#")]
        self.emails = {e.lower() for e in extra_emails if e}
        self.fatal = []   # built-in rules: never intended on a public repository, so the caller denies instead of asking
    def hit(self, loc, kind, val):
        for _k, rx in SECRET_RES:   # a file name or a matched denylist value can carry a secret
            loc = rx.sub(lambda m: m.group(0)[:4] + "…", loc); val = rx.sub(lambda m: m.group(0)[:4] + "…", val)
        self.total += 1
        if len(self.hits) < MAX_HITS: self.hits.append("  %s  [%s] %s" % (loc, kind, val))
    def line(self, loc, text, trailer_ok=False, path_only=False, builtin=False):
        if builtin:   # messages and published texts: the session link and the session trailer, whatever else the line says
            for kind, rx in BUILTIN_RES:
                if rx.search(text):
                    self.fatal.append("%s (%s)" % (kind, loc)); self.hit(loc, kind, trunc(rx.search(text).group(0), 28))
        if "EXAMPLE" in text:   # an explicit uppercase marker: the line says it is an example (the leak-scan convention); only the denylist still applies
            for n, rx in self.deny:
                m = rx.search(text)
                if m: self.hit(loc, "denylist #%d" % n, trunc(redact(m.group(0))))
            return
        if True:
            for kind, rx in SECRET_RES:
                m = rx.search(text)
                if m and not PLACEHOLDER.search(text): self.hit(loc, kind, m.group(0)[:4] + "…")
            for m in ([] if path_only else HOMEPATH.finditer(text)):
                u = m.group(1).lower()
                if u == REAL_USER or u not in PLACEHOLDER_USERS:
                    self.hit(loc, "home path", trunc(m.group(0), 18)); break
            if not (trailer_ok and TRAILER.match(text)):
                for m in EMAIL.finditer(text):
                    e = m.group(0).lower()
                    if e in self.emails or any(fnmatch.fnmatch(e, g.lower()) for g in self.email_allow): continue
                    self.hit(loc, "email", trunc(e)); break
        for n, rx in self.deny:
            m = rx.search(text)
            if m: self.hit(loc, "denylist #%d" % n, trunc(redact(m.group(0))))   # redact BEFORE truncating: a cut token no longer matches

def scan_range(act, revargs, remote, notall=False):
    """revargs: list of rev-list args selecting tips. Returns (hits_lines, total, truncated)."""
    # a source that does not resolve cannot be pushed (git itself will fail): skip it
    def _resolves(r):
        rc_ = git(act, "rev-parse", "--verify", "-q", r + "^{commit}")[0]
        if rc_ not in (0, 1): raise ScanFailed()   # -q gives 1 for a revision that does not exist; anything else is git failing or timing out
        return rc_ == 0
    revargs = [r for r in revargs if r.startswith("--") or _resolves(r)]
    if not revargs: return [], 0, False, None
    base = ["rev-list", "--max-count=%d" % (MAX_COMMITS + 1)] + revargs
    if remote: base += ["--not", "--remotes=" + remote]
    elif notall: base += ["--not", "--remotes"]   # what no remote ref holds, whichever remote a tool pushes to
    rc, o = git(act, *base)
    if rc != 0: raise ScanFailed()   # a resolvable ref whose walk fails is not a clean scan
    shas = o.split()
    truncated = len(shas) > MAX_COMMITS
    shas = shas[:MAX_COMMITS]
    if not shas: return [], 0, False, None
    # authors and committers are published with the commits anyway
    rc, ae = git(act, "log", "--no-walk=unsorted", "--format=%ae%n%ce", *shas)
    _, ue = git(act, "config", "user.email")
    sc = Scanner(ae.split() + ue.split())
    cwd = act["cwd"] if os.path.isdir(act["cwd"]) else None
    # changed paths straight from git, NUL-delimited: patch headers quote odd names and vary with diff.noprefix
    names = run_capped(["git"] + act["gitopts"] + NOEXEC + ["log", "--no-walk=unsorted", "--root", "-z", "--name-only", "--no-renames", "--format=" + M1 + "%h"] + shas, cwd, MAX_BYTES).decode("utf-8", "replace")
    csha = ""
    for tok in names.split("\0"):
        tok = tok.strip("\n")
        if not tok: continue
        if tok.startswith(M1): csha = tok[len(M1):]; continue
        sc.line("commit %s path %s" % (csha, trunc(redact(tok), 40)), tok, path_only=True)
    data = run_capped(["git"] + act["gitopts"] + NOEXEC + ["log", "--no-walk=unsorted", "--root", "--no-renames", "--no-color", "--no-textconv", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "-p", "-U0",
                      "--format=" + M1 + "%h%n%B" + M2] + shas, cwd, MAX_BYTES)
    if len(data) > MAX_BYTES: truncated = True; data = data[:MAX_BYTES]
    o = data.decode("utf-8", "replace")
    sha, mode, path, ln, inhunk = "", "", "", 0, False
    for raw in o.split("\n"):
        if raw.startswith(M1):
            sha = raw[len(M1):]; mode = "msg"; continue
        if mode == "msg":
            if raw.endswith(M2):
                body = raw[:-len(M2)]
                if body: sc.line("commit %s message" % sha, body, True, builtin=True)
                mode = "diff"; inhunk = False; continue
            sc.line("commit %s message" % sha, raw, True, builtin=True)
            continue
        if raw.startswith("diff --git "):   # content lines always carry a +/-/space prefix, so this is a header
            inhunk = False
            m = re.match(r"diff --git a/(.*?) b/(.*)$", raw)
            path = m.group(2) if m else ""
            continue
        if not inhunk and raw.startswith("+++ "):
            p = raw[4:]; path = p[2:] if p.startswith("b/") else path; continue
        if raw.startswith("@@"):
            inhunk = True
            m = re.search(r"\+(\d+)", raw); ln = int(m.group(1)) - 1 if m else 0; continue
        if inhunk and raw.startswith("+"):
            ln += 1
            sc.line("%s:%d (%s)" % (trunc(redact(path), 60), ln, sha), raw[1:])
        elif raw.startswith(" ") or raw.startswith("-"):
            if raw.startswith(" "): ln += 1
    return sc.hits, sc.total, truncated, sc

def report_hits(title, hits, total, truncated, sc, extra=()):
    lines = [title]
    lines += hits
    if total > len(hits): lines.append("  … and %d more hits" % (total - len(hits)))
    if truncated: lines.append("  the scan was truncated (more than %d outgoing commits or %d MB of diff): not everything was read" % (MAX_COMMITS, MAX_BYTES // 1048576))
    if sc is not None and sc.bad_deny: lines.append("  denylist lines with an invalid regex were skipped: " + ", ".join(map(str, sc.bad_deny)))
    lines += list(extra)
    return lines

# ---- per action ----
def push_revs(argv):
    """-> (remote_arg|None, revargs list, skip_all) from git push args"""
    pos, flags, i = [], set(), 0
    valued = {"--repo", "-o", "--push-option", "--receive-pack", "--exec", "--force-with-lease", "--signed", "--recurse-submodules"}
    repo_opt = None
    while i < len(argv):
        a = argv[i]
        if a == "--":
            pos += argv[i + 1:]; break
        if a.startswith("--repo="): repo_opt = a.split("=", 1)[1]; i += 1; continue
        if a == "--repo" and i + 1 < len(argv): repo_opt = argv[i + 1]; i += 2; continue
        if a.startswith("-") and a != "-":
            if a in ("-o", "--push-option", "--receive-pack", "--exec") and i + 1 < len(argv): i += 2; continue
            if a == "--recurse-submodules" and i + 1 < len(argv) and argv[i + 1] in ("check", "on-demand", "only", "no", "yes"):
                flags.add("--recurse-submodules=" + argv[i + 1]); i += 2; continue
            flags.add(a); i += 1; continue
        pos.append(a); i += 1
    return repo_opt, pos, flags

def rewrite_url(act, u, push=True):
    """git's url.<base>.pushInsteadOf / insteadOf for an explicit URL (longest prefix wins; pushInsteadOf first when pushing)"""
    rc, o = git(act, "config", "--get-regexp", r"^url\..*\.(pushinsteadof|insteadof)$")
    best = {"pushinsteadof": ("", ""), "insteadof": ("", "")}
    for line in o.splitlines():
        key, _, val = line.partition(" ")
        m = re.match(r"^url\.(.*)\.(pushinsteadof|insteadof)$", key, re.I)
        if m and val and u.startswith(val) and len(val) > len(best[m.group(2).lower()][0]):
            best[m.group(2).lower()] = (val, m.group(1))
    for kind in (("pushinsteadof", "insteadof") if push else ("insteadof",)):
        val, base = best[kind]
        if val: return base + u[len(val):]
    return u

def scan_tag_messages(act, refspecs, flags, tips=(), remote=None):
    """messages of the annotated tags a push publishes: named tags, every annotated tag for --tags/--mirror or a
    refs/tags/* refspec, and for --follow-tags/push.followTags those reachable from the pushed tips"""
    names, overflow = [], []
    follow = "--follow-tags" in flags or ("--no-follow-tags" not in flags and git(act, "config", "--bool", "push.followTags")[1].strip() == "true")
    wild = any("refs/tags/" in rs and "*" in rs for rs in refspecs)
    def annotated(*extra):
        rc, o = git(act, "for-each-ref", "--count=5000", "--format=%(objecttype) %(refname)", *extra, "refs/tags")
        if len(o.splitlines()) >= 5000: overflow.append(1)   # more tags than we list: say so instead of passing
        return [l.split(" ", 1)[1] for l in o.splitlines() if l.startswith("tag ")]
    if flags & {"--tags", "--mirror"} or wild:
        names += annotated()
    elif follow:
        for t in tips:
            if t in ("--branches", "--all"):   # expand a selector into the branch tips it stands for
                t_list = [l for l in git(act, "for-each-ref", "--count=200", "--format=%(refname)", "refs/heads")[1].split()]
            else:
                t_list = [t]
            for tt in t_list: names += annotated("--merged=" + tt)
    for rs in refspecs:
        src = rs.lstrip("+").split(":", 1)[0]
        if src and "*" not in src and git(act, "cat-file", "-t", src)[1].strip() == "tag": names.append(src)
    sc = Scanner([git(act, "config", "user.email")[1].strip()])
    for n in dict.fromkeys(names):
        rc, o = git(act, "cat-file", "tag", n)
        body = o.split("\n\n", 1)[1] if "\n\n" in o else ""
        for ln in body.split("\n"): sc.line("tag %s message" % trunc(redact(n.replace("refs/tags/", "")), 30), ln, True, builtin=True)
    if overflow: sc.hit("tags", "tag list", "more than 5000 tags: not all annotations were read")
    return sc.hits, sc.total, sc.fatal

def handle_push(act):
    _flags = push_revs(act["argv"])[2]
    if _flags & {"--dry-run", "-n", "--delete", "-d"}: return None   # publishes nothing, whatever ran before it
    _rec = next((f.split("=", 1)[1] for f in _flags if f.startswith("--recurse-submodules=")), None)
    if _rec is None: _rec = git(act, "config", "--get", "push.recurseSubmodules")[1].strip() or None
    if _rec in ("on-demand", "only") and os.path.exists(os.path.join(act["cwd"], ".gitmodules")):
        return ["this push recurses into submodules (%s), which are separate repositories whose visibility and outgoing commits this guard does not check. Push the submodules in their own calls." % _rec]
    if act["pre"]["retarget"]:
        return retry("An earlier command in this call (git %s) changes where the push goes, so its target was not checked. Run the push in a separate call." % act["pre"]["retarget"][0])
    repo_opt, pos, flags = push_revs(act["argv"])
    if "--branches" in flags: flags.add("--all")   # git's documented alias
    if "--dry-run" in flags or "-n" in flags: return None
    if "--delete" in flags or "-d" in flags: return None
    remote = repo_opt or (pos[0] if pos else None)
    if remote and ("$" in remote or "`" in remote):
        return retry("The push remote %s contains an unexpanded variable or substitution, so the target cannot be resolved. Name the remote literally." % trunc(remote, 30))
    unexpanded = any(("$" in a or "`" in a) for a in pos)
    refspecs = pos[1:] if (pos and not repo_opt) else pos if repo_opt else []
    if not act["known"]:
        return retry("The working directory is not statically known (cd into a variable or substitution, pushd/popd), so the target repository cannot be resolved. Issue the push as its own call with a literal path and without that cd (`git -C /path push ...`).")
    if not os.path.isdir(act["cwd"]):   # never fall back to the hook's own directory: that is another repository
        return retry("The directory this push runs in (%s) does not exist yet; if an earlier command in this call creates it (git worktree add, git clone, mkdir), run that first and the push in a separate call." % trunc(act["cwd"], 60))
    if remote is None:
        _sw = [m for m in act["pre"]["mutators"] if m in ("switch", "checkout")]
        if _sw and len(git(act, "remote")[1].split()) > 1:   # the branch decides the remote, and the branch changes first
            return retry("This call runs `git %s` before a push that names no remote, in a repository with several remotes: which remote the push uses is decided by the branch it ends up on. Run the push in a separate call, or name the remote." % _sw[0])
        _, br = git(act, "symbolic-ref", "--short", "-q", "HEAD"); br = br.strip()
        for key in ([("branch.%s.pushRemote" % br)] if br else []) + ["remote.pushDefault"] + ([("branch.%s.remote" % br)] if br else []):
            rc, v = git(act, "config", "--get", key)
            if rc == 0 and v.strip(): remote = v.strip(); break
        if remote is None:
            names = git(act, "remote")[1].split()
            remote = names[0] if len(names) == 1 else "origin"   # git's own fallback: the sole remote, else origin
    # push URLs
    if parse_url(remote) is not None or remote.startswith(("/", ".", "~", "file://")):
        urls, remote_name = [rewrite_url(act, remote)], None
    else:
        rc, o = git(act, "remote", "get-url", "--push", "--all", remote)
        if rc == 124:
            return ["resolving the push remote timed out, so the push target could not be checked."]
        if rc != 0 or not o.strip():
            rw = rewrite_url(act, remote)   # not a remote name: a url.<base>.insteadOf shorthand ("publish") still reaches a URL
            if rw == remote: return None    # no such remote: git push itself will fail
            urls, remote_name = [rw], None
        else:
            urls, remote_name = [u.strip() for u in o.splitlines() if u.strip()], remote
    if remote_name and not refspecs and git(act, "config", "--bool", "remote.%s.mirror" % remote_name)[1].strip() == "true":
        flags.add("--mirror")
    if not refspecs:
        rc, o = git(act, "config", "--get-all", "remote.%s.push" % remote_name) if remote_name else (1, "")
        if rc == 0 and o.strip(): refspecs = [l.strip() for l in o.splitlines() if l.strip()]   # what git will actually push
        elif git(act, "config", "--get", "push.default")[1].strip() == "matching": refspecs = [":"]   # also for an explicit URL
    # sources
    revargs = []
    for rs in refspecs:
        rs = rs.lstrip("+")
        if rs == ":": revargs.append("--branches"); continue   # the "matching" refspec pushes every branch the remote has
        if rs.startswith(":"): continue
        src = rs.split(":", 1)[0]
        if rs == "tag": continue
        if "*" in src:
            revargs.append("--tags" if src.startswith("refs/tags/") else "--branches" if src.startswith("refs/heads/") else "--all")
        else: revargs.append(src)
    if "--all" in flags or "--mirror" in flags: revargs.append("--branches" if "--mirror" not in flags else "--all")
    if "--tags" in flags: revargs.append("--tags")
    if not revargs and not refspecs: revargs = ["HEAD"]
    if not revargs: return None
    revargs = [r for r in dict.fromkeys(revargs)]
    problems, hit_lines = [], []
    for u in urls:
        pu = parse_url(u)
        if pu is None:
            if u.startswith(("/", ".", "~", "file://")): continue   # local path: not a public host
            problems.append("the push URL %s has a form this guard cannot parse (visibility unknown)." % trunc(u, 40))
            continue
        host, parts = pu
        host = resolve_alias(host)
        slug = host + "/" + "/".join(parts)
        if host not in GH_HOSTS or len(parts) < 2:
            if is_trusted(slug): continue
            problems.append("%s is not a GitHub host this guard can query (visibility unknown). Add it to ~/.megavibe/personal/public-push.trusted if it is private." % host)
            continue
        vis, _ = gh_visibility(host, parts[0] + "/" + parts[1])
        if vis is None:
            if is_trusted(slug): continue   # the trusted file answers only where the lookup cannot: it never overrides a PUBLIC answer
            problems.append("could not determine whether %s is public (gh missing, not logged in, offline or no access)." % slug)
            continue
        if vis != "PUBLIC": continue
        act["public"] = slug   # from here on a failure of this guard asks instead of passing
        if unexpanded:
            return retry("%s is PUBLIC and a refspec contains an unexpanded variable, so which commits go out cannot be known. Name the refs literally." % slug)
        if act["pre"]["mutators"]:
            return retry("%s is PUBLIC and this call runs `git %s` before the push, which changes what would be pushed; this guard does not simulate that. Run the push in a separate call so it can be checked." % (slug, act["pre"]["mutators"][0]))
        if not known_public(slug): problems.append(not_expected(slug))
        fetch_urls = git(act, "remote", "get-url", remote_name)[1].split() if remote_name else []
        # tracking refs describe what the FETCH side holds: use them only when we push to that same place
        _track = remote_name if (remote_name and u in fetch_urls) else None
        if _track and stale_tracking(act, host, parts[0] + "/" + parts[1], revargs, _track):
            problems.append("the local tracking refs of `%s` hold commits that %s does not have (did its URL change since the last fetch?), so they were not used to decide what is already published: every commit that would go out was scanned. `git fetch --prune %s` brings them up to date." % (_track, slug, _track))
            _track = None
        hits, total, trunc_, sc = scan_range(act, revargs, _track)
        if total or trunc_:
            hit_lines += report_hits("%s is PUBLIC and the outgoing commits contain:" % slug, hits, total, trunc_, sc)
        th, tt, tf = scan_tag_messages(act, refspecs, flags, [r for r in revargs if not r.startswith("--") or r in ("--branches", "--all")] or ["HEAD"], _track)
        if tt: hit_lines += report_hits("%s is PUBLIC and the annotated tags being pushed contain:" % slug, th, tt, False, None)
        fatal = (sc.fatal if sc is not None else []) + tf
        holders = {}
        for f in fatal:
            m_ = re.search(r"commit (\S+) message", f)
            if m_:
                h_ = sorted({l.strip().split("/", 1)[0] for l in git(act, "branch", "-r", "--contains", m_.group(1))[1].splitlines() if l.strip()})
                if h_: holders[f] = h_
        on_remote = list(holders)
        fresh = [f for f in fatal if f not in on_remote]
        if fresh:
            return retry("%s is PUBLIC and an outgoing commit or tag message that no remote holds yet contains %s. %s Rewrite those "
                         "messages without it (`git commit --amend` for the last commit, `git rebase` for earlier ones; never rewrite "
                         "commits a remote already has) and push again." % (slug, "; ".join(fresh[:5]), BUILTIN_FIX))
        if on_remote:
            problems.append("%s is PUBLIC and outgoing commits carry a session link or Claude-Session trailer that the remote(s) %s already "
                            "hold (%s). If that remote is public they are already published: `git fetch` this push's remote and push again. "
                            "If it is private, this push publishes them for the first time, and rewriting them would rewrite history "
                            "that remote has: decide with the human." % (slug, ", ".join(sorted({x for v in holders.values() for x in v})), "; ".join(on_remote[:3])))
    return problems + hit_lines or None

def flag_value(argv, names):
    vals = []
    for i, a in enumerate(argv):
        for n in names:
            if a == n and i + 1 < len(argv): vals.append(argv[i + 1])
            elif n.startswith("--") and a.startswith(n + "="): vals.append(a.split("=", 1)[1])
            elif not n.startswith("--") and len(a) > 2 and a.startswith(n) and not a.startswith("--"):
                vals.append(a[2:].lstrip("="))   # -Rowner/repo, -R=owner/repo
    return vals

def local_history_scan(act, title, revs=("HEAD",)):
    hits, total, tr, sc = scan_range(act, list(revs), None)
    if total or tr: return report_hits(title, hits, total, tr, sc)
    return []

MAX_TEXT = 1024 * 1024
def read_text_file(act, path):
    """-> (text, None) or (None, reason) for a file a gh command will read"""
    if getattr(path, "dyn", False) or re.search(r"[*?\[]", path):
        return None, "names its file through a variable, a substitution or a glob"
    p = expand(str(path))
    if not os.path.isabs(p):
        if not act["known"]: return None, "names a relative file after a cd this guard cannot follow"
        p = os.path.join(act["cwd"], p)
    if not is_regular(p): return None, "names a file that does not exist (yet) or is not a regular file"
    try:
        with open(p, "rb") as f: data = f.read(MAX_TEXT + 1)
    except OSError:
        return None, "names a file this guard cannot read"
    if len(data) > MAX_TEXT: return None, "names a file larger than 1 MB"
    if NCMD[0] > 1:   # another command in this call may write the file before gh reads it: the hook sees it as it is now
        name = os.path.basename(p)
        if len(re.findall(r"(?<![A-Za-z0-9_.-])" + re.escape(name) + r"(?![A-Za-z0-9_.-])", re.sub(r"[\x27\"\\]", "", CMD))) > 1:
            return None, "names a file (%s) that another command in the same call also names, so it may be written before gh reads it" % trunc(name, 30)
    return data.decode("utf-8", "replace"), None

def json_strings(text):
    """every string value of a JSON document, else None"""
    try: doc = json.loads(text)
    except Exception: return None
    out = []
    def walk(x):
        if isinstance(x, str): out.append(x)
        elif isinstance(x, dict): [walk(v) for v in x.values()]
        elif isinstance(x, list): [walk(v) for v in x]
    walk(doc); return "\n".join(out)

def gh_texts(act):
    """-> (pieces [(label, text)], unseen [reasons]) for the text the gh command publishes"""
    key, vals = act["key"], act["vals"]
    pieces, unseen = [], []
    def stdin(label, js=False):
        if act["hd"]:   # bash feeds the last heredoc to standard input
            t, literal = body_of(act["hd"][-1])
            if js and json_strings(t) is not None: t = json_strings(t)
            if literal: pieces.append((label + " (heredoc)", t)); return
            unseen.append("%s reads an unquoted heredoc that expands $, backticks or backslashes" % label); return
        unseen.append("%s reads standard input (a pipe, a redirection or a here-string), which this guard cannot see" % label)
    def lit(label, v):
        if v is True or v is None: return
        m = re.fullmatch(r"\$\(\s*cat\s+" + HDTOK.pattern + r"[\s;]*\)", v)   # "$(cat <<'EOF' ... EOF)": the heredoc's body, trailing newlines dropped
        if m:
            t, literal = body_of(int(m.group(1)))
            if literal: pieces.append((label + " (heredoc)", t.rstrip("\n"))); return
        if getattr(v, "dyn", False):
            unseen.append("%s is built by a variable or a command substitution" % label); return
        pieces.append((label, str(v)))
    def fil(label, v, js=False):
        if v is True or v is None: return
        if str(v) == "-": stdin(label, js); return
        t, why = read_text_file(act, v)
        if t is None: unseen.append("%s %s" % (label, why)); return
        if js: t = json_strings(t) if json_strings(t) is not None else t
        pieces.append(("%s %s" % (label, trunc(redact(os.path.basename(str(v))), 30)), t))
    if key == "api":
        for opt in ("--raw-field", "--field"):
            for v in vals.get(opt, []):
                if v is True: continue
                k, _, val = str(v).partition("=")
                val = word(val, getattr(v, "dyn", False))
                if opt == "--field" and val.startswith("@"):
                    fil("field " + trunc(k, 20), word(val[1:], val.dyn))
                    if k == "content" and pieces and pieces[-1][0].startswith("field content"):
                        try:
                            import base64
                            pieces.append(("field content (decoded)", base64.b64decode("".join(pieces[-1][1].split()), validate=True).decode("utf-8", "replace")))
                        except Exception: pass
                    continue
                lit("field " + trunc(k, 20), val)
                if k == "content" and not val.dyn:   # the contents API takes a file as base64: read what it decodes to
                    try:
                        import base64
                        pieces.append(("field content (decoded)", base64.b64decode(str(val), validate=True).decode("utf-8", "replace")))
                    except Exception: pass
        for v in vals.get("--input", []): fil("input", v, js=True)
        if vals.get("__dyn__"): unseen.append("an argument is built by a variable or a substitution")
        if act.get("xargs"): unseen.append("it runs through xargs, which supplies arguments this guard cannot see")
        return pieces, unseen
    for opt, label in GH_TEXT.items():
        for v in vals.get(opt, []): lit(label, v)
    for opt, label in GH_FILE.items():
        for v in vals.get(opt, []): fil(label, v)
    if any(vals.get(o) for o in ("--fill", "--fill-first", "--fill-verbose")):
        unseen.append("--fill builds the text from commit messages")
    if vals.get("--editor"):
        unseen.append("--editor takes the text from an editor")
    if vals.get("__dyn__"):
        unseen.append("an argument is built by a variable or a substitution, so which option it is cannot be known (resolve it in an earlier call and pass it literally)")
    if act.get("xargs"):
        unseen.append("it runs through xargs, which supplies arguments this guard cannot see")
    return pieces, unseen

def input_queries(act):
    """the GraphQL query strings of gh api graphql --input FILE: its "query" value, else the whole text"""
    out = []
    for v in act["vals"].get("--input", []):
        if v is True: continue
        t = body_of(act["hd"][-1])[0] if (str(v) == "-" and act["hd"]) else read_text_file(act, v)[0]
        if t is None: continue
        try: d = json.loads(t); out.append(d.get("query", "") if isinstance(d, dict) else t)
        except Exception: out.append(t)
    return out

def preview(pieces):
    text = "\n".join(t for _l, t in pieces)
    lines = text.split("\n")
    out = ["  the text that will be published: %d characters, %d lines; it begins:" % (len(text), len(lines))]
    out += ["    | " + trunc(redact(l), 110) for l in lines[:6]]
    if len(lines) > 6: out.append("    | …")
    return out

def scan_texts(pieces):
    sc = Scanner([run(["git", "config", "--global", "user.email"])[1].strip()])
    for label, t in pieces:
        ls = t.split("\n")
        for n, ln in enumerate(ls, 1):
            sc.line(label if len(ls) == 1 else "%s line %d" % (label, n), ln, trailer_ok=True, builtin=True)
    return sc

def gh_target(act):
    """-> (host, nwo|None, is_graphql, reason_to_skip|None). nwo None: the repository gh resolves from the checkout."""
    vals, key, env = act["vals"], act["key"], act.get("env", {})
    host = (env.get("GH_HOST") or os.environ.get("GH_HOST", "github.com")).lower()
    repo = (vals.get("--repo") or [None])[-1]   # gh uses the last -R
    if repo is True: repo = None
    if key == "api":
        method = str((vals.get("--method") or [""])[-1]).upper()
        if vals.get("--hostname") and vals["--hostname"][-1] is not True: host = str(vals["--hostname"][-1]).lower()
        writes = method in ("POST", "PATCH", "PUT") or (not method and any(vals.get(o) for o in ("--raw-field", "--field", "--input")))
        if not writes: return host, None, False, "read"
        if act["pos"] and getattr(act["pos"][0], "dyn", False): return host, "$", False, None
        ep = str(act["pos"][0]) if act["pos"] else ""
        ep = re.sub(r"^https?://[^/]+/(?:api/v3/)?", "", ep).lstrip("/")
        ep = re.sub(r"(^|/):(owner|repo)(?=/|$)", r"\1{\2}", ep)   # gh's older :owner/:repo spelling
        if ep == "graphql": return host, None, True, None
        m = re.match(r"repos/([^/]+)/([^/?#]+)", ep)
        if not m: return host, None, False, "not a repository"   # SHORTCUT: gists, users and orgs are not repositories; see the header
        if m.group(0) == "repos/{owner}/{repo}":   # gh fills both from GH_REPO or the checkout
            return host, env.get("GH_REPO") or os.environ.get("GH_REPO") or None, False, None
        return host, m.group(1) + "/" + m.group(2), False, None   # one placeholder: handle_text fills it from the checkout
    for p in act["pos"]:   # a pull request or issue named by URL publishes to the repository in the URL, whatever -R says
        m = re.match(r"^https?://([^/]+)/([^/]+)/([^/]+)/(?:pull|issues)/\d+", str(p))
        if m: return m.group(1).lower(), m.group(2) + "/" + m.group(3), False, None
    if not repo: repo = env.get("GH_REPO")
    if repo:
        if getattr(repo, "dyn", False): return host, "$", False, None
        parts = str(repo).split("/")
        if len(parts) == 3: return parts[0].lower(), "/".join(parts[1:]), False, None
        return host, str(repo), False, None
    return host, None, False, None

def handle_text(act):
    """a gh command that publishes text: pr/issue create, edit, comment, close, reopen; pr review, merge; release
    create, edit; gh api writes. On a PUBLIC repository the text is scanned like an outgoing commit."""
    vals = act["vals"]
    if vals.get("--dry-run"): return None
    what = "gh " + act["key"]
    host, nwo, graphql, skip = gh_target(act)
    if skip: return None
    if act["pre"]["retarget"] and (nwo is None or act["key"] == "pr create"):   # gh resolves from the checkout (pr create may also push): an
        # earlier remote/config change would make the lookup see the target as it is now, not as the call leaves it
        return retry("An earlier command in this call (git %s) changes where %s publishes, so its target was not checked. Run %s in a separate call." % (act["pre"]["retarget"][0], what, what))
    hint = "-F body=@FILE" if act["key"] == "api" else "--notes-file FILE" if act["key"].startswith("release") else "--body-file FILE"
    pieces, unseen = gh_texts(act)
    if graphql:
        q_unseen = [u for u in unseen if u.startswith(("field query", "input", "an argument", "it runs"))]
        mut = any(re.match(r"\s*mutation\b", t) for l, t in pieces if l.startswith("field query")) or \
              any(re.match(r"\s*mutation\b", q) for q in input_queries(act))
        if q_unseen or mut:
            sc = scan_texts(pieces)
            return (["%s runs a GraphQL mutation; this guard cannot tell which repository it writes to, or whether that repository is public." % what]
                    + (["  text this guard could not see: " + "; ".join(unseen)] if unseen else []) + sc.hits + preview(pieces))
        return None
    if nwo and "{" in nwo:   # repos/{owner}/name or repos/owner/{repo}: the missing half is the checkout's
        if not act["known"] or not os.path.isdir(act["cwd"]):
            return retry("%s names its repository with a {owner} or {repo} placeholder in a directory this guard cannot resolve. Name the repository literally." % what)
        _v, here = gh_visibility(host, None, act["cwd"])
        if not here:
            return ["could not determine which repository %s fills its {owner}/{repo} placeholder from, or whether it is public." % what] + preview(pieces)
        o, n = here.split("/", 1); a, b = nwo.split("/", 1)
        nwo = (o if a == "{owner}" else a) + "/" + (n if b == "{repo}" else b)
    if nwo == "$":
        return retry("%s names its repository through a variable or a substitution, so its visibility cannot be checked. Name the repository literally (-R owner/repo)." % what)
    if nwo is None and act["pre"]["ghdefault"]:
        return retry("An earlier command in this call (gh repo set-default) changes which repository %s publishes to, so its target was not checked. Run %s in a separate call." % (what, what))
    if nwo is None and not act["known"]:   # a named repository does not depend on the directory
        return retry("The working directory is not statically known (cd into a variable or substitution, pushd/popd), so the repository %s publishes to cannot be resolved. Replace the variable directory with a literal path, or name the repository with -R owner/repo." % what)
    if nwo is None and not os.path.isdir(act["cwd"]):
        return retry("The directory %s runs in (%s) does not exist yet; if an earlier command in this call creates it, run that first and this command in a separate call." % (what, trunc(act["cwd"], 60)))
    if not pieces and not unseen and act["key"] != "pr create": return None   # publishes no new text (an approval, a merge with its default message)
    vis, got = gh_visibility(host, nwo, act["cwd"] if act["known"] else None)
    if vis is None:
        if nwo and is_trusted(host + "/" + nwo): return None   # only where the lookup cannot answer; never over a PUBLIC answer
        sc = scan_texts(pieces)
        return (["could not determine whether the repository %s publishes to is public (gh missing, not logged in, offline or no access)." % what]
                + (["  text this guard could not see: " + "; ".join(unseen)] if unseen else []) + sc.hits + preview(pieces))
    if vis != "PUBLIC": return None
    slug = host + "/" + (got or nwo or "?")
    act["public"] = slug   # from here on a failure of this guard asks instead of passing
    if unseen:
        if any(u.startswith(("title", "comment")) for u in unseen): hint += " (a title, subject or comment literally)"
        return retry("%s is PUBLIC and the text of this %s cannot be checked: %s. Write the text to a file in a separate call and pass it with %s." % (slug, what, "; ".join(unseen), hint))
    sc = scan_texts(pieces)
    if sc.fatal:
        return retry("%s is PUBLIC and the text of this %s contains %s. %s Remove it and issue the command again." % (slug, what, "; ".join(sc.fatal[:5]), BUILTIN_FIX))
    lines = []
    if sc.total: lines += report_hits("%s is PUBLIC and the text of this %s contains:" % (slug, what), sc.hits, sc.total, False, sc)
    if not known_public(slug): lines.append(not_expected(slug))
    return (lines + preview(pieces)) if lines else None

def handle_repo(act):
    argv = act["argv"]; kind = act["kind"]
    if kind == "repo-edit":
        vis = flag_value(argv, ["--visibility"])
        if not any(v.lower() == "public" for v in vis): return None
        valued = {"--visibility", "--description", "-d", "--homepage", "-h", "--default-branch", "--add-topic", "--remove-topic", "--template"}
        words, skip = [], False
        for a in argv:
            if skip: skip = False; continue
            if a in valued: skip = True; continue
            if not a.startswith("-"): words.append(a)
        extra = local_history_scan(act, "the local history (every branch and tag) contains:", ("--branches", "--tags", "HEAD")) if len(words) <= 2 and act["known"] else []
        return ["this makes a repository PUBLIC: its whole history, every branch and every fork-visible object, becomes readable by anyone. Read the history first."] + extra
    # create
    if not any(a == "--public" or a.lower() in ("--public=true", "--public=1") for a in argv): return None
    extra = []
    src = flag_value(argv, ["--source"])
    if src: act = dict(act, cwd=os.path.normpath(os.path.join(act["cwd"], expand(src[0]))))
    if ("--push" in argv or src) and act["known"]:
        extra = local_history_scan(act, "the local history (HEAD) that will be pushed contains:")
    return ["this creates a PUBLIC repository."] + extra

problems = []
for act in ACTIONS:
    try:
        r = {"push": handle_push, "text": handle_text}.get(act["kind"], handle_repo)(act)
    except Exception as e:
        if isinstance(e, ScanFailed): r = ["the scan could not run (git failed or timed out), so the outgoing commits were not checked."]
        elif act.get("public"): r = ["%s is PUBLIC and this guard failed internally (%s) before it finished checking, so the outgoing content was not fully checked." % (act["public"], type(e).__name__)]
        else: r = None   # a bug before the target is known to be public fails open
    if r: problems += r
if RETRY:
    deny(RETRY + NOTES)
if problems:
    ask(problems + NOTES)
sys.exit(0)
PYEOF

printf '%s' "$INPUT" | python3 -I -c "$_PROG" 2>/dev/null
exit 0
