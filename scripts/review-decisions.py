#!/usr/bin/env python3
"""
Megavibe — review staged decisions from the context-watcher.

The watcher stages decisions (the high-stakes category — durable, propagates
everywhere) instead of auto-applying them. This walks the staging file(s),
shows each candidate + its verbatim evidence, and either appends accepted
ones to .agent/DECISIONS.md or marks them rejected.

Usage:
  scripts/review-decisions.py                              # walk all sessions, current project
  scripts/review-decisions.py --session SID                # one session only
  scripts/review-decisions.py --project-dir /path/to/proj  # off the current cwd
  scripts/review-decisions.py --list                       # non-interactive, just show counts
  scripts/review-decisions.py --yes-all                    # accept everything (use sparingly)
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def find_pending_files(agent_dir: Path, session: str | None) -> list[Path]:
    logs = agent_dir / "LOGS"
    if not logs.exists():
        return []
    pattern = f"pending-decisions.{session}.jsonl" if session else "pending-decisions.*.jsonl"
    return sorted(logs.glob(pattern))


def load_rows(p: Path) -> list[dict]:
    rows: list[dict] = []
    if not p.exists():
        return rows
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


def write_rows(p: Path, rows: list[dict]) -> None:
    """Atomic full-file rewrite (cheap — these files stay small)."""
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    tmp.replace(p)


def next_decision_number(decisions_path: Path) -> int:
    """Find the highest existing decision row number in DECISIONS.md so we
    continue the sequence rather than colliding."""
    if not decisions_path.exists():
        return 1
    highest = 0
    for line in decisions_path.read_text().splitlines():
        # rows look like:  | 92 | ... | YYYY-MM-DD |
        if not line.startswith("|"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) >= 2 and parts[1].isdigit():
            highest = max(highest, int(parts[1]))
    return highest + 1


def render_decision_row(num: int, row: dict) -> str:
    title = row.get("title", "?")
    rationale = row.get("rationale", "?").replace("\n", " ")
    evidence = (row.get("verbatim_evidence", "") or "").replace("\n", " ")
    date = row.get("date", "?")
    # Match the existing DECISIONS.md table format
    return f"| {num} | {title} | {rationale} Evidence: \"{evidence}\" | {date} |\n"


def prompt_user(row: dict, idx: int, total: int) -> str:
    print(f"\n────────  decision {idx}/{total}  ────────")
    print(f"  title:     {row.get('title','?')}")
    print(f"  date:      {row.get('date','?')}")
    print(f"  rationale: {row.get('rationale','?')}")
    print(f"  evidence:  \"{(row.get('verbatim_evidence','') or '')[:300]}\"")
    print(f"  staged:    {row.get('staged_at','?')}  session={row.get('session_id','?')}")
    while True:
        choice = input("  [a]ccept / [r]eject / [s]kip / [q]uit > ").strip().lower()
        if choice in ("a", "r", "s", "q"):
            return choice
        print("  (enter a, r, s, or q)")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--project-dir", type=Path, default=Path.cwd())
    p.add_argument("--session", help="Limit to a specific session ID")
    p.add_argument("--list", action="store_true",
                   help="Just count pending decisions per session, don't review")
    p.add_argument("--yes-all", action="store_true",
                   help="Accept everything without prompting (skip the gate — use with caution)")
    args = p.parse_args()

    agent_dir = args.project_dir / ".agent"
    decisions_md = agent_dir / "DECISIONS.md"

    files = find_pending_files(agent_dir, args.session)
    if not files:
        print(f"No pending decisions in {agent_dir / 'LOGS'} "
              + (f"for session {args.session}" if args.session else ""))
        return 0

    if args.list:
        for f in files:
            pending = [r for r in load_rows(f) if r.get("status") == "pending"]
            print(f"  {f.name}: {len(pending)} pending")
        return 0

    next_num = next_decision_number(decisions_md)
    accepted_blocks: list[str] = []
    counts = {"accepted": 0, "rejected": 0, "skipped": 0}

    for f in files:
        rows = load_rows(f)
        pending_idx = [i for i, r in enumerate(rows) if r.get("status") == "pending"]
        if not pending_idx:
            continue

        for n, i in enumerate(pending_idx, 1):
            row = rows[i]
            if args.yes_all:
                choice = "a"
            else:
                choice = prompt_user(row, n, len(pending_idx))

            if choice == "q":
                # Persist whatever we decided so far in this file before exiting
                write_rows(f, rows)
                if accepted_blocks:
                    _flush_accepted(decisions_md, accepted_blocks)
                _summary(counts)
                return 0
            elif choice == "a":
                accepted_blocks.append(render_decision_row(next_num, row))
                rows[i]["status"] = "accepted"
                rows[i]["reviewed_at"] = datetime.now(timezone.utc).isoformat()
                next_num += 1
                counts["accepted"] += 1
            elif choice == "r":
                rows[i]["status"] = "rejected"
                rows[i]["reviewed_at"] = datetime.now(timezone.utc).isoformat()
                counts["rejected"] += 1
            else:  # s = skip — leave as pending
                counts["skipped"] += 1

        write_rows(f, rows)

    if accepted_blocks:
        _flush_accepted(decisions_md, accepted_blocks)
    _summary(counts)
    return 0


def _flush_accepted(decisions_md: Path, blocks: list[str]) -> None:
    decisions_md.parent.mkdir(parents=True, exist_ok=True)
    with decisions_md.open("a") as f:
        f.write("\n" + "".join(blocks))
    print(f"\n  appended {len(blocks)} row(s) → {decisions_md}")


def _summary(counts: dict) -> None:
    print(f"\n  accepted={counts['accepted']}  rejected={counts['rejected']}  skipped={counts['skipped']}")


if __name__ == "__main__":
    raise SystemExit(main())
