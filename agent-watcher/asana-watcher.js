#!/usr/bin/env node
// asana-watcher.js — Poll Asana for Pending agent tasks; spawn up to
// MAX_CONCURRENT parallel tmux sessions, each in its own git worktree, on its own
// cloned iOS simulator, on its own Metro port, behind a resource guardrail.
//
// Per-tick flow:
//   1. MAX_CONCURRENT     — config .watcher.max_concurrent (default 2);
//                           env override AGENT_WATCHER_MAX_CONCURRENT.
//   2. active             — count of LIVE `claude-asana-*` tmux sessions.
//   3. active >= MAX      → log "at cap (active=N max=M)", exit 0.
//   4. resource guardrail → 1-min load avg > max_load_avg OR free RAM < min_free_ram_gb
//                           → log "skipped this tick: guardrail (...)", exit 0.
//   5. fetch tasks; pick the oldest (MAX - active) Pending tasks.
//   6. per picked task: set Planning, setup worktree, clone sim, allocate slot, spawn.
//   7. slot allocations persisted to slots.json (via lib/slots.js).
//
// SLOT ACCOUNTING IS BY LIVE TMUX SESSIONS, NOT BY ASANA STATE. A task that is
// blocked or in-flight in Asana but whose tmux session has died does NOT hold a
// slot — that lane is free for a fresh spawn. slots.json is bookkeeping for
// teardown (which sim/worktree to reap); the concurrency cap is always enforced
// against the count of real live sessions.
//
// Usage:
//   asana-watcher.js                                 run for real (spawns sessions)
//   asana-watcher.js --dry-run                       log decisions; no spawn, no Asana mutation
//   asana-watcher.js --dry-run --simulate-pending 3 [--simulate-active 0]
//                                                    fabricate Pending tasks to test the cap logic
//
// Reads:
//   ~/.config/agent-watcher/credentials.json   (ASANA_TOKEN)
//   ~/.config/agent-watcher/asana-config.json  (project + custom field GIDs + .watcher.*)

const fs = require('node:fs')
const path = require('node:path')
const { execSync, spawnSync } = require('node:child_process')
const api = require('./asana-api.js')
const slots = require('./lib/slots.js')

const HOME = process.env.HOME || ''
const DIR = path.join(HOME, '.config/agent-watcher')
const CONFIG_PATH = path.join(DIR, 'asana-config.json')
const SESSION_PREFIX = 'claude-asana-'
const RC_READY_MARKER = 'Remote Control active'
const BYPASS_PROMPT_MARKER = 'Yes, I accept'
const RC_READY_TIMEOUT_MS = 60 * 1000
const RC_READY_POLL_MS = 1000

const DRY_RUN = process.argv.includes('--dry-run')

function log(msg) {
  const ts = new Date().toISOString()
  const tag = DRY_RUN ? '[DRY] ' : ''
  console.log(`[${ts}] ${tag}${msg}`)
}

function sh(cmd) {
  try {
    return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  } catch {
    return ''
  }
}

function argInt(flag) {
  const i = process.argv.indexOf(flag)
  if (i === -1) return null
  const v = parseInt(process.argv[i + 1], 10)
  return Number.isFinite(v) ? v : null
}

function loadConfig() {
  return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'))
}

// ─── Concurrency cap + guardrail ───────────────────────────────────────────────

function maxConcurrent(cfg) {
  const env = parseInt(process.env.AGENT_WATCHER_MAX_CONCURRENT || '', 10)
  if (Number.isFinite(env) && env > 0) return env
  return cfg.watcher?.max_concurrent || 2
}

function guardrailThresholds(cfg) {
  const g = cfg.watcher?.resource_guardrail || {}
  const envLoad = parseFloat(process.env.AGENT_WATCHER_MAX_LOAD_AVG || '')
  const envFree = parseFloat(process.env.AGENT_WATCHER_MIN_FREE_RAM_GB || '')
  return {
    maxLoad: Number.isFinite(envLoad) ? envLoad : (g.max_load_avg ?? 12.0),
    minFree: Number.isFinite(envFree) ? envFree : (g.min_free_ram_gb ?? 4.0),
  }
}

function countActiveSessions() {
  const out = sh('tmux list-sessions -F "#{session_name}"')
  if (!out) return 0
  return out.split('\n').filter((s) => s.startsWith(SESSION_PREFIX)).length
}

function getLoadAvg() {
  const m = sh('uptime').match(/load averages?:\s+([\d.]+)/i)
  return m ? parseFloat(m[1]) : 0
}

function getFreeRamGb() {
  const out = sh('vm_stat')
  if (!out) return Infinity // can't read → don't gate on RAM
  const pageM = out.match(/page size of (\d+) bytes/)
  const pageSize = pageM ? parseInt(pageM[1], 10) : 16384
  const pages = (label) => {
    const m = out.match(new RegExp(`${label}:\\s+(\\d+)`))
    return m ? parseInt(m[1], 10) : 0
  }
  // "Available" ≈ free + speculative + inactive (inactive is reclaimable).
  const bytes = (pages('Pages free') + pages('Pages speculative') + pages('Pages inactive')) * pageSize
  return bytes / 1024 ** 3
}

// ─── Asana ─────────────────────────────────────────────────────────────────────

function listAgentTasks(cfg) {
  const optFields = 'name,custom_fields.gid,custom_fields.name,custom_fields.enum_value.name,created_at'
  return api.listProjectTasks(cfg.project_gid, optFields)
}

function getAgentStatus(task, cfg) {
  const field = task.custom_fields?.find((f) => f.gid === cfg.custom_fields.agent_status.gid)
  return field?.enum_value?.name || null
}

function setStatusPlanning(taskGid) {
  log(`  setting task ${taskGid} agent_status=Planning`)
  if (DRY_RUN) return
  execSync(`${DIR}/update-status.sh ${taskGid} Planning`, { stdio: 'inherit' })
}

// ─── tmux / spawn ───────────────────────────────────────────────────────────────

function tmuxSessionExists(name) {
  return sh(`tmux has-session -t "${name}" 2>/dev/null && echo yes`) === 'yes'
}

function shCapture(cmd) {
  // Run a helper that prints status to stderr (shown live) and its result to stdout (captured).
  return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] }).trim()
}

function waitRcReadyAndSendPrompt(sessionName, prompt) {
  const deadline = Date.now() + RC_READY_TIMEOUT_MS
  let ready = false
  let acceptedBypass = false
  while (Date.now() < deadline) {
    const pane = sh(`tmux capture-pane -t "${sessionName}" -p`)
    if (pane.includes(RC_READY_MARKER)) { ready = true; break }
    if (!acceptedBypass && pane.includes(BYPASS_PROMPT_MARKER)) {
      log(`  bypass-permissions dialog detected; auto-accepting (Down + Enter)`)
      execSync(`tmux send-keys -t "${sessionName}" Down`, { stdio: 'inherit' })
      execSync('sleep 0.3')
      execSync(`tmux send-keys -t "${sessionName}" Enter`, { stdio: 'inherit' })
      acceptedBypass = true
    }
    execSync(`sleep ${RC_READY_POLL_MS / 1000}`)
  }
  if (!ready) log(`  WARNING: RC ready marker not seen after ${RC_READY_TIMEOUT_MS}ms; sending prompt anyway`)

  // Send text then Enter separately — a single send-keys sometimes drops the Enter.
  execSync(`tmux send-keys -t "${sessionName}" ${JSON.stringify(prompt)}`, { stdio: 'inherit' })
  execSync('sleep 1')
  execSync(`tmux send-keys -t "${sessionName}" Enter`, { stdio: 'inherit' })
  log(`  prompt sent: ${prompt}`)
}

// Full per-task spawn: Planning → worktree → sim clone → slot allocate → tmux session.
function spawnForTask(task, cfg) {
  const sessionName = `${SESSION_PREFIX}${task.gid}`
  const repo = cfg.watcher?.default_repo || 'edge-react-gui'
  const label = `Asana: ${task.name}`.slice(0, 120)
  const taskUrl = `https://app.asana.com/0/${cfg.project_gid}/${task.gid}`

  log(`Spawning slot for: ${task.name} (gid=${task.gid}, repo=${repo})`)

  if (tmuxSessionExists(sessionName)) {
    log(`  session ${sessionName} already exists — refusing to spawn over it. Skipping.`)
    return false
  }

  if (DRY_RUN) {
    log(`  (dry-run) would: Planning → setup-task-workspace → clone-ios-sim → allocate slot → spawn`)
    log(`  (dry-run) would send-keys: /one-shot --yolo ${taskUrl}`)
    return true
  }

  setStatusPlanning(task.gid)

  let worktreePath
  try {
    worktreePath = shCapture(`${DIR}/setup-task-workspace.sh --task-gid ${task.gid} --repo ${repo}`).split('\n').pop()
  } catch (e) {
    log(`  setup-task-workspace failed (${e.status ?? '?'}) — skipping spawn for ${task.gid}`)
    return false
  }

  let simUdid
  try {
    simUdid = shCapture(`${DIR}/allocate-from-pool.sh --task-gid ${task.gid}`).split('\n').pop()
  } catch (e) {
    log(`  allocate-from-pool failed (${e.status ?? '?'}) — skipping spawn for ${task.gid}`)
    return false
  }

  const slot = slots.allocate({ task_gid: task.gid, worktree_path: worktreePath, sim_udid: simUdid })
  log(`  slot ${slot.slot_index}: metro ${slot.metro_port}, sim ${simUdid}`)

  const r = spawnSync(`${DIR}/spawn-test-session.sh`, [
    '--yolo',
    '--slot-index', String(slot.slot_index),
    '--task-gid', task.gid,
    '--sim-udid', simUdid,
    '--metro-port', String(slot.metro_port),
    '--worktree-path', worktreePath,
    '--label', label,
  ], { stdio: 'inherit' })
  if (r.status !== 0) {
    log(`  spawn helper failed with exit code ${r.status}`)
    return false
  }

  waitRcReadyAndSendPrompt(sessionName, `/one-shot --yolo ${taskUrl}`)
  return true
}

// ─── Main ────────────────────────────────────────────────────────────────────

function main() {
  const cfg = loadConfig()
  const MAX = maxConcurrent(cfg)
  log(`Watcher tick — project: ${cfg.project_name} (${cfg.project_gid}), max_concurrent=${MAX}`)

  const simulatePending = argInt('--simulate-pending')
  const simulating = simulatePending != null
  if (simulating && !DRY_RUN) {
    log('--simulate-pending requires --dry-run (refusing to spawn against fake tasks)')
    return
  }

  // Step 2: active = live claude-asana-* sessions (or simulated).
  const active = simulating ? (argInt('--simulate-active') ?? 0) : countActiveSessions()
  log(`Active sessions: ${active}`)

  // Step 3: at cap.
  if (active >= MAX) {
    log(`at cap (active=${active} max=${MAX}) — nothing to spawn this tick`)
    return
  }

  // Step 4: resource guardrail.
  const { maxLoad, minFree } = guardrailThresholds(cfg)
  const load = getLoadAvg()
  const freeGb = getFreeRamGb()
  if (load > maxLoad || freeGb < minFree) {
    log(`skipped this tick: guardrail (load=${load.toFixed(2)} max=${maxLoad}, free=${freeGb.toFixed(1)}GB min=${minFree}GB)`)
    return
  }
  log(`guardrail ok (load=${load.toFixed(2)}/${maxLoad}, free=${freeGb.toFixed(1)}GB/${minFree}GB)`)

  const available = MAX - active

  // Step 5: gather + sort Pending tasks (oldest first).
  let pending
  if (simulating) {
    pending = Array.from({ length: simulatePending }, (_, i) => ({
      gid: `SIM${i + 1}`,
      name: `Simulated pending task ${i + 1}`,
      created_at: new Date(Date.now() + i * 1000).toISOString(),
    }))
  } else {
    const tasks = listAgentTasks(cfg)
    log(`Fetched ${tasks.length} task(s) from project`)
    pending = tasks.filter((t) => getAgentStatus(t, cfg) === 'Pending')
  }
  pending.sort((a, b) => (a.created_at || '').localeCompare(b.created_at || ''))

  if (pending.length === 0) {
    log('No Pending tasks. Nothing to do.')
    return
  }

  const toSpawn = pending.slice(0, available)
  const deferred = pending.slice(available)
  log(`Pending=${pending.length}, free slots=${available} → spawning ${toSpawn.length}, deferring ${deferred.length}`)

  // Ensure the iOS-sim pool has enough free entries to cover all spawns this
  // tick. Any dirty entries from prior reaps are refreshed here (delete stale
  // sim + clone fresh). This is the only place where simctl clone runs;
  // per-task allocation below is instant.
  if (toSpawn.length > 0 && !DRY_RUN) {
    const poolSize = cfg.watcher?.sim_pool?.size || MAX
    log(`Ensuring iOS sim pool (size=${poolSize})…`)
    const r = spawnSync(`${DIR}/ensure-sim-pool.sh`, ['--size', String(poolSize)], { stdio: 'inherit' })
    if (r.status !== 0) {
      log(`ensure-sim-pool failed (exit ${r.status}) — skipping spawns this tick`)
      return
    }
  }

  // Step 6 + 7: spawn each picked task (slot persisted inside spawnForTask).
  for (const task of toSpawn) spawnForTask(task, cfg)

  // Anything beyond the cap waits for a future tick.
  for (const task of deferred) {
    log(`skipped: at cap (max=${MAX} would be exceeded) — "${task.name}" (gid=${task.gid}) deferred to a later tick`)
  }
}

main()
