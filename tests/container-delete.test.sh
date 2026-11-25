#!/bin/bash
# /bin/bash tests/container-delete.test.sh
# Container deletes (kubectl/oc/docker/podman exec, docker compose exec) go to the permission
# prompt like a remote delete; ordinary container commands must not. Only the hook text is read.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$REPO/template/.claude/hooks/block-dangerous-bash.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/container-delete-test.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
trap '/bin/rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# a stand-in rmtrash, so the local real-delete guard is active as on a set-up Mac
mkdir -p "$T/bin" "$T/cwd" "$T/home"; printf '#!/bin/bash\nexit 0\n' > "$T/bin/rmtrash"; chmod +x "$T/bin/rmtrash"
export HOME="$T/home"
cd "$T/cwd" || exit 2
export PATH="$T/bin:$PATH"
printf 'cd /srv/app\nrm -rf releases/old\n' > "$T/cwd/del.sh"
printf 'cd /srv/app\ngit pull\nls releases\n' > "$T/cwd/plain.sh"
printf 'rm /upload/old.zip\nbye\n' > "$T/cwd/batch.txt"

run() {   # run <command text>: sets RC, OUT (stdout), WHY (the ask reason, empty if none)
  OUT=$(jq -n --arg c "$1" --arg d "$T/cwd" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | bash "$HOOK" 2>/dev/null); RC=$?
  WHY=$(printf '%s' "$OUT" | jq -r 'select(.hookSpecificOutput.permissionDecision == "ask") | .hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
}
asks() {  # asks <name> <command> [text the reason must contain]...
  local name=$1; run "$2"; shift 2
  if [ "$RC" != 0 ] || [ -z "$WHY" ]; then bad "$name (rc=$RC, no ask)"; return; fi
  local s; for s in "$@"; do case "$WHY" in *"$s"*) ;; *) bad "$name (reason lacks: $s)"; return ;; esac; done
  ok
}
passes() { run "$2"; if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "$1 (rc=$RC out=${OUT:0:80})"; fi; }
blocks() { run "$2"; if [ "$RC" = 2 ]; then ok; else bad "$1 (rc=$RC)"; fi; }
# stops: asked about, or blocked by the local guard (a shell word outside the quotes): never a silent pass
stops() { run "$2"; if [ "$RC" = 2 ] || [ -n "$WHY" ]; then ok; else bad "$1 (rc=$RC, passed silently)"; fi; }


# asks: a delete in the container, named with the container
asks "docker exec argv" "docker exec web rm -r /data" "container web" "/data"
asks "docker exec flags" "docker exec -it -u root -w /app web rm -rf cache" "container web" "cache"
asks "docker exec sh -c" "docker exec web sh -c \"rm -r /data/old\"" "container web" "/data/old"
asks "podman exec" "podman exec web rm /tmp/x" "container web" "/tmp/x"
asks "docker container exec" "docker container exec web rm /tmp/x" "/tmp/x"
asks "docker compose exec" "docker compose -f dc.yml exec -T app rm -rf /var/cache/app" "container app" "/var/cache/app"
asks "docker-compose exec" "docker-compose exec app sh -c 'find /tmp -mtime +9 -delete'" "container app" "find -delete"
asks "kubectl exec after --" "kubectl -n staging exec mypod -- rm -rf /data" "pod mypod" "/data"
asks "kubectl exec bash -lc" "kubectl -n staging exec -c app mypod -- bash -lc 'cd /srv && rm -r old'" "pod mypod" "old"
asks "oc exec" "oc -n dev exec mypod -- rm /tmp/f" "pod mypod" "/tmp/f"
asks "after && in a longer command" "echo hi && docker exec web rm -r /data" "/data"
# passes: ordinary container commands
passes "docker exec ls" "docker exec web ls -la /data"
passes "docker exec cat" "docker exec -it web cat /etc/os-release"
passes "docker exec env" "docker exec web env"
passes "docker exec test run" "docker exec web sh -c 'npm test && echo rm done'"
passes "docker exec path named rm" "docker exec web cat /usr/share/doc/rm/README"
passes "docker exec mv" "docker exec web mv /data/a /data/b"
passes "docker ps" "docker ps -a"
passes "docker run rm flag" "docker run --rm alpine ls"
passes "docker rm of a container is not a container delete" "docker rm -f web"
passes "kubectl exec ls" "kubectl -n staging exec mypod -- ls /data"
passes "kubectl exec sh -c grep" "kubectl -n staging exec mypod -- sh -c 'grep -r error /var/log | head'"
passes "kubectl get pods" "kubectl -n staging get pods"
passes "compose exec ls" "docker compose exec app ls"
passes "text mentioning exec and rm" "git commit -m 'docker exec web rm: note'"
blocks "a local quoted rm next to a container command stays blocked" "docker exec web sh -c 'ls'; echo \"\$(rm -rf /local)\""
blocks "a local sh -c rm after a container command stays blocked" "docker exec web ls; sh -c \"rm -r /local\""
passes "docker exec ls before a pipe" "docker exec web ls | grep rm"
asks "container delete after sudo" "sudo docker exec web rm /x" "/x"
blocks "a container command inside a quoted substitution is not stripped" "echo \"\$(docker exec web ls)\"; sh -c \"rm -r /local\""
# the kubectl production guard keeps precedence
blocks "kubectl prod exec stays blocked" "kubectl -n prod exec mypod -- rm -rf /data"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
