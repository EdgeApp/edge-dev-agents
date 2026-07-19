#!/usr/bin/env bash
# tdd-lint.sh — deterministic convention checks for a markdown TDD.
#
# Checks:
#   - metadata table at top with a Status row
#   - "## Contents" ToC present; every ToC link resolves to a real heading slug
#   - heading slugs unique (GFM slugger: lowercase, strip punctuation, space->-)
#   - every plain-text "section N"/"decision N" reference is inside a link
#   - zero em dashes (U+2014)
#   - no TBD/TODO/FIXME placeholders
#   - mermaid fences are non-empty
#
# Usage: tdd-lint.sh <file.md>
# Output: LINT_OK, or FINDING lines. Exit 0 = clean, 1 = findings/error.
set -euo pipefail

FILE="${1:-}"
[[ -f "$FILE" ]] || { echo "usage: tdd-lint.sh <file.md>" >&2; exit 1; }

node -e '
const fs = require("fs")
const src = fs.readFileSync(process.argv[1], "utf8")
const lines = src.split("\n")
const findings = []

// GFM heading slugger (ASCII docs; verified against gist rendering).
const counts = {}
function slug(text) {
  let s = text.toLowerCase().trim()
    .replace(/`/g, "")
    .replace(/[^a-z0-9 _\-]/g, "")
    .replace(/ /g, "-")
  if (counts[s] == null) { counts[s] = 0; return s }
  counts[s] += 1
  return s + "-" + counts[s]
}

// Collect headings (outside code fences) and their slugs.
let inFence = false
const slugs = new Set()
const headings = []
lines.forEach((line, i) => {
  if (/^```/.test(line)) { inFence = !inFence; return }
  if (inFence) return
  const m = /^(#{1,6})\s+(.*)$/.exec(line)
  if (m != null) {
    const s = slug(m[2])
    headings.push({ line: i + 1, text: m[2], slug: s })
    slugs.add(s)
  }
})

// Metadata table with Status row near the top.
const head = lines.slice(0, 25).join("\n")
if (!/\|\s*Status\s*\|/.test(head)) {
  findings.push("metadata: no Status row in the top metadata table")
}

// ToC present and resolvable.
if (!/^## Contents$/m.test(src)) {
  findings.push("toc: no \"## Contents\" section")
}
const linkRe = /\]\(#([^)]+)\)/g
let lm
lines.forEach((line, i) => {
  linkRe.lastIndex = 0
  while ((lm = linkRe.exec(line)) != null) {
    if (!slugs.has(lm[1])) {
      findings.push(`anchor: line ${i + 1} links to #${lm[1]} but no heading has that slug`)
    }
  }
})

// Plain-text section/decision references outside links.
inFence = false
lines.forEach((line, i) => {
  if (/^```/.test(line)) { inFence = !inFence; return }
  if (inFence || /^#{1,6}\s/.test(line)) return
  const stripped = line.replace(/\[[^\]]*\]\([^)]*\)/g, "LINK")
  const m = /\b([Ss]ections?|[Dd]ecisions?) [0-9]/.exec(stripped)
  if (m != null) {
    findings.push(`ref: line ${i + 1} has unlinked reference "${m[0]}..." — make it a clickable anchor link`)
  }
})

// Em dashes, placeholders.
lines.forEach((line, i) => {
  if (line.includes("—")) findings.push(`style: line ${i + 1} contains an em dash`)
  if (/\b(TBD|TODO|FIXME|XXX:)\b/.test(line)) findings.push(`placeholder: line ${i + 1} contains a deferred-work marker`)
})

// Mermaid fences non-empty.
const mermaid = src.match(/```mermaid\n([\s\S]*?)```/g) ?? []
mermaid.forEach(block => {
  if (block.replace(/```(mermaid)?/g, "").trim() === "") findings.push("mermaid: empty diagram block")
})

if (findings.length === 0) {
  console.log("LINT_OK headings=" + headings.length + " mermaid=" + mermaid.length)
} else {
  findings.forEach(f => console.log("FINDING " + f))
  process.exit(1)
}
' "$FILE"
