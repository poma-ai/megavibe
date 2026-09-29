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
# hatch on purpose: a human empties it in Finder. Reads (ls, du), restoring one
# file with mv, and text that merely mentions these words (commit messages, grep
# patterns, PR bodies) are untouched.
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

exit 0
