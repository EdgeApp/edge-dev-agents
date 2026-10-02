#!/usr/bin/env node
// maestro-mcp-lazy.js -- stdio MCP proxy that runs the maestro MCP JVM only
// while a session is driving with it.
//
// Every orch claude is launched with maestro-mcp.json, and most sessions never
// call a maestro tool (land, review and Task runs; iOS runs that drive on the
// XCUITest interpreter). The JVM costs ~160 MB idle and ~1.3 GB with its iOS
// driver up (JVM + xcodebuild + the driver runner app on the sim). This proxy
// answers the MCP handshake and tools/list from a cache, starts the JVM on the
// first real call, and stops it (with its driver) after MAESTRO_MCP_IDLE_SECS
// without a call. The next call starts it again, which also re-pins the device.
//
// Usage: maestro-mcp-lazy.js <maestro args...>   (argv is passed to maestro
// unchanged, so `--device <id>` stays visible in this process's command line
// for the watchdog's Android "attended" check)
//
// Cache: ~/.cache/agent-watcher/maestro-mcp-handshake.json, keyed by the
// maestro install's lib mtime. Missing or stale: the JVM starts at once (the
// old behavior) and its initialize and tools/list answers refill the cache.
//
// A JVM that exits under the proxy (xcuitest-run.sh stops it before an
// interpreter run, the watchdog at retirement) fails the calls in flight with a
// JSON-RPC error; the proxy stays up and the next call starts a fresh JVM.
//
// Env: MAESTRO_BIN (default ~/.maestro/bin/maestro), MAESTRO_MCP_IDLE_SECS
// (default 600; 0 never stops the JVM), MAESTRO_MCP_CACHE (cache path),
// AGENT_SIM_UDID (the sim whose driver app is terminated on stop).
'use strict'
const { spawn, execFileSync } = require('child_process')
const fs = require('fs')
const os = require('os')
const path = require('path')

const BIN = process.env.MAESTRO_BIN || path.join(os.homedir(), '.maestro/bin/maestro')
const IDLE_MS = 1000 * Number(process.env.MAESTRO_MCP_IDLE_SECS ?? 600)
const CACHE = process.env.MAESTRO_MCP_CACHE || path.join(os.homedir(), '.cache/agent-watcher/maestro-mcp-handshake.json')
const DRIVER_APP = 'dev.mobile.maestro-driver-iosUITests.xctrunner'
const ARGS = process.argv.slice(2)
const INIT_ID = '__lazy_init__'

const log = (m) => process.stderr.write(`maestro-mcp-lazy: ${m}\n`)
const send = (m) => process.stdout.write(JSON.stringify(m) + '\n')

function installKey() {
  try { return String(fs.statSync(path.join(path.dirname(BIN), '../lib')).mtimeMs) } catch { /* no lib dir */ }
  try { return String(fs.statSync(BIN).mtimeMs) } catch { return '' }
}
const KEY = installKey()
let cache = null
try {
  const c = JSON.parse(fs.readFileSync(CACHE, 'utf8'))
  if (c.key === KEY && c.initialize && c.tools) cache = c
} catch { /* no cache yet */ }
const fresh = { key: KEY } // filled from the JVM's own answers when the cache is missing

let child = null
let ready = false // the running JVM answered initialize
let handshaken = false // the client has its initialize result (from the cache or the first JVM)
let queue = [] // client messages held until the JVM is ready
let clientInit = null // the client's initialize request, replayed to each later JVM
let clientInitialized = null
const captureIds = {} // request id -> 'initialize' | 'tools', answers to store in the cache
const pending = new Set() // client request ids the JVM has not answered
let idleTimer = null

function touch() {
  clearTimeout(idleTimer)
  if (!IDLE_MS) return
  idleTimer = setTimeout(() => {
    if (!child) return
    if (pending.size) return touch()
    log(`no call for ${IDLE_MS / 1000}s, stopping the JVM`)
    stopChild()
  }, IDLE_MS)
}

function descendants(pid, depth = 4) {
  if (depth <= 0) return []
  let out = ''
  try { out = execFileSync('pgrep', ['-P', String(pid)], { encoding: 'utf8' }) } catch { return [] }
  const kids = out.split('\n').map((x) => parseInt(x, 10)).filter(Number.isFinite)
  return kids.concat(...kids.map((k) => descendants(k, depth - 1)))
}

function stopChild() {
  const c = child
  if (!c) return
  child = null
  ready = false
  const pids = [c.pid, ...descendants(c.pid)]
  for (const pid of pids) { try { process.kill(pid, 'SIGTERM') } catch { /* gone */ } }
  setTimeout(() => { for (const pid of pids) { try { process.kill(pid, 'SIGKILL') } catch { /* gone */ } } }, 2000).unref()
  const udid = process.env.AGENT_SIM_UDID
  if (udid) spawn('xcrun', ['simctl', 'terminate', udid, DRIVER_APP], { stdio: 'ignore', detached: true }).on('error', () => {}).unref()
}

function toChild(m) {
  if (m.id !== undefined && m.method) pending.add(m.id)
  child.stdin.write(JSON.stringify(m) + '\n')
}

function onChildLine(line) {
  let m
  try { m = JSON.parse(line) } catch { return log(`server: ${line}`) } // the JVM's logging banner; stdout carries JSON-RPC only
  const isResponse = m.id !== undefined && !m.method
  if (isResponse && m.id === INIT_ID) {
    ready = true
    if (clientInitialized) toChild(clientInitialized)
    for (const q of queue.splice(0)) toChild(q)
    return
  }
  if (isResponse) {
    pending.delete(m.id)
    touch()
    const kind = captureIds[m.id]
    if (kind && m.result) {
      delete captureIds[m.id]
      fresh[kind] = m.result
      if (kind === 'initialize') { ready = true; handshaken = true }
      if (fresh.initialize && fresh.tools) {
        try {
          fs.mkdirSync(path.dirname(CACHE), { recursive: true })
          fs.writeFileSync(CACHE + '.' + process.pid, JSON.stringify(fresh))
          fs.renameSync(CACHE + '.' + process.pid, CACHE)
          cache = fresh
        } catch (e) { log(`cache write failed: ${e.message}`) }
      }
    }
  }
  send(m)
}

function startChild() {
  child = spawn(BIN, ARGS, { stdio: ['pipe', 'pipe', 'inherit'] })
  const c = child
  log(`started the JVM (pid ${c.pid})`)
  let buf = ''
  c.stdout.on('data', (d) => {
    buf += d
    let i
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i)
      buf = buf.slice(i + 1)
      if (line.trim()) onChildLine(line)
    }
  })
  c.stdin.on('error', () => {})
  c.on('error', (e) => { log(`cannot start ${BIN}: ${e.message}`); process.exit(1) })
  c.on('exit', (code, sig) => {
    if (child === c) { child = null; ready = false }
    if (!handshaken) process.exit(code ?? 1) // the client never got a handshake: nothing to serve
    for (const id of pending) send({ jsonrpc: '2.0', id, error: { code: -32000, message: `maestro MCP server exited (${sig || code}); retry the call to start a new one` } })
    pending.clear()
    queue = []
  })
  // The client already has its handshake, so this JVM gets a private
  // initialize whose answer is swallowed.
  if (handshaken) c.stdin.write(JSON.stringify({ ...clientInit, id: INIT_ID }) + '\n')
  touch()
}

function forward(m) {
  touch()
  if (!child) startChild()
  if (ready || !handshaken) return toChild(m) // before the first handshake the JVM sees the client's messages in order
  if (m.id !== undefined) pending.add(m.id)
  queue.push(m)
}

function onClient(m) {
  if (m.method === 'initialize') {
    clientInit = m
    if (cache) {
      handshaken = true
      if (child && !ready) child.stdin.write(JSON.stringify({ ...m, id: INIT_ID }) + '\n')
      return send({ jsonrpc: '2.0', id: m.id, result: cache.initialize })
    }
    captureIds[m.id] = 'initialize'
    return forward(m)
  }
  // A client probing for a newer protocol sends another request before
  // initialize. The JVM refuses those, so the proxy refuses them itself.
  if (!handshaken && cache && !child && m.id !== undefined) {
    return send({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: `Server does not support ${m.method}` } })
  }
  if (m.method === 'notifications/initialized') {
    clientInitialized = m
    if (child) toChild(m)
    return
  }
  if (m.method === 'tools/list' && !child && cache) return send({ jsonrpc: '2.0', id: m.id, result: cache.tools })
  if (m.method === 'tools/list' && !cache) captureIds[m.id] = 'tools'
  if (m.method === 'ping' && !child) return send({ jsonrpc: '2.0', id: m.id, result: {} })
  if (m.id === undefined && !child) return // a notification with no JVM to hear it
  forward(m)
}

let inBuf = ''
process.stdin.on('data', (d) => {
  inBuf += d
  let i
  while ((i = inBuf.indexOf('\n')) >= 0) {
    const line = inBuf.slice(0, i)
    inBuf = inBuf.slice(i + 1)
    if (!line.trim()) continue
    try { onClient(JSON.parse(line)) } catch (e) { log(`bad client message: ${e.message}`) }
  }
})
const quit = () => { stopChild(); process.exit(0) }
process.stdin.on('end', quit)
process.on('SIGTERM', quit)
process.on('SIGINT', quit)
process.on('SIGHUP', quit)
