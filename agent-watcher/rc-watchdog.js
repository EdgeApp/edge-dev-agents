#!/usr/bin/env node
// rc-watchdog.js — Watchdog for claude-asana-* tmux sessions.
//
// Variants handled:
//  - Variant 1 (RC bridge dead, claude alive): heuristic — pane content unchanged for IDLE_THRESHOLD_MS → send a wake message, wait, then `/remote-control`. This is keystroke-only; it never spawns a new claude.
//  - Completion sweep: if Asana agent_status is Complete for a session's task GID, kill the tmux session to free resources.
//
// REMOVED 2026-05-28 — Variant 2 (process-death auto-resume):
//   It detected "claude dead" and injected `claude --resume` into the pane. Two defects made it
//   a memory-runaway hazard: (a) detection was broken — claude-code's process `comm` is `cli`
//   (argv is renamed), so the /claude/ regex never matched and the watchdog believed claude was
//   dead on EVERY tick; (b) the remedy spawned a claude. Combined with /one-shot's old `/loop`
//   PR-watcher, resumes could stack and self-replicate into the fork chain that OOM'd the box
//   twice (see oom-repro/HANDOFF.md). The watchdog no longer auto-resumes; dead sessions are
//   logged and left for manual / Asana-driven handling.
//
// Spawn pattern this watchdog expects:
//   tmux new-session -d -s "claude-asana-<id>" \
//     "bash -c 'cd ~/git && claude --rc \"<prompt>\" ; echo \"[claude exited at $(date)]\" ; exec bash'"
// The `exec bash` keeps the pane alive after claude exits.

const { execSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const slots = require('./lib/slots.js')

const HOME = process.env.HOME || ''
const DIR = path.join(HOME, '.config/agent-watcher')
const STATE_FILE = path.join(slots.STATE_DIR, 'watchdog-state.json')
const CRED_FILE = path.join(HOME, '.config/agent-watcher/credentials.json')
const CFG_FILE = path.join(HOME, '.config/agent-watcher/asana-config.json')
const IDLE_THRESHOLD_MS = 20 * 60 * 1000
const SESSION_PREFIX = 'claude-asana-'
const WORKTREES_ROOT = path.join(HOME, 'git/.agent-worktrees')
const DEFAULT_KEEP_COMPLETED = 5

// Cache: token + status field GID + retention cap read once per process run.
let _token = null
let _statusFieldGid = null
let _keepCompleted = null
function getAsanaToken() {
  if (_token !== null) return _token
  try {
    const data = JSON.parse(fs.readFileSync(CRED_FILE, 'utf8'))
    _token = data.asana_token || ''
  } catch { _token = '' }
  return _token
}
function getStatusFieldGid() {
  if (_statusFieldGid !== null) return _statusFieldGid
  try {
    const cfg = JSON.parse(fs.readFileSync(CFG_FILE, 'utf8'))
    _statusFieldGid = cfg.custom_fields?.agent_status?.gid || ''
  } catch { _statusFieldGid = '' }
  return _statusFieldGid
}
// How many completed worktrees to retain on disk before pruning the oldest.
function getKeepCompletedWorktrees() {
  if (_keepCompleted !== null) return _keepCompleted
  try {
    const cfg = JSON.parse(fs.readFileSync(CFG_FILE, 'utf8'))
    const n = cfg.watcher?.keep_completed_worktrees
    _keepCompleted = Number.isFinite(n) && n >= 0 ? n : DEFAULT_KEEP_COMPLETED
  } catch { _keepCompleted = DEFAULT_KEEP_COMPLETED }
  return _keepCompleted
}

function fetchAgentStatus(taskGid) {
  const token = getAsanaToken()
  const fieldGid = getStatusFieldGid()
  if (!token || !fieldGid) return null
  const out = sh(`curl -sS -H "Authorization: Bearer ${token}" "https://app.asana.com/api/1.0/tasks/${taskGid}?opt_fields=custom_fields.gid,custom_fields.enum_value.name"`)
  if (!out) return null
  try {
    const parsed = JSON.parse(out)
    const field = parsed.data?.custom_fields?.find((f) => f.gid === fieldGid)
    return field?.enum_value?.name || null
  } catch { return null }
}

function sh(cmd) {
  try {
    return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  } catch {
    return ''
  }
}

function shStrict(cmd) {
  return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] }).trim()
}

function listTargetSessions() {
  const out = sh('tmux list-sessions -F "#{session_name}"')
  return out.split('\n').filter((s) => s.startsWith(SESSION_PREFIX))
}

function capturePane(session) {
  return sh(`tmux capture-pane -t "${session}" -p`)
}

function getPanePid(session) {
  const out = sh(`tmux list-panes -t "${session}" -F "#{pane_pid}"`)
  const n = parseInt(out.split('\n')[0], 10)
  return Number.isFinite(n) ? n : null
}

// Recursively check whether any descendant of `pid` is a live claude-code process.
// claude-code's executable `comm` is `cli` (its argv[0] is renamed), NOT `claude`, so
// we match both: a path/name containing `claude`, OR a bare `cli`. Missing the `cli`
// case is what made the old death-path fire spuriously on every tick.
function claudeRunningUnder(pid, depth = 4) {
  if (depth <= 0) return false
  const childOut = sh(`pgrep -P ${pid}`)
  if (!childOut) return false
  const children = childOut.split('\n').filter(Boolean).map((s) => parseInt(s, 10))
  for (const child of children) {
    const comm = sh(`ps -o comm= -p ${child}`).trim()
    if (/(^|\/)claude($|\s)/.test(comm) || comm === 'cli' || comm.endsWith('/cli')) return true
    if (claudeRunningUnder(child, depth - 1)) return true
  }
  return false
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'))
  } catch {
    return { sessions: {} }
  }
}

function saveState(state) {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true })
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2))
}

function attemptRcRevive(session) {
  log(`[${session}] Variant 1 candidate: pane idle ${Math.round(IDLE_THRESHOLD_MS / 60000)}+ min. Sending wake + /remote-control.`)
  sh(`tmux send-keys -t "${session}" "<watchdog-revive-ping>" Enter`)
  sh('sleep 8')
  sh(`tmux send-keys -t "${session}" "/remote-control" Enter`)
}

function log(msg) {
  const ts = new Date().toISOString()
  console.log(`[${ts}] ${msg}`)
}

// On completion we KEEP the worktree on disk (up to keep_completed_worktrees, default 5)
// so it can be inspected or resumed afterward. We still immediately free the scarce
// concurrency resources: the cloned sim (released back to the pool, marked dirty for
// refresh) and the slot record. Worktree pruning to the cap happens in
// pruneRetainedWorktrees(). Best-effort; a partial failure must not wedge the sweep.
function releaseSimAndSlot(taskGid) {
  let slot = null
  try { slot = slots.get(taskGid) } catch { /* slots.json unreadable */ }
  if (slot?.sim_udid) {
    log(`  [${taskGid}] releasing pool entry holding ${slot.sim_udid}`)
    sh(`"${DIR}/release-pool-entry.sh" --task-gid "${taskGid}"`)
  }
  try { slots.release(taskGid); log(`  [${taskGid}] slot freed (worktree retained for inspection)`) }
  catch (e) { log(`  [${taskGid}] slot release failed: ${e.message}`) }
}

// Full teardown of one retained worktree: remove the worktree + branch (and any
// lingering sim/slot, though those were freed at completion). Used only by the prune.
function removeWorktree(taskGid, repo) {
  log(`  [${taskGid}] pruning retained worktree (repo ${repo})`)
  try { const s = slots.get(taskGid); if (s?.sim_udid) sh(`"${DIR}/release-pool-entry.sh" --task-gid "${taskGid}"`) } catch { /* none */ }
  sh(`"${DIR}/cleanup-task-workspace.sh" --task-gid "${taskGid}" --repo "${repo}"`)
  try { slots.release(taskGid) } catch { /* already gone */ }
}

// Enforce the retention cap. A worktree whose task still has a LIVE tmux session is
// never touched (and does not count against the cap). Among the rest — "retired"
// worktrees: completed, or whose session is gone — keep the newest
// keep_completed_worktrees by directory mtime and prune the older ones.
function pruneRetainedWorktrees(liveSessions) {
  const keep = getKeepCompletedWorktrees()
  let gidDirs
  try { gidDirs = fs.readdirSync(WORKTREES_ROOT) } catch { return } // no worktrees root yet
  const activeGids = new Set(liveSessions.map((s) => s.slice(SESSION_PREFIX.length)))
  const retired = []
  for (const gid of gidDirs) {
    if (activeGids.has(gid)) continue // task still running → keep, don't count
    const gidDir = path.join(WORKTREES_ROOT, gid)
    let repos
    try {
      if (!fs.statSync(gidDir).isDirectory()) continue
      repos = fs.readdirSync(gidDir)
    } catch { continue }
    for (const repo of repos) {
      const wt = path.join(gidDir, repo)
      try {
        const st = fs.statSync(wt)
        if (st.isDirectory()) retired.push({ gid, repo, mtimeMs: st.mtimeMs })
      } catch { /* skip unreadable */ }
    }
  }
  if (retired.length <= keep) {
    if (retired.length > 0) log(`Worktree retention: ${retired.length}/${keep} retained; none pruned`)
    return
  }
  retired.sort((a, b) => b.mtimeMs - a.mtimeMs) // newest first
  const toPrune = retired.slice(keep)
  log(`Worktree retention: ${retired.length} retired > cap ${keep} → pruning ${toPrune.length} oldest`)
  for (const w of toPrune) removeWorktree(w.gid, w.repo)
}

function main() {
  const sessions = listTargetSessions()
  if (sessions.length === 0) {
    // No live sessions, but still run the retention prune below (completed worktrees
    // linger after their sessions are gone and must be capped even when idle).
    log(`No ${SESSION_PREFIX}* tmux sessions found.`)
  } else {
    log(`Watching ${sessions.length} session(s): ${sessions.join(', ')}`)
  }

  const state = loadState()
  const now = Date.now()

  for (const session of sessions) {
    // Completion sweep: if Asana shows agent_status=Complete, kill the session.
    const taskGid = session.slice(SESSION_PREFIX.length)
    const agentStatus = fetchAgentStatus(taskGid)
    if (agentStatus === 'Complete') {
      log(`[${session}] Asana agent_status=Complete → killing session, freeing sim+slot, RETAINING worktree`)
      sh(`tmux kill-session -t "${session}"`)
      releaseSimAndSlot(taskGid)
      delete state.sessions[session]
      continue
    }

    const panePid = getPanePid(session)
    if (panePid === null) {
      log(`[${session}] could not read pane PID; skipping`)
      continue
    }

    if (!claudeRunningUnder(panePid)) {
      // Death-path auto-resume REMOVED (2026-05-28) — it was a memory-runaway vector.
      // Log and leave the session for manual / Asana-driven handling; do NOT spawn claude.
      log(`[${session}] claude not detected under pane (pid ${panePid}). NOT auto-resuming (death-path removed). Leaving for manual handling.`)
      delete state.sessions[session]
      continue
    }

    const content = capturePane(session)
    const prior = state.sessions[session]
    if (!prior || prior.lastContent !== content) {
      state.sessions[session] = { lastContent: content, lastChange: now }
    } else if (now - prior.lastChange > IDLE_THRESHOLD_MS) {
      attemptRcRevive(session)
      // Reset so we don't re-fire until the pane settles again
      state.sessions[session] = { lastContent: content, lastChange: now }
    }
  }

  // Enforce the worktree retention cap (keep newest N completed/retired worktrees).
  pruneRetainedWorktrees(sessions)

  // Garbage-collect state for sessions that no longer exist
  for (const key of Object.keys(state.sessions)) {
    if (!sessions.includes(key)) delete state.sessions[key]
  }

  saveState(state)
}

main()
