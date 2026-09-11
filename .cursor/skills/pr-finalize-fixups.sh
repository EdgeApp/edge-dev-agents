#!/usr/bin/env bash
# pr-finalize-fixups.sh
# Shared post-fixup finalization for pr-address, bugbot, and any future skill
# that applies fixup commits to a PR branch.
#
# POLICY (single source of truth — do not duplicate in skill .md files):
#
#   Operator rewrite approval: in an orchestrated session (AGENT_TASK_GID set), a
#   non-empty /tmp/agent-history-rewrite-approved-<gid>.md (the agent's record of
#   an operator task comment approving a history rewrite under review) turns a
#   preserve verdict into autosquash for an OWNED PR. Same note git-history-gate.sh
#   honors; /eval-run audits it against the operator comment it cites.
#
#   Ownership guard (HARD override, checked first): if the authenticated gh user
#   is NOT the PR author (currentUser != prAuthor), mode is ALWAYS preserve and
#   squash-stale is a noop. We never autosquash or otherwise rewrite a PR we
#   don't own — fixups are left on top for the owner to squash at merge. This
#   takes precedence over the activity-based derivation below.
#
#   Modes — derived from the latest human activity on the PR (formal review,
#   inline comment, or top-level comment), ONLY when we own the PR. "Human" =
#   anyone except the currently authenticated gh user (currentUser) and bots.
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
#                   and slotted. Both modes first re-stamp a committed TDD that
#                   was EDITED since the remote head (tdd-stamp.sh --fold: the
#                   stamp asserts the doc was re-read against this tree, so an
#                   unedited stale doc is left for the Complete gate to bounce).
#                   In autosquash mode → autosquash + force-push.
#                   In preserve mode → condense (git-branch-ops.sh
#                   condense-fixups: one fixup! per target commit, bodies
#                   concatenated, targets untouched) + force-with-lease push.
#                   However many bot rounds a review turn takes, the reviewer
#                   sees one delta per target.
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
#     {"action": "autosquash" | "push" | "noop", "mode": "...", "newHead": "...", "reason": "...",
#      "condensed": N (preserve push: fixup commits folded away), "stamped": true|false (TDD re-stamped)}
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
# Ownership flag from review-mode. When false (we are not the PR author),
# history must never be rewritten — review-mode already forces MODE=preserve,
# and squash-stale becomes a hard noop below.
IS_OWNER=$(echo "$MODE_JSON" | node -e "
  const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'))
  process.stdout.write(String(d.isOwner === true))
")

REWRITE_OK="/tmp/agent-history-rewrite-approved-${AGENT_TASK_GID:-none}.md"
if [[ "$MODE" == "preserve" && "$IS_OWNER" == "true" && -n "${AGENT_TASK_GID:-}" && -s "$REWRITE_OK" ]]; then
  echo ">> pr-finalize-fixups: preserve -> autosquash by operator rewrite approval ($REWRITE_OK)" >&2
  MODE="autosquash"
fi

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

TDD_STAMPED="false"
CONDENSED=0

# Re-stamp a committed TDD (src/docs/*.md on the branch) when its stamp is stale
# AND the doc text (minus the stamp line) changed since the remote head, or has
# never been pushed. An unedited stale doc is deliberately NOT stamped: the stamp
# means "re-read against this tree", which only the run can do.
stamp_tdd_if_edited() {
  local stamp_sh="$SKILLS_DIR/tdd/scripts/tdd-stamp.sh" doc branch head_doc remote_doc
  [[ -x "$stamp_sh" && -n "$MERGE_BASE" ]] || return 0
  doc="$(git diff --name-only "$MERGE_BASE..HEAD" -- 'src/docs/*.md' 2>/dev/null | head -1)"
  [[ -n "$doc" ]] && git cat-file -e "HEAD:$doc" 2>/dev/null || return 0
  "$stamp_sh" . "$doc" --check >/dev/null 2>&1 && return 0
  branch="$(git branch --show-current)"
  if git cat-file -e "origin/$branch:$doc" 2>/dev/null; then
    head_doc="$(git show "HEAD:$doc" | grep -v 'tdd-code-fingerprint:' || true)"
    remote_doc="$(git show "origin/$branch:$doc" | grep -v 'tdd-code-fingerprint:' || true)"
    if [[ "$head_doc" == "$remote_doc" ]]; then
      echo ">> pr-finalize-fixups: $doc stamp is stale and the doc was not edited since origin/$branch; not re-stamping (the Complete gate wants it re-read: tdd doc-rides-the-first-commit)" >&2
      return 0
    fi
  fi
  "$stamp_sh" . "$doc" --fold >&2 || return 1
  TDD_STAMPED="true"
}

run_autosquash_and_push() {
  "$GIT_BRANCH_OPS_SH" autosquash >&2
  "$GIT_BRANCH_OPS_SH" push --force-with-lease >&2
  emit_json "{action: '$(prefix_action autosquash)', mode: '$MODE', newHead: '$(git rev-parse --short=10 HEAD)', stamped: $TDD_STAMPED}"
}

run_condense_and_push() {
  local plan
  plan="$("$GIT_BRANCH_OPS_SH" condense-fixups --base "$MERGE_BASE")" || exit 1
  CONDENSED="$(printf '%s' "$plan" | jq -r '.condensed // 0')"
  # Force-with-lease because per-fixup slotting and the condense rewrote tip.
  "$GIT_BRANCH_OPS_SH" push --force-with-lease >&2
  emit_json "{action: '$(prefix_action push)', mode: '$MODE', newHead: '$(git rev-parse --short=10 HEAD)', condensed: $CONDENSED, stamped: $TDD_STAMPED}"
}

emit_noop() {
  local reason="$1"
  emit_json "{action: '$(prefix_action noop)', mode: '$MODE', reason: '$reason'}"
}

if [[ "$SUBCMD" == "squash-stale" ]]; then
  # Ownership guard: never squash/rewrite history on a PR we don't own, even if
  # the timestamp heuristic below would otherwise fire in preserve mode.
  if [[ "$IS_OWNER" != "true" ]]; then
    emit_noop "not PR owner — never rewrite owner history"
    exit 0
  fi
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
# The "&& IS_OWNER" is belt-and-suspenders: review-mode already forces preserve
# when we don't own the PR, so a non-owner can never reach the autosquash path.
if [[ "$MODE" == "autosquash" && "$IS_OWNER" == "true" ]]; then
  if [[ "$CHECK_ONLY" == "true" ]]; then
    emit_json "{action: '$(prefix_action autosquash)', mode: '$MODE', reason: 'no active reviewer'}"
    exit 0
  fi
  # Same check git-history-gate.sh applies to a raw push: a non-fixup commit
  # that rewrites lines already on the remote branch must be folded before the
  # push (git-branch-ops.sh self-rewrite owns the rule and the remediation).
  # Runs BEFORE the autosquash so fixup! commits, the compliant shape, are still
  # distinguishable from standalone rewrites.
  if ! "$GIT_BRANCH_OPS_SH" self-rewrite --gate >/dev/null; then
    exit 1
  fi
  stamp_tdd_if_edited || exit 1
  run_autosquash_and_push
  exit 0
fi

# preserve mode
if [[ "$CHECK_ONLY" == "true" ]]; then
  emit_json "{action: '$(prefix_action push)', mode: '$MODE', reason: 'reviewer still active; preserving fixups, condensed to one per target'}"
  exit 0
fi

stamp_tdd_if_edited || exit 1
run_condense_and_push
