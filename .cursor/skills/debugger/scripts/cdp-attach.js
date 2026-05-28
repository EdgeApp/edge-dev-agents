#!/usr/bin/env node
// cdp-attach.js — Attach to a Hermes JS VM via Metro inspector (CDP), set a
// breakpoint at file:line, optionally trigger it, and report call stack /
// locals / arbitrary evaluated expressions on pause.
//
// Uses Node's built-in global WebSocket (Node 22+) — no npm deps.
//
// USAGE:
//   node cdp-attach.js \
//     --break-at <pattern>:<line>[:<col>]      \
//     [--condition '<js-expression>']          \
//     [--trigger '<js-expression>']            \
//     [--report stack,locals,evaluate:<expr>]  \
//     [--metro localhost:8081]                 \
//     [--target-regex 'React Native|Hermes|Bridgeless'] \
//     [--timeout-ms 8000]
//
//   --break-at: pattern is matched as a case-insensitive urlRegex against the
//               source file URL Hermes reports. Substring is fine —
//               e.g. `rampConstraints.ts:51` becomes the regex `.*rampConstraints\.ts.*`.
//               Line is 1-based (matches editor convention).
//
//   --condition: optional JS expression evaluated in the breakpoint's scope.
//               The breakpoint only fires when this returns truthy.
//               Example: `paymentType === "ach"` to only break on ACH calls.
//
//   --trigger: optional JS evaluated in the live VM AFTER the breakpoint is
//              set. Use to force-hit the breakpoint deterministically (call the
//              function that contains it). If omitted, the script WAITS
//              passively until the breakpoint fires (e.g. from human/automation
//              driving the app) or --timeout-ms elapses.
//
//   --report: comma-separated list of what to include in the pause report.
//             Supports:
//               stack            — top 10 call frames (default)
//               locals           — local-scope variables of the top frame (default)
//               evaluate:<expr>  — Debugger.evaluateOnCallFrame on top frame
//             Can repeat `evaluate:`. Example: --report stack,locals,evaluate:foo,evaluate:bar
//
// OUTPUT: structured JSON on stdout (the pause report or an error envelope).
//         Status/log lines on stderr.
//
// EXIT CODES:
//   0 = breakpoint hit, report emitted
//   1 = error (Metro unreachable, target not found, breakpoint unresolved, etc.)
//   2 = no breakpoint hit within --timeout-ms (passive-wait mode timed out)

'use strict'

const http = require('node:http')

// ─── Arg parsing ─────────────────────────────────────────────────────────────

const args = process.argv.slice(2)
const opts = {
  breakAt: null,
  condition: null,
  trigger: null,
  report: 'stack,locals',
  // Default Metro endpoint follows the slot's port when the watcher set it,
  // else the RN default 8081. Explicit --metro always wins.
  metro: `localhost:${process.env.AGENT_METRO_PORT || '8081'}`,
  targetRegex: 'React Native|Hermes|Bridgeless',
  timeoutMs: 8000,
}

for (let i = 0; i < args.length; i++) {
  const a = args[i]
  const next = () => args[++i]
  switch (a) {
    case '--break-at':    opts.breakAt = next(); break
    case '--condition':   opts.condition = next(); break
    case '--trigger':     opts.trigger = next(); break
    case '--report':      opts.report = next(); break
    case '--metro':       opts.metro = next(); break
    case '--target-regex': opts.targetRegex = next(); break
    case '--timeout-ms':  opts.timeoutMs = parseInt(next(), 10); break
    case '--help':
    case '-h':
      process.stdout.write(require('node:fs').readFileSync(__filename, 'utf8').split('\n').slice(0, 50).join('\n') + '\n')
      process.exit(0)
    default:
      console.error(`Unknown arg: ${a}`)
      process.exit(1)
  }
}

if (!opts.breakAt) {
  console.error('Missing required --break-at <pattern>:<line>[:<col>]')
  process.exit(1)
}

// Parse pattern:line[:col]
const bpMatch = opts.breakAt.match(/^(.+?):(\d+)(?::(\d+))?$/)
if (!bpMatch) {
  console.error(`--break-at must be <pattern>:<line>[:<col>] — got: ${opts.breakAt}`)
  process.exit(1)
}
const bpPattern = bpMatch[1]
const bpLine = parseInt(bpMatch[2], 10) - 1 // CDP is 0-based; user input is 1-based
const bpColumn = bpMatch[3] != null ? parseInt(bpMatch[3], 10) : undefined

// Build CDP urlRegex: escape regex metachars in the user's substring, wrap with .*
const escapedPattern = bpPattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const urlRegex = `.*${escapedPattern}.*`

// Parse --report into structured form
const reportItems = opts.report.split(',').map((s) => s.trim()).filter(Boolean)
const wantStack = reportItems.includes('stack')
const wantLocals = reportItems.includes('locals')
const evaluateExprs = reportItems
  .filter((s) => s.startsWith('evaluate:'))
  .map((s) => s.slice('evaluate:'.length))

// ─── HTTP target discovery ───────────────────────────────────────────────────

function httpGetJson(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, (res) => {
      let body = ''
      res.on('data', (d) => (body += d))
      res.on('end', () => {
        try { resolve(JSON.parse(body)) } catch (e) { reject(e) }
      })
    })
    req.on('error', reject)
    req.setTimeout(3000, () => req.destroy(new Error('timeout')))
  })
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  // Discover targets
  let targets
  try {
    targets = await httpGetJson(`http://${opts.metro}/json/list`)
  } catch (e) {
    console.error(`Failed to fetch targets from http://${opts.metro}/json/list: ${e.message}`)
    process.exit(1)
  }

  const re = new RegExp(opts.targetRegex, 'i')
  const target = targets.find((t) => re.test((t.description || '') + (t.title || '')))
  if (!target) {
    console.error(`No target matching /${opts.targetRegex}/i. Available targets:`)
    targets.forEach((t) => console.error(`  - ${t.title || '?'} | ${t.description || '?'}`))
    process.exit(1)
  }
  console.error(`>> cdp-attach: target = ${target.title} | ${target.description}`)

  // Connect via the built-in WebSocket (Node 22+)
  if (typeof WebSocket === 'undefined') {
    console.error('Node WebSocket global not available. Use Node 22+.')
    process.exit(1)
  }
  const ws = new WebSocket(target.webSocketDebuggerUrl)
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', () => resolve(), { once: true })
    ws.addEventListener('error', (e) => reject(new Error(e.message || 'ws error')), { once: true })
  })
  console.error('>> cdp-attach: WS connected')

  // Tiny CDP RPC helper
  let nextId = 0
  const pending = new Map()
  let pausedParams = null
  const eventListeners = new Map() // method → array of resolvers (waitFor)

  ws.addEventListener('message', (event) => {
    const msg = JSON.parse(event.data)
    if (msg.id != null && pending.has(msg.id)) {
      const { resolve } = pending.get(msg.id)
      pending.delete(msg.id)
      resolve(msg.error ? { __error: msg.error } : (msg.result || {}))
      return
    }
    if (msg.method === 'Debugger.paused') {
      pausedParams = msg.params
    }
    const listeners = eventListeners.get(msg.method)
    if (listeners && listeners.length > 0) {
      const resolvers = listeners.splice(0)
      for (const r of resolvers) r(msg.params)
    }
  })

  function send(method, params = {}) {
    return new Promise((resolve) => {
      const id = ++nextId
      pending.set(id, { resolve })
      ws.send(JSON.stringify({ id, method, params }))
    })
  }

  function waitForEvent(method, timeoutMs) {
    return new Promise((resolve, reject) => {
      const to = setTimeout(() => reject(new Error(`timeout waiting for ${method}`)), timeoutMs)
      const list = eventListeners.get(method) || []
      list.push((params) => { clearTimeout(to); resolve(params) })
      eventListeners.set(method, list)
    })
  }

  await send('Runtime.enable')
  await send('Debugger.enable', { maxScriptsCacheSize: 10_000_000 })
  await send('Debugger.setBreakpointsActive', { active: true })

  // Set the breakpoint
  const bpResult = await send('Debugger.setBreakpointByUrl', {
    urlRegex,
    lineNumber: bpLine,
    ...(bpColumn != null ? { columnNumber: bpColumn } : {}),
    ...(opts.condition ? { condition: opts.condition } : {}),
  })

  if (bpResult.__error) {
    console.error(`setBreakpointByUrl failed: ${bpResult.__error.message}`)
    ws.close()
    process.exit(1)
  }

  const resolvedCount = (bpResult.locations || []).length
  console.error(`>> cdp-attach: breakpoint set (id=${bpResult.breakpointId}, resolved=${resolvedCount} locations)`)
  if (resolvedCount === 0) {
    console.error(`   pattern: /${urlRegex}/ line=${bpLine + 1}${bpColumn != null ? ` col=${bpColumn}` : ''}`)
    console.error('   warning: 0 locations resolved. Breakpoint will fire if the source URL appears later.')
  }

  // Wait for pause
  const pausePromise = waitForEvent('Debugger.paused', opts.timeoutMs)

  // Optionally trigger
  if (opts.trigger) {
    console.error(`>> cdp-attach: triggering with --trigger expression`)
    send('Runtime.evaluate', { expression: opts.trigger, includeCommandLineAPI: false }).catch(() => {})
  } else {
    console.error(`>> cdp-attach: waiting passively for breakpoint to fire (timeout ${opts.timeoutMs}ms)`)
  }

  let pause
  try {
    pause = await pausePromise
  } catch (e) {
    console.error(`>> cdp-attach: ${e.message}`)
    const envelope = { error: 'timeout', breakpoint: { pattern: bpPattern, line: bpLine + 1, resolved: resolvedCount } }
    process.stdout.write(JSON.stringify(envelope, null, 2) + '\n')
    ws.close()
    process.exit(2)
  }

  // Build the report
  const report = {
    breakpoint: {
      pattern: bpPattern,
      line: bpLine + 1,
      column: bpColumn,
      resolved: resolvedCount,
    },
    paused: {
      reason: pause.reason,
    },
  }

  if (wantStack) {
    report.paused.callStack = pause.callFrames.slice(0, 10).map((f) => ({
      function: f.functionName || '(anon)',
      url: f.url || `(scriptId:${f.location.scriptId})`,
      line: f.location.lineNumber + 1,
      column: f.location.columnNumber,
    }))
  }

  const topFrame = pause.callFrames[0]

  if (wantLocals && topFrame) {
    const localScope = (topFrame.scopeChain || []).find((s) => s.type === 'local')
    if (localScope) {
      const props = await send('Runtime.getProperties', {
        objectId: localScope.object.objectId,
        ownProperties: true,
      })
      report.paused.locals = {}
      for (const p of props.result || []) {
        const v = p.value
        report.paused.locals[p.name] = v
          ? (v.value !== undefined ? v.value : (v.description || `<${v.type}>`))
          : '<unavailable>'
      }
    } else {
      report.paused.locals = '<no local scope reported>'
    }
  }

  if (evaluateExprs.length > 0 && topFrame) {
    report.paused.evaluated = {}
    for (const expr of evaluateExprs) {
      const r = await send('Debugger.evaluateOnCallFrame', {
        callFrameId: topFrame.callFrameId,
        expression: expr,
      })
      report.paused.evaluated[expr] = r.__error
        ? `<error: ${r.__error.message}>`
        : (r.result ? (r.result.value !== undefined ? r.result.value : r.result.description) : '<no result>')
    }
  }

  // Resume so the app keeps running
  await send('Debugger.resume')

  process.stdout.write(JSON.stringify(report, null, 2) + '\n')
  ws.close()
  process.exit(0)
}

main().catch((e) => {
  console.error(`cdp-attach failed: ${e.message}`)
  process.exit(1)
})
