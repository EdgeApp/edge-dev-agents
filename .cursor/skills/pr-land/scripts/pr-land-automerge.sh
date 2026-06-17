#!/usr/bin/env bash
# pr-land-automerge.sh — DEFAULT land path: arm GitHub auto-merge (merge-commit) for
# each PR so GitHub merges it when required CI checks pass, instead of rebasing,
# verifying, and merging locally. GitHub owns the rebase/queue and the green-CI wait;
# the agent does not babysit the watch loop.
#
# Input (stdin JSON array): [{"repo":"edge-react-gui","prNumber":123}, ...]
#   (repo is "<name>" under EdgeApp, or "<owner>/<name>").
#
# Per PR, emits one result line to stdout:
#   armed     — auto-merge enabled; GitHub will merge on green CI
#   merged    — already merged (skip, idempotent re-run)
#   blocked   — not mergeable yet (review/changes-requested) — reported, not armed
#   unsupported — repo does not allow auto-merge / merge-commit; caller falls back
#                 to the local path (pr-land-merge.sh)
#   error     — other failure (message included)
#
# Exit: 0 if every PR is armed or already merged; 1 if any blocked/unsupported/error
# (so the caller knows to inspect / fall back). gh handles auth + API versioning.
set -uo pipefail

command -v gh >/dev/null || { echo "ERROR: gh not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 2; }

INPUT="$(cat)"
[ -n "$INPUT" ] || { echo "ERROR: no PR JSON on stdin" >&2; exit 2; }

RC=0
echo "$INPUT" | jq -c '.[]' | while read -r pr; do
  REPO=$(echo "$pr" | jq -r '.repo')
  NUM=$(echo "$pr" | jq -r '.prNumber')
  [[ "$REPO" == */* ]] || REPO="EdgeApp/$REPO"

  STATE=$(gh pr view "$NUM" --repo "$REPO" --json state,reviewDecision,mergeStateStatus 2>/dev/null || echo '')
  if [ -z "$STATE" ]; then echo "error   $REPO#$NUM — gh pr view failed"; RC=1; continue; fi
  PRSTATE=$(echo "$STATE" | jq -r '.state'); REVIEW=$(echo "$STATE" | jq -r '.reviewDecision')

  if [ "$PRSTATE" = "MERGED" ]; then echo "merged  $REPO#$NUM"; continue; fi
  if [ "$REVIEW" = "CHANGES_REQUESTED" ]; then echo "blocked $REPO#$NUM — changes requested; resolve before landing"; RC=1; continue; fi

  # Arm auto-merge with the merge-commit method. gh returns non-zero if the repo
  # disallows auto-merge or merge commits — surface that so the caller can fall back.
  ERR=$(gh pr merge "$NUM" --repo "$REPO" --auto --merge 2>&1)
  if [ $? -eq 0 ]; then
    echo "armed   $REPO#$NUM — auto-merge (merge commit) on green CI"
  elif echo "$ERR" | grep -qiE "already merged"; then
    echo "merged  $REPO#$NUM"
  elif echo "$ERR" | grep -qiE "auto.?merge is not allowed|does not allow|merge commits are not allowed|Protected branch"; then
    echo "unsupported $REPO#$NUM — $(echo "$ERR" | head -1) (fall back to pr-land-merge.sh)"; RC=1
  else
    echo "error   $REPO#$NUM — $(echo "$ERR" | head -1)"; RC=1
  fi
done

exit $RC
