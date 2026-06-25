#!/usr/bin/env bash
# delete-ios-sim.sh — Tear down a per-slot iOS simulator clone (shut down, then delete).
#
# The simctl sim-teardown helper session-watchdog.js uses (it must NOT inline simctl
# calls — DRY). Pairs with clone-ios-sim.sh.
#
# Usage:
#   delete-ios-sim.sh --udid <udid> [--shutdown-only]
#     --shutdown-only  shut the sim down but do NOT delete it. Used by the watchdog's
#                      idle-pool reclaim: a dirty (released, pending-refresh) pool sim
#                      provides zero allocatable value while booted, so shut it down to
#                      free CPU/RAM; ensure-sim-pool still does the clean delete+re-clone
#                      on the next spawn. (delete needs the sim to exist; shutdown-only
#                      leaves it present for that later refresh.)
#
# Best-effort: shutting down an already-shut sim, or deleting a sim that's
# already gone, is treated as success. NEVER pass the master sim's UDID here —
# callers (watchdog, gc, cleanup) only pass UDIDs they read out of slots.json/pool.json,
# which only ever hold clones.
#
# Exit codes:
#   0 = sim deleted / shut down (or already absent)
#   1 = delete failed for a present sim
#   2 = usage error

set -euo pipefail

UDID=""
SHUTDOWN_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)          UDID="$2"; shift 2 ;;
    --shutdown-only) SHUTDOWN_ONLY=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$UDID" ]] || { echo "Usage: delete-ios-sim.sh --udid <udid> [--shutdown-only]" >&2; exit 2; }
command -v xcrun >/dev/null 2>&1 || { echo "xcrun not found (install Xcode CLT)" >&2; exit 1; }

# Already gone? Nothing to do.
if ! xcrun simctl list devices 2>/dev/null | grep -q "$UDID"; then
  echo ">> delete-ios-sim: $UDID not present (already deleted)" >&2
  exit 0
fi

xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true  # no-op if already shut down

if [[ "$SHUTDOWN_ONLY" == true ]]; then
  echo ">> delete-ios-sim: shut down $UDID (--shutdown-only; left present for ensure-sim-pool refresh)" >&2
  exit 0
fi

if xcrun simctl delete "$UDID" >/dev/null 2>&1; then
  echo ">> delete-ios-sim: deleted $UDID" >&2
  exit 0
fi

echo "delete-ios-sim: FAILED to delete $UDID" >&2
exit 1
