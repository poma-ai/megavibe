#!/bin/bash -p
# Empty what the Trash review marked droppable (or, with --all, the whole Trash),
# but only behind a permission prompt.
#
#   ~/.megavibe/scripts/trash-empty.sh          delete the items marked "droppable" in the review
#   ~/.megavibe/scripts/trash-empty.sh --all    delete everything in ~/.Trash
#
# This is the one place megavibe really deletes. Megavibe sessions run with
# permissions bypassed, and every consent check an agent can run itself was shown
# forgeable (environment overrides, transcript appends, pseudo-terminals). What an agent
# cannot do from a Bash command is answer Claude Code's own permission prompt: an ASK
# rule is honoured under bypassPermissions, and the prompt is forwarded to the phone
# under Remote Control. setup.sh installs the rules; this script is what they gate:
#
#   Bash(~/.megavibe/scripts/trash-empty.sh *)    the one spelling the hook lets through
#   Bash(*trash-empty*)                           catch-all: any command text naming it prompts
#
# A text rule cannot see every spelling that reaches a file (a glob, a symlinked directory,
# a variable), so the script does not trust the text it was started with. It checks what
# Claude Code's own shell was given. Claude Code runs a Bash call as a child of its `claude`
# process through `<shell> -c 'source <home>/.claude/shell-snapshots/snapshot-...sh 2>/dev/null
# || true && ... && eval '<COMMAND AS TYPED>' < /dev/null && pwd -P >| /tmp/claude-<hex>-cwd'`
# (measured on Claude Code 2.1.30x with zsh), and that shell's command line is the text the
# permission rules matched. The script walks its ancestors and runs only if the topmost
# `claude` is a running process that satisfies Anthropic's code-signing requirement (codesign
# on the live pid) and the shell right below it has exactly that shape with the payload
# `~/.megavibe/scripts/trash-empty.sh` (or the same with ` --all`, matching its own argument).
# Anything else, including a plain terminal, exits 5.
#
# What that proves is: Claude Code's own shell was given exactly the approved command, which
# Claude Code prompts for. It does NOT prove a human answered. A PermissionRequest hook in
# Claude Code's own configuration can answer the prompt, so the script refuses (exit 6) while
# one is visible in a settings file it can read (managed, ~/.claude, and the .claude of the
# session's working directory and every directory above it), and a hook guard blocks writing
# one. Other configuration an agent can rewrite (plugins, agent and skill frontmatter, a second
# `claude` started with other settings, an MCP server or hook command written to imitate the
# shell's shape) is outside what this script checks, and so is an agent writing deleting code
# of its own. README, "Trash greenlight", states that boundary. This relies on Claude Code's
# current way of running commands and fails closed if that changes.
#
# Everything else here is about not trusting the caller's environment:
#   - `#!/bin/bash -p`: no BASH_ENV/ENV, no functions imported from the environment. The
#     script refuses to run unless -p is in effect (so not via `bash script` or `source`);
#   - PATH is fixed, the environment is wiped (`env -i`), python3 is looked up in fixed
#     directories only, and the home directory is the user database's, not $HOME's:
#     a different $HOME is refused. CLAUDE_CONFIG_DIR is ignored;
#   - the permission rules must be in the managed settings file or in
#     <home>/.claude/settings.json, as a real array of strings under permissions.ask. That
#     is the mechanism check, not consent: the consent is the prompt;
#   - the deleting is ONE python program embedded below (python3 -I), not a subcommand of
#     trash-review.py (`python3 trash-review.py ...` is allowed and typable). It pins
#     ~/.Trash by file descriptor, takes the ledger as structured JSON, accepts only a
#     direct-child name, claims each entry by an atomic rename into a private quarantine
#     directory inside the Trash, verifies it is the object the ledger recorded (device
#     and inode) AFTER the claim, and deletes with directory-relative calls that never
#     follow a symlink (a symlink in the Trash is unlinked, its target untouched). Two
#     ledger records for one object that disagree (kept vs droppable) skip it. A droppable
#     item that is no longer in the Trash gets an `emptied` row ("already gone") and does not
#     fail the run. It takes the review's apply lock, so it never runs in the middle of a review.
#
# The delete uses plain unlink/rmdir on purpose: the rm-to-trash.sh hook rewrites the
# command text Claude runs, never the inside of a script, so this really deletes, and that
# is the point of the prompt. There is no --yes, --dry-run or environment switch.
#
# Exit: 0 done (or nothing to do); 1 something failed or was skipped; 2 usage;
#       3 environment (not -p, not Darwin, wrong home, not the install path, no Trash);
#       4 the permission rules are not installed; 5 not run from an approved Claude Code call;
#       6 a PermissionRequest hook is configured.
#
# Known limits (README, "Trash greenlight"): the installed script is a file the user's own
# account can edit, so an edited copy runs after a legitimate Yes; the prompt is consent to
# delete what the review marked droppable, and those marks are written by `trash-review.py
# apply`, which an agent can also run; the rule-presence check reads a file the same account
# can edit (the managed settings file is the answer to that, not to hooks); an agent can still
# write code of its own that deletes from ~/.Trash, as before this script existed.

case $- in
  *p*) ;;
  *) echo "trash-empty.sh: run it directly as ~/.megavibe/scripts/trash-empty.sh (not through bash, sh or source: privileged mode, -p, is what keeps the caller's environment out)" >&2
     return 3 2>/dev/null || exit 3 ;;
esac
[[ ${BASH_SOURCE[0]} == "$0" ]] || { echo "trash-empty.sh: refusing to be sourced" >&2; return 3 2>/dev/null || exit 3; }
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset BASH_ENV ENV CDPATH GLOBIGNORE IFS

die() { echo "trash-empty.sh: $2" >&2; exit "$1"; }
MODE=droppable
case $# in
  0) ;;
  1) if [ "$1" = "--all" ]; then MODE=all; else echo "usage: ~/.megavibe/scripts/trash-empty.sh [--all]" >&2; exit 2; fi ;;
  *) echo "usage: ~/.megavibe/scripts/trash-empty.sh [--all]" >&2; exit 2 ;;
esac

# python3 only from fixed directories; never through PATH.
PY=""
for _d in /opt/homebrew/bin /usr/local/bin /usr/bin; do
  if [ -x "$_d/python3" ]; then PY="$_d/python3"; break; fi
done
[ -n "$PY" ] || die 3 "python3 not found in /opt/homebrew/bin, /usr/local/bin or /usr/bin"

read -r -d '' TE_PY <<'EOPY' || true
#--- TE_PY BEGIN
import ctypes, errno, fcntl, json, os, pwd, re, stat, subprocess, sys, time, uuid

# Each of these is ONE line the tests replace in a scratch copy (a fake home, a fake managed
# file, no provenance gate, an interleaving hook). Nothing else in this program is rewritten.
OS_NAME = sys.platform  # TE_OS
MANAGED = "/Library/Application Support/ClaudeCode/managed-settings.json"  # TE_MANAGED
REQUIRE_PROVENANCE = True  # TE_GATE
def db_home(): return pwd.getpwuid(os.getuid()).pw_dir  # TE_HOME
def _hook(point, **kw): pass  # TE_HOOK

RULE_PATH = "Bash(~/.megavibe/scripts/trash-empty.sh *)"
RULE_ANY = "Bash(*trash-empty*)"
CLAUDE_TEAM = "Q6L2SF6YDW"          # Anthropic's Developer ID team (the OU of its signing certificate)
PS, CODESIGN, LSOF = "/bin/ps", "/usr/bin/codesign", "/usr/sbin/lsof"
RENAME_EXCL = 0x4


def die(code, msg):
    print("trash-empty.sh: " + msg, file=sys.stderr)
    sys.exit(code)


def show(s):
    return json.dumps(s, ensure_ascii=True)       # names printed to the terminal are escaped


# ---- who is asking: the Claude Code harness shell must carry exactly the asked command ----

# ps renders a newline as \012 and a tab as \011. The payload is the single-quoted argument of the
# harness shell's `eval`; a quote inside a payload is rendered '"'"' (Claude Code 2.1.30x with zsh;
# '\'' would do the same), so `eval '` followed by the approved path can only occur at the real start
# of the payload. The whole command line must have the measured shape: the snapshot sourced from the
# user's own ~/.claude, the eval of the approved payload from /dev/null, and the cwd file at the end.
# That rejects the bare `bash -c ... && eval '...'` that a hook, an MCP server or a helper command
# would produce by accident; it does not reject a command line written to imitate the shape
# (README, "Not covered").
_WS = r"(?: |\\011|\\012)*"


def harness_re(home):
    return re.compile(
        r"^(?:/bin|/usr/bin|/usr/local/bin|/opt/homebrew/bin)/(?:zsh|bash) (?:-[A-Za-z]+ )*-c (?:-[A-Za-z]+ )*source "
        + re.escape(home) + r"/\.claude/shell-snapshots/snapshot-(?:zsh|bash)-[0-9]+-[a-z0-9]+\.sh 2>/dev/null \|\| true && (?:.* && )?eval '"
        + _WS + r"(~/\.megavibe/scripts/trash-empty\.sh)( --all)?" + _WS
        + r"' < /dev/null && pwd -P >\| /tmp/claude-[0-9a-f]+-cwd$", re.S)


def ps_table():
    p = subprocess.run([PS, "-A", "-ww", "-o", "pid=,ppid=,comm="], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, universal_newlines=True, errors="replace")
    rows = {}
    for line in p.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            rows[int(parts[0])] = (int(parts[1]), parts[2] if len(parts) > 2 else "")
    return rows


def ps_cmd(pid):
    p = subprocess.run([PS, "-ww", "-o", "command=", "-p", str(int(pid))], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, universal_newlines=True, errors="replace")
    return p.stdout.rstrip("\n")


def ps_signed(pid):
    """True when the RUNNING process `pid` satisfies Anthropic's Developer ID requirement. codesign -v on a
    live pid checks the process itself, not a path that could name a different file than the one running."""
    req = 'anchor apple generic and certificate leaf[subject.OU] = "%s"' % CLAUDE_TEAM
    p = subprocess.run([CODESIGN, "-v", "-R=" + req, str(int(pid))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return p.returncode == 0


def ps_cwd(pid):
    """The working directory of `pid` ("" when it cannot be read)."""
    p = subprocess.run([LSOF, "-a", "-p", str(int(pid)), "-d", "cwd", "-Fn"], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, universal_newlines=True, errors="replace")
    for line in p.stdout.splitlines():
        if line.startswith("n"):
            return line[1:]
    return ""


def provenance_ex(table, cmd_of, signed_of, start, mode, home):
    """(reason, harness pid, claude pid). The reason is None when this process was started by Claude Code's Bash
    tool with exactly the asked command. Pure over the accessors it is given."""
    chain, seen, cur = [], set(), start
    while cur > 1 and cur not in seen and cur in table and len(chain) < 64:
        seen.add(cur)
        ppid, comm = table[cur]
        chain.append((cur, comm))
        cur = ppid
    claudes = [i for i, (_, comm) in enumerate(chain) if os.path.basename(comm.strip()) == "claude"]
    if not claudes:
        return "no Claude Code process above this script", None, None
    top = claudes[-1]                  # the TOPMOST claude: a look-alike can only sit below the real one
    if top < 3:                        # chain: this program, the shell script, the harness shell, claude
        return "no harness shell between this script and Claude Code", None, None
    cpid, hpid = chain[top][0], chain[top - 1][0]
    if not signed_of(cpid):
        return "the claude process is not Anthropic's signed Claude Code", None, None
    cmd = cmd_of(hpid)
    if not cmd:
        return "cannot read the harness shell's command line", None, None
    m = harness_re(home).match(cmd)
    if not m:
        if len(claudes) > 1:
            return ("this runs inside a claude that was itself started from another claude's Bash call, and the outermost "
                    "session's shell was not given exactly ~/.megavibe/scripts/trash-empty.sh as its only command"), None, None
        return "the shell Claude Code ran this in was not given exactly ~/.megavibe/scripts/trash-empty.sh as its only command", None, None
    if bool(m.group(2)) != (mode == "all"):
        return "the approved command and this run disagree about --all", None, None
    return None, hpid, cpid


def provenance(table, cmd_of, signed_of, start, mode, home):
    return provenance_ex(table, cmd_of, signed_of, start, mode, home)[0]


# ---- is the prompt installed, and can something else answer it ----------------------------

def has_rules(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return False
    perms = d.get("permissions") if isinstance(d, dict) else None
    ask = perms.get("ask") if isinstance(perms, dict) else None
    return isinstance(ask, list) and RULE_PATH in ask and RULE_ANY in ask


def permission_hook_in(path):
    """True when the settings file at `path` configures a PermissionRequest hook: a hook that Claude Code runs
    instead of asking you, and that can answer Yes for you. A file that does not parse is judged by its text."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return False
    try:
        d = json.loads(text)
    except ValueError:
        return "PermissionRequest" in text
    hooks = d.get("hooks") if isinstance(d, dict) else None
    return isinstance(hooks, dict) and bool(hooks.get("PermissionRequest"))


def permission_hook_source(home, managed, cwds):
    """The first settings file that configures a PermissionRequest hook, or None. Looked at: the managed file, the user's
    settings.json and settings.local.json, and for each working directory given, .claude/settings.json and
    .claude/settings.local.json in it and in every directory above it. Plugins and agent or skill frontmatter are not."""
    sources = [managed, os.path.join(home, ".claude", "settings.json"), os.path.join(home, ".claude", "settings.local.json")]
    for c in cwds:
        d = os.path.realpath(c) if c else ""
        while d:
            sources += [os.path.join(d, ".claude", "settings.json"), os.path.join(d, ".claude", "settings.local.json")]
            if d == "/":
                break
            d = os.path.dirname(d)
    seen = set()
    for s in sources:
        if s not in seen:
            seen.add(s)
            if permission_hook_in(s):
                return s
    return None


# ---- ledger ----------------------------------------------------------------------------

def read_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    rows.append(r)
    except OSError:
        pass
    return rows


def merged_ledger(rows):
    """One record per id; a later line for the same id (a relocation) updates it."""
    by_id = {}
    for r in rows:
        i = r.get("id")
        if not isinstance(i, str):
            continue
        if i in by_id:
            by_id[i].update(r)
        elif "path" in r:
            by_id[i] = dict(r)
    return list(by_id.values())


def latest_decisions(rows):
    latest = {}
    for r in rows:
        if r.get("ok") and isinstance(r.get("id"), str):
            latest[r["id"]] = r.get("action")
    return latest


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def conflict(c, recs, latest):
    """Another record for the same object (same inode, or same Trash name) whose latest decision is
    not a final one and not droppable: the review does not agree that this object may go."""
    for r in recs:
        if r is c:
            continue
        if (r.get("dev"), r.get("ino")) == (c.get("dev"), c.get("ino")) or r.get("trash_path") == c.get("trash_path"):
            if latest.get(r.get("id")) not in ("droppable", "restore", "backup", "emptied"):
                return r
    return None


# ---- file-descriptor-relative deletion --------------------------------------------------

def rename_excl(src, sfd, dst, dfd):
    lib = ctypes.CDLL(None, use_errno=True)
    fn = getattr(lib, "renameatx_np", None)
    if fn is None:
        try:
            os.stat(dst, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            os.rename(src, dst, src_dir_fd=sfd, dst_dir_fd=dfd)
            return
        raise FileExistsError(errno.EEXIST, "exists", dst)
    if fn(sfd, os.fsencode(src), dfd, os.fsencode(dst), RENAME_EXCL) != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e), dst)


def rm_at(dfd, name):
    """Delete the entry `name` under dfd without ever following a symlink."""
    st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
    if not stat.S_ISDIR(st.st_mode):
        os.unlink(name, dir_fd=dfd)
        return
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)
    first = None
    try:
        fs = os.fstat(fd)
        if (fs.st_dev, fs.st_ino) != (st.st_dev, st.st_ino):
            raise OSError(errno.ESTALE, "changed while being emptied", name)
        for ent in list(os.scandir(fd)):
            try:
                rm_at(fd, ent.name)
            except (OSError, RecursionError) as e:
                first = first or e
    finally:
        os.close(fd)
    if first:
        raise first
    os.rmdir(name, dir_fd=dfd)


class Trash:
    """~/.Trash pinned by descriptor, plus a private quarantine directory inside it."""

    def __init__(self, home):
        self.home = home
        self.path = os.path.join(home, ".Trash")
        try:
            self.fd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError as e:
            die(3, "%s is not a directory (or is a symlink): %s" % (self.path, e.strerror))
        if os.fstat(self.fd).st_uid != os.getuid():
            die(3, "%s is not yours" % self.path)
        self.qname = self.qfd = None
        self.n = 0

    def quarantine(self):
        if self.qfd is None:
            self.qname = ".megavibe-empty-" + uuid.uuid4().hex[:12]
            try:
                os.mkdir(self.qname, 0o700, dir_fd=self.fd)
                self.qfd = os.open(self.qname, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
            except OSError as e:
                die(3, "cannot make a quarantine directory in %s: %s" % (self.path, e.strerror))
        return self.qfd

    def remove(self, name, want):
        """Claim `name` by an atomic rename, check it is the object `want` (dev, ino) AFTER the claim,
        then delete it. Returns (state, detail): ok / skip (nothing was deleted) / fail."""
        qfd = self.quarantine()
        self.n += 1
        slot = "%06d" % self.n
        try:
            os.rename(name, slot, src_dir_fd=self.fd, dst_dir_fd=qfd)
        except OSError as e:
            return ("skip" if e.errno == errno.ENOENT else "fail"), "claim failed: " + e.strerror
        try:
            got = os.stat(slot, dir_fd=qfd, follow_symlinks=False)
        except OSError as e:
            return "fail", "claimed but unreadable: " + e.strerror
        if (got.st_dev, got.st_ino) != tuple(want):
            try:
                rename_excl(slot, qfd, name, self.fd)
                where = "put back"
            except OSError:
                where = "could NOT be put back: it is in %s" % self.qname
            return "skip", "replaced since it was marked (the object now there was %s)" % where
        _hook("after_claim", home=self.home, tfd=self.fd, name=name, slot=slot, qfd=qfd)
        try:
            rm_at(qfd, slot)
        except (OSError, RecursionError) as e:
            try:
                rename_excl(slot, qfd, name, self.fd)       # what is left gets its name back for a later run
            except OSError:
                pass
            return "fail", str(getattr(e, "strerror", None) or e)
        return "ok", ""

    def finish(self):
        if self.qfd is not None:
            os.close(self.qfd)
            try:
                os.rmdir(self.qname, dir_fd=self.fd)
            except OSError:
                print("note: something is left in %s inside the Trash" % self.qname, file=sys.stderr)


def append_rows(path, rows):
    if not rows:
        return
    try:
        with open(path, "a", encoding="utf-8") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
    except OSError as e:
        print("note: could not record %d row(s) in %s: %s" % (len(rows), path, e.strerror), file=sys.stderr)


def main():
    if len(sys.argv) != 4:
        die(2, "internal error: bad arguments")
    mode, selfpath, env_home = sys.argv[1:4]
    if OS_NAME != "darwin":
        die(3, "macOS only (the Trash and its ledger are macOS-specific)")
    need = (os.rename, os.mkdir, os.unlink, os.rmdir, os.stat, os.open)
    if not all(f in os.supports_dir_fd for f in need) or os.scandir not in os.supports_fd or os.stat not in os.supports_follow_symlinks:
        die(3, "this python lacks directory-relative file operations")
    home = db_home()
    if not home or not env_home or os.path.realpath(env_home) != os.path.realpath(home):
        die(3, "$HOME (%s) is not your home directory (%s)" % (env_home, home))
    inst = os.path.join(home, ".megavibe", "scripts")
    if (os.path.islink(selfpath) or not os.path.isfile(selfpath) or os.path.basename(selfpath) != "trash-empty.sh"
            or os.path.realpath(os.path.dirname(os.path.abspath(selfpath))) != os.path.realpath(inst)):
        die(3, "run it from its install path: ~/.megavibe/scripts/trash-empty.sh (not a copy or a symlink)")
    if not (has_rules(MANAGED) or has_rules(os.path.join(home, ".claude", "settings.json"))):
        die(4, "the permission prompt that gates this script is not installed; run setup.sh (it adds the permissions.ask rules)")
    cwds = []
    if REQUIRE_PROVENANCE:
        why, hpid, cpid = provenance_ex(ps_table(), ps_cmd, ps_signed, os.getpid(), mode, home)
        if why:
            die(5, why + ". Run it as typed from a Claude Code session so you get the approval prompt, "
                         "or empty the Trash in Finder.")
        cwds = [c for c in (ps_cwd(hpid), ps_cwd(cpid)) if c]
        if not cwds:
            print("note: could not read the session's working directory, so project settings were not checked "
                  "for a PermissionRequest hook", file=sys.stderr)
    hook = permission_hook_source(home, MANAGED, cwds)
    if hook:
        die(6, "%s configures a PermissionRequest hook, which can answer the approval prompt without you. "
               "Remove it, or empty the Trash in Finder." % hook)

    sys.setrecursionlimit(5000)
    ldir = os.path.join(home, ".megavibe", "trash")
    try:
        os.makedirs(ldir, exist_ok=True)
        lockfd = os.open(os.path.join(ldir, "apply.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    except OSError as e:
        die(3, "cannot use %s: %s" % (ldir, e.strerror))
    for _ in range(150):                                   # the review's own lock: never run in the middle of one
        try:
            fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            time.sleep(0.2)
    else:
        die(1, "a Trash review is running; try again in a moment")

    trash = Trash(home)
    _hook("after_open_trash", home=home, tfd=trash.fd)
    ledger_rows, reviewed_rows = read_jsonl(os.path.join(ldir, "ledger.jsonl")), read_jsonl(os.path.join(ldir, "reviewed.jsonl"))
    recs, latest = merged_ledger(ledger_rows), latest_decisions(reviewed_rows)
    emptied = failed = skipped = gone = kb = 0
    out_rows = []

    def row(rec, ok, detail):
        r = {"id": rec["id"], "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "action": "emptied", "ok": ok,
             "kb": max(rec.get("kb", 0), 0) if is_int(rec.get("kb")) else 0, "path": rec.get("path", ""), "detail": detail}
        out_rows.append(r)
        return r["kb"]

    def done(name, state, detail, recs_for):
        nonlocal emptied, failed, skipped, gone, kb
        if state == "gone":            # restored, backed up or emptied in Finder since it was marked: nothing left to do
            gone += 1
            print("gone:    %s (no longer in the Trash)" % show(name))
            for rec in recs_for:
                row(rec, True, "already gone from the Trash")
        elif state == "ok":
            emptied += 1
            print("emptied: " + show(name))
            for rec in recs_for:
                kb += row(rec, True, "emptied from the Trash")
        elif state == "fail":
            failed += 1
            print("failed:  %s (%s)" % (show(name), detail), file=sys.stderr)
            for rec in recs_for:
                row(rec, False, "emptying failed: " + detail)
        else:
            skipped += 1
            print("skipped: %s (%s)" % (show(name), detail), file=sys.stderr)

    try:
        if mode == "droppable":
            cands = [r for r in recs if latest.get(r.get("id")) == "droppable"]
            if not cands:
                print("nothing marked droppable; run the Trash review first")
            for c in cands:
                tp = c.get("trash_path")
                label = tp if isinstance(tp, str) else str(c.get("id"))
                if not (isinstance(tp, str) and is_int(c.get("dev")) and is_int(c.get("ino"))):
                    done(label, "skip", "the ledger record is incomplete", [])
                    continue
                d, name = os.path.split(tp)
                if "\0" in tp or tp.endswith("/") or d != trash.path or name in ("", ".", ".."):
                    done(label, "skip", "not a direct child of %s" % trash.path, [])
                    continue
                bad = conflict(c, recs, latest)
                if bad is not None:
                    done(name, "skip", "another record for this object (%s) is not marked droppable" % bad.get("id"), [])
                    continue
                try:
                    st = os.stat(name, dir_fd=trash.fd, follow_symlinks=False)
                except FileNotFoundError:
                    done(name, "gone", "", [c])
                    continue
                except OSError as e:
                    done(name, "skip", "cannot look at it: " + e.strerror, [])
                    continue
                if (st.st_dev, st.st_ino) != (c["dev"], c["ino"]):
                    done(name, "skip", "replaced since it was marked droppable", [])
                    continue
                _hook("after_check", home=home, tfd=trash.fd, name=name)
                state, detail = trash.remove(name, (c["dev"], c["ino"]))
                done(name, state, detail, [c])
        else:
            try:
                names = sorted(e.name for e in os.scandir(trash.fd))
            except OSError as e:
                die(3, "cannot list %s: %s" % (trash.path, e.strerror))
            for name in names:
                if name == trash.qname:
                    continue
                try:
                    st = os.stat(name, dir_fd=trash.fd, follow_symlinks=False)
                except FileNotFoundError:
                    done(name, "gone", "", [])
                    continue
                except OSError as e:
                    done(name, "skip", "cannot look at it: " + e.strerror, [])
                    continue
                _hook("after_check", home=home, tfd=trash.fd, name=name)
                tp = os.path.join(trash.path, name)
                match = [r for r in recs if r.get("trash_path") == tp and (r.get("dev"), r.get("ino")) == (st.st_dev, st.st_ino)]
                state, detail = trash.remove(name, (st.st_dev, st.st_ino))
                done(name, state, detail, match)
    finally:                           # even on an unexpected error: leave no quarantine, record what was done
        trash.finish()
        append_rows(os.path.join(ldir, "reviewed.jsonl"), out_rows)
    summary = "mode=%s emptied=%d failed=%d skipped=%d gone=%d kb=%d" % (mode, emptied, failed, skipped, gone, kb)
    if emptied or failed or skipped or gone:
        print(summary)
    try:
        with open(os.path.join(ldir, "empty.log"), "a", encoding="utf-8") as f:
            f.write("%s user=%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), pwd.getpwuid(os.getuid()).pw_name, summary))
    except OSError:
        pass
    return 0 if not failed and not skipped else 1


if __name__ == "__main__":
    sys.exit(main())
#--- TE_PY END
EOPY

/usr/bin/env -i PATH="$PATH" HOME="${HOME:-}" LC_ALL=C "$PY" -I -c "$TE_PY" "$MODE" "$0" "${HOME:-}"
exit $?
