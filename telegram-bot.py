#!/usr/bin/env python3
"""Megavibe Remote v4 — Personal assistant + project session launcher.

Architecture:
  - 1:1 TG DM chat
  - Personal assistant: full Claude session in tmux (all tools, persistent)
  - Project commands: spawns `claude remote-control` → sends session URL
  - Project status: reads .agent/ directly
  - Watch: voice STT via OpenAI Whisper, concise responses

The personal session runs in tmux as a full interactive Claude — not claude -p.
Messages are injected via tmux send-keys, responses read from session JSONL.
This gives the personal assistant ALL tools (WebSearch, MCP, etc.).

Env vars:
  MEGAVIBE_TELEGRAM_TOKEN   — Bot token from @BotFather (required)
  MEGAVIBE_TELEGRAM_USER_ID — Your Telegram user ID for auth (required)
  OPENAI_API_KEY            — For voice STT (gpt-4o-transcribe)
  MEGAVIBE_TG_PLUGIN_DIR    — Button plugins (default ~/.megavibe/tg-plugins; README-remote.md)
"""

import asyncio
import fcntl
import html
import json
import logging
import os
import signal
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("megavibe-remote")
logging.getLogger("httpx").setLevel(logging.WARNING)

# ─── Config ──────────────────────────────────────────────────────────

TOKEN = os.environ.get("MEGAVIBE_TELEGRAM_TOKEN", "")
ALLOWED_USER = os.environ.get("MEGAVIBE_TELEGRAM_USER_ID", "")
OPENAI_KEY = os.environ.get("OPENAI_API_KEY", "")
MEGAVIBE_HOME = Path.home() / ".megavibe"
PROJECTS_FILE = MEGAVIBE_HOME / "projects.json"
PERSONAL_DIR = MEGAVIBE_HOME / "personal"
TMUX_SESSION = "megavibe-personal"

for var, name in [(TOKEN, "MEGAVIBE_TELEGRAM_TOKEN"), (ALLOWED_USER, "MEGAVIBE_TELEGRAM_USER_ID")]:
    if not var:
        print(f"Error: {name} not set", file=sys.stderr)
        sys.exit(1)

ALLOWED_USER_ID = int(ALLOWED_USER)

try:
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
    from telegram.error import Conflict, NetworkError, TimedOut
    from telegram.ext import (
        ApplicationBuilder, CallbackQueryHandler, CommandHandler,
        ContextTypes, MessageHandler, filters,
    )
except ImportError:
    print("Error: python-telegram-bot not installed. Run: pip3 install python-telegram-bot", file=sys.stderr)
    sys.exit(1)


# ─── Single-instance lock ────────────────────────────────────────────
# Two pollers sharing one token make Telegram return
# `Conflict: terminated by other getUpdates request`, which the network
# retry loop then spams forever. The CLI guards its own paths (the default
# reuses a running bot; `--fg` refuses if the supervised bot is up), but a
# second machine reusing the token — or any direct launch — can still
# collide. An flock held for the process lifetime is the real guard: the
# second LOCAL instance refuses to start instead of conflicting.
_LOCK_FH = None  # module-global keeps the fd (and thus the lock) alive


def acquire_single_instance_lock() -> None:
    global _LOCK_FH
    MEGAVIBE_HOME.mkdir(parents=True, exist_ok=True)
    _LOCK_FH = open(MEGAVIBE_HOME / "remote.lock", "w")
    try:
        fcntl.flock(_LOCK_FH.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(
            "Error: another megavibe remote bot already holds "
            "~/.megavibe/remote.lock. Stop it first: megavibe remote --stop",
            file=sys.stderr,
        )
        sys.exit(1)
    _LOCK_FH.write(str(os.getpid()))
    _LOCK_FH.flush()

# ─── Project registry ────────────────────────────────────────────────


def load_projects() -> dict:
    if PROJECTS_FILE.exists():
        try:
            return json.loads(PROJECTS_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            return {}
    return {}


def save_projects(projects: dict):
    PROJECTS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = PROJECTS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(projects, indent=2))
    tmp.rename(PROJECTS_FILE)


def find_project(text: str) -> tuple[str | None, str | None]:
    """Find a project name mentioned in text. Returns (name, dir) or (None, None)."""
    projects = load_projects()
    for name in sorted(projects, key=len, reverse=True):
        if re.search(rf'\b{re.escape(name)}\b', text, re.IGNORECASE):
            return name, projects[name]
    return None, None


# ─── Helpers ─────────────────────────────────────────────────────────


def tasks_summary(project_dir: str) -> str:
    tasks_file = Path(project_dir) / ".agent" / "TASKS.md"
    if not tasks_file.exists():
        return "No tasks"
    text = tasks_file.read_text()
    done = text.count("| done")
    pending = text.count("| pending") + text.count("| in progress") + text.count("| planned")
    total = done + pending
    return f"{done}/{total} tasks done" if total > 0 else "No tasks"


def recent_activity(project_dir: str, n: int = 3) -> str:
    fc = Path(project_dir) / ".agent" / "FULL_CONTEXT.md"
    if not fc.exists():
        return ""
    lines = fc.read_text().strip().splitlines()
    return "\n".join(lines[-n:]) if lines else ""


def is_session_active(project_dir: str) -> bool:
    lock = Path(project_dir) / ".agent" / ".session-lock.d" / "metadata.json"
    if not lock.exists():
        return False
    try:
        meta = json.loads(lock.read_text())
        pid = meta.get("pid", 0)
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError, json.JSONDecodeError):
        return False


# ─── Personal session (tmux + full Claude) ───────────────────────────


def find_session_jsonl(project_dir: Path) -> Path | None:
    """Find the most recent session JSONL for a project.
    Claude encodes paths as directory names under ~/.claude/projects/
    but the encoding is opaque (dots stripped, slashes become dashes).
    We scan for a matching suffix instead of computing the encoding."""
    projects_root = Path.home() / ".claude" / "projects"
    if not projects_root.exists():
        return None
    # The dir name ends with the project's basename(s)
    dir_name = project_dir.name  # e.g. "personal"
    candidates = [d for d in projects_root.iterdir()
                  if d.is_dir() and d.name.endswith(dir_name)]
    if not candidates:
        # Broader search: any dir containing the last two path components
        parent = project_dir.parent.name  # e.g. ".megavibe" or "megavibe"
        suffix = f"{parent.lstrip('.')}-{dir_name}"  # "megavibe-personal"
        candidates = [d for d in projects_root.iterdir()
                      if d.is_dir() and suffix in d.name]
    if not candidates:
        return None
    # Pick the one with the most recent JSONL
    best = None
    best_mtime = 0
    for cand in candidates:
        for jf in cand.glob("*.jsonl"):
            mt = jf.stat().st_mtime
            if mt > best_mtime:
                best = jf
                best_mtime = mt
    return best


def is_personal_session_alive() -> bool:
    """Check if the tmux personal session is running."""
    result = subprocess.run(["tmux", "has-session", "-t", TMUX_SESSION],
                            capture_output=True, timeout=5)
    return result.returncode == 0


def start_personal_session():
    """Start a full Claude session in tmux for personal assistant."""
    if is_personal_session_alive():
        log.info("Personal tmux session already running")
        return

    # Pre-accept workspace trust (run claude once to establish trust)
    log.info("Ensuring workspace trust for personal dir...")
    subprocess.run(
        ["claude", "-p", "--dangerously-skip-permissions", "echo ok"],
        cwd=str(PERSONAL_DIR), capture_output=True, timeout=30,
    )

    log.info("Starting personal Claude session in tmux...")
    # Create tmux session running claude directly (not megavibe — avoid lock issues)
    subprocess.run([
        "tmux", "new-session", "-d", "-s", TMUX_SESSION,
        "-c", str(PERSONAL_DIR),
        "claude", "--dangerously-skip-permissions", "--remote-control",
        "--name", "Personal Assistant",
    ], check=True, timeout=10)
    # Give Claude a moment to start and create JSONL
    time.sleep(5)
    log.info("Personal session started in tmux session '%s'", TMUX_SESSION)


def _norm(s: str) -> str:
    """Collapse all whitespace (incl. newlines) so multi-line text matches."""
    return " ".join(s.split())


def _new_user_turns(jsonl_path: Path, start_offset: int) -> list[str]:
    """Text of user turns appended to the JSONL after start_offset."""
    out: list[str] = []
    try:
        with open(jsonl_path) as f:
            f.seek(start_offset)
            data = f.read()
    except OSError:
        return out
    for line in data.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "user":
            continue
        content = entry.get("message", {}).get("content", "")
        if isinstance(content, list):
            content = " ".join(
                b.get("text", "") for b in content
                if isinstance(b, dict) and b.get("type") == "text"
            )
        if isinstance(content, str):
            out.append(content)
    return out


def _submit_confirmed(jsonl_path: Path, start_offset: int, needle: str) -> bool:
    """True once a user turn matching `needle` lands in the JSONL after offset."""
    n = _norm(needle)[:60]
    turns = _new_user_turns(jsonl_path, start_offset)
    if not n:
        return bool(turns)  # empty message: any new user turn counts
    return any(n in _norm(t) for t in turns)


def inject_message(text: str, jsonl_path: Path | None = None) -> bool:
    """Type a message into the personal tmux session and CONFIRM it submitted.

    Returns True once the user turn is observed in the session JSONL (i.e. the
    message actually submitted), False if it could not be confirmed.

    Why the confirm loop: submission into Claude Code's Ink TUI is unreliable
    for multi-line / pasted input — the trailing Enter can be swallowed by
    paste-detection and the message then sits in the input box forever. That is
    exactly what produced "only 'Wtf?' arrived, ohne Bezug" failures: the real
    question never submitted, only later one-word follow-ups did. So we send
    Enter and verify the user turn landed in the JSONL, re-pressing Enter until
    it does. Claude writes the user turn to the JSONL at submit time, which is a
    reliable oracle.
    """
    # Byte offset to read NEW jsonl lines from, so we only match OUR turn.
    start_offset = 0
    if jsonl_path is not None and jsonl_path.exists():
        try:
            start_offset = jsonl_path.stat().st_size
        except OSError:
            start_offset = 0

    # Interrupt any in-progress generation and clear the input box.
    # Exactly ONE Ctrl-C: a second consecutive Ctrl-C would quit Claude.
    subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, "C-c"], timeout=5)
    time.sleep(0.4)

    # Type the message literally. -l stops tmux interpreting key-names that
    # appear in user text (e.g. "Enter", "C-c"); `--` guards a leading dash.
    subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, "-l", "--", text],
                   timeout=5, check=True)
    time.sleep(0.4)

    # Cold start (no JSONL yet): blind submit, can't confirm.
    if jsonl_path is None:
        subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, "Enter"], timeout=5)
        return True

    # Confirm-and-retry: press Enter until the user turn appears in the JSONL.
    for attempt in range(1, 9):
        subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, "Enter"], timeout=5)
        for _ in range(8):  # poll ~2s per Enter
            time.sleep(0.25)
            if _submit_confirmed(jsonl_path, start_offset, text):
                log.info("Submit confirmed on Enter attempt %d", attempt)
                return True
    log.error("Submit NOT confirmed after 8 Enter attempts — message may be stuck")
    return False


async def wait_for_response(jsonl_path: Path, after_timestamp: float,
                             timeout: float = 120) -> str | None:
    """Watch JSONL for a new assistant text response after the given timestamp."""
    deadline = time.time() + timeout
    # Start reading from current end of file (only new entries)
    last_size = jsonl_path.stat().st_size if jsonl_path.exists() else 0
    text_parts = []

    log.info("Watching JSONL from byte %d (timeout %ds)", last_size, timeout)

    while time.time() < deadline:
        await asyncio.sleep(0.5)

        if not jsonl_path.exists():
            continue

        try:
            current_size = jsonl_path.stat().st_size
        except OSError:
            continue

        if current_size <= last_size:
            continue

        # Read new data
        try:
            with open(jsonl_path) as f:
                f.seek(last_size)
                new_data = f.read()
                last_size = f.tell()
        except OSError:
            continue

        for line in new_data.strip().splitlines():
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            entry_type = entry.get("type", "")

            if entry_type == "assistant":
                msg = entry.get("message", {})
                content = msg.get("content", [])
                for block in content:
                    if block.get("type") == "text" and block.get("text"):
                        text_parts.append(block["text"])
                # Only return on end_turn (not tool_use — those are intermediate)
                if msg.get("stop_reason") == "end_turn" and text_parts:
                    log.info("Got response (%d chars)", sum(len(t) for t in text_parts))
                    return "\n".join(text_parts)

    # Timeout — return whatever we collected
    if text_parts:
        log.info("Timeout but have partial response (%d chars)", sum(len(t) for t in text_parts))
        return "\n".join(text_parts)
    log.warning("No response detected in JSONL within %ds", timeout)
    return None


async def ask_personal(text: str, is_voice: bool = False) -> str:
    """Send a message to the personal Claude session and wait for response."""
    if not is_personal_session_alive():
        start_personal_session()
        await asyncio.sleep(5)  # extra time for first start

    # Append brevity hint for Watch/voice
    prompt = text
    if is_voice:
        prompt = text + " (Keep it concise — user is on mobile/Watch.)"

    # Find the JSONL BEFORE injecting so inject_message can confirm our turn
    # actually landed (it captures the file's current end as its read offset).
    jsonl = find_session_jsonl(PERSONAL_DIR)
    log.info("Personal JSONL: %s", jsonl)
    timestamp = time.time()

    submitted = inject_message(prompt, jsonl)
    if not submitted:
        log.error("Message not confirmed submitted to personal session")
        return ("⚠️ Couldn't get that into the session — it may be stuck in the "
                "input box. Send it once more, or check: "
                "tmux attach -t megavibe-personal")

    # Cold start: the JSONL may have only just been created.
    if jsonl is None:
        await asyncio.sleep(2)
        jsonl = find_session_jsonl(PERSONAL_DIR)

    if jsonl:
        response = await wait_for_response(jsonl, timestamp, timeout=600)
        if response:
            return response

    return "(No response received — check tmux session: tmux attach -t megavibe-personal)"


# ─── Project session spawning ────────────────────────────────────────

active_sessions: dict[str, asyncio.subprocess.Process] = {}


async def spawn_remote_session(project_dir: str, name: str) -> str | None:
    """Spawn `claude remote-control` in project dir, capture session URL."""
    cmd = ["claude", "remote-control", "--name", name]

    proc = await asyncio.create_subprocess_exec(
        *cmd, cwd=project_dir,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    active_sessions[project_dir] = proc

    url = None
    try:
        deadline = asyncio.get_event_loop().time() + 30
        while asyncio.get_event_loop().time() < deadline:
            try:
                line = await asyncio.wait_for(proc.stderr.readline(), timeout=2)
                if not line:
                    line = await asyncio.wait_for(proc.stdout.readline(), timeout=1)
                if line:
                    text = line.decode(errors="replace").strip()
                    log.info("remote-control: %s", text)
                    match = re.search(r'https://claude\.ai/\S+', text)
                    if match:
                        url = match.group(0)
                        break
            except asyncio.TimeoutError:
                if proc.returncode is not None:
                    break
                continue
    except Exception as e:
        log.error("Error capturing URL: %s", e)

    return url


# ─── Auth ────────────────────────────────────────────────────────────


def auth(func):
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        if update.effective_user and update.effective_user.id == ALLOWED_USER_ID:
            return await func(update, context)
    return wrapper


# ─── Button plugins ──────────────────────────────────────────────────
# Telegram delivers button presses only to the process polling the token, so a
# tool that sends its own messages with inline buttons (a mail digest, say)
# cannot receive the presses itself while this bot runs. Instead it names a
# plugin: callback_data "<name>:<payload>" runs the executable
# $MEGAVIBE_TG_PLUGIN_DIR/<name> (default ~/.megavibe/tg-plugins/<name>) as
#     <plugin> callback <payload>          (a button was pressed)
#     <plugin> reply <text>                (you replied to one of its messages)
# with a JSON context on stdin, and applies the JSON it prints:
#     {"toast": str, "edit_text": str, "parse_mode": "HTML", "buttons": [[{"text","data"|"url"}]],
#      "reply_text": str}
# No shell is involved, the name is restricted to [a-z0-9_-], and only the
# allowed user reaches this code (the @auth decorator). No plugin dir, no change.

PLUGIN_DIR = Path(os.environ.get("MEGAVIBE_TG_PLUGIN_DIR", MEGAVIBE_HOME / "tg-plugins")).expanduser()
PLUGIN_NAME_RE = re.compile(r"^[a-z0-9_-]{1,24}$")
PLUGIN_TIMEOUT = 180


def plugin_for(data: str | None):
    """(path, payload) for callback data naming an installed plugin, else None."""
    if not data or ":" not in data:
        return None
    name, payload = data.split(":", 1)
    if not PLUGIN_NAME_RE.fullmatch(name):
        return None
    path = PLUGIN_DIR / name
    if not (path.is_file() and os.access(path, os.X_OK)):
        return None
    return path, payload


def markup_from(rows):
    try:
        return _markup_from(rows)
    except Exception as e:             # a malformed "buttons" value must not lose the result
        log.info("plugin buttons ignored: %s", e)
        return None


def _markup_from(rows):
    out = []
    for row in rows or []:
        btns = []
        for b in row:
            if b.get("url"):
                btns.append(InlineKeyboardButton(str(b["text"])[:64], url=str(b["url"])))
            elif b.get("data"):
                data = str(b["data"])
                if len(data.encode()) > 64:        # Telegram's limit is 64 BYTES
                    log.warning("button data over 64 bytes dropped: %r", data[:40])
                    continue
                btns.append(InlineKeyboardButton(str(b["text"])[:64], callback_data=data))
        if btns:
            out.append(btns)
    return InlineKeyboardMarkup(out) if out else None


async def _safe_answer(answer, text="") -> bool:
    """Acknowledge a button press; a failed acknowledgement must never abort the
    plugin run or leave its process behind. True if Telegram took it."""
    if not answer:
        return False
    try:
        await answer(str(text or "")[:200])
        return True
    except Exception as e:
        log.info("callback answer failed: %s", e)
        return False


PLUGIN_OUT_MAX = 1 << 20          # stdout beyond this kills the plugin
PLUGIN_ERR_KEEP = 8 << 10         # only the tail of stderr is kept (for the log)
PLUGIN_DRAIN = 1.0                # after the leader exits, wait this long for output
PLUGIN_TEXT_MAX = 16 << 10        # any text from a plugin is cut to this BEFORE processing
PLUGIN_GROUPS: set[int] = set()   # process groups of plugins that are running now


def _killpg(pgid: int, sig) -> bool:
    """Signal a group; False when it no longer exists."""
    try:
        os.killpg(pgid, sig)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def kill_plugin_groups():
    """Kill every live plugin group (shutdown, SIGHUP). Synchronous and safe in a
    signal handler."""
    for pgid in list(PLUGIN_GROUPS):
        _killpg(pgid, signal.SIGKILL)


STOPPING = False


def on_stop_signal(signum, frame):
    """SIGTERM/SIGINT: kill the plugin groups FIRST, then stop through PTB's
    KeyboardInterrupt path. PTB's own stop waits for running handler tasks before
    post_stop, so a running plugin would otherwise hold shutdown for up to its
    180 s limit. A press still queued when the signal arrives starts no plugin."""
    global STOPPING
    STOPPING = True
    kill_plugin_groups()
    raise KeyboardInterrupt


def on_sighup(signum, frame):
    """tmux kill-session sends SIGHUP: plugins have their own sessions, so they
    would survive it. Kill them, then die at once as the bot always did on
    SIGHUP: a graceful stop would wait for an in-flight question (up to 10
    minutes) while holding the bot's lock, so a restart right after
    `megavibe remote --stop` would fail."""
    kill_plugin_groups()
    signal.signal(signal.SIGHUP, signal.SIG_DFL)
    signal.raise_signal(signal.SIGHUP)


async def _reap_group(pgid: int):
    """Whatever is left in the plugin's group: TERM, then KILL after 1 s."""
    if not _killpg(pgid, signal.SIGTERM):
        return
    for _ in range(20):
        await asyncio.sleep(0.05)
        if not _killpg(pgid, 0):
            return
    _killpg(pgid, signal.SIGKILL)


async def run_plugin(path: Path, mode: str, arg: str, ctx: dict, answer=None) -> dict:
    """Run a plugin under ONE deadline (PLUGIN_TIMEOUT). If it outlives
    Telegram's ~15 s callback window, acknowledge the press first so the button
    stops spinning. The plugin gets its own process group; whatever is left in
    it is killed on EVERY way out (result, failure, timeout, cancellation).
    Output is read with caps, never buffered whole. Never raises (except
    cancellation); failures come back as a toast, and `_answered` says whether
    the press was already acknowledged."""
    if STOPPING:
        return {"toast": "The bot is shutting down; try again in a moment."}
    try:
        return await _run_plugin(path, mode, arg, ctx, answer)
    except asyncio.CancelledError:
        raise
    except Exception as e:
        # RecursionError, ValueError and friends: still answer the press.
        log.warning("plugin %s runner failed: %r", path.name, e)
        return {"toast": f"\u274c {path.name} failed", "_answered": False}


async def _run_plugin(path, mode, arg, ctx, answer) -> dict:
    answered = False
    loop = asyncio.get_running_loop()
    deadline = loop.time() + PLUGIN_TIMEOUT
    try:
        stdin_data = json.dumps(ctx).encode()
        proc = await asyncio.create_subprocess_exec(
            str(path), mode, arg, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            start_new_session=True)
    except (OSError, ValueError, RecursionError, TypeError) as e:
        log.warning("plugin %s could not start: %s", path.name, e)
        return {"toast": f"\u274c {path.name} could not start", "_answered": False}

    pgid = proc.pid
    PLUGIN_GROUPS.add(pgid)
    out_buf = bytearray()
    err_buf = bytearray()
    state = {"overflow": False}

    async def feed():
        try:
            proc.stdin.write(stdin_data)
            await proc.stdin.drain()
        except Exception:
            pass
        finally:
            try:
                proc.stdin.close()
            except Exception:
                pass

    async def read_out():
        while True:
            chunk = await proc.stdout.read(65536)
            if not chunk:
                return
            out_buf.extend(chunk)
            if len(out_buf) > PLUGIN_OUT_MAX:
                state["overflow"] = True
                _killpg(pgid, signal.SIGKILL)
                return

    async def read_err():
        while True:
            chunk = await proc.stderr.read(65536)
            if not chunk:
                return
            err_buf.extend(chunk)
            if len(err_buf) > 2 * PLUGIN_ERR_KEEP:
                del err_buf[:-PLUGIN_ERR_KEEP]

    async def collect():
        readers = [asyncio.ensure_future(read_out()), asyncio.ensure_future(read_err()),
                   asyncio.ensure_future(feed())]
        try:
            # The leader only. proc.wait() also waits for the pipes to close, which a
            # backgrounded child holding them would delay until it exits.
            while proc.returncode is None:
                await asyncio.sleep(0.05)
            await asyncio.wait(readers, timeout=PLUGIN_DRAIN)
        finally:
            for r in readers:
                if not r.done():
                    r.cancel()

    work = asyncio.ensure_future(collect())
    hard = False
    try:
        done, _ = await asyncio.wait({work}, timeout=8)
        if not done:
            answered = await _safe_answer(answer, "\u23f3 working\u2026")
            done, _ = await asyncio.wait({work}, timeout=max(1.0, deadline - loop.time()))
        if not done:
            hard = True
            _killpg(pgid, signal.SIGKILL)
            return {"toast": f"\u274c {path.name} timed out", "_answered": answered}
        work.result()
    except BaseException:
        hard = True
        _killpg(pgid, signal.SIGKILL)      # cancelled or crashed: leave nothing running
        raise
    finally:
        if not work.done():
            work.cancel()
        try:
            if proc.returncode is None:
                _killpg(pgid, signal.SIGKILL)
            for _ in range(100):                       # the leader is reaped by asyncio
                if proc.returncode is not None:
                    break
                await asyncio.sleep(0.05)
        except BaseException:
            pass
        try:
            if not hard:
                await _reap_group(pgid)
        except BaseException:
            _killpg(pgid, signal.SIGKILL)
        PLUGIN_GROUPS.discard(pgid)

    if state["overflow"]:
        log.warning("plugin %s output over %d bytes; killed", path.name, PLUGIN_OUT_MAX)
        return {"toast": f"\u274c {path.name}: output too large", "_answered": answered}
    if proc.returncode != 0:
        log.warning("plugin %s exited %s: %s", path.name, proc.returncode,
                    bytes(err_buf[-300:]).decode(errors="replace"))
        return {"toast": f"\u274c {path.name} failed", "_answered": answered}
    try:
        res = json.loads(bytes(out_buf).decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        res = None
    if not isinstance(res, dict):
        return {"toast": f"\u274c {path.name} returned no JSON object", "_answered": answered}
    res["_answered"] = answered
    return res


def fit(text, parse_mode):
    """Telegram's 4096-character limit, without cutting formatting in half: an
    over-long formatted text is sent as plain text instead (a slice can end
    inside a tag, and then the whole message is rejected). The input is cut to
    PLUGIN_TEXT_MAX first and stripped in one linear pass, so a hostile text
    costs the event loop microseconds."""
    text = str(text)[:PLUGIN_TEXT_MAX]
    if not isinstance(parse_mode, str):
        parse_mode = None
    if len(text) <= 4096:
        return text, parse_mode
    if parse_mode and parse_mode.upper() == "HTML":
        text = html.unescape(re.sub(r"<[^<>]*>", "", text))
    elif parse_mode:
        text = re.sub(r"[*_`\\[\]]", "", text)
    return (text if len(text) <= 4096 else text[:4095] + "\u2026"), None


async def apply_plugin_result(res: dict, message, bot, query=None) -> bool:
    """Apply a plugin's result. Returns True when its outcome reached the user.

    The toast is the outcome ("done", "refused: …"). It travels as the press's
    toast when it can; otherwise (reply mode, an early "working…"
    acknowledgement, a rejected answer) it is sent as a chat message, even when
    an edit also succeeded — the edit may not say what the toast says. A failed
    edit (other than "not modified") or a failed reply always produces a
    warning, so a lost card never looks like success."""
    toast = str(res.get("toast") or "")[:PLUGIN_TEXT_MAX].strip()
    toast_done = False
    if query and not res.get("_answered"):
        ok = await _safe_answer(query.answer, toast)
        # A press toast holds 200 characters; a longer outcome is ALSO sent whole.
        toast_done = ok and bool(toast) and len(toast) <= 200
    failed = reply_failed = False
    lost_text = []
    if res.get("edit_text") and message:
        text, mode = fit(res["edit_text"], res.get("parse_mode"))
        try:
            await message.edit_text(text, parse_mode=mode,
                                    reply_markup=markup_from(res.get("buttons")),
                                    disable_web_page_preview=True)
        except Exception as e:
            if "not modified" not in str(e).lower():
                failed = True
                # The card is gone or refused: deliver its text as a message instead.
                plain = str(res["edit_text"])[:PLUGIN_TEXT_MAX]
                if isinstance(res.get("parse_mode"), str) and res["parse_mode"].upper() == "HTML":
                    plain = html.unescape(re.sub(r"<[^<>]*>", "", plain))
                lost_text.append(plain)
            log.info("plugin edit skipped: %s", e)
    if res.get("reply_text") and message:
        text, mode = fit(res["reply_text"], res.get("parse_mode"))
        try:
            await bot.send_message(message.chat_id, text, parse_mode=mode,
                                   reply_markup=markup_from(res.get("reply_buttons")),
                                   reply_to_message_id=message.message_id,
                                   disable_web_page_preview=True)
        except Exception:
            failed = reply_failed = True
            log.exception("plugin reply failed")
    notes = []
    if toast and not toast_done:
        notes.append(toast)
    if lost_text:
        notes.append("\u26a0\ufe0f The card could not be updated; its new text:\n" + lost_text[0])
    elif failed:
        notes.append("\u26a0\ufe0f The result could not be shown.")
    if not notes:
        return True
    if not message:
        return False
    try:
        # Not tied to the source message: it may have been deleted meanwhile.
        await bot.send_message(message.chat_id, "\n".join(notes)[:4096],
                               reply_to_message_id=message.message_id,
                               allow_sending_without_reply=True)
        # A refused edit whose text arrived here as a message still reached the user.
        return not reply_failed
    except Exception as e:
        log.info("plugin toast message failed: %s", e)
        return False


def own_private_message(message, bot) -> bool:
    """Plugins act only on messages THIS bot sent, in a private chat. Otherwise
    another bot's keyboard in a group could route an ordinary reply into a local
    plugin (review 2026-11-03)."""
    chat = getattr(message, "chat", None)
    sender = getattr(message, "from_user", None)    # absent on InaccessibleMessage
    return bool(chat and getattr(chat, "type", None) == "private"
                and sender and sender.id == bot.id)


@auth
async def handle_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Registered non-blocking (block=False): a slow plugin must not hold up the
    next press or an ordinary message."""
    q = update.callback_query
    hit = plugin_for(q.data)
    msg = q.message
    if not hit:
        await _safe_answer(q.answer)
        return
    if not own_private_message(msg, context.bot):
        # Telegram hides messages older than 48 h (InaccessibleMessage, which has
        # no sender); anything else here is a message this bot does not serve.
        old = getattr(msg, "from_user", None) is None
        await _safe_answer(q.answer, "This message is too old to act on." if old
                           else "These buttons are not handled here.")
        return
    path, payload = hit
    ctx = {"chat_id": msg.chat_id, "message_id": msg.message_id, "text": msg.text, "data": q.data}
    res = await run_plugin(path, "callback", payload, ctx, answer=q.answer)
    await apply_plugin_result(res, msg, context.bot, query=q)


def plugin_of_message(message):
    """The plugin whose buttons sit on `message`, if any — how a text reply to a
    plugin's card finds its way back to that plugin."""
    kb = getattr(message, "reply_markup", None)
    for row in (kb.inline_keyboard if kb else []):
        for b in row:
            hit = plugin_for(b.callback_data)
            if hit:
                return hit[0]
    return None


async def _reply_to_plugin(plugin, replied, update, context, text):
    ctx = {"chat_id": replied.chat_id, "message_id": replied.message_id,
           "text": replied.text, "reply_text": text}
    res = await run_plugin(plugin, "reply", text, ctx)
    # No press to toast on here: apply_plugin_result sends the toast (or a
    # warning, when an edit/reply failed) as a message itself.
    await apply_plugin_result(res, replied, context.bot)


# ─── Handlers ────────────────────────────────────────────────────────


@auth
async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Route: project name → remote-control session, else → personal Claude."""
    text = update.message.text.strip()
    replied = update.message.reply_to_message
    plugin = plugin_of_message(replied) if own_private_message(replied, context.bot) else None
    if plugin:
        # In the background, so the text handler (and the next update) is not
        # held for up to PLUGIN_TIMEOUT.
        context.application.create_task(_reply_to_plugin(plugin, replied, update, context, text))
        return
    proj_name, proj_dir = find_project(text)

    if proj_name and proj_dir:
        # Check if session already active (terminal or previous remote)
        if is_session_active(proj_dir):
            status = tasks_summary(proj_dir)
            await update.message.reply_text(
                f"\U0001f7e2 **{proj_name}** has an active session.\n{status}\n\n"
                f"Connect via Claude app or type /rc in the terminal.",
                parse_mode="Markdown")
            return

        status_msg = await update.message.reply_text(f"\u23f3 Starting session in {proj_name}...")
        url = await spawn_remote_session(proj_dir, f"{proj_name}: {text[:50]}")

        if url:
            keyboard = InlineKeyboardMarkup([
                [InlineKeyboardButton("\U0001f4bb Open session", url=url)],
            ])
            status = tasks_summary(proj_dir)
            await status_msg.edit_text(
                f"\U0001f7e2 **{proj_name}** session ready\n{status}\n\nTell Claude: _{text}_",
                reply_markup=keyboard, parse_mode="Markdown",
            )
        else:
            await status_msg.edit_text(f"\u274c Could not start session for {proj_name}")
    else:
        # Personal assistant — full Claude via tmux
        status_msg = await update.message.reply_text("\u23f3 Thinking...")
        try:
            result = await ask_personal(text)
            await send_response(update, result, status_msg)
        except Exception as e:
            log.exception("Personal error")
            await status_msg.edit_text(f"\u274c Error: {e}")


@auth
async def handle_voice(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Voice → OpenAI STT → route like text."""
    if not OPENAI_KEY:
        await update.message.reply_text("Voice requires OPENAI_API_KEY")
        return
    try:
        import httpx
    except ImportError:
        await update.message.reply_text("Voice requires httpx: pip3 install httpx")
        return

    voice_file = await update.message.voice.get_file()
    with tempfile.NamedTemporaryFile(suffix=".ogg", delete=False) as f:
        await voice_file.download_to_drive(f.name)
        ogg_path = f.name

    try:
        async with httpx.AsyncClient(timeout=30) as client:
            with open(ogg_path, "rb") as audio:
                resp = await client.post(
                    "https://api.openai.com/v1/audio/transcriptions",
                    headers={"Authorization": f"Bearer {OPENAI_KEY}"},
                    files={"file": ("voice.ogg", audio, "audio/ogg")},
                    data={"model": "gpt-4o-transcribe"},
                )
                resp.raise_for_status()
                transcript = resp.json()["text"]

        await update.message.reply_text(f'\U0001f3a4 "{transcript}"')

        proj_name, proj_dir = find_project(transcript)
        if proj_name and proj_dir:
            if is_session_active(proj_dir):
                status = tasks_summary(proj_dir)
                await update.message.reply_text(
                    f"\U0001f7e2 **{proj_name}** active. {status}",
                    parse_mode="Markdown")
                return

            status_msg = await update.message.reply_text(f"\u23f3 Starting {proj_name}...")
            url = await spawn_remote_session(proj_dir, f"{proj_name}: {transcript[:50]}")
            if url:
                keyboard = InlineKeyboardMarkup([
                    [InlineKeyboardButton("\U0001f4bb Open session", url=url)],
                ])
                await status_msg.edit_text(
                    f"\U0001f7e2 **{proj_name}** ready",
                    reply_markup=keyboard, parse_mode="Markdown",
                )
            else:
                await status_msg.edit_text(f"\u274c Could not start {proj_name}")
        else:
            # Personal — full Claude via tmux
            status_msg = await update.message.reply_text("\u23f3 Thinking...")
            try:
                result = await ask_personal(transcript, is_voice=True)
                await send_response(update, result, status_msg)
            except Exception as e:
                await status_msg.edit_text(f"\u274c Error: {e}")
    except Exception as e:
        log.exception("Voice failed")
        await update.message.reply_text(f"\u274c Voice error: {e}")
    finally:
        os.unlink(ogg_path)


async def send_response(update: Update, text: str, status_msg):
    """Send response to TG. Future: parse options → inline buttons."""
    if len(text) <= 4096:
        await status_msg.edit_text(text)
    else:
        await status_msg.edit_text(text[:4000] + "\n\n_(full response attached)_",
                                   parse_mode="Markdown")
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
            f.write(text)
            f.flush()
            await update.effective_chat.send_document(
                document=open(f.name, "rb"), filename="response.md")
            os.unlink(f.name)


# ─── Commands ────────────────────────────────────────────────────────


@auth
async def cmd_register(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Register a project: /register <name> <path>"""
    args = context.args
    if not args or len(args) < 2:
        await update.message.reply_text("Usage: /register myproject ~/path/to/project")
        return
    name = args[0].lower()
    project_dir = os.path.expanduser(" ".join(args[1:]))
    project_dir = os.path.abspath(project_dir)
    if not os.path.isdir(project_dir):
        await update.message.reply_text(f"Not a directory: {project_dir}")
        return
    projects = load_projects()
    projects[name] = project_dir
    save_projects(projects)
    status = tasks_summary(project_dir)
    active = "\U0001f7e2 active" if is_session_active(project_dir) else "\u26aa idle"
    await update.message.reply_text(
        f"Registered **{name}** \u2192 `{project_dir}`\n{status} | {active}",
        parse_mode="Markdown")


@auth
async def cmd_projects(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """List registered projects."""
    projects = load_projects()
    if not projects:
        await update.message.reply_text("No projects. Use /register name ~/path")
        return
    lines = []
    for name, d in projects.items():
        if os.path.isdir(d):
            status = tasks_summary(d)
            dot = "\U0001f7e2" if is_session_active(d) else "\u26aa"
            lines.append(f"{dot} **{name}**: {status}")
        else:
            lines.append(f"\u274c **{name}**: missing ({d})")
    await update.message.reply_text("\n".join(lines), parse_mode="Markdown")


@auth
async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Project status: /status [name]"""
    args = context.args
    if args:
        projects = load_projects()
        name = args[0].lower()
        d = projects.get(name)
        if not d:
            await update.message.reply_text(f"Unknown project: {name}")
            return
        status = tasks_summary(d)
        active = "\U0001f7e2 Terminal active" if is_session_active(d) else "\u26aa No active session"
        activity = recent_activity(d, 5)
        await update.message.reply_text(
            f"**{name}**\n{status} | {active}\n\nRecent:\n{activity}",
            parse_mode="Markdown")
    else:
        await cmd_projects(update, context)


@auth
async def cmd_cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Kill a remote-control session or interrupt personal."""
    args = context.args
    if args and args[0].lower() == "personal":
        if is_personal_session_alive():
            subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, "C-c"], timeout=5)
            await update.message.reply_text("\u274c Interrupted personal session")
        else:
            await update.message.reply_text("Personal session not running")
        return
    if not args:
        # Cancel all remote sessions
        killed = 0
        for d, proc in list(active_sessions.items()):
            proc.terminate()
            active_sessions.pop(d, None)
            killed += 1
        if killed:
            await update.message.reply_text(f"\u274c Killed {killed} session(s)")
        else:
            await update.message.reply_text("No active remote sessions")
        return
    projects = load_projects()
    name = args[0].lower()
    d = projects.get(name)
    if d and d in active_sessions:
        active_sessions[d].terminate()
        active_sessions.pop(d)
        await update.message.reply_text(f"\u274c Killed {name} session")
    else:
        await update.message.reply_text(f"No active session for {name}")


@auth
async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "**Megavibe Remote v4**\n\n"
        "Send any message:\n"
        "\u2022 Mention a project \u2192 opens Claude session in Claude app\n"
        "\u2022 No project name \u2192 personal assistant (full Claude)\n"
        "\u2022 Voice notes \u2192 transcribed + routed\n\n"
        "Commands:\n"
        "/register name ~/path \u2014 register project\n"
        "/projects \u2014 list all\n"
        "/status [name] \u2014 project status\n"
        "/cancel [name|personal] \u2014 stop session\n"
        "/help \u2014 this message",
        parse_mode="Markdown")


# ─── Main ────────────────────────────────────────────────────────────


async def on_error(update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Keep polling errors quiet and legible.

    Without a registered error handler, PTB logs a full multi-frame traceback
    for every transient get_updates failure ("No error handlers are registered,
    logging exception") — alarming noise for what is just a flaky network. Route
    them here: transient drops get one warning line, Conflict gets an actionable
    message, everything else keeps its traceback.
    """
    err = context.error
    if isinstance(err, Conflict):
        log.error(
            "Telegram Conflict: another instance is polling with this token. "
            "Only one bot may run — check `megavibe remote --status` and any "
            "other machine/session. Polling will keep retrying."
        )
    elif isinstance(err, (NetworkError, TimedOut)):
        log.warning("Transient network error (%s); polling will retry.", type(err).__name__)
    else:
        log.error("Unhandled error in update %s", update, exc_info=err)


async def _post_stop(app):
    kill_plugin_groups()


def main():
    # Ensure personal session is running
    if subprocess.run(["which", "tmux"], capture_output=True).returncode != 0:
        print("Error: tmux not installed. Run: brew install tmux", file=sys.stderr)
        sys.exit(1)

    acquire_single_instance_lock()
    start_personal_session()

    app = (ApplicationBuilder().token(TOKEN)
           .post_stop(_post_stop).post_shutdown(_post_stop).build())
    signal.signal(signal.SIGHUP, on_sighup)
    signal.signal(signal.SIGTERM, on_stop_signal)
    signal.signal(signal.SIGINT, on_stop_signal)

    app.add_handler(CommandHandler("register", cmd_register))
    app.add_handler(CommandHandler("projects", cmd_projects))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("cancel", cmd_cancel))
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(CallbackQueryHandler(handle_callback, block=False))
    app.add_handler(MessageHandler(filters.VOICE, handle_voice))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))
    app.add_error_handler(on_error)

    log.info("Megavibe Remote v4 — personal (tmux:%s) + project launcher", TMUX_SESSION)
    # Signals are ours (on_stop_signal kills plugin groups before PTB waits for tasks).
    app.run_polling(drop_pending_updates=True, stop_signals=None)


if __name__ == "__main__":
    main()
