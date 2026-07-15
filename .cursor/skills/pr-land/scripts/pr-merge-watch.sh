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
#
# BACKGROUNDED CALLERS: read the VERDICT, never the exit code. A backgrounded
# wrapper reports ITS OWN exit 0 and can mask exit 3 (the 2026-07-14 Banxa
# land nearly called a BEHIND branch merged this way). The verdict is written
# to --result-file (default /tmp/pr-merge-watch-<sanitized-first-pr>.result)
# as "<VERDICT> <details>", and is also always the final stdout line.

INTERVAL=90
TIMEOUT=3600
RESULT_FILE=""
PRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --result-file) RESULT_FILE="$2"; shift 2 ;;
    *) PRS+=("$1"); shift ;;
  esac
done
[ ${#PRS[@]} -gt 0 ] || { echo "usage: pr-merge-watch.sh <repo#num> [more...] [--result-file <path>]" >&2; exit 1; }
[ -n "$RESULT_FILE" ] || RESULT_FILE="/tmp/pr-merge-watch-$(printf "%s" "${PRS[0]}" | tr -c "A-Za-z0-9" "-").result"
rm -f "$RESULT_FILE"

finish() { # $1=verdict line, $2=exit code
  echo "$1"
  printf "%s\n" "$1" > "$RESULT_FILE" 2>/dev/null || true
  exit "$2"
}

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

  if [ "$open" -eq 0 ]; then finish "ALL_MERGED" 0; fi
  if [ -n "$red_pr" ]; then finish "CHECK_FAILED $red_pr" 4; fi
  if [ ${#rebase_prs[@]} -gt 0 ]; then finish "NEEDS_REBASE ${rebase_prs[*]}" 3; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then finish "TIMEOUT" 5; fi
  sleep "$INTERVAL"
done
