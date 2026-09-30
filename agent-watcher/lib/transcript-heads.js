'use strict'
// lib/transcript-heads.js — the head facts of a claude transcript, cached.
//
// A transcript's head is write-once: the first 50 lines never change after the
// 50th newline lands, and the first 64 KB never change once the file is that
// long. Everything the orch lists need from a transcript comes from that head:
//
//   sig      1 iff the first 50 lines carry a /one-shot or /task-run --yolo
//            prompt (RUN_SIGNATURE_RE, read from lib/run-signature.sh so bash
//            and node share one pattern)
//   gid      the task gid: the LAST 12+ digit run of the URL in the run's own
//            /one-shot or /task-run --yolo prompt (first 50 lines); without
//            one, of the first app.asana.com URL within the first 50 lines or
//            64 KB (whichever is longer) that carries a 12+ digit run and is
//            not a /profile/ (user) link
//   preview  the "/one-shot --yolo <url>" prompt text, the title fallback when
//            the task name cannot be resolved
//
// Cache: $STATE_DIR/transcript-heads.json, {path: {v, ino, size, mtimeMs, final,
// sig, gid, preview}}. A final entry (both windows complete) is reused while
// the file keeps its inode and does not shrink; any other entry is reused only
// while inode, size and mtime are unchanged. So a scan reads new or growing
// short files only.
//
//   headFacts(paths) -> Map(path -> {path, mtime, sig, gid, preview})
//                       (missing files are left out; saves the cache when it grew)
//
// CLI: node lib/transcript-heads.js <file>...
//   one TSV row per readable file: path \t mtime \t sig \t gid \t preview,
//   "-" for an empty field (tab is IFS whitespace, so an empty field would
//   collapse on `IFS=$'\t' read` and shift the columns).
const fs = require('fs')
const os = require('os')
const path = require('path')

const HOME = os.homedir()
const ST = `${process.env.XDG_STATE_HOME || HOME + '/.local/state'}/agent-watcher`
const CACHE = `${ST}/transcript-heads.json`
const HEAD_LINES = 50
const GID_WINDOW = 65536

const RUN_SIGNATURE_RE = (() => {
  const src = fs.readFileSync(path.join(__dirname, 'run-signature.sh'), 'utf8')
  const m = src.match(/^RUN_SIGNATURE_RE='(.*)'$/m)
  if (!m) throw new Error('RUN_SIGNATURE_RE not found in lib/run-signature.sh')
  return new RegExp(m[1])
})()
const PREVIEW_LINE_RE = /"\/(one-shot|task-run) --yolo/
const PREVIEW_RE = /"(\/(?:one-shot|task-run) --yolo [^"]{0,80})[^"]*"/g
// The task URL the run was launched with, in either recorded prompt form.
const PROMPT_URL_RE = /(?:"\/(?:one-shot|task-run) --yolo|<command-args>--yolo)\s+(https?:\/\/app\.asana\.com[A-Za-z0-9/._-]*)/
// Bump when derive() changes; entries stamped with another version are recomputed.
const FACTS_VERSION = 3

// Read until both windows are covered (HEAD_LINES newlines and GID_WINDOW
// bytes) or EOF.
function readHead (p, size) {
  const fd = fs.openSync(p, 'r')
  try {
    const chunks = []
    let pos = 0
    let lines = 0
    let lineEnd = -1
    const buf = Buffer.alloc(1 << 20)
    while (pos < size && (lines < HEAD_LINES || pos < GID_WINDOW)) {
      const n = fs.readSync(fd, buf, 0, buf.length, pos)
      if (n <= 0) break
      const chunk = Buffer.from(buf.subarray(0, n))
      for (let i = 0; i < n && lines < HEAD_LINES; i++) {
        if (chunk[i] === 10 && ++lines === HEAD_LINES) lineEnd = pos + i
      }
      chunks.push(chunk)
      pos += n
    }
    const all = Buffer.concat(chunks)
    const headEnd = lineEnd >= 0 ? lineEnd : all.length
    // The URL fallback scans the longer of the two windows, which contains the other.
    const scanEnd = Math.max(headEnd, Math.min(GID_WINDOW, all.length))
    return { head: all.subarray(0, headEnd).toString('utf8'), prefix: all.subarray(0, scanEnd).toString('latin1'), complete: lines >= HEAD_LINES }
  } finally { fs.closeSync(fd) }
}

function derive (head, prefix) {
  const sig = RUN_SIGNATURE_RE.test(head) ? 1 : 0
  // The run prompt's own URL first: injected session-start context (Asana
  // comments) can put @-mention profile URLs, whose id is a USER gid, ahead of
  // it. Otherwise the first non-profile URL carrying a gid.
  const url = (head.match(PROMPT_URL_RE) || [])[1] ||
    (prefix.match(/app\.asana\.com[A-Za-z0-9/._-]*/g) || []).find(u => /[0-9]{12,}/.test(u) && !/\/profile\//.test(u)) || ''
  const gid = (url.match(/[0-9]{12,}/g) || []).pop() || ''
  let preview = ''
  const line = head.split('\n').find(l => PREVIEW_LINE_RE.test(l))
  if (line) {
    const ms = [...line.matchAll(PREVIEW_RE)]
    preview = (ms.length ? ms[ms.length - 1][1] : line).slice(0, 100)
  }
  return { sig, gid, preview }
}

function loadCache () {
  try { return JSON.parse(fs.readFileSync(CACHE, 'utf8')) } catch { return {} }
}

function saveCache (cache) {
  for (const p of Object.keys(cache)) if (!fs.existsSync(p)) delete cache[p]
  try {
    fs.mkdirSync(ST, { recursive: true })
    const tmp = `${CACHE}.${process.pid}.tmp`
    fs.writeFileSync(tmp, JSON.stringify(cache))
    fs.renameSync(tmp, CACHE)
  } catch { /* a lost write only costs a re-read next scan */ }
}

function headFacts (paths) {
  const cache = loadCache()
  let dirty = false
  const out = new Map()
  for (const p of paths) {
    let st
    try { st = fs.statSync(p) } catch { continue }
    const c = cache[p]
    const valid = c && c.v === FACTS_VERSION && c.ino === st.ino && (c.final ? st.size >= c.size : c.size === st.size && c.mtimeMs === st.mtimeMs)
    let facts
    if (valid) facts = c
    else {
      let h
      try { h = readHead(p, st.size) } catch { continue }
      facts = derive(h.head, h.prefix)
      cache[p] = { v: FACTS_VERSION, ino: st.ino, size: st.size, mtimeMs: st.mtimeMs, final: h.complete && st.size >= GID_WINDOW, ...facts }
      dirty = true
    }
    out.set(p, { path: p, mtime: Math.floor(st.mtimeMs / 1000), sig: facts.sig, gid: facts.gid, preview: facts.preview })
  }
  if (dirty) saveCache(cache)
  return out
}

module.exports = { headFacts, RUN_SIGNATURE_RE }

if (require.main === module) {
  const dash = (v) => (v === '' || v == null ? '-' : String(v).replace(/[\t\n]/g, ' '))
  for (const f of headFacts(process.argv.slice(2)).values()) {
    process.stdout.write([f.path, f.mtime, f.sig, dash(f.gid), dash(f.preview)].join('\t') + '\n')
  }
}
