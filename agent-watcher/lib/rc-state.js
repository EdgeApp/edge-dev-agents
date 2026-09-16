// rc-state.js: the ONE remote-control liveness check. session-watchdog.js (the
// actor: revives on DOWN) and lib/fleet-model.js (the view) both call this, so
// the two can never disagree about a pane again.
//
// Why two sources (diagnosed 2026-09-11):
//   1. The footer pill ("/rc", "/rc active", "/rc reconnecting", "/rc failed",
//      "/rc connecting…"). Authoritative whenever it is visible: it reflects the
//      live bridge state, including the failure states.
//   2. The session record ~/.claude/sessions/<pid>.json `bridgeSessionId`.
//      Claude Code >= 2.1.268 renders the pill only when the account's
//      `tengu_ccr_bridge` rollout flag is on (default off), so a connected
//      session can show NO pill at all. The record's bridge id is written when
//      the bridge registers; it proves RC was set up for this process, not that
//      the link is live this second. It is therefore only the FALLBACK, used
//      when the pill is absent. Pre-2.1.268 builds sometimes omit the field
//      while their pill shows, which is why the pill always wins.
//
// Known limit: on a pill-less build, a dropped link with a stale record reads
// UP, so the watchdog will not revive it. Accepted over the alternative (a
// false DOWN on every pill-less session: a respawn every 6h per anchor).

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')

const FOOTER_RE = /shift\+tab to cycle|for agents/
const PILL_RE = /(^|\s)\/rc(?: (active|failed|reconnecting|connecting\S*))?(?=\s|$)/
const PILL_ONLY_LINE_RE = /^\s*\/rc(?: (active|failed|reconnecting|connecting\S*))?\s*$/
const SESSIONS_DIR = path.join(os.homedir(), '.claude', 'sessions')

// Pill state from the pane's footer region (last 4 non-empty lines), so
// conversation text above that quotes "/rc failed" never counts.
// Returns 'up' | 'down' | null (no pill visible).
function pillState (content) {
  const tail = content.split('\n').filter(l => l.trim()).slice(-4)
  for (const l of tail) {
    // A pill sits on the footer line, or wraps onto its own line when the
    // footer is long (busy panes: "... esc to interrupt · ← for ag…" then "/rc").
    const onFooter = FOOTER_RE.test(l) && PILL_RE.test(l)
    const alone = PILL_ONLY_LINE_RE.test(l)
    if (!onFooter && !alone) continue
    const state = (l.match(PILL_RE) || [])[2] || 'active'
    return state === 'active' ? 'up' : 'down'
  }
  if (/Remote Control active/.test(tail.slice(-3).join('\n'))) return 'up' // oldest builds
  return null
}

function recordBridgeId (pid) {
  if (!pid) return ''
  try {
    const rec = JSON.parse(fs.readFileSync(path.join(SESSIONS_DIR, `${pid}.json`), 'utf8'))
    return typeof rec.bridgeSessionId === 'string' ? rec.bridgeSessionId : ''
  } catch { return '' }
}

// { up, source: 'pill' | 'record' | 'none', pill: 'up' | 'down' | null }
function rcState (content, pid) {
  const pill = pillState(content || '')
  if (pill) return { up: pill === 'up', source: 'pill', pill }
  if (recordBridgeId(pid)) return { up: true, source: 'record', pill: null }
  return { up: false, source: 'none', pill: null }
}

function rcBridgeUp (content, pid) { return rcState(content, pid).up }

module.exports = { rcState, rcBridgeUp, pillState, recordBridgeId }
