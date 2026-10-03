#!/usr/bin/env bash
# remove-task-worktrees.sh: remove one task's worktrees (and their DerivedData) off
# the watchdog's tick. A removal runs minutes (git worktree remove over ~164k
# node_modules files, ~2 GB DerivedData per iOS worktree), and the watchdog tick is
# serial: blocking on it froze Complete retirement, so a finished task kept holding
# its concurrency slot and new spawns waited.
#
# Started by session-watchdog.js removeTaskWorktrees() in its own session (spawn
# detached = setsid), so launchd's process-group kill at watchdog exit cannot end it.
# The watchdog releases the task's pool sim and slot itself BEFORE starting this.
#
# IN-PROGRESS MARKER: $STATE_DIR/removing/<gid> holds this worker's pid while it runs.
#   session-watchdog.js   skips the gid (no second removal, no unsaved check on a
#                         half-deleted tree)
#   gc-worktrees.sh       skips the gid
#   setup-task-workspace.sh  waits for it before reusing or re-creating the worktree
# A marker whose pid is gone is stale: readers ignore it and the next tick retries.
#
# Usage:   remove-task-worktrees.sh <gid> <repo> [<repo>...]
# Output:  cleanup-task-workspace.sh's lines, then one "done" line (to the caller's log)
# Exit:    0 = removal attempted for every repo, 1 = usage error

set -euo pipefail
source "$HOME/.config/agent-watcher/lib/worktree-root.sh"  # the one worktree-root resolver

[[ $# -ge 2 ]] || { echo "usage: remove-task-worktrees.sh <gid> <repo> [<repo>...]" >&2; exit 1; }
GID="$1"; shift
[[ "$GID" =~ ^[0-9]+$ ]] || { echo "remove-task-worktrees: gid must be numeric: $GID" >&2; exit 1; }

DIR="$HOME/.config/agent-watcher"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
MARKER="$STATE_DIR/removing/$GID"
GID_DIR="$(task_worktree "$GID")"

mkdir -p "$STATE_DIR/removing"
echo "$$" > "$MARKER"
trap 'rm -f "$MARKER"' EXIT

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
echo "[$(ts)] [$GID] removing worktree(s): $*"
for repo in "$@"; do
  "$DIR/cleanup-task-workspace.sh" --task-gid "$GID" --repo "$repo" 2>&1 || true
done
# cleanup-task-workspace.sh exits 0 even when removal fails (e.g. a non-git dir);
# take what it left so the next tick does not retry the same gid forever.
if [[ -d "$GID_DIR" ]]; then
  echo "[$(ts)] [$GID] cleanup left $GID_DIR behind; force-removing"
  rm -rf -- "$GID_DIR" || echo "[$(ts)] [$GID] WARN force-remove failed"
fi
echo "[$(ts)] [$GID] done"
