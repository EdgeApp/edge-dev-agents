#!/usr/bin/env node
// orch-tui.js — read-only orchestration dashboard: one screen showing the
// whole orch state. NO controls (by design); keys are q quit, r refresh only.
// Launch: `orch-tui` alias, or run this file.
//
// Panels:
//   VITALS    load vs guardrail max (red = spawns gated), free RAM vs min,
//             active/max_concurrent, watcher + watchdog last-tick age, launchd
//             job health (asana-watcher, session-watchdog, config-watch,
//             memory-monitor, runaway-guard; config-watch exit 1 = CONFIG
//             DRIFT), Asana agent_status tally for the agent project
//   SESSIONS  the session-tui.js live model (same code, required as a lib)
//   SLOTS     slots.json ⨯ live sessions (stale slot = gid with no session)
//   SIM POOL  pool.json entries ⨯ liveness
//   WORKTREES ~/git/.agent-worktrees/<gid> ⨯ liveness
//   ACTIVITY  merged interesting tail of watcher + watchdog logs
//
// Refresh: local state every 10s; Asana tally every 60s; `r` forces both.
// Titles come from the shared asana-task-names.tsv cache (resume-agent's) —
// no per-refresh Asana calls for names.
'use strict'
const fs = require('fs')
const os = require('os')
const HOME = os.homedir()
const AW = `${HOME}/.config/agent-watcher`
const ST = `${process.env.XDG_STATE_HOME || HOME + '/.local/state'}/agent-watcher`
const { buildModel, fmtAgo, sh } = require(`${AW}/session-tui.js`)

const ESC = '\x1b['
const C = { inv: `${ESC}7m`, dim: `${ESC}2m`, bold: `${ESC}1m`, red: `${ESC}31m`, grn: `${ESC}32m`, yel: `${ESC}33m`, cyn: `${ESC}36m`, off: `${ESC}0m` }
const strip = (s) => s.replace(/\x1b\[[0-9;]*m/g, '')
const pad = (s, w) => { const l = strip(s).length; return l >= w ? strip(s).slice(0, w - 1) + '…' : s + ' '.repeat(w - l) }
const jread = (p, fb) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')) } catch { return fb } }

// ─── task-name cache (shared with resume-agent) ──────────────────────────────
let NAMES = new Map()
function loadNames () {
  NAMES = new Map()
  try {
    for (const line of fs.readFileSync(`${ST}/asana-task-names.tsv`, 'utf8').split('\n')) {
      const [gid, name] = line.split('\t')
      if (gid && name && !NAMES.has(gid)) NAMES.set(gid, name)
    }
  } catch {}
}
const nameOf = (gid) => NAMES.get(gid) || ''

// ─── collectors ──────────────────────────────────────────────────────────────
// Same "available RAM" formula as asana-watcher.js getFreeRamGb(): free +
// speculative + inactive pages. os.freemem() on macOS reports only truly-free
// pages (near zero on a busy box) and would false-alarm the RAM gauge.
function freeRamGb () {
  const out = sh('vm_stat')
  if (!out) return Infinity
  const pageSize = Number((out.match(/page size of (\d+) bytes/) || [])[1] || 16384)
  const pages = (label) => Number((out.match(new RegExp(`${label}:\\s+(\\d+)`)) || [])[1] || 0)
  return (pages('Pages free') + pages('Pages speculative') + pages('Pages inactive')) * pageSize / 1024 ** 3
}

function collectVitals (cfgAll) {
  const w = cfgAll.watcher || {}
  const load = (() => { try { return os.loadavg()[0] } catch { return 0 } })()
  const freeGb = freeRamGb()
  const maxLoad = Number(w.resource_guardrail?.max_load_avg ?? 12)
  const minFree = Number(w.resource_guardrail?.min_free_ram_gb ?? 8)
  // launchd job health: pid (running now) + last exit status per com.jontz job.
  const jobs = []
  for (const line of sh('launchctl list 2>/dev/null').split('\n')) {
    const m = line.match(/^(\S+)\s+(-?\d+)\s+(com\.jontz\.\S+)/)
    if (m) jobs.push({ name: m[3].replace('com.jontz.', ''), pid: m[1] === '-' ? null : m[1], rc: Number(m[2]) })
  }
  const tickAge = (logPath, re) => {
    const t = sh(`tail -40 '${logPath}' 2>/dev/null`).split('\n').reverse().find(l => re.test(l))
    const ts = t && t.match(/^\[([0-9T:.Z-]+)\]/)
    return ts ? (Date.now() - Date.parse(ts[1])) / 1000 : null
  }
  const lastWatcher = sh("tail -40 /tmp/asana-watcher.out 2>/dev/null").split('\n').filter(Boolean)
  const gated = lastWatcher.slice().reverse().find(l => /skipped this tick|Spawning|Spawned|nothing to spawn|Active sessions/.test(l)) || ''
  return {
    load, maxLoad, freeGb, minFree,
    maxConcurrent: Number(process.env.AGENT_WATCHER_MAX_CONCURRENT || w.max_concurrent || 2),
    watcherTickAge: tickAge('/tmp/asana-watcher.out', /Watcher tick/),
    watchdogTickAge: tickAge('/tmp/session-watchdog.out', /Watching \d+ session/),
    lastWatcherLine: gated.replace(/^\[[^\]]+\]\s*/, ''),
    jobs
  }
}

function collectSlots (liveGids) {
  const slots = (jread(`${ST}/slots.json`, {}).slots || []).map(s => ({
    ...s,
    title: nameOf(s.task_gid),
    live: liveGids.has(s.task_gid)
  }))
  // Metro LISTEN check in one lsof pass.
  const listening = new Set()
  for (const line of sh('lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null').split('\n')) {
    const m = line.match(/:(\d+)\s+\(LISTEN\)/)
    if (m) listening.add(Number(m[1]))
  }
  for (const s of slots) s.metroUp = listening.has(Number(s.metro_port))
  return slots
}

function collectPool (liveGids) {
  return (jread(`${ST}/pool.json`, {}).pool || []).map(p => ({
    ...p,
    title: nameOf(p.task_gid),
    live: p.task_gid ? liveGids.has(p.task_gid) : false
  }))
}

function collectWorktrees (liveGids) {
  const root = `${HOME}/git/.agent-worktrees`
  const out = []
  try {
    for (const gid of fs.readdirSync(root)) {
      if (!/^\d{12,}$/.test(gid)) continue
      const st = fs.statSync(`${root}/${gid}`)
      out.push({ gid, title: nameOf(gid), live: liveGids.has(gid), mtime: st.mtimeMs / 1000 })
    }
  } catch {}
  return out.sort((a, b) => b.mtime - a.mtime)
}

const INTERESTING = /Spawn|spawn|Retired|retire|reap|killed|revive|Revive|guardrail|Blocked|blocked|ERROR|WARN|prune|Prune|drift/
function collectActivity () {
  const rows = []
  for (const [src, p] of [['watcher', '/tmp/asana-watcher.out'], ['watchdog', '/tmp/session-watchdog.out']]) {
    for (const line of sh(`tail -80 '${p}' 2>/dev/null`).split('\n')) {
      const m = line.match(/^\[([0-9T:.Z-]+)\]\s*(.*)$/)
      if (m && INTERESTING.test(m[2])) rows.push({ ts: Date.parse(m[1]), src, msg: m[2] })
    }
  }
  return rows.sort((a, b) => b.ts - a.ts).slice(0, 10)
}

// ─── Asana agent_status tally (async, 60s cache) ─────────────────────────────
let ASANA = { tally: null, pending: [], err: '', at: 0 }
async function refreshAsana (cfgAll) {
  const proj = cfgAll.agent_project_gid || cfgAll.watcher?.project_gid || cfgAll.project_gid
  const token = jread(`${AW}/credentials.json`, {}).asana_token
  if (!proj || !token) { ASANA.err = !token ? 'no asana token' : 'no project gid in config'; return }
  try {
    let url = `https://app.asana.com/api/1.0/projects/${proj}/tasks?opt_fields=name,completed,custom_fields.name,custom_fields.display_value&limit=100`
    const tally = new Map(); const pending = []
    for (let page = 0; page < 8 && url; page++) {
      const r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } })
      if (!r.ok) throw new Error(`HTTP ${r.status}`)
      const j = await r.json()
      for (const t of j.data || []) {
        if (t.completed) continue
        const f = (t.custom_fields || []).find(f => /agent_status/i.test(f.name))
        const v = (f && f.display_value) || '(none)'
        tally.set(v, (tally.get(v) || 0) + 1)
        if (/pending|in progress|blocked/i.test(v)) pending.push({ name: t.name, status: v })
      }
      url = j.next_page ? j.next_page.uri : null
    }
    ASANA = { tally, pending, err: '', at: Date.now() }
  } catch (e) { ASANA.err = String(e.message || e); ASANA.at = Date.now() }
}

// ─── model + render ──────────────────────────────────────────────────────────
let M = null
function collect () {
  loadNames()
  const cfgAll = jread(`${AW}/asana-config.json`, {})
  const fleet = buildModel()
  const liveGids = new Set(fleet.live.filter(r => r.gid).map(r => r.gid))
  M = {
    at: Date.now(),
    vitals: collectVitals(cfgAll),
    fleet,
    slots: collectSlots(liveGids),
    pool: collectPool(liveGids),
    worktrees: collectWorktrees(liveGids),
    activity: collectActivity(),
    cfgAll
  }
}

function vline (v) {
  const loadBad = v.load > v.maxLoad
  const ramBad = v.freeGb < v.minFree
  const seg = []
  seg.push(`${loadBad ? C.red : C.grn}load ${v.load.toFixed(1)}/${v.maxLoad}${loadBad ? ' SPAWNS GATED' : ''}${C.off}`)
  seg.push(`${ramBad ? C.red : C.grn}ram ${v.freeGb.toFixed(0)}G free (min ${v.minFree})${C.off}`)
  seg.push(`cap ${v.maxConcurrent}`)
  seg.push(`watcher tick ${v.watcherTickAge == null ? `${C.red}?${C.off}` : fmtAgo(Date.now() / 1000 - v.watcherTickAge) + ' ago'}`)
  seg.push(`watchdog ${v.watchdogTickAge == null ? `${C.red}?${C.off}` : fmtAgo(Date.now() / 1000 - v.watchdogTickAge) + ' ago'}`)
  return seg.join('   ')
}

function jobsLine (jobs) {
  return jobs.map(j => {
    let col = C.grn; let note = ''
    if (j.name === 'config-watch' && j.rc === 1) { col = C.red; note = ':DRIFT' } else if (j.rc !== 0) { col = C.yel; note = `:rc${j.rc}` }
    return `${col}${j.name}${note}${C.off}`
  }).join('  ')
}

function render () {
  if (!M) return
  const cols = process.stdout.columns || 140
  const rows = process.stdout.rows || 45
  const L = []
  const v = M.vitals
  L.push(`${C.bold} ORCH ${C.off} ${C.dim}${new Date(M.at).toLocaleTimeString()}${C.off}  ${vline(v)}`)
  L.push(`   jobs: ${jobsLine(v.jobs)}   ${C.dim}${v.lastWatcherLine.slice(0, cols - 40)}${C.off}`)

  // Asana tally
  let asanaSeg = `${C.dim}asana loading…${C.off}`
  if (ASANA.err) asanaSeg = `${C.yel}asana: ${ASANA.err}${C.off}`
  else if (ASANA.tally) {
    asanaSeg = [...ASANA.tally.entries()].sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k}=${n}`).join('  ')
  }
  L.push(`   agent_status (open tasks): ${asanaSeg}`)
  L.push('')

  const titleW = Math.min(52, cols - 60)
  L.push(`${C.bold} SESSIONS${C.off}  ${C.dim}● running ◐ retired ✗ dead ⚓ anchor ◦ chat — ${M.fleet.dead.length} resumable transcripts not shown${C.off}`)
  for (const r of M.fleet.live) {
    const sym = r.kind === 'run' ? (r.state === 'running' ? `${C.grn}●${C.off}` : r.state === 'retired' ? `${C.yel}◐${C.off}` : `${C.red}✗${C.off}`)
      : r.state === 'dead' ? `${C.red}✗${C.off}` : r.kind === 'anchor' ? `${C.cyn}⚓${C.off}` : `${C.grn}◦${C.off}`
    const rc = !r.claudeAlive ? `${C.red}claude dead${C.off}` : r.rc ? (r.rcUp ? `${C.grn}rc:${r.rc}${C.off}` : `${C.yel}rc:${r.rc}↓${C.off}`) : `${C.dim}no rc${C.off}`
    const reap = r.reap ? `  ${C.red}${r.reap}${C.off}` : ''
    L.push(`  ${sym} ${pad(r.kind === 'run' ? r.state : r.kind, 8)}${pad(r.title.replace(/^Asana: /, ''), titleW)} ${pad(rc, 22)}idle ${fmtAgo(r.activity)}${reap}`)
  }
  L.push('')

  L.push(`${C.bold} SLOTS${C.off}`)
  if (!M.slots.length) L.push(`  ${C.dim}(none allocated)${C.off}`)
  for (const s of M.slots) {
    const flag = s.live ? `${C.grn}live${C.off}` : `${C.red}STALE (no session)${C.off}`
    const metro = s.metroUp ? `${C.grn}metro:${s.metro_port}${C.off}` : `${C.dim}metro:${s.metro_port} down${C.off}`
    L.push(`  ${s.slot_index}  ${pad(s.title || s.task_gid, titleW)} ${pad(metro, 20)}sim ${String(s.sim_udid).slice(0, 8)}  ${pad(`up ${fmtAgo(Date.parse(s.spawned_at) / 1000)}`, 11)}${flag}`)
  }
  L.push('')

  L.push(`${C.bold} SIM POOL${C.off}`)
  if (!M.pool.length) L.push(`  ${C.dim}(empty)${C.off}`)
  for (const p of M.pool) {
    const who = p.task_gid ? (p.title || p.task_gid) : ''
    const flag = p.state === 'in_use' ? (p.live ? `${C.grn}in_use${C.off}` : `${C.red}in_use but no session${C.off}`) : `${C.dim}${p.state}${C.off}`
    L.push(`  ${p.slot ?? '-'}  ${String(p.udid).slice(0, 8)}  ${pad(flag, 24)}${pad(who, titleW)}`)
  }
  L.push('')

  L.push(`${C.bold} WORKTREES${C.off} ${C.dim}(${M.worktrees.length} on disk)${C.off}`)
  for (const w of M.worktrees.slice(0, 6)) {
    L.push(`  ${pad(w.title || w.gid, titleW)} ${w.live ? `${C.grn}live${C.off}` : `${C.dim}idle${C.off}`}  ${C.dim}touched ${fmtAgo(w.mtime)} ago${C.off}`)
  }
  L.push('')

  L.push(`${C.bold} ACTIVITY${C.off} ${C.dim}(watcher + watchdog, interesting lines)${C.off}`)
  for (const a of M.activity) {
    const t = new Date(a.ts); const hh = `${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}`
    L.push(`  ${C.dim}${hh} ${pad(a.src, 9)}${C.off}${a.msg.slice(0, cols - 16)}`)
  }

  let out = `${ESC}H${ESC}2J` + L.slice(0, rows - 2).join('\n')
  out += `${ESC}${rows};1H${C.dim} q quit · r refresh (local 10s / asana 60s auto)${C.off}`
  process.stdout.write(out)
}

// ─── main ────────────────────────────────────────────────────────────────────
if (process.argv.includes('--dump')) {
  collect()
  refreshAsana(M.cfgAll).then(() => {
    console.log(JSON.stringify({ ...M, asana: { ...ASANA, tally: ASANA.tally && [...ASANA.tally] } }, null, 2))
    process.exit(0)
  })
} else {
if (!process.stdin.isTTY) { console.error('orch-tui: needs a TTY (run from a terminal)'); process.exit(1) }

process.stdout.write(`${ESC}?1049h${ESC}?25l`)
process.stdin.setRawMode(true)
process.stdin.resume()
process.on('exit', () => process.stdout.write(`${ESC}?1049l${ESC}?25h`))
process.on('SIGINT', () => process.exit(0))
process.stdout.on('resize', render)

collect(); render()
refreshAsana(M.cfgAll).then(render)
setInterval(() => { collect(); render() }, 10000)
setInterval(() => { refreshAsana(M.cfgAll).then(render) }, 60000)

process.stdin.on('data', (b) => {
  const k = b.toString()
  if (k === 'q' || k === '\x03') process.exit(0)
  if (k === 'r') { collect(); render(); refreshAsana(M.cfgAll).then(render) }
})
}
