#!/bin/bash
set -euo pipefail

# Resolve the harness default centrally so a moved scratch volume stays visible.
case "${1:-}" in
  stamp|session-tmpdir|sweep-orphans) ;;
  *)
    if [[ -z "${TMPDIR:-}" ]]; then
      TMPDIR=$("$(dirname "$0")/scratch-root.sh" base)
      export TMPDIR
    fi
    ;;
esac

# Directory descriptors keep cleanup anchored even if a name is replaced mid-walk.
exec python3 - "$0" "$@" <<'PY'
import ctypes
import fcntl
import fnmatch
import json
import os
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time
from contextlib import contextmanager
from datetime import datetime

DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
MARK = ".megavibe-review-copy"
SID = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*")
UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
TEMP_MARK = ".sid"
MISSING = object()
UID = os.getuid()
REVIEW = ("claude-review-scratch.*", "codex-review-scratch.*")
NOW = time.time()
RESUME_CUTOFF = NOW - 3600
FAILURES = (OSError, ValueError, subprocess.SubprocessError, RecursionError)
FCHFLAGS = getattr(ctypes.CDLL(None, use_errno=True), "fchflags", None) if sys.platform == "darwin" else None


@contextmanager
def directory(path, parent=None):
    fd = os.open(path, DIR, dir_fd=parent)
    try:
        yield fd
    finally:
        os.close(fd)


def entry(parent, name):
    return os.stat(name, dir_fd=parent, follow_symlinks=False)


def read_at(parent, name, limit=4096):
    info = entry(parent, name)
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("expected a regular file")
    fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=parent)
    with os.fdopen(fd, "rb") as stream:
        return stream.read(limit)


def output(*args, timeout=5):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=True, timeout=timeout).stdout


def birth(path, info):
    value = getattr(info, "st_birthtime", None)
    if value is None:
        seconds, _, formatted = output("stat", "-c", "%W %w", path).partition(b" ")
        fraction = re.search(rb"\.([0-9]{1,9}) ", formatted)
        value = int(seconds)
        if fraction:
            value += int(fraction[1].ljust(9, b"0")) / 1e9
    if value <= 0:
        raise ValueError("birth time unavailable")
    return value


def reviewer_running(fd, path):
    try:
        data = read_at(fd, ".pid", 64).strip()
    except FileNotFoundError:
        return True
    if not re.fullmatch(rb"[1-9][0-9]{0,9}", data):
        raise ValueError("invalid reviewer PID")
    pid = int(data)
    if pid > 2147483647:
        raise ValueError("invalid reviewer PID")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    except PermissionError:
        return True
    else:
        return True
    # Legacy reviewers can leave a child running even after the launcher exits.
    processes = output("ps", "-ax", "-o", "command=")
    if os.fsencode(path) in processes:
        return True
    result = subprocess.run(["lsof", "-a", "-u", str(os.getuid()), "-d", "cwd", "-Fn"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    if result.returncode != 0 or result.stderr:
        raise ValueError("reviewer process scan incomplete")
    prefix = b"n" + os.fsencode(path)
    return any(line == prefix or line.startswith(prefix + b"/")
               for line in result.stdout.splitlines())


def newer(path, info, started):
    if started is None:
        raise ValueError("session start unavailable")
    return birth(path, info) > started


def identity(path, info):
    return [info.st_dev, info.st_ino, birth(path, info)]


def registrations(filename, rows=None):
    flags = os.O_NOFOLLOW | os.O_NONBLOCK
    if rows is not None:
        flags |= os.O_WRONLY | os.O_CREAT | os.O_APPEND
    try:
        fd = os.open(filename, flags, 0o600)
    except FileNotFoundError:
        if rows is None:
            return {}
        raise
    with os.fdopen(fd, "r" if rows is None else "a", encoding="ascii") as stream:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError("invalid session register")
        fcntl.flock(fd, fcntl.LOCK_SH if rows is None else fcntl.LOCK_EX)
        if rows is None:
            records = {}
            for line in stream:
                batch = json.loads(line)
                if not isinstance(batch, dict):
                    raise ValueError("invalid session register")
                records.update(batch)
            return records
        print(json.dumps(rows), file=stream)


def register(base, filename, paths, started):
    if started is None:
        raise ValueError("session start unavailable")
    rows = {}
    with directory(base) as root:
        for supplied in paths:
            parent, name = os.path.split(supplied.rstrip("/"))
            if name in ("", ".", "..") or os.path.realpath(parent or ".") != base:
                raise ValueError("register requires a direct child of the temp base")
            path = os.path.join(base, name)
            info = entry(root, name)
            if stat.S_ISLNK(info.st_mode) or path != label(path):
                raise ValueError("cannot register a symlink or a path with control characters")
            if info.st_uid != os.getuid() or not same_entry(info, os.lstat(supplied.rstrip("/"))):
                raise ValueError("register requires an entry owned by the current user")
            record = identity(path, info)
            if not same_entry(info, entry(root, name)):
                raise ValueError("entry changed")
            if record[2] <= started:
                raise ValueError("registered entry must be created after the session stamp")
            rows[path] = record
    registrations(filename, rows)


def owned(parent, name, path, info, sid, started, registered, cleaning):
    if not sid or info.st_uid != os.getuid() or stat.S_ISLNK(info.st_mode):
        return False
    if stat.S_ISDIR(info.st_mode) and name.startswith("mv-review-copy."):
        with directory(name, parent) as fd:
            try:
                lines = read_at(fd, MARK).split(b"\n", 2)
            except FileNotFoundError:
                pass
            else:
                if lines[0] == b"mv-review-copy-v1" and len(lines) > 1 and lines[1].startswith(b"session "):
                    return (lines[1] == b"session " + sid.encode()
                            and (not cleaning or newer(path, info, started)))
    if stat.S_ISDIR(info.st_mode) and any(fnmatch.fnmatchcase(name, p) for p in REVIEW):
        with directory(name, parent) as fd:
            return not reviewer_running(fd, path) and newer(path, info, started)
    if path in registered and started is not None:
        record = identity(path, info)
        return record == registered[path] and record[2] > started
    return False


def tree(fd, device, path, mounts, scratchpad=False, owner_only=False):
    root = os.fstat(fd)
    newest, blocks, keep = root.st_mtime, root.st_blocks, False
    for name in os.listdir(fd):
        child = os.path.join(path, name)
        info = entry(fd, name)
        if (info.st_dev != device or child in mounts
                or (owner_only and info.st_uid != UID)):
            raise ValueError("mount boundary")
        newest = max(newest, info.st_mtime)
        if scratchpad:
            keep |= name == ".keep"
        if stat.S_ISDIR(info.st_mode):
            with directory(name, fd) as sub:
                if not same_entry(info, os.fstat(sub)):
                    raise ValueError("entry changed")
                modified, allocated, protected = tree(sub, device, child, mounts, scratchpad, owner_only)
                newest = max(newest, modified)
                blocks += allocated
                keep |= protected
        elif scratchpad:
            blocks += file_blocks(info)
    return newest, blocks, keep


def file_blocks(info):
    return info.st_blocks if info.st_nlink == 1 else 0


def same_entry(a, b):
    return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)


def writable(fd, info):
    # Clearing flags on the open inode avoids changing a substituted path.
    flags = getattr(info, "st_flags", 0)
    if FCHFLAGS and flags & stat.UF_IMMUTABLE:
        if FCHFLAGS(fd, flags & ~stat.UF_IMMUTABLE) != 0:
            raise OSError(ctypes.get_errno(), "cannot clear immutable flag")
    mode = stat.S_IMODE(info.st_mode)
    executable = stat.S_ISDIR(info.st_mode) or mode & 0o111
    os.fchmod(fd, mode | (0o700 if executable else 0o600))


def remove_file(parent, name, expected):
    # A hard link can name a user file outside scratch. Unlink our name
    # without changing that inode's mode or flags.
    if stat.S_ISREG(expected.st_mode) and expected.st_nlink == 1:
        fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not same_entry(expected, info) or info.st_nlink != 1:
                raise ValueError("entry changed")
            writable(fd, info)
        finally:
            os.close(fd)
    if not same_entry(entry(parent, name), expected):
        raise ValueError("entry changed")
    os.unlink(name, dir_fd=parent)


def remove(parent, name, expected, path, mounts, cutoff=None, owner_only=False,
           preserve_temp_root=False, protect_reviewers=False):
    with directory(name, parent) as fd:
        info = os.fstat(fd)
        if not same_entry(info, expected) or path in mounts:
            raise ValueError("entry changed")
        if cutoff is not None and info.st_mtime >= cutoff:
            raise ValueError("entry changed")
        children = os.listdir(fd)
        if owner_only and info.st_uid != UID:
            raise ValueError("foreign owner")
        if cutoff is not None and ".keep" in children:
            raise ValueError("entry protected")
        if protect_reviewers and any(fnmatch.fnmatchcase(name, pattern) for pattern in REVIEW):
            try:
                if reviewer_running(fd, path):
                    return True, 0
            except FAILURES:
                return True, 0
        writable(fd, info)
        retained = False
        blocks = 0
        # Keep the ownership marker until the rest has gone, so a retry can
        # still identify a copy after a partial deletion.
        for child in sorted(children, key=lambda name: name in (MARK, TEMP_MARK)):
            if child == TEMP_MARK and (preserve_temp_root or (protect_reviewers and retained)):
                continue
            child_path = os.path.join(path, child)
            item = entry(fd, child)
            if (item.st_dev != info.st_dev or child_path in mounts
                    or (owner_only and item.st_uid != UID)):
                raise ValueError("mount boundary")
            if stat.S_ISDIR(item.st_mode):
                kept, removed = remove(fd, child, item, child_path, mounts, cutoff, owner_only,
                                       protect_reviewers=protect_reviewers)
                retained |= kept
                blocks += removed
                continue
            if cutoff is not None and item.st_mtime >= cutoff:
                raise ValueError("entry changed")
            remove_file(fd, child, item)
            blocks += file_blocks(item)
        if not same_entry(entry(parent, name), info):
            raise ValueError("entry changed")
        if not preserve_temp_root and not retained:
            os.rmdir(name, dir_fd=parent)
            blocks += info.st_blocks
        return retained, blocks


def sweep_entry(fd, name, path, device, mounts):
    info = entry(fd, name)
    if (name == ".keep" or info.st_mtime >= RESUME_CUTOFF
            or info.st_dev != device or path in mounts):
        return None
    is_dir = stat.S_ISDIR(info.st_mode)
    allocated = file_blocks(info)
    if is_dir:
        with directory(name, fd) as sub:
            if not same_entry(info, os.fstat(sub)):
                raise ValueError("entry changed")
            newest, allocated, keep = tree(sub, device, path, mounts, scratchpad=True)
        if keep or newest >= RESUME_CUTOFF:
            return None
    current = entry(fd, name)
    if not same_entry(info, current) or current.st_mtime >= RESUME_CUTOFF:
        return None
    writable(fd, os.fstat(fd))
    if is_dir:
        remove(fd, name, info, path, mounts, cutoff=RESUME_CUTOFF)
    else:
        remove_file(fd, name, info)
    return allocated


def sweep_session(project, sid, expected, path, device, mounts, report):
    count = blocks = 0
    with directory(sid, project) as fd:
        session = os.fstat(fd)
        if not same_entry(expected, session):
            raise ValueError("entry changed")
        if session.st_uid != os.getuid() or session.st_dev != device or path in mounts:
            return count, blocks
        for name in os.listdir(fd):
            child = os.path.join(path, name)
            try:
                allocated = sweep_entry(fd, name, child, device, mounts)
                if allocated is not None:
                    count += 1
                    blocks += allocated
            except FileNotFoundError:
                continue
            except FAILURES as exc:
                report(child, exc)
        try:
            if not os.listdir(fd) and same_entry(entry(project, sid), session):
                writable(fd, os.fstat(fd))
                os.rmdir(sid, dir_fd=project)
                blocks += session.st_blocks
        except FileNotFoundError:
            pass
        except FAILURES as exc:
            report(path, exc)
    return count, blocks


def sweep_scratchpads(script, sid, mounts, report):
    # Use the same root list and project levels as disk-watch. Resolve paths
    # for mount lookup, and open each directory relative to its pinned parent.
    roots = root_paths(script, "roots")
    seen = set()
    count = blocks = 0
    for root in roots:
        try:
            root_info = os.lstat(root)
            if not stat.S_ISDIR(root_info.st_mode):
                continue
            with directory(root) as fd:
                if not same_entry(root_info, os.fstat(fd)):
                    raise ValueError("entry changed")
                physical = os.path.realpath(root)
                for name in os.listdir(fd):
                    if name == "t" or name.startswith("."):
                        continue
                    project_path = os.path.join(physical, name)
                    path = os.path.join(project_path, sid)
                    try:
                        info = entry(fd, name)
                        if (not stat.S_ISDIR(info.st_mode) or info.st_dev != root_info.st_dev
                                or project_path in mounts):
                            continue
                        with directory(name, fd) as project:
                            if not same_entry(info, os.fstat(project)):
                                raise ValueError("entry changed")
                            # An open alone can match a different spelling on APFS.
                            if path in seen or sid not in os.listdir(project):
                                continue
                            session = entry(project, sid)
                            if not stat.S_ISDIR(session.st_mode):
                                continue
                            seen.add(path)
                            n, allocated = sweep_session(project, sid, session, path, info.st_dev,
                                                         mounts, report)
                            count += n
                            blocks += allocated
                    except FileNotFoundError:
                        continue
                    except FAILURES as exc:
                        report(path, exc)
        except FileNotFoundError:
            continue
        except FAILURES as exc:
            report(root, exc)
    return seen, count, (blocks + 1) // 2


def root_paths(script, command):
    if "\n" in os.environ.get("CLAUDE_CODE_TMPDIR", ""):
        raise ValueError("invalid session root path")
    helper = os.path.join(os.path.dirname(os.path.abspath(script)), "scratch-root.sh")
    return list(filter(None, map(os.fsdecode, output(helper, command).splitlines())))


def canonical_temp(path):
    if not os.path.isabs(path) or path != label(path):
        raise ValueError("invalid temp path")
    path = path.rstrip("/") or "/"
    if path != os.path.normpath(path):
        raise ValueError("noncanonical temp path")
    if sys.platform == "darwin" and (path in ("/tmp", "/var")
                                     or path.startswith(("/tmp/", "/var/"))):
        path = "/private" + path
    return path


@contextmanager
def pinned_dir(path, create=False):
    # Open every component without following symlinks, including root ancestors.
    parent, name = os.path.split(path)
    if not name:
        with directory(path) as fd:
            yield fd
        return
    with pinned_dir(parent) as fd:
        with child_dir(fd, name, create) as child:
            yield child


@contextmanager
def child_dir(parent, name, create=False):
    if create:
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
        except FileExistsError:
            pass
    with directory(name, parent) as fd:
        yield fd


def safe_dir(info, device, path, mounts):
    return (stat.S_ISDIR(info.st_mode) and info.st_uid == UID
            and info.st_dev == device and path not in mounts)


def marker_sid(fd, name):
    info = entry(fd, TEMP_MARK)
    if info.st_uid != UID or info.st_nlink != 1 or info.st_size > 4096:
        return None
    sid = read_at(fd, TEMP_MARK).decode("ascii").removesuffix("\n")
    return sid if SID.fullmatch(sid) and sid[:8] == name else None


def system_temp():
    if sys.platform == "darwin":
        return os.fsdecode(output("getconf", "DARWIN_USER_TEMP_DIR", timeout=1).strip())
    return "/tmp"


def session_tmpdir(script, sid):
    envfile = os.environ.get("CLAUDE_ENV_FILE")
    if not envfile or len(sid) >= 4096 or os.environ.get("MEGAVIBE_SESSION_TMPDIR") == "0":
        return
    pinned = os.environ.get("TMPDIR", "").rstrip("/")
    if (pinned and pinned not in ("/tmp", "/private/tmp")
            and pinned != system_temp().rstrip("/")):
        return
    root, = map(canonical_temp, root_paths(script, "root"))
    short = sid[:8]
    path = os.path.join(root, "t", short)
    # Leave room for socket filenames, including on macOS's 104-byte sockaddr_un.
    if len(os.fsencode(path + "/ctl.sock")) >= 90:
        return
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(envfile, flags, 0o600), "w", encoding="utf-8",
                   errors="surrogateescape") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            return
        with pinned_dir(root, create=True) as fd:
            root_info = os.fstat(fd)
            if root_info.st_uid != UID or root_info.st_mode & 0o022:
                return
            with child_dir(fd, "t", create=True) as temp:
                info = os.fstat(temp)
                if info.st_uid != UID or info.st_mode & 0o022 or info.st_dev != root_info.st_dev:
                    return
                try:
                    os.mkdir(short, 0o700, dir_fd=temp)
                except FileExistsError:
                    if short not in os.listdir(temp):
                        return
                    with directory(short, temp) as child:
                        info = os.fstat(child)
                        if (info.st_uid != UID or stat.S_IMODE(info.st_mode) != 0o700
                                or info.st_dev != root_info.st_dev or marker_sid(child, short) != sid):
                            return
                        os.utime(child, None)
                else:
                    with directory(short, temp) as child:
                        os.fchmod(child, 0o700)
                        marker = os.open(TEMP_MARK, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                                         os.O_NOFOLLOW, 0o600, dir_fd=child)
                        with os.fdopen(marker, "w", encoding="ascii") as identity_file:
                            identity_file.write(sid + "\n")
                stream.write(f"export TMPDIR={shlex.quote(path)}; "
                             '[ -L "$TMPDIR" ] || [ -d "$TMPDIR" ] || mkdir -m 700 -p "$TMPDIR"\n')


def old_tree(parent, name, info, path, mounts, cutoff):
    with directory(name, parent) as fd:
        if not same_entry(info, os.fstat(fd)):
            raise ValueError("entry changed")
        newest, blocks, keep = tree(fd, info.st_dev, path, mounts, True, True)
    return blocks if not keep and newest < cutoff else None


def session_temps(roots, sid, cmd, mounts, report):
    count = blocks = 0
    matched = []
    seen = set()
    cutoff = RESUME_CUTOFF if cmd == "clean-end" else float("inf")
    for path in roots:
        temp_path = os.path.join(path, "t")
        short = sid[:8]
        target = os.path.join(temp_path, short)
        if target in seen:
            continue
        seen.add(target)
        try:
            with pinned_dir(path) as root, directory("t", root) as temp:
                device = os.fstat(root).st_dev
                if (os.fstat(root).st_uid != UID
                        or not safe_dir(os.fstat(temp), device, temp_path, mounts)
                        or short not in os.listdir(temp)):
                    continue
                info = entry(temp, short)
                if not safe_dir(info, device, target, mounts):
                    continue
                with directory(short, temp) as fd:
                    if not same_entry(info, os.fstat(fd)) or marker_sid(fd, short) != sid:
                        continue
                matched.append(target)
                if cmd == "other":
                    continue
                if cmd == "list":
                    print(f"{size(target)}\t{target}")
                    continue
                allocated = old_tree(temp, short, info, target, mounts, cutoff)
                if allocated is not None:
                    retained, removed = remove(
                        temp, short, info, target, mounts, cutoff, owner_only=True,
                        preserve_temp_root=(cmd == "clean-unit"), protect_reviewers=True)
                    if removed or not retained:
                        count += 1
                    blocks += removed
        except FileNotFoundError:
            continue
        except FAILURES as exc:
            report(target, exc)
    return count, (blocks + 1) // 2, matched


def parse_process_start(value):
    if not isinstance(value, str):
        raise ValueError("invalid process start")
    text = " ".join(value.split())
    if not re.fullmatch(
            r"[A-Za-z]{3} [A-Za-z]{3} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}", text):
        raise ValueError("invalid process start")
    started = datetime.strptime(text, "%a %b %d %H:%M:%S %Y")
    if started.strftime("%a").lower() != text[:3].lower():
        raise ValueError("invalid process start weekday")
    return started


def process_matches(pid, recorded):
    accessible = True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        accessible = False
    if recorded is MISSING:
        return True
    started = parse_process_start(recorded)
    if not accessible:
        return True
    try:
        result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                                capture_output=True, text=True, timeout=1,
                                env={**os.environ, "LC_ALL": "C", "TZ": "UTC"})
        return (result.returncode != 0 or bool(result.stderr)
                or parse_process_start(result.stdout) == started)
    except FAILURES:
        return True


def live_sessions(current):
    live = {current}
    invalid = 0
    limit = 1024 * 1024
    home = os.environ["HOME"]
    configs = [os.path.join(home, ".claude")]
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        configs.append(os.environ["CLAUDE_CONFIG_DIR"])
    for name in os.listdir(home):
        if not name.startswith(".claude"):
            continue
        config = os.path.join(home, name)
        try:
            if stat.S_ISDIR(os.stat(config).st_mode):
                configs.append(config)
        except FileNotFoundError:
            continue
    seen = set()
    for config in dict.fromkeys(configs):
        path = os.path.realpath(os.path.join(config, "sessions"))
        try:
            with directory(path) as fd:
                info = os.fstat(fd)
                identity = (info.st_dev, info.st_ino)
                if identity in seen:
                    continue
                seen.add(identity)
                for name in os.listdir(fd):
                    if not name.endswith(".json"):
                        continue
                    try:
                        data = read_at(fd, name, limit + 1)
                        if len(data) > limit:
                            raise ValueError("session record too large")
                        record = json.loads(data)
                        if not isinstance(record, dict):
                            raise ValueError("invalid session record")
                        sid, pid = record.get("sessionId"), record.get("pid")
                        if not (isinstance(sid, str) and SID.fullmatch(sid)
                                and type(pid) is int and 0 < pid <= 2147483647):
                            raise ValueError("invalid session record")
                        if process_matches(pid, record.get("procStart", MISSING)):
                            live.add(sid)
                    except FileNotFoundError:
                        continue
                    except (OSError, ValueError, RecursionError):
                        invalid += 1
        except FileNotFoundError:
            continue
    return live, invalid


def sweep_pytest(cutoff, mounts, report):
    lsof = shutil.which("lsof")
    if not lsof:
        return 0
    base = canonical_temp(system_temp())
    path = os.path.join(base, "pytest-of-" + pwd.getpwuid(UID).pw_name)
    blocks = 0
    try:
        with pinned_dir(base) as root, directory(os.path.basename(path), root) as parent:
            device = os.fstat(root).st_dev
            if not safe_dir(os.fstat(parent), device, path, mounts):
                return 0
            for name in os.listdir(parent):
                if not re.fullmatch(r"pytest-[0-9]+", name):
                    continue
                target = os.path.join(path, name)
                try:
                    info = entry(parent, name)
                    if not safe_dir(info, device, target, mounts) or info.st_mtime >= cutoff:
                        continue
                    allocated = old_tree(parent, name, info, target, mounts, cutoff)
                    if allocated is None:
                        continue
                    # lsof can report symlinks in the tree, but +D without -x
                    # does not traverse them or cross mount points.
                    result = subprocess.run([lsof, "+D", target], stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, timeout=1)
                    if result.returncode == 1 and not result.stdout and not result.stderr:
                        remove(parent, name, info, target, mounts, cutoff, True)
                        blocks += allocated
                except FAILURES as exc:
                    report(target, exc)
    except FileNotFoundError:
        pass
    return blocks


def sweep_session_orphans(script, live, cutoff, mounts, report):
    ended = set()
    live_uuids = {sid.lower() for sid in live if UUID.fullmatch(sid)}
    blocks = 0
    for path in dict.fromkeys(map(canonical_temp, root_paths(script, "roots"))):
        try:
            with pinned_dir(path) as root:
                root_info = os.fstat(root)
                if root_info.st_uid != UID or ".keep" in os.listdir(root):
                    continue
                for project in os.listdir(root):
                    project_path = os.path.join(path, project)
                    try:
                        info = entry(root, project)
                        if not safe_dir(info, root_info.st_dev, project_path, mounts):
                            continue
                        # Harness slugs encode absolute project paths and start with a dash.
                        if project != "t" and not project.startswith("-"):
                            print(f"scratch-own: {label(project_path)}: {size(project_path)} kB",
                                  file=sys.stderr)
                            continue
                        with directory(project, root) as parent:
                            if not same_entry(info, os.fstat(parent)):
                                raise ValueError("entry changed")
                            if ".keep" in os.listdir(parent):
                                continue
                            for name in os.listdir(parent):
                                target = os.path.join(project_path, name)
                                try:
                                    info = entry(parent, name)
                                    if not safe_dir(info, root_info.st_dev, target, mounts):
                                        continue
                                    if project != "t" and not UUID.fullmatch(name):
                                        print(f"scratch-own: {label(target)}: {size(target)} kB",
                                              file=sys.stderr)
                                        continue
                                    if info.st_mtime >= cutoff:
                                        continue
                                    sid = name
                                    if project == "t":
                                        with directory(name, parent) as fd:
                                            if not same_entry(info, os.fstat(fd)):
                                                raise ValueError("entry changed")
                                            sid = marker_sid(fd, name)
                                    if not sid or sid in live or sid.lower() in live_uuids:
                                        continue
                                    allocated = old_tree(parent, name, info, target, mounts, cutoff)
                                    if allocated is not None:
                                        remove(parent, name, info, target, mounts, cutoff, True)
                                        blocks += allocated
                                        ended.add(sid)
                                except FileNotFoundError:
                                    continue
                                except FAILURES as exc:
                                    report(target, exc)
                    except FAILURES as exc:
                        report(project_path, exc)
        except (FileNotFoundError, NotADirectoryError):
            continue
        except FAILURES as exc:
            report(path, exc)
    return blocks, len(ended)


def sweep_orphans(script, current, mounts, report):
    hours = os.environ.get("MEGAVIBE_SCRATCH_ORPHAN_HOURS") or "24"
    if not re.fullmatch(r"[0-9]{1,9}", hours):
        raise ValueError("invalid orphan age")
    if not int(hours):
        return
    cutoff = NOW - int(hours) * 3600
    live, invalid = live_sessions(current)
    blocks = ended = 0
    if invalid:
        print(f"scratch-own: skipped session scratch sweep due to {invalid} invalid session record(s)",
              file=sys.stderr)
    else:
        blocks, ended = sweep_session_orphans(script, live, cutoff, mounts, report)
    try:
        blocks += sweep_pytest(cutoff, mounts, report)
    except FAILURES as exc:
        report("pytest runs", exc)
    if ended or blocks:
        print(f"freed {blocks / 2048:.0f} MB from {ended} ended sessions")


def size(path):
    raw = output("du", "-skx", path).split(b"\t", 1)[0]
    if not raw.isdigit():
        raise ValueError("invalid size")
    return int(raw)


def label(path):
    return re.sub(r"[\x00-\x1f\x7f]", "?", path)


def scan_shared(cmd, sid, arg, stamp, paths, mounts, swept, report, short_dirs=()):
    started = None
    if sid:
        try:
            info = os.lstat(stamp)
            if not stat.S_ISREG(info.st_mode) or info.st_mtime <= 0:
                raise ValueError("invalid session stamp")
            started = info.st_mtime
        except FileNotFoundError:
            pass
    temp = os.environ["TMPDIR"]
    base = os.path.realpath(temp)
    cleaning = cmd.startswith("clean-")
    if base == "/" or (cleaning and (not os.path.isabs(temp) or not os.path.isdir(temp))):
        raise ValueError("invalid temp base")
    if cleaning:
        # The system aliases are part of standard macOS temp paths. Other
        # symlinks must not redirect a destructive scan into a different tree.
        expected = os.path.abspath(temp)
        if sys.platform == "darwin" and (expected == "/tmp" or
                expected.startswith(("/tmp/", "/var/"))):
            expected = "/private" + expected
        if base != expected:
            raise ValueError("symlinked temp base")
    register_file = stamp + ".register"
    if cmd == "register":
        register(base, register_file, paths, started)
        return 0, 0
    registered = registrations(register_file) if sid else {}
    count = total = 0
    others = []
    session_dirs = os.environ.get("MEGAVIBE_SCRATCH_SESSION_DIRS", "").splitlines()
    session_dirs.extend(short_dirs)

    def visit(parent, name, path):
        nonlocal count, total
        try:
            info = entry(parent, name)
            if owned(parent, name, path, info, sid, started, registered, cleaning):
                if cmd == "other":
                    return
                if info.st_dev != device or path in mounts:
                    raise ValueError("mount boundary")
                if cmd != "other" and path != label(path):
                    raise ValueError("path cannot be represented in a line")
                is_dir = stat.S_ISDIR(info.st_mode)
                newest = info.st_mtime
                if is_dir and (cleaning or cmd == "list"):
                    with directory(name, parent) as fd:
                        if not same_entry(info, os.fstat(fd)):
                            raise ValueError("entry changed")
                        newest, _, _ = tree(fd, device, path, mounts)
                kb = size(path)
                if cmd == "list":
                    print(f"{kb}\t{path}")
                elif cleaning and (cmd != "clean-end" or newest < RESUME_CUTOFF):
                    if is_dir:
                        remove(parent, name, info, path, mounts)
                    else:
                        remove_file(parent, name, info)
                    count += 1
                    total += kb
                return
            if cmd == "other":
                enclosed = [d for d in session_dirs if d.startswith(path + "/")]
                # The harness root is shared. Its row covers the space left
                # after removing this session's contribution to its size.
                own_kb = sum(size(d) for d in enclosed
                             if not any(d.startswith(p + "/") for p in enclosed))
                others.append((max(0, size(path) - own_kb), label(name),
                               max(0, int((NOW - info.st_mtime) / 60))))
        except FAILURES as exc:
            report(path, exc)

    # A TMPDIR inside the session directory must obey the scratchpad retention rules.
    if not any(base == d or base.startswith(d + "/") for d in swept):
        with directory(base) as root:
            device = os.fstat(root).st_dev
            for name in os.listdir(root):
                path = os.path.join(base, name)
                if cmd == "other" and any(path == d or path.startswith(d + "/") for d in session_dirs):
                    continue
                if any(d == path or d.startswith(path + "/") for d in swept):
                    continue
                visit(root, name, path)
    if cmd == "other":
        for kb, name, age in sorted(others, reverse=True)[:int(arg or "3")]:
            print(f"{kb}\t{age}\t{name}")
    return count, total


def main():
    script = sys.argv.pop(1)
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if (cmd not in ("stamp", "register", "list", "other", "clean-unit", "clean-end",
                        "session-tmpdir", "sweep-orphans")
            or (cmd != "register" and len(sys.argv) > 3)):
        raise ValueError("usage: scratch-own.sh stamp SID | register [SID] PATH... | list SID | other [N] | clean-unit SID | clean-end SID | session-tmpdir SID | sweep-orphans SID")
    arg = sys.argv[2] if len(sys.argv) >= 3 else ""
    if cmd == "other" and arg and not re.fullmatch(r"[0-9]{1,6}", arg):
        raise ValueError("invalid entry count")
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "") if cmd == "other" else arg
    paths = sys.argv[2:]
    if cmd == "register":
        # Existing paths take precedence over an optional positional SID.
        if SID.fullmatch(arg) and not os.path.lexists(arg):
            sid = paths.pop(0)
        else:
            sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
        if not sid:
            raise ValueError("register requires a session ID argument or CLAUDE_CODE_SESSION_ID")
        if not paths:
            raise ValueError("register requires at least one path")
    if not SID.fullmatch(sid) and (sid or cmd != "other"):
        raise ValueError("invalid session id")
    if cmd == "session-tmpdir":
        session_tmpdir(script, sid)
        return 0
    stamps = os.path.join(os.environ["HOME"], ".megavibe", "scratch-start")
    stamp = os.path.join(stamps, sid)
    if cmd == "stamp":
        os.makedirs(stamps, mode=0o700, exist_ok=True)
        try:
            os.close(os.open(stamp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        except FileExistsError:
            pass
        return 0
    mounts = set()
    if cmd != "register" and os.path.isfile("/proc/self/mountinfo"):
        with open("/proc/self/mountinfo") as stream:
            for line in stream:
                mount = line.split()[4]
                mounts.add(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), mount))
    errors = 0

    def report(path, exc):
        nonlocal errors
        errors += 1
        print(f"scratch-own: skipped {label(path)} ({type(exc).__name__})", file=sys.stderr)

    if cmd == "sweep-orphans":
        sweep_orphans(script, sid, mounts, report)
        return 4 if errors else 0

    # SessionEnd also sweeps the session directory itself, where attribution is
    # unnecessary. Delete scratch directly so it frees space without filling Trash.
    swept = set()
    pad_count = pad_kb = 0
    if cmd == "clean-end":
        try:
            swept, pad_count, pad_kb = sweep_scratchpads(script, sid, mounts, report)
        except FAILURES as exc:
            report("session roots", exc)

    count = total = 0
    short_dirs = []
    skip_shared = False
    if sid and cmd in ("list", "other", "clean-unit", "clean-end"):
        try:
            # The short TMPDIR is measured and cleaned as a single attributed tree.
            # If a Bash call inherited it, do not scan its children a second time.
            temp = os.path.realpath(os.environ["TMPDIR"])
            roots = tuple(map(canonical_temp, root_paths(script, "roots")))
            for root in roots:
                short_base = os.path.join(root, "t")
                if temp == short_base or temp.startswith(short_base + "/"):
                    if cmd == "other":
                        os.environ["TMPDIR"] = system_temp()
                    else:
                        skip_shared = True
                    break
            count, total, short_dirs = session_temps(roots, sid, cmd, mounts, report)
        except FAILURES as exc:
            report("session temp roots", exc)
    try:
        if not skip_shared:
            shared_count, shared_total = scan_shared(cmd, sid, arg, stamp, paths, mounts,
                                                    swept, report, short_dirs)
            count += shared_count
            total += shared_total
    except FAILURES as exc:
        if cmd != "clean-end":
            raise
        report("shared temp base", exc)
    if cmd == "clean-end":
        print(f"scratch cleanup: removed {count} entries, {total} kB; "
              f"scratchpad {pad_count} entries, {pad_kb} kB", file=sys.stderr)
    elif cmd == "clean-unit":
        print(f"scratch cleanup: removed {count} entries, {total} kB")
    return 4 if errors else 0


try:
    sys.exit(main())
except (OSError, ValueError, subprocess.SubprocessError) as exc:
    print(f"scratch-own: {exc}", file=sys.stderr)
    sys.exit(4)
PY
