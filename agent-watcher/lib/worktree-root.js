// worktree-root.js: where per-task worktrees live (<root>/<task-gid>/<repo>/).
// JS twin of lib/worktree-root.sh, same order: AGENT_WORKTREE_ROOT, then
// asana-config.json watcher.worktrees_root (~ expanded), then ~/git/.agent-worktrees.
const fs = require('fs')
const os = require('os')
const path = require('path')

function worktreeRoot () {
  const home = process.env.HOME || os.homedir()
  if (process.env.AGENT_WORKTREE_ROOT) return process.env.AGENT_WORKTREE_ROOT
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(home, '.config/agent-watcher/asana-config.json'), 'utf8'))
    const r = cfg.watcher && cfg.watcher.worktrees_root
    if (r) return r.replace(/^~(?=$|\/)/, home)
  } catch (e) {}
  return path.join(home, 'git/.agent-worktrees')
}

module.exports = { worktreeRoot }
