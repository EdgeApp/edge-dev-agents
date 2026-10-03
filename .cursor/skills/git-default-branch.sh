#!/usr/bin/env bash
# git-default-branch.sh: the ONE answer to "what is this repo's default branch"
# (what a new PR targets, and the base a feature branch is measured from).
# Every script that needs it calls this instead of keeping its own fallback
# chain; the copies had drifted to different defaults (origin/master in some,
# origin/develop in others), so the same repo could resolve two ways.
#
# Order:
#   1. origin/HEAD as recorded in the clone
#   2. ask the remote once (`git remote set-head origin --auto`), which also
#      records origin/HEAD so the next call is local
#   3. offline: the first of origin/main, origin/master, origin/develop that
#      exists (develop last: a stale origin/develop in a master-default repo
#      inflates every diff measured from it)
#
# Usage: git-default-branch.sh [-C <repo-dir>] [--short]
# stdout: origin/<branch>, or <branch> with --short
# Exit: 0 resolved; 1 nothing resolvable (not a repo, no origin refs)
set -uo pipefail

DIR="."; SHORT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C) DIR="$2"; shift 2 ;;
    --short) SHORT=true; shift ;;
    *) echo "usage: git-default-branch.sh [-C <repo-dir>] [--short]" >&2; exit 2 ;;
  esac
done

ref=$(git -C "$DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
if [[ -z "$ref" ]]; then
  git -C "$DIR" remote set-head origin --auto >/dev/null 2>&1 || true
  ref=$(git -C "$DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
fi
if [[ -z "$ref" ]]; then
  for b in main master develop; do
    git -C "$DIR" rev-parse --verify -q "refs/remotes/origin/$b" >/dev/null 2>&1 && { ref="origin/$b"; break; }
  done
fi
[[ -n "$ref" && "$ref" != "origin/" ]] || exit 1
if $SHORT; then printf '%s\n' "${ref#origin/}"; else printf '%s\n' "$ref"; fi
