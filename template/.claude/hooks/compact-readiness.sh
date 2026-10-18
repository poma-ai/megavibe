#!/bin/bash
# Exit 0: ready; 1: blockers; 2: invalid input or unable to check.
# Coverage is by immutable filename, never timestamp or filename ordering.
command -v python3 >/dev/null 2>&1 || {
  echo 'compact-readiness: unable to check: python3 is required' >&2
  exit 2
}
# Preserve hook JSON stdin while the Python program comes from a here document.
exec 3<&0
exec python3 - "$@" <<'PY'
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
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
ADVISORY = re.compile(r"\b(decisions?|decided|chosen|chose|selected|agreed|verdict)\b"
                      r"|\bD[0-9]+\b|\bdefault [A-D]\b", re.I)
CP = Path(".agent/.registers-checkpoint")
LOGS = Path(".agent/LOGS")


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


def atomic(path, text):
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if path.exists():
            os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def checkpoint(path):
    if not path.exists() and path == CP:
        return set()
    lines = path.read_text().splitlines()
    # A legacy single-filename checkpoint cannot prove identity coverage.
    if not lines or not lines[0].startswith("covered-through "):
        fail("invalid coverage record; review events and remove legacy checkpoint: " + str(path))
    covered = set(lines[1:])
    if (any(not EVENT.fullmatch(n) for n in covered)
            or lines[0] != "covered-through " + max(covered, default="")):
        fail("invalid coverage record: " + str(path))
    return covered


def save_checkpoint(covered):
    atomic(CP, "covered-through " + max(covered, default="") + "\n"
           + "".join(n + "\n" for n in sorted(covered)))


def events():
    root = Path(".agent/events")
    return sorted(p.name for p in root.glob("*.md")
                  if p.is_file() and EVENT.fullmatch(p.name))


def body_lines(name):
    fence = 0
    for line in (Path(".agent/events") / name).read_text().splitlines():
        match = re.match(r"^ {0,3}(`{3,})(.*)$", line)
        if match:
            if not fence:
                fence = len(match[1])
            elif len(match[1]) >= fence and not match[2].strip():
                fence = 0
            continue
        if not fence:
            yield line


def marked(names):
    return sum(any(re.match(MARKER, line) for line in body_lines(n)) for n in names)


def session(requested):
    counters = [p for p in LOGS.glob(".tool-call-counter.*")
                if p.is_file() and not p.name.endswith(".lock")
                and time.time() - p.stat().st_mtime <= 86400]
    sid = requested or os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    how = "--session" if requested else "CLAUDE_CODE_SESSION_ID"
    if not sid:
        if len(counters) > 1:
            fail("ambiguous session: pass --session")
        sid = counters[0].name[len(".tool-call-counter."):] if counters else ""
        how = "recent tool-call counter"
    if not sid:
        return "", "unknown"
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", sid) or sid in (".", ".."):
        fail("invalid session id")
    # Directories and full background-state keys are authoritative identities.
    known = {p.name for p in Path(".agent/sessions").glob("*") if p.is_dir()}
    known.update(p.name[len(".bg-tasks."):-len(".jsonl")]
                 for p in LOGS.glob(".bg-tasks.*.jsonl"))
    if sid not in known and len(sid) <= 12:
        matches = {s for s in known if s.startswith(sid)}
        if len(matches) > 1:
            fail("ambiguous session: pass --session")
        if matches:
            sid = matches.pop()
    return sid, how


def row_id(path, index, row):
    digest = hashlib.sha256(json.dumps(row, sort_keys=True, ensure_ascii=True,
                                      separators=(",", ":")).encode()).hexdigest()
    return "%s:%d:%s" % (path.name, index, digest)


def queue_rows(path, sid):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    if any(not isinstance(row, dict) for row in rows):
        fail("invalid pending row: " + str(path))
    mine = {sid, sid[:12]}
    handled = set()
    for row in rows:
        if row.get("status") == "handled-by-session" and row.get("session_id") in mine:
            ids = row.get("handled_rows", [])
            if not isinstance(ids, list) or any(type(i) not in (str, int) for i in ids):
                fail("invalid handling marker: " + str(path))
            handled.update(ids)
    return {row_id(path, i, row): row for i, row in enumerate(rows, 1)
            if row.get("status") == "pending" and i not in handled
            and row_id(path, i, row) not in handled
            and row.get("session_id", sid[:12]) in mine}


def fold(before):
    cutoff = dt.datetime.strptime(before, "%Y-%m-%d").strftime("%Y%m%d")
    covered = checkpoint(CP)
    names = [n for n in events() if n[:8] < cutoff]
    if any(n not in covered for n in names):
        fail("fold refused: uncovered events; reconcile registers and --mark first")
    snapshot = Path(".agent/snapshot.md")
    old = snapshot.read_text() if snapshot.exists() else ""
    prior = re.findall(r"^<!-- registers-fold-cutoff: ([0-9]{8}) -->$", old, re.M)
    cutoff = max([cutoff] + prior)
    old = re.sub(r"^<!-- registers-fold-cutoff: [0-9]{8} -->\n?", "", old, flags=re.M)
    text = "<!-- registers-fold-cutoff: " + cutoff + " -->\n" + old
    text += "".join((Path(".agent/events") / n).read_text() for n in names)
    # Publish history first. A crash can duplicate history, never lose it.
    atomic(snapshot, text)
    for n in names:
        (Path(".agent/events") / n).unlink()
    live = set(events())
    save_checkpoint({n for n in covered if n[:8] >= cutoff or n in live})
    print("agent-log: folded %d entries older than %s" % (len(names), before))
    return 0


def main():
    parser = argparse.ArgumentParser(description="Check explicit register coverage.")
    parser.add_argument("--project", default=".")
    parser.add_argument("--session")
    parser.add_argument("--decisions-since", metavar="CHECKPOINT")
    parser.add_argument("--mark", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--staged-handled", nargs="+", metavar="ROW_ID")
    parser.add_argument("--hook-input", metavar="JSON_FILE", help="live hook payload; - reads stdin")
    parser.add_argument("--fold-before", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if any(value == "" for value in (args.project, args.session, args.decisions_since)):
        parser.error("option values must not be empty")
    if (args.force or args.staged_handled) and not args.mark:
        parser.error("--force and --staged-handled require --mark")
    if sum(bool(v) for v in (args.decisions_since, args.mark, args.fold_before)) > 1:
        parser.error("probe, mark and fold are mutually exclusive")
    minimum = number("MEGAVIBE_READY_TASKS_MIN_EVENTS", 3)
    limit = number("MEGAVIBE_READY_ADVISORY_LIMIT", 20, 0, 1000)
    interval = max(60, min(600, number("MEGAVIBE_BG_CHECK_SECS", 300)))
    for name in ("MEGAVIBE_READY_TASKS_LAG_MIN", "MEGAVIBE_READY_DECISION_RE"):
        if name in os.environ:
            fail(name + " is retired; use event counts and structured markers")
    os.chdir(args.project)
    if not Path(".agent").is_dir():
        fail("no .agent/ in project")
    if args.decisions_since:
        covered = checkpoint(Path(args.decisions_since))
        count = marked([n for n in events() if n not in covered])
        print(count)
        return int(count > 0)
    if args.fold_before:
        with Path(str(CP) + ".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return fold(args.fold_before)
    sid, how = session(args.session)
    if args.staged_handled and not sid:
        fail("--staged-handled requires --session")
    paths = []
    for path in LOGS.glob("pending-decisions.*.jsonl"):
        key = path.name[len("pending-decisions."):-len(".jsonl")]
        if sid and key in (sid, sid[:12]):
            peers = {p.name for p in Path(".agent/sessions").glob(sid[:12] + "*") if p.is_dir()}
            peers.update(p.name[len(".bg-tasks."):-len(".jsonl")]
                         for p in LOGS.glob(".bg-tasks." + sid[:12] + "*.jsonl"))
            peers.update(p.name[len(".tool-call-counter."):]
                         for p in LOGS.glob(".tool-call-counter." + sid[:12] + "*")
                         if not p.name.endswith(".lock") and len(p.name[len(".tool-call-counter."):]) > 12)
            if any(p != sid for p in peers) and (key != sid or len(sid) <= 12):
                fail("ambiguous session queue: pass an unambiguous --session")
            paths.append(path)
        elif not sid:
            fail("session unknown with staged rows: pass --session")
    with contextlib.ExitStack() as stack:
        # Serialize marks/folds and queue observations with the watcher's locks.
        locks = ([Path(str(CP) + ".lock")] if args.mark else [])
        locks += sorted(Path(str(p) + ".lock") for p in paths)
        for path in locks:
            fcntl.flock(stack.enter_context(path.open("a")), fcntl.LOCK_EX)
        covered = checkpoint(CP)
        names = events()
        newer = [n for n in names if n not in covered]
        count = marked(newer)
        blocks, info, advisory = [], [], []
        info.append("%d uncovered events; %d marked-decision events" % (len(newer), count))
        if not Path(".agent/DECISIONS.md").is_file():
            blocks.append("DECISIONS.md is missing")
        elif count:
            blocks.append("DECISIONS.md: reconcile marked decisions, including their reasons")
        if not Path(".agent/TASKS.md").is_file():
            blocks.append("TASKS.md is missing")
        elif count or len(newer) >= minimum:
            blocks.append("TASKS.md: reconcile item status and blockers")
        pending = {p: queue_rows(p, sid) for p in paths}
        ids = {i for rows in pending.values() for i in rows}
        receipt = LOGS / (".readiness-shown." + sid + ".json")
        selected = set(args.staged_handled or [])
        if selected:
            shown = set(json.loads(receipt.read_text())) if receipt.exists() else set()
            if not selected <= shown or not selected <= ids:
                fail("staged row ids were not shown to this session or have changed; run the check again")
        remaining = ids - selected
        if remaining:
            blocks.append("%d pending decisions for this session; review ROW_IDs below, then use "
                          "--mark --staged-handled ROW_ID ..." % len(remaining))
        info.extend("ROW_ID " + i for i in sorted(ids))
        info.append("%d pending decisions for this session" % len(ids))
        bg = LOGS / (".bg-tasks." + sid + ".jsonl")
        rows = [json.loads(line) for line in bg.read_text().splitlines()] if sid and bg.exists() else []
        for row in rows:
            if int(row.get("nudged", 0)) > 0:
                advisory.append("background task %s: earlier heartbeat nudge" % row.get("id", "?"))
        info.append("%d background tasks recorded" % len(rows) if rows else
                    "no background tasks recorded for this session")
        if args.hook_input:
            payload = json.load(os.fdopen(3) if args.hook_input == "-" else open(args.hook_input))
            if payload.get("session_id") != sid:
                fail("live registry session does not match --session")
            registry = payload.get("background_tasks")
        else:
            registry = None
        if registry is None:
            info.append("live background registry unavailable; heartbeat coverage unknown")
        else:
            if not isinstance(registry, list) or any(not isinstance(r, dict) for r in registry):
                fail("invalid live background registry")
            live = {r["id"]: r for r in registry if r.get("status") == "running"}
            base = {r["id"]: r for r in rows if r["id"] in live}
            for ident, row in base.items():
                def names_task(command, task):
                    return task["id"] in command or bool(task.get("path") and task["path"] in command)
                covered_task = any(names_task(r.get("command", ""), row)
                                   for key, r in live.items() if key != ident)
                watcher = any(names_task(live[ident].get("command", ""), other)
                              for key, other in base.items() if key != ident)
                if not covered_task and not watcher and time.time() - row.get("started", time.time()) >= interval:
                    blocks.append("background %s task %s found without a heartbeat; arm a Monitor or stop it"
                                  % (row.get("kind", "?"), ident))
        wc = Path(".agent/sessions") / sid / "WORKING_CONTEXT.md"
        if sid and wc.is_file() and wc.stat().st_size:
            age = max(0, int(time.time() - wc.stat().st_mtime))
            info.append("WORKING_CONTEXT %s: %dm old; /rehydrate %s" %
                        (wc, age // 60, "required" if age > 3600 else "optional"))
        else:
            info.append("no WORKING_CONTEXT for session " + (sid or "unknown"))
        result = subprocess.run(["git", "status", "--porcelain"], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True)
        info.append("uncommitted work: %d paths (survives compaction)" % len(result.stdout.splitlines())
                    if result.returncode == 0 else "uncommitted work: not a git repository")
        # Keep only the bounded preview, even for multi-megabyte events.
        total_advisory = len(advisory)
        advisory = advisory[:limit]
        for name in newer:
            for line in body_lines(name):
                if ADVISORY.search(line) and not re.match(MARKER, line):
                    total_advisory += 1
                    if len(advisory) < limit:
                        advisory.append("advisory %s: %s" % (name, line))
        print("compact-readiness: %s (session %s [%s])" %
              ("NOT READY" if blocks else "READY", sid or "unknown", how))
        for line in blocks:
            print("- [!] " + line)
        for line in info:
            print("- [i] " + line)
        for line in advisory:
            print(("- [ADVISORY] " + line)[:200])
        if total_advisory > limit:
            print("- [ADVISORY] and %d more" % (total_advisory - limit))
        if not args.mark:
            if sid and ids:
                LOGS.mkdir(exist_ok=True)
                atomic(receipt, json.dumps(sorted(ids)))
            return int(bool(blocks))
        # The exact observed identities alone may be acknowledged, even if a
        # watcher appended more rows while this mark waited for the queue lock.
        for path, rows in pending.items():
            reviewed = sorted(selected.intersection(rows))
            if reviewed:
                with path.open("a") as stream:
                    stream.write(json.dumps(dict(status="handled-by-session", session_id=sid,
                                                 handled_rows=reviewed)) + "\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                print("Appended status: handled-by-session for %d rows in %s" % (len(reviewed), path))
        if remaining or (blocks and not args.force):
            print("Checkpoint unchanged: blocking items remain. Reconcile them, then use --mark --force; "
                  "pending rows always require --staged-handled ROW_ID ...")
            return 1
        if events() != names:
            fail("events changed during --mark; retry after reviewing the new events")
        snapshot = Path(".agent/snapshot.md")
        cutoffs = re.findall(r"^<!-- registers-fold-cutoff: ([0-9]{8}) -->$",
                             snapshot.read_text() if snapshot.exists() else "", re.M)
        cutoff = max(cutoffs, default="")
        save_checkpoint({n for n in covered if n[:8] >= cutoff} | set(names))
        print("Checkpoint marked: " + max(names, default="(no events)"))
        return 0


try:
    sys.exit(main())
except (OSError, ValueError, TypeError, KeyError) as error:
    print("compact-readiness: unable to check: " + str(error), file=sys.stderr)
    sys.exit(2)
PY
