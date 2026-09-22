#!/usr/bin/env bash
# develop-buildable.sh — Is the base branch a PR would land on known to be unbuildable?
#
# refresh-master-build.sh memoizes a develop commit that failed to build as
# `failed_sha` in master-build.json (see its FAILURE MEMO header). Landing more
# PRs on that commit is wrong three ways: the PR was sim-verified against the
# last-good master, not the tip it lands on; every land moves develop's SHA,
# which clears the memo and buys another full doomed rebuild on the next spawn
# tick; and the broken range grows. pr-land-prepare.sh calls this before the
# rebase and skips the PR on exit 3.
#
# Only the repo the master is built from (.watcher.default_repo) is ever gated;
# any other repo exits 0 without touching git.
#
# Usage: develop-buildable.sh --repo <name> [--ref <ref>]
#   --repo   repo name under ~/git
#   --ref    the base ref to check (default: origin/develop); fetched first
#
# Exit codes:
#   0 = buildable, or the repo is not the master's repo, or no memo exists
#   3 = the ref's HEAD equals the memoized failed_sha (stderr names both SHAs)
#   2 = usage error
set -euo pipefail

CONFIG="$HOME/.config/agent-watcher/asana-config.json"
MARKER="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/master-build.json"

REPO=""; REF="origin/develop"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --ref)  REF="$2";  shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$REPO" ]] || { echo "Usage: develop-buildable.sh --repo <name> [--ref <ref>]" >&2; exit 2; }

MASTER_REPO="$(jq -r '.watcher.default_repo // empty' "$CONFIG" 2>/dev/null || true)"
[[ "$REPO" == "$MASTER_REPO" ]] || exit 0
[[ -f "$MARKER" ]] || exit 0
FAILED_SHA="$(jq -r '.failed_sha // empty' "$MARKER" 2>/dev/null || true)"
[[ -n "$FAILED_SHA" ]] || exit 0

REPO_DIR="$HOME/git/$REPO"
[[ -d "$REPO_DIR/.git" ]] || exit 0
REMOTE="${REF%%/*}"; BRANCH="${REF#*/}"
git -C "$REPO_DIR" fetch --quiet "$REMOTE" "$BRANCH" 2>/dev/null || true
HEAD_SHA="$(git -C "$REPO_DIR" rev-parse --verify --quiet "$REF" 2>/dev/null || true)"
[[ -n "$HEAD_SHA" ]] || exit 0

if [[ "$HEAD_SHA" == "$FAILED_SHA" ]]; then
  GOOD_SHA="$(jq -r '.develop_sha // empty' "$MARKER" 2>/dev/null || true)"
  echo "develop-buildable: $REF (${HEAD_SHA:0:9}) is memoized as unbuildable (last-good master: ${GOOD_SHA:0:9}); land the fix first, or pass --allow-broken-develop to pr-land-prepare when this PR IS the fix" >&2
  exit 3
fi
exit 0
