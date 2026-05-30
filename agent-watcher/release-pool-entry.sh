#!/usr/bin/env bash
# release-pool-entry.sh — Mark the pool entry currently held by a task as dirty,
# so the next ensure-sim-pool.sh run refreshes it (delete stale sim, clone fresh).
#
# Called by the watchdog when a task reaches Complete. Best-effort: if the task
# isn't found in the pool (e.g. bootstrapped session that bypassed the pool),
# this script exits 0 with a notice on stderr — does NOT fail.
#
# Usage:
#   release-pool-entry.sh --task-gid <gid>
#
# Exit codes:
#   0 = released (or task not found — non-fatal)
#   1 = pool file missing / malformed

set -euo pipefail

DIR="$HOME/.config/agent-watcher"
POOL="$DIR/pool.json"
LOCK="$DIR/pool.lock"

TASK_GID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-gid) TASK_GID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$TASK_GID" ]] || { echo "Usage: release-pool-entry.sh --task-gid <gid>" >&2; exit 1; }
if [[ ! -f "$POOL" ]]; then
  echo ">> release-pool-entry: no pool file at $POOL — nothing to release" >&2
  exit 0
fi

i=0
while ! ( set -C; : > "$LOCK" ) 2>/dev/null; do
  i=$((i + 1))
  [[ $i -gt 300 ]] && { echo "Could not acquire $LOCK after 30s" >&2; exit 1; }
  sleep 0.1
done
trap 'rm -f "$LOCK"' EXIT

POOL_JSON=$(cat "$POOL")

SLOT=$(jq -r --arg t "$TASK_GID" '.pool[] | select(.task_gid == $t) | .slot' <<<"$POOL_JSON" | head -1)
if [[ -z "$SLOT" ]]; then
  echo ">> release-pool-entry: no pool slot held by task $TASK_GID (likely bootstrapped); nothing to release" >&2
  exit 0
fi

NEW_JSON=$(jq --arg s "$SLOT" \
  '(.pool[] | select(.slot == ($s | tonumber)).state) = "dirty"
   | (.pool[] | select(.slot == ($s | tonumber)).task_gid) = null' <<<"$POOL_JSON")
tmp=$(mktemp)
jq . > "$tmp" <<<"$NEW_JSON"
mv "$tmp" "$POOL"

echo ">> release-pool-entry: slot $SLOT marked dirty (was task $TASK_GID)" >&2
