#!/usr/bin/env bash
# watch-pr.sh — single bounded `gh pr checks --watch` call against a shared
# per-task 30-minute deadline. Owns the budget arithmetic that one-shot's
# pr-watch-bounded-poll rule used to spell out in prose.
#
# First call for a task computes deadline = now + budget and persists it; every
# subsequent call bounds its watch by the remaining budget. One blocking call per
# invocation. No loops, no respawned processes (never-self-respawn).
#
# Usage: watch-pr.sh --pr <num> [--repo <owner/name>] [--task-gid <gid>]
#                    [--budget-seconds 1800] [--interval 30]
# Exit: 0   all checks pass
#       1   a check failed (read `gh run view --log-failed`, fix, amend, re-run)
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

ARGS=(pr checks "$PR" --watch --interval "$INTERVAL")
[ -n "$REPO" ] && ARGS+=(--repo "$REPO")
timeout "$REMAINING" gh "${ARGS[@]}"
