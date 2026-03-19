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
"""

import asyncio
import json
import logging
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("megavibe-remote")

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
    from telegram.ext import (
        ApplicationBuilder, CommandHandler,
        ContextTypes, MessageHandler, filters,
    )
except ImportError:
    print("Error: python-telegram-bot not installed. Run: pip3 install python-telegram-bot", file=sys.stderr)
    sys.exit(1)

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


def inject_message(text: str):
    """Inject a message into the personal tmux session via send-keys."""
    # Escape special characters for tmux
    # Send Ctrl+C first to interrupt any in-progress generation
    subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, "C-c"], timeout=5)
    time.sleep(0.3)
    # Send the actual message
    subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, text, "Enter"],
                    timeout=5, check=True)


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

    timestamp = time.time()
    inject_message(prompt)

    # Wait a moment for Claude to start processing, then find the JSONL
    await asyncio.sleep(2)
    jsonl = find_session_jsonl(PERSONAL_DIR)
    log.info("Personal JSONL: %s", jsonl)

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


# ─── Handlers ────────────────────────────────────────────────────────


@auth
async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Route: project name → remote-control session, else → personal Claude."""
    text = update.message.text.strip()
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


def main():
    # Ensure personal session is running
    if subprocess.run(["which", "tmux"], capture_output=True).returncode != 0:
        print("Error: tmux not installed. Run: brew install tmux", file=sys.stderr)
        sys.exit(1)

    start_personal_session()

    app = ApplicationBuilder().token(TOKEN).build()

    app.add_handler(CommandHandler("register", cmd_register))
    app.add_handler(CommandHandler("projects", cmd_projects))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("cancel", cmd_cancel))
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(MessageHandler(filters.VOICE, handle_voice))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))

    log.info("Megavibe Remote v4 — personal (tmux:%s) + project launcher", TMUX_SESSION)
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
