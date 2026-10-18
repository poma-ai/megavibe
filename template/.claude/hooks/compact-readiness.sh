#!/bin/bash
# Advisory: exit 0 = no findings; 1 = NOT READY; 2 = unable to check.
# Reports write nothing. --mark records event coverage, never queue handling.
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
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

# The watcher uses Unicode isalnum(); agent-log uses ASCII hashes.
EVENT = re.compile(r"[0-9]{8}T[0-9]{6}Z-[\w.-]+\.md")
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
    names = []
    for path in root.glob("*"):
        if not path.is_file() or not EVENT.fullmatch(path.name):
            fail("unexpected event filename: " + repr(path.name))
        names.append(path.name)
    return sorted(names)


def body_lines(name):
    fence = 0
    for line in (Path(".agent/events") / name).read_text().splitlines():
        match = re.match(r"^ {0,3}(`{3,})(.*)$", line)
        if match:
            if not fence and "`" not in match[2]:
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
    known = identities()
    if sid not in known and len(sid) <= 12:
        matches = {s for s in known if s.startswith(sid)}
        if len(matches) > 1:
            fail("ambiguous session: pass --session")
        if matches:
            sid = matches.pop()
    return sid, how


def valid_sid(sid):
    return bool(re.fullmatch(r"[A-Za-z0-9._-]{1,64}", sid)) and sid not in (".", "..")


def identities():
    known = {p.name for p in Path(".agent/sessions").glob("*") if p.is_dir()}
    known.update(p.name[len(".bg-tasks."):-len(".jsonl")]
                 for p in LOGS.glob(".bg-tasks.*.jsonl"))
    # Short queue/counter keys are aliases, not evidence of an exact identity.
    for pattern, prefix, suffix in (("pending-decisions.*.jsonl", "pending-decisions.", ".jsonl"),
                                     (".tool-call-counter.*", ".tool-call-counter.", "")):
        for path in LOGS.glob(pattern):
            key = path.name[len(prefix):]
            if suffix:
                key = key[:-len(suffix)]
            if path.is_file() and not path.name.endswith(".lock") and len(key) > 12:
                known.add(key)
    return {s for s in known if valid_sid(s)}


def pending_counts(sid):
    result = []
    peers = {s for s in identities() if s.startswith(sid[:12])}
    for path in sorted(LOGS.glob("pending-decisions.*.jsonl")):
        key = path.name[len("pending-decisions."):-len(".jsonl")]
        if not valid_sid(key):
            fail("invalid session queue filename: " + repr(path.name))
        if not sid:
            fail("session unknown with staged rows: pass --session")
        if key not in (sid, sid[:12]):
            continue
        if any(p != sid for p in peers) and (key != sid or len(sid) <= 12):
            fail("ambiguous legacy session queue; ownership unknown: " + str(path))
        count = 0
        for line in path.read_text().splitlines():
            row = json.loads(line)
            if not isinstance(row, dict):
                fail("invalid pending row: " + str(path))
            if row.get("status") == "pending":
                if row.get("session_id", key) not in (sid, sid[:12]):
                    fail("pending row ownership does not match queue: " + str(path))
                count += 1
        result.append((path, count))
    return result


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
    parser = argparse.ArgumentParser(description="Advisory register coverage report; never blocks compaction.", allow_abbrev=False)
    parser.add_argument("--project", default=".")
    parser.add_argument("--session")
    parser.add_argument("--mark", action="store_true")
    parser.add_argument("--hook-input", metavar="JSON_FILE", help="live hook payload; - reads stdin")
    parser.add_argument("--fold-before", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if any(value == "" for value in (args.project, args.session, args.hook_input, args.fold_before)):
        parser.error("option values must not be empty")
    if args.mark and args.fold_before:
        parser.error("mark and fold are mutually exclusive")
    minimum = number("MEGAVIBE_READY_TASKS_MIN_EVENTS", 3)
    limit = number("MEGAVIBE_READY_ADVISORY_LIMIT", 20, 0, 1000)
    interval = max(60, min(600, number("MEGAVIBE_BG_CHECK_SECS", 300)))
    for name in ("MEGAVIBE_READY_TASKS_LAG_MIN", "MEGAVIBE_READY_DECISION_RE"):
        if name in os.environ:
            fail(name + " is retired; use event counts and structured markers")
    os.chdir(args.project)
    if not Path(".agent").is_dir():
        fail("no .agent/ in project")
    if args.fold_before:
        with Path(str(CP) + ".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return fold(args.fold_before)
    sid, how = session(args.session)
    with contextlib.ExitStack() as stack:
        # Only coverage writers take a lock. Reports never create lock files.
        if args.mark:
            lock = stack.enter_context(Path(str(CP) + ".lock").open("a"))
            fcntl.flock(lock, fcntl.LOCK_EX)
        covered = checkpoint(CP)
        names = events()
        if args.mark:
            # The caller asserts review; this is not a readiness certificate.
            # Fold alone prunes prior identities, under the same lock.
            save_checkpoint(covered | set(names))
            covered |= set(names)
            print("Coverage recorded for %d observed events; readiness is reported separately." % len(names))
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
        pending = pending_counts(sid)
        for path, count_pending in pending:
            if count_pending:
                blocks.append("%d pending decisions for this session: %s" % (count_pending, path))
        info.append("%d pending decisions for this session" % sum(n for _, n in pending))
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
            base, freshest = {}, {}
            for row in rows:
                ident = row["id"]
                if ident not in live:
                    continue
                started = row.get("started")
                if type(started) not in (int, float) or not 0 < started < float("inf"):
                    fail("background task %s: missing or invalid registry start time" % ident)
                if ident not in base:
                    base[ident] = dict(row)
                    freshest[ident] = started
                else:
                    merged = base[ident]
                    merged["started"] = min(merged["started"], started)
                    merged["nudged"] = max(merged.get("nudged", 0), row.get("nudged", 0))
                    if started >= freshest[ident]:
                        merged["path"] = row.get("path", "")
                        freshest[ident] = started
            for ident, row in base.items():
                def names_task(command, task):
                    return task["id"] in command or bool(task.get("path") and task["path"] in command)
                covered_task = any(names_task(r.get("command", ""), row)
                                   for key, r in live.items() if key != ident)
                watcher = any(names_task(live[ident].get("command", ""), other)
                              for key, other in base.items() if key != ident)
                if not covered_task and not watcher and time.time() - row["started"] >= interval:
                    blocks.append("background %s task %s found without a heartbeat; arm a Monitor or stop it"
                                       % (row.get("kind", "?"), ident))
        wc = Path(".agent/sessions") / sid / "WORKING_CONTEXT.md"
        if sid and wc.is_file() and wc.stat().st_size:
            age = max(0, int(time.time() - wc.stat().st_mtime))
            info.append("WORKING_CONTEXT %s: %dm old; /rehydrate %s" %
                        (wc, age // 60, "required" if age > 3600 else "optional"))
        else:
            info.append("no WORKING_CONTEXT for session " + (sid or "unknown"))
        result = subprocess.run(["git", "status", "--porcelain"], stdout=subprocess.PIPE, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"),
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
        print("compact-readiness: %s (session %s [%s]; advisory only)" %
              ("NOT READY" if blocks else "READY", sid or "unknown", how))
        for label, lines, cap in (("!", blocks, 20), ("i", info, 20),
                                  ("ADVISORY", advisory, limit)):
            for line in lines[:cap]:
                print(("- [%s] %s" % (label, " ".join(line.split())))[:200])
            if len(lines) > cap:
                print("- [%s] and %d more" % (label, len(lines) - cap))
        if total_advisory > limit:
            print("- [ADVISORY] and %d more" % (total_advisory - limit))
        return int(bool(blocks))


try:
    sys.exit(main())
except (OSError, ValueError, TypeError, KeyError) as error:
    print(("compact-readiness: unable to check: " + " ".join(str(error).split()))[:200], file=sys.stderr)
    sys.exit(2)
PY
