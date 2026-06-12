// local-research.workflow.js — deep research over the LOCAL filesystem/codebase.
//
// The local-research counterpart to the built-in web `deep-research`: instead of
// WebSearch/WebFetch over the internet, it scopes a question into research angles,
// fans out reader agents that Read/Grep/Glob the assigned local scope, adversarially
// verifies each cited claim by RE-OPENING the cited file:line, then synthesizes a
// cited report. Citations are `path:line`, which render as clickable references.
//
// Invoke via the /local-research skill, or directly:
//   Workflow({ scriptPath: "~/.cursor/skills/local-research/local-research.workflow.js",
//              args: { question: "...", roots: ["~/x"], breadth: "thorough", style: "rubric" } })
//
// args (string OR object):
//   string                 → treated as { question: <string> }, roots default to ["."]
//   question  (required)   → the research question
//   roots     (string[])   → directories/files to scope the search to (default ["."])
//   angles    (number)     → number of research angles (default 5 medium / 7 thorough)
//   breadth   ("medium"|"thorough") → thorough = more angles + 3-vote adversarial verify
//   style     ("report"|"rubric"|"map") → shape of the synthesized output (default report)
//   hint      (string)     → optional extra guidance woven into scoping (key files, gotchas)

export const meta = {
  name: 'local-research',
  description: 'Deep research over the LOCAL filesystem/codebase: scope into angles, fan out reader agents, adversarially verify cited claims, synthesize a cited report',
  phases: [
    { title: 'Scope', detail: 'decompose the question into research angles + file scopes' },
    { title: 'Investigate', detail: 'one reader agent per angle, extract file:line-cited findings' },
    { title: 'Verify', detail: 'adversarial re-read, re-open each citation, drop unsupported claims' },
    { title: 'Synthesize', detail: 'dedup across angles, organize, emit a cited report' },
  ],
}

// ── args ───────────────────────────────────────────────────────────────────────
// The harness may deliver `args` JSON-stringified. Parse it first: a string that
// parses to an object IS the args object (not a question); a string that doesn't
// parse is a bare question. (Without this, a stringified {question,roots,…} put the
// whole JSON blob in .question and silently fell back to default roots/breadth.)
let A = args
if (typeof A === 'string') {
  try { const p = JSON.parse(A); A = (p && typeof p === 'object') ? p : { question: A } }
  catch (e) { A = { question: A } }
}
A = A || {}
const QUESTION = (A.question || '').trim()
if (!QUESTION) throw new Error('local-research: args.question is required (pass a string, or { question, roots, breadth, style })')
const ROOTS = (Array.isArray(A.roots) && A.roots.length) ? A.roots : ['.']
const BREADTH = A.breadth === 'thorough' ? 'thorough' : 'medium'
const NUM_ANGLES = Number.isFinite(A.angles) ? A.angles : (BREADTH === 'thorough' ? 7 : 5)
const VOTES = BREADTH === 'thorough' ? 3 : 1
const STYLE = ['report', 'rubric', 'map'].includes(A.style) ? A.style : 'report'
const HINT = (A.hint || '').trim()
const ROOTS_STR = ROOTS.join(', ')

// ── schemas ──────────────────────────────────────────────────────────────────────
const SCOPE_SCHEMA = {
  type: 'object',
  required: ['angles'],
  properties: {
    angles: {
      type: 'array',
      items: {
        type: 'object',
        required: ['key', 'sub_question', 'scope', 'extract'],
        properties: {
          key: { type: 'string', description: 'short-kebab id for this angle' },
          sub_question: { type: 'string', description: 'the specific question this angle answers' },
          scope: { type: 'string', description: 'concrete files/dirs/globs to read for this angle' },
          extract: { type: 'string', description: 'what kind of findings to pull out' },
        },
      },
    },
  },
}

const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'claim', 'citation', 'detail'],
        properties: {
          id: { type: 'string', description: 'short-kebab slug, unique within the angle' },
          claim: { type: 'string', description: 'a single falsifiable statement grounded in the source' },
          citation: { type: 'string', description: 'path:line (or path:rule-id) the claim is grounded in' },
          detail: { type: 'string', description: 'supporting specifics / context' },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'claim', 'citation', 'detail', 'verdict'],
        properties: {
          id: { type: 'string' },
          claim: { type: 'string' },
          citation: { type: 'string' },
          detail: { type: 'string' },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
          verdict: { type: 'string', enum: ['confirmed', 'corrected', 'dropped'], description: 'confirmed=citation opened and supports claim; corrected=reworded/recited to match source; dropped=citation missing/does not support/hallucinated/duplicate' },
          verify_note: { type: 'string' },
        },
      },
    },
  },
}

// ── helpers ──────────────────────────────────────────────────────────────────────
// Merge N adversarial verifier votes for one angle. A finding survives if a MAJORITY
// of votes did not drop it; the surviving text is taken from a confirming/correcting vote.
function mergeVotes(votes) {
  const need = Math.floor(votes.length / 2) + 1
  const byId = new Map()
  for (const v of votes.filter(Boolean)) {
    for (const f of (v.findings || [])) {
      if (!byId.has(f.id)) byId.set(f.id, [])
      byId.get(f.id).push(f)
    }
  }
  const survivors = []
  for (const [, copies] of byId) {
    const kept = copies.filter((c) => c.verdict !== 'dropped')
    if (kept.length >= need) {
      // prefer a 'corrected' copy (it fixed something), else the first confirmed
      const pick = kept.find((c) => c.verdict === 'corrected') || kept[0]
      survivors.push(pick)
    }
  }
  return survivors
}

const SCOPE_NOTE = `Search scope (roots): ${ROOTS_STR}. Stay WITHIN these roots. Use absolute paths in citations where possible.`

// ── Scope ────────────────────────────────────────────────────────────────────────
phase('Scope')
log(`local-research: "${QUESTION.slice(0, 80)}" over [${ROOTS_STR}] — ${NUM_ANGLES} angles, ${BREADTH} (${VOTES}-vote verify), style=${STYLE}`)

const scope = await agent(
  `You are scoping a LOCAL research task (filesystem/codebase, NOT the web).\n\nQUESTION: ${QUESTION}\n\n${SCOPE_NOTE}\n` +
  (HINT ? `\nHINT from the requester: ${HINT}\n` : '') +
  `\nFirst EXPLORE the roots shallowly to understand the structure (ls / glob / grep for key terms / read a couple of index or entrypoint files). Do NOT do the deep reading yet. ` +
  `Then decompose the question into ${NUM_ANGLES} NON-OVERLAPPING research angles that together fully cover it. For each angle give: a 'key' (kebab id), a 'sub_question', a concrete 'scope' (the specific files/dirs/globs a reader should open for it, drawn from what you actually saw), and 'extract' (what kind of findings to pull). Partition the material so angles do not redundantly read the same files. Return exactly the angles.`,
  { schema: SCOPE_SCHEMA, label: 'scope', phase: 'Scope' }
)
const angles = (scope.angles || []).slice(0, NUM_ANGLES)
log(`Scoped into ${angles.length} angles: ${angles.map((a) => a.key).join(', ')}`)

// ── Investigate → Verify (pipelined per angle) ────────────────────────────────────
phase('Investigate')
const perAngle = await pipeline(
  angles,
  // Stage 1: read the angle's scope, extract cited findings
  (ang) => agent(
    `LOCAL research, angle "${ang.key}". ${SCOPE_NOTE}\n\nSUB-QUESTION: ${ang.sub_question}\nREAD (open these, use Read/Grep/Glob): ${ang.scope}\nEXTRACT: ${ang.extract}\n\n` +
    `Pull a comprehensive set of FALSIFIABLE findings, each grounded in the source with a precise 'citation' (path:line, or path:rule-id for skills/rules). Every claim MUST be something a skeptic could check by opening that citation. Do not infer beyond the source; do not invent citations. ${BREADTH === 'thorough' ? 'Be exhaustive.' : 'Favor the load-bearing findings.'}`,
    { schema: FINDINGS_SCHEMA, label: `read:${ang.key}`, phase: 'Investigate' }
  ),
  // Stage 2: adversarial verification — re-open citations, refute the unsupported
  async (found, ang) => {
    const claims = JSON.stringify(found.findings, null, 1)
    const votePrompt =
      `Adversarial verification for LOCAL research angle "${ang.key}". ${SCOPE_NOTE}\n\nCandidate findings:\n${claims}\n\n` +
      `For EACH finding you MUST actually OPEN its 'citation' (Read the file at that path/line, or Grep for the rule-id) and judge against what is really there. Default to skepticism. Set 'verdict':\n` +
      `- 'confirmed' — opened the citation; it clearly supports the claim as stated.\n` +
      `- 'corrected' — the gist is real but the claim/citation/detail is off; REWRITE to match the source exactly (note the fix in verify_note).\n` +
      `- 'dropped' — citation is missing/wrong, does not support the claim, is hallucinated, or duplicates another finding (say which in verify_note).\n` +
      `Return the full list with verdicts (keep dropped ones tagged).`
    const votes = await parallel(
      Array.from({ length: VOTES }, (_, i) =>
        () => agent(votePrompt + `\n(Independent reviewer ${i + 1}; do your own reading.)`,
          { schema: VERDICT_SCHEMA, label: `verify:${ang.key}#${i + 1}`, phase: 'Verify' })
      )
    )
    return { key: ang.key, survivors: mergeVotes(votes) }
  }
)

const surviving = perAngle.filter(Boolean).flatMap((r) =>
  (r.survivors || []).map((f) => ({ ...f, angle: r.key }))
)
log(`Verified: ${surviving.length} findings survived ${VOTES}-vote adversarial check across ${perAngle.filter(Boolean).length} angles.`)

if (!surviving.length) {
  return { report: `# ${QUESTION}\n\nNo findings survived verification. The scope (${ROOTS_STR}) may not contain the answer, or the question needs refining.`, surviving: [], angles: angles.map((a) => a.key) }
}

// ── Synthesize ─────────────────────────────────────────────────────────────────────
phase('Synthesize')
const styleGuide = STYLE === 'rubric'
  ? `Organize as an EVALUATION RUBRIC: group findings into logical sections; within each, a markdown TABLE with columns Criterion | Severity | Pass signal | Source. Add a short "How to use" preamble.`
  : STYLE === 'map'
    ? `Organize as a STRUCTURE MAP: a hierarchical outline of the subject with each node annotated by its source citation; group by component/module.`
    : `Organize as a RESEARCH REPORT: a 3-5 line executive summary, then thematic sections with prose + bullets, each claim carrying its inline citation.`

const report = await agent(
  `Synthesize the final answer to a LOCAL research question from these source-verified findings.\n\nQUESTION: ${QUESTION}\n\n` +
  `FINDINGS (verified, with citations):\n${JSON.stringify(surviving, null, 1)}\n\n` +
  `${styleGuide}\n\nRequirements: (1) MERGE semantic duplicates across angles into one entry, noting multiple sources. (2) Preserve every surviving finding's citation as \`path:line\` so it stays clickable. (3) Order by importance/confidence within each section. (4) Note open questions or gaps the findings revealed. (5) Be dense and faithful to the sources; do NOT introduce claims not present in the findings. (6) Avoid em-dashes in the body (output may be committed); use commas, colons, or parentheses. Return ONLY the markdown.`,
  { label: 'synthesize', phase: 'Synthesize' }
)

return {
  report,
  question: QUESTION,
  roots: ROOTS,
  breadth: BREADTH,
  style: STYLE,
  angles: angles.map((a) => ({ key: a.key, sub_question: a.sub_question })),
  survivingCount: surviving.length,
}
