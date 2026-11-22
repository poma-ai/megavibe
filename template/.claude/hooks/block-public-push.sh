#!/bin/bash
# Megavibe — ask before internal work reaches a PUBLIC repository.
# Triggered by: PreToolUse (Bash). Runs in ALL projects (a push is a push).
# DO NOT use set -e. This hook never blocks (exit 2): it answers with a permission
# prompt (permissionDecision "ask", honoured under bypassPermissions and forwarded to
# the phone, like the remote-delete guard) or stays silent (exit 0). Infra failures
# (no jq, no python3, a crashed check) fail OPEN: silent exit 0.
set -u
#
# Why: on 2026-11-21 a session pushed a branch with internal cost formulas to a
# repository that turned out to be public; it was reachable for about 50 minutes.
# "Check the repository's visibility before every push" lived only in memory and was
# skipped. This is the check, in code.
#
# What fires it (parsed with shlex, so quoted text, echo and commit messages are not
# commands; `bash -c`, `sudo`, `env X=1`, `git -C dir`, and `cd dir && git push` are):
#   git push                      the target is resolved (remote name, URL, pushurl,
#                                 insteadOf, branch/pushDefault remote) and its
#                                 visibility looked up with `gh repo view`
#   gh pr create                  same lookup for the base repository; the title and
#                                 body text are scanned
#   gh repo create --public       asks (publishes a new repo); scans local history
#                                 when --push/--source is given
#   gh repo edit --visibility public   asks: it turns the WHOLE history public;
#                                 scans local history when no other repo is named
# Not fired: --dry-run, --delete, a delete refspec (":branch"), a local-path remote.
#
# Chains are NOT simulated. A state-changing git command earlier in the same call (add, commit, switch,
# checkout, branch, merge, rebase, pull, cherry-pick, reset, stash, tag, ...) makes the push's content
# unknowable beforehand, and every simulated predecessor opened the next gap (fifteen review rounds). So a push
# to a PUBLIC repository after one asks to be run in a separate call, where the full scan applies:
# `git commit ... && git push` chains to public repos therefore always prompt, BY DESIGN (a standalone push
# keeps the full scan; the same chain to a private repo passes). `git remote add|set-url|rename|remove` and
# `git config` (writes) before a push ask whatever the visibility, since they change where it goes.
#
# Postures (each reason names what was found, one line per hit, values truncated):
#   PRIVATE / INTERNAL target     silent pass, no scan, no cost
#   PUBLIC target, scan clean     silent pass (a clean megavibe push never prompts)
#   PUBLIC target, hits           ask, each hit named by file:line (secrets show 4
#                                 characters at most)
#   visibility UNKNOWN            ask: gh missing or failing, offline, a host that is
#                                 not GitHub, an ssh alias that does not resolve. A
#                                 push to a host that might be public never passes
#                                 silently. Silence a host or repo you know is private
#                                 in ~/.megavibe/personal/public-push.trusted
#   scan truncated               ask: more than 500 outgoing commits or 8 MB of diff
#                                 is a scan that did not see everything
#
# What is scanned (outgoing = `git rev-list <src> --not --remotes=<remote>`: commits
# the remote's last-fetched refs do not hold; a new branch yields every commit it
# does not share with the remote): added lines, commit messages, changed file paths.
#   generic     home paths (/Users/<name>/, /home/<name>/; placeholders such as
#               /Users/<you>/ pass, the real login name never does), private keys and
#               token shapes (AWS, GitHub, Slack, Anthropic/OpenAI sk-, Google AIza,
#               Stripe live, GitLab; a line containing example/placeholder/xxx/redacted/
#               dummy is skipped for these, as scripts/leak-scan.sh does), email addresses other than: the authors and
#               committers of the outgoing commits and your user.email (they are
#               published anyway), trailer lines (Co-authored-by:, Signed-off-by:),
#               noreply addresses, example.* domains, and your allow file
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
# Known gaps (not enforced here): a push through a git alias, a script or
# $(...)/backtick substitution; `git push` inside a command run by another tool;
# gh pr create does not scan commits (they were scanned when pushed) and cannot read
# a body that comes from $(...); binary content; the conflict-resolution lines of a merge
# commit (git log -p shows no diff for merges); another gh operation that publishes
# (gh gist create --public, gh release create); a denylist
# written in a file the hook cannot read is silently empty (the reason says so only
# for an invalid regex).

command -v jq &>/dev/null || exit 0
command -v python3 &>/dev/null || exit 0

[ "${MEGAVIBE_ALLOW_PUBLIC_PUSH:-0}" = "1" ] && exit 0

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$COMMAND" ] || exit 0

case "$COMMAND" in
  *push*|*gh*pr*|*gh*repo*) ;;
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

# ---- command parsing (same family as the kill guard in block-dangerous-bash.sh) ----
_QUOTED = re.compile(r"""('[^']*'|"(?:\\.|[^"\\])*")""")
def strip_comments(text):
    """drop shell comments (an unquoted # at a word start, up to the newline); quotes may span lines"""
    return "".join(part if k % 2 else re.sub(r"(?:^|(?<=[\s;&|(]))#[^\n]*", "", part) for k, part in enumerate(_QUOTED.split(text)))
out, pending, HEREDOCS = [], [], []
for line in CMD.split("\n"):
    if pending:
        if line.strip() == pending[0]: pending.pop(0)
        else: HEREDOCS.append(line)
        continue
    out.append(line)
    pending = re.findall(r"(?<!<)<<(?!<)-?\s*\\?[\x27\"]?([A-Za-z_][A-Za-z0-9_]*)[\x27\"]?", line)
TEXT = strip_comments("\n".join(out)).replace("\\\n", "").replace("\n", " ; ")
# redirections are not arguments: `2>&1`, `> file`, `< file`
_REDIR = re.compile(r"(?:(?<=\s)|^)\d*(?:>>?|<)(?:&\d+-?|[ \t]*[^\s;&|()\"'<>]+)")   # an unquoted operand; a quoted one is dropped with its operator at token level
TEXT = "".join(part if i % 2 else _REDIR.sub(" ", part).replace("\\ ", "\x1f") for i, part in enumerate(_QUOTED.split(TEXT)))   # "\\ " (an escaped space) stays inside its word   # quoted text is never a redirection

WRAP = {"sudo": {"-u","-g","-h","-p","-C","-T","-r","-t","-U","-D","-R"}, "doas": {"-u","-C"},
        "env": {"-u","-C","-S","-P"}, "nice": {"-n"}, "stdbuf": {"-i","-o","-e"},
        "timeout": {"-s","-k"}, "nohup": set(), "command": set(), "time": set(), "builtin": set(),
        "xargs": {"-I","-n","-P","-L","-s","-E","-d","-a"}}
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "fi", "done"}
SHELLS = {"sh", "bash", "zsh", "ksh", "dash"}
OPS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&", ";;"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

def split_tokens(s):
    lx = shlex.shlex(s, posix=False, punctuation_chars=True)
    lx.whitespace_split = True
    lx.commenters = ""
    try: toks = list(lx)
    except ValueError: return None
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

def unq(tok):
    try:
        w = shlex.split(tok)
        return ("".join(w) if w else "").replace("\x1f", " ")
    except ValueError:
        return tok

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
PRE = {"mutators": [], "retarget": []}
PERSIST, INHERIT = {}, [{}]   # exported / bare GH_REPO= selections persist in the shell; a child shell inherits the command's
ENVSEL = {}   # inline GH_REPO= / GH_HOST= selections, which gh honours (the override variable is NOT honoured inline)
def note_assign(a):
    if a.startswith("MEGAVIBE_ALLOW_PUBLIC_PUSH="):
        NOTES.append("an inline MEGAVIBE_ALLOW_PUBLIC_PUSH assignment in the command is ignored: only the session's launch environment counts")
    elif a.startswith(("GH_REPO=", "GH_HOST=", "GIT_DIR=", "GIT_WORK_TREE=")):
        ENVSEL[a.split("=", 1)[0]] = a.split("=", 1)[1]
def scan_argv(argv, depth=0):
    if depth > 3 or not argv: return
    ENVSEL.clear(); ENVSEL.update(PERSIST); ENVSEL.update(INHERIT[-1])
    if argv == ["__PUSH__"]: SCOPES.append((state["cwd"], state["cwd_known"], dict(PERSIST))); return   # a subshell's cd must not leak out
    if argv == ["__POP__"]:
        if SCOPES:
            state["cwd"], state["cwd_known"], _p = SCOPES.pop()
            PERSIST.clear(); PERSIST.update(_p)
        return
    i = 0
    while i < len(argv):
        a = argv[i]; b = os.path.basename(a)
        if ASSIGN.match(a):
            note_assign(a)
            i += 1; continue
        if a in KEYWORDS: i += 1; continue
        if b in WRAP:
            i += 1
            while i < len(argv) and argv[i].startswith("-") and argv[i] != "-":
                opt = argv[i]; i += 1
                if opt == "--": break
                if opt in WRAP[b] and i < len(argv): i += 1
            while i < len(argv) and ASSIGN.match(argv[i]):
                note_assign(argv[i])
                i += 1
            if b == "timeout" and i < len(argv) and re.match(r"^[0-9.]+[smhd]?$", argv[i]): i += 1
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
                t = split_tokens(strip_comments(argv[j + 1]).replace("\n", " ; "))
                if t is None:
                    if GITPUSH.search(argv[j + 1]): UNPARSED.append(argv[j + 1])
                    return
                saved = (state["cwd"], state["cwd_known"], len(SCOPES), dict(PERSIST))
                INHERIT.append(dict(ENVSEL))
                try:
                    for c in commands(t): scan_argv(c, depth + 1)
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
                gitopts += [o, argv[k + 1]]; k += 2; continue
            if o.startswith("--git-dir=") or o.startswith("--work-tree="):
                gitopts.append(o)
            k += 1
        _verb = argv[k] if k < len(argv) else ""
        if _verb == "remote" and len(argv) > k + 1 and argv[k + 1] in ("add", "set-url", "rename", "remove", "r" + "m", "set-head"):
            PRE["retarget"].append("remote " + argv[k + 1])   # changes where the push goes
        elif _verb == "config" and len(argv) > k + 1 and not any(a in ("--get", "--get-all", "--get-regexp", "--list", "-l") for a in argv[k + 1:]):
            PRE["retarget"].append("config")
        elif _verb == "branch" and any(not a.startswith("-") for a in argv[k + 1:]):
            PRE["mutators"].append("branch")
        elif _verb in STATE_VERBS:
            PRE["mutators"].append(_verb)   # changes what would be pushed: not simulated, see below
        if k < len(argv) and argv[k] == "push":
            for _v in ("GIT_DIR", "GIT_WORK_TREE"):   # inline repository selectors, which git honours
                if ENVSEL.get(_v): gitopts.append("--%s=%s" % (_v.lower().replace("_", "-"), os.path.join(cwd, expand(ENVSEL[_v]))))
            ACTIONS.append({"kind": "push", "argv": argv[k + 1:], "cwd": cwd, "gitopts": gitopts, "known": dir_known, "pre": {"mutators": list(PRE["mutators"]), "retarget": list(PRE["retarget"])}})
        return
    if base == "gh":
        rest = [x for x in argv[1:]]
        # gh [-R repo] group verb ...
        words, skip = [], False
        for x in rest:   # global/option values (-R owner/repo, --repo x) are not the command group or verb
            if skip: skip = False; continue
            if x in ("-R", "--repo"): skip = True; continue
            if not x.startswith("-"): words.append(x)
        if len(words) >= 2 and words[0] == "pr" and words[1] == "create":
            ACTIONS.append({"kind": "pr", "argv": rest, "cwd": state["cwd"], "gitopts": [], "known": state["cwd_known"], "env": dict(ENVSEL)})
        elif len(words) >= 2 and words[0] == "repo" and words[1] in ("create", "edit"):
            ACTIONS.append({"kind": "repo-" + words[1], "argv": rest, "cwd": state["cwd"], "gitopts": [], "known": state["cwd_known"]})

GITPUSH = re.compile(r"\bgit\b(?:\s+-\S+(?:\s+\S+)?)*\s+push\b|\bgh\s+(?:pr\s+create|repo\s+(?:create|edit))\b")
toks = split_tokens(TEXT)
if toks is None:
    # the text cannot be tokenised (an unclosed quote, say): do not let that hide a push
    if GITPUSH.search(TEXT): ask(["this command mentions a push or a public-repository operation but could not be parsed (unbalanced quotes?), so its target was not checked."])
    sys.exit(0)
for c in commands(toks):
    scan_argv(c)
if UNPARSED:
    ask(["a nested shell command mentions a push or a public-repository operation but could not be parsed, so its target was not checked."])
SUBST = re.compile(r"(?:\$\(|`|\beval\b)[^)`]*" + GITPUSH.pattern)
if not ACTIONS and SUBST.search(TEXT):
    ask(["a push or public-repository operation sits inside a command substitution or eval, which this guard does not parse: its target was not checked."])
if not ACTIONS:
    sys.exit(0)

# ---- helpers: git / gh ----
# no git call of ours may reach the network or write objects: a partial clone would otherwise lazy-fetch a missing blob
SAFE_ENV = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
def run(cmd, cwd=None, timeout=10, env=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=timeout, env=env or SAFE_ENV)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return 124, ""
    except Exception:
        return 127, ""

def is_regular(path):   # a FIFO or device at a config/cache path would block the hook on open
    try: return stat.S_ISREG(os.stat(path).st_mode)
    except OSError: return False

NOEXEC = ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "log.showSignature=false", "-c", "diff.external=", "-c", "core.pager=cat"]   # a configured fsmonitor program would run on status/diff
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
    def hit(self, loc, kind, val):
        for _k, rx in SECRET_RES:   # a file name or a matched denylist value can carry a secret
            loc = rx.sub(lambda m: m.group(0)[:4] + "…", loc); val = rx.sub(lambda m: m.group(0)[:4] + "…", val)
        self.total += 1
        if len(self.hits) < MAX_HITS: self.hits.append("  %s  [%s] %s" % (loc, kind, val))
    def line(self, loc, text, trailer_ok=False, path_only=False):
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

def scan_range(act, revargs, remote):
    """revargs: list of rev-list args selecting tips. Returns (hits_lines, total, truncated)."""
    # a source that does not resolve cannot be pushed (git itself will fail): skip it
    revargs = [r for r in revargs if r.startswith("--") or git(act, "rev-parse", "--verify", "-q", r + "^{commit}")[0] == 0]
    if not revargs: return [], 0, False, None
    base = ["rev-list", "--max-count=%d" % (MAX_COMMITS + 1)] + revargs
    if remote: base += ["--not", "--remotes=" + remote]
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
    names = run_capped(["git"] + act["gitopts"] + NOEXEC + ["log", "--no-walk=unsorted", "-z", "--name-only", "--no-renames", "--format=" + M1 + "%h"] + shas, cwd, MAX_BYTES).decode("utf-8", "replace")
    csha = ""
    for tok in names.split("\0"):
        tok = tok.strip("\n")
        if not tok: continue
        if tok.startswith(M1): csha = tok[len(M1):]; continue
        sc.line("commit %s path %s" % (csha, trunc(redact(tok), 40)), tok, path_only=True)
    data = run_capped(["git"] + act["gitopts"] + NOEXEC + ["log", "--no-walk=unsorted", "--no-color", "--no-textconv", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "-p", "-U0",
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
                if body: sc.line("commit %s message" % sha, body, True)
                mode = "diff"; inhunk = False; continue
            sc.line("commit %s message" % sha, raw, True)
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
        for ln in body.split("\n"): sc.line("tag %s message" % trunc(redact(n.replace("refs/tags/", "")), 30), ln, True)
    if overflow: sc.hit("tags", "tag list", "more than 5000 tags: not all annotations were read")
    return sc.hits, sc.total

def handle_push(act):
    _flags = push_revs(act["argv"])[2]
    _rec = next((f.split("=", 1)[1] for f in _flags if f.startswith("--recurse-submodules=")), None)
    if _rec is None: _rec = git(act, "config", "--get", "push.recurseSubmodules")[1].strip() or None
    if _rec in ("on-demand", "only") and os.path.exists(os.path.join(act["cwd"], ".gitmodules")):
        return ["this push recurses into submodules (%s), which are separate repositories whose visibility and outgoing commits this guard does not check. Push the submodules in their own calls." % _rec]
    if act["pre"]["retarget"]:
        return ["an earlier command in this call (git %s) changes where the push goes, so its target was not checked. Run the push in a separate call." % act["pre"]["retarget"][0]]
    repo_opt, pos, flags = push_revs(act["argv"])
    if "--branches" in flags: flags.add("--all")   # git's documented alias
    if "--dry-run" in flags or "-n" in flags: return None
    if "--delete" in flags or "-d" in flags: return None
    remote = repo_opt or (pos[0] if pos else None)
    if remote and ("$" in remote or "`" in remote):
        return ["the push remote %s contains an unexpanded variable or substitution, so the target cannot be resolved." % trunc(remote, 30)]
    unexpanded = any(("$" in a or "`" in a) for a in pos)
    refspecs = pos[1:] if (pos and not repo_opt) else pos if repo_opt else []
    if not act["known"]:
        return ["the working directory is not statically known (cd into a variable), so the target repository cannot be resolved."]
    if remote is None:
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
        if is_trusted(slug): continue
        if host not in GH_HOSTS or len(parts) < 2:
            problems.append("%s is not a GitHub host this guard can query (visibility unknown). Add it to ~/.megavibe/personal/public-push.trusted if it is private." % host)
            continue
        vis, _ = gh_visibility(host, parts[0] + "/" + parts[1])
        if vis is None:
            problems.append("could not determine whether %s is public (gh missing, not logged in, offline or no access)." % slug)
            continue
        if vis != "PUBLIC": continue
        if unexpanded:
            problems.append("%s is PUBLIC and a refspec contains an unexpanded variable, so which commits go out cannot be known." % slug)
            continue
        fetch_urls = git(act, "remote", "get-url", remote_name)[1].split() if remote_name else []
        # tracking refs describe what the FETCH side holds: use them only when we push to that same place
        hits, total, trunc_, sc = scan_range(act, revargs, remote_name if (remote_name and u in fetch_urls) else None)
        if total or trunc_:
            hit_lines += report_hits("%s is PUBLIC and the outgoing commits contain:" % slug, hits, total, trunc_, sc)
        if act["pre"]["mutators"]:
            problems.append("%s is PUBLIC and this command runs `git %s` before the push, which changes what would be pushed; this guard does not simulate that. Run the push in a separate call so it can be checked." % (slug, act["pre"]["mutators"][0]))
        th, tt = scan_tag_messages(act, refspecs, flags, [r for r in revargs if not r.startswith("--") or r in ("--branches", "--all")] or ["HEAD"], remote_name if (remote_name and u in fetch_urls) else None)
        if tt: hit_lines += report_hits("%s is PUBLIC and the annotated tags being pushed contain:" % slug, th, tt, False, None)
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

def handle_pr(act):
    argv = act["argv"]
    repo = (flag_value(argv, ["--repo", "-R"]) or [act.get("env", {}).get("GH_REPO")])[0]
    if not act["known"]:
        return ["the working directory is not statically known (cd into a variable), so the base repository cannot be resolved."]
    host = (act.get("env", {}).get("GH_HOST") or os.environ.get("GH_HOST", "github.com")).lower()
    nwo = None
    if repo:
        parts = repo.split("/")
        if len(parts) == 3: host, nwo = parts[0].lower(), "/".join(parts[1:])
        else: nwo = repo
        if is_trusted(host + "/" + nwo): return None
    vis, got = gh_visibility(host, nwo, act["cwd"])
    if vis is None:
        return ["could not determine whether the pull request's base repository is public (gh missing, not logged in, offline or no access)."]
    if vis != "PUBLIC": return None
    if got and is_trusted(host + "/" + got): return None
    _m = re.search(r"\bpr\s+create\b", TEXT)
    def _cut(t):   # stop at the first unquoted ; & | : later commands are not PR text
        res = []
        for k, part in enumerate(_QUOTED.split(t)):
            if k % 2: res.append(part); continue
            m = re.search(r"[;&|]", part)
            if m: res.append(part[:m.start()]); break
            res.append(part)
        return "".join(res)
    _whole = re.sub(r"\s+(?=--?[A-Za-z])", "\n", re.sub(r"(?:--body-file|-F)[ =]+\S+", " ", _cut(TEXT[_m.start():]))) if _m else ""   # one chunk per flag, so a word in --title cannot excuse --body
    texts = [_whole.replace(" ; ", "\n")] + flag_value(argv, ["--title", "-t", "--body", "-b"]) + HEREDOCS   # the whole command text too: --body='two words' is split by the tokenizer   # a heredoc body is how most PR bodies arrive
    unread = []
    _bf = [x for x in flag_value(argv, ["--body-file", "-F"]) if x != "-"]
    _cut = CMD.find("pr create") if "pr create" in CMD else CMD.find("pr  create")
    if _m and _bf and _cut > 0 and any(os.path.basename(x) in CMD[:_cut] for x in _bf):
        texts.append(TEXT[:_m.start()].replace(" ; ", "\n"))   # the body file is named earlier in this command, so it may be written there: scan that text too
    _unres = [t for t in flag_value(argv, ["--title", "-t", "--body", "-b"]) if re.search(r"\$\{?[A-Za-z_]", t)]
    if _unres:
        return ["%s is PUBLIC and the pull request title/body contains an unexpanded variable, so its text cannot be scanned." % (got or "the base repository")]
    for f in flag_value(argv, ["--body-file", "-F"]):
        if f == "-" or f in ("/dev/stdin", "/dev/tty") or re.match(r"^/(?:dev|proc/self)/fd/\d+$", f):
            if not HEREDOCS: unread.append("standard input")
            continue
        p = os.path.join(act["cwd"], expand(f.replace("$HOME", HOME).replace("${HOME}", HOME)))
        if "$" in p: unread.append(trunc(f, 30)); continue
        try:
            if not stat.S_ISREG(os.stat(p).st_mode): unread.append(trunc(f, 30)); continue   # a FIFO or device could block the hook
            texts.append(open(p, encoding="utf-8", errors="replace").read(1 << 20))
        except OSError: unread.append(trunc(f, 30))
    if unread:
        return ["%s is PUBLIC and the pull request body source (%s) could not be read, so the body was not scanned." % (got or "the base repository", ", ".join(unread))]
    sc = Scanner([])
    for t in texts:
        for ln in t.split("\n"): sc.line("pull request text", ln, True)
    if sc.total:
        return report_hits("%s is PUBLIC and the pull request text contains:" % (got or "the base repository"), sc.hits, sc.total, False, sc)
    return None

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
        r = {"push": handle_push, "pr": handle_pr}.get(act["kind"], handle_repo)(act)
    except Exception as e:
        r = ["the scan could not run (git failed or timed out), so the outgoing commits were not checked."] if isinstance(e, ScanFailed) else None   # any other bug fails open
    if r: problems += r
if problems:
    ask(problems + NOTES)
sys.exit(0)
PYEOF

printf '%s' "$INPUT" | python3 -I -c "$_PROG" 2>/dev/null
exit 0
