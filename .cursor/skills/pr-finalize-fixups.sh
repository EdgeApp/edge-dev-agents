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
#   preserve verdict into autosquash for an OWNED PR — but only when the note
#   says `Targets: all`. The autosquash below is WHOLE-BRANCH, so a note naming
#   specific commits (or the legacy note with no `Targets:` line) approves only
#   a one-fixup fold (lint-commit.sh --fixup, git-branch-ops.sh fold-one) and
#   leaves this path in preserve: condense + push, reviewer's delta intact.
#   Same note and same parse (git-branch-ops.sh note-scope) git-history-gate.sh
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
#     squash-stale  Run BEFORE adding new fixups in the address-pass. LOCAL
#                   ONLY: it never pushes (one push per review round, and that
#                   push is finalize's). In autosquash mode it autosquashes the
#                   whole branch. In preserve mode it folds exactly the fixups
#                   AUTHORED before the latest human activity (the reviewer has
#                   read them) into their targets (git-branch-ops.sh
#                   fold-before) and leaves newer fixups visible. Author date,
#                   never committer date: every rebase and slot resets %cI, so
#                   a committer timestamp makes an already-reviewed fixup look
#                   new and the fold never fires. When it reports a non-noop
#                   action, finalize must run this round even if no new fixup
#                   was made, or the rewrite never reaches the remote.
#
#     finalize      (default subcommand) Run AFTER all new fixups are committed
#                   and slotted. Both modes first re-stamp a committed TDD that
#                   was EDITED since the remote head (tdd-stamp.sh --fold: the
#                   stamp asserts the doc was re-read against this tree, so an
#                   unedited stale doc is left for the Complete gate to bounce).
#                   In autosquash mode → autosquash + force-push.
#                   In preserve mode → the same stale fold squash-stale does
#                   (so a skipped or failed step 1.5 heals here), then condense
#                   (git-branch-ops.sh condense-fixups: one fixup! per target
#                   and kind, bodies concatenated, targets untouched) +
#                   force-with-lease push. However many bot rounds a review
#                   turn takes, the reviewer sees at most one human and one
#                   auto delta per target.
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
#     {"action": "autosquash" | "fold" | "push" | "noop", "mode": "...", "newHead": "...", "reason": "...",
#      "folded": N (stale fixups folded into their targets), "condensed": N (preserve push:
#      fixup commits folded away), "stamped": true|false (TDD re-stamped)}
#   squash-stale reports "autosquash" (autosquash mode) or "fold" (preserve mode), never "push".
#   With --check-only the action becomes "wouldAutosquash" / "wouldFold" / "wouldPush" / "wouldNoop".
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
      fold) echo "wouldFold" ;;
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
  if "$GIT_BRANCH_OPS_SH" note-scope --note "$REWRITE_OK" 2>/dev/null | grep -qx 'all'; then
    echo ">> pr-finalize-fixups: preserve -> autosquash by operator rewrite approval ($REWRITE_OK says Targets: all)" >&2
    MODE="autosquash"
  else
    echo ">> pr-finalize-fixups: $REWRITE_OK does not say 'Targets: all', so it does not approve a whole-branch autosquash; staying in preserve (condense + push). Fold an approved target with git-branch-ops.sh fold-one." >&2
  fi
fi

DEFAULT_UPSTREAM="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
  || echo "origin/$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p')" \
  || echo "origin/master")"
[[ -z "$DEFAULT_UPSTREAM" || "$DEFAULT_UPSTREAM" == "origin/" ]] && DEFAULT_UPSTREAM="origin/master"
MERGE_BASE="$(git merge-base "$DEFAULT_UPSTREAM" HEAD 2>/dev/null || true)"

# Capture before grepping: under pipefail, `git log | grep -q` dies of SIGPIPE
# once grep exits on the first match, which reads as "no fixups".
HAS_FIXUPS="false"
BRANCH_SUBJECTS="$([[ -n "$MERGE_BASE" ]] && git log "$MERGE_BASE..HEAD" --format='%s' || true)"
if grep -q '^fixup! ' <<<"$BRANCH_SUBJECTS"; then
  HAS_FIXUPS="true"
fi

TDD_STAMPED="false"
CONDENSED=0
FOLDED=0

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

# Fold the fixups the reviewer already read (authored before the latest human
# activity) into their targets. Local only. Sets FOLDED.
fold_stale_fixups() {
  local plan
  [[ -n "$LATEST_TS" && -n "$MERGE_BASE" && "$HAS_FIXUPS" == "true" ]] || return 0
  plan="$("$GIT_BRANCH_OPS_SH" fold-before --before "$LATEST_TS" --base "$MERGE_BASE")" || return 1
  FOLDED="$(printf '%s' "$plan" | jq -r '.folded // 0')"
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
  emit_json "{action: '$(prefix_action push)', mode: '$MODE', newHead: '$(git rev-parse --short=10 HEAD)', folded: $FOLDED, condensed: $CONDENSED, stamped: $TDD_STAMPED}"
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
  if [[ "$HAS_FIXUPS" != "true" ]]; then
    emit_noop "no existing fixups"
    exit 0
  fi

  if [[ "$MODE" == "autosquash" ]]; then
    if [[ "$CHECK_ONLY" == "true" ]]; then
      emit_json "{action: '$(prefix_action autosquash)', mode: '$MODE', reason: 'no active reviewer'}"
      exit 0
    fi
    "$GIT_BRANCH_OPS_SH" autosquash >&2
    emit_json "{action: 'autosquash', mode: '$MODE', newHead: '$(git rev-parse --short=10 HEAD)', reason: 'no active reviewer; local only, finalize pushes'}"
    exit 0
  fi

  if [[ -z "$LATEST_TS" ]]; then
    emit_noop "no human activity to date the fixups against"
    exit 0
  fi
  if [[ "$CHECK_ONLY" == "true" ]]; then
    emit_json "{action: '$(prefix_action fold)', mode: '$MODE', reason: 'fold fixups authored before $LATEST_TS'}"
    exit 0
  fi
  fold_stale_fixups || exit 1
  if [[ "$FOLDED" == "0" ]]; then
    emit_noop "every existing fixup postdates the latest review ($LATEST_TS)"
    exit 0
  fi
  emit_json "{action: 'fold', mode: '$MODE', newHead: '$(git rev-parse --short=10 HEAD)', folded: $FOLDED, reason: 'fixups authored before $LATEST_TS folded; local only, finalize pushes'}"
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

# Only on an owned PR: a non-owner never rewrites history, not even a fold.
if [[ "$IS_OWNER" == "true" ]]; then
  fold_stale_fixups || exit 1
fi
stamp_tdd_if_edited || exit 1
run_condense_and_push
