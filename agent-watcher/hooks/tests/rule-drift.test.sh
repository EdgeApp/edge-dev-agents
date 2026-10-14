#!/usr/bin/env bash
# rule-drift.test.sh: the check that tells a scoring sheet its cited rule moved.
#
#   rubric-drift.sh  the check reads the lock and never writes it; its exit
#                    code separates clean (0), drift on a cited rule or file
#                    (1) and uncovered rules alone (3); a file anchor is
#                    fingerprinted by its header plus the blocks the citing
#                    lines name, or by header plus code when a line names
#                    none; a blanket acknowledgment lapses after 90 days as a
#                    note that never fails the check; and --narrow moves an
#                    old whole-file lock only when that lock is clean.
#
# Runs the real script against a private tree of skills, rules, scripts and
# two scoring sheets, addressed through the script's RD_* variables. The
# clock is pinned with RD_TODAY, so the test never waits.
set -uo pipefail

RD="$HOME/.cursor/skills/rubric-drift.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rule-drift-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export RD_SKILLS_DIR="$TMP/skills" RD_RULES_DIR="$TMP/rules" RD_WATCHER_DIR="$TMP/watcher"
export RD_LOCK="$TMP/lock.json" RD_TODAY=2026-01-01
FAILS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}
has() { # has <name> <text>: the last output holds the text
  if grep -qF -- "$2" "$TMP/out" "$TMP/err"; then ok "$1"; else fail "$1: no '$2' in: $(head -c 400 "$TMP/out" "$TMP/err")"; fi
}
hasnt() {
  if grep -qF -- "$2" "$TMP/out" "$TMP/err"; then fail "$1: found '$2'"; else ok "$1"; fi
}
rc() { bash "$RD" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }
lockfield() { jq -r "$1" "$RD_LOCK"; }
# swap <file> <old> <new>: replace one exact string, fail loudly when absent.
swap() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
assert s.count(a) == 1, (p, a, s.count(a))
open(p, 'w').write(s.replace(a, b))
PY
}
# The older fingerprint: sha256 of the whole file, whitespace collapsed, 12 hex.
wholehash() {
  python3 - "$1" <<'PY'
import sys, re, hashlib
s = re.sub(r'\s+', ' ', open(sys.argv[1]).read()).strip()
print(hashlib.sha256(s.encode()).hexdigest()[:12])
PY
}
snapshot() { cp "$RD_LOCK" "$TMP/lock.before"; }
untouched() { # untouched <name>: the lock is byte for byte the snapshot
  if cmp -s "$RD_LOCK" "$TMP/lock.before"; then ok "$1"; else fail "$1: the lock changed"; fi
}

# --- the private tree ---
mkdir -p "$TMP/skills/alpha/references" "$TMP/skills/alpha/templates" "$TMP/skills/beta" \
  "$TMP/skills/agent-eval/references" "$TMP/skills/orch-eval/references" \
  "$TMP/rules" "$TMP/watcher/hooks"
cat > "$TMP/skills/alpha/SKILL.md" <<'EOF'
<rule id="r1">Do the first thing.</rule>
<rule id="r2">Do the second thing.</rule>
<rule id="r3">Do the third thing.</rule>
EOF
cat > "$TMP/skills/alpha/references/slice.md" <<'EOF'
<rule id="r4">A rule kept in a reference file.</rule>
EOF
cat > "$TMP/skills/alpha/templates/report.md" <<'EOF'
# Report
Intro text.
<facts>
one fact
</facts>
Closing text.
EOF
cat > "$TMP/rules/std.mdc" <<'EOF'
<rule id="s1">A standing rule.</rule>
EOF
cat > "$TMP/watcher/tool.sh" <<'EOF'
#!/usr/bin/env bash
# tool.sh: the header says what the tool does.
set -euo pipefail
# a comment below the header
echo run
EOF
cat > "$TMP/watcher/lib.js" <<'EOF'
#!/usr/bin/env node
// lib.js: the header.

const LIMIT = 20
const OTHER = 5
function doWork(x) {
  return x + LIMIT
}
function unrelated() {
  return OTHER
}
EOF
cat > "$TMP/watcher/hooks/gate.sh" <<'EOF'
#!/usr/bin/env bash
# gate.sh: the header.
check_it() {
  echo checked
}
other_fn() {
  echo other
}
check_it
EOF
cat > "$TMP/skills/agent-eval/references/rubric.md" <<'EOF'
| Dim | Name | Expectation | Grounding |
|---|---|---|---|
| A1 | first | does it | alpha:`r1`; `tool.sh` |
| A2 | **second (GATE)** | does it | `lib.js` `LIMIT` and `doWork` |
| A3 | third | does it | alpha templates/report.md `<facts>` |
EOF
cat > "$TMP/skills/orch-eval/references/rubric.md" <<'EOF'
| Dim | Name | Expectation | Grounding |
|---|---|---|---|
| O1 | gate | does it | `gate.sh` `check_it`; alpha `r4` |
EOF

# --- baseline and a clean, read-only check ---
check "a check with no lock is a usage error" "$(rc)" 2
has "it says to baseline" "No baseline"
[[ -e "$RD_LOCK" ]] && fail "a check with no lock creates none" || ok "a check with no lock creates none"
check "baseline succeeds" "$(rc --baseline)" 0
check "baseline tracks six anchors" "$(lockfield '.anchors | length')" 6
check "baseline writes the narrowed fingerprint mark" "$(lockfield .file_fingerprint)" 2
check "baseline acknowledges the three uncited rules" "$(lockfield '.acked_uncovered | keys | join(",")')" "alpha:r2,alpha:r3,std:s1"
check "a baseline acknowledgment is marked blanket" "$(lockfield '.acked_uncovered["alpha:r2"].blanket')" true
snapshot
check "the check is clean after a baseline" "$(rc)" 0
has "it prints the clean line" "CLEAN"
untouched "a clean check leaves the lock as found"

# --- which file anchors narrow ---
check "the fingerprint listing succeeds" "$(rc --fingerprints)" 0
has "a .js file narrows to its named constant and function" "NARROWED file:lib.js (dims A2) header + LIMIT, doWork"
has "a .sh file narrows to its named function" "NARROWED file:gate.sh (dims O1) header + check_it"
has "a .md file narrows to its named tag block" "NARROWED file:report.md (dims A3) header + facts"
has "a file whose line names no block stays whole" "WHOLE file:tool.sh (dims A1) no block named by A1"
has "the listing counts both modes" "3 narrowed, 1 whole"
untouched "the listing leaves the lock as found"

# --- a narrowed anchor: only the header and the named blocks count ---
swap "$TMP/watcher/lib.js" "return OTHER" "return OTHER + 1"
check "an edit to an unnamed function is not drift" "$(rc)" 0
swap "$TMP/watcher/lib.js" "const OTHER = 5" "const OTHER = 6"
check "an edit to an unnamed constant is not drift" "$(rc)" 0
swap "$TMP/watcher/lib.js" "return x + LIMIT" "return x * LIMIT"
check "an edit inside the named function is drift" "$(rc)" 1
has "it names the file anchor and its line" "CHANGED file:lib.js (dims A2)"
snapshot
check "reconcile accepts the new content" "$(rc --reconcile file:lib.js)" 0
check "the check is clean after the reconcile" "$(rc)" 0
swap "$TMP/watcher/lib.js" "const LIMIT = 20" "const LIMIT = 25"
check "an edit to the named constant is drift" "$(rc)" 1
check "reconcile again" "$(rc --reconcile file:lib.js)" 0
swap "$TMP/watcher/lib.js" "// lib.js: the header." "// lib.js: the header, reworded."
check "an edit to the header of a narrowed file is drift" "$(rc)" 1
check "reconcile the header edit" "$(rc --reconcile file:lib.js)" 0
swap "$TMP/watcher/hooks/gate.sh" "echo other" "echo other thing"
check "an edit to an unnamed shell function is not drift" "$(rc)" 0
swap "$TMP/watcher/hooks/gate.sh" "echo checked" "echo checked twice"
check "an edit inside the named shell function is drift" "$(rc)" 1
check "reconcile the shell function" "$(rc --reconcile file:gate.sh)" 0
swap "$TMP/skills/alpha/templates/report.md" "Closing text." "Closing words."
check "an edit outside the named tag block is not drift" "$(rc)" 0
swap "$TMP/skills/alpha/templates/report.md" "one fact" "two facts"
check "an edit inside the named tag block is drift" "$(rc)" 1
check "reconcile the tag block" "$(rc --reconcile file:report.md)" 0

# --- a whole anchor: comments below the header are ignored, code is not ---
swap "$TMP/watcher/tool.sh" "# a comment below the header" "# a reworded comment below the header"
check "a comment edit below the header is not drift" "$(rc)" 0
swap "$TMP/watcher/tool.sh" "echo run" "echo run now"
check "a code edit in a whole file is drift" "$(rc)" 1
has "it names the whole file anchor" "CHANGED file:tool.sh (dims A1)"
check "reconcile the code edit" "$(rc --reconcile file:tool.sh)" 0
swap "$TMP/watcher/tool.sh" "the header says what the tool does" "the header says something new"
check "a header edit in a whole file is drift" "$(rc)" 1
check "reconcile the header edit of the whole file" "$(rc --reconcile file:tool.sh)" 0
# A line that stops naming its block sends the file back to whole.
swap "$TMP/skills/orch-eval/references/rubric.md" '`gate.sh` `check_it`' '`gate.sh`'
check "a line that drops its block name changes the fingerprint" "$(rc)" 1
check "the listing still succeeds" "$(rc --fingerprints)" 0
has "the file is whole once a line names no block" "WHOLE file:gate.sh (dims O1) no block named by O1"
swap "$TMP/skills/orch-eval/references/rubric.md" '`gate.sh`;' '`gate.sh` `check_it`;'
check "restoring the block name restores a clean check" "$(rc)" 0

# --- rules: drift, whitespace, and the exit codes ---
swap "$TMP/skills/alpha/SKILL.md" "Do the first thing." "Do  the first
thing."
check "a whitespace-only rule edit is not drift" "$(rc)" 0
swap "$TMP/skills/alpha/references/slice.md" "A rule kept in a reference file." "A rule kept in a reference file, reworded."
check "an edit to a cited rule in a reference file is drift" "$(rc)" 1
has "it names the rule and its line" "CHANGED alpha:r4 (dims O1)"
check "reconcile the rule" "$(rc --reconcile alpha:r4)" 0
echo '<rule id="r5">A new rule.</rule>' >> "$TMP/skills/alpha/SKILL.md"
check "a new uncited rule alone exits 3" "$(rc)" 3
has "it is reported as uncovered" "UNCOVERED alpha:r5"
hasnt "no clean line is printed with a finding" "CLEAN"
swap "$TMP/watcher/tool.sh" "echo run now" "echo run later"
check "drift together with an uncovered rule exits 1" "$(rc)" 1
has "both findings are printed: the drift" "CHANGED file:tool.sh"
has "both findings are printed: the uncovered rule" "UNCOVERED alpha:r5"
check "reconcile the file" "$(rc --reconcile file:tool.sh)" 0
check "acknowledge the new rule" "$(rc --ack alpha:r5 --reason judged)" 0
check "the check is clean after the acknowledgment" "$(rc)" 0
check "a judged acknowledgment is not marked blanket" "$(lockfield '.acked_uncovered["alpha:r5"].blanket // "unset"')" unset
swap "$TMP/skills/alpha/SKILL.md" "A new rule." "A new rule, changed."
check "an acknowledged rule that changed exits 3" "$(rc)" 3
has "it is reported for a fresh decision" "UNCOVERED-CHANGED alpha:r5"
check "acknowledge it again" "$(rc --ack alpha:r5 --reason judged)" 0
echo '<rule id="b1">A rule of another skill.</rule>' > "$TMP/skills/beta/SKILL.md"
check "a rule of a new skill exits 3" "$(rc)" 3
check "excluding the skill needs a reason" "$(rc --exclude-skill beta)" 2
check "excluding the skill succeeds" "$(rc --exclude-skill beta --reason 'operator tooling')" 0
check "an excluded skill's rules are not reported" "$(rc)" 0

# --- a scoring line stops citing, and a cited rule disappears ---
swap "$TMP/skills/agent-eval/references/rubric.md" 'alpha:`r1`; `tool.sh`' 'alpha; `tool.sh`'
check "a rule a line stopped citing is drift" "$(rc)" 1
has "it is reported as unanchored" "UNANCHORED alpha:r1"
check "forget refuses an anchor that is not in the lock" "$(rc --forget alpha:nope)" 2
check "forget drops the anchor" "$(rc --forget alpha:r1)" 0
check "the forgotten rule is then uncovered" "$(rc)" 3
swap "$TMP/skills/agent-eval/references/rubric.md" 'alpha; `tool.sh`' 'alpha:`r1`; `tool.sh`'
check "a line that cites a rule again is drift until reconciled" "$(rc)" 1
has "it is reported as a new anchor" "NEW-ANCHOR alpha:r1"
check "forget refuses an anchor a line still cites" "$(rc --forget alpha:r1)" 2
check "reconcile starts tracking it" "$(rc --reconcile alpha:r1)" 0
check "the check is clean again" "$(rc)" 0
cp "$TMP/skills/alpha/references/slice.md" "$TMP/slice.keep"
: > "$TMP/skills/alpha/references/slice.md"
check "a cited rule that was deleted is drift" "$(rc)" 1
has "it is reported as missing" "MISSING alpha:r4"
cp "$TMP/slice.keep" "$TMP/skills/alpha/references/slice.md"
check "restoring the rule restores a clean check" "$(rc)" 0

# --- notes never fail the check, and only --prune removes them ---
jq '.acked_uncovered["alpha:r1"] = "2026-01-01: an old text acknowledgment"
    | .acked_uncovered["alpha:gone"] = {reason: "2026-01-01: judged", hash: "000000000000"}' \
  "$RD_LOCK" > "$TMP/lock.new" && mv "$TMP/lock.new" "$RD_LOCK"
snapshot
check "leftover acknowledgments do not fail the check" "$(rc)" 0
has "an acknowledgment for a cited rule is noted" "REDUNDANT-ACK alpha:r1"
has "an acknowledgment for a deleted rule is noted" "STALE-ACK alpha:gone"
has "the clean line is still printed" "CLEAN"
untouched "the check does not rewrite the old text acknowledgment"
check "prune succeeds" "$(rc --prune)" 0
has "prune reports what it removed" "PRUNED 1 now-anchored ack(s) and 1 ack(s) for deleted rules"
check "prune removed both" "$(lockfield '.acked_uncovered | has("alpha:r1") or has("alpha:gone")')" false
check "prune kept the others" "$(lockfield '.acked_uncovered | has("alpha:r2") and has("alpha:r5")')" true
check "the check is clean after the prune" "$(rc)" 0
hasnt "no note is left" "-ACK"

# --- blanket acknowledgments lapse after 90 days, as a note ---
snapshot
check "on day 90 nothing has lapsed" "$(RD_TODAY=2026-04-01 rc)" 0
hasnt "no lapse line on day 90" "LAPSED-ACK"
check "on day 91 the check still exits 0" "$(RD_TODAY=2026-04-02 rc)" 0
has "the lapse line counts the three blanket acknowledgments" "LAPSED-ACK 3 blanket ack(s) are older than 90 days (oldest 2026-01-01)"
has "the clean line is printed beside the lapse line" "CLEAN"
check "the lapsed listing succeeds" "$(RD_TODAY=2026-04-02 rc --lapsed)" 0
has "it lists a lapsed rule with its date" "LAPSED-ACK alpha:r2 (blanket ack of 2026-01-01, 91 days old)"
hasnt "a judged acknowledgment of the same age never lapses" "alpha:r5"
untouched "neither the lapse check nor the listing writes the lock"
check "a judged acknowledgment replaces a blanket one" "$(RD_TODAY=2026-04-02 rc --ack alpha:r2 --reason 'judged: not graded')" 0
check "the count drops by one" "$(RD_TODAY=2026-04-02 rc)" 0
has "two blanket acknowledgments remain lapsed" "LAPSED-ACK 2 blanket ack(s)"
# An acknowledgment that carries only the older reason text is blanket too.
jq '.acked_uncovered["alpha:r3"] = {reason: "2026-01-01: pre-baseline, not re-triaged individually", hash: .acked_uncovered["alpha:r3"].hash}' \
  "$RD_LOCK" > "$TMP/lock.new" && mv "$TMP/lock.new" "$RD_LOCK"
check "the lapsed listing succeeds again" "$(RD_TODAY=2026-04-02 rc --lapsed)" 0
has "an acknowledgment with the older blanket reason lapses" "LAPSED-ACK alpha:r3"

# --- moving an old whole-file lock ---
old_lock() { # rewrite the lock as the older script left it
  jq --arg t "$(wholehash "$TMP/watcher/tool.sh")" --arg l "$(wholehash "$TMP/watcher/lib.js")" \
     --arg g "$(wholehash "$TMP/watcher/hooks/gate.sh")" --arg r "$(wholehash "$TMP/skills/alpha/templates/report.md")" \
     'del(.file_fingerprint) | .anchors["file:tool.sh"].hash = $t | .anchors["file:lib.js"].hash = $l
      | .anchors["file:gate.sh"].hash = $g | .anchors["file:report.md"].hash = $r' \
     "$RD_LOCK" > "$TMP/lock.new" && mv "$TMP/lock.new" "$RD_LOCK"
}
old_lock
snapshot
check "an old lock still checks clean with the whole-file fingerprint" "$(rc)" 0
has "the check notes the older fingerprint" "NOTE the lock holds the whole-file fingerprint"
swap "$TMP/watcher/lib.js" "return OTHER + 1" "return OTHER + 2"
check "under an old lock any edit to the file is drift" "$(rc)" 1
check "the move refuses while a file anchor has drifted" "$(rc --narrow)" 1
has "it names the drifted anchor" "NARROW-FAIL file:lib.js"
untouched "a refused move leaves the lock as found"
swap "$TMP/watcher/lib.js" "return OTHER + 2" "return OTHER + 1"
check "the move succeeds on a clean old lock" "$(rc --narrow)" 0
has "it reports the count moved" "MOVED 4 file anchor(s)"
check "the moved lock carries the mark" "$(lockfield .file_fingerprint)" 2
check "the check is clean after the move" "$(rc)" 0
hasnt "the note is gone after the move" "NOTE the lock holds"
check "a second move is refused as a usage error" "$(rc --narrow)" 2
swap "$TMP/watcher/lib.js" "return OTHER + 1" "return OTHER + 3"
check "after the move an edit to an unnamed function is not drift" "$(rc)" 0

# --- the map and usage errors ---
snapshot
check "the map succeeds" "$(rc --map)" 0
check "the map marks a gate line" "$(jq -r '.A2.gate' "$TMP/out")" true
check "the map strips the gate mark from the name" "$(jq -r '.A2.name' "$TMP/out")" second
check "the map carries the other sheet's line" "$(jq -r '.O1.name' "$TMP/out")" gate
untouched "the map leaves the lock as found"
check "reconcile with no anchor is a usage error" "$(rc --reconcile)" 2
check "reconcile of an unknown anchor is a usage error" "$(rc --reconcile alpha:nope)" 2
check "acknowledging an unknown rule is a usage error" "$(rc --ack alpha:nope --reason x)" 2
check "acknowledging without a reason is a usage error" "$(rc --ack alpha:r3)" 2
untouched "a usage error leaves the lock as found"

if [[ "$FAILS" -eq 0 ]]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
