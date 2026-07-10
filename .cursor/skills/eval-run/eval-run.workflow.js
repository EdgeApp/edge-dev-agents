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
// optional model override for all evaluator/verifier/synthesis agents (e.g. 'opus');
// omitted → agents inherit the session model
const MODEL = ['sonnet', 'opus', 'haiku', 'fable'].includes(input && input.model) ? input.model : undefined
const MOPT = MODEL ? { model: MODEL } : {}
if (!manifests.length) return { error: 'no manifests passed in args.manifests' }
// optional: per-manifest m.cohort (label) and m.eval_notes (free-text instructions appended to eval prompts)
const cohortSplitDate = (input && input.cohortSplitDate) || null
const cohortInstructions = (input && input.cohortInstructions) || null

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
        required: ['id', 'name', 'verdict', 'evidence'],
        properties: {
          id: { type: 'string' },
          name: { type: 'string', description: 'the dimension name from the rubric, e.g. review-response for A14 — never emit a bare code' },
          verdict: { enum: ['GOOD', 'MINOR', 'BAD', 'NA', 'NOT_CAPTURED'] },
          evidence: { type: 'string' },
          citation: { type: 'string' },
        },
      },
    },
    infra_issues: { type: 'array', items: { type: 'string' } },
    playbook_proposals: { type: 'array', items: { type: 'string' } },
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
  (m.__fetch_full
    ? `This run was passed to you as a THIN reference (gid + cohort context only) to keep orchestration payload small. ` +
      `Your FIRST step: run \`~/.cursor/skills/resolve-run/scripts/resolve-run.sh --gid ${m.gid}\` (timeout 90000ms+) to get the FULL manifest ` +
      `JSON (transcript path, window, friction block, probe_index, auto_na, followup, blocking, etc.) for this gid. Use that as ` +
      `"the manifest" for the rest of this evaluation. Thin reference passed by the orchestrator: ${JSON.stringify(m)}\n`
    : `Run manifest (from /resolve-run):\n${JSON.stringify(m)}\n`) +
  `The manifest carries probe_index (pre-computed transcript probe hits: counts + sample line numbers, plus the update-status ladder) ` +
  `and auto_na (manifest-derived NA determinations). START from them: verify at the indexed lines instead of re-deriving discovery greps ` +
  `(counts are advisory — quoted skill bodies inflate them), and accept each auto_na entry unless evidence contradicts it.\n` +
  `Return every rubric dimension exactly once, each with BOTH its id and its rubric name (e.g. A14 + review-response).` +
  (m.eval_notes ? `\nRUN-SPECIFIC NOTES (read carefully, these override defaults for this run only): ${m.eval_notes}` : '')

// Evaluate + verify per run, pipelined (no cross-run barrier)
const results = await pipeline(
  evaluable,
  m => parallel([
    () => agent(evalPrompt('agent-eval', m), { label: `agent-eval:${m.gid}`, phase: 'Evaluate', schema: FINDINGS_SCHEMA, ...MOPT }),
    () => agent(evalPrompt('orch-eval', m), { label: `orch-eval:${m.gid}`, phase: 'Evaluate', schema: FINDINGS_SCHEMA, ...MOPT }),
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
        (m.__fetch_full
          ? `Manifest was passed thin; if the citation alone is insufficient, run \`~/.cursor/skills/resolve-run/scripts/resolve-run.sh --gid ${m.gid}\` ` +
            `(timeout 90000ms+) for the full manifest. Thin reference: ${JSON.stringify(m)}`
          : `Manifest: ${JSON.stringify(m)}`),
        { label: `verify:${m.gid}:${b.id}`, phase: 'Verify', schema: VERDICT_SCHEMA, effort: 'low', ...MOPT }
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
      gid: m.gid, task_name: m.task_name, cohort: m.cohort || null, window_end: (m.window && m.window.end) || null, verdict,
      gate_failures: gateFails.map(g => GATES[g.id]),
      confirmed_bad: confirmed.map(c => ({ id: c.id, evidence: c.evidence, citation: c.citation })),
      dimensions: finalDims,
      not_captured: notCaptured,
      infra_issues: [...((agentF && agentF.infra_issues) || []), ...((orchF && orchF.infra_issues) || [])],
      playbook_proposals: [...((agentF && agentF.playbook_proposals) || []), ...((orchF && orchF.playbook_proposals) || [])],
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
  (cohortSplitDate ? `COHORT SPLIT (hard requirement): each run carries a "cohort" label and "window_end". Split EVERY friction statistic ` +
    `(process-friction A29 findings, hook_blocks/tool_errors/build_invocations counts from manifests, and any other friction metric) ` +
    `into two groups by window_end relative to ${cohortSplitDate}: PRIOR (window_end < ${cohortSplitDate}) vs POST-FIX (window_end >= ${cohortSplitDate}). ` +
    `Present this as an explicit comparison table or subsection so the pre/post trend is visible, not buried in per-run rows.\n` : '') +
  (cohortInstructions ? `ADDITIONAL CONTEXT: ${cohortInstructions}\n` : '') +
  `DIMENSION RENDERING (hard rule): never write a bare dimension code anywhere in the report. Every mention is id + name ` +
  `(e.g. "A14 review-response", "O6 resource-release"), and the FIRST mention of each dimension in the findings section adds a ` +
  `one-line plain-language gloss of what it checks (take it from the finding's evidence context). A reader who has never seen ` +
  `the rubric must be able to follow the report.\n` +
  `Structure: 1) verdict summary table (gid, task, verdict, gate failures, confirmed-BAD count, coverage gaps); ` +
  `2) confirmed findings grouped by dimension WITH citations, so recurring patterns across runs are visible; ` +
  `3) infra issues (substrate, not per-run); 4) coverage gaps (NOT_CAPTURED patterns — note O1/O6 expected until capture hook ships); ` +
  `5) recommended skill/infra fixes ranked by recurrence; ` +
  `6) "## Actions" — EVERY finding that admits a concrete remediation, as a checklist of typed, ready-to-execute DRAFTS the operator can approve row-by-row (the eval itself mutates nothing). Types and required content: ` +
  `[field-correction] the exact \`~/.config/agent-watcher/set-tested.sh <gid> "<Option>" ...\` command with the evidence line justifying it; ` +
  `[re-run] the task gid + the specific DoD gap and terminal bar for its followup comment (the operator stamps it from eval-run references/followup-comment-template.md) + \`~/.config/agent-watcher/update-status.sh <gid> Pending\`; ` +
  `[playbook-proposal] each collected playbook_proposals bullet verbatim with its source run, ready for operator promotion to the sim-testing playbook; ` +
  `[skill-gap] the target skill/rule and one-line fix for /author; [infra-fix] the component and change. ` +
  `Derive actions ONLY from findings present above (no inventions); omit types with no instances. Return ONLY the markdown.`,
  { label: 'cohort-report', phase: 'Synthesize', ...MOPT }
)

return { runDate, runs, skipped, cohortReport: cohort }
