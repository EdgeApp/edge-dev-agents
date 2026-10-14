#!/usr/bin/env bash
# rubric-drift.sh — detect drift between the eval rubrics and the skill rules /
# orch scripts they anchor to.
#
# The eval rubrics (agent-eval, orch-eval references/rubric.md) are CURATED:
# incident-hardened wording, gate designations, BAD examples. They must never be
# auto-regenerated from the skills. But their expectations anchor to skill
# <rule id="..."> blocks and agent-watcher scripts, and those change. This tool
# makes the seam checkable in both directions:
#
#   DRIFT    — an anchored rule/file changed (or vanished) since last reconcile
#              → the dimension(s) citing it may need re-wording (or removal).
#   COVERAGE — a rule id exists in the corpus that no dimension anchors and no
#              operator has acknowledged → candidate new dimension.
#
# The rubric grounding column IS the anchor source (single source of truth; no
# sidecar mapping to drift). Parsing convention: any backticked token in a
# dimension row's grounding cell that equals a known <rule id> is an anchor
# (the skill named before the token disambiguates duplicates); any *.js/*.sh
# token resolving under ~/.config/agent-watcher is a file anchor; any
# templates/*.md token resolving under a skill dir is a file anchor.
#
# What a FILE anchor's fingerprint covers (lock field file_fingerprint: 2):
#   narrowed  when every dimension citing the file names, in backticks, a
#             top-level function, constant or variable of it (or, for a .md
#             file, a <tag> block): the header comment plus those blocks.
#   whole     otherwise: the header comment plus every line that is not a
#             full-line comment (.md: the whole file). A comment edit below
#             the header no longer trips the anchor; any code edit still does.
# --fingerprints lists which mode each file anchor is in and why. A lock
# without the field holds the older whole-file fingerprint; --narrow moves it.
#
# State: rubric-drift.lock.json next to this script (syncs via convention-sync).
# Holds last-reconciled hashes + the acknowledged-uncovered list (rules triaged
# as not-eval-relevant, with reasons). Rules are NOT tagged in their SKILL.md.
#
# Usage:
#   rubric-drift.sh                          # check; reads the lock, never writes it
#   rubric-drift.sh --baseline [--reason R]  # snapshot all hashes; ack all
#                                            #   currently-uncovered rules as R
#   rubric-drift.sh --forget A [A...]        # drop a lock anchor the rubric no longer
#                                            # cites on purpose (clears MISSING/UNANCHORED)
#   rubric-drift.sh --reconcile A [A...]     # after triaging, accept anchor A's
#                                            #   current hash (A = skill:rule-id
#                                            #   or file:<basename>)
#   rubric-drift.sh --ack skill:rule-id --reason R   # ack one uncovered rule
#   rubric-drift.sh --exclude-skill <name> --reason R
#                                            # mark a whole skill OUT OF COVERAGE SCOPE:
#                                            # rubrics grade ORCH-DEPENDENT skills only
#                                            # (operator/discussion tooling never runs
#                                            # inside an orch run), so its rules are
#                                            # never flagged UNCOVERED and need no acks
#   rubric-drift.sh --prune                  # drop acks the lock no longer needs: for
#                                            #   rules a dimension now anchors, and for
#                                            #   rules that were deleted
#   rubric-drift.sh --lapsed                 # list the lapsed blanket acks. Reads only
#   rubric-drift.sh --fingerprints           # list each file anchor: narrowed (with the
#                                            #   blocks) or whole (with the dimensions
#                                            #   that name no block). Reads only
#   rubric-drift.sh --narrow                 # one-time: move a lock from the whole-file
#                                            #   fingerprint to the narrowed one. Refuses
#                                            #   unless every file anchor is clean first
#   rubric-drift.sh --map                    # emit {dim: {name, gate, file, line}} JSON
#                                            #   (consumed by eval-run report annotation)
#
# Only --baseline, --reconcile, --forget, --ack, --exclude-skill, --prune and
# --narrow write the lock. The check and --map read it and leave it byte for byte as found.
#
# Acks are PER-VERSION (store the rule's hash at ack time): if an acked rule's
# content later changes it re-flags once as UNCOVERED-CHANGED for re-triage.
#
# A BLANKET ack is one --baseline wrote for every rule at once, with nobody
# judging the rule. It lapses 90 days after its date: the check then prints one
# LAPSED-ACK summary line and --lapsed lists the rules. A lapsed ack is a
# reminder to judge the rule, never a finding: it does not change the exit
# code. --ack on the rule replaces it with a judged one.
#
# Env (for testing): RD_SKILLS_DIR, RD_RULES_DIR, RD_WATCHER_DIR, RD_LOCK,
# RD_TODAY (YYYY-MM-DD in place of the clock).
# Exit (check): 0 = clean; 1 = an anchored rule or file drifted (CHANGED,
#   MISSING, NEW-ANCHOR, UNANCHORED), with or without uncovered rules;
#   3 = no drift, but a rule is uncovered (UNCOVERED, UNCOVERED-CHANGED);
#   2 = usage/parse error. STALE-ACK, REDUNDANT-ACK, LAPSED-ACK and PARSE-WARN
#   lines are notes and never change the exit code.
set -euo pipefail

# Bash 3.2 cannot nest a heredoc inside "$(...)", so the node payload lives
# after the __NODE__ marker at the bottom of this file and is self-extracted.
NODE_CODE=$(sed -n '/^#__NODE__$/,$p' "$0" | tail -n +2)
exec node -e "$NODE_CODE" -- "$@"
#__NODE__
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const os = require('os')

const HOME = os.homedir()
const SKILLS_DIR = process.env.RD_SKILLS_DIR || path.join(HOME, '.cursor/skills')
const RULES_DIR = process.env.RD_RULES_DIR || path.join(HOME, '.cursor/rules')
const WATCHER_DIR = process.env.RD_WATCHER_DIR || path.join(HOME, '.config/agent-watcher')
const LOCK = process.env.RD_LOCK || path.join(SKILLS_DIR, 'rubric-drift.lock.json')
const RUBRICS = [
  path.join(SKILLS_DIR, 'agent-eval/references/rubric.md'),
  path.join(SKILLS_DIR, 'orch-eval/references/rubric.md'),
]

// ---- args ----
const argv = process.argv.slice(1) // node -e swallows the leading `--`; real args start at 1
const has = (f) => argv.includes(f)
const val = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : undefined }
const vals = (f) => { // all non-flag tokens after f
  const i = argv.indexOf(f); if (i < 0) return []
  const out = []
  for (let j = i + 1; j < argv.length && !argv[j].startsWith('--'); j++) out.push(argv[j])
  return out
}
const MODE = has('--baseline') ? 'baseline' : has('--forget') ? 'forget' : has('--reconcile') ? 'reconcile' : has('--ack') ? 'ack' : has('--map') ? 'map' : has('--exclude-skill') ? 'exclude' : has('--prune') ? 'prune' : has('--narrow') ? 'narrow' : has('--fingerprints') ? 'fingerprints' : has('--lapsed') ? 'lapsed' : 'check'

const sha = (s) => crypto.createHash('sha256').update(s.replace(/\s+/g, ' ').trim()).digest('hex').slice(0, 12)

// ---- index all <rule id> bodies across skills + rules ----
// key: "<skill>:<rule-id>" (skill = SKILL.md parent dir, or .mdc basename)
const ruleIndex = new Map()
function indexRules(file, skillName) {
  const text = fs.readFileSync(file, 'utf8')
  const re = /<rule id="([^"]+)">([\s\S]*?)<\/rule>/g
  let m
  while ((m = re.exec(text))) {
    const key = skillName + ':' + m[1]
    ruleIndex.set(key, { hash: sha(m[2]), file })
  }
}
for (const d of fs.existsSync(SKILLS_DIR) ? fs.readdirSync(SKILLS_DIR) : []) {
  const f = path.join(SKILLS_DIR, d, 'SKILL.md')
  if (fs.existsSync(f)) indexRules(f, d)
  // Reference slices too: a skill whose body outgrew the re-attach budget
  // keeps its rules verbatim in <skill>/references/*.md. The anchor stays
  // <skill>:<rule-id> wherever the body lives, so a moved rule keeps its lock
  // entry and only a real content change reports CHANGED.
  const refs = path.join(SKILLS_DIR, d, 'references')
  let slices = []
  try { slices = fs.readdirSync(refs) } catch { slices = [] }
  for (const s of slices) if (s.endsWith('.md')) indexRules(path.join(refs, s), d)
}
for (const f of fs.existsSync(RULES_DIR) ? fs.readdirSync(RULES_DIR) : []) {
  if (f.endsWith('.mdc')) indexRules(path.join(RULES_DIR, f), f.replace(/\.mdc$/, ''))
}
// rule-id -> [skill...] for disambiguation
const byId = new Map()
for (const key of ruleIndex.keys()) {
  const [skill, id] = [key.slice(0, key.indexOf(':')), key.slice(key.indexOf(':') + 1)]
  if (!byId.has(id)) byId.set(id, [])
  byId.get(id).push(skill)
}

// ---- parse rubric dimension rows -> anchors ----
// anchors: Map key -> { dims:Set, kind:'rule'|'file', hash|null, path? }
const anchors = new Map()
const parseErrors = []
function addAnchor(key, dim, kind, hash, p, tokens) {
  if (!anchors.has(key)) anchors.set(key, { dims: new Set(), kind, hash, path: p, named: new Map() })
  anchors.get(key).dims.add(dim)
  if (tokens) anchors.get(key).named.set(dim, tokens)
}
function resolveFile(tok) {
  const isFile = (c) => { try { return fs.statSync(c).isFile() } catch { return false } }
  const flat = (t) => [path.join(WATCHER_DIR, t), path.join(WATCHER_DIR, 'hooks', t), path.join(WATCHER_DIR, 'lib', t),
                       path.join(SKILLS_DIR, t), path.join(SKILLS_DIR, 'one-shot/scripts', t)]
  if (tok.includes('/')) {
    // skill-relative path first (e.g. templates/agent-run-report.md), then basename fallback
    // for tokens that captured a partial absolute path (e.g. config/agent-watcher/set-tested.sh)
    const rel = fs.readdirSync(SKILLS_DIR).map((d) => path.join(SKILLS_DIR, d, tok)).find(isFile)
    return rel || flat(path.basename(tok)).find(isFile)
  }
  return flat(tok).find(isFile)
}
const dimIndex = {} // dim -> {name, gate, file, line} for --map consumers
for (const rubric of RUBRICS) {
  if (!fs.existsSync(rubric)) { parseErrors.push('rubric missing: ' + rubric); continue }
  const rubricLines = fs.readFileSync(rubric, 'utf8').split('\n')
  for (let li = 0; li < rubricLines.length; li++) {
    const line = rubricLines[li]
    const row = line.match(/^\|\s*([AO]\d+)\s*\|/)
    if (!row) continue
    const dim = row[1]
    const cells = line.split('|').map((c) => c.trim()).filter((c) => c.length)
    const grounding = cells[cells.length - 1]
    const rawName = cells[1] || ''
    dimIndex[dim] = {
      name: rawName.replace(/\*\*/g, '').replace(/\s*\(GATE[^)]*\)\s*/i, '').trim(),
      gate: /GATE/.test(rawName),
      file: rubric,
      line: li + 1,
    }
    // rule anchors: backticked tokens matching known rule ids
    for (const t of grounding.matchAll(/`([a-z][a-z0-9_-]*)`/g)) {
      const id = t[1]
      const skills = byId.get(id)
      if (!skills) continue
      const named = skills.filter((s) => grounding.includes(s))
      for (const s of named.length ? named : skills) {
        const key = s + ':' + id
        addAnchor(key, dim, 'rule', ruleIndex.get(key).hash)
      }
    }
    // file anchors: *.js/*.sh + templates/*.md tokens
    const fileToks = new Set()
    for (const t of grounding.matchAll(/([\w][\w./-]*\.(?:js|sh))\b/g)) fileToks.add(t[1])
    for (const t of grounding.matchAll(/((?:[\w-]+\/)+[\w-]+\.md)\b/g)) fileToks.add(t[1])
    for (const tok of fileToks) {
      const p = resolveFile(tok)
      if (!p) { parseErrors.push(`${dim}: unresolvable file anchor "${tok}"`); continue }
      // hash is filled in once the lock says which fingerprint it holds
      const ticks = [...grounding.matchAll(/`<?([A-Za-z_][\w-]*)>?`/g)].map((t) => t[1])
      addAnchor('file:' + path.basename(tok), dim, 'file', null, p, ticks)
    }
  }
}

if (MODE === 'map') { console.log(JSON.stringify(dimIndex)); process.exit(0) }

// ---- lock ----
const lock = fs.existsSync(LOCK)
  ? JSON.parse(fs.readFileSync(LOCK, 'utf8'))
  : { baselined_at: null, anchors: {}, acked_uncovered: {} }
const save = () => fs.writeFileSync(LOCK, JSON.stringify(lock, null, 2) + '\n')

// ---- file anchor fingerprints ----
// The header is the leading run of comment and blank lines (shebang included).
function headerEnd(lines, ext) {
  const c = ext === '.js' ? '//' : '#'
  let i = 0, inBlock = false
  for (; i < lines.length; i++) {
    const t = lines[i].trim()
    if (inBlock) { if (t.includes('*/')) inBlock = false; continue }
    if (ext === '.js' && t.startsWith('/*')) { if (!t.includes('*/')) inBlock = true; continue }
    if (t === '' || t.startsWith(c) || t.startsWith('#!')) continue
    break
  }
  return i
}
// A named block: a top-level definition of the token, through its closing
// line when the definition line opens a bracket. null when the file has none.
function blockOf(lines, tok, ext) {
  if (ext === '.md') {
    const i = lines.findIndex((l) => new RegExp('<' + tok + '[\\s>]').test(l))
    if (i < 0) return null
    let j = i
    while (j < lines.length && !lines[j].includes('</' + tok + '>')) j++
    return { name: tok, start: i, end: Math.min(j, lines.length - 1) }
  }
  const re = new RegExp('^(?:(?:async\\s+)?function\\s+' + tok + '\\b|(?:const|let|var)\\s+' + tok + '\\b|' + tok + '\\s*\\(\\)|(?:readonly\\s+|export\\s+|declare\\s+(?:-\\w+\\s+)?)?' + tok + '=)')
  const i = lines.findIndex((l) => re.test(l))
  if (i < 0) return null
  let j = i
  if (/[{(\[]\s*$/.test(lines[i])) {
    j = i + 1
    while (j < lines.length && !/^[})\]]/.test(lines[j])) j++
    j = Math.min(j, lines.length - 1)
  }
  return { name: tok, start: i, end: j }
}
function fingerprintFile(a) {
  const text = fs.readFileSync(a.path, 'utf8')
  const ext = path.extname(a.path)
  const lines = text.split('\n')
  const hEnd = ext === '.md' ? 0 : headerEnd(lines, ext)
  const header = lines.slice(0, hEnd).join('\n')
  const blocks = new Map(), unnamed = []
  for (const dim of [...a.dims].sort()) {
    const found = (a.named.get(dim) || []).map((t) => blockOf(lines, t, ext)).filter(Boolean)
    if (!found.length) unnamed.push(dim)
    for (const b of found) blocks.set(b.name, b)
  }
  const v1 = sha(text)
  if (!unnamed.length) {
    const ordered = [...blocks.values()].sort((x, y) => x.start - y.start)
    const body = ordered.map((b) => lines.slice(b.start, b.end + 1).join('\n')).join('\n')
    return { v1, v2: sha(header + '\n' + body), mode: 'narrowed', blocks: ordered.map((b) => b.name), unnamed }
  }
  if (ext === '.md') return { v1, v2: v1, mode: 'whole', blocks: [], unnamed }
  const c = ext === '.js' ? '//' : '#'
  const code = lines.slice(hEnd).filter((l) => !l.trim().startsWith(c)).join('\n')
  return { v1, v2: sha(header + '\n' + code), mode: 'whole', blocks: [], unnamed }
}
// --baseline always writes the narrowed fingerprint; otherwise the lock decides.
const FP = MODE === 'baseline' || lock.file_fingerprint === 2 ? 2 : 1
for (const a of anchors.values()) {
  if (a.kind !== 'file') continue
  a.fp = fingerprintFile(a)
  a.hash = FP === 2 ? a.fp.v2 : a.fp.v1
}
const fileAnchors = [...anchors].filter(([, a]) => a.kind === 'file')

if (MODE === 'fingerprints') {
  for (const [key, a] of fileAnchors) {
    console.log(a.fp.mode === 'narrowed'
      ? `NARROWED ${key} (dims ${[...a.dims].sort()}) header + ${a.fp.blocks.join(', ')}`
      : `WHOLE ${key} (dims ${[...a.dims].sort()}) no block named by ${a.fp.unnamed.join(', ')}`)
  }
  console.log(`${fileAnchors.filter(([, a]) => a.fp.mode === 'narrowed').length} narrowed, ${fileAnchors.filter(([, a]) => a.fp.mode === 'whole').length} whole; lock holds the ${FP === 2 ? 'narrowed' : 'whole-file'} fingerprint`)
  process.exit(0)
}

if (MODE === 'narrow') {
  if (lock.file_fingerprint === 2) { console.error('NARROW-FAIL the lock already holds the narrowed fingerprint'); process.exit(2) }
  // Both fingerprints side by side: the old one must match the lock for every
  // file anchor, so the rewrite cannot hide a change nobody has read.
  const dirty = []
  for (const [key, a] of fileAnchors) {
    const prev = lock.anchors[key]
    if (!prev) dirty.push(`${key}: not in the lock`)
    else if (prev.hash !== a.fp.v1) dirty.push(`${key}: changed since the last reconcile (${prev.hash} -> ${a.fp.v1})`)
  }
  for (const key of Object.keys(lock.anchors)) {
    if (key.startsWith('file:') && !anchors.has(key)) dirty.push(`${key}: in the lock, no longer cited`)
  }
  if (dirty.length) {
    for (const d of dirty) console.error('NARROW-FAIL ' + d)
    console.error('Reconcile or forget these first, then run --narrow again.')
    process.exit(1)
  }
  for (const [key, a] of fileAnchors) {
    lock.anchors[key] = { hash: a.fp.v2, dims: [...a.dims].sort() }
    console.log(`${a.fp.mode === 'narrowed' ? 'NARROWED' : 'WHOLE'} ${key} ${a.fp.v1} -> ${a.fp.v2}`)
  }
  lock.file_fingerprint = 2
  save()
  console.log(`MOVED ${fileAnchors.length} file anchor(s) to the narrowed fingerprint`)
  process.exit(0)
}
const today = process.env.RD_TODAY || new Date().toISOString().slice(0, 10)
const LAPSE_DAYS = 90

// Acks are PER-VERSION: each stores the rule's hash at ack time, so a later
// content change re-flags once (UNCOVERED-CHANGED) for re-triage. Legacy
// string acks are converted in memory, so only a write mode stores the new
// shape. An ack for a rule a dimension now anchors is redundant (anchored
// rules are hash-tracked): the check notes it and --prune removes it.
const redundantAcks = []
for (const k of Object.keys(lock.acked_uncovered)) {
  if (typeof lock.acked_uncovered[k] === 'string') {
    lock.acked_uncovered[k] = { reason: lock.acked_uncovered[k], hash: ruleIndex.has(k) ? ruleIndex.get(k).hash : null }
  }
  if (anchors.has(k)) redundantAcks.push(k)
}
const staleAcks = Object.keys(lock.acked_uncovered).filter((k) => !ruleIndex.has(k))

if (MODE === 'prune') {
  for (const k of redundantAcks) delete lock.acked_uncovered[k]
  for (const k of staleAcks) delete lock.acked_uncovered[k]
  save()
  console.log(`PRUNED ${redundantAcks.length} now-anchored ack(s) and ${staleAcks.length} ack(s) for deleted rules`)
  process.exit(0)
}

if (MODE === 'baseline') {
  const reason = val('--reason') || 'pre-baseline (not triaged individually)'
  lock.baselined_at = today
  lock.file_fingerprint = 2
  lock.anchors = {}
  for (const [key, a] of anchors) lock.anchors[key] = { hash: a.hash, dims: [...a.dims].sort() }
  for (const key of ruleIndex.keys()) {
    if (!anchors.has(key) && !lock.acked_uncovered[key]) {
      lock.acked_uncovered[key] = { reason: `${today}: ${reason}`, hash: ruleIndex.get(key).hash, blanket: true }
    }
  }
  save()
  console.log(`BASELINED ${anchors.size} anchors (${[...anchors.values()].filter((a) => a.kind === 'rule').length} rule, ${[...anchors.values()].filter((a) => a.kind === 'file').length} file); acked ${Object.keys(lock.acked_uncovered).length} uncovered rules`)
  if (parseErrors.length) { for (const e of parseErrors) console.log('PARSE-WARN ' + e) }
  process.exit(0)
}

if (MODE === 'reconcile') {
  const targets = vals('--reconcile')
  if (!targets.length) { console.error('usage: --reconcile <skill:rule-id|file:name> [...]'); process.exit(2) }
  for (const t of targets) {
    if (!anchors.has(t)) { console.error(`RECONCILE-FAIL ${t}: not a current anchor`); process.exit(2) }
    lock.anchors[t] = { hash: anchors.get(t).hash, dims: [...anchors.get(t).dims].sort() }
    console.log(`RECONCILED ${t} @ ${anchors.get(t).hash}`)
  }
  save()
  process.exit(0)
}

if (MODE === 'forget') {
  const targets = vals('--forget')
  if (!targets.length) { console.error('usage: --forget <skill:rule-id|file:name> [...]'); process.exit(2) }
  for (const t of targets) {
    if (anchors.has(t)) { console.error(`FORGET-FAIL ${t}: still cited by the rubric; --reconcile it instead`); process.exit(2) }
    if (!lock.anchors[t]) { console.error(`FORGET-FAIL ${t}: not in the lock`); process.exit(2) }
    delete lock.anchors[t]
    console.log(`FORGOT ${t}`)
  }
  save()
  process.exit(0)
}

if (MODE === 'exclude') {
  const name = val('--exclude-skill'), reason = val('--reason')
  if (!name || !reason) { console.error('usage: --exclude-skill <name> --reason "why non-orch"'); process.exit(2) }
  lock.excluded_skills = lock.excluded_skills || {}
  lock.excluded_skills[name] = `${today}: ${reason}`
  // prune now-redundant per-rule acks for the excluded skill
  let pruned = 0
  for (const k of Object.keys(lock.acked_uncovered)) {
    if (k.startsWith(name + ':')) { delete lock.acked_uncovered[k]; pruned++ }
  }
  save()
  console.log(`EXCLUDED ${name} from coverage scope (${pruned} per-rule ack(s) pruned)`)
  process.exit(0)
}

if (MODE === 'ack') {
  const id = val('--ack'), reason = val('--reason')
  if (!id || !reason) { console.error('usage: --ack skill:rule-id --reason "why not eval-relevant"'); process.exit(2) }
  if (!ruleIndex.has(id)) { console.error(`ACK-FAIL ${id}: no such rule in corpus`); process.exit(2) }
  lock.acked_uncovered[id] = { reason: `${today}: ${reason}`, hash: ruleIndex.get(id).hash }
  save()
  console.log(`ACKED ${id}`)
  process.exit(0)
}

// ---- check ----
if (!lock.baselined_at) { console.error('No baseline. Run: rubric-drift.sh --baseline'); process.exit(2) }
const excluded = lock.excluded_skills || {}
// Blanket acks past the lapse period, among the acks still in force (rule
// exists, unanchored, skill in scope, content unchanged since the ack).
const lapsed = []
for (const [key, ack] of Object.entries(lock.acked_uncovered)) {
  if (!ruleIndex.has(key) || anchors.has(key) || excluded[key.slice(0, key.indexOf(':'))]) continue
  if (ack.hash && ack.hash !== ruleIndex.get(key).hash) continue
  const date = (String(ack.reason).match(/^(\d{4}-\d\d-\d\d):/) || [])[1]
  const blanket = ack.blanket === true || /^\d{4}-\d\d-\d\d: pre-baseline/.test(String(ack.reason))
  if (!blanket || !date) continue
  const days = Math.floor((Date.parse(today) - Date.parse(date)) / 86400000)
  if (days > LAPSE_DAYS) lapsed.push({ key, date, days })
}
lapsed.sort((a, b) => a.date.localeCompare(b.date) || a.key.localeCompare(b.key))
if (MODE === 'lapsed') {
  for (const l of lapsed) console.log(`LAPSED-ACK ${l.key} (blanket ack of ${l.date}, ${l.days} days old)`)
  console.log(`${lapsed.length} blanket ack(s) older than ${LAPSE_DAYS} days`)
  process.exit(0)
}
let drift = 0, uncovered = 0
const out = (s) => { console.log(s); drift++ }
const cov = (s) => { console.log(s); uncovered++ }
// drift on anchored items
for (const [key, a] of anchors) {
  const prev = lock.anchors[key]
  if (!prev) out(`NEW-ANCHOR ${key} (dims ${[...a.dims]}) — rubric now cites it; reconcile to start tracking`)
  else if (prev.hash !== a.hash) out(`CHANGED ${key} (dims ${[...a.dims]}) ${prev.hash} -> ${a.hash} — re-read the rule/file diff; update the dimension wording if the expectation moved, then --reconcile ${key}`)
}
for (const key of Object.keys(lock.anchors)) {
  if (!anchors.has(key)) {
    const gone = key.startsWith('file:') ? !resolveFile(key.slice(5)) : !ruleIndex.has(key)
    out(`${gone ? 'MISSING' : 'UNANCHORED'} ${key} (dims ${lock.anchors[key].dims}) — ${gone ? 'the anchored rule/file no longer exists; the dimension may be stale' : `rubric no longer cites it; --forget ${key} after confirming intentional`}`)
  }
}
// coverage: corpus rules with no anchor and no current-version ack.
// Skills in excluded_skills are categorically OUT OF SCOPE (rubrics grade
// orch-dependent behavior only): never flagged, no per-rule acks needed.
for (const key of ruleIndex.keys()) {
  if (excluded[key.slice(0, key.indexOf(':'))]) continue
  if (anchors.has(key)) continue
  const ack = lock.acked_uncovered[key]
  if (!ack) cov(`UNCOVERED ${key} — new rule with no rubric dimension; propose a dimension or --ack with a reason`)
  else if (ack.hash && ack.hash !== ruleIndex.get(key).hash) cov(`UNCOVERED-CHANGED ${key} ${ack.hash} -> ${ruleIndex.get(key).hash} — acked rule's content changed since the ack; re-triage: propose a dimension or --ack ${key} again`)
}
// hygiene notes: acks the lock no longer needs. Neither is a finding.
for (const key of staleAcks) console.log(`STALE-ACK ${key} — rule deleted; --prune removes the ack`)
for (const key of redundantAcks) console.log(`REDUNDANT-ACK ${key} — a dimension now anchors this rule; --prune removes the ack`)
if (lapsed.length) console.log(`LAPSED-ACK ${lapsed.length} blanket ack(s) are older than ${LAPSE_DAYS} days (oldest ${lapsed[0].date}); nobody judged these rules one by one. --lapsed lists them; --ack <skill:rule-id> --reason R settles one`)
for (const e of parseErrors) console.log('PARSE-WARN ' + e)
if (FP === 1 && fileAnchors.length) console.log('NOTE the lock holds the whole-file fingerprint for file anchors; --narrow moves it to the narrowed one')
if (!drift && !uncovered) console.log(`CLEAN — ${anchors.size} anchors tracked, baseline ${lock.baselined_at}`)
process.exit(drift ? 1 : uncovered ? 3 : 0)
