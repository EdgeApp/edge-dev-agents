#!/usr/bin/env bash
# restore-sim-app-container.sh — restore the Edge app's DATA container on a sim
# from a healthy donor sim (the master, or a provisioned pool sim).
#
# Why: `simctl uninstall` deletes the app's data container — including the
# logged-in test account, which cannot be re-provisioned without a manual login.
# When a slot sim loses its account (wipe, bad uninstall fallback), the recovery
# is an APFS-clone copy of a donor's container subdirs — never re-onboarding,
# and never ad-hoc rm -rf/cp typed by an agent (the 2026-07-21 wallet-cache run
# parked 87 minutes on the destructive-command dialog doing exactly that by hand).
#
# Usage: restore-sim-app-container.sh --to <udid> [--from <udid>] [--bundle <id>] [--plan]
#   --from   Donor sim udid. Default: auto — prefer the master ("iPhone 16 Pro
#            Max"), else any other pool sim whose container has Documents/logins.
#   --plan   Resolve donor + containers and print the plan without copying.
#
# The target app is terminated first. The target must have the app INSTALLED
# (this restores DATA only; reinstall the app first if the bundle is gone).
# Exit: 0 = restored (or plan printed), 1 = error, 2 = usage.

set -uo pipefail

BUNDLE="co.edgesecure.app"
TO="" FROM="" PLAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) TO="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    --plan) PLAN=1; shift ;;
    *) echo "restore-sim-app-container: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$TO" ]] || { echo "usage: restore-sim-app-container.sh --to <udid> [--from <udid>] [--bundle <id>] [--plan]" >&2; exit 2; }

# Locate a sim's data container for the bundle id. Prints the path or nothing.
container_for() {
  local udid="$1" d c id
  d="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Data/Application"
  [[ -d "$d" ]] || return 0
  for c in "$d"/*/; do
    id=$(plutil -extract MCMMetadataIdentifier raw "$c/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null)
    [[ "$id" == "$BUNDLE" ]] && { echo "$c"; return 0; }
  done
}

# A donor is healthy when its container carries logged-in account state.
healthy() { [[ -n "$1" && -d "$1/Documents/logins" ]] && [[ -n "$(ls "$1/Documents/logins" 2>/dev/null)" ]]; }

TARGET_C="$(container_for "$TO")"
[[ -n "$TARGET_C" ]] || { echo "restore-sim-app-container: target $TO has no $BUNDLE data container — install the app first, then re-run" >&2; exit 1; }

DONOR="" DONOR_C=""
if [[ -n "$FROM" ]]; then
  DONOR="$FROM"; DONOR_C="$(container_for "$FROM")"
  healthy "$DONOR_C" || { echo "restore-sim-app-container: donor $FROM has no healthy container (no Documents/logins)" >&2; exit 1; }
else
  # Auto: master first, then pool sims (excluding the target).
  MASTER=$(xcrun simctl list devices 2>/dev/null | grep -E "^\s+iPhone 16 Pro Max \(" | grep -oE '[0-9A-F-]{36}' | head -1)
  POOL_UDIDS=$(jq -r '.pool[]?.udid // empty' "${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/pool.json" 2>/dev/null)
  for u in $MASTER $POOL_UDIDS; do
    [[ "$u" == "$TO" ]] && continue
    c="$(container_for "$u")"
    if healthy "$c"; then DONOR="$u"; DONOR_C="$c"; break; fi
  done
  [[ -n "$DONOR" ]] || { echo "restore-sim-app-container: no healthy donor found (master or pool sim with Documents/logins)" >&2; exit 1; }
fi

echo ">> restore-sim-app-container: $BUNDLE"
echo ">>   donor:  $DONOR"
echo ">>     $DONOR_C"
echo ">>   target: $TO"
echo ">>     $TARGET_C"
if [[ "$PLAN" == 1 ]]; then echo ">>   plan only — no copy performed"; exit 0; fi

xcrun simctl terminate "$TO" "$BUNDLE" 2>/dev/null || true
RESTORED=0
for SUB in Documents Library tmp SystemData; do
  [[ -d "$DONOR_C/$SUB" ]] || continue
  rm -rf "${TARGET_C:?}/$SUB"
  if cp -Rc "$DONOR_C/$SUB" "$TARGET_C/$SUB" 2>/dev/null || cp -R "$DONOR_C/$SUB" "$TARGET_C/$SUB"; then
    echo ">>   restored $SUB"
    RESTORED=$((RESTORED + 1))
  else
    echo "restore-sim-app-container: copy failed for $SUB" >&2; exit 1
  fi
done
[[ "$RESTORED" -gt 0 ]] || { echo "restore-sim-app-container: donor container had none of Documents/Library/tmp/SystemData" >&2; exit 1; }
echo ">>   done — relaunch the app; it should log in from the restored account"
