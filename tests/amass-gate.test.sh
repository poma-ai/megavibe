#!/bin/bash
# /bin/bash tests/amass-gate.test.sh
# amass-gate.sh: a reader round (codex-review.sh / claude-review.sh --as-reviewer) is refused
# (exit 6) without an amass run for THIS directory in the window; --no-amass "<reason>" covers
# only its own call and is recorded; other directories (same basename), old rows, dedupe rows
# and waivers do not count; one malformed row cannot hide or fake a sweep; an unwritable ledger
# fails the waiver; MEGAVIBE_AMASS_GATE=0 and a non-reviewer call are untouched. No model is
# called: the gate runs before the backend (a stub codex stands in).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/amass-gate.XXXXXX") || exit 2
trap 'chmod -R u+w "$T" 2>/dev/null; rm -r "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
G="$REPO/scripts/amass-gate.sh"
export AMASS_LEDGER="$T/ledger.jsonl"; unset MEGAVIBE_AMASS_GATE
P="$T/proj"; mkdir -p "$P"; cd "$P" || exit 2
P=$PWD
now() { date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%SZ; }
row() { printf '{"ts":"%s","cmd":"%s","project":"%s","ok":1}\n' "$(now "$1")" "$2" "$3" >> "$AMASS_LEDGER"; }
reset() { rm -f "$AMASS_LEDGER"; }
rc_check() { "$G" check >/dev/null 2>&1; echo $?; }

[ "$(rc_check)" = 6 ] && ok || bad "no ledger blocks"
row 5 run other; [ "$(rc_check)" = 6 ] && ok || bad "another project's sweep does not count"
row 300 run proj; [ "$(rc_check)" = 6 ] && ok || bad "a sweep older than the window does not count"
row 5 dedupe proj; [ "$(rc_check)" = 6 ] && ok || bad "dedupe alone is not a sweep"
row 5 run proj; [ "$(rc_check)" = 0 ] && ok || bad "a recent run (old-format row, basename key) passes"
reset; "$G" waive "ab" >/dev/null 2>&1; [ $? -eq 2 ] && ok || bad "a waiver needs a real reason"
"$G" waive "hotfix: urgent" >/dev/null 2>&1; [ "$(rc_check)" = 6 ] && ok || bad "a waiver authorizes only its own call, never the window"
grep -q '"cmd":"waive"' "$AMASS_LEDGER" && ok || bad "the waiver is a ledger row"
reset; printf 'not json\n' > "$AMASS_LEDGER"; row 5 run proj; [ "$(rc_check)" = 0 ] && ok || bad "a malformed row does not hide a valid sweep"
reset; printf 'not json\n' > "$AMASS_LEDGER"; [ "$(rc_check)" = 6 ] && ok || bad "a ledger of only malformed rows blocks"
reset; printf '{"ts":"%s","cmd":"run","project":"proj","cwd":"/elsewhere/proj"}\n' "$(now 5)" > "$AMASS_LEDGER"; [ "$(rc_check)" = 6 ] && ok || bad "same basename, other directory does not count"
reset; printf '{"ts":"%s","cmd":"run","project":"proj","cwd":"%s","ok":1}\n' "$(now 5)" "$P" > "$AMASS_LEDGER"; [ "$(rc_check)" = 0 ] && ok || bad "a sweep from this directory counts"
chmod a-w "$AMASS_LEDGER"; "$G" waive "hotfix: cannot be written" >/dev/null 2>&1; [ $? -eq 0 ] && ok || bad "an unwritable ledger warns and proceeds (fail open)"; chmod u+w "$AMASS_LEDGER"
chmod 000 "$AMASS_LEDGER"; [ "$(rc_check)" = 0 ] && ok || bad "an existing unreadable ledger fails open"; chmod u+rw "$AMASS_LEDGER"
reset; printf '{"ts":"%s","cmd":"run","project":"proj","cwd":"%s","ok":0,"calls":3}\n' "$(now 5)" "$P" > "$AMASS_LEDGER"; [ "$(rc_check)" = 6 ] && ok || bad "a sweep whose calls all failed does not count"
reset; printf '{"ts":"%s","cmd":"run","project":"proj","cwd":"%s","ok":2,"calls":3}\n' "$(now 5)" "$P" > "$AMASS_LEDGER"; [ "$(rc_check)" = 0 ] && ok || bad "a sweep with a successful call counts"
reset; MEGAVIBE_AMASS_GATE=0 "$G" check; [ $? -eq 0 ] && ok || bad "gate off"
w=$("$G" waive "$(printf 'hotfix bad\033[31mreason')" 2>&1 >/dev/null); [[ "$w" != *$'\033'* ]] && ok || bad "control characters stripped from a waiver reason"
reset
# the review scripts: refused before any backend runs, waiver accepted for that call, non-reviewer untouched
mkdir -p "$T/bin"; printf '#!/bin/bash\necho "stub codex $*"; exit 0\n' > "$T/bin/codex"; chmod +x "$T/bin/codex"
# a fake claude for claude-review.sh: reports a claude.ai login, answers nothing else (no login or
# sandbox needed on the test machine); --tools none keeps the seatbelt out of these checks
cat > "$T/bin/fake-claude" <<'FAKE'
#!/bin/bash
case "$*" in *"auth status"*) echo '{"loggedIn":true,"authMethod":"claude.ai"}' ;; esac
exit 0
FAKE
chmod +x "$T/bin/fake-claude"
export CLAUDE_REVIEW_CLAUDE="$T/bin/fake-claude"
out=$(PATH="$T/bin:$PATH" bash "$REPO/scripts/codex-review.sh" --as-reviewer --prompt x 2>&1); rc=$?
[ $rc -eq 6 ] && [[ "$out" == *"no amass sweep recorded"* ]] && ok || bad "codex-review --as-reviewer refused (rc=$rc): $out"
out=$(PATH="$T/bin:$PATH" bash "$REPO/scripts/codex-review.sh" --as-reviewer --no-amass "hotfix, reviewed after the ship" --prompt x 2>&1); rc=$?
[ $rc -ne 6 ] && grep -q '"cmd":"waive"' "$AMASS_LEDGER" && ok || bad "codex-review --no-amass proceeds and records (rc=$rc): $out"
reset
out=$(PATH="$T/bin:$PATH" bash "$REPO/scripts/codex-review.sh" --prompt x 2>&1); rc=$?
[ $rc -ne 6 ] && ok || bad "a non-reviewer call is not gated (rc=$rc): $out"
out=$(PATH="$T/bin:$PATH" bash "$REPO/scripts/codex-review.sh" --as-reviewer --no-amass --prompt x 2>&1); rc=$?
[ $rc -eq 2 ] && ok || bad "--no-amass cannot swallow the next option (codex, rc=$rc)"
out=$(bash "$REPO/scripts/claude-review.sh" --as-reviewer --no-amass 2>&1); rc=$?
[ $rc -eq 2 ] && ok || bad "--no-amass without a value (claude, rc=$rc)"
out=$(bash "$REPO/scripts/claude-review.sh" --as-reviewer --tools none --prompt x 2>&1); rc=$?
[ $rc -eq 6 ] && ok || bad "claude-review --as-reviewer refused (rc=$rc): $out"
reset
# the gate comes after the scripts' own validation: usage errors keep their exit codes
out=$(bash "$REPO/scripts/claude-review.sh" --as-reviewer --prompt x --tools bogus 2>&1); rc=$?; [ $rc -eq 2 ] && ok || bad "claude --tools bogus keeps exit 2 (rc=$rc)"
out=$(bash "$REPO/scripts/claude-review.sh" --as-reviewer --prompt x --max-input-kb oops 2>&1); rc=$?; [ $rc -eq 2 ] && ok || bad "claude --max-input-kb oops keeps exit 2 (rc=$rc)"
out=$(PATH="$T/bin:$PATH" bash "$REPO/scripts/codex-review.sh" --as-reviewer 2>&1); rc=$?; [ $rc -eq 2 ] && ok || bad "codex without a prompt keeps exit 2 (rc=$rc)"
out=$(PATH="$T/bin:$PATH" bash "$REPO/scripts/codex-review.sh" --as-reviewer --prompt-file "$T/absent.md" 2>&1); rc=$?; [ $rc -eq 1 ] && ok || bad "codex with a missing prompt file keeps exit 1 (rc=$rc)"
# an oversized request keeps its own exit 2 (size is checked before the gate)
head -c 160000 /dev/zero | tr '\0' 'a' > "$T/large.txt"
out=$(bash "$REPO/scripts/claude-review.sh" --as-reviewer --tools read --model haiku --prompt review "$T/large.txt" 2>&1); rc=$?
[ $rc -eq 2 ] && ok || bad "an oversized request keeps exit 2 (rc=$rc): $out"
# an inherited CDPATH must not make the gate look absent
out=$(CDPATH=. PATH="$T/bin:$PATH" bash "$REPO/scripts/codex-review.sh" --as-reviewer --prompt x 2>&1); rc=$?; [ $rc -eq 6 ] && ok || bad "CDPATH=. still gates codex-review (rc=$rc): $out"
out=$(CDPATH=. bash "$REPO/scripts/claude-review.sh" --as-reviewer --tools none --prompt x 2>&1); rc=$?; [ $rc -eq 6 ] && ok || bad "CDPATH=. still gates claude-review (rc=$rc): $out"
out=$(bash "$REPO/scripts/claude-review.sh" --as-reviewer --tools none --no-amass "hotfix: after the ship" --prompt x 2>&1); rc=$?
grep -q '"cmd":"waive"' "$AMASS_LEDGER" && ok || bad "claude-review --no-amass records its waiver (rc=$rc): $out"
reset; out=$(bash "$REPO/scripts/claude-review.sh" --as-reviewer --tools none --no-amass "sweep ran earlier on the branch" --prompt x 2>&1); rc=$?
[ $rc -eq 2 ] && ! [ -s "$AMASS_LEDGER" ] && ok || bad "claude-review refuses a free-text waiver (rc=$rc): $out"
reset; out=$(PATH="$T/bin:$PATH" bash "$REPO/scripts/codex-review.sh" --as-reviewer --no-amass "re-review after fix round" --prompt x 2>&1); rc=$?
[ $rc -eq 2 ] && ok || bad "codex-review refuses a free-text waiver (rc=$rc): $out"
printf '# doc\n' > "$T/doc.md"
out=$(PATH="$T/bin:$PATH" bash "$REPO/scripts/codex-review.sh" --as-reviewer --no-amass "prose: doc wording" --prompt x "$T/doc.md" 2>&1); rc=$?
[ $rc -ne 2 ] && [ $rc -ne 6 ] && ok || bad "codex-review passes its files to the prose check (rc=$rc): $out"

# --- waiver categories (2026-11-19): only oversize|prose|hotfix, the first two checked against the files
W="$T/w"; mkdir -p "$W"
wv() { "$G" waive "$@" >/dev/null 2>&1; echo $?; }
reset
[ "$(wv "sweep ran on the branch earlier")" = 2 ] && ok || bad "free-text waiver refused"
[ "$(wv "small diff, tested")" = 2 ] && ok || bad "small-diff waiver refused"
printf 'x=1\n' > "$W/a.py"; printf '# t\n' > "$W/a.md"; printf 'a,b\n' > "$W/d.csv"
[ "$(wv "oversize: big" "$W/a.py")" = 2 ] && ok || bad "oversize refused for a small file"
head -c 145000 /dev/zero | tr '\0' 'a' > "$W/big.py"; head -c 200000 /dev/zero | tr '\0' 'a' > "$W/big.csv"
[ "$(wv "oversize: big" "$W/big.py")" = 0 ] && ok || bad "oversize accepted over 150 KB"
[ "$(wv "Oversize" "$W/big.csv" "$W/a.py")" = 2 ] && ok || bad "data files do not make a review oversize"
[ "$(wv "prose: wording" "$W/a.md" "$W/d.csv")" = 0 ] && ok || bad "prose accepted for md+csv"
[ "$(wv "prose: wording" "$W/a.md" "$W/a.py")" = 2 ] && ok || bad "prose refused with a code file"
[ "$(wv "prose")" = 2 ] && ok || bad "prose refused without files"
printf 'diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-a\n+b\n' > "$W/p.patch"
[ "$(wv "prose: readme" "$W/p.patch")" = 0 ] && ok || bad "prose accepted for a patch of .md only"
printf 'diff --git a/x.sh b/x.sh\nnew file mode 100755\n--- /dev/null\n+++ b/x.sh\n@@ -0,0 +1 @@\n+echo x\n' >> "$W/p.patch"
[ "$(wv "prose: readme" "$W/p.patch")" = 2 ] && ok || bad "prose refused when the patch adds a script"
printf 'no paths here\n' > "$W/e.diff"; [ "$(wv "prose" "$W/e.diff")" = 2 ] && ok || bad "prose refused for a patch naming no paths"
printf 'diff --git a/run.py b/run2.py\nsimilarity index 100%%\nrename from run.py\nrename to run2.py\n' > "$W/ren.patch"
[ "$(wv "prose: x" "$W/ren.patch")" = 2 ] && ok || bad "prose refused for a patch that renames code (no ---/+++ lines)"
printf 'diff --git a/x.bin b/x.bin\nBinary files a/x.bin and b/x.bin differ\n' > "$W/bin.patch"
[ "$(wv "prose: x" "$W/bin.patch")" = 2 ] && ok || bad "prose refused for a binary non-data change"
printf 'diff --git a/i.png b/i.png\nBinary files a/i.png and b/i.png differ\n' > "$W/png.patch"
[ "$(wv "prose: x" "$W/png.patch")" = 0 ] && ok || bad "prose accepted for an image change"
printf 'diff --git "a/na\\303\\257ve.md" "b/na\\303\\257ve.md"\n--- "a/na\\303\\257ve.md"\n+++ "b/na\\303\\257ve.md"\n' > "$W/q.patch"
[ "$(wv "prose: x" "$W/q.patch")" = 0 ] && ok || bad "prose accepted for a quoted (escaped) prose path"
[ "$(wv "hotfix-ish")" = 2 ] && ok || bad "a category needs a delimiter (hotfix-ish refused)"
[ "$(wv "hotfix, after the ship")" = 0 ] && ok || bad "a comma after the category is a delimiter"
grep -q '"category":"oversize"' "$AMASS_LEDGER" && grep -q '"category":"prose"' "$AMASS_LEDGER" && ok || bad "categories recorded"

# --- status: silent without waivers, owed hotfix until a sweep runs in that directory
reset; [ -z "$("$G" status)" ] && ok || bad "status silent with no waivers"
"$G" waive "hotfix: prod down" >/dev/null 2>&1
st=$("$G" status); [[ "$st" == *"waivers (last 24 h): 1 (hotfix 1)"* && "$st" == *"sweeps owed: proj"* ]] && ok || bad "status shows the owed hotfix sweep: $st"
sleep 1; printf '{"ts":"%s","cmd":"run","project":"proj","cwd":"%s","ok":1}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P" >> "$AMASS_LEDGER"
st=$("$G" status); [[ "$st" != *"owed"* ]] && ok || bad "a later sweep settles the owed hotfix: $st"
# a sweep earlier in the ledger, in the same second, does not settle a later hotfix (ledger order breaks the tie)
reset; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","cmd":"run","project":"proj","cwd":"%s","ok":1}\n{"ts":"%s","cmd":"waive","category":"hotfix","project":"proj","cwd":"%s","reason":"hotfix"}\n' "$ts" "$P" "$ts" "$P" > "$AMASS_LEDGER"
st=$("$G" status); [[ "$st" == *"sweeps owed: proj"* ]] && ok || bad "same-second earlier sweep leaves the hotfix owed: $st"

printf '{"ts":"%s","cmd":"waive","category":"hotfix","project":"gone","cwd":"/gone","reason":"hotfix"}\n' "$(now 14400)" >> "$AMASS_LEDGER"
st=$("$G" status); [[ "$st" != *"gone"* ]] && ok || bad "an owed hotfix older than 7 days is no longer listed: $st"
printf '{"ts":"%s","cmd":"waive","project":"old","cwd":"/x","reason":"free text"}\n' "$(now 5)" >> "$AMASS_LEDGER"
st=$("$G" status); [[ "$st" == *"unchecked 1"* ]] && ok || bad "a legacy free-text waiver shows as unchecked: $st"

# --- the sweep must be of THIS candidate in a git checkout
R="$T/repo"; mkdir -p "$R/.agent"; cd "$R" || exit 2; R=$PWD
git init -q; git config user.email t@t; git config user.name t; printf 'a\n' > f.sh; printf 'n\n' > .agent/n.md; git add -A; git commit -qm one
fprow() { printf '{"ts":"%s","cmd":"run","project":"repo","cwd":"%s","ok":1,"fingerprint":"%s"}\n' "$(now 1)" "$PWD" "$1" >> "$AMASS_LEDGER"; }
reset; fp=$("$G" fingerprint); [[ "$fp" == tree:* ]] && ok || bad "fingerprint in a git checkout: $fp"
fprow "$fp"; [ "$(rc_check)" = 0 ] && ok || bad "a sweep of this candidate counts"
printf 'n2\n' > .agent/n.md; [ "$(rc_check)" = 0 ] && ok || bad ".agent edits do not change the candidate"
printf 'b\n' > f.sh; out=$("$G" check 2>&1); rc=$?
[ $rc -eq 6 ] && [[ "$out" == *"other content"* ]] && ok || bad "a tracked edit after the sweep needs a new sweep (rc=$rc): $out"
git commit -qam two; [ "$(rc_check)" = 6 ] && ok || bad "a commit of unswept content needs a new sweep"
reset; fprow "$("$G" fingerprint)"; printf 'e\n' > f.sh; fprow "$("$G" fingerprint)"
git commit -qam swept; [ "$(rc_check)" = 0 ] && ok || bad "committing exactly the swept content keeps the sweep"
git commit -q --amend -m "swept, reworded"; [ "$(rc_check)" = 0 ] && ok || bad "amending the message keeps the sweep"
git -c diff.external=/bin/echo -c color.ui=always status >/dev/null; [ "$(GIT_EXTERNAL_DIFF=/bin/echo rc_check)" = 0 ] && ok || bad "diff settings do not change the fingerprint"
printf 'f\n' > f.sh; git add f.sh; [ "$(rc_check)" = 6 ] && ok || bad "a staged fix edit needs a new sweep"; git checkout -q HEAD -- f.sh
fprow "$("$G" fingerprint)"; [ "$(rc_check)" = 0 ] && ok || bad "a new sweep of the new commit counts"
# a nested project's .agent/ (cwd below the git top) is left out too
mkdir -p "$R/sub/.agent"; printf 'x\n' > "$R/sub/.agent/log.md"; printf 'c\n' > "$R/sub/c.py"; git add -A; git commit -qm three
cd "$R/sub" || exit 2; reset; fprow "$("$G" fingerprint)"
printf 'another note\n' > .agent/log.md; [ "$(rc_check)" = 0 ] && ok || bad "a nested .agent/ edit does not change the candidate"
printf 'd\n' > c.py; [ "$(rc_check)" = 6 ] && ok || bad "a nested code edit does change it"
git checkout -q -- c.py; cd "$R" || exit 2
# racy clean: an edit of the same size in the same second as the index write is still seen
reset; printf 'aaaa\n' > f.sh; git commit -qam racy; fprow "$("$G" fingerprint)"; printf 'bbbb\n' > f.sh; sleep 1
[ "$(rc_check)" = 6 ] && ok || bad "a same-second, same-size edit after the sweep needs a new sweep"
git checkout -q HEAD -- f.sh
reset; printf '{"ts":"%s","cmd":"run","project":"repo","cwd":"%s","ok":1}\n' "$(now 1)" "$R" >> "$AMASS_LEDGER"; [ "$(rc_check)" = 0 ] && ok || bad "a row without a fingerprint counts by the window"
cd "$P" || exit 2; [ -z "$("$G" fingerprint)" ] && ok || bad "no fingerprint outside git"
echo "amass-gate tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
