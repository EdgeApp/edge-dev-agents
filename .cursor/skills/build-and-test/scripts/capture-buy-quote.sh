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
#                        [--bundle-id <id>] [--quote-secs N] [--window-secs N] [--cycles N]
#
# Defaults:
#   --out         /tmp/agent-mvp-buy-quote-screenshot.png
#   --flow        <this-script-dir>/../maestro/buy-quote-input.yaml
#   --bundle-id   co.edgesecure.app
#   --quote-secs  7   (require a live frame from at least this late post-input)
#   --window-secs 14  (stop bursting after this long; app survived → static frame)
#   --cycles      5   (retry the whole login→Buy→input cycle this many times)
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)         OUT="$2";         shift 2 ;;
    --flow)        FLOW="$2";        shift 2 ;;
    --bundle-id)   BUNDLE_ID="$2";   shift 2 ;;
    --quote-secs)  QUOTE_SECS="$2";  shift 2 ;;
    --window-secs) WINDOW_SECS="$2"; shift 2 ;;
    --cycles)      CYCLES="$2";      shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v maestro       >/dev/null 2>&1 || { echo "maestro not found in PATH" >&2; exit 1; }
command -v xcrun         >/dev/null 2>&1 || { echo "xcrun not found (need Xcode CLT)" >&2; exit 1; }
[[ -f "$FLOW" ]] || { echo "Maestro flow not found: $FLOW" >&2; exit 1; }

TMP="$(mktemp -d /tmp/buyquote-cap.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

alive() { xcrun simctl spawn booted launchctl list 2>/dev/null | grep -qi "${BUNDLE_ID#*.}"; }

for ((cycle = 1; cycle <= CYCLES; cycle++)); do
  echo "[capture] cycle $cycle/$CYCLES: maestro $FLOW ..."
  maestro test "$FLOW" >"$TMP/maestro.log" 2>&1 || true
  best=""; best_t=0; SECONDS=0
  while [[ "$SECONDS" -lt "$WINDOW_SECS" ]]; do
    alive || break
    if xcrun simctl io booted screenshot "$TMP/cap-${SECONDS}-$RANDOM.png" >/dev/null 2>&1; then
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

echo "[capture] FAIL after $CYCLES cycles — last maestro output:"
tail -30 "$TMP/maestro.log" >&2
exit 1
