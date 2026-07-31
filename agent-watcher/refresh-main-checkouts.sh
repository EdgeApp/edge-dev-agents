#!/usr/bin/env bash
# refresh-main-checkouts.sh — keep the ~/git main checkouts (the APFS-clone
# SOURCES for every agent worktree's node_modules) current with origin.
#
# Why: setup-task-workspace.sh clones node_modules from these checkouts. They
# had NO refresh mechanism (only the GUI gets one via refresh-master-build), so
# a checkout that fell behind poisoned every worktree spawned from it — accb
# sat 64 commits behind with stellar-sdk 0.11.0 in node_modules, which is how
# the 2026-07-30 fleet-wide "Horizon.Server undefined" toast got baked into
# locally-built WebView bundles.
#
# SAFE BY CONSTRUCTION: a checkout is touched ONLY when it is (a) clean (no
# staged/unstaged/untracked changes) AND (b) on its default branch. Dirty or
# feature-branch checkouts are reported and left alone — never stash, never
# switch, never stomp operator work. npm ci runs only when the pull changed
# package-lock.json (that's when the existing node_modules became wrong).
#
# Usage:
#   refresh-main-checkouts.sh [--dry-run] [repo ...]
# Default repo set: the GUI-dependency repos + the GUI itself.
# Exit: 0 always (per-repo outcomes in the report; this is maintenance, not a gate).
set -uo pipefail

DRY=false
REPOS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=true ;;
    *) REPOS+=("$a") ;;
  esac
done
[[ ${#REPOS[@]} -gt 0 ]] || REPOS=(edge-currency-accountbased edge-exchange-plugins edge-core-js edge-currency-plugins edge-login-ui-rn edge-react-gui)

for r in "${REPOS[@]}"; do
  d="$HOME/git/$r"
  [[ -d "$d/.git" ]] || { echo "$r: SKIP (no checkout)"; continue; }
  cd "$d" || continue
  git fetch origin --quiet 2>/dev/null || { echo "$r: SKIP (fetch failed — offline?)"; continue; }
  def=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')
  def=${def:-master}
  cur=$(git branch --show-current)
  behind=$(git rev-list --count "HEAD..origin/$def" 2>/dev/null || echo '?')
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "$r: HOLD (dirty; on $cur; behind origin/$def by $behind) — resolve manually"
    continue
  fi
  if [[ "$cur" != "$def" ]]; then
    echo "$r: HOLD (on branch '$cur', not $def; behind origin/$def by $behind) — switch manually when done"
    continue
  fi
  if [[ "$behind" == "0" ]]; then
    echo "$r: OK (current)"
    continue
  fi
  if $DRY; then
    echo "$r: WOULD fast-forward $def by $behind commits$(git diff --quiet "HEAD" "origin/$def" -- package-lock.json 2>/dev/null || echo ' + npm ci (lockfile changed)')"
    continue
  fi
  lock_before=$(git rev-parse "HEAD:package-lock.json" 2>/dev/null || true)
  if ! git merge --ff-only "origin/$def" --quiet; then
    echo "$r: HOLD (ff-only merge failed — diverged history) — resolve manually"
    continue
  fi
  lock_after=$(git rev-parse "HEAD:package-lock.json" 2>/dev/null || true)
  did_ci=""
  if [[ "$lock_before" != "$lock_after" ]]; then
    if sfw npm ci --no-audit --no-fund >/tmp/refresh-ci-$r.log 2>&1; then
      did_ci=" + npm ci OK"
    else
      did_ci=" + npm ci FAILED (see /tmp/refresh-ci-$r.log) — node_modules now stale vs lockfile"
    fi
  fi
  echo "$r: FF'd $def by $behind commits$did_ci"
done
