#!/usr/bin/env node
// Replay comparator: score replayed /pr-review findings against the real human
// review comments on the same PR, with a Sonnet judge batched through
// `claude -p` on the subscription (no API key, no GitHub calls).
//
// Stage 1 (per PR, cached, independent of the findings): build the human set.
// Inline threads rooted by a human count as they are. A human review summary is
// split into points; a point that only restates an inline comment from the same
// review is dropped (the inline comment already counts it). Conversation
// comments count as their own items. Every item is marked actionable or not
// (praise, thanks, status chatter and pure questions are not), and recall uses
// the actionable items. Baseline and candidate replays of one PR therefore share
// one denominator.
//
// Stage 2 (per findings file): label each finding `match` (with the human ids it
// matches), `valid` (a real issue no human raised) or `noise`. Inline comments
// match on location and substance, summary and conversation points on substance
// only. A human item is caught when any finding matches it.
//
// Metrics, per findings file and per label (version) in aggregate:
//   recall           caught actionable human items / actionable human items
//   precision        matched findings / findings
//   signal-to-noise  (matched + valid) / noise
// plus counts per finding tag (the rule or lens behind each finding).
//
// Usage:
//   replay-compare.js --findings <file|dir> [--findings ...] [--export <jsonl>]
//     [--out <dir>] [--label <name>] [--repo-dir <clone>] [--sha <commit>]
//     [--human-until <iso>] [--allow-held-out] [--model sonnet] [--parallel 3]
//     [--sample <n>] [--dry-run]
//
// Judge verdicts are cached by prompt; --sample <n> (default 1) draws a fresh
// verdict under a separate cache key, to measure run-to-run judge variance.
//
// Findings file: an object with `repo` and `number` (or `prUrl`) and a list in
// `findings` (workflow shape: file/path, line, summary, failure_scenario, lens,
// tag) or `comments` (/pr-review Review JSON: path, line, start_line, body, tag),
// or a bare array with --pr owner/repo#N. A missing `tag` falls back to the
// `<!-- pr-review:tag=... -->` marker in the body, then `lens:<lens>`, then
// `untagged`. Optional `label` (the version), `snapshot` (a directory holding
// the PR's files; defaults to replay-snapshot.py's
// ~/.config/pr-review/replay/snapshots/<repo>-<N>/repo when it exists) or
// `repoDir` + `sha` give the judge code around each finding; a finding's own
// `commit` overrides `sha`. Human comments from every review round count; a
// later-round comment on code the snapshot lacks counts as missed for every
// version alike, and --human-until <iso> drops comments after a cutoff.
//
// Export: the scrape JSONL. Rows without `kind` are inline threads (the
// 2025-10-23 export); the rerun adds kind = thread | review_summary |
// conversation | pr. Human logins come from the machine-local accounts.json
// (`humans`), never from this file.
//
// Held-out PRs (number mod 3 == 2) are refused unless --allow-held-out, which
// only the replay run passes.
const { spawn, spawnSync } = require('child_process')
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')

const HOME = process.env.HOME
const MINING = `${HOME}/.config/pr-review/mining`
const CACHE = `${HOME}/.cache/replay-compare-judge`
const PROMPT_VERSION = 'rc-v3'
const FINDING_BATCH = 25

function parseArgs(argv) {
  const opts = { findings: [], parallel: 3, model: 'sonnet' }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const next = () => {
      if (i + 1 >= argv.length) die(`${a} needs a value`)
      return argv[++i]
    }
    if (a === '--findings') opts.findings.push(next())
    else if (a === '--export') opts.export = next()
    else if (a === '--accounts') opts.accounts = next()
    else if (a === '--out') opts.out = next()
    else if (a === '--label') opts.label = next()
    else if (a === '--pr') opts.pr = next()
    else if (a === '--repo-dir') opts.repoDir = next()
    else if (a === '--sha') opts.sha = next()
    else if (a === '--human-until') opts.humanUntil = next()
    else if (a === '--model') opts.model = next()
    else if (a === '--parallel') opts.parallel = Number(next())
    else if (a === '--sample') opts.sample = Number(next())
    else if (a === '--allow-held-out') opts.allowHeldOut = true
    else if (a === '--dry-run') opts.dryRun = true
    else if (a === '-h' || a === '--help') {
      process.stdout.write(fs.readFileSync(__filename, 'utf8').split('\nconst ')[0])
      process.exit(0)
    } else die(`unknown argument: ${a}`)
  }
  if (opts.findings.length === 0) die('pass at least one --findings <file|dir>')
  return opts
}

function die(msg) {
  process.stderr.write(`replay-compare: ${msg}\n`)
  process.exit(2)
}

// Newest rerun export (has `kind`) when present, else the first threads export.
function defaultExport() {
  const files = fs.readdirSync(MINING).filter(f => /^review-.*\.jsonl$/.test(f))
  const rerun = files.filter(f => !f.startsWith('review-threads-')).sort()
  const pick = rerun.length > 0 ? rerun[rerun.length - 1] : files.sort()[0]
  if (pick == null) die(`no review-*.jsonl export in ${MINING}`)
  return path.join(MINING, pick)
}

function loadHumans(file) {
  const accounts = JSON.parse(fs.readFileSync(file, 'utf8'))
  const humans = new Set((accounts.humans ?? []).map(h => h.toLowerCase()))
  if (humans.size === 0) die(`no humans listed in ${file}`)
  return humans
}

// --- findings ---------------------------------------------------------------

const TAG_MARKER = /<!--\s*pr-review:tag=([^\s>]+)\s*-->/

function parsePrRef(ref) {
  const m = /github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/.exec(ref) ?? /^(?:([^/]+)\/)?([^#/]+)#(\d+)$/.exec(ref)
  if (m == null) die(`cannot read a PR from "${ref}"`)
  return { repo: m[2], number: Number(m[3]) }
}

function findingFiles(paths) {
  const out = []
  for (const p of paths) {
    if (fs.statSync(p).isDirectory()) {
      for (const f of fs.readdirSync(p).sort()) if (f.endsWith('.json')) out.push(path.join(p, f))
    } else out.push(p)
  }
  return out
}

function loadFindings(file, opts) {
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'))
  const doc = Array.isArray(raw) ? { findings: raw } : raw
  let pr
  if (doc.repo != null && (doc.number ?? doc.prNumber) != null) pr = { repo: doc.repo, number: Number(doc.number ?? doc.prNumber) }
  else if (doc.prUrl != null || doc.url != null) pr = parsePrRef(doc.prUrl ?? doc.url)
  else if (opts.pr != null) pr = parsePrRef(opts.pr)
  else die(`${file}: no repo/number or prUrl, and no --pr`)
  const list = doc.findings ?? doc.comments ?? []
  const findings = list.map((f, i) => {
    const body = f.body ?? [f.summary, f.failure_scenario].filter(Boolean).join('\n\nFailure scenario: ')
    const marker = TAG_MARKER.exec(body ?? '')
    const tag = f.tag ?? (marker ? marker[1] : null) ?? (f.lens ? `lens:${f.lens}` : null) ?? 'untagged'
    return {
      id: `f${i + 1}`,
      path: f.path ?? f.file ?? null,
      line: f.line ?? f.endLine ?? null,
      startLine: f.start_line ?? f.startLine ?? null,
      // Bot comments carry HTML button blocks (fix-in-editor links) that only
      // cost judge tokens.
      body: clip(String(body ?? '').replace(/<div[\s\S]*?<\/div>/g, ''), 2000),
      tag,
      commit: f.commit ?? null,
      sourceUrl: f.url ?? null
    }
  })
  return {
    file,
    pr,
    label: opts.label ?? doc.label ?? doc.version ?? path.basename(path.dirname(path.resolve(file))),
    snapshot: doc.snapshot ?? doc.snapshotDir ?? defaultSnapshot(pr),
    repoDir: opts.repoDir ?? doc.repoDir ?? null,
    sha: opts.sha ?? doc.sha ?? doc.headSha ?? null,
    findings
  }
}

// The checked-out tree replay-snapshot.py builds for the PR, when it exists.
function defaultSnapshot(pr) {
  const dir = `${HOME}/.config/pr-review/replay/snapshots/${pr.repo}-${pr.number}/repo`
  return fs.existsSync(dir) ? dir : null
}

// Code around a finding, from the snapshot directory or a clone at a commit.
function codeContext(set, f) {
  if (f.path == null || f.line == null) return null
  let text = null
  if (set.snapshot != null) {
    const p = path.join(set.snapshot, f.path)
    if (fs.existsSync(p)) text = fs.readFileSync(p, 'utf8')
  }
  const sha = f.commit ?? set.sha
  const dirs = [set.repoDir, `${MINING}/repos/${set.pr.repo}`, `${HOME}/git/${set.pr.repo}`].filter(Boolean)
  if (text == null && sha != null) {
    for (const dir of dirs) {
      if (!fs.existsSync(dir)) continue
      const r = spawnSync('git', ['-C', dir, 'show', `${sha}:${f.path}`], { encoding: 'utf8', maxBuffer: 64 << 20 })
      if (r.status === 0) {
        text = r.stdout
        break
      }
    }
  }
  if (text == null) return null
  const lines = text.split('\n')
  const lo = Math.max(1, (f.startLine ?? f.line) - 12)
  const hi = Math.min(lines.length, f.line + 6)
  const out = []
  for (let n = lo; n <= hi; n++) out.push(`${String(n).padStart(5)}${n === f.line ? '>' : ' '} ${lines[n - 1]}`)
  return out.join('\n').slice(0, 2500)
}

// --- human set --------------------------------------------------------------

const isHuman = (humans, login) => login != null && humans.has(String(login).toLowerCase())
const clip = (s, n) => {
  const t = String(s ?? '').replace(/<!--[\s\S]*?-->/g, '').trim()
  return t.length > n ? `${t.slice(0, n)} [...]` : t
}
const loginOf = r => r.author ?? r.login ?? r.user ?? null
const prKey = (repo, number) => `${repo}#${number}`

// One pass over the export, keeping only the PRs being scored.
function loadExportRows(file, wanted) {
  const byPr = new Map()
  const text = fs.readFileSync(file, 'utf8')
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue
    const r = JSON.parse(line)
    const key = prKey(r.repo, r.prNumber ?? r.number)
    if (!wanted.has(key)) continue
    if (!byPr.has(key)) byPr.set(key, [])
    byPr.get(key).push(r)
  }
  return byPr
}

function humanInputs(rows, humans, humanUntil) {
  const before = t => humanUntil == null || t == null || t <= humanUntil
  const inline = []
  const summaries = []
  const conversation = []
  for (const r of rows) {
    const kind = r.kind ?? 'thread'
    if (kind === 'thread') {
      const root = r.comments?.[0]
      if (root == null || !isHuman(humans, root.author) || !before(root.createdAt)) continue
      inline.push({
        id: `t${root.id ?? r.threadId}`,
        kind: 'inline',
        author: root.author,
        path: r.path,
        // The location at the commit the comment was written on, which is the
        // commit a replay snapshot is built from.
        line: r.originalLine ?? r.line,
        startLine: r.originalStartLine ?? r.startLine,
        commit: root.originalCommit ?? r.originalCommit,
        createdAt: root.createdAt,
        reviewId: root.reviewId ?? root.pullRequestReviewId ?? root.reviewDatabaseId ?? null,
        url: root.url,
        body: clip(root.body, 1500),
        hunk: String(r.diffHunk ?? '').split('\n').slice(-8).join('\n').slice(0, 800),
        replies: r.comments.slice(1).map(c => `${c.author}: ${clip(c.body, 300)}`)
      })
    } else if (kind === 'review_summary') {
      const body = clip(r.body, 2500)
      if (!isHuman(humans, loginOf(r)) || body === '' || !before(r.submittedAt)) continue
      summaries.push({
        id: `r${r.reviewId ?? r.id ?? r.databaseId}`,
        kind: 'summary',
        author: loginOf(r),
        state: r.state,
        commit: r.commit ?? r.commitId ?? r.commitOid,
        submittedAt: r.submittedAt,
        url: r.url,
        body
      })
    } else if (kind === 'conversation') {
      const body = clip(r.body, 1500)
      if (!isHuman(humans, loginOf(r)) || body === '' || !before(r.createdAt)) continue
      conversation.push({ id: `c${r.commentId ?? r.id ?? r.databaseId}`, kind: 'conversation', author: loginOf(r), createdAt: r.createdAt, url: r.url, body })
    }
  }
  // Link inline comments to the review they were submitted with: the review id
  // when the export carries it, else same author and commit, created no later
  // than the review and after that author's previous review.
  for (const s of summaries) {
    const prev = summaries
      .filter(o => o.author === s.author && o.submittedAt < s.submittedAt)
      .map(o => o.submittedAt)
      .sort()
      .pop()
    s.inlineIds = inline
      .filter(c =>
        c.reviewId != null
          ? `r${c.reviewId}` === s.id
          : c.author === s.author && c.commit === s.commit && c.createdAt <= s.submittedAt && (prev == null || c.createdAt > prev)
      )
      .map(c => c.id)
  }
  return { inline, summaries, conversation }
}

function stage1Prompt(pr, h) {
  const inl = h.inline.map(c =>
    [`[${c.id}] inline by ${c.author} on ${c.path}:${c.line} (commit ${String(c.commit).slice(0, 7)}, ${c.createdAt})`, c.body, c.replies.length ? `replies: ${c.replies.join(' | ')}` : ''].filter(Boolean).join('\n')
  )
  const sums = h.summaries.map(s =>
    [`[${s.id}] review summary by ${s.author}, state ${s.state} (commit ${String(s.commit).slice(0, 7)}, ${s.submittedAt}); inline comments in this review: ${s.inlineIds.join(', ') || 'none'}`, s.body].join('\n')
  )
  const conv = h.conversation.map(c => [`[${c.id}] conversation comment by ${c.author} (${c.createdAt})`, c.body].join('\n'))
  return `You prepare the human side of a code-review comparison for ${pr.repo} PR #${pr.number} (Edge: a crypto wallet; React Native app, TypeScript plugins, Node servers).

Below are the human reviewers' inline comments, review summaries and conversation comments on the PR.

Tasks:
1. For EACH inline comment and EACH conversation comment: is it actionable? Actionable means it asks for or points at a change to the code, tests or docs, including a question that implies a defect ("shouldn't this be X?"). Not actionable: praise, thanks, approval, status chatter, a pure request for context, or a comment the replies show was withdrawn. Give a gist of at most 15 words.
2. For EACH review summary: split it into its distinct points. Drop a point when it only restates or introduces an inline comment from the SAME review (the ids listed with the summary); that inline comment already counts it. Also drop pure verdict or praise lines ("LGTM", "looks good", "the three findings are fixed"). Keep overarching points: a concern, request or design point the review's inline comments do not already carry. For each kept point give its text (one or two sentences, in the reviewer's terms) and whether it is actionable. List the inline ids the dropped points restated.

INLINE COMMENTS
${inl.join('\n\n') || '(none)'}

REVIEW SUMMARIES
${sums.join('\n\n') || '(none)'}

CONVERSATION COMMENTS
${conv.join('\n\n') || '(none)'}

Reply with ONLY one JSON object:
{"items":[{"id":"<inline or conversation id>","actionable":true,"gist":"..."}],
 "summaries":[{"id":"<summary id>","restates":["<inline id>"],"points":[{"text":"...","actionable":true}]}]}
Every inline and conversation id appears once in "items"; every summary id appears once in "summaries" (with "points": [] when nothing is left).`
}

function stage2Prompt(set, humanItems, batch) {
  // The judge sees short ids (H1, H2, ...): GitHub comment ids on one PR often
  // differ only in their last digit, and the judge mixed them up.
  const hs = humanItems.map((h, i) => {
    const where = h.kind === 'inline' ? `inline on ${h.path}:${h.line}` : h.kind === 'summary-point' ? 'review summary point (no location)' : 'conversation comment (no location)'
    const parts = [`[H${i + 1}] ${where}${h.actionable ? '' : ' (not actionable)'}`, h.text]
    if (h.kind === 'inline' && h.hunk) parts.push(`diff at the comment:\n${h.hunk}`)
    return parts.join('\n')
  })
  const fs_ = batch.map(f => {
    const parts = [`[${f.id}] ${f.path ?? '(no file)'}:${f.line ?? '?'}${f.startLine != null && f.startLine !== f.line ? ` (from line ${f.startLine})` : ''}`, f.body]
    if (f.context) parts.push(`code at the finding (> marks the line):\n${f.context}`)
    return parts.join('\n')
  })
  return `You grade an AI code reviewer's findings against the human review of ${set.pr.repo} PR #${set.pr.number} (Edge: a crypto wallet; React Native app, TypeScript plugins, Node servers). The humans reviewed the same PR; their comments are the reference.

For EACH AI finding pick exactly one label:
- "match": it raises the same problem as one or more human comments, so a reader of the AI finding would make the change the human asked for.
  - Inline human comments need BOTH location and substance: same file, and the same code (nearby lines, or the same function or construct; line numbers can drift a few lines between commits), and the same underlying problem.
  - Summary points and conversation comments have no location: match on substance only.
  - Same file or same topic with a different problem is NOT a match. A finding that names a symptom of the human's root cause, with the same fix, IS a match.
  - Compare the outcome each asks for, not the mechanism each describes: the human comment and the finding may have been written against different commits, so a finding that the change the human asked for is still missing or incomplete IS a match.
- "valid": no human raised it, but it names a specific way this code fails or misleads, and the code shown is consistent with it. Minor issues count, including a concrete risk that a likely next change (a new enum member, a new format) breaks the code.
- "noise": the code shown contradicts it, it has no grounds in the code, it restates what the PR plainly intends, or it is too trivial to be worth a comment. When unsure between valid and noise, choose valid unless you can name what in the code makes the finding wrong.

HUMAN COMMENTS
${hs.join('\n\n') || '(none)'}

AI FINDINGS
${fs_.join('\n\n')}

Reply with ONLY a JSON array, one object per finding, in order:
[{"id":"f1","label":"match|valid|noise","humans":["H1", "..."],"reason":"<one short sentence>"}]
"humans" is empty unless the label is "match".`
}

// --- judge ------------------------------------------------------------------

const stats = { calls: 0, cached: 0, inTok: 0, outTok: 0, cost: 0, failures: [] }

function callClaude(model, text) {
  return new Promise((resolve, reject) => {
    // Isolated child: no tools, no MCP, no user hooks, none of the run's AGENT_*
    // env (a child that inherits AGENT_TASK_GID starts acting as the run).
    const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('AGENT_') && k !== 'TMUX_PANE'))
    const ch = spawn(
      'claude',
      ['-p', '--model', model, '--output-format', 'json', '--tools', '', '--strict-mcp-config', '--no-session-persistence', '--setting-sources', 'project'],
      { stdio: ['pipe', 'pipe', 'pipe'], env, cwd: CACHE }
    )
    let out = ''
    let err = ''
    const timer = setTimeout(() => {
      ch.kill('SIGKILL')
      reject(new Error('timeout'))
    }, 600000)
    ch.stdout.on('data', d => (out += d))
    ch.stderr.on('data', d => (err += d))
    ch.on('close', code => {
      clearTimeout(timer)
      if (code !== 0) return reject(new Error(`exit ${code}: ${(err || out).slice(0, 200)}`))
      try {
        const envl = JSON.parse(out)
        resolve({ result: String(envl.result ?? ''), usage: envl.usage ?? null, cost: envl.total_cost_usd ?? null })
      } catch (e) {
        reject(new Error(`bad envelope: ${out.slice(0, 200)}`))
      }
    })
    ch.stdin.end(text)
  })
}

function extractJson(result, open) {
  const close = open === '[' ? ']' : '}'
  const start = result.indexOf(open)
  const end = result.lastIndexOf(close)
  if (start < 0 || end < start) throw new Error(`no JSON ${open}${close} in result`)
  return JSON.parse(result.slice(start, end + 1))
}

// Cached judge call: sha of model + prompt version + prompt. Failures are never
// cached; one retry, then the caller sees the error.
async function judge(opts, prompt, open, validate) {
  const key = crypto.createHash('sha256').update(`${PROMPT_VERSION}\n${opts.model}\n${opts.sample ?? 1}\n${prompt}`).digest('hex').slice(0, 20)
  const file = `${CACHE}/${key}.json`
  if (fs.existsSync(file)) {
    stats.cached++
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  }
  if (opts.dryRun) {
    const dir = opts.out ?? CACHE
    fs.mkdirSync(dir, { recursive: true })
    fs.writeFileSync(`${dir}/prompt-${key}.txt`, prompt)
    stats.failures.push(`dry run: ${prompt.length} chars not sent, wrote ${dir}/prompt-${key}.txt`)
    return null
  }
  let lastErr
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const { result, usage, cost } = await callClaude(opts.model, prompt)
      const parsed = extractJson(result, open)
      validate(parsed)
      fs.writeFileSync(file, JSON.stringify(parsed))
      stats.calls++
      if (usage != null) {
        stats.inTok += (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0)
        stats.outTok += usage.output_tokens ?? 0
      }
      if (cost != null) stats.cost += cost
      return parsed
    } catch (e) {
      lastErr = e
      stats.failures.push(`attempt ${attempt}: ${e.message}`)
    }
  }
  throw lastErr
}

async function buildHumanSet(opts, pr, h) {
  const all = [...h.inline, ...h.conversation]
  if (all.length === 0 && h.summaries.length === 0) return []
  const verdict = await judge(opts, stage1Prompt(pr, h), '{', v => {
    const ids = new Set((v.items ?? []).map(i => i.id))
    const missing = all.filter(c => !ids.has(c.id)).map(c => c.id)
    if (missing.length > 0) throw new Error(`stage 1 missed items ${missing.join(',')}`)
    const sids = new Set((v.summaries ?? []).map(s => s.id))
    const smissing = h.summaries.filter(s => !sids.has(s.id)).map(s => s.id)
    if (smissing.length > 0) throw new Error(`stage 1 missed summaries ${smissing.join(',')}`)
  })
  if (verdict == null) return null
  const byId = new Map(verdict.items.map(i => [i.id, i]))
  const items = all.map(c => ({
    id: c.id,
    kind: c.kind,
    author: c.author,
    path: c.path ?? null,
    line: c.line ?? null,
    hunk: c.hunk ?? null,
    url: c.url ?? null,
    createdAt: c.createdAt,
    text: c.body,
    gist: byId.get(c.id).gist ?? '',
    actionable: byId.get(c.id).actionable === true
  }))
  for (const s of h.summaries) {
    const v = verdict.summaries.find(o => o.id === s.id)
    ;(v.points ?? []).forEach((p, i) =>
      items.push({
        id: `${s.id}.p${i + 1}`,
        kind: 'summary-point',
        author: s.author,
        url: s.url ?? null,
        createdAt: s.submittedAt,
        text: p.text,
        gist: p.text,
        actionable: p.actionable === true,
        restatesDropped: v.restates ?? []
      })
    )
  }
  return items
}

async function labelFindings(opts, set, humanItems) {
  for (const f of set.findings) f.context = codeContext(set, f)
  const shortIds = new Map(humanItems.map((h, i) => [`H${i + 1}`, h.id]))
  const labels = []
  for (let i = 0; i < set.findings.length; i += FINDING_BATCH) {
    const batch = set.findings.slice(i, i + FINDING_BATCH)
    const v = await judge(opts, stage2Prompt(set, humanItems, batch), '[', arr => {
      if (!Array.isArray(arr) || arr.length !== batch.length) throw new Error(`expected ${batch.length} labels, got ${arr?.length}`)
      arr.forEach((o, j) => {
        if (o.id !== batch[j].id) throw new Error(`label ${j} is for ${o.id}, expected ${batch[j].id}`)
        if (!['match', 'valid', 'noise'].includes(o.label)) throw new Error(`bad label ${o.label}`)
      })
    })
    if (v == null) return null
    for (const o of v) {
      const humansMatched = (o.humans ?? []).map(id => shortIds.get(String(id).toUpperCase())).filter(id => id != null)
      // A match that names no known human id is treated as valid-unmatched.
      labels.push({ id: o.id, label: o.label === 'match' && humansMatched.length === 0 ? 'valid' : o.label, humans: o.label === 'match' ? humansMatched : [], reason: o.reason ?? '' })
    }
  }
  return labels
}

// --- metrics and output -----------------------------------------------------

function ratio(a, b) {
  return b === 0 ? null : Math.round((a / b) * 1000) / 1000
}

function metrics(c) {
  return {
    ...c,
    recall: ratio(c.caught, c.actionable),
    precision: ratio(c.matched, c.findings),
    signalToNoise: c.noise === 0 ? (c.matched + c.valid > 0 ? 'inf' : null) : ratio(c.matched + c.valid, c.noise)
  }
}

function emptyCounts() {
  return { prs: 0, humanItems: 0, actionable: 0, caught: 0, caughtAll: 0, findings: 0, matched: 0, valid: 0, noise: 0 }
}

function addCounts(a, b) {
  for (const k of Object.keys(a)) a[k] += b[k] ?? 0
}

function fmt(v) {
  if (v == null) return 'n/a'
  if (typeof v === 'number' && v <= 1 && !Number.isInteger(v)) return `${Math.round(v * 100)}%`
  return String(v)
}

function renderReport(results, aggregates, run) {
  const out = ['# Replay comparator results', '', `Export: ${run.export}. Judge: ${run.model}, prompt ${PROMPT_VERSION}. Judge calls: ${run.stats.calls} new, ${run.stats.cached} cached.`, '']
  out.push('## Aggregate by label', '', '| Label | PRs | Actionable human | Caught | Recall | Findings | Match | Valid | Noise | Precision | Signal:noise |', '|---|---|---|---|---|---|---|---|---|---|---|')
  for (const [label, a] of Object.entries(aggregates)) {
    const m = a.totals
    out.push(`| ${label} | ${m.prs} | ${m.actionable} | ${m.caught} | ${fmt(m.recall)} | ${m.findings} | ${m.matched} | ${m.valid} | ${m.noise} | ${fmt(m.precision)} | ${m.signalToNoise === 'inf' ? 'inf' : m.signalToNoise ?? 'n/a'} |`)
  }
  for (const [label, a] of Object.entries(aggregates)) {
    out.push('', `### Findings by tag (${label})`, '', '| Tag | Findings | Match | Valid | Noise |', '|---|---|---|---|---|')
    for (const [tag, c] of Object.entries(a.byTag).sort((x, y) => y[1].findings - x[1].findings)) out.push(`| ${tag} | ${c.findings} | ${c.match} | ${c.valid} | ${c.noise} |`)
  }
  for (const r of results) {
    const m = r.metrics
    out.push('', `## ${r.pr.repo}#${r.pr.number} (${r.label})`, '', `Findings file: ${r.file}`, '', `Recall ${fmt(m.recall)} (${m.caught}/${m.actionable} actionable), precision ${fmt(m.precision)} (${m.matched}/${m.findings}), signal:noise ${m.signalToNoise ?? 'n/a'}.`, '')
    out.push('| Finding | Where | Tag | Label | Matches | Reason |', '|---|---|---|---|---|---|')
    for (const f of r.findings) out.push(`| ${f.id} | ${f.path ?? ''}:${f.line ?? ''} | ${f.tag} | ${f.label} | ${f.humans.join(', ')} | ${String(f.reason).replace(/\|/g, '/')} |`)
    out.push('', '| Human item | Kind | Where | Actionable | Caught by | Gist |', '|---|---|---|---|---|---|')
    for (const h of r.humans) out.push(`| ${h.id} | ${h.kind} | ${h.path ? `${h.path}:${h.line}` : ''} | ${h.actionable ? 'yes' : 'no'} | ${h.caughtBy.join(', ')} | ${String(h.gist).replace(/\|/g, '/')} |`)
  }
  return out.join('\n') + '\n'
}

async function main() {
  const opts = parseArgs(process.argv.slice(2))
  fs.mkdirSync(CACHE, { recursive: true })
  const exportFile = opts.export ?? defaultExport()
  const humans = loadHumans(opts.accounts ?? `${MINING}/accounts.json`)
  const sets = findingFiles(opts.findings).map(f => loadFindings(f, opts))
  const heldOut = sets.filter(s => s.pr.number % 3 === 2)
  if (heldOut.length > 0 && opts.allowHeldOut !== true) {
    die(`held-out PRs (number mod 3 == 2) need --allow-held-out: ${heldOut.map(s => prKey(s.pr.repo, s.pr.number)).join(', ')}`)
  }
  const wanted = new Set(sets.map(s => prKey(s.pr.repo, s.pr.number)))
  const rowsByPr = loadExportRows(exportFile, wanted)
  for (const k of wanted) if (!rowsByPr.has(k)) process.stderr.write(`replay-compare: ${k} has no rows in ${exportFile}; scoring against an empty human set\n`)

  // Stage 1 once per PR, shared by every findings file for that PR.
  const humanSets = new Map()
  const prs = [...wanted]
  let nextPr = 0
  await Promise.all(
    Array.from({ length: opts.parallel }, async () => {
      while (nextPr < prs.length) {
        const key = prs[nextPr++]
        const pr = parsePrRef(key)
        const h = humanInputs(rowsByPr.get(key) ?? [], humans, opts.humanUntil)
        humanSets.set(key, await buildHumanSet(opts, pr, h))
      }
    })
  )

  const results = []
  let nextSet = 0
  await Promise.all(
    Array.from({ length: opts.parallel }, async () => {
      while (nextSet < sets.length) {
        const set = sets[nextSet++]
        const humanItems = humanSets.get(prKey(set.pr.repo, set.pr.number))
        if (humanItems == null) continue
        const labels = set.findings.length > 0 ? await labelFindings(opts, set, humanItems) : []
        if (labels == null) continue
        const findings = set.findings.map((f, i) => ({ id: f.id, path: f.path, line: f.line, tag: f.tag, body: f.body, sourceUrl: f.sourceUrl, ...labels[i] }))
        const humansOut = humanItems.map(h => ({ ...h, caughtBy: findings.filter(f => f.humans.includes(h.id)).map(f => f.id) }))
        const counts = {
          prs: 1,
          humanItems: humansOut.length,
          actionable: humansOut.filter(h => h.actionable).length,
          caught: humansOut.filter(h => h.actionable && h.caughtBy.length > 0).length,
          caughtAll: humansOut.filter(h => h.caughtBy.length > 0).length,
          findings: findings.length,
          matched: findings.filter(f => f.label === 'match').length,
          valid: findings.filter(f => f.label === 'valid').length,
          noise: findings.filter(f => f.label === 'noise').length
        }
        results.push({ pr: set.pr, label: set.label, file: set.file, metrics: metrics(counts), findings, humans: humansOut })
      }
    })
  )
  results.sort((a, b) => a.label.localeCompare(b.label) || prKey(a.pr.repo, a.pr.number).localeCompare(prKey(b.pr.repo, b.pr.number)))

  const aggregates = {}
  for (const r of results) {
    const a = (aggregates[r.label] ??= { counts: emptyCounts(), byTag: {} })
    addCounts(a.counts, r.metrics)
    for (const f of r.findings) {
      const t = (a.byTag[f.tag] ??= { findings: 0, match: 0, valid: 0, noise: 0 })
      t.findings++
      t[f.label]++
    }
  }
  for (const a of Object.values(aggregates)) a.totals = metrics(a.counts)

  const run = { export: exportFile, model: opts.model, promptVersion: PROMPT_VERSION, humanUntil: opts.humanUntil ?? null, stats }
  const outDir = opts.out ?? `${HOME}/.config/pr-review/replay-compare/runs/${new Date().toISOString().replace(/[:.]/g, '-')}`
  fs.mkdirSync(outDir, { recursive: true })
  fs.writeFileSync(`${outDir}/results.json`, JSON.stringify({ run, aggregates, results }, null, 1))
  fs.writeFileSync(`${outDir}/report.md`, renderReport(results, aggregates, run))

  for (const [label, a] of Object.entries(aggregates)) {
    const m = a.totals
    console.log(`${label}: ${m.prs} PRs, recall ${fmt(m.recall)} (${m.caught}/${m.actionable}), precision ${fmt(m.precision)} (${m.matched}/${m.findings}), valid ${m.valid}, noise ${m.noise}, signal:noise ${m.signalToNoise ?? 'n/a'}`)
  }
  console.log(`judge: ${stats.calls} calls, ${stats.cached} cached, ${stats.inTok} in / ${stats.outTok} out tokens, failures ${stats.failures.length}`)
  for (const f of stats.failures) console.log(`  ${f}`)
  console.log(`wrote ${outDir}/results.json and report.md`)
  if (results.length < sets.length) process.exit(1)
}

if (require.main === module) {
  main().catch(e => {
    process.stderr.write(`replay-compare: ${e.stack ?? e.message}\n`)
    process.exit(1)
  })
}

module.exports = { loadFindings, codeContext, humanInputs, metrics }
