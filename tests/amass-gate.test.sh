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
"$G" waive "input over 150 KB" >/dev/null 2>&1; [ "$(rc_check)" = 6 ] && ok || bad "a waiver authorizes only its own call, never the window"
grep -q '"cmd":"waive"' "$AMASS_LEDGER" && ok || bad "the waiver is a ledger row"
reset; printf 'not json\n' > "$AMASS_LEDGER"; row 5 run proj; [ "$(rc_check)" = 0 ] && ok || bad "a malformed row does not hide a valid sweep"
reset; printf 'not json\n' > "$AMASS_LEDGER"; [ "$(rc_check)" = 6 ] && ok || bad "a ledger of only malformed rows blocks"
reset; printf '{"ts":"%s","cmd":"run","project":"proj","cwd":"/elsewhere/proj"}\n' "$(now 5)" > "$AMASS_LEDGER"; [ "$(rc_check)" = 6 ] && ok || bad "same basename, other directory does not count"
reset; printf '{"ts":"%s","cmd":"run","project":"proj","cwd":"%s","ok":1}\n' "$(now 5)" "$P" > "$AMASS_LEDGER"; [ "$(rc_check)" = 0 ] && ok || bad "a sweep from this directory counts"
chmod a-w "$AMASS_LEDGER"; "$G" waive "reason that cannot be written" >/dev/null 2>&1; [ $? -eq 0 ] && ok || bad "an unwritable ledger warns and proceeds (fail open)"; chmod u+w "$AMASS_LEDGER"
chmod 000 "$AMASS_LEDGER"; [ "$(rc_check)" = 0 ] && ok || bad "an existing unreadable ledger fails open"; chmod u+rw "$AMASS_LEDGER"
reset; printf '{"ts":"%s","cmd":"run","project":"proj","cwd":"%s","ok":0,"calls":3}\n' "$(now 5)" "$P" > "$AMASS_LEDGER"; [ "$(rc_check)" = 6 ] && ok || bad "a sweep whose calls all failed does not count"
reset; printf '{"ts":"%s","cmd":"run","project":"proj","cwd":"%s","ok":2,"calls":3}\n' "$(now 5)" "$P" > "$AMASS_LEDGER"; [ "$(rc_check)" = 0 ] && ok || bad "a sweep with a successful call counts"
reset; MEGAVIBE_AMASS_GATE=0 "$G" check; [ $? -eq 0 ] && ok || bad "gate off"
w=$("$G" waive "$(printf 'bad\033[31mreason')" 2>&1 >/dev/null); [[ "$w" != *$'\033'* ]] && ok || bad "control characters stripped from a waiver reason"
reset
# the review scripts: refused before any backend runs, waiver accepted for that call, non-reviewer untouched
mkdir -p "$T/bin"; printf '#!/bin/bash\necho "stub codex $*"; exit 0\n' > "$T/bin/codex"; chmod +x "$T/bin/codex"
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
out=$(bash "$REPO/scripts/claude-review.sh" --as-reviewer --prompt x 2>&1); rc=$?
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
out=$(CDPATH=. bash "$REPO/scripts/claude-review.sh" --as-reviewer --prompt x 2>&1); rc=$?; [ $rc -eq 6 ] && ok || bad "CDPATH=. still gates claude-review (rc=$rc): $out"
out=$(bash "$REPO/scripts/claude-review.sh" --as-reviewer --no-amass "prose only" --prompt x 2>&1); rc=$?
grep -q '"cmd":"waive"' "$AMASS_LEDGER" && ok || bad "claude-review --no-amass records its waiver (rc=$rc): $out"
echo "amass-gate tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
