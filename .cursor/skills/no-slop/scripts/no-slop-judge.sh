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
#   aphorism-formula     an ordinary claim dressed as a maxim (SKILL rule 17)
#   second-proof         a second observation restating a proven point (rule 22)
#   extra-ask            a second request or history aside on a message (rule 22)
#   uniform-connector-cadence  a run of adjacent "X, so Y"/"X, and Y" compound
#                        sentences sharing one shape (SKILL rule 20); nominated
#                        per WINDOW of consecutive sentences, not per sentence
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
# FAIL-OPEN BUT NEVER SILENT: a call that was attempted and produced no
# verdicts prints "WARN 0: semantic judge unavailable (<reason>)" on stdout and
# a "no-slop-judge: UNAVAILABLE ..." line on stderr. Exit stays 0, so no
# boundary blocks on a judge outage, but a dead tier no longer reads as a clean
# pass. Every run also writes a stderr census (candidates / cached / judged) so
# "nothing nominated" and "nothing judged" are distinguishable.
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
  [/\b(happy to|glad to|feel free|let me know|hope (this|that|it) helps|reach out|don\x27t hesitate|say the word|if (that|this) helps|any questions|no concerns|nothing further|nothing else|that\x27s all|all set|we\x27re good|shout if|ping me|holler|up to you|either way|whatever works|no rush|no hurry|at your convenience|when(ever)? (you|someone|anyone) (get|gets|has|have)( a)? (moment|chance|sec|second)|if (helpful|useful|needed)|here to help|on hand|available if|as needed|for anything else)\b/i, "courtesy-ender"],
  [/\b(here\x27s (what|the|why|how)|the key (thing|point|takeaway|insight)|what matters( most)?|worth (noting|flagging|mentioning|calling out)|let\x27s break|let me break|to summarize|to be clear|simply put|importantly|notably)\b/i, "forward-reference"],
  // Numeric preview of the structure that follows ("Three things need...",
  // "four items below"). The prose form of "Three things:" reads as content, so
  // the mechanical tier misses it; the judge decides whether it announces.
  [/\b(two|three|four|five|six|seven|eight|nine|ten|\d+) (?:[a-z]+ ){0,2}(things|items|points|questions|reasons|takeaways|asks|notes|observations)\b/i, "structure-announcement"],
  [/^(good|great|excellent|fair|solid|nice) (question|point|catch|call)\b|\byou\x27re (absolutely |quite )?right\b|\bvalid (point|concern)\b/i, "validation-preamble"],
  [/\b(boils down to|comes down to|the difference between|the whole point|becomes a trap|think of it as|where the rubber|is the [a-z]+ of (?:the|a|all)\b)/i, "aphorism-formula"],
  // SKILL rule 22: a second observation restating a proven point, and a
  // second request or a history aside riding on the real ask of the message.
  [/\b(sees? (?:this|it|the same) too|also (?:sees?|confirms?|shows?|returns?) (?:this|it|the same)|confirms? (?:this|it|the same)|the same (?:thing|result|failure|error) (?:from|in|on)|as well as the|likewise)\b/i, "second-proof"],
  [/\b(once before|has happened before|in the past|previously|last time|back on [A-Z][a-z]{2}|if (?:the key|it|that|this) (?:changed|was rotated),? please|please (?:also|in addition)|one more (?:thing|ask|request)|separately,? (?:can|could|please))\b/i, "extra-ask"],
]

const hash = s => crypto.createHash("sha256").update(s.replace(/\s+/g, " ").trim().toLowerCase()).digest("hex").slice(0, 16)

// Collect candidates: per non-fence, non-heading, non-table line, per sentence.
const candidates = []  // {line, sentence, hint}
const prose = []       // ordered sentence stream for window-level rules
let fence = false
fs.readFileSync(file, "utf8").split("\n").forEach((raw, i) => {
  if (/^\s*```/.test(raw)) { fence = !fence; return }
  if (fence || /^\s*#|^\s*\||^\s*>/.test(raw)) return
  const line = raw.replace(/^\s*(?:[-*]\s+|\d+[.)]\s+)?/, "")
  for (const s of line.split(/(?<=[.:!?])\s+/)) {
    const t = s.trim()
    if (t.length < 8) continue
    prose.push({ line: i + 1, sentence: t })
    for (const [re, hint] of NETS) {
      if (re.test(t)) { candidates.push({ line: i + 1, sentence: t, hint }); break }
    }
  }
})

// Window-level net (SKILL rule 20): 3+ CONSECUTIVE sentences each carrying a
// mid-sentence ", so/and/but " join nominate as ONE candidate — the whole run,
// joined with " | ". The net is wide (list commas match too); the judge owns
// precision, same as the per-sentence nets.
const COMPOUND = /,\s+(so|and|but)\s+\S/i
for (let i = 0; i < prose.length; ) {
  let j = i
  while (j < prose.length && COMPOUND.test(prose[j].sentence)) j++
  if (j - i >= 3) {
    const run = prose.slice(i, j)
    candidates.push({
      line: run[0].line,
      sentence: run.map(p => p.sentence.replace(/\n/g, " ")).join(" | "),
      hint: "uniform-connector-cadence"
    })
  }
  i = Math.max(j, i + 1)
}
const diag = m => { try { fs.writeSync(2, "no-slop-judge: " + m + "\n") } catch {} }
if (!candidates.length) { diag("0 candidates nominated"); process.exit(0) }

// Cache pass.
const findings = []
const toJudge = []
let unavailable = null
let judgedCount = 0
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
    "You judge sentences from technical prose against the rules below. Answer with JSON ONLY, no prose.",
    "",
    "Rule courtesy-ender: a content-free courtesy or OPEN-ENDED offer, typically closing a message: \"Happy to re-review once X lands\", \"Let me know if you have questions\", \"Hope this helps\", \"Feel free to reach out\". DIRECTION IS THE TEST: the violation is something the WRITER offers or an open invitation to be contacted, carrying no information. A REQUEST TO THE RECIPIENT is never this rule, however politely softened: \"Still waiting on that square PNG logo, whenever someone has a moment\" and \"the signed copy when you get a chance, no rush\" both name an outstanding deliverable, so they carry information and are clean. NOT a violation either when the phrase does technical work (\"the happy path returns the cached token\", \"clients are free to retry\") or requests a SPECIFIC needed decision or input (\"Let me know which of the two schemas you pick, since the migration differs\" asks for a concrete choice the work depends on; \"let me know if you have questions\" asks for nothing).",
    "Rule forward-reference: a sentence whose only job is to preview, announce, or grade the prose itself: \"Here is what matters:\", \"Worth flagging explicitly:\", \"The key thing is this:\", \"To summarize:\", \"Let me break this down\". NOT a violation when the sentence carries the actual claim alongside: \"Worth noting the cache is already warm, so the retry is free\" still announces, but \"The cache is already warm, so the retry is free\" does not; judge whether removing the announcing clause loses information.",
    "Rule validation-preamble: an opener that grades the reader\x27s stance instead of stating facts: \"Good question\", \"You\x27re right to push on this\", \"Fair point\". NOT a violation when agreement itself is the factual content and is followed by the specifics in the same sentence.",
    "Rule aphorism-formula: an ordinary claim dressed as a maxim instead of stated plainly: \"That is the difference between shipping a claim flow and shipping a warning\", \"It all boils down to trust\", \"Latency becomes a trap\". NOT a violation when the construction carries a real comparison or measurement the reader needs (\"the difference between the two timeouts is 90 seconds\", \"the cost comes down to one extra round trip\"); judge whether a concrete fact would be lost by rewriting it flat.",
    "Rule second-proof: a sentence that adds a SECOND observation confirming a point the previous sentence already proved: \"Our production plugin sees this too: quotes fail with 401\" after \"every endpoint returns 401 for any key\". NOT a violation when the second observation adds a different fact the reader acts on (a different endpoint, a different user impact, a number the first lacked).",
    "Rule extra-ask: a message-level rule. Violation when the sentence is a SECOND request piggybacking on the message\x27s real ask (\"If the key changed, please send us the current one\" after \"Was the key revoked or rotated?\"), or a history aside the recipient does not need to act on (\"It was disabled once before, on Apr 27\"). NOT a violation when the sentence is the only request in the message, or when the prior incident changes what the recipient must do now.",
    "Rule uniform-connector-cadence: applies ONLY to entries containing \" | \", which mark a RUN of consecutive sentences from the document. Violation when the run shares one repeated two-clause shape — independent clause, comma, connector (so/and/but), clause — so the passage reads as a drumbeat: \"The cache was cold, so the first load was slow. | The index was stale, so the query scanned. | The pool was small, and the workers queued.\" NOT a violation when a matched comma joins list items rather than clauses (\"a, b, and c\"), when the sentences otherwise vary clearly in shape and length, or when splitting any of the connectors would lose a causal or coordinate link the reader needs. Judge the run as a whole, not each sentence.",
    "",
    "Sentences:",
    ...cap.map((c, i) => (i + 1) + ". " + c.sentence.replace(/\n/g, " ")),
    "",
    "Output: a JSON array, one entry per sentence number, shape {\"n\": <number>, \"violation\": true|false, \"rule\": \"courtesy-ender\"|\"forward-reference\"|\"validation-preamble\"|\"aphorism-formula\"|\"uniform-connector-cadence\"|\"second-proof\"|\"extra-ask\"|\"none\"}."
  ].join("\n")

  let verdicts = null, failure = null
  try {
    const out = execSync("claude -p --model haiku", { input: prompt, timeout: 90000, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] })
    const m = out.match(/\[[\s\S]*\]/)
    if (m) {
      const arr = JSON.parse(m[0])
      if (Array.isArray(arr)) verdicts = arr
    }
    if (!verdicts) failure = "unparseable response"
  } catch (e) {
    const raw = [e && e.stdout, e && e.stderr, e && e.message].filter(Boolean).join(" ")
    failure = String(raw).replace(/\s+/g, " ").trim().slice(0, 120) || "claude -p failed"
  }

  if (verdicts) {
    for (const v of verdicts) {
      const c = cap[(v.n | 0) - 1]
      if (!c) continue
      const bad = v.violation === true && v.rule && v.rule !== "none"
      try { fs.writeFileSync(cacheDir + "/" + hash(c.sentence), bad ? "1 " + v.rule : "0") } catch {}
      judgedCount++
      if (bad) findings.push({ ...c, rule: v.rule })
    }
  } else {
    // Fail open on findings, but never silently: an unauthenticated or broken
    // `claude -p` used to be indistinguishable from a clean pass, which hid a
    // dead judge tier for weeks. Cache nothing so a fix takes effect at once.
    unavailable = { reason: failure || "no verdicts", n: cap.length }
  }
}

findings.sort((a, b) => a.line - b.line)
for (const f of findings) console.log(`HARD ${f.line}: judge(${f.rule}): "${f.sentence.slice(0, 90)}"`)
if (unavailable) {
  console.log(`WARN 0: semantic judge unavailable (${unavailable.reason}); ${unavailable.n} candidate sentence(s) unjudged`)
  diag(`UNAVAILABLE (${unavailable.reason}); ${unavailable.n} candidates unjudged`)
} else {
  diag(`${candidates.length} candidates, ${candidates.length - toJudge.length} cached, ${judgedCount} judged`)
}
process.exit(findings.length ? 1 : 0)
' "$FILE" "$CACHE"
