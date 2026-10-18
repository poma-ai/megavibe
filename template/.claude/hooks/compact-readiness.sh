#!/bin/bash
# Exit 0: ready; 1: blockers; 2: invalid input or cannot check.
# Requires python3. Event order is filename order, never filesystem time.
# --mark [--force] [--staged-handled] is the only checkpoint writer.
# --decisions-since FILE reads a checkpoint filename from FILE, not its mtime.
exec python3 - "$@" <<'PY'
import argparse
import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

EVENT = re.compile(r"[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9._-]+\.md")
MARKER = r"^(DECISION:|D[0-9]+( |:)|Decided:)"
ADVISORY = re.compile(
    r"\b(decisions?|decided|chosen|chose|selected|agreed|verdict)\b"
    r"|\bD[0-9]+\b|\bdefault [A-D]\b", re.I)
CP = Path(".agent/.registers-checkpoint")


def fail(message):
    raise ValueError(message)


def number(name, default, low=1, high=1000000):
    value = os.environ.get(name, str(default))
    if not re.fullmatch(r"[0-9]+", value):
        fail(name + ": expected a decimal integer")
    value = int(value, 10)
    if not low <= value <= high:
        fail(name + ": out of range")
    return value


def checkpoint(path):
    if not path.exists() and path == CP:
        return ""
    value = path.read_text().rstrip("\n")
    if value and not EVENT.fullmatch(value):
        fail("invalid checkpoint: " + str(path))
    return value


def events():
    root = Path(".agent/events")
    return sorted(p.name for p in root.iterdir()
                  if p.is_file() and EVENT.fullmatch(p.name)) if root.exists() else []


def marked(names):
    if not names:
        return 0
    # One process for all candidate files; no content scan on the empty path.
    result = subprocess.run(
        ["grep", "-lE", MARKER] + [".agent/events/" + n for n in names],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env=dict(os.environ, LC_ALL="C"))
    if result.returncode not in (0, 1):
        fail("cannot scan event bodies")
    return len(result.stdout.splitlines())


def session(requested):
    logs = Path(".agent/LOGS")
    # Counter mtimes select active identities only; never register coverage.
    counters = [p for p in logs.glob(".tool-call-counter.*")
                if p.is_file() and not p.name.endswith(".lock")
                and time.time() - p.stat().st_mtime <= 86400]
    how = "--session" if requested else "CLAUDE_CODE_SESSION_ID"
    sid = requested or os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not sid:
        if len(counters) > 1:
            fail("ambiguous session: pass --session")
        sid = counters[0].name[len(".tool-call-counter."):] if counters else ""
        how = "recent tool-call counter"
    if not sid:
        return "", "unknown"
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", sid) or sid in (".", ".."):
        fail("invalid session id")
    known = {p.name for p in Path(".agent/sessions").glob("*") if p.is_dir()}
    for pattern, prefix, suffix in (
        (".bg-tasks.*.jsonl", ".bg-tasks.", ".jsonl"),
        ("pending-decisions.*.jsonl", "pending-decisions.", ".jsonl"),
        (".tool-call-counter.*", ".tool-call-counter.", ""),
    ):
        for p in logs.glob(pattern):
            if p.is_file() and not p.name.endswith(".lock"):
                known.add(p.name[len(prefix):-len(suffix)] if suffix
                          else p.name[len(prefix):])
    if len(sid) <= 12:
        matches = {s for s in known if s.startswith(sid)}
        # A short flag key and its single full id represent one session.
        leaves = {s for s in matches
                  if not any(t != s and t.startswith(s) for t in matches)}
        if len(leaves) > 1:
            fail("ambiguous session: pass --session")
        if leaves:
            sid = leaves.pop()
    return sid, how


def queue_rows(path, sid, cut):
    rows = []
    for line in path.read_text().splitlines():
        row = json.loads(line)
        if not isinstance(row, dict):
            fail("invalid pending row: " + str(path))
        rows.append(row)
    mine = {sid, sid[:12]}
    handled = set()
    for row in rows:
        if row.get("status") == "handled-by-session" and row.get("session_id") in mine:
            indexes = row.get("handled_rows", [])
            if not isinstance(indexes, list) or any(type(i) is not int for i in indexes):
                fail("invalid handling marker: " + str(path))
            handled.update(indexes)
    cutoff = dt.datetime.strptime(cut[:16], "%Y%m%dT%H%M%SZ").replace(
        tzinfo=dt.timezone.utc) if cut else None
    pending = []
    for index, row in enumerate(rows, 1):
        if (row.get("status") != "pending" or index in handled
                or row.get("session_id", sid[:12]) not in mine):
            continue
        # Legacy queues have no event key. Use their explicit UTC staged_at.
        # Missing timestamps cannot establish coverage: keep those rows pending
        # until an append-only handling marker acknowledges them.
        stamp = row.get("staged_at")
        try:
            when = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            if when.tzinfo is None:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            when = None
        if cutoff is None or when is None or when > cutoff:
            pending.append(index)
    return pending


def main():
    parser = argparse.ArgumentParser(description="Check explicit register coverage.")
    parser.add_argument("--project", default=".")
    parser.add_argument("--session")
    parser.add_argument("--decisions-since", metavar="CHECKPOINT")
    parser.add_argument("--mark", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--staged-handled", action="store_true")
    args = parser.parse_args()
    for value in (args.project, args.session, args.decisions_since):
        if value == "":
            parser.error("option values must not be empty")
    if (args.force or args.staged_handled) and not args.mark:
        parser.error("--force and --staged-handled require --mark")
    if args.decisions_since and args.mark:
        parser.error("--decisions-since cannot be combined with --mark")
    minimum = number("MEGAVIBE_READY_TASKS_MIN_EVENTS", 3)
    interval = max(60, min(600, number("MEGAVIBE_BG_CHECK_SECS", 300)))
    # Retired settings must not silently change or disable a check.
    if "MEGAVIBE_READY_TASKS_LAG_MIN" in os.environ:
        fail("MEGAVIBE_READY_TASKS_LAG_MIN is retired; use MEGAVIBE_READY_TASKS_MIN_EVENTS")
    if "MEGAVIBE_READY_DECISION_RE" in os.environ:
        fail("MEGAVIBE_READY_DECISION_RE is retired; use structured markers")
    os.chdir(args.project)
    if not Path(".agent").is_dir():
        fail("no .agent/ in project")
    if args.decisions_since:
        cut = checkpoint(Path(args.decisions_since))
        count = marked([n for n in events() if n > cut])
        print(count)
        return int(count > 0)

    sid, how = session(args.session)
    if args.staged_handled and not sid:
        fail("--staged-handled requires --session")
    queue_paths = []
    for path in Path(".agent/LOGS").glob("pending-decisions.*.jsonl"):
        key = path.name[len("pending-decisions."):-len(".jsonl")]
        if key in (sid, sid[:12]) and sid:
            # A truncated queue cannot be attributed across colliding full ids.
            peers = [p.name for p in Path(".agent/sessions").glob(sid[:12] + "*")
                     if p.is_dir() and len(p.name) > 12]
            peers += [p.name[len(".bg-tasks."):-len(".jsonl")]
                      for p in Path(".agent/LOGS").glob(".bg-tasks." + sid[:12] + "*.jsonl")]
            peers += [p.name[len(".tool-call-counter."):]
                      for p in Path(".agent/LOGS").glob(".tool-call-counter." + sid[:12] + "*")
                      if not p.name.endswith(".lock") and len(p.name[len(".tool-call-counter."):]) > 12]
            if key != sid and any(p != sid for p in peers):
                fail("ambiguous session queue: pass an unambiguous --session")
            queue_paths.append(path)
        elif not sid:
            fail("session unknown with staged rows: pass --session")

    with contextlib.ExitStack() as stack:
        if args.mark:
            # Same queue locks as the watcher; retain them through the append.
            for path in [Path(str(CP) + ".lock")] + sorted(
                    Path(str(p) + ".lock") for p in queue_paths):
                lock = stack.enter_context(path.open("a"))
                fcntl.flock(lock, fcntl.LOCK_EX)
        cut = checkpoint(CP)
        names = events()
        newer = [n for n in names if n > cut]
        count = marked(newer)
        blocks, info = [], []
        info.append("%d events after checkpoint; %d marked-decision events"
                    % (len(newer), count))
        if not Path(".agent/DECISIONS.md").is_file():
            blocks.append("DECISIONS.md is missing")
        elif count:
            blocks.append("DECISIONS.md: reconcile marked decisions, including their reasons")
        if not Path(".agent/TASKS.md").is_file():
            blocks.append("TASKS.md is missing")
        elif count or len(newer) >= minimum:
            blocks.append("TASKS.md: reconcile item status and blockers")
        pending = {p: queue_rows(p, sid, "" if args.staged_handled else cut)
                   for p in queue_paths}
        total = sum(len(rows) for rows in pending.values())
        if total and not args.staged_handled:
            blocks.append("%d pending decisions for this session; review them, then use "
                          "--mark --staged-handled (add --force after reconciling register blockers)"
                          % total)
        else:
            info.append("%d pending decisions for this session%s" %
                        (total, "; will append handling markers" if total else ""))

        bg = Path(".agent/LOGS/.bg-tasks." + sid + ".jsonl")
        if sid and bg.exists():
            rows = [json.loads(line) for line in bg.read_text().splitlines()]
            info.append("%d background tasks recorded; coverage known only at turn end" % len(rows))
            for row in rows:
                nudged = int(str(row.get("nudged", 0)), 10)
                if nudged > 0 and 0 <= time.time() - nudged <= interval * 2:
                    blocks.append("background %s task %s found without a heartbeat; "
                                  "arm a Monitor or stop it" %
                                  (row.get("kind", "?"), row.get("id", "?")))
                elif nudged > 0:
                    info.append("background task %s: earlier heartbeat nudge" % row.get("id", "?"))
        else:
            info.append("no background tasks recorded for this session" if sid
                        else "background tasks: session unknown, not checked")
        wc = Path(".agent/sessions") / sid / "WORKING_CONTEXT.md"
        if sid and wc.is_file() and wc.stat().st_size:
            age = max(0, int(time.time() - wc.stat().st_mtime))
            info.append("WORKING_CONTEXT %s: %dm old; /rehydrate %s" %
                        (wc, age // 60, "required" if age > 3600 else "optional"))
        else:
            info.append("no WORKING_CONTEXT for session " + (sid or "unknown"))
        result = subprocess.run(["git", "status", "--porcelain"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        info.append("uncommitted work: %d paths (survives compaction)" %
                    len(result.stdout.splitlines()) if result.returncode == 0
                    else "uncommitted work: not a git repository")
        for name in newer:
            for line in (Path(".agent/events") / name).read_text().splitlines():
                if ADVISORY.search(line) and not re.match(MARKER, line):
                    info.append("advisory %s: %s" % (name, line))

        print("compact-readiness: %s (session %s [%s])" %
              ("NOT READY" if blocks else "READY", sid or "unknown", how))
        for line in blocks:
            print("- [!] " + line)
        for line in info:
            print("- [i] " + line)
        if not args.mark:
            return int(bool(blocks))
        if blocks and not args.force:
            print("Checkpoint unchanged: blocking items remain. Reconcile them, then "
                  "use --mark --force; use --staged-handled for reviewed pending rows.")
            return 1
        # Do not certify events that appeared during the check.
        if events() != names:
            fail("events changed during --mark; retry after reviewing the new events")
        for path, indexes in pending.items():
            if args.staged_handled and indexes:
                with path.open("a") as stream:
                    stream.write(json.dumps(dict(status="handled-by-session",
                                                 session_id=sid, handled_rows=indexes)) + "\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                print("Appended status: handled-by-session for %d rows in %s" %
                      (len(indexes), path))
        newest = names[-1] if names else ""
        fd, temporary = tempfile.mkstemp(prefix=".registers-checkpoint.", dir=".agent")
        try:
            with os.fdopen(fd, "w") as stream:
                stream.write(newest + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, CP)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        print("Checkpoint marked: " + (newest or "(no events)"))
        return 0


try:
    sys.exit(main())
except (OSError, ValueError, TypeError, KeyError) as error:
    print("compact-readiness: " + str(error), file=sys.stderr)
    sys.exit(2)
PY
