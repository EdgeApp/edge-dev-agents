// worktree-merge-state.js: has a task's work landed through merged PRs?
// Used by session-watchdog.js teardownMergedWork().
//
// A worktree can name its branch two ways. Attached, it is HEAD. Detached, it is the
// branch /pr-land's prepare step detached from to free it for the primary checkout,
// read from the reflog ONLY when that detach is the worktree's newest entry: anything
// after it (a commit on the detached HEAD, a checkout elsewhere) may be work the PR
// does not hold, so the worktree then reads as having no branch.
//
// mergeState() per worktree:
//   merged   at least one merged PR and none open (urls lists them)
//   open     a PR is open on the branch
//   closed   only closed-unmerged PRs
//   none     no PR, or no agent branch to look one up by
//   unknown  gh failed or returned something unreadable
//
// mergedPrUrlsForTask() is the task verdict. Every worktree must be merged, except a
// sibling in state "none" that lib/worktree-unsaved.sh calls clean: that is a checkout
// holding nothing of its own (a dep built against), which does not hold the task.
// Any other state keeps the task, and a task with no merged PR at all is never done.
'use strict'
const { execFileSync } = require('child_process')
const path = require('path')

const UNSAVED_SH = path.join(__dirname, 'worktree-unsaved.sh')

function run(cmd, args, cwd) {
  try {
    return execFileSync(cmd, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return null
  }
}

function worktreeBranch(wt) {
  const head = run('git', ['rev-parse', '--abbrev-ref', 'HEAD'], wt)
  if (head !== 'HEAD') return head
  const newest = run('git', ['reflog', '-n', '1', '--format=%gs'], wt)
  const m = newest && newest.match(/^checkout: moving from (\S+) to HEAD$/)
  return m ? m[1] : null
}

function mergeState(wt) {
  const branch = worktreeBranch(wt)
  const prefix = process.env.GIT_BRANCH_PREFIX || 'jon'
  if (!branch || !(branch.startsWith('agent/') || branch.startsWith(`${prefix}/`))) return { state: 'none', urls: [] }
  const out = run('gh', ['pr', 'list', '--head', branch, '--state', 'all', '--limit', '20', '--json', 'url,state,isCrossRepository'], wt)
  let prs
  try { prs = JSON.parse(out).filter((p) => !p.isCrossRepository) } catch { return { state: 'unknown', urls: [] } }
  if (prs.some((p) => p.state === 'OPEN')) return { state: 'open', urls: [] }
  const urls = prs.filter((p) => p.state === 'MERGED').map((p) => p.url)
  if (urls.length > 0) return { state: 'merged', urls }
  return { state: prs.length > 0 ? 'closed' : 'none', urls: [] }
}

// The merged PR urls when the whole task is done, or null when anything holds it.
function mergedPrUrlsForTask(worktrees) {
  const states = worktrees.map((wt) => ({ wt, ...mergeState(wt) }))
  if (!states.some((s) => s.state === 'merged')) return null
  const held = states.some((s) => s.state !== 'merged'
    && !(s.state === 'none' && run(UNSAVED_SH, [s.wt]) === 'clean'))
  return held ? null : states.flatMap((s) => s.urls)
}

module.exports = { worktreeBranch, mergeState, mergedPrUrlsForTask }
