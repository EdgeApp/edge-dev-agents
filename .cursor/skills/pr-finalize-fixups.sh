#!/usr/bin/env bash
# pr-finalize-fixups.sh
# Shared post-fixup finalization for pr-address, bugbot, and any future skill
# that applies fixup commits to a PR branch.
#
# POLICY (single source of truth — do not duplicate in skill .md files):
#
#   Modes — derived from the latest human activity on the PR (formal review,
#   inline comment, or top-level comment). "Human" = anyone except the
#   currently authenticated gh user (currentUser) and bots. The GitHub PR
#   "author" gets no special treatment — in solo PRs (currentUser == prAuthor)
#   the currentUser exclusion already covers them; in collab PRs they're a
#   peer reviewer like anyone else.
#     - autosquash : no human activity yet, OR latest activity is a review
#                    with state APPROVED or DISMISSED (reviewer is no longer
#                    actively reviewing).
#     - preserve   : latest activity is anything else (CHANGES_REQUESTED,
#                    COMMENTED, inline-comment-without-formal-submit, or
#                    top-level PR comment). Reviewer is still looking and
#                    needs to see fixup commits.
#
#   Subcommands:
#     squash-stale  Run BEFORE adding new fixups in the address-pass. Squashes
#                   any pre-existing fixups (Fixups A) when (a) mode is
#                   autosquash, or (b) mode is preserve AND the latest human
#                   activity timestamp is newer than the latest existing fixup
#                   commit timestamp (the reviewer has seen Fixups A and
#                   re-reviewed → start fresh on Fixups B). No-op otherwise.
#
#     finalize      (default subcommand) Run AFTER all new fixups are committed
#                   and slotted. In autosquash mode → autosquash + force-push.
#                   In preserve mode → just push (force-with-lease since the
#                   per-fixup slotting rewrote tip).
#
#   Skill pre-conditions (caller's responsibility):
#     - All fixup commits for this cycle are committed on HEAD and slotted next
#       to their target groups (via slot-fixup.sh).
#     - Reply+resolve calls referencing fixup SHAs come AFTER finalize so they
#       cite stable post-rewrite SHAs.
#
# Usage:
#   pr-finalize-fixups.sh [finalize] --owner <o> --repo <r> --pr <n> [--check-only]
#   pr-finalize-fixups.sh squash-stale --owner <o> --repo <r> --pr <n> [--check-only]
#
# --check-only  Print the decision as JSON without modifying git history.
#
# Output (stdout, one line of compact JSON):
#   finalize / squash-stale shared schema:
#     {"action": "autosquash" | "push" | "noop", "mode": "...", "newHead": "...", "reason": "..."}
#   With --check-only the action becomes "wouldAutosquash" / "wouldPush" / "wouldNoop".
#
# Exit codes:
#   0 — done (action completed, deliberately skipped, or --check-only)
#   1 — generic error (malformed args, missing deps, rebase conflict, etc.)
#   2 — needs user input (gh not authenticated) — `PROMPT_GH_AUTH` on stderr

set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ADDRESS_SH="$SKILLS_DIR/pr-address/scripts/pr-address.sh"
GIT_BRANCH_OPS_SH="$SKILLS_DIR/git-branch-ops.sh"

SUBCMD="finalize"
case "${1:-}" in
  finalize|squash-stale)
    SUBCMD="$1"; shift
    ;;
esac

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
  echo "Usage: pr-finalize-fixups.sh [finalize|squash-stale] --owner <o> --repo <r> --pr <n> [--check-only]" >&2
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

emit_json() {
  node -e "process.stdout.write(JSON.stringify($1) + '\n')"
}

prefix_action() {
  local action="$1"
  if [[ "$CHECK_ONLY" == "true" ]]; then
    case "$action" in
      autosquash) echo "wouldAutosquash" ;;
      push) echo "wouldPush" ;;
      noop) echo "wouldNoop" ;;
      *) echo "$action" ;;
    esac
  else
    echo "$action"
  fi
}

# Determine mode + latest human activity timestamp.
MODE_JSON="$("$PR_ADDRESS_SH" review-mode --owner "$OWNER" --repo "$REPO" --pr "$PR")"
MODE=$(echo "$MODE_JSON" | node -e "
  const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'))
  process.stdout.write(d.mode)
")
LATEST_TS=$(echo "$MODE_JSON" | node -e "
  const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'))
  process.stdout.write(d.latestHumanActivity?.timestamp || '')
")

# Find latest existing fixup commit's timestamp on this branch (if any).
DEFAULT_UPSTREAM="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
  || echo "origin/$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p')" \
  || echo "origin/master")"
[[ -z "$DEFAULT_UPSTREAM" || "$DEFAULT_UPSTREAM" == "origin/" ]] && DEFAULT_UPSTREAM="origin/master"
MERGE_BASE="$(git merge-base "$DEFAULT_UPSTREAM" HEAD 2>/dev/null || true)"

if [[ -n "$MERGE_BASE" ]]; then
  LATEST_FIXUP_TS=$(git log "$MERGE_BASE..HEAD" --format='%cI %s' \
    | awk '/^[^ ]+ fixup! / { print $1; exit }')
else
  LATEST_FIXUP_TS=""
fi

run_autosquash_and_push() {
  "$GIT_BRANCH_OPS_SH" autosquash >&2
  "$GIT_BRANCH_OPS_SH" push --force-with-lease >&2
  emit_json "{action: '$(prefix_action autosquash)', mode: '$MODE', newHead: '$(git rev-parse --short=10 HEAD)'}"
}

run_push_only() {
  # Force-with-lease because per-fixup slotting may have rewritten tip.
  "$GIT_BRANCH_OPS_SH" push --force-with-lease >&2
  emit_json "{action: '$(prefix_action push)', mode: '$MODE', newHead: '$(git rev-parse --short=10 HEAD)'}"
}

emit_noop() {
  local reason="$1"
  emit_json "{action: '$(prefix_action noop)', mode: '$MODE', reason: '$reason'}"
}

if [[ "$SUBCMD" == "squash-stale" ]]; then
  if [[ -z "$LATEST_FIXUP_TS" ]]; then
    emit_noop "no existing fixups"
    exit 0
  fi

  SHOULD_SQUASH="false"
  if [[ "$MODE" == "autosquash" ]]; then
    SHOULD_SQUASH="true"
  elif [[ -n "$LATEST_TS" ]] && [[ "$LATEST_TS" > "$LATEST_FIXUP_TS" ]]; then
    SHOULD_SQUASH="true"
  fi

  if [[ "$SHOULD_SQUASH" != "true" ]]; then
    emit_noop "existing fixups still relevant for current review cycle"
    exit 0
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    emit_json "{action: '$(prefix_action autosquash)', mode: '$MODE', reason: 'stale fixups predate latest review'}"
    exit 0
  fi

  run_autosquash_and_push
  exit 0
fi

# finalize subcommand
if [[ "$MODE" == "autosquash" ]]; then
  if [[ "$CHECK_ONLY" == "true" ]]; then
    emit_json "{action: '$(prefix_action autosquash)', mode: '$MODE', reason: 'no active reviewer'}"
    exit 0
  fi
  run_autosquash_and_push
  exit 0
fi

# preserve mode
if [[ "$CHECK_ONLY" == "true" ]]; then
  emit_json "{action: '$(prefix_action push)', mode: '$MODE', reason: 'reviewer still active — preserving fixups'}"
  exit 0
fi

run_push_only
