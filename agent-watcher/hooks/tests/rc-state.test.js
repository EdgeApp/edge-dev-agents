// Tests for lib/rc-state.js: the shared remote-control liveness check.
// Run: node ~/.config/agent-watcher/hooks/tests/rc-state.test.js
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const assert = require('node:assert')

const { rcState, pillState } = require('../../lib/rc-state.js')

const FOOT = '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'
const pane = (...tail) => ['some conversation text', '❯ ', '─'.repeat(40), ...tail].join('\n')

// A fake session record under the real sessions dir, keyed by an impossible pid.
const SESS = path.join(os.homedir(), '.claude', 'sessions')
const FAKE_PID = '999999991'
const FAKE_REC = path.join(SESS, `${FAKE_PID}.json`)

let failed = 0
function t (name, fn) {
  try { fn(); console.log(`ok   ${name}`) } catch (e) { failed++; console.log(`FAIL ${name}: ${e.message}`) }
}

t('compact pill on footer line -> up', () => assert.strictEqual(pillState(pane(`${FOOT}             /rc`)), 'up'))
t('verbose pill "/rc active" -> up', () => assert.strictEqual(pillState(pane(`${FOOT}      /rc active`)), 'up'))
t('"/rc reconnecting" -> down', () => assert.strictEqual(pillState(pane(`${FOOT} /rc reconnecting`)), 'down'))
t('"/rc failed" -> down', () => assert.strictEqual(pillState(pane(`${FOOT}      /rc failed`)), 'down'))
t('"/rc connecting…" -> down', () => assert.strictEqual(pillState(pane(`${FOOT} /rc connecting…`)), 'down'))
t('pill wrapped onto its own line (busy footer) -> up', () =>
  assert.strictEqual(pillState(pane('  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← for ag…', '                  /rc', '  ⧉  eval-tiers-map')), 'up'))
t('oldest build "Remote Control active" -> up', () => assert.strictEqual(pillState(pane('Remote Control active')), 'up'))
t('no pill -> null', () => assert.strictEqual(pillState(pane(FOOT, '  ⧉  taste-board · palette-picker')), null))
t('conversation text quoting "/rc failed" above the footer is ignored', () =>
  assert.strictEqual(pillState(['/rc failed', 'x', 'y', 'z', '❯ ', FOOT].join('\n')), null))

fs.mkdirSync(SESS, { recursive: true })
try {
  fs.writeFileSync(FAKE_REC, JSON.stringify({ pid: Number(FAKE_PID), bridgeSessionId: 'session_test' }))
  t('no pill + record bridge id -> up via record', () =>
    assert.deepStrictEqual(rcState(pane(FOOT), FAKE_PID), { up: true, source: 'record', pill: null }))
  t('failure pill beats a record bridge id -> down', () =>
    assert.strictEqual(rcState(pane(`${FOOT}      /rc failed`), FAKE_PID).up, false))
  fs.writeFileSync(FAKE_REC, JSON.stringify({ pid: Number(FAKE_PID) }))
  t('no pill + record without bridge id -> down', () =>
    assert.deepStrictEqual(rcState(pane(FOOT), FAKE_PID), { up: false, source: 'none', pill: null }))
} finally { fs.rmSync(FAKE_REC, { force: true }) }
t('no pill + no pid -> down', () => assert.strictEqual(rcState(pane(FOOT)).up, false))
t('no pill + missing record -> down', () => assert.strictEqual(rcState(pane(FOOT), FAKE_PID).up, false))
t('pill up without record (pre-2.1.268 shape) -> up via pill', () =>
  assert.deepStrictEqual(rcState(pane(`${FOOT}             /rc`), FAKE_PID), { up: true, source: 'pill', pill: 'up' }))

console.log(failed ? `\n${failed} failed` : '\nall passed')
process.exit(failed ? 1 : 0)
