#!/usr/bin/env node
// pr-evidence-table.js — the evidence table's data model and renderer.
//
// Owns three things pr-attach-screenshots.sh needs and bash cannot do cleanly:
// merging new frames into the per-PR manifest, rendering the commit-grouped
// table, and splicing that table into a PR body between sentinels.
//
// WHY the manifest keys a group on the commit SUBJECT rather than its sha:
// this workflow rebases and autosquashes, so a recorded sha stops resolving the
// moment a fixup folds in. The subject survives that (a fixup targets its
// commit BY subject), so the subject is the stable identity and the sha is
// re-resolved from the PR's live commit list at every render.
//
// FILENAME MARKERS are UPPERCASE tokens, which is what separates a marker from
// prose: HACKED = the frame was forced by a temporary edit; BEFORE = the frame
// shows behavior prior to the fix; AFTER = explicitly the post-fix frame
// (optional; untokened frames are current-HEAD evidence). A lowercase word in
// the slug is description and carries no meaning, so "slider-before-slide"
// reads as a gesture, never as a pre-fix frame.

const PER_ROW = 3, IMG_W = 200, CELL_W = 210, HDR_W = 170
const START = '<!-- agent-test-evidence:start -->'
const END = '<!-- agent-test-evidence:end -->'
const HEADING = '### Test evidence'

// Sentinel pair for any agent-owned block in a PR body. Shared so the evidence
// table and the mirrored TDD overview splice the same way and cannot diverge.
const marks = name => [`<!-- agent-${name}:start -->`, `<!-- agent-${name}:end -->`]

const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

// Filename → { caption, hacked, phase }. Strips the transport prefix
// (<stamp>-agent-proof-<gid>-<NN>-) and the uppercase marker tokens.
function parseName (file) {
  let s = String(file).replace(/\.[a-z0-9]+$/i, '')
  s = s.replace(/^\d{8}-\d{6}-/, '')
  s = s.replace(/^agent[-_]?proof[-_]/i, '').replace(/^\d+[-_]/, '').replace(/^\d+[-_]/, '')
  const hacked = /(^|-)HACKED(-|$)/.test(s)
  const before = /(^|-)BEFORE(-|$)/.test(s)
  const after = /(^|-)AFTER(-|$)/.test(s)
  s = s.replace(/(^|-)(HACKED|BEFORE|AFTER)(?=-|$)/g, '')
  const caption = s.replace(/[-_]+/g, ' ').trim()
  return { caption, hacked, phase: before ? 'before' : after ? 'after' : null }
}

function captionOf (e) {
  const p = e.phase === 'before' ? ' (before fix)' : e.phase === 'after' ? ' (after fix)' : ''
  return `${e.caption}${p}`
}

// Identity of a frame, independent of which upload it came from. Upload paths
// carry a timestamp, so keying on the path would file a re-attached frame as a
// second copy; keying on the de-stamped basename makes a re-run idempotent.
// The phase is part of the key, which is what keeps a BEFORE/AFTER pair of the
// same scene as two distinct frames rather than one overwriting the other. A
// frame with no phase and no marker is plain current-HEAD evidence, so a later
// capture of it supersedes the earlier one, which is the intended behavior.
function frameKey (entry) {
  const path = typeof entry === 'string' ? entry : entry.path
  const phase = (typeof entry === 'object' && entry && entry.phase) || ''
  return phase + '|' + String(path).split('/').pop().replace(/^\d{8}-\d{6}-/, '')
}

// Append entries, replacing any existing frame of the same identity so a later
// capture of that frame supersedes the earlier one in place.
function mergeManifest (manifest, entries) {
  const out = Array.isArray(manifest && manifest.entries) ? manifest.entries.slice() : []
  for (const e of entries) {
    const k = frameKey(e)
    const at = out.findIndex(x => frameKey(x) === k)
    // Carry a hosted url across a re-merge. A migrate re-run rebuilds entries
    // from the PR comments and knows nothing about object storage, so a blind
    // replace would silently revert a re-hosted PR to its long raw URLs and
    // could push it back over the body cap.
    if (at >= 0) out[at] = (e.url == null && out[at].url != null) ? { ...e, url: out[at].url } : e
    else out.push(e)
  }
  return { version: 1, entries: out }
}

// commits: [{sha, subject}] from the PR, newest last. Groups render in PR
// commit order; a group whose subject no longer exists keeps its recorded sha.
function render (manifest, { repo, pr, rawBase, commits }) {
  const bySubject = new Map((commits || []).map(c => [c.subject, c.sha]))
  const groups = []
  const index = new Map()
  for (const e of manifest.entries) {
    const key = e.subject || e.sha || 'unattributed'
    if (!index.has(key)) {
      const g = { key, subject: e.subject, sha: bySubject.get(e.subject) || e.sha, hackNote: null, imgs: [] }
      index.set(key, g); groups.push(g)
    }
    const g = index.get(key)
    if (e.hacked && e.hackNote && !g.hackNote) g.hackNote = e.hackNote
    g.imgs.push(e)
  }
  const order = (commits || []).map(c => c.subject)
  groups.sort((a, b) => {
    const ia = order.indexOf(a.subject), ib = order.indexOf(b.subject)
    return (ia < 0 ? 1e9 : ia) - (ib < 0 ? 1e9 : ib)
  })

  const out = ['<table>']
  for (const g of groups) {
    const rows = []
    for (let i = 0; i < g.imgs.length; i += PER_ROW) rows.push(g.imgs.slice(i, i + PER_ROW))
    rows.forEach((row, ri) => {
      out.push('<tr>')
      if (ri === 0) {
        const link = g.sha
          ? `<a href="https://github.com/${repo}/pull/${pr}/commits/${g.sha}"><code>${g.sha.slice(0, 7)}</code></a>`
          : '<code>(unattributed)</code>'
        const note = g.hackNote ? `<br><sub>🪓 <em>${esc(g.hackNote)}</em></sub>` : ''
        out.push(`<td rowspan="${rows.length}" width="${HDR_W}" valign="top">${link}<br><sub>${esc(g.subject || '')}</sub>${note}</td>`)
      }
      for (let c = 0; c < PER_ROW; c++) {
        const e = row[c]
        if (e == null) { out.push(`<td width="${CELL_W}"></td>`); continue }
        // An entry may carry its own absolute url (object storage, where the
        // key has its own random suffix and cannot be derived from a base).
        // Otherwise the path is resolved against the assets-branch raw base.
        const url = e.url || (rawBase + e.path.split('/').pop())
        out.push(`<td width="${CELL_W}" valign="top" align="center"><a href="${url}"><img src="${url}" width="${IMG_W}"></a><br><sub>${e.hacked ? '🪓 ' : ''}${esc(captionOf(e))}</sub></td>`)
      }
      out.push('</tr>')
    })
  }
  out.push('</table>')
  return out.join('\n')
}

// Replace between sentinels, or append the section when absent. Never touches
// anything outside the sentinels, so a human-edited body survives a re-render.
//
// The ANCHOR is the sentinel comment pair and nothing else. The heading is
// regenerated INSIDE the block, so it is display text: renaming it, or a human
// writing the words "Test evidence" elsewhere in the body, cannot move or
// duplicate the block. Half a pair means a hand-edit truncated the block;
// appending a second one there would silently leave two tables, so it throws.
function splice (body, table, opts) {
  const { name = 'test-evidence', heading = HEADING } = opts || {}
  const [START, END] = marks(name)
  const block = heading
    ? `${START}\n${heading}\n\n${table}\n${END}`
    : `${START}\n${table}\n${END}`
  const b = String(body || '')
  const i = b.indexOf(START), j = b.indexOf(END)
  if (i >= 0 && j > i) return b.slice(0, i) + block + b.slice(j + END.length)
  if ((i >= 0) !== (j >= 0)) {
    throw new Error(`PR body has a broken evidence block: found ${i >= 0 ? START : END} without its pair. Repair or remove it, then re-run.`)
  }
  return b.replace(/\s*$/, '') + '\n\n' + block + '\n'
}


// Replace the ENTIRE body of a `### <heading>` section with `content`, leaving
// every other section untouched. The evidence table appends its own section;
// the description instead OWNS one the template already provides, so a sync
// has to clear whatever prose is sitting there rather than add a second copy.
// When the section is absent it is inserted before the first existing heading,
// which is where the template now puts Description.
function replaceSection (body, heading, content) {
  const b = String(body || '')
  const h = `### ${heading}`
  const lines = b.split('\n')
  const at = lines.findIndex(l => l.trim() === h)
  if (at < 0) {
    const first = lines.findIndex(l => /^###\s+/.test(l))
    const block = [h, '', content, '']
    if (first < 0) return b.replace(/\s*$/, '') + '\n\n' + block.join('\n')
    return [...lines.slice(0, first), ...block, ...lines.slice(first)].join('\n')
  }
  let end = lines.length
  for (let i = at + 1; i < lines.length; i++) if (/^###\s+/.test(lines[i])) { end = i; break }
  return [...lines.slice(0, at), h, '', content, '', ...lines.slice(end)].join('\n')
}


// Cut a whole `### <heading>` section out of a body. The TDD stopped being its
// own section once the description carries the link, so a synced body drops the
// old one rather than showing the doc twice.
function removeSection (body, heading) {
  const lines = String(body || '').split('\n')
  const at = lines.findIndex(l => l.trim() === `### ${heading}`)
  if (at < 0) return String(body || '')
  let end = lines.length
  for (let i = at + 1; i < lines.length; i++) if (/^###\s+/.test(lines[i])) { end = i; break }
  return [...lines.slice(0, at), ...lines.slice(end)].join('\n').replace(/\n{3,}/g, '\n\n')
}

// Hoist a section to the top of the body. New PRs get the order from the repo
// template; a PR opened before that change still has Description wherever it
// was appended, so a sync moves it rather than leaving the reader to scroll.
function moveSectionFirst (body, heading) {
  const b = String(body || '')
  const lines = b.split('\n')
  const at = lines.findIndex(l => l.trim() === `### ${heading}`)
  if (at <= 0) return b
  let end = lines.length
  for (let i = at + 1; i < lines.length; i++) if (/^###\s+/.test(lines[i])) { end = i; break }
  const section = lines.slice(at, end)
  while (section.length && section[section.length - 1].trim() === '') section.pop()
  const rest = [...lines.slice(0, at), ...lines.slice(end)]
  while (rest.length && rest[0].trim() === '') rest.shift()
  return [...section, '', ...rest].join('\n').replace(/\n{3,}/g, '\n\n')
}

module.exports = { parseName, frameKey, mergeManifest, render, splice, replaceSection, removeSection, moveSectionFirst, marks, START, END }
