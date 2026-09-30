#!/usr/bin/env node
// orch-tui.js — the orchestration TUI: one process, two views on Tab.
//   HEALTH    answers "why is nothing spawning?": the watcher's spawn verdict
//             with the first blocker named; load with the processes pinning
//             it; RAM plus memory-monitor level; capacity (runs/slots/sims/
//             pending); guards (fseventsd, runaway count, hold files); launchd
//             job health (config-watch exit 1 = CONFIG DRIFT); the watcher's
//             last tick line; Asana agent_status tally. Then SLOTS ⨯ liveness,
//             SIM POOL, WORKTREES, and the merged ACTIVITY tail. Read-only;
//             a one-line session census points at the Sessions view.
//   SESSIONS  the fleet list with actions (attach, chat-fork, in-place resume,
//             revive, kill, content search) — session-tui.js as a view.
// Both views render lib/fleet-model.js, the same model the Fleet artifact page
// uses, so the terminal and the phone never disagree.
//
// Launch: `orch-tui` (Health first) or `agent-tui` / `resume-agent --tui` /
// `session-tui.js` (Sessions first). Keys: Tab switch view, r refresh, q quit;
// Health scrolls its ACTIVITY log (↑↓/j k, PgUp/PgDn, g newest, G oldest) and
// jumps to a time with t (14:30, 2:30p, 45m, 2h); plus the Sessions view's keys. Local model refreshes every 10s on a
// worker thread (lib/collect-worker.js), so keys never wait on a refresh; the
// Asana tally every 60s (never while a Sessions prompt is open).
// `--once` prints one Health frame (no TTY). `--dump` prints the full model
// as JSON, Asana tally included. `--view sessions` opens on Sessions.
'use strict'
const os = require('os')
const AW = `${os.homedir()}/.config/agent-watcher`
const M0 = require(`${AW}/lib/fleet-model.js`)
const { collect, collectAsana, spawnVerdict, fmtAgo, retitle } = M0
const { createSessionsView } = require(`${AW}/session-tui.js`)
const { paint, invalidate } = require(`${AW}/lib/frame.js`)
const { Worker } = require('worker_threads')

const ESC = '\x1b['
const C = { inv: `${ESC}7m`, dim: `${ESC}2m`, bold: `${ESC}1m`, red: `${ESC}31m`, grn: `${ESC}32m`, yel: `${ESC}33m`, mag: `${ESC}35m`, cyn: `${ESC}36m`, off: `${ESC}0m` }
const strip = (s) => s.replace(/\x1b\[[0-9;]*m/g, '')
const pad = (s, w) => { const l = strip(s).length; return l >= w ? strip(s).slice(0, w - 1) + '…' : s + ' '.repeat(w - l) }

let M = null
let ASANA = { tally: null, pending: [], err: '', at: 0 }

// ─── activity log: color, scroll, jump to a time ─────────────────────────────
// M.activity is newest first. actAnchor pins the top visible row by timestamp
// (null = follow the newest), so a refresh that adds rows does not move a view
// the operator scrolled back to. actInput is the open time prompt (null = closed).
let actAnchor = null
let actInput = null
let actStatus = ''
let actPage = 10

function actTime (ts) {
  const t = new Date(ts)
  const p = (n) => String(n).padStart(2, '0')
  const hm = `${p(t.getHours())}:${p(t.getMinutes())}`
  return t.toDateString() === new Date().toDateString() ? hm : `${t.getMonth() + 1}/${t.getDate()} ${hm}`
}

// Failures red, watchdog revives magenta, routine cleanup cyan (checked before
// "killed" so killing a retired session's JVM reads as cleanup), holds and
// warnings yellow, spawns green.
function actColor (msg) {
  if (/\bERROR\b|failed|\bFAIL|crash|\bOOM\b|runaway|died/.test(msg)) return C.red
  if (/[Rr]evive/.test(msg)) return C.mag
  if (/Retired|retire|reap|[Pp]rune|teardown/.test(msg)) return C.cyn
  if (/killed/.test(msg)) return C.red
  if (/WARN|deferred|held|guardrail|[Bb]locked|drift|skipped/.test(msg)) return C.yel
  if (/[Ss]pawn|resumed/.test(msg)) return C.grn
  return ''
}

function actOffset () {
  if (actAnchor == null || !M) return 0
  const i = M.activity.findIndex(a => a.ts <= actAnchor)
  return i < 0 ? Math.max(0, M.activity.length - actPage) : i
}

function actSetOffset (off) {
  const max = Math.max(0, M.activity.length - actPage)
  const o = Math.min(max, Math.max(0, off))
  actAnchor = o === 0 ? null : M.activity[o].ts
}

// "14:30" / "2:30p" (local, the latest past occurrence) or "45m" / "2h" ago.
function actJump (q) {
  if (!M || !M.activity.length) return
  let target
  let m
  if ((m = q.match(/^(\d+)\s*([mh])$/i))) {
    target = Date.now() - Number(m[1]) * (m[2].toLowerCase() === 'h' ? 3600e3 : 60e3)
  } else if ((m = q.match(/^(\d{1,2}):?(\d{2})\s*([ap])?m?$/i))) {
    let h = Number(m[1])
    if (m[3]) h = (h % 12) + (m[3].toLowerCase() === 'p' ? 12 : 0)
    const d = new Date()
    d.setHours(h, Number(m[2]), 0, 0)
    if (d.getTime() > Date.now()) d.setDate(d.getDate() - 1)
    target = d.getTime()
  } else {
    actStatus = `can't read "${q}": use 14:30, 2:30p, 45m or 2h`
    return
  }
  const i = M.activity.findIndex(a => a.ts <= target)
  if (i < 0) {
    actSetOffset(Infinity)
    actStatus = `the log goes back to ${actTime(M.activity[M.activity.length - 1].ts)}; showing the oldest lines`
    return
  }
  actSetOffset(i)
  actStatus = `jumped to ${actTime(M.activity[i].ts)}`
}

function jobsLine (jobs) {
  return jobs.map(j => {
    let col = C.grn; let note = ''
    if (j.name === 'config-watch' && j.rc === 1) { col = C.red; note = ' DRIFT' } else if (j.rc !== 0) { col = C.yel; note = ` rc${j.rc}` }
    return `${col}${j.name}${note}${C.off}`
  }).join('  ')
}

function healthPanel (v, cols) {
  const running = M.fleet.live.filter(r => r.kind === 'run' && r.state === 'running')
  const simGids = new Set(M.slots.filter(s => s.sim_udid).map(s => s.task_gid))
  const runs = { sim: running.filter(r => simGids.has(r.gid)).length, nosim: running.filter(r => !simGids.has(r.gid)).length }
  const freeSlots = Math.max(0, v.maxConcurrent - M.slots.length)
  const freeSims = M.pool.filter(p => p.state === 'free').length
  const pendingTasks = (ASANA.pending || []).filter(p => /^pending$/i.test(p.status))
  const verdict = spawnVerdict(v, runs, freeSims, ASANA.tally ? pendingTasks.length : 0)
  const row = (label, body) => `  ${C.dim}${pad(label, 10)}${C.off}${body}`
  const L = []
  const nextTick = v.watcherTickAge == null ? '?' : `${Math.max(0, Math.round(v.watcherInterval - v.watcherTickAge))}s`
  const spawn = verdict.ok
    ? (verdict.idle ? `${C.grn}● OPEN${C.off}  ${C.dim}${verdict.why}${C.off}` : `${C.grn}● OPEN${C.off}  ${verdict.why}`)
    : `${C.red}✗ GATED${C.off}  ${C.red}${verdict.why}${C.off}`
  L.push(row('spawn', `${spawn}   ${C.dim}next watcher tick in ${nextTick}${C.off}`))
  const lc = (x) => (x > v.maxLoad ? C.red : x > v.maxLoad * 0.75 ? C.yel : C.grn) + x.toFixed(1) + C.off
  const hogs = v.hogs.length ? `${C.dim}pinned by${C.off} ${v.hogs.slice(0, 4).join(', ')}` : ''
  L.push(row('load', `1m ${lc(v.loads[0])}  5m ${lc(v.loads[1])}  15m ${lc(v.loads[2])}  ${C.dim}max ${v.maxLoad} (${v.cores} cores)${C.off}   ${hogs}`))
  const ramCol = v.freeGb < v.minFree ? C.red : C.grn
  const mm = v.memLevel ? `   ${C.dim}memory-monitor${C.off} ${v.memLevel.level === 'green' ? C.grn : v.memLevel.level === 'warn' ? C.yel : C.red}${v.memLevel.level}${C.off} ${C.dim}(avail ${v.memLevel.avail})${C.off}` : ''
  L.push(row('ram', `${ramCol}${v.freeGb.toFixed(0)}G free${C.off}  ${C.dim}min ${v.minFree}G${C.off}${mm}`))
  const pendNames = pendingTasks.slice(0, 3).map(p => p.name.replace(/^Asana: /, '').slice(0, 28)).join(', ')
  const pendSeg = ASANA.tally ? `pending ${pendingTasks.length}${pendNames ? ` ${C.dim}(${pendNames}${pendingTasks.length > 3 ? ', …' : ''})${C.off}` : ''}` : `${C.dim}pending ?${C.off}`
  L.push(row('capacity', `runs sim ${runs.sim}/${v.maxConcurrent} nosim ${runs.nosim}/${v.maxConcurrentNosim}   slots ${freeSlots} free   sims ${freeSims}/${M.pool.length} free   ${pendSeg}`))
  const fse = v.fseventsd
    ? `fseventsd ${(f => (f.cpu >= 100 ? C.red : f.cpu >= 50 ? C.yel : C.grn) + f.cpu.toFixed(0) + '%' + C.off)(v.fseventsd)} ${v.fseventsd.rssGb.toFixed(1)}G up ${v.fseventsd.etime}${v.fseventsd.lastRestart ? `${C.dim}, guard restarted ${fmtAgo(v.fseventsd.lastRestart / 1000)} ago${C.off}` : ''}`
    : `${C.dim}fseventsd ?${C.off}`
  const rg = v.runaway ? `   runaway ${v.runaway.total >= v.runaway.cap * 0.8 ? C.yel : C.grn}${v.runaway.total}/${v.runaway.cap}${C.off} agent procs` : ''
  const holds = v.holds.length ? `   ${C.red}holds: ${v.holds.join(' ')}${C.off}` : `   ${C.dim}holds: none${C.off}`
  L.push(row('guards', `${fse}${rg}${holds}`))
  L.push(row('jobs', `${jobsLine(v.jobs)}   ${C.dim}watcher tick ${v.watcherTickAge == null ? '?' : fmtAgo(Date.now() / 1000 - v.watcherTickAge) + ' ago'} · watchdog ${v.watchdogTickAge == null ? '?' : fmtAgo(Date.now() / 1000 - v.watchdogTickAge) + ' ago'}${C.off}`))
  const lw = v.lastWatcherLine ? `${/skipped|deferred|held/.test(v.lastWatcherLine) ? C.yel : C.dim}${v.lastWatcherLine.slice(0, cols - 14)}${C.off}` : `${C.dim}(no watcher line)${C.off}`
  L.push(row('watcher', lw))
  let asanaSeg = `${C.dim}loading…${C.off}`
  if (ASANA.err) asanaSeg = `${C.yel}${ASANA.err}${C.off}`
  else if (ASANA.tally) asanaSeg = [...ASANA.tally.entries()].sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k}=${n}`).join('  ') + `   ${C.dim}(open tasks, ${fmtAgo(ASANA.at / 1000)} ago)${C.off}`
  L.push(row('asana', asanaSeg))
  return L
}

function census () {
  const live = M.fleet.live
  const n = (f) => live.filter(f).length
  const parts = [
    `${C.grn}${n(r => r.kind === 'run' && r.state === 'running')} running${C.off}`,
    `${n(r => r.state === 'retired')} retired`,
    `${n(r => r.kind === 'chat' && r.state !== 'dead')} chats`,
    `${n(r => r.kind === 'anchor' && r.state !== 'dead')} anchors`
  ]
  const dead = n(r => r.state === 'dead')
  if (dead) parts.push(`${C.red}${dead} dead${C.off}`)
  parts.push(`${M.fleet.dead.length} resumable transcripts`)
  return parts.join('  ·  ')
}

function renderHealth () {
  if (!M) { paint([`${C.bold} ORCH HEALTH${C.off} ${C.dim}loading…${C.off}`]); return }
  const cols = process.stdout.columns || 140
  const rows = process.stdout.rows || 45
  const v = M.vitals
  const titleW = Math.min(52, cols - 60)
  const L = []
  L.push(`${C.bold} ORCH HEALTH${C.off} ${C.dim}${new Date(M.at).toLocaleTimeString()}${C.off}`)
  L.push(...healthPanel(v, cols))
  L.push('')
  L.push(`${C.bold} SESSIONS${C.off}  ${census()}   ${C.dim}(Tab for the list and actions)${C.off}`)
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
  // The activity window takes whatever rows remain above the footer.
  actPage = Math.max(1, rows - 2 - L.length - 1)
  const off = actOffset()
  const shown = M.activity.slice(off, off + actPage)
  const pos = off === 0
    ? `${C.dim}(watcher + watchdog, newest first, live)${C.off}`
    : `${C.yel}paused at ${actTime(M.activity[off].ts)}${C.off} ${C.dim}(lines ${off + 1}-${off + shown.length} of ${M.activity.length}; g returns to live)${C.off}`
  L.push(`${C.bold} ACTIVITY${C.off} ${pos}`)
  for (const a of shown) {
    const col = actColor(a.msg)
    L.push(`  ${C.dim}${pad(actTime(a.ts), 11)}${pad(a.src, 9)}${C.off}${col}${a.msg.slice(0, cols - 23)}${col ? C.off : ''}`)
  }
  const frame = L.slice(0, rows - 2)
  frame[rows - 1] = actInput !== null
    ? `${C.cyn} jump to time (14:30, 2:30p, 45m, 2h; Enter go, Esc cancel): ${actInput}▌${C.off}`
    : actStatus
      ? `${C.yel} ${actStatus}${C.off}`
      : `${C.dim} Tab sessions · ↑↓ PgUp PgDn scroll activity · g newest · G oldest · t jump to time · r refresh · q quit${C.off}`
  paint(frame)
}

// ─── entry points ────────────────────────────────────────────────────────────
if (process.argv.includes('--once')) {
  M = collect()
  collectAsana(M.cfgAll).then(a => {
    ASANA = a
    const cols = process.stdout.columns || 140
    console.log([`${C.bold} ORCH HEALTH${C.off} ${C.dim}${new Date(M.at).toLocaleTimeString()}${C.off}`, ...healthPanel(M.vitals, cols), '', `${C.bold} SESSIONS${C.off}  ${census()}`].join('\n'))
    process.exit(0)
  })
} else if (process.argv.includes('--dump')) {
  M0.dump().then(d => { console.log(JSON.stringify(d, null, 2)); process.exit(0) })
} else {
  if (!process.stdin.isTTY) { console.error('orch-tui: needs a TTY (run from a terminal)'); process.exit(1) }

  const suspend = () => { process.stdin.setRawMode(false); process.stdout.write(`${ESC}?1049l${ESC}?25h`) }
  const resume = () => { process.stdout.write(`${ESC}?1049h${ESC}?25l`); invalidate(); process.stdin.setRawMode(true) }
  const quit = () => { suspend(); process.exit(0) }
  // One collect in flight at a time; a request made meanwhile runs once after it.
  const worker = new Worker(`${AW}/lib/collect-worker.js`)
  let collecting = false
  let again = false
  const reloads = []
  const collectAll = (onModel) => {
    if (onModel) reloads.push(onModel)
    if (collecting) { again = true; return }
    collecting = true
    worker.postMessage('collect')
  }
  const sessions = createSessionsView({ suspend, resume, quit, footerHint: 'Tab health', reload: (cb) => collectAll(cb) })
  let view = process.argv.includes('--view') && process.argv[process.argv.indexOf('--view') + 1] === 'sessions' ? 'sessions' : 'health'

  const render = () => (view === 'health' ? renderHealth() : sessions.render())
  const refreshAsana = () => M && collectAsana(M.cfgAll).then(a => { ASANA = a; retitle(M.fleet, a.names); sessions.setModel(M.fleet); render() })
  worker.on('message', (r) => {
    collecting = false
    const first = !M
    if (r.model) {
      M = r.model
      retitle(M.fleet, ASANA.names)
      for (const cb of reloads.splice(0)) cb(M.fleet)
      if (!sessions.busy()) sessions.setModel(M.fleet)
      render()
      if (first) refreshAsana()
    }
    if (again) { again = false; collectAll() }
  })
  worker.on('error', (e) => { collecting = false; suspend(); console.error(`orch-tui: collector failed: ${e.message || e}`); process.exit(1) })

  process.stdout.write(`${ESC}?1049h${ESC}?25l`)
  invalidate()
  process.stdin.setRawMode(true)
  process.stdin.resume()
  process.on('exit', () => process.stdout.write(`${ESC}?1049l${ESC}?25h`))
  process.on('SIGINT', quit)
  process.stdout.on('resize', () => { invalidate(); render() })

  render()
  collectAll()
  setInterval(() => { if (!sessions.busy()) collectAll() }, 10000)
  setInterval(() => { if (!sessions.busy()) refreshAsana() }, 60000)

  process.stdin.on('data', (b) => {
    const k = b.toString()
    if (view === 'sessions' && sessions.busy()) { sessions.onKey(k); return }
    if (view === 'health' && actInput !== null) {
      // A chunk can carry several keys (fast typing, paste), Enter included.
      if (k === '\x1b' || k === '\x03') actInput = null
      else if (k === '\x7f' || k === '\b') actInput = actInput.slice(0, -1)
      else {
        const [typed, ...rest] = k.split('\r')
        actInput += typed.replace(/[^0-9:hmapHMAP ]/g, '')
        if (rest.length) { const q = actInput.trim(); actInput = null; if (q) actJump(q) }
      }
      render(); return
    }
    if (view === 'health' && M) {
      const was = actStatus
      actStatus = ''
      let hit = true
      if (k === `${ESC}A` || k === 'k') actSetOffset(actOffset() - 1)
      else if (k === `${ESC}B` || k === 'j') actSetOffset(actOffset() + 1)
      else if (k === `${ESC}5~`) actSetOffset(actOffset() - actPage)
      else if (k === `${ESC}6~`) actSetOffset(actOffset() + actPage)
      else if (k === 'g' || k === `${ESC}H` || k === `${ESC}1~`) actAnchor = null
      else if (k === 'G' || k === `${ESC}F` || k === `${ESC}4~`) actSetOffset(Infinity)
      else if (k === 't') actInput = ''
      else { hit = false; actStatus = was }
      if (hit) { render(); return }
    }
    if (k === '\t') { view = view === 'health' ? 'sessions' : 'health'; render(); return }
    if (k === 'q' || k === '\x03') quit()
    if (view === 'sessions') { if (sessions.onKey(k)) return }
    if (k === 'r') { collectAll(); refreshAsana() }
  })
}
