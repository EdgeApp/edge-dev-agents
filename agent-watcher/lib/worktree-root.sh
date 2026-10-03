#!/usr/bin/env bash
# worktree-root.sh: where per-task worktrees live (<root>/<task-gid>/<repo>/).
# The ONE resolver for bash (lib/worktree-root.js is its JS twin, same order):
#   1. AGENT_WORKTREE_ROOT (tests, overrides)
#   2. asana-config.json watcher.worktrees_root (~ expanded)
#   3. ~/git/.agent-worktrees
# worktree_root          prints the root
# task_worktree <gid>    prints <root>/<gid>
worktree_root() {
  local r="${AGENT_WORKTREE_ROOT:-}"
  [ -n "$r" ] || r=$(jq -r '.watcher.worktrees_root // empty' "$HOME/.config/agent-watcher/asana-config.json" 2>/dev/null)
  [ -n "$r" ] || r="$HOME/git/.agent-worktrees"
  printf '%s\n' "${r/#\~/$HOME}"
}
task_worktree() { printf '%s/%s\n' "$(worktree_root)" "$1"; }
