#!/usr/bin/env bash
# pr-finalize-fixups.sh
# Shared post-fixup finalization for pr-address, bugbot, and any future skill
# that applies fixup commits to a PR branch.
#
# POLICY (single source of truth — do not duplicate in skill .md files):
#   Autosquash + force-push ONLY when the PR has no external human reviewers.
#   "External" = any commenter who is NOT the PR author, NOT the authenticated
#   user (currentUser), and NOT a bot. When external humans have commented,
#   they are actively reviewing and need to see the fixup commits, so we leave
#   the branch untouched after the initial push.
#
# Skill pre-conditions (caller's responsibility):
#   1. All fixup commits for this cycle are committed on HEAD.
#   2. HEAD has been pushed to origin (non-force) so replies citing fixup SHAs
#      resolve for reviewers.
#   3. Reply+resolve calls on threads referencing the fixup SHAs are done.
#      (Autosquash rewrites history; referenced SHAs become reachable only via
#      reflog after the force-push, which is fine for audit but cheap to avoid
#      regenerating reply links.)
#
# Usage:
#   pr-finalize-fixups.sh --owner <o> --repo <r> --pr <n> [--check-only]
#
# --check-only  Query the reviewer state, print the decision as JSON, but do
#               NOT run autosquash or force-push. Safe for testing the
#               decision logic in any working tree. Without this flag the
#               script WILL rewrite git history when no external human
#               reviewers are present.
#
# Output (stdout, one line of compact JSON):
#   Without --check-only:
#     {"autosquashed": true, "newHead": "abc1234567"}
#     {"autosquashed": false, "reason": "has external human reviewers", "reviewers": ["alice", "bob"]}
#   With --check-only:
#     {"wouldAutosquash": true, "reason": "no external human reviewers"}
#     {"wouldAutosquash": false, "reason": "has external human reviewers", "reviewers": ["alice", "bob"]}
#
# Exit codes:
#   0 — done (either autosquashed cleanly, deliberately skipped, or --check-only)
#   1 — generic error (malformed args, missing deps, rebase conflict, etc.)
#   2 — needs user input (gh not authenticated) — `PROMPT_GH_AUTH` on stderr

set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ADDRESS_SH="$SKILLS_DIR/pr-address/scripts/pr-address.sh"
GIT_BRANCH_OPS_SH="$SKILLS_DIR/git-branch-ops.sh"

OWNER="" REPO="" PR="" CHECK_ONLY="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --check-only) CHECK_ONLY="true"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$OWNER" || -z "$REPO" || -z "$PR" ]]; then
  echo "Usage: pr-finalize-fixups.sh --owner <o> --repo <r> --pr <n> [--check-only]" >&2
  exit 1
fi

if [[ ! -x "$PR_ADDRESS_SH" ]]; then
  echo "Error: pr-address.sh not found at $PR_ADDRESS_SH" >&2
  exit 1
fi

if [[ ! -x "$GIT_BRANCH_OPS_SH" ]]; then
  echo "Error: git-branch-ops.sh not found at $GIT_BRANCH_OPS_SH" >&2
  exit 1
fi

# Fetch reviewer state. pr-address.sh handles gh auth + pagination + filtering.
FETCH_JSON="$("$PR_ADDRESS_SH" fetch --owner "$OWNER" --repo "$REPO" --pr "$PR")"

# Extract the two fields we care about.
read -r HAS_HUMANS HUMAN_LIST < <(
  echo "$FETCH_JSON" | node -e "
    const d = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'))
    const has = d.hasHumanReviewers ? 'true' : 'false'
    const list = (d.humanReviewers || []).join(',')
    process.stdout.write(has + ' ' + (list || '-') + '\n')
  "
)

HUMAN_LIST_JSON=$(node -e "
  const list = process.argv[1] === '-' ? [] : process.argv[1].split(',')
  process.stdout.write(JSON.stringify(list))
" "$HUMAN_LIST")

if [[ "$HAS_HUMANS" == "true" ]]; then
  # Preserve fixup commits for human reviewers to inspect.
  KEY="autosquashed"
  [[ "$CHECK_ONLY" == "true" ]] && KEY="wouldAutosquash"
  node -e "process.stdout.write(JSON.stringify({
    ['$KEY']: false,
    reason: 'has external human reviewers',
    reviewers: $HUMAN_LIST_JSON
  }) + '\n')"
  exit 0
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
  node -e "process.stdout.write(JSON.stringify({
    wouldAutosquash: true,
    reason: 'no external human reviewers'
  }) + '\n')"
  exit 0
fi

# No external humans → autosquash + force-push-with-lease.
# git-branch-ops.sh autosquash rebases against origin/<default-branch>'s
# merge-base with HEAD. On conflict it exits non-zero and leaves the working
# tree mid-rebase; set -e propagates that so the caller can surface to the
# user. Do NOT force-push if autosquash failed.
"$GIT_BRANCH_OPS_SH" autosquash
"$GIT_BRANCH_OPS_SH" push --force-with-lease

NEW_HEAD="$(git rev-parse --short=10 HEAD)"
node -e "process.stdout.write(JSON.stringify({
  autosquashed: true,
  newHead: '$NEW_HEAD'
}) + '\n')"
