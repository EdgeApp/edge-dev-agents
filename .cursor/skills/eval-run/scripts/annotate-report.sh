#!/usr/bin/env bash
# annotate-report.sh — make eval-report dimension mentions clickable.
#
# For each rubric dimension mentioned in the report (via rubric-drift.sh --map):
#   1. linkify mentions: `A14 review-response` (and stray bare `A14`) become
#      intra-document links to the glossary anchor
#   2. append a `## Dimension glossary` section: per mentioned dimension, its
#      name, the local rubric path:line (clickable in the Claude Code chat),
#      and a GitHub permalink pinned to the synced repo's current HEAD SHA
#      (clickable from Asana/gist/phone; the SHA pin keeps line anchors stable).
#
# Usage: annotate-report.sh <report.md> [<report2.md> ...]
# Idempotent: a report already carrying the glossary section is skipped.
# Exit: 0 = ok, 1 = error, 2 = usage.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: annotate-report.sh <report.md> [...]" >&2; exit 2; }

RD_MAP=$(~/.cursor/skills/rubric-drift.sh --map)
REPO="$HOME/git/edge-dev-agents"
SHA=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "")
ORIGIN=$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#git@github\.com:#https://github.com/#; s#\.git$##' || echo "")
export RD_MAP SHA ORIGIN

# Bash 3.2 cannot nest a heredoc inside "$(...)", so the node payload lives
# after the __NODE__ marker at the bottom of this file and is self-extracted.
NODE_CODE=$(sed -n '/^#__NODE__$/,$p' "$0" | tail -n +2)
exec node -e "$NODE_CODE" -- "$@"
#__NODE__
const fs = require('fs')
const os = require('os')
const path = require('path')

const map = JSON.parse(process.env.RD_MAP || '{}')
const sha = process.env.SHA || ''
const origin = process.env.ORIGIN || ''
const HOME = os.homedir()

let argv = process.argv.slice(1)
if (argv[0] === '--') argv = argv.slice(1)

const slug = (id, name) => (id + ' ' + name).toLowerCase().replace(/[^a-z0-9 -]/g, '').replace(/ /g, '-')

for (const report of argv) {
  if (!fs.existsSync(report)) { console.error(`SKIP ${report}: not found`); continue }
  let text = fs.readFileSync(report, 'utf8')
  if (text.includes('## Dimension glossary')) { console.log(`SKIP ${report}: already annotated`); continue }

  // which dimensions does this report mention?
  const mentioned = Object.keys(map).filter((id) => new RegExp('\\b' + id + '\\b').test(text))
  if (!mentioned.length) { console.log(`SKIP ${report}: no dimension mentions`); continue }

  for (const id of mentioned) {
    const { name } = map[id]
    const anchor = '#' + slug(id, name)
    // 1) full "A14 review-response" mentions not already inside a link
    text = text.replace(new RegExp('(?<![\\[#\\w-])' + id + ' ' + name + '\\b', 'g'), `[${id} ${name}](${anchor})`)
    // 2) stray bare codes (synthesis slip): not preceded by [, #, ( or word chars, not followed by the name
    text = text.replace(new RegExp('(?<![\\[#\\w-])' + id + '\\b(?! ' + name + ')(?!\\]|\\d)', 'g'), `[${id} ${name}](${anchor})`)
  }

  const entries = mentioned.sort().map((id) => {
    const { name, gate, file, line } = map[id]
    const local = `${file}:${line}`
    const repoRel = file.startsWith(HOME + '/.cursor') ? '.cursor' + file.slice((HOME + '/.cursor').length) : null
    const permalink = repoRel && sha && origin ? `${origin}/blob/${sha}/${repoRel}#L${line}` : null
    return `### ${id} ${name}\n` +
      (gate ? '- GATE dimension: a confirmed BAD hard-fails the run\n' : '') +
      `- Rubric row: ${local}\n` +
      (permalink ? `- [Rubric row on GitHub](${permalink})\n` : '')
  })
  text = text.replace(/\n*$/, '\n\n## Dimension glossary\n\n' + entries.join('\n') + '\n')

  fs.writeFileSync(report, text)
  console.log(`ANNOTATED ${report}: ${mentioned.length} dimension(s) linked, glossary appended`)
}
