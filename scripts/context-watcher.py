#!/usr/bin/env python3
"""
Megavibe context-watcher — long-running daemon that keeps .agent/ files fresh
from a live Claude Code transcript, with NO in-session token tax.

Lifecycle: one process per Claude session. Spawned by on-session-start.sh
into a named tmux session ('mvw-<sid12>'); cleaned up by on-session-end.sh.

Loop (every --interval seconds, default 300):
  1. Read new turns from --transcript past .agent/LOGS/.flush-cursor.<sid>.
  2. If fewer than --min-new-turns, skip.
  3. Send the slice + existing .agent/ files to a backend (Gemini → Codex).
  4. Parse the JSON envelope. Substring-validate every verbatim_evidence
     against the slice. Lessons additionally require user-role evidence.
  5. Auto-apply narrative/lessons/tasks_patch under flock.
  6. Stage decisions to .agent/LOGS/pending-decisions.<sid>.jsonl —
     human gates these via scripts/review-decisions.py.
  7. Advance cursor atomically (write tmpfile, rename).

SIGTERM does one last flush then exits clean.

Operational notes:
  - The daemon writes to .agent/ files OUTSIDE the Claude session, so it
    does not trigger PostToolUse hooks. But its writes DO bump file mtimes,
    which log-tool-event.sh notices and uses to reset the stale-context
    counter — exactly the intended side-effect.
  - Pure subscription path is best-effort: if all backends fail, the cycle
    is logged and skipped. The watcher never blocks the user.
  - Multi-session: concurrent watchers on the same project use flock on
    .agent/<FILE>.lock to serialize append-to-shared-files.

Usage:
  scripts/context-watcher.py \\
    --session-id <SID> \\
    --project-dir <PROJ> \\
    --transcript ~/.claude/projects/<slug>/<sid>.jsonl \\
    [--interval 300] [--min-new-turns 10] [--max-turns 200]
    [--once] [--backend gemini|codex|auto]
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------- transcript slice + role extraction (shared with the spike) ------

def load_transcript_slice(path: Path, cursor: int, max_turns: int) -> tuple[list[dict], int]:
    turns: list[dict] = []
    new_cursor = cursor
    if not path.exists():
        return [], cursor
    with path.open() as f:
        for i, line in enumerate(f):
            if i < cursor:
                continue
            line = line.strip()
            if not line:
                new_cursor = i + 1
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                new_cursor = i + 1
                continue
            turns.append(obj)
            new_cursor = i + 1
            if len(turns) >= max_turns:
                break
    return turns, new_cursor


def slice_date_range(turns: list[dict]) -> tuple[str, str]:
    stamps: list[str] = []
    for t in turns:
        ts = t.get("timestamp") or (t.get("message") or {}).get("timestamp")
        if isinstance(ts, str) and len(ts) >= 10:
            stamps.append(ts[:10])
    if not stamps:
        today = datetime.now(timezone.utc).date().isoformat()
        return today, today
    return stamps[0], stamps[-1]


def compact_turn(t: dict) -> dict | None:
    typ = t.get("type")
    if typ not in ("user", "assistant"):
        return None
    msg = t.get("message") or {}
    role = msg.get("role") or typ
    content = msg.get("content")
    pieces: list[str] = []
    if isinstance(content, str):
        pieces.append(content[:4000])
    elif isinstance(content, list):
        for c in content:
            if not isinstance(c, dict):
                continue
            ctype = c.get("type")
            if ctype == "text":
                pieces.append(c.get("text", "")[:4000])
            elif ctype == "thinking":
                pieces.append(f"[thinking] {c.get('thinking','')[:2000]}")
            elif ctype == "tool_use":
                name = c.get("name", "?")
                inp = json.dumps(c.get("input", {}))[:500]
                pieces.append(f"[tool_use:{name}] {inp}")
            elif ctype == "tool_result":
                out = c.get("content", "")
                if isinstance(out, list):
                    out = " ".join(
                        x.get("text", "") if isinstance(x, dict) else str(x)
                        for x in out
                    )
                pieces.append(f"[tool_result] {str(out)[:1500]}")
    if not pieces:
        return None
    return {"role": role, "text": "\n".join(pieces)}


# ---------- prompt + validation (mirrors the spike v3) ---------------------

def read_tail(path: Path, max_chars: int = 8000) -> str:
    if not path.exists():
        return f"(no {path.name})"
    try:
        data = path.read_text()
        return data if len(data) <= max_chars else data[-max_chars:]
    except OSError:
        return f"(unreadable {path.name})"


PROMPT_TEMPLATE = """You are the context watcher for a Claude Code session. You read raw transcript turns and emit ONLY a JSON envelope describing what should be appended to durable project context files.

**ABSOLUTE RULE: every extracted item must include `verbatim_evidence` — an EXACT substring (>=20 chars) lifted from the transcript slice below. No paraphrasing. No inference from existing context files. If you cannot quote it from the NEW SLICE, do not extract it.**

Items without valid evidence are dropped by an automated post-check.

## Existing project files (for de-duplication ONLY — never quote or extract from these)

### Tail of FULL_CONTEXT.md
{full_ctx}

### DECISIONS.md
{decisions}

### LESSONS.md
{lessons}

### TASKS.md
{tasks}

## NEW transcript slice (the ONLY source of truth for extraction)

Slice spans dates: {date_first} → {date_last}

{turns}

## Output

Emit a single JSON object — no prose before or after, no markdown fences. Schema:

{{
  "narrative": "string | null  // 1-3 sentence factual recap. null if nothing notable.",
  "decisions": [
    {{
      "title":             "short title",
      "rationale":         "1-2 sentences with the WHY",
      "date":              "YYYY-MM-DD  // from slice, use {date_last} if unsure",
      "verbatim_evidence": "exact >=20-char substring from the slice that demonstrates the decision was made"
    }}
  ],
  "lessons": [
    {{
      "pattern":           "short rule",
      "context":           "1 sentence on when/why it applies",
      "verbatim_evidence": "exact >=20-char substring from a USER correction/confirmation"
    }}
  ],
  "tasks_patch": {{
    "add":           [ {{ "name": "...", "files": "...", "verify": "...", "verbatim_evidence": "..." }} ],
    "update_status": [ {{ "match": "substring of existing task in TASKS.md above", "to": "done|in-progress|blocked", "verbatim_evidence": "..." }} ],
    "comments":      [ {{ "match": "substring of existing task in TASKS.md above", "comment": "1 line", "verbatim_evidence": "..." }} ]
  }}
}}

What counts:
- **Decision**: explicit verbal choice — USER said "let's do X / go with X / not Y, X" OR assistant proposed X and the user agreed. Implementation patterns the assistant inferred do NOT count.
- **Lesson**: the user explicitly CORRECTED something OR explicitly CONFIRMED a non-obvious choice. Generic best practices do NOT count.
- **Task add**: the user explicitly opened a new task / asked for new work.
- **Task status change**: a task already in TASKS.md was reported done / blocked / etc. in the slice.

Empty arrays are GOOD. `null` narrative is GOOD. Pad nothing.
"""


def build_prompt(turns: list[dict], agent_dir: Path) -> tuple[str, str, str]:
    compact = [c for c in (compact_turn(t) for t in turns) if c]
    turns_blob = "\n\n".join(f"### {c['role']}\n{c['text']}" for c in compact)
    user_blob = "\n\n".join(c["text"] for c in compact if c["role"] == "user")
    if len(turns_blob) > 120_000:
        turns_blob = turns_blob[-120_000:]
    date_first, date_last = slice_date_range(turns)
    prompt = PROMPT_TEMPLATE.format(
        full_ctx=read_tail(agent_dir / "FULL_CONTEXT.md", 6000),
        decisions=read_tail(agent_dir / "DECISIONS.md", 4000),
        lessons=read_tail(agent_dir / "LESSONS.md", 3000),
        tasks=read_tail(agent_dir / "TASKS.md", 3000),
        turns=turns_blob,
        date_first=date_first,
        date_last=date_last,
    )
    return prompt, turns_blob, user_blob


_WS_RE = re.compile(r"\s+")
def _norm_ws(s: str) -> str:
    return _WS_RE.sub(" ", s).strip()


def validate_evidence(env: dict, slice_text: str, user_text: str,
                      min_chars: int = 20) -> tuple[dict, list[str]]:
    norm_slice = _norm_ws(slice_text)
    norm_user = _norm_ws(user_text)
    dropped: list[str] = []

    def keep(item: dict, label: str, require_user: bool = False) -> bool:
        ev = item.get("verbatim_evidence", "") or ""
        if not isinstance(ev, str) or len(ev.strip()) < min_chars:
            dropped.append(f"{label}: evidence missing/short ({len(ev)} chars)")
            return False
        nev = _norm_ws(ev)
        if nev not in norm_slice:
            dropped.append(f"{label}: evidence not in slice")
            return False
        if require_user and nev not in norm_user:
            dropped.append(f"{label}: evidence not from user-role turn")
            return False
        return True

    out = dict(env)
    if isinstance(out.get("decisions"), list):
        out["decisions"] = [d for i, d in enumerate(out["decisions"])
                            if keep(d, f"decision[{i}]")]
    if isinstance(out.get("lessons"), list):
        out["lessons"] = [l for i, l in enumerate(out["lessons"])
                          if keep(l, f"lesson[{i}]", require_user=True)]
    tp = out.get("tasks_patch") or {}
    for k in ("add", "update_status", "comments"):
        if isinstance(tp.get(k), list):
            tp[k] = [x for i, x in enumerate(tp[k])
                     if keep(x, f"tasks_patch.{k}[{i}]")]
    out["tasks_patch"] = tp
    return out, dropped


def parse_envelope(raw: str) -> dict[str, Any]:
    s = raw.strip()
    if s.startswith("```"):
        nl = s.find("\n")
        s = s[nl + 1:] if nl != -1 else s
        if s.endswith("```"):
            s = s[:-3]
    s = s.strip()
    start, end = s.find("{"), s.rfind("}")
    if start == -1 or end == -1:
        raise ValueError("no JSON object in output")
    return json.loads(s[start:end + 1])


# ---------- backend dispatch with fallback ---------------------------------

def call_backend(prompt: str, preferred: str, timeout: int, log) -> str:
    """Try preferred backend, then fall back. Raise if all fail.

    Pure-subscription path: if both gemini and codex CLIs are missing or
    error out, the caller logs the cycle as skipped — never crashes the
    daemon. The user keeps working unaffected.
    """
    order = []
    if preferred == "gemini":
        order = ["gemini", "codex"]
    elif preferred == "codex":
        order = ["codex", "gemini"]
    else:  # auto
        order = ["gemini", "codex"]

    last_err = None
    for backend in order:
        try:
            if backend == "gemini":
                return _call_gemini(prompt, timeout)
            elif backend == "codex":
                return _call_codex(prompt, timeout)
        except Exception as e:
            log(f"backend={backend} failed: {type(e).__name__}: {str(e)[:200]}")
            last_err = e
            continue
    raise RuntimeError(f"all backends failed; last={last_err}")


def _call_gemini(prompt: str, timeout: int) -> str:
    r = subprocess.run(["gemini", "-p", prompt],
                       capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"gemini exit={r.returncode}: {r.stderr[:400]}")
    return r.stdout


def _call_codex(prompt: str, timeout: int) -> str:
    # codex CLI: `codex exec` with prompt on stdin
    r = subprocess.run(["codex", "exec", "--quiet"],
                       input=prompt, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"codex exit={r.returncode}: {r.stderr[:400]}")
    return r.stdout


# ---------- file-application primitives ------------------------------------

class FileLock:
    """flock-based exclusive lock. Multi-session safety on shared .agent/ files."""

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = None

    def __enter__(self):
        self._fh = open(self.path, "a+")
        fcntl.flock(self._fh.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc, tb):
        if self._fh:
            fcntl.flock(self._fh.fileno(), fcntl.LOCK_UN)
            self._fh.close()


def append_with_lock(target: Path, text: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    lock_path = target.with_suffix(target.suffix + ".lock")
    with FileLock(lock_path):
        with target.open("a") as f:
            f.write(text)


def apply_narrative(agent_dir: Path, narrative: str, slice_date: str) -> bool:
    if not narrative:
        return False
    block = f"\n## {slice_date} (auto-flushed by context-watcher)\n\n{narrative}\n"
    append_with_lock(agent_dir / "FULL_CONTEXT.md", block)
    return True


def apply_lessons(agent_dir: Path, lessons: list[dict]) -> int:
    if not lessons:
        return 0
    target = agent_dir / "LESSONS.md"
    chunks = []
    for l in lessons:
        chunks.append(f"- **{l.get('pattern','?')}** — {l.get('context','?')}\n")
    append_with_lock(target, "\n" + "".join(chunks))
    return len(lessons)


def apply_tasks_patch(agent_dir: Path, tp: dict) -> dict:
    """Append new tasks; for updates, append a separate 'flush note' rather
    than try to rewrite existing rows (table editing in markdown is fragile;
    a flush note preserves intent without risk of mangling the table)."""
    counts = {"add": 0, "update_status": 0, "comments": 0}
    target = agent_dir / "TASKS.md"
    blocks: list[str] = []
    for t in tp.get("add", []):
        blocks.append(
            f"| R-auto | {t.get('name','?')} | {t.get('files','?')} | "
            f"{t.get('verify','?')} | — | pending |\n"
        )
        counts["add"] += 1
    notes: list[str] = []
    for u in tp.get("update_status", []):
        notes.append(f"- watcher: '{u.get('match','?')[:60]}' → {u.get('to','?')}")
        counts["update_status"] += 1
    for c in tp.get("comments", []):
        notes.append(f"- watcher: '{c.get('match','?')[:60]}' — {c.get('comment','?')}")
        counts["comments"] += 1
    if blocks or notes:
        out = []
        if blocks:
            out.append("\n" + "".join(blocks))
        if notes:
            out.append("\n<!-- watcher notes -->\n" + "\n".join(notes) + "\n")
        append_with_lock(target, "".join(out))
    return counts


def stage_decisions(agent_dir: Path, sid: str, decisions: list[dict]) -> int:
    if not decisions:
        return 0
    target = agent_dir / "LOGS" / f"pending-decisions.{sid}.jsonl"
    target.parent.mkdir(parents=True, exist_ok=True)
    lock_path = target.with_suffix(target.suffix + ".lock")
    now = datetime.now(timezone.utc).isoformat()
    with FileLock(lock_path):
        with target.open("a") as f:
            for d in decisions:
                row = {**d, "status": "pending", "staged_at": now, "session_id": sid}
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return len(decisions)


# ---------- cursor + daemon loop -------------------------------------------

def cursor_path(agent_dir: Path, sid: str) -> Path:
    return agent_dir / "LOGS" / f".flush-cursor.{sid}"


def read_cursor(agent_dir: Path, sid: str) -> int:
    p = cursor_path(agent_dir, sid)
    if not p.exists():
        return 0
    try:
        return int(p.read_text().strip() or "0")
    except (ValueError, OSError):
        return 0


def write_cursor(agent_dir: Path, sid: str, value: int) -> None:
    p = cursor_path(agent_dir, sid)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(str(value))
    tmp.replace(p)  # atomic rename


_stop = False
def _handle_signal(signum, frame):
    global _stop
    _stop = True


def run_cycle(args, log) -> dict:
    """One flush cycle. Returns a small stats dict for logging."""
    cursor = read_cursor(args.agent_dir, args.session_id)
    turns, new_cursor = load_transcript_slice(
        args.transcript, cursor, args.max_turns
    )
    stats = {"cursor": cursor, "new_cursor": new_cursor, "n_turns": len(turns)}
    if len(turns) < args.min_new_turns:
        stats["skipped"] = f"only {len(turns)} new turns (<{args.min_new_turns})"
        return stats

    prompt, slice_text, user_text = build_prompt(turns, args.agent_dir)
    stats["prompt_chars"] = len(prompt)

    raw = call_backend(prompt, args.backend, args.timeout, log)
    stats["raw_chars"] = len(raw)

    try:
        env = parse_envelope(raw)
    except (ValueError, json.JSONDecodeError) as e:
        stats["parse_error"] = str(e)[:200]
        return stats

    filtered, dropped = validate_evidence(env, slice_text, user_text)
    stats["dropped"] = len(dropped)
    if dropped:
        for d in dropped:
            log(f"  drop: {d}")

    slice_date = slice_date_range(turns)[1]
    nar_applied = apply_narrative(args.agent_dir,
                                  filtered.get("narrative") or "",
                                  slice_date)
    n_lessons = apply_lessons(args.agent_dir, filtered.get("lessons") or [])
    tp_counts = apply_tasks_patch(args.agent_dir,
                                  filtered.get("tasks_patch") or {})
    n_staged = stage_decisions(args.agent_dir, args.session_id,
                               filtered.get("decisions") or [])

    stats.update({
        "narrative_applied": nar_applied,
        "lessons_applied": n_lessons,
        "tasks": tp_counts,
        "decisions_staged": n_staged,
    })

    # Only advance cursor after successful application — if we crashed before
    # this, the next cycle re-processes the same slice (idempotency-friendly
    # vs catastrophic skip).
    write_cursor(args.agent_dir, args.session_id, new_cursor)
    return stats


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--session-id", required=True)
    p.add_argument("--project-dir", type=Path, required=True)
    p.add_argument("--transcript", type=Path, required=True)
    p.add_argument("--agent-dir", type=Path, default=None,
                   help="Defaults to <project-dir>/.agent")
    p.add_argument("--interval", type=int, default=300,
                   help="Seconds between cycles (default 300 = 5min)")
    p.add_argument("--min-new-turns", type=int, default=10)
    p.add_argument("--max-turns", type=int, default=200)
    p.add_argument("--timeout", type=int, default=240,
                   help="Per-backend call timeout (seconds)")
    p.add_argument("--backend", choices=["gemini", "codex", "auto"],
                   default="auto")
    p.add_argument("--once", action="store_true",
                   help="Run one cycle then exit (testing)")
    args = p.parse_args()

    args.agent_dir = args.agent_dir or args.project_dir / ".agent"
    log_path = args.agent_dir / "LOGS" / f"watcher.{args.session_id[:12]}.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)

    def log(msg: str) -> None:
        ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
        line = f"{ts}  {msg}\n"
        try:
            with log_path.open("a") as f:
                f.write(line)
        except OSError:
            pass
        sys.stderr.write(line)

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    # SIGHUP fires when the parent tmux session is killed via 'tmux kill-session'
    # (the canonical shutdown path from on-session-end.sh). Handling it the same
    # as SIGTERM lets the watcher do its final flush before exit instead of
    # dying mid-cycle.
    signal.signal(signal.SIGHUP, _handle_signal)

    log(f"watcher start  sid={args.session_id[:12]}  transcript={args.transcript.name}  "
        f"interval={args.interval}s  min-turns={args.min_new_turns}  backend={args.backend}")

    while not _stop:
        try:
            stats = run_cycle(args, log)
            log(f"cycle  {json.dumps(stats)}")
        except Exception as e:
            log(f"cycle FAILED: {type(e).__name__}: {str(e)[:300]}")

        if args.once:
            break

        # Sleep in small ticks so SIGTERM is responsive
        slept = 0
        while slept < args.interval and not _stop:
            time.sleep(min(2, args.interval - slept))
            slept += 2

    # final pass before exit (best-effort)
    if not args.once:
        try:
            stats = run_cycle(args, log)
            log(f"final cycle on shutdown: {json.dumps(stats)}")
        except Exception as e:
            log(f"final cycle FAILED: {type(e).__name__}: {str(e)[:300]}")

    log("watcher exit clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
