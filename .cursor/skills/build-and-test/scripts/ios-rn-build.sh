#!/usr/bin/env bash
# ios-rn-build.sh — Build + install + launch a React-Native iOS app on a sim.
#
# Detects whether the app is already installed and skips the full RN build path
# (which can take 30-60 min on cold cache). Pass --force-rebuild to always
# rebuild from scratch.
#
# Usage:
#   ios-rn-build.sh --udid <UDID> --bundle-id <co.example.app> [--port <n>] [--force-rebuild]
#
# Env fallbacks (used when the flag is NOT passed): watcher-spawned sessions get
# these exported automatically, so the build targets the slot's sim + Metro port
# without any extra plumbing:
#   --udid  ← $AGENT_SIM_UDID
#   --port  ← $AGENT_METRO_PORT (else 8081)
# When the resolved port differs from 8081, it is passed to `react-native run-ios`
# so the app connects to this slot's Metro instance, not the default one.
#
# Assumes npm (not yarn). edge-react-gui migrated to npm; this script does NOT
# fall back to yarn. If a future repo uses yarn, add a detection branch or use
# the top-level install-deps.sh which auto-detects.
#
# Exit codes:
#   0 = installed/launched successfully
#   1 = build, install, or launch failed
#   2 = simulator not booted (run select-ios-sim.sh --boot first)

set -euo pipefail

UDID=""
BUNDLE_ID=""
PORT=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)          UDID="$2";      shift 2 ;;
    --bundle-id)     BUNDLE_ID="$2"; shift 2 ;;
    --port)          PORT="$2";      shift 2 ;;
    --force-rebuild) FORCE=true;     shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Fall back to the watcher-provided env when flags are omitted.
UDID="${UDID:-${AGENT_SIM_UDID:-}}"
PORT="${PORT:-${AGENT_METRO_PORT:-8081}}"

[[ -n "$UDID" && -n "$BUNDLE_ID" ]] || {
  echo "Usage: ios-rn-build.sh --udid <UDID> --bundle-id <id> [--port <n>] [--force-rebuild]" >&2
  echo "  (--udid may instead come from \$AGENT_SIM_UDID)" >&2
  exit 1
}

# Confirm sim is booted
if ! xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1; then
  echo ">> ios-rn-build: simulator $UDID is not booted; run select-ios-sim.sh --boot first" >&2
  exit 2
fi

# Already installed?
if ! $FORCE && xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
  echo ">> ios-rn-build: $BUNDLE_ID already installed on $UDID; launching only" >&2
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  echo ">> ios-rn-build: PASS (cached install, launched)"
  exit 0
fi

# Full build path
echo ">> ios-rn-build: npm install" >&2
npm install --no-audit --no-fund

echo ">> ios-rn-build: npm run prepare" >&2
npm run prepare

echo ">> ios-rn-build: npm run prepare.ios" >&2
npm run prepare.ios

RUN_ARGS=(--udid "$UDID")
if [[ "$PORT" != "8081" ]]; then
  RUN_ARGS+=(--port "$PORT")
  echo ">> ios-rn-build: using non-default Metro port $PORT" >&2
fi
echo ">> ios-rn-build: npx react-native run-ios ${RUN_ARGS[*]}  (cold build: 30-60 min)" >&2
npx react-native run-ios "${RUN_ARGS[@]}"

echo ">> ios-rn-build: PASS (fresh build, installed, launched)"
