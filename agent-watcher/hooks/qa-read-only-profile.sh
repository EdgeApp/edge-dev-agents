#!/usr/bin/env node
// PreToolUse hook (matchers: Bash, Write|Edit|MultiEdit|NotebookEdit,
// mcp__claude_ai_Asana__.*). The read-only profile of an async QA session
// (qa-run SKILL.md `read-only-session`): a QA pass tests the dev run's PR head
// and posts one verdict, so it changes nothing it did not create.
//
// Active only when AGENT_MODE=qa AND AGENT_TASK_GID is set (spawn-test-session.sh
// --qa exports both). Every other session: exit 0, no output.
//
// Blocked (exit 2, stderr names `qa-run:read-only-session` and the compliant path):
//   Bash
//     - git writes: commit, push, rebase, merge, cherry-pick, reset, revert, am,
//       tag, stash, switch, branch -d/-D/-m/-M, checkout/restore of anything but
//       src/util/corePlugins.ts (the documented runtime switch, reverted with
//       `git restore` or `git checkout --` on that one file);
//     - gh writes: pr create/edit/comment/review/merge/close/ready/reopen, issue
//       writes, `gh api` with a write method or field flags;
//     - orch writers: update-status.sh, set-agent-field.sh, asana-task-update.sh,
//       pr-create.sh, pr-address.sh, github-pr-review.sh, lint-commit.sh,
//       allocate-from-pool.sh, release-pool-entry.sh;
//     - installs: npm ci/install/i/add, yarn (bare, install, add), pod install,
//       bundle install, npx pod-install;
//     - shell writes onto a git-tracked file other than corePlugins.ts: `>`/`>>`
//       redirects, tee, sed -i, perl -i, cp/mv destinations.
//   Write/Edit/MultiEdit/NotebookEdit onto a git-tracked file other than
//     src/util/corePlugins.ts (harness files belong under /tmp).
//   Asana MCP tools other than get_* / search_* (verdicts post through
//     qa-verdict.sh, which writes from a subprocess this hook never sees).
//
// Allowed: everything under ~/.cursor/skills/qa-run/scripts/ (their own Asana and
// gh calls are subprocesses, not tool calls), reads, builds, drives.
//
// Escape hatch: /tmp/agent-qa-write-<gid>.md (non-empty, says what and why).
// /eval-run audits it; an unjustified note is a finding.
//
// Commands are read with cmd-parse.sh (lib/shell-commands.js), so a quoted or
// heredoc MENTION never fires. When the line cannot be parsed the hook falls back
// to a plain text match on the mention-stripped view.
'use strict'

const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')

const GID = process.env.AGENT_TASK_GID || ''
if (process.env.AGENT_MODE !== 'qa' || !GID) process.exit(0)

const HOME = process.env.HOME || ''
const HOOKS = path.join(HOME, '.config/agent-watcher/hooks')
const HATCH = `/tmp/agent-qa-write-${GID}.md`
const SWITCH_RE = /(^|\/)src\/util\/corePlugins\.ts$/
const QA_SCRIPTS = path.join(HOME, '.cursor/skills/qa-run/scripts') + '/'

let input = {}
try { input = JSON.parse(fs.readFileSync(0, 'utf8') || '{}') } catch { process.exit(0) }
const tool = input.tool_name || ''
const ti = input.tool_input || {}
const baseCwd = input.cwd || process.cwd()

function hatchOpen() {
  try { return fs.statSync(HATCH).size > 0 } catch { return false }
}

function block(what, compliant) {
  if (hatchOpen()) {
    process.stderr.write(`qa-read-only-profile: allowed by ${HATCH} (${what})\n`)
    process.exit(0)
  }
  process.stderr.write(
    `BLOCKED [qa-run:read-only-session]: ${what}. A QA session changes nothing it did not create.\n` +
    `Compliant path: ${compliant}\n` +
    `Escape hatch (audited by /eval-run): write the reason to ${HATCH}.\n`)
  process.exit(2)
}

function expand(p) { return p.startsWith('~/') ? path.join(HOME, p.slice(2)) : p }

// True when file resolves to a git-tracked path other than the runtime switch.
function trackedNonSwitch(file, cwd) {
  if (!file) return false
  const abs = path.resolve(cwd || baseCwd, expand(file))
  if (SWITCH_RE.test(abs)) return false
  let dir = path.dirname(abs)
  while (dir !== '/' && !fs.existsSync(dir)) dir = path.dirname(dir)
  const r = spawnSync('git', ['-C', dir, 'ls-files', '--error-unmatch', abs], { stdio: 'ignore' })
  return r.status === 0
}

// ---- Asana MCP
if (tool.startsWith('mcp__claude_ai_Asana__')) {
  const verb = tool.slice('mcp__claude_ai_Asana__'.length)
  if (/^(get|search)_/.test(verb)) process.exit(0)
  block(`Asana MCP write ${verb}`, 'post the verdict with ~/.cursor/skills/qa-run/scripts/qa-verdict.sh (or qa-gate.sh for a skip)')
}

// ---- Write / Edit
if (['Write', 'Edit', 'MultiEdit', 'NotebookEdit'].includes(tool)) {
  const f = ti.file_path || ti.notebook_path || ''
  if (trackedNonSwitch(f, baseCwd)) {
    block(`${tool} on tracked file ${f}`, 'put harness files under /tmp; the only tracked edit is the src/util/corePlugins.ts runtime switch, reverted before the verdict')
  }
  process.exit(0)
}

if (tool !== 'Bash') process.exit(0)
const cmd = ti.command || ''
if (!cmd) process.exit(0)

const ORCH_WRITERS = new Set(['update-status.sh', 'set-agent-field.sh', 'asana-task-update.sh', 'pr-create.sh',
  'pr-address.sh', 'github-pr-review.sh', 'lint-commit.sh', 'allocate-from-pool.sh', 'release-pool-entry.sh'])
const GIT_WRITES = new Set(['commit', 'push', 'rebase', 'merge', 'cherry-pick', 'reset', 'revert', 'am', 'tag', 'stash', 'switch'])
const GH_PR_WRITES = /^pr (create|edit|comment|review|merge|close|ready|reopen)\b/
const GH_ISSUE_WRITES = /^issue (create|edit|comment|close|reopen|delete|transfer|pin|unpin|lock|unlock)\b/
const VERDICT = 'post results only through qa-verdict.sh / qa-gate.sh; QA never edits the dev branch, PR or task fields'

function judge(rec) {
  const argv = rec.argv || []
  const name = rec.name || ''
  const p = rec.path || ''
  if (p.startsWith(QA_SCRIPTS)) return
  if (ORCH_WRITERS.has(name)) block(`${name} in a QA session`, VERDICT)
  if (rec.git) {
    const sub = rec.git.sub || ''
    const args = rec.git.args || []
    if (GIT_WRITES.has(sub)) block(`git ${sub}`, VERDICT)
    if (sub === 'branch' && args.some((a) => /^-[dDmM]$|^--(delete|move)$/.test(a))) block('git branch delete/move', VERDICT)
    if (sub === 'checkout' || sub === 'restore') {
      const paths = args.filter((a) => !a.startsWith('-'))
      if (sub === 'checkout' && !args.includes('--')) block('git checkout of a ref', 'stay on the pinned PR head; revert the switch with `git restore src/util/corePlugins.ts`')
      if (!paths.length || !paths.every((a) => SWITCH_RE.test(a))) block(`git ${sub} ${paths.join(' ')}`, 'only src/util/corePlugins.ts may be restored')
    }
  }
  if (name === 'gh') {
    const sub = rec.gh?.sub || argv.slice(1, 3).join(' ')
    if (GH_PR_WRITES.test(sub) || GH_ISSUE_WRITES.test(sub)) block(`gh ${sub}`, VERDICT)
    if (argv[1] === 'api') {
      const a = argv.slice(2)
      const method = (() => { const i = a.findIndex((x) => x === '-X' || x === '--method'); return i >= 0 ? (a[i + 1] || '').toUpperCase() : (a.find((x) => /^(-X|--method=)/.test(x)) || '').replace(/^(-X|--method=)/, '').toUpperCase() })()
      const fields = a.some((x) => /^(-f|-F|--field|--raw-field|--input)$/.test(x) || /^(-f|-F)./.test(x))
      const isGraphqlRead = a[0] === 'graphql' && !a.some((x) => /mutation/.test(x))
      if (/^(POST|PATCH|PUT|DELETE)$/.test(method) || (fields && !isGraphqlRead && method !== 'GET')) block(`gh api write (${a.slice(0, 3).join(' ')})`, VERDICT)
    }
  }
  const sub1 = argv[1] || ''
  if ((name === 'npm' && /^(ci|install|i|add)$/.test(sub1)) || (name === 'yarn' && (!sub1 || /^(install|add)$/.test(sub1) || sub1.startsWith('--'))) ||
      (name === 'pod' && sub1 === 'install') || (name === 'bundle' && sub1 === 'install') || (name === 'npx' && sub1 === 'pod-install')) {
    block(`${name} ${sub1}`.trim() + ' (install step)', 'reuse the dev worktree as is; ios-rn-build.sh installs the cached dev app')
  }
  const cwd = rec.cwd || baseCwd
  for (const r of rec.redirs || []) {
    if (/>/.test(r.op || '') && trackedNonSwitch(r.target, cwd)) block(`shell redirect onto tracked file ${r.target}`, 'write harness output under /tmp')
  }
  if (name === 'tee') for (const f of argv.slice(1).filter((x) => !x.startsWith('-'))) if (trackedNonSwitch(f, cwd)) block(`tee onto tracked file ${f}`, 'write under /tmp')
  if ((name === 'sed' || name === 'perl') && argv.some((x) => /^-[a-zA-Z]*i/.test(x))) {
    for (const f of argv.slice(1).filter((x) => !x.startsWith('-'))) if (trackedNonSwitch(f, cwd)) block(`${name} -i on tracked file ${f}`, 'only src/util/corePlugins.ts may be edited')
  }
  if ((name === 'cp' || name === 'mv') && argv.length > 2) {
    const dest = argv[argv.length - 1]
    if (trackedNonSwitch(dest, cwd)) block(`${name} onto tracked file ${dest}`, 'write under /tmp')
  }
}

const parsed = spawnSync(path.join(HOOKS, 'cmd-parse.sh'), ['--cwd', baseCwd], { input: cmd, encoding: 'utf8' })
if (parsed.status === 0) {
  for (const line of (parsed.stdout || '').split('\n').filter(Boolean)) {
    let rec
    try { rec = JSON.parse(line) } catch { continue }
    judge(rec)
  }
  process.exit(0)
}

// Unparseable line: text match on the mention-stripped view.
const stripped = spawnSync(path.join(HOOKS, 'strip-cmd-mentions.sh'), [], { input: cmd, encoding: 'utf8' })
const view = stripped.status === 0 ? stripped.stdout : cmd
if (/qa-run\/scripts\//.test(view)) process.exit(0)
const TEXT = /\bgit\s+(\S+\s+)*(commit|push|rebase|merge|cherry-pick|reset|stash)\b|\bgh\s+pr\s+(create|edit|comment|review|merge|close)\b|\b(update-status|set-agent-field|asana-task-update|pr-create|allocate-from-pool|release-pool-entry)\.sh\b|\b(npm\s+(ci|install)|yarn\s+install|pod\s+install)\b/
const m = view.match(TEXT)
if (m) block(`unparseable command containing "${m[0]}"`, VERDICT)
process.exit(0)
