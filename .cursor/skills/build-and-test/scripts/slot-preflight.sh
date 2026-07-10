#!/usr/bin/env bash
# slot-preflight.sh — one-call situational readout (and cheap repair) of a testing slot
# BEFORE the agent starts guessing build/test steps.
#
# Why: testing friction is dominated by DECISIONS the agent re-derives per run (is the
# sim booted? is my Metro port free or already mine? is the installed app's native side
# current, i.e. full rebuild vs JS-only?). The 2026-07-09 combined eval showed hour-scale
# pre-drive grind and repeated build attempts. This script answers those questions
# deterministically in one call and performs the safe repairs (boot the sim) itself.
#
# Usage: slot-preflight.sh [--udid <udid>] [--bundle-id <id>] [--port <metro-port>] [--repo <dir>]
#   Defaults: $AGENT_SIM_UDID, co.edgesecure.app, $AGENT_METRO_PORT, cwd.
#
# Output: one VERDICT line per check (grep-able), then a final PLAN line:
#   PLAN: ready | js-only | full-rebuild | install   — feed the matching ios-rn-build.sh
#   invocation; no other build decision needed.
# Exit: 0 always when the readout completes (the PLAN is the answer); 1 on usage error.

set -uo pipefail

UDID="${AGENT_SIM_UDID:-}"
BUNDLE_ID="co.edgesecure.app"
PORT="${AGENT_METRO_PORT:-8081}"
REPO_DIR="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --repo) REPO_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$UDID" ]] || { echo "slot-preflight: no --udid and \$AGENT_SIM_UDID unset" >&2; exit 1; }

PLAN="ready"
bump() { # escalate the plan: ready < install < js-only < full-rebuild
  local order="ready install js-only full-rebuild" cur_i=0 new_i=0 i=0 w
  for w in $order; do [[ "$w" == "$PLAN" ]] && cur_i=$i; [[ "$w" == "$1" ]] && new_i=$i; i=$((i+1)); done
  [[ "$new_i" -gt "$cur_i" ]] && PLAN="$1"
}

# 1. Sim exists + booted (safe repair: boot it).
STATE="$(xcrun simctl list devices 2>/dev/null | grep -F "$UDID" | grep -oE '\((Booted|Shutdown|Creating)\)' | tr -d '()' || true)"
if [[ -z "$STATE" ]]; then
  echo "SIM: MISSING — $UDID not in simctl list (slot broken; re-allocate via the watcher, do not clone manually)"
  echo "PLAN: full-rebuild"
  exit 0
elif [[ "$STATE" != "Booted" ]]; then
  echo "SIM: $STATE — booting now"
  xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
  echo "SIM: booted ($UDID)"
else
  echo "SIM: booted ($UDID)"
fi

# 2. Metro port: free, OURS (a metro serving this repo), or SQUATTED (another process).
PORT_PID="$(lsof -ti tcp:"$PORT" 2>/dev/null | head -1 || true)"
if [[ -z "$PORT_PID" ]]; then
  echo "METRO: port $PORT free — ios-rn-build.sh will start Metro"
else
  PORT_CMD="$(ps -o command= -p "$PORT_PID" 2>/dev/null || true)"
  if printf '%s' "$PORT_CMD" | grep -qE 'metro|react-native|node'; then
    echo "METRO: running on $PORT (pid $PORT_PID) — reuse it, do NOT start a second Metro"
  else
    echo "METRO: PORT $PORT SQUATTED by non-Metro pid $PORT_PID ($(printf '%s' "$PORT_CMD" | cut -c1-60)) — kill it or use the slot's assigned port"
    bump install
  fi
fi

# 3. App installed on this sim?
DATA_DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
if [[ -z "$DATA_DIR" ]]; then
  echo "APP: $BUNDLE_ID NOT installed on this sim"
  bump full-rebuild
else
  echo "APP: installed"
  # 4. Native drift: installed app's stamp vs the worktree's ios/Podfile.lock.
  #    (Same stamp ios-rn-build.sh writes; clones inherit it from the master via APFS.)
  STAMP_FILE="$DATA_DIR/.agent-native-build-stamp"
  HAVE="$(cat "$STAMP_FILE" 2>/dev/null || echo "no-stamp")"
  if [[ -f "$REPO_DIR/ios/Podfile.lock" ]]; then
    WANT="$(shasum -a 256 "$REPO_DIR/ios/Podfile.lock" | cut -c1-16)"
  else
    WANT="no-podfile-lock"
  fi
  if [[ "$HAVE" == "$WANT" ]]; then
    echo "NATIVE: stamp match ($HAVE) — JS bundles live from Metro; NO rebuild needed"
  elif [[ "$HAVE" == "no-stamp" ]]; then
    echo "NATIVE: no stamp on installed app (pre-stamp build) — full rebuild to establish baseline"
    bump full-rebuild
  else
    echo "NATIVE: DRIFT (installed $HAVE vs worktree $WANT) — native deps changed; full rebuild required"
    bump full-rebuild
  fi
fi

# 5. Worktree sanity: node_modules present (else install-deps first).
if [[ ! -d "$REPO_DIR/node_modules" ]]; then
  echo "DEPS: node_modules missing in $REPO_DIR — run ~/.cursor/skills/install-deps.sh first"
  bump full-rebuild
else
  echo "DEPS: node_modules present"
fi

echo "PLAN: $PLAN"
