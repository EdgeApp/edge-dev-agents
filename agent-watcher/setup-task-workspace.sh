#!/usr/bin/env bash
# setup-task-workspace.sh — Create a per-task git worktree for a parallel agent slot.
#
# Each parallel agent runs in its own worktree so concurrent sessions never share
# a working tree. The worktree lives at:
#     ~/git/.agent-worktrees/<task-gid>/<repo>/
# on a fresh branch `agent/<task-gid>` based on origin/develop (configurable), with
# the npm-migration commit cherry-picked on top so RN tooling uses npm not yarn.
# env.json is COPIED (a real file, NOT a symlink) from the main checkout. A symlink is
# fragile: the repo's `configure` step (scripts/configure.ts → cleaner-config makeConfig)
# rewrites env.json, and if the link isn't resolving to a real file when that runs, the
# worktree ends up with a defaults-only skeleton (every secret blank/false/null). A real
# copy is read by configure and its real, in-schema values survive the rewrite. Copy also
# avoids the write-through footgun where a tool writing env.json clobbers the shared main
# file. env.json is gitignored, so the copy never lands in a commit/PR.
# node_modules is APFS-cloned (cp -c) from the main checkout so the agent session
# does NOT run a full `npm install`. A scratch install in a project this size spawns
# ~1500 node workers and OOM'd the machine on 2026-05-28 (see oom-repro/HANDOFF.md).
# The clone is copy-on-write: ~26s for a 2.6 GB / 164k-file tree, single-process,
# ~500 MB transient memory, near-zero new disk blocks. Each worktree's tree diverges
# only on files it changes; the session's own `npm install` reconciles just the diff.
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
# Idempotent: if the worktree already exists it is reused (env.json copy re-ensured)
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

# ── APFS clone of node_modules from the main checkout ─────────────────────────
# Uses cp -c (clonefile) so it's instant and copy-on-write. Both paths live under
# ~/git, the same APFS volume, so the clone never falls back to a full byte copy.
# Best-effort: a failure warns and leaves the worktree without node_modules so the
# session can still recover via its own `npm install`.
clone_node_modules() {
  local src="$MAIN_REPO/node_modules"
  local dst="$WT/node_modules"
  if [[ ! -d "$src" ]]; then
    echo ">> setup-task-workspace: WARN — $src not present; skipping node_modules clone" >&2
    return 0
  fi
  if [[ -e "$dst" ]]; then
    echo ">> setup-task-workspace: node_modules already present in worktree; skipping clone" >&2
    return 0
  fi
  local t0 t1
  t0=$(date +%s)
  if cp -cR "$src" "$dst" 2>/tmp/setup-clone.log; then
    t1=$(date +%s)
    echo ">> setup-task-workspace: APFS-cloned node_modules in $((t1 - t0))s ($src → $dst)" >&2
  else
    echo ">> setup-task-workspace: WARN — node_modules clone failed; session will need a full npm install" >&2
    cat /tmp/setup-clone.log >&2
    rm -rf "$dst" 2>/dev/null || true
  fi
}

# ── Copy env.json from the main checkout (durable real file, NOT a symlink) ───
# rm first so we never write *through* an existing symlink into the shared main
# env.json. See the header comment for why a copy beats a symlink here.
ensure_env_json() {
  if [[ -f "$MAIN_REPO/env.json" ]]; then
    rm -f "$WT/env.json"
    cp "$MAIN_REPO/env.json" "$WT/env.json"
    echo ">> setup-task-workspace: copied env.json ← $MAIN_REPO/env.json" >&2
  else
    echo ">> setup-task-workspace: WARN — $MAIN_REPO/env.json not found; worktree has NO secrets" >&2
  fi
}

link_shared_memory() {
  # Surface shared Claude memory (orchestration + user context) in this worktree
  # so the spawned agent sees it. The helper links BOTH the git-root and the
  # worktree-path memory keyings. Idempotent and non-fatal — never blocks setup.
  # Output is redirected to stderr so this script's stdout stays just "$WT".
  local helper="$HOME/.claude/link-shared-memory.sh"
  if [[ -x "$helper" ]]; then
    "$helper" "$WT" >&2 || echo ">> setup-task-workspace: WARN — link-shared-memory failed (non-fatal)" >&2
  fi
}

# ── Idempotent reuse ──────────────────────────────────────────────────────────
if git -C "$MAIN_REPO" worktree list --porcelain | grep -qxF "worktree $WT"; then
  echo ">> setup-task-workspace: worktree already exists, reusing $WT" >&2
  ensure_env_json
  clone_node_modules
  link_shared_memory
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

# ── Copy env.json from the main checkout (real file; survives `configure`) ─────
ensure_env_json

# ── Clone node_modules (after cherry-pick so package.json is in its final state) ─
clone_node_modules

# ── Surface shared Claude memory in this worktree (non-fatal) ─────────────────
link_shared_memory

echo ">> setup-task-workspace: ready $WT (branch $BRANCH)" >&2
echo "$WT"
