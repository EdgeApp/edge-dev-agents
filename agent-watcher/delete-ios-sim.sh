#!/usr/bin/env bash
# delete-ios-sim.sh — Shut down and delete a per-slot iOS simulator clone.
#
# The simctl-delete helper session-watchdog.js uses during its completion sweep (it
# must NOT inline simctl calls — DRY). Pairs with clone-ios-sim.sh.
#
# Usage:
#   delete-ios-sim.sh --udid <udid>
#
# Best-effort: shutting down an already-shut sim, or deleting a sim that's
# already gone, is treated as success. NEVER pass the master sim's UDID here —
# callers (watchdog, gc, cleanup) only pass UDIDs they read out of slots.json,
# which only ever holds clones.
#
# Exit codes:
#   0 = sim deleted (or already absent)
#   1 = delete failed for a present sim
#   2 = usage error

set -euo pipefail

UDID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$UDID" ]] || { echo "Usage: delete-ios-sim.sh --udid <udid>" >&2; exit 2; }
command -v xcrun >/dev/null 2>&1 || { echo "xcrun not found (install Xcode CLT)" >&2; exit 1; }

# Already gone? Nothing to do.
if ! xcrun simctl list devices 2>/dev/null | grep -q "$UDID"; then
  echo ">> delete-ios-sim: $UDID not present (already deleted)" >&2
  exit 0
fi

xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true  # no-op if already shut down

if xcrun simctl delete "$UDID" >/dev/null 2>&1; then
  echo ">> delete-ios-sim: deleted $UDID" >&2
  exit 0
fi

echo "delete-ios-sim: FAILED to delete $UDID" >&2
exit 1
