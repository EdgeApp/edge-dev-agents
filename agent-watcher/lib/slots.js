#!/usr/bin/env node
// lib/slots.js — Slot allocator for parallel agent sessions.
//
// A "slot" is one parallel agent lane. Each slot owns a worktree, a cloned iOS
// simulator, and a Metro port. Slot accounting is persisted to slots.json so the
// watcher (allocator), the watchdog (reaper), resume-agent, and gc-worktrees all
// agree on what's live.
//
// State file: ${XDG_STATE_HOME:-~/.local/state}/agent-watcher/slots.json
//   { "slots": [ { slot_index, task_gid, worktree_path, sim_udid, metro_port, spawned_at }, ... ] }
//
// Concurrency contract (smoke check D5): every read-modify-write goes through
// withLock() — an exclusive lock file acquired via O_CREAT|O_EXCL with a spin +
// stale-lock steal — and every write is atomic (tmpfile in the same dir + rename).
// Two concurrent writers therefore serialize and can never produce a torn file.
//
// Used as a library (require) by asana-watcher.js / session-watchdog.js, AND as a CLI
// by the shell helpers (setup/cleanup/gc/resume):
//   node lib/slots.js list
//   node lib/slots.js get        --task-gid <gid>
//   node lib/slots.js allocate   --task-gid <gid> --worktree-path <p> --sim-udid <u> [--metro-port <n>]
//   node lib/slots.js release    --task-gid <gid>
//   node lib/slots.js metro-port --slot-index <n>
//
// Exit codes (CLI): 0 = ok, 1 = runtime error, 2 = usage error.

'use strict'

const fs = require('node:fs')
const path = require('node:path')

const HOME = process.env.HOME || ''
const DIR = path.join(HOME, '.config/agent-watcher')
// Machine-local state lives under XDG state (not the committed config dir).
const STATE_DIR = process.env.XDG_STATE_HOME
  ? path.join(process.env.XDG_STATE_HOME, 'agent-watcher')
  : path.join(HOME, '.local/state/agent-watcher')
const SLOTS_PATH = process.env.AGENT_SLOTS_PATH || path.join(STATE_DIR, 'slots.json')
const LOCK_PATH = `${SLOTS_PATH}.lock`
const METRO_BASE_PORT = parseInt(process.env.AGENT_METRO_BASE_PORT || '8081', 10)
const LOCK_TIMEOUT_MS = 10_000
const LOCK_STALE_MS = 30_000

function sleepSync(ms) {
  // Block without spinning the CPU and without async — Atomics.wait on a throwaway buffer.
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

function acquireLock() {
  const start = Date.now()
  for (;;) {
    try {
      const fd = fs.openSync(LOCK_PATH, 'wx') // exclusive create — throws EEXIST if held
      fs.writeSync(fd, `${process.pid} ${new Date().toISOString()}`)
      fs.closeSync(fd)
      return
    } catch (e) {
      if (e.code !== 'EEXIST') throw e
      // Lock is held. Steal it if it's stale (holder probably died mid-write).
      try {
        const st = fs.statSync(LOCK_PATH)
        if (Date.now() - st.mtimeMs > LOCK_STALE_MS) {
          fs.unlinkSync(LOCK_PATH)
          continue
        }
      } catch {
        // lock vanished between EEXIST and stat — retry immediately
        continue
      }
      if (Date.now() - start > LOCK_TIMEOUT_MS) {
        throw new Error(`slots: could not acquire ${LOCK_PATH} within ${LOCK_TIMEOUT_MS}ms`)
      }
      sleepSync(25)
    }
  }
}

function releaseLock() {
  try { fs.unlinkSync(LOCK_PATH) } catch { /* already gone — fine */ }
}

function readSlotsRaw() {
  try {
    const parsed = JSON.parse(fs.readFileSync(SLOTS_PATH, 'utf8'))
    if (parsed && Array.isArray(parsed.slots)) return parsed
  } catch { /* missing or corrupt → start clean */ }
  return { slots: [] }
}

function writeSlotsAtomic(state) {
  fs.mkdirSync(path.dirname(SLOTS_PATH), { recursive: true })
  const tmp = `${SLOTS_PATH}.tmp.${process.pid}.${Math.random().toString(36).slice(2)}`
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n')
  fs.renameSync(tmp, SLOTS_PATH) // atomic on the same filesystem
}

function withLock(fn) {
  acquireLock()
  try {
    return fn()
  } finally {
    releaseLock()
  }
}

// ─── Public API ──────────────────────────────────────────────────────────────

function list() {
  return readSlotsRaw().slots
}

function get(taskGid) {
  return readSlotsRaw().slots.find((s) => s.task_gid === taskGid) || null
}

function metroPortForIndex(slotIndex) {
  return METRO_BASE_PORT + slotIndex
}

// Lowest non-negative integer not already in use.
function firstFreeIndex(slots) {
  const used = new Set(slots.map((s) => s.slot_index))
  let i = 0
  while (used.has(i)) i++
  return i
}

// Idempotent: re-allocating an existing task_gid returns its current slot unchanged.
function allocate({ task_gid, worktree_path, sim_udid, metro_port }) {
  if (!task_gid) throw new Error('allocate: task_gid is required')
  return withLock(() => {
    const state = readSlotsRaw()
    const existing = state.slots.find((s) => s.task_gid === task_gid)
    if (existing) return existing
    const slotIndex = firstFreeIndex(state.slots)
    const entry = {
      slot_index: slotIndex,
      task_gid,
      worktree_path: worktree_path || null,
      sim_udid: sim_udid || null,
      metro_port: metro_port != null ? metro_port : metroPortForIndex(slotIndex),
      spawned_at: new Date().toISOString(),
    }
    state.slots.push(entry)
    state.slots.sort((a, b) => a.slot_index - b.slot_index)
    writeSlotsAtomic(state)
    return entry
  })
}

// Idempotent: releasing an unknown task_gid is a no-op. Returns the removed entry or null.
function release(taskGid) {
  if (!taskGid) throw new Error('release: task_gid is required')
  return withLock(() => {
    const state = readSlotsRaw()
    const idx = state.slots.findIndex((s) => s.task_gid === taskGid)
    if (idx === -1) return null
    const [removed] = state.slots.splice(idx, 1)
    writeSlotsAtomic(state)
    return removed
  })
}

module.exports = { list, get, allocate, release, metroPortForIndex, SLOTS_PATH, STATE_DIR }

// ─── CLI ─────────────────────────────────────────────────────────────────────

function parseFlags(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a.startsWith('--')) out[a.slice(2)] = argv[++i]
  }
  return out
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2)
  const f = parseFlags(rest)
  switch (cmd) {
    case 'list':
      process.stdout.write(JSON.stringify(list(), null, 2) + '\n')
      return 0
    case 'get': {
      if (!f['task-gid']) { console.error('get: --task-gid required'); return 2 }
      const e = get(f['task-gid'])
      process.stdout.write((e ? JSON.stringify(e, null, 2) : '') + '\n')
      return e ? 0 : 0
    }
    case 'allocate': {
      if (!f['task-gid']) { console.error('allocate: --task-gid required'); return 2 }
      const e = allocate({
        task_gid: f['task-gid'],
        worktree_path: f['worktree-path'],
        sim_udid: f['sim-udid'],
        metro_port: f['metro-port'] != null ? parseInt(f['metro-port'], 10) : undefined,
      })
      process.stdout.write(JSON.stringify(e, null, 2) + '\n')
      return 0
    }
    case 'release': {
      if (!f['task-gid']) { console.error('release: --task-gid required'); return 2 }
      const e = release(f['task-gid'])
      process.stdout.write((e ? JSON.stringify(e, null, 2) : '') + '\n')
      return 0
    }
    case 'metro-port': {
      if (f['slot-index'] == null) { console.error('metro-port: --slot-index required'); return 2 }
      process.stdout.write(metroPortForIndex(parseInt(f['slot-index'], 10)) + '\n')
      return 0
    }
    default:
      console.error('usage: slots.js <list|get|allocate|release|metro-port> [flags]')
      return 2
  }
}

if (require.main === module) {
  try {
    process.exit(main())
  } catch (e) {
    console.error(`slots: ${e.message}`)
    process.exit(1)
  }
}
