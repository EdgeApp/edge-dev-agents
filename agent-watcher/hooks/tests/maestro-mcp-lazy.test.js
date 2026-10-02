#!/usr/bin/env node
// Vectors for maestro-mcp-lazy.js against a fake MCP server (no maestro, no JVM).
// Run: node ~/.config/agent-watcher/hooks/tests/maestro-mcp-lazy.test.js
'use strict'
const { spawn } = require('child_process')
const fs = require('fs')
const os = require('os')
const path = require('path')

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp-lazy-test-'))
const STARTS = path.join(TMP, 'starts')
const FAKE = path.join(TMP, 'fake-maestro')
fs.writeFileSync(FAKE, `#!/usr/bin/env node
require('fs').appendFileSync(${JSON.stringify(STARTS)}, process.argv.slice(2).join(' ') + '\\n')
let b = ''
process.stdin.on('data', (d) => { b += d; let i; while ((i = b.indexOf('\\n')) >= 0) { const m = JSON.parse(b.slice(0, i)); b = b.slice(i + 1)
  const r = (result) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: m.id, result }) + '\\n')
  if (m.method === 'initialize') r({ protocolVersion: 'p', capabilities: { tools: {} }, serverInfo: { name: 'fake' } })
  else if (m.method === 'tools/list') r({ tools: [{ name: 'echo' }] })
  else if (m.method === 'tools/call' && m.params.name === 'die') process.exit(3)
  else if (m.method === 'tools/call') r({ content: [{ type: 'text', text: 'ran ' + m.params.name }] })
} })
`)
fs.chmodSync(FAKE, 0o755)
const PROXY = path.join(os.homedir(), '.config/agent-watcher/maestro-mcp-lazy.js')
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const starts = () => { try { return fs.readFileSync(STARTS, 'utf8').split('\n').filter(Boolean) } catch { return [] } }
const fails = []
const ok = (name, cond, detail = '') => { if (!cond) fails.push(name); console.log((cond ? 'ok   ' : 'FAIL ') + name + (cond ? '' : '  ' + detail)) }

function session(idle = '0') {
  const p = spawn(PROXY, ['--device', 'SIM-1', 'mcp'], { stdio: ['pipe', 'pipe', 'ignore'],
    env: { ...process.env, MAESTRO_BIN: FAKE, MAESTRO_MCP_CACHE: path.join(TMP, 'cache.json'), MAESTRO_MCP_IDLE_SECS: idle, AGENT_SIM_UDID: '' } })
  const got = {}
  let b = ''
  p.stdout.on('data', (d) => { b += d; let i; while ((i = b.indexOf('\n')) >= 0) { const m = JSON.parse(b.slice(0, i)); b = b.slice(i + 1); got[m.id] = m } })
  const w = (m) => p.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...m }) + '\n')
  const handshake = async () => {
    w({ id: 1, method: 'initialize', params: { protocolVersion: 'p', capabilities: {} } }); await sleep(400)
    w({ method: 'notifications/initialized' }); w({ id: 2, method: 'tools/list' }); await sleep(400)
  }
  const call = async (id, name) => { w({ id, method: 'tools/call', params: { name, arguments: {} } }); await sleep(500); return got[id] }
  return { p, got, w, handshake, call, end: async () => { p.stdin.end(); await sleep(300) } }
}

;(async () => {
  let s = session()
  await s.handshake()
  ok('no cache: the server starts at once and answers the handshake itself', starts().length === 1 && s.got[1]?.result?.serverInfo?.name === 'fake' && s.got[2]?.result?.tools?.length === 1)
  ok('no cache: the handshake fills the cache', fs.existsSync(path.join(TMP, 'cache.json')))
  ok('maestro args reach the server unchanged', starts()[0] === '--device SIM-1 mcp')
  await s.end()

  fs.rmSync(STARTS)
  fs.renameSync(path.join(TMP, 'cache.json'), path.join(TMP, 'cache.keep'))
  s = session()
  s.w({ id: 0, method: 'server/discover', params: {} }); await sleep(300)
  await s.handshake()
  ok('no cache: a request ahead of initialize still leaves a working handshake', s.got[1]?.result?.serverInfo?.name === 'fake' && s.got[2]?.result?.tools?.length === 1)
  await s.end()
  fs.renameSync(path.join(TMP, 'cache.keep'), path.join(TMP, 'cache.json'))
  fs.rmSync(STARTS)
  s = session('1')
  s.w({ id: 0, method: 'server/discover', params: {} }); await sleep(300)
  ok('cached: a request ahead of initialize is refused with no server', starts().length === 0 && s.got[0]?.error?.code === -32601)
  await s.handshake()
  ok('cached: handshake and tools/list answered with no server', starts().length === 0 && s.got[1]?.result?.serverInfo?.name === 'fake' && s.got[2]?.result?.tools?.[0]?.name === 'echo')
  s.w({ id: 3, method: 'ping' }); await sleep(200)
  ok('cached: ping starts no server', starts().length === 0 && s.got[3]?.result)
  let r = await s.call(4, 'echo')
  ok('first tool call starts the server and gets its answer', starts().length === 1 && r?.result?.content?.[0]?.text === 'ran echo')
  ok('the replayed initialize answer is not sent to the client', !('__lazy_init__' in s.got))
  await sleep(1500)
  r = await s.call(5, 'echo')
  ok('after the idle stop, the next call starts a second server', starts().length === 2 && r?.result?.content?.[0]?.text === 'ran echo')
  r = await s.call(6, 'die')
  ok('a server that exits mid-call fails that call with a JSON-RPC error', r?.error?.code === -32000)
  r = await s.call(7, 'echo')
  ok('the proxy survives and the next call starts a third server', starts().length === 3 && r?.result?.content?.[0]?.text === 'ran echo')
  await s.end()
  ok('the proxy exits when the client closes stdin', s.p.exitCode === 0)

  fs.rmSync(TMP, { recursive: true, force: true })
  console.log(fails.length ? `\nFAILED: ${fails.length}` : '\nall vectors pass')
  process.exit(fails.length ? 1 : 0)
})()
