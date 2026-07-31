#!/usr/bin/env bash
# watch-pr.sh — single bounded `gh pr checks --watch` call against a shared
# per-task 30-minute deadline. Owns the budget arithmetic that one-shot's
# pr-watch-bounded-poll rule used to spell out in prose.
#
# First call for a task computes deadline = now + budget and persists it; every
# subsequent call bounds its watch by the remaining budget. One blocking call per
# invocation. No loops, no respawned processes (never-self-respawn).
#
# SLOW-CI CARVE-OUT (2026-07-24): the Travis check is non-blocking WHILE PENDING.
# Travis runs 9-13 min but queues 40-90 min under contention (shared account
# concurrency + develop/staging push builds), and this watch fires after EVERY
# force-push — each bot-fix cycle re-waited the whole queue, and queue time alone
# could exhaust the 30-min budget into a spurious blocked=Yes. The watch now goes
# green once every OTHER check passes; a pending Travis is reported, a FAILED
# Travis still exits 1 (red is signal, queued is not). Landing paths are
# unaffected: pr-land's auto-merge + BLOCKED_ON_REVIEW require full green.
#
# WIP-GUARD CLASSIFICATION (2026-07-28): a red `block-wip-pr` is EXPECTED
# BY DESIGN while the branch carries fixup! commits under an active human
# review — pr-address's preserve mode REQUIRES those commits to stay, so the
# check cannot go green until the review resolves and the fixups legitimately
# squash. Presenting it as a plain failure created a contract contradiction
# that a run resolved by autosquashing mid-review (swapter PR #475). The
# classifier consults the SAME oracle the squash decision uses
# (pr-address.sh review-mode): mode=preserve + fixups present -> expected;
# mode=autosquash -> the red is actionable (squash via pr-finalize-fixups.sh).
#
# Usage: watch-pr.sh --pr <num> [--repo <owner/name>] [--task-gid <gid>]
#                    [--budget-seconds 1800] [--interval 30]
# Exit: 0   green — final stdout line distinguishes:
#             RESULT: green                   (everything passed, Travis included)
#             RESULT: green-travis-pending    (all but Travis passed; Travis
#                                              queued/running — report its state
#                                              in the Finalize Gate checklist)
#             Any RESULT may carry a ` reviewer-unavailable:<name>` suffix,
#             meaning that reviewer posted NO check-run on a HEAD whose other
#             checks all completed. Proceed; record it as an unchecked box in
#             the report's Finalize Gate rather than claiming reviewer-clean.
#             RESULT: green-wip-preserve      (all passed except the wip-guard
#                                              check, red only because preserved
#                                              fixup commits are on the branch
#                                              during an active review — never
#                                              squash to clear it; it goes green
#                                              at finalize when pr-finalize-fixups
#                                              legitimately squashes)
#       1   a check failed, Travis included (read `gh run view --log-failed`, fix)
#       75  budget already exhausted — stop watching, take the blocked=Yes path
#       124 this watch hit the remaining-budget timeout (same: budget is gone)
#       2   usage error / missing tool
set -euo pipefail

PR="" REPO="" TASK_GID="" BUDGET=1800 INTERVAL=30
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --task-gid) TASK_GID="$2"; shift 2 ;;
    --budget-seconds) BUDGET="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) echo "usage: watch-pr.sh --pr <num> [--repo <owner/name>] [--task-gid <gid>] [--budget-seconds N] [--interval N]" >&2; exit 2 ;;
  esac
done
[ -n "$PR" ] || { echo "usage: watch-pr.sh --pr <num> ..." >&2; exit 2; }
command -v gh >/dev/null || { echo "ERROR: gh not found" >&2; exit 2; }
# Without --repo, gh resolves the repo from cwd; from ~/git (not a repo) it prints
# "fatal: not a git repository" and the watch silently no-ops. Fail loudly instead.
if [ -z "$REPO" ] && ! git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not in a git repo and no --repo given — pass --repo <owner/name> or run from the PR's worktree" >&2
  exit 2
fi
# Make the target repo EXPLICIT — never rely on gh's silent cwd inference. Run from
# the WRONG worktree and gh would resolve a same-numbered PR in a different repo (or
# "no checks") and the watch could read as green. If --repo was not passed, resolve
# it from the cwd repo and LOG it, so a wrong-worktree cwd surfaces in the output
# instead of silently watching the wrong PR.
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  [ -n "$REPO" ] && echo ">> watch-pr: no --repo given; resolved '$REPO' from cwd ($(basename "$PWD"))" >&2
fi
command -v timeout >/dev/null || { echo "ERROR: timeout not on PATH (shim: ~/.cursor/skills/timeout.sh)" >&2; exit 2; }

# Deadline is per task (falls back to per PR for ad-hoc use), shared across calls
# WITHIN a run. A prior run of the same task leaves this file behind, so a re-run
# would inherit a days-old deadline and falsely report "budget exhausted" on its
# first call. Guard on the file's age: a legitimately live deadline is at most
# BUDGET seconds old (the first call stamped it now+BUDGET); if the file is older
# than BUDGET, it is a stale carryover from a prior run — discard and re-stamp.
DEADLINE_FILE="/tmp/agent-watch-deadline-${TASK_GID:-pr$PR}"
NOW=$(date +%s)
if [ -r "$DEADLINE_FILE" ]; then
  FILE_MTIME=$(stat -f %m "$DEADLINE_FILE" 2>/dev/null || echo 0)
  if [ $((NOW - FILE_MTIME)) -gt "$BUDGET" ]; then
    echo ">> watch-pr: stale deadline file ($((NOW - FILE_MTIME))s old > ${BUDGET}s budget) from a prior run — resetting" >&2
    rm -f "$DEADLINE_FILE"
  fi
fi
if [ -r "$DEADLINE_FILE" ]; then
  DEADLINE=$(cat "$DEADLINE_FILE")
else
  DEADLINE=$((NOW + BUDGET))
  echo "$DEADLINE" > "$DEADLINE_FILE"
fi

REMAINING=$((DEADLINE - NOW))
if [ "$REMAINING" -le 0 ]; then
  echo ">> watch-pr: budget exhausted (deadline passed $((-REMAINING))s ago)" >&2
  exit 75
fi
echo ">> watch-pr: ${REMAINING}s of budget remain; watching ${REPO:+$REPO }PR #$PR" >&2

# Poll loop instead of `gh pr checks --watch`: --watch blocks on ALL checks with
# no way to exempt the slow-CI check. Same budget contract as before.
SLOW_CI_PATTERN="Travis CI"
# The reviewer bot's check-run NAME (not its login). A reviewer that never posts
# a check-run on a HEAD whose other checks all completed is UNAVAILABLE, not
# pending: it is out of quota, disabled for the repo, or down. That is a
# different verdict from "found nothing", and only this script can tell them
# apart, so it reports which one rather than leaving the caller to guess.
REVIEWER_CHECK_PATTERN="${REVIEWER_CHECK_PATTERN:-Cursor Bugbot}"
# The same reviewer's GitHub LOGIN, for the review query below. GraphQL strips
# the `[bot]` suffix, so Cursor's bots appear as plain `cursor`.
REVIEWER_BOT_LOGIN="${REVIEWER_BOT_LOGIN:-cursor}"
WIP_GUARD_PATTERN="block-wip-pr"
WIP_MODE=""  # cached review-mode verdict; fetched at most once per invocation

# wip_guard_expected: the wip-guard red is expected iff the branch actually
# carries fixup! commits AND the squash oracle says preserve. Same oracle as
# pr-finalize-fixups — no second derivation of "is a reviewer active".
wip_guard_expected() {
  [ -n "$REPO" ] || return 1
  case "$WIP_MODE" in
    preserve) return 0 ;;
    autosquash|none) return 1 ;;
  esac
  local heads
  heads=$(gh pr view "$PR" --repo "$REPO" --json commits -q '[.commits[].messageHeadline] | join("\n")' 2>/dev/null || true)
  printf '%s' "$heads" | grep -q '^fixup!' || { WIP_MODE="none"; return 1; }
  WIP_MODE=$("$HOME/.cursor/skills/pr-address/scripts/pr-address.sh" review-mode \
    --owner "${REPO%%/*}" --repo "${REPO##*/}" --pr "$PR" 2>/dev/null \
    | jq -r '.mode // empty' 2>/dev/null || true)
  [ "$WIP_MODE" = "preserve" ]
}

# reviewer_reviewed_head: did the reviewer bot post a REVIEW whose commit IS the
# PR's current head? The check-run bucket alone lies in both directions — Cursor
# Bugbot has reported `skipping` on a HEAD it had just reviewed and filed a
# finding on, so trusting the bucket would have recorded a real finding as
# "reviewer unavailable" and walked past it. A review pinned to the head commit
# is the only proof of coverage.
reviewer_reviewed_head() {
  [ -n "$REPO" ] || return 1
  local count
  count=$(gh api graphql -f query="{repository(owner:\"${REPO%%/*}\",name:\"${REPO##*/}\"){pullRequest(number:$PR){headRefOid reviews(last:50){nodes{author{login} commit{oid}}}}}}" \
    --jq ".data.repository.pullRequest | .headRefOid as \$h | [.reviews.nodes[] | select(.author.login == \"$REVIEWER_BOT_LOGIN\") | select(.commit.oid == \$h)] | length" \
    2>/dev/null || echo 0)
  [ "${count:-0}" -gt 0 ]
}

while :; do
  NOW=$(date +%s)
  [ "$NOW" -ge "$DEADLINE" ] && { echo ">> watch-pr: remaining-budget timeout" >&2; exit 124; }
  JSON=$(gh pr checks "$PR" ${REPO:+--repo "$REPO"} --json name,bucket 2>/dev/null || true)
  [ -n "$JSON" ] || JSON="[]"
  TOTAL=$(jq 'length' <<<"$JSON" 2>/dev/null || echo 0)
  FAILS_REAL=$(jq -r --arg w "$WIP_GUARD_PATTERN" '[.[] | select(.bucket=="fail" or .bucket=="cancel") | .name | select(startswith($w) | not)] | join(", ")' <<<"$JSON" 2>/dev/null || true)
  FAILS_WIP=$(jq -r --arg w "$WIP_GUARD_PATTERN" '[.[] | select(.bucket=="fail" or .bucket=="cancel") | .name | select(startswith($w))] | join(", ")' <<<"$JSON" 2>/dev/null || true)
  if [ -n "$FAILS_REAL" ]; then
    echo ">> watch-pr: FAILED check(s): $FAILS_REAL" >&2
    exit 1
  fi
  if [ -n "$FAILS_WIP" ] && ! wip_guard_expected; then
    echo ">> watch-pr: FAILED check(s): $FAILS_WIP (wip-guard, and review-mode is NOT preserve — squash the fixups via ~/.cursor/skills/pr-finalize-fixups.sh, never by raw rebase)" >&2
    exit 1
  fi
  PENDING_OTHER=$(jq -r --arg p "$SLOW_CI_PATTERN" '[.[] | select(.bucket=="pending") | .name | select(startswith($p) | not)] | join(", ")' <<<"$JSON" 2>/dev/null || true)
  PENDING_SLOW=$(jq -r --arg p "$SLOW_CI_PATTERN" '[.[] | select(.bucket=="pending") | .name | select(startswith($p))] | join(", ")' <<<"$JSON" 2>/dev/null || true)
  if [ "$TOTAL" -gt 0 ] && [ -z "$PENDING_OTHER" ]; then
    # A reviewer that did not actually review looks two ways: no check-run at
    # all, or one whose bucket is "skipping". Neither is reviewed-and-clean, so
    # neither may be reported as reviewer coverage — but neither PROVES absence
    # either, so the check-run only raises the question. A review pinned to the
    # head commit answers it, and that answer wins.
    REVIEWER_REVIEWED=$(jq -r --arg p "$REVIEWER_CHECK_PATTERN" '[.[] | select(.name | startswith($p)) | select(.bucket != "skipping")] | length' <<<"$JSON" 2>/dev/null || echo 0)
    REVIEWER_NOTE=""
    if [ "${REVIEWER_REVIEWED:-0}" -eq 0 ] && ! reviewer_reviewed_head; then
      REVIEWER_SEEN=$(jq -r --arg p "$REVIEWER_CHECK_PATTERN" '[.[] | .name | select(startswith($p))] | length' <<<"$JSON" 2>/dev/null || echo 0)
      if [ "${REVIEWER_SEEN:-0}" -eq 0 ]; then WHY="no check-run"; else WHY="check-run skipped"; fi
      REVIEWER_NOTE=" reviewer-unavailable:$REVIEWER_CHECK_PATTERN($WHY, no review on HEAD)"
      echo ">> watch-pr: '$REVIEWER_CHECK_PATTERN' did not review this HEAD ($WHY, and it posted no review on the head commit) while every other check completed — out of quota, disabled, or down. Waiting cannot fix it. Proceed, and record it as an UNCHECKED box in the run report's Finalize Gate rather than as reviewer-clean." >&2
    fi
    if [ -n "$FAILS_WIP" ]; then
      echo ">> watch-pr: green except wip-guard ($FAILS_WIP): expected while fixups are PRESERVED for the active reviewer — do NOT squash to clear it" >&2
      echo "RESULT: green-wip-preserve ($FAILS_WIP)$REVIEWER_NOTE"
    elif [ -z "$PENDING_SLOW" ]; then
      echo "RESULT: green$REVIEWER_NOTE"
    else
      echo ">> watch-pr: every check green except still-pending: $PENDING_SLOW (non-blocking; red would block)" >&2
      echo "RESULT: green-travis-pending ($PENDING_SLOW)$REVIEWER_NOTE"
    fi
    exit 0
  fi
  sleep "$INTERVAL"
done
