#!/bin/bash
# Megavibe — historical .agent/ recall on PreToolUse Grep/Glob.
# Bash content search is OPT-IN: MEGAVIBE_POMA_BASH=1. Literal search targets
# establish scope; parse ambiguity retains recall. Never eval shell text.
# MEGAVIBE_POMA_MAX_AGE_DAYS defaults to 45 (DECISIONS.md/LESSONS.md exempt).
# MEGAVIBE_POMA_MAX_CHARS defaults to 2400 per hit including metadata;
# MEGAVIBE_POMA_MAX_TOTAL_CHARS defaults to 6000 including framing/metadata.
# RRF scores rank candidates, not relevance. The lexical gate is deliberately
# conservative: >=2 distinct query words of >=4 characters in the emitted text,
# or the sole eligible word. Synonyms, short symbols and regexes can miss recall.
# No set -e: infrastructure failure must never block the tool or weaken filters.
set -u
trap 'exit 0' ERR
[ -d ".agent" ] || exit 0
command -v jq &>/dev/null || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
[ "$TOOL" != Bash ] || [ "${MEGAVIBE_POMA_BASH:-}" = 1 ] || exit 0

if ! command -v python3 &>/dev/null; then
  # No diagnostic search: without Python the required filters cannot run.
  # The audit is best effort and must never wait on another invocation.
  ROW=$(printf '%s' "$INPUT" | jq -ac '
    def capped: tostring | if length > 300 then .[:297] + "..." else . end;
    {tool:((.tool_name // "") | tostring | .[:32]),kept:false,reason:"python-unavailable",hits:[]}
    + (if .tool_name == "Bash" then {} else {query:((.tool_input.pattern // "") | capped)} end)' 2>/dev/null) || exit 0
  if command -v perl &>/dev/null; then
    ( printf '%s\n' "$ROW" | perl -MFcntl=:DEFAULT,:flock -e '
      exit if -l ".agent/LOGS";
      mkdir ".agent/LOGS" unless -d ".agent/LOGS";
      sysopen my $dir, ".agent/LOGS", O_RDONLY | O_DIRECTORY | O_NOFOLLOW or exit;
      chdir $dir or exit; # Pin all subsequent opens to this directory inode.
      my $flags = O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK;
      sysopen my $lock, ".injections.lock", $flags, 0600 or exit;
      -f $lock or exit;
      flock($lock, LOCK_EX | LOCK_NB) or exit;
      sysopen my $out, "injections.jsonl", $flags, 0600 or exit;
      -f $out or exit;
      seek $out, 0, 2 or exit; print $out <STDIN>;
      seek $out, 0, 0 or exit; my @lines = <$out>;
      if (@lines > 2000) {
        seek $out, 0, 0 or exit; truncate $out, 0 or exit;
        print $out @lines[-2000..-1];
      }
    ' ) 2>/dev/null || true
  fi
  exit 0
fi

POMA_EXE=$(command -v poma-memory 2>/dev/null || true)
HOOK_INPUT="$INPUT" POMA_EXE="$POMA_EXE" python3 - 2>/dev/null <<'PY'
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
from collections import deque
from contextlib import contextmanager

HOME_ROOT = Path.cwd().resolve()
LOCAL = (HOME_ROOT / '.agent').resolve()
LOGS = LOCAL / 'LOGS'
row = {'tool': '', 'query': '', 'kept': False, 'reason': 'invalid-input', 'hits': []}


def number(name, default, minimum=0):
    value = os.environ.get(name, str(default))
    return max(minimum, int(value)) if re.fullmatch(r'[0-9]{1,6}', value) else default


def under(path, root):
    return path == root or root in path.parents


def agent_path(path):
    return '.agent' in path.parts


def owner(path):
    # Only a tree with its own .agent establishes foreign ownership.
    for parent in [path] + list(path.parents):
        if (parent / '.agent').is_dir():
            return (parent / '.agent').resolve()
    return None


def resolve(value, cwd):
    if value.startswith('~/'):
        value = str(Path.home()) + value[1:]
    if any(c in value for c in '$`~\n*?[]{}'):
        raise ValueError('dynamic-path')
    return (cwd / value).resolve()


def search_scope(targets, globs, cwd):
    # Only resolved targets and literal leading directories are evidence.
    # Positive globs form a union; never intersect targets with each glob.
    if any(operational_target(p) and not agent_path(p) for p in targets):
        raise ValueError('operational-target')
    scopes = list(targets)
    for value in globs:
        if value.startswith('!'):
            continue
        prefix = []
        for part in value.split('/')[:-1]:
            if any(c in part for c in '*?[]{}$`\\\n'):
                break
            prefix.append(part)
        if prefix:
            try:
                scopes.append(resolve('/'.join(prefix) + '/', cwd))
            except (ValueError, OSError, RuntimeError):
                pass
    return scopes or [cwd]


def query_terms(pattern):
    # Shared by Bash, native Grep and the filename pattern derived from Glob.
    if pattern.count('|') >= 3:
        raise ValueError('regex-alternation')
    words = re.findall(r'[A-Za-z0-9]+', pattern)
    if words and sum(bool(re.fullmatch(r'[A-Za-z]{1,2}[0-9]+[a-z]?', w)) for w in words) * 2 > len(words):
        raise ValueError('id-pattern')
    terms = {w.lower() for w in words if len(w) >= 4}
    if not terms:
        raise ValueError('no-query-terms')
    return ' '.join(words), terms


def parse_bash_search(command):
    # shlex preserves quoted regexes and separates operators even without spaces.
    if any(c in command for c in '$`\n'):
        raise ValueError('dynamic-command')
    lex = shlex.shlex(command, posix=True, punctuation_chars=';&|()<>')
    lex.whitespace_split = True
    tokens = list(lex)
    cwd = HOME_ROOT
    # Only a prefix of literal cd commands is accepted; no wrappers/subshells.
    while tokens and tokens[0] == 'cd':
        if len(tokens) < 4 or tokens[2] != '&&':
            raise ValueError('unsupported-command')
        cwd = resolve(tokens[1], cwd)
        tokens = tokens[3:]
    if tokens[:1] == ['git']:
        tokens = tokens[1:]
        if tokens[:1] == ['-C'] and len(tokens) >= 3:
            cwd = resolve(tokens[1], cwd)
            tokens = tokens[2:]
        if tokens[:1] != ['grep']:
            raise ValueError('not-content-search')
    if not tokens or tokens[0] not in {'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack'}:
        raise ValueError('not-content-search')
    # Complex shell syntax falls back to lexical recall without scope inference.
    if any(t and all(c in ';&|()<>' for c in t) for t in tokens[1:]):
        raise ValueError('compound-command')
    pattern = None
    targets = []
    globs = []
    options = True
    args = iter(tokens[1:])
    value_flags = {'-g', '--glob', '-t', '--type', '--include', '--exclude',
                   '-m', '--max-count', '-A', '-B', '-C', '--context',
                   '--max-depth', '--threads', '-j', '--encoding', '--color', '--colors'}
    simple_long = {'--line-number', '--ignore-case', '--recursive', '--hidden',
                   '--fixed-strings', '--extended-regexp', '--word-regexp',
                   '--no-heading', '--with-filename', '--text', '--files-with-matches'}
    for arg in args:
        if options and arg == '--':
            options = False
        elif options and arg in {'-e', '--regexp'}:
            if pattern is not None:
                raise ValueError('multiple-patterns')
            pattern = next(args)
        elif options and (arg.startswith('--regexp=') or arg.startswith('-e') and len(arg) > 2):
            if pattern is not None:
                raise ValueError('multiple-patterns')
            pattern = arg.split('=', 1)[1] if '=' in arg else arg[2:]
        elif options and arg.startswith('-g') and len(arg) > 2:
            globs.append(arg[2:])
        elif options and arg.split('=', 1)[0] in value_flags:
            value = arg.split('=', 1)[1] if '=' in arg else next(args)
            if arg.split('=', 1)[0] in {'-g', '--glob', '--include'}:
                globs.append(value)
        elif options and arg.startswith('-'):
            if arg in simple_long or re.fullmatch(r'-[nrRiIEFHhwlstaUvV]+', arg):
                continue
            raise ValueError('unsupported-option')
        elif pattern is None:
            pattern = arg
        else:
            try:
                targets.append(resolve(arg, cwd))
            except (ValueError, OSError, RuntimeError):
                pass
    if pattern is None:
        raise ValueError('no-pattern')
    return pattern, search_scope(targets, globs, cwd)


def bash_search(command):
    try:
        return parse_bash_search(command)
    except (ValueError, StopIteration, OSError, RuntimeError) as exc:
        if str(exc) in {'not-content-search', 'operational-target'}:
            raise
        # Ambiguous syntax supplies query text, never negative scope evidence.
        return command, [HOME_ROOT]


def operational_target(path):
    if path == HOME_ROOT:
        return False
    # Managed worktree ancestors are not operational search targets.
    base = HOME_ROOT if under(path, HOME_ROOT) else Path.home().resolve()
    parts = path.relative_to(base).parts if under(path, base) else ()
    return path.suffix in {'.log', '.jsonl'} or any(
        part in {'.claude', '.megavibe'} and parts[i + 1:i + 2] != ('worktrees',)
        for i, part in enumerate(parts))



def file_age(path):
    # Filename dates describe provenance; Updated: describes the index upsert.
    match = re.match(r'^(\d{4}-\d{2}-\d{2})(?=\D|$)', path.name)
    compact = re.match(r'^(\d{8})(?:T\d{6}Z?)?(?=[^A-Za-z0-9]|$)', path.name)
    date = None
    source = 'filename' if match or compact else 'mtime'
    try:
        if match:
            date = dt.date.fromisoformat(match.group(1))
        elif compact:
            date = dt.datetime.strptime(compact.group(1), '%Y%m%d').date()
    except ValueError:
        source = 'mtime (invalid filename date)'  # Report the fallback explicitly.
    try:
        if date is None:
            date = dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc).date()
        age = (dt.datetime.now(dt.timezone.utc).date() - date).days
        # Future timestamps cannot establish freshness.
        return (age, date.isoformat(), source) if age >= 0 else (None, None, source)
    except (OSError, ValueError, OverflowError):
        return None, None, source



def load(path):
    try:
        return set(path.read_text().splitlines())
    except OSError:
        return set()


def excerpt(body, terms, budget):
    if len(body) <= budget:
        return body
    marker = ' [... truncated]'
    # Withhold oversized chunks when too little room remains for their head.
    if budget < 200:
        return ''
    width = budget - len(marker)
    end = width
    while end > 0 and not body[end].isspace():
        end -= 1
    # Python string slicing preserves Unicode even without a whitespace boundary.
    return body[:end or width] + marker


@contextmanager
def log_directory():
    LOGS.mkdir(exist_ok=True)
    fd = os.open(LOGS, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        yield fd
    finally:
        os.close(fd)


def log_file(directory, name, append=False):
    flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK
    fd = os.open(name, flags | (os.O_APPEND if append else 0), 0o600, dir_fd=directory)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError('non-regular log')
    return os.fdopen(fd, 'r+', encoding='utf-8')


def main():
    data = json.loads(os.environ['HOOK_INPUT'])
    tool = data.get('tool_name', '')
    inp = data.get('tool_input') or {}
    row['tool'] = tool
    row['query'] = inp.get('pattern', '') if tool != 'Bash' else ''
    if tool == 'Bash':
        pattern, targets = bash_search(inp.get('command', ''))
    elif tool in {'Grep', 'Glob'}:
        pattern = inp.get('pattern', '')
        try:
            targets = [resolve(inp['path'], HOME_ROOT)] if inp.get('path') else []
        except (ValueError, OSError, RuntimeError):
            targets = []
        if tool == 'Glob':
            targets = search_scope(targets, [pattern], targets[0] if targets else HOME_ROOT)
            pattern = pattern.rsplit('/', 1)[-1]
            if re.fullmatch(r'[*?]+\.[A-Za-z0-9]+', pattern):
                pattern = ''
        else:
            targets = search_scope(targets, [inp['glob']] if inp.get('glob') else [], HOME_ROOT)
    else:
        row['reason'] = 'unsupported-tool'
        return
    # Ambiguous Bash parsing can return the entire command for recall only.
    row['query'] = pattern if tool != 'Bash' or pattern != inp.get('command') else ''
    if any(agent_path(p) or under(p, LOCAL) for p in targets):
        row['reason'] = 'self-search'
        return
    query, terms = query_terms(pattern)
    extras = set()
    for entry in os.environ.get('MEGAVIBE_EXTRA_AGENT_DIRS', '').split(':'):
        try:
            p = resolve(entry, HOME_ROOT)
            if p.name == '.agent' and p.is_dir():
                extras.add(p)
        except (ValueError, OSError, RuntimeError):
            continue
    owners = {owner(p) for p in targets} - {None}
    if owners - extras - {LOCAL}:
        row['reason'] = 'foreign-repo'
        return
    # Ambiguous allowed scopes retain local recall; never fan out to extras.
    target_root = next(iter(owners)) if len(owners) == 1 else LOCAL
    roots = [target_root] if (target_root / '.poma-memory.db').is_file() else []
    if not roots:
        row['reason'] = 'missing-index'
        return
    executable = os.environ.get('POMA_EXE', '')
    if not executable:
        row['reason'] = 'missing-poma'
        return
    blocks = []
    for root in roots:
        try:
            with subprocess.Popen([executable, 'search', query, '--json', '--path', str(root) + '/',
                                   '--top-k', str(number('MEGAVIBE_POMA_TOPK', 8, 1)),
                                   '--min-score', os.environ.get('MEGAVIBE_POMA_MIN_SCORE', '0.028')],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  text=True, start_new_session=True) as process:
                try:
                    output, _ = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
                    raise
                if process.returncode:
                    row['reason'] = 'bad-output' if process.returncode == 2 else 'search-failed'
                    return
                try:
                    hits = json.loads(output)
                    if not isinstance(hits, list) or any(
                        not isinstance(h, dict) or not isinstance(h.get('file_path'), str)
                        or not isinstance(h.get('context'), str)
                        or type(h.get('score')) not in {int, float}
                        or not math.isfinite(h['score']) for h in hits
                    ):
                        raise ValueError()
                except (ValueError, TypeError):
                    row['reason'] = 'bad-output'
                    return
                blocks.extend(hits)
        except UnicodeError:
            row['reason'] = 'bad-output'
            return
        except subprocess.TimeoutExpired:
            row['reason'] = 'timeout'
            return
        except (OSError, subprocess.SubprocessError):
            row['reason'] = 'search-failed'
            return
    blocks.sort(key=lambda h: h['score'], reverse=True)
    sid = str(data.get('session_id') or 'default')[:12]
    if not re.fullmatch(r'[A-Za-z0-9._-]+', sid) or sid in {'.', '..'}:
        sid = 'default'
    ledger = LOGS / ('injected.' + sid + '.log')
    written = {str(Path(w).resolve()) for w in load(LOGS / ('session-writes.' + sid + '.log'))} if not LOGS.is_symlink() else set()
    maxn = number('MEGAVIBE_POMA_MAX_RESULTS', 3)
    maxage = number('MEGAVIBE_POMA_MAX_AGE_DAYS', 45)
    # Lock-free per-session append avoids waiting; simultaneous same-session
    # calls may rarely duplicate recall, but unrelated sessions never lose it.
    injected = load(ledger) if not LOGS.is_symlink() else set()
    kept, keys = [], []
    header = 'Historical project notes from poma-memory; they may be superseded. Verify against current code before stating any claim as fact.\n'
    remaining = max(0, number('MEGAVIBE_POMA_MAX_TOTAL_CHARS', 6000) - len(header))
    maxchars = number('MEGAVIBE_POMA_MAX_CHARS', 2400)
    for block in blocks:
        fp, body = block['file_path'], block['context']
        # Indexed names are literal data, never shell expressions. A malformed
        # path or outward symlink rejects only this candidate.
        try:
            if not fp or any(ord(c) < 32 for c in fp):
                raise ValueError('invalid-path')
            path = (HOME_ROOT / fp).resolve()
            contained = under(path, target_root)
            exists = path.is_file() if contained else False
            age, date, source = file_age(path) if exists else (None, None, None)
        except (OSError, ValueError, RuntimeError):
            path, contained, exists = None, False, False
            age, date, source = None, None, None
        reason = 'kept'
        if not contained:
            reason = 'outside-root'
        elif path.name in {'FULL_CONTEXT.md', 'snapshot.md', 'WORKING_CONTEXT.md', 'TASKS.md'} or any(part in {'LOGS', 'sessions'} for part in path.relative_to(target_root).parts):
            reason = 'excluded-path'
        elif not exists:
            reason = 'missing-file'
        elif (age is None or age > maxage) and path.name not in {'DECISIONS.md', 'LESSONS.md'}:
            reason = 'unknown-age' if age is None else 'too-old'
        elif str(path) in written:
            reason = 'self-written'
        elif len(kept) >= maxn:
            reason = 'result-cap'
        if age is None:
            age_line = 'Age unknown'
        elif source == 'filename':
            age_line = 'Age: dated {} ({} days ago)'.format(date, age)
        else:
            age_line = 'Age: file modified {} days ago (mtime; the text may be older)'.format(age)
        if source and 'invalid filename date' in source:
            age_line += ' — ' + source
        prefix = '--- Result {} (score: {}) ---\nFile: {}\n{}\n'.format(len(kept) + 1, block['score'], fp, age_line)
        budget = min(maxchars - len(prefix), remaining - len(prefix) - bool(kept))
        if reason == 'kept':
            clipped = excerpt(body, terms, budget) if budget > 0 else ''
            key = hashlib.md5((str(path) + '\n' + clipped).encode()).hexdigest()
            if not clipped:
                reason = 'char-cap'
            elif len(terms & set(w.lower() for w in re.findall(r'[A-Za-z0-9]+', clipped))) < min(2, len(terms)):
                reason = 'lexical-overlap'
            elif key in injected:
                reason = 'duplicate'
        row['hits'].append({'file': fp, 'score': block['score'], 'age_days': age,
                            'date': date, 'age_source': source, 'kept': reason == 'kept', 'reason': reason})
        if reason != 'kept':
            continue
        result = prefix + clipped
        remaining -= len(result) + bool(kept)
        kept.append(result)
        keys.append(key)
        injected.add(key)
    if keys:
        try:
            with log_directory() as directory, log_file(directory, ledger.name, append=True) as f:
                f.write('\n'.join(keys) + '\n')
        except OSError:
            pass
    row['kept'] = bool(kept)
    row['reason'] = 'injected' if kept else 'no-survivors'
    if kept:
        print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'additionalContext':
            header + '\n'.join(kept)},
            'systemMessage': 'megavibe: {} historical .agent matches injected as context'.format(len(kept))}))


def audit_line():
    if row['reason'] == 'not-content-search':
        return json.dumps({'reason': row['reason']}) + '\n'
    entry = dict(row)
    query = str(entry['query'])
    entry['query'] = query[:297] + '...' if len(query) > 300 else query
    entry['tool'] = str(entry['tool'])[:32]
    entry['reason'] = str(entry['reason'])[:128]
    entry['hits'] = list(entry['hits'])
    # Bound serialized bytes (including escaped Unicode), not just characters.
    # Drop trailing candidate diagnostics before shortening other fields.
    while True:
        line = json.dumps(entry, ensure_ascii=True) + '\n'
        if len(line) <= 4096:
            return line
        entry['truncated'] = True
        if entry['hits']:
            entry['hits'].pop()
        elif entry['query']:
            entry['query'] = entry['query'][:len(entry['query']) // 2]
            if entry['query']:
                entry['query'] += '...'
        else:
            return json.dumps({'reason': entry['reason'], 'truncated': True}) + '\n'


def audit():
    try:
        with log_directory() as directory, log_file(directory, '.injections.lock') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with log_file(directory, 'injections.jsonl') as f:
                f.seek(0, os.SEEK_END)
                f.write(audit_line())
                f.seek(0)
                lines = deque(f, maxlen=2000)
                # Rewrite through the same descriptor, never reopen a pathname.
                if len(lines) == 2000:
                    f.seek(0)
                    f.truncate()
                    f.writelines(lines)
    except (OSError, ValueError):
        pass


try:
    try:
        LOGS.mkdir(exist_ok=True)
    except OSError:
        pass
    main()
except (ValueError, StopIteration) as exc:
    row['reason'] = str(exc) or 'invalid-command'
except Exception:
    row['reason'] = 'infrastructure-failure'
finally:
    audit()
PY
exit 0
