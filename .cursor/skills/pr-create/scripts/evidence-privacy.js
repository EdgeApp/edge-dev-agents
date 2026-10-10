#!/usr/bin/env node
// evidence-privacy.js: decides whether an evidence frame shows private content.
// Run it through evidence-privacy.sh, which builds the Vision reader this needs.
//
// The definition of private content belongs to the rule
// `redact-secrets-before-attach` (build-and-test references/drive.md). This
// file is its mechanical reading, with two classes:
//   SECRET    a wallet seed or mnemonic, a private key, a cleartext password,
//             an OTP or 2FA code. The frame may not be published.
//   USERNAME  a test-account username from the local roster. The frame is
//             publishable once the name is hatched out.
// Every rule leans toward SECRET: a wrong SECRET withholds one frame, a wrong
// clean publishes a key.
//
//   classify [--roster <json>] [--list <file>] [--explain] [<image>...]
//       One JSON record per frame on stdout, in input order:
//         { file, class: clean|SECRET|USERNAME|error, reasons: [{ rule,
//           detail, box }], usernames: [{ role, box }], width, height }
//       `--list` reads image paths from a file, one per line. Records never
//       carry the matched text: a reason names the rule, a username names the
//       roster role. Boxes are [x, y, w, h] pixels from the top-left corner.
//   redact [--roster <json>] <in> <out>
//       Writes <out>, a copy of <in> with every roster username hatched out,
//       re-reads it and prints its record plus { out }. <in> is never written.
//       A clean frame is copied unchanged. A SECRET frame writes nothing.
//   hatch [--roster <json>] <in> <out> <x,y,w,h>...
//       Writes <out> with the given boxes hatched out, for covering a secret
//       by hand, then classifies <out> and prints its record plus { out }.
//       `classify --explain` adds each finding's box to its reason.
//   render <out> <width> <height> [<x,y,size,text>...]
//       Draws text on a blank canvas. Tests build their frames with it.
//
// Exit codes: 0 every frame has a verdict; 1 bad usage; 3 the detector could
// not read a frame (callers refuse: no verdict is never a clean verdict);
// 4 `redact` refused a SECRET frame.

'use strict'

const cp = require('child_process')
const fs = require('fs')
const os = require('os')
const path = require('path')

const DEFAULT_ROSTER = path.join(os.homedir(), '.config/edge-secrets/test-accounts.json')

// ---------------------------------------------------------------- word lists

const LISTS = [
  { name: 'BIP39', file: 'bip39-english.txt' },
  { name: 'Monero', file: 'monero-english.txt' },
  // The pre-2014 Electrum list: Zano seeds and legacy Monero seeds.
  { name: 'Zano/Electrum', file: 'electrum-old-english.txt' }
]

const deletions = w => {
  const out = []
  for (let i = 0; i < w.length; i++) out.push(w.slice(0, i) + w.slice(i + 1))
  return out
}

let loadedLists = null
function wordLists() {
  if (loadedLists != null) return loadedLists
  loadedLists = LISTS.map(l => {
    const words = fs.readFileSync(path.join(__dirname, 'wordlists', l.file), 'utf8').split('\n').filter(Boolean)
    const near = new Set()
    for (const w of words) for (const d of deletions(w)) near.add(d)
    return { name: l.name, words: new Set(words), near }
  })
  return loadedLists
}

// One OCR slip away from a list word: a dropped, added or swapped letter.
function nearWord(list, t) {
  if (t.length < 5) return false
  if (list.near.has(t)) return true
  for (const d of deletions(t)) if (list.words.has(d) || list.near.has(d)) return true
  return false
}

// -------------------------------------------------------------------- roster

// Folds the characters OCR confuses, so a roster value still matches when the
// reader swaps a zero for an o or drops an underscore.
const fold = s => s.toLowerCase().replace(/0/g, 'o').replace(/[1i|!]/g, 'l')
const squash = s => fold(s).replace(/[^a-z0-9]/g, '')

function loadRoster(file) {
  const out = { usernames: [], secrets: [] }
  if (!fs.existsSync(file)) return out
  const roster = JSON.parse(fs.readFileSync(file, 'utf8')).roster
  if (roster == null || typeof roster !== 'object') throw new Error(`roster file has no "roster" object: ${file}`)
  const addUser = (role, v) => {
    if (typeof v === 'string' && squash(v).length >= 4 && !out.usernames.some(u => u.value === v)) out.usernames.push({ role, value: v })
  }
  const addSecret = (role, kind, v) => {
    if (typeof v === 'string' && squash(v).length >= 6) out.secrets.push({ role, kind, value: v })
  }
  const entries = Array.isArray(roster) ? roster.map((e, i) => [e.role ?? String(i), e]) : Object.entries(roster)
  for (const [role, entry] of entries) {
    if (entry == null || typeof entry !== 'object') continue
    const sources = [entry]
    if (typeof entry.credsFile === 'string') {
      const p = entry.credsFile.replace(/^~(?=\/)/, os.homedir())
      const full = path.isAbsolute(p) ? p : path.join(path.dirname(file), p)
      // A named creds file that cannot be read is a detector failure: its
      // password would otherwise go unchecked.
      sources.push(JSON.parse(fs.readFileSync(full, 'utf8')))
    }
    for (const src of sources) {
      addUser(role, src.username)
      for (const [k, v] of Object.entries(src)) {
        if (/pass(word|phrase)?$/i.test(k)) addSecret(role, 'password', v)
        else if (/otp|totp|2fa|secret|seed|mnemonic|private/i.test(k)) addSecret(role, 'key', v)
      }
    }
  }
  return out
}

// ------------------------------------------------------------------ geometry

const right = b => b[0] + b[2]
const bottom = b => b[1] + b[3]
const union = (a, b) => {
  if (a == null) return b
  const x = Math.min(a[0], b[0])
  const y = Math.min(a[1], b[1])
  return [x, y, Math.max(right(a), right(b)) - x, Math.max(bottom(a), bottom(b)) - y]
}
const overlaps = (a, b) => a[0] < right(b) && b[0] < right(a) && a[1] < bottom(b) && b[1] < bottom(a)

// Top to bottom, then left to right within a row.
function readingOrder(lines) {
  const sorted = [...lines].sort((a, b) => a.box[1] + a.box[3] / 2 - (b.box[1] + b.box[3] / 2))
  const rows = []
  for (const l of sorted) {
    const cy = l.box[1] + l.box[3] / 2
    const row = rows[rows.length - 1]
    if (row != null && cy - row.cy < Math.min(row.h, l.box[3]) * 0.5) row.lines.push(l)
    else rows.push({ cy, h: l.box[3], lines: [l] })
  }
  return rows.flatMap(r => r.lines.sort((a, b) => a.box[0] - b.box[0]))
}

// ----------------------------------------------------------------- mnemonics

// Scene labels that sit directly above key material. Matched against a whole
// line, so a warning sentence that merely mentions private keys is no context.
const KEY_LABEL = /^(master private (seed|key)|private (key|seed)( or private seed)?|active private key|private view key|private spend key|(secret|private) (view|spend) key|raw keys|seed( phrase)?|(recovery|secret|backup|mnemonic) phrase|mnemonic( seed)?|secret key|copy seed|transaction key)\s*:?$/i

const RUN_ANY_CASE = 12
const RUN_LOWERCASE = 6
const RUN_WITH_LABEL = 5

function mnemonicReasons(lines, hasKeyLabel) {
  const tokens = []
  for (const l of lines) {
    for (const w of l.words) {
      let t = w.text.replace(/^[("'\[]+/, '').replace(/^\d{1,2}[.):]?(?=\D|$)/, '')
      if (t === '') continue // a bare list number between words
      const clauseEnd = /[,.;:!?)]$/.test(t)
      t = t.replace(/[,.;:!?)"'\]]+$/, '')
      tokens.push({ text: t, box: w.box, clauseEnd, word: /^[A-Za-z]+$/.test(t) })
    }
  }
  const reasons = []
  for (const list of wordLists()) {
    let run = null
    const close = () => {
      if (run == null) return
      // A trailing unread word never extends a run.
      const r = run
      run = null
      const total = r.exact + r.near
      const lower = r.lower
      const hit = total >= RUN_ANY_CASE || lower >= RUN_LOWERCASE || (hasKeyLabel && lower >= RUN_WITH_LABEL)
      if (!hit || r.near > Math.max(1, total / 4)) return
      reasons.push({ rule: 'mnemonic-words', detail: `run of ${total} ${list.name} words`, box: r.box })
    }
    for (const tok of tokens) {
      const t = tok.text.toLowerCase()
      const exact = tok.word && list.words.has(t)
      const near = !exact && tok.word && nearWord(list, t)
      // A near miss only continues a run of real list words: on its own it is
      // an ordinary plural or verb form in a sentence.
      if (exact || (near && run != null && run.exact >= 3)) {
        if (run == null) run = { exact: 0, near: 0, lower: 0, box: null, gap: false }
        run.exact += exact ? 1 : 0
        run.near += near ? 1 : 0
        if (tok.text === t) run.lower += 1
        run.box = union(run.box, tok.box)
        run.gap = false
      } else if (run != null && run.exact >= RUN_LOWERCASE && !run.gap && tok.word && tok.text === t && t.length >= 3 && t.length <= 12) {
        // One unreadable lowercase word inside an established run is an OCR
        // miss, not an end. Shorter runs get no such bridge: that is how
        // sentences chain into false mnemonics.
        run.gap = true
        continue
      } else {
        close()
      }
      if (tok.clauseEnd) close()
    }
    close()
  }
  return reasons
}

// -------------------------------------------------------------- key material

const BASE58 = '1-9A-HJ-NP-Za-km-z'
const STRING_RULES = [
  [/[xyzYZtuvUV]prv[1-9A-HJ-NP-Za-km-z]{20,}|(Ltpv|dgpv|drkp|xprv)[1-9A-HJ-NP-Za-km-z]{20,}/, 'extended-private-key', 'xprv-style extended private key'],
  [/secret-extended-key-(main|test)|zxviews1|zxviewtestsapling1|uview1|uviewtest1|zivks1|suiprivkey1|nsec1[a-z0-9]{20,}/i, 'private-key', 'shielded spending or viewing key'],
  [/(edsk|spsk|p2sk|edesk)[1-9A-HJ-NP-Za-km-z]{40,}/, 'private-key', 'Tezos secret key'],
  [/-----BEGIN [A-Z ]*PRIVATE KEY/, 'private-key', 'PEM private key'],
  [/otpauth:\/\//i, 'otp-secret', '2FA enrolment link'],
  [/"[A-Za-z]*(mnemonic|privateKey|private_key|secretKey|seed|[a-z]Key|Key)"\s*:\s*"?[A-Za-z0-9]/, 'raw-keys', 'key field with a value']
]

const isHexish = s => {
  const body = s.replace(/^0x/i, '')
  if (body.length < 16) return false
  const hex = (body.match(/[0-9a-f]/gi) ?? []).length
  // OCR reads a few hex digits as look-alike letters.
  return hex >= body.length * 0.92 && /^[0-9a-fOoIlSsZzGgqt]+$/.test(body)
}

const KEYISH_LABEL = /private|secret|seed|master|spend|view(ing)? key|transaction key|tx key|mnemonic|\bkeys?\s*:?$/i
const PUBLIC_LABEL = /public|pubkey|xpub/i
const BENIGN_LABEL = /transaction id|txid|tx ?id|\bhash|block|signature|payment id|order|memo|\bdata\b|contract|address|proof|root|checksum|\bsha|commit|digest|nonce|uuid|trace|\bid\b|token|asset|pool|validator|topic|input|output|event|log/i
const TX_CONTEXT = /transaction|txid|\bhash\b|explorer|confirmations?|block ?height|\bsha-?256\b|checksum|digest|commit/i

// Unbroken strings long enough to be key material, with wrapped lines joined:
// the app wraps a 64-character key over two lines.
function opaqueStrings(lines) {
  const frags = []
  for (const l of lines) {
    const compact = l.text.replace(/\s+/g, '')
    const single = l.words.length === 1
    const digits = (compact.match(/\d/g) ?? []).length
    if (/^[A-Za-z0-9+/=_-]{16,}$/.test(compact) && (isHexish(compact) || (single && (digits >= 2 || compact.length >= 30)))) {
      frags.push({ text: compact, box: l.box, line: l, whole: true })
      continue
    }
    for (const w of l.words) {
      const t = w.text.replace(/^[^A-Za-z0-9]+|[^A-Za-z0-9=]+$/g, '')
      if (t.length >= 20 && /^[A-Za-z0-9+/=_-]+$/.test(t) && /\d/.test(t)) frags.push({ text: t, box: w.box, line: l, whole: false })
    }
  }
  frags.sort((a, b) => a.box[1] - b.box[1] || a.box[0] - b.box[0])
  const used = new Set()
  const out = []
  for (let i = 0; i < frags.length; i++) {
    if (used.has(i)) continue
    const s = { text: frags[i].text, box: frags[i].box, first: frags[i] }
    let last = frags[i]
    for (let j = i + 1; j < frags.length; j++) {
      if (used.has(j)) continue
      const f = frags[j]
      const gap = f.box[1] - bottom(last.box)
      const aligned = Math.abs(f.box[0] - last.box[0]) < last.box[3] * 1.2 || Math.abs(f.box[0] + f.box[2] / 2 - (last.box[0] + last.box[2] / 2)) < last.box[3] * 1.2
      if (gap > -last.box[3] * 0.4 && gap < last.box[3] * 0.9 && aligned) {
        used.add(j)
        s.text += f.text
        s.box = union(s.box, f.box)
        last = f
      }
    }
    out.push(s)
  }
  return out
}

// The nearest text that names a value: earlier words on its own line, else the
// closest line above that shares its column.
function labelFor(lines, frag) {
  if (!frag.whole) {
    const before = frag.line.words.filter(w => right(w.box) <= frag.box[0] + 2).map(w => w.text).join(' ')
    if (/[A-Za-z]{3}/.test(before)) return before
  }
  let best = null
  for (const l of lines) {
    if (l === frag.line || bottom(l.box) > frag.box[1] + frag.box[3] * 0.3) continue
    if (frag.box[1] - bottom(l.box) > frag.box[3] * 4) continue
    if (l.box[0] > right(frag.box) || right(l.box) < frag.box[0]) continue
    if (!/[A-Za-z]{3}/.test(l.text)) continue
    if (best == null || bottom(l.box) > bottom(best.box)) best = l
  }
  return best?.text ?? null
}

function keyReasons(lines, barcodes, allText, hasKeyLabel) {
  const reasons = []
  const sources = [...lines.map(l => ({ text: l.text, box: l.box })), ...barcodes.map(b => ({ text: b.payload, box: b.box, barcode: true }))]
  const strings = opaqueStrings(lines)
  for (const s of strings) sources.push({ text: s.text, box: s.box })
  for (const src of sources) {
    for (const [re, rule, detail] of STRING_RULES) {
      if (re.test(src.text)) reasons.push({ rule, detail: src.barcode ? `${detail} in a QR code` : detail, box: src.box })
    }
  }
  const txContext = TX_CONTEXT.test(allText)
  const candidates = [...strings, ...barcodes.map(b => ({ text: b.payload.trim(), box: b.box, barcode: true }))]
  for (const s of candidates) {
    const body = s.text.replace(/^0x/i, '')
    const label = s.barcode ? null : labelFor(lines, s.first)
    const keyish = label != null && KEYISH_LABEL.test(label) && !PUBLIC_LABEL.test(label)
    const benign = label != null && !keyish && (BENIGN_LABEL.test(label) || PUBLIC_LABEL.test(label))
    if (isHexish(s.text) && body.length >= 60 && body.length <= 70) {
      if (keyish) reasons.push({ rule: 'private-key', detail: '64-hex value under a key label', box: s.box })
      else if (!benign && (hasKeyLabel || !txContext)) reasons.push({ rule: 'private-key', detail: '64-hex value with nothing marking it as a transaction id or hash', box: s.box })
      continue
    }
    // WIF: 51 characters from 5, or 52 from K or L (and the altcoin prefixes).
    const b58 = (body.match(new RegExp(`[${BASE58}]`, 'g')) ?? []).length
    if (body.length >= 50 && body.length <= 53 && /^[5KLTQX679c]/.test(body) && b58 >= body.length - 2 && /\d/.test(body) && /[a-z]/.test(body) && /[A-Z]/.test(body)) {
      reasons.push({ rule: 'private-key', detail: 'WIF-shaped private key', box: s.box })
      continue
    }
    if (/^S[A-Z2-7]{55}$/.test(body)) {
      reasons.push({ rule: 'private-key', detail: 'Stellar secret key', box: s.box })
      continue
    }
    if (keyish && body.length >= 20) reasons.push({ rule: 'private-key', detail: 'unbroken value under a key label', box: s.box })
  }
  // A secret key shown as a byte array.
  for (const l of lines) {
    if ((l.text.match(/\b\d{1,3}\s*,/g) ?? []).length >= 24 && hasKeyLabel) reasons.push({ rule: 'private-key', detail: 'byte array under a key label', box: l.box })
  }
  return reasons
}

// -------------------------------------------------------------- scene rules

const lineIs = (l, re) => re.test(l.text.trim())

function sceneReasons(lines, height) {
  const reasons = []
  // The Get Seed modal: title, the seed and key, then OK and Copy Seed. Copy
  // Seed exists only once the content is revealed, and a correctly hatched
  // frame has no text left between the title and the buttons.
  for (const copy of lines.filter(l => lineIs(l, /^copy seed$/i))) {
    const titles = lines.filter(l => lineIs(l, /^get seed$/i) && bottom(l.box) <= copy.box[1])
    const top = titles.length > 0 ? Math.max(...titles.map(l => bottom(l.box))) : copy.box[1] - height * 0.45
    const content = lines.filter(l => l !== copy && l.box[1] >= top - 2 && bottom(l.box) <= copy.box[1] + 2 && !lineIs(l, /^(ok|x|×)$/i) && /[A-Za-z0-9]{2}/.test(l.text))
    if (content.length > 0) reasons.push({ rule: 'seed-scene', detail: 'Get Seed modal with its content visible', box: content.reduce((b, l) => union(b, l.box), null) })
  }
  // An import field holding typed text: the floating label sits directly
  // above the value. An empty field shows the label alone.
  const IMPORT_LABEL = /^(private key or private seed|private key|private seed|active private key|seed passphrase)$/i
  for (const label of lines.filter(l => lineIs(l, IMPORT_LABEL))) {
    const value = lines.find(l => l !== label && l.box[1] >= bottom(label.box) - 4 && l.box[1] - bottom(label.box) < label.box[3] * 1.6 && Math.abs(l.box[0] - label.box[0]) < label.box[3] * 2 && /[A-Za-z0-9]{3}/.test(l.text))
    if (value != null) reasons.push({ rule: 'import-field', detail: `"${label.text.trim()}" field with a typed value`, box: value.box })
  }
  // Raw Keys modal: any structured content under the title.
  for (const title of lines.filter(l => lineIs(l, /^raw keys$/i))) {
    const content = lines.filter(l => l.box[1] > bottom(title.box) && /["{}]|\w:\s*\S/.test(l.text))
    if (content.length > 0) reasons.push({ rule: 'raw-keys', detail: 'Raw Keys modal with its content visible', box: content.reduce((b, l) => union(b, l.box), null) })
  }
  // The 2FA settings scene offers "Hide 2FA code" only while the code shows.
  for (const l of lines.filter(l => /hide 2fa code/i.test(l.text))) reasons.push({ rule: 'otp-secret', detail: '2FA code revealed', box: l.box })
  return reasons
}

const OTP_CONTEXT = /verification code|\b\d-digit code|one[- ]time (pass|code)|\botp\b|2fa code|authentication code|authenticator|security code|enter (the|your) code|confirmation code|login code/i

function otpReasons(lines, allText) {
  if (!OTP_CONTEXT.test(allText)) return []
  const reasons = []
  for (const l of lines) {
    const t = l.text.trim()
    // A code on its own, whole or spread over one box per digit.
    if (/^\d{3}[ -]?\d{3}$/.test(t) || /^\d{4}$|^\d{5}$|^\d{8}$/.test(t) || /^(\d\s+){3,7}\d$/.test(t)) reasons.push({ rule: 'otp-code', detail: 'one-time code on a verification screen', box: l.box })
    if (/^[A-Z2-7]{4}( ?[A-Z2-7]{4}){3,7}$/.test(t)) reasons.push({ rule: 'otp-secret', detail: '2FA setup key', box: l.box })
  }
  // Single-digit boxes read as separate lines on one row.
  const digits = lines.filter(l => /^\d$/.test(l.text.trim()))
  for (const d of digits) {
    const row = digits.filter(o => Math.abs(o.box[1] - d.box[1]) < d.box[3] * 0.5)
    if (row.length >= 4 && row[0] === d) reasons.push({ rule: 'otp-code', detail: 'one-time code on a verification screen', box: row.reduce((b, l) => union(b, l.box), null) })
  }
  return reasons
}

// A password field with its value showing: the field label, then text that is
// neither masked nor one of the app's own hints.
const PASSWORD_LABEL = /^((current|new|confirm|re-?enter|your)\s+)?password$/i
const PASSWORD_HINT = /password|characters|uppercase|lowercase|number|must|forgot|username|login|log in|sign in|next|done|cancel|continue|submit|save|show|hide|create|recover|help|touch|face|pin|enter|required|incorrect|match|change|confirm|verify|^ok$|^or$/i

function passwordReasons(lines) {
  const reasons = []
  for (const label of lines.filter(l => lineIs(l, PASSWORD_LABEL))) {
    const value = lines.find(l => l !== label && l.box[1] >= bottom(label.box) - 4 && l.box[1] - bottom(label.box) < label.box[3] * 1.4 && Math.abs(l.box[0] - label.box[0]) < label.box[3] * 1.5)
    if (value == null) continue
    const t = value.text.trim()
    if (t.length < 4 || /^[•●·*.\s∙⚫]+$/.test(t) || /\s\S+\s/.test(t) || PASSWORD_HINT.test(t)) continue
    reasons.push({ rule: 'password', detail: 'password field with its value showing', box: value.box })
  }
  return reasons
}

// ------------------------------------------------------------ roster matches

// Finds `needle` (already squashed) in a line, tolerating one misread
// character, and returns the union box of the words it spans.
function findInLine(line, needle) {
  const chars = []
  line.words.forEach((w, wi) => {
    for (const c of squash(w.text)) chars.push({ c, wi })
  })
  const hay = chars.map(c => c.c).join('')
  const spans = []
  let at = hay.indexOf(needle)
  while (at !== -1) {
    spans.push([at, at + needle.length])
    at = hay.indexOf(needle, at + 1)
  }
  if (spans.length === 0 && needle.length >= 8) {
    for (let i = 0; i + needle.length - 1 <= hay.length; i++) {
      for (const len of [needle.length, needle.length - 1, needle.length + 1]) {
        if (i + len > hay.length) continue
        if (withinOneEdit(hay.slice(i, i + len), needle)) spans.push([i, i + len])
      }
    }
  }
  return spans.map(([a, b]) => {
    let box = null
    for (let i = a; i < b; i++) box = union(box, line.words[chars[i].wi].box)
    return box
  })
}

function withinOneEdit(a, b) {
  if (a === b) return true
  if (Math.abs(a.length - b.length) > 1) return false
  let i = 0
  while (i < a.length && i < b.length && a[i] === b[i]) i++
  if (a.length === b.length) return a.slice(i + 1) === b.slice(i + 1)
  return a.length > b.length ? a.slice(i + 1) === b.slice(i) : a.slice(i) === b.slice(i + 1)
}

function rosterMatches(lines, roster) {
  const usernames = []
  const reasons = []
  for (const l of lines) {
    for (const u of roster.usernames) {
      for (const box of findInLine(l, squash(u.value))) usernames.push({ role: u.role, box })
    }
    for (const s of roster.secrets) {
      for (const box of findInLine(l, squash(s.value))) {
        reasons.push({ rule: s.kind === 'password' ? 'password' : 'otp-secret', detail: `the ${s.role} account's ${s.kind === 'password' ? 'password' : '2FA or key secret'} from the roster`, box })
      }
    }
  }
  return { usernames, reasons }
}

// ------------------------------------------------------------------ classify

function dedupe(items, key) {
  const out = []
  for (const it of items) {
    if (!out.some(o => key(o) === key(it) && (o.box == null || it.box == null || overlaps(o.box, it.box)))) out.push(it)
  }
  return out
}

// `ocr` is one record from `frame-vision ocr`. Both OCR passes are judged and
// the findings merged, so the stricter reading always wins.
function classifyOcr(ocr, roster = { usernames: [], secrets: [] }) {
  if (ocr.error != null || !Array.isArray(ocr.passes)) {
    return { file: ocr.file, class: 'error', reasons: [{ rule: 'unreadable', detail: ocr.error ?? 'no OCR result', box: null }], usernames: [] }
  }
  let reasons = []
  let usernames = []
  const barcodes = ocr.barcodes ?? []
  for (const pass of ocr.passes) {
    const lines = readingOrder(pass.lines)
    const allText = lines.map(l => l.text).join('\n')
    const hasKeyLabel = lines.some(l => KEY_LABEL.test(l.text.trim()))
    reasons.push(...mnemonicReasons(lines, hasKeyLabel))
    reasons.push(...keyReasons(lines, barcodes, allText, hasKeyLabel))
    reasons.push(...sceneReasons(lines, ocr.height))
    reasons.push(...otpReasons(lines, allText))
    reasons.push(...passwordReasons(lines))
    const matched = rosterMatches(lines, roster)
    reasons.push(...matched.reasons)
    usernames.push(...matched.usernames)
  }
  reasons = dedupe(reasons, r => r.rule + r.detail)
  usernames = dedupe(usernames, u => u.role)
  const cls = reasons.length > 0 ? 'SECRET' : usernames.length > 0 ? 'USERNAME' : 'clean'
  return { file: ocr.file, class: cls, reasons, usernames, width: ocr.width, height: ocr.height }
}

// ----------------------------------------------------------------------- CLI

class DetectorError extends Error {}

function vision(args) {
  const bin = process.env.FRAME_VISION
  if (bin == null || bin === '') throw new DetectorError('FRAME_VISION is not set: run this through evidence-privacy.sh')
  const res = cp.spawnSync(bin, args, { encoding: 'utf8', maxBuffer: 1 << 30 })
  if (res.error != null || res.status !== 0) throw new DetectorError(`frame-vision ${args[0]} failed: ${res.error?.message ?? res.stderr.trim()}`)
  return res.stdout
}

function ocrFiles(files) {
  const out = []
  for (let i = 0; i < files.length; i += 40) {
    const chunk = files.slice(i, i + 40)
    const rows = vision(['ocr', ...chunk]).split('\n').filter(Boolean).map(l => JSON.parse(l))
    if (rows.length !== chunk.length) throw new DetectorError(`frame-vision returned ${rows.length} results for ${chunk.length} files`)
    out.push(...rows)
  }
  return out
}

const pad = (b, by, w, h) => {
  const x = Math.max(0, b[0] - by)
  const y = Math.max(0, b[1] - by)
  return [x, y, Math.min(w, right(b) + by) - x, Math.min(h, bottom(b) + by) - y].map(Math.round).join(',')
}

function main(argv) {
  const cmd = argv.shift()
  let rosterFile = process.env.EVIDENCE_ROSTER || DEFAULT_ROSTER
  let listFile = null
  let explain = false
  const rest = []
  while (argv.length > 0) {
    const a = argv.shift()
    if (a === '--roster') rosterFile = argv.shift()
    else if (a === '--list') listFile = argv.shift()
    else if (a === '--explain') explain = true
    else rest.push(a)
  }
  const usage = () => {
    process.stderr.write('usage: evidence-privacy.sh classify [--roster <json>] [--list <file>] [--explain] [<image>...]\n       evidence-privacy.sh redact [--roster <json>] <in> <out>\n       evidence-privacy.sh hatch [--roster <json>] <in> <out> <x,y,w,h>...\n')
    return 1
  }
  if (rosterFile == null) return usage()
  let roster
  try {
    roster = loadRoster(rosterFile)
  } catch (e) {
    process.stderr.write(`evidence-privacy: cannot read the roster (${e.message}); refusing to classify without it\n`)
    return 3
  }
  const print = rec => process.stdout.write(JSON.stringify(rec) + '\n')
  try {
    if (cmd === 'classify') {
      const files = [...rest]
      if (listFile != null) files.push(...fs.readFileSync(listFile, 'utf8').split('\n').filter(Boolean))
      if (files.length === 0) return usage()
      let failed = false
      for (let i = 0; i < files.length; i += 40) {
        for (const ocr of ocrFiles(files.slice(i, i + 40))) {
          const rec = classifyOcr(ocr, roster)
          if (rec.class === 'error') failed = true
          if (!explain) for (const r of rec.reasons) delete r.box
          print(rec)
        }
      }
      return failed ? 3 : 0
    }
    if (cmd === 'redact') {
      if (rest.length !== 2) return usage()
      const [src, out] = rest
      if (path.resolve(src) === path.resolve(out)) throw new DetectorError('redact never writes over its input')
      let rec = classifyOcr(ocrFiles([src])[0], roster)
      if (rec.class === 'error') throw new DetectorError(`${src}: ${rec.reasons[0].detail}`)
      if (rec.class === 'SECRET') {
        print(rec)
        return 4
      }
      if (rec.class === 'clean') {
        fs.copyFileSync(src, out)
        print({ ...rec, out })
        return 0
      }
      // Hatch, re-read, and widen the boxes when a name still reads through.
      let boxes = []
      let from = src
      const tmp = `${out}.redact-${process.pid}.png`
      for (let round = 0; round < 3 && rec.class === 'USERNAME'; round++) {
        boxes = rec.usernames.map(u => pad(u.box, Math.ceil(rec.height * (0.006 + 0.006 * round)), rec.width, rec.height))
        vision(['hatch', from, round % 2 === 0 ? out : tmp, ...boxes])
        from = round % 2 === 0 ? out : tmp
        rec = classifyOcr(ocrFiles([from])[0], roster)
        if (rec.class === 'error') throw new DetectorError(`${from}: ${rec.reasons[0].detail}`)
      }
      if (from === tmp) fs.renameSync(tmp, out)
      else fs.rmSync(tmp, { force: true })
      if (rec.class !== 'clean') {
        fs.rmSync(out, { force: true })
        if (rec.class === 'SECRET') {
          print(rec)
          return 4
        }
        throw new DetectorError(`${src}: a roster username still reads through the hatch`)
      }
      print({ ...rec, file: src, out, hatched: true })
      return 0
    }
    if (cmd === 'render') {
      if (rest.length < 3) return usage()
      vision(['render', ...rest])
      return 0
    }
    if (cmd === 'hatch') {
      if (rest.length < 3) return usage()
      const [src, out, ...boxes] = rest
      if (path.resolve(src) === path.resolve(out)) throw new DetectorError('hatch never writes over its input')
      vision(['hatch', src, out, ...boxes])
      const rec = classifyOcr(ocrFiles([out])[0], roster)
      print({ ...rec, out })
      return rec.class === 'error' ? 3 : 0
    }
  } catch (e) {
    if (!(e instanceof DetectorError)) throw e
    process.stderr.write(`evidence-privacy: ${e.message}\n`)
    return 3
  }
  return usage()
}

module.exports = { classifyOcr, loadRoster, readingOrder, squash }

if (require.main === module) process.exit(main(process.argv.slice(2)))
