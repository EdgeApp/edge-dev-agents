// Tests for pr-evidence-table.js: the evidence table's data model, as plain
// function calls. Nothing here touches the network, gh or the bucket.
// Run: node ~/.config/agent-watcher/hooks/tests/pr-evidence-table.test.js
// EVIDENCE_SCRIPTS points the test at another copy of the scripts.
const assert = require('node:assert')
const os = require('node:os')
const path = require('node:path')

const SCRIPTS = process.env.EVIDENCE_SCRIPTS || path.join(os.homedir(), '.cursor/skills/pr-create/scripts')
const m = require(path.join(SCRIPTS, 'pr-evidence-table.js'))

let failed = 0
function t (name, fn) {
  try { fn(); console.log(`ok   ${name}`) } catch (e) { failed++; console.log(`FAIL ${name}: ${e.message}`) }
}

const S = '<!-- agent-test-evidence:start -->'
const E = '<!-- agent-test-evidence:end -->'
const count = (body, needle) => body.split(needle).length - 1

t('splice appends one block to a body that has none', () => {
  const out = m.splice('A description.\n', '<table>new</table>')
  assert.ok(out.startsWith('A description.\n\n' + S))
  assert.strictEqual(count(out, S), 1)
  assert.strictEqual(count(out, E), 1)
})
t('splice replaces between the sentinels and leaves the rest alone', () => {
  const out = m.splice(`Top.\n\n${S}\nold\n${E}\n\nBottom.\n`, '<table>new</table>')
  assert.ok(out.startsWith('Top.\n\n' + S))
  assert.ok(out.endsWith(E + '\n\nBottom.\n'))
  assert.ok(!out.includes('old'))
  assert.strictEqual(count(out, S), 1)
})
t('splice is stable across a second run', () => {
  const once = m.splice('A description.\n', '<table>new</table>')
  assert.strictEqual(m.splice(once, '<table>new</table>'), once)
})
for (const [name, body] of [
  ['a start sentinel with no end', `Top.\n${S}\nold\n`],
  ['an end sentinel with no start', `Top.\nold\n${E}\n`],
  ['an end sentinel above the start', `Top.\n${E}\n${S}\nold\n`],
  ['a stray end sentinel above a whole pair', `Top.\n${E}\n${S}\nold\n${E}\n`]
]) {
  t(`splice throws on ${name}`, () => assert.throws(() => m.splice(body, '<table>new</table>'), /broken evidence block/))
}

for (const [file, index, caption] of [
  ['02-settings.png', '2', 'settings'],
  ['20261001-120000-agent-proof-1234567890123456-03-send-scene.png', '3', 'send scene'],
  ['02-2-factor-prompt.png', '2', '2 factor prompt'],
  ['1234567890123456-04-24-word-backup.png', '4', '24 word backup'],
  ['login.png', null, 'login']
]) {
  t(`parseName reads ${file}`, () => {
    const p = m.parseName(file)
    assert.strictEqual(p.index, index)
    assert.strictEqual(p.caption, caption)
  })
}
t('parseName lifts the marker tokens out of the caption', () => {
  const p = m.parseName('05-HACKED-BEFORE-swap-quote.png')
  assert.deepStrictEqual(p, { caption: 'swap quote', index: '5', hacked: true, phase: 'before' })
})

const entry = (file, batchAt, extra) => ({ path: file, url: `https://bucket.test/k/${file}`, batchAt, headSha: 'a'.repeat(40), ...m.parseName(file), ...extra })
const T1 = '2026-10-01T10:00:00Z'
const T2 = '2026-10-02T10:00:00Z'
const T3 = '2026-10-03T10:00:00Z'

t('mergeManifest replaces a re-shot frame inside its batch', () => {
  const first = m.mergeManifest(null, [entry('01-login.png', T1), entry('02-send.png', T1)])
  const again = m.mergeManifest(first, [entry('20261001-110000-01-login.png', T1, { url: 'https://bucket.test/k/new.png' })])
  assert.strictEqual(again.entries.length, 2)
  assert.strictEqual(again.entries[0].url, 'https://bucket.test/k/new.png')
})
t('mergeManifest appends a same-named frame from a later batch', () => {
  const first = m.mergeManifest(null, [entry('01-login.png', T1)])
  assert.strictEqual(m.mergeManifest(first, [entry('01-login.png', T2)]).entries.length, 2)
})
t('mergeManifest keeps a BEFORE and AFTER pair as two frames', () => {
  const out = m.mergeManifest(null, [entry('01-BEFORE-login.png', T1), entry('01-AFTER-login.png', T1)])
  assert.strictEqual(out.entries.length, 2)
})

const three = { version: 2, entries: [entry('01-login.png', T1), entry('01-login.png', T2), entry('01-login.png', T3)] }
t('pruneBatches keeps only the newest batch when no human acted', () => {
  const { manifest, dropped } = m.pruneBatches(three, [])
  assert.deepStrictEqual(manifest.entries.map(e => e.batchAt), [T3])
  assert.deepStrictEqual(dropped.map(b => b.batchAt), [T1, T2])
})
t('pruneBatches keeps a batch a human acted on before the next one landed', () => {
  const { manifest } = m.pruneBatches(three, ['2026-10-01T12:00:00Z'])
  assert.deepStrictEqual(manifest.entries.map(e => e.batchAt), [T1, T3])
})
t('pruneBatches ignores an unparseable timestamp', () => {
  assert.deepStrictEqual(m.pruneBatches(three, ['not a date']).manifest.entries.map(e => e.batchAt), [T3])
})
t('wouldRetire names what a new batch would drop and changes nothing', () => {
  const one = { version: 2, entries: [entry('01-login.png', T1)] }
  assert.deepStrictEqual(m.wouldRetire(one, [], T2).map(b => b.batchAt), [T1])
  assert.deepStrictEqual(m.wouldRetire(one, ['2026-10-01T12:00:00Z'], T2), [])
  assert.strictEqual(one.entries.length, 1)
})

const opts = { repo: 'Org/repo', pr: 7, commits: [{ sha: 'a'.repeat(40), subject: 'Fix <b> & more' }] }
t('render numbers the cell, escapes the subject and links a live commit', () => {
  const html = m.render({ version: 2, entries: [entry('02-send-scene.png', T1)] }, opts)
  assert.ok(html.includes('<b>2.</b> send scene'))
  assert.ok(html.includes('Fix &lt;b&gt; &amp; more'))
  assert.ok(html.includes(`/pull/7/commits/${'a'.repeat(40)}`))
})
t('render does not link a commit the PR no longer has', () => {
  const html = m.render({ version: 2, entries: [entry('02-send-scene.png', T1)] }, { ...opts, commits: [] })
  assert.ok(!html.includes('/commits/'))
})
t('render keeps a url with a quote inside its attribute', () => {
  const bad = 'https://bucket.test/k/a.png"><img src=x onerror="1'
  const html = m.render({ version: 2, entries: [entry('02-send-scene.png', T1, { url: bad })] }, opts)
  assert.ok(!html.includes(bad))
  assert.strictEqual(count(html, '<img '), 1)
})
t('render marks a hacked frame and prints its note once per batch', () => {
  const html = m.render({ version: 2, entries: [
    entry('01-HACKED-quote.png', T1, { hackNote: 'forced the rate' }),
    entry('02-HACKED-confirm.png', T1, { hackNote: 'forced the rate' })
  ] }, opts)
  assert.strictEqual(count(html, 'forced the rate'), 1)
  assert.strictEqual(count(html, '🪓 quote'), 1)
})

console.log(failed === 0 ? '\nall passed' : `\n${failed} failed`)
process.exit(failed === 0 ? 0 : 1)
