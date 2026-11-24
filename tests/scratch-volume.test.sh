#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/scratch-volume.XXXXXX")
T=$(cd "$T" && pwd -P)
export HOME="$T/home" TMPDIR="$T/tmp"
mkdir -p "$HOME" "$TMPDIR"
python3 -B - "$REPO" "$T" <<'PY'
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import stat
import shutil
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

repo, temp = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("scratch_volume", repo / "scripts/scratch-volume.py")
volume = importlib.util.module_from_spec(spec)
spec.loader.exec_module(volume)
mount = temp / "External  disk"
project = mount / "nested" / "project"
project.mkdir(parents=True)
alias = temp / "project link"
alias.symlink_to(project)
base = mount / ".megavibe-scratch" / str(os.getuid())
root = base / ("claude-" + str(os.getuid()))
home = Path(os.environ["HOME"]) / ".megavibe"
home.mkdir()
gib = 1024**3

def device(path):
    return os.stat(path).st_dev + int(Path(path) == mount or mount in Path(path).parents)

def run(path):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        volume.main(["select", str(path)])
    return out.getvalue().splitlines(), err.getvalue().splitlines()

def rejected(path):
    out, err = run(path)
    assert not out and len(err) == 1 and "default scratch" in err[0], (out, err)
    assert not base.exists()

with patch.dict(os.environ, clear=False), patch.object(volume, "device", device):
    for name in ("CLAUDE_CODE_TMPDIR", "MEGAVIBE_SCRATCH_FOLLOWS_PROJECT", "MEGAVIBE_HOME"):
        os.environ.pop(name, None)
    assert run(temp) == ([], []) and not base.exists()
    with patch.dict(os.environ, CLAUDE_CODE_TMPDIR="/chosen/missing"):
        assert run(project) == ([], []) and not base.exists()
    with patch.dict(os.environ, CLAUDE_CODE_TMPDIR=""):
        assert run(project) == ([], []) and not base.exists()
    with patch.dict(os.environ, MEGAVIBE_SCRATCH_FOLLOWS_PROJECT="0"):
        assert run(project) == ([], []) and not base.exists()

    vfs = SimpleNamespace(f_flag=os.ST_RDONLY, f_frsize=gib, f_bavail=100, f_blocks=100)
    with patch.object(volume.os, "fstatvfs", return_value=vfs):
        rejected(project)
        vfs.f_flag, vfs.f_bavail = 0, 4
        rejected(project)
        vfs.f_blocks, vfs.f_bavail = 1000, 49
        rejected(project)
        vfs.f_bavail = 50
        with patch.object(volume.os, "access", return_value=False):
            rejected(project)
        with patch.object(volume.os, "mkdir", side_effect=PermissionError):
            rejected(project)
        assert run(alias) == ([str(base)], [])
        assert run(project) == ([str(base)], [])  # idempotent
        assert stat.S_IMODE(base.stat().st_mode) == 0o700 and base.stat().st_uid == os.getuid()
        assert not list(volume.discover(project, home))  # harness root has yet to be used
        root.mkdir()
        assert list(volume.discover(project, home)) == [root]
        assert list(volume.discover(temp, home)) == [root]  # registry from another project
        assert (home / volume.REGISTRY).read_text().count("\n") == 1

        scripts = home / "scripts"
        scripts.mkdir()
        for name in ("scratch-root.sh", "scratch-own.sh", "disk-watch.sh"):
            shutil.copy2(repo / "scripts" / name, scripts)
        # Use the same device fixture through the installed root resolver.
        (scripts / "scratch-volume.py").write_text(f"""
import runpy
import os
import sys
from pathlib import Path
module = runpy.run_path({str(repo / 'scripts/scratch-volume.py')!r})
mount = Path({str(mount)!r})
def fixture_device(path):
    return os.stat(path).st_dev + int(path == mount or mount in Path(path).parents)
module['main'].__globals__['device'] = fixture_device
module['main'](sys.argv[1:])
""")
        sid = "fixture-session"
        session = root / "fixture-project" / sid / "scratchpad"
        session.mkdir(parents=True)
        (session / "data").write_bytes(b"x" * 65536)
        roots = subprocess.check_output([scripts / "scratch-root.sh", "roots"], cwd=temp, text=True)
        assert str(root) in roots.splitlines()
        kb = subprocess.check_output([scripts / "disk-watch.sh", "scratch-kb", sid], cwd=temp, text=True)
        assert int(kb) >= 64

        launcher = (repo / "megavibe").read_text()
        function = launcher.split("launch_claude() {", 1)[1].split("\n}", 1)[0]
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        claude = bin_dir / "claude"
        claude.write_text('#!/bin/bash\nprintf "%s\\n" "${CLAUDE_CODE_TMPDIR-unset}"\n')
        claude.chmod(0o700)
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", MEGAVIBE_HOME=str(home))
        command = ["bash", "-ec", f'launch_claude() {{{function}\n}}; LAUNCH_PROJECT=$1; launch_claude', "_"]
        def launch(path, **overrides):
            return subprocess.check_output([*command, path], env=dict(env, **overrides), text=True).rstrip("\n")
        assert launch(temp) == "unset"
        assert launch(alias) == str(base)
        assert launch(alias, CLAUDE_CODE_TMPDIR="/chosen/missing") == "/chosen/missing"
        assert launch(alias, CLAUDE_CODE_TMPDIR="") == ""
        assert launch(alias, MEGAVIBE_SCRATCH_FOLLOWS_PROJECT="0") == "unset"
        assert launcher.count('launch_claude --dangerously-skip-permissions') == 2
        (scripts / "scratch-volume.py").write_text(f"print({str(temp / 'missing')!r})")
        missing = subprocess.run([*command, alias], env=env, text=True, capture_output=True, check=True)
        assert missing.stdout == "unset\n" and missing.stderr.count("\n") == 1
        root.rename(root.with_name("saved"))
        root.symlink_to(root.with_name("saved"))
        assert not list(volume.discover(temp, home))
        base.rename(base.with_name("saved-base"))
        base.symlink_to(base.with_name("saved-base"))
        assert not list(volume.discover(temp, home))
        assert len(run(project)[1]) == 1
        mount.rename(temp / "unmounted")
        assert not list(volume.discover(temp, home))
env = dict(os.environ, CLAUDE_CODE_TMPDIR=str(base))
actual = subprocess.check_output([repo / "scripts/scratch-root.sh", "root"], env=env, text=True)
assert actual.strip().startswith(("/tmp/claude-", "/private/tmp/claude-"))
print("scratch volume fixture passed")
PY
