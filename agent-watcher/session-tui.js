#!/usr/bin/env node
// session-tui.js — interactive terminal UI over the agent session fleet.
// Launch: `resume-agent --tui` (or `agent-tui` alias, or run this file).
//
// One screen, two groups:
//   LIVE        every claude-asana-* / done-asana-* tmux session: kind, task
//               title, claude-process liveness, remote-control name + bridge
//               state, idle time, and reap exposure
//   TRANSCRIPTS recent watcher-spawned transcripts with NO live tmux session
//               (resumable; source = `resume-agent.sh --list --porcelain`)
//
// Reap display mirrors session-watchdog.js policy (the watchdog is the actor,
// this is only a view): chats, ad-hoc names, AND retired (done-asana) sessions
// share one idle TTL (watcher.idle_reap_hours, default 72h) unless the name is
// in watcher.persistent_anchors; retirees additionally cap at the newest
// keep_completed_sessions (oldest-first kill). Idle here is tmux
// session_activity — an approximation of the watchdog's own pane-content
// clock, close enough for a dashboard.
//
// Keys (context-sensitive, shown in the footer):
//   up/down/j/k  move       Enter/a  attach (switch-client inside tmux)
//   c  fork a new RC'd chat from the row's transcript (resume-agent --chat)
//   C  same, with --chrome
//   s  resume a TRANSCRIPTS row in place — same conversation, NO fork, no
//      confirm (resume-agent --chat --in-place; note in-place turns on a run
//      transcript land in the conversation evals and watcher resumes read)
//   /  content search over ALL transcripts on the machine (every kind and
//      project dir, live or dead) via session-index.sh --grep; ⏎ runs it,
//      Esc clears. Rows live in a pane attach; dead rows fork/resume.
//      o  cycles search sort: rank (index order) → activity → spawn
//   i  revive claude inside a DEAD chat/anchor pane (same conversation + RC)
//   x  kill tmux session (y/n confirm)      r  refresh      q  quit
//
// `--dump` prints the gathered model as JSON and exits (debugging / tests).
//
// Never respawns claude inside ITS OWN pane (this process runs in the
// operator's terminal, outside the fleet's panes, so acting on any listed
// session is safe).
'use strict'
const { execSync, execFileSync, spawnSync } = require('child_process')
const fs = require('fs')
const os = require('os')

const HOME = os.homedir()
const AW = `${HOME}/.config/agent-watcher`
const RESUME = `${AW}/resume-agent.sh`
const FORKS = `${process.env.XDG_STATE_HOME || HOME + '/.local/state'}/agent-watcher/chat-forks.jsonl`

const sh = (cmd) => { try { return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }) } catch { return '' } }

// ─── data gathering ──────────────────────────────────────────────────────────

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

// RC "bridge up" detection — same two-build-style logic as session-watchdog.js
// rcBridgeUp() (new builds: "/rc" token on the status footer line; old builds:
// "Remote Control active" within the last 3 lines). Keep in sync with the
// watchdog; it is the actor, this is the view.
const RC_FOOTER_RE = /shift\+tab to cycle|for agents/
const RC_TOKEN_RE = /(^|\s)\/rc(\s|$)/
function rcBridgeUp (content) {
  const lines = content.split('\n')
  if (lines.some(l => RC_FOOTER_RE.test(l) && RC_TOKEN_RE.test(l))) return true
  return /Remote Control active/.test(lines.slice(-3).join('\n'))
}

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
  // to '_', which glued "_<activity>_<created>" onto every session name and
  // crashed classify() on done-asana-* rows (no pattern matched the mangled name).
  const out = sh(`tmux list-sessions -F '#{session_name}|#{session_activity}|#{session_created}' 2>/dev/null`)
  for (const line of out.split('\n')) {
    if (!line.trim()) continue
    const [name, activity, created] = line.split('|')
    if (!/^(claude|done)-asana-/.test(name)) continue
    // -s: all panes in ALL windows of the session, not just the active window.
    const pids = sh(`tmux list-panes -s -t '${name}' -F '#{pane_pid}' 2>/dev/null`).split('\n').filter(Boolean)
    let claudeArgs = ''
    for (const pid of pids) {
      for (const c of kids.get(pid.trim()) || []) {
        if (/(^|\/)claude( |$)/.test(c.cmd) || c.cmd.startsWith('claude ')) { claudeArgs = c.cmd; break }
      }
      if (claudeArgs) break
    }
    const rc = (claudeArgs.match(/--remote-control\s+(\S+)/) || [])[1] || ''
    const resumeUuid = (claudeArgs.match(/--resume\s+([0-9a-f-]{36})/) || [])[1] || ''
    // Bridge state is checked from the pane footer for EVERY live claude, not
    // just argv-named ones: on current CLI builds RC can be armed app-side with
    // no --remote-control flag in argv, so an empty rc name says nothing about
    // whether the bridge is up.
    let rcUp = false
    if (claudeArgs) rcUp = rcBridgeUp(sh(`tmux capture-pane -p -t '${name}' 2>/dev/null`))
    sessions.push({
      name,
      activity: Number(activity) || 0,
      created: Number(created) || 0,
      claudeAlive: !!claudeArgs,
      rc, rcUp, resumeUuid
    })
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

// Every datetime the TUI renders is PT, 12-hour ("8/11 4:17p").
function fmtDate (epoch) {
  if (!epoch) return '?'
  return new Date(epoch * 1000)
    .toLocaleString('en-US', { timeZone: 'America/Los_Angeles', month: 'numeric', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true })
    .replace(',', '').replace(' AM', 'a').replace(' PM', 'p')
}

function fmtAgo (epoch) {
  if (!epoch) return '?'
  let s = Math.max(0, Math.floor(Date.now() / 1000 - epoch))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h${Math.floor((s % 3600) / 60)}m`
  return `${Math.floor(s / 86400)}d${Math.floor((s % 86400) / 3600)}h`
}

function buildModel () {
  const cfg = loadConfig()
  const forks = loadForks()
  const transcripts = loadTranscripts()
  const tmux = loadTmux()

  const newestByGid = new Map()
  for (const t of transcripts) if (t.gid && !newestByGid.has(t.gid)) newestByGid.set(t.gid, t)

  const live = tmux.map(s => {
    const c = classify(s, cfg)
    const row = { ...s, ...c, title: '', uuid: '', reap: '' }
    if (c.kind === 'run') {
      const t = newestByGid.get(c.gid)
      row.title = t ? t.title : `task ${c.gid}`
      row.uuid = t ? t.uuid : ''
    } else {
      row.uuid = s.resumeUuid   // pane's argv uuid; for a fork the REAL transcript is the registry child
      const reg = forks.bySlug.get(c.slug)
      if (reg) {
        row.uuid = reg.child && reg.child !== 'unknown' ? reg.child : row.uuid
        // Fork rows title by what they fork, not by their uuid-derived slug —
        // the slug is still visible in the rc column. Parent outside the
        // porcelain list (e.g. fork of an anchor chat) falls back to its uuid.
        const parent = transcripts.find(t => t.uuid === reg.parent)
        row.title = parent
          ? `FORK: ${parent.title.replace(/^Asana: /, '')}`
          : `FORK: ${String(reg.parent).slice(0, 8)}…`
      }
      if (!row.title) row.title = c.slug
    }
    // Reap exposure — shared TTL for every non-run class (chats, ad-hoc,
    // retired). Idle here is tmux activity, an approximation of the watchdog's
    // pane-content clock; shown only inside the last 24h so the column stays
    // quiet for fresh sessions.
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
    .map(t => ({ kind: 'transcript', state: '', title: t.title, uuid: t.uuid, gid: t.gid, mtime: t.mtime, forkChild: t.forkChild, isForkOfLive: !!t.forkChild }))

  return { live, dead, cfg }
}

// ─── rendering ───────────────────────────────────────────────────────────────

const ESC = '\x1b['
const clr = { inv: `${ESC}7m`, dim: `${ESC}2m`, bold: `${ESC}1m`, red: `${ESC}31m`, grn: `${ESC}32m`, yel: `${ESC}33m`, cyn: `${ESC}36m`, off: `${ESC}0m` }
let model = { live: [], dead: [], cfg: {} }
let items = []          // flattened selectable rows
let sel = 0
let status = ''
let confirmFn = null    // pending y/n action
let searchInput = null  // string while the operator types a query ('/' mode)
let search = null       // {q, rows} while results are displayed

function flatten () {
  items = []
  if (search) {
    for (const r of search.rows) items.push(r)
  } else {
    for (const r of model.live) items.push(r)
    for (const r of model.dead) items.push(r)
  }
  if (sel >= items.length) sel = Math.max(0, items.length - 1)
}

// 'o' in search results: cycle sort order. 'rank' is session-index's own
// ranking (originals first, authored count, recency); activity/spawn are
// newest-first by transcript mtime/birth.
function cycleSearchSort () {
  if (!search) return
  search.sort = search.sort === 'rank' ? 'act' : search.sort === 'act' ? 'spawn' : 'rank'
  search.rows = search.sort === 'rank'
    ? search.rank.slice()
    : search.rank.slice().sort((a, b) => (search.sort === 'act' ? b.mtime - a.mtime : b.birth - a.birth))
  sel = 0
  flatten()
  status = `sort: ${search.sort === 'rank' ? 'rank (index order)' : search.sort === 'act' ? 'last activity' : 'spawn date'}`
  render()
}

// '/' search: content search over EVERY transcript on this machine (all kinds,
// all project dirs, live or dead) via session-index.sh --grep — a superset of
// the TRANSCRIPTS list, which only carries watcher-spawned runs. Rows whose
// conversation is live in a pane attach; dead ones fork/resume like any
// transcript row.
function runSearch (q) {
  status = `searching all transcripts for '${q}'…`; render()
  let j
  try {
    const out = execFileSync(`${AW}/session-index.sh`, ['--grep', q], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
    j = JSON.parse(out)
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
  sel = 0
  flatten()
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

function stripAnsi (s) { return s.replace(/\x1b\[[0-9;]*m/g, '') }
function pad (s, w) {
  const len = stripAnsi(s).length
  if (len >= w) {
    // truncate on the plain string, re-colorless (cheap + safe)
    return stripAnsi(s).slice(0, w - 1) + '…'
  }
  return s + ' '.repeat(w - len)
}

function render () {
  const cols = process.stdout.columns || 120
  const rows = process.stdout.rows || 40
  let out = `${ESC}H${ESC}2J`
  out += `${clr.bold} AGENT SESSIONS${clr.off}  ${clr.dim}${new Date().toLocaleTimeString('en-US', { timeZone: 'America/Los_Angeles', hour12: true })}  anchors never reap: ${(model.cfg.anchors || []).join(', ')}  retired kept: ${model.cfg.keepCompleted}${clr.off}\n\n`

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
      if (search) {
        l = `   ${pad(fmtDate(r.mtime), 15)}${pad(fmtAgo(r.mtime), 9)}${pad(fmtDate(r.birth), 15)}${pad(r.title, titleW)}${fork}`
      } else {
        l = `   ${pad(fmtDate(r.mtime), 12)}${pad(r.title, titleW)}${fork}`
      }
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
    if (r.kind !== 'transcript') { acts.push('⏎/a attach', 'x kill') }
    if (r.kind === 'transcript' && r.liveName) acts.push('⏎/a attach (live)')
    if (r.uuid) acts.push('c chat-fork', 'C chat+chrome')
    if (r.kind === 'transcript' && r.uuid && !r.liveName) acts.push('s resume (no fork)')
    if (r.state === 'dead' && r.kind !== 'run' && r.uuid) acts.push('i revive in pane')
  }
  acts.push('/ search')
  if (search) acts.push('o sort', 'Esc clear')
  acts.push('r refresh', 'q quit')
  out += `\n${ESC}${rows - 1};1H${clr.dim} ${acts.join('  ·  ')}${clr.off}`
  if (searchInput !== null) out += `${ESC}${rows};1H${clr.cyn} search: ${searchInput}▌${clr.off}`
  else if (status) out += `${ESC}${rows};1H${clr.yel} ${status.slice(0, cols - 2)}${clr.off}`
  process.stdout.write(out)
}

// ─── actions ─────────────────────────────────────────────────────────────────

function suspendTui () { process.stdin.setRawMode(false); process.stdout.write(`${ESC}?1049l${ESC}?25h`) }
function resumeTui () { process.stdout.write(`${ESC}?1049h${ESC}?25l`); process.stdin.setRawMode(true) }

function runVisible (cmd, args) {
  suspendTui()
  const res = spawnSync(cmd, args, { stdio: 'inherit' })
  process.stdout.write('\n[press any key to return]')
  // one blocking read
  spawnSync('bash', ['-c', 'read -n1 -s'], { stdio: 'inherit' })
  resumeTui()
  return res.status
}

function attach (r) {
  // Search rows are transcripts, but one whose conversation is live in a pane
  // attaches to that pane (resuming a live conversation would fork reality).
  const target = r.kind === 'transcript' ? r.liveName : r.name
  if (!target) return
  if (process.env.TMUX) {
    sh(`tmux switch-client -t '${target}'`)
    quit()   // this client moved to the target session; leave the TUI cleanly
  } else {
    suspendTui()
    spawnSync('tmux', ['attach', '-t', target], { stdio: 'inherit' })
    resumeTui()
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

// Resume a TRANSCRIPTS row in place: SAME conversation, no fork, in a new
// watchdog-covered RC'd tmux session (resume-agent --chat --in-place). Run
// transcripts get a confirm first: new turns append to the conversation that
// evals and the watcher's own resumes read, unlike a fork which leaves it
// pristine.
function resumeInPlace (r) {
  if (r.kind !== 'transcript') return
  if (!r.uuid) { status = 'no transcript uuid resolved for this row'; render(); return }
  if (r.liveName) { status = `live in ${r.liveName} — attach (⏎) instead of resuming a live conversation`; render(); return }
  // No confirm, by operator decree: in-place turns on a RUN transcript do land
  // in the conversation evals/watcher resumes read — operator owns that risk.
  runVisible(RESUME, ['--uuid', r.uuid, '--chat', '--in-place'])
  refresh('in-place resume attempted — refreshed')
}

// Revive claude INSIDE an existing dead pane (chat/anchor only; runs need
// slot re-allocation, which is resume-task.sh's job). Continues the SAME
// conversation (no fork) and restores the session's original RC name, so the
// tmux name, watchdog coverage, and phone-list identity all stay intact.
// resume-agent --chat --in-place is NOT usable here: it refuses while the tmux
// session still exists, and its slug would be re-derived from the uuid.
function reviveInPane (r) {
  if (r.kind === 'run') { status = 'dead RUN panes need slot re-alloc — use: resume-task.sh ' + (r.gid || ''); render(); return }
  if (!r.uuid) { status = 'no transcript uuid known (not in fork registry) — fork instead with c'; render(); return }
  const rcName = r.slug   // chats: "chat-<slug>"; anchors/ad-hoc: the bare name — both equal the RC convention
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
  model = buildModel()
  search = null           // refresh always returns to the fleet view
  flatten()
  status = msg || ''
  render()
}

function quit () {
  suspendTui()
  process.exit(0)
}

// ─── main loop ───────────────────────────────────────────────────────────────

// Importable as a library: orch-tui.js reuses buildModel() so the fleet/tmux
// logic lives in exactly one place. The interactive loop only runs when this
// file is the entrypoint.
module.exports = { buildModel, fmtAgo, sh }
if (require.main !== module) return

if (process.argv.includes('--dump')) {
  const m = buildModel()
  console.log(JSON.stringify(m, null, 2))
  process.exit(0)
}
if (!process.stdin.isTTY) { console.error('session-tui: needs a TTY (run from a terminal)'); process.exit(1) }
process.stdout.write(`${ESC}?1049h${ESC}?25l`)
process.stdin.setRawMode(true)
process.stdin.resume()
process.on('exit', () => process.stdout.write(`${ESC}?1049l${ESC}?25h`))
process.on('SIGINT', quit)
process.stdout.on('resize', render)

refresh()

process.stdin.on('data', (b) => {
  const k = b.toString()
  if (confirmFn) { const f = confirmFn; confirmFn = null; f(k === 'y' || k === 'Y'); return }
  if (searchInput !== null) {           // typing a query
    if (k === '\x03' || k === '\x1b') { searchInput = null; status = ''; render(); return }
    if (k === '\r') { const q = searchInput.trim(); searchInput = null; if (q) runSearch(q); else render(); return }
    if (k === '\x7f' || k === '\b') { searchInput = searchInput.slice(0, -1); render(); return }
    if (k.length === 1 && k >= ' ') { searchInput += k; render() }
    return
  }
  const r = items[sel]
  if (k === '\x1b' && search) { search = null; sel = 0; flatten(); status = ''; render(); return }
  if (k === '/') { searchInput = ''; render(); return }
  if (k === 'o' && search) { cycleSearchSort(); return }
  if (k === 'q' || k === '\x03') quit()
  else if (k === `${ESC}A` || k === 'k') { sel = Math.max(0, sel - 1); render() }
  else if (k === `${ESC}B` || k === 'j') { sel = Math.min(items.length - 1, sel + 1); render() }
  else if (k === 'r') refresh()
  else if (k === '\r' || k === 'a') { if (r) attach(r) }
  else if (k === 'c') { if (r) chatFork(r, false) }
  else if (k === 'C') { if (r) chatFork(r, true) }
  else if (k === 's') { if (r) resumeInPlace(r) }
  else if (k === 'i') { if (r && r.state === 'dead') reviveInPane(r) }
  else if (k === 'x') { if (r) killSession(r) }
})
