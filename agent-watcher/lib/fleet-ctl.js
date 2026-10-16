#!/usr/bin/env node
// fleet-ctl.js -- the fleet's control surface as JSON in, JSON out, for
// clients that are not a terminal: the `fleet` Claude Code mod (local, or on
// another machine over `ssh eddy fleet-ctl.sh ...`). It holds no fleet logic
// of its own: the model is orch-tui's dump, search is session-index.sh, and
// every action calls the script session-tui.js calls for the same key.
//
// Usage (via fleet-ctl.sh, which sets PATH for a non-login ssh shell):
//   snapshot                         vitals + live sessions + resumable transcripts
//   search                           stdin: the query; session-index.sh --grep
//   fork <uuid> [--chrome]           resume-agent.sh --uuid <uuid> --chat
//   resume <uuid>                    resume-agent.sh --uuid <uuid> --chat --in-place
//   revive <tmux-session>            restart claude in a dead chat/anchor pane
//   kill <tmux-session>              tmux kill-session
//   new <slug> [--model m] [--effort e] [--no-chrome]
//                                    stdin: the brief; spawn-chat-session.sh
// Free text (a search query, a brief) only ever arrives on stdin, and every
// argv token is checked against a fixed pattern, so a command line that a
// remote shell re-parses carries nothing it could interpret.
// Output: one JSON object on stdout. Exit 0 ok, 1 refused or failed (the JSON
// says why in `error`).
'use strict'
const { spawnSync } = require('child_process')
const fs = require('fs')
const os = require('os')
const path = require('path')

const AW = path.join(os.homedir(), '.config/agent-watcher')
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const TMUX = /^(claude|done)-asana-[A-Za-z0-9_-]{1,80}$/
const SLUG = /^[a-z0-9][a-z0-9-]{0,39}$/
const MODEL = /^(opus|sonnet|haiku|fable)(\[1m\])?$/
const EFFORT = /^(low|medium|high|xhigh|max)$/

function out (obj, code = 0) {
  process.stdout.write(JSON.stringify(obj) + '\n')
  process.exit(code)
}
function fail (error) { out({ ok: false, error }, 1) }

function run (cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 << 20, ...opts })
  return { code: r.status ?? 1, stdout: r.stdout || '', stderr: r.stderr || '' }
}
function lastLine (s) { return s.split('\n').map(l => l.trim()).filter(Boolean).pop() || '' }
function readStdin () { try { return fs.readFileSync(0, 'utf8') } catch { return '' } }

// orch-tui --dump calls process.exit right after console.log, which cuts a
// piped stdout at 64 KB; a file descriptor is written synchronously, so the
// dump goes to a temp file.
function dump () {
  const file = path.join(os.tmpdir(), `fleet-dump-${process.pid}.json`)
  const fd = fs.openSync(file, 'w')
  const r = spawnSync('node', [path.join(AW, 'orch-tui.js'), '--dump'], { stdio: ['ignore', fd, 'pipe'], encoding: 'utf8', timeout: 90000 })
  fs.closeSync(fd)
  const text = fs.readFileSync(file, 'utf8')
  fs.rmSync(file, { force: true })
  if (r.status !== 0) fail(`orch-tui --dump exited ${r.status}: ${lastLine(r.stderr || '')}`)
  return JSON.parse(text)
}

// os.hostname() follows DHCP (it read Mac.edge.app on the office LAN); the
// machine's own LocalHostName is the name people know it by.
function hostName () {
  const r = run('/usr/sbin/scutil', ['--get', 'LocalHostName'])
  return r.code === 0 && r.stdout.trim() ? r.stdout.trim() : os.hostname()
}

function snapshot () {
  const d = dump()
  const v = d.vitals || {}
  out({
    ok: true,
    at: d.at,
    host: hostName(),
    vitals: {
      load: v.load, cores: v.cores, maxLoad: v.maxLoad,
      freeGb: v.freeGb, minFree: v.minFree, memLevel: v.memLevel?.level || '',
      hogs: (v.hogs || []).slice(0, 3),
      runaway: v.runaway || null,
      holds: v.holds || [],
      watcherTickAge: v.watcherTickAge, watchdogTickAge: v.watchdogTickAge,
      lastWatcherLine: v.lastWatcherLine || '',
      jobsDown: (v.jobs || []).filter(j => j.rc !== 0).map(j => j.name),
    },
    slots: { used: (d.slots || []).filter(s => s.live).length, max: v.maxConcurrent },
    live: (d.fleet?.live || []).map(s => ({
      name: s.name, kind: s.kind, state: s.state, title: s.title || s.name,
      alive: !!s.claudeAlive, rc: s.rc || '', rcUp: !!s.rcUp, uuid: s.uuid || s.resumeUuid || '',
      activity: s.activity, reap: s.reap || '',
    })),
    dead: (d.fleet?.dead || []).slice(0, 40).map(t => ({
      kind: t.kind, title: t.title || t.uuid, uuid: t.uuid, gid: t.gid || '', mtime: t.mtime,
    })),
    activity: (d.activity || []).slice(0, 8).map(a => ({ ts: a.ts, src: a.src, msg: a.msg })),
  })
}

function search () {
  const q = readStdin().trim().slice(0, 200)
  if (!q) fail('empty search query')
  const r = run(path.join(AW, 'session-index.sh'), ['--grep', q], { timeout: 180000 })
  if (r.code !== 0) fail(`session-index.sh exited ${r.code}: ${lastLine(r.stderr)}`)
  const j = JSON.parse(r.stdout)
  const hits = (j.transcripts || []).filter(t => t.grep && t.grep.authored > 0).slice(0, 30).map(t => ({
    uuid: t.uuid, kind: t.kind, title: t.task_name || '', gid: t.task_gid || '',
    mtime: Math.floor(Date.parse(t.mtime) / 1000), live: t.live_tmux || '',
    authored: t.grep.authored,
  }))
  out({ ok: true, query: q, hits })
}

// resume-agent prints the tmux and RC names it used; pass them back.
function resumeAgent (args) {
  const r = run(path.join(AW, 'resume-agent.sh'), args, { timeout: 240000, cwd: path.join(os.homedir(), 'git') })
  const all = r.stdout + '\n' + r.stderr
  const tmux = (all.match(/tmux: (claude-asana-[A-Za-z0-9_-]+)/) || all.match(/(claude-asana-chat-[a-z0-9-]+)/) || [])[1] || ''
  const rc = (all.match(/remote: ([A-Za-z0-9_-]+)/) || [])[1] || ''
  if (r.code !== 0) fail(lastLine(all) || `resume-agent exited ${r.code}`)
  out({ ok: true, tmux, rc, message: lastLine(all) })
}

// Same RC naming as lib/fleet-model.js classify().
function slugOf (name) {
  const m = name.match(/^claude-asana-chat-(.+)$/)
  if (m) return `chat-${m[1]}`
  return name.replace(/^claude-asana-/, '')
}

function revive (name) {
  if (!name.startsWith('claude-asana-') || /^claude-asana-\d+$/.test(name)) {
    fail('only chat and anchor panes revive here; a dead run needs resume-task.sh (slot re-allocation)')
  }
  const row = (dump().fleet?.live || []).find(s => s.name === name)
  if (!row) fail(`no live tmux session ${name}`)
  if (row.claudeAlive) fail(`claude is already running in ${name}`)
  const uuid = row.uuid || row.resumeUuid
  if (!uuid || !UUID.test(uuid)) fail('no transcript uuid known for this pane; fork it instead')
  const rcName = slugOf(name)
  run('tmux', ['send-keys', '-t', `=${name}:`, 'C-u'])
  const r = run('tmux', ['send-keys', '-t', `=${name}:`, `claude --resume ${uuid} --dangerously-skip-permissions --remote-control ${rcName}`, 'Enter'])
  if (r.code !== 0) fail(`tmux send-keys exited ${r.code}: ${lastLine(r.stderr)}`)
  out({ ok: true, tmux: name, rc: rcName, message: `revived claude in ${name}; give it a few seconds` })
}

function kill (name) {
  const r = run('tmux', ['kill-session', '-t', `=${name}`])
  if (r.code !== 0) fail(lastLine(r.stderr) || `tmux kill-session exited ${r.code}`)
  out({ ok: true, tmux: name, message: `killed ${name}; its transcript stays resumable` })
}

function spawnNew (slug, flags) {
  const brief = readStdin().trim()
  if (!brief) fail('empty brief')
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-brief-'))
  const file = path.join(dir, 'brief.md')
  fs.writeFileSync(file, brief + '\n')
  const args = ['--name', slug, '--brief-file', file]
  if (flags.model) args.push('--model', flags.model)
  if (flags.effort) args.push('--effort', flags.effort)
  if (flags.noChrome) args.push('--no-chrome')
  const r = run(path.join(AW, 'spawn-chat-session.sh'), args, { timeout: 240000 })
  fs.rmSync(dir, { recursive: true, force: true })
  const all = r.stdout + '\n' + r.stderr
  if (r.code !== 0 && r.code !== 3) fail(lastLine(all) || `spawn-chat-session exited ${r.code}`)
  out({
    ok: true, tmux: `claude-asana-chat-${slug}`, rc: `chat-${slug}`,
    message: r.code === 3 ? 'spawned, but the brief pointer did not arrive intact; open the session and resend' : `started chat-${slug}`,
  })
}

const [verb, ...rest] = process.argv.slice(2)
switch (verb) {
  case 'snapshot': snapshot(); break
  case 'search': search(); break
  case 'fork':
    if (!UUID.test(rest[0] || '')) fail('fork: bad uuid')
    resumeAgent(['--uuid', rest[0], '--chat', ...(rest.includes('--chrome') ? ['--chrome'] : [])]); break
  case 'resume':
    if (!UUID.test(rest[0] || '')) fail('resume: bad uuid')
    resumeAgent(['--uuid', rest[0], '--chat', '--in-place']); break
  case 'revive':
    if (!TMUX.test(rest[0] || '')) fail('revive: bad session name')
    revive(rest[0]); break
  case 'kill':
    if (!TMUX.test(rest[0] || '')) fail('kill: bad session name')
    kill(rest[0]); break
  case 'new': {
    const slug = (rest[0] || '').replace(/^chat-/, '')
    if (!SLUG.test(slug)) fail('new: slug must be lowercase letters, digits and hyphens, at most 40')
    const flags = {}
    for (let i = 1; i < rest.length; i++) {
      if (rest[i] === '--model' && MODEL.test(rest[i + 1] || '')) flags.model = rest[++i]
      else if (rest[i] === '--effort' && EFFORT.test(rest[i + 1] || '')) flags.effort = rest[++i]
      else if (rest[i] === '--no-chrome') flags.noChrome = true
      else fail(`new: unknown or invalid option ${rest[i]}`)
    }
    spawnNew(slug, flags); break
  }
  default: fail('usage: fleet-ctl.sh snapshot|search|fork|resume|revive|kill|new ...')
}
