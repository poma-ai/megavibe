#!/bin/bash
# Read-only template checker and scratch-copy mutations. Compatible with Bash 3.2.
# Front matter supports single-line scalars; YAML collections/multiline values
# are explicitly unsupported. No launcher, skill command or backend is run.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
INVENTORY='catchup clip doc-review finish-feature init-feature megavibe-restart prune-context rehydrate watch'

validate_skill() {
  awk -v skill="$2" '
    function fail(message) { print FILENAME ":" NR ": " message > "/dev/stderr"; bad=1 }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function scalar(s, q,i,c,rest) {
      s=trim(s); quoted=0
      q=substr(s,1,1)
      if(q == "\042" || q == "\047") {
        quoted=1
        for(i=2;i<=length(s);i++) {
          c=substr(s,i,1)
          if(c == q) {
            rest=trim(substr(s,i+1))
            if(rest != "" && rest !~ /^#/) fail("unsupported quoted scalar syntax")
            s=substr(s,2,i-2)
            if(q == "\042" && index(s,"\\")) fail("unsupported quoted scalar escape")
            return s
          }
        }
        fail("unterminated quoted scalar"); return ""
      }
      sub(/[ \t]+#.*/, "", s); s=trim(s)
      if(s == "" || s ~ /^[\[\]{}|>&*!]/) fail("unsupported scalar or YAML collection")
      return s
    }
    function unrestricted(s, cmd,rest) {
      if(s == "Bash" || s == "Bash(*)") return 1
      if(s !~ /^Bash\(/) return 0
      s=substr(s,6,length(s)-6)
      cmd=s; sub(/ .*/, "", cmd)
      rest=trim(substr(s,length(cmd)+1)); sub(/^.*\//, "", cmd)
      if(cmd ~ /^(bash|sh|zsh|dash|ksh|fish|csh|tcsh|python[^ ]*|perl|ruby|node|php|lua|env|eval)$/)
        return (rest == "" || rest == "*" || rest ~ /^-/ || cmd == "env" || cmd == "eval")
      return 0
    }
    function glob_regex(s, out,i,c) {
      out="^"
      for(i=1;i<=length(s);i++) {
        c=substr(s,i,1)
        if(c == "*") out=out ".*"
        else if(index(".[]^$+?(){}|\\",c)) out=out "\\" c
        else out=out c
      }
      return out "$"
    }
    function grants(s, reason, n,a,i,g,command,pattern) {
      n=split(s,a,",")
      for(i=1;i<=n;i++) {
        g=trim(a[i])
        if(g !~ /^[A-Za-z][A-Za-z0-9_]*$/ && g !~ /^Bash\([^()]+\)$/)
          fail("unsupported allowed-tools grant: " g)
        if(unrestricted(g) && !reason) fail("unrestricted Bash requires a reason directly above allowed-tools")
        if(skill == "finish-feature") {
          if(unrestricted(g)) fail("finish-feature must not pre-approve gh pr merge")
          if(g ~ /^Bash\(/) {
            command=substr(g,6,length(g)-6)
            pattern=glob_regex(command)
            if(command ~ /^gh pr merge([ *]|$)/ || "gh pr merge" ~ pattern || "gh pr merge 1 --squash" ~ pattern)
              fail("finish-feature must not pre-approve gh pr merge")
          }
        }
      }
    }
    NR == 1 { if($0 !~ /^---[ \t]*$/) fail("missing opening front matter"); next }
    closed { next }
    /^---[ \t]*$/ { closed=1; next }
    /^[ \t]*#/ || /^[ \t]*$/ { prev=$0; next }
    {
      if($0 !~ /^[a-z][a-z-]*:[ \t]*/) {
        fail("unsupported front matter syntax (including YAML block lists)"); next
      }
      key=$0; sub(/:.*/, "", key)
      if(key !~ /^(name|description|allowed-tools|disable-model-invocation|user-invocable|argument-hint)$/)
        fail("unsupported front matter key: " key)
      if(key in value) fail("duplicate front matter key: " key)
      raw=$0; sub(/^[^:]+:[ \t]*/, "", raw)
      value[key]=scalar(raw)
      if(key == "disable-model-invocation" || key == "user-invocable") {
        if(quoted || value[key] !~ /^(true|false)$/) fail("invocation policy must be an unquoted YAML boolean")
      }
      if(key == "allowed-tools") grants(value[key], prev ~ /^[ \t]*#[ \t]*[^ \t#]/)
      prev=$0
    }
    END {
      if(!closed) fail("missing closing front matter")
      if(value["name"] != skill) fail("front matter name must match directory")
      if(value["description"] == "") fail("description is required")
      if(skill ~ /^(rehydrate|catchup|doc-review|init-feature|watch)$/ && value["disable-model-invocation"] == "true")
        fail(skill " must remain model-invocable")
      if(skill ~ /^(megavibe-restart|finish-feature|prune-context)$/ && value["disable-model-invocation"] != "true")
        fail(skill " must remain manual-only")
      if(skill ~ /^(megavibe-restart|finish-feature)$/ && value["user-invocable"] != "true")
        fail(skill " must remain user-invocable")
      exit bad ? 1 : 0
    }
  ' "$1"
}

validate_docs() {
  local root=$1 f bad=0
  local docs=("$root/CLAUDE.md" "$root/template/CLAUDE.md" "$root"/README*.md)
  # Include nested rule documents and every shipped skill text.
  while IFS= read -r f; do docs+=("$f"); done < <(find "$root/template/.claude/rules" -type f -name '*.md')
  for f in "$root"/template/.claude/skills/*/SKILL.md; do docs+=("$f"); done
  for f in "${docs[@]}"; do
    [ "$f" != "$root/README-delegation-measurements.md" ] || continue
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      printf 'Missing readable document: %s\n' "$f" >&2; bad=1; continue
    fi
    if ! awk -v readme="$root/README.md" '
      /(^|[^[:alnum:]_.\/-])\/copy([^[:alnum:]_-]|$)/ {
        if(FILENAME == readme && /^\*\*Upgrading from the custom `\/copy` skill:\*\*/) next
        print FILENAME ":" FNR ": retired custom /copy reference" > "/dev/stderr"; bad=1
      }
      END { exit bad ? 1 : 0 }
    ' "$f"; then bad=1; fi
  done
  return "$bad"
}

validate_tree() {
  local root=$1 name dir bad=0
  local skills="$root/template/.claude/skills"
  for name in $INVENTORY; do
    if [ ! -f "$skills/$name/SKILL.md" ] || [ ! -r "$skills/$name/SKILL.md" ]; then
      printf 'Missing readable shipped skill: %s\n' "$name" >&2
      bad=1
    elif ! validate_skill "$skills/$name/SKILL.md" "$name"; then bad=1; fi
  done
  for dir in "$skills"/*; do
    name=${dir##*/}
    case " $INVENTORY " in
      *" $name "*) ;;
      *) printf 'Unexpected skill inventory entry: %s\n' "$name" >&2; bad=1 ;;
    esac
  done
  if [ ! -d "$root/template/.claude/rules" ]; then
    printf 'Missing rules directory\n' >&2; bad=1
  else
    validate_docs "$root" || bad=1
  fi
  return "$bad"
}

# This mode runs the same checker without recursively running the mutations.
if [ "${1:-}" = --check ]; then
  [ "$#" -eq 2 ] || { printf 'Usage: %s --check ROOT\n' "$0" >&2; exit 2; }
  validate_tree "$2"
  exit $?
fi
[ "$#" -eq 0 ] || { printf 'Unexpected arguments\n' >&2; exit 2; }

PASS=0; FAIL=0; NEGATIVE=0
check() {
  local label=$1; shift
  if "$@"; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
check 'shipped templates' validate_tree "$REPO"
# Broken real templates must fail, even if all mutation expectations would pass.
[ "$FAIL" -eq 0 ] || { printf 'passed=%s failed=%s negative=%s\n' "$PASS" "$FAIL" "$NEGATIVE"; exit 1; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/skills-test.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
BASE="$SCRATCH/base"
FIXTURE="$SCRATCH/fixture"
mkdir -p "$BASE/template/.claude"
cp -R "$REPO/template/.claude/skills" "$REPO/template/.claude/rules" "$BASE/template/.claude/"
cp "$REPO/CLAUDE.md" "$REPO"/README*.md "$BASE/"
cp "$REPO/template/CLAUDE.md" "$BASE/template/"
reset_fixture() { rm -rf "$FIXTURE"; cp -R "$BASE" "$FIXTURE"; }
# Replace a key (or insert it if absent), optionally with an immediately preceding
# comment. Mutations edit only the scratch copies, never the checked-out files.
set_field() {
  local name=$1 key=$2 value=$3 reason=${4:-}
  local file="$FIXTURE/template/.claude/skills/$name/SKILL.md"
  SKILL_TEST_VALUE="$value" SKILL_TEST_REASON="$reason" awk -v key="$key" '
    BEGIN { value=ENVIRON["SKILL_TEST_VALUE"]; reason=ENVIRON["SKILL_TEST_REASON"] }
    NR == 1 { print; if(reason != "") print reason; print key ": " value; next }
    /^---$/ { closed=1 }
    !closed && index($0,key ":") == 1 { next }
    { print }
  ' "$file" > "$SCRATCH/edit"
  mv "$SCRATCH/edit" "$file"
}
expect_failure() {
  local diagnostic=$1
  NEGATIVE=$((NEGATIVE + 1))
  if validate_tree "$FIXTURE" > "$SCRATCH/result" 2>&1; then
    printf 'Checker incorrectly accepted mutation\n' >&2; return 1
  fi
  if ! grep -Fq "$diagnostic" "$SCRATCH/result"; then
    cat "$SCRATCH/result" >&2; return 1
  fi
}

# Exact inventory, including the review reproduction (missing rehydrate).
for name in $INVENTORY; do
  reset_fixture
  rm "$FIXTURE/template/.claude/skills/$name/SKILL.md"
  check "missing $name fails" expect_failure "Missing readable shipped skill: $name"
done
reset_fixture
mkdir "$FIXTURE/template/.claude/skills/copy"
check 'retired directory fails inventory' expect_failure 'Unexpected skill inventory entry: copy'
reset_fixture
mkdir "$FIXTURE/template/.claude/skills/unexpected"
check 'extra directory fails inventory' expect_failure 'Unexpected skill inventory entry: unexpected'

# Invocation policy and scalar parsing: inline comments and trailing space are
# interpreted; quoted booleans are explicitly rejected rather than misread.
for name in rehydrate catchup doc-review init-feature watch; do
  for value in true 'true # manual only' 'true   ' '"true"' "'true'"; do
    reset_fixture
    set_field "$name" disable-model-invocation "$value"
    check "$name rejects manual-only value: $value" expect_failure 'must remain model-invocable'
  done
done
for name in megavibe-restart finish-feature prune-context; do
  reset_fixture
  set_field "$name" disable-model-invocation 'false # model may start it'
  check "$name rejects model invocation" expect_failure 'must remain manual-only'
  reset_fixture
  sed '/^disable-model-invocation:/d' "$FIXTURE/template/.claude/skills/$name/SKILL.md" > "$SCRATCH/edit"
  mv "$SCRATCH/edit" "$FIXTURE/template/.claude/skills/$name/SKILL.md"
  check "$name requires explicit manual policy" expect_failure 'must remain manual-only'
done
for value in 'false # still automatic' 'false   '; do
  reset_fixture
  set_field rehydrate disable-model-invocation "$value"
  set_field finish-feature disable-model-invocation 'true # manual only'
  check "valid commented/space-padded booleans: $value" validate_tree "$FIXTURE"
done
reset_fixture
set_field rehydrate disable-model-invocation '"false"'
check 'quoted false is explicitly unsupported' expect_failure 'unquoted YAML boolean'
reset_fixture
set_field watch user_invocable true
check 'misspelled invocation key fails' expect_failure 'unsupported front matter syntax'
reset_fixture
set_field catchup name '"catchup" # quoted name'
check 'quoted scalar name is interpreted' validate_tree "$FIXTURE"
reset_fixture
set_field catchup name "'copy' # wrong quoted name"
check 'wrong quoted name fails' expect_failure 'name must match directory'
reset_fixture
set_field catchup name '"catchup'
check 'unterminated scalar fails' expect_failure 'unterminated quoted scalar'
reset_fixture
sed '1d' "$FIXTURE/template/.claude/skills/rehydrate/SKILL.md" > "$SCRATCH/edit"
mv "$SCRATCH/edit" "$FIXTURE/template/.claude/skills/rehydrate/SKILL.md"
check 'missing opening front matter fails' expect_failure 'missing opening front matter'
reset_fixture
sed '4d' "$FIXTURE/template/.claude/skills/rehydrate/SKILL.md" > "$SCRATCH/edit"
mv "$SCRATCH/edit" "$FIXTURE/template/.claude/skills/rehydrate/SKILL.md"
check 'missing closing front matter fails' expect_failure 'missing closing front matter'
reset_fixture
set_field catchup allowed-tools $'\n  - Read\n  - Bash # unrestricted shell'
check 'block-list review reproduction fails explicitly' expect_failure 'unsupported scalar or YAML collection'
reset_fixture
set_field catchup allowed-tools '[Read, Bash]'
check 'flow list fails explicitly' expect_failure 'unsupported scalar or YAML collection'

# Whole-shell grants must have an adjacent reason, including quoted scalars.
for grant in 'Bash' 'Bash(*)' 'Bash(bash *)' 'Bash(sh *)' 'Bash(zsh *)' 'Bash(python* *)' 'Bash(python3 *)' 'Bash(env *)' 'Bash(eval *)'; do
  reset_fixture
  set_field catchup allowed-tools "Read, $grant # inline comment is not a reason"
  check "unexplained $grant fails" expect_failure 'unrestricted Bash requires a reason'
  reset_fixture
  set_field catchup allowed-tools "Read, $grant" '# Project-specific implementation commands need unrestricted execution.'
  check "explained $grant is accepted" validate_tree "$FIXTURE"
done
reset_fixture
set_field catchup allowed-tools '"Read, Bash(*)" # quoted scalar'
check 'quoted unrestricted grant fails' expect_failure 'unrestricted Bash requires a reason'
reset_fixture
set_field catchup allowed-tools 'Bash' '#   '
check 'empty reason fails' expect_failure 'unrestricted Bash requires a reason'
reset_fixture
set_field catchup allowed-tools 'Bash' $'# Project-specific commands.\n'
check 'nonadjacent reason fails' expect_failure 'unrestricted Bash requires a reason'
reset_fixture
set_field catchup allowed-tools 'Bash'
printf '\n# A body comment is not a grant reason.\n' >> "$FIXTURE/template/.claude/skills/catchup/SKILL.md"
check 'body reason fails' expect_failure 'unrestricted Bash requires a reason'
reset_fixture
set_field catchup allowed-tools 'Bash(bash ~/.megavibe/scripts/tick.sh *)'
check 'specific script through bash needs no reason' validate_tree "$FIXTURE"
reset_fixture
set_field catchup allowed-tools '"Read, Bash(git status *)" # scoped tools'
check 'quoted scoped grant with inline comment is interpreted' validate_tree "$FIXTURE"

# Current docs cannot reintroduce the retired custom command. The exception is
# only the named upgrade paragraph, not every /copy mention in README.md.
for path in CLAUDE.md template/CLAUDE.md README.md README-watcher.md template/.claude/rules/delegation.md template/.claude/skills/clip/SKILL.md; do
  reset_fixture
  printf '\nUse `/copy` for the clipboard.\n' >> "$FIXTURE/$path"
  check "retired reference fails in $path" expect_failure 'retired custom /copy reference'
done
reset_fixture
printf '\nDated record: `/copy`.\n' >> "$FIXTURE/README-delegation-measurements.md"
check 'dated measurement record is excepted' validate_tree "$FIXTURE"
for grant in 'Bash(gh pr merge *)' 'Bash(gh pr merge)' 'Bash(gh pr merge --admin *)' 'Bash(gh pr *)' 'Bash(gh *)' 'Bash(*)'; do
  reset_fixture
  set_field finish-feature allowed-tools "$grant" '# Even an explanation must not pre-approve a merge.'
  check "finish-feature rejects merge through $grant" expect_failure 'must not pre-approve gh pr merge'
done

printf 'passed=%s failed=%s negative=%s\n' "$PASS" "$FAIL" "$NEGATIVE"
[ "$FAIL" -eq 0 ]
