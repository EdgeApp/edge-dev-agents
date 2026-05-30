#!/usr/bin/env bash
# allocate-from-pool.sh — Atomically pull a free entry from the sim pool and
# mark it in_use for a task. Prints the UDID on stdout, status on stderr.
#
# Usage:
#   allocate-from-pool.sh --task-gid <gid>
#
# Exit codes:
#   0 = allocated (UDID on stdout)
#   1 = no free entries in pool (caller must run ensure-sim-pool.sh first)
#   2 = pool file missing or malformed

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

[[ -n "$TASK_GID" ]] || { echo "Usage: allocate-from-pool.sh --task-gid <gid>" >&2; exit 1; }
[[ -f "$POOL"      ]] || { echo "Pool file missing: $POOL (run ensure-sim-pool.sh first)" >&2; exit 2; }

# Lock + atomic JSON update.
i=0
while ! ( set -C; : > "$LOCK" ) 2>/dev/null; do
  i=$((i + 1))
  [[ $i -gt 300 ]] && { echo "Could not acquire $LOCK after 30s" >&2; exit 1; }
  sleep 0.1
done
trap 'rm -f "$LOCK"' EXIT

POOL_JSON=$(cat "$POOL")

# Find first slot in state=free.
SLOT=$(jq -r '[.pool[] | select(.state == "free")] | first | .slot // empty' <<<"$POOL_JSON")
if [[ -z "$SLOT" ]]; then
  FREE_COUNT=$(jq '[.pool[] | select(.state == "free")] | length' <<<"$POOL_JSON")
  TOTAL=$(jq '.pool | length' <<<"$POOL_JSON")
  echo ">> allocate-from-pool: no free entries (free=$FREE_COUNT total=$TOTAL)" >&2
  exit 1
fi

UDID=$(jq -r --arg s "$SLOT" '.pool[] | select(.slot == ($s | tonumber)) | .udid' <<<"$POOL_JSON")
if [[ -z "$UDID" || "$UDID" == "null" ]]; then
  echo ">> allocate-from-pool: slot $SLOT has no UDID; pool is corrupt" >&2
  exit 2
fi

# Mark in_use with task_gid.
NEW_JSON=$(jq --arg s "$SLOT" --arg t "$TASK_GID" \
  '(.pool[] | select(.slot == ($s | tonumber)).state) = "in_use"
   | (.pool[] | select(.slot == ($s | tonumber)).task_gid) = $t' <<<"$POOL_JSON")
tmp=$(mktemp)
jq . > "$tmp" <<<"$NEW_JSON"
mv "$tmp" "$POOL"

echo ">> allocate-from-pool: slot $SLOT → $UDID (task $TASK_GID)" >&2
echo "$UDID"
