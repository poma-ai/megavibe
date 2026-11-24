#!/usr/bin/env python3
"""Read-only estimate of Megavibe's allocated space on the boot volume."""
import os
import re
import signal
import stat
import subprocess
import sys
from pathlib import Path

GIB_KB = 1024**2
DARWIN = sys.platform == "darwin"
DEFAULT = Path("/private/tmp" if DARWIN else "/tmp")
BOOT = DEFAULT if DARWIN else Path("/")


def run(args):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)


def used_kb():
    result = run(["df", "-Pk", BOOT])
    lines = result.stdout.splitlines()
    if result.returncode != 0 or len(lines) < 2:
        raise ValueError("boot disk usage unavailable")
    row = re.search(rb"\s+[0-9]+\s+([0-9]+)\s+-?[0-9]+\s+[0-9]+%\s+", lines[1])
    if row is None:
        raise ValueError("boot disk usage unavailable")
    return int(row[1])


def on_boot(path, dev, folder=False):
    try:
        info = path.lstat()
        return (info.st_dev == dev and not stat.S_ISLNK(info.st_mode)
                and (not folder or stat.S_ISDIR(info.st_mode)))
    except FileNotFoundError:
        return False


def worktrees(folder, dev):
    if not on_boot(folder, dev, folder=True):
        return set()
    found = set()
    pending = [folder]
    while pending:
        current = pending.pop()
        if current in found:
            continue
        if current != folder and (current / ".git").exists():
            result = run(["git", "-C", current, "worktree", "list", "--porcelain", "-z"])
            if result.returncode:
                raise ValueError("worktree list unavailable")
            for field in result.stdout.split(b"\0"):
                if not field.startswith(b"worktree "):
                    continue
                path = Path(os.fsdecode(field[9:]))
                if folder in path.parents and path.resolve() == path and on_boot(path, dev, folder=True):
                    found.add(path)
            continue
        with os.scandir(current) as entries:
            pending.extend(Path(entry.path) for entry in entries
                           if entry.is_dir(follow_symlinks=False)
                           and on_boot(Path(entry.path), dev, folder=True))
    return found


def measure(paths, covered):
    selected = []
    for path in sorted(paths, key=lambda path: (len(path.parts), path)):
        if path not in covered and not any(parent in covered for parent in path.parents):
            covered.add(path)
            selected.append(path)
    if not selected:
        return 0
    result = run(["du", "-skx", *selected])
    rows = [line.partition(b"\t")[0] for line in result.stdout.splitlines()]
    if result.returncode or len(rows) != len(selected) or not all(row.isdigit() for row in rows):
        raise ValueError("directory size unavailable")
    return sum(map(int, rows))


def main():
    used = used_kb()
    dev = BOOT.stat().st_dev
    home = Path(os.environ.get("MEGAVIBE_HOME") or Path.home() / ".megavibe")
    own = Path(__file__).with_name("scratch-own.sh")
    bases = [DEFAULT]
    override = Path(os.environ.get("CLAUDE_CODE_TMPDIR") or ".")
    user_temp = Path(os.environ.get("TMPDIR") or ".")
    bases.extend(path for path in (override, user_temp) if path.is_absolute())
    if DARWIN:
        result = run(["getconf", "DARWIN_USER_TEMP_DIR"])
        if result.returncode == 0 and result.stdout.startswith(b"/"):
            bases.append(Path(os.fsdecode(result.stdout.rstrip(b"\n"))).resolve())

    def scratch_paths():
        # TMPDIR is a temp attribution base, not a Claude scratch override.
        scratch_bases = [DEFAULT]
        if override.is_absolute():
            scratch_bases.append(override.resolve())
        roots = {base / f"claude-{os.getuid()}" for base in scratch_bases}
        return {path for path in roots if on_boot(path, dev, folder=True)
                and path.lstat().st_uid == os.getuid()}

    def temp_paths():
        result = run(["env", f"TMPDIR={DEFAULT}", own, "footprint-paths", BOOT, *bases])
        if result.returncode:
            raise ValueError("temp attribution unavailable")
        return {Path(os.fsdecode(path)) for path in result.stdout.split(b"\0") if path}

    covered = set()
    sizes = []
    for paths in (scratch_paths, temp_paths, lambda: worktrees(home.resolve() / "worktrees", dev)):
        try:
            sizes.append(measure(paths(), covered))
        except (OSError, ValueError, subprocess.SubprocessError):
            sizes.append(None)
    scratch, temp, trees = sizes
    total = sum(size or 0 for size in sizes)
    incomplete = None in sizes
    major = used > 0 and total * 2 >= used
    verdict = "major part" if major else "share unknown" if incomplete else "less than half"

    def gb(kb):
        return "unknown" if kb is None else f"{kb / GIB_KB:.1f} GB"

    estimate = "at least " if incomplete else ""
    suffix = " (measurement incomplete)" if incomplete else ""
    print(f"megavibe: {estimate}{gb(total)} of {gb(used)} used "
          f"(scratch {gb(scratch)}, temp {gb(temp)}, worktrees {gb(trees)}) — {verdict}{suffix}")


def bounded_footprint():
    probe = subprocess.Popen([sys.executable, __file__, "--worker"],
                             stdout=subprocess.PIPE, start_new_session=True)
    try:
        output, _ = probe.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(probe.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        # A kernel I/O wait may outlive SIGKILL. Close the private pipe
        # without waiting for the worker so it cannot hold the hook open.
        probe.stdout.close()
        return 1
    if probe.returncode:
        return 1
    sys.stdout.buffer.write(output)
    return 0


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--worker"]:
            main()
        else:
            sys.exit(bounded_footprint())
    except (OSError, ValueError, subprocess.SubprocessError):
        sys.exit(1)
