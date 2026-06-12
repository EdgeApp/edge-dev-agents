#!/usr/bin/env bash
# ios-rn-build.sh — Build + install + launch a React-Native iOS app on a sim.
#
# Detects whether the app is already installed and skips the full RN build path.
# A real build here is usually only a FEW MINUTES — the Hermes prebuilt tarball is
# prefetched below, which avoids the slow (~40 min) build-from-source; warm Xcode +
# APFS-cloned node_modules keep the rest fast. Pass --force-rebuild to always rebuild.
#
# Usage:
#   ios-rn-build.sh --udid <UDID> --bundle-id <co.example.app> [--port <n>] [--force-rebuild] [--skip-install]
#
# Env fallbacks (used when the flag is NOT passed): watcher-spawned sessions get
# these exported automatically, so the build targets the slot's sim + Metro port
# without any extra plumbing:
#   --udid  ← $AGENT_SIM_UDID
#   --port  ← $AGENT_METRO_PORT (else 8081)
# When the resolved port differs from 8081, it is passed to `react-native run-ios`
# so the app connects to this slot's Metro instance, not the default one.
#
# Package manager is auto-detected from the lockfile via the shared dispatcher
# ~/.cursor/skills/pm.sh (package-lock.json -> npm, yarn.lock -> yarn). Do not
# hardcode npm or yarn here; repos migrate between them.
#
# --skip-install skips `<pm> install` (still runs prepare/prepare.ios). Use it
# when node_modules was just provisioned (e.g. APFS-cloned by
# setup-task-workspace.sh) and the branch has no dependency changes — a
# re-install on a near-identical tree wastes minutes and, across npm/yarn
# migrations, can corrupt an otherwise-usable tree.
#
# Exit codes:
#   0 = installed/launched successfully
#   1 = build, install, or launch failed
#   2 = simulator not booted (run select-ios-sim.sh --boot first)

set -euo pipefail

# CocoaPods (pod install via prepare.ios) requires a UTF-8 locale; headless
# agent shells often have no LANG set, which crashes pod with
# "Unicode Normalization not appropriate for ASCII-8BIT".
export LANG="${LANG:-en_US.UTF-8}"

PM_SH="$HOME/.cursor/skills/pm.sh"

UDID=""
BUNDLE_ID=""
PORT=""
FORCE=false
SKIP_INSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)          UDID="$2";      shift 2 ;;
    --bundle-id)     BUNDLE_ID="$2"; shift 2 ;;
    --port)          PORT="$2";      shift 2 ;;
    --force-rebuild) FORCE=true;     shift ;;
    --skip-install)  SKIP_INSTALL=true; shift ;;
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

# Confirm sim is booted. (get_app_container returns a false negative on a SHUT or
# never-booted clone — even though the clone DOES inherit the app from the master
# via APFS copy-on-write — so we MUST boot before checking, or we'd trigger a
# needless rebuild (minutes) that also wipes the cloned login state.)
if ! xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1; then
  echo ">> ios-rn-build: simulator $UDID is not booted; run select-ios-sim.sh --boot first" >&2
  exit 2
fi

# Foreign-Metro guard: if $PORT is already LISTENed by a process from a DIFFERENT
# directory (a stale/foreign Metro from another slot or a dead session), the app
# would silently bundle from the WRONG repo's Metro (red "No script URL" screen, or
# worse, another task's code). Fail loudly so the caller frees the port. Used by
# BOTH the cached-launch and the full-build paths.
assert_metro_port_free_or_ours() {
  local pid cwd
  pid="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  [[ -z "$pid" ]] && return 0
  cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  if [[ "$cwd" != "$PWD" ]]; then
    echo ">> ios-rn-build: FAIL — Metro port $PORT is held by PID $pid (cwd: ${cwd:-unknown}), not this repo. Free it or pass a free --port." >&2
    exit 1
  fi
  echo ">> ios-rn-build: reusing Metro already running on port $PORT for this repo" >&2
}

# Already installed? (sim is booted now, so this is an accurate check.)
if ! $FORCE && xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
  echo ">> ios-rn-build: $BUNDLE_ID already installed on $UDID; launching only (port $PORT)" >&2
  # The cached app was baked for some default packager host; on a non-8081 slot it
  # would connect to the wrong/foreign Metro. Guard the port and PIN the app to THIS
  # slot's Metro before launching, so it bundles from the right place.
  assert_metro_port_free_or_ours
  # The full-build path gets Metro implicitly from run-ios; the cached path got NOTHING —
  # the app launched pinned to a port nobody was listening on ("No script URL" hang).
  # Start one if the port is free, with a bounded readiness probe against the real port.
  if [[ -z "$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)" ]]; then
    echo ">> ios-rn-build: no Metro on port $PORT; starting one for the cached launch (log: /tmp/metro-$PORT.log)" >&2
    nohup npx react-native start --port "$PORT" >/tmp/metro-"$PORT".log 2>&1 &
    METRO_READY=false
    for _ in $(seq 1 60); do
      if curl -fsS --max-time 2 "http://localhost:$PORT/status" 2>/dev/null | grep -q "packager-status:running"; then
        METRO_READY=true; break
      fi
      sleep 2
    done
    if ! $METRO_READY; then
      echo ">> ios-rn-build: FAIL — Metro did not become ready on port $PORT within 120s (see /tmp/metro-$PORT.log)" >&2
      exit 1
    fi
    echo ">> ios-rn-build: Metro ready on port $PORT" >&2
  fi
  xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" RCT_jsLocation "localhost:$PORT" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  echo ">> ios-rn-build: PASS (cached install, launched on Metro port $PORT)"
  exit 0
fi

# Full build path
PM="$("$PM_SH" detect)"
if $SKIP_INSTALL && [[ -d node_modules ]]; then
  echo ">> ios-rn-build: --skip-install (node_modules present; pm=$PM)" >&2
else
  echo ">> ios-rn-build: $PM install (via pm.sh)" >&2
  "$PM_SH" install
fi

echo ">> ios-rn-build: $PM run prepare (via pm.sh)" >&2
"$PM_SH" run prepare

# Hermes: the podspec probes repo1.maven.org with curl to decide
# prebuilt-tarball vs build-from-source. Under the sfw package-firewall shim
# (agent shells), that probe inherits a proxy that fails, silently flipping
# hermes to build-from-source (needs cmake/make, ~40 min). Pre-fetch the
# debug tarball with plain curl and pin it; harmless no-op if the fetch
# fails or the var is already set. (This script always builds Debug.)
RN_VER="$(node -p "require('./node_modules/react-native/package.json').version" 2>/dev/null || true)"
if [[ -n "$RN_VER" && -z "${HERMES_ENGINE_TARBALL_PATH:-}" ]]; then
  HERMES_TARBALL="/tmp/hermes-ios-debug-$RN_VER.tar.gz"
  HERMES_URL="https://repo1.maven.org/maven2/com/facebook/react/react-native-artifacts/$RN_VER/react-native-artifacts-$RN_VER-hermes-ios-debug.tar.gz"
  if [[ ! -s "$HERMES_TARBALL" ]]; then
    echo ">> ios-rn-build: pre-fetching hermes prebuilt tarball ($RN_VER)" >&2
    curl -fsSL -o "$HERMES_TARBALL" "$HERMES_URL" || rm -f "$HERMES_TARBALL"
  fi
  if [[ -s "$HERMES_TARBALL" ]]; then
    export HERMES_ENGINE_TARBALL_PATH="$HERMES_TARBALL"
    echo ">> ios-rn-build: HERMES_ENGINE_TARBALL_PATH=$HERMES_TARBALL" >&2
  fi
fi

echo ">> ios-rn-build: $PM run prepare.ios (via pm.sh)" >&2
"$PM_SH" run prepare.ios

# Refuse to race a foreign Metro before the (long) build: otherwise run-ios hangs on
# an interactive "use another port?" prompt and can exit 0 without building.
assert_metro_port_free_or_ours

RUN_ARGS=(--udid "$UDID")
if [[ "$PORT" != "8081" ]]; then
  RUN_ARGS+=(--port "$PORT")
  echo ">> ios-rn-build: using non-default Metro port $PORT" >&2
fi
echo ">> ios-rn-build: npx react-native run-ios ${RUN_ARGS[*]}  (usually a few minutes)" >&2
RUN_LOG="/tmp/ios-rn-build-runios-$$.log"
RUN_EXIT=0
npx react-native run-ios "${RUN_ARGS[@]}" 2>&1 | tee "$RUN_LOG" || RUN_EXIT=$?

# run-ios sometimes fails (exit 65) as a wrapper artifact while xcodebuild itself
# would succeed. Fall back ONCE to direct xcodebuild + simctl install/launch with
# real diagnostics, so the agent never needs to improvise this bypass by hand.
if [[ $RUN_EXIT -ne 0 ]]; then
  echo ">> ios-rn-build: run-ios FAILED (exit $RUN_EXIT). Last errors:" >&2
  grep -iE "error:|fatal|BUILD FAILED" "$RUN_LOG" | tail -8 >&2 || tail -8 "$RUN_LOG" >&2
  WORKSPACE=$(ls -d ios/*.xcworkspace 2>/dev/null | head -1)
  SCHEME=$(basename "${WORKSPACE%.xcworkspace}")
  if [[ -n "$WORKSPACE" ]]; then
    echo ">> ios-rn-build: falling back to direct xcodebuild ($WORKSPACE, scheme $SCHEME)" >&2
    DD="/tmp/ios-rn-build-dd-$$"
    if xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug \
         -destination "id=$UDID" -derivedDataPath "$DD" build > "$RUN_LOG.xcb" 2>&1; then
      APP=$(find "$DD/Build/Products" -maxdepth 2 -name "*.app" -type d | head -1)
      [[ -n "$APP" ]] && xcrun simctl install "$UDID" "$APP" && xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null \
        && echo ">> ios-rn-build: fallback build installed + launched" >&2
    else
      echo ">> ios-rn-build: FAIL — direct xcodebuild also failed. Last errors:" >&2
      grep -iE "error:|fatal|BUILD FAILED" "$RUN_LOG.xcb" | tail -8 >&2 || tail -8 "$RUN_LOG.xcb" >&2
      echo ">> ios-rn-build: full logs: $RUN_LOG $RUN_LOG.xcb" >&2
      exit 1
    fi
  fi
fi

# run-ios can exit 0 without installing (e.g. after an interactive prompt is
# EOF'd in a headless shell). PASS only if the app container actually exists.
if ! xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
  echo ">> ios-rn-build: FAIL — build completed but $BUNDLE_ID is not installed on $UDID" >&2
  exit 1
fi

echo ">> ios-rn-build: PASS (fresh build, installed, launched)"
