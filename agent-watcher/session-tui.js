#!/usr/bin/env node
// session-tui.js — the SESSIONS view of the orchestration TUI: the agent
// session fleet with actions. Data comes from lib/fleet-model.js; the host
// terminal (alt screen, raw stdin, refresh timers, Tab between views) is
// orch-tui.js. Running this file directly opens orch-tui on the Sessions view,
// so `agent-tui` and `resume-agent --tui` keep working.
//
// Two groups:
//   LIVE        every claude-asana-* / done-asana-* tmux session: kind, task
//               title, claude-process liveness, remote-control name + bridge
//               state, idle time, and reap exposure
//   TRANSCRIPTS recent watcher-spawned transcripts with NO live tmux session
//               (resumable; source = `resume-agent.sh --list --porcelain`)
//
// Keys (context-sensitive, shown in the footer):
//   up/down/j/k  move       Enter/a  attach (switch-client inside tmux)
//   c  fork a new RC'd chat from the row's transcript (resume-agent --chat)
//   C  same, with --chrome
//   s  resume a TRANSCRIPTS row in place (resume-agent --chat --in-place)
//   /  content search over ALL transcripts via session-index.sh --grep;
//      Enter runs it, Esc clears, o cycles sort (rank / activity / spawn)
//   i  revive claude inside a DEAD chat/anchor pane (same conversation + RC)
//   x  kill tmux session (y/n confirm)      r  refresh
//
// `--dump` prints the sessions model as JSON (the artifact page and tests use
// the full model from orch-tui --dump instead).
'use strict'
const { execFileSync, spawnSync } = require('child_process')
const os = require('os')
const AW = `${os.homedir()}/.config/agent-watcher`
const { buildSessions, fmtAgo, fmtDate, sh } = require(`${AW}/lib/fleet-model.js`)
const RESUME = `${AW}/resume-agent.sh`

const ESC = '\x1b['
const clr = { inv: `${ESC}7m`, dim: `${ESC}2m`, bold: `${ESC}1m`, red: `${ESC}31m`, grn: `${ESC}32m`, yel: `${ESC}33m`, cyn: `${ESC}36m`, off: `${ESC}0m` }
const stripAnsi = (s) => s.replace(/\x1b\[[0-9;]*m/g, '')
function pad (s, w) {
  const len = stripAnsi(s).length
  if (len >= w) return stripAnsi(s).slice(0, w - 1) + '…'
  return s + ' '.repeat(w - len)
}

// createSessionsView(host): host = { suspend(), resume(), quit(), footerHint }
// Returns { name, render(), onKey(k) -> handled, refresh(msg), setModel(fleet) }.
function createSessionsView (host) {
  let model = { live: [], dead: [], cfg: {} }
  let items = []
  let sel = 0
  let status = ''
  let confirmFn = null
  let searchInput = null
  let search = null

  function flatten () {
    items = []
    if (search) for (const r of search.rows) items.push(r)
    else { for (const r of model.live) items.push(r); for (const r of model.dead) items.push(r) }
    if (sel >= items.length) sel = Math.max(0, items.length - 1)
  }

  function cycleSearchSort () {
    if (!search) return
    search.sort = search.sort === 'rank' ? 'act' : search.sort === 'act' ? 'spawn' : 'rank'
    search.rows = search.sort === 'rank'
      ? search.rank.slice()
      : search.rank.slice().sort((a, b) => (search.sort === 'act' ? b.mtime - a.mtime : b.birth - a.birth))
    sel = 0; flatten()
    status = `sort: ${search.sort === 'rank' ? 'rank (index order)' : search.sort === 'act' ? 'last activity' : 'spawn date'}`
    render()
  }

  function runSearch (q) {
    status = `searching all transcripts for '${q}'…`; render()
    let j
    try {
      j = JSON.parse(execFileSync(`${AW}/session-index.sh`, ['--grep', q], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }))
    } catch (e) { search = null; status = `search failed: ${String(e).slice(0, 80)}`; render(); return }
    const rows = (j.transcripts || []).filter(t => t.grep).map(t => ({
      kind: 'transcript',
      state: '',
      title: (t.live_tmux ? '[LIVE] ' : '') + (t.task_name ? `Asana: ${t.task_name}` : `${t.kind} ${t.uuid.slice(0, 8)}`) +
        (t.grep.inherited_from ? '  (fork echo — prefer parent)' : `  (${t.grep.authored} hits)`),
      uuid: t.uuid,
      gid: t.task_gid || '',
      mtime: Math.floor(Date.parse(t.mtime) / 1000),
      birth: Math.floor(Date.parse(t.birth) / 1000) || 0,
      forkChild: null,
      liveName: t.live_tmux || ''
    }))
    search = { q, rows, rank: rows.slice(), sort: 'rank' }
    sel = 0; flatten()
    status = `${rows.length} matches for '${q}' — Esc clears, o cycles sort (rank/activity/spawn)`
    render()
  }

  function glyph (r) {
    if (r.kind === 'run') return r.state === 'running' ? `${clr.grn}●${clr.off}` : r.state === 'retired' ? `${clr.yel}◐${clr.off}` : `${clr.red}✗${clr.off}`
    if (r.kind === 'transcript') return ' '
    if (r.state === 'dead') return `${clr.red}✗${clr.off}`
    return r.kind === 'anchor' ? `${clr.cyn}⚓${clr.off}` : `${clr.grn}◦${clr.off}`
  }

  function rcCell (r) {
    if (r.kind === 'transcript') return ''
    if (!r.claudeAlive) return `${clr.red}claude dead${clr.off}`
    if (!r.rc) return r.rcUp ? `${clr.grn}rc:(in-app)${clr.off}` : `${clr.dim}no rc${clr.off}`
    return r.rcUp ? `${clr.grn}rc:${r.rc}${clr.off}` : `${clr.yel}rc:${r.rc} (bridge down)${clr.off}`
  }

  function render () {
    const cols = process.stdout.columns || 120
    const rows = process.stdout.rows || 40
    let out = `${ESC}H${ESC}2J`
    out += `${clr.bold} SESSIONS${clr.off}  ${clr.dim}${host.footerHint || ''}  ${new Date().toLocaleTimeString('en-US', { timeZone: 'America/Los_Angeles', hour12: true })}  anchors never reap: ${(model.cfg.anchors || []).join(', ')}  retired kept: ${model.cfg.keepCompleted}${clr.off}\n\n`
    const titleW = Math.min(58, cols - 52)
    let line = 0
    const maxLines = rows - 7
    const startIdx = Math.max(0, sel - maxLines + 4)
    let printedLive = false; let printedDead = false
    if (search) {
      out += `${clr.bold} SEARCH '${search.q}' — ${search.rows.length} transcript match(es), all kinds — sort: ${search.sort}${clr.off}\n`
      out += `${clr.dim}   ${pad('LAST ACTIVITY', 15)}${pad('IDLE', 9)}${pad('SPAWNED', 15)}TITLE${clr.off}\n`
      line += 2
    }
    items.forEach((r, i) => {
      if (i < startIdx || line >= maxLines) return
      if (!search && i < model.live.length && !printedLive) { out += `${clr.bold} LIVE (tmux)${clr.off}\n`; printedLive = true; line++ }
      if (!search && i >= model.live.length && !printedDead) { out += `\n${clr.bold} TRANSCRIPTS (no live session — resumable)${clr.off}\n`; printedDead = true; line += 2 }
      let l
      if (r.kind === 'transcript') {
        const fork = r.isForkOfLive ? `${clr.dim} → has live fork${clr.off}` : ''
        l = search
          ? `   ${pad(fmtDate(r.mtime), 15)}${pad(fmtAgo(r.mtime), 9)}${pad(fmtDate(r.birth), 15)}${pad(r.title, titleW)}${fork}`
          : `   ${pad(fmtDate(r.mtime), 12)}${pad(r.title, titleW)}${fork}`
      } else {
        const idle = `idle ${fmtAgo(r.activity)}`
        const reap = r.reap ? (r.reap.startsWith('REAPABLE') || r.reap.startsWith('overflow') ? `${clr.red}${r.reap}${clr.off}` : `${clr.yel}${r.reap}${clr.off}`) : ''
        l = ` ${glyph(r)} ${pad(r.kind === 'run' ? r.state : r.kind, 8)}${pad(r.title, titleW)} ${pad(rcCell(r), 26)}${pad(idle, 14)}${reap}`
      }
      if (i === sel) l = `${clr.inv}${pad(stripAnsi(l), cols - 2)}${clr.off}`
      out += l + '\n'
      line++
    })
    const r = items[sel]
    const acts = []
    if (r) {
      if (r.kind !== 'transcript') acts.push('⏎/a attach', 'x kill')
      if (r.kind === 'transcript' && r.liveName) acts.push('⏎/a attach (live)')
      if (r.uuid) acts.push('c chat-fork', 'C chat+chrome')
      if (r.kind === 'transcript' && r.uuid && !r.liveName) acts.push('s resume (no fork)')
      if (r.state === 'dead' && r.kind !== 'run' && r.uuid) acts.push('i revive in pane')
    }
    acts.push('/ search')
    if (search) acts.push('o sort', 'Esc clear')
    acts.push('r refresh', 'Tab health', 'q quit')
    out += `\n${ESC}${rows - 1};1H${clr.dim} ${acts.join('  ·  ')}${clr.off}`
    if (searchInput !== null) out += `${ESC}${rows};1H${clr.cyn} search: ${searchInput}▌${clr.off}`
    else if (status) out += `${ESC}${rows};1H${clr.yel} ${status.slice(0, cols - 2)}${clr.off}`
    process.stdout.write(out)
  }

  // ── actions ──
  function runVisible (cmd, args) {
    host.suspend()
    const res = spawnSync(cmd, args, { stdio: 'inherit' })
    process.stdout.write('\n[press any key to return]')
    spawnSync('bash', ['-c', 'read -n1 -s'], { stdio: 'inherit' })
    host.resume()
    return res.status
  }

  function attach (r) {
    const target = r.kind === 'transcript' ? r.liveName : r.name
    if (!target) return
    if (process.env.TMUX) {
      sh(`tmux switch-client -t '${target}'`)
      host.quit()
    } else {
      host.suspend()
      spawnSync('tmux', ['attach', '-t', target], { stdio: 'inherit' })
      host.resume()
      refresh('detached — refreshed')
    }
  }

  function chatFork (r, chrome) {
    if (!r.uuid) { status = 'no transcript uuid resolved for this row'; render(); return }
    const args = ['--uuid', r.uuid, '--chat']
    if (chrome) args.push('--chrome')
    runVisible(RESUME, args)
    refresh('chat spawn attempted — refreshed')
  }

  function resumeInPlace (r) {
    if (r.kind !== 'transcript') return
    if (!r.uuid) { status = 'no transcript uuid resolved for this row'; render(); return }
    if (r.liveName) { status = `live in ${r.liveName} — attach (⏎) instead of resuming a live conversation`; render(); return }
    runVisible(RESUME, ['--uuid', r.uuid, '--chat', '--in-place'])
    refresh('in-place resume attempted — refreshed')
  }

  // Revive claude INSIDE an existing dead pane (chat/anchor only; runs need
  // slot re-allocation, which is resume-task.sh's job).
  function reviveInPane (r) {
    if (r.kind === 'run') { status = 'dead RUN panes need slot re-alloc — use: resume-task.sh ' + (r.gid || ''); render(); return }
    if (!r.uuid) { status = 'no transcript uuid known (not in fork registry) — fork instead with c'; render(); return }
    const rcName = r.slug
    sh(`tmux send-keys -t '${r.name}' C-u`)
    sh(`tmux send-keys -t '${r.name}' "claude --resume ${r.uuid} --dangerously-skip-permissions --remote-control ${rcName}" Enter`)
    refresh(`revived claude in ${r.name} (rc ${rcName}) — give it a few seconds, then r to re-check`)
  }

  function killSession (r) {
    if (r.kind === 'transcript') return
    status = `kill tmux session ${r.name}? [y/n]`
    confirmFn = (yes) => {
      if (yes) { sh(`tmux kill-session -t '${r.name}'`); refresh(`killed ${r.name}`) } else { status = ''; render() }
    }
    render()
  }

  function refresh (msg) {
    status = 'loading…'; render()
    model = buildSessions()
    search = null
    flatten()
    status = msg || ''
    render()
  }

  // Host-driven model updates (auto-refresh): keep selection and search; only
  // swap the fleet lists. Skipped by the host while the operator is typing or
  // confirming, so the screen never moves under a decision.
  function setModel (fleet) {
    model = fleet
    if (!search) flatten()
  }
  const busy = () => confirmFn !== null || searchInput !== null

  function onKey (k) {
    if (confirmFn) { const f = confirmFn; confirmFn = null; f(k === 'y' || k === 'Y'); return true }
    if (searchInput !== null) {
      if (k === '\x03' || k === '\x1b') { searchInput = null; status = ''; render(); return true }
      if (k === '\r') { const q = searchInput.trim(); searchInput = null; if (q) runSearch(q); else render(); return true }
      if (k === '\x7f' || k === '\b') { searchInput = searchInput.slice(0, -1); render(); return true }
      if (k.length === 1 && k >= ' ') { searchInput += k; render() }
      return true
    }
    const r = items[sel]
    if (k === '\x1b' && search) { search = null; sel = 0; flatten(); status = ''; render(); return true }
    if (k === '/') { searchInput = ''; render(); return true }
    if (k === 'o' && search) { cycleSearchSort(); return true }
    if (k === `${ESC}A` || k === 'k') { sel = Math.max(0, sel - 1); render(); return true }
    if (k === `${ESC}B` || k === 'j') { sel = Math.min(items.length - 1, sel + 1); render(); return true }
    if (k === 'r') { refresh(); return true }
    if (k === '\r' || k === 'a') { if (r) attach(r); return true }
    if (k === 'c') { if (r) chatFork(r, false); return true }
    if (k === 'C') { if (r) chatFork(r, true); return true }
    if (k === 's') { if (r) resumeInPlace(r); return true }
    if (k === 'i') { if (r && r.state === 'dead') reviveInPane(r); return true }
    if (k === 'x') { if (r) killSession(r); return true }
    return false
  }

  return { name: 'sessions', render, onKey, refresh, setModel, busy }
}

module.exports = { createSessionsView, buildModel: buildSessions, buildSessions, fmtAgo, sh }

if (require.main === module) {
  if (process.argv.includes('--dump')) {
    console.log(JSON.stringify(buildSessions(), null, 2))
    process.exit(0)
  }
  process.argv.push('--view', 'sessions')
  require(`${AW}/orch-tui.js`)
}
