#!/bin/bash
# Local disk reports and conservative worktree removal. Bash 3.2 compatible.
set -euo pipefail
export LC_ALL=C
# Repository selection must come from paths, not a caller's Git overrides.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
export GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1

usage() {
  cat <<'EOF'
Usage: worktrees-audit.sh audit [--root DIR]... [--min-mb N] [--offline]
       worktrees-audit.sh remove-safe [--dry-run] [--offline]
       worktrees-audit.sh scratch [--days N] [--root DIR]
       worktrees-audit.sh caches

audit reports the current repository and repositories owning worktrees under
$HOME/dev/_wt, plus --root directories. Sizes are du -sk KiB; --min-mb uses MiB.
Paths and branches are shell-escaped. Dirty includes untracked and ignored files.
audit and remove-safe need network access: fetch --prune each remote and verify
its default branch with ls-remote (45 seconds per command). Fetch only updates
remote-tracking refs. --offline skips the network and prevents SAFE verdicts.
remove-safe is limited to the SAFE set: clean, fully pushed, unlocked, neither
main nor containing the current directory, and merged into the server's verified
default branch (origin, else the first remote), or detached at a remote commit.
KEEP reasons: remote-unverified = offline, absent or failed remote verification;
git-lock = Git transaction lock or an unverifiable lock scan;
pending-operation = unfinished Git operation/autostash; submodule = any indexed
gitlink, initialized or not; parked-branch = unmerged named branch; unpushed =
commits not on a verified remote. Dirty, locked, hidden-index-state, changed and
unreadable states also mean KEEP. Local safety checks run again before removal.
The tool never removes a worktree it can detect as dirty, unpushed, locked,
mid-operation, or unverifiable.
Known limit: verification and removal are not atomic. A process writing into a
worktree in the short window between the final check and removal is not protected:
git worktree remove without --force does not protect unpushed commits or ignored
files created in that window. Only remove worktrees nobody is using; this is why
remove-safe prints the list before acting.
Before removal, a flushed JSON intent records time, repo, path, branch, sha,
size (KiB) and status; afterward an outcome records removed or refused in
${MEGAVIBE_HOME:-$HOME/.megavibe}/worktrees-audit-removals.jsonl (mode 0600 where
possible), plus the project's agent-log hook on success when present. A failed
intent write means KEEP (log-write-failed). An unwritable removal log refuses all
removals. Remote verification/logging requires Perl (JSON::PP).
git worktree remove frees space at once and does NOT go through the Trash.
Only rm-style deletes go through the Trash via rm-to-trash.
scratch reports immediate child directories older than N days (default 3),
largest first, and the top 5 repo copies or virtualenvs within those directories.
caches reports sizes only; the sanctioned uv cleanup command is: uv cache prune
EOF
}
die() { printf 'worktrees-audit: %s\n' "$*" >&2; exit 2; }
warn() { printf 'worktrees-audit: %s\n' "$*" >&2; }
number() { [[ $1 =~ ^[0-9]{1,7}$ ]] || die "invalid number: $1"; }
CMD=${1:-help}
[[ $# -eq 0 ]] || shift
ROOTS=()
MIN_MB=0 DAYS=3 DRY=0 OFFLINE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $CMD == audit || $CMD == scratch ]] || die '--root requires audit or scratch'
      [[ $# -ge 2 && -d $2 ]] || die '--root needs an existing directory'
      ROOTS+=("$(cd "$2" && pwd -P)"); shift 2 ;;
    --min-mb|--days)
      OPT=$1
      [[ $# -ge 2 ]] || die "$OPT needs a number"
      number "$2"
      if [[ $OPT == --min-mb && $CMD == audit ]]; then MIN_MB=$((10#$2));
      elif [[ $OPT == --days && $CMD == scratch ]]; then DAYS=$((10#$2));
      else die "invalid option for $CMD: $OPT"; fi
      shift 2 ;;
    --dry-run) [[ $CMD == remove-safe ]] || die '--dry-run requires remove-safe'; DRY=1; shift ;;
    --offline) [[ $CMD == audit || $CMD == remove-safe ]] || die '--offline requires audit or remove-safe'; OFFLINE=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$CMD" in help|-h|--help) usage; exit 0 ;; audit|remove-safe|scratch|caches) ;; *) usage >&2; exit 2 ;; esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/worktrees-audit.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
START=$(pwd -P)
PROJECT=$(git -C "$START" rev-parse --show-toplevel 2>/dev/null) || PROJECT=''
COMMONS=()
size_kb() {
  local value
  value=$(du -sk -- "$1" 2>/dev/null) || return 1
  value=${value%%[[:space:]]*}
  [[ $value =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$value"
}
add_repo() {
  local dir=$1 common seen
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$common" in /*) ;; *) common=$dir/$common ;; esac
  common=$(cd "$common" 2>/dev/null && pwd -P) || return 0
  for seen in ${COMMONS[@]+"${COMMONS[@]}"}; do [[ $seen != "$common" ]] || return 0; done
  COMMONS+=("$common")
}
discover() {
  local root marker
  add_repo "$START"
  ROOTS+=("$HOME/dev/_wt")
  for root in ${ROOTS[@]+"${ROOTS[@]}"}; do
    [[ -d $root ]] || continue
    add_repo "$root"
    # .git files in linked worktrees resolve back to their owning common dir.
    if ! find "$root" -name .git -print0 -prune > "$WORK/discover"; then
      warn "incomplete repository discovery under $root"
    fi
    while IFS= read -r -d '' marker; do add_repo "${marker%/.git}"; done < "$WORK/discover"
  done
}

keep() { VERDICT=KEEP; REASON=${REASON:+$REASON,}$1; }

# Kill the entire network command's process group on timeout, including helpers.
# A missing Perl, failed fork/setsid/exec or timeout is a verification failure.
remote_git() {
  GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never perl -MPOSIX -e '
    my $pid = fork(); defined $pid or exit 125;
    if (!$pid) {
      POSIX::setsid() >= 0 or exit 125;
      exec @ARGV; exit 125;
    }
    $SIG{ALRM} = sub { kill "KILL", -$pid; kill "KILL", $pid; waitpid($pid, 0); exit 124 };
    alarm 45;
    waitpid($pid, 0);
    my $status = $?; alarm 0;
    exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
  ' git --git-dir="$COMMON" "$@"
}

# Only explicitly fetched branch namespaces supply reachability. In particular,
# local symbolic origin/HEAD and refs belonging to removed remotes are excluded.
verify_remotes() {
  local remotes remote selected='' head branch server_sha ref tip symbolic fetched
  REMOTE_OK=no DEFAULT_TIP='' REMOTE_TIPS=()
  [[ $OFFLINE == 0 ]] || return 0
  remotes=$(git --git-dir="$COMMON" remote 2>/dev/null) || return 0
  [[ -n $remotes ]] || return 0
  while IFS= read -r remote; do
    [[ -n $remote ]] || return 0
    # Explicit refspec and --no-tags prevent configured fetch mappings from
    # updating local branches/tags. Forced updates also detect server rollbacks.
    remote_git fetch --prune --no-prune-tags --no-tags --refmap= --no-write-fetch-head --no-recurse-submodules \
      "$remote" "+refs/heads/*:refs/remotes/$remote/*" > "$WORK/fetch" 2>&1 || return 0
    head=$(remote_git ls-remote --symref "$remote" HEAD 2>/dev/null) || return 0
    branch=$(printf '%s\n' "$head" | awk '$1 == "ref:" && $3 == "HEAD" {print $2}')
    server_sha=$(printf '%s\n' "$head" | awk '$2 == "HEAD" && $1 != "ref:" {print $1}')
    [[ $branch == refs/heads/* && $server_sha =~ ^[0-9a-f]+$ ]] || return 0
    git check-ref-format "$branch" >/dev/null 2>&1 || return 0
    ref=refs/remotes/$remote/${branch#refs/heads/}
    # The default must be a concrete fetched ref, matching the server's HEAD.
    if git --git-dir="$COMMON" symbolic-ref -q "$ref" >/dev/null 2>&1; then return 0; fi
    fetched=$(git --git-dir="$COMMON" rev-parse --verify "$ref^{commit}" 2>/dev/null) || return 0
    [[ $fetched == "$server_sha" ]] || return 0
    if [[ -z $selected || $remote == origin ]]; then selected=$remote; DEFAULT_TIP=$fetched; fi
    git --git-dir="$COMMON" for-each-ref --format='%(objectname) %(refname) %(symref)' \
      "refs/remotes/$remote/" > "$WORK/remote-refs" 2>/dev/null || return 0
    while read -r tip ref symbolic; do
      [[ -z $symbolic ]] || continue
      [[ $tip =~ ^[0-9a-f]+$ ]] || return 0
      REMOTE_TIPS+=("$tip")
    done < "$WORK/remote-refs"
  done <<< "$remotes"
  [[ ${#REMOTE_TIPS[@]} -gt 0 && -n $DEFAULT_TIP ]] || return 0
  REMOTE_OK=yes
}

# Inspect only this worktree's metadata, the common top level and common refs.
# Never follow symlinks or descend into shared objects/other worktrees. Bounds
# and all scan errors fail closed, including an unexpectedly large refs tree.
git_locks_clear() {
  perl -e '
    use strict; use warnings;
    $SIG{ALRM} = sub { exit 1 }; alarm 5;
    my ($own, $common) = @ARGV;
    my @todo = ([$common, 0, 0]);
    push @todo, [$own, 0, 1] if $own ne $common;
    my $budget = 4096;
    while (my $item = pop @todo) {
      my ($dir, $depth, $recursive) = @$item;
      lstat($dir) && -d _ && !-l _ or exit 1;
      opendir(my $dh, $dir) or exit 1;
      while (1) {
        $! = 0;
        my $name = readdir($dh);
        if (!defined $name) { $! == 0 or exit 1; last }
        next if $name eq "." || $name eq "..";
        --$budget >= 0 or exit 1;
        $name !~ /\.lock\z/ or exit 1;
        my $path = "$dir/$name";
        lstat($path) or exit 1;
        # Symlinked metadata cannot be verified without following it.
        !-l _ or exit 1;
        if (-d _ && ($recursive || $name eq "refs")) {
          $depth < 32 or exit 1;
          push @todo, [$path, $depth + 1, 1];
        }
      }
      closedir($dh) or exit 1;
    }
  ' "$1" "$COMMON" 2>/dev/null
}

assess() {
  local actual common entry logs rc gitdir marker
  SIZE='?' DIRTY='?' UNPUSHED='?' MERGED=no DATE='?' SHA='?'
  VERDICT=SAFE REASON=''
  [[ $MAIN == no ]] || keep main-worktree
  [[ $LOCKED == no ]] || keep locked
  [[ $META_OK == yes ]] || keep unreadable-metadata
  if [[ -n $PROJECT && $PROJECT -ef $WT ]]; then keep current-worktree;
  else
    # Identity works through case aliases and symlinks. Walking ancestors also
    # covers invocation inside a nested repository with a different top level.
    actual=$START
    while :; do
      if [[ $actual -ef $WT ]]; then keep current-worktree; break; fi
      [[ $actual != / ]] || break
      actual=${actual%/*}; actual=${actual:-/}
    done
  fi
  [[ $REMOTE_OK == yes ]] || keep remote-unverified
  SIZE=$(size_kb "$WT") || { SIZE='?'; keep unreadable-size; }
  actual=$(cd "$WT" 2>/dev/null && pwd -P) || { keep unreadable-path; return; }
  [[ $actual == "$WT" ]] || { keep changed-path; return; }
  actual=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) || { keep unreadable-worktree; return; }
  [[ $actual == "$WT" ]] || { keep wrong-worktree; return; }
  common=$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null) || { keep unreadable-common-dir; return; }
  case "$common" in /*) ;; *) common=$WT/$common ;; esac
  common=$(cd "$common" 2>/dev/null && pwd -P) || { keep unreadable-common-dir; return; }
  [[ $common == "$COMMON" ]] || { keep wrong-repository; return; }
  gitdir=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null) || { keep unreadable-git-dir; return; }
  git_locks_clear "$gitdir" || keep git-lock
  for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer AUTO_MERGE; do
    if [[ -e $gitdir/$marker || -L $gitdir/$marker ]]; then keep pending-operation; break; fi
  done
  # Autostashes can live at the top level or inside operation directories.
  if find "$gitdir" -iname '*autostash*' -print > "$WORK/autostashes" 2>/dev/null; then
    if [[ -s $WORK/autostashes && $REASON != *pending-operation* ]]; then keep pending-operation; fi
  else keep unreadable-git-dir; fi
  SHA=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || { SHA='?'; keep unreadable-head; return; }
  [[ $SHA == "$LIST_SHA" ]] || keep changed-head
  if actual=$(git -C "$WT" symbolic-ref -q HEAD 2>/dev/null); then
    [[ $DETACHED == no && $actual == "refs/heads/$BRANCH" ]] || keep changed-branch
  else
    rc=$?
    [[ $rc == 1 && $DETACHED == yes ]] || keep unreadable-branch
  fi
  # NUL records count names with newlines correctly, including rename pairs.
  if git -C "$WT" status --porcelain=v1 -z --untracked-files=all --ignored --ignore-submodules=none > "$WORK/status" 2>/dev/null; then
    DIRTY=0
    while IFS= read -r -d '' entry; do
      DIRTY=$((DIRTY + 1))
      case "${entry:0:2}" in *R*|*C*) IFS= read -r -d '' entry || keep unreadable-status ;; esac
    done < "$WORK/status"
    [[ $DIRTY == 0 ]] || keep dirty
  else keep unreadable-status; fi
  # status can hide modified tracked files behind these index flags. Refuse
  # those trees rather than altering their index to inspect them.
  if git -C "$WT" ls-files -v -z > "$WORK/index" 2>/dev/null; then
    while IFS= read -r -d '' entry; do
      case "$entry" in [a-zS]*) DIRTY='?'; keep hidden-index-state; break ;; esac
    done < "$WORK/index"
  else DIRTY='?'; keep unreadable-index; fi
  # status hides local files inside uninitialized gitlinks, even with --ignored.
  # Keep every indexed submodule, whether or not its .git exists.
  if git -C "$WT" ls-files --stage -z > "$WORK/modules" 2>/dev/null; then
    while IFS= read -r -d '' entry; do
      [[ $entry == '160000 '* ]] || continue
      keep submodule; break
    done < "$WORK/modules"
  else keep unreadable-submodules; fi
  if [[ $REMOTE_OK == yes ]]; then
    # Pin the fetched tips: never let stale symbolic refs participate in log.
    if logs=$(git -C "$WT" log --oneline HEAD --not "${REMOTE_TIPS[@]}" -- 2>/dev/null); then
      UNPUSHED=$(printf '%s\n' "$logs" | awk 'NF {n++} END {print n+0}')
      [[ $UNPUSHED == 0 ]] || keep unpushed
    else keep unreadable-unpushed; fi
    if git -C "$WT" merge-base --is-ancestor HEAD "$DEFAULT_TIP" 2>/dev/null; then MERGED=yes;
    else rc=$?; [[ $rc == 1 ]] || keep unreadable-ancestry; fi
    if [[ $DETACHED == yes ]]; then
      [[ $UNPUSHED == 0 ]] || keep detached-not-on-remote
    elif [[ $MERGED != yes ]]; then keep parked-branch; fi
  fi
  DATE=$(git -C "$WT" log -1 --format=%cI HEAD 2>/dev/null) || { DATE='?'; keep unreadable-date; }
  [[ -n $DATE ]] || keep unreadable-date
  [[ -n $REASON ]] || REASON=clean-pushed-merged-or-detached-on-remote
}
row() {
  printf '%q\t%s\t%s\t%s\t%s\t%s\t%q\t%s\t%s\t%s\n' \
    "$WT" "$SIZE" "$DIRTY" "$UNPUSHED" "$MERGED" "$DATE" "$BRANCH" "$LOCKED" "$VERDICT" "$REASON"
}
# Each invocation reads a complete successful porcelain snapshot before trusting it.
walk() {
  local target=${1:-} file=$2 token
  WT='' LIST_SHA='' BRANCH=detached DETACHED=no LOCKED=no MAIN=yes META_OK=yes
  while IFS= read -r -d '' token; do
    case "$token" in
      'worktree '*) WT=${token#worktree } ;;
      'HEAD '*) LIST_SHA=${token#HEAD } ;;
      'branch refs/heads/'*) BRANCH=${token#branch refs/heads/} ;;
      detached) DETACHED=yes ;;
      locked|'locked '*) LOCKED=yes ;;
      bare|prunable|'prunable '*) META_OK=no ;;
      '')
        if [[ -n $WT && ( -z $target || $WT == "$target" ) ]]; then
          assess
          if [[ -n $target ]]; then return 0; fi
          if [[ $SIZE == '?' ]] || (( SIZE >= MIN_MB * 1024 )); then row; fi
          if [[ $CMD == remove-safe && $VERDICT == SAFE ]]; then printf '%s\0%s\0' "$COMMON" "$WT" >> "$WORK/candidates"; fi
        fi
        WT='' LIST_SHA='' BRANCH=detached DETACHED=no LOCKED=no MAIN=no META_OK=yes ;;
      *) META_OK=no ;;
    esac
  done < "$file"
  [[ -z $target ]]
}

prepare_removal_log() {
  local dir=${MEGAVIBE_HOME:-$HOME/.megavibe}
  REMOVAL_LOG=$dir/worktrees-audit-removals.jsonl
  perl -MJSON::PP -e 'exit 0' >/dev/null 2>&1 || die 'cannot encode removal log (Perl JSON::PP required); nothing removed'
  (umask 077; mkdir -p -- "$dir") || die "cannot create removal log directory: $dir; nothing removed"
  [[ -d $dir && -w $dir ]] || die "removal log directory is not writable: $dir; nothing removed"
  if [[ -e $REMOVAL_LOG || -L $REMOVAL_LOG ]]; then
    [[ -f $REMOVAL_LOG && ! -L $REMOVAL_LOG && -w $REMOVAL_LOG ]] || die "removal log is not a writable regular file: $REMOVAL_LOG; nothing removed"
  fi
  (umask 077; : >> "$REMOVAL_LOG") || die "cannot open removal log: $REMOVAL_LOG; nothing removed"
  chmod 600 "$REMOVAL_LOG" 2>/dev/null || :
  exec 3>> "$REMOVAL_LOG" || die "cannot open removal log: $REMOVAL_LOG; nothing removed"
}

write_removal_event() {
  # Check print, flush and close: opening a log does not prove it accepts writes.
  perl -MJSON::PP -MPOSIX=strftime -MIO::Handle -e '
    print STDOUT encode_json({ time => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime),
      repo => $ARGV[0], path => $ARGV[1], branch => $ARGV[2], sha => $ARGV[3],
      size => 0 + $ARGV[4], status => $ARGV[5] }), "\n" or die "log write: $!";
    STDOUT->flush or die "log flush: $!";
    close STDOUT or die "log close: $!";
  ' "$COMMON" "$WT" "$removed_branch" "$removed_sha" "$amount" "$1" >&3
}

worktrees() {
  local candidate freed=0 amount removed_branch removed_sha verified_common=''
  discover
  : > "$WORK/candidates"
  printf 'PATH\tSIZE_KIB\tDIRTY\tUNPUSHED\tMERGED\tLAST_COMMIT\tBRANCH\tLOCKED\tVERDICT\tREASON\n'
  for COMMON in ${COMMONS[@]+"${COMMONS[@]}"}; do
    verify_remotes
    if git --git-dir="$COMMON" worktree list --porcelain -z > "$WORK/list"; then walk '' "$WORK/list";
    else warn "KEEP: cannot list worktrees for $COMMON"; fi
  done
  [[ $CMD == remove-safe ]] || return 0
  if [[ $DRY == 0 && -s $WORK/candidates ]]; then prepare_removal_log; fi
  while IFS= read -r -d '' COMMON && IFS= read -r -d '' candidate; do
    # Candidates are grouped by repository. Refresh once more for this pass.
    if [[ $verified_common != "$COMMON" ]]; then verify_remotes; verified_common=$COMMON; fi
    if ! git --git-dir="$COMMON" worktree list --porcelain -z > "$WORK/recheck" || ! walk "$candidate" "$WORK/recheck"; then
      warn "KEEP: cannot recheck $candidate"; continue
    fi
    if [[ $VERDICT != SAFE ]]; then row; continue; fi
    if [[ $DRY == 1 ]]; then printf 'WOULD_REMOVE\t%q\t%s KiB\n' "$WT" "$SIZE"; continue; fi
    amount=$SIZE removed_branch=$BRANCH removed_sha=$SHA
    if ! write_removal_event intent; then
      REASON=''; keep log-write-failed; row; continue
    fi
    if git --git-dir="$COMMON" worktree remove -- "$WT"; then
      write_removal_event removed || die "removal outcome write failed after removing $WT; intent logged; stopping removals"
      freed=$((freed + amount))
      printf 'REMOVED\t%q\tfreed %s KiB (du estimate)\n' "$WT" "$amount"
      if [[ -n $PROJECT && -f $PROJECT/.claude/hooks/agent-log.sh ]]; then
        if ! printf 'worktree removal: path=%q branch=%q sha=%s size_kib=%s\n' "$WT" "$removed_branch" "$removed_sha" "$amount" |
          /bin/bash "$PROJECT/.claude/hooks/agent-log.sh" append --project "$PROJECT"; then warn "removal log failed for $WT"; fi
      fi
    else
      write_removal_event refused || die "removal outcome write failed for $WT; intent logged; stopping removals"
      warn "KEEP: git worktree remove refused $WT"
    fi
  done < "$WORK/candidates"
  printf 'Freed: %s KiB (du estimate)\n' "$freed"
}
scratch() {
  local parent root dir marker kb escaped
  : > "$WORK/scratch-roots"
  for root in ${ROOTS[@]+"${ROOTS[@]}"}; do printf '%s\0' "$root" >> "$WORK/scratch-roots"; done
  for parent in /private/tmp/claude-* "${TMPDIR:-/tmp}"/claude-*; do
    [[ -d $parent ]] || continue
    find "$parent" -type d -name scratchpad -print0 -prune >> "$WORK/scratch-roots" || warn "incomplete scratch search: $parent"
  done
  : > "$WORK/old"; : > "$WORK/copies"
  while IFS= read -r -d '' root; do
    find "$root" -mindepth 1 -maxdepth 1 -type d -mmin "+$((DAYS * 1440))" -print0 > "$WORK/children" || warn "incomplete scratch search: $root"
    while IFS= read -r -d '' dir; do
      if kb=$(size_kb "$dir"); then printf -v escaped '%q' "$dir"; printf '%s\t%s\n' "$kb" "$escaped" >> "$WORK/old";
      else warn "unreadable size: $dir"; fi
      find "$dir" \( -name .git -o -name pyvenv.cfg \) -print0 -prune > "$WORK/markers" || warn "incomplete copy search: $dir"
      while IFS= read -r -d '' marker; do
        parent=${marker%/*}
        if kb=$(size_kb "$parent"); then printf -v escaped '%q' "$parent"; printf '%s\t%s\n' "$kb" "$escaped" >> "$WORK/copies";
        else warn "unreadable size: $parent"; fi
      done < "$WORK/markers"
    done < "$WORK/children"
  done < "$WORK/scratch-roots"
  printf 'SIZE_KIB\tSCRATCH_DIRECTORY (older than %s days)\n' "$DAYS"
  sort -u "$WORK/old" | sort -nr
  printf 'SIZE_KIB\tTOP_5_REPO_COPIES_OR_VIRTUALENVS\n'
  sort -u "$WORK/copies" | sort -nr | sed -n '1,5p'
}
caches() {
  local dir kb
  for dir in "$HOME/.cache/uv" "$HOME/.cache/huggingface" "$HOME/.colima" "$HOME/.pyenv" "$HOME/Library/Caches"; do
    [[ -e $dir ]] || continue
    kb=$(size_kb "$dir") || kb='?'
    printf '%q\t%s KiB\n' "$dir" "$kb"
  done
  printf 'Sanctioned safe command: uv cache prune\n'
}
case "$CMD" in audit|remove-safe) worktrees ;; scratch) scratch ;; caches) caches ;; esac
