#!/usr/bin/env node
// session-watchdog.js — Watchdog tending live claude-asana-* tmux sessions.
// (Formerly rc-watchdog.js; renamed because it does more than RC.) Three jobs:
// RC-bridge revive, completion sweep (agent_status=Complete → teardown), and
// worktree-retention GC. RC revive is just one of them.
//
// Variants handled:
//  - Variant 1 (RC bridge dead, claude alive): the pane footer ("Remote Control active") is the source of truth. Absent + idle past IDLE_THRESHOLD_MS → revive (wake message, wait, `/remote-control`, then Esc to dismiss the modal). Present → do NOT ping at all (a half-open bridge is left for the operator to reconnect on next attach). Keystroke-only; never spawns a new claude.
//  - Completion sweep: if Asana agent_status is Complete for a session's task GID, RETIRE the session — rename claude-asana-<gid> → done-asana-<gid> and free the sim+Metro+slot, but leave claude alive so it stays attachable / re-engageable. Retired sessions no longer count toward the concurrency cap; the oldest beyond keep_completed_sessions are killed to bound memory.
//  - Blocked sweep: if a session's task has blocked=Yes, shed its heavy resources (sim + Metro) so it stops squatting while it waits on a human — but keep the session + slot alive so it can resume on unblock (done once, re-armed when unblocked).
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
const RC_ACTIVE_MARKER = 'Remote Control active'        // pane footer present iff the RC bridge is up (near-end view)
const RC_HALFOPEN_BACKSTOP_MS = 3 * 60 * 60 * 1000      // DISABLED 2026-06-05 (backstop removed to eval zero-ping-on-healthy); kept for easy revert
const SESSION_PREFIX = 'claude-asana-'
// Completed sessions are RENAMED to this prefix instead of being killed, so the
// watcher (which counts a slot only for `claude-asana-<digits>`) stops counting
// them — freeing capacity — while the session stays alive and attachable for
// inspection / remote re-engagement. pruneRetiredSessions() caps how many linger.
const RETIRED_PREFIX = 'done-asana-'
const WORKTREES_ROOT = path.join(HOME, 'git/.agent-worktrees')
const DEFAULT_KEEP_COMPLETED = 5
const DEFAULT_KEEP_COMPLETED_SESSIONS = 3

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
let _blockedFieldGid = null
function getBlockedFieldGid() {
  if (_blockedFieldGid !== null) return _blockedFieldGid
  try {
    const cfg = JSON.parse(fs.readFileSync(CFG_FILE, 'utf8'))
    _blockedFieldGid = cfg.custom_fields?.blocked?.gid || ''
  } catch { _blockedFieldGid = '' }
  return _blockedFieldGid
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
// How many retired (completed-but-kept-alive) sessions to keep before killing the
// oldest. Each holds a live claude, so this bounds memory.
let _keepCompletedSessions = null
function getKeepCompletedSessions() {
  if (_keepCompletedSessions !== null) return _keepCompletedSessions
  try {
    const cfg = JSON.parse(fs.readFileSync(CFG_FILE, 'utf8'))
    const n = cfg.watcher?.keep_completed_sessions
    _keepCompletedSessions = Number.isFinite(n) && n >= 0 ? n : DEFAULT_KEEP_COMPLETED_SESSIONS
  } catch { _keepCompletedSessions = DEFAULT_KEEP_COMPLETED_SESSIONS }
  return _keepCompletedSessions
}

// One fetch → both agent_status and blocked (both enum custom fields).
function fetchTaskState(taskGid) {
  const token = getAsanaToken()
  const statusGid = getStatusFieldGid()
  if (!token || !statusGid) return { agentStatus: null, blocked: null }
  const blockedGid = getBlockedFieldGid()
  const out = sh(`curl -sS -H "Authorization: Bearer ${token}" "https://app.asana.com/api/1.0/tasks/${taskGid}?opt_fields=custom_fields.gid,custom_fields.enum_value.name"`)
  if (!out) return { agentStatus: null, blocked: null }
  try {
    const parsed = JSON.parse(out)
    const cfs = parsed.data?.custom_fields || []
    const agentStatus = cfs.find((f) => f.gid === statusGid)?.enum_value?.name || null
    const blocked = blockedGid ? (cfs.find((f) => f.gid === blockedGid)?.enum_value?.name || null) : null
    return { agentStatus, blocked }
  } catch { return { agentStatus: null, blocked: null } }
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
  log(`[${session}] RC revive: wake ping + /remote-control + Esc-dismiss.`)
  sh(`tmux send-keys -t "${session}" "<watchdog-revive-ping>" Enter`)
  sh('sleep 8')
  sh(`tmux send-keys -t "${session}" "/remote-control" Enter`)
  // `/remote-control` opens a blocking modal (Continue / Esc). Left open it
  // intercepts ALL keystrokes and wedges the session input — prompts and pings
  // do nothing until dismissed, which is what made idle sessions look "hung".
  // Dismiss it with Escape ("continue": keeps RC active, just closes the modal)
  // so this revive probe can never leave the session stuck behind the dialog.
  sh('sleep 2')
  sh(`tmux send-keys -t "${session}" Escape`)
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

// Kill whatever is LISTENing on a Metro port. Slot Metro ports are reused by the
// next task on the same slot_index, so a retired session's lingering Metro would
// collide — free the port explicitly. The old hard-kill freed it by killing the
// whole session; we kill only Metro and keep claude alive (also sheds Metro's RAM,
// the heaviest process). No-op if nothing is bound.
function freeMetroPort(port) {
  if (!port) return
  const pids = sh(`lsof -ti tcp:${port} -sTCP:LISTEN`).split('\n').filter(Boolean)
  if (pids.length) {
    sh(`kill ${pids.join(' ')}`)
    log(`  [metro] freed port ${port} (killed Metro pid ${pids.join(',')})`)
  }
}

// Shed the heavy per-task resources (sim + Metro) WITHOUT freeing the slot or
// touching the tmux session. Used when a task is blocked (waiting on a human): it
// stops squatting on a booted sim and a Metro server while idle, but the session +
// slot stay so it can resume on unblock. NOTE: the sim returns to the pool and may
// be recycled, so a resumed task re-provisions its sim/Metro via build-and-test.
function freeSimAndMetro(taskGid) {
  let slot = null
  try { slot = slots.get(taskGid) } catch { /* slots.json unreadable */ }
  if (slot?.sim_udid) {
    log(`  [${taskGid}] releasing sim ${slot.sim_udid}`)
    sh(`"${DIR}/release-pool-entry.sh" --task-gid "${taskGid}"`)
  }
  freeMetroPort(slot?.metro_port ?? null)
}

// Reap orphan Metro bundlers: a Metro whose cwd is an .agent-worktrees/<gid> dir
// that no longer exists (the slot was torn down but its Metro lingered, squatting a
// port the next slot reuses → the "foreign Metro on my port" failures). Only kills
// Metros whose cwd is under the worktrees root AND gone; spares live-worktree Metros
// and any Metro outside the worktrees root (e.g. a manual one in ~/git/<repo>).
function reapOrphanMetros() {
  const out = sh('pgrep -fl "react-native.*start|node_modules/metro"')
  if (!out) return
  for (const line of out.split('\n').filter(Boolean)) {
    const pid = parseInt(line.trim().split(/\s+/)[0], 10)
    if (!Number.isFinite(pid)) continue
    const cwdRaw = sh(`lsof -a -p ${pid} -d cwd -Fn`).split('\n').map((s) => s.replace(/^n/, '')).filter(Boolean).pop() || ''
    const cwd = cwdRaw.replace(/ \(deleted\)$/, '')
    if (!cwd || !cwd.startsWith(WORKTREES_ROOT)) continue // only worktree Metros
    if (!fs.existsSync(cwd)) {
      sh(`kill ${pid}`)
      log(`[reaper] killed orphan Metro pid ${pid} (worktree gone: ${cwd})`)
    }
  }
}

// Full teardown of one retained worktree: remove the worktree + branch (and any
// lingering sim/slot, though those were freed at completion). Used only by the prune.
function removeWorktree(taskGid, repo) {
  log(`  [${taskGid}] pruning retained worktree (repo ${repo})`)
  try { const s = slots.get(taskGid); if (s?.sim_udid) sh(`"${DIR}/release-pool-entry.sh" --task-gid "${taskGid}"`) } catch { /* none */ }
  sh(`"${DIR}/cleanup-task-workspace.sh" --task-gid "${taskGid}" --repo "${repo}"`)
  try { slots.release(taskGid) } catch { /* already gone */ }
}

// Retired sessions (completed, renamed out of the slot-counted namespace, claude
// left alive so they stay attachable). Returned newest-first by tmux creation time.
function listRetiredSessions() {
  const out = sh('tmux list-sessions -F "#{session_name} #{session_created}"')
  if (!out) return []
  return out.split('\n').filter(Boolean)
    .map((line) => { const [name, created] = line.split(' '); return { name, gid: name.slice(RETIRED_PREFIX.length), created: parseInt(created, 10) || 0 } })
    .filter((s) => s.name.startsWith(RETIRED_PREFIX))
    .sort((a, b) => b.created - a.created)
}

// Un-retire sweep (symmetric to the completion sweep): a retired done-asana-<gid>
// session whose task is NO LONGER Complete means a human re-engaged a finished task
// for followup work (and, per one-shot's `followup-reopens-status`, the agent moved
// agent_status off Complete). Rename it BACK to claude-asana-<gid> so it re-occupies
// a concurrency slot — otherwise the followup runs off-the-books and the watcher can
// oversubscribe. Only for still-alive sessions with a real, non-Complete status; the
// session re-provisions its own sim/Metro as the work proceeds.
function unretireFollowups() {
  for (const r of listRetiredSessions()) {
    const { agentStatus } = fetchTaskState(r.gid)
    if (!agentStatus || agentStatus === 'Complete') continue
    const ppid = getPanePid(r.name)
    if (ppid === null || !claudeRunningUnder(ppid)) continue // only re-occupy for a live session
    const dest = `${SESSION_PREFIX}${r.gid}`
    if (sh(`tmux has-session -t "${dest}" 2>/dev/null && echo yes`) === 'yes') continue // a live slot already owns the name
    sh(`tmux rename-session -t "${r.name}" "${dest}"`)
    log(`[${r.name}] agent_status=${agentStatus} (followup on a completed task) → UN-RETIRED as ${dest}; re-occupies a slot`)
    // Re-reserve the resources this still-running session is ACTUALLY using, read
    // from its live env, so slots.json reflects reality and the watcher won't hand its
    // Metro port to another task. (ensure-sim-pool separately RECLAIMS the sim from
    // recycling once it's referenced by this now-active session.)
    const cpid = parseInt((sh(`pgrep -P ${ppid}`).split('\n')[0] || '').trim(), 10)
    if (Number.isFinite(cpid)) {
      const env = sh(`ps eww -p ${cpid}`)
      const simUdid = (env.match(/AGENT_SIM_UDID=([0-9A-Fa-f-]{36})/) || [])[1]
      const metroPort = parseInt((env.match(/AGENT_METRO_PORT=(\d+)/) || [])[1] || '', 10)
      if (simUdid) {
        try {
          slots.allocate({ task_gid: r.gid, worktree_path: path.join(WORKTREES_ROOT, r.gid), sim_udid: simUdid, metro_port: Number.isFinite(metroPort) ? metroPort : undefined })
          log(`  [${r.gid}] re-reserved slot (sim ${simUdid}, metro ${Number.isFinite(metroPort) ? metroPort : 'auto'})`)
        } catch (e) { log(`  [${r.gid}] re-reserve failed: ${e.message}`) }
      }
    }
  }
}

// Retire a completed session instead of killing it: rename it out of the
// slot-counted `claude-asana-<gid>` namespace (so the watcher stops counting it and
// can spawn the next task) while KEEPING the claude process alive — the session
// stays attachable and re-engageable via RC. Sim + slot are freed; worktree is
// retained. Old retirements are bounded by pruneRetiredSessions().
function retireSession(session, taskGid) {
  const dest = `${RETIRED_PREFIX}${taskGid}`
  // rename-session can't clobber; drop a prior retirement of the same task first.
  if (sh(`tmux has-session -t "${dest}" 2>/dev/null && echo yes`) === 'yes') {
    sh(`tmux kill-session -t "${dest}"`)
  }
  // Read the FULL slot BEFORE releasing it: the Metro port must be freed after the
  // slot release (next task on this slot_index reuses it), and the release receipt
  // needs the slot's identity after slots.json forgets it. claude stays alive.
  let slot = null
  try { slot = slots.get(taskGid) } catch { /* slots.json unreadable */ }
  const metroPort = slot?.metro_port ?? null
  sh(`tmux rename-session -t "${session}" "${dest}"`)
  releaseSimAndSlot(taskGid)
  freeMetroPort(metroPort)
  writeReleaseReceipt(taskGid, slot, metroPort)
  log(`[${session}] agent_status=Complete → RETIRED as ${dest} (claude kept alive; Metro+sim+slot freed; worktree retained)`)
}

// Durable release receipt: slots.json/pool.json forget a run seconds after retirement,
// so post-hoc evals (orch-eval O1/O6) cannot otherwise verify clean resource release.
// One small JSON per gid under STATE_DIR/releases; best-effort, never wedges the sweep.
function writeReleaseReceipt(taskGid, slot, metroPort) {
  try {
    const dir = path.join(slots.STATE_DIR, 'releases')
    fs.mkdirSync(dir, { recursive: true })
    fs.writeFileSync(path.join(dir, `${taskGid}.json`), JSON.stringify({
      gid: taskGid,
      retired_at: new Date().toISOString(),
      slot_index: slot?.slot_index ?? null,
      sim_udid: slot?.sim_udid ?? null,
      metro_port: metroPort,
      released: { sim: Boolean(slot?.sim_udid), slot: Boolean(slot), metro: metroPort != null },
    }, null, 2) + '\n')
    log(`  [${taskGid}] release receipt written`)
  } catch (e) { log(`  [${taskGid}] release receipt failed: ${e.message}`) }
}

// Cap retired sessions kept alive (each holds a live claude → memory bound). Keep
// the newest keep_completed_sessions; kill the older ones outright.
function pruneRetiredSessions() {
  const keep = getKeepCompletedSessions()
  const retired = listRetiredSessions()
  if (retired.length <= keep) {
    if (retired.length > 0) log(`Retired sessions: ${retired.length}/${keep} kept; none pruned`)
    return
  }
  const toPrune = retired.slice(keep) // oldest beyond the cap
  log(`Retired sessions: ${retired.length} > cap ${keep} → killing ${toPrune.length} oldest`)
  for (const s of toPrune) {
    sh(`tmux kill-session -t "${s.name}"`)
    log(`[${s.name}] retired beyond cap → killed`)
  }
}

// Enforce the retention cap. A worktree whose task still has a LIVE tmux session —
// including a RETIRED (kept-alive) one — is never touched (and does not count
// against the cap). Among the rest — "retired" worktrees: completed with the
// session already gone — keep the newest keep_completed_worktrees by directory
// mtime and prune the older ones.
function pruneRetainedWorktrees(liveSessions) {
  const keep = getKeepCompletedWorktrees()
  let gidDirs
  try { gidDirs = fs.readdirSync(WORKTREES_ROOT) } catch { return } // no worktrees root yet
  const activeGids = new Set([
    ...liveSessions.map((s) => s.slice(SESSION_PREFIX.length)),
    ...listRetiredSessions().map((s) => s.gid), // retired-but-alive sessions keep their worktree
  ])
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
    // Completion sweep: if Asana shows agent_status=Complete, retire the session.
    const taskGid = session.slice(SESSION_PREFIX.length)
    const { agentStatus, blocked } = fetchTaskState(taskGid)
    if (agentStatus === 'Complete') {
      // Retire (rename + keep claude alive), NOT hard-kill — so the session stays
      // attachable / re-engageable. Capacity is freed because the renamed session
      // no longer matches the slot-counted `claude-asana-<digits>` pattern.
      retireSession(session, taskGid)
      delete state.sessions[session]
      continue
    }

    if (agentStatus === 'Pending') {
      // Operator restart: Pending on a task that still has a live session is a
      // contradiction — Pending means "spawn fresh", and this session's existence
      // is exactly what blocks the watcher from doing so (name collision + cap).
      // Hard-kill (not retire: a fresh start wants the name freed), release
      // sim/slot/Metro, and remove the worktree so the respawn starts clean.
      log(`[${session}] agent_status=Pending with live session → operator restart; killing session and releasing resources`)
      let slot = null
      try { slot = slots.get(taskGid) } catch { /* slots.json unreadable */ }
      const metroPort = slot?.metro_port ?? null
      sh(`tmux kill-session -t "${session}"`)
      releaseSimAndSlot(taskGid)
      freeMetroPort(metroPort)
      const wtRepo = fs.existsSync(path.join(WORKTREES_ROOT, taskGid))
        ? (fs.readdirSync(path.join(WORKTREES_ROOT, taskGid))[0] || null) : null
      if (wtRepo) sh(`"${DIR}/cleanup-task-workspace.sh" --task-gid "${taskGid}" --repo "${wtRepo}"`)
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
    const rcUp = content.includes(RC_ACTIVE_MARKER)   // near-end belief about the RC bridge
    const prior = state.sessions[session]
    const isBlocked = /^yes$/i.test(blocked || '')

    // Blocked → shed heavy resources (sim + Metro) ONCE, but keep the session + slot
    // alive so a human can unblock and resume. `heavyFreed` prevents re-freeing every
    // tick; it's cleared automatically once the task is no longer blocked, so a later
    // block re-arms the cleanup.
    if (isBlocked && !prior?.heavyFreed) {
      log(`[${session}] blocked=Yes → freeing sim + Metro (session kept alive for unblock)`)
      freeSimAndMetro(taskGid)
    }

    const changed = !prior || prior.lastContent !== content
    let lastChange = changed ? now : prior.lastChange
    if (!changed && !rcUp && now - prior.lastChange > IDLE_THRESHOLD_MS) {
      // Pure indicator: revive ONLY when the pane reports the RC bridge is DOWN and
      // the session has been idle past the threshold. When the indicator says UP,
      // NEVER ping — a half-open bridge (indicator up but actually unreachable) is
      // left for the operator to reconnect on their next attach (the real ground-
      // truth test anyway). [Backstop re-register removed 2026-06-05 to evaluate
      // zero-ping-on-healthy; to revert, re-add an
      // `rcUp && idle > RC_HALFOPEN_BACKSTOP_MS` branch here.]
      const idle = now - prior.lastChange
      log(`[${session}] RC indicator ABSENT + idle ${Math.round(idle / 60000)}m → reviving.`)
      attemptRcRevive(session)
      lastChange = now // reset so we don't re-fire until the pane settles
    }
    state.sessions[session] = { lastContent: content, lastChange, heavyFreed: isBlocked }
  }

  // Un-retire any completed session a human re-engaged for followup (status moved off
  // Complete) so it re-occupies a slot. Runs BEFORE the retired-cap prune.
  unretireFollowups()

  // Cap retired (completed-but-kept-alive) sessions so they don't accumulate in memory.
  pruneRetiredSessions()

  // Kill Metro bundlers whose worktree was torn down (orphans squatting slot ports).
  reapOrphanMetros()

  // Enforce the worktree retention cap (keep newest N completed/retired worktrees).
  pruneRetainedWorktrees(sessions)

  // Garbage-collect state for sessions that no longer exist
  for (const key of Object.keys(state.sessions)) {
    if (!sessions.includes(key)) delete state.sessions[key]
  }

  saveState(state)
}

main()
