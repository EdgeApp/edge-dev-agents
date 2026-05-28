#!/usr/bin/env bash
# select-ios-sim.sh — Resolve an iOS simulator UDID by runtime + device name.
#
# Usage:
#   select-ios-sim.sh --runtime <runtime-substring> --device <device-name> [--boot]
#   select-ios-sim.sh --accept-udid <udid> [--boot]
#
#   --runtime: matches the runtime header in `xcrun simctl list devices`.
#              Examples: "iOS 18", "iOS 18.6", "iOS 26".
#              Use "iOS 18" (broad) when you want any 18.x device that matches the device name.
#   --device:  exact device name as it appears in the list (e.g. "iPhone 16 Pro Max").
#   --accept-udid: caller already has a UDID (e.g. a per-slot sim clone) — skip
#              runtime/device resolution entirely, just confirm the UDID exists
#              (and boots, with --boot) and echo it back. Mutually exclusive with
#              --runtime/--device. Watcher-spawned sessions pass $AGENT_SIM_UDID here.
#   --boot:    boot the resolved sim and open Simulator.app.
#
# Prints the UDID on stdout, status messages on stderr.
#
# Exit codes:
#   0 = success (UDID printed on stdout)
#   1 = error (no match, simctl failed)
#   2 = ambiguous (multiple matches; caller must pass a tighter --runtime/--device)

set -euo pipefail

RUNTIME=""
DEVICE=""
ACCEPT_UDID=""
BOOT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)     RUNTIME="$2";     shift 2 ;;
    --device)      DEVICE="$2";      shift 2 ;;
    --accept-udid) ACCEPT_UDID="$2"; shift 2 ;;
    --boot)        BOOT=true;        shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --accept-udid short-circuit: trust a caller-supplied UDID, just verify + (boot).
if [[ -n "$ACCEPT_UDID" ]]; then
  if ! xcrun simctl list devices 2>/dev/null | grep -q "$ACCEPT_UDID"; then
    echo "select-ios-sim: --accept-udid $ACCEPT_UDID not found in simctl device list" >&2
    exit 1
  fi
  echo ">> select-ios-sim: accepting caller UDID $ACCEPT_UDID" >&2
  if $BOOT; then
    xcrun simctl boot "$ACCEPT_UDID" 2>/dev/null || true   # no-op if already booted
    open -a Simulator
    echo ">> select-ios-sim: booted + opened Simulator.app" >&2
  fi
  echo "$ACCEPT_UDID"
  exit 0
fi

[[ -n "$RUNTIME" && -n "$DEVICE" ]] || {
  echo "Usage: select-ios-sim.sh --runtime <runtime> --device <device-name> [--boot]" >&2
  echo "   or: select-ios-sim.sh --accept-udid <udid> [--boot]" >&2
  exit 1
}

# xcrun simctl list devices groups by runtime: "-- iOS 18.6 --" ... "-- iOS 26.3 --"
# Slice the block for the requested runtime, grep the device, extract UDIDs.
UDIDS=$(xcrun simctl list devices 2>/dev/null \
  | sed -n "/^-- $RUNTIME/,/^-- /p" \
  | grep -F "$DEVICE" \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' || true)

count=$(echo "$UDIDS" | grep -c . || true)

if [[ "$count" -eq 0 ]]; then
  echo "No simulator matching runtime=$RUNTIME device=$DEVICE" >&2
  echo "(hint: 'xcrun simctl list devices' to see what's available)" >&2
  exit 1
elif [[ "$count" -gt 1 ]]; then
  echo "Multiple matches for runtime=$RUNTIME device=$DEVICE:" >&2
  echo "$UDIDS" | sed 's/^/  /' >&2
  echo "(narrow --runtime — e.g. 'iOS 18.6' instead of 'iOS 18')" >&2
  exit 2
fi

UDID="$UDIDS"
echo ">> select-ios-sim: $DEVICE / $RUNTIME → $UDID" >&2

if $BOOT; then
  xcrun simctl boot "$UDID" 2>/dev/null || true   # no-op if already booted
  open -a Simulator
  echo ">> select-ios-sim: booted + opened Simulator.app" >&2
fi

echo "$UDID"
