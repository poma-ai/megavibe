#!/usr/bin/env python3
"""
Megavibe context-watcher SPIKE (v3) — dry-run extraction of structured updates
from a Claude Code transcript JSONL into the .agent/ file format.

STATUS: prototype. Reads only, writes nothing to .agent/. Not wired into hooks.
Run by hand against a saved transcript to inspect what the production watcher
would propose. Supersede with a real daemon (tmux session, cursor persistence,
fallback chain, atomic appends) before deleting.

What's proven in the spike runs:
  - Gemini emits a parseable JSON envelope at ~30s round trip on a ~45K prompt.
  - Forcing `verbatim_evidence` >=20 chars per item and substring-validating it
    against the transcript slice drops the worst hallucinations mechanically.
  - Requiring lessons' evidence to appear in a USER-role turn filters out
    assistant self-reflection masquerading as user-confirmed pattern.
  - Decisions are staged (would queue to `pending-decisions.<sid>.jsonl`) rather
    than auto-applied — proposal-vs-locked-decision ambiguity bites here, and
    the human gate is cheap. Narrative / lessons / tasks_patch auto-apply.
  - Two transcript runs show the conservative bias works in both directions:
    a decision-heavy slice extracts real items, an exploration slice extracts
    almost nothing — no shoehorning into a recurring theme.

What's NOT in the spike (and is needed for production):
  - Long-running daemon (`tail -F` the transcript), cursor in
    `.agent/LOGS/.flush-cursor.$SID`, incremental delta only.
  - `flock`-guarded appends so concurrent sessions don't race on shared files.
  - Standard fallback chain (Gemini MCP → $GEMINI_API_KEY curl → Codex MCP →
    Claude subagent).
  - A review surface for staged decisions (`megavibe review` or a /skill).

Usage:
  scripts/watcher-spike.py <transcript.jsonl> [--cursor N] [--max-turns 80]
                          [--backend gemini|stub] [--timeout 240]
                          [--agent-dir .agent]
                          [--save-prompt FILE] [--save-raw FILE]

Example:
  scripts/watcher-spike.py \
    ~/.claude/projects/-Users-alexkihm-Documents--1-WORK-poma-megavibe/aa252f49-eb5c-4d1f-b350-1c3affa18301.jsonl \
    --max-turns 80
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import date
from pathlib import Path
from typing import Any


def load_transcript_slice(path: Path, cursor: int, max_turns: int) -> tuple[list[dict], int]:
    """Read JSONL from `cursor` onward, return up to max_turns assistant/user/tool turns + new cursor."""
    turns: list[dict] = []
    new_cursor = cursor
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
    """Return (first_iso_date, last_iso_date) from turn timestamps. Falls back to today."""
    stamps: list[str] = []
    for t in turns:
        ts = t.get("timestamp") or (t.get("message") or {}).get("timestamp")
        if isinstance(ts, str) and len(ts) >= 10:
            stamps.append(ts[:10])
    if not stamps:
        today = date.today().isoformat()
        return today, today
    return stamps[0], stamps[-1]


def compact_turn(t: dict) -> dict | None:
    """Strip a transcript JSONL line down to what an extractor needs.

    Drops large internal fields (uuid chains, raw API metadata), keeps role +
    text + tool calls/results. Returns None for noise that shouldn't go to the
    extractor (sidechain summaries, etc.).
    """
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

Items without valid evidence are dropped by an automated post-check. Inventing evidence is worse than extracting nothing — it pollutes the durable log forever and a human reviewer will see the failed validation.

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
  "narrative": "string | null  // 1-3 sentence factual recap of what happened. null if nothing notable.",
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
- **Decision**: explicit verbal choice — the USER said "let's do X / go with X / not Y, X" OR the assistant proposed X and the user agreed. Implementation patterns the assistant inferred do NOT count.
- **Lesson**: the user explicitly CORRECTED something ("no, don't do X", "actually X is wrong"), OR explicitly CONFIRMED a non-obvious choice ("yes that's the right call"). Generic best practices the assistant thought of do NOT count.
- **Task add**: the user explicitly opened a new task / asked for new work.
- **Task status change**: a task already in TASKS.md was reported done / blocked / etc. in the slice.

Empty arrays are GOOD. `null` narrative is GOOD. Pad nothing.
"""


def build_prompt(turns: list[dict], agent_dir: Path) -> tuple[str, str, str]:
    """Return (prompt, slice_text_all, slice_text_user_only).

    slice_text_all = every role's text — used for general substring validation.
    slice_text_user_only = concatenation of just user-role turns — used to
    enforce that lessons come from a user correction/confirmation, not from
    assistant self-reflection (the most stubborn hallucination class in v2)."""
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


_WS_RE = None
def _norm_ws(s: str) -> str:
    """Collapse all runs of whitespace to single spaces — for substring matching
    that survives line-wrapping differences between transcript and model output."""
    global _WS_RE
    import re
    if _WS_RE is None:
        _WS_RE = re.compile(r"\s+")
    return _WS_RE.sub(" ", s).strip()


def validate_evidence(
    env: dict, slice_text: str, user_text: str, min_evidence_chars: int = 20
) -> tuple[dict, list[str]]:
    """Drop any extracted item whose `verbatim_evidence` isn't in the slice.

    Lessons must additionally appear in the USER-role portion — a lesson is a
    learned pattern from a user correction or explicit confirmation, not from
    assistant self-reflection. Without this guard, the assistant's own
    after-the-fact reasoning shows up as 'lessons' that the user never validated.

    Returns (filtered_env, dropped_reasons)."""
    norm_slice = _norm_ws(slice_text)
    norm_user = _norm_ws(user_text)
    dropped: list[str] = []

    def keep(item: dict, label: str, require_user: bool = False) -> bool:
        ev = item.get("verbatim_evidence", "") or ""
        if not isinstance(ev, str) or len(ev.strip()) < min_evidence_chars:
            dropped.append(f"{label}: evidence missing or too short ({len(ev)} chars)")
            return False
        nev = _norm_ws(ev)
        if nev not in norm_slice:
            preview = ev[:60].replace("\n", " ")
            dropped.append(f"{label}: evidence not found in slice — '{preview}…'")
            return False
        if require_user and nev not in norm_user:
            preview = ev[:60].replace("\n", " ")
            dropped.append(f"{label}: evidence not from user-role turn — '{preview}…'")
            return False
        return True

    out = dict(env)
    if isinstance(out.get("decisions"), list):
        out["decisions"] = [d for i, d in enumerate(out["decisions"])
                            if keep(d, f"decision[{i}] '{d.get('title','?')[:40]}'")]
    if isinstance(out.get("lessons"), list):
        out["lessons"] = [l for i, l in enumerate(out["lessons"])
                          if keep(l, f"lesson[{i}] '{l.get('pattern','?')[:40]}'",
                                  require_user=True)]
    tp = out.get("tasks_patch") or {}
    for k in ("add", "update_status", "comments"):
        if isinstance(tp.get(k), list):
            tp[k] = [x for i, x in enumerate(tp[k])
                     if keep(x, f"tasks_patch.{k}[{i}]")]
    out["tasks_patch"] = tp
    return out, dropped


def call_gemini(prompt: str, timeout: int = 120) -> str:
    """Invoke gemini CLI headlessly. Returns raw stdout."""
    try:
        result = subprocess.run(
            ["gemini", "-p", prompt],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        raise RuntimeError("gemini CLI not on PATH")
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"gemini timed out after {timeout}s")
    if result.returncode != 0:
        raise RuntimeError(f"gemini exit={result.returncode}: {result.stderr[:500]}")
    return result.stdout


def parse_envelope(raw: str) -> dict[str, Any]:
    """Strip markdown fences if present, parse JSON."""
    s = raw.strip()
    if s.startswith("```"):
        first_nl = s.find("\n")
        s = s[first_nl + 1 :] if first_nl != -1 else s
        if s.endswith("```"):
            s = s[:-3]
    s = s.strip()
    start = s.find("{")
    end = s.rfind("}")
    if start == -1 or end == -1:
        raise ValueError("no JSON object found in output")
    return json.loads(s[start : end + 1])


def validate_envelope(env: dict) -> list[str]:
    """Return list of validation warnings (empty = clean)."""
    warns: list[str] = []
    if not isinstance(env.get("decisions", []), list):
        warns.append("decisions: not a list")
    if not isinstance(env.get("lessons", []), list):
        warns.append("lessons: not a list")
    tp = env.get("tasks_patch", {})
    if not isinstance(tp, dict):
        warns.append("tasks_patch: not a dict")
    for k in ("add", "update_status", "comments"):
        if k in tp and not isinstance(tp[k], list):
            warns.append(f"tasks_patch.{k}: not a list")
    return warns


def render_dry_run(env: dict, slice_date: str | None = None) -> str:
    """Pretty-print what would be applied vs staged.

    Auto-apply (low-stakes, easy to reverse):
      - narrative → FULL_CONTEXT.md
      - lessons → LESSONS.md (already gated on user-role evidence)
      - tasks_patch → TASKS.md

    Staged for user review (high-stakes, durable rationale that propagates):
      - decisions → .agent/LOGS/pending-decisions.{sid}.jsonl

    The asymmetry is deliberate: lessons and tasks_patch are trivially
    reversible; an unwanted decision in DECISIONS.md is a long-lived
    pollutant. Forcing a human gate on decisions is the cheap defense.
    """
    stamp = slice_date or date.today().isoformat()
    lines: list[str] = []

    lines.append("─── AUTO-APPLY (low-stakes, easy to revert) ───\n")
    nar = env.get("narrative")
    if nar:
        lines.append(f"== WOULD APPEND TO FULL_CONTEXT.md ==\n{stamp} — {nar}\n")
    less = env.get("lessons") or []
    if less:
        lines.append("== WOULD APPEND TO LESSONS.md ==")
        for l in less:
            lines.append(f"  • {l.get('pattern','?')}")
            lines.append(f"    when:    {l.get('context','?')}")
        lines.append("")
    tp = env.get("tasks_patch", {})
    if any(tp.get(k) for k in ("add", "update_status", "comments")):
        lines.append("== WOULD PATCH TASKS.md ==")
        for t in tp.get("add", []):
            lines.append(f"  + ADD:    {t.get('name','?')}  files={t.get('files','?')}")
        for t in tp.get("update_status", []):
            lines.append(f"  ~ STATUS: '{t.get('match','?')}' → {t.get('to','?')}")
        for t in tp.get("comments", []):
            lines.append(f"  # NOTE:   '{t.get('match','?')}': {t.get('comment','?')}")
        lines.append("")
    if not (nar or less or any(tp.get(k) for k in ("add", "update_status", "comments"))):
        lines.append("(nothing to auto-apply)\n")

    decs = env.get("decisions") or []
    lines.append("─── STAGED FOR REVIEW (decisions — pending user confirm) ───\n")
    if decs:
        lines.append(f"== WOULD QUEUE TO .agent/LOGS/pending-decisions.<sid>.jsonl ==")
        for d in decs:
            lines.append(f"  ? {d.get('title','?')}  ({d.get('date','?')})")
            lines.append(f"    rationale: {d.get('rationale','?')}")
            lines.append(f"    evidence:  '{d.get('verbatim_evidence','')[:120]}…'")
    else:
        lines.append("(no decisions to stage)")

    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("transcript", type=Path, help="Path to a Claude Code session JSONL")
    p.add_argument("--cursor", type=int, default=0, help="Start line (default 0)")
    p.add_argument("--max-turns", type=int, default=80, help="Cap on turns this run")
    p.add_argument("--agent-dir", type=Path, default=Path(".agent"))
    p.add_argument("--backend", choices=["gemini", "stub"], default="gemini")
    p.add_argument("--timeout", type=int, default=240, help="Gemini call timeout (seconds)")
    p.add_argument("--save-prompt", type=Path, help="Write the assembled prompt here (for inspection)")
    p.add_argument("--save-raw", type=Path, help="Write raw model output here")
    args = p.parse_args()

    if not args.transcript.exists():
        print(f"transcript not found: {args.transcript}", file=sys.stderr)
        return 2

    turns, new_cursor = load_transcript_slice(args.transcript, args.cursor, args.max_turns)
    date_first, date_last = slice_date_range(turns)
    print(f"[spike] loaded {len(turns)} turns from line {args.cursor} → {new_cursor}  (dates {date_first} → {date_last})", file=sys.stderr)

    prompt, slice_text, user_text = build_prompt(turns, args.agent_dir)
    print(f"[spike] prompt size: {len(prompt):,} chars  (slice {len(slice_text):,} / user-only {len(user_text):,} chars)", file=sys.stderr)

    if args.save_prompt:
        args.save_prompt.write_text(prompt)
        print(f"[spike] wrote prompt → {args.save_prompt}", file=sys.stderr)

    if args.backend == "stub":
        print("[spike] backend=stub — skipping model call. Use --backend gemini for real run.", file=sys.stderr)
        return 0

    print(f"[spike] calling gemini (timeout {args.timeout}s)...", file=sys.stderr)
    raw = call_gemini(prompt, timeout=args.timeout)

    if args.save_raw:
        args.save_raw.write_text(raw)
        print(f"[spike] wrote raw → {args.save_raw}", file=sys.stderr)

    try:
        env = parse_envelope(raw)
    except (ValueError, json.JSONDecodeError) as e:
        print(f"[spike] FAILED to parse envelope: {e}", file=sys.stderr)
        print("--- raw output ---", file=sys.stderr)
        print(raw[:2000], file=sys.stderr)
        return 3

    warns = validate_envelope(env)
    for w in warns:
        print(f"[spike] WARN  {w}", file=sys.stderr)

    # Substring-validate every extracted item's verbatim_evidence against the slice.
    # Items with missing / fabricated quotes get dropped here — the strongest
    # defense against the hallucination class observed in spike v1.
    # Lessons additionally require their evidence to live in a user-role turn
    # (v3): a lesson must come from a user correction/confirmation, not from
    # assistant self-reflection.
    filtered, dropped = validate_evidence(env, slice_text, user_text)
    if dropped:
        print(file=sys.stderr)
        print(f"[spike] EVIDENCE-CHECK dropped {len(dropped)} item(s):", file=sys.stderr)
        for d in dropped:
            print(f"  - {d}", file=sys.stderr)

    print()
    print(render_dry_run(filtered, slice_date=date_last))
    print()
    print(f"[spike] next cursor would be: {new_cursor}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
