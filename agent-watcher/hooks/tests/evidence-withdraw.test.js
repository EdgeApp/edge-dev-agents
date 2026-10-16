// Tests for pr-evidence-withdraw.sh: a withdrawn frame leaves the bucket, the
// manifest and the PR body's table, and nothing else moves.
// Run: node ~/.config/agent-watcher/hooks/tests/evidence-withdraw.test.js
//
// Nothing here reaches GitHub or the real bucket: `gh` is a shim on PATH that
// logs its arguments and answers from files, and the bucket is a local server
// named by EVIDENCE_BUCKET_CONFIG. Frames are drawn at run time and attached
// with pr-attach-screenshots.sh, so the manifest under test is one the attach
// script wrote. EVIDENCE_SCRIPTS points the test at another copy of the scripts.
const assert = require('node:assert')
const cp = require('node:child_process')
const fs = require('node:fs')
const http = require('node:http')
const os = require('node:os')
const path = require('node:path')

const SCRIPTS = process.env.EVIDENCE_SCRIPTS || path.join(os.homedir(), '.cursor/skills/pr-create/scripts')
const ATTACH = path.join(SCRIPTS, 'pr-attach-screenshots.sh')
const WITHDRAW = path.join(SCRIPTS, 'pr-evidence-withdraw.sh')
const PRIVACY = path.join(SCRIPTS, 'evidence-privacy.sh')

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'evidence-withdraw-test-'))
process.on('exit', () => fs.rmSync(TMP, { recursive: true, force: true }))

const REPO = 'acme/edge-widget'
const PR = '7'
const MANIFEST_KEY = `manifests/${REPO}/pr-${PR}.json`
const HEAD = 'a'.repeat(40)
const START = '<!-- agent-test-evidence:start -->'

// Fake bucket: an S3-shaped object store that records every request.
const objects = new Map()
let requests = []
let failManifestPut = false
const server = http.createServer((req, res) => {
  const chunks = []
  req.on('data', c => chunks.push(c))
  req.on('end', () => {
    const key = decodeURIComponent(new URL(req.url, 'http://x').pathname.replace(/^\/[^/]+\/?/, ''))
    requests.push({ method: req.method, key })
    if (req.method === 'PUT') {
      if (failManifestPut && key === MANIFEST_KEY) { res.writeHead(500); return res.end('<Error>boom</Error>') }
      objects.set(key, Buffer.concat(chunks)); res.writeHead(200); return res.end()
    }
    if (req.method === 'DELETE') { objects.delete(key); res.writeHead(204); return res.end() }
    if (!objects.has(key)) { res.writeHead(404); return res.end('<Error><Code>NoSuchKey</Code></Error>') }
    res.writeHead(200)
    res.end(req.method === 'HEAD' ? undefined : objects.get(key))
  })
})

// Fake gh: logs argv, answers from files in GH_DIR. A body edit becomes the
// body the next read returns, as on GitHub.
const GH_DIR = path.join(TMP, 'gh')
const BIN = path.join(TMP, 'bin')
fs.mkdirSync(GH_DIR)
fs.mkdirSync(BIN)
fs.writeFileSync(path.join(BIN, 'gh'), `#!/usr/bin/env node
const fs = require('fs')
const path = require('path')
const dir = ${JSON.stringify(GH_DIR)}
const a = process.argv.slice(2)
fs.appendFileSync(path.join(dir, 'log'), JSON.stringify(a) + '\\n')
const read = f => fs.readFileSync(path.join(dir, f), 'utf8')
if (a[0] === 'api' && a[1] === 'graphql') { process.stdout.write(read('pr.json')); process.exit(0) }
// The comment lists, one JSON object per line as --jq '.[]' prints them.
const list = a[0] === 'api' && a[1] === '--paginate' && /^repos[/][^/]+[/][^/]+[/](issues|pulls)[/][0-9]+[/](comments|reviews)$/.exec(a[2])
if (list) {
  const f = path.join(dir, list[1] + '-' + list[2] + '.json')
  if (fs.existsSync(path.join(dir, 'fail-comments'))) { process.stderr.write('HTTP 502'); process.exit(1) }
  for (const c of fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')) : []) process.stdout.write(JSON.stringify(c) + '\\n')
  process.exit(0)
}
if (a[0] === 'api' && /^repos\\/[^/]+\\/[^/]+\\/pulls\\/\\d+$/.test(a[1])) { process.stdout.write(read('body.md')); process.exit(0) }
if (a[0] === 'pr' && a[1] === 'edit') { fs.copyFileSync(a[a.indexOf('--body-file') + 1], path.join(dir, 'body.md')); process.exit(0) }
process.stderr.write('fake gh: unexpected call ' + JSON.stringify(a) + '\\n')
process.exit(1)
`, { mode: 0o755 })

const prState = (author = 'the-author') => JSON.stringify({ data: { viewer: { login: 'the-author' }, repository: { pullRequest: {
  author: { login: author },
  headRefOid: HEAD,
  commits: { nodes: [{ commit: { oid: HEAD, messageHeadline: 'Do the thing' } }] },
  reviews: { nodes: [] },
  comments: { nodes: [] },
  reviewThreads: { nodes: [] }
} } } })
const PR_STATE = prState()

const ROSTER = path.join(TMP, 'roster.json')
fs.writeFileSync(ROSTER, JSON.stringify({ roster: { agent: { username: 'zq-probe-41x', pin: '1111' } } }))
const BUCKET_CFG = path.join(TMP, 'r2.json')
const env = () => ({ ...process.env, PATH: `${BIN}:${process.env.PATH}`, EVIDENCE_ROSTER: ROSTER, EVIDENCE_BUCKET_CONFIG: BUCKET_CFG })

const FRAMES = {
  '01-wallet-list': ['Wallets', 'My Bitcoin', '0.01234 BTC', 'Send', 'Receive'],
  '02-settings': ['Settings', 'Auto log off', 'Default currency', 'Dark mode'],
  '03-send-scene': ['Send', 'Amount', 'Recipient address', 'Slide to confirm']
}
const frame = name => path.join(TMP, `${name}.png`)

// Async on purpose: the bucket server lives in this process, and a spawnSync
// would stop it answering the script under test.
function run (script, args) {
  return new Promise(resolve => {
    const child = cp.spawn(script, args, { env: env() })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', d => { stdout += d })
    child.stderr.on('data', d => { stderr += d })
    child.on('close', status => resolve({ status, stdout, stderr }))
  })
}
const forPr = args => ['--repo', REPO, '--pr', PR, ...args]
const withdraw = (...args) => run(WITHDRAW, forPr(args))

const body = () => fs.readFileSync(path.join(GH_DIR, 'body.md'), 'utf8')
const manifest = () => JSON.parse(objects.get(MANIFEST_KEY).toString('utf8'))
const frameKeys = () => [...objects.keys()].filter(k => k !== MANIFEST_KEY).sort()
const urlOf = scene => manifest().entries.find(e => e.url.includes(scene)).url
const ghEdits = () => fs.readFileSync(path.join(GH_DIR, 'log'), 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)).filter(a => a[0] === 'pr').length
const snapshot = () => JSON.stringify([[...objects.entries()].map(([k, v]) => [k, v.toString('base64')]), body()])

// A fresh world per case: the PR with the named frames attached.
async function seed (...names) {
  objects.clear()
  failManifestPut = false
  for (const f of fs.readdirSync(GH_DIR)) fs.rmSync(path.join(GH_DIR, f))
  fs.writeFileSync(path.join(GH_DIR, 'pr.json'), PR_STATE)
  fs.writeFileSync(path.join(GH_DIR, 'body.md'), 'A PR description.\n')
  if (names.length) {
    const r = await run(ATTACH, forPr(names.map(frame)))
    assert.strictEqual(r.status, 0, `seeding attach failed: ${r.stderr}`)
  }
  fs.rmSync(path.join(GH_DIR, 'log'), { force: true })
  fs.writeFileSync(path.join(GH_DIR, 'log'), '')
  requests = []
}

let failed = 0
async function t (name, fn) {
  try { await fn(); console.log(`ok   ${name}`) } catch (e) { failed++; console.log(`FAIL ${name}: ${e.message}`) }
}

async function main () {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  const port = server.address().port
  fs.writeFileSync(BUCKET_CFG, JSON.stringify({ endpoint: `http://127.0.0.1:${port}`, accessKeyId: 'test', secretAccessKey: 'test', bucket: 'test-bucket', publicBaseUrl: 'https://bucket.test' }))

  for (const [name, lines] of Object.entries(FRAMES)) {
    const specs = lines.map((l, i) => `80,${120 + i * 70},36,${l}`)
    const r = await run(PRIVACY, ['render', frame(name), '1000', '1400', ...specs])
    if (r.status !== 0) { console.log(`FAIL cannot render ${name}: ${r.stderr}`); process.exit(1) }
  }

  await t('withdrawing one scene deletes its object, its manifest entry and its table cell', async () => {
    await seed('01-wallet-list', '02-settings')
    assert.strictEqual(frameKeys().length, 2)
    const gone = urlOf('wallet-list')
    const kept = urlOf('settings')
    const r = await withdraw('wallet-list')
    assert.strictEqual(r.status, 0, r.stderr)
    assert.deepStrictEqual(frameKeys().map(k => `https://bucket.test/${k}`), [kept])
    assert.deepStrictEqual(manifest().entries.map(e => e.url), [kept])
    assert.ok(!body().includes(gone), 'the body still shows the withdrawn frame')
    assert.ok(body().includes(kept))
    assert.ok(body().startsWith('A PR description.'))
    assert.strictEqual(ghEdits(), 1)
  })

  await t('the manifest is written after the object delete and the body edit', async () => {
    const writes = requests.filter(r => r.method === 'DELETE' || r.method === 'PUT').map(r => `${r.method} ${r.key === MANIFEST_KEY ? 'manifest' : 'frame'}`)
    assert.deepStrictEqual(writes, ['DELETE frame', 'PUT manifest'])
  })

  await t('a hosted URL names a frame as well as a scene does', async () => {
    await seed('01-wallet-list', '02-settings')
    const gone = urlOf('settings')
    const r = await withdraw(gone)
    assert.strictEqual(r.status, 0, r.stderr)
    assert.ok(!manifest().entries.some(e => e.url === gone))
    assert.strictEqual(frameKeys().length, 1)
  })

  await t('an unmatched frame exits 1, lists the scenes and changes nothing', async () => {
    await seed('01-wallet-list', '02-settings')
    const before = snapshot()
    const r = await withdraw('wallet-list', 'no-such-scene')
    assert.strictEqual(r.status, 1)
    assert.match(r.stderr, /nothing changed/)
    assert.match(r.stderr, /no-such-scene/)
    assert.match(r.stderr, /settings/)
    assert.strictEqual(snapshot(), before)
    assert.strictEqual(requests.filter(q => q.method !== 'GET' && q.method !== 'HEAD').length, 0)
    assert.strictEqual(ghEdits(), 0)
  })

  await t('a dry run prints the plan and changes nothing', async () => {
    await seed('01-wallet-list', '02-settings')
    const before = snapshot()
    const r = await withdraw('--dry-run', 'wallet-list')
    assert.strictEqual(r.status, 0, r.stderr)
    assert.match(r.stdout, /would withdraw wallet-list https:\/\/bucket\.test\//)
    assert.strictEqual(snapshot(), before)
    assert.strictEqual(ghEdits(), 0)
  })

  await t('withdrawing the last frame removes the whole evidence block', async () => {
    await seed('01-wallet-list')
    assert.ok(body().includes(START))
    const r = await withdraw('wallet-list')
    assert.strictEqual(r.status, 0, r.stderr)
    assert.strictEqual(body().trim(), 'A PR description.')
    assert.deepStrictEqual(manifest().entries, [])
    assert.deepStrictEqual(frameKeys(), [])
  })

  await t('a run that fails at the manifest write is finished by running it again', async () => {
    await seed('01-wallet-list', '02-settings', '03-send-scene')
    const gone = urlOf('send-scene')
    failManifestPut = true
    const first = await withdraw('send-scene')
    assert.strictEqual(first.status, 1)
    assert.match(first.stderr, /manifest write failed/)
    assert.strictEqual(frameKeys().length, 2, 'the object outlived a failed run')
    assert.strictEqual(manifest().entries.length, 3, 'the manifest moved on a failed write')
    failManifestPut = false
    const second = await withdraw('send-scene')
    assert.strictEqual(second.status, 0, second.stderr)
    assert.ok(!manifest().entries.some(e => e.url === gone))
    assert.strictEqual(manifest().entries.length, 2)
    assert.ok(!body().includes(gone))
  })

  await t('a withdrawn URL quoted outside the table is named on stderr', async () => {
    await seed('01-wallet-list', '02-settings')
    const gone = urlOf('wallet-list')
    fs.appendFileSync(path.join(GH_DIR, 'body.md'), `\nSee ${gone} for the list.\n`)
    const r = await withdraw('wallet-list')
    assert.strictEqual(r.status, 0, r.stderr)
    assert.ok(r.stderr.includes(`WARN: ${gone} is still quoted`))
    assert.match(r.stderr, /pr-evidence-relink\.sh/)
  })

  await t('a PR another account opened is refused and nothing changes', async () => {
    await seed('01-wallet-list', '02-settings')
    fs.writeFileSync(path.join(GH_DIR, 'pr.json'), prState('someone-else'))
    const before = snapshot()
    const r = await withdraw('wallet-list')
    assert.strictEqual(r.status, 1)
    assert.match(r.stderr, /opened by someone-else, not the-author: nothing changed/)
    assert.strictEqual(snapshot(), before)
    assert.strictEqual(requests.length, 0, 'the bucket was touched')
    assert.strictEqual(ghEdits(), 0)
  })

  await t('a withdrawn URL quoted in a PR comment or review is named, and no comment is edited', async () => {
    await seed('01-wallet-list', '02-settings')
    const gone = urlOf('wallet-list')
    const kept = urlOf('settings')
    fs.writeFileSync(path.join(GH_DIR, 'issues-comments.json'), JSON.stringify([
      { html_url: 'https://gh.test/c/1', body: `Look: ![x](${gone})` },
      { html_url: 'https://gh.test/c/2', body: `Only ${kept}` }
    ]))
    fs.writeFileSync(path.join(GH_DIR, 'pulls-comments.json'), JSON.stringify([{ html_url: 'https://gh.test/rc/3', body: gone }]))
    fs.writeFileSync(path.join(GH_DIR, 'pulls-reviews.json'), JSON.stringify([{ html_url: 'https://gh.test/r/4', body: null }]))
    const r = await withdraw('wallet-list')
    assert.strictEqual(r.status, 0, r.stderr)
    assert.ok(r.stderr.includes(`WARN: ${gone} is quoted in a PR comment https://gh.test/c/1`))
    assert.ok(r.stderr.includes(`WARN: ${gone} is quoted in a PR comment https://gh.test/rc/3`))
    assert.ok(!r.stderr.includes('https://gh.test/c/2'))
    assert.ok(!r.stderr.includes('https://gh.test/r/4'))
    assert.strictEqual(ghEdits(), 1, 'only the body edit')
  })

  await t('a dry run names quoting comments too', async () => {
    await seed('01-wallet-list', '02-settings')
    const gone = urlOf('wallet-list')
    fs.writeFileSync(path.join(GH_DIR, 'issues-comments.json'), JSON.stringify([{ html_url: 'https://gh.test/c/9', body: gone }]))
    const r = await withdraw('--dry-run', 'wallet-list')
    assert.strictEqual(r.status, 0, r.stderr)
    assert.ok(r.stderr.includes('is quoted in a PR comment https://gh.test/c/9'))
    assert.strictEqual(ghEdits(), 0)
  })

  await t('a failed comment read is a WARN and the withdraw still finishes', async () => {
    await seed('01-wallet-list', '02-settings')
    fs.writeFileSync(path.join(GH_DIR, 'fail-comments'), '')
    const r = await withdraw('wallet-list')
    assert.strictEqual(r.status, 0, r.stderr)
    assert.match(r.stderr, /WARN: could not read repos\/acme\/edge-widget\/issues\/7\/comments/)
    assert.match(r.stderr, /PASS: withdrew 1 frame/)
  })

  await t('no manifest for the PR exits 1 with nothing to withdraw', async () => {
    await seed()
    const r = await withdraw('wallet-list')
    assert.strictEqual(r.status, 1)
    assert.match(r.stderr, /no evidence manifest/)
    assert.strictEqual(ghEdits(), 0)
  })

  await t('missing arguments are a usage error', async () => {
    const r = await run(WITHDRAW, ['--repo', REPO, '--pr', PR])
    assert.strictEqual(r.status, 1)
    assert.match(r.stderr, /^Usage: /)
  })

  server.close()
  if (failed) { console.log(`\n${failed} failed`); process.exit(1) }
  console.log('\nall passed')
}

main()
