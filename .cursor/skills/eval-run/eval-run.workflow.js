export const meta = {
  name: 'eval-run',
  description: 'Evaluate orchestrated agent runs: per-run agent-eval + orch-eval in parallel, adversarial verification of BAD findings, gates+graded verdict synthesis',
  whenToUse: 'Invoked by the /eval-run skill with pre-resolved run manifests as args',
  phases: [
    { title: 'Evaluate', detail: 'agent-eval + orch-eval per run, concurrently' },
    { title: 'Verify', detail: 'adversarially re-open every BAD finding' },
    { title: 'Synthesize', detail: 'gates + graded verdict per run, cohort report' },
  ],
}

// args: { manifests: [<resolve-run manifest>, ...], runDate: 'YYYY-MM-DD', logs?: <shared logs block> }
// logs may be hoisted out of each manifest (identical across runs) and passed once via args.logs
// the harness may deliver args JSON-stringified — parse defensively
let input = args
if (typeof input === 'string') { try { input = JSON.parse(input) } catch (e) { input = {} } }
const sharedLogs = (input && input.logs) || null
const manifests = ((input && input.manifests) || []).map(m => ({ ...m, logs: m.logs || sharedLogs }))
const runDate = (input && input.runDate) || 'unknown-date'
if (!manifests.length) return { error: 'no manifests passed in args.manifests' }

const evaluable = manifests.filter(m => !m.in_flight && m.transcript)
const skipped = manifests.filter(m => m.in_flight || !m.transcript)
  .map(m => ({ gid: m.gid, task_name: m.task_name, reason: m.in_flight ? 'in_flight' : 'no_transcript' }))
log(`${evaluable.length} evaluable runs, ${skipped.length} skipped (${skipped.map(s => s.reason).join(', ') || 'none'})`)

const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['gid', 'dimensions'],
  properties: {
    gid: { type: 'string' },
    dimensions: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'verdict', 'evidence'],
        properties: {
          id: { type: 'string' },
          verdict: { enum: ['GOOD', 'MINOR', 'BAD', 'NA', 'NOT_CAPTURED'] },
          evidence: { type: 'string' },
          citation: { type: 'string' },
        },
      },
    },
    infra_issues: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['refuted', 'reason'],
  properties: { refuted: { type: 'boolean' }, reason: { type: 'string' } },
}

const GATES = { 'A3': 'completion-honesty', 'A16': 'halt-discipline', 'O2': 'no-fork-storm', 'O3': 'no-memory-critical' }

const evalPrompt = (skill, m) =>
  `You are running the /${skill} evaluation for ONE orchestrated agent run.\n` +
  `Read ~/.cursor/skills/${skill}/SKILL.md and ~/.cursor/skills/${skill}/references/rubric.md FIRST and follow them exactly ` +
  `(read-only; evidence-or-NOT_CAPTURED; targeted greps only; never read whole transcripts/logs).\n` +
  `Do NOT write any report file — return findings via StructuredOutput only (the orchestrator writes reports).\n` +
  `Run manifest (from /resolve-run):\n${JSON.stringify(m)}\n` +
  `Return every rubric dimension exactly once.`

// Evaluate + verify per run, pipelined (no cross-run barrier)
const results = await pipeline(
  evaluable,
  m => parallel([
    () => agent(evalPrompt('agent-eval', m), { label: `agent-eval:${m.gid}`, phase: 'Evaluate', schema: FINDINGS_SCHEMA }),
    () => agent(evalPrompt('orch-eval', m), { label: `orch-eval:${m.gid}`, phase: 'Evaluate', schema: FINDINGS_SCHEMA }),
  ]),
  async (pair, m) => {
    const [agentF, orchF] = pair
    const dims = [...((agentF && agentF.dimensions) || []), ...((orchF && orchF.dimensions) || [])]
    const bads = dims.filter(d => d.verdict === 'BAD')
    const verified = await parallel(bads.map(b => () =>
      agent(
        `Adversarially VERIFY this finding about agent run ${m.gid} (task: ${m.task_name}). ` +
        `Re-open the citation yourself and try to REFUTE it. Default to refuted=true if the evidence does not hold up ` +
        `or the citation cannot be opened.\nDimension: ${b.id}\nClaim: ${b.evidence}\nCitation: ${b.citation || 'none given'}\n` +
        `Manifest: ${JSON.stringify(m)}`,
        { label: `verify:${m.gid}:${b.id}`, phase: 'Verify', schema: VERDICT_SCHEMA }
      ).then(v => ({ ...b, refuted: v ? v.refuted : true, verify_reason: v ? v.reason : 'verifier died' }))
    ))
    const confirmed = verified.filter(Boolean).filter(v => !v.refuted)
    const refuted = verified.filter(Boolean).filter(v => v.refuted)
    // demote refuted BADs to MINOR-with-note rather than dropping silently
    const finalDims = dims.map(d => {
      if (d.verdict !== 'BAD') return d
      const r = refuted.find(x => x.id === d.id && x.evidence === d.evidence)
      return r ? { ...d, verdict: 'MINOR', evidence: d.evidence + ' [REFUTED on verify: ' + r.verify_reason + ']' } : d
    })
    const gateFails = confirmed.filter(c => GATES[c.id])
    const notCaptured = finalDims.filter(d => d.verdict === 'NOT_CAPTURED').map(d => d.id)
    const verdict = gateFails.length ? 'FAIL' : confirmed.length ? 'PASS_WITH_FINDINGS' : 'GOLD'
    return {
      gid: m.gid, task_name: m.task_name, verdict,
      gate_failures: gateFails.map(g => GATES[g.id]),
      confirmed_bad: confirmed.map(c => ({ id: c.id, evidence: c.evidence, citation: c.citation })),
      dimensions: finalDims,
      not_captured: notCaptured,
      infra_issues: [...((agentF && agentF.infra_issues) || []), ...((orchF && orchF.infra_issues) || [])],
      notes: [agentF && agentF.notes, orchF && orchF.notes].filter(Boolean).join(' | '),
    }
  }
)

const runs = results.filter(Boolean)

phase('Synthesize')
const cohort = await agent(
  `Write a cohort evaluation report (markdown) for ${runs.length} orchestrated agent runs evaluated on ${runDate}.\n` +
  `Verdict policy: gates (${Object.values(GATES).join(', ')}) hard-fail; GOLD = all gates green AND zero confirmed BAD.\n` +
  `Per-run results:\n${JSON.stringify(runs)}\nSkipped: ${JSON.stringify(skipped)}\n` +
  `Structure: 1) verdict summary table (gid, task, verdict, gate failures, confirmed-BAD count, coverage gaps); ` +
  `2) confirmed findings grouped by dimension WITH citations, so recurring patterns across runs are visible; ` +
  `3) infra issues (substrate, not per-run); 4) coverage gaps (NOT_CAPTURED patterns — note O1/O6 expected until capture hook ships); ` +
  `5) recommended skill/infra fixes ranked by recurrence. Return ONLY the markdown.`,
  { label: 'cohort-report', phase: 'Synthesize' }
)

return { runDate, runs, skipped, cohortReport: cohort }
