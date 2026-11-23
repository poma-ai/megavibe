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

# A formatter at the end of a pipeline otherwise hides the check's status from
# the following destructive command. Keep this gate fork-free and before the
# slower Python parser. Mask quoted text so commit messages remain prose.
# Most commands fail the fork-free prefilter; only candidates pay one perl call.
_PIPE_TEXT=''
if [[ "$COMMAND" == *'|'* && ( "$COMMAND" == *push* || "$COMMAND" == *commit* || "$COMMAND" == *merge* ) ]] && command -v perl >/dev/null 2>&1; then
  # A backslash-newline continuation becomes two spaces (same length, so offsets map back to COMMAND);
  # quoted text becomes Q, not spaces, so a quoted path such as "$PWD" still leaves a token for the pattern.
  _PIPE_TEXT=$(printf '%s' "$COMMAND" | perl -0777 -pe 's/\\\n/  /g; s/\\.|'"'"'[^'"'"']*'"'"'|"(?:\\.|[^"\\])*"/"Q" x length($&)/gse' 2>/dev/null) || _PIPE_TEXT=''
  # A newline ends a command, as ';' does.
  _PIPE_TEXT=${_PIPE_TEXT//$'\n'/;}
fi
# Only an && after the formatter counts: after ; the destructive command does not depend on the pipeline.
# The pipe is a single | (not ||): the character before it must not be a pipe.
_PIPE_DANGER='(^|[;])[[:space:]]*[^;]*[^|]\|&?[[:space:]]*(tail|head|grep|sed|awk|cut|sort|uniq|wc|tee|jq|rg|tr|cat)([[:space:]][^;|]*)?[[:space:]]*\&\&[[:space:]]*(cd[[:space:]]+[^;&|]*\&\&[[:space:]]*)*(git[[:space:]]+(-C[[:space:]]+[^[:space:];&|]+[[:space:]]+)?(push|commit)|gh[[:space:]]+pr[[:space:]]+merge)([[:space:];&|]|$)'
# A pipefail set in the same segment or an earlier one; a newline, { or ( may start that segment too.
_PIPEFAIL='(^|[;&{(])[[:space:]]*set[[:space:]]+[^;|&]*-[a-zA-Z]*o[[:space:]]*pipefail'
if [[ "$_PIPE_TEXT" == *'|'* && "$_PIPE_TEXT" =~ $_PIPE_DANGER ]]; then
  _m=${BASH_REMATCH[0]}
  # Only a pipefail set before the pipeline counts (same segment or earlier).
  _pre="${_PIPE_TEXT%%"$_m"*}${_m%%|*}"
  if [[ ! "$_pre" =~ $_PIPEFAIL ]]; then
    # An explicit PIPESTATUS check between the formatter and git is the status check itself.
    _mpipe=${_m%%|*}
    _between=${COMMAND:${#_pre}:$(( ${#_m} - ${#_mpipe} ))}
    # Every push, commit or merge in the && chain after the formatter must be a dry run to pass
    # (--dry-run; for push also -n, alone or in a short-option cluster; commit -n skips hooks).
    _chain=${_PIPE_TEXT#*"$_mpipe"}; _chain=${_chain#*|}; _chain=${_chain%%;*}
    _live=0; _cmd=''
    while [ -n "$_chain" ]; do
      _cmd=${_chain%%&&*}
      if [ "$_cmd" = "$_chain" ]; then _chain=''; else _chain=${_chain#*&&}; fi
      if [[ " $_cmd " =~ [[:space:]]gh[[:space:]]+pr[[:space:]]+merge[[:space:]] ]]; then _live=1; break; fi
      if [[ " $_cmd " =~ [[:space:]]git([[:space:]].*)?[[:space:]](push|commit)[[:space:]] ]]; then
        _verb=${BASH_REMATCH[2]}
        if [[ " $_cmd " == *" --dry-run "* ]]; then continue; fi
        if [ "$_verb" = push ] && [[ " $_cmd " =~ [[:space:]]-[a-zA-Z]*n[a-zA-Z]*[[:space:]] ]]; then continue; fi
        _live=1; break
      fi
    done
    if [[ "$_between" != *PIPESTATUS* && $_live = 1 ]]; then
      echo 'Blocked: capture the status first (check; rc=$?), or set -o pipefail;' >&2
      exit 2
    fi
  fi
fi

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
# It is the one deleting path. What gates it is Claude Code's permission prompt (setup.sh
# installs `permissions.ask` rules; an ask rule is honoured under bypassPermissions and is
# forwarded to the phone). What keeps that gate from being walked around is the script
# itself: it runs only when the Claude Code shell above it was asked for exactly
# `~/.megavibe/scripts/trash-empty.sh [--all]` (README, "Trash greenlight"). A spelling that
# reaches the file without the ask rules matching (a glob, a symlinked directory, a variable,
# `cd` first) is therefore harmless: the script exits 5 before it touches anything.
#
# This block is only the first net, so the agent gets a clear message here instead of a
# refusal later, and only the reviewed spelling reaches the prompt:
#   - the exact command, alone in the call: exit 0 here (no permission decision is made; the
#     ask rule prompts next). It also keeps the crude no-python fallback below from refusing it;
#   - any other command whose text names the script (trash-empty, trash-em*, trash-e*; quotes,
#     backslashes, brackets, braces and newlines ignored, case ignored): blocked;
#   - a home-anchored path whose first part is a glob that could complete to .megavibe and
#     that goes on below it (~/.m*/scripts/x, ~/.meg?vibe/x): blocked; a plain `ls -d ~/.m*` passes;
#   - osascript, launchctl, crontab or a new Terminal window that mentions ~/.megavibe or the
#     script: blocked (they start a process outside Claude Code's process tree; the script
#     refuses those anyway). `launchctl list | grep com.megavibe` is not a mention.
# HACK: a net, not a wall. Known holes: a name assembled from pieces the text never shows
# together, a script FILE that calls it; the script itself is the lock for both.
# Known over-blocks: any Bash text that names the script is refused, including `git add
# scripts/trash-empty.sh`, `bash -n`, `grep`, `cat` and a commit message that mentions it; use
# the Read and Grep tools, `git add scripts/` (the directory), a loop over the directory for
# lint, `git commit -F file`.
# ---------------------------------------------------------------------------
_TE=$(printf '%s' "$COMMAND" | tr -d "\"'\\\\[]{},\n" | tr '[:upper:]' '[:lower:]')
_TE_RAW=$(printf '%s' "$COMMAND" | tr '[:upper:]' '[:lower:]')
case "$_TE|$_TE_RAW" in
  *trash-e*|*/.m*|*launchctl*|*osascript*|*osacompile*|*crontab*|*terminal*|*iterm*)
    _TE_EXACT='^[[:space:]]*~/\.megavibe/scripts/trash-empty\.sh( --all)?[[:space:]]*$'
    if [[ $COMMAND =~ $_TE_EXACT ]]; then
      exit 0
    fi
    _TE_WHY=""
    if printf '%s' "$_TE" | grep -Eq 'trash-e(m|[*?]|[^a-z0-9]|$)'; then
      _TE_WHY="names trash-empty.sh"
    elif printf '%s' "$_TE_RAW" | grep -Eq '(^|[[:space:]=:("'"'"'])(~|\$\{?home\}?|/users/[^[:space:]/]+)/\.(m|me|meg|mega|megav|megavi|megavib)[*?][^[:space:]]*/'; then
      _TE_WHY="has a path whose first part is a glob that could expand to ~/.megavibe"
    elif printf '%s' "$_TE_RAW" | grep -Eq '(osascript|osacompile|launchctl|crontab|(^|[[:space:];&|(])open[[:space:]].*(terminal|iterm))' \
         && printf '%s' "$_TE_RAW" | grep -Eq '[/~]\.megavibe|trash-e'; then
      _TE_WHY="starts a process outside Claude Code that mentions ~/.megavibe or trash-empty.sh"
    fi
    if [ -n "$_TE_WHY" ]; then
      echo "Blocked: this command $_TE_WHY. ~/.megavibe/scripts/trash-empty.sh may only be run exactly as typed, alone in the call, so Claude Code asks the user first. To read it use the Read tool; to name it in a commit message use git commit -F." >&2
      exit 2
    fi
    ;;
esac

# A PermissionRequest hook is run by Claude Code instead of asking the user, and can answer Yes: it
# would answer the prompt in front of trash-empty.sh without the human. block-permission-hooks.sh
# refuses the Write/Edit route; this is the Bash route (jq, a redirect, sed -i) as a text rule.
# Over-block: any Bash text that mentions PermissionRequest next to a settings or hooks file, even
# to read it (use the Read and Grep tools). Not covered: an interpreter that assembles the name.
case "$_TE_RAW" in
  *permissionrequest*)
    case "$_TE_RAW" in
      *settings*|*hooks.json*|*/.claude/*)
        echo "Blocked: this command mentions PermissionRequest next to a Claude Code settings or hooks file. A PermissionRequest hook answers permission prompts for the user (including the one in front of ~/.megavibe/scripts/trash-empty.sh), so it is not something to write on the user's behalf; to read one use the Read or Grep tool." >&2
        exit 2 ;;
    esac ;;
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
# the remote-control sessions, the Personal Assistant, and the context
# watchers. A prose prohibition in the brief is not a sandbox
# (same class as the `git rm -f` incident of 2026-10-08).
#
# Blocked when they are the command: pkill, killall, `tmux kill-server|kill-session|
# kill-window|kill-pane`, `launchctl bootout|unload|remove|stop|kill|disable|bootstrap`
# and `launchctl kickstart -k`. NOT blocked: `kill <pid>` (a PID you started),
# `tmux ls|new|send-keys|capture-pane|attach`, `launchctl list|print|kickstart`, and
# `launchctl bootstrap gui/<uid> ~/Library/LaunchAgents/<name>.plist` (loading a user agent
# stops nothing; any other bootstrap form stays blocked).
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

def user_agent_bootstrap(argv):
    # bootstrap gui/UID ~/Library/LaunchAgents/NAME.plist only LOADS a user agent (stops
    # nothing): exactly one user-domain target and one plist file directly under the user own
    # LaunchAgents folder, no option, no dotdot. A system domain, a LaunchDaemons path, a
    # second plist or anything else stays blocked.
    rest = argv[2:]
    cut = next((k for k, x in enumerate(rest) if re.match(r"^[0-9]*[<>&]", x)), None)
    if cut is not None:
        if not all(re.match(r"^([0-9]*[<>&]+|/dev/null|[0-9]+)$", x) for x in rest[cut:]): return False
        rest = rest[:cut]
    if len(rest) != 2 or any(x.startswith("-") for x in rest): return False
    dom, path = rest
    m = re.match(r"^(gui|user)/([0-9]+)$", dom)
    if not m or int(m.group(2)) != os.getuid(): return False
    home = os.path.expanduser("~")
    if path.startswith("~/"): path = home + path[1:]
    elif path.startswith("$HOME/"): path = home + path[5:]
    if ".." in path.split("/") or not re.match(r"^[A-Za-z0-9._/ -]+$", path): return False
    pre = home + "/Library/LaunchAgents/"
    if os.path.exists(path) and not os.path.realpath(path).startswith(os.path.realpath(pre) + "/"): return False
    return path.startswith(pre) and path.endswith(".plist") and "/" not in path[len(pre):] and len(path) > len(pre) + 6

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
                if b == "env" and re.match(r"^-[A-Za-z]*S", opt) and any("launchctl" in x for x in argv[i:]): return True   # env -S runs a split string: not parsed here, so blocked
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
        if v == "bootstrap": return not user_agent_bootstrap(argv)
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
  # worktree + remove in any quoting (git "worktree" remove): a bash pattern, no fork
  # _TE is the command with quotes, backslashes and brackets already out (wor"ktree" spells
  # worktree too): no second pass over the text, a per-character ${//} is quadratic in bash 3.2
  [[ $_TE == *worktree* && $_TE == *remove* ]] && return 0
  printf '%s' "$c" | grep -Eq -- '-delete|unlink|clean|shred|srm|rimraf|(^|[[:space:]])-[[:alnum:]]*P|=["'\'']?[^[:space:]]*rm|[\\"'\'']rm|r[\\"'\'']+m|[\"'\''][^[:space:]]*/rm[\"'\'']|which rm|(command|type)[[:space:]]+-[[:alpha:]]*[vVpP][[:alpha:]]*[[:space:]]+rm|git[^;|&]* rm|[[:space:]]-([[:alpha:]]*[xX]|-exec|-exec-batch)[[:space:]]' && return 0
  printf '%s' "$c" | grep -Eq '(^|[^[:alnum:]_])(python[0-9.]*|pypy[0-9.]*|node|nodejs|deno|bun|perl|ruby|php|lua|osascript|awk|gawk|mawk|sh|bash|zsh|dash|ksh|tcsh|csh|fish|eval|trap|env|xargs|parallel|source)([^[:alnum:]_]|$)' \
    && printf '%s' "$c" | grep -Eiq 'rm|remove|unlink|delete|empty'     # every pattern below contains one of these
}
# Only where deletes go to the Trash at all: without rmtrash, rm-to-trash.sh is inert, `rm`
# deletes for real, and blocking the other forms would only push agents to that rm.
_rd_trash_ready() { command -v rmtrash &>/dev/null; }      # the same condition rm-to-trash.sh uses
# ---------------------------------------------------------------------------
# Deletes on a remote host (ssh, sftp, rsync --delete towards a remote side).
#
# There is no Trash on the other side, and both delete guards used to treat the quoted
# remote command as an opaque argument: on 2026-11-15 an agent ran an approved log purge
# over ssh and appended an `rm -f` of a neighbouring file nobody had approved; nothing
# fired and the file was gone for good. A remote delete is therefore sent to the
# permission prompt (permissionDecision "ask") with the host and every deleted path
# named, so the human compares them with what they approved. Where no prompt can be
# shown (dontAsk, headless, measured 2026-11-15 on bypassPermissions/dontAsk/default with
# Bash allow-listed: the call is denied and the reason reaches the agent) it is a block.
# No environment escape hatch and no inline acknowledgement: either would be written by
# the agent this guard exists to stop. Moving files (mv into a dated quarantine folder
# on that host) is not a delete and passes.
# Read: the remote command (quoted or not, through sh -c, eval, trap, xargs, find -exec, $( )),
# a script sent on stdin to a remote shell (heredoc, here-string, `< file`, `cat file |`,
# `echo ... |`), sftp/lftp command text, rsync --delete/--remove-source-files with a remote side.
# A stdin script the guard cannot read (a variable path, another command's output) is asked
# about as well. The local real-delete check below still reads the whole command, as it always
# did: where it fires on a command that also deletes remotely (a shell or interpreter word
# outside the quotes, an unquoted remote find -delete) the call stays blocked, with a note on
# the form that reaches the prompt. HACK: a net, not a wall. Not covered: a script that already lives on the
# remote host, kubectl/docker exec payloads, scp/mv/redirects that overwrite, truncation,
# database statements, rclone and other clients, a command line assembled at runtime.
# ---------------------------------------------------------------------------
_RD_LOCAL=0; _RD_REMOTE=0
[ "${MEGAVIBE_ALLOW_REAL_DELETE:-0}" != "1" ] && _rd_trash_ready && _rd_gate && _RD_LOCAL=1
[[ $_TE == *ssh* || $_TE == *sftp* || $_TE == *lftp* || $_TE == *rsync* ]] && _RD_REMOTE=1      # _TE: quotes and backslashes out, lower case
_rd_remote_ask() {    # $1: the lines "host<TAB>what<TAB>paths"; prints the ask decision and ends the hook
  local why="Remote delete: no Trash on the other side, nothing here can be restored."$'\n' host what paths
  while IFS=$'\t' read -r host what paths; do
    [ -n "$what" ] && why+="- on ${host}: ${what}${paths:+: $paths}"$'\n'
  done <<< "$1"
  # the whole reason is capped, and says so: a prompt nobody can read protects nothing
  if [ "${#why}" -gt 16000 ]; then why="${why:0:16000}"$'\n'"[CUT: $(( ${#why} - 16000 )) more characters not shown, so this list is INCOMPLETE; read the command and any script it sends]"$'\n'; fi
  why+="An approval covers the paths named in it and nothing else: approve only if every line above is exactly what was asked for, and none is a file of unknown origin."$'\n'
  why+="Agent: if this was denied, do not respell it. Either move instead of deleting, which needs no approval (ssh HOST 'mkdir -p ~/.megavibe-quarantine/DATE && mv -n -- PATHS ~/.megavibe-quarantine/DATE/'), or name these exact paths to the user in chat and let them approve the prompt or run the command themselves."
  # through stdin, not an argument (a long reason does not fit an argument list); if jq fails, still ask
  printf '%s' "$why" | jq -Rs '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: .}}' 2>/dev/null \
    || printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Remote delete: this command deletes on a remote host, where nothing can be restored. The details could not be shown, so this prompt is INCOMPLETE: read the command and any script it sends before approving."}}'
  exit 0
}
_rd_cmd_text() {      # the command on one line for a fallback reason, capped, and saying so when it is cut
  local c; c=$(printf '%s' "$COMMAND" | tr '\t\n' '  ')
  if [ "${#c}" -gt 3000 ]; then c="${c:0:3000} [CUT: $(( ${#c} - 3000 )) more characters not shown, so this is INCOMPLETE; read the command itself]"; fi
  printf '%s' "the command, as written: $c"
}
if ! command -v python3 &>/dev/null && [ "$_RD_REMOTE" = 1 ] \
   && printf '%s' "$COMMAND" | grep -Eq '(^|[^[:alnum:]_.-])(rm|rmdir|unlink|shred)([^[:alnum:]_.-]|$)|-delete|--del|--remove-source'; then
  _rd_remote_ask "?"$'\t'"ssh, sftp, lftp or rsync next to a deleting word (python3 is missing, so the command was not parsed)"$'\t'"$(_rd_cmd_text)"
fi
if command -v python3 &>/dev/null && [ "$_RD_LOCAL$_RD_REMOTE" != 00 ]; then
  read -r -d '' _RD_PY <<'PY' || true
import os, re, shlex, signal, sys

# Coarse on purpose. Six review rounds of finer checks here each found new spellings, so
# this reads the command TEXT and blocks on co-occurrence. Heredoc bodies count only when a
# shell or interpreter consumes them (a commit message written through `cat <<EOF` is
# prose); quoted text counts only when a shell, eval, trap, env -S, parallel or awk runs it.
# A pathological input that makes the patterns slow is blocked, never let through.
LOCAL, REMOTE = os.environ.get("RD_LOCAL", "1") == "1", os.environ.get("RD_REMOTE") == "1"
signal.signal(signal.SIGALRM, lambda *a: (print("L\ta command too complex to check (guard timed out)" if LOCAL else
    "R\t?\ta command too complex to check: the guard timed out, so nothing was parsed and this prompt is INCOMPLETE\tthe command, as written: "
    + globals().get("ORIG", "").replace("\t", " ").replace("\n", "\\n")[:3000]), sys.exit(0)))
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
    w, force, dry, i = (args.split() if isinstance(args, str) else list(args)), False, False, 0
    while i < len(w):
        x = w[i]
        if x == "--": break
        if x == "-e" or (len(x) > 2 and "--exclude".startswith(x)): i += 2; continue
        if x.startswith("--"):                       # git accepts any unambiguous prefix: --f, --for
            force |= len(x) > 2 and "--force".startswith(x); dry |= len(x) > 2 and "--dry-run".startswith(x)
            i += 1; continue
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


WT_MSG = ("git worktree remove --force (it deletes the worktree's uncommitted, untracked and ignored files for good, "
          "outside the Trash; run git status --porcelain --ignored there, commit or move what matters, then "
          "rm -r <worktree>, which goes to the Trash, and git worktree prune)")
# git's global options that take a separate value; the other leading -x/--x words are flags or --opt=value.
GIT_VAL = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--exec-path", "--attr-source"}
SUDO_VAL = {"-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t",
            "--user", "--group", "--host", "--prompt", "--chdir", "--chroot"}
XARGS_VAL = {"-n", "-I", "-d", "-E", "-L", "-P", "-s", "-a", "-J", "-R", "-S"}
KEYWORDS = {"!", "{", "}", "if", "then", "else", "elif", "do", "while", "until"}
PUNCT = set("();&|<>")


def force_flag(args):
    """--force, any prefix of it from --f (git takes abbreviations), or a short cluster with f,
    before a `--`: after that every word is a path."""
    for x in args:
        if x == "--": return False
        if x.startswith("--"):
            if "--force".startswith(x.split("=")[0]): return True
        elif x.startswith("-") and "f" in x[1:]:
            return True
    return False


def git_reason(w):
    """Why the words after `git` delete for good, or None: skip the global options, then
    worktree remove / clean / rm."""
    i = 0
    while i < len(w):
        if w[i] in GIT_VAL: i += 2; continue
        if w[i].startswith("-"): i += 1; continue
        break
    if i >= len(w): return None
    sub, rest = w[i], w[i + 1:]
    if sub == "worktree":
        j = 0
        while j < len(rest) and rest[j].startswith("-") and rest[j] != "--": j += 1
        if j < len(rest) and rest[j] == "remove" and force_flag(rest[j + 1:]):
            return WT_MSG
    elif sub == "clean" and git_clean_forced(rest):
        return "git clean (anything but a dry run -n deletes)"
    elif sub == "rm" and force_flag(rest) and not any(len(x) > 2 and "--cached".startswith(x) for x in rest):
        return "git rm -f (drops uncommitted changes; plain git rm or git rm --cached is fine)"
    return None


class Cmd(list):
    """A simple command's words; .hs holds the texts of its here-strings (<<<)."""
    def __init__(self, *a):
        list.__init__(self, *a); self.hs = []


SHELL_NAMES = {"sh", "bash", "zsh", "dash", "ksh"}


def cmd_words(text):
    """The simple commands of a shell text as word lists. posix shlex, like the guards above:
    quotes and backslashes are resolved, so "git", \\git and 'worktree' are the words they spell.
    Separators end a command; redirection operators and their targets (and a bare fd number
    before them) are dropped."""
    t = text.replace("\n", " ; ").replace("`", " ( ")
    try:
        lx = shlex.shlex(t, posix=True, punctuation_chars=True)
        lx.whitespace_split = True; lx.commenters = ""
        toks = list(lx)
    except ValueError:
        return None          # unbalanced quote, trailing backslash: the caller decides
    cmds, cur, skip, hs = [], Cmd(), False, False
    for tok in toks:
        if skip:
            skip = False
            if hs: cur.hs.append(tok); hs = False
            continue
        if tok and set(tok) <= PUNCT:
            if tok == "<<<":
                skip = hs = True         # a here-string: its text is what a shell would run
            elif ("<" in tok or ">" in tok) and not tok.endswith("("):
                if cur and cur[-1].isdigit(): cur.pop()
                skip = True
            else:
                cmds.append(cur); cur = Cmd()
            continue
        cur.append(tok)
    cmds.append(cur)
    return [c for c in cmds if c]


def command_start(w):
    """Index of the command word after VAR=value, keywords and the wrappers command, builtin,
    exec, env, sudo, nice, nohup, time and xargs (with their options); None if none."""
    i, n = 0, len(w)
    while i < n:
        x = w[i]; b = os.path.basename(x)
        if re.match(r"[A-Za-z_]\w*\+?=", x) or x in KEYWORDS: i += 1; continue
        if b in ("timeout", "gtimeout"):
            i += 1
            while i < n and w[i].startswith("-"):
                i += 2 if w[i] in ("-s", "--signal", "-k", "--kill-after") else 1
            i += 1                                  # the duration
            continue
        if b in ("xcrun", "arch"):                      # macOS tool selection: xcrun [-sdk X] git, arch -arm64 git
            i += 1
            while i < n and w[i].startswith("-"):
                if w[i] in ("-sdk", "--sdk", "-toolchain", "--toolchain", "-e"): i += 2
                elif b == "xcrun" and w[i] in ("--find", "-f", "--show-sdk-path", "--show-sdk-version"): return None
                else: i += 1
            continue
        if b in ("stdbuf", "caffeinate"):
            vals = {"stdbuf": ("-i", "-o", "-e"), "caffeinate": ("-t", "-w")}[b]
            i += 1
            while i < n and w[i].startswith("-"): i += 2 if w[i] in vals else 1
            continue
        if b in ("command", "builtin", "exec", "nohup", "time"):
            i += 1
            if b == "exec" and i < n and w[i] == "-a": i += 2       # exec -a NAME
            while i < n and w[i].startswith("-"):
                if b == "command" and re.match(r"-[A-Za-z]*[vV]", w[i]): return None    # a lookup, not a run
                i += 2 if b == "time" and w[i] in ("-o", "-f", "--output", "--format") else 1
            continue
        if b == "env":
            i += 1
            while i < n:
                if w[i] in ("-u", "-C", "-S", "-P", "--unset", "--chdir", "--split-string"): i += 2
                elif w[i].startswith("-") or re.match(r"[A-Za-z_]\w*=", w[i]): i += 1
                else: break
            continue
        if b in ("sudo", "doas", "nice", "xargs"):
            vals = {"nice": {"-n", "--adjustment"}, "xargs": XARGS_VAL}.get(b, SUDO_VAL)
            i += 1
            while i < n and w[i].startswith("-"):
                i += 2 if w[i] in vals else 1
            continue
        return i
    return None


def walk_reason(text, shell=False, depth=0):
    """git worktree remove --force, git clean, git rm -f in command position of `text`.
    With a shell in the call, a quoted word that holds a command line is walked too."""
    words = cmd_words(text)
    if words is None:
        # Not parsable as shell (bash itself may still run it): fail closed on the one
        # combination this gate exists for.
        if re.search(r"worktree", text) and re.search(r"\bremove\b", text) and re.search(r"(?<!\S)(?:--f\w*|-[A-Za-z]*f)(?!\S)", text):
            return WT_MSG
        return None
    for w in words:
        i = command_start(w)
        if i is not None and os.path.basename(w[i]) == "git":
            r = git_reason(w[i + 1:])
            if r: return r
        # find runs its -exec/-execdir/-ok/-okdir command itself: walk that command too, through
        # the same wrappers ({} stays an operand: git -C {} worktree ...)
        if i is not None and os.path.basename(w[i]) in ("find", "gfind"):
            for k in range(i + 1, len(w) - 1):
                if w[k] in ("-exec", "-execdir", "-ok", "-okdir"):
                    sub = [x for x in w[k + 1:] if x not in (";", "+")]
                    j = command_start(sub)
                    if j is not None and os.path.basename(sub[j]) == "git":
                        r = git_reason(sub[j + 1:])
                        if r: return r
        # a shell reads its here-string as a script: bash <<< 'git worktree remove --force x'
        if i is not None and os.path.basename(w[i]) in SHELL_NAMES and depth < 3:
            for x in w.hs:
                r = walk_reason(x, True, depth + 1)
                if r: return r
        if shell and depth < 3:
            for x in w:
                if " " in x and "git" in x:
                    r = walk_reason(x, True, depth + 1)
                    if r: return r
    return None


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
    # Argument lists as string literals, one element each (a value may hold spaces, the list
    # may span lines, Black-style): ["git", "-C", "my dir", "worktree", "remove", "--force", "x"]
    nocom = re.sub(r"(\"(?:[^\"\\\n]|\\.)*\"|\x27(?:[^\x27\\\n]|\\.)*\x27)|#[^\n]*", lambda m: m.group(1) or "", raw)   # a # comment line between list elements
    for m in re.finditer(r"(?:(?:\"[^\"\n]*\"|\x27[^\x27\n]*\x27)\s*,\s*)+(?:\"[^\"\n]*\"|\x27[^\x27\n]*\x27)", nocom.replace("\\\"", "\"").replace("\\\x27", "\x27")):
        lits = [a if a else b for a, b in re.findall(r"\"([^\"\n]*)\"|\x27([^\x27\n]*)\x27", m.group(0))]
        for k, x in enumerate(lits):
            if os.path.basename(x) == "git":
                r = git_reason(lits[k + 1:])
                if r: return r
    toks = re.sub(r"[;|&<>`()]+", " ; ", norm.replace("\n", " ; ")).split()
    for k, t in enumerate(toks):                 # every git, not the first: a plain removal hides nothing
        if os.path.basename(t) == "git":
            args = []
            for y in toks[k + 1:]:
                if y == ";": break
                args.append(y)
            r = git_reason(args)
            if r: return r
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
    for t in (lines, exe):
        r = walk_reason(t, bool(shell))
        if r:
            return r
    for t in [outer, exe] + ([lines] if shell else []):
        r = shell_text_reasons(t)
        if r:
            return r
    for sub in substitutions(lines) + prose_subs:
        r = reasons(sub, depth + 1)
        if r:
            return r
    return None


# --- Deletes on a remote host -------------------------------------------------------------
SSH_VAL = set("-B -b -c -D -E -e -F -I -i -J -L -l -m -O -o -P -p -Q -R -S -W -w".split())
SFTP_VAL = set("-B -b -c -D -F -i -J -l -o -P -R -S -s -X".split())
RSYNC_VAL = {"-e", "--rsh", "--exclude", "--include", "-f", "--filter", "--files-from", "--exclude-from", "--include-from",
             "--backup-dir", "--suffix", "-T", "--temp-dir", "--log-file", "--partial-dir", "--compare-dest", "--copy-dest",
             "--link-dest", "--bwlimit", "--port", "--password-file", "--rsync-path", "--chown", "--chmod", "-M",
             "--remote-option", "--max-size", "--min-size", "--timeout", "--out-format", "--info", "--debug", "--max-delete",
             "-B", "--block-size", "--contimeout", "--address", "--sockopts", "--iconv", "--checksum-seed",
             "--modify-window", "--max-alloc", "--stop-after", "--stop-at", "--usermap", "--groupmap",
             "--skip-compress", "--compress-level", "--outbuf", "--write-batch", "--read-batch",
             "--only-write-batch", "--early-input", "--protocol", "--checksum-choice", "--compress-choice",
             "--log-file-format", "--max-delete", "--delay-updates-dir", "--files-from", "--from0-file", "--copy-as"}
DEL_VERBS = {"rm", "rmdir", "unlink", "shred", "srm", "rimraf"}
HD_RE = r"(?<!<)<<(?!<)-?\s*(\\?[\x27\"]?)([^\s;|&<>()\x27\"]+)[\x27\"]?"
REMOTE_FILE, MOVED = False, None      # read_local: a path on the other host; a relative path after a cd
ESC = {";": "\x02", "(": "\x05", ")": "\x06"}      # escaped \; \( \): words of find, not shell operators
# Command position in plain text, for the backstop: after a separator, a wrapper with its options, or find -exec.
POS = (r"(?:^|[;&|(`\n{]|\$\(|\b(?:then|do|else|xargs|exec|env|sudo|doas|nohup|time|command|nice|ionice|timeout|busybox|parallel|taskset|chrt|setsid|stdbuf|unbuffer)"
       r"\s+(?:-\S+\s+(?:[^-\s]\S*\s+)?)*|\s-(?:exec|execdir|ok|okdir)\s+)[ \t]*(?:\w+=\S*\s+)*(?:\S*/)?")


# Commands whose arguments are words and patterns, not commands to run: a deleting word after them is data.
NOISE = {"grep", "egrep", "fgrep", "zgrep", "bzgrep", "xzgrep", "zegrep", "fd", "rg", "ag", "ack",
         "echo", "printf", "man", "which", "type", "whereis", "apropos", "docker", "docker-compose",
         "podman", "podman-compose", "nerdctl", "git", "npm", "yarn", "pnpm", "kubectl", "helm", "apt", "apt-get", "yum", "dnf", "brew",
         "pip", "pip3", "cat", "less", "more", "tail", "head", "sed", "awk", "ls", "test", "[", "[[", "find", "gfind",
         "history", "alias", "complete", "logger", "wall", "write", "tee", "cut", "tr", "sort", "wc", "journalctl",
         "pytest", "py.test", "tox", "nox", "go", "cargo", "make", "rspec", "jest", "phpunit", "mvn", "gradle", "ctest",
         "rails", "rake", "mix", "dotnet",
         "jq", "yq", "xmllint", "xmlstarlet", "csvgrep", "csvcut", "sqlite3", "psql", "mysql", "mariadb",
         "column", "uniq", "bat", "nl", "diff", "cmp", "comm", "od", "hexdump", "strings", "file", "stat",
         "du", "df", "lsof", "ps", "pgrep", "dmesg"}


def remote_data_command(b, args):
    # SQLite can escape to the shell. Do not exempt that mode just because SQL is data.
    if b == "sqlite3" and re.search(r"\.shell\b|\bsystem\b", " ".join(args), re.I): return False
    if b == "systemctl":
        i = 0
        while i < len(args) and args[i].startswith("-"):
            i += remote_opt_width(args[i], {"-H", "--host", "-M", "--machine", "-t", "--type", "--state", "-p", "--property", "-n", "--lines"})
        return i < len(args) and args[i] == "status"
    return b in NOISE


def coarse(text):
    """The backstop under the parser: a deleting command in a text that runs remotely, found by
    pattern where the parser found nothing. It reads executable text only: comments are out, and so
    are heredoc bodies (one that a shell runs has been read by the parser; one that is written to a
    file is data). A deleting word after a command that takes words as data (NOISE) is data, also
    behind sudo, env, xargs and the other wrappers."""
    code = heredocs(text)[0]
    r = None
    for w, _, _ in (segs(code) or []):
        i = remote_command_start(w)
        if i is None: continue
        b = os.path.basename(w[i])
        if remote_data_command(b, w[i + 1:]): continue
        if b == "sqlite3" and re.search(r"\b(?:" + "|".join(DEL_VERBS) + r")\b", " ".join(w[i + 1:])):
            r = "sqlite3 shell/system escape"; break
        # These commands have explicit source/payload boundaries in script_dels. Re-scanning
        # their argv here would turn filters, script arguments and nested searches into code.
        if INTERP.fullmatch(b) or b in SHELL_NAMES | {"su", "runuser", "flock", "eval", "trap", "ssh", "autossh"}: continue
        # Resolve wrappers before searching command positions: their option operands and the
        # arguments of grep/git/etc. must never become executable words in the backstop.
        bare = unquoted(join(w[i:]))
        m = re.search(POS + r"\\?(rm|rmdir|unlink|shred|srm)(?=\s|$)", bare)
        if m: r = m.group(1); break
        if re.search(r"\bg?find\b(?:\\;|[^;|&\n])*\s-delete\b", bare):
            r = "find -delete"; break
        # behind a wrapper nobody listed (chroot DIR rm -rf x, setpriv ... -- rm x): the word, then
        # options and a path-like operand, in a command that is not known to take such words as data
        for n in range(i + 1, len(w) - 1):
            if w[n] in ("rm", "rmdir", "unlink", "shred", "srm"):
                ops = [a for a in w[n + 1:] if a != "--" and not a.startswith("-")]
                flagged = any(a.startswith("-") and a != "--" for a in w[n + 1:])
                if ops and (flagged or "/" in ops[0] or ops[0][:1] in "~$."): r = w[n]; break
        if r: break
    return ("a deleting command (" + r + ") that the parser could not place; read the text") if r else None


def heredocs(text):
    """(the command lines without comments and heredoc bodies, {marker: [body, ...]} in order of appearance)."""
    out, bodies, pending, q = [], {}, [], (None, [])
    rows = text.split("\n")
    for n, line in enumerate(rows):
        if pending:
            if line.strip() == pending[0]: pending.pop(0)
            else: bodies[pending[0]][-1].append(line)
            continue
        line, q, outside = scan_line(line, q)
        out.append(line)
        for m in re.finditer(HD_RE, line):
            if outside[m.start()] and any(r.strip() == m.group(2) for r in rows[n + 1:]):
                pending.append(m.group(2)); bodies.setdefault(m.group(2), []).append([])
    return "\n".join(out), {k: ["\n".join(b) for b in v] for k, v in bodies.items()}


def mask_subs(t):
    """$( ) and backtick spans outside single quotes replaced by placeholders, so that the
    parentheses inside them do not split the word they belong to: (text, the spans)."""
    nosq = re.sub(r"\x27[^\x27]*\x27", lambda m: "\x27" + " " * (len(m.group(0)) - 2) + "\x27", t)
    out, subs, i, last = [], [], 0, 0
    while True:
        m = re.search(r"(?<!\\)(?:\$\(|`)", nosq[i:])
        if not m: break
        s = i + m.start()
        if nosq[s] == "`":
            e = nosq.find("`", s + 1); e = len(nosq) if e < 0 else e + 1
        else:
            d, e = 1, s + 2
            while e < len(nosq) and d: d += {"(": 1, ")": -1}.get(nosq[e], 0); e += 1
        out.append(t[last:s]); out.append("\x03%d\x03" % len(subs)); subs.append(t[s:e]); last = i = e
    out.append(t[last:])
    return "".join(out), subs


def piped(pre):
    """Whether the operators before a command make it read the previous command's output. A newline
    after the | (a pipeline continued on the next line) arrives as | followed by ;."""
    return bool(re.search(r"(?<!\|)\|&?(?!\|)", pre))          # | or |&, also inside a run like )| ; never ||


def live_subs(code):
    """substitutions() without the escaped \\$( forms, which are literal text in a message."""
    return substitutions(re.sub(r"\\\$\(", "\\$ (", code))


def opt_width(a, vals):
    """How many words an ssh option word takes: -p 2222 is two, -p2222 and -tt one, -tp 2222 two
    (the first letter in the cluster that takes a value takes the rest of the word, or the next word)."""
    for n, ch in enumerate(a[1:]):
        if "-" + ch in vals: return 2 if n == len(a) - 2 else 1
    return 1


def ssh_target(args, vals):
    """Keep explicit connection settings while resolving the host and payload. Never read
    SSH config or execute ProxyCommand; the same parser also handles SSH inside a payload."""
    j, hostname, options = 0, None, []

    def scan_options():
        nonlocal j, hostname
        while j < len(args) and args[j].startswith("-") and args[j] != "--":
            a, width = args[j], opt_width(args[j], vals)
            for n, ch in enumerate(a[1:]):
                flag = "-" + ch
                if flag not in vals: continue
                value = a[n + 2:] or (args[j + 1] if j + 1 < len(args) else "")
                key, setting = "", ""
                if flag == "-o":
                    m = re.match(r"^\s*([^\s=]+)(?:\s*=\s*|\s+)(.*)$", value)
                    if m: key, setting = m.group(1).lower(), m.group(2).strip()
                if key == "hostname" and hostname is None: hostname = setting
                if flag in {"-J", "-p", "-W", "-F", "-l"} or key in {"hostname", "proxyjump", "proxycommand", "port", "user"}:
                    note = join(args[j:j + width])
                    if flag == "-F": note += " (config file in use; real destination may come from that file)"
                    options.append(note)
                break       # the rest of this option word is its value, not more flags
            j += width

    scan_options()
    if j < len(args) and args[j] == "--": j += 1
    if j >= len(args): return None, [], options
    host, j = args[j], j + 1
    scan_options()           # ssh host -p 2222 cmd
    if j < len(args) and args[j] == "--": j += 1
    if hostname is not None: host = hostname + " (ssh alias " + host + ")"
    return host, args[j:], options


def remote_opt_width(a, vals):
    """Separate long-option values, or the first value-taking short option in a cluster."""
    if a in vals: return 2
    return 1 if a.startswith("--") else opt_width(a, vals)


REMOTE_WRAPPER_VAL = {
    "sudo": SUDO_VAL | {"--close-from", "--command-timeout", "--other-user", "--role", "--type"},
    "doas": {"-u", "-C"}, "nice": {"-n", "--adjustment"},
    "env": {"-u", "-C", "-S", "-P", "--unset", "--chdir", "--split-string"},
    "xargs": XARGS_VAL | {"--max-args", "--replace", "--delimiter", "--eof", "--max-lines",
                           "--max-procs", "--max-chars", "--arg-file"},
    "command": set(), "builtin": set(), "exec": {"-a"}, "nohup": set(),
    "time": {"-o", "-f", "--output", "--format"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "gtimeout": {"-s", "-k", "--signal", "--kill-after"},
    "ionice": {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata", "--pid", "--pgid", "--uid"},
    "taskset": set(), "chrt": {"-T", "-P", "-D", "--sched-runtime", "--sched-period", "--sched-deadline"},
    "setsid": set(), "chronic": set(), "unbuffer": set(), "caffeinate": {"-t", "-w"},
    "flock": {"-w", "-E", "--wait", "--timeout", "--conflict-exit-code"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "xcrun": {"-sdk", "--sdk", "-toolchain", "--toolchain"}, "arch": {"-e"},
    "busybox": set(), "parallel": XARGS_VAL | {"-j", "--jobs"},
    "numactl": {"-m", "-p", "-i", "-N", "-C", "--membind", "--preferred", "--interleave",
                "--cpunodebind", "--physcpubind"},
    "watch": {"-n", "--interval"}, "strace": {"-e", "-o", "-p", "-s", "-u"},
    "ltrace": {"-e", "-o", "-p", "-s", "-u"},
    "runuser": {"-u", "-g", "-G", "-s", "-w", "--user", "--group", "--supp-group", "--shell", "--whitelist-environment"},
    "chroot": {"--userspec", "--groups"},
    "setpriv": {"--ruid", "--euid", "--reuid", "--rgid", "--egid", "--regid", "--groups",
                "--inh-caps", "--ambient-caps", "--bounding-set", "--securebits", "--pdeathsig",
                "--selinux-label", "--apparmor-profile", "--landlock-access", "--landlock-rule", "--seccomp-filter"},
    "chpst": {"-u", "-U", "-b", "-e", "-/", "-C", "-n", "-l", "-L", "-m", "-d", "-o", "-p", "-f", "-c", "-t"},
    "uv": {"--directory", "--project", "--config-file", "--cache-dir", "--python", "-p",
           "--with", "--with-editable", "--with-requirements", "--extra", "--group", "--package", "--env-file", "--index", "--index-url"},
    "poetry": {"-C", "--directory", "-P", "--project"},
    "pipenv": {"--python"},
    "pipx": {"--spec", "--python", "--pip-args", "--index-url"},
    "hatch": {"-e", "--env", "-p", "--project"},
    "pdm": {"-p", "--project", "-c", "--config", "-G", "--group"},
    "rye": {"--pyproject"},
    "conda": {"-n", "--name", "-p", "--prefix", "--cwd"},
    "tox": {"-e", "-c", "--conf", "--workdir", "--root"},
    "npx": {"-p", "--package", "--cache", "--registry", "--userconfig"},
    "bunx": {"-p", "--package"}, "pnpx": {"--package"},
    "pnpm": {"-C", "--dir", "--filter", "--package", "--store-dir"},
    "yarn": {"--cwd", "--cache-folder", "--modules-folder", "-p", "--package"},
    "npm": {"--prefix", "--workspace", "-w", "--package", "--cache", "--registry"},
    "corepack": set(), "bundle": {"--gemfile", "--path"},
}
REMOTE_WRAPPER_VAL["uvx"] = REMOTE_WRAPPER_VAL["uv"] | {"--from"}
# Only these subcommands launch another tool. In particular, package-manager rm/remove
# stays attached to npm/pnpm/yarn, whose operands are packages rather than filesystem paths.
# Their run subcommand names project scripts (even a script named unlink), not OS commands.
REMOTE_LAUNCH_SUBCOMMANDS = {
    "uv": {"run"}, "poetry": {"run"}, "pipenv": {"run"}, "pipx": {"run"},
    "hatch": {"run"}, "pdm": {"run"}, "rye": {"run"}, "conda": {"run"},
    "pnpm": {"exec", "dlx"}, "yarn": {"exec", "dlx"}, "npm": {"exec"},
    "bundle": {"exec"},
}


def remote_command_start(w):
    """Shared command resolution for remote parsing and its backstop; LOCAL keeps its resolver."""
    i = 0
    while i < len(w):
        x = w[i]; b = os.path.basename(x)
        if re.match(r"[A-Za-z_]\w*\+?=", x) or x in KEYWORDS: i += 1; continue
        if b not in REMOTE_WRAPPER_VAL: return i
        start = i
        if b == "runuser" and not any(a in ("-u", "--user") or a.startswith(("-u", "--user=")) for a in w[i + 1:]): return i
        vals = REMOTE_WRAPPER_VAL[b]
        i += 1
        terminated = False
        while i < len(w) and w[i].startswith("-"):
            a = w[i]
            if a == "--": i += 1; terminated = True; break
            if b in ("flock", "runuser") and a in ("-c", "--command", "--session-command"): return start
            if b == "command" and re.match(r"^-[A-Za-z]*[vV]", a): return None
            if b == "xcrun" and a in ("--find", "-f", "--show-sdk-path", "--show-sdk-version"): return None
            i += remote_opt_width(a, vals)
        if b == "tox" and not terminated: return start
        if b in REMOTE_LAUNCH_SUBCOMMANDS:
            if i >= len(w) or w[i] not in REMOTE_LAUNCH_SUBCOMMANDS[b]: return start
            i += 1
            while i < len(w) and w[i].startswith("-"):
                if w[i] == "--": i += 1; break
                i += remote_opt_width(w[i], vals)
        if b in ("timeout", "gtimeout", "taskset", "chrt", "flock", "chroot"): i += 1  # duration, CPU mask, priority, lock, root
        if b == "flock" and i < len(w) and w[i] in ("-c", "--command"): return start
    return None


def segs(text, bodies=None):
    """The simple commands of a shell text, in order: (words, the operator before it, [(redirection, target)]).
    A newline ends a command only outside quotes: inside a quoted word it belongs to the text that
    word carries (a remote script), which is parsed on its own, comments included. An escaped \\; is
    a word (find's terminator), not a separator. Each heredoc redirection gets its own body, in order
    of appearance, as ("<<body", text)."""
    t, subs = mask_subs(re.sub(r"(?<![\\\w$])\$(?=\x27)", "", text.replace("\\\n", "")))
    inq = quoted_mask(t)
    # both only outside quotes: inside a quoted word they belong to the text that word carries
    def piece(k, c):
        if c == "\n" and not inq[k]: return " ; "
        if c in ";()" and k and t[k - 1] == "\\" and not inq[k]: return " " + ESC[c] + " "
        return c
    t = re.sub(r"\\( [\x02\x05\x06] )", r"\1", "".join(piece(k, c) for k, c in enumerate(t)))
    try:
        lx = shlex.shlex(t, posix=True, punctuation_chars=True)
        lx.whitespace_split = True; lx.commenters = ""
        toks = list(lx)
    except ValueError:
        return None
    back = lambda x: re.sub("\x03(\\d+)\x03", lambda m: subs[int(m.group(1))], x).replace("\x02", ";").replace("\x05", "(").replace("\x06", ")")
    out, cur, red, pre, op = [], [], [], "", None
    for tok in toks:
        if op:
            if op in ("<<", "<<-") and bodies is not None:
                b = bodies.get(tok) or bodies.get(tok.lstrip("-")) or [""]      # <<-EOF arrives as << and -EOF
                red.append(("<<body", b.pop(0) if len(b) > 1 else b[0]))
            else:
                red.append((op, back(tok)))
            op = None
            if tok.endswith("(") and set(tok) <= PUNCT:       # < <(cmd): unreadable input, and cmd is a command of its own
                out.append((cur, pre, red)); cur, red, pre = [], [], "("
            continue
        if tok and set(tok) <= PUNCT:
            if ("<" in tok or ">" in tok) and not tok.endswith("("):
                if cur and cur[-1].isdigit() and len(cur[-1]) == 1: cur.pop()     # 2>file: a descriptor, not an operand
                op = tok
            else:
                if cur or red:
                    out.append((cur, pre, red)); cur, red, pre = [], [], tok
                else:
                    pre = (pre + " " + tok).strip()
            continue
        cur.append(back(tok))
    if cur or red: out.append((cur, pre, red))
    return out


def operands(args):
    out, done = [], False
    for a in args:
        if a == "--" and not done: done = True
        elif done or not a.startswith("-"): out.append(a)
    return out


def join(words):
    return " ".join(shlex.quote(x) for x in words)


def shell_reads_stdin(w):
    """sh, bash -s, sudo bash: a shell with no script operand and no -c runs what arrives on stdin
    (not with -n, which only checks the syntax)."""
    i = remote_command_start(w)
    if i is None or os.path.basename(w[i]) not in SHELL_NAMES: return False
    args = w[i + 1:]
    if any(re.match(r"^-[A-Za-z]*[cn][A-Za-z]*$", a) for a in args): return False
    ops, skip = [], False
    for a in args:
        if skip: skip = False
        elif a[:1] in "-+" and not a.startswith("--"): skip = a.endswith("o")      # -o pipefail, -euo pipefail
        elif not a.startswith("--"): ops.append(a)
    return any(re.match(r"^-[A-Za-z]*s[A-Za-z]*$", a) for a in args) or not ops


def read_local(path, cwd):
    """A local file's text, or None when the guard cannot know it (a variable, a glob, missing, not a
    regular file, too big, a relative path after a cd, a path on the other host)."""
    if cwd is REMOTE_FILE: return None
    if path == "/dev/null": return ""
    if re.search(r"[$*?`\[<(]", path): return None
    p = os.path.expanduser(path)
    if not os.path.isabs(p):
        if cwd is MOVED: return None
        p = os.path.join(cwd or ".", p)
    try:
        if not os.path.isfile(p) or os.path.getsize(p) > 1 << 20: return None
        with open(p, errors="replace") as f: return f.read()
    except OSError:
        return None


def stdin_texts(ss, k, cwd, pcwd=Ellipsis):
    """What seg k reads on stdin: [(label, text or None when unreadable)]. pcwd: the directory of the
    command before the pipe, when it differs (a cd inside a subshell)."""
    out = []
    if pcwd is Ellipsis: pcwd = cwd
    w, pre, red = ss[k]
    def from_redirs(red):
        for op, tgt in red:
            if op == "<<body": out.append(("a heredoc", tgt))
            elif op == "<<<": out.append(("a here-string", tgt))
            elif op == "<": out.append(("the file " + tgt, read_local(tgt, cwd)))
    from_redirs(red)
    if piped(pre) and k > 0:
        pw, _, pred = ss[k - 1]
        i = command_start(pw)
        b = os.path.basename(pw[i]) if i is not None else ""
        a = pw[i + 1:] if i is not None else []
        if b == "cat":
            files = operands(a)
            for f in files: out.append(("the file " + f, read_local(f, pcwd)))
            if not files: from_redirs(pred)
        elif b == "echo":
            while a and re.match(r"^-[neE]+$", a[0]): a = a[1:]
            out.append(("the output of: " + join(pw[i:]), " ".join(a).replace("\\n", "\n")))
        elif b == "printf":
            # the format with its arguments filled in when it only uses %s; otherwise every argument
            # as a line of its own (the label carries the command as written either way)
            fmt, rest = (a[0], a[1:]) if a else ("", [])
            n = fmt.count("%s")
            if n and rest and "%" not in fmt.replace("%s", ""):
                parts, text = fmt.split("%s"), ""
                for j in range(0, len(rest), n):         # printf reuses the format until the arguments run out
                    text += "".join(p + c for p, c in zip(parts, (rest[j:j + n] + [""] * n)[:n] + [""]))
            else:
                text = "\n".join(a)
            out.append(("the output of: " + join(pw[i:]), text.replace("\\n", "\n")))
        else: out.append(("the output of " + (b or "a command"), None))
    return out


def rsync_dels(args):
    """(deletes on the destination side, deletes on the source side, positionals); nothing on a dry run."""
    pos, opts, j = [], [], 0
    while j < len(args):
        if args[j] == "--": pos.extend(args[j + 1:]); break
        if args[j].startswith("-"):
            a = args[j]
            # Attached option values are data, including an 'n' in -ffilter or -essh.
            flag = a
            if not a.startswith("--"):
                for n, ch in enumerate(a[1:], 1):
                    if "-" + ch in RSYNC_VAL: flag = a[:n]; break
            opts.append(flag)
            j += remote_opt_width(a, RSYNC_VAL)
        else: pos.append(args[j]); j += 1
    if any(a in ("--dry-run", "--list-only") or re.match(r"^-[A-Za-z]*n[A-Za-z]*$", a) for a in opts): return False, False, []
    args = opts
    dest = any(re.match(r"^--del(ete(-(before|during|delay|after|excluded|missing-args))?)?$", a) for a in args)
    src = "--remove-source-files" in args or "--remove-sent-files" in args
    return dest, src, pos


def remote_git(args):
    """Why a git command on the remote side deletes files, or None."""
    i = 0
    while i < len(args):
        if args[i] in GIT_VAL: i += 2; continue
        if args[i].startswith("-"): i += 1; continue
        break
    if args[i:i + 1] == ["rm"] and any(a == "--dry-run" or re.match(r"^-[A-Za-z]*n[A-Za-z]*$", a) for a in args[i + 1:]): return None
    r = git_reason(args)
    if r: return r.split(" (")[0]
    if args[i:i + 2] == ["worktree", "remove"]: return "git worktree remove (it deletes the worktree's untracked and ignored files)"
    return None


def python_source(args):
    """Executable -c text, None for stdin, or empty text for module/script arguments."""
    j = 0
    while j < len(args):
        a = args[j]
        if a == "--":
            return None if j + 1 == len(args) or args[j + 1] == "-" else ""
        if a == "-": return None
        if not a.startswith("-") or a in ("-h", "-V") or a.startswith(("--help", "--version")): return ""
        if a == "--check-hash-based-pycs": j += 2; continue
        if not a.startswith("--"):
            for n, ch in enumerate(a[1:], 1):
                if ch in "cmWX":
                    value = a[n + 1:] or (args[j + 1] if j + 1 < len(args) else "")
                    if ch == "c": return value
                    if ch == "m": return ""
                    if not a[n + 1:]: j += 1
                    break
        j += 1
    return None


# Only options that take executable source belong here. In particular node -r, ruby -E,
# perl -p and Python -m take modules/encodings or change execution mode, not inline code.
INLINE_CODE = {
    "node": {"-e", "-p", "--eval", "--print"}, "nodejs": {"-e", "-p", "--eval", "--print"},
    "bun": {"-e", "-p", "--eval", "--print"}, "deno": set(),
    "ruby": {"-e"}, "perl": {"-e", "-E"}, "php": {"-r", "-B", "-R", "-E"},
    "lua": {"-e"}, "osascript": {"-e"},
}
INTERP_VALUES = {
    "node": {"-r", "--require", "--import", "--loader", "--experimental-loader", "--test-name-pattern", "--test-skip-pattern", "--test-reporter", "--test-reporter-destination", "--input-type", "--conditions", "-C"},
    "bun": {"-r", "--require", "--preload", "--loader", "--define", "--cwd", "--env-file", "--config", "-c"},
    "deno": {"--config", "-c", "--import-map", "--lock", "--seed", "--v8-flags", "--ext"},
    "ruby": {"-I", "-r", "-E", "--encoding", "-C", "-F", "-K"},
    "perl": {"-I", "-M", "-m", "-F"}, "php": {"-c", "-d", "-z", "--php-ini", "--define"},
    "lua": {"-l"}, "osascript": {"-l", "-s"},
}


def interpreter_source(b, args):
    """Inline source, None for a stdin script, or empty text for script/subcommand argv.
    Stop at the source boundary; a script's options and arguments are never interpreter code.
    Used for both remote stdin routing and the parser (which owns these commands in coarse).
    """
    if re.fullmatch(r"(?:python|pypy)[0-9.]*", b): return python_source(args)
    if b not in INLINE_CODE: return ""
    opts = INLINE_CODE[b]
    vals = INTERP_VALUES.get("node" if b == "nodejs" else b, set())
    sources, j, mode = [], 0, None
    while j < len(args):
        a = args[j]
        if a == "--":
            return "\n".join(sources) if sources else (None if j + 1 == len(args) or args[j + 1] == "-" else "")
        if a == "-": return "\n".join(sources) if sources else None
        if not a.startswith("-"):
            if b in ("deno", "bun") and mode is None and a in ("eval", "run"):
                mode = a; j += 1; continue
            if b == "deno" and mode == "eval": return a
            return "\n".join(sources)
        if a in ("-h", "--help", "-v", "--version") or (b in ("node", "nodejs") and a in ("--test", "-c", "--check")):
            return ""
        if b == "php" and (a in ("-f", "--file", "-F") or a.startswith(("--file=", "-f", "-F"))): return "\n".join(sources)
        if a.startswith("--"):
            flag, eq, value = a.partition("=")
            if flag in opts:
                sources.append(value if eq else (args[j + 1] if j + 1 < len(args) else ""))
                j += 1 if eq else 2
                if b in ("node", "nodejs", "bun"): return "\n".join(sources)
                continue
            j += 2 if flag in vals and not eq else 1
            continue
        # Short options can be clustered and their value can be attached (-weCODE, -Itest).
        for n, ch in enumerate(a[1:], 1):
            flag = "-" + ch
            if flag in opts | vals:
                value = a[n + 1:] or (args[j + 1] if j + 1 < len(args) else "")
                if flag in opts: sources.append(value)
                if not a[n + 1:]: j += 1
                if flag in opts and b in ("node", "nodejs", "bun"): return "\n".join(sources)
                break
        j += 1
    if sources: return "\n".join(sources)
    return "" if b == "deno" else None


def interp_code_dels(b, code_text):
    m = DEL_API.search(code_text)
    r = (b + " code that deletes (" + " ".join(m.group(0).split())[:40] + "); the code") if m else interp_runs_deleter(code_text)
    return [(r, [code_text])] if r else []


def filter_sources(b, args):
    """awk/sed programs only: -e/--expression/--source or the first non-option.
    File names, -v assignments, field separators and input files are data.
    """
    sources, supplied, j = [], False, 0
    vals = {"-v", "--assign", "-F", "--field-separator", "-i", "--include", "-l", "--load"} if b != "sed" else set()
    while j < len(args):
        a = args[j]
        flag, eq, value = a.partition("=")
        if flag in ("-e", "--expression", "--source", "-f", "--file") or a[:2] in ("-e", "-f"):
            short = a[:2] in ("-e", "-f")
            value = a[2:] if short else (value if eq else "")
            if not value:
                j += 1; value = args[j] if j < len(args) else ""
            if flag not in ("-f", "--file") and not a.startswith("-f"): sources.append(value)
            supplied = True
        elif a == "--":
            if not supplied and j + 1 < len(args): sources.append(args[j + 1])
            break
        elif a.startswith("-"): j += remote_opt_width(a, vals) - 1
        elif not supplied: sources.append(a); supplied = True
        j += 1
    return sources


def awk_dels(source, depth):
    # Mask strings, regex literals and comments before locating execution operators. Their
    # contents cannot introduce system() or a pipe, but a string at an operator is shell text.
    pattern = r'"(?:\\.|[^"\\])*"|/(?:\\.|[^/\\\n])*/|#[^\n]*'
    literals = {}
    def mask(m):
        if m.group().startswith('"'):
            literals[m.start()] = re.sub(r'\\(["\\])', r'\1', m.group()[1:-1])
        return " " * len(m.group())
    code = re.sub(pattern, mask, source)
    found = []
    for m in re.finditer(r"\bsystem\s*\(|(?<!\|)\|(?!\|)", code):
        start = m.end()
        end = re.search(r"[);}\n]", code[start:])
        end = start + end.start() if end else len(code)
        command = "".join(v for p, v in literals.items() if start <= p < end)
        found += script_dels(command, depth + 1)
        if coarse(command): found.append((coarse(command), [source]))
        # Invalid shell quoting in a pipe target must not abort the surrounding script scan.
        if m.group() == "|" and any(shell_reads_stdin(w) for w, _, _ in (segs(command) or [])):
            # print "rm /path" | "sh": the strings on the sending side are shell source.
            boundary = max(code.rfind(";", 0, m.start()), code.rfind("{", 0, m.start()), code.rfind("\n", 0, m.start()))
            for p, value in literals.items():
                if boundary < p < m.start(): found += script_dels(value, depth + 1)
    return [("awk command: " + what, [source] + paths) for what, paths in found]


def sed_dels(source, depth):
    """Skip addresses and s/y pattern/replacement data; only e executes shell text."""
    found, i = [], 0
    def delimited(pos, delimiter):
        while pos < len(source):
            if source[pos] == "\\": pos += 2; continue
            if source[pos] == delimiter: return pos + 1
            pos += 1
        return pos
    while i < len(source):
        c = source[i]
        if c.isspace() or c.isdigit() or c in ";,${}!": i += 1; continue
        if c == "#":
            i = source.find("\n", i)
            if i < 0: break
            continue
        if c == "/": i = delimited(i + 1, c); continue
        if c == "\\" and i + 1 < len(source): i = delimited(i + 2, source[i + 1]); continue
        if c in "sy" and i + 1 < len(source):
            delimiter = source[i + 1]
            start = i + 2
            middle = delimited(start, delimiter)
            end = delimited(middle, delimiter)
            flags = re.match(r"[^;\n}]*", source[end:]).group()
            if c == "s" and "e" in flags.split("w", 1)[0]:
                for text in (source[start:middle - 1], source[middle:end - 1]):
                    found += script_dels(text, depth + 1)
            i = end + len(flags); continue
        end = source.find("\n", i)
        if end < 0: end = len(source)
        if c == "e": found += script_dels(source[i + 1:end].strip(), depth + 1)
        elif c not in "aicw":
            i += 1; continue
        i = end
    return [("sed command: " + what, [source] + paths) for what, paths in found]


def script_dels(text, depth=0):
    """Deletes in a shell text that runs on the remote side: [(what, paths)]."""
    found = []
    if depth > 3 or not text.strip(): return found
    code, bodies = heredocs(text)
    ss = segs(code, bodies)
    if ss is None:
        if re.search(RM_WORD, text) or shell_text_reasons(text):
            found.append(("a delete in text the guard cannot parse", [text]))
        return found
    for sub in live_subs(code):
        found += script_dels(sub, depth + 1)
    for k, (w, pre, red) in enumerate(ss):
        i = remote_command_start(w)
        if i is None: continue
        b, args = os.path.basename(w[i]), w[i + 1:]
        fed = any(os.path.basename(x) in ("xargs", "parallel") for x in w[:i])
        if b in DEL_VERBS:
            paths = [shlex.quote(x) if re.search(r"\s", x) else x for x in operands(args)]
            if fed and piped(pre) and k > 0: paths.append("(names from: " + " ".join(ss[k - 1][0]) + ")")
            elif fed: paths.append("(names from stdin)")
            found.append((b, paths))
        elif b in ("find", "gfind"):
            if "-delete" in args: found.append(("find -delete", [" ".join(w[i:])]))
            for n, a in enumerate(args):
                if a in ("-exec", "-execdir", "-ok", "-okdir"):
                    sub = []
                    for y in args[n + 1:]:
                        if y in (";", "+"): break
                        sub.append(y)
                    for what, _ in script_dels(join(sub), depth + 1):
                        found.append(("find " + a + " " + what, [" ".join(w[i:])]))
        elif b == "fd":
            for n, a in enumerate(args):
                if a in ("-x", "--exec", "-X", "--exec-batch"):
                    sub = args[n + 1:]
                    if ";" in sub: sub = sub[:sub.index(";")]
                    for what, _ in script_dels(join(sub), depth + 1):
                        found.append(("fd " + a + " " + what, [" ".join(w[i:])]))
                    break
        elif b == "git":
            r = remote_git(args)
            if r: found.append((r, [" ".join(w[i:])]))
        elif b == "rsync":
            dest, src, pos = rsync_dels(args)
            if (dest or src) and len(pos) > 1: found.append(("rsync with a deleting option", [" ".join(w[i:])]))
        elif b in ("tar", "gtar", "bsdtar") and any(a.startswith("--remove-files") for a in args):
            found.append(("tar --remove-files (deletes what it archived)", [" ".join(w[i:])]))
        elif b == "zip" and any(a == "--move" or re.match(r"^-[A-Za-z0-9]*m[A-Za-z0-9]*$", a) for a in args):
            found.append(("zip -m (deletes what it archived)", [" ".join(w[i:])]))
        elif b in ("su", "runuser", "flock"):
            for n, a in enumerate(args[:-1]):
                if a in ("-c", "--command", "--session-command"):
                    found += script_dels(args[n + 1], depth + 1); break
        elif b == "eval":
            found += script_dels(" ".join(args), depth + 1)
        elif b == "trap" and operands(args):
            found += [("trap: " + what, p) for what, p in script_dels(operands(args)[0], depth + 1)]
        elif b in SHELL_NAMES:
            if any(re.match(r"^-[A-Za-z]*n[A-Za-z]*$", a) for a in args): continue       # a syntax check runs nothing
            for n, a in enumerate(args[:-1]):
                if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a):
                    found += script_dels(args[n + 1], depth + 1); break
            if shell_reads_stdin([b] + args):
                for _, t in stdin_texts(ss, k, REMOTE_FILE):
                    if t: found += script_dels(t, depth + 1)
        elif b in ("awk", "gawk", "mawk", "sed"):
            for source in filter_sources(b, args):
                found += sed_dels(source, depth) if b == "sed" else awk_dels(source, depth)
        elif INTERP.match(" " + b):
            code_text = interpreter_source(b, args)
            if code_text is None: code_text = "\n".join(t or "" for _, t in stdin_texts(ss, k, REMOTE_FILE))
            found += interp_code_dels(b, code_text)
    # Scan the complete payload so nested remote tools retain heredocs/pipelines too.
    # Files named here live on the SSH host and must never be read from the local cwd.
    found += [(what + " (on " + h + ", through this host)", p)
              for h, what, p in remote_findings(text, REMOTE_FILE, depth + 1)]
    return found


def is_remote(p):
    return bool(re.match(r"^(?:[^/\s:\[]*\[[^\]]+\]|[^/\s:]+):", p))


def rsync_host(p):
    m = re.match(r"^rsync://(?:[^@/]*@)?(\[[^\]]+\]|[^/:]+)", p) or re.match(r"^((?:[^@/\s]*@)?\[[^\]]+\]):", p)
    return m.group(1) if m else p.split(":")[0]


def ftp_dels(tool, host, label, t):
    """Deleting commands and final host in sftp or lftp command text. lftp separates commands
    with ; && || too, and `open` changes the host the rest runs on."""
    out = []
    for line in t.split("\n"):
        for c in (re.split(r";|&&?|\|\|", line) if tool == "lftp" else [line]):
            if tool == "lftp": c = re.sub(r"^\s*queue\s+", "", c)
            cw = c.split()
            if tool == "lftp" and len(cw) > 1 and cw[0] in ("open", "connect"): host = cw[-1]; continue
            m = re.match(r"^\s*[-@]?\s*(?:glob\s+(?:-\S+\s+)*)?(rm|rmdir|mrm|mdelete|delete|mrmdir)\b\s*(.*)", c)
            if m: out.append((host, tool + " " + m.group(1) + " (in " + label + ")", [m.group(2).strip()]))
            # lftp mirror -R uploads; with --delete (-e) it removes what the local side does not have
            elif re.match(r"^\s*mirror\b", c) and re.search(r"\s(--delete\b|-[A-Za-z]*e)", c) and re.search(r"\s(--reverse\b|-[A-Za-z]*R)", c) \
                    and not re.search(r"\s--dry-run\b|\s--just-print\b", c):
                out.append((host, "lftp mirror --reverse --delete removes whatever the local side does not have", [c.strip()]))
    return out, host


def remote_findings(text, cwd, depth=0):
    """Deletes this LOCAL shell text runs on a remote host: [(host, what, paths)]."""
    out = []
    if depth > 3: return out
    code, bodies = heredocs(text)
    ss = segs(code, bodies)
    if ss is None:
        if re.search(r"(?<![\w.-])(ssh|sftp|lftp)(?![\w.-])", text) and (re.search(RM_WORD, text) or shell_text_reasons(text)):
            out.append(("?", "ssh, sftp or lftp next to a delete, in a command the guard cannot parse; the command", [text]))
        return out
    for sub in live_subs(code):          # outside single quotes, not escaped: quoted prose is not a command
        out += remote_findings(sub, cwd, depth + 1)
    scopes, cwds = [], []
    for k, (w, pre, red) in enumerate(ss):
        for ch in pre:                        # a directory change inside ( ) ends with the subshell
            if ch == "(": scopes.append(cwd)
            elif ch == ")" and scopes: cwd = scopes.pop()
        cwds.append(cwd)
        pcwd = cwds[k - 1] if k else cwd      # the command before a `) |` ran in the subshell's directory
        i = remote_command_start(w)
        if i is None: continue
        b = os.path.basename(w[i])
        if b in ("cd", "pushd", "popd") and cwd is not REMOTE_FILE:
            # a relative script path after this is read from where the shell then is; when that
            # cannot be known (cd -, a variable, pushd) it is not read at all
            dest = operands(w[i + 1:])[:1]
            if b == "cd" and dest and not re.search(r"[$*?`\[]", dest[0]) and dest[0] != "-":
                d = os.path.expanduser(dest[0])
                cwd = d if os.path.isabs(d) else (MOVED if cwd is MOVED else os.path.normpath(os.path.join(cwd or ".", d)))
            else:
                cwd = MOVED
            continue
        if b == "sshpass":
            i += 1
            while i < len(w) and w[i].startswith("-"): i += 2 if w[i] in ("-p", "-f", "-d", "-P") else 1
            if i >= len(w): continue
            b = os.path.basename(w[i])
        args = w[i + 1:]
        if b in ("ssh", "autossh"):
            vals = SSH_VAL | ({"-M"} if b == "autossh" else set())      # ssh -M is a flag, autossh -M takes a port
            host, rest, connection_options = ssh_target(args, vals)
            if host is None: continue
            payload = " ".join(rest)                    # ssh itself joins the words with spaces
            got = [(host, what, p) for what, p in script_dels(payload)]
            if got: got.append((host, "the whole remote command, as written", [payload]))
            elif coarse(payload): got.append((host, coarse(payload), [payload]))
            ps = segs(heredocs(payload)[0]) or []
            readers = []
            for pw, _, _ in ps:
                pi = remote_command_start(pw)
                if pi is None: continue
                pb = os.path.basename(pw[pi])
                if shell_reads_stdin(pw) or (INTERP.fullmatch(pb) and interpreter_source(pb, pw[pi + 1:]) is None):
                    readers.append(pb)
            if not payload.strip(): readers.append("sh")
            if readers:
                for label, t in stdin_texts(ss, k, cwd, pcwd):
                    if t is None:
                        got.append((host, "a script the guard cannot read is sent to a remote shell (" + label + "); pass a literal file path (no cd before it) or put the commands in the call", []))
                        continue
                    d = []
                    for reader in readers:
                        d += script_dels(t) if reader in SHELL_NAMES else interp_code_dels(reader, t)
                    got += [(host, what + " (in " + label + ")", p) for what, p in d]
                    if d: got.append((host, "the whole script (" + label + ")", [t]))
                    elif any(reader in SHELL_NAMES for reader in readers) and coarse(t): got.append((host, coarse(t) + " (" + label + ")", [t]))
            if got and connection_options:
                got.append((host, "ssh connection options", [" ".join(connection_options)]))
            out += got
        elif b in ("sftp", "lftp"):
            pos, j, batch = [], 0, []
            while j < len(args):
                if (args[j] == "-b" or (args[j] == "-f" and b == "lftp")) and j + 1 < len(args) and args[j + 1] != "-":     # -b -: the batch is stdin
                    batch.append(("the batch file " + args[j + 1], read_local(args[j + 1], cwd)))
                if b == "sftp" and args[j].startswith("-b") and len(args[j]) > 2:      # -bFILE
                    batch.append(("the batch file " + args[j][2:], read_local(args[j][2:], cwd)))
                if args[j] in ("-c", "-e") and b == "lftp" and j + 1 < len(args): batch.append(("the command text", args[j + 1]))
                if b == "lftp" and args[j][:2] in ("-c", "-e") and len(args[j]) > 2: batch.append(("the command text", args[j][2:]))
                if args[j].startswith("-"): j += opt_width(args[j], SFTP_VAL) if b == "sftp" else (2 if args[j] in ("-c", "-e", "-f", "-u", "-p") else 1)     # sftp -qP 2222
                else: pos.append(args[j]); j += 1
            host = pos[0] if pos else "?"
            context = []
            for label, t in batch + stdin_texts(ss, k, cwd, pcwd):
                if t is None:
                    out.append((host, b + " commands the guard cannot read (" + label + ")", [])); continue
                context.append(label + ":\n" + t)
                d, host = ftp_dels(b, host, label, t)
                out += d
                if d: out.append((d[-1][0], "the whole " + b + " command text, as written", ["\n".join(context)]))
        elif b == "rsync":
            dest, src, pos = rsync_dels(args)
            if len(pos) < 2: continue
            remote_end = lambda p: is_remote(p) or p.startswith("rsync://")
            if dest and remote_end(pos[-1]):
                out.append((rsync_host(pos[-1]), "rsync with a --delete option removes whatever the source does not have", [pos[-1]]))
            if src and any(remote_end(p) for p in pos[:-1]):
                rp = [p for p in pos[:-1] if remote_end(p)]
                out.append((rsync_host(rp[0]), "rsync --remove-source-files deletes the transferred files there", rp))
        elif b in ("find", "gfind"):
            for n, a in enumerate(args):
                if a in ("-exec", "-execdir", "-ok", "-okdir"):
                    sub = []
                    for y in args[n + 1:]:
                        if y in (";", "+"): break
                        sub.append(y)
                    out += remote_findings(join(sub), cwd, depth + 1)
        elif b == "eval":
            out += remote_findings(" ".join(args), cwd, depth + 1)
        elif b in SHELL_NAMES:
            if any(re.match(r"^-[A-Za-z]*n[A-Za-z]*$", a) for a in args): continue       # a syntax check runs nothing
            for n, a in enumerate(args[:-1]):
                if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a):
                    out += remote_findings(args[n + 1], cwd, depth + 1); break
            if shell_reads_stdin(w[i:]):
                for _, t in stdin_texts(ss, k, cwd, pcwd):
                    if t: out += remote_findings(t, cwd, depth + 1)
    return out


def clean(s, cap):
    s = str(s).strip().replace("\r", "").replace("\t", "\\t").replace("\n", "\\n")      # one line, spaces as written
    return s if len(s) <= cap else s[:cap] + " [CUT: " + str(len(s) - cap) + " more characters not shown, so this list is INCOMPLETE; read the command itself]"


remote = []
if REMOTE:
    try:
        remote = remote_findings(ORIG, os.environ.get("RD_CWD", ""))
    except Exception:
        # the guard's own failure must not wave a remote delete through
        if re.search(RM_WORD, ORIG) or re.search(r"-delete\b|\bunlink\b|--del|--remove-", ORIG):
            remote = [("?", "ssh, sftp, lftp or rsync next to a deleting word (the guard failed to parse the command)", [])]
seen, rows = set(), []
for host, what, paths in sorted(remote, key=lambda x: not x[1].startswith("the whole")):      # the text as written first
    row = "R\t" + clean(host, 120) + "\t" + clean(what, 300) + "\t" + clean(" ".join(paths), 3000)
    if row not in seen:
        seen.add(row); rows.append(row)
if len(rows) > 40:
    rows = rows[:40] + ["R\t?\t" + str(len(rows) - 40) + " more findings not shown, so this list is INCOMPLETE; read the command and any script it sends\t"]
for row in rows:
    print(row)
if LOCAL:
    r = reasons(ORIG)
    if r:
        print("L\t" + clean(r, 400))
PY
  _RD_RC=0
  _RD_OUT=$(printf '%s' "$COMMAND" | RD_LOCAL=$_RD_LOCAL RD_REMOTE=$_RD_REMOTE RD_CWD="$_TRASH_CWD" python3 -c "$_RD_PY" 2>/dev/null) || _RD_RC=$?
  # python3 is there but the check itself died: the same crude ask as without python3
  if [ "$_RD_RC" != 0 ] && [ "$_RD_REMOTE" = 1 ] \
     && printf '%s' "$COMMAND" | grep -Eq '(^|[^[:alnum:]_.-])(rm|rmdir|unlink|shred)([^[:alnum:]_.-]|$)|-delete|--del|--remove-source'; then
    _rd_remote_ask "?"$'\t'"ssh, sftp, lftp or rsync next to a deleting word (the check failed to run, so the command was not parsed)"$'\t'"$(_rd_cmd_text)"
  fi
  _RD=""; _RD_R=""
  while IFS= read -r _rd_line; do
    case "$_rd_line" in
      L$'\t'*) [ -z "$_RD" ] && _RD=${_rd_line#L$'\t'} ;;
      R$'\t'*) _RD_R+="${_rd_line#R$'\t'}"$'\n' ;;
    esac
  done <<< "$_RD_OUT"
  if [ -z "$_RD" ] && [ -n "$_RD_R" ]; then
    _rd_remote_ask "$_RD_R"
  fi
  if [ -n "$_RD" ]; then
    # The local check reads the whole command and cannot tell a remote delete from a local one in
    # this form (a shell or interpreter word outside the quotes, an unquoted remote command), so it
    # stays a block, exactly as before the remote rule existed.
    [ -n "$_RD_R" ] && echo "Note: this command also deletes on a remote host, and in this form the local check cannot tell the two apart. A remote delete goes to the user's prompt when it is a plain rm or find in a single-quoted ssh command of its own (ssh HOST 'rm -- PATH'; ssh HOST 'find DIR ... -exec rm {} +'), with nothing local in the same call." >&2
    echo "Blocked: a real delete that skips the Trash: $_RD." >&2
    echo "Use rm on the command line itself (with rmtrash installed it goes to the Trash and is recorded for review), or call ~/.megavibe/scripts/trash.sh from the code. A glob or rmtree over a scratch directory has destroyed finished work for good before." >&2
    echo "If this is only text (a commit message, a note), run it as its own Bash call, or write it to a file with the Write tool and pass the file (git commit -F, gh pr create --body-file). If a human has decided the delete must be unrecoverable, they set MEGAVIBE_ALLOW_REAL_DELETE=1 in Claude Code's environment." >&2
    exit 2
  fi
fi

exit 0
