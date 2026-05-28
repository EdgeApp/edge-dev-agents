#!/usr/bin/env bash
# clone-ios-sim.sh — Clone the master iOS simulator into a per-slot sim.
#
# The master is the iOS 18 "iPhone 16 Pro Max" device that holds the test
# account (edge-rjqa3 / PIN 1111). Each parallel agent slot gets its own clone so
# concurrent UI tests don't fight over one simulator.
#
# Usage:
#   clone-ios-sim.sh --name <clone-name> [--master <name-or-udid>] [--runtime <substr>] [--device <name>]
#
#   --name     REQUIRED. Name for the clone, e.g. "agent-slot-0". Used for idempotency:
#              if a device with this name already exists, its UDID is returned and no
#              new clone is made.
#   --master   Master device name or UDID to clone. If omitted, resolved from
#              --device + --runtime (defaults below).
#   --runtime  Runtime substring for master resolution (default "iOS 18").
#   --device   Device name for master resolution (default "iPhone 16 Pro Max").
#
# Prints the clone's UDID on stdout, status on stderr.
#
# Idempotent: re-running with the same --name returns the existing clone's UDID.
#
# Exit codes:
#   0 = success (UDID on stdout)
#   1 = error (master not found, clone failed)
#   2 = ambiguous master (multiple matches; pass --master <udid>)

set -euo pipefail

NAME=""
MASTER=""
RUNTIME="iOS 18"
DEVICE="iPhone 16 Pro Max"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    NAME="$2";    shift 2 ;;
    --master)  MASTER="$2";  shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    --device)  DEVICE="$2";  shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$NAME" ]] || { echo "Usage: clone-ios-sim.sh --name <clone-name> [--master <name-or-udid>]" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "xcrun not found (install Xcode CLT)" >&2; exit 1; }

udid_for_name() {
  # Exact device-name match anywhere in the device list → first matching UDID.
  xcrun simctl list devices 2>/dev/null \
    | grep -F "$1 (" \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
    | head -1 || true
}

device_state() {
  # Prints the parenthesized state for a UDID, e.g. Booted / Shutdown.
  xcrun simctl list devices 2>/dev/null | grep -F "$1" | grep -oE '\(Booted\)|\(Shutdown\)|\(Shutting Down\)|\(Booting\)' | head -1 | tr -d '()'
}

wait_for_shutdown() {
  # simctl shutdown is async — poll until the device reaches Shutdown (≤30s).
  local udid="$1" i
  for ((i = 0; i < 30; i++)); do
    [[ "$(device_state "$udid")" == "Shutdown" ]] && return 0
    sleep 1
  done
  return 1
}

delete_by_name() {
  # Remove any (possibly half-created) device with this name.
  local u
  for u in $(xcrun simctl list devices 2>/dev/null | grep -F "$1 (" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'); do
    xcrun simctl delete "$u" >/dev/null 2>&1 || true
  done
}

# Idempotency: a clone with this name already exists → return it, do not re-clone.
EXISTING=$(udid_for_name "$NAME")
if [[ -n "$EXISTING" ]]; then
  echo ">> clone-ios-sim: clone '$NAME' already exists → $EXISTING" >&2
  echo "$EXISTING"
  exit 0
fi

# Resolve the master UDID.
if [[ -z "$MASTER" ]]; then
  UDIDS=$(xcrun simctl list devices 2>/dev/null \
    | sed -n "/^-- $RUNTIME/,/^-- /p" \
    | grep -F "$DEVICE (" \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' || true)
  count=$(echo "$UDIDS" | grep -c . || true)
  if [[ "$count" -eq 0 ]]; then
    echo "No master simulator matching runtime='$RUNTIME' device='$DEVICE'" >&2
    exit 1
  elif [[ "$count" -gt 1 ]]; then
    echo "Multiple master candidates for runtime='$RUNTIME' device='$DEVICE':" >&2
    echo "$UDIDS" | sed 's/^/  /' >&2
    echo "(pass --master <udid> to disambiguate)" >&2
    exit 2
  fi
  MASTER="$UDIDS"
fi

# `simctl clone` refuses a BOOTED source (CoreSimulator err 405). The master is
# only a template — its data volume (test account, PIN, wallet) persists across a
# shutdown — so we shut it down to clone, then restore its prior booted state.
# Consumers (select-ios-sim --boot) boot on demand regardless, so this is safe.
if [[ "$MASTER" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  MASTER_UDID="$MASTER"
else
  MASTER_UDID=$(udid_for_name "$MASTER")
fi

MASTER_WAS_BOOTED=false
if [[ -n "$MASTER_UDID" ]] && [[ "$(device_state "$MASTER_UDID")" == "Booted" ]]; then
  MASTER_WAS_BOOTED=true
  echo ">> clone-ios-sim: master is booted; shutting down to clone (data persists)" >&2
  xcrun simctl shutdown "$MASTER_UDID" >/dev/null 2>&1 || true
  if ! wait_for_shutdown "$MASTER_UDID"; then
    echo ">> clone-ios-sim: WARN — master did not reach Shutdown in time; cloning anyway" >&2
  fi
fi

echo ">> clone-ios-sim: cloning master '$MASTER' → '$NAME'" >&2
if ! CLONE_UDID=$(xcrun simctl clone "$MASTER" "$NAME" 2>/tmp/clone-ios-sim.err); then
  echo "clone failed:" >&2
  cat /tmp/clone-ios-sim.err >&2
  delete_by_name "$NAME"   # drop any half-created device so re-runs stay idempotent
  $MASTER_WAS_BOOTED && xcrun simctl boot "$MASTER_UDID" >/dev/null 2>&1 || true
  exit 1
fi

# Restore the master's prior booted state (best-effort; boot returns promptly).
if $MASTER_WAS_BOOTED; then
  xcrun simctl boot "$MASTER_UDID" >/dev/null 2>&1 || true
  echo ">> clone-ios-sim: re-booted master to restore prior state" >&2
fi

echo ">> clone-ios-sim: created $NAME → $CLONE_UDID" >&2
echo "$CLONE_UDID"
