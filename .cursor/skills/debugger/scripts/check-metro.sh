#!/usr/bin/env bash
# check-metro.sh — Preflight for Hermes debugging via Metro inspector.
#
# Verifies Metro is running on the given port and exposes at least one Hermes
# JS target. Use BEFORE invoking cdp-attach.js to fail fast with an actionable
# error.
#
# Usage:
#   check-metro.sh [--port 8081]
#
# Exit codes:
#   0 = ready (Metro alive, ≥1 Hermes target)
#   1 = Metro not reachable on the requested port
#   2 = Metro alive but no Hermes target (app not running in Hermes mode, or
#       not connected to Metro)

set -euo pipefail

PORT=8081
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! curl -fsS -m 3 "http://localhost:$PORT/status" >/dev/null 2>&1; then
  echo "Metro not reachable on localhost:$PORT" >&2
  echo "  start Metro in the project: npx react-native start --reset-cache" >&2
  exit 1
fi

LIST=$(curl -fsS -m 3 "http://localhost:$PORT/json/list" 2>/dev/null || echo '[]')
HERMES_COUNT=$(echo "$LIST" | jq '[.[] | select((.description // "") + (.title // "") | test("React Native|Hermes|Bridgeless"; "i"))] | length' 2>/dev/null || echo 0)

if [[ "$HERMES_COUNT" -eq 0 ]]; then
  echo "Metro alive on :$PORT but no Hermes JS target found" >&2
  echo "  is the app actually running on a sim/device?" >&2
  echo "  is Hermes enabled in the build? (RN typically default-on now)" >&2
  echo "  current targets:" >&2
  echo "$LIST" | jq -r '.[] | "    - \(.title // "(no title)") | \(.description // "(no desc)")"' >&2
  exit 2
fi

echo ">> check-metro: ready (Metro on :$PORT, $HERMES_COUNT Hermes target(s))"
exit 0
