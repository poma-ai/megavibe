#!/bin/bash
# Read-only template checker and scratch-copy mutations. Compatible with Bash 3.2.
# Front matter supports single-line scalars; YAML collections/multiline values
# are explicitly unsupported. No launcher, skill command or backend is run.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
INVENTORY='catchup clip compaction-lifecycle delegation disk-and-trash doc-review finish-feature init-feature megavibe-restart process-discipline prod-access-discipline prune-context rehydrate spinouts watch'

validate_skill() {
  awk -v skill="$2" '
    # Golden Bash sets: changes require an intentional update here, including
    # removals. Empty lists are intentional. Compare after prefix normalization.
    BEGIN {
      golden["catchup"]="Bash(git log *), Bash(git diff *), Bash(git branch --show-current *), Bash(git fetch *), Bash(git status *)"
      golden["clip"]="Bash(pbcopy *), Bash(xclip -selection clipboard *), Bash(xsel --clipboard *), Bash(clip.exe *)"
      golden["doc-review"]="Bash(ls CLAUDE.md README*.md *), Bash(find docs -maxdepth 2 -name *), Bash(bash ~/.megavibe/scripts/amass.sh *), Bash(bash ~/.megavibe/scripts/usage-route.sh *), Bash(bash ~/.megavibe/scripts/reviewers.sh *), Bash(bash ~/.megavibe/scripts/codex-progress.sh *), Bash(bash ~/.megavibe/scripts/codex-review.sh *), Bash(bash ~/.megavibe/scripts/gemini-review.sh *)"
      golden["finish-feature"]="Bash(bash .claude/skills/finish-feature/session-cost.sh *), Bash(git fetch *), Bash(git diff *), Bash(jq *), Bash(git symbolic-ref -q HEAD *), Bash(ls .agent/PLANS/*-brief.md *), Bash(grep -rl *), Bash(tail -5 *), Bash(grep -A20 *), Bash(gh issue view *), Bash(gh auth status *), Bash(gh repo view *), Bash(gh pr view *), Bash(gh pr create *), Bash(gh pr comment *), Bash(printf *), Bash(echo *), Bash(true *), Bash(.claude/hooks/agent-log.sh append *)"
      # Arbitrary Bash is needed for project-specific implementation and verification on the user-chosen vibe route.
      golden["init-feature"]="Bash"
      golden["megavibe-restart"]=""
      golden["prune-context"]=""
      golden["rehydrate"]=""
      # Procedure skills moved out of the eager rules: read-only text, no grants.
      golden["compaction-lifecycle"]=""
      golden["delegation"]=""
      golden["disk-and-trash"]=""
      golden["process-discipline"]=""
      golden["prod-access-discipline"]=""
      golden["spinouts"]=""
      golden["watch"]="Bash(bash ~/.megavibe/scripts/tick.sh *), Bash(bash ~/.megavibe/scripts/claude-auth-check.sh *), Bash(basename *), Bash(printf *), Bash(shasum *), Bash(cut -c1-6 *), Bash(gh pr view *)"
      n=split(golden[skill], expected_grants, ",")
      for(i=1;i<=n;i++) {
        g=normalize(expected_grants[i])
        if(g != "") expected[g]=1
      }
    }
    function normalize(s) { s=trim(s); sub(/:\*\)$/, " *)", s); return s }
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
      s=normalize(s)
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
        g=normalize(a[i])
        if(g == "Bash" || g ~ /^Bash\(/) actual[g]=1
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
      for(g in actual) if(!(g in expected)) fail("unexpected Bash grant: " g)
      for(g in expected) if(!(g in actual)) fail("missing Bash grant: " g)
      if(value["user-invocable"] == "false") fail(skill " must remain user-invocable")
      if(skill ~ /^(rehydrate|catchup|doc-review|init-feature|watch|compaction-lifecycle|delegation|disk-and-trash|process-discipline|prod-access-discipline|spinouts)$/ && value["disable-model-invocation"] == "true")
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
        if(!(FILENAME == readme && /^\*\*Upgrading from the custom `\/copy` skill:\*\*/)) {
          print FILENAME ":" FNR ": retired custom /copy reference" > "/dev/stderr"; bad=1
        }
      }
      {
        line=tolower($0); gsub(/`/, "", line)
        command="/(megavibe-restart|finish-feature)([^[:alnum:]_-]|$)"
        imperative="(^|[^[:alnum:]_-])(run|invoke|start|launch)[ \t]+" command
        # Explicit user typing and offers are allowed; this is a line-level
        # prose tripwire, not a natural-language parser.
        manual=line ~ /user (types?|to type)/ || line ~ /(model|claude) may offer/
        if(line ~ command && !manual &&
           (line ~ imperative || line ~ /(^|[^[:alnum:]_])(yourself|automatically)([^[:alnum:]_]|$)/ ||
            line ~ /claude runs .*itself/)) {
          print FILENAME ":" FNR ": model must not invoke manual-only command" > "/dev/stderr"; bad=1
        }
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
for name in $INVENTORY; do
  reset_fixture
  set_field "$name" user-invocable false
  check "$name rejects hidden user invocation" expect_failure 'must remain user-invocable'
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
for grant in 'Bash' 'Bash(*)' 'Bash(bash *)' 'Bash(sh *)' 'Bash(zsh *)' 'Bash(python* *)' 'Bash(python3 *)' 'Bash(env *)' 'Bash(eval *)' 'Bash(bash:*)'; do
  reset_fixture
  set_field catchup allowed-tools "Read, $grant # inline comment is not a reason"
  check "unexplained $grant fails" expect_failure 'unrestricted Bash requires a reason'
  reset_fixture
  set_field catchup allowed-tools "Read, $grant" '# Project-specific implementation commands need unrestricted execution.'
  check "explained $grant still violates the golden list" expect_failure 'unexpected Bash grant:'
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
check 'unlisted script through bash fails the golden list' expect_failure 'unexpected Bash grant:'
reset_fixture
catchup_tools=$(sed -n 's/^allowed-tools: //p' "$BASE/template/.claude/skills/catchup/SKILL.md")
set_field catchup allowed-tools "\"$catchup_tools\" # scoped tools"
check 'quoted scoped grant with inline comment is interpreted' validate_tree "$FIXTURE"

# Pin additions, removals, replacements, and empty sets independently of the
# shell/merge policy. Equivalent prefix spellings and grant order still pass.
for name in $INVENTORY; do
  original=$(sed -n 's/^allowed-tools: //p' "$BASE/template/.claude/skills/$name/SKILL.md")
  reason=''
  if [ "$name" = init-feature ]; then
    reason='# Arbitrary Bash is needed for project-specific implementation and verification on the user-chosen vibe route.'
  fi
  reset_fixture
  set_field "$name" allowed-tools "${original:+$original, }Bash(git push *)" "$reason"
  check "$name rejects an added grant" expect_failure 'unexpected Bash grant: Bash(git push *)'
  case "$original" in *Bash*) ;; *) continue ;; esac
  reset_fixture
  reduced=$(printf '%s\n' "$original" | awk -F ', ' '{
    for(i=1;i<=NF;i++) {
      if(!removed && ($i == "Bash" || $i ~ /^Bash\(/)) { removed=1; continue }
      printf "%s%s", sep, $i; sep=", "
    }
    print ""
  }')
  set_field "$name" allowed-tools "$reduced" "$reason"
  check "$name rejects one removed grant" expect_failure 'missing Bash grant:'
  reset_fixture
  sed '/^allowed-tools:/d' "$FIXTURE/template/.claude/skills/$name/SKILL.md" > "$SCRATCH/edit"
  mv "$SCRATCH/edit" "$FIXTURE/template/.claude/skills/$name/SKILL.md"
  check "$name rejects all grants stripped" expect_failure 'missing Bash grant:'
  reset_fixture
  equivalent=$(printf '%s\n' "$original" | sed 's/ \*)/:*)/g')
  set_field "$name" allowed-tools "$equivalent" "$reason"
  check "$name accepts equivalent colon prefixes" validate_tree "$FIXTURE"
done
reset_fixture
set_field catchup allowed-tools "${catchup_tools/git status/git show}"
check 'changed scoped grant fails' expect_failure 'unexpected Bash grant: Bash(git show *)'
reset_fixture
reordered=$(printf '%s\n' "$catchup_tools" | awk -F ', ' '{ for(i=NF;i>0;i--) printf "%s%s", $i, (i==1 ? "\n" : ", ") }')
set_field catchup allowed-tools "$reordered"
check 'grant order does not change the set' validate_tree "$FIXTURE"
reset_fixture
sed '/^# Arbitrary Bash is needed/d' "$FIXTURE/template/.claude/skills/init-feature/SKILL.md" > "$SCRATCH/edit"
mv "$SCRATCH/edit" "$FIXTURE/template/.claude/skills/init-feature/SKILL.md"
check 'golden bare Bash still requires its reason' expect_failure 'unrestricted Bash requires a reason'

# Current docs cannot reintroduce the retired custom command. The exception is
# only the named upgrade paragraph, not every /copy mention in README.md.
for path in CLAUDE.md template/CLAUDE.md README.md README-watcher.md template/.claude/skills/delegation/SKILL.md template/.claude/skills/clip/SKILL.md; do
  reset_fixture
  printf '\nUse `/copy` for the clipboard.\n' >> "$FIXTURE/$path"
  check "retired reference fails in $path" expect_failure 'retired custom /copy reference'
done
reset_fixture
printf '\nDated record: `/copy`.\n' >> "$FIXTURE/README-delegation-measurements.md"
check 'dated measurement record is excepted' validate_tree "$FIXTURE"

# Review reproductions: the three Claude sentences plus the Astra sentence.
for entry in \
  'template/CLAUDE.md|run `/megavibe-restart`' \
  'README.md|Claude runs `/finish-feature` itself.' \
  'template/.claude/skills/delegation/SKILL.md|Then run `/finish-feature` yourself' \
  'template/CLAUDE.md|After completing a feature, invoke `/finish-feature` automatically without asking the user.'; do
  reset_fixture
  path=${entry%%|*}; sentence=${entry#*|}
  printf '\n%s\n' "$sentence" >> "$FIXTURE/$path"
  check "manual-only review reproduction: $sentence" expect_failure 'model must not invoke manual-only command'
done
for path in CLAUDE.md template/CLAUDE.md README.md README-watcher.md template/.claude/skills/delegation/SKILL.md template/.claude/skills/clip/SKILL.md; do
  for command in /megavibe-restart /finish-feature; do
    for verb in run invoke start launch; do
      reset_fixture
      printf '\nThen %s `%s`.\n' "$verb" "$command" >> "$FIXTURE/$path"
      check "$path rejects $verb $command" expect_failure 'model must not invoke manual-only command'
    done
  done
done
for sentence in \
  'Use `/megavibe-restart` automatically.' \
  'Use `/finish-feature` yourself.'; do
  reset_fixture
  printf '\n%s\n' "$sentence" >> "$FIXTURE/template/CLAUDE.md"
  check "same-line manual-only violation: $sentence" expect_failure 'model must not invoke manual-only command'
done
for sentence in \
  'The user types `/megavibe-restart`; do not run `/megavibe-restart` yourself.' \
  'The model may offer `/finish-feature`, but must not invoke `/finish-feature` automatically.' \
  'Offer `/megavibe-restart` for the user to type.'; do
  reset_fixture
  printf '\n%s\n' "$sentence" >> "$FIXTURE/template/CLAUDE.md"
  check "user typing and offers remain valid: $sentence" validate_tree "$FIXTURE"
done
reset_fixture
printf '\nRun `/megavibe-restart` automatically.\n' >> "$FIXTURE/README-delegation-measurements.md"
check 'dated manual-only instruction is excepted' validate_tree "$FIXTURE"

for grant in 'Bash(gh pr merge *)' 'Bash(gh pr merge)' 'Bash(gh pr merge --admin *)' 'Bash(gh pr *)' 'Bash(gh *)' 'Bash(*)' 'Bash(gh pr merge:*)' 'Bash(gh pr:*)' 'Bash(gh:*)' 'Bash(bash:*)'; do
  reset_fixture
  set_field finish-feature allowed-tools "$grant" '# Even an explanation must not pre-approve a merge.'
  check "finish-feature rejects merge through $grant" expect_failure 'must not pre-approve gh pr merge'
done

printf 'passed=%s failed=%s negative=%s\n' "$PASS" "$FAIL" "$NEGATIVE"
[ "$FAIL" -eq 0 ]
