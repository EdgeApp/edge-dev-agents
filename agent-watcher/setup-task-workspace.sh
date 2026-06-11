#!/usr/bin/env bash
# setup-task-workspace.sh — Create a per-task git worktree for a parallel agent slot.
#
# Each parallel agent runs in its own worktree so concurrent sessions never share
# a working tree. The worktree lives at:
#     ~/git/.agent-worktrees/<task-gid>/<repo>/
# on a fresh branch `agent/<task-gid>` based on origin/develop (configurable).
# Works for ANY repo under ~/git (gui or a dependency), so one task can have several
# co-located worktrees that updot can sibling-link.
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
#   setup-task-workspace.sh --task-gid <gid> --repo <name> [--base <ref>]
#
#   --task-gid     REQUIRED. Asana task GID; namespaces the worktree + branch.
#   --repo         REQUIRED. Repo name under ~/git, e.g. edge-react-gui.
#   --base         Base ref for the new branch (default: origin/develop).
#
# Idempotent: if the worktree already exists it is reused (env.json copy re-ensured)
# and its path is returned without re-creating anything.
#
# Prints the worktree path on stdout, status on stderr.
#
# Exit codes:
#   0 = worktree ready (path on stdout)
#   1 = error (missing repo, worktree add failed)
#   2 = usage error

set -euo pipefail

CONFIG="$HOME/.config/agent-watcher/asana-config.json"
WORKTREES_ROOT="$HOME/git/.agent-worktrees"
REPOS_ROOT="$HOME/git"

TASK_GID=""
REPO=""
BASE=""        # empty = resolve per-repo below (prefer origin/develop, else the repo's default branch)
BRANCH_ARG=""  # explicit branch name; default is "$GIT_BRANCH_PREFIX/<gid>" (see below)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-gid)    TASK_GID="$2";    shift 2 ;;
    --repo)        REPO="$2";        shift 2 ;;
    --base)        BASE="$2";        shift 2 ;;
    --branch)      BRANCH_ARG="$2";  shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TASK_GID" && -n "$REPO" ]] || {
  echo "Usage: setup-task-workspace.sh --task-gid <gid> --repo <name> [--base <ref>] [--branch <name>]" >&2
  exit 2
}

MAIN_REPO="$REPOS_ROOT/$REPO"
[[ -d "$MAIN_REPO/.git" ]] || { echo "Repo not found or not a git repo: $MAIN_REPO" >&2; exit 1; }

# Resolve the base ref when not given on the CLI. Edge convention is `develop`;
# repos that don't use it (most deps/servers) fall back to their actual default
# branch (origin/HEAD), then origin/main, then origin/master.
if [[ -z "$BASE" ]]; then
  if git -C "$MAIN_REPO" rev-parse --verify --quiet "origin/develop" >/dev/null 2>&1; then
    BASE="origin/develop"
  else
    BASE="$(git -C "$MAIN_REPO" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/||')"
    if [[ -z "$BASE" ]]; then
      for cand in origin/main origin/master; do
        git -C "$MAIN_REPO" rev-parse --verify --quiet "$cand" >/dev/null 2>&1 && { BASE="$cand"; break; }
      done
    fi
  fi
  [[ -z "$BASE" ]] && BASE="origin/develop"   # last-resort
  echo ">> setup-task-workspace: base ref for $REPO → $BASE" >&2
fi

WT="$WORKTREES_ROOT/$TASK_GID/$REPO"
# Branch: explicit --branch wins (one-shot passes "$GIT_BRANCH_PREFIX/<short-name>");
# otherwise default to "$GIT_BRANCH_PREFIX/<gid>" (prefix defaults to "jon"), matching
# the /im convention instead of the opaque agent/<gid>.
BRANCH="${BRANCH_ARG:-${GIT_BRANCH_PREFIX:-jon}/$TASK_GID}"

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

# ── Materialize husky's generated runtime (.husky/_) from the main checkout ───
# node_modules is APFS-cloned but `husky install` never runs in the worktree, so
# .husky/_/husky.sh is missing and EVERY `git commit` fails (hooks resolve via the
# shared core.hooksPath=.husky against the worktree's checkout). That broken hook
# induced --no-verify workarounds in 6/8 failed agent-run evals on 2026-06-10.
# Best-effort: repos without husky (no .husky in main checkout) are skipped.
ensure_husky_runtime() {
  local src="$MAIN_REPO/.husky/_"
  local dst="$WT/.husky/_"
  [[ -d "$WT/.husky" ]] || return 0          # repo doesn't use husky
  [[ -d "$dst" ]] && return 0                # already materialized
  if [[ -d "$src" ]]; then
    if cp -cR "$src" "$dst" 2>/dev/null || cp -R "$src" "$dst" 2>/dev/null; then
      echo ">> setup-task-workspace: materialized .husky/_ from main checkout" >&2
    else
      echo ">> setup-task-workspace: WARN — .husky/_ copy failed; commits may need husky install" >&2
    fi
  else
    echo ">> setup-task-workspace: WARN — $src missing (husky not installed in main checkout?); commits will fail the pre-commit hook" >&2
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
    # Enforce the standard agent login: every new run starts on edge-funds (the
    # funded account), regardless of master env.json drift. YOLO auto-login
    # re-asserts this account on every app relaunch.
    node -e '
      const fs = require("fs"); const p = process.argv[1];
      const env = JSON.parse(fs.readFileSync(p, "utf8"));
      env.YOLO_USERNAME = "edge-funds"; env.YOLO_PIN = "0000";
      fs.writeFileSync(p, JSON.stringify(env, null, 2) + "\n");
    ' "$WT/env.json" 2>/dev/null \
      && echo ">> setup-task-workspace: env.json YOLO login pinned to edge-funds" >&2 \
      || echo ">> setup-task-workspace: WARN — could not pin YOLO login (env.json left as copied)" >&2
  else
    echo ">> setup-task-workspace: WARN — $MAIN_REPO/env.json not found; worktree has NO secrets" >&2
  fi
}

# ── Copy testconfig.json from the main checkout (same rm-then-copy pattern) ───
# edge-exchange-plugins keeps swap-partner API creds in gitignored testconfig.json;
# worktrees don't inherit gitignored files, so exch agents otherwise spawn with no
# creds. No-op for repos without one.
ensure_testconfig_json() {
  if [[ -f "$MAIN_REPO/testconfig.json" ]]; then
    rm -f "$WT/testconfig.json"
    cp "$MAIN_REPO/testconfig.json" "$WT/testconfig.json"
    echo ">> setup-task-workspace: copied testconfig.json ← $MAIN_REPO/testconfig.json" >&2
  fi
}

link_shared_memory() {
  # Surface shared Claude memory (orchestration + user context) for this task so
  # the spawned agent sees it. A worktree session reads auto-memory from the MAIN
  # repo's memory dir (verified empirically), and the helper resolves the worktree
  # path to that git-root dir, so passing "$WT" links the right place. Idempotent
  # and non-fatal — never blocks setup. Output → stderr so stdout stays just "$WT".
  local helper="$HOME/.claude/link-shared-memory.sh"
  if [[ -x "$helper" ]]; then
    "$helper" "$WT" >&2 || echo ">> setup-task-workspace: WARN — link-shared-memory failed (non-fatal)" >&2
  fi
}

# ── Idempotent reuse ──────────────────────────────────────────────────────────
if git -C "$MAIN_REPO" worktree list --porcelain | grep -qxF "worktree $WT"; then
  echo ">> setup-task-workspace: worktree already exists, reusing $WT" >&2
  ensure_env_json
  ensure_testconfig_json
  clone_node_modules
  ensure_husky_runtime
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

# ── Copy env.json from the main checkout (real file; survives `configure`) ─────
ensure_env_json

# ── Copy testconfig.json (swap-partner API creds) when the repo has one ────────
ensure_testconfig_json

# ── Clone node_modules from the main checkout ───────────────────────────────────
clone_node_modules

# ── Materialize husky runtime so worktree commits don't fail the pre-commit hook ─
ensure_husky_runtime

# ── Surface shared Claude memory in this worktree (non-fatal) ─────────────────
link_shared_memory

echo ">> setup-task-workspace: ready $WT (branch $BRANCH)" >&2
echo "$WT"
