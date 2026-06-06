#!/usr/bin/env bash
# cleanup-task-workspace.sh — Reverse of setup-task-workspace.sh.
#
# Removes a per-task worktree, deletes its env.json copy, and deletes the
# agent branch if it's safe (the branch matches our `agent/<gid>` convention).
# Used by session-watchdog.js during the completion sweep and by gc-worktrees.sh.
#
# Usage:
#   cleanup-task-workspace.sh --task-gid <gid> --repo <name>
#
# Best-effort by design: a partial failure (e.g. branch already gone) is warned
# about but does NOT fail the command. The watchdog must never get stuck because
# one piece of teardown didn't apply.
#
# Exit codes:
#   0 = always (best-effort teardown; warnings on stderr)
#   2 = usage error

set -euo pipefail

REPOS_ROOT="$HOME/git"
WORKTREES_ROOT="$HOME/git/.agent-worktrees"

TASK_GID=""
REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-gid) TASK_GID="$2"; shift 2 ;;
    --repo)     REPO="$2";     shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TASK_GID" && -n "$REPO" ]] || {
  echo "Usage: cleanup-task-workspace.sh --task-gid <gid> --repo <name>" >&2
  exit 2
}

MAIN_REPO="$REPOS_ROOT/$REPO"
WT="$WORKTREES_ROOT/$TASK_GID/$REPO"
# The branch is no longer the opaque agent/<gid> — setup may have named it
# "$GIT_BRANCH_PREFIX/<short-name>". Read the worktree's actual HEAD branch BEFORE
# we remove the worktree; fall back to the legacy name if the worktree is gone.
BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ -z "$BRANCH" || "$BRANCH" == "HEAD" ]] && BRANCH="agent/$TASK_GID"

# Delete the env.json copy first so we scrub the plaintext secrets even if the
# worktree-remove below fails and the dir lingers. (-e: it's now a real file, not
# a symlink; older worktrees may still have a symlink — rm -f handles both.)
if [[ -e "$WT/env.json" || -L "$WT/env.json" ]]; then
  rm -f "$WT/env.json" && echo ">> cleanup-task-workspace: removed env.json" >&2
fi

# Remove the worktree (force — it may have build artifacts / uncommitted state).
if [[ -d "$MAIN_REPO/.git" ]]; then
  if git -C "$MAIN_REPO" worktree remove --force "$WT" 2>/dev/null; then
    echo ">> cleanup-task-workspace: removed worktree $WT" >&2
  else
    echo ">> cleanup-task-workspace: WARN — worktree remove failed (already gone?); pruning" >&2
    git -C "$MAIN_REPO" worktree prune 2>/dev/null || true
  fi

  # Delete the branch — but ONLY if it matches one of our agent naming conventions
  # (agent/* or "$GIT_BRANCH_PREFIX/*"). NEVER delete a shared branch (develop/main/…).
  PREFIX="${GIT_BRANCH_PREFIX:-jon}"
  if [[ "$BRANCH" == agent/* || "$BRANCH" == "$PREFIX"/* ]]; then
    if git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git -C "$MAIN_REPO" branch -D "$BRANCH" >/dev/null 2>&1 \
        && echo ">> cleanup-task-workspace: deleted branch $BRANCH" >&2 \
        || echo ">> cleanup-task-workspace: WARN — could not delete branch $BRANCH" >&2
    fi
  else
    echo ">> cleanup-task-workspace: WARN — branch '$BRANCH' isn't agent/* or $PREFIX/*; NOT deleting (safety)" >&2
  fi
else
  echo ">> cleanup-task-workspace: WARN — main repo $MAIN_REPO missing; skipping git teardown" >&2
fi

# Drop the now-empty per-task parent dir if nothing else lives under it.
rmdir "$WORKTREES_ROOT/$TASK_GID" 2>/dev/null || true

echo ">> cleanup-task-workspace: done ($TASK_GID / $REPO)" >&2
exit 0
