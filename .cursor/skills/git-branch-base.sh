#!/usr/bin/env bash
# git-branch-base.sh: the ONE answer to "what ref is THIS branch measured from"
# (the base of its commit range: first-commit lookup, fixup targets, autosquash,
# doc fingerprints). Distinct from git-default-branch.sh, which answers what a
# NEW PR targets. The two agree on an ordinary branch and differ on a stacked
# one: a branch whose PR targets another feature branch is measured from that
# branch, and measuring it from the default branch pulls the parent branch's
# commits into the range, so a fold or autosquash lands in someone else's commit.
#
# Order:
#   1. the base of the current branch's OPEN PR (gh, 10 s cap), fetched when the
#      clone has no origin/<base> yet
#   2. git-default-branch.sh (no PR, detached HEAD, gh missing or offline)
#
# Usage: git-branch-base.sh [-C <repo-dir>] [--short]
# stdout: origin/<branch>, or <branch> with --short
# Exit: 0 resolved; 1 nothing resolvable; 2 usage
set -uo pipefail

DIR="."; SHORT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C) DIR="$2"; shift 2 ;;
    --short) SHORT=true; shift ;;
    *) echo "usage: git-branch-base.sh [-C <repo-dir>] [--short]" >&2; exit 2 ;;
  esac
done

ref=""
cur=$(git -C "$DIR" branch --show-current 2>/dev/null || true)
if [[ -n "$cur" ]] && command -v gh >/dev/null 2>&1; then
  base=$(cd "$DIR" 2>/dev/null && perl -e 'alarm shift; exec @ARGV' 10 \
    gh pr view "$cur" --json baseRefName,state \
    -q 'select(.state == "OPEN") | .baseRefName' 2>/dev/null || true)
  if [[ -n "$base" && "$base" != "$cur" ]]; then
    git -C "$DIR" rev-parse --verify -q "refs/remotes/origin/$base" >/dev/null 2>&1 \
      || git -C "$DIR" fetch -q origin "$base:refs/remotes/origin/$base" >/dev/null 2>&1 || true
    git -C "$DIR" rev-parse --verify -q "refs/remotes/origin/$base" >/dev/null 2>&1 && ref="origin/$base"
  fi
fi
if [[ -z "$ref" ]]; then
  ref=$("$HOME/.cursor/skills/git-default-branch.sh" -C "$DIR" 2>/dev/null || true)
fi
[[ -n "$ref" ]] || exit 1
if $SHORT; then printf '%s\n' "${ref#origin/}"; else printf '%s\n' "$ref"; fi
