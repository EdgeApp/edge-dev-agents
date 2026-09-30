'use strict'
// lib/task-names.js — Asana task gid -> name, for titles in the orch lists.
// A transcript records only the task URL, never the name.
//
// Positive cache: $STATE_DIR/asana-task-names.tsv, gid \t name, FIRST row for
// a gid wins (a refresh writes fresh rows first; a single lookup appends a gid
// the file did not have). Refreshed from the agent project's task list (up to 8
// pages of 100, one retry per page) once it is older than 6 h.
// Negative cache: $STATE_DIR/asana-task-names-missing.tsv, gid \t epoch \t ttl.
// A per-gid GET that fails is not retried until its ttl passes: 6 h when Asana
// answered (deleted task, no access), 15 min when the request itself failed
// (timeout, network), so an outage does not hide a name for hours.
// Every failure path yields no name; callers fall back to transcript text.
//
//   load()              -> Map(gid -> name), cache only, sync
//   refreshIfStale()    -> async; re-pulls the project list when the cache is 6 h old
//   resolve(gids)       -> async Map for the given gids: cache, then per-gid GETs
//                          for the rest (skipping negatively cached gids)
//
// CLI: node lib/task-names.js <gid>...   ->  gid \t name per resolved gid
const fs = require('fs')
const os = require('os')

const HOME = os.homedir()
const AW = `${HOME}/.config/agent-watcher`
const ST = `${process.env.XDG_STATE_HOME || HOME + '/.local/state'}/agent-watcher`
const CACHE = `${ST}/asana-task-names.tsv`
const MISSING = `${ST}/asana-task-names-missing.tsv`
const CACHE_TTL_MS = 6 * 3600 * 1000
const MISS_TTL_S = 6 * 3600
const MISS_TTL_NET_S = 15 * 60
const TIMEOUT_MS = 10000

const jread = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')) } catch { return {} } }
const token = () => process.env.ASANA_TOKEN || jread(`${AW}/credentials.json`).asana_token || ''

function load () {
  const names = new Map()
  try {
    for (const line of fs.readFileSync(CACHE, 'utf8').split('\n')) {
      const [gid, name] = line.split('\t')
      if (gid && name && !names.has(gid)) names.set(gid, name)
    }
  } catch {}
  return names
}

function loadMissing () {
  const now = Date.now() / 1000
  const miss = new Map()
  try {
    for (const line of fs.readFileSync(MISSING, 'utf8').split('\n')) {
      const [gid, at, ttl] = line.split('\t')
      if (gid && now - Number(at) < Number(ttl || MISS_TTL_S)) miss.set(gid, line)
    }
  } catch {}
  return miss
}

async function getJson (url, tok) {
  const r = await fetch(url, { headers: { Authorization: `Bearer ${tok}` }, signal: AbortSignal.timeout(TIMEOUT_MS) })
  if (!r.ok) { const e = new Error(`HTTP ${r.status}`); e.answered = true; throw e }
  return r.json()
}

async function refreshIfStale () {
  let age = Infinity
  try { age = Date.now() - fs.statSync(CACHE).mtimeMs } catch {}
  if (age < CACHE_TTL_MS) return
  const tok = token()
  const proj = jread(`${AW}/asana-config.json`).project_gid
  if (!tok || !proj) return
  const fresh = []
  let url = `https://app.asana.com/api/1.0/projects/${proj}/tasks?opt_fields=name&limit=100`
  for (let page = 0; url && page < 8; page++) {
    let j = null
    for (let attempt = 0; attempt < 2 && !j; attempt++) { try { j = await getJson(url, tok) } catch {} }
    if (!j) break
    for (const t of j.data || []) if (t.gid && t.name) fresh.push(`${t.gid}\t${t.name.replace(/[\t\n]/g, ' ')}`)
    url = j.next_page?.offset ? `https://app.asana.com/api/1.0/projects/${proj}/tasks?opt_fields=name&limit=100&offset=${j.next_page.offset}` : null
  }
  if (!fresh.length) return
  let old = ''
  try { old = fs.readFileSync(CACHE, 'utf8') } catch {}
  const seen = new Set()
  const rows = [...fresh, ...old.split('\n')].filter(l => {
    const [gid, name] = l.split('\t')
    if (!gid || !name || seen.has(gid)) return false
    seen.add(gid); return true
  })
  try {
    fs.mkdirSync(ST, { recursive: true })
    const tmp = `${CACHE}.${process.pid}.tmp`
    fs.writeFileSync(tmp, rows.join('\n') + '\n')
    fs.renameSync(tmp, CACHE)
  } catch {}
}

async function resolve (gids) {
  const names = load()
  const out = new Map()
  const todo = []
  const miss = loadMissing()
  for (const g of new Set(gids)) {
    if (!g) continue
    if (names.has(g)) out.set(g, names.get(g))
    else if (!miss.has(g)) todo.push(g)
  }
  const tok = todo.length ? token() : ''
  if (!tok) return out
  const found = []
  const failed = []
  const now = Math.floor(Date.now() / 1000)
  const lookup = async (g) => {
    try {
      const nm = (await getJson(`https://app.asana.com/api/1.0/tasks/${g}?opt_fields=name`, tok)).data?.name
      if (nm) { out.set(g, nm); found.push(`${g}\t${nm.replace(/[\t\n]/g, ' ')}`) } else failed.push(`${g}\t${now}\t${MISS_TTL_S}`)
    } catch (e) { failed.push(`${g}\t${now}\t${e.answered ? MISS_TTL_S : MISS_TTL_NET_S}`) }
  }
  for (let i = 0; i < todo.length; i += 5) await Promise.all(todo.slice(i, i + 5).map(lookup))
  try {
    fs.mkdirSync(ST, { recursive: true })
    if (found.length) fs.appendFileSync(CACHE, found.join('\n') + '\n')
    if (failed.length) fs.writeFileSync(MISSING, [...miss.values(), ...failed].join('\n') + '\n')
  } catch {}
  return out
}

module.exports = { load, refreshIfStale, resolve }

if (require.main === module) {
  (async () => {
    await refreshIfStale()
    for (const [g, n] of await resolve(process.argv.slice(2))) process.stdout.write(`${g}\t${n}\n`)
  })()
}
