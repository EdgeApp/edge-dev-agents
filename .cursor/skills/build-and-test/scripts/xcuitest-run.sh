#!/usr/bin/env bash
# xcuitest-run.sh: drive a slot sim with the native XCUITest interpreter
# (EdgeFlowRunner) instead of the Maestro driver. Three modes, one command:
#   --flow <flow.yaml>   run a Maestro flow file (the proof run)
#   --steps '<yaml>'     run inline steps against the live app, no flow file
#   --inspect            print the current screen's elements
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
# Usage: xcuitest-run.sh (--flow <flow.yaml> | --steps '<yaml>' | --inspect)
#          [--full] [--udid <udid>] [--env K=V ...]
#          [--quiescence-cap <seconds>] [--animations off|fast|on]
#          [--lookup-timeout <seconds>] [--tap-check note|off] [--typing auto|events]
#          [--keep-mcp] [--login-role <role>]
#   --udid defaults to $AGENT_SIM_UDID.
#   --steps: a command list (`- tapOn: Wallets`), one `command: args` map, or
#     a bare command name. The steps run against the app as it is: nothing
#     launches or relaunches it unless a step says launchApp. runFlow paths
#     resolve against the current directory.
#   --inspect: print the screen as `type id= label= value= frame=x,y,WxH
#     hit|nohit|offscreen [disabled]` lines, indented by nesting, then exit.
#     It sends no event and never launches the app. Compact by default (only
#     elements a selector can name; keyboard keys folded into one line);
#     --full prints every node. Combined with --steps or --flow it prints the
#     screen after the last step, and after a failed step.
#   --lookup-timeout: how long a tap or an assert waits for its element.
#     Default with --flow: Maestro's 17 (7 for optional steps). Default with
#     --steps: 3, so a selector that misses fails fast. A failed probe also
#     skips xcodebuild's failure diagnostics (about 25s).
#   --quiescence-cap: cap on XCUITest's app-idle wait per event (default 1,
#     0 disables the wait). A flow can override it with env EDGE_QUIESCENCE_CAP.
#   --animations: test-mode animation switch passed to the app as
#     `-EdgeTestAnimations <mode>` on launchApp and persisted in the sim's
#     defaults for relaunches (default off; `on` clears it). Without --flow
#     the sim default is left alone unless --animations is passed.
#   --tap-check: `note` (default) compares the screen before and after every
#     tap and marks a tap that changed nothing in its step line; `off` skips
#     the two screenshots per tap.
#   --typing: `auto` (default) types through the focused element, then the
#     on-screen keys, then key events when the keys are off screen; `events`
#     sends every string as key events.
#   --login-role: a role in ~/.config/edge-secrets/test-accounts.json. Passes
#     that account to the flow as env EXPECT_USERNAME and PIN_DIGIT (read by
#     common/login-if-needed.yaml, which refuses to tap a PIN on another
#     account's PIN scene) and masks the username and tapped digits in the
#     output.
#   Relative takeScreenshot paths resolve against the current directory, as
#   with `maestro test`.
# Output: `[edge-flow]` step lines and the inspect lines, then
#   RESULT=passed|failed, WALL=<seconds>,
#   RUN_DIR=<dir with flow.json, xcodebuild.log, result.xcresult>.
# Exit: 0 passed; 1 usage/setup error; 2 a step or the inspect failed.

set -uo pipefail

UDID="${AGENT_SIM_UDID:-}"
FLOW=""
STEPS=""
HAVE_STEPS=0
INSPECT=""
FULL=0
CAP="1"
LOOKUP=""
ANIMATIONS="off"
SET_ANIMATIONS=0
KEEP_MCP=0
TAP_CHECK="note"
TYPING="auto"
LOGIN_ROLE=""
BUNDLE_ID="co.edgesecure.app"
ENV_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flow) FLOW="$2"; shift 2 ;;
    --steps) STEPS="$2"; HAVE_STEPS=1; shift 2 ;;
    --inspect) INSPECT="compact"; shift ;;
    --full) FULL=1; shift ;;
    --udid) UDID="$2"; shift 2 ;;
    --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
    --quiescence-cap) CAP="$2"; shift 2 ;;
    --lookup-timeout) LOOKUP="$2"; shift 2 ;;
    --animations) ANIMATIONS="$2"; SET_ANIMATIONS=1; shift 2 ;;
    --tap-check) TAP_CHECK="$2"; shift 2 ;;
    --typing) TYPING="$2"; shift 2 ;;
    --keep-mcp) KEEP_MCP=1; shift ;;
    --login-role) LOGIN_ROLE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [[ -n "$FLOW" ]]; then
  [[ -f "$FLOW" ]] || { echo "xcuitest-run: flow not found: $FLOW" >&2; exit 1; }
  [[ "$HAVE_STEPS" == 0 ]] || { echo "xcuitest-run: pass --flow or --steps, not both" >&2; exit 1; }
  SET_ANIMATIONS=1
elif [[ "$HAVE_STEPS" == 0 && -z "$INSPECT" ]]; then
  echo "xcuitest-run: one of --flow <yaml>, --steps '<yaml>' or --inspect required" >&2; exit 1
fi
[[ "$FULL" == 0 ]] || { [[ -n "$INSPECT" ]] || { echo "xcuitest-run: --full needs --inspect" >&2; exit 1; }; INSPECT="full"; }
[[ -n "$UDID" ]] || { echo "xcuitest-run: no --udid and \$AGENT_SIM_UDID unset" >&2; exit 1; }
case "$ANIMATIONS" in off|fast|on) ;; *) echo "xcuitest-run: --animations must be off, fast or on" >&2; exit 1 ;; esac
case "$TAP_CHECK" in note|off) ;; *) echo "xcuitest-run: --tap-check must be note or off" >&2; exit 1 ;; esac
case "$TYPING" in auto|events) ;; *) echo "xcuitest-run: --typing must be auto or events" >&2; exit 1 ;; esac

MASK=()
if [[ -n "$LOGIN_ROLE" ]]; then
  ROSTER="$HOME/.config/edge-secrets/test-accounts.json"
  LOGIN_USER="$(jq -r --arg r "$LOGIN_ROLE" '.roster[$r].username // empty' "$ROSTER" 2>/dev/null)"
  LOGIN_PIN="$(jq -r --arg r "$LOGIN_ROLE" '.roster[$r].pin // empty' "$ROSTER" 2>/dev/null)"
  [[ -n "$LOGIN_USER" && -n "$LOGIN_PIN" ]] || { echo "xcuitest-run: no roster role $LOGIN_ROLE in $ROSTER" >&2; exit 1; }
  ENV_ARGS+=(--env "EXPECT_USERNAME=$LOGIN_USER" --env "PIN_DIGIT=${LOGIN_PIN:0:1}")
  MASK=(-e "s/$(printf '%s' "$LOGIN_USER" | sed 's/[][\\.*^$/]/\\&/g')/<$LOGIN_ROLE account>/g"
    -e 's/tapOn "[0-9]"/tapOn "<digit>"/g' -e 's/"text":"[0-9]"/"text":"<digit>"/g'
    -e 's/text="[0-9]"/text="<digit>"/g')
fi

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
START=$(date +%s)
if [[ -n "$FLOW" ]]; then
  FLOW_NAME="$(basename "$FLOW" .yaml)"
  SOURCE=("$FLOW")
elif [[ "$HAVE_STEPS" == 1 ]]; then
  FLOW_NAME="steps"
  SOURCE=(--steps "$STEPS")
else
  FLOW_NAME="inspect"
  SOURCE=(--steps "[]")
fi
DIAGNOSTICS=()
if [[ -z "$FLOW" ]]; then
  LOOKUP="${LOOKUP:-3}"
  DIAGNOSTICS=(-collect-test-diagnostics never)
fi
LOOKUP_MS=""
if [[ -n "$LOOKUP" ]]; then
  LOOKUP_MS="$(awk -v s="$LOOKUP" 'BEGIN { if (s ~ /^[0-9]+(\.[0-9]+)?$/) printf "%d", s * 1000 }')"
  [[ -n "$LOOKUP_MS" ]] || { echo "xcuitest-run: --lookup-timeout must be a number of seconds" >&2; exit 1; }
fi
RUN_DIR="${TMPDIR:-/tmp}/edge-flow-runs/$UDID/$(date +%Y%m%d-%H%M%S)-$FLOW_NAME-$$"
mkdir -p "$RUN_DIR"

/usr/bin/ruby "$SCRIPTS/maestro-yaml-to-json.rb" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} "${SOURCE[@]}" > "$RUN_DIR/flow.json" \
  || { echo "xcuitest-run: could not convert ${FLOW:-the inline steps}" >&2; exit 1; }

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

if [[ "$SET_ANIMATIONS" == 0 ]]; then
  :
elif [[ "$ANIMATIONS" == on ]]; then
  xcrun simctl spawn "$UDID" defaults delete "$BUNDLE_ID" EdgeTestAnimations >/dev/null 2>&1 || true
else
  xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" EdgeTestAnimations "$ANIMATIONS" >/dev/null 2>&1 || true
fi

echo "xcuitest-run: ${FLOW:-$FLOW_NAME} on $UDID (cap ${CAP}s, animations $ANIMATIONS${INSPECT:+, inspect $INSPECT}), run dir $RUN_DIR"
TEST_RUNNER_EDGE_FLOW_FILE="$RUN_DIR/flow.json" \
TEST_RUNNER_EDGE_FLOW_CWD="$(pwd)" \
TEST_RUNNER_EDGE_QUIESCENCE_CAP="$CAP" \
TEST_RUNNER_EDGE_TEST_ANIMATIONS="$ANIMATIONS" \
TEST_RUNNER_EDGE_INSPECT="$INSPECT" \
TEST_RUNNER_EDGE_TAP_CHECK="$TAP_CHECK" \
TEST_RUNNER_EDGE_TYPING="$TYPING" \
TEST_RUNNER_EDGE_LOOKUP_MS="$LOOKUP_MS" \
TEST_RUNNER_EDGE_OPTIONAL_LOOKUP_MS="$LOOKUP_MS" \
  xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID" \
    -only-testing:EdgeFlowRunner/FlowRunnerTests/testFlow -parallel-testing-enabled NO \
    ${DIAGNOSTICS[@]+"${DIAGNOSTICS[@]}"} \
    -resultBundlePath "$RUN_DIR/result.xcresult" > "$RUN_DIR/xcodebuild.log" 2>&1 &
XC_PID=$!
# Stream step and inspect lines as they land (the log is the full record).
tail -n +1 -f "$RUN_DIR/xcodebuild.log" 2>/dev/null > >(sed -l -n ${MASK[@]+"${MASK[@]}"} -e '/\[edge-flow\]/p' -e 's/^.*\[edge-inspect\] //p') &
TAIL_PID=$!
wait "$XC_PID"
STATUS=$?
sleep 0.5
kill "$TAIL_PID" 2>/dev/null
wait "$TAIL_PID" 2>/dev/null

if [[ "$STATUS" != 0 ]]; then
  grep -E "error:|Failing tests|\*\* TEST" "$RUN_DIR/xcodebuild.log" | grep -v '\[edge-\(flow\|inspect\)\]' | head -10
fi
echo "RESULT=$([[ "$STATUS" == 0 ]] && echo passed || echo failed)"
echo "WALL=$(( $(date +%s) - START ))"
echo "RUN_DIR=$RUN_DIR"
[[ "$STATUS" == 0 ]] || exit 2
