#!/usr/bin/env bash
# no-slop-lint.sh — deterministic checks for the mechanically detectable subset
# of the no-slop rules. Shared by tdd-lint.sh, the run-report attach gate, and
# anything else that lints agent prose.
#
# Checks (tiered):
#   HARD  em dashes (U+2014)
#   HARD  banned vocabulary (parsed live from ../banned-vocabulary.md tables)
#   HARD  count-announcement openers, the high-precision shapes:
#           1. colon-terminated count NP:   "Three things:" "A few points:"
#           2. bare count-NP sentence:      "Two supporting facts." (no verb)
#           3. existential:                 "There are two issues ..."
#           4. mid-line counted padding header over a GENERIC-counter noun:
#              "Two defects compound: the engine ..." (the colon does not end
#              the line, so shape 1's label-colon exemption would pass it; the
#              generic-noun list keeps precision vs the legit label idiom
#              "One visible seam: the race ...")
#         (also matched after a greeting clause: "Hi team, two issues on X.")
#   WARN  count + contentless predicate:   "Two consequences are easy to miss."
#         (finite predicate list; incomplete by nature, hence warn-only)
#
# Exclusions keeping false positives out: code fences, headings, table rows,
# partitives ("Two of the five ..."), hyphenated compounds ("Two-phase auth"),
# time/measure nouns ("Two days later"), counts bound to a real verb
# ("Two engines start concurrently").
#
# V2 SEMANTIC TIER (designed 2026-07-28, built 2026-08-19): --semantic runs
# scripts/no-slop-judge.sh after the mechanical pass — a wide regex net
# nominates candidate sentences, one batched `claude -p` haiku call judges the
# rules regexes cannot decide (courtesy enders, forward references, validation
# preambles; SKILL rules 14/15), verdicts cached by sentence hash, fail-open.
# Opt-in per boundary: seconds of latency, so posting/attach boundaries use it,
# high-frequency write paths do not. When the judge cannot run it emits a
# non-blocking "WARN 0: semantic judge unavailable (<reason>)" line, so a dead
# tier is visible in the output instead of passing as NO_SLOP_OK.
#
# --fragment: the input is a text FRAGMENT (an Edit new_string, a Bash command
# carrying a heredoc), not a whole document. Runs only the checks that are
# position-independent (em dashes, banned vocabulary, session links, loudness)
# and skips the sentence-shape checks, which false-positive without the
# surrounding document.
#
# Usage: no-slop-lint.sh <file.md> [--warn-only] [--fragment] [--semantic]
# Output: "HARD <line>: <finding>" / "WARN <line>: <finding>" per finding.
# Exit: 0 = clean or warnings only (always 0 with --warn-only), 1 = HARD
#       findings, 2 = usage.

set -uo pipefail

FILE="${1:-}"
[ -f "$FILE" ] || { echo "usage: no-slop-lint.sh <file.md> [--warn-only] [--fragment] [--semantic]" >&2; exit 2; }
shift
WARN_ONLY=0 FRAGMENT=0 SEMANTIC=0
for a in "$@"; do
  case "$a" in
    --warn-only) WARN_ONLY=1 ;;
    --fragment)  FRAGMENT=1 ;;
    --semantic)  SEMANTIC=1 ;;
    *) echo "no-slop-lint: unknown flag $a" >&2; exit 2 ;;
  esac
done
VOCAB="$(cd "$(dirname "$0")/.." && pwd)/banned-vocabulary.md"

MECH_OUT=$(node -e '
const fs = require("fs")
const [file, vocabFile, fragment] = process.argv.slice(1)
const FRAGMENT = fragment === "1"

// Banned vocabulary: first cell of every table row in the vocab doc; entries
// like "delve / delve into" split on "/", "(metaphorical)" qualifiers dropped.
// Words whose TECHNICAL sense dominates in our repos (wallet keys, test
// harness, robust-to-failures, plugin ecosystem, underscore the character,
// currency landscape tables...): banned only in their filler sense, which a
// regex cannot tell apart — corpus dry-run flagged 10 legit uses of "key"
// alone. These stay prose-judgment / v2-judge territory.
const AMBIGUOUS = new Set(["key", "harness", "underscore", "robust", "ecosystem", "landscape", "word"])
const vocab = []
try {
  for (const line of fs.readFileSync(vocabFile, "utf8").split("\n")) {
    const m = line.match(/^\|\s*([^|]+?)\s*\|/)
    if (!m || /^-+$|^Banned$/.test(m[1].trim())) continue
    for (let w of m[1].split("/")) {
      w = w.replace(/\(.*?\)/g, "").trim().toLowerCase()
      if (w.length > 2 && !AMBIGUOUS.has(w)) vocab.push(w)
    }
  }
} catch {}

const NUM = "(?:one|two|three|four|five|six|seven|eight|nine|ten|\\d+|a few|several|a couple of|some)"
// Generic counter nouns: high-precision list for the mid-line padding-header
// shape. Only nouns whose count+colon use is near-always structural padding.
const COUNTNOUN = /^(?:changes?|defects?|issues?|things?|points?|reasons?|ways?|parts?|items?|fixes?|problems?|options?|notes?|steps?|cases?|goals?|aspects?|factors?|takeaways?|observations?|considerations?|blockers?|concerns?|gaps?|risks?|findings?|caveats?|constraints?|tradeoffs?|surprises?|corrections?|clarifications?|asks?|questions?|exceptions?|differences?|misses?|wins?)\b/i
const TIME = /^(?:day|days|week|weeks|month|months|hour|hours|minute|minutes|second|seconds|percent|ms|px)\b/i
const VERBS = new Set(("is are was were has have had do does did start starts started take takes took run runs ran need needs use uses show shows fail fails work works go goes come comes mean means make makes get gets give gives keep keeps hold holds add adds drop drops call calls return returns throw throws pass passes block blocks land lands ship ships wait waits cover covers remain remains require requires").split(" "))
const PRED = /\b(?:are|is)\s+(?:easy to miss|worth noting|worth calling out|worth mentioning|notable|important to note)\b|\bstands? out\b|\bdeserves? (?:mention|attention)\b/i

const findings = []
let fence = false
// Hard-wrapped prose (commit bodies wrap at 72, and PR bodies often inherit the
// habit) puts one sentence across several physical lines. The line-scoped checks
// below are unaffected, but every sentence-shape check needs the whole sentence:
// splitting "...a value of 9.789\nBTC." at the wrap made "BTC." read as a
// verbless bare-count sentence, and a colon landing on a wrap point read as a
// line-final colon. PARA[i] holds the joined paragraph for the line that STARTS
// it and null for continuation lines, so those checks run once per paragraph and
// report at its first line.
const LINES = fs.readFileSync(file, "utf8").split("\n")
const PARA = new Array(LINES.length).fill(null)
{
  let f = false, start = -1, buf = []
  const flush = () => {
    if (start >= 0 && buf.length) PARA[start] = buf.join(" ")
    start = -1; buf = []
  }
  LINES.forEach((raw, i) => {
    if (/^\s*```/.test(raw)) { f = !f; flush(); return }
    // A blank line, or any construct the per-line loop already skips, ends the
    // paragraph. A new list marker starts one, so sibling items never merge.
    if (f || !raw.trim() || /^\s*#|^\s*\||^\s*>/.test(raw)) { flush(); return }
    if (/^\s*(?:[-*]\s+|\d+[.)]\s+)/.test(raw)) flush()
    if (start < 0) start = i
    buf.push(raw.trim())
  })
  flush()
}
LINES.forEach((raw, i) => {
  const n = i + 1
  if (/^\s*```/.test(raw)) { fence = !fence; return }
  if (fence) return
  let line = raw
  // Em dashes: everywhere, including headings/tables.
  if (line.includes("—")) findings.push(["HARD", n, "em dash"])
  if (/^\s*#|^\s*\||^\s*>/.test(line)) return
  const isListItem = /^\s*(?:[-*]\s+|\d+[.)]\s+)/.test(line)
  line = line.replace(/^\s*(?:[-*]\s+|\d+[.)]\s+)?/, "") // markers stripped, content participates
  const lower = " " + line.toLowerCase() + " "
  for (const w of vocab) {
    if (lower.includes(" " + w + " ") || lower.includes(" " + w + ",") || lower.includes(" " + w + "."))
      findings.push(["HARD", n, `banned vocabulary: "${w}"`])
  }
  // Claude session links (operator ruling 2026-08-18): never in outward-facing
  // prose (PR bodies, repo docs, reports). Bare session IDs in report
  // frontmatter/stamp lines are fine — this matches URLs only.
  if (/claude\.ai\/(code|share|chat)\//i.test(line))
    findings.push(["HARD", n, "claude session link: outward-facing prose never carries chat/session URLs"])
  // Loudness precision (operator ruling 2026-08-18): "warn/log/print loudly"
  // is decorative (the output IS the loudness) — HARD. Any other loud/loudly
  // is a vague mechanism claim — WARN: the litmus is "say what happens and who
  // sees it" (exit code, gate, report section, operator ping).
  const DECOR = /\b(?:warn(?:s|ing)?|log(?:s|ging)?|print(?:s|ing)?|announc\w+)\s+loudly\b|\bloudly\s+(?:warn|log|print|announce)/i
  if (DECOR.test(line))
    findings.push(["HARD", n, `decorative "loudly" (the output is already the loud part): delete it or name the mechanism`])
  else if (/\bloud(?:ly)?\b/i.test(line))
    findings.push(["WARN", n, `vague loudness claim: name the mechanism and audience (exit code / gate / report section / ping)`])
  if (FRAGMENT) return  // sentence-shape checks need the whole document
  // Continuation lines carry no paragraph of their own; their text was folded
  // into the line that starts it.
  if (PARA[i] == null) return
  line = PARA[i].replace(/^\s*(?:[-*]\s+|\d+[.)]\s+)?/, "")
  // Count-announcement shapes, per SENTENCE; greeting clause stripped first.
  const body = line.replace(/^(?:hi|hello|hey)\b[^,]*,\s*/i, "")
  for (const s of body.split(/(?<=[.:!?])\s+/)) {
    const m = s.match(new RegExp("^(" + NUM + ")\\b[\\s]*([^]*)$", "i"))
    if (!m) {
      if (/^(?:there|here)\s+(?:are|is|were)\s+/i.test(s) && new RegExp("^(?:there|here)\\s+(?:are|is|were)\\s+" + NUM + "\\b", "i").test(s))
        findings.push(["HARD", n, `existential count announcement: "${s.slice(0, 60)}"`])
      continue
    }
    const rest = m[2]
    // A ZERO count is a conditional label, never a structure announcement:
    // "0 findings after curation: no review is submitted" states a case and its
    // consequence. Nobody announces that zero things follow.
    if (/^0+$/.test(m[1])) continue
    if (/^-/.test(rest)) continue                          // "Two-phase ..."
    if (/^of\b/i.test(rest.trim())) continue               // "Two of the five ..."
    if (TIME.test(rest.trim())) continue                   // "Two days later ..."
    const toks = rest.trim().replace(/[.:]$/, "").split(/\s+/).filter(Boolean)
    const hasVerb = toks.some(t => VERBS.has(t.toLowerCase().replace(/[,;]$/, "")))
    // Shape 4 only: the "bound to a real verb" exemption means the COUNTED NOUN
    // governs a verb ("Two options remain: ..."), not that a verb homograph sits
    // anywhere in a trailing qualifier. In "One blocker before we scope the
    // wallet work:", the noun "work" granted a blanket exemption. Check only the
    // head position, the token right after the counted noun.
    const headVerb = toks.length > 1 && VERBS.has(toks[1].toLowerCase().replace(/[,;]$/, ""))
    // Shape 1 requires the LINE to end with the colon: "One visible seam: the
    // race is..." is the legitimate label-colon idiom, not an announcement.
    if (/:$/.test(s.trim()) && /:\s*$/.test(line) && toks.length <= 6 && !hasVerb)
      findings.push(["HARD", n, `count-announcement opener: "${s.trim().slice(0, 60)}"`])
    // Shape 4: counted padding header whose colon does NOT end the line
    // ("Two defects compound: the engine ..."). Restricted to generic
    // counter nouns so the legitimate label-colon idiom stays exempt.
    else if (/:$/.test(s.trim()) && !/:\s*$/.test(line) && COUNTNOUN.test(rest.trim()) && toks.length <= 8 && !headVerb)
      findings.push(["HARD", n, `counted padding header (mid-line): "${s.trim().slice(0, 60)}"`])
    // Shape 2 applies to PROSE sentences only: a bare-NP BULLET ("- One
    // EdgeCurrencyWallet implementation.") is normal list style.
    else if (!isListItem && /\.$/.test(s.trim()) && toks.length >= 1 && toks.length <= 8 && !hasVerb)
      findings.push(["HARD", n, `bare count-NP sentence (verbless): "${s.trim().slice(0, 60)}"`])
    else if (PRED.test(s))
      findings.push(["WARN", n, `count + contentless predicate: "${s.trim().slice(0, 70)}"`])
  }
  // Shape 5: TRAILING count-apposition — a comma-appended counter closing the
  // sentence ("..., two separate things." / "..., three points:"). Same
  // announcement, different position; restricted to the generic counter nouns
  // (with optional filler adjective) so "..., two days later" and real content
  // stay exempt. (Gap found 2026-08-19: a Slack draft opened "Here is what we
  // found on our side, two separate things." and passed all leading shapes.)
  for (const s of body.split(/(?<=[.:!?])\s+/)) {
    const t = s.trim()
    const m5 = t.match(new RegExp(",\\s*(" + NUM + ")\\s+(?:separate\\s+|different\\s+|distinct\\s+|main\\s+|key\\s+|quick\\s+)?([a-z]+)\\s*[.:!]?$", "i"))
    if (m5 && COUNTNOUN.test(m5[2]) && !TIME.test(m5[2]))
      findings.push(["HARD", n, `trailing count-apposition: "${t.slice(-60)}"`])
  }
})

let hard = 0
for (const [tier, n, msg] of findings) {
  if (tier === "HARD") hard++
  console.log(`${tier} ${n}: ${msg}`)
}
process.exit(hard > 0 ? 1 : 0)
' "$FILE" "$VOCAB" "$FRAGMENT")
MECH_RC=$?

JUDGE_OUT="" JUDGE_RC=0
if [ "$SEMANTIC" = 1 ]; then
  JUDGE_OUT=$("$(dirname "$0")/no-slop-judge.sh" "$FILE") || JUDGE_RC=$?
  [ "$JUDGE_RC" = 1 ] || JUDGE_RC=0   # judge exit 2/errors fail open
fi

OUT=$(printf '%s\n%s\n' "$MECH_OUT" "$JUDGE_OUT" | grep -v '^$' || true)
if [ -z "$OUT" ]; then
  echo "NO_SLOP_OK"
  exit 0
fi
printf '%s\n' "$OUT"
HARD_PRESENT=0
{ [ "$MECH_RC" = 1 ] || [ "$JUDGE_RC" = 1 ]; } && HARD_PRESENT=1
if [ "$HARD_PRESENT" = 1 ] && [ "$WARN_ONLY" = 0 ]; then exit 1; fi
exit 0
