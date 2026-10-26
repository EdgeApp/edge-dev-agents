// qa-queue.js — the watcher's QA queue (qa-run skill). Two entry points per tick:
//
//   reconcile(tasks, ctx)  runs BEFORE dev spawns, every tick, even at cap:
//     - agent_qa Planning|Running with agent_status no longer Complete (the dev run was
//       re-armed): kill qa-asana-<gid>, free its slot/sim, agent_qa=Pending, archive
//       the pass dir. Killing first means the two sessions never share the worktree.
//     - agent_qa Failed with agent_status Complete: kill the QA session, free its slot,
//       agent_qa=Fixing, then agent_status=Pending (the dev resume picks the failed cases
//       up through check-followup-scope.sh). qa-verdict.sh already turned a Failed past
//       watcher.qa_rearm_cap into Blocked, so every Failed seen here re-arms.
//     - agent_qa terminal (Passed|Skipped|Blocked|Fixed): kill a QA session whose verdict
//       posted, free its slot/sim, drop the native app cache pin and the spawn counter.
//     - writes qa-holds.json: gids whose dev worktree QA still needs (agent_qa
//       Pending|Planning|Running on a Complete task). The watchdog's prune and teardown
//       sweeps and gc-worktrees.sh spare them.
//   spawn(tasks, ctx)  runs AFTER dev spawns, under its own cap (watcher.max_concurrent_qa).
//   One session runs the whole pass (plan, gate, drive, verdict) on a pool sim + slot,
//   spawned only when no dev sim task is waiting and the sim cap has room:
//     1. Planning|Running with no live session and no verdict → a crashed session:
//        respawn (qa-start.sh resumes the phase from the pass dir).
//     2. agent_qa Pending on a Complete task, oldest first → a fresh pass in the dev
//        worktree. qa-on-complete.sh queues only sim-lane tasks.
//   Every spawn counts in qa/spawns-<gid>; at 3 the pass ends with qa-verdict.sh
//   --abandon instead of another spawn.
//
// Sessions are `qa-asana-<gid>`, prompt `/qa-run --yolo <url>`, env AGENT_MODE=qa
// (spawn-test-session.sh --qa). A QA session is never retired: it is killed.
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const { execSync, spawnSync } = require('node:child_process')
const slots = require('./slots.js')

const HOME = process.env.HOME || ''
const DIR = path.join(HOME, '.config/agent-watcher')
const STATE = path.join(process.env.XDG_STATE_HOME || path.join(HOME, '.local/state'), 'agent-watcher')
const QA_ROOT = path.join(STATE, 'qa')
const HOLDS = path.join(STATE, 'qa-holds.json')
const QA_SCRIPTS = path.join(HOME, '.cursor/skills/qa-run/scripts')
const PINS = path.join(process.env.NATIVE_APP_CACHE_DIR || path.join(HOME, 'Library/Caches/agent-native-apps'), '.pins')
const QA_PREFIX = 'qa-asana-'
const MAX_SPAWNS = 3
const TERMINAL = new Set(['Passed', 'Skipped', 'Blocked', 'Fixed'])
const LIVE = new Set(['Pending', 'Planning', 'Running'])

function field(task, cfg, name) {
  const gid = cfg.custom_fields?.[name]?.gid
  const f = gid && task.custom_fields?.find((x) => x.gid === gid)
  return f?.enum_value?.name || null
}

function maxConcurrentQa(cfg) {
  const env = parseInt(process.env.AGENT_WATCHER_MAX_CONCURRENT_QA || '', 10)
  if (Number.isFinite(env) && env >= 0) return env
  return cfg.watcher?.max_concurrent_qa ?? 1
}

const passDir = (gid) => path.join(QA_ROOT, gid)
const has = (gid, f) => fs.existsSync(path.join(passDir(gid), f))
const read = (p) => { try { return fs.readFileSync(p, 'utf8').trim() } catch { return '' } }
const spawnsFile = (gid) => path.join(QA_ROOT, `spawns-${gid}`)
const qaSlotFile = (gid) => path.join(QA_ROOT, `slot-${gid}`)
const spawnCount = (gid) => parseInt(read(spawnsFile(gid)) || '0', 10) || 0

function liveQaSessions(ctx) {
  const out = ctx.sh('tmux list-sessions -F "#{session_name}"')
  return new Set((out ? out.split('\n') : []).filter((s) => s.startsWith(QA_PREFIX) && /^\d+$/.test(s.slice(QA_PREFIX.length))).map((s) => s.slice(QA_PREFIX.length)))
}

function act(ctx, desc, fn) {
  ctx.log(`  qa: ${desc}`)
  if (ctx.DRY_RUN) return true
  try { fn(); return true } catch (e) { ctx.log(`  qa: FAILED ${desc}: ${e.message}`); return false }
}

function setQa(gid, value) { execSync(`${DIR}/set-agent-field.sh ${gid} agent_qa ${value}`, { stdio: 'ignore' }) }

function killQa(ctx, gid) {
  ctx.sh(`tmux kill-session -t "=${QA_PREFIX}${gid}"`)
}

// Free the slot and pool sim a QA session held. The dev session shares the gid
// key, so nothing is freed while claude-asana-<gid> is live.
function freeQaResources(ctx, gid) {
  if (!fs.existsSync(qaSlotFile(gid))) return
  fs.rmSync(qaSlotFile(gid), { force: true })
  if (ctx.sh(`tmux has-session -t "=claude-asana-${gid}" 2>/dev/null && echo yes`) === 'yes') return
  try { slots.release(gid) } catch { /* already gone */ }
  try { execSync(`${DIR}/release-pool-entry.sh --task-gid ${gid}`, { stdio: 'ignore' }) } catch { /* best-effort */ }
}

function archivePass(gid) {
  if (!fs.existsSync(passDir(gid))) return
  fs.renameSync(passDir(gid), `${passDir(gid)}.prev-${Date.now()}`)
}

function reconcile(tasks, ctx) {
  const { cfg } = ctx
  const live = liveQaSessions(ctx)
  const holds = {}
  for (const t of tasks) {
    const qa = field(t, cfg, 'agent_qa')
    if (!qa) continue
    const status = field(t, cfg, 'agent_status')
    const gid = t.gid
    if ((qa === 'Planning' || qa === 'Running') && status !== 'Complete') {
      act(ctx, `${gid} dev re-armed (agent_status=${status}) during QA ${qa}: kill QA, agent_qa=Pending`, () => {
        killQa(ctx, gid); freeQaResources(ctx, gid); setQa(gid, 'Pending'); archivePass(gid); fs.rmSync(spawnsFile(gid), { force: true })
      })
      continue
    }
    if (qa === 'Failed' && status === 'Complete') {
      act(ctx, `${gid} QA Failed: agent_qa=Fixing, agent_status=Pending (dev followup re-armed)`, () => {
        killQa(ctx, gid); freeQaResources(ctx, gid); setQa(gid, 'Fixing')
        execSync(`${DIR}/update-status.sh ${gid} Pending`, { stdio: 'ignore' })
        fs.rmSync(spawnsFile(gid), { force: true })
      })
      continue
    }
    if (TERMINAL.has(qa)) {
      const pin = path.join(PINS, gid)
      const sessionDone = live.has(gid) && has(gid, 'verdict.json')
      const qaSlot = !live.has(gid) && fs.existsSync(qaSlotFile(gid))
      if (sessionDone || qaSlot || fs.existsSync(pin) || fs.existsSync(spawnsFile(gid))) {
        act(ctx, `${gid} QA ${qa}: cleanup (session, slot, cache pin)`, () => {
          if (sessionDone) killQa(ctx, gid)
          if (!live.has(gid) || sessionDone) freeQaResources(ctx, gid)
          fs.rmSync(pin, { force: true }); fs.rmSync(spawnsFile(gid), { force: true })
        })
      }
      continue
    }
    if (LIVE.has(qa) && status === 'Complete') holds[gid] = qa
  }
  if (!ctx.DRY_RUN) {
    fs.mkdirSync(STATE, { recursive: true })
    fs.writeFileSync(HOLDS, JSON.stringify({ updated_at: new Date().toISOString(), gids: holds }, null, 2))
  }
  return holds
}

function devRepoDir(gid) {
  const pinned = read(path.join(passDir(gid), 'pinned.json'))
  if (pinned) { try { const d = JSON.parse(pinned).repo_dir; if (d && fs.existsSync(d)) return d } catch { /* fall through */ } }
  // Same pick as qa-run lib.sh qa_repo_dir: the first repo whose branch has a PR
  // (edge-react-gui first), else the first repo with a .git.
  const root = path.join(require('./worktree-root.js').worktreeRoot(), gid)
  const names = ['edge-react-gui', ...(fs.existsSync(root) ? fs.readdirSync(root).filter((r) => r !== 'edge-react-gui') : [])]
  const dirs = names.map((r) => path.join(root, r)).filter((d) => fs.existsSync(path.join(d, '.git')))
  const withPr = dirs.find((d) => spawnSync('gh', ['pr', 'view', '--json', 'url'], { cwd: d, stdio: 'ignore' }).status === 0)
  if (withPr || dirs[0]) return withPr || dirs[0]
  return path.join(HOME, 'git') // qa-start.sh re-provisions the worktree
}

function spawnQa(ctx, task, kind) {
  const { cfg } = ctx
  const gid = task.gid
  const url = `https://app.asana.com/0/${cfg.project_gid}/${gid}`
  const cwd = devRepoDir(gid)
  ctx.log(`QA spawn (${kind}): ${task.name} (gid=${gid}, cwd=${cwd})`)
  if (ctx.DRY_RUN) return true
  fs.mkdirSync(QA_ROOT, { recursive: true })

  const args = ['--qa', '--yolo', '--task-gid', gid, '--worktree-path', cwd, '--label', `QA: ${task.name}`.slice(0, 120), '--deliverable', 'PR',
    '--lanes', 'iOS Sim']
  freeQaResources(ctx, gid) // a crashed session's slot and sim
  let udid
  try { udid = execSync(`${DIR}/allocate-from-pool.sh --task-gid ${gid}`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim().split('\n').pop() } catch (e) {
    ctx.log(`  qa: no free pool sim (allocate exit ${e.status ?? '?'}); QA spawn waits`)
    return false
  }
  let slot
  try { slot = slots.allocate({ task_gid: gid, worktree_path: path.dirname(cwd), sim_udid: udid }) } catch (e) {
    ctx.log(`  qa: slot allocation failed (${e.message}); releasing sim`)
    try { execSync(`${DIR}/release-pool-entry.sh --task-gid ${gid}`, { stdio: 'ignore' }) } catch { /* best-effort */ }
    return false
  }
  fs.writeFileSync(qaSlotFile(gid), String(slot.slot_index))
  args.push('--slot-index', String(slot.slot_index), '--sim-udid', udid, '--metro-port', String(slot.metro_port))
  fs.writeFileSync(spawnsFile(gid), String(spawnCount(gid) + 1))
  const r = spawnSync(`${DIR}/spawn-test-session.sh`, args, { stdio: 'inherit' })
  if (r.status !== 0) {
    ctx.log(`  qa: spawn-test-session --qa failed (exit ${r.status})`)
    freeQaResources(ctx, gid)
    return false
  }
  ctx.waitRcReadyAndSendPrompt(`${QA_PREFIX}${gid}`, `/qa-run --yolo ${url}`)
  return true
}

function abandon(ctx, gid, reason) {
  act(ctx, `${gid} abandon QA pass: ${reason}`, () => {
    spawnSync(`${QA_SCRIPTS}/qa-verdict.sh`, ['--gid', gid, '--abandon', reason], { stdio: 'inherit' })
    fs.rmSync(spawnsFile(gid), { force: true })
  })
}

function spawn(tasks, ctx) {
  const { cfg, simRoom } = ctx
  const cap = maxConcurrentQa(cfg)
  const live = liveQaSessions(ctx)
  let room = cap - live.size
  ctx.log(`QA sessions: ${live.size}/${cap}`)
  if (room <= 0) return
  if (ctx.holdReason) { ctx.log(`QA spawns held: ${ctx.holdReason}`); return }

  const crashed = []; const fresh = []
  for (const t of tasks) {
    const qa = field(t, cfg, 'agent_qa')
    if (field(t, cfg, 'agent_status') !== 'Complete' || live.has(t.gid)) continue
    if (ctx.sh(`tmux has-session -t "=claude-asana-${t.gid}" 2>/dev/null && echo yes`) === 'yes') continue
    if (qa === 'Pending') fresh.push(t)
    else if ((qa === 'Planning' || qa === 'Running') && !has(t.gid, 'verdict.json')) crashed.push(t)
  }
  const byAge = (a, b) => (a.created_at || '').localeCompare(b.created_at || '')
  fresh.sort(byAge)

  for (const t of [...crashed, ...fresh]) {
    if (room <= 0) return
    if (!simRoom) { ctx.log(`QA deferred (needs a sim; dev work or the sim cap holds it): ${t.name}`); continue }
    if (spawnCount(t.gid) >= MAX_SPAWNS) { abandon(ctx, t.gid, `the QA session died ${spawnCount(t.gid)} times before a verdict`); continue }
    if (field(t, cfg, 'agent_qa') === 'Pending' && !ctx.DRY_RUN) archivePass(t.gid)
    if (spawnQa(ctx, t, field(t, cfg, 'agent_qa') === 'Pending' ? 'fresh' : 'respawn')) room--
  }
}

module.exports = { reconcile, spawn, liveQaSessions, maxConcurrentQa }
