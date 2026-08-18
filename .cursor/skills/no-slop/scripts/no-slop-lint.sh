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
# V2 (designed 2026-07-28, not built): a small-model judge (claude -p, haiku)
# for the semantic tail these regexes cannot reach — regex flags a WIDE
# candidate net, the judge supplies precision, verdicts cached by sentence
# hash, fail-open, default-clean. Same judge-at-a-gate pattern as
# concession-validator / blocker-validator. Build it as a separate callable
# stage (--semantic) when cleanliness matters more than latency; calibrate
# haiku-vs-sonnet agreement on the corpus before any blocking use.
#
# Usage: no-slop-lint.sh <file.md> [--warn-only]
# Output: "HARD <line>: <finding>" / "WARN <line>: <finding>" per finding.
# Exit: 0 = clean or warnings only (always 0 with --warn-only), 1 = HARD
#       findings, 2 = usage.

set -uo pipefail

FILE="${1:-}"; MODE="${2:-}"
[ -f "$FILE" ] || { echo "usage: no-slop-lint.sh <file.md> [--warn-only]" >&2; exit 2; }
VOCAB="$(cd "$(dirname "$0")/.." && pwd)/banned-vocabulary.md"

node -e '
const fs = require("fs")
const [file, vocabFile, warnOnly] = process.argv.slice(1)

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
const COUNTNOUN = /^(?:changes?|defects?|issues?|things?|points?|reasons?|ways?|parts?|items?|fixes?|problems?|options?|notes?|steps?|cases?|goals?|aspects?|factors?|takeaways?|observations?|considerations?)\b/i
const TIME = /^(?:day|days|week|weeks|month|months|hour|hours|minute|minutes|second|seconds|percent|ms|px)\b/i
const VERBS = new Set(("is are was were has have had do does did start starts started take takes took run runs ran need needs use uses show shows fail fails work works go goes come comes mean means make makes get gets give gives keep keeps hold holds add adds drop drops call calls return returns throw throws pass passes block blocks land lands ship ships wait waits cover covers remain remains require requires").split(" "))
const PRED = /\b(?:are|is)\s+(?:easy to miss|worth noting|worth calling out|worth mentioning|notable|important to note)\b|\bstands? out\b|\bdeserves? (?:mention|attention)\b/i

const findings = []
let fence = false
fs.readFileSync(file, "utf8").split("\n").forEach((raw, i) => {
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
    if (/^-/.test(rest)) continue                          // "Two-phase ..."
    if (/^of\b/i.test(rest.trim())) continue               // "Two of the five ..."
    if (TIME.test(rest.trim())) continue                   // "Two days later ..."
    const toks = rest.trim().replace(/[.:]$/, "").split(/\s+/).filter(Boolean)
    const hasVerb = toks.some(t => VERBS.has(t.toLowerCase().replace(/[,;]$/, "")))
    // Shape 1 requires the LINE to end with the colon: "One visible seam: the
    // race is..." is the legitimate label-colon idiom, not an announcement.
    if (/:$/.test(s.trim()) && /:\s*$/.test(line) && toks.length <= 6 && !hasVerb)
      findings.push(["HARD", n, `count-announcement opener: "${s.trim().slice(0, 60)}"`])
    // Shape 4: counted padding header whose colon does NOT end the line
    // ("Two defects compound: the engine ..."). Restricted to generic
    // counter nouns so the legitimate label-colon idiom stays exempt.
    else if (/:$/.test(s.trim()) && !/:\s*$/.test(line) && COUNTNOUN.test(rest.trim()) && toks.length <= 4 && !hasVerb)
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
if (findings.length === 0) console.log("NO_SLOP_OK")
process.exit(hard > 0 && warnOnly !== "--warn-only" ? 1 : 0)
' "$FILE" "$VOCAB" "$MODE"
