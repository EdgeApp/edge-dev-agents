#!/usr/bin/env bash
# no-slop-judge.sh — the V2 SEMANTIC tier of the no-slop lint (designed
# 2026-07-28, built 2026-08-19): a small-model judge for the judgment-tier
# rules regexes cannot decide. A wide regex net nominates candidate sentences;
# a single batched `claude -p` (haiku) call rules on them; verdicts are cached
# by sentence hash so repeat lints are free.
#
# Rules judged (no-slop SKILL rules 14/15):
#   courtesy-ender       content-free courtesy/offer closers
#   forward-reference    sentences that only preview/announce/grade the prose
#   validation-preamble  stance-validation openers ("good question", "you're right")
#
# Why a judge: "Happy to re-review once the token bridge lands" and "happy path
# returns the cached token" share every token a regex can see; only reading
# comprehension separates them. The 2026-08-19 incident: a PR review posted
# both a courtesy ender and a forward reference, and the mechanical lint
# correctly (by its own scope) printed NO_SLOP_OK.
#
# FAIL-OPEN EVERYWHERE: no claude binary, timeout, unparseable response — all
# produce zero findings and exit 0. Only a parsed, affirmative violation
# verdict emits. Verdicts cache under ~/.cache/no-slop-judge/ ("1 <rule>" or
# "0" per sentence hash); failures are never cached.
#
# Usage: no-slop-judge.sh <file>
# Output: "HARD <line>: judge(<rule>): \"<sentence>\"" per finding.
# Exit: 0 = clean or fail-open, 1 = findings, 2 = usage.

set -uo pipefail
FILE="${1:-}"
[ -f "$FILE" ] || { echo "usage: no-slop-judge.sh <file>" >&2; exit 2; }
command -v claude >/dev/null 2>&1 || exit 0

CACHE="$HOME/.cache/no-slop-judge"
mkdir -p "$CACHE" 2>/dev/null || exit 0

node -e '
const fs = require("fs")
const crypto = require("crypto")
const { execSync } = require("child_process")
const [file, cacheDir] = process.argv.slice(1)

// Wide candidate net. Precision comes from the judge, so these lean inclusive.
const NETS = [
  [/\b(happy to|glad to|feel free|let me know|hope (this|that|it) helps|reach out|don\x27t hesitate|say the word|if (that|this) helps|any questions)\b/i, "courtesy-ender"],
  [/\b(here\x27s (what|the|why|how)|the key (thing|point|takeaway|insight)|what matters( most)?|worth (noting|flagging|mentioning|calling out)|let\x27s break|let me break|to summarize|to be clear|simply put|importantly|notably)\b/i, "forward-reference"],
  [/^(good|great|excellent|fair|solid|nice) (question|point|catch|call)\b|\byou\x27re (absolutely |quite )?right\b|\bvalid (point|concern)\b/i, "validation-preamble"],
]

const hash = s => crypto.createHash("sha256").update(s.replace(/\s+/g, " ").trim().toLowerCase()).digest("hex").slice(0, 16)

// Collect candidates: per non-fence, non-heading, non-table line, per sentence.
const candidates = []  // {line, sentence, hint}
let fence = false
fs.readFileSync(file, "utf8").split("\n").forEach((raw, i) => {
  if (/^\s*```/.test(raw)) { fence = !fence; return }
  if (fence || /^\s*#|^\s*\||^\s*>/.test(raw)) return
  const line = raw.replace(/^\s*(?:[-*]\s+|\d+[.)]\s+)?/, "")
  for (const s of line.split(/(?<=[.:!?])\s+/)) {
    const t = s.trim()
    if (t.length < 8) continue
    for (const [re, hint] of NETS) {
      if (re.test(t)) { candidates.push({ line: i + 1, sentence: t, hint }); break }
    }
  }
})
if (!candidates.length) process.exit(0)

// Cache pass.
const findings = []
const toJudge = []
for (const c of candidates) {
  const h = hash(c.sentence)
  let cached = null
  try { cached = fs.readFileSync(cacheDir + "/" + h, "utf8").trim() } catch {}
  if (cached === "0") continue
  if (cached && cached.startsWith("1 ")) { findings.push({ ...c, rule: cached.slice(2) }); continue }
  toJudge.push(c)
}

if (toJudge.length) {
  const cap = toJudge.slice(0, 40)  // bound the batch; the rest judges next run
  const prompt = [
    "You judge sentences from technical prose against three rules. Answer with JSON ONLY, no prose.",
    "",
    "Rule courtesy-ender: a content-free courtesy or OPEN-ENDED offer, typically closing a message: \"Happy to re-review once X lands\", \"Let me know if you have questions\", \"Hope this helps\", \"Feel free to reach out\". NOT a violation when the phrase does technical work (\"the happy path returns the cached token\", \"clients are free to retry\") or requests a SPECIFIC needed decision or input (\"Let me know which of the two schemas you pick, since the migration differs\" asks for a concrete choice the work depends on; \"let me know if you have questions\" asks for nothing).",
    "Rule forward-reference: a sentence whose only job is to preview, announce, or grade the prose itself: \"Here is what matters:\", \"Worth flagging explicitly:\", \"The key thing is this:\", \"To summarize:\", \"Let me break this down\". NOT a violation when the sentence carries the actual claim alongside: \"Worth noting the cache is already warm, so the retry is free\" still announces, but \"The cache is already warm, so the retry is free\" does not; judge whether removing the announcing clause loses information.",
    "Rule validation-preamble: an opener that grades the reader\x27s stance instead of stating facts: \"Good question\", \"You\x27re right to push on this\", \"Fair point\". NOT a violation when agreement itself is the factual content and is followed by the specifics in the same sentence.",
    "",
    "Sentences:",
    ...cap.map((c, i) => (i + 1) + ". " + c.sentence.replace(/\n/g, " ")),
    "",
    "Output: a JSON array, one entry per sentence number, shape {\"n\": <number>, \"violation\": true|false, \"rule\": \"courtesy-ender\"|\"forward-reference\"|\"validation-preamble\"|\"none\"}."
  ].join("\n")

  let verdicts = null
  try {
    const out = execSync("claude -p --model haiku", { input: prompt, timeout: 90000, encoding: "utf8", stdio: ["pipe", "pipe", "ignore"] })
    const m = out.match(/\[[\s\S]*\]/)
    if (m) {
      const arr = JSON.parse(m[0])
      if (Array.isArray(arr)) verdicts = arr
    }
  } catch {}

  if (verdicts) {
    for (const v of verdicts) {
      const c = cap[(v.n | 0) - 1]
      if (!c) continue
      const bad = v.violation === true && v.rule && v.rule !== "none"
      try { fs.writeFileSync(cacheDir + "/" + hash(c.sentence), bad ? "1 " + v.rule : "0") } catch {}
      if (bad) findings.push({ ...c, rule: v.rule })
    }
  }
  // No verdicts (call failed / unparseable): fail open, cache nothing.
}

findings.sort((a, b) => a.line - b.line)
for (const f of findings) console.log(`HARD ${f.line}: judge(${f.rule}): "${f.sentence.slice(0, 90)}"`)
process.exit(findings.length ? 1 : 0)
' "$FILE" "$CACHE"
