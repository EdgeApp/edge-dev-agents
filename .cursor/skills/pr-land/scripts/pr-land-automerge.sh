#!/usr/bin/env bash
# pr-land-automerge.sh — DEFAULT land path: arm GitHub auto-merge (merge-commit) for
# each PR so GitHub merges it when required CI checks pass, instead of rebasing,
# verifying, and merging locally. GitHub owns the rebase/queue and the green-CI wait;
# the agent does not babysit the watch loop.
#
# ARMING GATE (why this script refuses to arm while a reviewer bot is still running):
# armed auto-merge fires the instant required checks go green. Reviewer bots are NOT
# required checks, so a bot that is still reviewing HEAD loses that race and its
# finding lands on an already-merged PR, costing a second PR to fix what a fixup
# would have covered. Required CI blocks the merge by itself, so arming early buys
# nothing. Hence: bots complete first, then arm. Absence is NOT pending — a reviewer
# that posted no check-run at all (quota, outage, draft) must never wedge a land, so
# only a PENDING reviewer check-run holds arming back.
#
# Input (stdin JSON array): [{"repo":"edge-react-gui","prNumber":123}, ...]
#   (repo is "<name>" under EdgeApp, or "<owner>/<name>").
#
# Flags:
#   --disarm   Turn auto-merge OFF for each input PR instead of arming it. Required
#              before any force-push to an armed PR (a re-prepare/rebase push): the
#              push re-triggers the bots while auto-merge is still live, which is the
#              same race the arming gate exists to prevent. Re-arm afterwards through
#              the normal (gated) path.
#
# Per PR, emits one result line to stdout:
#   armed     — auto-merge enabled; GitHub will merge on green CI
#   disarmed  — auto-merge turned off (--disarm)
#   merged    — already merged (skip, idempotent re-run)
#   waiting   — a reviewer-bot check-run is still running on HEAD; NOT armed. Wait for
#               it to complete, then re-run this script (no fix implied).
#   blocked   — not armable: changes requested, or an unresolved reviewer-bot thread
#               (address per bot-thread-gate) — reported, not armed
#   unsupported — repo does not allow auto-merge / merge-commit; caller falls back
#                 to the local path (pr-land-merge.sh)
#   error     — other failure (message included)
#
# Exit: 0 if every PR is armed/disarmed/already merged; 76 if any PR is only WAITING on
# a reviewer bot (retry the same call later, nothing to fix); 1 if any blocked/
# unsupported/error; 75 if another session holds the repo land lease; 2 for usage/deps.
# gh handles auth + API versioning.
set -uo pipefail

command -v gh >/dev/null || { echo "ERROR: gh not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 2; }

MODE="arm"
while [ $# -gt 0 ]; do
  case "$1" in
    --disarm) MODE="disarm"; shift ;;
    *) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
  esac
done

# The reviewer bots' check-run NAME prefixes, `|`-separated, matched with startswith.
# Same prefixes watch-pr.sh gates on, so a land can never arm over a reviewer the
# Complete gate then refuses.
REVIEWER_CHECK_PATTERN="${REVIEWER_CHECK_PATTERN:-Cursor Bugbot|Cursor Security}"
COMMENTS_SH="$HOME/.cursor/skills/pr-land/scripts/pr-land-comments.sh"

INPUT="$(cat)"
[ -n "$INPUT" ] || { echo "ERROR: no PR JSON on stdin" >&2; exit 2; }

RC=0
# Per-repo land mutex: arming itself is server-side-safe, but automerge runs in
# the same trains as local rebases (see repo-land-lock.sh). Exit 75 = busy.
LOCK="$HOME/.cursor/skills/pr-land/scripts/repo-land-lock.sh"
LOCK_OWNER="${AGENT_SESSION_UUID:-op-${USER:-shell}}"
LOCK_REPOS="$(echo "$INPUT" | jq -r '.[].repo' | sed 's|.*/||' | sort -u)"
for _r in $LOCK_REPOS; do
  "$LOCK" acquire --repo "$_r" --owner "$LOCK_OWNER" || { echo "pr-land-automerge: land lock busy for $_r — wait and retry." >&2; exit 75; }
done
trap 'for _r in $LOCK_REPOS; do "$LOCK" release --repo "$_r" --owner "$LOCK_OWNER" >/dev/null 2>&1; done' EXIT

# Reviewer-bot check-runs still running on HEAD, as a comma-joined name list
# (empty = none pending). A "skipping"/absent reviewer is NOT pending: it did not
# review, waiting cannot change that, and blocking here would wedge the land.
pending_reviewers() {
  local repo="$1" num="$2" json
  json=$(gh pr checks "$num" --repo "$repo" --json name,bucket 2>/dev/null || echo '[]')
  jq -r --arg p "$REVIEWER_CHECK_PATTERN" \
    '[ .[] | select(.bucket == "pending") | .name
       | select( . as $n | ($p | split("|")) | any(. as $x | $n | startswith($x)) ) ]
     | join(", ")' <<<"$json" 2>/dev/null || true
}

# Count of unresolved reviewer-bot threads (bot-thread-gate). Fails CLOSED: an
# unreadable comment check returns "?" so the caller reports rather than arms blind.
bot_thread_count() {
  local pr_json="$1" out
  out=$(jq -c '[{repo:.repo, prNumber:.prNumber, branch:(.branch // "")}]' <<<"$pr_json" \
        | "$COMMENTS_SH" 2>/dev/null) || { echo "?"; return; }
  jq -r '[ .[] | (.botThreads // []) | length ] | add // 0' <<<"${out:-[]}" 2>/dev/null || echo "?"
}

while read -r pr; do
  REPO=$(echo "$pr" | jq -r '.repo')
  NUM=$(echo "$pr" | jq -r '.prNumber')
  [[ "$REPO" == */* ]] || REPO="EdgeApp/$REPO"

  STATE=$(gh pr view "$NUM" --repo "$REPO" --json state,reviewDecision,mergeStateStatus 2>/dev/null || echo '')
  if [ -z "$STATE" ]; then echo "error   $REPO#$NUM — gh pr view failed"; RC=1; continue; fi
  PRSTATE=$(echo "$STATE" | jq -r '.state'); REVIEW=$(echo "$STATE" | jq -r '.reviewDecision')

  if [ "$PRSTATE" = "MERGED" ]; then echo "merged  $REPO#$NUM"; continue; fi

  if [ "$MODE" = "disarm" ]; then
    ERR=$(gh pr merge "$NUM" --repo "$REPO" --disable-auto 2>&1)
    # Disarming a PR that was never armed is the same end state, not a failure:
    # the re-prepare loop calls this unconditionally before every force-push.
    if [ $? -eq 0 ] || echo "$ERR" | grep -qiE "not enabled|no auto.?merge|auto.?merge is not"; then
      echo "disarmed $REPO#$NUM — auto-merge off; re-arm through the gated path after the push"
    else echo "error   $REPO#$NUM — $(echo "$ERR" | head -1)"; RC=1; fi
    continue
  fi

  if [ "$REVIEW" = "CHANGES_REQUESTED" ]; then echo "blocked $REPO#$NUM — changes requested; resolve before landing"; RC=1; continue; fi

  # ARMING GATE (see header): reviewer bots finish before auto-merge goes live.
  PENDING=$(pending_reviewers "$REPO" "$NUM")
  if [ -n "$PENDING" ]; then
    echo "waiting $REPO#$NUM — reviewer bot(s) still running on HEAD: $PENDING. Not armed; re-run when they complete."
    [ "$RC" -eq 0 ] && RC=76
    continue
  fi
  BOTN=$(bot_thread_count "$pr")
  if [ "$BOTN" = "?" ]; then
    echo "error   $REPO#$NUM — comment check failed; cannot confirm reviewer-bot threads are clear"; RC=1; continue
  fi
  if [ "${BOTN:-0}" -gt 0 ]; then
    echo "blocked $REPO#$NUM — $BOTN unresolved reviewer-bot thread(s); address per bot-thread-gate before arming"; RC=1; continue
  fi

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
  # Process substitution, NOT a pipe: a piped `while` runs in a subshell under bash,
  # so every RC assignment above would be discarded and the script would exit 0 on a
  # blocked/unsupported PR.
done < <(echo "$INPUT" | jq -c '.[]')

exit $RC
