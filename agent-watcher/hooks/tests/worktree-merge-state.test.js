#!/usr/bin/env node
// Contract test for lib/worktree-merge-state.js against real throwaway git worktrees
// and a fake gh on PATH that answers by branch.
// Run: node ~/.config/agent-watcher/hooks/tests/worktree-merge-state.test.js
'use strict'
const { execFileSync } = require('child_process')
const fs = require('fs')
const os = require('os')
const path = require('path')

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'merge-state-test-'))
process.on('exit', () => fs.rmSync(TMP, { recursive: true, force: true }))
let fails = 0
function check(name, actual, want) {
  const a = JSON.stringify(actual)
  const w = JSON.stringify(want)
  if (a === w) console.log(`ok   ${name}`)
  else { console.log(`FAIL ${name}: got ${a}, want ${w}`); fails++ }
}

// PRs per branch for the fake gh; a branch starting jon/broken makes gh fail.
const PRS = {
  'jon/merged': [{ url: 'u/merged', state: 'MERGED', isCrossRepository: false }],
  'jon/merged-b': [{ url: 'u/merged-b', state: 'MERGED', isCrossRepository: false }],
  'jon/open': [{ url: 'u/open', state: 'OPEN', isCrossRepository: false }],
  'jon/open-2': [{ url: 'u/open-2', state: 'OPEN', isCrossRepository: false }],
  'jon/reopened': [{ url: 'u/old', state: 'MERGED', isCrossRepository: false }, { url: 'u/new', state: 'OPEN', isCrossRepository: false }],
  'jon/closed': [{ url: 'u/closed', state: 'CLOSED', isCrossRepository: false }],
  'jon/closed-2': [{ url: 'u/closed-2', state: 'CLOSED', isCrossRepository: false }],
  'jon/fork': [{ url: 'u/fork', state: 'MERGED', isCrossRepository: true }],
}
const BIN = path.join(TMP, 'bin')
fs.mkdirSync(BIN)
fs.writeFileSync(path.join(BIN, 'gh'), `#!/usr/bin/env node
const a = process.argv.slice(2); const b = a[a.indexOf('--head') + 1]
if (b.startsWith('jon/broken')) process.exit(1)
process.stdout.write(JSON.stringify(${JSON.stringify(PRS)}[b] || []))
`)
fs.chmodSync(path.join(BIN, 'gh'), 0o755)
process.env.PATH = `${BIN}:${process.env.PATH}`
process.env.GIT_BRANCH_PREFIX = 'jon'

const REPO = path.join(TMP, 'repo')
const git = (cwd, ...args) => execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
fs.mkdirSync(REPO)
git(REPO, 'init', '-q', '-b', 'develop')
git(REPO, 'config', 'user.email', 't@t')
git(REPO, 'config', 'user.name', 't')
fs.writeFileSync(path.join(REPO, 'a.txt'), 'a\n')
git(REPO, 'add', '-A')
git(REPO, 'commit', '-qm', 'base')
const ORIGIN = path.join(TMP, 'origin.git')
git(TMP, 'init', '-q', '--bare', ORIGIN)
git(REPO, 'remote', 'add', 'origin', ORIGIN)
git(REPO, 'push', '-q', 'origin', 'develop')

// A worktree on a new branch, with one commit no remote holds (like a landed PR's
// pre-rebase commit once the remote branch is deleted).
let n = 0
function worktree(branch) {
  const wt = path.join(TMP, `wt${++n}`)
  git(REPO, 'worktree', 'add', '-q', '-b', branch, wt)
  fs.writeFileSync(path.join(wt, `${branch.replace(/\W/g, '-')}.txt`), 'w\n')
  git(wt, 'add', '-A')
  git(wt, 'commit', '-qm', branch)
  return wt
}
function detached(branch) {
  const wt = worktree(branch)
  git(wt, 'checkout', '--detach')
  return wt
}

const { worktreeBranch, mergeState, mergedPrUrlsForTask } = require(path.join(os.homedir(), '.config/agent-watcher/lib/worktree-merge-state.js'))

// --- naming the branch ---
const attached = worktree('jon/merged')
check('attached: HEAD names the branch', worktreeBranch(attached), 'jon/merged')
const det = detached('jon/merged-b')
check('detached: the reflog names the branch', worktreeBranch(det), 'jon/merged-b')
const afterCommit = detached('jon/after-commit')
fs.writeFileSync(path.join(afterCommit, 'later.txt'), 'l\n')
git(afterCommit, 'add', '-A')
git(afterCommit, 'commit', '-qm', 'later')
check('a commit after the detach loses the branch', worktreeBranch(afterCommit), null)
const afterMove = detached('jon/after-move')
git(afterMove, 'checkout', '-q', 'HEAD~1')
check('a checkout after the detach loses the branch', worktreeBranch(afterMove), null)

// --- per-worktree state ---
check('merged on a detached worktree', mergeState(det), { state: 'merged', urls: ['u/merged-b'] })
check('an open PR beats a merged one', mergeState(worktree('jon/reopened')).state, 'open')
check('open', mergeState(worktree('jon/open')).state, 'open')
check('closed unmerged', mergeState(worktree('jon/closed')).state, 'closed')
check('no PR', mergeState(worktree('jon/no-pr')).state, 'none')
check('a fork PR does not count', mergeState(worktree('jon/fork')).state, 'none')
check('gh failure', mergeState(worktree('jon/broken')).state, 'unknown')
check('a non-agent branch has no lookup', mergeState(worktree('feature/x')).state, 'none')

// A sibling at the pushed base: detached, clean, no PR to look up.
const cleanSibling = path.join(TMP, 'clean')
git(REPO, 'worktree', 'add', '-q', '--detach', cleanSibling, 'origin/develop')
const dirtySibling = path.join(TMP, 'dirty')
git(REPO, 'worktree', 'add', '-q', '--detach', dirtySibling, 'origin/develop')
fs.writeFileSync(path.join(dirtySibling, 'a.txt'), 'edited\n')

// --- the task verdict ---
check('all merged: done', mergedPrUrlsForTask([attached, det]), ['u/merged', 'u/merged-b'])
check('merged plus a clean no-PR sibling: done', mergedPrUrlsForTask([det, cleanSibling]), ['u/merged-b'])
check('merged plus a dirty no-PR sibling: held', mergedPrUrlsForTask([det, dirtySibling]), null)
check('merged plus an unpushed no-PR sibling: held', mergedPrUrlsForTask([det, worktree('jon/no-pr-2')]), null)
check('merged plus an open sibling: held', mergedPrUrlsForTask([det, detached('jon/open-2')]), null)
check('merged plus work after a detach: held', mergedPrUrlsForTask([det, afterCommit]), null)
check('merged plus a gh failure: held', mergedPrUrlsForTask([det, detached('jon/broken-2')]), null)
check('merged plus closed unmerged: held', mergedPrUrlsForTask([det, detached('jon/closed-2')]), null)
check('nothing merged: not done', mergedPrUrlsForTask([cleanSibling]), null)

console.log(fails === 0 ? 'all passed' : `${fails} FAILED`)
process.exit(fails > 0 ? 1 : 0)
