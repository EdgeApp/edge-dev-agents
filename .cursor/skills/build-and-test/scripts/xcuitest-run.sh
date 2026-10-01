#!/usr/bin/env bash
# xcuitest-run.sh: run one Maestro flow YAML on a slot sim with the native
# XCUITest interpreter (EdgeFlowRunner) instead of the Maestro driver.
#
# Pipeline: maestro-yaml-to-json.rb inlines every runFlow/retry file into one
# JSON document; xcuitest-build.sh returns the cached runner; one
# `xcodebuild test-without-building` drives the sim named by UDID. Nothing
# binds a host port, so any number of slots can run side by side. The runner
# preflights the whole flow tree and fails before step 1 on any command it
# does not implement; there is no Maestro fallback.
#
# Before driving, the slot's maestro MCP daemon (the java process started
# with `--device <this UDID> ... mcp`) is stopped by explicit PID, and the
# Maestro XCTest driver app is terminated on this sim only: two automation
# sessions on one sim fight over the accessibility snapshot.
#
# Usage: xcuitest-run.sh --flow <flow.yaml> [--udid <udid>] [--env K=V ...]
#          [--quiescence-cap <seconds>] [--animations off|fast|on] [--keep-mcp]
#   --udid defaults to $AGENT_SIM_UDID.
#   --quiescence-cap: cap on XCUITest's app-idle wait per event (default 1,
#     0 disables the wait). A flow can override it with env EDGE_QUIESCENCE_CAP.
#   --animations: test-mode animation switch passed to the app as
#     `-EdgeTestAnimations <mode>` on launchApp and persisted in the sim's
#     defaults for relaunches (default off; `on` clears it).
#   Relative takeScreenshot paths resolve against the current directory, as
#   with `maestro test`.
# Output: `[edge-flow]` step lines, then RESULT=passed|failed, WALL=<seconds>,
#   RUN_DIR=<dir with flow.json, xcodebuild.log, result.xcresult>.
# Exit: 0 flow passed; 1 usage/setup error; 2 flow failed.

set -uo pipefail

UDID="${AGENT_SIM_UDID:-}"
FLOW=""
CAP="1"
ANIMATIONS="off"
KEEP_MCP=0
BUNDLE_ID="co.edgesecure.app"
ENV_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flow) FLOW="$2"; shift 2 ;;
    --udid) UDID="$2"; shift 2 ;;
    --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
    --quiescence-cap) CAP="$2"; shift 2 ;;
    --animations) ANIMATIONS="$2"; shift 2 ;;
    --keep-mcp) KEEP_MCP=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$FLOW" && -f "$FLOW" ]] || { echo "xcuitest-run: --flow <existing yaml> required" >&2; exit 1; }
[[ -n "$UDID" ]] || { echo "xcuitest-run: no --udid and \$AGENT_SIM_UDID unset" >&2; exit 1; }
case "$ANIMATIONS" in off|fast|on) ;; *) echo "xcuitest-run: --animations must be off, fast or on" >&2; exit 1 ;; esac

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
START=$(date +%s)
FLOW_NAME="$(basename "$FLOW" .yaml)"
RUN_DIR="${TMPDIR:-/tmp}/edge-flow-runs/$UDID/$(date +%Y%m%d-%H%M%S)-$FLOW_NAME-$$"
mkdir -p "$RUN_DIR"

/usr/bin/ruby "$SCRIPTS/maestro-yaml-to-json.rb" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} "$FLOW" > "$RUN_DIR/flow.json" \
  || { echo "xcuitest-run: could not convert $FLOW" >&2; exit 1; }

BUILD_OUT="$("$SCRIPTS/xcuitest-build.sh" --udid "$UDID")" || { echo "$BUILD_OUT" >&2; exit 1; }
XCTESTRUN="$(printf '%s\n' "$BUILD_OUT" | sed -n 's/^XCTESTRUN=//p' | tail -1)"
[[ -f "$XCTESTRUN" ]] || { echo "xcuitest-run: no xctestrun from xcuitest-build.sh" >&2; exit 1; }

if [[ "$KEEP_MCP" == 0 ]]; then
  for pid in $(pgrep -f "maestro.cli.AppKt --device $UDID .*mcp" || true); do
    echo "xcuitest-run: stopping maestro MCP daemon pid $pid (bound to $UDID)"
    kill "$pid" 2>/dev/null || true
  done
  xcrun simctl terminate "$UDID" dev.mobile.maestro-driver-iosUITests.xctrunner >/dev/null 2>&1 || true
fi

if [[ "$ANIMATIONS" == on ]]; then
  xcrun simctl spawn "$UDID" defaults delete "$BUNDLE_ID" EdgeTestAnimations >/dev/null 2>&1 || true
else
  xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" EdgeTestAnimations "$ANIMATIONS" >/dev/null 2>&1 || true
fi

echo "xcuitest-run: $FLOW on $UDID (cap ${CAP}s, animations $ANIMATIONS), run dir $RUN_DIR"
TEST_RUNNER_EDGE_FLOW_FILE="$RUN_DIR/flow.json" \
TEST_RUNNER_EDGE_FLOW_CWD="$(pwd)" \
TEST_RUNNER_EDGE_QUIESCENCE_CAP="$CAP" \
TEST_RUNNER_EDGE_TEST_ANIMATIONS="$ANIMATIONS" \
  xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID" \
    -only-testing:EdgeFlowRunner/FlowRunnerTests/testFlow -parallel-testing-enabled NO \
    -resultBundlePath "$RUN_DIR/result.xcresult" > "$RUN_DIR/xcodebuild.log" 2>&1 &
XC_PID=$!
# Stream step lines as they land (the log is the full record).
tail -n +1 -f "$RUN_DIR/xcodebuild.log" 2>/dev/null > >(grep --line-buffered '\[edge-flow\]') &
TAIL_PID=$!
wait "$XC_PID"
STATUS=$?
sleep 0.5
kill "$TAIL_PID" 2>/dev/null
wait "$TAIL_PID" 2>/dev/null

if [[ "$STATUS" != 0 ]]; then
  grep -E "error:|Failing tests|\*\* TEST" "$RUN_DIR/xcodebuild.log" | grep -v '\[edge-flow\]' | head -10
fi
echo "RESULT=$([[ "$STATUS" == 0 ]] && echo passed || echo failed)"
echo "WALL=$(( $(date +%s) - START ))"
echo "RUN_DIR=$RUN_DIR"
[[ "$STATUS" == 0 ]] || exit 2
