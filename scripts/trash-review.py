#!/usr/bin/env python3
"""Ledger and review of what agents moved to the Trash.

rm-to-trash.sh rewrites every `rm` to scripts/trash.sh, which runs `trash` here:
each operand is renamed into the Trash under a name carrying its ledger id
("<name> mv-<id>"), and the ledger records the original path, that exact Trash
entry and its inode. Past a threshold, the trash-watch.sh hook tells the session
to have the user decide, per group of items, to restore, keep in the Trash, back
up, or mark them droppable.

  trash-review.py trash [rm options] PATH...   what trash.sh runs; exit 3 = not handled, use rmtrash
  trash-review.py status            counts of unreviewed and droppable items
  trash-review.py droppable [--json]  the items marked droppable that are still in the Trash (read only)
  trash-review.py pending [--json]  unreviewed items still in the Trash (--all: kept and droppable ones too)
  trash-review.py nudge             hook helper: prints a message once per threshold crossing
  trash-review.py group FILE        FILE: {"groups": [{"label": "...", "ids": [...]}]}; registers the
                                    groups and prints one summary line per group, "[G<code>] ...",
                                    to be put VERBATIM into the question asked about that group
  trash-review.py apply FILE        FILE: {"decisions": [{"group": "G<code>", "action": "restore|keep|backup|droppable"}]}
  trash-review.py backup-dir        where `backup` moves items

Everything lives in $MEGAVIBE_TRASH_LEDGER_DIR (default ~/.megavibe/trash):
ledger.jsonl (one line per trashed item, append-only), reviewed.jsonl (one line
per decision, append-only), groups.jsonl (registered groups), nudge.json (hook state).

Every action first moves the recorded Trash entry into a private claim directory
and checks it is the same object (device and inode) there, and never replaces
anything at its destination; an item left in the claim directory by a failed or
interrupted action is put back into the Trash at the start of the next apply. A move
to another volume COPIES (a symlink as a symlink) and leaves the original in the Trash.

Nothing in this file deletes. "droppable" leaves the item in the Trash and counts it in
`status`, so the user can empty the Trash knowing what is in it. Megavibe sessions
run with permissions bypassed, and three review rounds found every agent-run
consent check forgeable (env overrides, transcript appends, pseudo-terminals), so
no consent check lives here. The permanent delete is scripts/trash-empty.sh, a shell
script that runs only behind a Claude Code permission prompt (an ask rule, honoured
under bypass and forwarded to the phone); it reads the droppable list from here, and
the user can still empty the Trash in Finder instead. The delete is deliberately not a
subcommand of this file: `python3 trash-review.py ...` is allowed and easy to type.
"""
import ctypes, errno, fcntl, json, os, shutil, stat, subprocess, sys, tempfile, time, uuid

HOME = os.path.expanduser("~")
DIR = os.environ.get("MEGAVIBE_TRASH_LEDGER_DIR") or os.path.join(HOME, ".megavibe", "trash")
TRASH = os.environ.get("MEGAVIBE_TRASH_DIR") or os.path.join(HOME, ".Trash")
LEDGER = os.path.join(DIR, "ledger.jsonl")
REVIEWED = os.path.join(DIR, "reviewed.jsonl")
NUDGE = os.path.join(DIR, "nudge.json")
GROUPS = os.path.join(DIR, "groups.jsonl")
LOCK = os.path.join(DIR, "apply.lock")
CLAIM = os.path.join(DIR, "claim")
NOT_HANDLED = 3


def env_int(name, default):
    try:
        v = int(os.environ.get(name, default))
        return v if v > 0 else default
    except ValueError:
        return default


COUNT_MAX = env_int("MEGAVIBE_TRASH_REVIEW_COUNT", 30)
MB_MAX = env_int("MEGAVIBE_TRASH_REVIEW_MB", 2048)


def append(path, rows):
    if not rows:
        return
    os.makedirs(DIR, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            out = []
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
            return out
    except OSError:
        return []


def size_kb(p):
    if os.path.islink(p) or not os.path.isdir(p):
        try:
            return os.lstat(p).st_blocks // 2
        except OSError:
            return 0
    try:   # du is bounded: a huge tree must not stall the user's rm
        r = subprocess.run(["du", "-sk", p], capture_output=True, text=True, timeout=10)
        return int(r.stdout.split()[0])
    except (subprocess.TimeoutExpired, ValueError, IndexError, OSError):
        return -1


# ---- moves that never replace -----------------------------------------------

_libc = ctypes.CDLL(None, use_errno=True)
_renamex = getattr(_libc, "renamex_np", None)
RENAME_EXCL = 0x4


def rename_noreplace(src, dst):
    """rename(2) that fails with EEXIST instead of replacing dst (macOS renamex_np)."""
    if _renamex is None:
        if os.path.lexists(dst):
            raise FileExistsError(errno.EEXIST, "exists", dst)
        os.rename(src, dst)          # SHORTCUT: not atomic off macOS; megavibe's Trash path is macOS-only
        return
    if _renamex(os.fsencode(src), os.fsencode(dst), ctypes.c_uint(RENAME_EXCL)) != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e), dst)


def move_noreplace(src, dst):
    """Move src to dst without replacing anything. Returns True when src was moved, False
    when dst is on another volume: then src is COPIED (a symlink as a symlink) and the
    source stays where it is, because removing it would be a real delete."""
    try:
        rename_noreplace(src, dst)
        return True
    except OSError as e:
        if e.errno != errno.EXDEV:
            raise
    # Copy into a fresh staging name beside dst (mkdtemp: created exclusively, so nothing
    # can be planted there), then publish with a no-replace rename on that volume.
    for root, dirs, files in ([("", [], [src])] if not os.path.isdir(src) or os.path.islink(src) else os.walk(src)):
        for f in files + dirs:
            m = os.lstat(os.path.join(root, f)).st_mode
            if stat.S_ISFIFO(m) or stat.S_ISSOCK(m) or stat.S_ISCHR(m) or stat.S_ISBLK(m):
                raise OSError(errno.EINVAL, "contains a FIFO, socket or device file; not copied", os.path.join(root, f))
    stage = tempfile.mkdtemp(prefix=".mv-stage-", dir=os.path.dirname(dst))
    tmp = os.path.join(stage, "item")
    try:
        if os.path.islink(src):
            os.symlink(os.readlink(src), tmp)
        elif shutil.which("ditto"):          # macOS: keeps resource forks, xattrs and ACLs
            subprocess.run(["ditto", "--rsrc", "--extattr", "--acl", src, tmp], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        elif os.path.isdir(src):
            shutil.copytree(src, tmp, symlinks=True)
        else:
            shutil.copy2(src, tmp, follow_symlinks=False)
        rename_noreplace(tmp, dst)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    return False


# ---- trash (what scripts/trash.sh runs) -------------------------------------

LONG = {"--recursive": "r", "--force": "f", "--dir": "d", "--verbose": "v"}


def parse_rm(args):
    """(options, operands) for the rm options this handles, or None: then rmtrash does it all.
    Options end at the first operand, as in BSD rm (`rm d -r` names a file called -r)."""
    opts, ops, done = set(), [], False
    for a in args:
        if done or a == "-" or not a.startswith("-"):
            done = True
            ops.append(a)
        elif a == "--":
            done = True
        elif a.startswith("--"):
            if a not in LONG:
                return None
            opts.add(LONG[a])
        else:
            if not set(a[1:]) <= set("rRfdv"):
                return None            # -i, -I, -x, -P, -W ...: leave them to rmtrash
            opts |= set(a[1:].replace("R", "r"))
    return opts, ops


def trash_name(base, suffix):
    """`<base><suffix>` cut to fit NAME_MAX (255 bytes), keeping the suffix with the id whole."""
    room = 255 - len(suffix.encode())
    b = base.encode()
    if len(b) > room:
        base = b[:room].decode("utf-8", "ignore")
    return base + suffix


def rmtrash_one(opts, o):
    rt = shutil.which("rmtrash")
    if not rt:
        return 1
    flags = ["-" + "".join(sorted(opts))] if opts else []
    return subprocess.run([rt] + flags + ["--", o]).returncode


def cmd_trash(args):
    if os.environ.get("MEGAVIBE_TRASH_DIR") and not os.path.isdir(TRASH):
        print(f"trash.sh: MEGAVIBE_TRASH_DIR={TRASH} is not a directory; refusing to delete", file=sys.stderr)
        return 1
    p = parse_rm(args)
    if p is None or not os.path.isdir(TRASH):
        return NOT_HANDLED
    opts, ops = p
    if not ops:
        if "f" in opts:
            return 0
        print("usage: rm [-f | -i] [-dIRrvWx] file ...", file=sys.stderr)
        return 64
    tdev = os.stat(TRASH).st_dev
    rc, rows = 0, []
    try:
        for o in ops:
            try:
                rc = trash_one(o, opts, tdev, rows) or rc
            except OSError as e:
                print(f"rm: {o}: {e.strerror}", file=sys.stderr); rc = 1
    finally:
        try:
            append(LEDGER, rows)
        except OSError as e:           # the items are in the Trash; only the record failed
            print(f"trash.sh: could not record {len(rows)} item(s) in {LEDGER}: {e.strerror}", file=sys.stderr)
    return rc


def trash_one(o, opts, tdev, rows):
    """Trash one operand the way rm would remove it; returns its exit status."""
    if o == "":
        if "f" in opts:
            return 0
        print("rm: : No such file or directory", file=sys.stderr); return 1
    stripped = o.rstrip("/") or "/"
    base = os.path.basename(stripped)
    if base in ("", ".", "..") or stripped == "/" or (not os.path.islink(stripped) and os.path.realpath(stripped) == "/"):
        print(f'rm: "{o}" may not be removed', file=sys.stderr); return 1
    if not os.path.lexists(stripped):
        if "f" in opts:
            return 0
        print(f"rm: {o}: No such file or directory", file=sys.stderr); return 1
    if stripped != o and os.path.islink(stripped):
        # `link/` means the directory behind the link to rm, the link to rmtrash: refuse to guess.
        print(f"rm: {o}: trailing slash on a symlink; name the link or its target", file=sys.stderr); return 1
    # The entry the filesystem means: parent resolved (a symlink, then `..`), last component kept.
    path = os.path.join(os.path.realpath(os.path.dirname(stripped) or "."), base)
    st = os.lstat(path)
    isdir = stat.S_ISDIR(st.st_mode)
    if isdir and "r" not in opts and not ("d" in opts and not os.listdir(path)):
        print(f"rm: {o}: " + ("Directory not empty" if "d" in opts else "is a directory"), file=sys.stderr); return 1
    row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "path": path, "kind": "dir" if isdir else "file",
           "cwd": os.getcwd(), "session": os.environ.get("CLAUDE_CODE_SESSION_ID", "")}
    if st.st_dev == tdev:
        iid = uuid.uuid4().hex[:12]
        dst = os.path.join(TRASH, trash_name(base, f" mv-{iid}"))
        kb = size_kb(path)
        try:
            rename_noreplace(path, dst)
        except OSError:
            dst = None                 # refused (privacy controls on ~/.Trash): rmtrash below
        if dst:
            # The identity of the object we moved, taken before the move (rename keeps it), never
            # whatever occupies dst afterwards: a replacement there then fails every later check.
            rows.append(dict(row, id=iid, trash_path=dst, dev=st.st_dev, ino=st.st_ino, kb=kb))
            if "v" in opts:
                print(o)
            return 0
    # Another volume (its own Trash) or a refused rename: rmtrash, recorded but not restorable here.
    r1 = rmtrash_one(opts, stripped)
    if r1 == 0 and not os.path.lexists(path):
        rows.append(dict(row, id=uuid.uuid4().hex[:12], trash_path=None, kb=-1))
    return 1 if r1 else 0


# ---- review -----------------------------------------------------------------

def same_entry(r):
    """The recorded Trash entry, still there and still the same object."""
    tp = r.get("trash_path")
    if not tp:
        return False
    try:
        st = os.lstat(tp)
    except OSError:
        return False
    return (st.st_dev, st.st_ino) == (r.get("dev"), r.get("ino")) \
        and os.path.realpath(os.path.dirname(tp)) == os.path.realpath(TRASH)


def ledger():
    """One record per id; a later line for the same id (a relocation) updates it."""
    by_id = {}
    for r in read(LEDGER):
        i = r.get("id")
        if i in by_id:
            by_id[i].update(r)
        elif "path" in r:
            by_id[i] = r
    return list(by_id.values())


def reviewable():
    """Ledger items still in the Trash that no review moved out: Keep and droppable items
    can still be restored or backed up later (Finder's Put Back does not know them)."""
    gone = {r.get("id") for r in read(REVIEWED) if r.get("ok") and r.get("action") in ("restore", "backup")}
    out = []
    for r in ledger():
        if r.get("id") in gone:
            continue
        r["in_trash"] = same_entry(r)
        out.append(r)
    return out


def pending():
    done = {r.get("id") for r in read(REVIEWED) if r.get("ok")}
    out = []
    for r in ledger():
        if r.get("id") in done:
            continue
        r["in_trash"] = same_entry(r)
        out.append(r)
    return out


def droppable():
    latest = {}
    for r in read(REVIEWED):              # the LATEST successful decision per item counts
        if r.get("ok"):
            latest[r.get("id")] = r.get("action")
    ids = {i for i, a in latest.items() if a == "droppable"}
    return [r for r in ledger() if r.get("id") in ids and same_entry(r)]


def totals(items):
    live = [r for r in items if r["in_trash"]]
    return len(live), sum(max(r.get("kb", 0), 0) for r in live) // 1024


def cmd_status():
    n, mb = totals(pending())
    print(f"{n} unreviewed item(s) in the Trash, {mb} MB (review at {COUNT_MAX} items or {MB_MAX} MB)")
    try:
        stuck = os.listdir(CLAIM)
    except OSError:
        stuck = []
    if stuck:
        print(f"{len(stuck)} item(s) stranded in {CLAIM} by an interrupted review: the next apply puts them back")
    d = droppable()
    if d:
        kb = sum(max(r.get("kb", 0), 0) for r in d)
        print(f"{len(d)} item(s), {human(kb)}, marked droppable: ~/.megavibe/scripts/trash-empty.sh frees them "
              f"(a permission prompt asks first, also on the phone), or empty the Trash in Finder")


def cmd_droppable(as_json):
    """Read only: what trash-empty.sh may delete. Every row is checked against the Trash
    (same entry, same inode) here, and again by the script right before it deletes."""
    for r in droppable():
        if as_json:
            print(json.dumps({k: r.get(k) for k in ("id", "trash_path", "dev", "ino", "kb", "path")}, ensure_ascii=False))
        else:
            print(f'{r["id"]}  {max(r.get("kb", 0), 0):>9} KB  {r["path"]}')


def cmd_pending(as_json, everything=False):
    items = [r for r in (reviewable() if everything else pending()) if r["in_trash"]]
    if as_json:
        for r in items:
            print(json.dumps({k: r.get(k) for k in ("id", "ts", "path", "kind", "kb", "cwd", "session")}, ensure_ascii=False))
        return
    for r in items:
        print(f'{r["id"]}  {r["ts"]}  {r.get("kb", 0):>9} KB  {r["kind"]:<4}  {r["path"]}')


def _over(items):
    return len(items) >= COUNT_MAX or sum(max(r.get("kb", 0), 0) for r in items) // 1024 >= MB_MAX


def _nudge_due(sid):
    """(due, crossing, live). A crossing: the items that became pending since the last nudge
    reach the threshold (counted by id, so a review between two deletes cannot hide them).
    Deferred: a session that was not told yet, while the pending total is over the threshold
    (an unattended run may leave the review for the next attended session)."""
    live = [r for r in pending() if r["in_trash"]]
    try:
        with open(NUDGE, encoding="utf-8") as f:
            st = json.load(f)
        seen, told = set(st.get("ids", [])), list(st.get("sessions", []))
    except (OSError, ValueError, AttributeError):
        seen, told = set(), []
    crossing = _over([r for r in live if r["id"] not in seen])
    deferred = bool(sid) and sid not in told and _over(live)
    return crossing or deferred, crossing, live, told


def cmd_nudge(peek=False, sid=""):
    due, crossing, live, told = _nudge_due(sid)
    if not due:
        return
    if not peek:
        _save_nudge(live, crossing, told, sid)
    n, mb_all = totals(live)
    print(f"{n} item(s), {mb_all} MB, went to the Trash and nobody has reviewed them.")


def _save_nudge(live, crossing, told, sid):
    os.makedirs(DIR, exist_ok=True)
    told = ([] if crossing else told) + ([sid] if sid and sid not in told else [])
    tmp = NUDGE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"ids": [r["id"] for r in live], "sessions": told[-50:]}, f)
    os.replace(tmp, NUDGE)


def backup_dir():
    d = os.environ.get("MEGAVIBE_TRASH_BACKUP_DIR")
    if d:
        return os.path.expanduser(d)
    icloud = os.path.join(HOME, "Library", "Mobile Documents", "com~apple~CloudDocs")
    return os.path.join(icloud if os.path.isdir(icloud) else HOME, "megavibe-trash-backup")


def claim(r):
    """Atomically take the recorded Trash entry into the private claim directory, then check it
    is the recorded object. Nothing else writes there, so nothing can swap it between the check
    and the action that follows. Returns the claimed path, or None (put back untouched)."""
    tp = r.get("trash_path")
    if not same_entry(r):
        return None
    os.makedirs(CLAIM, mode=0o700, exist_ok=True)
    cp = os.path.join(CLAIM, r["id"])
    try:
        rename_noreplace(tp, cp)
    except OSError:
        return None
    st = os.lstat(cp)
    if (st.st_dev, st.st_ino) != (r.get("dev"), r.get("ino")):
        unclaim(r, cp)                        # not ours: put it back untouched
        return None
    return cp


def unclaim(r, cp):
    """Put a claimed item back into the Trash: its recorded name, or a fresh one when
    something took that name meanwhile (the move is then recorded in the ledger)."""
    try:
        rename_noreplace(cp, r["trash_path"])
        return True
    except OSError:
        pass
    base = os.path.basename(r["path"])
    for n in range(1, 100):
        tp = os.path.join(TRASH, trash_name(base, f' mv-{r["id"]}-{n}'))
        try:
            rename_noreplace(cp, tp)
        except OSError:
            continue
        r["trash_path"] = tp
        try:
            append(LEDGER, [{"id": r["id"], "trash_path": tp, "relocated": time.strftime("%Y-%m-%dT%H:%M:%S%z")}])
        except OSError:
            pass
        return True
    return False


def recover_claims():
    """Put back anything a failed or interrupted action left in the claim directory."""
    try:
        names = os.listdir(CLAIM)
    except OSError:
        return
    by_id = {r.get("id"): r for r in ledger()}
    for n in names:
        r = by_id.get(n)
        if r and r.get("trash_path") and not unclaim(r, os.path.join(CLAIM, n)):
            print(f"{n}: still in {CLAIM} (its Trash name is taken): move it back by hand", file=sys.stderr)


def apply_one(r, action):
    orig = r["path"]
    if action in ("keep", "droppable"):
        if not same_entry(r):
            return False, "refused: the recorded Trash entry is gone or was replaced"
        return True, "kept in the Trash" + (", marked droppable" if action == "droppable" else "")
    if action not in ("restore", "backup"):
        return False, f"unknown action {action!r}"
    # Everything that can fail before the move happens before the claim.
    if action == "restore":
        targets = [orig]
        os.makedirs(os.path.dirname(orig), exist_ok=True)
    else:
        root = os.path.realpath(backup_dir())
        dest = os.path.join(root, time.strftime("%Y-%m-%d"), orig.lstrip("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if not os.path.realpath(os.path.dirname(dest)).startswith(root + os.sep):
            return False, f"refused: {os.path.dirname(dest)} leads out of {root} through a symlink"
        targets = [dest, f'{dest}.{r["id"]}']
    cp = claim(r)
    if cp is None:
        return False, "refused: the recorded Trash entry is gone or was replaced"
    def put_back(msg, ok=False):
        if unclaim(r, cp):
            return ok, msg + ("" if ok else "; left in the Trash")
        return False, msg + f"; could NOT be put back: it is in {cp}"
    try:
        for d in targets:
            try:
                moved = move_noreplace(cp, d)
            except FileExistsError:
                continue
            verb = "restored to " if action == "restore" else "backed up to "
            if moved:
                return True, verb + d
            return put_back(verb.replace("to ", "(copied) to ") + d + "; the original stays in the Trash", ok=True)
        return put_back("refused: " + " and ".join(targets) + " exist(s); nothing replaced")
    except BaseException as e:
        if os.path.lexists(cp):
            ok, msg = put_back(f"error: {e}")
            if isinstance(e, (OSError, subprocess.CalledProcessError)):
                return ok, msg
        raise


def human(kb):
    return f"{kb / 1048576:.1f} GB" if kb >= 1048576 else f"{kb / 1024:.0f} MB" if kb >= 1024 else f"{kb} KB"


def cmd_group(path):
    with open(path, encoding="utf-8") as f:
        spec = json.load(f)
    by_id = {r["id"]: r for r in reviewable() if r["in_trash"]}
    rows, seen = [], set()
    for g in spec.get("groups", []):
        ids = [i for i in g.get("ids", []) if i in by_id and i not in seen]
        if not ids:
            continue
        seen.update(ids)
        paths = [by_id[i]["path"] for i in ids]
        code = "G" + uuid.uuid4().hex[:5]
        kb = sum(max(by_id[i].get("kb", 0), 0) for i in ids)
        prefix = os.path.commonpath(paths) if len(paths) > 1 else os.path.dirname(paths[0])
        sample = ", ".join(os.path.relpath(p, prefix) for p in paths[:4]) + (", ..." if len(paths) > 4 else "")
        summary = f"[{code}] {len(ids)} item(s), {human(kb)}, under {prefix}: {sample}"
        rows.append({"code": code, "ids": ids, "label": str(g.get("label", ""))[:200], "summary": summary,
                     "ts": time.time(), "session": os.environ.get("CLAUDE_CODE_SESSION_ID", "")})
        print(f'{summary}  ({g.get("label", "")})')
    append(GROUPS, rows)
    unreviewed = {r["id"] for r in pending()}
    missing = [i for i in by_id if i not in seen and i in unreviewed]
    if missing:
        print(f"not grouped (still pending): {len(missing)} item(s)")


def groups():
    return {g["code"]: g for g in read(GROUPS)}


def cmd_apply(path):
    with open(path, encoding="utf-8") as f:
        spec = json.load(f)
    decisions = spec.get("decisions", [])
    os.makedirs(DIR, exist_ok=True)
    with open(LOCK, "a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)    # one review at a time: pending state, action and record together
        recover_claims()
        gs = groups()
        seen = {}
        for d in decisions:
            g = gs.get(d.get("group"))
            if g is None:
                print(f'{d.get("group")}: unknown group (register it with `group` first); nothing applied')
                return 1
            for i in g["ids"]:
                if i in seen:
                    print(f"{i}: in two decisions ({seen[i]} and {g['code']}); nothing applied")
                    return 1
                seen[i] = g["code"]
        by_id = {r["id"]: r for r in reviewable()}
        rows, rc = [], 0
        try:
            for d in decisions:
                g = gs[d["group"]]
                for i in g["ids"]:
                    r = by_id.get(i)
                    if r is None:
                        print(f"{i}: not in the Trash any more (restored, backed up, emptied, or copied across volumes with the original left in the Trash)"); rc = 1; continue
                    try:
                        ok, msg = apply_one(r, d.get("action"))
                    except OSError as e:          # before the claim: nothing moved
                        ok, msg = False, f"error: {e}; left in the Trash"
                    print(f'{i}: {msg}  [{r["path"]}]')
                    rc |= 0 if ok else 1
                    rows.append({"id": i, "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "action": d.get("action"), "ok": ok, "detail": msg})
        finally:
            append(REVIEWED, rows)
    return rc


def main(a):
    if not a:
        print(__doc__); return 2
    c = a[0]
    if c == "trash":
        return cmd_trash(a[1:])
    if c == "status":
        cmd_status()
    elif c == "pending":
        cmd_pending("--json" in a, "--all" in a)
    elif c == "droppable":
        cmd_droppable("--json" in a)
    elif c in ("nudge", "nudge-ack"):
        sid = a[a.index("--session") + 1] if "--session" in a and a.index("--session") + 1 < len(a) else ""
        if c == "nudge":
            cmd_nudge("--peek" in a, sid)
        else:                               # the hook delivered the message: record it for this session
            _, crossing, live, told = _nudge_due(sid)
            _save_nudge(live, crossing, told, sid)
    elif c == "group" and len(a) == 2:
        cmd_group(a[1])
    elif c == "apply" and len(a) == 2:
        return cmd_apply(a[1])
    elif c == "backup-dir":
        print(backup_dir())
    else:
        print(__doc__); return 2
    return 0


if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)    # `status | grep -q` closing early is not an error
    sys.exit(main(sys.argv[1:]))
