#!/usr/bin/env node
// pr-evidence-table.js — the evidence table's data model and renderer.
//
// Owns what pr-attach-screenshots.sh needs and bash cannot do cleanly: merging
// new frames into the per-PR manifest, deciding which capture batches survive,
// rendering the batch-grouped table, and splicing it into a PR body between
// sentinels.
//
// WHY BATCHES rather than commits: a frame evidences a BUILD, not a commit
// message. The old model grouped on the commit SUBJECT so that an autosquashed
// fixup kept its frames, which is exactly why it could not see a force-push —
// the subject is unchanged when the tree under it is rewritten, so frames shot
// against the old tree stayed filed under the new sha and went on asserting
// pixels that no longer existed. A batch is one attach invocation at one head
// sha, which is a fact no rebase can rewrite.
//
// THE KEEP PREDICATE is the whole retention model:
//
//   keep a batch iff it is the LATEST, or a human acted on the PR during its
//   REIGN (between its own capture and the next batch's capture)
//
// On a PR nobody has reviewed, nothing but the latest batch survives, so the
// table is the current build and nothing else. Once a human has looked, every
// batch they could have been looking at is frozen and new work appends a row.
// The reason is change VISIBILITY, not history: a reviewer who already scrolled
// past a thumbnail will never notice that it changed, but they will notice a new
// row. Consecutive batches with no human action between them collapse to the
// latest for free, so three fixes pushed between two reviews do not leave three
// rows of states nobody saw.
//
// Pruning happens at ATTACH time and is written into the manifest, never at
// render time. The predicate reads live review timestamps, so re-evaluating it
// later would resurrect a pruned batch the moment a reviewer arrived, showing
// them a state they never saw. Deciding once, as the new batch lands, is what
// makes the table stable; render is a pure function of the manifest.
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

// Entries written before batches existed carry no batchAt. They are one
// synthetic oldest batch rather than a special case threaded through every
// function, so the predicate retires them on the next attach like any other.
const LEGACY = '(earlier)'

// Sentinel pair for any agent-owned block in a PR body. Shared so the evidence
// table and the mirrored TDD overview splice the same way and cannot diverge.
const marks = name => [`<!-- agent-${name}:start -->`, `<!-- agent-${name}:end -->`]

const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

// Filename → { caption, index, hacked, phase }. Strips the transport prefix
// (<stamp>-agent-proof-<gid>-<NN>-) and the uppercase marker tokens.
//
// The INDEX is kept rather than discarded: reports and PR prose reference frames
// by their capture number ("screenshot 2"), and without it in the cell that
// number is visible only by hovering the image URL. A stripped run of digits is
// an index only when it is short — a task gid is 16 digits and is never one.
function parseName (file) {
  let s = String(file).replace(/\.[a-z0-9]+$/i, '')
  s = s.replace(/^\d{8}-\d{6}-/, '')
  s = s.replace(/^agent[-_]?proof[-_]/i, '')
  let index = null
  for (let i = 0; i < 2; i++) {
    const m = s.match(/^(\d+)[-_]/)
    if (!m) break
    if (m[1].length <= 3) index = String(Number(m[1]))
    s = s.slice(m[0].length)
  }
  const hacked = /(^|-)HACKED(-|$)/.test(s)
  const before = /(^|-)BEFORE(-|$)/.test(s)
  const after = /(^|-)AFTER(-|$)/.test(s)
  s = s.replace(/(^|-)(HACKED|BEFORE|AFTER)(?=-|$)/g, '')
  const caption = s.replace(/[-_]+/g, ' ').trim()
  return { caption, index, hacked, phase: before ? 'before' : after ? 'after' : null }
}

function captionOf (e) {
  const p = e.phase === 'before' ? ' (before fix)' : e.phase === 'after' ? ' (after fix)' : ''
  return `${e.caption}${p}`
}

const baseOf = entry => String((entry && entry.path) || entry).split('/').pop()
const deStamp = file => baseOf(file).replace(/^\d{8}-\d{6}-/, '')

// Identity of a frame WITHIN a batch, independent of which upload it came from.
// Upload paths carry a timestamp, so keying on the path would file a re-attached
// frame as a second copy; keying on the de-stamped basename makes a re-run
// idempotent. The phase is part of the key, which is what keeps a BEFORE/AFTER
// pair of the same scene as two distinct frames rather than one overwriting the
// other.
function frameKey (entry) {
  const phase = (typeof entry === 'object' && entry && entry.phase) || ''
  return phase + '|' + deStamp(entry)
}

// Replacement is scoped to the batch: a retained batch is what a reviewer
// already saw, so a same-named frame in a NEW batch appends a row instead of
// silently rewriting the old one.
const batchOf = e => (e && e.batchAt) || LEGACY
const batchFrameKey = e => batchOf(e) + '::' + frameKey(e)

// The name a disposition flag uses: the human-readable scene, with the NN index
// and transport prefix gone, so `--carry-forward empty-state` reads the way the
// caption does. The phase is part of it, which keeps a BEFORE/AFTER pair
// separately addressable.
function sceneId (entry) {
  const meta = (entry && entry.caption != null) ? entry : parseName(baseOf(entry))
  const slug = String(meta.caption || '').trim().toLowerCase().replace(/\s+/g, '-')
  const phase = (entry && entry.phase) || meta.phase
  return phase ? `${slug}:${phase}` : slug
}

// Resolve a disposition token against a set of entries. The scene slug is what
// the refusal prints; the full de-stamped basename is accepted as a fallback for
// the case where two scenes share a caption.
function resolveScenes (entries, token) {
  const t = String(token).trim().toLowerCase()
  const byScene = entries.filter(e => sceneId(e) === t)
  if (byScene.length) return byScene
  return entries.filter(e => deStamp(e).replace(/\.[a-z0-9]+$/i, '').toLowerCase() === t)
}

// Group entries into capture batches, oldest first. A batch carries the head sha
// the build was captured at, which is what the row header states.
function batchesOf (manifest) {
  const entries = (manifest && manifest.entries) || []
  const index = new Map()
  const out = []
  for (const e of entries) {
    const key = batchOf(e)
    if (!index.has(key)) {
      const b = { key, batchAt: e.batchAt || null, headSha: e.headSha || null, entries: [] }
      index.set(key, b); out.push(b)
    }
    index.get(key).entries.push(e)
  }
  out.sort((a, b) => timeOf(a) - timeOf(b))
  return out
}

const timeOf = b => (b && b.batchAt) ? Date.parse(b.batchAt) : 0

// THE KEEP PREDICATE. humanActions is a list of ISO timestamps (UTC) of
// non-bot, non-author activity on the PR; pr-attach-screenshots.sh builds it.
// Returns the pruned manifest plus the batches it dropped, so the caller can
// report what it retired.
function pruneBatches (manifest, humanActions) {
  const batches = batchesOf(manifest)
  const acts = (humanActions || []).map(t => Date.parse(t)).filter(n => !Number.isNaN(n))
  const keep = new Set()
  batches.forEach((b, i) => {
    if (i === batches.length - 1) { keep.add(b.key); return }
    const from = timeOf(b)
    const to = timeOf(batches[i + 1])
    if (acts.some(t => t >= from && t < to)) keep.add(b.key)
  })
  const entries = ((manifest && manifest.entries) || []).filter(e => keep.has(batchOf(e)))
  return { manifest: { version: 2, entries }, dropped: batches.filter(b => !keep.has(b.key)) }
}

// Which batches a NEW batch landing at newBatchAt would retire. The disposition
// gate calls this BEFORE uploading anything, so a refusal costs no blobs.
function wouldRetire (manifest, humanActions, newBatchAt) {
  const existing = ((manifest && manifest.entries) || [])
  const probe = { version: 2, entries: [...existing, { path: 'probe.png', batchAt: newBatchAt }] }
  return pruneBatches(probe, humanActions).dropped
}

// Append entries, replacing any existing frame of the same identity in the SAME
// batch so a later capture of that frame supersedes the earlier one in place.
function mergeManifest (manifest, entries) {
  const out = Array.isArray(manifest && manifest.entries) ? manifest.entries.slice() : []
  for (const e of entries) {
    const k = batchFrameKey(e)
    const at = out.findIndex(x => batchFrameKey(x) === k)
    // Carry a hosted url across a re-merge. A migrate re-run rebuilds entries
    // from the PR comments and knows nothing about object storage, so a blind
    // replace would silently revert a re-hosted PR to its long raw URLs and
    // could push it back over the body cap.
    if (at >= 0) out[at] = (e.url == null && out[at].url != null) ? { ...e, url: out[at].url } : e
    else out.push(e)
  }
  return { version: 2, entries: out }
}

// commits: [{sha, subject}] from the PR, newest last. A batch sha still present
// in that list links to its commit; one that a force-push orphaned renders as
// plain text, because the link would 404 once GitHub collects it.
function render (manifest, { repo, pr, rawBase, commits }) {
  const subjects = new Map((commits || []).map(c => [c.sha, c.subject]))
  const out = ['<table>']
  for (const b of batchesOf(manifest)) {
    const rows = []
    for (let i = 0; i < b.entries.length; i += PER_ROW) rows.push(b.entries.slice(i, i + PER_ROW))
    // The hack note is rebuilt from the frames that SURVIVED, so a row can never
    // caption a hack that no remaining frame used.
    const notes = [...new Set(b.entries.filter(e => e.hacked && e.hackNote).map(e => e.hackNote))]
    const subject = subjects.get(b.headSha) || (b.entries.find(e => e.subject) || {}).subject || ''
    rows.forEach((row, ri) => {
      out.push('<tr>')
      if (ri === 0) {
        const sha = b.headSha
        const label = sha
          ? (subjects.has(sha)
              ? `<a href="https://github.com/${repo}/pull/${pr}/commits/${sha}"><code>${sha.slice(0, 7)}</code></a>`
              : `<code>${sha.slice(0, 7)}</code>`)
          : `<code>${LEGACY}</code>`
        const subj = subject ? `<br><sub>${esc(subject)}</sub>` : ''
        const when = b.batchAt ? `<br><sub>${esc(b.batchAt.slice(0, 10))}</sub>` : ''
        const note = notes.length ? `<br><sub>🪓 <em>${esc(notes.join('; '))}</em></sub>` : ''
        out.push(`<td rowspan="${rows.length}" width="${HDR_W}" valign="top">${label}${subj}${when}${note}</td>`)
      }
      for (let c = 0; c < PER_ROW; c++) {
        const e = row[c]
        if (e == null) { out.push(`<td width="${CELL_W}"></td>`); continue }
        // An entry may carry its own absolute url (object storage, where the
        // key has its own random suffix and cannot be derived from a base).
        // Otherwise the path is resolved against the assets-branch raw base.
        const url = e.url || (rawBase + e.path.split('/').pop())
        // The capture number leads the caption so prose that says "screenshot 2"
        // resolves by reading, not by hovering the image URL. Position within
        // the batch is the fallback for a frame whose filename carried no index.
        const n = e.index != null ? e.index : (parseName(baseOf(e)).index || String(ri * PER_ROW + c + 1))
        out.push(`<td width="${CELL_W}" valign="top" align="center"><a href="${url}"><img src="${url}" width="${IMG_W}"></a><br><sub><b>${esc(n)}.</b> ${e.hacked ? '🪓 ' : ''}${esc(captionOf(e))}</sub></td>`)
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

module.exports = {
  parseName, frameKey, sceneId, resolveScenes, batchesOf, pruneBatches, wouldRetire,
  mergeManifest, render, splice, replaceSection, removeSection, moveSectionFirst,
  marks, START, END, LEGACY
}
