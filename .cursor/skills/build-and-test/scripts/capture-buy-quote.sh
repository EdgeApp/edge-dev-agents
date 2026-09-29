#!/usr/bin/env bash
# capture-buy-quote.sh — Reliably capture the Edge iOS "Buy <amount> quote" proof screenshot.
#
# Why a wrapper instead of a plain in-flow maestro `takeScreenshot`?
#
# The Buy (Ramp) scene in this debug build has an INTERMITTENT React Native
# Fabric text-measure crash (RCTTextLayoutManager / folly::EvictingCacheMap
# SIGABRT). Two things make a single in-flow screenshot unreliable:
#   1. maestro's assertVisible / extendedWaitUntil traverse the accessibility
#      hierarchy on a poll loop, which forces text re-measurement and
#      *provokes* the crash.
#   2. The quote takes ~6s to resolve, but the crash can fire any time on the
#      scene, so a fixed-delay single shot is either too early (still loading)
#      or too late (already crashed → springboard).
#
# This wrapper drives the interaction with maestro (the input flow), which does
# no polling after entering the amount, then captures with an EXTERNAL simctl
# screenshot burst (pixel-only, no hierarchy traversal), keeping the LAST frame
# taken while the app was still alive — i.e. the resolved quote, just before any
# crash. Retries the whole cycle until it lands a frame from late enough to
# show the quote.
#
# Usage:
#   capture-buy-quote.sh [--out <path>] [--flow <path-to-maestro-yaml>] \
#                        [--bundle-id <id>] [--quote-secs N] [--window-secs N] [--cycles N] \
#                        [--device <udid>] [--driver-port N] \
#                        [--engine maestro|maestro-runner]
#
# Defaults:
#   --out         /tmp/agent-mvp-buy-quote-screenshot.png
#   --flow        <this-script-dir>/../maestro/buy-quote-input.yaml
#   --bundle-id   co.edgesecure.app
#   --quote-secs  7   (require a live frame from at least this late post-input)
#   --window-secs 14  (stop bursting after this long; app survived → static frame)
#   --cycles      5   (retry the whole login→Buy→input cycle this many times)
#   --device      $AGENT_SIM_UDID when set (slot session), else simctl "booted"
#   --driver-port $AGENT_METRO_PORT+1000 when set (per-slot maestro driver port,
#                 keeps parallel slots' iOS drivers off each other), else unset.
#                 maestro engine only: maestro-runner has no such flag (its WDA
#                 port is derived from the UDID)
#   --engine      $AGENT_MAESTRO_ENGINE when set, else maestro. maestro-runner
#                 runs the same flow YAML through WebDriverAgent. There is no
#                 fallback between engines: a missing or failing engine fails
#                 the capture, so a proof never silently changes driver.
#
# Device pinning: with multiple sims booted (parallel orch slots), an unpinned
# maestro attaches to an arbitrary device and `simctl io booted` photographs an
# arbitrary one — the two can DISAGREE, producing sincere-but-false proof of the
# wrong simulator. Every maestro/simctl call below therefore targets ONE
# resolved $DEVICE.
#
# Exit codes:
#   0 = captured a post-quote-resolution frame
#   1 = exhausted retries without capturing a usable frame

set -euo pipefail

export PATH="$HOME/.maestro/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="/tmp/agent-mvp-buy-quote-screenshot.png"
FLOW="$SCRIPT_DIR/../maestro/buy-quote-input.yaml"
BUNDLE_ID="co.edgesecure.app"
QUOTE_SECS=7
WINDOW_SECS=14
CYCLES=5
DEVICE="${AGENT_SIM_UDID:-}"
DRIVER_PORT=""
[[ -n "${AGENT_METRO_PORT:-}" ]] && DRIVER_PORT=$((AGENT_METRO_PORT + 1000))
ENGINE="${AGENT_MAESTRO_ENGINE:-maestro}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)         OUT="$2";         shift 2 ;;
    --flow)        FLOW="$2";        shift 2 ;;
    --bundle-id)   BUNDLE_ID="$2";   shift 2 ;;
    --quote-secs)  QUOTE_SECS="$2";  shift 2 ;;
    --window-secs) WINDOW_SECS="$2"; shift 2 ;;
    --cycles)      CYCLES="$2";      shift 2 ;;
    --device)      DEVICE="$2";      shift 2 ;;
    --driver-port) DRIVER_PORT="$2"; shift 2 ;;
    --engine)      ENGINE="$2";      shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Resolve the device once; "booted" is acceptable ONLY outside slot sessions
# (single-sim manual use). Build the maestro global args from what's resolved.
SIMCTL_DEVICE="${DEVICE:-booted}"
MAESTRO_ARGS=()
case "$ENGINE" in
  maestro)
    [[ -n "$DEVICE" ]]      && MAESTRO_ARGS+=(--device "$DEVICE")
    [[ -n "$DRIVER_PORT" ]] && MAESTRO_ARGS+=(--driver-host-port "$DRIVER_PORT")
    ;;
  maestro-runner)
    # Without --platform ios the runner defaults to Android.
    export PATH="$HOME/.maestro-runner/bin:$PATH"
    MAESTRO_ARGS+=(--platform ios --no-ansi)
    [[ -n "$DEVICE" ]] && MAESTRO_ARGS+=(--device "$DEVICE")
    ;;
  *) echo "Unknown --engine: $ENGINE (maestro|maestro-runner)" >&2; exit 1 ;;
esac

command -v "$ENGINE"     >/dev/null 2>&1 || { echo "$ENGINE not found in PATH" >&2; exit 1; }
command -v xcrun         >/dev/null 2>&1 || { echo "xcrun not found (need Xcode CLT)" >&2; exit 1; }
[[ -f "$FLOW" ]] || { echo "Maestro flow not found: $FLOW" >&2; exit 1; }

TMP="$(mktemp -d /tmp/buyquote-cap.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

alive() { xcrun simctl spawn "$SIMCTL_DEVICE" launchctl list 2>/dev/null | grep -qi "${BUNDLE_ID#*.}"; }

for ((cycle = 1; cycle <= CYCLES; cycle++)); do
  echo "[capture] cycle $cycle/$CYCLES: $ENGINE ${MAESTRO_ARGS[*]:-} $FLOW (simctl device: $SIMCTL_DEVICE) ..."
  if [[ "$ENGINE" = maestro-runner ]]; then
    # The runner does not resolve a flow header's `appId: ${APP_ID}` from the
    # flow's own env: block (every library flow uses that header), so pass it.
    "$ENGINE" "${MAESTRO_ARGS[@]}" --output "$TMP/report-$cycle" test -e "APP_ID=$BUNDLE_ID" "$FLOW" >"$TMP/maestro.log" 2>&1 || true
    # A matchNote means the runner found an element only through its own
    # fallback (e.g. a React Native container it rescued as visible). The
    # flow passing does not settle the selector: add the testID
    # (build-and-test testids-over-coordinates).
    grep -rhoE '"matchNote": *"[^"]*"' "$TMP/report-$cycle" 2>/dev/null | sort -u |
      sed 's/^/[capture] WARN testID owed, selector matched via runner fallback: /' >&2 || true
    # The runner's text match is CONTAINS over each element's combined label,
    # so `tapOn: "1"` can resolve to a full-screen React Native container and
    # tap its center while the step reports passed, with no matchNote. Flag a
    # match whose element text is not the selector (placeholders unresolved in
    # the report count as wildcards) or is over 100 chars: that step touched
    # the wrong element, and the testID is owed.
    cat "$TMP"/report-"$cycle"/*/flows/*.json 2>/dev/null | jq -r '
      [.. | objects | select(.params?.selector?.type? == "text" and (.element?.text? // "") != "")] | .[]
      | (.params.selector.value | gsub("\\$\\{[^}]*\\}"; ".*")) as $re
      | select(((try (.element.text | test("^(" + $re + ")$"; "is")) catch false) | not) or (.element.text | length) > 100)
      | "[capture] WARN testID owed, runner matched a container for \(.params.selector.value): \(.element.text | .[0:60])"' |
      sort -u >&2 || true
  else
    maestro ${MAESTRO_ARGS[@]+"${MAESTRO_ARGS[@]}"} test "$FLOW" >"$TMP/maestro.log" 2>&1 || true
  fi
  best=""; best_t=0; SECONDS=0
  while [[ "$SECONDS" -lt "$WINDOW_SECS" ]]; do
    alive || break
    if xcrun simctl io "$SIMCTL_DEVICE" screenshot "$TMP/cap-${SECONDS}-$RANDOM.png" >/dev/null 2>&1; then
      best="$(ls -t "$TMP"/cap-*.png 2>/dev/null | head -1)"; best_t=$SECONDS
    fi
  done
  echo "[capture] last live frame at t=${best_t}s"
  if [[ -n "$best" && "$best_t" -ge "$QUOTE_SECS" ]]; then
    cp "$best" "$OUT"
    echo "[capture] PASS — $OUT (live frame at t=${best_t}s; quote resolved before crash)"
    exit 0
  fi
  echo "[capture] crashed before the quote resolved (last frame t=${best_t}s); retrying ..."
done

echo "[capture] FAIL after $CYCLES cycles — last $ENGINE output:"
tail -30 "$TMP/maestro.log" >&2
exit 1
