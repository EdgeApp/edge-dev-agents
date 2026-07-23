#!/usr/bin/env bash
# sim-app-reinstall.sh — install/upgrade the Edge app on a sim WITHOUT losing
# the logged-in account.
#
# `simctl install` over an existing app upgrades IN PLACE and preserves the data
# container (the account). `simctl uninstall` deletes the data container — that
# is the account-destroying move this script exists to avoid. Escalation ladder:
#   1. In-place `simctl install` (preserves data).
#   2. On failure (CoreSimulator "Could not hardlink copy" and friends):
#      shutdown + boot the sim, retry the in-place install.
#   3. Still failing: uninstall + install + restore the data container from a
#      healthy donor via restore-sim-app-container.sh — account-safe end state.
#
# Usage: sim-app-reinstall.sh --udid <u> --app <path/to/Edge.app> [--bundle <id>]
# Exit: 0 = installed with account intact, 1 = error, 2 = usage.

set -uo pipefail

DIR="$HOME/.config/agent-watcher"
BUNDLE="co.edgesecure.app"
UDID="" APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    *) echo "sim-app-reinstall: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$UDID" && -n "$APP" ]] || { echo "usage: sim-app-reinstall.sh --udid <u> --app <path/to/Edge.app> [--bundle <id>]" >&2; exit 2; }
[[ -d "$APP" ]] || { echo "sim-app-reinstall: app bundle not found: $APP" >&2; exit 1; }

try_install() { xcrun simctl install "$UDID" "$APP" 2>&1; }

echo ">> sim-app-reinstall: in-place install on $UDID"
OUT=$(try_install) && { echo ">>   installed (data container preserved)"; exit 0; }
echo ">>   in-place install failed: $(echo "$OUT" | head -2 | tr '\n' ' ')"

echo ">> sim-app-reinstall: rebooting sim and retrying"
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || sleep 10
OUT=$(try_install) && { echo ">>   installed after reboot (data container preserved)"; exit 0; }
echo ">>   retry failed: $(echo "$OUT" | head -2 | tr '\n' ' ')"

echo ">> sim-app-reinstall: falling back to uninstall + install + account restore"
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
OUT=$(try_install) || { echo "sim-app-reinstall: install still failing after uninstall: $OUT" >&2; exit 1; }
echo ">>   installed fresh; restoring account container"
"$DIR/restore-sim-app-container.sh" --to "$UDID" --bundle "$BUNDLE" || {
  echo "sim-app-reinstall: app installed but ACCOUNT RESTORE FAILED — the sim has no logged-in account; re-run restore-sim-app-container.sh manually" >&2
  exit 1
}
echo ">>   done — app upgraded, account intact"
