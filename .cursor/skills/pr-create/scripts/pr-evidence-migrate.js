#!/usr/bin/env node
// Extracts legacy screenshot comments into a manifest plan. Pure parsing plus
// the mechanical attribution rule; no judgement about what a picture shows.
// argv: <commentsJson> <commitsJson> <destDir>  ->  {entries, commentIds}
const table = require(process.env.HOME + '/.cursor/skills/pr-create/scripts/pr-evidence-table.js')
const [commentsJson, commitsJson, destDir] = process.argv.slice(2)
const comments = JSON.parse(commentsJson)
const commits = JSON.parse(commitsJson)

// A fixup lands in its target at autosquash, so file frames under the target.
const targetSubject = s => {
  let out = String(s)
  while (/^(fixup!|squash!|amend!)\s+/.test(out)) out = out.replace(/^(fixup!|squash!|amend!)\s+/, '')
  return out
}
// Newest commit authored at or before the batch time.
const attribute = when => {
  const t = Date.parse(when)
  const prior = commits.filter(c => Date.parse(c.date) <= t)
  const pick = (prior.length ? prior : commits).slice().sort((a, b) => Date.parse(b.date) - Date.parse(a.date))[0]
  return pick ? targetSubject(pick.subject) : ''
}

const entries = []
const commentIds = []
for (const c of comments) {
  const body = String(c.body || '')
  if (!/raw\.githubusercontent\.com[^"')\s]+\.png/.test(body)) continue
  // The banner carries what was hacked; it is the only per-batch prose worth keeping.
  const hm = body.match(/Hack-forced evidence:\*\*\s*([^\n]+)/)
  const hackNote = hm ? hm[1].replace(/\s*Temporary uncommitted edit.*$/, '').replace(/\s+$/, '') : null
  const subject = attribute(c.created_at)
  // Caption: the bold line above the image, else the alt attribute, else the filename.
  const re = /(?:\*\*(.+?)\*\*\s*\n\s*\n\s*)?<img\s+src="(https:\/\/raw\.githubusercontent\.com[^"]+\.png)"[^>]*?(?:alt="([^"]*)")?[^>]*\/?>/g
  let m
  while ((m = re.exec(body)) !== null) {
    const [, bold, url, alt] = m
    const file = url.split('/').pop()
    const parsed = table.parseName(file)
    let caption = (bold || alt || parsed.caption || '').trim()
    caption = caption.replace(/^🪓\s*HACK-FORCED:\s*/i, '').trim() || parsed.caption
    entries.push({
      path: `${destDir}/${file}`,
      caption,
      hacked: parsed.hacked,
      phase: parsed.phase,
      subject,
      hackNote: parsed.hacked ? hackNote : null,
      migratedFrom: c.id
    })
  }
  commentIds.push(c.id)
}
// Keep every legacy frame: they predate the phase tokens, so identity falls
// back to the upload stamp rather than collapsing same-slug re-captures.
const seen = new Set()
const deduped = entries.filter(e => { const k = e.path; if (seen.has(k)) return false; seen.add(k); return true })
console.log(JSON.stringify({ entries: deduped, commentIds }))
