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
#               /Users/you/ pass, the real login name never does), private keys and
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
# MEGAVIBE_GITHUB_HOSTS (space separated); an ssh alias is resolved with `ssh -G`.
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
import fnmatch, hashlib, json, os, re, shlex, subprocess, sys, time

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
out, pending, HEREDOCS = [], [], []
for line in CMD.split("\n"):
    if pending:
        if line.strip() == pending[0]: pending.pop(0)
        else: HEREDOCS.append(line)
        continue
    out.append(line)
    pending = re.findall(r"(?<!<)<<(?!<)-?\s*\\?[\x27\"]?([A-Za-z_][A-Za-z0-9_]*)[\x27\"]?", line)
TEXT = "\n".join(out).replace("\\\n", "").replace("\n", " ; ")
# redirections are not arguments: `2>&1`, `> file`, `< file`
TEXT = re.sub(r"(?<=\s)\d*(?:>>?|<)&?[ \t]*[^\s;&|()]*", " ", TEXT)

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
    try: return list(lx)
    except ValueError: return None

def unq(tok):
    try:
        w = shlex.split(tok)
        return "".join(w) if w else ""
    except ValueError:
        return tok

def commands(tokens):
    cur = []
    for t in tokens:
        if t in OPS:
            if cur: yield [unq(x) for x in cur]
            cur = []
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

def scan_argv(argv, depth=0):
    if depth > 3 or not argv: return
    i = 0
    while i < len(argv):
        a = argv[i]; b = os.path.basename(a)
        if ASSIGN.match(a):
            if a.startswith("MEGAVIBE_ALLOW_PUBLIC_PUSH="):
                NOTES.append("an inline MEGAVIBE_ALLOW_PUBLIC_PUSH assignment in the command is ignored: only the session's launch environment counts")
            i += 1; continue
        if a in KEYWORDS: i += 1; continue
        if b in WRAP:
            i += 1
            while i < len(argv) and argv[i].startswith("-") and argv[i] != "-":
                opt = argv[i]; i += 1
                if opt == "--": break
                if opt in WRAP[b] and i < len(argv): i += 1
            while i < len(argv) and ASSIGN.match(argv[i]):
                if argv[i].startswith("MEGAVIBE_ALLOW_PUBLIC_PUSH="):
                    NOTES.append("an inline MEGAVIBE_ALLOW_PUBLIC_PUSH assignment in the command is ignored: only the session's launch environment counts")
                i += 1
            if b == "timeout" and i < len(argv) and re.match(r"^[0-9.]+[smhd]?$", argv[i]): i += 1
            continue
        break
    if i >= len(argv): return
    argv = argv[i:]
    base = os.path.basename(argv[0])
    if base in SHELLS:
        for j, a in enumerate(argv[1:], 1):
            if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) and j + 1 < len(argv):
                t = split_tokens(argv[j + 1])
                if t is None: return
                for c in commands(t): scan_argv(c, depth + 1)
                return
        return
    if base in ("cd", "pushd"):
        do_cd(argv); return
    if base == "git":
        gitopts, k = [], 1
        cwd = state["cwd"]
        while k < len(argv) and argv[k].startswith("-"):
            o = argv[k]
            if o in ("-C",) and k + 1 < len(argv):
                cwd = os.path.normpath(os.path.join(cwd, expand(argv[k + 1]))); k += 2; continue
            if o in ("-c", "--git-dir", "--work-tree", "--namespace", "--exec-path") and k + 1 < len(argv):
                gitopts += [o, argv[k + 1]]; k += 2; continue
            if o.startswith("--git-dir=") or o.startswith("--work-tree="):
                gitopts.append(o)
            k += 1
        if k < len(argv) and argv[k] == "push":
            ACTIONS.append({"kind": "push", "argv": argv[k + 1:], "cwd": cwd, "gitopts": gitopts, "known": state["cwd_known"]})
        return
    if base == "gh":
        rest = [x for x in argv[1:]]
        # gh [-R repo] group verb ...
        words = [x for x in rest if not x.startswith("-")]
        if len(words) >= 2 and words[0] == "pr" and words[1] == "create":
            ACTIONS.append({"kind": "pr", "argv": rest, "cwd": state["cwd"], "gitopts": [], "known": state["cwd_known"]})
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
SUBST = re.compile(r"(?:\$\(|`|\beval\b)[^)`]*" + GITPUSH.pattern)
if not ACTIONS and SUBST.search(TEXT):
    ask(["a push or public-repository operation sits inside a command substitution or eval, which this guard does not parse: its target was not checked."])
if not ACTIONS:
    sys.exit(0)

# ---- helpers: git / gh ----
def run(cmd, cwd=None, timeout=10, env=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=timeout, env=env)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except Exception:
        return 127, ""

def git(act, *a, timeout=10):
    return run(["git"] + act["gitopts"] + list(a), cwd=act["cwd"] if os.path.isdir(act["cwd"]) else None, timeout=timeout)

def read_lines(path):
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
    if host in GH_HOSTS: return host
    rc, o = run(["ssh", "-G", host], timeout=3)
    if rc == 0:
        for l in o.splitlines():
            if l.startswith("hostname "):
                h = l.split(None, 1)[1].strip().lower()
                if h in GH_HOSTS: return h
    return host

def gh_visibility(host, nwo, cwd=None):
    """returns (VIS|None, nameWithOwner|None)"""
    cache = None
    if nwo:
        key = host + "/" + nwo.lower()
        cache = os.path.join(CACHE_DIR, hashlib.sha1(key.encode()).hexdigest())
        try:
            if time.time() - os.path.getmtime(cache) < TTL:
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
DEFAULT_EMAIL_ALLOW = ["*@users.noreply.github.com", "noreply@*", "no-reply@*", "*@example.com", "*@example.org",
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

def trunc(s, n=16):
    s = s.replace("\n", " ")
    return s if len(s) <= n else s[:n] + "…"

class ScanFailed(Exception): pass

def run_capped(cmd, cwd, cap, timeout=60):
    """stdout up to cap+1 bytes, then the process is killed; raises ScanFailed on error/timeout"""
    try:
        p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
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
        self.total += 1
        if len(self.hits) < MAX_HITS: self.hits.append("  %s  [%s] %s" % (loc, kind, val))
    def line(self, loc, text, trailer_ok=False, path_only=False):
        if not path_only:
            for kind, rx in SECRET_RES:
                m = rx.search(text)
                if m and not PLACEHOLDER.search(text): self.hit(loc, kind, m.group(0)[:4] + "…")
            for m in HOMEPATH.finditer(text):
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
            if m: self.hit(loc, "denylist #%d" % n, trunc(m.group(0)))

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
    data = run_capped(["git"] + act["gitopts"] + ["log", "--no-walk=unsorted", "--no-color", "--no-textconv", "--no-ext-diff", "-p", "-U0",
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
            if path: sc.line("commit %s path %s" % (sha, trunc(path, 40)), path, path_only=True)
            continue
        if not inhunk and raw.startswith("+++ "):
            p = raw[4:]; path = p[2:] if p.startswith("b/") else path; continue
        if raw.startswith("@@"):
            inhunk = True
            m = re.search(r"\+(\d+)", raw); ln = int(m.group(1)) - 1 if m else 0; continue
        if inhunk and raw.startswith("+"):
            ln += 1
            sc.line("%s:%d (%s)" % (trunc(path, 60), ln, sha), raw[1:])
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
            flags.add(a); i += 1; continue
        pos.append(a); i += 1
    return repo_opt, pos, flags

def handle_push(act):
    repo_opt, pos, flags = push_revs(act["argv"])
    if "--dry-run" in flags or "-n" in flags: return None
    if "--delete" in flags or "-d" in flags: return None
    remote = repo_opt or (pos[0] if pos else None)
    refspecs = pos[1:] if (pos and not repo_opt) else pos if repo_opt else []
    if not act["known"]:
        return ["the working directory is not statically known (cd into a variable), so the target repository cannot be resolved."]
    if remote is None:
        _, br = git(act, "symbolic-ref", "--short", "-q", "HEAD"); br = br.strip()
        for key in ([("branch.%s.pushRemote" % br)] if br else []) + ["remote.pushDefault"] + ([("branch.%s.remote" % br)] if br else []):
            rc, v = git(act, "config", "--get", key)
            if rc == 0 and v.strip(): remote = v.strip(); break
        if remote is None: remote = "origin"
    # push URLs
    if parse_url(remote) is not None or remote.startswith(("/", ".", "~", "file://")):
        urls, remote_name = [remote], None
    else:
        rc, o = git(act, "remote", "get-url", "--push", "--all", remote)
        if rc != 0 or not o.strip():
            return None   # no such remote: git push itself will fail
        urls, remote_name = [u.strip() for u in o.splitlines() if u.strip()], remote
    # sources
    revargs = []
    for rs in refspecs:
        rs = rs.lstrip("+")
        if rs.startswith(":"): continue
        src = rs.split(":", 1)[0]
        if rs == "tag": continue
        if "*" in src or src in ("refs/heads/*",): revargs.append("--branches")
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
        hits, total, trunc_, sc = scan_range(act, revargs, remote_name)
        if total or trunc_:
            hit_lines += report_hits("%s is PUBLIC and the outgoing commits contain:" % slug, hits, total, trunc_, sc)
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
    repo = (flag_value(argv, ["--repo", "-R"]) or [None])[0]
    if not act["known"]:
        return ["the working directory is not statically known (cd into a variable), so the base repository cannot be resolved."]
    host = os.environ.get("GH_HOST", "github.com").lower()
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
    texts = flag_value(argv, ["--title", "-t", "--body", "-b"]) + HEREDOCS   # a heredoc body is how most PR bodies arrive
    for f in flag_value(argv, ["--body-file", "-F"]):
        p = f if os.path.isabs(f) else os.path.join(act["cwd"], f)
        try: texts.append(open(p, encoding="utf-8", errors="replace").read(1 << 20))
        except OSError: pass
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
    if "--public" not in argv: return None
    extra = []
    if ("--push" in argv or flag_value(argv, ["--source"])) and act["known"]:
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
