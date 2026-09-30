'use strict'
// lib/transcript-list.js — the resumable-transcript list behind
// `resume-agent.sh --list`, its term matching, and the orch TUI / Fleet page
// (through lib/fleet-model.js). One implementation, no per-row subprocesses.
//
// Candidates are the orch-run transcripts under ~/.claude/projects/<enc(~/git)>*
// (head carries RUN_SIGNATURE_RE; lib/transcript-heads.js caches the head
// facts), plus, for listings, every prompt-spawned session in the chat-spawns
// registry. A --uuid selection replaces both with that uuid's transcript(s)
// in any project dir.
//
//   candidates({uuid, withSpawns})  sync, newest first: {path, mtime, uuid, gid, preview}
//   filterByTerm(cands, term)       async: every word of term must match (regex,
//                                   case-insensitive) the task identity: gid +
//                                   Asana name, or gid + the first 64 KB when
//                                   the name is unresolvable. Never the whole
//                                   body: a generic word appears in every
//                                   transcript and matched unrelated sessions.
//   rows(cands, {names, tmux})      sync porcelain rows; tmux is
//                                   fleet-model.loadTmux() output
//
// A row's state is running (claude-asana-<gid>), retired (done-asana-<gid>,
// claude alive, slot already freed), dead (pane without claude; the watchdog
// deliberately does not auto-resume these) or "" (transcript only). A pane
// launched with --fork-session writes a NEW uuid, so "some pane resumes this
// uuid" does not make the transcript live: the child comes from the fork
// registry and the row reports a fork of the run, never the run as live.
//
// CLI (resume-agent.sh delegates here):
//   --list [--porcelain] [--term T] [--uuid U]
//       porcelain row: mtime \t uuid \t gid \t state \t rc \t fork_child \t fork_rc \t title
//   --candidates [--term T]     path \t mtime \t uuid \t gid \t preview ("-" = empty)
//   --task-name <file>          the Asana name of the file's head task gid
// Exit 1 with the reason on stderr when nothing matches.
const fs = require('fs')
const os = require('os')
const path = require('path')
const { headFacts } = require('./transcript-heads.js')
const taskNames = require('./task-names.js')
const chatSpawns = require('./chat-spawns.js')

const HOME = os.homedir()
const PROJECTS = path.join(HOME, '.claude/projects')
const ST = `${process.env.XDG_STATE_HOME || HOME + '/.local/state'}/agent-watcher`
// claude encodes a project dir by replacing every "/" and "." in the cwd with
// "-"; legacy runs (cwd ~/git) and worktree runs (~/git/.agent-worktrees/...)
// share this prefix.
const ENC_GIT_PREFIX = `${HOME}/git`.replace(/[/.]/g, '-')

const readdir = (d) => { try { return fs.readdirSync(d) } catch { return [] } }

function runPaths () {
  const out = []
  for (const d of readdir(PROJECTS)) {
    if (!d.startsWith(ENC_GIT_PREFIX)) continue
    for (const f of readdir(path.join(PROJECTS, d))) if (f.endsWith('.jsonl')) out.push(path.join(PROJECTS, d, f))
  }
  return out
}

function uuidPaths (uuid) {
  return readdir(PROJECTS).map(d => path.join(PROJECTS, d, `${uuid}.jsonl`)).filter(p => fs.existsSync(p))
}

function candidates ({ uuid = '', withSpawns = false } = {}) {
  let facts
  if (uuid) facts = [...headFacts(uuidPaths(uuid)).values()]
  else {
    facts = [...headFacts(runPaths()).values()].filter(f => f.sig)
    if (withSpawns) {
      const have = new Set(facts.map(f => f.path))
      const extra = []
      for (const u of chatSpawns.load().byUuid.keys()) for (const p of uuidPaths(u)) if (!have.has(p)) { have.add(p); extra.push(p) }
      facts.push(...headFacts(extra).values())
    }
  }
  return facts
    .map(f => ({ path: f.path, mtime: f.mtime, uuid: path.basename(f.path, '.jsonl'), gid: f.gid, preview: f.preview }))
    .sort((a, b) => b.mtime - a.mtime || (a.uuid < b.uuid ? 1 : a.uuid > b.uuid ? -1 : 0))
}

function wordRe (w) {
  try { return new RegExp(w, 'i') } catch { return new RegExp(w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i') }
}

async function filterByTerm (cands, term) {
  const words = String(term || '').split(/\s+/).filter(Boolean)
  if (!words.length) return cands
  await taskNames.refreshIfStale()
  const names = await taskNames.resolve(cands.map(c => c.gid))
  const res = words.map(wordRe)
  return cands.filter(c => {
    let id = `${c.gid} ${names.get(c.gid) || ''}`
    if (!names.get(c.gid)) {
      try {
        const fd = fs.openSync(c.path, 'r'); const buf = Buffer.alloc(65536)
        const n = fs.readSync(fd, buf, 0, buf.length, 0); fs.closeSync(fd)
        id = `${c.gid} ${buf.subarray(0, n).toString('utf8').replace(/\0/g, '')}`
      } catch {}
    }
    return res.every(re => re.test(id))
  })
}

function tmuxState (tmux) {
  const byGid = new Map()
  const forkByParent = new Map()
  let reg = []
  try { reg = fs.readFileSync(`${ST}/chat-forks.jsonl`, 'utf8').split('\n') } catch {}
  const childOf = (parent) => {
    let child = ''
    for (const line of reg) { try { const j = JSON.parse(line); if (j.parent === parent && j.child) child = j.child } catch {} }
    return child || 'unknown'
  }
  for (const s of tmux || []) {
    const m = s.name.match(/^(claude|done)-asana-(\d{12,})$/)
    if (m && !byGid.has(m[2])) byGid.set(m[2], { state: s.claudeAlive ? (m[1] === 'claude' ? 'running' : 'retired') : 'dead', rc: s.rc })
    if (s.claudeAlive && s.fork && s.resumeUuid && !forkByParent.has(s.resumeUuid)) {
      forkByParent.set(s.resumeUuid, { child: childOf(s.resumeUuid), rc: s.rc })
    }
  }
  return { byGid, forkByParent }
}

function rows (cands, { names, tmux }) {
  const spawns = chatSpawns.load().byUuid
  const { byGid, forkByParent } = tmuxState(tmux)
  return cands.map(c => {
    let gid = c.gid
    const nm = gid && names.get(gid)
    let title = nm ? `Asana: ${nm}` : c.preview
    // A spawn's head gid is incidental (brief or injected context), never its task.
    const spawnRc = spawns.get(c.uuid)?.rc || ''
    if (spawnRc) { gid = ''; title = spawnRc }
    const st = (gid && byGid.get(gid)) || { state: '', rc: '' }
    const fk = forkByParent.get(c.uuid) || { child: '', rc: '' }
    return { mtime: c.mtime, uuid: c.uuid, gid, state: st.state, rc: st.rc, forkChild: fk.child, forkRc: fk.rc, title, spawned: !!spawnRc }
  })
}

module.exports = { candidates, filterByTerm, rows, ENC_GIT_PREFIX }

// ─── CLI ─────────────────────────────────────────────────────────────────────
function stamp (epoch) {
  const d = new Date(epoch * 1000)
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
}

function fail (...lines) { for (const l of lines) process.stderr.write(l + '\n'); process.exit(1) }

async function main (argv) {
  const opt = { list: false, porcelain: false, cands: false, term: '', uuid: '', taskName: '' }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--list') opt.list = true
    else if (a === '--porcelain') opt.porcelain = true
    else if (a === '--candidates') opt.cands = true
    else if (a === '--term') opt.term = argv[++i] || ''
    else if (a === '--uuid') opt.uuid = argv[++i] || ''
    else if (a === '--task-name') opt.taskName = argv[++i] || ''
    else fail(`transcript-list: unknown argument ${a}`)
  }
  const out = (s) => process.stdout.write(s + '\n')
  const dash = (v) => (v ? String(v).replace(/[\t\n]/g, ' ') : '-')

  if (opt.taskName) {
    const f = headFacts([opt.taskName]).get(opt.taskName)
    if (f && f.gid) { await taskNames.refreshIfStale(); const n = (await taskNames.resolve([f.gid])).get(f.gid); if (n) out(n) }
    return
  }

  let cands = candidates({ uuid: opt.uuid, withSpawns: opt.list })
  if (!cands.length) {
    if (opt.uuid) fail(`>> resume-agent: no transcript found for uuid ${opt.uuid}`)
    fail(`No watcher-spawned sessions found in ~/.claude/projects/${ENC_GIT_PREFIX}*`)
  }
  if (!opt.uuid && opt.term) {
    cands = await filterByTerm(cands, opt.term)
    if (!cands.length) fail(`No watcher-spawned session's task gid/name matches: ${opt.term}`, '(use --list to see all candidates)')
  }

  if (opt.cands) {
    for (const c of cands) out([c.path, c.mtime, c.uuid, dash(c.gid), dash(c.preview)].join('\t'))
    return
  }

  await taskNames.refreshIfStale()
  const names = await taskNames.resolve(cands.map(c => c.gid))
  const tmux = require('./fleet-model.js').loadTmux({ rcState: false })
  const rs = rows(cands, { names, tmux })
  if (opt.porcelain) {
    for (const r of rs) out([r.mtime, r.uuid, r.gid, r.state, r.rc, r.forkChild, r.forkRc, r.title].map(v => String(v ?? '').replace(/[\t\n]/g, ' ')).join('\t'))
    return
  }
  out('Watcher-spawned sessions (newest first):')
  out('  ● running   ◐ retired (alive, attachable)   ✗ dead pane')
  for (const r of rs) {
    const title = r.spawned ? `spawned: ${r.title}` : (r.title || '(title unavailable)')
    const sym = { running: '●', retired: '◐', dead: '✗' }[r.state] || ' '
    let notes = r.state
    if (r.rc) notes = `${notes ? notes + ' ' : ''}rc=${r.rc}`
    // A live fork means THIS transcript is frozen and the conversation moved on;
    // name the child uuid, which is what --uuid must be given to reach it. A fork
    // in this session's own pane shares its rc; do not print it twice.
    const forkRc = r.forkRc && r.forkRc !== r.rc ? r.forkRc : ''
    if (r.forkChild) notes = `${notes ? notes + ' ' : ''}-> live fork ${r.forkChild}${forkRc ? ` rc=${forkRc}` : ''}`
    out(`  ${sym} ${stamp(r.mtime)}  ${r.uuid}  ${title}${notes ? `   [${notes}]` : ''}`)
  }
}

if (require.main === module) main(process.argv.slice(2)).catch(e => fail(`transcript-list: ${e.message || e}`))
