#!/bin/bash
set -euo pipefail

# Resolve the harness default centrally so a moved scratch volume stays visible.
if [[ -z "${TMPDIR:-}" && "${1:-}" != stamp ]]; then
  TMPDIR=$("$(dirname "$0")/scratch-root.sh" base)
  export TMPDIR
fi

# Directory descriptors keep cleanup anchored even if a name is replaced mid-walk.
exec python3 - "$@" <<'PY'
import ctypes
import fnmatch
import os
import re
import stat
import subprocess
import sys
import time
from contextlib import contextmanager

DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
MARK = ".megavibe-review-copy"
REVIEW = ("claude-review-scratch.*", "codex-review-scratch.*")
PRODUCER = ("mv-*", "codex-*-scratch.*")
NOW = time.time()
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
        data = None
    if data is not None:
        if not re.fullmatch(rb"[1-9][0-9]{0,9}", data):
            raise ValueError("invalid reviewer PID")
        try:
            os.kill(int(data), 0)
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


def owned(parent, name, path, info, sid, started, nested, cmd):
    if not sid or info.st_uid != os.getuid():
        return False
    if not stat.S_ISDIR(info.st_mode):
        return (not nested and stat.S_ISREG(info.st_mode)
                and not name.startswith("mv-review-copy.")
                and not any(fnmatch.fnmatchcase(name, p) for p in REVIEW)
                and any(fnmatch.fnmatchcase(name, p) for p in PRODUCER)
                and newer(path, info, started))
    if nested:
        return newer(path, info, started)
    if name.startswith("pytest-of-"):
        return False
    with directory(name, parent) as fd:
        if name.startswith("mv-review-copy."):
            try:
                lines = read_at(fd, MARK).split(b"\n", 2)
            except FileNotFoundError:
                return False
            if lines[0] != b"mv-review-copy-v1":
                return False
            if len(lines) > 1 and lines[1].startswith(b"session "):
                return lines[1] == b"session " + sid.encode()
        elif not any(fnmatch.fnmatchcase(name, pattern)
                     for pattern in (*REVIEW, *PRODUCER, "pip-*")):
            try:
                if not stat.S_ISREG(entry(fd, "pyvenv.cfg").st_mode):
                    return False
            except FileNotFoundError:
                return False
        if not newer(path, info, started):
            return False
        return not (cmd.startswith("clean-") and any(fnmatch.fnmatchcase(name, p) for p in REVIEW)
                    and reviewer_running(fd, path))


def tree(fd, device, path, mounts):
    newest = os.fstat(fd).st_mtime
    for name in os.listdir(fd):
        child = os.path.join(path, name)
        info = entry(fd, name)
        if info.st_dev != device or child in mounts:
            raise ValueError("mount boundary")
        newest = max(newest, info.st_mtime)
        if stat.S_ISDIR(info.st_mode):
            with directory(name, fd) as sub:
                newest = max(newest, tree(sub, device, child, mounts))
    return newest


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


def remove(parent, name, expected, path, mounts):
    with directory(name, parent) as fd:
        info = os.fstat(fd)
        if not same_entry(info, expected) or path in mounts:
            raise ValueError("entry changed")
        writable(fd, info)
        # Keep the ownership marker until the rest has gone, so a retry can
        # still identify a copy after a partial deletion.
        for child in sorted(os.listdir(fd), key=lambda name: name == MARK):
            child_path = os.path.join(path, child)
            item = entry(fd, child)
            if item.st_dev != info.st_dev or child_path in mounts:
                raise ValueError("mount boundary")
            if stat.S_ISDIR(item.st_mode):
                remove(fd, child, item, child_path, mounts)
                continue
            remove_file(fd, child, item)
        if not same_entry(entry(parent, name), info):
            raise ValueError("entry changed")
        os.rmdir(name, dir_fd=parent)


def size(path):
    raw = output("du", "-skx", path).split(b"\t", 1)[0]
    if not raw.isdigit():
        raise ValueError("invalid size")
    return int(raw)


def label(path):
    return re.sub(r"[\x00-\x1f\x7f]", "?", path)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd not in ("stamp", "list", "other", "clean-unit", "clean-end") or len(sys.argv) > 3:
        raise ValueError("usage: scratch-own.sh stamp SID | list SID | other [N] | clean-unit SID | clean-end SID")
    arg = sys.argv[2] if len(sys.argv) == 3 else ""
    if cmd == "other" and arg and not re.fullmatch(r"[0-9]{1,6}", arg):
        raise ValueError("invalid entry count")
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "") if cmd == "other" else arg
    if not re.fullmatch(r"[A-Za-z0-9-]+", sid) and (sid or cmd != "other"):
        raise ValueError("invalid session id")
    stamps = os.path.join(os.environ["HOME"], ".megavibe", "scratch-start")
    stamp = os.path.join(stamps, sid)
    if cmd == "stamp":
        os.makedirs(stamps, mode=0o700, exist_ok=True)
        try:
            os.close(os.open(stamp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        except FileExistsError:
            pass
        return 0
    started = None
    if sid:
        try:
            info = os.lstat(stamp)
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("invalid session stamp")
            started = info.st_mtime
        except FileNotFoundError:
            pass
    base = os.path.realpath(os.environ["TMPDIR"])
    if base == "/":
        raise ValueError("invalid temp base")
    cleaning = cmd.startswith("clean-")
    mounts = set()
    if os.path.isfile("/proc/self/mountinfo"):
        with open("/proc/self/mountinfo") as stream:
            for line in stream:
                mount = line.split()[4]
                mounts.add(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), mount))
    errors = count = total = 0
    others = []
    session_dirs = os.environ.get("MEGAVIBE_SCRATCH_SESSION_DIRS", "").splitlines()
    failures = (OSError, ValueError, subprocess.SubprocessError)

    def report(path, exc):
        nonlocal errors
        errors += 1
        print(f"scratch-own: skipped {label(path)} ({type(exc).__name__})", file=sys.stderr)

    def visit(parent, location, name, nested=False):
        nonlocal count, total
        path = os.path.join(location, name)
        try:
            info = entry(parent, name)
            if owned(parent, name, path, info, sid, started, nested, cmd):
                if cmd == "other" and not nested:
                    return 0
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
                        newest = tree(fd, device, path, mounts)
                kb = size(path)
                if cmd == "list":
                    print(f"{kb}\t{path}")
                elif cleaning and (cmd != "clean-end" or newest < NOW - 3600):
                    if is_dir:
                        remove(parent, name, info, path, mounts)
                    else:
                        remove_file(parent, name, info)
                    count += 1
                    total += kb
                return kb
            if cmd == "other" and not nested:
                enclosed = [d for d in session_dirs if d.startswith(path + "/")]
                # The harness root is shared. Its row covers the space left
                # after removing this session's contribution to its size.
                own_kb = sum(size(d) for d in enclosed
                             if not any(d.startswith(p + "/") for p in enclosed))
                others.append((max(0, size(path) - own_kb), label(name),
                               max(0, int((NOW - info.st_mtime) / 60))))
        except failures as exc:
            report(path, exc)
        return 0

    with directory(base) as root:
        device = os.fstat(root).st_dev
        for name in os.listdir(root):
            path = os.path.join(base, name)
            if cmd == "other" and any(path == d or path.startswith(d + "/") for d in session_dirs):
                continue
            if sid and name.startswith("pytest-of-"):
                try:
                    info = entry(root, name)
                    if stat.S_ISDIR(info.st_mode):
                        if info.st_dev != device or path in mounts:
                            raise ValueError("mount boundary")
                        with directory(name, root) as parent:
                            owned_kb = sum(visit(parent, path, run, True) for run in os.listdir(parent)
                                           if re.fullmatch(r"pytest-[0-9]+", run))
                    else:
                        owned_kb = 0
                    if cmd == "other":
                        total_kb = size(path)
                        others.append((max(0, total_kb - owned_kb), label(name),
                                       max(0, int((NOW - info.st_mtime) / 60))))
                except failures as exc:
                    report(path, exc)
            else:
                visit(root, base, name)
    if cleaning:
        print(f"scratch cleanup: removed {count} entries, {total} kB")
    if cmd == "other":
        for kb, name, age in sorted(others, reverse=True)[:int(arg or "3")]:
            print(f"{kb}\t{age}\t{name}")
    return 4 if errors else 0


try:
    sys.exit(main())
except (OSError, ValueError, subprocess.SubprocessError) as exc:
    print(f"scratch-own: {exc}", file=sys.stderr)
    sys.exit(4)
PY
