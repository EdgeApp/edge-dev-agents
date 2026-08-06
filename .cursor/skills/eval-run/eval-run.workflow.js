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
// applies uniformly and beats the per-stage defaults below
const MODEL = ['sonnet', 'opus', 'haiku', 'fable'].includes(input && input.model) ? input.model : undefined
const MOPT = MODEL ? { model: MODEL } : {}
if (!manifests.length) return { error: 'no manifests passed in args.manifests' }
// optional: per-manifest m.cohort (label) and m.eval_notes (free-text instructions appended to eval prompts)
const cohortSplitDate = (input && input.cohortSplitDate) || null
const cohortInstructions = (input && input.cohortInstructions) || null
// optional targeted profile (named in agent-eval's <profiles>): grade ONLY that
// dimension subset. Profiles are agent-side clusters, so orch-eval is skipped
// entirely — that is what makes the run cheap.
//
// mode 'report' (the /eval-run DEFAULT): forces profile 'report' — one light
// agent per run grading claims vs live APIs, transcript never opened. A
// transcript is therefore NOT required to be evaluable (a report is; a run
// with no report skips here and is an escalation candidate by definition).
// mode 'transcript': the full pass (agent-eval process dimensions + orch-eval).
const mode = (input && input.mode) === 'transcript' ? 'transcript' : 'report'
const profile = mode === 'report' ? 'report' : ((input && input.profile) || null)

// Per-stage model defaults (operator policy 2026-07-29), each beaten by args.model:
//   report-eval agents  -> sonnet (report-vs-API comparison; opus is wasted, haiku
//                          risks the A3 timestamp-ordering judgment)
//   verifiers           -> sonnet + low effort (re-open one citation apiece)
//   transcript-eval agents + cohort synthesis -> inherit the session model
//                          (whole-transcript pattern-finding is where tier shows)
const EVAL_OPT = MODEL ? MOPT : (mode === 'report' ? { model: 'sonnet' } : {})
const VERIFY_OPT = { ...(MODEL ? MOPT : { model: 'sonnet' }), effort: 'low' }
const SYNTH_OPT = MOPT

const needsTranscript = mode === 'transcript'
// Thin references (__fetch_full) can't be pre-filtered here — the agent resolves
// the manifest itself and honors skip-in-flight / reports no-report as escalation.
const evaluable = manifests.filter(m => m.__fetch_full || (!m.in_flight && (needsTranscript ? m.transcript : m.run_report)))
const skipped = manifests.filter(m => !m.__fetch_full && (m.in_flight || (needsTranscript ? !m.transcript : !m.run_report)))
  .map(m => ({ gid: m.gid, task_name: m.task_name, reason: m.in_flight ? 'in_flight' : (needsTranscript ? 'no_transcript' : 'no_run_report (escalation candidate: transcript-eval it)') }))
log(`mode=${mode}: ${evaluable.length} evaluable runs, ${skipped.length} skipped (${skipped.map(s => s.reason).join(', ') || 'none'})`)

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
    flow_proposals: { type: 'array', items: { type: 'string' }, description: '[flow]/[flow-update] tagged bullets verbatim INCLUDING embedded yaml — collection only; promotion happens solely in the manual --consolidate-flows pass' },
    escalate: {
      type: 'object',
      description: 'report-mode only: whether this run warrants a one-off transcript-eval, per the report profile heuristics',
      required: ['suggested', 'reasons'],
      properties: { suggested: { type: 'boolean' }, reasons: { type: 'array', items: { type: 'string' } } },
    },
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
  (profile
    ? `TARGETED PROFILE "${profile}": grade ONLY the dimensions that profile names in your skill's <profiles> block. ` +
      `Every other dimension is OUT OF SCOPE for this run — do not emit it (not even as NA), do not gather its evidence. ` +
      `Return each in-profile dimension exactly once, with BOTH its id and its rubric name.` +
      (profile === 'report'
        ? ` REPORT-EVAL HARD CONSTRAINT: the transcript is NEVER opened — not one grep. Evidence is the run-report ` +
          `attachment + live GitHub/Asana APIs + the manifest's zero-LLM fields (friction, versions) only; anything ` +
          `needing the transcript is NOT_CAPTURED. ALWAYS return the escalate object per the profile's heuristics ` +
          `(reasons name the specific trigger, e.g. "hook_blocks=16" or "verified:partial with empty verify_blockers").`
        : '')
    : `Return every rubric dimension exactly once, each with BOTH its id and its rubric name (e.g. A14 + review-response).`) +
  (m.eval_notes ? `\nRUN-SPECIFIC NOTES (read carefully, these override defaults for this run only): ${m.eval_notes}` : '')

// Evaluate + verify per run, pipelined (no cross-run barrier)
const results = await pipeline(
  evaluable,
  m => parallel([
    () => agent(evalPrompt('agent-eval', m), { label: `agent-eval:${m.gid}`, phase: 'Evaluate', schema: FINDINGS_SCHEMA, ...EVAL_OPT }),
    ...(profile ? [] : [() => agent(evalPrompt('orch-eval', m), { label: `orch-eval:${m.gid}`, phase: 'Evaluate', schema: FINDINGS_SCHEMA, ...EVAL_OPT })]),
  ]),
  async (pair, m) => {
    const [agentF, orchF] = pair
    const dims = [...((agentF && agentF.dimensions) || []), ...((orchF && orchF.dimensions) || [])]
    const allBads = dims.filter(d => d.verdict === 'BAD')
    // Adversarial verify: every BAD in transcript mode (measured 2026-07-29:
    // 8/106 cohort BADs refuted, ALL of them transcript-read errors — ladder
    // timestamp misreads, friction miscounts). In report mode the evidence is
    // an API response the evaluator just fetched, where the refutation rate is
    // zero so far — verify only GATE findings there (a false FAIL is the one
    // cost worth a second read); other report-mode BADs confirm directly.
    const bads = mode === 'report' ? allBads.filter(b => GATES[b.id]) : allBads
    const autoConfirmed = allBads.filter(b => !bads.includes(b))
    const verified = await parallel(bads.map(b => () =>
      agent(
        `Adversarially VERIFY this finding about agent run ${m.gid} (task: ${m.task_name}). ` +
        `Re-open the citation yourself and try to REFUTE it. Default to refuted=true if the evidence does not hold up ` +
        `or the citation cannot be opened.\nDimension: ${b.id}\nClaim: ${b.evidence}\nCitation: ${b.citation || 'none given'}\n` +
        (m.__fetch_full
          ? `Manifest was passed thin; if the citation alone is insufficient, run \`~/.cursor/skills/resolve-run/scripts/resolve-run.sh --gid ${m.gid}\` ` +
            `(timeout 90000ms+) for the full manifest. Thin reference: ${JSON.stringify(m)}`
          : `Manifest: ${JSON.stringify(m)}`),
        { label: `verify:${m.gid}:${b.id}`, phase: 'Verify', schema: VERDICT_SCHEMA, ...VERIFY_OPT }
      ).then(v => ({ ...b, refuted: v ? v.refuted : true, verify_reason: v ? v.reason : 'verifier died' }))
    ))
    const confirmed = [...autoConfirmed, ...verified.filter(Boolean).filter(v => !v.refuted)]
    const refuted = verified.filter(Boolean).filter(v => v.refuted)
    // demote refuted BADs to MINOR-with-note rather than dropping silently
    const finalDims = dims.map(d => {
      if (d.verdict !== 'BAD') return d
      const r = refuted.find(x => x.id === d.id && x.evidence === d.evidence)
      return r ? { ...d, verdict: 'MINOR', evidence: d.evidence + ' [REFUTED on verify: ' + r.verify_reason + ']' } : d
    })
    const gateFails = confirmed.filter(c => GATES[c.id])
    const notCaptured = finalDims.filter(d => d.verdict === 'NOT_CAPTURED').map(d => d.id)
    // report-mode ceiling: a clean report-eval is REPORT_CLEAN, never GOLD (it cannot see process)
    const verdict = gateFails.length ? 'FAIL' : confirmed.length ? 'PASS_WITH_FINDINGS' : (mode === 'report' ? 'REPORT_CLEAN' : 'GOLD')
    return {
      gid: m.gid, task_name: m.task_name, cohort: m.cohort || null, window_end: (m.window && m.window.end) || null, verdict,
      eval_type: mode === 'report' ? 'report-eval' : 'transcript-eval',
      escalate: (agentF && agentF.escalate) || null,
      gate_failures: gateFails.map(g => GATES[g.id]),
      confirmed_bad: confirmed.map(c => ({ id: c.id, evidence: c.evidence, citation: c.citation })),
      dimensions: finalDims,
      not_captured: notCaptured,
      infra_issues: [...((agentF && agentF.infra_issues) || []), ...((orchF && orchF.infra_issues) || [])],
      playbook_proposals: [...((agentF && agentF.playbook_proposals) || []), ...((orchF && orchF.playbook_proposals) || [])],
      flow_proposals: [...((agentF && agentF.flow_proposals) || []), ...((orchF && orchF.flow_proposals) || [])],
      notes: [agentF && agentF.notes, orchF && orchF.notes].filter(Boolean).join(' | '),
    }
  }
)

const runs = results.filter(Boolean)

phase('Synthesize')
const cohort = await agent(
  `Write a cohort evaluation report (markdown) for ${runs.length} orchestrated agent runs evaluated on ${runDate}.\n` +
  `EVAL TYPE: ${mode === 'report' ? 'report-eval (claims vs live state; transcripts never opened; ceiling REPORT_CLEAN)' : 'transcript-eval (full process pass)'} — say this in the report header.\n` +
  (mode === 'report'
    ? `ESCALATION DEMOTION (settled 2026-08-06): a non-empty Orchestration Issues section NEVER generates a ` +
      `transcript-eval row — those disclosures feed [infra-fix] rows and Appendix C. The transcript-eval shortlist ` +
      `contains ONLY finding-driven candidates: confirmed BADs, gate failures, and process anomalies visible from ` +
      `outside (post-Complete force-pushes, unresolved reviewer disputes, missing reports).\n`
    : '') +
  `Verdict policy: gates (${Object.values(GATES).join(', ')}) hard-fail; GOLD = all gates green AND zero confirmed BAD${mode === 'report' ? '; report-evals top out at REPORT_CLEAN' : ''}.\n` +
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
  `TASK RENDERING (hard rule): never write a bare task gid anywhere in the report — a human reads this and gid numbers mean ` +
  `nothing to them. Every run/task mention, in every table and list, is a markdown link whose BODY is the task name: ` +
  `[<task_name>](https://app.asana.com/0/0/<gid>/f). When the task name is unknown (unresolvable gid), link the gid itself as ` +
  `a last resort and say why. The verdict table's first column is the linked task name; do not add a separate raw-gid column ` +
  `(machine consumers read results.json, not this report).\n` +
  `STRUCTURE (settled 2026-08-06, decision-first pyramid — every fact appears ONCE; findings are narrated in full ` +
  `ONLY in Appendix A, and every upfront row LINKS down instead of restating): ` +
  `Header paragraph: totals, one-line trend vs the prior cohort (read the newest earlier ~/agent-evals/*/results.json ` +
  `when one exists), and the reading contract. ` +
  `\"## Needs you\" — one consolidated approval checklist ordered by consequence, each row ONE line: ` +
  `[re-run] rows (gid + DoD gap + terminal bar + the update-status Pending command); ` +
  `[field-correction] rows (exact set-tested.sh command + one-line evidence); ` +
  `the [transcript-eval] shortlist (finding-driven only, per the demotion rule above); ` +
  `operator rulings the eval cannot settle; ` +
  `[skill-gap]/[infra-fix] rows in recurrence order (top item first, full per-run evidence in Appendix C); ` +
  `[playbook-proposal] one-liners and [flow-proposal] one-liners (verbatim texts in Appendix D). ` +
  `\"## Open defect classes\" — the already-fixed inspection INVERTED: lead with NOT-FIXED and PARTIAL classes ` +
  `(named mechanism or its absence, confidence, which upfront row closes it); fully-fixed classes collapse to one ` +
  `reassurance line. Inspection rules: rubric dated carve-outs, hook headers in ~/.config/agent-watcher/hooks/, ` +
  `git log of ~/git/edge-dev-agents since the oldest run window; HIGH confidence only for a deterministic gate ` +
  `shipped after the run window that mechanically blocks the class (name the file); never claim fixed without ` +
  `naming the mechanism. ` +
  `\"## Fleet health\" — ONE paragraph: totals, hook-hardened-surface observations, the clean runs as a single ` +
  `comma-separated line of linked task names (never a table of clean rows), coverage gaps in one line. ` +
  `Then \"# Appendices\": A confirmed findings by dimension (the only full narration, with citations); ` +
  `B the full verdict table (linked task name, verdict, gates, BAD count, gaps); ` +
  `C orchestration friction (substrate prose + the demoted friction-only run mentions, feeding the infra-fix rows); ` +
  `D playbook + flow proposal texts verbatim; E coverage gaps in full. ` +
  `Derive every row ONLY from findings present in the results (no inventions); omit empty subsections. ` +
  `Return ONLY the markdown.`,
  { label: 'cohort-report', phase: 'Synthesize', ...SYNTH_OPT }
)

return { runDate, runs, skipped, cohortReport: cohort }
