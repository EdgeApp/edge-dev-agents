#!/usr/bin/env bash
# setup-task-workspace.sh — Create a per-task git worktree for a parallel agent slot.
#
# Each parallel agent runs in its own worktree so concurrent sessions never share
# a working tree. The worktree lives at:
#     ~/git/.agent-worktrees/<task-gid>/<repo>/
# on a fresh branch `agent/<task-gid>` based on origin/develop (configurable), with
# the npm-migration commit cherry-picked on top so RN tooling uses npm not yarn.
# env.json is SYMLINKED (not copied) from the main checkout so secrets stay single-source.
#
# Usage:
#   setup-task-workspace.sh --task-gid <gid> --repo <name> [--base <ref>] [--cherry-pick <sha|none>]
#
#   --task-gid     REQUIRED. Asana task GID; namespaces the worktree + branch.
#   --repo         REQUIRED. Repo name under ~/git, e.g. edge-react-gui.
#   --base         Base ref for the new branch (default: origin/develop).
#   --cherry-pick  Commit to cherry-pick on top, or "none" to skip.
#                  Default: .watcher.npm_migration_commit from asana-config.json.
#
# Idempotent: if the worktree already exists it is reused (env.json symlink re-ensured)
# and its path is returned without re-creating anything.
#
# Prints the worktree path on stdout, status on stderr.
#
# Exit codes:
#   0 = worktree ready (path on stdout)
#   1 = error (missing repo, worktree add failed)
#   2 = usage error OR cherry-pick conflict (caller should treat as a blocker)

set -euo pipefail

CONFIG="$HOME/.config/agent-watcher/asana-config.json"
WORKTREES_ROOT="$HOME/git/.agent-worktrees"
REPOS_ROOT="$HOME/git"

TASK_GID=""
REPO=""
BASE="origin/develop"
CHERRY_PICK="__from_config__"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-gid)    TASK_GID="$2";    shift 2 ;;
    --repo)        REPO="$2";        shift 2 ;;
    --base)        BASE="$2";        shift 2 ;;
    --cherry-pick) CHERRY_PICK="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TASK_GID" && -n "$REPO" ]] || {
  echo "Usage: setup-task-workspace.sh --task-gid <gid> --repo <name> [--base <ref>] [--cherry-pick <sha|none>]" >&2
  exit 2
}

MAIN_REPO="$REPOS_ROOT/$REPO"
[[ -d "$MAIN_REPO/.git" ]] || { echo "Repo not found or not a git repo: $MAIN_REPO" >&2; exit 1; }

# Resolve the cherry-pick sha from config unless overridden on the CLI.
if [[ "$CHERRY_PICK" == "__from_config__" ]]; then
  if [[ -f "$CONFIG" ]] && command -v jq >/dev/null 2>&1; then
    CHERRY_PICK=$(jq -r '.watcher.npm_migration_commit // "none"' "$CONFIG")
  else
    CHERRY_PICK="none"
  fi
fi

WT="$WORKTREES_ROOT/$TASK_GID/$REPO"
BRANCH="agent/$TASK_GID"

# ── Idempotent reuse ──────────────────────────────────────────────────────────
if git -C "$MAIN_REPO" worktree list --porcelain | grep -qxF "worktree $WT"; then
  echo ">> setup-task-workspace: worktree already exists, reusing $WT" >&2
  ln -sfn "$MAIN_REPO/env.json" "$WT/env.json" 2>/dev/null || true
  echo "$WT"
  exit 0
fi

mkdir -p "$WORKTREES_ROOT/$TASK_GID"

# Best-effort refresh of the base ref so we branch from current develop.
git -C "$MAIN_REPO" fetch --quiet origin "${BASE#origin/}" 2>/dev/null \
  || echo ">> setup-task-workspace: WARN — fetch of $BASE failed; using local ref" >&2

echo ">> setup-task-workspace: git worktree add -b $BRANCH $WT $BASE" >&2
# Route git's stdout to a log so the ONLY thing on our stdout is the worktree path.
if ! git -C "$MAIN_REPO" worktree add -b "$BRANCH" "$WT" "$BASE" >/tmp/setup-wt.log 2>&1; then
  echo "worktree add failed:" >&2
  cat /tmp/setup-wt.log >&2
  rmdir "$WORKTREES_ROOT/$TASK_GID" 2>/dev/null || true
  exit 1
fi
cat /tmp/setup-wt.log >&2

# ── Cherry-pick the npm migration commit on top ───────────────────────────────
if [[ -n "$CHERRY_PICK" && "$CHERRY_PICK" != "none" ]]; then
  if git -C "$WT" merge-base --is-ancestor "$CHERRY_PICK" HEAD 2>/dev/null; then
    echo ">> setup-task-workspace: $CHERRY_PICK already present in base; skipping cherry-pick" >&2
  elif git -C "$WT" cherry-pick "$CHERRY_PICK" >/tmp/setup-cp.log 2>&1; then
    echo ">> setup-task-workspace: cherry-picked $CHERRY_PICK" >&2
  else
    # No staged/unstaged delta → the commit was redundant; finish the cherry-pick cleanly.
    if git -C "$WT" diff --quiet && git -C "$WT" diff --staged --quiet; then
      git -C "$WT" cherry-pick --skip 2>/dev/null || git -C "$WT" cherry-pick --quit 2>/dev/null || true
      echo ">> setup-task-workspace: cherry-pick $CHERRY_PICK was empty (already applied); skipped" >&2
    else
      echo "cherry-pick of $CHERRY_PICK conflicted:" >&2
      cat /tmp/setup-cp.log >&2
      git -C "$WT" cherry-pick --abort 2>/dev/null || true
      git -C "$MAIN_REPO" worktree remove --force "$WT" 2>/dev/null || true
      git -C "$MAIN_REPO" branch -D "$BRANCH" 2>/dev/null || true
      exit 2
    fi
  fi
fi

# ── Symlink env.json (single-source secrets; never a copy) ────────────────────
if [[ -f "$MAIN_REPO/env.json" ]]; then
  ln -sfn "$MAIN_REPO/env.json" "$WT/env.json"
  echo ">> setup-task-workspace: linked env.json → $MAIN_REPO/env.json" >&2
else
  echo ">> setup-task-workspace: WARN — $MAIN_REPO/env.json not found; no symlink created" >&2
fi

echo ">> setup-task-workspace: ready $WT (branch $BRANCH)" >&2
echo "$WT"
