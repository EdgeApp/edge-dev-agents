#!/usr/bin/env bash
# xcuitest-build.sh: build the EdgeFlowRunner XCUITest bundle once and cache it.
#
# The runner is generic (it interprets flow JSON at run time), so one build
# serves every flow and every slot sim on the same runtime. The cache key is
# Xcode build + target iOS runtime + a hash of the runner sources; a source
# change or Xcode upgrade builds a fresh copy. Concurrent callers (parallel
# slots) serialize on a mkdir lock and reuse the first build.
#
# Usage: xcuitest-build.sh [--udid <udid>] [--force]
#   --udid defaults to $AGENT_SIM_UDID; its runtime picks the cache entry.
# Output: last line is `XCTESTRUN=<path to .xctestrun>`.
# Exit: 0 built or cached; 1 usage or build failure.

set -euo pipefail

UDID="${AGENT_SIM_UDID:-}"
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$UDID" ]] || { echo "xcuitest-build: no --udid and \$AGENT_SIM_UDID unset" >&2; exit 1; }

SRC_DIR="$(cd "$(dirname "$0")/../xcuitest" && pwd)"
RUNTIME="$(xcrun simctl list devices -j | /usr/bin/ruby -rjson -e '
  udid = ARGV[0]
  JSON.parse($stdin.read)["devices"].each { |rt, devs| devs.each { |d| (puts rt.split(".").last; exit) if d["udid"] == udid } }
  exit 1' "$UDID")" || { echo "xcuitest-build: sim $UDID not found" >&2; exit 1; }
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ {print $3}')"
SRC_HASH="$(cd "$SRC_DIR" && find . -type f \( -name '*.swift' -o -name '*.m' -o -name '*.h' -o -name '*.pbxproj' -o -name '*.xcscheme' \) -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-12)"
CACHE_ROOT="$HOME/Library/Caches/edge-flow-runner"
CACHE="$CACHE_ROOT/$XCODE_BUILD-$RUNTIME-$SRC_HASH"
LOCK="$CACHE_ROOT/.lock-$XCODE_BUILD-$RUNTIME"
mkdir -p "$CACHE_ROOT"

find_xctestrun() { find "$CACHE/Build/Products" -maxdepth 1 -name '*.xctestrun' 2>/dev/null | head -1; }

if [[ "$FORCE" == 0 && -f "$CACHE/.done" ]]; then
  echo "xcuitest-build: cached ($CACHE)"
  echo "XCTESTRUN=$(find_xctestrun)"
  exit 0
fi

# mkdir is atomic; a lock older than 15 minutes belongs to a dead build.
waited=0
until mkdir "$LOCK" 2>/dev/null; do
  if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +15 2>/dev/null)" ]]; then
    echo "xcuitest-build: removing stale lock $LOCK" >&2
    rmdir "$LOCK" 2>/dev/null || true
    continue
  fi
  (( waited % 30 == 0 )) && echo "xcuitest-build: waiting for another build ($LOCK)"
  sleep 2; waited=$((waited + 2))
  (( waited < 900 )) || { echo "xcuitest-build: lock wait timed out" >&2; exit 1; }
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

if [[ "$FORCE" == 0 && -f "$CACHE/.done" ]]; then
  echo "xcuitest-build: built by a concurrent caller ($CACHE)"
  echo "XCTESTRUN=$(find_xctestrun)"
  exit 0
fi

rm -rf "$CACHE"
echo "xcuitest-build: building runner for $RUNTIME (Xcode $XCODE_BUILD) into $CACHE"
if ! xcodebuild build-for-testing \
  -project "$SRC_DIR/EdgeFlowRunner.xcodeproj" -scheme EdgeFlowRunner \
  -destination "id=$UDID" -derivedDataPath "$CACHE" -quiet > "$CACHE_ROOT/build-$RUNTIME.log" 2>&1; then
  grep -E "error:" "$CACHE_ROOT/build-$RUNTIME.log" | head -20 >&2
  echo "xcuitest-build: build failed, full log $CACHE_ROOT/build-$RUNTIME.log" >&2
  exit 1
fi
touch "$CACHE/.done"
echo "XCTESTRUN=$(find_xctestrun)"
