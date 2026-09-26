'use strict'
// lib/fleet-model.js — the ONE model behind every orchestration view: the
// terminal TUI (orch-tui.js, Health and Sessions views), the Fleet artifact
// page (fleet-page.js) and `--dump`. Collectors only; no rendering, no
// process.exit, no stdin. Everything here is a read of local state (tmux, ps,
// launchd, log tails, slots/pool json, transcripts) plus one optional async
// Asana tally.
//
//   buildSessions()          {live, dead, cfg}   tmux fleet + resumable transcripts
//   collect()                the full local model (sessions, vitals, slots, pool,
//                            worktrees, activity, cfgAll, names)
//   collectAsana(cfgAll)     async {tally: Map, pending: [], err, at}
//   spawnVerdict(...)        the watcher's tick gate, first blocker named
//   dump()                   async: collect() + asana, JSON-safe (tally as entries)
//   nameOf(gid), fmtAgo(epoch), fmtDate(epoch), sh(cmd)
const { execSync } = require('child_process')
const fs = require('fs')
const os = require('os')

const HOME = os.homedir()
const AW = `${HOME}/.config/agent-watcher`
const ST = `${process.env.XDG_STATE_HOME || HOME + '/.local/state'}/agent-watcher`
const RESUME = `${AW}/resume-agent.sh`
const FORKS = `${ST}/chat-forks.jsonl`
const chatSpawns = require('./chat-spawns.js')

const sh = (cmd) => { try { return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }) } catch { return '' } }
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
  return NAMES
}
const nameOf = (gid) => NAMES.get(gid) || ''

// ─── sessions (formerly session-tui.js data gathering) ───────────────────────
function loadConfig () {
  try {
    const c = JSON.parse(fs.readFileSync(`${AW}/asana-config.json`, 'utf8'))
    return {
      anchors: c.watcher?.persistent_anchors || [],
      keepCompleted: c.watcher?.keep_completed_sessions ?? 3,
      // Shared idle-reap TTL (watcher.idle_reap_hours): one clock for chats,
      // ad-hoc names, AND retired sessions — mirrors the watchdog.
      reapMs: (c.watcher?.idle_reap_hours ?? 72) * 3600 * 1000
    }
  } catch { return { anchors: [], keepCompleted: 3, reapMs: 72 * 3600 * 1000 } }
}

function loadForks () {
  const bySlug = new Map(); const byChild = new Map()
  try {
    for (const line of fs.readFileSync(FORKS, 'utf8').split('\n')) {
      if (!line.trim()) continue
      try {
        const j = JSON.parse(line)
        if (j.slug) bySlug.set(j.slug, j)   // latest entry wins
        if (j.child) byChild.set(j.child, j)
      } catch {}
    }
  } catch {}
  return { bySlug, byChild }
}

// resume-agent --list --porcelain →
//   mtime \t uuid \t gid \t state \t rc \t fork_child \t fork_rc \t title
function loadTranscripts () {
  const rows = []
  const out = sh(`${RESUME} --list --porcelain 2>/dev/null`)
  for (const line of out.split('\n')) {
    if (!line.trim()) continue
    const [mtime, uuid, gid, state, rc, forkChild, forkRc, title] = line.split('\t')
    rows.push({ mtime: Number(mtime), uuid, gid, state, rc, forkChild, forkRc, title: title || '(untitled)' })
  }
  return rows
}

// RC "bridge up": the ONE shared check with session-watchdog.js (the actor;
// this is the view). Footer pill when visible, else the session record's
// bridge id (>= 2.1.268 can hide the pill while connected). lib/rc-state.js.
const { rcBridgeUp } = require('./rc-state.js')

function loadTmux () {
  const sessions = []
  // One ps pass → child map. NOT pgrep -P: macOS pgrep silently excludes the
  // caller's own ancestors, so a claude session inspecting itself (or --list
  // run inside a pane) would report its own claude as dead.
  const kids = new Map()
  for (const line of sh('ps -axww -o pid=,ppid=,command=').split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/)
    if (!m) continue
    if (!kids.has(m[2])) kids.set(m[2], [])
    kids.get(m[2]).push({ pid: m[1], cmd: m[3] })
  }
  // '|' delimiter, NOT \t: tmux 3.6+ sanitizes control chars in format output
  // to '_', which glued "_<activity>_<created>" onto every session name.
  const out = sh(`tmux list-sessions -F '#{session_name}|#{session_activity}|#{session_created}' 2>/dev/null`)
  for (const line of out.split('\n')) {
    if (!line.trim()) continue
    const [name, activity, created] = line.split('|')
    if (!/^(claude|done)-asana-/.test(name)) continue
    const pids = sh(`tmux list-panes -s -t '${name}' -F '#{pane_pid}' 2>/dev/null`).split('\n').filter(Boolean)
    let claudeArgs = ''
    let claudePid = ''
    for (const pid of pids) {
      for (const c of kids.get(pid.trim()) || []) {
        if (/(^|\/)claude( |$)/.test(c.cmd) || c.cmd.startsWith('claude ')) { claudeArgs = c.cmd; claudePid = c.pid; break }
      }
      if (claudeArgs) break
    }
    const rc = (claudeArgs.match(/--remote-control\s+(\S+)/) || [])[1] || ''
    const resumeUuid = (claudeArgs.match(/--resume\s+([0-9a-f-]{36})/) || [])[1] || ''
    // Bridge state is checked (pill, else session record) for EVERY live claude, not
    // just argv-named ones: RC can be armed app-side with no flag in argv.
    let rcUp = false
    if (claudeArgs) rcUp = rcBridgeUp(sh(`tmux capture-pane -p -t '${name}' 2>/dev/null`), claudePid)
    sessions.push({ name, activity: Number(activity) || 0, created: Number(created) || 0, claudeAlive: !!claudeArgs, rc, rcUp, resumeUuid })
  }
  return sessions
}

function classify (s, cfg) {
  let m
  if ((m = s.name.match(/^claude-asana-(\d{12,})$/))) return { kind: 'run', gid: m[1], state: s.claudeAlive ? 'running' : 'dead' }
  if ((m = s.name.match(/^done-asana-(\d{12,})$/))) return { kind: 'run', gid: m[1], state: s.claudeAlive ? 'retired' : 'dead' }
  if ((m = s.name.match(/^claude-asana-chat-(.+)$/))) return { kind: 'chat', slug: `chat-${m[1]}`, state: s.claudeAlive ? 'alive' : 'dead' }
  m = s.name.match(/^claude-asana-(.+)$/)
  const anchor = cfg.anchors.includes(m[1])
  return { kind: anchor ? 'anchor' : 'adhoc', slug: m[1], state: s.claudeAlive ? 'alive' : 'dead' }
}

// Every datetime the views render is PT, 12-hour ("8/11 4:17p").
function fmtDate (epoch) {
  if (!epoch) return '?'
  return new Date(epoch * 1000)
    .toLocaleString('en-US', { timeZone: 'America/Los_Angeles', month: 'numeric', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true })
    .replace(',', '').replace(' AM', 'a').replace(' PM', 'p')
}

function fmtAgo (epoch) {
  if (!epoch) return '?'
  const s = Math.max(0, Math.floor(Date.now() / 1000 - epoch))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h${Math.floor((s % 3600) / 60)}m`
  return `${Math.floor(s / 86400)}d${Math.floor((s % 86400) / 3600)}h`
}

// Resolve a transcript title: porcelain titles for orch runs read
// "/one-shot --yolo <asana url>" when the run never wrote its task name; the
// gid is in the url and the shared name cache usually has it.
function resolveTitle (title, gid) {
  const t = String(title || '')
  // The task gid is the LAST 12+ digit run in an Asana url (the first is the project).
  // A "/one-shot <url>" title names its own task in the url; that beats the
  // porcelain gid, which is whatever gid appeared first in the transcript head.
  const runs = (t.match(/app\.asana\.com\/\S*/) || [''])[0].match(/\d{12,}/g) || []
  const g = runs[runs.length - 1] || gid
  if (/^\/one-shot/.test(t) || /^task \d{12,}$/.test(t) || !t.trim()) {
    const n = g && nameOf(g)
    if (n) return `Asana: ${n}`
  }
  return t
}

function buildSessions () {
  const cfg = loadConfig()
  const forks = loadForks()
  const spawns = chatSpawns.load()
  const transcripts = loadTranscripts()
  const tmux = loadTmux()

  const newestByGid = new Map()
  for (const t of transcripts) if (t.gid && !newestByGid.has(t.gid)) newestByGid.set(t.gid, t)

  const live = tmux.map(s => {
    const c = classify(s, cfg)
    const row = { ...s, ...c, title: '', uuid: '', reap: '' }
    if (c.kind === 'run') {
      const t = newestByGid.get(c.gid)
      row.title = resolveTitle(t ? t.title : `task ${c.gid}`, c.gid)
      row.uuid = t ? t.uuid : ''
    } else {
      row.uuid = s.resumeUuid   // pane's argv uuid; for a fork the REAL transcript is the registry child
      // A prompt-spawned pane has no --resume; the spawn registry names its transcript,
      // which keeps a live spawn out of the resumable list below.
      if (!row.uuid) { const sp = spawns.byTmux.get(s.name); if (sp) row.uuid = sp.uuid }
      const reg = forks.bySlug.get(c.slug)
      if (reg) {
        row.uuid = reg.child && reg.child !== 'unknown' ? reg.child : row.uuid
        const parent = transcripts.find(t => t.uuid === reg.parent)
        row.title = parent
          ? `FORK: ${resolveTitle(parent.title, parent.gid).replace(/^Asana: /, '')}`
          : `FORK: ${String(reg.parent).slice(0, 8)}…`
      }
      if (!row.title) row.title = c.slug
    }
    // Reap exposure — shared TTL for every non-run class (chats, ad-hoc,
    // retired). Shown only inside the last 24h so the column stays quiet.
    if (c.kind === 'chat' || c.kind === 'adhoc' || c.state === 'retired') {
      const left = cfg.reapMs / 1000 - (Date.now() / 1000 - s.activity)
      row.reap = left <= 0 ? 'REAPABLE now' : `reap in ${fmtAgo(Date.now() / 1000 - left)}`
      if (left > 24 * 3600) row.reap = ''
    }
    return row
  })

  // Retired overflow: newest keepCompleted survive the watchdog's bound sweep.
  const retired = live.filter(r => r.state === 'retired').sort((a, b) => b.activity - a.activity)
  retired.forEach((r, i) => { if (i >= cfg.keepCompleted) r.reap = 'overflow (next sweep)' })

  live.sort((a, b) => b.activity - a.activity)

  const liveGids = new Set(live.filter(r => r.gid).map(r => r.gid))
  const liveUuids = new Set(live.map(r => r.uuid).filter(Boolean))
  const dead = transcripts
    .filter(t => (!t.gid || !liveGids.has(t.gid)) && !liveUuids.has(t.uuid))
    .slice(0, 50)
    .map(t => ({ kind: 'transcript', state: '', title: resolveTitle(t.title, t.gid), uuid: t.uuid, gid: t.gid, mtime: t.mtime, forkChild: t.forkChild, isForkOfLive: !!t.forkChild }))

  return { live, dead, cfg }
}

// ─── vitals (formerly orch-tui.js collectors) ────────────────────────────────
// Same "available RAM" formula as asana-watcher.js getFreeRamGb(): free +
// speculative + inactive pages.
function freeRamGb () {
  const out = sh('vm_stat')
  if (!out) return Infinity
  const pageSize = Number((out.match(/page size of (\d+) bytes/) || [])[1] || 16384)
  const pages = (label) => Number((out.match(new RegExp(`${label}:\\s+(\\d+)`)) || [])[1] || 0)
  return (pages('Pages free') + pages('Pages speculative') + pages('Pages inactive')) * pageSize / 1024 ** 3
}

function collectVitals (cfgAll) {
  const w = cfgAll.watcher || {}
  const loads = (() => { try { return os.loadavg() } catch { return [0, 0, 0] } })()
  const load = loads[0]
  const freeGb = freeRamGb()
  const maxLoad = Number(w.resource_guardrail?.max_load_avg ?? 12)
  const minFree = Number(w.resource_guardrail?.min_free_ram_gb ?? 8)
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
  const lastWatcher = sh('tail -40 /tmp/asana-watcher.out 2>/dev/null').split('\n').filter(Boolean)
  const gated = lastWatcher.slice().reverse().find(l => /skipped this tick|Spawning|Spawned|spawned|resumed prior session|nothing to spawn|no Pending|Active sessions/.test(l)) || ''
  const hogs = []
  for (const line of sh('ps -axo pcpu=,comm= -r 2>/dev/null').split('\n').slice(0, 8)) {
    const m = line.trim().match(/^([\d.]+)\s+(.+)$/)
    if (!m || Number(m[1]) < 20) continue
    let name = m[2]
    const sim = name.match(/CoreSimulator\/Devices\/([0-9A-F]{8})[^/]*\/.*\/([^/]+\.app)\//)
    if (sim) name = `${sim[2]}@${sim[1]}`
    else if (/CoreSimulator\/Profiles\/Runtimes/.test(name)) name = 'sim runtime'
    else name = name.split('/').pop()
    hogs.push(`${name} ${Math.round(Number(m[1]))}%`)
  }
  const mm = sh('tail -1 /tmp/memory-monitor.log 2>/dev/null').match(/level=(\w+)\s+avail=(\S+)/)
  const memLevel = mm ? { level: mm[1], avail: mm[2] } : null
  const rg = sh(`tail -1 '${ST}/runaway-guard.log' 2>/dev/null`).match(/total=(\d+)\s+\(cap=(\d+)\)/)
  const runaway = rg ? { total: Number(rg[1]), cap: Number(rg[2]) } : null
  const fsePid = sh('pgrep -x fseventsd').split('\n')[0]
  const fse = fsePid ? sh(`ps -p ${fsePid} -o pcpu=,rss=,etime=`).trim().split(/\s+/) : null
  const fseRestart = sh("grep '\\[fseventsd\\]' /tmp/session-watchdog.out 2>/dev/null | tail -1").match(/^\[([0-9T:.Z-]+)\].*→ restarted/)
  const fseventsd = fse ? { cpu: Number(fse[0]), rssGb: Number(fse[1]) / 1024 / 1024, etime: fse[2], lastRestart: fseRestart ? Date.parse(fseRestart[1]) : null } : null
  const holds = sh('ls /tmp/reanchor-hold* /tmp/agent-watcher-hold* 2>/dev/null').split('\n').filter(Boolean).map(h => h.replace('/tmp/', ''))
  return {
    load, loads, maxLoad, freeGb, minFree, hogs, memLevel, runaway, fseventsd, holds,
    cores: os.cpus().length,
    maxConcurrent: Number(process.env.AGENT_WATCHER_MAX_CONCURRENT || w.max_concurrent || 2),
    maxConcurrentNosim: Number(process.env.AGENT_WATCHER_MAX_CONCURRENT_NOSIM || w.max_concurrent_nosim || 3),
    watcherInterval: 120,
    watcherTickAge: tickAge('/tmp/asana-watcher.out', /Watcher tick/),
    watchdogTickAge: tickAge('/tmp/session-watchdog.out', /Watching \d+ session/),
    lastWatcherLine: gated.replace(/^\[[^\]]+\]\s*/, ''),
    lastWatcherAt: (gated.match(/^\[([0-9T:.Z-]+)\]/) || [])[1] || null,
    jobs
  }
}

function collectSlots (liveGids) {
  const slots = (jread(`${ST}/slots.json`, {}).slots || []).map(s => ({ ...s, title: nameOf(s.task_gid), live: liveGids.has(s.task_gid) }))
  const listening = new Set()
  for (const line of sh('lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null').split('\n')) {
    const m = line.match(/:(\d+)\s+\(LISTEN\)/)
    if (m) listening.add(Number(m[1]))
  }
  for (const s of slots) s.metroUp = listening.has(Number(s.metro_port))
  return slots
}

function collectPool (liveGids) {
  return (jread(`${ST}/pool.json`, {}).pool || []).map(p => ({ ...p, title: nameOf(p.task_gid), live: p.task_gid ? liveGids.has(p.task_gid) : false }))
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

// ─── Asana agent_status tally (async; callers cache) ─────────────────────────
async function collectAsana (cfgAll) {
  const proj = cfgAll.agent_project_gid || cfgAll.watcher?.project_gid || cfgAll.project_gid
  const token = jread(`${AW}/credentials.json`, {}).asana_token
  if (!proj || !token) return { tally: null, pending: [], err: !token ? 'no asana token' : 'no project gid in config', at: Date.now() }
  try {
    let url = `https://app.asana.com/api/1.0/projects/${proj}/tasks?opt_fields=name,completed,custom_fields.name,custom_fields.display_value&limit=100`
    const tally = new Map(); const pending = []; const names = {}
    for (let page = 0; page < 8 && url; page++) {
      const r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } })
      if (!r.ok) throw new Error(`HTTP ${r.status}`)
      const j = await r.json()
      for (const t of j.data || []) {
        if (t.gid && t.name) names[t.gid] = t.name   // gid → name for every task, completed included
        if (t.completed) continue
        const f = (t.custom_fields || []).find(f => /agent_status/i.test(f.name))
        const v = (f && f.display_value) || '(none)'
        tally.set(v, (tally.get(v) || 0) + 1)
        if (/pending|in progress|blocked/i.test(v)) pending.push({ name: t.name, status: v })
      }
      url = j.next_page ? j.next_page.uri : null
    }
    return { tally, pending, names, err: '', at: Date.now() }
  } catch (e) { return { tally: null, pending: [], names: {}, err: String(e.message || e), at: Date.now() } }
}

// The spawn verdict mirrors asana-watcher.js's tick order (the two caps, then
// the load/RAM guardrail, then the sim pool) and lists EVERY blocker, so a full
// cap is not hidden behind a load spike or vice versa. `runs` is {sim, nosim}:
// the load cap and the pool block sim spawns only, so a blocker on that side
// says so when no-sim spawns can still go.
function spawnVerdict (v, runs, freeSims, pending) {
  const r = typeof runs === 'number' ? { sim: runs, nosim: 0 } : runs
  const why = []
  const simWhy = []
  if (v.holds.length) why.push(`hold file ${v.holds[0]}`)
  if (v.freeGb < v.minFree) why.push(`free RAM ${v.freeGb.toFixed(0)}G < min ${v.minFree}G`)
  if (r.sim >= v.maxConcurrent) simWhy.push(`sim runs ${r.sim}/${v.maxConcurrent} (cap)`)
  if (v.load > v.maxLoad) simWhy.push(`load ${v.load.toFixed(1)} > max_load_avg ${v.maxLoad}`)
  if (freeSims === 0) simWhy.push('no free sim in pool')
  const nosimFull = r.nosim >= v.maxConcurrentNosim
  if (simWhy.length && nosimFull) why.push(...simWhy, `no-sim runs ${r.nosim}/${v.maxConcurrentNosim} (cap)`)
  else if (simWhy.length) why.push(`sim spawns held: ${simWhy.join(', ')}; no-sim spawns open (${r.nosim}/${v.maxConcurrentNosim})`)
  else if (nosimFull) why.push(`no-sim runs ${r.nosim}/${v.maxConcurrentNosim} (cap); sim spawns open (${r.sim}/${v.maxConcurrent})`)
  const blocked = why.some(w => !w.startsWith('sim spawns held') && !w.startsWith('no-sim runs'))
    || (simWhy.length > 0 && nosimFull)
  if (blocked) return { ok: false, why: why.join(' · '), reasons: why }
  if (why.length) return { ok: true, why: why.join(' · '), partial: true, reasons: why }
  if (pending === 0) return { ok: true, why: 'idle: no Pending task', idle: true }
  return { ok: true, why: `${pending} Pending task(s) will spawn on the next tick` }
}

function collect () {
  loadNames()
  const cfgAll = jread(`${AW}/asana-config.json`, {})
  const fleet = buildSessions()
  const liveGids = new Set(fleet.live.filter(r => r.gid).map(r => r.gid))
  return {
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

async function dump () {
  const m = collect()
  const asana = await collectAsana(m.cfgAll)
  retitle(m.fleet, asana.names)
  return { ...m, asana: { ...asana, tally: asana.tally ? [...asana.tally] : null } }
}

// Second-pass title resolution with names the Asana tally brought back (the
// local cache misses tasks that never spawned through the watcher's cache path).
function retitle (fleet, names) {
  if (!names) return fleet
  const fix = (r) => {
    const t = String(r.title || '')
    const runs = (t.match(/app\.asana\.com\/\S*/) || [''])[0].match(/\d{12,}/g) || []
    const tm = t.match(/^task (\d{12,})$/)
    const g = runs[runs.length - 1] || (tm && tm[1]) || r.gid
    if (g && names[g] && (/^\/one-shot/.test(t) || /^task \d{12,}$/.test(t))) r.title = `Asana: ${names[g]}`
    return r
  }
  fleet.live.forEach(fix); fleet.dead.forEach(fix)
  return fleet
}

module.exports = { retitle, buildSessions, buildModel: buildSessions, collect, collectAsana, dump, spawnVerdict, loadNames, nameOf, fmtAgo, fmtDate, sh, jread, AW, ST }
