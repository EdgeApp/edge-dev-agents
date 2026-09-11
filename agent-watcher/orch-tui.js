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
// `session-tui.js` (Sessions first). Keys: Tab switch view, r refresh, q quit,
// plus the Sessions view's own keys. Local model refreshes every 10s; the
// Asana tally every 60s (never while a Sessions prompt is open).
// `--once` prints one Health frame (no TTY). `--dump` prints the full model
// as JSON, Asana tally included. `--view sessions` opens on Sessions.
'use strict'
const os = require('os')
const AW = `${os.homedir()}/.config/agent-watcher`
const M0 = require(`${AW}/lib/fleet-model.js`)
const { collect, collectAsana, spawnVerdict, fmtAgo, retitle } = M0
const { createSessionsView } = require(`${AW}/session-tui.js`)

const ESC = '\x1b['
const C = { inv: `${ESC}7m`, dim: `${ESC}2m`, bold: `${ESC}1m`, red: `${ESC}31m`, grn: `${ESC}32m`, yel: `${ESC}33m`, cyn: `${ESC}36m`, off: `${ESC}0m` }
const strip = (s) => s.replace(/\x1b\[[0-9;]*m/g, '')
const pad = (s, w) => { const l = strip(s).length; return l >= w ? strip(s).slice(0, w - 1) + '…' : s + ' '.repeat(w - l) }

let M = null
let ASANA = { tally: null, pending: [], err: '', at: 0 }

function jobsLine (jobs) {
  return jobs.map(j => {
    let col = C.grn; let note = ''
    if (j.name === 'config-watch' && j.rc === 1) { col = C.red; note = ' DRIFT' } else if (j.rc !== 0) { col = C.yel; note = ` rc${j.rc}` }
    return `${col}${j.name}${note}${C.off}`
  }).join('  ')
}

function healthPanel (v, cols) {
  const runs = M.fleet.live.filter(r => r.kind === 'run' && r.state === 'running').length
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
  L.push(row('capacity', `runs ${runs}/${v.maxConcurrent}   slots ${freeSlots} free   sims ${freeSims}/${M.pool.length} free   ${pendSeg}`))
  const fse = v.fseventsd
    ? `fseventsd ${(f => (f.cpu >= 100 ? C.red : f.cpu >= 50 ? C.yel : C.grn) + f.cpu.toFixed(0) + '%' + C.off)(v.fseventsd)} ${v.fseventsd.rssGb.toFixed(1)}G up ${v.fseventsd.etime}${v.fseventsd.lastRestart ? `${C.dim}, guard restarted ${fmtAgo(v.fseventsd.lastRestart / 1000)} ago${C.off}` : ''}`
    : `${C.dim}fseventsd ?${C.off}`
  const rg = v.runaway ? `   runaway ${v.runaway.total >= v.runaway.cap * 0.8 ? C.yel : C.grn}${v.runaway.total}/${v.runaway.cap}${C.off} agent procs` : ''
  const holds = v.holds.length ? `   ${C.red}holds: ${v.holds.join(' ')}${C.off}` : `   ${C.dim}holds: none${C.off}`
  L.push(row('guards', `${fse}${rg}${holds}`))
  L.push(row('jobs', `${jobsLine(v.jobs)}   ${C.dim}watcher tick ${v.watcherTickAge == null ? '?' : fmtAgo(Date.now() / 1000 - v.watcherTickAge) + ' ago'} · watchdog ${v.watchdogTickAge == null ? '?' : fmtAgo(Date.now() / 1000 - v.watchdogTickAge) + ' ago'}${C.off}`))
  const lw = v.lastWatcherLine ? `${/skipped/.test(v.lastWatcherLine) ? C.yel : C.dim}${v.lastWatcherLine.slice(0, cols - 14)}${C.off}` : `${C.dim}(no watcher line)${C.off}`
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
  if (!M) return
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
  L.push(`${C.bold} ACTIVITY${C.off} ${C.dim}(watcher + watchdog, interesting lines)${C.off}`)
  for (const a of M.activity) {
    const t = new Date(a.ts); const hh = `${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}`
    L.push(`  ${C.dim}${hh} ${pad(a.src, 9)}${C.off}${a.msg.slice(0, cols - 16)}`)
  }
  let out = `${ESC}H${ESC}2J` + L.slice(0, rows - 2).join('\n')
  out += `${ESC}${rows};1H${C.dim} Tab sessions · r refresh (local 10s / asana 60s auto) · q quit${C.off}`
  process.stdout.write(out)
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
  const resume = () => { process.stdout.write(`${ESC}?1049h${ESC}?25l`); process.stdin.setRawMode(true) }
  const quit = () => { suspend(); process.exit(0) }
  const sessions = createSessionsView({ suspend, resume, quit, footerHint: 'Tab health' })
  let view = process.argv.includes('--view') && process.argv[process.argv.indexOf('--view') + 1] === 'sessions' ? 'sessions' : 'health'

  const render = () => (view === 'health' ? renderHealth() : sessions.render())
  const collectAll = () => { M = collect(); retitle(M.fleet, ASANA.names); sessions.setModel(M.fleet) }
  const refreshAsana = () => collectAsana(M.cfgAll).then(a => { ASANA = a; retitle(M.fleet, a.names); sessions.setModel(M.fleet); render() })

  process.stdout.write(`${ESC}?1049h${ESC}?25l`)
  process.stdin.setRawMode(true)
  process.stdin.resume()
  process.on('exit', () => process.stdout.write(`${ESC}?1049l${ESC}?25h`))
  process.on('SIGINT', quit)
  process.stdout.on('resize', render)

  collectAll(); render()
  refreshAsana()
  setInterval(() => { if (sessions.busy()) return; collectAll(); render() }, 10000)
  setInterval(() => { if (!sessions.busy()) refreshAsana() }, 60000)

  process.stdin.on('data', (b) => {
    const k = b.toString()
    if (view === 'sessions' && sessions.busy()) { sessions.onKey(k); return }
    if (k === '\t') { view = view === 'health' ? 'sessions' : 'health'; render(); return }
    if (k === 'q' || k === '\x03') quit()
    if (view === 'sessions') { if (sessions.onKey(k)) return }
    if (k === 'r') { collectAll(); render(); refreshAsana() }
  })
}
