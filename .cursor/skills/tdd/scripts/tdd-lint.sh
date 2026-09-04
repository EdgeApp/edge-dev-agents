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
#   - mermaid fences are non-empty; quoted node brackets match; no participant
#     ID spells a mermaid keyword. That last one shipped a broken diagram once:
#     `participant Create as RampCreateScene` declares fine, then the first
#     `X->>Create:` message fails ("Expecting ... 'ACTOR', got 'create'") and
#     GitHub renders "Unable to render rich display" in place of the diagram.
#     The error points at the message line, not the declaration, and nothing
#     else in a repo parses mermaid, so this lint is the only thing between a
#     reserved-word ID and a human opening the file on GitHub.
#   - no semicolon in mermaid message/note text: mermaid lexes ";" as a
#     statement terminator even mid-text, so the remainder parses as a bogus
#     statement and GitHub shows "Unable to render rich display". Scoped to
#     text after a ":" so flowchart statement-ending semicolons stay legal.
#   - glossary: every "### Term" under "## Glossary" carries a source link
#     (HARD); first use of each term in EVERY top-level section is linked, via
#     tdd-glossary-link.sh --check (HARD); unexplained ALL-CAPS acronyms suggest
#     an entry (WARN)
#
# Usage: tdd-lint.sh <file.md>
# Output: LINT_OK, FINDING lines (hard), or WARN lines.
# Exit 0 = clean or warnings only, 1 = findings/error.
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

// The number a link DISPLAYS must match the heading its anchor resolves to.
// Renumbering rewrites the anchor and leaves the text behind, and the result
// still RESOLVES, so the check above cannot see it: a link reading
// "decision 9.1" whose anchor points at section 7.1 looks correct to every
// mechanical check and wrong to every reader.
const headingBySlug = new Map(headings.map(h => [h.slug, h.text]))
const numberedLinkRe = /\[([^\]]*)\]\(#([^)]+)\)/g
lines.forEach((line, i) => {
  numberedLinkRe.lastIndex = 0
  let nm
  while ((nm = numberedLinkRe.exec(line)) != null) {
    const text = nm[1]
    const anchor = nm[2]
    const heading = headingBySlug.get(anchor)
    if (heading == null) continue
    const hn = /^(\d+(?:\.\d+)*)\.?\s/.exec(heading)
    if (hn == null) continue
    const tn =
      /(?:^|\s)(?:[Ss]ections?|[Dd]ecisions?)\s+(\d+(?:\.\d+)*)\b/.exec(text) ??
      /^\s*(\d+(?:\.\d+)*)\s*$/.exec(text)
    if (tn == null) continue
    if (tn[1] !== hn[1]) {
      findings.push(`ref: line ${i + 1} displays "${tn[1]}" but #${anchor} is section ${hn[1]} — renumbering left the link text behind`)
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

// Mermaid fences non-empty, and quoted node brackets must match:
// a node like X{"text"] (open brace, close bracket) is a GitHub render error.
const mermaid = src.match(/```mermaid\n([\s\S]*?)```/g) ?? []
const pairs = { "[": "]", "{": "}", "(": ")" }
mermaid.forEach(block => {
  if (block.replace(/```(mermaid)?/g, "").trim() === "") findings.push("mermaid: empty diagram block")
  const nodeRe = /([\[{(])"[^"]*"([\]})])/g
  let nm
  while ((nm = nodeRe.exec(block)) != null) {
    if (pairs[nm[1]] !== nm[2]) {
      findings.push("mermaid: mismatched node brackets " + nm[1] + "\"...\"" + nm[2] + " (renders as a parse error)")
    }
  }
})

// A participant ID is lexed, so one that spells a mermaid keyword is read as
// that keyword. Verified against mermaid 11: each ID below fails to parse, the
// display label after "as" is unaffected, and no ID that merely STARTS with a
// keyword breaks. Line-aware pass so the finding points at the declaration.
const MERMAID_RESERVED = new Set(["create","destroy","participant","actor","activate","deactivate","note","loop","end","alt","else","opt","par","and","rect","box","link","links","autonumber","critical","option","break","title","over","properties","details"])
let inMermaid = false
lines.forEach((line, i) => {
  if (/^\s*```mermaid\s*$/.test(line)) { inMermaid = true; return }
  if (/^\s*```/.test(line)) { inMermaid = false; return }
  if (!inMermaid) return
  const pm = /^\s*(?:create\s+|destroy\s+)?(?:participant|actor)\s+([A-Za-z0-9_]+)\s*(?:\bas\b|$)/i.exec(line)
  if (pm != null && MERMAID_RESERVED.has(pm[1].toLowerCase())) {
    findings.push(`mermaid: line ${i + 1} declares participant "${pm[1]}", a mermaid keyword — the diagram fails to parse at the first message that names it. Rename the ID (the label after "as" can keep the old wording)`)
  }
  // ";" is a statement terminator even inside message/note text: everything
  // after it parses as a new (bogus) statement and the diagram fails to
  // render. Only text after a ":" is checked, so flowchart lines that
  // legitimately END statements with ";" (no colon) do not trip this.
  const ci = line.indexOf(":")
  if (ci >= 0 && line.indexOf(";", ci) >= 0) {
    findings.push(`mermaid: line ${i + 1} has a semicolon in message/note text — mermaid lexes ";" as a statement terminator and the diagram fails to render. Use a comma`)
  }
  // A labelled dotted link is "-. text .->"; the spaces are part of the token.
  // Written as "-.text.->" the label is not lexed as a label and the edge is
  // dropped from the rendered graph, silently and with no parse error. The
  // unlabelled "-.->" has no label to space and never matches here.
  const dm = /-\.([^\n]*?)\.->/.exec(line)
  if (dm != null && !(/^ /.test(dm[1]) && / $/.test(dm[1]))) {
    findings.push(`mermaid: line ${i + 1} writes a dotted link label as "-.${dm[1]}.->" — mermaid needs a space on each side ("-. ${dm[1].trim()} .->") or the edge renders without its label`)
  }
})

// ---------------------------------------------------------------------------
// Glossary. A reader who does not already know the jargon is the one the doc
// has to serve, so every term the doc leans on is defined once, sourced, and
// linked from where it is first used.
// ---------------------------------------------------------------------------
const warns = []
// Heading may be numbered per the template ("## 10. Glossary") or bare.
const glossIdx = lines.findIndex(l => /^##\s+(\d+\.\s+)?Glossary\s*$/i.test(l))
const glossTerms = []
if (glossIdx >= 0) {
  // Entries run until the next ## heading.
  let end = lines.length
  for (let i = glossIdx + 1; i < lines.length; i++) {
    if (/^##\s+/.test(lines[i])) { end = i; break }
  }
  let cur = null
  for (let i = glossIdx + 1; i < end; i++) {
    const m = /^###\s+(.*)$/.exec(lines[i])
    if (m != null) {
      if (cur != null) glossTerms.push(cur)
      // Reuse the slug computed in the heading pass: slug() carries a dedupe
      // counter, so calling it twice on the same text yields a "-1" variant.
      const h = headings.find(x => x.line === i + 1)
      cur = { term: m[1].trim(), line: i + 1, slug: h != null ? h.slug : null, body: [] }
    } else if (cur != null) {
      cur.body.push(lines[i])
    }
  }
  if (cur != null) glossTerms.push(cur)

  glossTerms.forEach(g => {
    // Source link: an external http(s) link somewhere in the entry.
    if (!/https?:\/\//.test(g.body.join("\n"))) {
      findings.push(`glossary: entry "${g.term}" (line ${g.line}) has no source link — add one for further reading`)
    }
  })

  // Per-section first-use linking is enforced deterministically by
  // tdd-glossary-link.sh --check (run after this node block).
}

// Decisions: every entry names what would reopen it. The alternatives and the
// evidence are judgment, but the trigger is checkable, and it is the part that
// silently goes missing: a decision with no trigger is invisible on the day the
// condition that would reopen it flips.
const decIdx = lines.findIndex(l => /^##\s+(\d+\.\s+)?Decisions\s*$/i.test(l))
if (decIdx >= 0) {
  let decEnd = lines.length
  for (let i = decIdx + 1; i < lines.length; i++) {
    if (/^##\s+/.test(lines[i])) { decEnd = i; break }
  }
  let cur = null
  const flushDecision = () => {
    if (cur == null) return
    if (!/reopen/i.test(cur.body.join("\n"))) {
      findings.push(`decision: "${cur.title}" (line ${cur.line}) names no reopen trigger — say what would reopen it (decisions-with-alternatives)`)
    }
  }
  for (let i = decIdx + 1; i < decEnd; i++) {
    const dm = /^###\s+(.*)$/.exec(lines[i])
    if (dm != null) {
      flushDecision()
      cur = { title: dm[1].trim(), line: i + 1, body: [] }
    } else if (cur != null) {
      cur.body.push(lines[i])
    }
  }
  flushDecision()
}

// Acronyms that need no explanation to this audience.
const COMMON = new Set(["HTTP","HTTPS","JSON","URL","URI","API","CI","CD","PR","ID","IDS","OS","UI","UX","SDK","TLS","SSL","DNS","IP","TCP","UDP","HTML","CSS","XML","YAML","SQL","REST","CRUD","MVP","TODO","FAQ","AWS","GPU","CPU","RAM","USB","PDF","ISO","UTC","AM","PM","OK","NA","EU","US","QA","RFC","MB","KB","GB","MS","SH","JS","TS","NPM","GIT","IDE","CLI","GUI","APK","IPA","LAN","VPN","SSH","JWTS"])
const glossNames = new Set(glossTerms.map(g => g.term.toUpperCase()))
const seenAcronym = new Set()
inFence = false
lines.forEach((line, i) => {
  if (/^```/.test(line)) { inFence = !inFence; return }
  if (inFence) return
  if (glossIdx >= 0 && i > glossIdx) return
  // Strip inline code and links so identifiers and URLs do not trip this.
  const text = line.replace(/`[^`]*`/g, " ").replace(/\]\([^)]*\)/g, "]")
  let m
  const acr = /\b([A-Z][A-Z0-9]{1,5})\b/g
  while ((m = acr.exec(text)) != null) {
    const a = m[1]
    if (COMMON.has(a) || seenAcronym.has(a)) continue
    // Version and model designators (V2, S9, G5) are not jargon.
    if (/^[A-Z][0-9]+$/.test(a)) continue
    // Defined in the glossary if any entry names it.
    let defined = false
    glossNames.forEach(n => { if (n.split(/[^A-Z0-9]+/).includes(a)) defined = true })
    if (defined) continue
    seenAcronym.add(a)
    warns.push(`glossary: line ${i + 1} uses "${a}" with no glossary entry — define it or spell it out`)
  }
})

// Code-block captions: exactly one per block, immediately above its fence, and
// pinned to a commit rather than a branch. A hand-written branch caption left
// beside a generated one shipped a doc with the same file linked twice; the
// linker now collapses that run, and this catches any that slip in another way.
const captionLine = /^\[`?([^`\]]+)`?\]\((https:\/\/github\.com\/[^/]+\/[^/]+\/blob\/\S+)\)\s*$/
lines.forEach((line, i) => {
  const m = captionLine.exec(line)
  if (m == null) return
  const [, labelPath, url] = m
  if (!url.endsWith("/" + labelPath)) return
  const next = lines[i + 1] || ""
  if (captionLine.test(next)) {
    findings.push(`codeblock caption: line ${i + 1} is followed by a second caption — one block, one caption (run tdd-codeblock-link.sh)`)
    return
  }
  if (!/^```/.test(next)) {
    findings.push(`codeblock caption: line ${i + 1} cites \`${labelPath}\` but no code fence follows it`)
    return
  }
  const ref = url.slice(url.indexOf("/blob/") + 6, url.length - labelPath.length - 1)
  if (!/^[0-9a-f]{7,40}$/.test(ref)) {
    findings.push(`codeblock caption: line ${i + 1} pins \`${labelPath}\` to "${ref}" — a branch URL 404s once the branch is deleted, use a commit SHA (run tdd-codeblock-link.sh)`)
  }
})

if (findings.length === 0 && warns.length === 0) {
  console.log("STRUCTURE_OK headings=" + headings.length + " mermaid=" + mermaid.length + " glossary=" + glossTerms.length)
} else {
  findings.forEach(f => console.log("FINDING " + f))
  warns.forEach(w => console.log("WARN " + w))
  if (findings.length > 0) process.exit(1)
  console.log("STRUCTURE_OK_WITH_WARNINGS headings=" + headings.length + " mermaid=" + mermaid.length + " glossary=" + glossTerms.length)
}
' "$FILE"
RC=$?

# Glossary link placement is computed, not judged: this reports any term whose
# first use in a top-level section is unlinked. Fix by running the same script
# without --check, which inserts them.
RC3=0
"$HOME/.cursor/skills/tdd/scripts/tdd-glossary-link.sh" "$FILE" --check >/tmp/tdd-glossary-check.$$ 2>&1 || RC3=$?
if [ "$RC3" -eq 1 ]; then sed "s/^MISSING/FINDING glossary:/" /tmp/tdd-glossary-check.$$; fi
rm -f /tmp/tdd-glossary-check.$$
[ "$RC3" -eq 2 ] && RC3=0   # no glossary section: other checks already cover it

# Shared prose checks (em dashes, banned vocabulary, count-announcement
# openers) — see no-slop-lint.sh for tiers and the v2 semantic-judge note.
RC2=0
"$HOME/.cursor/skills/no-slop/scripts/no-slop-lint.sh" "$FILE" || RC2=$?
if [ "$RC" -ne 0 ] || [ "$RC2" -ne 0 ] || [ "$RC3" -ne 0 ]; then exit 1; fi
echo "LINT_OK"
exit 0
