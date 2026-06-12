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
command -v timeout >/dev/null || { echo "ERROR: timeout not on PATH (shim: ~/.cursor/skills/timeout.sh)" >&2; exit 2; }

# Deadline is per task (falls back to per PR for ad-hoc use), shared across calls.
DEADLINE_FILE="/tmp/agent-watch-deadline-${TASK_GID:-pr$PR}"
NOW=$(date +%s)
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
echo ">> watch-pr: ${REMAINING}s of budget remain; watching PR #$PR" >&2

ARGS=(pr checks "$PR" --watch --interval "$INTERVAL")
[ -n "$REPO" ] && ARGS+=(--repo "$REPO")
timeout "$REMAINING" gh "${ARGS[@]}"
