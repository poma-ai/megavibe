#!/bin/bash
set -euo pipefail

# Resolve the harness default centrally so a moved scratch volume stays visible.
if [[ -z "${TMPDIR:-}" && "${1:-}" != stamp ]]; then
  TMPDIR=$("$(dirname "$0")/scratch-root.sh" base)
  export TMPDIR
fi

# Directory descriptors keep cleanup anchored even if a name is replaced mid-walk.
exec python3 - "$0" "$@" <<'PY'
import ctypes
import fcntl
import fnmatch
import json
import os
import re
import stat
import subprocess
import sys
import time
from contextlib import contextmanager

DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
MARK = ".megavibe-review-copy"
SID = re.compile(r"[A-Za-z0-9-]+")
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


def tree(fd, device, path, mounts, scratchpad=False):
    root = os.fstat(fd)
    newest, blocks, keep = root.st_mtime, root.st_blocks, False
    for name in os.listdir(fd):
        child = os.path.join(path, name)
        info = entry(fd, name)
        if info.st_dev != device or child in mounts:
            raise ValueError("mount boundary")
        newest = max(newest, info.st_mtime)
        if scratchpad:
            keep |= name == ".keep"
        if stat.S_ISDIR(info.st_mode):
            with directory(name, fd) as sub:
                if not same_entry(info, os.fstat(sub)):
                    raise ValueError("entry changed")
                modified, allocated, protected = tree(sub, device, child, mounts, scratchpad)
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


def remove(parent, name, expected, path, mounts, scratchpad=False):
    with directory(name, parent) as fd:
        info = os.fstat(fd)
        if not same_entry(info, expected) or path in mounts:
            raise ValueError("entry changed")
        if scratchpad and info.st_mtime >= RESUME_CUTOFF:
            raise ValueError("entry changed")
        children = os.listdir(fd)
        if scratchpad and ".keep" in children:
            raise ValueError("entry protected")
        writable(fd, info)
        # Keep the ownership marker until the rest has gone, so a retry can
        # still identify a copy after a partial deletion.
        for child in sorted(children, key=lambda name: name == MARK):
            child_path = os.path.join(path, child)
            item = entry(fd, child)
            if item.st_dev != info.st_dev or child_path in mounts:
                raise ValueError("mount boundary")
            if stat.S_ISDIR(item.st_mode):
                remove(fd, child, item, child_path, mounts, scratchpad)
                continue
            if scratchpad and item.st_mtime >= RESUME_CUTOFF:
                raise ValueError("entry changed")
            remove_file(fd, child, item)
        if not same_entry(entry(parent, name), info):
            raise ValueError("entry changed")
        os.rmdir(name, dir_fd=parent)


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
        remove(fd, name, info, path, mounts, scratchpad=True)
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
    if "\n" in os.environ.get("CLAUDE_CODE_TMPDIR", ""):
        raise ValueError("invalid session root path")
    roots = output(os.path.join(os.path.dirname(os.path.abspath(script)),
                                "scratch-root.sh"), "roots").split(b"\n")
    seen = set()
    count = blocks = 0
    for root in filter(None, map(os.fsdecode, roots)):
        try:
            root_info = os.lstat(root)
            if not stat.S_ISDIR(root_info.st_mode):
                continue
            with directory(root) as fd:
                if not same_entry(root_info, os.fstat(fd)):
                    raise ValueError("entry changed")
                physical = os.path.realpath(root)
                for name in os.listdir(fd):
                    if name.startswith("."):
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


def size(path):
    raw = output("du", "-skx", path).split(b"\t", 1)[0]
    if not raw.isdigit():
        raise ValueError("invalid size")
    return int(raw)


def label(path):
    return re.sub(r"[\x00-\x1f\x7f]", "?", path)


def scan_shared(cmd, sid, arg, stamp, paths, mounts, swept, report):
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


def footprint_paths(stamps, boot, bases):
    """NUL-delimited paths with a Megavibe ownership marker or registration."""
    device = os.stat(boot).st_dev
    registered = {}
    if os.path.isdir(stamps):
        for name in os.listdir(stamps):
            if not name.endswith(".register") or not SID.fullmatch(name[:-9]):
                continue
            stamp = os.path.join(stamps, name[:-9])
            try:
                info = os.lstat(stamp)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                    continue
                for path, record in registrations(stamp + ".register").items():
                    registered.setdefault(path, []).append((record, info.st_mtime))
            except (OSError, ValueError):
                continue
    candidate_bases = [*bases, *(os.path.dirname(path) for path in registered)]
    for base in dict.fromkeys(os.path.realpath(path) for path in candidate_bases if os.path.isabs(path)):
        if base == "/" or not os.path.isdir(base) or os.stat(base).st_dev != device:
            continue
        with directory(base) as parent:
            for name in os.listdir(parent):
                path = os.path.join(base, name)
                is_copy = name.startswith("mv-review-copy.")
                is_reviewer = any(fnmatch.fnmatchcase(name, pattern) for pattern in REVIEW)
                if not (is_copy or is_reviewer or path in registered):
                    continue
                try:
                    info = entry(parent, name)
                    if info.st_uid != os.getuid() or info.st_dev != device or stat.S_ISLNK(info.st_mode):
                        continue
                    attributed = False
                    if path in registered:
                        current = identity(path, info)
                        attributed = any(current == record and current[2] > started
                                         for record, started in registered[path])
                    if not attributed and stat.S_ISDIR(info.st_mode) and (is_copy or is_reviewer):
                        with directory(name, parent) as child:
                            if not same_entry(info, os.fstat(child)):
                                continue
                            if is_copy:
                                marker = read_at(child, MARK).split(b"\n", 2)
                                attributed = (len(marker) > 1 and marker[0] == b"mv-review-copy-v1"
                                              and re.fullmatch(rb"session [A-Za-z0-9-]+", marker[1]))
                            else:
                                attributed = re.fullmatch(rb"[1-9][0-9]{0,9}", read_at(child, ".pid", 64).strip())
                    if attributed:
                        sys.stdout.buffer.write(os.fsencode(path) + b"\0")
                except (FileNotFoundError, ValueError):
                    continue
    return 0


def main():
    script = sys.argv.pop(1)
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if (cmd not in ("stamp", "register", "list", "other", "clean-unit", "clean-end")
            or (cmd != "register" and len(sys.argv) > 3)):
        raise ValueError("usage: scratch-own.sh stamp SID | register [SID] PATH... | list SID | other [N] | clean-unit SID | clean-end SID")
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
    if (not SID.fullmatch(sid) and (sid or cmd != "other")
            or cmd == "clean-end" and sid.startswith("-")):
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

    # SessionEnd also sweeps the session directory itself, where attribution is
    # unnecessary. Delete scratch directly so it frees space without filling Trash.
    swept = set()
    pad_count = pad_kb = 0
    if cmd == "clean-end":
        try:
            swept, pad_count, pad_kb = sweep_scratchpads(script, sid, mounts, report)
        except FAILURES as exc:
            report("session roots", exc)

    try:
        count, total = scan_shared(cmd, sid, arg, stamp, paths, mounts, swept, report)
    except FAILURES as exc:
        if cmd != "clean-end":
            raise
        report("shared temp base", exc)
        count = total = 0
    if cmd == "clean-end":
        print(f"scratch cleanup: removed {count} entries, {total} kB; "
              f"scratchpad {pad_count} entries, {pad_kb} kB", file=sys.stderr)
    elif cmd == "clean-unit":
        print(f"scratch cleanup: removed {count} entries, {total} kB")
    return 4 if errors else 0


try:
    if sys.argv[2:3] == ["footprint-paths"]:
        stamps = os.path.join(os.environ["HOME"], ".megavibe", "scratch-start")
        sys.exit(footprint_paths(stamps, sys.argv[3], sys.argv[4:]))
    sys.exit(main())
except (OSError, ValueError, subprocess.SubprocessError) as exc:
    print(f"scratch-own: {exc}", file=sys.stderr)
    sys.exit(4)
PY
