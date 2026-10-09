#!/usr/bin/env bash
# orch-prose-lint.sh: content conventions for text an agent POSTS about its own
# work (run reports, PR bodies, TDDs, Asana comments and descriptions). The
# shared home for reporting rules that are not AI-prose tells; those stay in
# no-slop-lint.sh. Every posting boundary calls both.
#
# Checks:
#   HARD  passing-suite totals: "Mocha suite: 731 passing", "Tests: 731 passed,
#         731 total", "all 731 tests pass", "2 failing, 729 passing". A green
#         suite is the expected state, so its size is not a finding. Posted text
#         names failing tests (if any) and the new or changed cases, and when
#         neither exists names the check and stops ("verify-repo.sh clean").
#         Fenced blocks and code spans are checked too: a pasted suite summary
#         is the same noise. A count before an unrelated noun passes ("2
#         passing lanes"), as does "the 3 new cases pass".
#
# Usage:  orch-prose-lint.sh <file>
# Output: "HARD <line>: <finding>" per finding, nothing when clean.
# Exit:   0 = clean, 1 = HARD findings, 2 = usage.

set -uo pipefail

FILE="${1:-}"
[[ -n "$FILE" && -f "$FILE" ]] || { echo "usage: orch-prose-lint.sh <file>" >&2; exit 2; }

exec node -e '
const fs = require("fs")
const NOUN = "(?:tests?|specs?|suites?|assertions?)"
const KIND = "(?:(?:unit|jest|mocha)\\s+)?"
const AFTER = "(?:in|on|and|with|across|after|locally|now|again|total|tests?|specs?|cases?|assertions?)"
const TOTAL = new RegExp(
  "\\b\\d[\\d,]*\\s+" + KIND + "(?:" + NOUN + "\\s+)?(?:passing|passed)\\b(?!\\s+(?!" + AFTER + "\\b)[a-z])" +
  "|\\b\\d[\\d,]*\\s+" + KIND + NOUN + "\\s+pass\\b", "i")
let hard = 0
fs.readFileSync(process.argv[1], "utf8").split("\n").forEach((line, i) => {
  const m = line.match(TOTAL)
  if (!m) return
  hard++
  console.log(`HARD ${i + 1}: passing-suite total "${m[0]}": name failing tests (if any) and the new or changed cases, never the passing count`)
})
process.exit(hard ? 1 : 0)
' "$FILE"
