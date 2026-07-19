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
# State: rubric-drift.lock.json next to this script (syncs via convention-sync).
# Holds last-reconciled hashes + the acknowledged-uncovered list (rules triaged
# as not-eval-relevant, with reasons). Rules are NOT tagged in their SKILL.md.
#
# Usage:
#   rubric-drift.sh                          # check; exit 0 clean, 1 drift found
#   rubric-drift.sh --baseline [--reason R]  # snapshot all hashes; ack all
#                                            #   currently-uncovered rules as R
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
#   rubric-drift.sh --map                    # emit {dim: {name, gate, file, line}} JSON
#                                            #   (consumed by eval-run report annotation)
#
# Acks are PER-VERSION (store the rule's hash at ack time): if an acked rule's
# content later changes it re-flags once as UNCOVERED-CHANGED for re-triage.
#
# Env (for testing): RD_SKILLS_DIR, RD_RULES_DIR, RD_WATCHER_DIR, RD_LOCK.
# Exit: 0 = clean, 1 = drift/coverage findings, 2 = usage/parse error.
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
const MODE = has('--baseline') ? 'baseline' : has('--reconcile') ? 'reconcile' : has('--ack') ? 'ack' : has('--map') ? 'map' : has('--exclude-skill') ? 'exclude' : 'check'

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
function addAnchor(key, dim, kind, hash, p) {
  if (!anchors.has(key)) anchors.set(key, { dims: new Set(), kind, hash, path: p })
  anchors.get(key).dims.add(dim)
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
      addAnchor('file:' + path.basename(tok), dim, 'file', sha(fs.readFileSync(p, 'utf8')), p)
    }
  }
}

if (MODE === 'map') { console.log(JSON.stringify(dimIndex)); process.exit(0) }

// ---- lock ----
const lock = fs.existsSync(LOCK)
  ? JSON.parse(fs.readFileSync(LOCK, 'utf8'))
  : { baselined_at: null, anchors: {}, acked_uncovered: {} }
const save = () => fs.writeFileSync(LOCK, JSON.stringify(lock, null, 2) + '\n')
const today = new Date().toISOString().slice(0, 10)

// Acks are PER-VERSION: each stores the rule's hash at ack time, so a later
// content change re-flags once (UNCOVERED-CHANGED) for re-triage. Migrate
// legacy string acks in place; drop acks for rules a dimension now anchors
// (anchored rules are hash-tracked, the ack is redundant).
{
  let migrated = 0, dropped = 0
  for (const k of Object.keys(lock.acked_uncovered)) {
    if (typeof lock.acked_uncovered[k] === 'string') {
      lock.acked_uncovered[k] = { reason: lock.acked_uncovered[k], hash: ruleIndex.has(k) ? ruleIndex.get(k).hash : null }
      migrated++
    }
    if (anchors.has(k)) { delete lock.acked_uncovered[k]; dropped++ }
  }
  if (migrated || dropped) {
    save()
    console.log(`MIGRATED ${migrated} ack(s) to per-version format; dropped ${dropped} now-anchored ack(s)`)
  }
}

if (MODE === 'baseline') {
  const reason = val('--reason') || 'pre-baseline (not triaged individually)'
  lock.baselined_at = today
  lock.anchors = {}
  for (const [key, a] of anchors) lock.anchors[key] = { hash: a.hash, dims: [...a.dims].sort() }
  for (const key of ruleIndex.keys()) {
    if (!anchors.has(key) && !lock.acked_uncovered[key]) {
      lock.acked_uncovered[key] = { reason: `${today}: ${reason}`, hash: ruleIndex.get(key).hash }
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
let findings = 0
const out = (s) => { console.log(s); findings++ }
// drift on anchored items
for (const [key, a] of anchors) {
  const prev = lock.anchors[key]
  if (!prev) out(`NEW-ANCHOR ${key} (dims ${[...a.dims]}) — rubric now cites it; reconcile to start tracking`)
  else if (prev.hash !== a.hash) out(`CHANGED ${key} (dims ${[...a.dims]}) ${prev.hash} -> ${a.hash} — re-read the rule/file diff; update the dimension wording if the expectation moved, then --reconcile ${key}`)
}
for (const key of Object.keys(lock.anchors)) {
  if (!anchors.has(key)) {
    const gone = key.startsWith('file:') ? !resolveFile(key.slice(5)) : !ruleIndex.has(key)
    out(`${gone ? 'MISSING' : 'UNANCHORED'} ${key} (dims ${lock.anchors[key].dims}) — ${gone ? 'the anchored rule/file no longer exists; the dimension may be stale' : 'rubric no longer cites it; --reconcile after confirming intentional'}`)
  }
}
// coverage: corpus rules with no anchor and no current-version ack.
// Skills in excluded_skills are categorically OUT OF SCOPE (rubrics grade
// orch-dependent behavior only): never flagged, no per-rule acks needed.
const excluded = lock.excluded_skills || {}
for (const key of ruleIndex.keys()) {
  if (excluded[key.slice(0, key.indexOf(':'))]) continue
  if (anchors.has(key)) continue
  const ack = lock.acked_uncovered[key]
  if (!ack) out(`UNCOVERED ${key} — new rule with no rubric dimension; propose a dimension or --ack with a reason`)
  else if (ack.hash && ack.hash !== ruleIndex.get(key).hash) out(`UNCOVERED-CHANGED ${key} ${ack.hash} -> ${ruleIndex.get(key).hash} — acked rule's content changed since the ack; re-triage: propose a dimension or --ack ${key} again`)
}
// hygiene: acks pointing at dead rules
for (const key of Object.keys(lock.acked_uncovered)) {
  if (!ruleIndex.has(key)) console.log(`STALE-ACK ${key} — rule deleted; safe to remove from lock`)
}
for (const e of parseErrors) console.log('PARSE-WARN ' + e)
if (!findings) console.log(`CLEAN — ${anchors.size} anchors tracked, baseline ${lock.baselined_at}`)
process.exit(findings ? 1 : 0)
