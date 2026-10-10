// Tests for pr-attach-screenshots.sh: the privacy gate ahead of every upload,
// and the frames and manifest hosted in the bucket with no write to a git
// branch.
// Run: node ~/.config/agent-watcher/hooks/tests/evidence-attach.test.js
//
// Nothing here reaches GitHub or the real bucket: `gh` is a shim on PATH that
// logs its arguments and answers from files, and the bucket is a local server
// named by EVIDENCE_BUCKET_CONFIG. Frames are drawn at run time from a published
// BIP39 test vector and made-up account names; the real roster is never read.
// EVIDENCE_SCRIPTS points the test at another copy of the scripts.
const assert = require('node:assert')
const cp = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const http = require('node:http')
const os = require('node:os')
const path = require('node:path')

const SCRIPTS = process.env.EVIDENCE_SCRIPTS || path.join(os.homedir(), '.cursor/skills/pr-create/scripts')
const ATTACH = path.join(SCRIPTS, 'pr-attach-screenshots.sh')
const PRIVACY = path.join(SCRIPTS, 'evidence-privacy.sh')

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'evidence-attach-test-'))
process.on('exit', () => fs.rmSync(TMP, { recursive: true, force: true }))

const REPO = 'acme/edge-widget'
const PR = '7'
const MANIFEST_KEY = `manifests/${REPO}/pr-${PR}.json`
const HEAD_A = 'a'.repeat(40)
const HEAD_B = 'b'.repeat(40)
const LEGACY_BRANCH = 'agent-pr-assets'

// ── Fake bucket: an S3-shaped object store that records every request ────────
const objects = new Map()
let requests = []
let failGets = false
const server = http.createServer((req, res) => {
  const chunks = []
  req.on('data', c => chunks.push(c))
  req.on('end', () => {
    const key = decodeURIComponent(new URL(req.url, 'http://x').pathname.replace(/^\/[^/]+\/?/, ''))
    requests.push({ method: req.method, key })
    if (req.method === 'PUT') { objects.set(key, Buffer.concat(chunks)); res.writeHead(200); return res.end() }
    if (req.method === 'GET' && failGets) { res.writeHead(500); return res.end('<Error>boom</Error>') }
    if (req.method === 'DELETE') { objects.delete(key); res.writeHead(204); return res.end() }
    if (!objects.has(key)) { res.writeHead(404); return res.end('<Error><Code>NoSuchKey</Code></Error>') }
    res.writeHead(200)
    res.end(req.method === 'HEAD' ? undefined : objects.get(key))
  })
})

// ── Fake gh: logs argv, answers from files in GH_DIR ─────────────────────────
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
const has = f => fs.existsSync(path.join(dir, f))
const read = f => fs.readFileSync(path.join(dir, f), 'utf8')
if (a[0] === 'api' && a[1] === 'graphql') { process.stdout.write(read('pr.json')); process.exit(0) }
if (a[0] === 'api' && /^repos\\/[^/]+\\/[^/]+\\/contents\\//.test(a[1])) {
  if (has('legacy-broken')) { process.stderr.write('gh: Server Error (HTTP 502)\\n'); process.exit(1) }
  if (!has('legacy.json')) { process.stderr.write('gh: Not Found (HTTP 404)\\n'); process.exit(1) }
  process.stdout.write(Buffer.from(read('legacy.json')).toString('base64') + '\\n'); process.exit(0)
}
if (a[0] === 'api' && /^repos\\/[^/]+\\/[^/]+\\/pulls\\/\\d+$/.test(a[1])) { process.stdout.write(read('body.md')); process.exit(0) }
if (a[0] === 'pr' && a[1] === 'edit') { fs.copyFileSync(a[a.indexOf('--body-file') + 1], path.join(dir, 'body.out')); process.exit(0) }
process.stderr.write('fake gh: unexpected call ' + JSON.stringify(a) + '\\n')
process.exit(1)
`, { mode: 0o755 })

function prState (head, humanAt) {
  return JSON.stringify({ data: { repository: { pullRequest: {
    author: { login: 'the-author' },
    headRefOid: head,
    commits: { nodes: [{ commit: { oid: head, messageHeadline: 'Do the thing' } }] },
    reviews: { nodes: humanAt ? [{ createdAt: humanAt, author: { login: 'a-reviewer', __typename: 'User' } }] : [] },
    comments: { nodes: [] },
    reviewThreads: { nodes: [] }
  } } } })
}

// A fresh world per case: empty bucket, empty gh log, PR at HEAD_A.
function reset ({ head = HEAD_A } = {}) {
  objects.clear()
  requests = []
  failGets = false
  for (const f of fs.readdirSync(GH_DIR)) fs.rmSync(path.join(GH_DIR, f))
  fs.writeFileSync(path.join(GH_DIR, 'pr.json'), prState(head))
  fs.writeFileSync(path.join(GH_DIR, 'body.md'), 'A PR description.\n')
}
const ghLog = () => fs.existsSync(path.join(GH_DIR, 'log')) ? fs.readFileSync(path.join(GH_DIR, 'log'), 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)) : []
const puts = () => requests.filter(r => r.method === 'PUT').map(r => r.key)
const framePuts = () => puts().filter(k => k !== MANIFEST_KEY)
const manifest = () => JSON.parse(objects.get(MANIFEST_KEY).toString('utf8'))
const bodyOut = () => fs.readFileSync(path.join(GH_DIR, 'body.out'), 'utf8')
const sha = f => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex')

// Made-up accounts and a published BIP39 vector.
const USER = 'zq-probe-41x'
const ROSTER = path.join(TMP, 'roster.json')
fs.writeFileSync(ROSTER, JSON.stringify({ roster: { agent: { username: USER, pin: '1111' } } }))
const BIP39_12 = 'legal winner thank year wave sausage worth useful legal winner thank yellow'.split(' ')

const BUCKET_CFG = path.join(TMP, 'r2.json')
let ENV = null
function env (extra) {
  return { ...process.env, PATH: `${BIN}:${process.env.PATH}`, EVIDENCE_ROSTER: ROSTER, EVIDENCE_BUCKET_CONFIG: BUCKET_CFG, ...extra }
}

const FRAMES = {
  '01-wallet-list': ['Wallets', 'My Bitcoin', '0.01234 BTC', 'Send', 'Receive'],
  '02-settings': ['Settings', 'Auto log off', 'Default currency', 'Dark mode'],
  '03-seed-shown': ['Write these words down', BIP39_12.slice(0, 4).join(' '), BIP39_12.slice(4, 8).join(' '), BIP39_12.slice(8).join(' ')],
  '04-login': ['Sign In', 'Username', USER, '', 'Next']
}
const frame = name => path.join(TMP, `${name}.png`)

function run (args, extra) {
  return new Promise(resolve => {
    const child = cp.spawn(ATTACH, ['--repo', REPO, '--pr', PR, ...args], { env: env(extra) })
    let stderr = ''
    child.stderr.on('data', d => { stderr += d })
    child.stdout.resume()
    child.on('close', status => resolve({ status, stderr }))
  })
}
// The detector's verdict on some bytes, with the test roster.
function verdict (bytes, name) {
  const f = path.join(TMP, name)
  fs.writeFileSync(f, bytes)
  const r = cp.spawnSync(PRIVACY, ['classify', '--roster', ROSTER, f], { encoding: 'utf8', env: ENV })
  return JSON.parse(r.stdout.trim()).class
}

let failed = 0
async function t (name, fn) {
  try { await fn(); console.log(`ok   ${name}`) } catch (e) { failed++; console.log(`FAIL ${name}: ${e.message}`) }
}

async function main () {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  const port = server.address().port
  fs.writeFileSync(BUCKET_CFG, JSON.stringify({ endpoint: `http://127.0.0.1:${port}`, accessKeyId: 'test', secretAccessKey: 'test', bucket: 'test-bucket', publicBaseUrl: 'https://bucket.test' }))
  ENV = env()

  for (const [name, lines] of Object.entries(FRAMES)) {
    const specs = lines.map((l, i) => `80,${120 + i * 70},36,${l}`).filter(s => !s.endsWith(','))
    const r = cp.spawnSync(PRIVACY, ['render', frame(name), '1000', '1400', ...specs], { encoding: 'utf8', env: ENV })
    if (r.status !== 0) { console.log(`FAIL cannot render ${name}: ${r.stderr}`); process.exit(1) }
  }

  await t('clean attach: frame and manifest land in the bucket, the body gets the table', async () => {
    reset()
    const r = await run([frame('01-wallet-list')])
    assert.strictEqual(r.status, 0, r.stderr)
    assert.strictEqual(framePuts().length, 1)
    assert.match(framePuts()[0], /^widget7\/001-wallet-list-[0-9a-f]{6}\.png$/)
    const man = manifest()
    assert.strictEqual(man.entries.length, 1)
    assert.strictEqual(man.entries[0].url, `https://bucket.test/${framePuts()[0]}`)
    assert.strictEqual(man.entries[0].headSha, HEAD_A)
    assert.ok(bodyOut().startsWith('A PR description.'))
    assert.ok(bodyOut().includes(man.entries[0].url))
    assert.ok(!bodyOut().includes('raw.githubusercontent.com'))
  })

  await t('clean attach: gh is only read, apart from the one body edit', async () => {
    const calls = ghLog()
    assert.deepStrictEqual(calls.map(a => a.slice(0, 2).join(' ')), ['api graphql', `api repos/EdgeApp/edge-dev-agents/contents/assets/edge-widget/pr-${PR}/manifest.json?ref=${LEGACY_BRANCH}`, `api repos/${REPO}/pulls/${PR}`, 'pr edit'])
    for (const a of calls) {
      if (a[0] !== 'api' || a[1] === 'graphql') continue
      assert.ok(!a.some(x => /^(-X|--method|-f|-F|--field|--raw-field|--input)$/.test(x)), `a write-shaped gh api call: ${a.join(' ')}`)
      assert.ok(!/\/git\//.test(a[1]), `a git-data call: ${a[1]}`)
    }
  })

  await t('second attach at the same head reads the bucket manifest, not the branch', async () => {
    fs.rmSync(path.join(GH_DIR, 'log'))
    requests = []
    const r = await run([frame('02-settings')])
    assert.strictEqual(r.status, 0, r.stderr)
    assert.strictEqual(manifest().entries.length, 2)
    assert.ok(!ghLog().some(a => a.join(' ').includes(LEGACY_BRANCH)), 'the legacy branch was read although the bucket had the manifest')
  })

  await t('SECRET frame refuses the whole run: exit 3, frame and reason named, nothing sent anywhere', async () => {
    reset()
    const r = await run([frame('01-wallet-list'), frame('03-seed-shown')])
    assert.strictEqual(r.status, 3, r.stderr)
    assert.ok(r.stderr.includes(frame('03-seed-shown')), 'the refusal does not name the frame')
    assert.match(r.stderr, /BIP39/)
    assert.ok(!r.stderr.includes(frame('01-wallet-list')), 'a clean frame was named in the refusal')
    assert.ok(!/sausage|yellow/.test(r.stderr), 'the refusal repeats the seed')
    assert.strictEqual(requests.length, 0)
    assert.strictEqual(ghLog().length, 0)
  })

  await t('USERNAME frame uploads a hatched copy and leaves the original alone', async () => {
    reset()
    const before = sha(frame('04-login'))
    const r = await run([frame('04-login')])
    assert.strictEqual(r.status, 0, r.stderr)
    assert.match(r.stderr, /hatched the account name \(agent\)/)
    assert.ok(!r.stderr.includes(USER), 'the log repeats the account name')
    assert.strictEqual(sha(frame('04-login')), before)
    assert.strictEqual(framePuts().length, 1)
    assert.strictEqual(verdict(objects.get(framePuts()[0]), 'uploaded-login.png'), 'clean')
    // The same frame through the same downscale, without the gate, still shows
    // the name: the clean verdict above comes from the hatch.
    const scaled = path.join(TMP, 'scaled-control.png')
    cp.spawnSync('sips', ['--resampleWidth', '720', frame('04-login'), '--out', scaled])
    assert.strictEqual(verdict(fs.readFileSync(scaled), 'control-login.png'), 'USERNAME')
    assert.match(manifest().entries[0].path, /04-login\.png$/)
  })

  await t('a detector that cannot run refuses: exit 3, nothing sent anywhere', async () => {
    reset()
    const r = await run([frame('01-wallet-list')], { FRAME_VISION: path.join(TMP, 'no-such-reader') })
    assert.strictEqual(r.status, 3, r.stderr)
    assert.strictEqual(requests.length, 0)
    assert.strictEqual(ghLog().length, 0)
  })

  await t('an unreadable frame refuses: exit 3, nothing sent anywhere', async () => {
    reset()
    const junk = path.join(TMP, '05-not-an-image.png')
    fs.writeFileSync(junk, 'not a png')
    const r = await run([frame('01-wallet-list'), junk])
    assert.strictEqual(r.status, 3, r.stderr)
    assert.ok(r.stderr.includes(junk))
    assert.strictEqual(requests.length, 0)
    assert.strictEqual(ghLog().length, 0)
  })

  await t('legacy manifest on the branch is read once and moves to the bucket', async () => {
    reset()
    const old = { path: `assets/edge-widget/pr-${PR}/20260901-101010-agent-proof-1-01-old-scene.png`, caption: 'old scene', index: '01', hacked: false, batchAt: '2026-09-01T10:10:10Z', headSha: HEAD_A, addedAt: '2026-09-01T10:10:10Z' }
    fs.writeFileSync(path.join(GH_DIR, 'legacy.json'), JSON.stringify({ version: 2, entries: [old] }))
    const r = await run([frame('01-wallet-list')])
    assert.strictEqual(r.status, 0, r.stderr)
    const man = manifest()
    assert.strictEqual(man.entries.length, 2)
    assert.ok(man.entries.some(e => e.path === old.path && e.url == null))
    assert.ok(bodyOut().includes(`https://raw.githubusercontent.com/EdgeApp/edge-dev-agents/${LEGACY_BRANCH}/assets/edge-widget/pr-${PR}/20260901-101010-agent-proof-1-01-old-scene.png`))
    assert.strictEqual(ghLog().filter(a => a.join(' ').includes(LEGACY_BRANCH)).length, 1)
  })

  await t('a legacy read that fails (not a 404) stops before any write', async () => {
    reset()
    fs.writeFileSync(path.join(GH_DIR, 'legacy-broken'), '')
    const r = await run([frame('01-wallet-list')])
    assert.strictEqual(r.status, 1, r.stderr)
    assert.strictEqual(puts().length, 0)
    assert.ok(!fs.existsSync(path.join(GH_DIR, 'body.out')))
  })

  await t('a bucket manifest read that fails stops before any write', async () => {
    reset()
    objects.set(MANIFEST_KEY, Buffer.from(JSON.stringify({ version: 2, entries: [] })))
    failGets = true
    const r = await run([frame('01-wallet-list')])
    assert.strictEqual(r.status, 1, r.stderr)
    assert.strictEqual(puts().length, 0)
    assert.ok(!ghLog().some(a => a.join(' ').includes(LEGACY_BRANCH)), 'a failed bucket read fell through to the branch')
    assert.ok(!fs.existsSync(path.join(GH_DIR, 'body.out')))
  })

  await t('no bucket configured: exit 1 before any gh call', async () => {
    reset()
    const r = await run([frame('01-wallet-list')], { EVIDENCE_BUCKET_CONFIG: path.join(TMP, 'absent.json') })
    assert.strictEqual(r.status, 1, r.stderr)
    assert.strictEqual(ghLog().length, 0)
  })

  await t('head moved before review: dispositions still refuse with exit 2 and no upload', async () => {
    reset()
    assert.strictEqual((await run([frame('01-wallet-list')])).status, 0)
    fs.writeFileSync(path.join(GH_DIR, 'pr.json'), prState(HEAD_B))
    requests = []
    const r = await run([frame('02-settings')])
    assert.strictEqual(r.status, 2, r.stderr)
    assert.match(r.stderr, /--carry-forward wallet-list/)
    assert.strictEqual(puts().length, 0)
  })

  await t('carry-forward with no image re-points the hosted frame and uploads no pixels', async () => {
    const hosted = manifest().entries[0].url
    requests = []
    const r = await run(['--carry-forward', 'all'])
    assert.strictEqual(r.status, 0, r.stderr)
    assert.deepStrictEqual(puts(), [MANIFEST_KEY])
    const man = manifest()
    assert.strictEqual(man.entries.length, 1)
    assert.strictEqual(man.entries[0].url, hosted)
    assert.strictEqual(man.entries[0].headSha, HEAD_B)
  })

  await t('the script holds no branch mode and no git-data write', async () => {
    const src = fs.readFileSync(ATTACH, 'utf8')
    for (const gone of ['EVIDENCE_HOST', 'EVIDENCE_UPLOADER', 'upload-asset', 'git/refs', 'git/blobs', 'git/trees', 'git/commits', '-X PATCH', '-X POST', '-X PUT']) {
      assert.ok(!src.includes(gone), `still mentions ${gone}`)
    }
    const stray = src.split('\n').filter(l => l.includes(LEGACY_BRANCH) && !/LEGACY/.test(l))
    assert.deepStrictEqual(stray, [], 'the old branch is named outside a LEGACY-tagged line')
  })

  server.close()
  if (failed) { console.log(`\n${failed} failed`); process.exit(1) }
  console.log('\nall passed')
}

main()
