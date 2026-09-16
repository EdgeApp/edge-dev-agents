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
# The repo is never guessed: see REPO RESOLUTION below. Pass --repo whenever the
# PR is not in the cwd repo and the task does not yet attach it.
# Exit: 0   green — final stdout line distinguishes:
#             RESULT: green                   (everything passed, Travis included)
#             RESULT: green-travis-pending    (all but Travis passed; Travis
#                                              queued/running — report its state
#                                              in the Finalize Gate checklist)
#             Any RESULT may carry a ` reviewer-unavailable:<name>(<why>)[, ...]`
#             suffix, one entry per reviewer bot that posted no usable check-run
#             on a HEAD whose other checks all completed. Proceed; record each as
#             an unchecked box in the report's Finalize Gate and NOWHERE else
#             (no comment, no follow-up item; require-clean-run-report.sh and
#             the Asana comment hook enforce this).
#             RESULT: green-wip-preserve      (all passed except the wip-guard
#                                              check, red only because preserved
#                                              fixup commits are on the branch
#                                              during an active review — never
#                                              squash to clear it; it goes green
#                                              at finalize when pr-finalize-fixups
#                                              legitimately squashes)
#       1   a check failed, Travis included (read `gh run view --log-failed`, fix)
#       76  ZERO checks on the PR for NOCHECKS_GRACE seconds (default 300; a
#             draft posts no bot check-runs, and `[skip travis]` suppresses Travis,
#             so a misconfigured or draft PR can show nothing to wait on). Final
#             line: RESULT: no-checks. The caller reports it as a CI-configuration
#             problem; it is NOT a budget exhaustion and NOT a green.
#       7   CONTINUE: this call hit its per-call cap (MAX_CALL, default 540s, under
#             the Bash tool's 600s foreground limit) with checks still pending.
#             Final line: RESULT: continue. Re-invoke the SAME command at once; the
#             remaining round budget carries over. Not a failure, not exhaustion.
#       75  budget already exhausted — stop watching, take the blocked=Yes path
#       124 this watch hit the remaining-budget timeout (same: budget is gone)
#       2   usage error / missing tool
set -euo pipefail

PR="" REPO="" TASK_GID="" BUDGET=1800 INTERVAL=30
NOCHECKS_GRACE="${NOCHECKS_GRACE:-300}"
ZERO_SINCE=""
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

# REPO RESOLUTION: the target repo is EXPLICIT before anything is watched.
# PR numbers collide across repos and gh infers the repo from cwd, so a watch
# launched from another repo's worktree reads a DIFFERENT repo's PR of the same
# number and reports its state as this PR's (a run burned 5m26s and returned
# `RESULT: no-checks` off an unrelated PR that way). Precedence:
#   1. --repo      explicit wins, always.
#   2. --task-gid  the repo of the PR NUMBERED --pr attached to that task (parent
#                  or per-repo subtask). The task is the authority on which repo
#                  the run's PR lives in; cwd is not.
#   3. cwd         only when the cwd repo really HAS PR #--pr and the task
#                  attaches nothing that contradicts it.
# Anything else exits 2 naming --repo rather than watching a guess.
asana_task_pr_urls() { # $1=gid → github PR URLs attached to the task or its subtasks
  local gid="$1" token g api="https://app.asana.com/api/1.0"
  command -v curl >/dev/null && command -v jq >/dev/null || return 0
  token="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null || true)}"
  [ -n "$token" ] || return 0
  for g in "$gid" $(curl -sf --max-time 15 "$api/tasks/$gid/subtasks?opt_fields=gid" \
      -H "Authorization: Bearer $token" 2>/dev/null | jq -r '.data[]?.gid // empty' 2>/dev/null || true); do
    curl -sf --max-time 15 "$api/tasks/$g/attachments?opt_fields=view_url" \
      -H "Authorization: Bearer $token" 2>/dev/null | jq -r '.data[]? | .view_url // empty' 2>/dev/null || true
  done | { grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+' || true; } | sort -u
}
if [ -n "$REPO" ]; then
  echo ">> watch-pr: repo $REPO (source: --repo)" >&2
else
  CWD_REPO=""
  if git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CWD_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  fi
  TASK_PR_URLS=""
  [ -n "$TASK_GID" ] && TASK_PR_URLS=$(asana_task_pr_urls "$TASK_GID")
  TASK_REPO=$(printf '%s\n' "$TASK_PR_URLS" | awk -F/ -v n="$PR" 'NF >= 7 && $NF == n {print $4 "/" $5}' | head -1)
  if [ -n "$TASK_REPO" ]; then
    REPO="$TASK_REPO"
    if [ -n "$CWD_REPO" ] && [ "$CWD_REPO" != "$REPO" ]; then
      echo ">> watch-pr: cwd is $CWD_REPO, but task $TASK_GID attaches PR #$PR in $REPO; watching $REPO" >&2
    fi
    echo ">> watch-pr: repo $REPO (source: PR #$PR attached to task $TASK_GID)" >&2
  elif [ -n "$TASK_PR_URLS" ]; then
    echo "ERROR: task $TASK_GID attaches $(printf '%s' "$TASK_PR_URLS" | tr '\n' ' ')but none is PR #$PR, and PR numbers collide across repos. Pass --repo <owner/name> for PR #$PR" >&2
    exit 2
  elif [ -n "$CWD_REPO" ]; then
    if gh pr view "$PR" --repo "$CWD_REPO" --json number >/dev/null 2>&1; then
      REPO="$CWD_REPO"
      echo ">> watch-pr: repo $REPO (source: cwd $(basename "$PWD"); it has PR #$PR)" >&2
    else
      echo "ERROR: $CWD_REPO (resolved from cwd $(basename "$PWD")) has no PR #$PR. Pass --repo <owner/name> for the repo that does" >&2
      exit 2
    fi
  else
    echo "ERROR: no --repo, cwd is not a git repo, and no task attachment names PR #$PR. Pass --repo <owner/name>" >&2
    exit 2
  fi
fi
command -v timeout >/dev/null || { echo "ERROR: timeout not on PATH (shim: ~/.cursor/skills/timeout.sh)" >&2; exit 2; }

# BUDGET SEMANTICS (reworked 2026-08-06 per the cohort's watch-pr findings):
# the budget bounds waiting PER HEAD/ROUND, not per task-lifetime, and it burns
# only time this script actually spent watching:
#   - The file stores REMAINING seconds + the HEAD it applies to. Each call
#     measures its own runtime and decrements on exit (trap), so a call killed
#     by the harness's foreground cap loses only the seconds it truly watched —
#     the old wall-clock deadline burned ~5 idle minutes per kill.
#   - A NEW HEAD (fix push, next review round) resets the budget to full: a
#     legitimate 4-round review loop is 4 bounded waits, not one 30-min pool
#     (the old semantics exhausted mid-loop and forced hand-rolled polling).
#   - Staleness: a file older than 6h is a prior run's carryover; reset.
#   - Keyed by task + repo + PR, so a task alternating two PRs keeps a budget
#     per PR instead of each watch resetting the other's (the HEAD check below
#     would otherwise see a foreign HEAD every call).
BUDGET_FILE="/tmp/agent-watch-budget-${TASK_GID:-notask}-$(printf '%s' "$REPO" | tr -c 'A-Za-z0-9' '-')-pr$PR"
NOW=$(date +%s)
# One retry: a transient gh failure must not read as "PR #$PR is not in $REPO".
CUR_HEAD=$(gh pr view "$PR" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || true)
if [ -z "$CUR_HEAD" ]; then
  sleep 5
  CUR_HEAD=$(gh pr view "$PR" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || true)
fi
[ -n "$CUR_HEAD" ] || { echo "ERROR: $REPO has no PR #$PR (or gh cannot read it); watching it would report another repo's checks" >&2; exit 2; }
REMAINING="$BUDGET"
if [ -r "$BUDGET_FILE" ]; then
  FILE_MTIME=$(stat -f %m "$BUDGET_FILE" 2>/dev/null || echo 0)
  SAVED_HEAD=$(sed -n '2p' "$BUDGET_FILE" 2>/dev/null || echo "")
  if [ $((NOW - FILE_MTIME)) -gt 21600 ]; then
    echo ">> watch-pr: stale budget file from a prior run — resetting" >&2
  elif [ "$SAVED_HEAD" != "$CUR_HEAD" ]; then
    echo ">> watch-pr: new HEAD ${CUR_HEAD:0:8} (was ${SAVED_HEAD:0:8}) — fresh round, budget reset" >&2
  else
    REMAINING=$(sed -n '1p' "$BUDGET_FILE" 2>/dev/null || echo "$BUDGET")
    case "$REMAINING" in (*[!0-9-]*|"") REMAINING="$BUDGET" ;; esac
  fi
fi
printf '%s\n%s\n' "$REMAINING" "$CUR_HEAD" > "$BUDGET_FILE"

if [ "$REMAINING" -le 0 ]; then
  echo ">> watch-pr: budget exhausted for HEAD ${CUR_HEAD:0:8}" >&2
  exit 75
fi
WATCH_START=$(date +%s)
persist_budget() {
  local spent=$(( $(date +%s) - WATCH_START ))
  printf '%s\n%s\n' "$(( REMAINING - spent ))" "$CUR_HEAD" > "$BUDGET_FILE" 2>/dev/null || true
}
trap persist_budget EXIT
DEADLINE=$((NOW + REMAINING))
# CHUNKED WATCH: one call never outlives the Bash tool's foreground cap, so it
# self-bounds to MAX_CALL and exits 7 with the budget persisted by the trap
# above (same pattern as pr-land's pr-merge-watch.sh).
MAX_CALL="${MAX_CALL:-540}"
CALL_DEADLINE=$((WATCH_START + MAX_CALL))
# Land-lease upkeep: when this session holds the repo's land lease (a land is
# in flight), each poll renews it so the lease cannot expire under a long
# watch. renew exits 3 when no lease exists; that is the common case.
LAND_LOCK="$HOME/.cursor/skills/pr-land/scripts/repo-land-lock.sh"
LAND_LOCK_OWNER="${AGENT_SESSION_UUID:-op-${USER:-shell}}"
renew_land_lease() {
  [ -x "$LAND_LOCK" ] || return 0
  local rc=0
  "$LAND_LOCK" renew --repo "$REPO" --owner "$LAND_LOCK_OWNER" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] && echo ">> watch-pr: WARNING: land lease on ${REPO##*/} is not ours or expired; re-acquire before any push" >&2
  return 0
}
echo ">> watch-pr: ${REMAINING}s of round budget remain (HEAD ${CUR_HEAD:0:8}); watching $REPO PR #$PR" >&2

# Poll loop instead of `gh pr checks --watch`: --watch blocks on ALL checks with
# no way to exempt the slow-CI check. Same budget contract as before.
SLOW_CI_PATTERN="Travis CI"
# The reviewer bots' check-run NAME prefixes (not their logins), `|`-separated
# and matched with startswith. They are the SAME two prefixes the Complete gate
# counts (check-followup-scope.sh), so this watch can never report coverage the
# gate then refuses. A reviewer that never posts a check-run on a HEAD whose
# other checks all completed is UNAVAILABLE, not pending: it is out of quota,
# disabled for the repo, or down. That is a different verdict from "found
# nothing", and only this script can tell them apart, so it reports which one
# rather than leaving the caller to guess. Each reviewer is judged SEPARATELY:
# one bot's clean check-run says nothing about the other's absence.
REVIEWER_CHECK_PATTERN="${REVIEWER_CHECK_PATTERN:-Cursor Bugbot|Cursor Security}"
# The reviewers' shared GitHub LOGIN, for the review query below. GraphQL strips
# the `[bot]` suffix, so BOTH Cursor bots appear as plain `cursor`, which is why
# a review on HEAD can only answer "one of them reviewed", never which one.
REVIEWER_BOT_LOGIN="${REVIEWER_BOT_LOGIN:-cursor}"
WIP_GUARD_PATTERN="block-wip-pr"
WIP_MODE=""  # cached review-mode verdict; fetched at most once per invocation

# Backstop for the travis-draft-tag flow: a READY PR whose HEAD still carries
# [skip travis] can never go Travis-green — the strip was skipped at the flip.
# Print the warning to stderr (do not fail; the watch itself still gates everything else).
TAGCHK=$(gh pr view "$PR" --repo "$REPO" --json isDraft,commits \
  -q '{d: .isDraft, m: .commits[-1].messageHeadline}' 2>/dev/null || true)
if [ -n "$TAGCHK" ] && [ "$(jq -r '.d' <<<"$TAGCHK")" = "false" ] \
   && jq -r '.m' <<<"$TAGCHK" | grep -q '\[skip travis\]'; then
  echo ">> watch-pr: WARNING — PR is READY but HEAD still carries [skip travis]; Travis will never build this HEAD. Run ~/.cursor/skills/one-shot/scripts/travis-draft-tag.sh strip, force-push, then re-watch." >&2
fi

# wip_guard_expected: the wip-guard red is expected iff the branch actually
# carries fixup! commits AND the squash oracle says preserve. Same oracle as
# pr-finalize-fixups — no second derivation of "is a reviewer active".
wip_guard_expected() {

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

  local count
  count=$(gh api graphql -f query="{repository(owner:\"${REPO%%/*}\",name:\"${REPO##*/}\"){pullRequest(number:$PR){headRefOid reviews(last:50){nodes{author{login} commit{oid}}}}}}" \
    --jq ".data.repository.pullRequest | .headRefOid as \$h | [.reviews.nodes[] | select(.author.login == \"$REVIEWER_BOT_LOGIN\") | select(.commit.oid == \$h)] | length" \
    2>/dev/null || echo 0)
  [ "${count:-0}" -gt 0 ]
}

while :; do
  NOW=$(date +%s)
  [ "$NOW" -ge "$DEADLINE" ] && { echo ">> watch-pr: remaining-budget timeout" >&2; exit 124; }
  renew_land_lease
  JSON=$(gh pr checks "$PR" --repo "$REPO" --json name,bucket 2>/dev/null || true)
  [ -n "$JSON" ] || JSON="[]"
  TOTAL=$(jq 'length' <<<"$JSON" 2>/dev/null || echo 0)
  # ZERO checks: nothing has posted at all (draft PR, [skip travis] HEAD, or a
  # repo whose CI never triggered for this branch). The green test below needs
  # TOTAL > 0, so without this escape the watch waits out the whole budget and
  # reports a false blocked (explorer run, 2026-09-11).
  if [ "$TOTAL" -eq 0 ]; then
    [ -n "$ZERO_SINCE" ] || ZERO_SINCE=$(date +%s)
    if [ $(( $(date +%s) - ZERO_SINCE )) -ge "$NOCHECKS_GRACE" ]; then
      echo ">> watch-pr: NO checks on HEAD ${CUR_HEAD:0:8} after $((NOCHECKS_GRACE / 60))m — nothing to gate on. Is the PR a draft, does HEAD carry [skip travis], or does this repo run no CI on this branch?" >&2
      echo "RESULT: no-checks"
      exit 76
    fi
  else
    ZERO_SINCE=""
  fi
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
    # head commit answers it, and that answer wins. That answer is per-LOGIN and
    # both Cursor reviewers post as `cursor`, so it can only say "one of them
    # reviewed": it clears the note when EVERY reviewer is missing (the outage it
    # was written for), and when one reviewer DID post a usable check-run the
    # other's absence stands on its own.
    REVIEWER_MISS=$(jq -r --arg p "$REVIEWER_CHECK_PATTERN" '
      . as $c
      | [ ($p | split("|"))[]
          | . as $n
          | { n: $n,
              seen:   ([ $c[] | select(.name | startswith($n)) ] | length),
              usable: ([ $c[] | select((.name | startswith($n)) and (.bucket != "skipping")) ] | length) }
          | select(.usable == 0)
          | .n + (if .seen == 0 then "(no check-run)" else "(check-run skipped)" end) ] as $m
      | [ ($m | length), (($p | split("|")) | length), ($m | join(", ")) ] | @tsv' <<<"$JSON" 2>/dev/null || true)
    IFS=$'\t' read -r MISS_N REVIEWER_N MISS_TEXT <<<"${REVIEWER_MISS:-0	0	}"
    REVIEWER_NOTE=""
    if [ "${MISS_N:-0}" -gt 0 ] && ! { [ "$MISS_N" -eq "${REVIEWER_N:-0}" ] && reviewer_reviewed_head; }; then
      # DRAFT PRs (the 2026-07-31 bugbot-credit gate): reviewer bots skip drafts
      # BY DESIGN — absence is the gate working, not an outage. Distinct suffix
      # so the caller knows the finalize path is `gh pr ready` + re-watch, and
      # the Finalize Gate box is "pending ready-flip", not reviewer-unavailable.
      IS_DRAFT=$(gh pr view "$PR" --repo "$REPO" --json isDraft -q .isDraft 2>/dev/null || echo false)
      if [ "$IS_DRAFT" = "true" ]; then
        REVIEWER_NOTE=" draft-reviewer-skipped($MISS_TEXT: bots skip drafts by design; run gh pr ready at finalize, then re-watch)"
        echo ">> watch-pr: PR is DRAFT, so '$MISS_TEXT' skipping it is the credit gate working. CI is gated now; bots gate after 'gh pr ready' at finalize." >&2
      else
        # Genuinely unavailable reviewer on a READY PR: write the waiver the
        # Complete gate's bot check honors, so an outage blocks nothing while
        # staying on the audit trail (the eval reads this file's reason).
        if [ -n "$TASK_GID" ]; then
          printf 'reviewer-unavailable: %s posted no check-run/review on ready HEAD %s at %s (other checks complete)\n' \
            "$MISS_TEXT" "${CUR_HEAD:0:12}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "/tmp/agent-bot-unavailable-${TASK_GID}" 2>/dev/null || true
        fi
        REVIEWER_NOTE=" reviewer-unavailable:$MISS_TEXT(no review on HEAD)"
        echo ">> watch-pr: $MISS_TEXT did not review HEAD. Proceed. Record it ONLY as the unchecked reviewer box in the run report's Finalize Gate; mention it nowhere else (operator ruling 2026-09-02)." >&2
      fi
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
  if [ $(( $(date +%s) + INTERVAL )) -ge "$CALL_DEADLINE" ]; then
    echo ">> watch-pr: per-call cap (${MAX_CALL}s) reached with checks pending; budget persisted" >&2
    echo "RESULT: continue ($(( DEADLINE - $(date +%s) ))s of round budget remain; re-invoke the same command)"
    exit 7
  fi
  sleep "$INTERVAL"
done
