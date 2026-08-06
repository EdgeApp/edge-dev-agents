#!/usr/bin/env bash
# tdd-glossary-link.sh — insert glossary anchor links into a TDD body, so link
# placement is computed rather than hand-placed.
#
# Placement rule (the same invariant tdd-lint.sh enforces): in EVERY top-level
# "## " section, the FIRST prose occurrence of each glossary term is linked.
# Once per term per section, not once per document: a reader who jumps straight
# to section 5 from the ToC gets clickable jargon without scrolling back to
# wherever the term happened to debut.
#
# Never touches: code fences, inline code spans, headings, the Contents list,
# the glossary section itself, or text already inside a markdown link.
# Idempotent: a second run makes no changes.
#
# Terms come from the "## Glossary" section's "### " entries. An entry titled
# "HMAC (hash-based message authentication code)" matches the bare acronym
# "HMAC"; an entry titled "Secure Enclave" matches that phrase, case-insensitive
# at a word boundary.
#
# Usage: tdd-glossary-link.sh <file.md> [--check]
#   (no flag) rewrites the file in place and reports what it linked
#   --check    reports what WOULD change and exits 1 if anything would, 0 if clean
# Exit: 0 = clean/updated, 1 = --check found missing links, 2 = usage/no glossary.
set -euo pipefail

FILE="${1:-}"
MODE="${2:-write}"
[[ -f "$FILE" ]] || { echo "usage: tdd-glossary-link.sh <file.md> [--check]" >&2; exit 2; }

node -e '
const fs = require("fs")
const file = process.argv[1]
const check = process.argv[2] === "--check"
const lines = fs.readFileSync(file, "utf8").split("\n")

// GFM slugger, matching tdd-lint.sh.
const counts = {}
const slug = text => {
  const s = text.toLowerCase().trim()
    .replace(/`/g, "")
    .replace(/[^a-z0-9 _\-]/g, "")
    .replace(/ /g, "-")
  if (counts[s] == null) { counts[s] = 0; return s }
  counts[s] += 1
  return s + "-" + counts[s]
}
// Pre-slug every heading so glossary slugs match what the renderer produces.
let fence = false
const headingSlug = {}
lines.forEach((l, i) => {
  if (/^```/.test(l)) { fence = !fence; return }
  if (fence) return
  const m = /^(#{1,6})\s+(.*)$/.exec(l)
  if (m != null) headingSlug[i] = slug(m[2])
})

const glossIdx = lines.findIndex(l => /^##\s+(\d+\.\s+)?Glossary\s*$/i.test(l))
if (glossIdx < 0) { console.log("NO_GLOSSARY"); process.exit(2) }
let glossEnd = lines.length
for (let i = glossIdx + 1; i < lines.length; i++) {
  if (/^##\s+/.test(lines[i])) { glossEnd = i; break }
}

// Terms: the matchable name plus the anchor to link to.
const terms = []
for (let i = glossIdx + 1; i < glossEnd; i++) {
  const m = /^###\s+(.*)$/.exec(lines[i])
  if (m == null) continue
  const title = m[1].trim()
  // "ACRONYM (expansion)" matches the acronym; otherwise the whole phrase.
  const paren = /^([^(]+?)\s*\(.*\)$/.exec(title)
  const name = (paren != null ? paren[1] : title).trim()
  terms.push({ name, anchor: headingSlug[i] })
}
// Longest first so "Android Keystore key attestation" wins over a shorter term.
terms.sort((a, b) => b.name.length - a.name.length)

const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
// Identifier-ish terms (attestationApplicationId) are case-sensitive and may be
// wrapped in backticks; prose terms match case-insensitively.
const isIdent = n => /^[a-z][A-Za-z0-9]*$/.test(n) && /[A-Z]/.test(n)

let sectionKey = ""
const linkedInSection = new Set()
const changes = []
fence = false

for (let i = 0; i < lines.length; i++) {
  const line = lines[i]
  if (/^```/.test(line)) { fence = !fence; continue }
  if (fence) continue
  if (i >= glossIdx && i < glossEnd) continue          // never inside the glossary
  const h = /^(#{1,6})\s+(.*)$/.exec(line)
  if (h != null) {
    if (h[1].length <= 2) { sectionKey = h[2]; linkedInSection.clear() }
    continue                                            // never link a heading
  }
  if (/^\s*\d+\.\s+\[/.test(line)) continue             // ToC entry
  if (/^\s*\|/.test(line) && /^\s*\|[\s:|-]+\|\s*$/.test(line)) continue

  let out = line
  for (const t of terms) {
    const key = sectionKey + "::" + t.anchor
    if (linkedInSection.has(key)) continue
    const flags = isIdent(t.name) ? "g" : "gi"
    const re = new RegExp("(`?)\\b" + esc(t.name) + "\\b(`?)", flags)
    let m
    let searchFrom = 0
    let placed = false
    while (!placed && (m = new RegExp(re.source, flags.replace("g", "") ).exec(out.slice(searchFrom))) != null) {
      const at = searchFrom + m.index
      const before = out.slice(0, at)
      // Skip when already inside a link text, a link target, or an odd number
      // of backticks (i.e. inside an inline code span that we are not wrapping).
      const openLink = /\[[^\]]*$/.test(before)
      const inTarget = /\]\([^)]*$/.test(before)
      const tickParity = (before.match(/`/g) || []).length % 2 === 1
      const wrappedInTicks = m[1] === "`" && m[2] === "`"
      // Already inside a link: this section already satisfies the invariant for
      // this term, so stop hunting. Continuing would link a SECOND occurrence on
      // every rerun, which is what made this pass non-idempotent.
      if (openLink) { linkedInSection.add(key); placed = true; break }
      if (inTarget || (tickParity && !wrappedInTicks)) {
        searchFrom = at + m[0].length
        continue
      }
      const text = m[0]
      out = before + "[" + text + "](#" + t.anchor + ")" + out.slice(at + text.length)
      linkedInSection.add(key)
      changes.push({ line: i + 1, term: t.name, section: sectionKey })
      placed = true
    }
  }
  lines[i] = out
}

if (check) {
  if (changes.length === 0) { console.log("GLOSSARY_LINKS_OK"); process.exit(0) }
  changes.forEach(c => console.log(`MISSING line ${c.line}: "${c.term}" unlinked in section "${c.section}"`))
  process.exit(1)
}
fs.writeFileSync(file, lines.join("\n"))
console.log("GLOSSARY_LINKS_APPLIED " + changes.length)
changes.forEach(c => console.log(`  linked "${c.term}" at line ${c.line} (${c.section})`))
' "$FILE" "$([[ "$MODE" == "--check" ]] && echo --check || echo --write)"
