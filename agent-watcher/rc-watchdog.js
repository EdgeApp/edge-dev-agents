#!/usr/bin/env node
// rc-watchdog.js — Watchdog for claude-asana-* tmux sessions.
//
// Variants handled:
//  - Variant 2 (process death): claude descendant of pane PID missing → send `claude --resume` into the pane.
//  - Variant 1 (RC bridge dead, claude alive): heuristic — pane content unchanged for IDLE_THRESHOLD_MS → send a wake message, wait, then `/remote-control`.
//  - Completion sweep: if Asana agent_status is Complete for a session's task GID, kill the tmux session to free resources.
//
// Spawn pattern this watchdog expects:
//   tmux new-session -d -s "claude-asana-<id>" \
//     "bash -c 'cd ~/git && claude --rc \"<prompt>\" ; echo \"[claude exited at $(date)]\" ; exec bash'"
// The `exec bash` keeps the pane alive after claude exits so we can re-launch claude in it.

const { execSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const slots = require('./lib/slots.js')

const HOME = process.env.HOME || ''
const DIR = path.join(HOME, '.config/agent-watcher')
const STATE_FILE = path.join(HOME, '.config/agent-watcher/watchdog-state.json')
const CRED_FILE = path.join(HOME, '.config/agent-watcher/credentials.json')
const CFG_FILE = path.join(HOME, '.config/agent-watcher/asana-config.json')
const IDLE_THRESHOLD_MS = 20 * 60 * 1000
const SESSION_PREFIX = 'claude-asana-'

// Cache: token + status field GID read once per process run.
let _token = null
let _statusFieldGid = null
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

// Recursively check whether any descendant of `pid` has a comm matching /claude/.
function claudeRunningUnder(pid, depth = 4) {
  if (depth <= 0) return false
  const childOut = sh(`pgrep -P ${pid}`)
  if (!childOut) return false
  const children = childOut.split('\n').filter(Boolean).map((s) => parseInt(s, 10))
  for (const child of children) {
    const comm = sh(`ps -o comm= -p ${child}`)
    if (/(^|\/)claude($|\s)/.test(comm)) return true
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

function attemptResume(session) {
  log(`[${session}] Variant 2: claude not found under pane. Sending 'claude --resume'.`)
  // Ensure we're at a clean prompt: send Enter first to clear any partial input
  sh(`tmux send-keys -t "${session}" Enter`)
  sh(`tmux send-keys -t "${session}" "claude --resume" Enter`)
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

// Completion teardown: delete the slot's cloned sim, remove its worktree + branch,
// and drop the slot record so the lane frees up. Sim deletion and worktree removal
// are delegated to the shared helpers (delete-ios-sim.sh, cleanup-task-workspace.sh)
// rather than inlined here — DRY. Best-effort throughout; a partial failure must
// not wedge the sweep.
function teardownSlot(taskGid) {
  let slot = null
  try { slot = slots.get(taskGid) } catch { /* slots.json unreadable → nothing to reap */ }
  if (!slot) {
    log(`  [${taskGid}] no slot record — nothing to reap`)
    return
  }
  if (slot.sim_udid) {
    log(`  [${taskGid}] deleting sim ${slot.sim_udid}`)
    sh(`"${DIR}/delete-ios-sim.sh" --udid "${slot.sim_udid}"`)
  }
  if (slot.worktree_path) {
    const repo = path.basename(slot.worktree_path)
    log(`  [${taskGid}] removing worktree ${slot.worktree_path} (repo ${repo})`)
    sh(`"${DIR}/cleanup-task-workspace.sh" --task-gid "${taskGid}" --repo "${repo}"`)
  }
  try { slots.release(taskGid); log(`  [${taskGid}] slot reaped`) }
  catch (e) { log(`  [${taskGid}] slot release failed: ${e.message}`) }
}

function main() {
  const sessions = listTargetSessions()
  if (sessions.length === 0) {
    log(`No ${SESSION_PREFIX}* tmux sessions found.`)
    return
  }
  log(`Watching ${sessions.length} session(s): ${sessions.join(', ')}`)

  const state = loadState()
  const now = Date.now()

  for (const session of sessions) {
    // Completion sweep: if Asana shows agent_status=Complete, kill the session.
    const taskGid = session.slice(SESSION_PREFIX.length)
    const agentStatus = fetchAgentStatus(taskGid)
    if (agentStatus === 'Complete') {
      log(`[${session}] Asana agent_status=Complete → killing session + reaping slot`)
      sh(`tmux kill-session -t "${session}"`)
      teardownSlot(taskGid)
      delete state.sessions[session]
      continue
    }

    const panePid = getPanePid(session)
    if (panePid === null) {
      log(`[${session}] could not read pane PID; skipping`)
      continue
    }

    if (!claudeRunningUnder(panePid)) {
      attemptResume(session)
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

  // Garbage-collect state for sessions that no longer exist
  for (const key of Object.keys(state.sessions)) {
    if (!sessions.includes(key)) delete state.sessions[key]
  }

  saveState(state)
}

main()
