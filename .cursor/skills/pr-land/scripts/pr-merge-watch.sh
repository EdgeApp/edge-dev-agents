#!/usr/bin/env bash
set -uo pipefail

# pr-merge-watch.sh — babysit armed auto-merge PRs until they merge or need help.
#
# GitHub auto-merge never updates a BEHIND branch: an armed PR whose base
# moved sits BEHIND with green checks forever. This watcher treats
# BEHIND-with-green and DIRTY as the same actionable state (NEEDS_REBASE) so
# the caller loops back into prepare→push instead of stalling. Transient
# UNKNOWN/BEHIND flickers right after a push are absorbed by requiring the
# same state on two consecutive polls before acting.
#
# Usage: pr-merge-watch.sh <owner/repo#num> [more...] [--interval <secs>] [--timeout <secs>]
#        (bare repo#num defaults owner to EdgeApp)
#
# Prints one status line per poll. Final line + exit code:
#   ALL_MERGED    (exit 0) — every PR merged
#   CHECK_FAILED <repo#num> (exit 4) — a check went red; auto-merge left armed
#   NEEDS_REBASE <repo#num...> (exit 3) — DIRTY, or BEHIND with green checks,
#                 on two consecutive polls; re-run prepare→push for those PRs
#   TIMEOUT       (exit 5) — deadline hit with PRs still pending

INTERVAL=90
TIMEOUT=3600
PRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) PRS+=("$1"); shift ;;
  esac
done
[ ${#PRS[@]} -gt 0 ] || { echo "usage: pr-merge-watch.sh <repo#num> [more...]" >&2; exit 1; }

deadline=$(( $(date +%s) + TIMEOUT ))
# Consecutive-poll state tracking without associative arrays (macOS bash 3.2).
PREV_STATES=""
prev_state() { printf '%s\n' "$PREV_STATES" | grep -F "|$1=" | head -1 | cut -d= -f2; }

while :; do
  open=0
  red_pr=""
  rebase_prs=()
  line=""
  next_states=""

  for spec in "${PRS[@]}"; do
    repo_part="${spec%%#*}"
    num="${spec##*#}"
    case "$repo_part" in
      */*) slug="$repo_part" ;;
      *) slug="EdgeApp/$repo_part" ;;
    esac

    js=$(gh pr view "$num" --repo "$slug" --json state,mergeStateStatus,statusCheckRollup 2>/dev/null) || {
      line="$line $spec=FETCH_ERR"
      open=$((open + 1))
      continue
    }
    st=$(echo "$js" | jq -r '.state')
    if [ "$st" = "MERGED" ]; then
      line="$line $spec=MERGED"
      continue
    fi
    open=$((open + 1))
    ms=$(echo "$js" | jq -r '.mergeStateStatus')
    bad=$(echo "$js" | jq -r '[.statusCheckRollup[]? | select((.conclusion // .state // "") | test("FAILURE|CANCELLED|TIMED_OUT|ERROR"))] | length')
    line="$line $spec=$ms(red=$bad)"

    if [ "${bad:-0}" -gt 0 ] 2>/dev/null; then
      red_pr="$spec"
      continue
    fi
    # DIRTY, or BEHIND with all checks green, needs a rebase — but only after
    # the same state on two consecutive polls (GitHub recomputes after pushes).
    if [ "$ms" = "DIRTY" ] || [ "$ms" = "BEHIND" ]; then
      if [ "$(prev_state "$spec")" = "$ms" ]; then
        rebase_prs+=("$spec")
      fi
    fi
    next_states="$next_states|$spec=$ms
"
  done
  PREV_STATES="$next_states"

  echo "$(date +%H:%M:%S) open=$open |$line"

  if [ "$open" -eq 0 ]; then echo "ALL_MERGED"; exit 0; fi
  if [ -n "$red_pr" ]; then echo "CHECK_FAILED $red_pr"; exit 4; fi
  if [ ${#rebase_prs[@]} -gt 0 ]; then echo "NEEDS_REBASE ${rebase_prs[*]}"; exit 3; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then echo "TIMEOUT"; exit 5; fi
  sleep "$INTERVAL"
done
