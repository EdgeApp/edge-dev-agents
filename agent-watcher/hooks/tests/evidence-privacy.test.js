// Tests for pr-create's evidence privacy detector (evidence-privacy.sh), the
// mechanical reading of build-and-test's `redact-secrets-before-attach`.
// Run: node ~/.config/agent-watcher/hooks/tests/evidence-privacy.test.js
//
// Every frame is drawn at run time from published test vectors and made-up
// names, so no fixture image exists and nothing here is a real seed, key or
// account. The roster is a temp file; the real one is never read.
// EVIDENCE_SCRIPTS points the test at another copy of the scripts.
const assert = require('node:assert')
const cp = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const SCRIPTS = process.env.EVIDENCE_SCRIPTS || path.join(os.homedir(), '.cursor/skills/pr-create/scripts')
const PRIVACY = path.join(SCRIPTS, 'evidence-privacy.sh')
const { classifyOcr } = require(path.join(SCRIPTS, 'evidence-privacy.js'))

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'evidence-privacy-test-'))
process.on('exit', () => fs.rmSync(TMP, { recursive: true, force: true }))

let failed = 0
function t (name, fn) {
  try { fn(); console.log(`ok   ${name}`) } catch (e) { failed++; console.log(`FAIL ${name}: ${e.message}`) }
}

// Published vectors: BIP39 (trezor/python-mnemonic vectors.json), BIP32 test
// vector 1, the Bitcoin wiki's WIF example, RFC 6238's shared secret in base32.
const BIP39_12 = 'legal winner thank year wave sausage worth useful legal winner thank yellow'.split(' ')
const XPRV = 'xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi'
const XPUB = 'xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8'
const HEX64 = 'e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35'
const WIF = '5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ'
const TOTP = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'

// Made-up accounts. The agent role keeps its password and OTP key in a creds
// file, the way the real roster does.
const USER_A = 'zq-probe-41x'
const USER_F = 'made.up-name7'
const PASSWORD = 'Vx7#made-up-pw'
const CREDS = path.join(TMP, 'creds.json')
const ROSTER = path.join(TMP, 'roster.json')
fs.writeFileSync(CREDS, JSON.stringify({ username: USER_A, password: PASSWORD, pin: '1111', otpKey: TOTP }))
fs.writeFileSync(ROSTER, JSON.stringify({ roster: { agent: { username: USER_A, pin: '1111', credsFile: CREDS }, funds: { username: USER_F, pin: '2222' } } }))

function run (args, env) {
  return cp.spawnSync(PRIVACY, args, { encoding: 'utf8', env: { ...process.env, ...env } })
}
const records = out => out.split('\n').filter(Boolean).map(l => JSON.parse(l))
const sha = f => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex')

// A stride through a word list: the right vocabulary, no real wallet.
function strideWords (file, n) {
  const words = fs.readFileSync(path.join(SCRIPTS, 'wordlists', file), 'utf8').split('\n').filter(Boolean)
  return Array.from({ length: n }, (_, i) => words[(i * 61 + 7) % words.length])
}
const rows = (words, per) => Array.from({ length: Math.ceil(words.length / per) }, (_, i) => words.slice(i * per, i * per + per).join(' '))
const wrap = (s, n) => s.match(new RegExp(`.{1,${n}}`, 'g'))

// name -> lines of text, drawn top down. A string is one line at the left
// margin; [x, y, text] places a line exactly.
const FRAMES = {
  clean: ['Wallets', 'My Bitcoin', '0.01234 BTC', 'Send', 'Receive'],
  prose: ['Changing your username only updates it on this', 'device. Any other devices logged into this account', 'will keep the old username. To keep using them, log', 'out of those devices and sign back in with your', 'new username.'],
  bip39: ['Write these words down', ...rows(BIP39_12, 4)],
  monero: rows(strideWords('monero-english.txt', 25), 5),
  zano: rows(strideWords('electrum-old-english.txt', 26), 5),
  wif: ['Paper wallet', ...wrap(WIF, 26)],
  xprv: ['Account', ...wrap(XPRV, 37)],
  xpub: ['Account', ...wrap(XPUB, 37)],
  'hex-key': ['Master Private Key', ...wrap(HEX64, 32)],
  'hex-txid': ['Transaction ID', ...wrap(HEX64, 32), 'Confirmations', '12'],
  'get-seed': [[400, 200, 'Get Seed'], [100, 320, BIP39_12.slice(0, 6).join(' ')], [100, 380, BIP39_12.slice(6).join(' ')], [450, 640, 'OK'], [400, 740, 'Copy Seed']],
  'import-typed': ['Import Wallet', 'Private Key or Private Seed', 'abandon ability able', 'Next'],
  'import-empty': ['Import Wallet', 'Private Key or Private Seed', '', '', 'Next'],
  otp: ['Email Verification', 'Enter the 6-digit code we sent you', '', '483 920'],
  'password-shown': ['Sign In', 'Password', 'Tr0ub4dor&3', '', 'Next'],
  'password-masked': ['Sign In', 'Password', '••••••••••', '', 'Next'],
  username: ['Sign In', 'Username', USER_A, '', 'Recent', USER_F, 'someone-else'],
  'roster-password': ['Notes', `pw ${PASSWORD}`],
  'roster-otp': ['Two-factor backup', TOTP]
}

const W = 1000
const H = 1400
const frame = name => path.join(TMP, `${name}.png`)
for (const [name, lines] of Object.entries(FRAMES)) {
  const specs = lines.map((l, i) => Array.isArray(l) ? `${l[0]},${l[1]},36,${l[2]}` : `80,${120 + i * 70},36,${l}`).filter(s => !s.endsWith(','))
  const r = run(['render', '--roster', ROSTER, frame(name), String(W), String(H), ...specs])
  if (r.status !== 0) { console.log(`FAIL cannot render ${name}: ${r.stderr}`); process.exit(1) }
}

const names = Object.keys(FRAMES)
const all = run(['classify', '--roster', ROSTER, ...names.map(frame)])
t('classify gives every frame a verdict', () => assert.strictEqual(all.status, 0, all.stderr))
const byName = Object.fromEntries(records(all.stdout).map((r, i) => [names[i], r]))

const EXPECT = {
  clean: ['clean'],
  prose: ['clean'],
  bip39: ['SECRET', 'mnemonic-words'],
  monero: ['SECRET', 'mnemonic-words'],
  zano: ['SECRET', 'mnemonic-words'],
  wif: ['SECRET', 'private-key'],
  xprv: ['SECRET', 'extended-private-key'],
  xpub: ['clean'],
  'hex-key': ['SECRET', 'private-key'],
  'hex-txid': ['clean'],
  'get-seed': ['SECRET', 'seed-scene'],
  'import-typed': ['SECRET', 'import-field'],
  'import-empty': ['clean'],
  otp: ['SECRET', 'otp-code'],
  'password-shown': ['SECRET', 'password'],
  'password-masked': ['clean'],
  username: ['USERNAME'],
  'roster-password': ['SECRET', 'password'],
  'roster-otp': ['SECRET', 'otp-secret']
}
for (const [name, [cls, rule]] of Object.entries(EXPECT)) {
  t(`${name} -> ${cls}${rule ? ` (${rule})` : ''}`, () => {
    const rec = byName[name]
    assert.ok(rec, 'no record')
    assert.strictEqual(rec.class, cls, JSON.stringify(rec.reasons))
    if (rule) assert.ok(rec.reasons.some(r => r.rule === rule), JSON.stringify(rec.reasons))
  })
}

t('a USERNAME record names roles and boxes, never the name', () => {
  const rec = byName.username
  assert.deepStrictEqual(rec.usernames.map(u => u.role).sort(), ['agent', 'funds'])
  for (const u of rec.usernames) assert.strictEqual(u.box.length, 4)
})
t('no record carries matched text', () => {
  for (const secret of [USER_A, USER_F, PASSWORD, TOTP, WIF, HEX64, 'sausage']) assert.ok(!all.stdout.includes(secret), secret)
})
t('reason boxes appear only with --explain', () => {
  assert.ok(byName.bip39.reasons.every(r => !('box' in r)))
  const r = run(['classify', '--roster', ROSTER, '--explain', frame('bip39')])
  assert.ok(records(r.stdout)[0].reasons.every(x => Array.isArray(x.box) && x.box.length === 4))
})

// ---- redact
t('redact hatches every roster name and leaves the original alone', () => {
  const before = sha(frame('username'))
  const out = path.join(TMP, 'username-redacted.png')
  const r = run(['redact', '--roster', ROSTER, frame('username'), out])
  assert.strictEqual(r.status, 0, r.stderr)
  const rec = records(r.stdout)[0]
  assert.strictEqual(rec.class, 'clean')
  assert.strictEqual(rec.hatched, true)
  assert.strictEqual(sha(frame('username')), before)
  assert.notStrictEqual(sha(out), before)
  const again = records(run(['classify', '--roster', ROSTER, out]).stdout)[0]
  assert.strictEqual(again.class, 'clean')
})
t('redact copies a clean frame byte for byte', () => {
  const out = path.join(TMP, 'clean-copy.png')
  const r = run(['redact', '--roster', ROSTER, frame('clean'), out])
  assert.strictEqual(r.status, 0, r.stderr)
  assert.strictEqual(sha(out), sha(frame('clean')))
})
t('redact refuses a SECRET frame with exit 4 and writes nothing', () => {
  const out = path.join(TMP, 'bip39-redacted.png')
  const r = run(['redact', '--roster', ROSTER, frame('bip39'), out])
  assert.strictEqual(r.status, 4)
  assert.ok(!fs.existsSync(out))
})
t('redact never writes over its input', () => {
  const before = sha(frame('username'))
  const r = run(['redact', '--roster', ROSTER, frame('username'), frame('username')])
  assert.strictEqual(r.status, 3)
  assert.strictEqual(sha(frame('username')), before)
})

// ---- hatch: a seed scene with its content covered is clean
t('a Get Seed modal with its content hatched out is clean', () => {
  const out = path.join(TMP, 'get-seed-hatched.png')
  const r = run(['hatch', '--roster', ROSTER, frame('get-seed'), out, '60,290,900,160'])
  assert.strictEqual(r.status, 0, r.stderr)
  assert.strictEqual(records(r.stdout)[0].class, 'clean', r.stdout)
})

// ---- fail closed
t('an unreadable frame is an error record and exit 3', () => {
  const bad = path.join(TMP, 'not-an-image.png')
  fs.writeFileSync(bad, 'not a png')
  const r = run(['classify', '--roster', ROSTER, frame('clean'), bad])
  assert.strictEqual(r.status, 3)
  assert.deepStrictEqual(records(r.stdout).map(x => x.class), ['clean', 'error'])
})
t('a missing frame is exit 3', () => {
  assert.strictEqual(run(['classify', '--roster', ROSTER, path.join(TMP, 'absent.png')]).status, 3)
})
t('no Vision reader is exit 3 with no verdicts', () => {
  const r = run(['classify', '--roster', ROSTER, frame('clean')], { FRAME_VISION: path.join(TMP, 'no-such-reader') })
  assert.strictEqual(r.status, 3)
  assert.strictEqual(r.stdout, '')
})
t('a malformed roster is exit 3', () => {
  const bad = path.join(TMP, 'bad-roster.json')
  fs.writeFileSync(bad, '{"roster": ')
  assert.strictEqual(run(['classify', '--roster', bad, frame('clean')]).status, 3)
})
t('a roster whose creds file is unreadable is exit 3', () => {
  const bad = path.join(TMP, 'dangling-roster.json')
  fs.writeFileSync(bad, JSON.stringify({ roster: { agent: { username: USER_A, credsFile: path.join(TMP, 'gone.json') } } }))
  assert.strictEqual(run(['classify', '--roster', bad, frame('clean')]).status, 3)
})
t('an absent roster file checks secrets only', () => {
  const r = run(['classify', '--roster', path.join(TMP, 'no-roster.json'), frame('username'), frame('bip39')])
  assert.strictEqual(r.status, 0, r.stderr)
  assert.deepStrictEqual(records(r.stdout).map(x => x.class), ['clean', 'SECRET'])
})

// ---- classifier on synthetic OCR: shapes Vision cannot be made to draw here
const line = (text, y, x = 80) => {
  const words = []
  let at = x
  for (const w of text.split(/\s+/).filter(Boolean)) { words.push({ text: w, box: [at, y, w.length * 20, 40] }); at += w.length * 20 + 20 }
  return { text, box: [x, y, Math.max(1, at - 20 - x), 40], words }
}
const ocr = (lines, barcodes = []) => ({ file: 'synthetic.png', width: W, height: H, passes: [{ correction: false, lines }, { correction: true, lines }], barcodes })

t('a QR code holding a WIF key is SECRET', () => {
  const rec = classifyOcr(ocr([line('Scan to sweep', 100)], [{ payload: WIF, box: [200, 300, 400, 400] }]))
  assert.strictEqual(rec.class, 'SECRET')
})
t('a QR code holding a 2FA enrolment link is SECRET', () => {
  const rec = classifyOcr(ocr([line('Scan with your authenticator', 100)], [{ payload: `otpauth://totp/x?secret=${TOTP}`, box: [200, 300, 400, 400] }]))
  assert.ok(rec.reasons.some(r => r.rule === 'otp-secret'))
})
t('a QR code holding an address is clean', () => {
  const rec = classifyOcr(ocr([line('Receive', 100)], [{ payload: 'bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq', box: [200, 300, 400, 400] }]))
  assert.strictEqual(rec.class, 'clean', JSON.stringify(rec.reasons))
})
t('a numbered seed grid is SECRET', () => {
  const lines = BIP39_12.map((w, i) => line(`${i + 1}. ${w}`, 100 + Math.floor(i / 2) * 60, 80 + (i % 2) * 400))
  assert.strictEqual(classifyOcr(ocr(lines)).class, 'SECRET')
})
t('a capitalised sentence of list words is clean', () => {
  const rec = classifyOcr(ocr([line('Legal Winner Thank Year Wave', 100)]))
  assert.strictEqual(rec.class, 'clean', JSON.stringify(rec.reasons))
})
t('a username misread by one character still matches', () => {
  const roster = { usernames: [{ role: 'agent', value: USER_A }], secrets: [] }
  const rec = classifyOcr(ocr([line('Username', 100), line(USER_A.replace('4', 'A'), 160)]), roster)
  assert.strictEqual(rec.class, 'USERNAME')
})
t('Raw Keys with content is SECRET', () => {
  const rec = classifyOcr(ocr([line('Raw Keys', 100), line('{ "displayKey": "made-up-value" }', 200)]))
  assert.strictEqual(rec.class, 'SECRET')
})
t('"Hide 2FA code" means the code is showing', () => {
  assert.strictEqual(classifyOcr(ocr([line('2-Factor Security', 100), line('Hide 2FA code', 400)])).class, 'SECRET')
  assert.strictEqual(classifyOcr(ocr([line('2-Factor Security', 100), line('Show 2FA code', 400)])).class, 'clean')
})
t('an OCR failure record classifies as error, never clean', () => {
  assert.strictEqual(classifyOcr({ file: 'x.png', error: 'unreadable image' }).class, 'error')
  assert.strictEqual(classifyOcr({ file: 'x.png' }).class, 'error')
})

console.log(failed === 0 ? '\nall passed' : `\n${failed} failed`)
process.exit(failed === 0 ? 0 : 1)
