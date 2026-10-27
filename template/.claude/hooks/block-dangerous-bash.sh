#!/bin/bash
# DO NOT use set -e — transient jq/grep failures must not produce "hook error" noise.
# Exit 2 = block the command; Exit 0 = allow; Exit 1 = "hook error" (bad).
# NOTE: no 'trap exit 0' here — this hook INTENTIONALLY exits 2 to block dangerous commands.
set -u

# Megavibe — block destructive Bash commands before execution
# Triggered by: PreToolUse (Bash)
# Exit 2 = block the command; Exit 0 = allow
# Note: this guard runs in ALL projects (safety is always good)

# Require jq — exit 0 (allow) if missing (don't block Claude over missing jq)
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command' 2>/dev/null || echo "")

# If we couldn't parse the command, allow it (don't block on parse errors)
[ -n "$COMMAND" ] || exit 0

# Recursive/forced rm targeting root, home, or cwd — INCLUDING glob forms.
#
# Three tests ANDed: is rm invoked, does it carry a destructive flag, is the target
# a bare top-level path or top-level glob. Splitting them is what lets scoped deletes
# through (./build/*, /tmp/x, *.log) while still catching the top-level globs that an
# earlier single-regex version allowed straight past it.
#
# Evaluated PER COMMAND SEGMENT, not against the whole string. Applied globally, the
# three tests combine across unrelated fragments of a long command line — a heredoc
# that merely mentions rm in one line and a glob in another would trip all three and
# block a completely safe command.
# rmtrash too: moving / or ~ into the Trash is not a recoverable mistake either.
_RM_INVOKED='(^|[[:space:]])(rm|rmtrash)([[:space:]]+-{1,2}[[:alnum:]-]+)*[[:space:]]'
_RM_DESTRUCTIVE_FLAG='[[:space:]]-{1,2}[[:alnum:]]*[rRf]'
_RM_TOPLEVEL_TARGET='(^|[[:space:]])(\*|\.|\.\*|\.\/\*?|\/\*?|~\/?\*?|\$HOME\/?\*?|\.\[[^]]*\]\*?)([[:space:]]|$)'

# tr (not sed) for the split: BSD/macOS sed does not expand \n in the replacement.
# ; | & and newline all become segment boundaries; && and || yield an empty segment.
while IFS= read -r _seg; do
  [ -n "$_seg" ] || continue
  # pad with a trailing space so end-of-segment behaves like a word boundary
  _seg="$_seg "
  if printf '%s' "$_seg" | grep -Eq "$_RM_INVOKED" \
     && printf '%s' "$_seg" | grep -Eq "$_RM_DESTRUCTIVE_FLAG" \
     && printf '%s' "$_seg" | grep -Eq "$_RM_TOPLEVEL_TARGET"; then
    echo "Blocked: recursive rm targeting root/home/cwd or a top-level glob. Use an explicit scoped path." >&2
    exit 2
  fi
done <<EOF
$(printf '%s' "$COMMAND" | tr ';|&' '\n\n\n')
EOF

# ---------------------------------------------------------------------------
# Emptying, or deleting from, the Trash.
#
# rm-to-trash.sh makes the Trash the ONLY undo for every delete an agent performs;
# emptying it destroys that undo for everything at once, including files nobody
# looked at (an agent "freeing space" did exactly this on 2026-09-30). No escape
# hatch for an agent: a human empties it in Finder, or answers the permission prompt
# in front of ~/.megavibe/scripts/trash-empty.sh (the gate just below). Reads (ls, du),
# restoring one file with mv, and text that merely mentions these words (commit
# messages, grep patterns, PR bodies) are untouched.
#
# Parsed with shlex like the kubectl guard below, for the same reason: regexes over
# shell text were defeated by (rm ...), { rm; }, then/do, env VAR=x rm, sudo -u root
# rm, multi-line osascript scripts and quoting tricks, and blocked commit messages.
# The parser splits commands and pipelines, finds the command word past keywords,
# assignments and wrappers, recurses into bash -c / eval, tracks variables and cd
# pointed at the Trash, and treats Finder `empty`, trash --empty, rm/unlink/find
# -delete/rsync --delete/mv-of-the-directory and interpreter one-liners on the Trash
# as blocked.
#
# Relevance gate first: hooks fire on every tool call, so python only starts when the
# text mentions the Trash or osascript (quotes and [] stripped, so `."Trash` and
# `.[T]rash` still trip it). Without python3, or if it fails, a crude regex applies.
#
# HACK: it reads command text and allows what it does not recognise, so it is a
# net with holes, not a wall. Known gaps: a script FILE that empties the Trash; a
# path assembled at runtime or obfuscated (T=~/.Tr; T=${T}ash, ~/.Tras*,
# ~/.Tr$'a'sh); tar/zip variants, ssh, shell functions and other exotic deleters; a
# wrapper that the per-group "deleting verb next to a Trash path" rule misses.
# Known over-blocks: prose inside a heredoc that feeds a shell or interpreter,
# `find ~/.Trash -exec mv` restores, grep of the word rm next to a Trash path.
# Every review round on this block found a new bypass or over-block, so do not read
# a clean regression corpus as proof. Upgrade path: a filesystem-level guard.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# The Trash greenlight script: ~/.megavibe/scripts/trash-empty.sh.
#
# It is the one deleting path, and what gates it is NOT this hook but Claude Code's
# permission prompt: setup.sh installs `permissions.ask` rules for it, and an ask rule
# is honoured under bypassPermissions and forwarded to the phone. Those rules match the
# command text as written (`bash <script>`, an absolute or $HOME spelling, a copy, `sh -c`
# or a glob all slip a path-anchored rule), so this gate's job is to let exactly ONE
# spelling reach the prompt and to refuse every other command that names the script or
# reaches into its directory by a spelling the rules would miss:
#   - the exact command `~/.megavibe/scripts/trash-empty.sh [--all]`, with nothing else in
#     the call: exit 0 here (no permission decision is made; the ask rule prompts next);
#   - any other command whose text, quotes and brackets stripped, contains `trash-e`; or that
#     names .megavibe/scripts/ with a $, glob, brace, bracket or backtick after it; or that
#     starts a home-anchored path at a dot directory whose name is globbed or expanded and
#     globs on (`~/.m*/scripts/t*-e*sh`); or that cd/pushd into .megavibe or .megavibe/scripts:
#     blocked.
# The early exit also sidesteps the crude no-python fallback further down, which would
# otherwise refuse the asked form. Python is not needed for any of this.
# HACK: a net, not a wall. Known holes: a script FILE that calls it, a name assembled
# from pieces the text never shows together (a variable set in a file, `ls` + eval).
# The catch-all ask rule `Bash(*trash-empty*)` still prompts whenever the plain name
# appears, and the script itself refuses to run unless it is invoked from its install
# path with the ask rules installed.
# Known over-blocks: ANY Bash text containing `trash-e` is refused, including `git add
# scripts/trash-empty.sh`, `bash -n`, `shellcheck`, `grep` and a commit message that names
# it; so is `cd ~/.megavibe` and a glob under `~/.megavibe/` or `~/.m*`. Use the Read and
# Grep tools, `git add scripts/` (the directory), `git commit -F file`, absolute paths.
# ---------------------------------------------------------------------------
_TE=$(printf '%s' "$COMMAND" | tr -d "\"'\\\\[]{},\n" | tr '[:upper:]' '[:lower:]')
_TE_RAW=$(printf '%s' "$COMMAND" | tr '[:upper:]' '[:lower:]')
case "$_TE|$_TE_RAW" in
  *trash-e*|*.megavibe*|*/.m*|*/.\**|*/.\?*|*/.\[*|*/.\{*|*/.\$*)
    _TE_EXACT='^[[:space:]]*~/\.megavibe/scripts/trash-empty\.sh([[:blank:]]+--all)?[[:space:]]*$'
    if [[ $COMMAND =~ $_TE_EXACT ]]; then
      exit 0
    fi
    if printf '%s' "$_TE" | grep -Eq 'trash-e' \
       || printf '%s' "$_TE_RAW" | grep -Eq '\.megavibe/scripts/[^[:space:]]*[$*?{[`]' \
       || printf '%s' "$_TE_RAW" | grep -Eq '(^|[[:space:]=:("'"'"'])(~|\$\{?home\}?|/users/[^[:space:]/]+)/\.[m*?[{$][^[:space:]]*[*?{[]' \
       || printf '%s' "$_TE_RAW" | grep -Eq '(^|[[:space:];&|(])(cd|pushd)[[:space:]]+[^[:space:];&|]*\.megavibe(/scripts)?/?([[:space:];&|)]|$)'; then
      echo "Blocked: trash-empty.sh may only be run exactly as ~/.megavibe/scripts/trash-empty.sh [--all] (alone in the call; the user is asked for permission). To read it use the Read tool; to name it in a commit message use git commit -F." >&2
      exit 2
    fi
    ;;
esac

_TRASH_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || true)
_TRASH_CMD=$(printf '%s' "$COMMAND" | tr -d "\"'\\\\[]" | tr '[:upper:]' '[:lower:]')
case "$_TRASH_CMD $(printf '%s' "$_TRASH_CWD" | tr '[:upper:]' '[:lower:]')" in
  *trash*|*osascript*|*osacompile*)
    _TV=""
    if command -v python3 &>/dev/null; then
      read -r -d '' _TRASH_PY <<'PY' || true
import os, re, shlex, sys

CMD = os.environ.get("TR_CMD", "").replace("\\\n", "")
TR = re.compile(r"\.Trash(es)?(?![A-Za-z0-9_.-])", re.I)
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
KW = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "fi", "done", "esac", "time"}
# wrapper -> options that consume the next token
WRAP = {
    "sudo": {"-u", "-g", "-C", "-U", "-h", "-p", "-r", "-t", "-D", "-R"},
    "doas": {"-u", "-C"}, "env": {"-u", "-S", "-C", "-P"}, "command": set(), "nohup": set(), "time": set(),
    "nice": {"-n"}, "xargs": {"-I", "-J", "-L", "-P", "-n", "-E", "-R", "-S", "-d", "-s", "-a"}, "exec": {"-a"}, "builtin": set(),
    "stdbuf": set(), "ionice": {"-c", "-n"}, "caffeinate": {"-t"}, "parallel": {"-j", "-S"},
    "timeout": {"-s", "-k"}, "gtimeout": {"-s", "-k"}, "flock": {"-w", "-E"}, "arch": {"-arch"}, "watch": {"-n", "-d"}, "chronic": set(), "ssh-agent": set(),
    "uv": set(), "npx": set(), "bunx": set(), "poetry": set(), "bundle": set(), "pipx": set(), "pnpm": set(), "yarn": set(), "npm": set(),
}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
VERBS = {"rm", "rmtrash", "srm", "shred", "unlink", "rmdir", "truncate", "tee", "dd", "rimraf"}
SUBCMD = {"run", "exec", "dlx", "x"}
CLOBBER = {"cp", "ditto", "install", "mv"}
INTERP = re.compile(r"^(python[0-9.]*|node|nodejs|ruby|perl|php|deno|bun|lua|awk|gawk|swift|pwsh)$")
CODE_DEL = re.compile(r"unlink|rmtree|rmSync|\.rm\(|rm_rf|rimraf|rmdir|os\.remove|\.remove\(|File\.delete|remove_entry|Files\.delete|FileUtils|rm_r|remove_tree|os\.system|system\(|subprocess|Popen|(^|[^A-Za-z0-9_./-])rm(?=[\s'\",\]])|emptyDir|trashItem|removeItem|shutil\.move|os\.replace|os\.rename", re.I)
PH = {";": "\x01a", "&": "\x01b", "|": "\x01c", "(": "\x01d", ")": "\x01e", "<": "\x01f", ">": "\x01g"}
UNPH = {v: k for k, v in PH.items()}


def rs(a):
    return re.sub("\x01[a-g]", lambda m: UNPH[m.group(0)], a)


REDIR = {">", ">>", ">|", ">&", "<", "<<", "<<<", "<&", "<<-"}
PUNCT = re.compile(r";;|&&|\|\||\|&|>>|>\||<<<|<<-|<<|<&|>&|[;&|()<>]")


def nl_split(s):
    """Newlines outside quotes separate commands; comments end at the newline; quoted text is untouched."""
    out, q, i, n = [], None, 0, len(s)
    while i < n:
        c = s[i]
        if c == "\\" and q != "'" and i + 1 < n:
            d = s[i + 1]
            out.append(c + (PH[d] if d in PH else d)); i += 2; continue
        if q:
            if c == q: q = None
            out.append(PH.get(c, c) if c != q and q is not None else c)
        elif c in "'\"":
            q = c; out.append(c)
        elif c == "#" and (i == 0 or s[i - 1] in " \t\n;&|()"):
            while i < n and s[i] != "\n": i += 1
            continue
        elif c == "\n":
            out.append(" ; ")
        else:
            out.append(c)
        i += 1
    return "".join(out)


def strip_heredocs(s):
    lines, out, i = s.split("\n"), [], 0
    while i < len(lines):
        ln = lines[i]; out.append(ln); i += 1
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", ln)
        if m and not re.search(r"(^|[^A-Za-z0-9_.-])(ba|z|k|da)?sh(\s|$)|python|node|ruby|perl|osascript|osacompile|awk|swift|php|deno|bun|lua|eval|xargs", ln[:m.start()]):
            while i < len(lines) and lines[i].strip() != m.group(2): i += 1
    return "\n".join(out)


def subst_bodies(s):
    out, q, i, n = [], None, 0, len(s)
    while i < n:
        c = s[i]
        if c == "\\": i += 2; continue
        if q == "'":
            if c == "'": q = None
        elif c in "'\"" and (q is None or c == q): q = None if q else c
        elif c == "$" and s[i + 1:i + 2] == "(":
            d, j = 1, i + 2
            while j < n and d:
                d += (s[j] == "(") - (s[j] == ")"); j += 1
            out.append(s[i + 2:j - 1]); i = j; continue
        elif c == "`":
            j = s.find("`", i + 1)
            if j > i: out.append(s[i + 1:j]); i = j
        i += 1
    return out


def tokens(s):
    lx = shlex.shlex(nl_split(strip_heredocs(s)), posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    lx.commenters = ""
    out = []
    for t in lx:
        if t and all(ch in ";&|()<>" for ch in t): out.extend(PUNCT.findall(t) or [t])
        else: out.append(t)
    return out


def pipelines(toks):
    groups, pipe, cur = [], [], []
    for t in toks:
        if t and all(ch in ";&|()" for ch in t):
            if cur: pipe.append(cur); cur = []
            if t in ("(", ")"): pipe.append([t])
            if t not in ("|", "|&", "(", ")"):
                if pipe: groups.append(pipe); pipe = []
        else:
            cur.append(t)
    if cur: pipe.append(cur)
    if pipe: groups.append(pipe)
    return groups


def strip_redirs(t):
    out, i = [], 0
    while i < len(t):
        if t[i] in REDIR: i += 2; continue
        if t[i].isdigit() and i + 1 < len(t) and t[i + 1] in REDIR: i += 3; continue
        out.append(t[i]); i += 1
    return out


def resolve(t):
    i, via = 0, False
    while i < len(t):
        w = t[i]; b = os.path.basename(w)
        if w in KW or ASSIGN.match(w):
            i += 1; continue
        if b in WRAP:
            via = via or b in ("xargs", "parallel")
            i += 1
            posn = 1 if b in ("timeout", "gtimeout", "flock") else 0
            while i < len(t) and (t[i].startswith("-") or ASSIGN.match(t[i]) or (b in ("uv", "poetry", "bundle", "pipx", "pnpm", "yarn", "npm") and t[i] in SUBCMD)):
                i += 2 if t[i] in WRAP[b] else 1
            i += posn
            continue
        return i, via
    return None, via


def positionals(args):
    out, skip = [], False
    for a in args:
        if skip: skip = False; continue
        if a in ("--exclude", "--include", "--filter", "-e", "--rsh"): skip = True; continue
        if a.startswith("-"): continue
        out.append(a)
    return out


ABS = re.compile(r"^(/|~(?!\+)|\$(?!\{?PWD)[A-Za-z_{])")
READERS = {"grep", "egrep", "fgrep", "rg", "ag", "echo", "printf", "cat", "man", "which", "type", "whatis", "less", "more", "head", "tail", "wc", "ls", "file", "stat", "open", "git", "gh", "brew", "sed", "awk", "diff", "cmp"}
DEL_TOK = {"rm", "rmtrash", "srm", "shred", "unlink", "rmdir", "rimraf", "grm"}


def all_abs(args):
    p = [a for a in args if not a.startswith("-")]
    return bool(p) and all(ABS.match(a) for a in p)


def analyse(s, st, depth=0):
    if depth > 4: return False
    for body in subst_bodies(strip_heredocs(s)):
        if analyse(body, st, depth + 1): return True
    for pipe in pipelines(tokens(s)):
        pipe_trash = any(c and c[-1] == "<" for c in pipe) and any(TR.search(re.sub(r"[\[\]]", "", x)) for c in pipe for x in c)
        for raw in pipe:
            if raw == ["("]: st["stack"].append(st["cwd"]); continue
            if raw == [")"]:
                if st["stack"]: st["cwd"] = st["stack"].pop()
                continue
            def tr(a):
                n = re.sub(r"[\[\]]", "", a)
                if TR.search(n): return True
                if "@" in st["vars"] and re.search(r"\$[@*]|\$\{[@*]\}", a): return True
                return any(m.group(1) in st["vars"] for m in re.finditer(r"\$\{?(\w+)", a))
            # redirects into the Trash; input redirects are reads
            for k, a in enumerate(raw[:-1]):
                if a in (">", ">>", ">|", ">&") and tr(raw[k + 1]): return True
            t = strip_redirs(raw)
            targs, prev, prev2 = [], None, None
            for a in t:
                excl = prev in ("--exclude", "-E") or (prev in ("-path", "-ipath", "-wholename", "-iwholename", "-regex", "-name", "-iname") and prev2 in ("-not", "!"))
                if not a.startswith("--exclude") and not a.startswith("if=") and not excl and tr(a): targs.append(a)
                prev2, prev = prev, a
            if st["subst"] and targs: return True
            st["subst"] = False
            if targs: pipe_trash = True
            for a in t:
                m = ASSIGN.match(a)
                if m:
                    subst_val = (a.endswith("$") or "`" in a) and targs
                    (st["vars"].add if (tr(a[m.end():]) or subst_val) else st["vars"].discard)(a[:m.end() - 1])
                    if a.endswith("$"): st["pa"] = a[:m.end() - 1]
            if st["pa"] and targs: st["vars"].add(st["pa"])
            if not (t and ASSIGN.match(t[-1]) and t[-1].endswith("$")): st["pa"] = ""
            if t[:1] == ["for"] and "in" in t[:4] and len(t) > 3 and any(tr(a) for a in t[3:]): st["vars"].add(t[1])
            i, via = resolve(t)
            if i is None: continue
            w = os.path.basename(t[i]); args = t[i + 1:]
            if targs and (w.startswith("$") or w.startswith("-")): return True
            if w in ("cd", "pushd", "popd"):
                dest = [a for a in args if not a.startswith("-")]
                if args[:1] == ["-"]: st["cwd"] = False
                elif any(tr(a) for a in dest): st["cwd"] = True
                elif w == "popd": st["cwd"] = False
                elif dest and dest[0] not in (".", "./") and not (st["cwd"] and not ABS.match(dest[0]) and not dest[0].startswith("..")): st["cwd"] = False
            if w in SHELLS or INTERP.match(w):
                idx = pipe.index(raw)
                has_script = any(not a.startswith("-") for a in args)
                cands = ([] if has_script else [x for c in pipe[:idx] for x in c]) + [raw[k + 1] for k, x in enumerate(raw[:-1]) if x == "<<<"]
                for c in cands:
                    c = rs(c)
                    if not TR.search(c): continue
                    if w in SHELLS and analyse(c, dict(st, vars=set(st["vars"]), stack=[]), depth + 1): return True
                    if INTERP.match(w) and CODE_DEL.search(c): return True
            if w in SHELLS:
                for k, a in enumerate(args[:-1]):
                    if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a):
                        sub = {**st, "vars": set(st["vars"]), "stack": [], "cwd": st["cwd"] or (via and pipe_trash)}
                        for x, pa in enumerate(args[k + 2:]):
                            if tr(pa): sub["vars"].add(str(x))
                        if analyse(rs(args[k + 1]), sub, depth + 1): return True
                        st["osa"] += sub["osa"]; st["interp"] = st["interp"] or sub["interp"]
                        break
            if w == "eval" and analyse(rs(" ".join(args)), dict(st, vars=set(st["vars"]), stack=[]), depth + 1): return True
            if w == "set" and args[:1] == ["--"] and any(tr(a) for a in args[1:]): st["vars"].add("@")
            if w == "read" and (pipe_trash or (re.search(r"<\s*\(", CMD) and TR.search(re.sub(r"[\[\]]", "", CMD)))):
                for a in args:
                    if not a.startswith("-"): st["vars"].add(a)
            if w in ("osascript", "osacompile"):
                # only this command, what feeds it and its heredoc count as Finder script text
                ofeed = " ".join(" ".join(x) for x in pipe[:pipe.index(raw) + 1])
                st["osa"] = st["osa"] + " " + ofeed + (" " + s[s.find("<<"):] if "<<" in raw else "")
            if w == "git" and args[:1] == ["clean"] and targs: return True
            if w == "shortcuts" and any(re.search(r"empty", a, re.I) for a in args): return True
            if w == "ssh" and any(TR.search(re.sub(r"[\[\]]", "", a)) for a in args) and analyse(rs(args[-1]), dict(st, vars=set(st["vars"]), stack=[]), depth + 1): return True
            if w in ("trash-empty", "emptytrash", "empty-trash", "empty-trash-cli"): return True
            if w == "trash" and any(a == "--empty" or re.match(r"^-[a-z]*e[a-z]*$", a) or (re.match(r"^-[a-z]*s[a-z]*$", a) and "y" in a) for a in args): return True
            if w == "gio" and args[:1] == ["trash"] and "--empty" in args: return True
            rel = st["cwd"] and not all_abs(args)
            if w in VERBS:
                if targs or rel or (via and pipe_trash): return True
                if any(a.endswith("$") or "`" in a for a in args): st["subst"] = True
            if w in ("find", "gfind"):
                lead, skip, take = [], False, False
                for a in args:
                    if skip: skip = False; continue
                    if a in ("-H", "-L", "-P", "-O1", "-O2", "-O3", "-E", "-X", "-x", "-s"): continue
                    if a == "-D": skip = True; continue
                    if a == "-f": take = True; continue
                    if take: lead.append(a); take = False; continue
                    if a.startswith("-") or a.startswith("\x01") or a == "!": break
                    lead.append(a)
                ftr = any(tr(a) for a in lead)
            if w in ("find", "gfind"):
                for k, a in enumerate(args[1:], 1):
                    if args[k - 1] in ("-path", "-ipath", "-wholename", "-iwholename", "-regex") and tr(a) and (k < 2 or args[k - 2] not in ("-not", "!")) \
                            and "-prune" not in args and ("-delete" in args or "-exec" in args or "-execdir" in args): return True
            if w in ("find", "gfind") and (ftr or rel):
                for k, a in enumerate(args):
                    if a == "-delete": return True
                    if a in ("-exec", "-execdir", "-ok", "-okdir"):
                        seq = []
                        for y in args[k + 1:]:
                            if y in ("\x01a", "+"): break
                            seq.append(y)
                        j, _ = resolve(seq)
                        if j is not None:
                            b = os.path.basename(seq[j])
                            if INTERP.match(b) and any(CODE_DEL.search(rs(y)) for y in seq): return True
                            if b == "dd":
                                if any(y.startswith("of={}") for y in seq): return True
                            elif b == "tee":
                                if "{}" in seq: return True
                            elif b in VERBS or b == "mv": return True
                            if b in SHELLS:
                                sub = {"vars": set(st["vars"]), "cwd": True, "interp": False, "osa": "", "subst": False, "stack": [], "pa": ""}
                                for x, y in enumerate(seq[j + 1:-1]):
                                    if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", y) and analyse(rs(seq[j + 2 + x]), sub, depth + 1): return True
            if w == "rsync" and not ("--dry-run" in args or any(re.match(r"^-[A-Za-z]*n[A-Za-z]*$", a) for a in args)):
                pos = positionals(args)
                rel_ = lambda a: st["cwd"] and not ABS.match(a)
                if any(a.startswith("--remove-source") for a in args) and any(tr(a) or rel_(a) for a in pos[:-1]): return True
                if any(a.startswith("--del") for a in args) and pos and (tr(pos[-1]) or rel_(pos[-1])): return True
            if w == "mv":
                pos = positionals(args)
                if any(re.search(r"\.Trash(es)?/?$|\.Trash(es)?/.*[*?]", re.sub(r"[\[\]]", "", a), re.I) for a in pos[:-1]): return True
            if w in CLOBBER and "-n" not in args:
                pos = positionals(args)
                # a file NAMED inside the Trash is overwritten; the bare directory is where files are put
                if pos and re.search(r"\.Trash(es)?/[^/]+$", re.sub(r"[\[\]]", "", pos[-1]), re.I): return True
            if w == "cp" and "/dev/null" in args and targs: return True
            if INTERP.match(w):
                if (targs or st["cwd"] or (via and pipe_trash)) and any(CODE_DEL.search(rs(a)) for a in args): return True
                if "<<" in raw or "<<-" in raw:
                    hd = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?[^\n]*\n(.*?)\n[ \t]*\1[ \t]*(\n|$)", s, re.S)
                    if hd and TR.search(re.sub(r"[\[\]]", "", hd.group(2))) and CODE_DEL.search(hd.group(2)): return True
        if pipe_trash and "-prune" not in [x for c in pipe for x in c]:
            for c in pipe:
                cw, _ = resolve(strip_redirs(c))
                word = os.path.basename(c[cw]) if cw is not None else ""
                if word in READERS: continue
                if any(os.path.basename(x) in DEL_TOK or x == "--remove-files" for x in c): return True
    return False


def osa_text(s):
    s = re.sub(r'"[^"]*"', " ", rs(s))
    if re.search(r"(?<![A-Za-z0-9_])(empty|secure\s*empty)(?![A-Za-z0-9_])|emptyTrash|fndremty|key code 51", s, re.I): return True
    return bool(re.search(r"(?<![A-Za-z0-9_])trash(?![A-Za-z0-9_])", s, re.I) and re.search(r"(?<![A-Za-z0-9_])(delete|remove|erase)(?![A-Za-z0-9_])", s, re.I))


try:
    st = {"vars": set(), "cwd": bool(TR.search(os.environ.get("TR_CWD", ""))), "interp": False, "osa": "", "subst": False, "stack": [], "pa": ""}
    bad = analyse(CMD, st)
    if not bad and st["osa"]:
        for m in re.finditer(r'do shell script\s+"((?:[^"\\]|\\.)*)"', rs(st["osa"])):
            if analyse(m.group(1).replace('\\"', '"'), dict(st, vars=set(st["vars"]), stack=[])): bad = True
    if not bad and st["osa"] and osa_text(st["osa"]): bad = True
    print("BLOCK" if bad else "OK")
except ValueError:
    # unbalanced quotes: cannot parse, so judge crudely and lean towards blocking
    bad = TR.search(CMD) and re.search(r"(^|[^A-Za-z0-9_-])(rm|rmtrash|srm|shred|unlink|rmdir|rmtree)([^A-Za-z0-9_-]|$)|-delete|--del", CMD)
    print("BLOCK" if bad or (re.search(r"osascript|osacompile", CMD) and osa_text(CMD)) else "OK")
PY
      _TV=$(TR_CMD="$COMMAND" TR_CWD="$_TRASH_CWD" python3 -c "$_TRASH_PY" 2>/dev/null)
    fi
    if [ -z "$_TV" ]; then
      if printf '%s %s' "$_TRASH_CMD" "$(printf '%s' "$_TRASH_CWD" | tr '[:upper:]' '[:lower:]')" | grep -Eq '\.trash' \
         && printf '%s' "$_TRASH_CMD" | grep -Eq '(^|[^[:alnum:]_-])(rm|rmtrash|srm|shred|unlink|rmdir|rmtree|rimraf)([^[:alnum:]_-]|$)|-delete|--del'; then
        _TV=BLOCK
      elif printf '%s' "$_TRASH_CMD" | grep -Eqi 'osascript.*empty|emptytrash|trash-empty|trash[[:space:]]+(-e|--empty)|gio[[:space:]]+trash[[:space:]]+--empty'; then
        _TV=BLOCK
      fi
    fi
    if [ "$_TV" = "BLOCK" ]; then
      echo "Blocked: emptying or deleting from the Trash. It is the only undo for agent deletes. Ask the user to empty it themselves." >&2
      exit 2
    fi
    ;;
esac

# force-push to the trunk branch
if echo "$COMMAND" | grep -Eqi 'git[[:space:]]+push[[:space:]]+.*--force.*[[:space:]]+(main|master)'; then
  echo "Blocked: force push to trunk" >&2
  exit 2
fi

# DROP TABLE / DROP DATABASE
if echo "$COMMAND" | grep -Eqi '(DROP[[:space:]]+(TABLE|DATABASE))'; then
  echo "Blocked: DROP TABLE/DATABASE" >&2
  exit 2
fi

# git reset --hard
if echo "$COMMAND" | grep -Eqi 'git[[:space:]]+reset[[:space:]]+--hard'; then
  echo "Blocked: git reset --hard" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Cluster exec-class commands against a namespace that is not visibly non-prod.
#
# `kubectl exec` LOOKS like a read when all you want is an env var or a version
# string — it is not. It starts a process inside a live production container, in
# that container's cgroup. Where the cluster convention is
# request.mem == limit.mem (Guaranteed QoS, zero headroom by design), an extra
# interpreter can push the cgroup over its limit and the kernel kills the
# LARGEST process — the server, not your shell. `attach`, `cp`, `debug` and
# `port-forward` are the same class: they reach inside, or tunnel into, a
# running production workload.
#
# This is the one destructive class that gets mistaken for a read, which is why
# it is guarded and the obviously-mutating verbs (apply/patch/delete/scale/
# rollout) are not — nobody confuses those for reads, and blocking them would
# break ordinary operations.
#
# Parsed with Python's shlex, NOT with regexes. A regex first cut was defeated
# by every one of: `bash -c "kubectl exec …"`, `kube'ctl' exec`, a
# backslash-newline continuation between `kubectl` and `exec`, and
# `COLOR=#ff00aa kubectl exec …` (a `#` inside a word is not a comment). It also
# blocked `kubectl get pod exec` by scanning every word for the verb instead of
# parsing the subcommand. Shell is not a regular language; do not put a regex
# back here.
#
# FAIL-CLOSED: allowed only when the namespace/context visibly names a non-prod
# environment, matched COMPONENT-WISE (split on - _ . : /), never as a substring
# — `prodev`, `citadel`, `special-prod` and `my-device-prod` are production. Any
# component naming production (prod/prd/production/live) blocks outright, so
# `qa-mirror-of-prod` cannot slip through on its `qa`.
#
# A visibly local current-context (docker-desktop/minikube/kind/k3d/colima/…)
# read from KUBECONFIG allows everything, so ordinary local development against
# the `default` namespace is untouched.
#
# Escape hatch, because legitimate prod exec exists: MEGAVIBE_ALLOW_PROD_EXEC=1,
# set deliberately, per session, when a human has decided to go in. Extend the
# safe list with MEGAVIBE_NONPROD_PATTERN (space- or pipe-separated tokens).
#
# Read-only verbs (get/describe/logs/top/events/explain/version/config) are
# untouched — they answer almost every question exec gets reached for.
#
# Needs python3; without it the guard is skipped (same posture as rm-to-trash.sh:
# degrade to "no guard" rather than block a user's work over a missing tool).
# ---------------------------------------------------------------------------
case "$COMMAND" in
  *kube*|*oc\ *|*oc$'\t'*|*k\ *) _MAYBE_KUBE=1 ;;   # 'kube' also catches kube'ctl' / kubecolor
  *) _MAYBE_KUBE=0 ;;
esac
if [ "$_MAYBE_KUBE" = "1" ] && [ "${MEGAVIBE_ALLOW_PROD_EXEC:-0}" != "1" ] && command -v python3 &>/dev/null; then
  _VERDICT=$(printf '%s' "$COMMAND" | python3 -c '
import os, re, shlex, sys

CMD = sys.stdin.read().replace("\\\n", "")   # shell removes line continuations first
CMD = CMD.replace("\n", " ; ")                # a newline separates commands; shlex would eat it
EXEC_VERBS = {"exec", "attach", "cp", "debug", "port-forward", "rsh", "node-shell", "proxy"}
KUBE_BINS = {"kubectl", "kubecolor", "oc", "k"}
WRAPPERS = {"sudo", "env", "command", "nice", "time", "nohup", "stdbuf", "doas"}
SHELLS = {"sh", "bash", "zsh", "ksh", "dash"}
OPS = {";", "&&", "||", "|", "&", "\n"}

def toks(s):
    lx = shlex.shlex(s, posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    lx.commenters = ""          # "#" is a comment only at word start; do not truncate
    try:
        return list(lx)
    except ValueError:
        return None             # unbalanced quotes -> caller decides, fail closed

def commands(tokens):
    cur = []
    for t in tokens:
        if t in OPS:
            if cur: yield cur
            cur = []
        else:
            cur.append(t)
    if cur: yield cur

NONPROD = set(re.split(r"[\s|]+", (os.environ.get("MEGAVIBE_NONPROD_PATTERN") or
    "dev development test tst testing staging stage qa uat sandbox sbx local localhost "
    "ci preview demo scratch tmp kind k3d k3s minikube colima orbstack docker-desktop "
    "rancher-desktop").strip()))
PROD = {"prod", "prd", "production", "live"}
LOCAL_CTX = {"docker-desktop", "minikube", "colima", "orbstack", "rancher-desktop",
             "kind", "k3d", "k3s", "microk8s", "local", "localhost"}

def parts(v):
    return [p for p in re.split(r"[-_.:/]+", v.strip().lower()) if p]

def nonprod(v):
    if not v: return False
    ps = parts(v)
    if any(p in PROD for p in ps): return False    # an explicit prod component wins
    return any(p in NONPROD for p in ps)

def local_context():
    raw = os.environ.get("KUBECONFIG") or os.path.expanduser("~/.kube/config")
    for cfg in raw.split(os.pathsep):
        try:
            with open(cfg) as fh:
                for line in fh:
                    if line.startswith("current-context:"):
                        v = line.split(":", 1)[1].strip().strip("\"\x27")
                        return v.lower() in LOCAL_CTX or any(p in LOCAL_CTX for p in parts(v))
        except OSError:
            continue
    return False

def flag_value(argv, names):
    for i, a in enumerate(argv):
        for n in names:
            if a == n and i + 1 < len(argv): return argv[i + 1]
            if a.startswith(n + "="):        return a.split("=", 1)[1]
    return None

VALUED = {"-n","--namespace","--context","--cluster","--kubeconfig","--user","--token",
          "--server","-s","--as","--as-group","--request-timeout","--cache-dir",
          "--client-key","--client-certificate","--certificate-authority","--tls-server-name"}

def subcommand(argv):
    """First non-flag token after the binary, skipping global flags and their values."""
    i = 1
    while i < len(argv):
        a = argv[i]
        if a.startswith("-"):
            i += 2 if a in VALUED else 1
            continue
        return a
    return None

def scan(argv, depth=0):
    if depth > 3 or not argv: return False
    i = 0
    while i < len(argv) and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[i])
                             or os.path.basename(argv[i]) in WRAPPERS):
        # The block message tells you to re-run with this prefix. The hook is a
        # separate process reading the Claude Code environment, so an inline
        # assignment would never reach it - honour it here or the documented
        # escape hatch is a door painted on a wall.
        if argv[i].startswith("MEGAVIBE_ALLOW_PROD_EXEC=") and argv[i].split("=", 1)[1] == "1":
            return False
        i += 1
    if i >= len(argv): return False
    argv = argv[i:]
    base = os.path.basename(argv[0])
    if base in SHELLS:                      # bash -c "kubectl exec …" -> recurse
        body = flag_value(argv, ["-c"])
        if not body: return False
        t = toks(body)
        if t is None: return True           # unparseable body -> fail closed
        return any(scan(c, depth + 1) for c in commands(t))
    if base not in KUBE_BINS: return False
    if "--help" in argv or "-h" in argv: return False    # reading the docs is not an exec
    verb = subcommand(argv)
    if verb == "run":                                    # only the interactive form is a shell-in
        if not any(f in argv for f in ("-it", "-ti", "-i", "--stdin", "--attach")): return False
    elif verb not in EXEC_VERBS:
        return False
    if nonprod(flag_value(argv, ["-n", "--namespace"])): return False
    if nonprod(flag_value(argv, ["--context"])): return False
    return True

t = toks(CMD)
if t is None:
    # Unbalanced quotes: the shell would reject this anyway. Only flag it when the
    # raw text plausibly holds a kube exec, so a broken echo is not blocked.
    print("block" if re.search(r"(kubectl|oc)\b[^\n]*\b(exec|attach|cp|debug|port-forward)\b", CMD) else "ok")
else:
    hit = any(scan(c) for c in commands(t))
    print("block" if (hit and not local_context()) else "ok")
' 2>/dev/null || echo ok)
  if [ "$_VERDICT" = "block" ]; then
    echo "Blocked: cluster exec-class command (exec/attach/cp/debug/port-forward) against a namespace that is not visibly non-prod." >&2
    echo "This is a WRITE, not a read: it runs a process inside a live container and can OOM-kill the server in a zero-headroom pod." >&2
    echo "Get the fact from the manifest instead: kubectl get/describe, the image tag, the env block, the sealed secret, or the repo." >&2
    echo "If a human has decided to go in: re-run with MEGAVIBE_ALLOW_PROD_EXEC=1, or widen MEGAVIBE_NONPROD_PATTERN." >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# Process-kill and session-kill commands by PATTERN or by SERVER.
#
# 2026-10-15 18:35: a review subagent cleaning up after a timeout test ran
# `pkill -f 'perl -e' -P 1`. The pattern also matched the tmux server (its argv
# carries the whole start command), and every tmux-hosted session died with it:
# the remote-control sessions, the Telegram bot, the Personal Assistant, the
# context watchers. A prose prohibition in the brief is not a sandbox
# (same class as the `git rm -f` incident of 2026-10-08).
#
# Blocked when they are the command: pkill, killall, `tmux kill-server|kill-session|
# kill-window|kill-pane`, `launchctl bootout|unload|remove|stop|kill|bootstrap|disable`
# and `launchctl kickstart -k`. NOT blocked: `kill <pid>` (a PID you started),
# `tmux ls|new|send-keys|capture-pane|attach`, `launchctl list|print|kickstart`.
# Parsed with shlex like the exec guard above, so the words inside quotes, an
# echo, a commit message or a heredoc body are not commands; `bash -c "pkill x"`,
# `sudo pkill x` and `env X=1 pkill x` are. Escape hatch for a human decision:
# MEGAVIBE_ALLOW_KILL=1 (environment or an inline prefix). Needs python3; without
# it the guard is skipped (same posture as the other guards here).
# ---------------------------------------------------------------------------
case "$COMMAND" in
  *pkill*|*killall*|*tmux*|*launchctl*) _MAYBE_KILL=1 ;;
  *) _MAYBE_KILL=0 ;;
esac
if [ "$_MAYBE_KILL" = "1" ] && [ "${MEGAVIBE_ALLOW_KILL:-0}" != "1" ] && command -v python3 &>/dev/null; then
  _KV=$(printf '%s' "$COMMAND" | python3 -c '
import os, re, shlex, sys

CMD = sys.stdin.read()
# Heredoc bodies are text, not commands: drop the body of EVERY heredoc started on a line
# (cat <<A <<B has two), up to its delimiter line.
out, pending = [], []
for line in CMD.split("\n"):
    if pending:
        if line.strip() == pending[0]: pending.pop(0)
        continue
    out.append(line)
    pending = re.findall(r"(?<!<)<<(?!<)-?\s*\\?[\x27\"]?([A-Za-z_][A-Za-z0-9_]*)[\x27\"]?", line)
CMD = "\n".join(out).replace("\\\n", "")
CMD = CMD.replace("\n", " ; ")

KILLERS = {"pkill", "killall"}
TMUX_VERBS = {"kill-server", "kill-session", "kill-window", "kill-pane"}
LAUNCHCTL_VERBS = {"bootout", "unload", "remove", "stop", "kill", "bootstrap", "disable"}
WRAPPER_OPTS = {"sudo": {"-u","-g","-h","-p","-C","-T","-r","-t","-U","-D","-R"}, "doas": {"-u","-C"},
                "env": {"-u","-C","-S","-P"}, "nice": {"-n"}, "stdbuf": {"-i","-o","-e"},
                "timeout": {"-s","-k"}, "nohup": set(), "command": set(),
                "time": set(), "builtin": set(),
                "xargs": {"-I","-n","-P","-L","-s","-E","-d","-a","-J","-R","-S"}}
WRAPPER_OPTS["ex" + "ec"] = {"-a"}
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "fi", "done"}
SHELLS = {"sh", "bash", "zsh", "ksh", "dash"}
OPS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&", ";;"}

def split_tokens(s):
    # Non-POSIX mode keeps the quotes on a word, so a QUOTED ";" or "&&" is a word
    # (echo ";" pkill x prints text) and only a bare one is an operator.
    lx = shlex.shlex(s, posix=False, punctuation_chars=True)
    lx.whitespace_split = True
    lx.commenters = ""
    try:
        return list(lx)
    except ValueError:
        return None

def unq(tok):
    try:
        w = shlex.split(tok)
        return "".join(w) if w else ""
    except ValueError:
        return tok

def commands(tokens):
    cur = []
    for t in tokens:
        if t in OPS:
            if cur: yield [unq(x) for x in cur]
            cur = []
        else:
            cur.append(t)
    if cur: yield [unq(x) for x in cur]

def verb(argv, valued):
    i = 1
    while i < len(argv):
        a = argv[i]
        if a.startswith("-"):
            i += 2 if a in valued else 1
            continue
        return a
    return None

def scan(argv, depth=0):
    if depth > 3 or not argv: return False
    i = 0
    while i < len(argv):
        a = argv[i]; b = os.path.basename(a)
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", a):
            if a == "MEGAVIBE_ALLOW_KILL=1": return False
            i += 1; continue
        if a in KEYWORDS:
            i += 1; continue
        if b in WRAPPER_OPTS:
            i += 1
            while i < len(argv) and argv[i].startswith("-") and argv[i] != "-":
                opt = argv[i]; i += 1
                if opt == "--": break
                if opt in WRAPPER_OPTS[b] and i < len(argv): i += 1
            while i < len(argv) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[i]):
                if argv[i] == "MEGAVIBE_ALLOW_KILL=1": return False
                i += 1
            if b == "timeout" and i < len(argv) and re.match(r"^[0-9.]+[smhd]?$", argv[i]): i += 1
            continue
        break
    if i >= len(argv): return False
    argv = argv[i:]
    base = os.path.basename(argv[0])
    if base in SHELLS:
        for j, a in enumerate(argv[1:], 1):
            if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) and j + 1 < len(argv):
                t = split_tokens(argv[j + 1])
                if t is None: return False
                return any(scan(c, depth + 1) for c in commands(t))
        return False
    if base in KILLERS:
        return not ("--help" in argv or "-h" in argv)
    if base == "tmux":
        return verb(argv, {"-L", "-S", "-f", "-c", "-T"}) in TMUX_VERBS
    if base == "launchctl":
        v = verb(argv, set())
        if v == "kickstart": return any(re.match(r"^-[A-Za-z]*k[A-Za-z]*$", x) for x in argv[1:])
        return v in LAUNCHCTL_VERBS
    return False

t = split_tokens(CMD)
if t is None:
    print("ok")
else:
    print("block" if any(scan(c) for c in commands(t)) else "ok")
' 2>/dev/null || echo ok)
  if [ "$_KV" = "block" ]; then
    echo "Blocked: pkill/killall or a tmux/launchctl kill command." >&2
    echo "A pattern kill can hit the tmux server and every remote-control session with it (2026-10-15 18:35). Kill only a PID you started yourself (kill \$!, then ps -p), never a pattern, a server or a service." >&2
    echo "If a human has decided to: re-run with MEGAVIBE_ALLOW_KILL=1." >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# Real deletes that skip the Trash.
#
# rm-to-trash.sh only rewrites `rm` on the command line. On 2026-10-26 an agent freed
# disk with an inline python3 heredoc (globs + shutil.rmtree) over its scratchpad; one
# glob matched a directory of finished work, and nothing was left in the Trash.
# Blocked: an interpreter (python, node, perl, ruby, ...) anywhere in a command whose
# text calls a deletion API; `rm` inside a quoted sh -c / eval body (not rewritten);
# find -delete, unlink, shred, srm, rm -P, rimraf and git clean -f in command position,
# heredoc bodies included. It reads TEXT, coarsely, after four review rounds in which a
# shell parser here kept missing new spellings: it over-blocks text that merely names
# these calls next to an interpreter word, and still misses a script FILE an
# interpreter runs, rsync --delete, mv/cp over a file, truncation, and code assembled
# at runtime. A net, not a wall.
# Escape hatch for a human decision: MEGAVIBE_ALLOW_REAL_DELETE=1 in the environment
# Claude Code runs with. Deliberately not an inline prefix: the agent that would reach
# for it is the one this guard exists to stop.
# ---------------------------------------------------------------------------
# Relevance gate (hooks fire on every call): python starts for a deleting word or any
# interpreter name. A superset of what the parser below detects, never a filter of
# its own: a narrower gate let `fs.rm(` and `'/bin/rm'` through in review.
_rd_gate() {
  local bsnl=$'\\\n'    # bash 3.2 does not expand $'..' inside a ${//} pattern: via a variable
  local c="${COMMAND//"$bsnl"/}"
  # a continuation inside a word (r\<newline>m) joins into an rm rm-to-trash.sh never sees
  [ "$c" != "$COMMAND" ] && printf '%s' "$c" | grep -Eq '(^|[^[:alnum:]_.-])rm([^[:alnum:]_.-]|$)' && return 0
  printf '%s' "$c" | grep -Eq -- '-delete|unlink|clean|shred|srm|rimraf|(^|[[:space:]])-[[:alnum:]]*P|=["'\'']?[^[:space:]]*rm|[\\"'\'']rm|r[\\"'\'']+m|[\"'\''][^[:space:]]*/rm[\"'\'']|which rm|(command|type)[[:space:]]+-[[:alpha:]]*[vVpP][[:alpha:]]*[[:space:]]+rm|git[^;|&]* rm|[[:space:]]-([[:alpha:]]*[xX]|-exec|-exec-batch)[[:space:]]' && return 0
  printf '%s' "$c" | grep -Eq '(^|[^[:alnum:]_])(python[0-9.]*|pypy[0-9.]*|node|nodejs|deno|bun|perl|ruby|php|lua|osascript|awk|gawk|mawk|sh|bash|zsh|dash|ksh|tcsh|csh|fish|eval|trap|env|xargs|parallel|source)([^[:alnum:]_]|$)' \
    && printf '%s' "$c" | grep -Eiq 'rm|remove|unlink|delete|empty'     # every pattern below contains one of these
}
# Only where deletes go to the Trash at all: without rmtrash, rm-to-trash.sh is inert, `rm`
# deletes for real, and blocking the other forms would only push agents to that rm.
_rd_trash_ready() { command -v rmtrash &>/dev/null; }      # the same condition rm-to-trash.sh uses
if [ "${MEGAVIBE_ALLOW_REAL_DELETE:-0}" != "1" ] && command -v python3 &>/dev/null && _rd_trash_ready && _rd_gate; then
  read -r -d '' _RD_PY <<'PY' || true
import re, signal, sys

# Coarse on purpose. Six review rounds of finer checks here each found new spellings, so
# this reads the command TEXT and blocks on co-occurrence. Heredoc bodies count only when a
# shell or interpreter consumes them (a commit message written through `cat <<EOF` is
# prose); quoted text counts only when a shell, eval, trap, env -S, parallel or awk runs it.
# A pathological input that makes the patterns slow is blocked, never let through.
signal.signal(signal.SIGALRM, lambda *a: (print("a command too complex to check (guard timed out)"), sys.exit(0)))
signal.alarm(2)

ORIG = sys.stdin.read()

INTERP_W = r"(?:python[0-9.]*|pypy[0-9.]*|node|nodejs|deno|bun|perl|ruby|php|lua|osascript|awk|gawk|mawk)"
SHELL_W = r"(?:sh|bash|zsh|dash|ksh|tcsh|csh|fish|eval|trap|parallel|source|awk|gawk|mawk)"   # not xargs: it runs no shell
INTERP = re.compile(r"(^|[^\w.-])" + INTERP_W + r"(?![\w/-])")          # python/ is a directory
SHELLISH = re.compile(r"(^|[^\w.-])" + SHELL_W + r"(?![\w/-])|\benv\s+(?:-\S+\s+)*(?:-S|--split-string)")
DEL_API = re.compile(
    r"shutil\.rmtree|\brmtree\b|remove_tree|\brimraf\b|\bremoveSync\b|\bemptyDirSync\b"
    r"|\bos\.(remove|unlink|rmdir|removedirs)\b|\.unlink\(|\.rmdir\("
    r"|\b(unlinkSync|rmSync|rmdirSync)\b|\bfs(\.promises)?\.(rm|unlink|rmdir)\s*\(|Deno\.remove"
    r"|FileUtils\.(rm|remove)|File\.(delete|unlink)|\bunlink\s*[\s(]|\brmdir\s*[\s(]"
    r"|[\x27\"](/usr/bin/|/bin/)?rm[\x27\"]\s*[,\]]|[\x27\"`]\s*(/usr/bin/|/bin/)?rm(\s|[\x27\"`]|$)"
    r"|\bsystem\s*\([^)]*\brm\b|array_map\s*\(\s*[\x27\"]unlink"
    r"|\bfrom\s+(os|shutil|pathlib)\s+import\b[^\n;]*(\b(remove|unlink|rmdir|removedirs|rmtree)\b|\*)"
    r"|__import__\(\s*[\x27\"](os|shutil)[\x27\"]\s*\)\s*\.\s*(remove|unlink|rmdir|removedirs|rmtree)"
    r"|getattr\(\s*(os|shutil)\s*,\s*[\x27\"](remove|unlink|rmdir|removedirs|rmtree)"
    r"|(fs|fs/promises|fs-extra)[\x27\"].*?\b(rm|unlink|rmdir|remove|emptyDir)\s*\("
    r"|\)\s*\.\s*(rm|rmSync|unlink|unlinkSync|rmdir|rmdirSync)\s*\(", re.S)
RM_WORD = r"(?<![\w.-])\\?rm(?![\w.-])"


def scan_line(line, st):
    """(the line without a comment, the quote state at its end, outside[i] per kept char).
    The state (open quote, stack of enclosing quotes) is carried from the previous command
    line, so a `#` inside a multi-line string is not a comment; `#` inside ${...} is not one
    either. A $( ) inside double quotes starts afresh: `"$(cat <<'EOF'` opens a real heredoc."""
    q, stack = st
    stack = list(stack)
    outside, i, brace = [], 0, 0
    while i < len(line):
        c = line[i]
        if q == "\x27":
            outside.append(False); q = None if c == "\x27" else q; i += 1; continue
        if q == "\"":
            if c == "\\" and i + 1 < len(line):
                outside += [False, False]; i += 2; continue
            if c == "$" and line[i + 1:i + 2] == "(":
                stack.append(["\"", 0]); q = None
                outside += [True, True]; i += 2; continue
            outside.append(False); q = None if c == "\"" else q; i += 1; continue
        if stack and c == "(":
            stack[-1][1] += 1
        elif stack and c == ")":
            if stack[-1][1] == 0:
                q = stack.pop()[0]; outside.append(True); i += 1; continue
            stack[-1][1] -= 1
        if c == "\\":
            outside += [True] * min(2, len(line) - i); i += 2; continue
        if c in "\x27\"":
            q = c; outside.append(False); i += 1; continue
        if c == "$" and line[i + 1:i + 2] == "{":
            brace += 1
        elif c == "}" and brace:
            brace -= 1
        elif c == "#" and not brace and (i == 0 or line[i - 1] in " \t;&|()"):
            return line[:i], (q, stack), outside      # a comment ends the line, a trailing \ included
        outside.append(True); i += 1
    return line, (q, stack), outside


def split_heredocs(text):
    """(command lines, executed heredoc bodies, substitutions in prose heredoc bodies)."""
    out, exe, subs, pending, q = [], [], [], [], (None, [])
    rows = text.split("\n")
    for n, line in enumerate(rows):
        if pending:
            marker, runs, expands = pending[0]
            if line.strip() == marker:
                pending.pop(0)
            elif runs:
                exe.append(line)
            elif expands:
                subs.extend(substitutions(line, heredoc=True))
            continue
        line, q, outside = scan_line(line, q)
        out.append(line)
        for m in re.finditer(r"(?<!<)<<(?!<)-?\s*(\\?[\x27\"]?)([^\s;|&<>()\x27\"]+)[\x27\"]?", line):
            if not outside[m.start()]:          # "a << Q" inside quotes is not a heredoc
                continue
            # Only a real heredoc if a LATER line is exactly the marker (as rm-to-trash.sh
            # checks): `$((1 << SHIFT))` or "a << b" in a message must not swallow what follows.
            if not any(r.strip() == m.group(2) for r in rows[n + 1:]):
                continue
            # The consumer may come before `<<` or after it (`cat <<EOF | bash`, `<<EOF bash`),
            # or on the line after the terminator when this line ends in a pipe: then assume it runs.
            u = unquoted(line)
            runs = bool(re.search(r"(^|[^\w.-])(" + SHELL_W + r"|" + INTERP_W + r")(?![\w-])", u)) or u.rstrip().endswith("|")
            pending.append((m.group(2), runs, not m.group(1)))
    return "\n".join(out), "\n".join(exe), subs


def quoted_mask(text, single_only=False):
    """inside[i]: whether text[i] sits inside a quoted string. A backslash-escaped quote
    (don\'t) opens nothing. single_only: only single quotes, the ones that stop $( )."""
    inside = [False] * len(text)
    for m in re.finditer(r"\\.|\x27[^\x27]*\x27|\"(?:[^\"\\]|\\.)*\"", text):
        if m.group(0)[0] == "\\" or (single_only and m.group(0)[0] == "\""):
            continue
        for k in range(m.start() + 1, m.end() - 1):
            inside[k] = True
    return inside


def unquoted(text):
    """The text with quoted strings blanked: what the shell itself parses as words. A quoted
    option word ('-delete', "-fd") is still that option, so it is kept, unquoted."""
    t = re.sub(r"([\x27\"])(-[\w-]+)\1", r"\2", text)
    t = re.sub(r"\x27[^\x27]*\x27", "\x27\x27", t)
    return re.sub(r"\"(?:[^\"\\]|\\.)*\"", "\"\"", t)


def substitutions(text, heredoc=False):
    """$( ) and backtick bodies outside single quotes: they run even inside double quotes.
    In an unquoted heredoc body quotes are plain characters, so nothing is masked there."""
    # single-quoted text blanked at the SAME length, so positions still index the original
    nosq = text if heredoc else re.sub(r"\x27[^\x27]*\x27", lambda m: "\x27" + " " * (len(m.group(0)) - 2) + "\x27", text)
    found, i = [], 0
    while True:
        i = nosq.find("$(", i)
        if i < 0: break
        d, j = 1, i + 2
        while j < len(nosq) and d:
            d += {"(": 1, ")": -1}.get(nosq[j], 0); j += 1
        found.append(text[i + 2:j - 1]); i += 2      # the ORIGINAL text: quoted programs inside stay readable
    found += [text[m.start(1):m.end(1)] for m in re.finditer(r"(?<!\\)`([^`]*)`", nosq)]   # \` is a literal backtick
    return found


CMDPOS = (r"(?:^|[;&|(`\n{!\x27\"]|\$\(|\b(?:if|elif|while|until|then|do|else|xargs|exec|env|sudo|doas|nohup|time|command|builtin|nice|ionice|timeout|stdbuf|caffeinate|arch|xcrun)\s+(?!\s)(?:-\S+\s+(?!\s)(?:[^-\s]\S*\s+(?!\s))?)*|\s-(?:exec|execdir|ok|okdir)\s+(?!\s))"
          r"[ \t]*(?:\w+=\S*\s+(?!\s)|\d*[<>]+&?\d*[^\s;|&()<>]*\s+(?!\s))*(?:\S*/)?")


def git_clean_forced(args):
    """True unless a dry run: `git -c clean.requireForce=false clean -d` deletes without -f."""
    w, force, dry, i = args.split(), False, False, 0
    while i < len(w):
        x = w[i]
        if x == "--": break
        if x in ("-e", "--exclude"): i += 2; continue
        if x.startswith("--"):
            force |= x == "--force"; dry |= x == "--dry-run"; i += 1; continue
        if x.startswith("-"):
            step = 1
            for k, ch in enumerate(x[1:]):          # a short cluster, left to right
                if ch == "e":                        # -e takes the rest of the word, or the next word
                    step = 2 if k == len(x) - 2 else 1
                    break
                force |= ch == "f"; dry |= ch == "n"
            i += step; continue
        i += 1
    return not dry


# xargs and the options before the command it runs (some take a value: -n 1, -I {}, -d ';').
XARGS_CMD = (r"\bxargs\b(?:\s+(?:-[0-9A-Za-z]*[nPLIdEsaJRS]\s*(?:\x27[^\x27]*\x27|\"[^\"]*\"|[^\s\x27\"]\S*)"
             r"|--[\w-]+(?:=\S*)?|-\S+))*\s+"
             # wrappers it may run first: xargs sudo unlink, xargs -0 nice unlink, xargs env X=1 unlink
             r"(?:(?:\S*/)?(?:sudo|doas|nice|ionice|env|command|time|nohup|timeout|stdbuf|caffeinate|arch|xcrun)\s+"
             r"(?:-\S+\s+|\w+=\S*\s+|\d+[smhd]?\s+)*)*")


def shell_text_reasons(t):
    if re.search(r"\bg?find\b(?:\\;|[^;|&\n])*\s-delete\b", t):
        return "find -delete"
    m = re.search(CMDPOS + r"(unlink|shred|srm)\s+\S", t)
    if m:
        return m.group(1)
    m = re.search(XARGS_CMD + r"[\\\x27\"]*(?:\S*/)?(unlink|shred|srm)[\x27\"]*(?![\w.-])", t)
    if m:
        return "xargs " + m.group(1) + " (its operands arrive on stdin)"
    m = re.search(r"\bparallel\b[^;|&\n]*?(?<![\w./-])(?:\S*/)?(unlink|shred|srm)(?![\w.-])", t)
    if m:
        return "parallel " + m.group(1) + " (its operands arrive on stdin)"
    m = re.search(r"\bfd(?:find)?\b[^;|&\n]*\s(?:-[A-Za-z]*[xX]|--exec|--exec-batch)\s+[\\\x27\"]*(?:\S*/)?(rm|unlink|shred|srm)[\x27\"]*(?![\w.-])", t)
    if m:
        return "fd -x " + m.group(1) + " (fd runs it directly, so it is not rewritten to the Trash)"
    if re.search(CMDPOS + r"\\?rm\s+(?:-\w+\s+)*-[A-Za-z]*P", t):
        return "rm -P (overwrite)"
    if re.search(CMDPOS + r"(?:(?:npx|bunx|yarn|pnpm\s+(?:dlx|exec)|npm\s+exec)\s+(?:-\S+\s+)*)?rimraf\b", t):
        return "rimraf"
    for m in re.finditer(r"\bgit\s+(?:-\S+\s+(?:\S+\s+)?)*rm\b([^;&|\n]*)", t):
        a = m.group(1).split()
        if "--cached" not in a and any(x == "--force" or re.match(r"^-[A-Za-z]*f", x) for x in a if x.startswith("-")):
            return "git rm -f (drops uncommitted changes; plain git rm or git rm --cached is fine)"
    for m in re.finditer(r"\bgit\s+(?:-[Cc]\s+\S+\s+|--?\S+\s+)*clean\b([^;&|\n]*)", t):
        if git_clean_forced(m.group(1)):
            return "git clean (anything but a dry run -n deletes)"
    return None


def interp_runs_deleter(raw):
    """An interpreter's subprocess strings that run a protected deleter."""
    norm = re.sub(r"[\x27\"\[\],()]", " ", raw)
    if re.search(r"\bg?find\b", norm) and re.search(r"(?<![\w-])-delete\b", norm):
        return "find -delete"
    m = re.search(r"\b(unlink|shred|srm)\s+[-\w./~$]", norm)
    if m:
        return m.group(1)
    m = re.search(r"\bgit\s+clean\b([^\n;]*)", norm)
    if m and git_clean_forced(m.group(1)):
        return "git clean -f"
    return None


def reasons(raw, depth=0):
    if depth > 3:
        return None
    lines, exe, prose_subs = split_heredocs(raw)
    # Comments are already gone (a comment ending in \ does not continue), so joining line
    # continuations now cannot pull the next line into a comment.
    split = lines
    raw, lines, exe = (x.replace("\\\n", "") for x in (raw, lines, exe))
    if len(re.findall(RM_WORD, lines)) > len(re.findall(RM_WORD, split)):
        return "rm split by a line continuation, which is not rewritten to the Trash"
    outer = unquoted(lines)
    shell = bool(SHELLISH.search(outer) or SHELLISH.search(exe) or re.search(r"\|\s*(?:sudo\s+)?(?:\S*/)?(?:sh|bash|zsh|dash|ksh)\b", outer))
    interp = INTERP.search(outer) or INTERP.search(exe) or (shell and INTERP.search(lines))
    if interp:
        who = interp.group(0).strip(" \t;&|(`\n{!\x27\"")
        m = DEL_API.search(raw)
        if m:
            return who + " in a command whose text calls a deletion (" + " ".join(m.group(0).split())[:60] + ")"
        for a in re.finditer(r"\bimport\s+(?:os|shutil)\s+as\s+(\w+)", raw):
            if re.search(r"\b" + re.escape(a.group(1)) + r"\.(remove|unlink|rmdir|removedirs|rmtree)\b", raw):
                return "an interpreter that deletes files directly (" + a.group(1) + ".remove)"
        r = interp_runs_deleter(raw)
        if r:
            return "an interpreter that runs " + r
    if shell:
        # rm the shell runs from text rm-to-trash.sh cannot rewrite: quoted text, an executed
        # heredoc, an eval/trap argument, or text piped into a shell.
        if len(re.findall(RM_WORD, lines)) + len(re.findall(RM_WORD, exe)) > len(re.findall(RM_WORD, outer)):
            sm = SHELLISH.search(outer) or SHELLISH.search(exe)
            who = sm.group(0).strip(" \t;&|(`\n{!") if sm else "a shell"
            return "rm inside quoted text or a heredoc, with " + who + " in the command to run it, where it is not rewritten to the Trash"
        if re.search(r"\b(?:eval|trap)\s+(?:\S+\s+)*?" + RM_WORD, outer):
            return "rm run through eval or trap, where it is not rewritten to the Trash"
        if re.search(RM_WORD + r"[^|\n]*\|\s*(?:sudo\s+)?(?:\S*/)?(?:sh|bash|zsh|dash|ksh)\b", outer):
            return "rm text piped into a shell, where it is not rewritten to the Trash"
    # rm spelled so that rm-to-trash.sh does not recognise it: quoted, escaped, held in a
    # variable or looked up. Checked on the text with its quotes, since the quotes are the trick.
    qrm = quoted_mask(lines)
    if any(not qrm[m.start()] for m in re.finditer(
                 r"(?:^|[;&|(`\n{!]|\$\(|\s-(?:exec|execdir|ok|okdir)(?=\s))\s*(?:\w+=\S*\s+)*"
                 r"(?:(?:command(?!\s+-[vV])|builtin|exec|sudo|doas|nice|env|nohup|time)\s+(?:-\S+\s+)*)*"
                 r"(?!\\rm\s)(?=\S*[\\\x27\"])[\\\x27\"]*(?:[\w.-]*/)*[\\\x27\"]*r[\\\x27\"]*m[\x27\"]*(?:\s|$)", lines)) \
            or re.search(XARGS_CMD + r"(?=\S*[\\\x27\"])[\\\x27\"]*(?:\S*/)?r[\\\x27\"]*m[\x27\"]*(?:\s|$)", lines):
        return "a quoted or escaped rm, which is not rewritten to the Trash"
    inq, insq = quoted_mask(lines), quoted_mask(lines, single_only=True)
    # $(which rm) runs wherever $( ) runs: outside single quotes and not escaped as \$(
    for m in re.finditer(r"(?<!\\)(?:\$\(|`)\s*(?:which|command\s+-[vV]|type\s+-[pP])\s+rm\s*[)`]", lines):
        if not insq[m.start()]:
            return "rm through a lookup ($(which rm)), which is not rewritten to the Trash"
    for m in re.finditer(r"(?:^|[;&|\s])(\w+=)[\x27\"]?(?:\S*/)?rm(?:[\x27\"\s;)]|$)", lines):
        if not inq[m.start(1)]:
            return "rm through a variable, which is not rewritten to the Trash"
    m = re.search(XARGS_CMD + r"[\\\x27\"]+(?:\S*/)?(unlink|shred|srm)[\x27\"]*(?![\w.-])", lines)
    if m:                              # a quoted deleter as the command xargs runs
        return "xargs " + m.group(1) + " (its operands arrive on stdin)"
    for t in [outer, exe] + ([lines] if shell else []):
        r = shell_text_reasons(t)
        if r:
            return r
    for sub in substitutions(lines) + prose_subs:
        r = reasons(sub, depth + 1)
        if r:
            return r
    return None


r = reasons(ORIG)
if r:
    print(r)
PY
  _RD=$(printf '%s' "$COMMAND" | python3 -c "$_RD_PY" 2>/dev/null || true)
  if [ -n "$_RD" ]; then
    echo "Blocked: a real delete that skips the Trash: $_RD." >&2
    echo "Use rm on the command line itself (with rmtrash installed it goes to the Trash and is recorded for review), or call ~/.megavibe/scripts/trash.sh from the code. A glob or rmtree over a scratch directory has destroyed finished work for good before." >&2
    echo "If this is only text (a commit message, a note), run it as its own Bash call, or write it to a file with the Write tool and pass the file (git commit -F, gh pr create --body-file). If a human has decided the delete must be unrecoverable, they set MEGAVIBE_ALLOW_REAL_DELETE=1 in Claude Code's environment." >&2
    exit 2
  fi
fi

exit 0
