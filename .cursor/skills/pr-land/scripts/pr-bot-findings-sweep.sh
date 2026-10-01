#!/usr/bin/env bash
# pr-bot-findings-sweep.sh — harvest reviewer-bot findings from PRs that already
# merged. Pairs with `pr-land-automerge.sh --no-bugbot-wait`: arming without the
# reviewer wait lets a PR merge before its bots finish, so their findings land
# on a merged PR where no arming gate will ever read them. This sweep is the
# reader: it waits (bounded) for reviewer check-runs still pending on each PR's
# final head, then lists every unresolved bot thread.
#
# Usage: pr-bot-findings-sweep.sh <repo#num> [more...] [--wait <secs>] [--interval <secs>]
#        (bare repo#num defaults owner to EdgeApp; --wait default 600, total
#         budget across all PRs, not per PR)
#
# Output (stdout): one JSON array, one entry per PR:
#   {"repo","prNumber","prUrl","unreviewed":[<reviewer still pending at the deadline>],
#    "botThreads":[{"threadId","commentId","user","path","body","url"}]}
# `unreviewed` non-empty means the bot never finished inside the budget: the
# follow-up records the PR as not reviewed, never as clean.
#
# Exit: 0 = every PR reviewed and no unresolved bot threads
#       3 = findings or unreviewed PRs present (the follow-up step acts on them)
#       1 = a GitHub read failed (stderr names the PR)
#       2 = usage
set -uo pipefail

command -v gh >/dev/null || { echo "ERROR: gh not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 2; }

WAIT=600
INTERVAL=30
PRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) WAIT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -*) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
    *) PRS+=("$1"); shift ;;
  esac
done
[ ${#PRS[@]} -gt 0 ] || { echo "usage: pr-bot-findings-sweep.sh <repo#num> [more...] [--wait <secs>]" >&2; exit 2; }

# Same reviewer prefixes the arming gate uses (pr-land-automerge.sh).
REVIEWER_CHECK_PATTERN="${REVIEWER_CHECK_PATTERN:-Cursor Bugbot|Cursor Security}"
COMMENTS_SH="$HOME/.cursor/skills/pr-land/scripts/pr-land-comments.sh"

slug_of() { case "${1%%#*}" in */*) echo "${1%%#*}" ;; *) echo "EdgeApp/${1%%#*}" ;; esac; }

pending_reviewers() { # $1=slug $2=num → JSON array of pending reviewer names
  local json
  json=$(gh pr checks "$2" --repo "$1" --json name,bucket 2>/dev/null) || { echo "ERR"; return; }
  jq -c --arg p "$REVIEWER_CHECK_PATTERN" \
    '[ .[] | select(.bucket == "pending") | .name
       | select( . as $n | ($p | split("|")) | any(. as $x | $n | startswith($x)) ) ]' <<<"$json"
}

# Phase 1: wait out pending reviewers, bounded by one shared deadline.
deadline=$(( $(date +%s) + WAIT ))
while :; do
  still=0
  for spec in "${PRS[@]}"; do
    p=$(pending_reviewers "$(slug_of "$spec")" "${spec##*#}")
    [ "$p" = "ERR" ] && { echo "ERROR: gh pr checks failed for $spec" >&2; exit 1; }
    [ "$p" != "[]" ] && still=$((still + 1))
  done
  [ "$still" -eq 0 ] && break
  [ "$(date +%s)" -ge "$deadline" ] && break
  echo "$(date +%H:%M:%S) $still PR(s) with a reviewer bot still running; waiting" >&2
  sleep "$INTERVAL"
done

# Phase 2: collect unresolved bot threads + whatever is still pending.
RC=0
OUT="[]"
for spec in "${PRS[@]}"; do
  slug=$(slug_of "$spec"); num="${spec##*#}"; repo="${slug#*/}"
  pend=$(pending_reviewers "$slug" "$num")
  [ "$pend" = "ERR" ] && { echo "ERROR: gh pr checks failed for $spec" >&2; exit 1; }
  cm=$(jq -cn --arg r "$slug" --argjson n "$num" '[{repo:$r, prNumber:$n, branch:""}]' | "$COMMENTS_SH" 2>/dev/null) \
    || { echo "ERROR: pr-land-comments.sh failed for $spec" >&2; exit 1; }
  threads=$(jq -c --arg base "https://github.com/$slug/pull/$num" \
    '[ .[] | (.botThreads // [])[] | . + {url: ($base + "#discussion_r" + (.commentId|tostring))} ]' <<<"${cm:-[]}")
  entry=$(jq -cn --arg repo "$repo" --argjson n "$num" --arg url "https://github.com/$slug/pull/$num" \
    --argjson u "$pend" --argjson t "$threads" \
    '{repo:$repo, prNumber:$n, prUrl:$url, unreviewed:$u, botThreads:$t}')
  OUT=$(jq -c --argjson e "$entry" '. + [$e]' <<<"$OUT")
  if [ "$pend" != "[]" ] || [ "$threads" != "[]" ]; then RC=3; fi
done

echo "$OUT"
exit $RC
