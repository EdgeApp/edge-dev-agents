#!/usr/bin/env node
// session-watchdog.js — Watchdog tending live claude-asana-* tmux sessions.
// (Formerly rc-watchdog.js; renamed because it does more than RC.) Jobs:
// RC-bridge revive, completion sweep (agent_status=Complete → teardown), blocked
// sweep, worktree-retention GC, orphan-Metro + idle-dirty-sim reclaim, and the two
// operator-escalation surfaces (paneAwaitingChoice park, and the Stop-hook stuck flag).
// RE-ENGAGEMENT IS NOT HERE: re-running/continuing a finished task is the WATCHER's job
// (set it to Pending → the watcher resumes from the transcript on a fresh slot, or
// fresh-spawns a never-run task). The un-retire sweep was removed 2026-06-25.
//
// BOUNDARY — what this watchdog does NOT do: it does NOT prod a stopped session to
// CONTINUE. Forcing a premature-stopped --yolo run to keep going is owned by the
// in-session Stop hook (hooks/require-continuation-or-block.sh), which fires the instant
// the turn ends and injects a continue directive. The watchdog's only "prod" is the RC
// revive WAKE PING, and that is gated to a DEAD RC bridge (!rcUp) — a different failure
// (broken comms the agent can't receive through) than a clean stop. The two are
// complementary, not redundant; do not re-add a general continue-prod here.
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
// resume-agent --chat forks (claude-asana-chat-*) are discussion sessions: their
// non-gid names exempt them from the completion sweep, so without a reaper they
// accumulate (each idle claude holds 100s of MB). Reap after 48h without pane
// change; the transcript survives, so `resume-agent <term> --chat` resurrects.
// Named discussion anchors (main/eval/pokemon/...) are NOT chat- prefixed and
// are never reaped.
const CHAT_IDLE_REAP_MS = 48 * 60 * 60 * 1000
// Android emulators are NOT slot resources: nothing tracks their spawn (agents boot
// them ad hoc via `emulator -avd ...`) and qemu reparents to launchd immediately, so
// ownership can't come from ancestry or slots.json. Ownership signal instead: a
// maestro client (--device emulator-<port>), since all agent device driving goes
// through maestro-mcp. A serial with no maestro client for this long is orphaned.
//
// KNOWN GAP — deferred 2026-07-22: true iOS parity would make Android slot-tracked
// (an ensure-android-emulator.sh spawn helper records emulator_serial/avd in
// slots.json; freeSimAndMetro() then releases it deterministically at retire/block,
// like sim_udid + metro_port). Deferred because NO managed spawn path exists yet —
// no skill or script boots emulators, tasks do it ad hoc — so there is nothing to
// hook. If Android becomes a regular task resource, build the spawn helper FIRST,
// then wire the release; the 2h grace reap below is the interim safety net.
const ANDROID_EMU_UNATTENDED_MS = 2 * 60 * 60 * 1000
// Anchor panes (claude-asana-<word>: non-gid, non-chat) whose claude died sit as bare
// bash shells forever — the completion sweep can't see them (no task gid) and the
// chat reaper skips them. Deleting a bridged desktop session SIGKILLs the CLI, so a
// dead anchor pane usually means the operator already discarded the conversation;
// reap after a grace that covers a manual restart-in-place.
const DEAD_ANCHOR_REAP_MS = 10 * 60 * 1000
const ANDROID_SDK = '/opt/homebrew/share/android-commandlinetools'
// After this long parked at a human-choice prompt, emit ONE escalation line (instead
// of the per-tick park log) so an operator notices; never auto-sheds.
const PARK_ESCALATE_MS = 60 * 60 * 1000
// Remote-control "up" detection, across TWO claude build styles that render it
// differently in the bottom status region:
//   - New builds (--rc / /remote-control): a compact "/rc" token at the right end of the
//     status footer line (the line carrying "shift+tab to cycle" / "for agents").
//   - Old builds (e.g. a long-lived session still on an earlier claude): the words
//     "Remote Control active" on their own line just below the footer, with NO "/rc".
// Both signals live in the LAST few lines of the pane. We bound the old-style check to
// the tail so the same words appearing in the scrolled CONVERSATION can never false-match
// (the original plain whole-buffer substring marker did exactly that, and also missed the
// "/rc" style entirely). A genuinely dead bridge shows neither → revive.
const RC_FOOTER_RE = /shift\+tab to cycle|for agents/
const RC_TOKEN_RE = /(^|\s)\/rc(\s|$)/
function rcBridgeUp(content) {
  const lines = content.split('\n')
  if (lines.some((l) => RC_FOOTER_RE.test(l) && RC_TOKEN_RE.test(l))) return true // new style
  if (/Remote Control active/.test(lines.slice(-3).join('\n'))) return true        // old style
  return false
}
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

// One fetch → both agent_status and blocked (both enum custom fields). `ok`
// distinguishes a CONFIRMED read from a transient failure: a failed fetch
// returns blocked:null, which is indistinguishable from "not blocked" and would
// otherwise let the revive guard ping a session that is actually blocked/parked
// (observed 2026-06-13/15: a blocked task got revived on the tick its fetch
// blipped to null, then re-froze the next tick). Callers that take a HARMFUL
// action on the absence of a state (revive) MUST gate on `ok`.
function fetchTaskState(taskGid) {
  const token = getAsanaToken()
  const statusGid = getStatusFieldGid()
  if (!token || !statusGid) return { agentStatus: null, blocked: null, ok: false }
  const blockedGid = getBlockedFieldGid()
  const out = sh(`curl -sS -H "Authorization: Bearer ${token}" "https://app.asana.com/api/1.0/tasks/${taskGid}?opt_fields=custom_fields.gid,custom_fields.enum_value.name"`)
  if (!out) return { agentStatus: null, blocked: null, ok: false }
  try {
    const parsed = JSON.parse(out)
    const cfs = parsed.data?.custom_fields || []
    const agentStatus = cfs.find((f) => f.gid === statusGid)?.enum_value?.name || null
    const blocked = blockedGid ? (cfs.find((f) => f.gid === blockedGid)?.enum_value?.name || null) : null
    return { agentStatus, blocked, ok: true }
  } catch { return { agentStatus: null, blocked: null, ok: false } }
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

// True when the pane is parked at an interactive prompt awaiting a human CHOICE
// (permission/tool-approval dialog, trust prompt, numbered selection menu). Such a
// prompt makes the pane go STATIC — indistinguishable from "hung" by the idle
// heuristic — but reviving it is harmful: the revive keystrokes (ping+Enter,
// /remote-control+Enter, Esc) answer the dialog blindly. The normal idle composer
// ("❯ " with an empty input line) is NOT a choice prompt and must not match here.
function paneAwaitingChoice(content) {
  return /❯\s+\d+\.\s/.test(content)                                  // selected numbered menu option (❯ 1. …)
    || /\bNo, and tell Claude\b/i.test(content)                       // distinctive permission-prompt option text
    || /\bDo you want to (proceed|continue|create|trust|allow|make)\b/i.test(content) // dialog header
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
  // C-u before each typed send: remote-control clients can sync drafts into
  // the composer; typing without clearing concatenates the draft.
  sh(`tmux send-keys -t "${session}" C-u`)
  sh(`tmux send-keys -t "${session}" "<watchdog-revive-ping>" Enter`)
  sh('sleep 8')
  sh(`tmux send-keys -t "${session}" C-u`)
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
  freeWorktreeListeners(taskGid)
}

// Ad-hoc Metros (agent-started, untracked in slots.json, possibly on a non-slot
// port) survive the tracked-port kill: the 2026-07-22 swapter run inherited slot
// port 8181 still held by the PREVIOUS task's untracked Metro 1.5h after its
// retirement, and the app silently loaded the wrong bundle. Kill by WORKTREE
// CWD: any listener serving from this task's worktree dies with the task.
function freeWorktreeListeners(taskGid) {
  const root = `${WORKTREES_ROOT}/${taskGid}`
  const pids = sh('lsof -iTCP -sTCP:LISTEN -t 2>/dev/null').split('\n').filter(Boolean)
  for (const pid of [...new Set(pids)]) {
    const cwd = sh(`lsof -a -p ${pid} -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'`).split('\n')[0] || ''
    if (cwd === root || cwd.startsWith(`${root}/`)) {
      sh(`kill ${pid}`)
      log(`  [metro] killed listener pid ${pid} (cwd ${cwd} under retired worktree ${taskGid})`)
    }
  }
}

// Operator-escalation surface for the Stop hook's livelock bound. CONTINUATION itself
// is owned by the in-session Stop hook (require-continuation-or-block.sh): it forces a
// premature-stopped --yolo run to keep going. Only when that hook hits STOP_BLOCK_MAX
// consecutive premature stops (the run genuinely can't finish AND can't legitimately
// block) does it give up, drop /tmp/agent-stuck-<gid>.md, and allow the stop. The
// watchdog's job here is narrow: surface that flag to the operator ONCE (rename to
// .escalated so it never re-logs every tick; a fresh .md from a later livelock cycle
// re-escalates). The watchdog does NOT prod sessions to continue — that is the Stop
// hook's job; the watchdog only revives DEAD RC BRIDGES (a different failure: a stop
// event the Stop hook sees vs a broken comms channel the agent can't receive through)
// and runs the lifecycle/GC sweeps below.
function escalateStuckSessions() {
  let files = []
  try { files = fs.readdirSync('/tmp').filter((f) => /^agent-stuck-\d+\.md$/.test(f)) } catch { return }
  for (const f of files) {
    const gid = f.replace(/^agent-stuck-(\d+)\.md$/, '$1')
    const full = `/tmp/${f}`
    let detail = ''
    try { detail = fs.readFileSync(full, 'utf8').split('\n').slice(1).join(' ').replace(/\s+/g, ' ').trim().slice(0, 220) } catch { /* best-effort */ }
    log(`[claude-asana-${gid}] STUCK — agent gave up after repeated premature stops (Stop-hook livelock bound). Operator attention needed (attach: tmux attach -t claude-asana-${gid}). ${detail}`)
    try { fs.renameSync(full, `${full}.escalated`) } catch { /* best-effort */ }
  }
}

// Load relief, independent of the watcher's load gate. A pool sim in state "dirty"
// (released by a finished/blocked task, pending ensure-sim-pool's delete+re-clone) has
// NO allocatable value while booted — it can't be handed out until refreshed, and the
// refresh deletes it anyway. But ensure-sim-pool runs ONLY inside an asana-watcher spawn
// tick, which is itself load-gated — so under high load (or with no Pending tasks) dirty
// sims sit BOOTED indefinitely, burning the very CPU/RAM that keeps the box over the
// spawn guardrail (the loop: high load → watcher skips → no refresh → dirty sims stay
// booted → load stays high → never refreshed). The watchdog runs every tick regardless
// of load, so shed them here: shut down (shutdown-only — ensure-sim-pool still does the
// clean delete+re-clone later) any booted dirty pool sim. Never touches free/in_use sims
// (the allocatable, pre-warmed ones) or the master.
function reclaimIdlePoolSims() {
  const poolPath = path.join(slots.STATE_DIR, 'pool.json')
  let pool
  try { pool = JSON.parse(fs.readFileSync(poolPath, 'utf8')).pool || [] } catch { return }
  const dirty = pool.filter((e) => e && e.state === 'dirty' && e.udid)
  if (!dirty.length) return
  const booted = sh('xcrun simctl list devices booted 2>/dev/null')
  for (const e of dirty) {
    if (!booted.includes(e.udid)) continue // already shut down
    sh(`"${DIR}/delete-ios-sim.sh" --udid "${e.udid}" --shutdown-only`)
    log(`[reclaim] shut down booted dirty pool sim ${e.udid} (slot ${e.slot}) — idle + pending refresh; frees load while the watcher is gated`)
  }
}

// Reap orphan Metro bundlers, two orphan shapes: (a) cwd is an .agent-worktrees/<gid>
// dir that no longer exists (the slot was torn down but its Metro lingered, squatting
// a port the next slot reuses → the "foreign Metro on my port" failures); (b) the
// worktree still exists (retention keeps up to keep_completed_worktrees on disk) but
// the gid has NO tmux session left in either prefix — nothing can be using that Metro.
// Only touches Metros whose cwd is under the worktrees root; spares live-session
// Metros and any Metro outside the worktrees root (e.g. a manual one in ~/git/<repo>).
function reapOrphanMetros(liveSessions) {
  const out = sh('pgrep -fl "react-native.*start|node_modules/metro"')
  if (!out) return
  const sessionGids = new Set([
    ...liveSessions.map((s) => s.slice(SESSION_PREFIX.length)),
    ...listRetiredSessions().map((s) => s.gid),
  ])
  for (const line of out.split('\n').filter(Boolean)) {
    const pid = parseInt(line.trim().split(/\s+/)[0], 10)
    if (!Number.isFinite(pid)) continue
    const cwdRaw = sh(`lsof -a -p ${pid} -d cwd -Fn`).split('\n').map((s) => s.replace(/^n/, '')).filter(Boolean).pop() || ''
    const cwd = cwdRaw.replace(/ \(deleted\)$/, '')
    if (!cwd || !cwd.startsWith(WORKTREES_ROOT)) continue // only worktree Metros
    const gid = cwd.slice(WORKTREES_ROOT.length + 1).split('/')[0]
    if (!fs.existsSync(cwd)) {
      sh(`kill ${pid}`)
      log(`[reaper] killed orphan Metro pid ${pid} (worktree gone: ${cwd})`)
    } else if (gid && !sessionGids.has(gid)) {
      sh(`kill ${pid}`)
      log(`[reaper] killed orphan Metro pid ${pid} (no session for gid ${gid}; worktree retained: ${cwd})`)
    }
  }
}

// Manual-hold escalation: pool entries allocated with a NON-NUMERIC task_gid
// (operator hand-labels like "qr-login-manual") are invisible to every sweep —
// the completion sweep keys off Asana status for numeric gids, and dirty/free
// reclaim never touches in_use. A forgotten manual hold keeps a sim booted
// indefinitely (found 2026-07-23: pool-2 booted-idle under "qr-login-manual",
// no log trail). Never auto-release (a human owns it, and release destroys
// their manual state); escalate ONCE after the threshold so the operator
// decides. Boot state is re-checked live so a shutdown hold stays quiet.
const MANUAL_HOLD_ESCALATE_MS = 4 * 60 * 60 * 1000
function escalateManualPoolHolds(state) {
  let pool = []
  try { pool = JSON.parse(fs.readFileSync(path.join(slots.STATE_DIR, 'pool.json'), 'utf8')).pool || [] } catch { return }
  for (const e of pool) {
    if (e.state !== 'in_use' || !e.task_gid || /^\d+$/.test(e.task_gid)) continue
    const key = `manual-hold-${e.task_gid}`
    const prior = state[key]
    if (!prior) { state[key] = { since: Date.now(), escalated: false }; continue }
    const booted = sh(`xcrun simctl list devices 2>/dev/null | grep "${e.udid}" | grep -c Booted`) === '1'
    if (!booted) continue
    if (!prior.escalated && Date.now() - prior.since > MANUAL_HOLD_ESCALATE_MS) {
      log(`[pool] manual hold "${e.task_gid}" has kept sim ${e.udid} booted >${Math.round(MANUAL_HOLD_ESCALATE_MS / 3600000)}h — operator attention: shutdown it, or release with release-pool-entry.sh --task-gid "${e.task_gid}". Not auto-releasing.`)
      prior.escalated = true
    }
  }
  // Entries that left in_use reset their tracking.
  for (const k of Object.keys(state)) {
    if (!k.startsWith('manual-hold-')) continue
    const gid = k.slice('manual-hold-'.length)
    if (!pool.some((e) => e.state === 'in_use' && e.task_gid === gid)) delete state[k]
  }
}

// Watchman GC: watchman accumulates a root per task worktree (Metro adds it; nothing
// removes it) and every root holds a live fsevents subscription. That churn is a
// primary driver of the fseventsd RSS leak on this box (43.6GB, PID 29 up 56 days,
// observed 2026-07-22). Del roots under the worktrees tree whose dir is gone OR whose
// gid has no session in either prefix. Never touches the main-repo root or any
// non-worktree root. Safe: a resumed task's Metro re-creates its watch on demand.
function reapStaleWatchmanRoots(liveSessions) {
  const out = sh('watchman watch-list 2>/dev/null')
  if (!out) return
  let roots = []
  try { roots = JSON.parse(out).roots || [] } catch { return }
  const sessionGids = new Set([
    ...liveSessions.map((s) => s.slice(SESSION_PREFIX.length)),
    ...listRetiredSessions().map((s) => s.gid),
  ])
  for (const r of roots) {
    if (!r.startsWith(WORKTREES_ROOT)) continue
    const gid = r.slice(WORKTREES_ROOT.length + 1).split('/')[0]
    const dirGone = !fs.existsSync(r)
    if (dirGone || (gid && !sessionGids.has(gid))) {
      sh(`watchman watch-del "${r}"`)
      log(`[reaper] watchman watch-del ${r} (${dirGone ? 'dir gone' : `no session for gid ${gid}`})`)
    }
  }
}

// fseventsd leak guard. fseventsd (root-owned) leaks RSS under heavy fs churn
// (worktree/sim-clone/node_modules cycles): 43.6GB after 56 days, observed
// 2026-07-22. Only root can restart it, so this guard is INERT until the operator
// adds a narrow sudoers rule via `sudo visudo`:
//   eddy ALL=(root) NOPASSWD: /usr/bin/pkill -x fseventsd
// With the rule: past the RSS limit, `sudo -n` restarts it (launchd respawns it
// clean; watchman/Spotlight recrawl once, first Metro rebuild after is slower).
// Without it: sudo -n fails silently and we log the manual instruction, throttled
// to once per 24h via watchdog state.
const FSEVENTSD_RSS_LIMIT_KB = 16 * 1024 * 1024 // 16GB
function guardFseventsd(state, now) {
  const pid = parseInt(sh('pgrep -x fseventsd').split('\n')[0], 10)
  if (!Number.isFinite(pid)) return
  const rssKb = parseInt(sh(`ps -p ${pid} -o rss=`), 10)
  if (!Number.isFinite(rssKb) || rssKb < FSEVENTSD_RSS_LIMIT_KB) return
  if (state.fseventsdLastAttempt && now - state.fseventsdLastAttempt < 24 * 3600 * 1000) return
  state.fseventsdLastAttempt = now
  sh('sudo -n /usr/bin/pkill -x fseventsd 2>/dev/null')
  sh('sleep 3')
  if (!sh(`ps -p ${pid} -o pid=`)) {
    log(`[fseventsd] RSS ${Math.round(rssKb / 1024 / 1024)}GB over limit → restarted via sudo -n (launchd respawns it)`)
  } else {
    log(`[fseventsd] RSS ${Math.round(rssKb / 1024 / 1024)}GB over ${Math.round(FSEVENTSD_RSS_LIMIT_KB / 1024 / 1024)}GB limit — cannot restart without sudo. One-time setup (sudo visudo): eddy ALL=(root) NOPASSWD: /usr/bin/pkill -x fseventsd`)
  }
}

// Android reaping — see ANDROID_EMU_UNATTENDED_MS for the ownership model. Two passes:
//   1. crashpad_handler whose --monitor-pid target is dead: kill on sight. Its only
//      job is watching that pid; orphaned ones spin hot (observed ~99% CPU for a
//      week, 2026-07-14→21).
//   2. emulator with no maestro client for the grace window (first-unattended time
//      tracked per-serial in watchdog state): graceful `adb emu kill`, hard-kill
//      fallback. Its crashpad child dies with it (or pass 1 catches it next tick).
// PHYSICAL DEVICES ARE NEVER TOUCHED: pass 2 targets qemu-system pids and their
// emulator-<port> serials only; adb is never invoked against any other serial.
function reapOrphanAndroid(state, now) {
  const adb = fs.existsSync(`${ANDROID_SDK}/platform-tools/adb`) ? `${ANDROID_SDK}/platform-tools/adb` : 'adb'
  for (const line of sh('pgrep -fl "emulator/crashpad_handler"').split('\n').filter(Boolean)) {
    const pid = parseInt(line.trim().split(/\s+/)[0], 10)
    const mon = line.match(/--monitor-pid=(\d+)/)?.[1]
    if (!Number.isFinite(pid) || !mon) continue
    if (sh(`ps -p ${mon} -o pid=`)) continue // monitored emulator still alive
    sh(`kill ${pid}`)
    log(`[reaper] killed orphan crashpad_handler pid ${pid} (monitored pid ${mon} dead)`)
  }
  const tracked = state.android_emus || {}
  const next = {}
  for (const line of sh('pgrep -fl "qemu-system-"').split('\n').filter(Boolean)) {
    const pid = parseInt(line.trim().split(/\s+/)[0], 10)
    if (!Number.isFinite(pid) || !/ -avd /.test(line)) continue
    // serial = emulator-<console-port>: the lowest port qemu LISTENs on in adb's
    // console range (console is always allocated one below the adb port).
    const ports = (sh(`lsof -a -p ${pid} -iTCP -sTCP:LISTEN -Fn`).match(/:(\d+)$/gm) || []).map((s) => parseInt(s.slice(1), 10))
    const consolePort = ports.filter((p) => p >= 5554 && p <= 5682).sort((a, b) => a - b)[0]
    const serial = consolePort ? `emulator-${consolePort}` : null
    const avd = line.match(/ -avd (\S+)/)?.[1] || '?'
    if (serial && sh(`pgrep -f "maestro.*--device ${serial}( |$)"`)) continue // attended → not tracked
    const key = serial || `pid-${pid}`
    const since = tracked[key] ?? now
    if (now - since >= ANDROID_EMU_UNATTENDED_MS) {
      if (serial) { sh(`"${adb}" -s ${serial} emu kill`); sh('sleep 5') }
      if (sh(`ps -p ${pid} -o pid=`)) sh(`kill ${pid}`)
      log(`[reaper] killed orphan Android emulator ${avd} (${key}) — no maestro client for ${Math.round((now - since) / 3600000)}h`)
    } else {
      next[key] = since
      if (!(key in tracked)) log(`[reaper] tracking unattended Android emulator ${avd} (${key}) — reap after ${Math.round(ANDROID_EMU_UNATTENDED_MS / 3600000)}h without a maestro client`)
    }
  }
  state.android_emus = next
}

// Full teardown of one retained worktree: remove the worktree + branch (and any
// lingering sim/slot, though those were freed at completion). Used only by the prune.
function removeWorktree(taskGid, repo) {
  // Re-check session liveness at PRUNE TIME, under BOTH prefixes. The caller's
  // sparing logic uses lists captured earlier in the tick; an un-retire renames
  // done-asana → claude-asana mid-tick, leaving the gid in neither stale list —
  // the prune then destroys the just-resurrected session's worktree and slot.
  const liveNow = sh(`tmux has-session -t "${SESSION_PREFIX}${taskGid}" 2>/dev/null && echo yes`) === 'yes'
    || sh(`tmux has-session -t "${RETIRED_PREFIX}${taskGid}" 2>/dev/null && echo yes`) === 'yes'
  if (liveNow) {
    log(`  [${taskGid}] prune SKIPPED: a session exists for this gid (re-checked live)`)
    return
  }
  log(`  [${taskGid}] pruning retained worktree (repo ${repo})`)
  try { const s = slots.get(taskGid); if (s?.sim_udid) sh(`"${DIR}/release-pool-entry.sh" --task-gid "${taskGid}"`) } catch { /* none */ }
  sh(`"${DIR}/cleanup-task-workspace.sh" --task-gid "${taskGid}" --repo "${repo}"`)
  try { slots.release(taskGid) } catch { /* already gone */ }
  // cleanup-task-workspace is best-effort and exits 0 even when removal fails
  // (e.g. a non-git dir), which previously made the prune retry the same gid
  // every tick forever. Escalate: force-remove what the gated cleanup left.
  const dir = path.join(WORKTREES_ROOT, taskGid)
  if (fs.existsSync(dir)) {
    log(`  [${taskGid}] cleanup left the worktree dir behind — force-removing ${dir}`)
    try { fs.rmSync(dir, { recursive: true, force: true }) }
    catch (e) { log(`  [${taskGid}] force-remove failed: ${e.message}`) }
  }
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

// REMOVED 2026-06-25 — un-retire sweep (was unretireFollowups):
//   It renamed a retired done-asana-<gid> back to claude-asana-<gid> when its task moved
//   off Complete to a PHASE status, to re-engage a finished task in place. Two problems:
//   (a) it kept the LIVE process but could NOT refresh the sim/Metro freed at completion,
//   so a re-engaged build/test ran on dead resources (the same "dead hands" as talking to
//   a retired session directly); (b) it made re-engagement branch on status VALUE (a phase
//   status un-retired here, while Pending fresh-spawned in the watcher) — the confusing
//   split the operator never wanted. Re-engagement is now a SINGLE path through the WATCHER:
//   set a finished task to `Pending` and the watcher RESUMES it (memory + a fresh slot, via
//   resume-task) when a prior transcript exists, else fresh-spawns. So phase statuses are
//   progress-only (set by the running agent), never a manual re-engagement trigger, and
//   this watchdog stays out of re-engagement entirely (see the header BOUNDARY note).

// Retire a completed session instead of killing it: rename it out of the
// slot-counted `claude-asana-<gid>` namespace (so the watcher stops counting it and
// can spawn the next task) while KEEPING the claude process alive — the session
// stays attachable and re-engageable via RC. Sim + slot are freed; worktree is
// retained. Old retirements are bounded by pruneRetiredSessions().
function retireSession(session, taskGid, agentStatus = 'Complete') {
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
  log(`[${session}] agent_status=${agentStatus} → RETIRED as ${dest} (claude kept alive; Metro+sim+slot freed; worktree retained)`)
}

// Monitor-liveness heartbeat check: memory-monitor logs every 30s tick; a stale
// log means the box's memory gate is blind (it once died silently for 11 hours
// on a parse error while exiting 0). Detection only — repair is the operator's.
function checkMonitorHeartbeat() {
  try {
    const st = fs.statSync('/tmp/memory-monitor.log')
    const ageMin = (Date.now() - st.mtimeMs) / 60000
    if (ageMin > 10) log(`[infra] memory-monitor log STALE ${Math.round(ageMin)}min — the memory gate is blind; check /tmp/memory-monitor.err`)
  } catch { log('[infra] memory-monitor log MISSING — the memory gate is blind') }
}

// Durable release receipt: slots.json/pool.json forget a run seconds after retirement,
// so post-hoc evals (orch-eval O1/O6) cannot otherwise verify clean resource release.
// One small JSON per gid under STATE_DIR/releases; best-effort, never wedges the sweep.
// Box-wide flat-tree snapshot at retirement: agent-cli proc total + the max
// per-process-group count, matching `claude`/`cli` by basename (the runaway-guard
// match). Gives orch-eval's no-fork-storm (O2) dimension durable post-retirement
// evidence — `max_pgid_count` well under `threshold` means no fork storm occurred,
// which otherwise was NOT_CAPTURED once the live tree was gone.
function flatTreeSnapshot() {
  try {
    const counts = {}
    for (const line of sh('ps -axo pgid,comm').split('\n')) {
      const m = line.trim().match(/^(\d+)\s+(.+)$/)
      if (!m) continue
      const base = m[2].split('/').pop()
      if (base === 'cli' || base === 'claude') counts[m[1]] = (counts[m[1]] || 0) + 1
    }
    const vals = Object.values(counts)
    return { cli_total: vals.reduce((a, b) => a + b, 0), max_pgid_count: vals.length ? Math.max(...vals) : 0, threshold: 50 }
  } catch { return null }
}

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
      flat_tree: flatTreeSnapshot(),
    }, null, 2) + '\n')
    log(`  [${taskGid}] release receipt written`)
  } catch (e) { log(`  [${taskGid}] release receipt failed: ${e.message}`) }
}

// Cap retired sessions kept alive (each holds a live claude → memory bound). Keep
// the newest keep_completed_sessions; kill the older ones outright.
function pruneRetiredSessions() {
  const keep = getKeepCompletedSessions()
  let retired = listRetiredSessions()
  // A retired pane is kept alive ONLY so its claude stays attachable / re-engageable;
  // with claude gone (e.g. the operator deleted the bridged desktop session) it's a
  // bare shell with no value — reap it now instead of letting it squat the cap.
  const dead = retired.filter((s) => {
    const pid = getPanePid(s.name)
    return pid !== null && !claudeRunningUnder(pid)
  })
  for (const s of dead) {
    sh(`tmux kill-session -t "${s.name}"`)
    log(`[${s.name}] retired pane's claude gone → killed`)
  }
  if (dead.length) retired = retired.filter((s) => !dead.includes(s))
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
    // Completion sweep: if Asana shows a terminal agent_status (Complete, or the
    // operator-only Archived), retire the session.
    const taskGid = session.slice(SESSION_PREFIX.length)
    const { agentStatus, blocked, ok: stateOk } = fetchTaskState(taskGid)
    if (agentStatus === 'Complete' || agentStatus === 'Archived') {
      // Retire (rename + keep claude alive), NOT hard-kill — so the session stays
      // attachable / re-engageable. Capacity is freed because the renamed session
      // no longer matches the slot-counted `claude-asana-<digits>` pattern.
      retireSession(session, taskGid, agentStatus)
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
      // EXCEPT chat forks: a claude-asana-chat-* pane with no claude is pure waste
      // (no forensic value; the transcript survives on disk) — kill it immediately.
      if (taskGid.startsWith('chat-')) {
        log(`[${session}] chat session's claude is gone → killing the empty pane (transcript survives; resurrect: resume-agent <term> --chat)`)
        sh(`tmux kill-session -t "${session}"`)
        delete state.sessions[session]
        continue
      }
      if (!/^\d+$/.test(taskGid)) {
        // Anchor pane (see DEAD_ANCHOR_REAP_MS): desktop-delete propagation. The
        // grace period is tracked in state; a claude restart in the pane clears it
        // (the live path below rewrites the state entry without deadSince).
        const deadSince = state.sessions[session]?.deadSince ?? now
        if (now - deadSince >= DEAD_ANCHOR_REAP_MS) {
          log(`[${session}] anchor pane's claude gone ${Math.round((now - deadSince) / 60000)}m → reaped (transcript survives; resurrect via /resume-session)`)
          sh(`tmux kill-session -t "${session}"`)
          delete state.sessions[session]
        } else {
          if (!state.sessions[session]?.deadSince) log(`[${session}] anchor pane's claude gone → reaping in ${Math.round(DEAD_ANCHOR_REAP_MS / 60000)}m unless it comes back`)
          state.sessions[session] = { ...state.sessions[session], deadSince }
        }
        continue
      }
      log(`[${session}] claude not detected under pane (pid ${panePid}). NOT auto-resuming (death-path removed). Leaving for manual handling.`)
      delete state.sessions[session]
      continue
    }

    const content = capturePane(session)
    const rcUp = rcBridgeUp(content)   // footer "/rc" token = RC bridge up (idle near-end view)
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
    // Chat-session idle reaper (see CHAT_IDLE_REAP_MS). Runs after the pane
    // capture so `changed` is fresh; RC revive below still applies to chat
    // sessions younger than the reap threshold.
    if (taskGid.startsWith('chat-') && !changed && now - (prior?.lastChange ?? now) > CHAT_IDLE_REAP_MS) {
      log(`[${session}] chat session idle ${Math.round((now - prior.lastChange) / 3600000)}h > 48h → reaped (transcript survives; resurrect: resume-agent <term> --chat)`)
      sh(`tmux kill-session -t "${session}"`)
      delete state.sessions[session]
      continue
    }
    // Never revive a session that is DELIBERATELY idle waiting on a human: a blocked
    // task, or one parked at an interactive choice prompt. The revive keystrokes
    // (ping + /remote-control + Esc) would answer the dialog blindly. Both make the
    // pane static, so the idle heuristic alone cannot tell them from a hang.
    const awaitingChoice = paneAwaitingChoice(content)
    // Park tracking: a session parked at a human-choice prompt is correctly NOT
    // revived, but the per-tick log used to spam (~60 identical lines for a 2h park).
    // Log ONCE on entering the park, then a SINGLE escalation after PARK_ESCALATE_MS
    // (operator attention, not auto-shed — shedding could kill a session mid-decision),
    // and reset the moment it leaves the park.
    let parkedSince = null
    let parkLogged = false
    let parkEscalated = false
    if (awaitingChoice && !changed && now - (prior?.lastChange ?? now) > IDLE_THRESHOLD_MS) {
      parkedSince = prior?.parkedSince ?? now
      parkLogged = true
      parkEscalated = prior?.parkEscalated ?? false
      if (!prior?.parkLogged) {
        log(`[${session}] parked at an interactive prompt — NOT reviving (needs a human choice).`)
      } else if (!parkEscalated && now - parkedSince > PARK_ESCALATE_MS) {
        log(`[${session}] STILL parked at a human-choice prompt after ${Math.round((now - parkedSince) / 60000)}m — operator attention needed (attach: tmux attach -t ${session}). Not reviving, not shedding.`)
        parkEscalated = true
      }
    }
    if (stateOk && !isBlocked && !awaitingChoice && !changed && !rcUp && now - prior.lastChange > IDLE_THRESHOLD_MS) {
      // Require stateOk: never revive on an UNCONFIRMED status. A transient Asana
      // fetch failure returns blocked:null (=> isBlocked false); without this gate a
      // blocked/parked session gets pinged on the blip tick (the 2026-06-15 regression).
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
    // On an unconfirmed fetch, preserve the prior heavyFreed rather than letting a
    // null-blocked blip reset it to false and re-free next tick.
    state.sessions[session] = { lastContent: content, lastChange, heavyFreed: stateOk ? isBlocked : (prior?.heavyFreed ?? false), parkedSince, parkLogged, parkEscalated }
  }

  // Cap retired (completed-but-kept-alive) sessions so they don't accumulate in memory.
  // (Re-engagement of a finished task is the WATCHER's job now, via Pending → resume;
  // the un-retire sweep was removed 2026-06-25 — see its REMOVED note above.)
  pruneRetiredSessions()

  // Surface any session the Stop hook gave up on (livelock bound) to the operator.
  escalateStuckSessions()

  // Shut down booted dirty pool sims (idle, pending refresh) to relieve load even when
  // the watcher is load-gated and won't run ensure-sim-pool. Breaks the high-load loop.
  reclaimIdlePoolSims()

  // Kill Metro bundlers whose worktree was torn down or whose task session is gone.
  reapOrphanMetros(sessions)

  // Kill orphaned Android emulators + dead-monitor crashpad handlers.
  reapOrphanAndroid(state, now)

  // Drop watchman roots for worktrees with no session (fseventsd leak mitigation).
  reapStaleWatchmanRoots(sessions)

  // Surface booted sims held by hand-labeled (non-numeric-gid) pool allocations.
  escalateManualPoolHolds(state)

  // Restart a bloated fseventsd when the sudoers rule permits; log otherwise.
  guardFseventsd(state, now)

  // Enforce the worktree retention cap (keep newest N completed/retired worktrees).
  pruneRetainedWorktrees(sessions)

  // Surface silent death of the memory gate (detection only).
  checkMonitorHeartbeat()

  // Garbage-collect state for sessions that no longer exist
  for (const key of Object.keys(state.sessions)) {
    if (!sessions.includes(key)) delete state.sessions[key]
  }

  saveState(state)
}

main()
