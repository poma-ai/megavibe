#!/usr/bin/env python3
"""Select a project-volume scratch base and discover previously used roots."""
import fcntl
import json
import os
from pathlib import Path
import signal
import stat
import sys
from contextlib import contextmanager

UID = os.getuid()
BOOT = Path("/private/tmp" if sys.platform == "darwin" else "/")
HIDDEN = ".megavibe-scratch"
REGISTRY = "scratch-volumes.jsonl"
DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
ACCESS = os.R_OK | os.W_OK | os.X_OK
GIB = 1024**3


def device(path):
    return os.stat(path).st_dev


def project_mount(project):
    path = Path(project).resolve(strict=True)
    dev = device(path)
    if dev == device(BOOT):
        return None
    while path != path.parent and device(path.parent) == dev:
        path = path.parent
    return path


@contextmanager
def directory(path, parent=None, create=False, private=False, protected=False):
    if create:
        try:
            os.mkdir(path, 0o700, dir_fd=parent)
        except FileExistsError:
            pass
    fd = os.open(path, DIR, dir_fd=parent)
    try:
        info = os.fstat(fd)
        if parent is not None and (
            info.st_uid != UID or info.st_dev != os.fstat(parent).st_dev
            or (protected and info.st_mode & 0o022)
            or (private and stat.S_IMODE(info.st_mode) != 0o700)
        ):
            raise PermissionError("unsafe scratch directory")
        yield fd
    finally:
        os.close(fd)


def safe_line(path):
    return not any(ord(c) < 32 or ord(c) == 127 for c in str(path))


def probe(directory_fd):
    name = ".probe-" + os.urandom(16).hex()
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600, dir_fd=directory_fd)
    try:
        os.unlink(name, dir_fd=directory_fd)
    finally:
        os.close(fd)


def mounts(home, record=None):
    flags = os.O_NOFOLLOW | os.O_NONBLOCK
    flags |= os.O_RDWR | os.O_CREAT | os.O_APPEND if record else os.O_RDONLY
    try:
        fd = os.open(home / REGISTRY, flags, 0o600)
    except FileNotFoundError:
        if record:
            raise
        return []
    with os.fdopen(fd, "a+" if record else "r", encoding="ascii") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != UID or info.st_mode & 0o022:
            raise PermissionError("unsafe scratch volume registry")
        fcntl.flock(stream, (fcntl.LOCK_EX if record else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        stream.seek(0)
        paths = []
        for line in stream:
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, str) and value.startswith("/") and safe_line(value):
                paths.append(Path(value))
        if record and record not in paths:
            print(json.dumps(str(record)), file=stream)
        return paths


def select(project, home):
    if "CLAUDE_CODE_TMPDIR" in os.environ or os.environ.get("MEGAVIBE_SCRATCH_FOLLOWS_PROJECT") == "0":
        return None
    mount = project_mount(project)
    if mount is None:
        return None
    if not safe_line(mount):
        raise ValueError("project mount path contains control characters")
    base = mount / HIDDEN / str(UID)
    with directory(mount) as mounted:
        if project_mount(mount) != mount or not os.path.samestat(os.stat(mount), os.fstat(mounted)):
            raise OSError("project volume is no longer mounted")
        space = os.fstatvfs(mounted)
        if space.f_flag & os.ST_RDONLY or not os.access(mount, ACCESS):
            raise PermissionError("project volume is read-only or unwritable")
        if space.f_bavail * space.f_frsize < 5 * GIB or space.f_bavail * 20 < space.f_blocks:
            raise OSError("project volume is nearly full")
        with directory(HIDDEN, mounted, create=True, protected=True) as shared:
            if not os.access(base.parent, ACCESS):
                raise PermissionError("project scratch parent is inaccessible")
            with directory(str(UID), shared, create=True, private=True) as scratch:
                if (project_mount(project) != mount or base.resolve(strict=True) != base
                        or not os.path.samestat(os.stat(base), os.fstat(scratch))
                        or not os.access(base, ACCESS)):
                    raise OSError("project scratch is no longer available")
                probe(scratch)
                home.mkdir(mode=0o700, parents=True, exist_ok=True)
                mounts(home, record=mount)
    return base


def discover(project, home):
    try:
        current = project_mount(project)
    except (OSError, RuntimeError):
        current = None
    try:
        recorded = mounts(home)
    except (OSError, UnicodeError):
        recorded = []
    for mount in dict.fromkeys([current, *recorded]):
        try:
            if mount is None or not safe_line(mount) or project_mount(mount) != mount:
                continue
            with directory(mount) as mounted:
                with directory(HIDDEN, mounted, protected=True) as shared:
                    with directory(str(UID), shared, private=True) as scratch:
                        with directory(f"claude-{UID}", scratch) as root:
                            path = mount / HIDDEN / str(UID) / f"claude-{UID}"
                            if path.resolve(strict=True) == path and os.path.samestat(path.stat(), os.fstat(root)):
                                yield path
        except (OSError, RuntimeError):
            continue


def resolve(args):
    command, project, *defaults = args
    home = Path(os.environ.get("MEGAVIBE_HOME") or Path.home() / ".megavibe")
    if command == "discover":
        seen = set()
        for root in defaults:
            if root not in seen:
                print(root, flush=True)
                seen.add(root)
        for root in map(str, discover(project, home)):
            if root not in seen:
                print(root, flush=True)
                seen.add(root)
    elif command == "select":
        try:
            base = select(project, home)
        except (OSError, ValueError, RuntimeError):
            print("megavibe: could not use project-volume scratch; using default scratch", file=sys.stderr)
            return 1
        else:
            if base is not None:
                print(base)


def main(args):
    message = ("project-volume scratch selection timed out; using default scratch"
               if args[0] == "select" else "scratch volume discovery timed out")

    def timed_out(_signum, _frame):
        os.write(2, f"megavibe: {message}\n".encode())
        os._exit(124)

    previous = signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(3)
    try:
        return resolve(args)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
