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
