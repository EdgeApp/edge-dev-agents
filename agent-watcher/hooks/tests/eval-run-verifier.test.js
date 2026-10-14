#!/usr/bin/env node
// Contract test for the verify stage of ~/.cursor/skills/eval-run/eval-run.workflow.js:
// a verifier that dies leaves its finding BAD and marked not verified, never refuted
// and never dropped.
//
// Run: node ~/.config/agent-watcher/hooks/tests/eval-run-verifier.test.js
//
// The workflow script runs here under stand-ins for the workflow runtime (agent,
// parallel, pipeline, phase, log). The evaluator stand-in returns four BAD findings;
// the verifier stand-in confirms one, refutes one, returns null for one (the runtime's
// answer for a dead agent) and throws for one (parallel turns that into a null slot).
const fs = require('fs')
const os = require('os')
const path = require('path')

const file = path.join(os.homedir(), '.cursor/skills/eval-run/eval-run.workflow.js')
const src = fs.readFileSync(file, 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

let fails = 0
const check = (name, cond, detail) => {
  console.log((cond ? 'ok   ' : 'FAIL ') + name + (cond ? '' : '  ' + (detail || '')))
  if (!cond) fails++
}

const BADS = ['A1', 'A2', 'A3', 'A4'].map(id => ({ id, name: 'dim-' + id, verdict: 'BAD', evidence: 'claim ' + id, citation: 'c' }))
const agent = async (prompt, opts) => {
  const label = (opts && opts.label) || ''
  if (label.startsWith('agent-eval:')) return { gid: '1', dimensions: [...BADS, { id: 'A5', name: 'dim-A5', verdict: 'GOOD', evidence: 'fine' }] }
  if (label.startsWith('orch-eval:')) return { gid: '1', dimensions: [] }
  if (label === 'verify:1:A1') return { refuted: false, reason: 'holds' }
  if (label === 'verify:1:A2') return { refuted: true, reason: 'citation does not say that' }
  if (label === 'verify:1:A3') return null
  if (label === 'verify:1:A4') throw new Error('verifier crashed')
  if (label === 'cohort-report') return { report: '', actions: [] }
  throw new Error('unexpected agent call: ' + label)
}
const parallel = thunks => Promise.all(thunks.map(t => Promise.resolve().then(t).catch(() => null)))
const pipeline = (items, ...stages) => Promise.all(items.map(async (item, i) => {
  let v = item
  try { for (const s of stages) v = await s(v, item, i) } catch (e) { return null }
  return v
}))

const args = { mode: 'transcript', runDate: 'd', manifests: [{ gid: '1', task_name: 't', transcript: '/x', run_report: '/y' }] }
new AsyncFunction('args', 'agent', 'parallel', 'pipeline', 'phase', 'log', 'budget', src)(
  args, agent, parallel, pipeline, () => {}, () => {}, { total: null, spent: () => 0, remaining: () => Infinity }
).then(out => {
  const run = out.runs[0]
  const dim = id => run.dimensions.find(d => d.id === id)
  const conf = id => run.confirmed_bad.find(c => c.id === id)
  check('a confirmed finding stays BAD and is counted', dim('A1').verdict === 'BAD' && conf('A1') && !conf('A1').not_verified, JSON.stringify(run.confirmed_bad))
  check('a refuted finding is demoted with the reason', dim('A2').verdict === 'MINOR' && dim('A2').evidence.includes('REFUTED on verify: citation does not say that') && !conf('A2'))
  for (const [id, how] of [['A3', 'returned null'], ['A4', 'threw']]) {
    check(`a verifier that ${how} leaves the finding BAD, counted and marked not verified`,
      dim(id).verdict === 'BAD' && dim(id).evidence.includes('NOT VERIFIED') && !dim(id).evidence.includes('REFUTED') &&
      conf(id) && conf(id).not_verified === true, JSON.stringify([dim(id), conf(id)]))
  }
  check('the run lists its not verified findings', JSON.stringify(run.not_verified) === '["A3","A4"]', JSON.stringify(run.not_verified))
  check('the verdict counts them', run.verdict === 'PASS_WITH_FINDINGS' || run.verdict === 'FAIL', run.verdict)
  console.log(fails ? `\n${fails} failure(s)` : '\nall passed')
  process.exit(fails ? 1 : 0)
}).catch(e => { console.log('FAIL workflow threw: ' + (e && e.stack || e)); process.exit(1) })
