#!/bin/bash
# Shipped skill names, invocation policy and whole-shell grant documentation.
# Reads templates only; never launches a session or runs a skill.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SKILLS="$REPO/template/.claude/skills"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; fi; }

frontmatter() {
  awk 'NR == 1 {if ($0 != "---") exit 1; next} /^---$/ {exit} {print}' "$1"
}
field() {
  frontmatter "$1" | awk -v key="$2" '$0 ~ "^" key ":" {
    sub("^" key ":[[:space:]]*", ""); gsub(/[\047\042]/, ""); print
  }'
}
# Built-ins referenced by the repository, plus copy (the original collision).
# Extend this list when a newly shipped name conflicts with a built-in.
builtin() {
  case "$1" in
    copy|compact|clear|init|exit|help|model|effort|hooks|login|usage|resume|branch|rc) return 0 ;;
    *) return 1 ;;
  esac
}
documented_bash() {
  # Accept the existing comma-separated scalar and YAML flow/block lists.
  # Only a nonempty comment immediately above allowed-tools counts as a reason.
  awk '
    function grants(s, n,a,i) {
      gsub(/[\047\042\[\]]/, "", s)
      n=split(s,a,",")
      for(i=1;i<=n;i++) {
        sub(/^[[:space:]]*(-[[:space:]]*)?/, "", a[i])
        sub(/[[:space:]]*$/, "", a[i])
        if(a[i] == "Bash" && !reason) bad=1
      }
    }
    /^allowed-tools:/ {
      reason=(prev ~ /^[[:space:]]*#[[:space:]]*[^[:space:]#]/)
      active=1; line=$0; sub(/^allowed-tools:[[:space:]]*/, "", line)
      grants(line); prev=$0; next
    }
    active && /^[^[:space:]#]/ {active=0}
    active && /^[[:space:]]+-/ {grants($0)}
    {prev=$0}
    END {exit bad ? 1 : 0}
  '
}

for f in "$SKILLS"/*/SKILL.md; do
  dir=${f%/SKILL.md}; name=${dir##*/}
  check "$name: front matter name matches directory" '[ "$(field "$f" name)" = "$name" ]'
  check "$name: does not shadow a built-in" '! builtin "$name" && ! builtin "$(field "$f" name)"'
  check "$name: bare Bash grants have a reason above the key" 'frontmatter "$f" | documented_bash'
done
for name in megavibe-restart watch finish-feature; do
  f="$SKILLS/$name/SKILL.md"
  check "$name: manual-only" '[ "$(field "$f" disable-model-invocation)" = true ]'
  check "$name: remains user-invocable" '[ "$(field "$f" user-invocable)" = true ]'
done
for name in rehydrate catchup doc-review init-feature; do
  f="$SKILLS/$name/SKILL.md"
  check "$name: remains model-invocable" '[ "$(field "$f" disable-model-invocation)" != true ]'
done
check 'clip replaces the shipped copy directory' '[ -f "$SKILLS/clip/SKILL.md" ] && [ ! -e "$SKILLS/copy" ]'
check 'no misspelled invocation key' '! grep -q "^user_invocable:" "$SKILLS"/*/SKILL.md'

# Exercise the policy checker so narrowing or a comment elsewhere cannot hide a grant.
check 'scoped Bash needs no reason' 'printf "%s\n" "allowed-tools: Read, Bash(git status *)" | documented_bash'
check 'undocumented scalar Bash is rejected' '! printf "%s\n" "allowed-tools: Read, Bash" | documented_bash'
check 'documented scalar Bash is accepted' 'printf "%s\n" "# Project-specific verification commands." "allowed-tools: Read, Bash" | documented_bash'
check 'undocumented flow-list Bash is rejected' '! printf "%s\n" "allowed-tools: [Read, Bash]" | documented_bash'
check 'undocumented block-list Bash is rejected' '! printf "%s\n" "allowed-tools:" "  - Read" "  - Bash" | documented_bash'
check 'documented block-list Bash is accepted' 'printf "%s\n" "# Project-specific verification commands." "allowed-tools:" "  - Bash" | documented_bash'
check 'blank comment is not a reason' '! printf "%s\n" "# " "allowed-tools: Bash" | documented_bash'
check 'distant comment is not a reason' '! printf "%s\n" "# Project-specific verification commands." "description: Example" "allowed-tools: Bash" | documented_bash'
check 'a body comment cannot justify front matter' '! printf "%s\n" "---" "allowed-tools: Bash" "---" "# Project-specific verification commands." | documented_bash'
check 'copy is a reserved name' 'builtin copy'

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
