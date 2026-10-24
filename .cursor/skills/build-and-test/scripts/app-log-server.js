#!/usr/bin/env node
// app-log-server.js: receive the gui's LOG_SERVER console stream for one slot.
//
// With LOG_SERVER set in config.json, src/app.ts sends every console line
// (core and plugin logs included) to POST <host>:<port>/log as {"data": "..."}.
// This listener appends each one to --out as `<ISO time> <line>`. Started by
// app-log-capture.sh, which owns the port, the file and config.json.
//
// Usage: app-log-server.js --port <n> --out <file>
const fs = require('fs')
const http = require('http')

const args = process.argv.slice(2)
const flag = name => {
  const i = args.indexOf(name)
  return i >= 0 ? args[i + 1] : undefined
}
const port = Number(flag('--port'))
const out = flag('--out')
if (!Number.isInteger(port) || port <= 0 || out == null) {
  console.error('usage: app-log-server.js --port <n> --out <file>')
  process.exit(2)
}

const stream = fs.createWriteStream(out, { flags: 'a' })

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type')
  if (req.method === 'OPTIONS') {
    res.writeHead(204)
    res.end()
    return
  }
  if (req.method !== 'POST' || req.url !== '/log') {
    res.writeHead(404)
    res.end()
    return
  }
  let body = ''
  req.setEncoding('utf8')
  req.on('data', chunk => {
    body += chunk
  })
  req.on('end', () => {
    let line = body
    try {
      const { data } = JSON.parse(body)
      if (data != null) line = String(data)
    } catch (e) {}
    stream.write(`${new Date().toISOString()} ${line.trim()}\n`)
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end('{"ok":true}')
  })
})

server.on('error', err => {
  console.error(`app-log-server: ${err.message}`)
  process.exit(1)
})
// Loopback only: the iOS sim shares the host's loopback. An Android emulator
// needs `adb reverse tcp:<port> tcp:<port>` to reach it (android-dev-server.sh runs it).
server.listen(port, '127.0.0.1', () => {
  console.error(`app-log-server: port ${port} -> ${out}`)
})
